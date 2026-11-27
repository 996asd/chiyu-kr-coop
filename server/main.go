package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

const (
	maxFrameBytes = 4 * 1024 * 1024 // Hard 4 MB upper bound per JSON line (anti-OOM)
	maxMsgsPerSec = 200             // Per-client message rate limit (ample for 60Hz turns + voice + ping)
)

var errFrameTooLarge = errors.New("frame exceeds maximum size")

// readLineLimited reads a single '\n'-terminated frame while strictly bounding memory to limit bytes.
// Unlike bufio.Reader.ReadBytes('\n'), an attacker sending gigabytes without '\n' is rejected immediately.
func readLineLimited(r *bufio.Reader, limit int) ([]byte, error) {
	var out []byte
	for {
		frag, err := r.ReadSlice('\n')
		if len(out)+len(frag) > limit {
			return nil, errFrameTooLarge
		}
		if err == nil {
			if len(out) == 0 {
				cp := make([]byte, len(frag))
				copy(cp, frag)
				return cp, nil
			}
			return append(out, frag...), nil
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			out = append(out, frag...)
			continue
		}
		if len(frag) > 0 {
			out = append(out, frag...)
		}
		return out, err
	}
}

func extractRemoteIP(addr net.Addr) string {
	if addr == nil {
		return ""
	}
	host, _, err := net.SplitHostPort(addr.String())
	if err != nil {
		return addr.String()
	}
	return host
}

func isLoopbackIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	return ip != nil && ip.IsLoopback()
}

type Client struct {
	id             int64
	remoteIP       string
	conn           net.Conn
	hub            *Hub
	sendCh         chan []byte
	done           chan struct{}
	closeOnce      sync.Once
	helloDone      bool
	name           string
	modVer         string
	flVer          string
	scriptHash     string
	tickLen        float64
	roomCode       string
	pid            int
	msgWindowStart time.Time
	msgWindowCount int
	lastCreateRoom time.Time
}

func NewClient(conn net.Conn, hub *Hub) *Client {
	var rip string
	if conn != nil {
		rip = extractRemoteIP(conn.RemoteAddr())
	}
	return &Client{
		remoteIP: rip,
		conn:     conn,
		hub:      hub,
		sendCh:   make(chan []byte, 256),
		done:     make(chan struct{}),
	}
}

func (c *Client) Send(v any) {
	line, err := encodeLine(v)
	if err != nil {
		log.Printf("[CLIENT %d] encode error: %v", c.id, err)
		return
	}
	select {
	case <-c.done:
		return
	default:
	}
	select {
	case <-c.done:
		return
	case c.sendCh <- line:
	default:
		log.Printf("[CLIENT %d] send buffer full; dropping slow client", c.id)
		c.Close()
	}
}

// SendDropIfBusy queues ephemeral traffic (such as live voice frames) only when plenty of buffer headroom exists,
// guaranteeing voice traffic can NEVER congest or disconnect 60Hz lockstep match frames.
func (c *Client) SendDropIfBusy(v any) {
	if len(c.sendCh) >= cap(c.sendCh)/2 {
		return
	}
	line, err := encodeLine(v)
	if err != nil {
		return
	}
	select {
	case <-c.done:
		return
	case c.sendCh <- line:
	default:
	}
}

func (c *Client) Close() {
	c.closeOnce.Do(func() {
		close(c.done)
		_ = c.conn.Close()
	})
}

func (c *Client) writeLoop() {
	for {
		select {
		case <-c.done:
			return
		case line := <-c.sendCh:
			_ = c.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if _, err := c.conn.Write(line); err != nil {
				c.Close()
				return
			}
		}
	}
}

func (c *Client) readLoop() {
	defer func() {
		c.hub.UnregisterClient(c)
		c.Close()
	}()

	// Allow large START_MATCH / slot_snapshot / RECONNECT_STATE payloads up to 4 MB per line (strictly bounded)
	reader := bufio.NewReaderSize(c.conn, 64*1024)
	for {
		_ = c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		line, err := readLineLimited(reader, maxFrameBytes)
		if err != nil {
			if errors.Is(err, errFrameTooLarge) {
				log.Printf("[CLIENT %d] oversized frame (>%d bytes) from %s; disconnecting", c.id, maxFrameBytes, c.remoteIP)
			} else if err != io.EOF {
				log.Printf("[CLIENT %d] read closed: %v", c.id, err)
			}
			return
		}

		now := time.Now()
		if c.msgWindowStart.IsZero() || now.Sub(c.msgWindowStart) >= time.Second {
			c.msgWindowStart = now
			c.msgWindowCount = 1
		} else {
			c.msgWindowCount++
			if c.msgWindowCount > maxMsgsPerSec {
				log.Printf("[CLIENT %d] rate limit exceeded (%d msgs/s) from %s; disconnecting", c.id, c.msgWindowCount, c.remoteIP)
				return
			}
		}

		var msg IncomingMsg
		if err := json.Unmarshal(line, &msg); err != nil {
			log.Printf("[CLIENT %d] malformed JSON: %v", c.id, err)
			c.Send(map[string]any{"t": "ERROR", "msg": "Malformed JSON packet"})
			continue
		}
		c.hub.HandleMessage(c, &msg)
	}
}

func main() {
	addr := flag.String("addr", ":17780", "TCP listen address for KR-MP clients")
	httpAddr := flag.String("http", "", "Optional HTTP status endpoint (e.g. 127.0.0.1:17781)")
	graceSec := flag.Int("grace", 300, "Reconnect grace period in seconds for dropped matches")
	maxRooms := flag.Int("max-rooms", 200, "Maximum concurrent rooms")
	maxConns := flag.Int("max-conns", 500, "Maximum concurrent TCP client connections")
	maxPerIP := flag.Int("max-per-ip", 16, "Maximum concurrent TCP connections per non-loopback IP")
	maxRoomsPerIP := flag.Int("max-rooms-per-ip", 4, "Maximum concurrent rooms per non-loopback IP")
	flag.Parse()

	hub := NewHubWithLimits(*maxRooms, *maxConns, *maxPerIP, *maxRoomsPerIP, time.Duration(*graceSec)*time.Second)
	stopJanitor := make(chan struct{})
	go hub.RunJanitor(stopJanitor)

	if *httpAddr != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(hub.Stats())
		})
		go func() {
			log.Printf("[KR-MP SERVER] HTTP health listening on %s/health", *httpAddr)
			if err := http.ListenAndServe(*httpAddr, mux); err != nil {
				log.Printf("[KR-MP SERVER] HTTP error: %v", err)
			}
		}()
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("[KR-MP SERVER] Failed to listen on %s: %v", *addr, err)
	}
	defer ln.Close()

	log.Printf("=== KR-MP Public Lobby & Frame-Relay Server v%s (proto=%d) ===", ServerVersion, ProtocolVer)
	log.Printf("[KR-MP SERVER] Listening on TCP %s | Reconnect Grace: %ds | Max Rooms: %d",
		*addr, *graceSec, *maxRooms)

	// Graceful shutdown on Ctrl+C / SIGTERM
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Printf("[KR-MP SERVER] Shutting down...")
		close(stopJanitor)
		_ = ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-stopJanitor:
				return
			default:
				log.Printf("[KR-MP SERVER] Accept error: %v", err)
				continue
			}
		}
		if tc, ok := conn.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
			_ = tc.SetKeepAlive(true)
			_ = tc.SetKeepAlivePeriod(20 * time.Second)
		}
		client := NewClient(conn, hub)
		id, rejectReason := hub.TryRegisterClient(client)
		if rejectReason != "" {
			log.Printf("[LIMIT] Rejected connection from %s: %s", conn.RemoteAddr(), rejectReason)
			_ = conn.Close()
			continue
		}
		log.Printf("[CLIENT %d] Connected from %s", id, conn.RemoteAddr())
		go client.writeLoop()
		go client.readLoop()
	}
}

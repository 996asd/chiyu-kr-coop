package main

import (
	"bufio"
	"encoding/json"
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

type Client struct {
	id         int64
	conn       net.Conn
	hub        *Hub
	sendCh     chan []byte
	done       chan struct{}
	closeOnce  sync.Once
	helloDone  bool
	name       string
	modVer     string
	flVer      string
	scriptHash string
	tickLen    float64
	roomCode   string
	pid        int
}

func NewClient(conn net.Conn, hub *Hub) *Client {
	return &Client{
		conn:   conn,
		hub:    hub,
		sendCh: make(chan []byte, 256),
		done:   make(chan struct{}),
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

	// Allow large START_MATCH / slot_snapshot / RECONNECT_STATE payloads up to 4 MB per line
	reader := bufio.NewReaderSize(c.conn, 64*1024)
	for {
		_ = c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err != io.EOF {
				log.Printf("[CLIENT %d] read closed: %v", c.id, err)
			}
			return
		}
		if len(line) > 4*1024*1024 {
			log.Printf("[CLIENT %d] oversized frame (%d bytes)", c.id, len(line))
			return
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
	httpAddr := flag.String("http", "", "Optional HTTP status endpoint (e.g. :17781)")
	graceSec := flag.Int("grace", 300, "Reconnect grace period in seconds for dropped matches")
	maxRooms := flag.Int("max-rooms", 200, "Maximum concurrent rooms")
	flag.Parse()

	hub := NewHub(*maxRooms, time.Duration(*graceSec)*time.Second)
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
		id := hub.RegisterClient(client)
		log.Printf("[CLIENT %d] Connected from %s", id, conn.RemoteAddr())
		go client.writeLoop()
		go client.readLoop()
	}
}

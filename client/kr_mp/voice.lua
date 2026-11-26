-- KR-MP Built-in Real-Time Voice Chat Engine (Zero-Dependency LuaJIT FFI + Windows WinMM + love.thread)
-- Features:
--   - 16kHz Mono 16-bit PCM captured & played inside an isolated love.thread (0ms impact on 60Hz game loop / PRNG)
--   - Self-contained 40ms IMA-ADPCM frames (~8.1 KB/s binary, ~10.8 KB/s base64 while speaking; 0 KB/s when silent)
--   - 1st-order DC high-pass filter + smart VAD (noise gate + 320ms hangover) + Push-to-Talk (V) + Quick Mute (M)
--   - Jitter-buffered waveOut playback + live animated 5-bar spectrum levels for 1P/2P livestream overlays
--   - Graceful degradation on headless / mic-less machines (listen-only works even with 0 microphones!)
local voice = {
    boot = nil,
    transport = nil,

    supported = false,
    disabled_for_test = false,
    thread = nil,
    ch_cmd = nil,
    ch_out = nil,

    -- User settings (persisted in kr_mp_prefs.json)
    mode = "ptt",          -- "ptt" (按V说话) | "vad" (自由麦) | "mute" (闭麦)
    peer_muted = false,    -- mute incoming roommate audio
    peer_volume = 1.0,     -- 0.0 .. 1.6
    vad_threshold = 0.018, -- normalized RMS threshold for free-mic VAD
    self_test = false,     -- local loopback test (hear yourself in lobby)

    -- Live runtime status
    active_room = false,
    peer_connected = false,
    online_server_ok = true,
    ptt_held = false,
    in_devs = 0,
    out_devs = 0,
    mic_open = false,
    spk_open = false,
    last_err = nil,

    -- Live visual telemetry for Lobby & Livestream Battle Overlay (never touches sim!)
    local_level = 0,       -- smoothed 0..1
    local_talking = false,
    local_talk_until = 0,
    peer_level = 0,        -- smoothed 0..1
    peer_talking = false,
    peer_talk_until = 0,
    tx_count = 0,
    rx_count = 0,
    _last_cfg_sig = nil,
}

-- Pure-Lua fast Base64 encoder/decoder (RFC 4648)
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_ENC = {}
local B64_DEC = {}
for i = 1, 64 do
    local c = B64_CHARS:sub(i, i)
    B64_ENC[i - 1] = c
    B64_DEC[string.byte(c)] = i - 1
end

local function b64_encode(data)
    if not data or #data == 0 then return "" end
    local out = {}
    local n = #data
    local k = 0
    local i = 1
    while i <= n do
        local a = string.byte(data, i) or 0
        local b = string.byte(data, i + 1)
        local c = string.byte(data, i + 2)
        local bb = b or 0
        local cc = c or 0
        local v = a * 65536 + bb * 256 + cc
        k = k + 1; out[k] = B64_ENC[math.floor(v / 262144) % 64]
        k = k + 1; out[k] = B64_ENC[math.floor(v / 4096) % 64]
        k = k + 1; out[k] = b and B64_ENC[math.floor(v / 64) % 64] or "="
        k = k + 1; out[k] = c and B64_ENC[v % 64] or "="
        i = i + 3
    end
    return table.concat(out)
end

local function b64_decode(str)
    if type(str) ~= "string" or #str == 0 then return nil end
    local out = {}
    local k = 0
    local n = #str
    local i = 1
    while i <= n do
        local c1 = B64_DEC[string.byte(str, i) or 0]
        local c2 = B64_DEC[string.byte(str, i + 1) or 0]
        if not c1 or not c2 then break end
        local b3 = string.byte(str, i + 2) or 61
        local b4 = string.byte(str, i + 3) or 61
        local c3 = B64_DEC[b3]
        local c4 = B64_DEC[b4]
        local v = c1 * 262144 + c2 * 4096 + (c3 or 0) * 64 + (c4 or 0)
        k = k + 1; out[k] = string.char(math.floor(v / 65536) % 256)
        if b3 ~= 61 and c3 then
            k = k + 1; out[k] = string.char(math.floor(v / 256) % 256)
        end
        if b4 ~= 61 and c4 then
            k = k + 1; out[k] = string.char(v % 256)
        end
        i = i + 4
    end
    return table.concat(out)
end

-- Exported for unit / loopback verification
voice._b64_encode = b64_encode
voice._b64_decode = b64_decode

-- Isolated Windows WinMM + IMA-ADPCM Audio Worker Thread (runs completely outside 60Hz game loop)
local WORKER_CODE = [===[
local ch_cmd_name, ch_out_name = ...
local ch_cmd = love.thread.getChannel(ch_cmd_name)
local ch_out = love.thread.getChannel(ch_out_name)

local ok_timer, ltimer = pcall(require, "love.timer")
local ok_ffi, ffi = pcall(require, "ffi")
local ok_bit, bit = pcall(require, "bit")
if not ok_ffi or not ok_bit or ffi.os ~= "Windows" then
    ch_out:push({ kind = "init", ok = false, err = "non_windows_or_no_ffi" })
    return
end

ffi.cdef[[
    typedef unsigned int UINT;
    typedef unsigned long DWORD;
    typedef unsigned short WORD;
    typedef uintptr_t DWORD_PTR;
    typedef void* HWAVEIN;
    typedef void* HWAVEOUT;
    typedef UINT MMRESULT;

    #pragma pack(push, 1)
    typedef struct {
        WORD  wFormatTag;
        WORD  nChannels;
        DWORD nSamplesPerSec;
        DWORD nAvgBytesPerSec;
        WORD  nBlockAlign;
        WORD  wBitsPerSample;
        WORD  cbSize;
    } KR_WAVEFORMATEX;
    #pragma pack(pop)

    typedef struct kr_wavehdr_tag {
        char* lpData;
        DWORD dwBufferLength;
        DWORD dwBytesRecorded;
        DWORD_PTR dwUser;
        DWORD dwFlags;
        DWORD dwLoops;
        struct kr_wavehdr_tag* lpNext;
        DWORD_PTR reserved;
    } KR_WAVEHDR;

    UINT waveInGetNumDevs(void);
    UINT waveOutGetNumDevs(void);
    MMRESULT waveInOpen(HWAVEIN* phwi, UINT uDeviceID, const KR_WAVEFORMATEX* pwfx, DWORD_PTR dwCallback, DWORD_PTR dwInstance, DWORD fdwOpen);
    MMRESULT waveInPrepareHeader(HWAVEIN hwi, KR_WAVEHDR* pwh, UINT cbwh);
    MMRESULT waveInUnprepareHeader(HWAVEIN hwi, KR_WAVEHDR* pwh, UINT cbwh);
    MMRESULT waveInAddBuffer(HWAVEIN hwi, KR_WAVEHDR* pwh, UINT cbwh);
    MMRESULT waveInStart(HWAVEIN hwi);
    MMRESULT waveInStop(HWAVEIN hwi);
    MMRESULT waveInReset(HWAVEIN hwi);
    MMRESULT waveInClose(HWAVEIN hwi);

    MMRESULT waveOutOpen(HWAVEOUT* phwo, UINT uDeviceID, const KR_WAVEFORMATEX* pwfx, DWORD_PTR dwCallback, DWORD_PTR dwInstance, DWORD fdwOpen);
    MMRESULT waveOutPrepareHeader(HWAVEOUT hwo, KR_WAVEHDR* pwh, UINT cbwh);
    MMRESULT waveOutUnprepareHeader(HWAVEOUT hwo, KR_WAVEHDR* pwh, UINT cbwh);
    MMRESULT waveOutWrite(HWAVEOUT hwo, KR_WAVEHDR* pwh, UINT cbwh);
    MMRESULT waveOutReset(HWAVEOUT hwo);
    MMRESULT waveOutClose(HWAVEOUT hwo);
]]

local ok_mm, winmm = pcall(ffi.load, "winmm")
if not ok_mm then
    ch_out:push({ kind = "init", ok = false, err = "winmm_load_failed" })
    return
end

local SAMPLE_RATE = 16000
local FRAME_SAMPLES = 640   -- 40ms @ 16kHz
local FRAME_BYTES = FRAME_SAMPLES * 2
local WAVE_MAPPER = 0xFFFFFFFF
local WHDR_DONE = 1
local HDR_SIZE = ffi.sizeof("KR_WAVEHDR")

local in_devs = tonumber(winmm.waveInGetNumDevs()) or 0
local out_devs = tonumber(winmm.waveOutGetNumDevs()) or 0
ch_out:push({ kind = "init", ok = true, in_devs = in_devs, out_devs = out_devs })

-- Standard IMA-ADPCM lookup tables (0-based offsets + 1 for Lua)
local STEP_TABLE = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
}
local INDEX_TABLE = { -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 }

local enc_out = ffi.new("uint8_t[?]", 4 + FRAME_SAMPLES / 2)
local enc_hp_x = 0.0
local enc_hp_y = 0.0
local enc_step_index = 0

local function encode_adpcm_and_rms(pcm_ptr, n_samples)
    local sum_sq = 0.0
    local filtered = ffi.new("int16_t[?]", n_samples)
    local prev_x, prev_y = enc_hp_x, enc_hp_y
    for i = 0, n_samples - 1 do
        local x = tonumber(pcm_ptr[i])
        local y = x - prev_x + 0.992 * prev_y
        prev_x = x
        prev_y = y
        if y > 32767 then y = 32767 elseif y < -32768 then y = -32768 end
        local yi = math.floor(y + 0.5)
        filtered[i] = yi
        local nf = yi / 32768.0
        sum_sq = sum_sq + nf * nf
    end
    enc_hp_x, enc_hp_y = prev_x, prev_y
    local rms = math.sqrt(sum_sq / n_samples)

    -- Pack self-contained 4-byte header: int16 initial predictor + uint8 step_index + uint8 reserved
    local valpred = tonumber(filtered[0])
    local index = enc_step_index
    if index < 0 then index = 0 elseif index > 88 then index = 88 end
    local vp_u = valpred < 0 and (valpred + 65536) or valpred
    enc_out[0] = bit.band(vp_u, 0xFF)
    enc_out[1] = bit.band(bit.rshift(vp_u, 8), 0xFF)
    enc_out[2] = index
    enc_out[3] = 0

    local step = STEP_TABLE[index + 1]
    local out_pos = 4
    local low_nib = 0
    for i = 0, n_samples - 1 do
        local sample = tonumber(filtered[i])
        local diff = sample - valpred
        local sign = 0
        if diff < 0 then
            sign = 8
            diff = -diff
        end
        local delta = 0
        local vpdiff = bit.rshift(step, 3)
        if diff >= step then
            delta = 4
            diff = diff - step
            vpdiff = vpdiff + step
        end
        local half = bit.rshift(step, 1)
        if diff >= half then
            delta = bit.bor(delta, 2)
            diff = diff - half
            vpdiff = vpdiff + half
        end
        local quarter = bit.rshift(step, 2)
        if diff >= quarter then
            delta = bit.bor(delta, 1)
            vpdiff = vpdiff + quarter
        end
        if sign ~= 0 then
            valpred = valpred - vpdiff
        else
            valpred = valpred + vpdiff
        end
        if valpred > 32767 then valpred = 32767 elseif valpred < -32768 then valpred = -32768 end

        local code = bit.bor(delta, sign)
        index = index + INDEX_TABLE[code + 1]
        if index < 0 then index = 0 elseif index > 88 then index = 88 end
        step = STEP_TABLE[index + 1]

        if bit.band(i, 1) == 0 then
            low_nib = code
        else
            enc_out[out_pos] = bit.bor(low_nib, bit.lshift(code, 4))
            out_pos = out_pos + 1
        end
    end
    enc_step_index = index
    return ffi.string(enc_out, out_pos), rms
end

local function decode_adpcm_into(adpcm_str, out_pcm_ptr, gain)
    local len = #adpcm_str
    if len < 6 then return 0, 0 end
    local raw = ffi.cast("const uint8_t*", adpcm_str)
    local vp_u = raw[0] + raw[1] * 256
    local valpred = vp_u >= 32768 and (vp_u - 65536) or vp_u
    local index = raw[2]
    if index > 88 then index = 88 end
    local step = STEP_TABLE[index + 1]

    local n_bytes = len - 4
    local n_samples = math.min(FRAME_SAMPLES, n_bytes * 2)
    local sum_sq = 0.0
    local g = gain or 1.0
    for i = 0, n_samples - 1 do
        local byte_val = raw[4 + bit.rshift(i, 1)]
        local code = (bit.band(i, 1) == 0) and bit.band(byte_val, 0x0F) or bit.rshift(byte_val, 4)
        local sign = bit.band(code, 8)
        local delta = bit.band(code, 7)

        local vpdiff = bit.rshift(step, 3)
        if bit.band(delta, 4) ~= 0 then vpdiff = vpdiff + step end
        if bit.band(delta, 2) ~= 0 then vpdiff = vpdiff + bit.rshift(step, 1) end
        if bit.band(delta, 1) ~= 0 then vpdiff = vpdiff + bit.rshift(step, 2) end
        if sign ~= 0 then
            valpred = valpred - vpdiff
        else
            valpred = valpred + vpdiff
        end
        if valpred > 32767 then valpred = 32767 elseif valpred < -32768 then valpred = -32768 end

        index = index + INDEX_TABLE[code + 1]
        if index < 0 then index = 0 elseif index > 88 then index = 88 end
        step = STEP_TABLE[index + 1]

        local s = valpred * g
        if s > 32767 then s = 32767 elseif s < -32768 then s = -32768 end
        local si = math.floor(s + 0.5)
        out_pcm_ptr[i] = si
        local nf = si / 32768.0
        sum_sq = sum_sq + nf * nf
    end
    for i = n_samples, FRAME_SAMPLES - 1 do
        out_pcm_ptr[i] = 0
    end
    return n_samples, math.sqrt(sum_sq / math.max(1, n_samples))
end

local function make_wfx()
    local wfx = ffi.new("KR_WAVEFORMATEX")
    wfx.wFormatTag = 1
    wfx.nChannels = 1
    wfx.nSamplesPerSec = SAMPLE_RATE
    wfx.wBitsPerSample = 16
    wfx.nBlockAlign = 2
    wfx.nAvgBytesPerSec = SAMPLE_RATE * 2
    wfx.cbSize = 0
    return wfx
end

-- Capture device state
local NUM_IN = 4
local hwi = nil
local in_hdrs = ffi.new("KR_WAVEHDR[?]", NUM_IN)
local in_bufs = {}
for i = 0, NUM_IN - 1 do
    in_bufs[i] = ffi.new("int16_t[?]", FRAME_SAMPLES)
end

local function close_mic()
    if not hwi then return end
    winmm.waveInStop(hwi)
    winmm.waveInReset(hwi)
    for i = 0, NUM_IN - 1 do
        winmm.waveInUnprepareHeader(hwi, in_hdrs + i, HDR_SIZE)
    end
    winmm.waveInClose(hwi)
    hwi = nil
    ch_out:push({ kind = "status", mic_open = false })
end

local function open_mic()
    if hwi then return true end
    if in_devs <= 0 then
        in_devs = tonumber(winmm.waveInGetNumDevs()) or 0
        if in_devs <= 0 then
            ch_out:push({ kind = "status", mic_open = false, err = "no_mic" })
            return false
        end
    end
    local wfx = make_wfx()
    local phwi = ffi.new("HWAVEIN[1]")
    local r = winmm.waveInOpen(phwi, WAVE_MAPPER, wfx, 0, 0, 0)
    if r ~= 0 then
        ch_out:push({ kind = "status", mic_open = false, err = "waveInOpen_" .. tostring(tonumber(r)) })
        return false
    end
    hwi = phwi[0]
    for i = 0, NUM_IN - 1 do
        ffi.fill(in_hdrs + i, HDR_SIZE)
        in_hdrs[i].lpData = ffi.cast("char*", in_bufs[i])
        in_hdrs[i].dwBufferLength = FRAME_BYTES
        in_hdrs[i].dwFlags = 0
        winmm.waveInPrepareHeader(hwi, in_hdrs + i, HDR_SIZE)
        winmm.waveInAddBuffer(hwi, in_hdrs + i, HDR_SIZE)
    end
    local sr = winmm.waveInStart(hwi)
    if sr ~= 0 then
        close_mic()
        ch_out:push({ kind = "status", mic_open = false, err = "waveInStart_" .. tostring(tonumber(sr)) })
        return false
    end
    ch_out:push({ kind = "status", mic_open = true })
    return true
end

-- Playback device state (8-slot ring buffer + smart 2-frame pre-roll jitter buffer)
local NUM_OUT = 8
local hwo = nil
local out_hdrs = ffi.new("KR_WAVEHDR[?]", NUM_OUT)
local out_bufs = {}
local out_in_use = {}
for i = 0, NUM_OUT - 1 do
    out_bufs[i] = ffi.new("int16_t[?]", FRAME_SAMPLES)
    out_in_use[i] = false
end
local play_q = {}
local play_q_first_ts = 0

local function close_spk()
    if not hwo then return end
    winmm.waveOutReset(hwo)
    for i = 0, NUM_OUT - 1 do
        if out_in_use[i] then
            winmm.waveOutUnprepareHeader(hwo, out_hdrs + i, HDR_SIZE)
            out_in_use[i] = false
        end
    end
    winmm.waveOutClose(hwo)
    hwo = nil
    play_q = {}
    ch_out:push({ kind = "status", spk_open = false })
end

local function open_spk()
    if hwo then return true end
    if out_devs <= 0 then
        out_devs = tonumber(winmm.waveOutGetNumDevs()) or 0
        if out_devs <= 0 then
            return false
        end
    end
    local wfx = make_wfx()
    local phwo = ffi.new("HWAVEOUT[1]")
    local r = winmm.waveOutOpen(phwo, WAVE_MAPPER, wfx, 0, 0, 0)
    if r ~= 0 then
        ch_out:push({ kind = "status", spk_open = false, err = "waveOutOpen_" .. tostring(tonumber(r)) })
        return false
    end
    hwo = phwo[0]
    for i = 0, NUM_OUT - 1 do
        out_in_use[i] = false
    end
    ch_out:push({ kind = "status", spk_open = true })
    return true
end

-- Runtime control state
local want_mic = false
local want_spk = false
local mode = "ptt"
local ptt_held = false
local peer_muted = false
local peer_volume = 1.0
local vad_threshold = 0.018
local self_test = false
local vad_hangover = 0
local ptt_hangover = 0
local running = true

local function now_sec()
    return (ok_timer and ltimer and ltimer.getTime) and ltimer.getTime() or os.clock()
end

while running do
    -- 1. Drain control & incoming audio commands
    while true do
        local cmd = ch_cmd:pop()
        if not cmd then break end
        if cmd.kind == "quit" then
            running = false
            break
        elseif cmd.kind == "cfg" then
            want_mic = (cmd.want_mic == true)
            want_spk = (cmd.want_spk == true)
            mode = cmd.mode or mode
            ptt_held = (cmd.ptt_held == true)
            peer_muted = (cmd.peer_muted == true)
            peer_volume = tonumber(cmd.peer_volume) or 1.0
            vad_threshold = tonumber(cmd.vad_threshold) or 0.018
            self_test = (cmd.self_test == true)
        elseif cmd.kind == "rx" and type(cmd.data) == "string" then
            if not peer_muted and (want_spk or self_test) then
                if #play_q >= 8 then
                    table.remove(play_q, 1)
                end
                if #play_q == 0 then
                    play_q_first_ts = now_sec()
                end
                play_q[#play_q + 1] = cmd.data
            end
        end
    end
    if not running then break end

    -- 2. Open / close audio devices lazily
    if want_mic then
        if not hwi then open_mic() end
    else
        if hwi then close_mic() end
    end

    if (want_spk or self_test) and (#play_q > 0 or hwo) then
        if not hwo then open_spk() end
    elseif not want_spk and not self_test and hwo then
        close_spk()
    end

    -- 3. Poll completed capture buffers (40ms each)
    if hwi then
        for i = 0, NUM_IN - 1 do
            if bit.band(in_hdrs[i].dwFlags, WHDR_DONE) ~= 0 then
                local bytes = tonumber(in_hdrs[i].dwBytesRecorded) or 0
                if bytes >= FRAME_BYTES then
                    local adpcm, rms = encode_adpcm_and_rms(in_bufs[i], FRAME_SAMPLES)
                    local send_tx = false
                    if mode == "vad" then
                        if rms >= vad_threshold then
                            vad_hangover = 8 -- 320ms smooth tail
                        end
                        if vad_hangover > 0 then
                            send_tx = true
                            vad_hangover = vad_hangover - 1
                        end
                    elseif mode == "ptt" then
                        if ptt_held then
                            ptt_hangover = 4 -- 160ms release tail
                        end
                        if ptt_hangover > 0 then
                            send_tx = true
                            ptt_hangover = ptt_hangover - 1
                        end
                    end

                    if send_tx then
                        ch_out:push({ kind = "tx", data = adpcm, level = rms })
                        if self_test then
                            if #play_q >= 6 then table.remove(play_q, 1) end
                            if #play_q == 0 then play_q_first_ts = now_sec() end
                            play_q[#play_q + 1] = adpcm
                        end
                    else
                        ch_out:push({ kind = "lvl", level = rms, talking = false })
                    end
                end
                in_hdrs[i].dwFlags = bit.band(in_hdrs[i].dwFlags, bit.bnot(WHDR_DONE))
                in_hdrs[i].dwBytesRecorded = 0
                winmm.waveInAddBuffer(hwi, in_hdrs + i, HDR_SIZE)
            end
        end
    end

    -- 4. Reclaim finished playback buffers & submit queued frames with 2-frame jitter pre-roll
    if hwo then
        local active_slots = 0
        for i = 0, NUM_OUT - 1 do
            if out_in_use[i] then
                if bit.band(out_hdrs[i].dwFlags, WHDR_DONE) ~= 0 then
                    winmm.waveOutUnprepareHeader(hwo, out_hdrs + i, HDR_SIZE)
                    out_in_use[i] = false
                else
                    active_slots = active_slots + 1
                end
            end
        end

        local can_start = (active_slots > 0) or (#play_q >= 2) or (#play_q >= 1 and (now_sec() - play_q_first_ts) >= 0.055)
        if can_start then
            while #play_q > 0 do
                local free_i = nil
                for i = 0, NUM_OUT - 1 do
                    if not out_in_use[i] then
                        free_i = i
                        break
                    end
                end
                if not free_i then break end
                local pkt = table.remove(play_q, 1)
                local ns = decode_adpcm_into(pkt, out_bufs[free_i], peer_volume)
                if ns > 0 then
                    ffi.fill(out_hdrs + free_i, HDR_SIZE)
                    out_hdrs[free_i].lpData = ffi.cast("char*", out_bufs[free_i])
                    out_hdrs[free_i].dwBufferLength = ns * 2
                    out_hdrs[free_i].dwFlags = 0
                    winmm.waveOutPrepareHeader(hwo, out_hdrs + free_i, HDR_SIZE)
                    winmm.waveOutWrite(hwo, out_hdrs + free_i, HDR_SIZE)
                    out_in_use[free_i] = true
                    active_slots = active_slots + 1
                end
            end
        end
    end

    if ok_timer and ltimer and ltimer.sleep then
        ltimer.sleep(0.008)
    end
end

close_mic()
close_spk()
]===]

local function get_now()
    return (love and love.timer and love.timer.getTime) and love.timer.getTime() or os.clock()
end

function voice:log(fmt, ...)
    if self.boot and self.boot.log then
        self.boot:log("[VOICE] " .. fmt, ...)
    end
end

function voice:init(boot, transport)
    self.boot = boot
    self.transport = transport

    -- Keep automated M1/M2/smoke tests headless & deterministic
    if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") or os.getenv("KR_MP_SMOKE_TEST") == "1" then
        self.disabled_for_test = true
        self.supported = false
        return
    end

    if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
        self.supported = false
        return
    end

    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi or ffi.os ~= "Windows" then
        self.supported = false
        return
    end

    self.ch_cmd = love.thread.getChannel("kr_mp_voice_cmd")
    self.ch_out = love.thread.getChannel("kr_mp_voice_out")
    self.ch_cmd:clear()
    self.ch_out:clear()

    local ok_th, th = pcall(love.thread.newThread, WORKER_CODE)
    if not ok_th or not th then
        self:log("Failed to spawn audio thread: %s", tostring(th))
        self.supported = false
        return
    end

    self.thread = th
    self.supported = true
    th:start("kr_mp_voice_cmd", "kr_mp_voice_out")
    self:log("Voice chat worker thread started (16kHz IMA-ADPCM, mode=%s)", tostring(self.mode))
end

function voice:shutdown()
    if self.ch_cmd then
        self.ch_cmd:push({ kind = "quit" })
    end
    if self.thread and self.thread.wait then
        pcall(self.thread.wait, self.thread)
    end
    self.thread = nil
    self.mic_open = false
    self.spk_open = false
end

function voice:set_mode(new_mode)
    if new_mode ~= "ptt" and new_mode ~= "vad" and new_mode ~= "mute" then
        new_mode = "ptt"
    end
    self.mode = new_mode
    if new_mode == "mute" then
        self.local_talking = false
        self.local_level = 0
        self.self_test = false
    end
    self._last_cfg_sig = nil
    return self.mode
end

function voice:cycle_mode()
    if self.mode == "ptt" then
        return self:set_mode("vad")
    elseif self.mode == "vad" then
        return self:set_mode("mute")
    else
        return self:set_mode("ptt")
    end
end

function voice:toggle_mute()
    if self.mode == "mute" then
        return self:set_mode(self._prev_unmuted_mode or "ptt")
    else
        self._prev_unmuted_mode = self.mode
        return self:set_mode("mute")
    end
end

function voice:toggle_peer_mute()
    self.peer_muted = not self.peer_muted
    if self.peer_muted then
        self.peer_talking = false
        self.peer_level = 0
    end
    self._last_cfg_sig = nil
    return self.peer_muted
end

function voice:toggle_self_test()
    if self.mode == "mute" then
        self:set_mode("vad")
    end
    self.self_test = not self.self_test
    self._last_cfg_sig = nil
    return self.self_test
end

function voice:get_mode_short()
    if not self.supported then return "麦:无" end
    if self.mode == "vad" then return "自由麦" end
    if self.mode == "ptt" then return "按V麦" end
    return "已闭麦"
end

function voice:get_mode_lobby_label()
    if not self.supported then return "连麦:不可用" end
    if self.mode == "vad" then return "连麦:自由麦" end
    if self.mode == "ptt" then return "连麦:按V说话" end
    return "连麦:已闭麦"
end

function voice:get_mode_toast()
    if self.mode == "vad" then
        return "连麦已切至【自由麦】：说话自动收音（建议戴耳机防回声，按 M 一键闭麦）"
    elseif self.mode == "ptt" then
        return "连麦已切至【按键说话】：按住键盘 V 键讲话（松开即静，零环境底噪）"
    else
        return "连麦已【闭麦】：你暂时不会发声，但仍可听见队友声音（按 M 恢复开麦）"
    end
end

function voice:on_voice_message(msg)
    if not self.supported or not msg or type(msg.d) ~= "string" then
        return
    end
    local now = get_now()
    local lvl = (tonumber(msg.l) or 25) / 100.0
    if lvl > 1 then lvl = 1 elseif lvl < 0 then lvl = 0 end
    self.peer_level = math.max(self.peer_level * 0.65, math.min(1.0, lvl * 2.4))
    self.peer_talking = true
    self.peer_talk_until = now + 0.45
    self.rx_count = self.rx_count + 1

    if self.peer_muted or not self.ch_cmd then
        return
    end
    local bin = b64_decode(msg.d)
    if bin and #bin >= 6 then
        self.ch_cmd:push({ kind = "rx", data = bin })
    end
end

function voice:update(dt, lobby, coop)
    local now = get_now()

    -- Decay speaking visual indicators smoothly
    if now > self.local_talk_until then
        self.local_talking = false
        self.local_level = math.max(0, self.local_level - (dt or 0.016) * 2.8)
    end
    if now > self.peer_talk_until then
        self.peer_talking = false
        self.peer_level = math.max(0, self.peer_level - (dt or 0.016) * 2.8)
    end

    if not self.supported or not self.ch_cmd or not self.ch_out then
        return
    end

    local in_room = (lobby ~= nil and (lobby.view == "room" or (coop ~= nil and coop:is_active())))
    local peer_ok = (lobby ~= nil and lobby.peer_connected == true) or (coop ~= nil and coop:is_active())
    local is_online = self.transport and self.transport:is_online()
    local srv_ok = (not is_online) or (lobby == nil) or (lobby.server_voice_ok ~= false)
    self.active_room = in_room
    self.peer_connected = peer_ok
    self.online_server_ok = srv_ok

    -- Hold-to-talk (V key) — ignored while typing inside a lobby text input box!
    local typing = (lobby ~= nil and lobby.open == true and lobby.focused_field ~= nil)
    local v_down = (not typing) and love and love.keyboard and love.keyboard.isDown and love.keyboard.isDown("v") or false
    self.ptt_held = v_down

    -- Only open hardware mic when inside a room (or self-testing) and not muted
    local want_mic = (in_room or self.self_test) and (self.mode ~= "mute")
    local want_spk = (in_room or self.self_test) and (not self.peer_muted)
    if not in_room and self.self_test then
        self.self_test = false
    end

    local sig = string.format("%s|%s|%s|%s|%s|%.2f|%s",
        tostring(want_mic), tostring(want_spk), tostring(self.mode),
        tostring(self.ptt_held), tostring(self.peer_muted), self.peer_volume, tostring(self.self_test))
    if sig ~= self._last_cfg_sig then
        self._last_cfg_sig = sig
        self.ch_cmd:push({
            kind = "cfg",
            want_mic = want_mic,
            want_spk = want_spk,
            mode = self.mode,
            ptt_held = self.ptt_held,
            peer_muted = self.peer_muted,
            peer_volume = self.peer_volume,
            vad_threshold = self.vad_threshold,
            self_test = self.self_test,
        })
    end

    -- Drain worker outputs (non-blocking)
    local sent_this_tick = 0
    while true do
        local ev = self.ch_out:pop()
        if not ev then break end
        if ev.kind == "init" then
            if not ev.ok then
                self.supported = false
                self.last_err = ev.err
                self:log("Audio worker unavailable: %s", tostring(ev.err))
            else
                self.in_devs = tonumber(ev.in_devs) or 0
                self.out_devs = tonumber(ev.out_devs) or 0
                self:log("WinMM ready: mic_devs=%d spk_devs=%d", self.in_devs, self.out_devs)
            end
        elseif ev.kind == "status" then
            if ev.mic_open ~= nil then self.mic_open = ev.mic_open end
            if ev.spk_open ~= nil then self.spk_open = ev.spk_open end
            if ev.err then
                self.last_err = ev.err
                self:log("Audio device status err=%s", tostring(ev.err))
            end
        elseif ev.kind == "lvl" then
            local norm = math.min(1.0, (tonumber(ev.level) or 0) * 5.0)
            self.local_level = self.local_level * 0.55 + norm * 0.45
        elseif ev.kind == "tx" and type(ev.data) == "string" then
            local norm = math.min(1.0, (tonumber(ev.level) or 0) * 5.0)
            self.local_level = math.max(self.local_level * 0.5, norm)
            self.local_talking = true
            self.local_talk_until = now + 0.35

            -- Transmit to peer if connected & transport queue is uncongested (never starve 60Hz lockstep!)
            if peer_ok and srv_ok and self.transport and self.transport:is_connected() and sent_this_tick < 3 then
                local qlen = self.transport.get_send_queue_len and self.transport:get_send_queue_len() or 0
                if qlen < 8 then
                    local lvl_int = math.min(100, math.max(1, math.floor(norm * 100 + 0.5)))
                    self.transport:send({
                        t = "VOICE",
                        d = b64_encode(ev.data),
                        l = lvl_int,
                    })
                    self.tx_count = self.tx_count + 1
                    sent_this_tick = sent_this_tick + 1
                end
            end
        end
    end
end

-- Returns (is_talking, level_0_to_1) for a given seat pid (1 or 2)
function voice:get_seat_state(pid, local_pid)
    if pid == local_pid then
        return self.local_talking, self.local_level
    else
        return self.peer_talking, self.peer_level
    end
end

return voice

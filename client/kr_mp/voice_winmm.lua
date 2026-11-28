-- KR-MP Isolated Windows WinMM Audio Worker Thread Script
-- Runs completely outside the 60Hz deterministic game loop and delegates IMA-ADPCM to shared kr_mp.voice_codec.
local M = {}

M.WORKER_CODE = [===[
local ch_cmd_name, ch_out_name, pkg_path = ...
if type(pkg_path) == "string" and #pkg_path > 0 then
    package.path = pkg_path
end
local ch_cmd = love.thread.getChannel(ch_cmd_name)
local ch_out = love.thread.getChannel(ch_out_name)

local ok_timer, ltimer = pcall(require, "love.timer")
local ok_ffi, ffi = pcall(require, "ffi")
local ok_bit, bit = pcall(require, "bit")
local ok_codec, codec = pcall(require, "kr_mp.voice_codec")
if not ok_ffi or not ok_bit or not ok_codec or not codec or ffi.os ~= "Windows" then
    ch_out:push({ kind = "init", ok = false, err = "non_windows_or_no_ffi_or_codec" })
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

local SAMPLE_RATE = codec.SAMPLE_RATE
local FRAME_SAMPLES = codec.FRAME_SAMPLES
local FRAME_BYTES = FRAME_SAMPLES * 2
local WAVE_MAPPER = 0xFFFFFFFF
local WHDR_DONE = 1
local HDR_SIZE = ffi.sizeof("KR_WAVEHDR")

local in_devs = tonumber(winmm.waveInGetNumDevs()) or 0
local out_devs = tonumber(winmm.waveOutGetNumDevs()) or 0
ch_out:push({ kind = "init", ok = true, in_devs = in_devs, out_devs = out_devs })

local enc_out = ffi.new("uint8_t[?]", 4 + FRAME_SAMPLES / 2)
local enc_filt = ffi.new("int16_t[?]", FRAME_SAMPLES)
local enc_state = { hp_x = 0.0, hp_y = 0.0, step_idx = 0 }

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
        if out_devs <= 0 then return false end
    end
    local wfx = make_wfx()
    local phwo = ffi.new("HWAVEOUT[1]")
    local r = winmm.waveOutOpen(phwo, WAVE_MAPPER, wfx, 0, 0, 0)
    if r ~= 0 then
        ch_out:push({ kind = "status", spk_open = false, err = "waveOutOpen_" .. tostring(tonumber(r)) })
        return false
    end
    hwo = phwo[0]
    for i = 0, NUM_OUT - 1 do out_in_use[i] = false end
    ch_out:push({ kind = "status", spk_open = true })
    return true
end

local want_mic, want_spk = false, false
local mode, ptt_held = "ptt", false
local mic_gain, peer_muted, peer_volume = 1.0, false, 1.0
local vad_threshold, self_test = 0.018, false
local vad_hangover, ptt_hangover = 0, 0
local running = true

local function now_sec()
    return (ok_timer and ltimer and ltimer.getTime) and ltimer.getTime() or os.clock()
end

while running do
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
            mic_gain = tonumber(cmd.mic_gain) or 1.0
            peer_muted = (cmd.peer_muted == true)
            peer_volume = tonumber(cmd.peer_volume) or 1.0
            vad_threshold = tonumber(cmd.vad_threshold) or 0.018
            self_test = (cmd.self_test == true)
        elseif cmd.kind == "rx" and type(cmd.data) == "string" then
            if not peer_muted and (want_spk or self_test) then
                if #play_q >= 8 then table.remove(play_q, 1) end
                if #play_q == 0 then play_q_first_ts = now_sec() end
                play_q[#play_q + 1] = cmd.data
            end
        end
    end
    if not running then break end

    if want_mic then
        if not hwi then open_mic() end
    elseif hwi then
        close_mic()
    end

    if (want_spk or self_test) and (#play_q > 0 or hwo) then
        if not hwo then open_spk() end
    elseif not want_spk and not self_test and hwo then
        close_spk()
    end

    if hwi then
        for i = 0, NUM_IN - 1 do
            if bit.band(in_hdrs[i].dwFlags, WHDR_DONE) ~= 0 then
                local bytes = tonumber(in_hdrs[i].dwBytesRecorded) or 0
                if bytes >= FRAME_BYTES then
                    local adpcm, rms = codec.encode_pcm_ptr(enc_state, ffi, bit, in_bufs[i], FRAME_SAMPLES, mic_gain, enc_out, enc_filt)
                    local send_tx = false
                    if mode == "vad" then
                        if rms >= vad_threshold then vad_hangover = 8 end
                        if vad_hangover > 0 then send_tx = true; vad_hangover = vad_hangover - 1 end
                    elseif mode == "ptt" then
                        if ptt_held then ptt_hangover = 4 end
                        if ptt_hangover > 0 then send_tx = true; ptt_hangover = ptt_hangover - 1 end
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
                    if not out_in_use[i] then free_i = i; break end
                end
                if not free_i then break end
                local pkt = table.remove(play_q, 1)
                local ns = codec.decode_to_pcm_ptr(ffi, bit, pkt, out_bufs[free_i], peer_volume)
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

return M

-- KR-MP Built-in Real-Time Voice Chat Engine (Zero-Dependency LuaJIT FFI + Windows WinMM + love.thread)
-- Features:
--   - 16kHz Mono 16-bit PCM captured & played inside an isolated love.thread (0ms impact on 60Hz game loop / PRNG)
--   - Self-contained 40ms IMA-ADPCM frames (~8.1 KB/s binary, ~10.8 KB/s base64 while speaking; 0 KB/s when silent)
--   - 1st-order DC high-pass filter + smart VAD (noise gate + 320ms hangover) + Push-to-Talk (V) + Quick Mute (M)
--   - Jitter-buffered waveOut playback + live animated 5-bar spectrum levels for 1P/2P livestream overlays
--   - Graceful degradation on headless / mic-less machines (listen-only works even with 0 microphones!)
local proto = require("kr_mp.proto")
local codec = require("kr_mp.voice_codec")
local winmm_worker = require("kr_mp.voice_winmm")

local voice = {
    boot = nil,
    transport = nil,

    supported = false,
    backend = nil,         -- "winmm" | "love_audio"
    disabled_for_test = false,
    thread = nil,
    ch_cmd = nil,
    ch_out = nil,

    -- Android / LÖVE 11+ native audio state (main-thread non-blocking, <0.1ms/frame)
    _rec_dev = nil,
    _qsrc = nil,
    _rec_rate = 16000,
    _rec_ch = 1,
    _rec_pcm = {},         -- accumulated 16kHz signed int16 samples
    _rec_hp_x = 0.0,
    _rec_hp_y = 0.0,
    _rec_step_idx = 0,
    _rec_hang_until = 0,
    _rec_retry_at = 0,
    _rec_perm_warned = false,
    _dec_buf = {},

    -- User settings (persisted in kr_mp_prefs.json)
    mode = "ptt",          -- "ptt" (按V说话 / 安卓按住讲) | "vad" (自由麦) | "mute" (闭麦)
    mic_gain = 1.0,        -- 0.4 .. 2.0 (40% .. 200% local mic volume gain)
    peer_muted = false,    -- mute incoming roommate audio
    peer_volume = 1.0,     -- 0.0 .. 1.8 (0% .. 180% peer playback volume)
    indicator_style = "compact", -- "compact" (极简微标) | "off" (关闭) | "card" (醒目大卡)
    vad_threshold = 0.018, -- normalized RMS threshold for free-mic VAD
    self_test = false,     -- local loopback test (hear yourself in lobby)

    -- Live runtime status
    _tx_pack_buf = nil,    -- pending 40ms ADPCM frame for SakuraFrp 80ms low-PPS packing
    _tx_pack_lvl = 0,
    _tx_pack_ts = 0,
    active_room = false,
    peer_connected = false,
    online_server_ok = true,
    ptt_held = false,
    touch_ptt_held = false,
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

local b64_encode = codec.b64_encode
local b64_decode = codec.b64_decode

-- Exported for unit / loopback verification
voice._b64_encode = b64_encode
voice._b64_decode = b64_decode

local function get_now()
    return (love and love.timer and love.timer.getTime) and love.timer.getTime() or os.clock()
end

local LA_FRAME_SAMPLES = codec.FRAME_SAMPLES

local function la_encode_frame(self, pcm_arr)
    local st = { hp_x = self._rec_hp_x or 0.0, hp_y = self._rec_hp_y or 0.0, step_idx = self._rec_step_idx or 0 }
    local bin, rms = codec.encode_pcm_array(st, pcm_arr, self.mic_gain or 1.0)
    self._rec_hp_x, self._rec_hp_y, self._rec_step_idx = st.hp_x, st.hp_y, st.step_idx
    return bin, rms
end

local function la_play_adpcm(self, bin)
    if not self._qsrc or not love or not love.sound or not love.sound.newSoundData then
        return
    end
    local ok_free, free_n = pcall(self._qsrc.getFreeBufferCount, self._qsrc)
    if not ok_free or not free_n or free_n <= 0 then
        return
    end
    if #bin < 6 then return end
    local ok_sd, sd = pcall(love.sound.newSoundData, LA_FRAME_SAMPLES, codec.SAMPLE_RATE, 16, 1)
    if not ok_sd or not sd then return end
    codec.decode_to_sounddata(bin, self.peer_volume or 1.0, sd)
    pcall(self._qsrc.queue, self._qsrc, sd)
    if self._qsrc.isPlaying and not self._qsrc:isPlaying() then
        pcall(self._qsrc.play, self._qsrc)
    end
    if sd.release then pcall(sd.release, sd) end
end

local function la_close_mic(self)
    if self._rec_dev then
        pcall(self._rec_dev.stop, self._rec_dev)
        self._rec_dev = nil
    end
    self._rec_pcm = {}
    self.mic_open = false
end

local function la_close_spk(self)
    if self._qsrc then
        pcall(self._qsrc.stop, self._qsrc)
        if self._qsrc.release then pcall(self._qsrc.release, self._qsrc) end
        self._qsrc = nil
    end
    self.spk_open = false
end

local function la_open_spk(self)
    if self._qsrc then return true end
    if not love or not love.audio or not love.audio.newQueueableSource then return false end
    local ok, qs = pcall(love.audio.newQueueableSource, 16000, 16, 1, 8)
    if ok and qs then
        self._qsrc = qs
        self.spk_open = true
        self.out_devs = 1
        return true
    end
    self.last_err = "qsrc_failed:" .. tostring(qs)
    return false
end

local function la_open_mic(self, now)
    if self._rec_dev then
        local ok_r, rec = pcall(self._rec_dev.isRecording, self._rec_dev)
        if ok_r and rec then return true end
        la_close_mic(self)
    end
    if now < (self._rec_retry_at or 0) then return false end
    self._rec_retry_at = now + 2.5
    if not love or not love.audio or not love.audio.getRecordingDevices then return false end
    local ok_d, devs = pcall(love.audio.getRecordingDevices)
    if not ok_d or type(devs) ~= "table" or #devs == 0 then
        self.in_devs = 0
        self.last_err = "no_recording_devices"
        return false
    end
    self.in_devs = #devs
    local dev = devs[1]
    -- Try 16kHz native first; fall back to 48kHz / 44.1kHz (Android Oboe/OpenAL hardware native rates)
    local try_rates = { { 3200, 16000 }, { 8192, 48000 }, { 8192, 44100 } }
    local started = false
    for _, cfg in ipairs(try_rates) do
        local ok_s, res = pcall(dev.start, dev, cfg[1], cfg[2], 16, 1)
        if ok_s and res then
            started = true
            break
        end
    end
    if not started then
        self.last_err = "mic_start_failed_or_permission_denied"
        if not self._rec_perm_warned then
            self._rec_perm_warned = true
            self:log("Android RecordingDevice:start failed (check Android Microphone permission)")
        end
        return false
    end
    self._rec_dev = dev
    self._rec_rate = (dev.getSampleRate and dev:getSampleRate()) or 16000
    self._rec_ch = (dev.getChannelCount and dev:getChannelCount()) or 1
    self._rec_pcm = {}
    self._rec_hp_x = 0.0
    self._rec_hp_y = 0.0
    self._rec_step_idx = 0
    self.mic_open = true
    self.last_err = nil
    self:log("LÖVE Audio mic opened: rate=%d ch=%d devs=%d", self._rec_rate, self._rec_ch, self.in_devs)
    return true
end

function voice:log(fmt, ...)
    if self.boot and self.boot.log then
        self.boot:log("[VOICE] " .. fmt, ...)
    end
end

function voice:set_touch_ptt(down)
    self.touch_ptt_held = (down == true)
end

function voice:init(boot, transport)
    self.boot = boot
    self.transport = transport

    -- Default hands-free smart VAD on Android touchscreens (no physical V key!)
    if proto.is_android() then
        self.mode = "vad"
    end

    -- Keep automated M1/M2/smoke tests headless & deterministic
    if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") or os.getenv("KR_MP_AUTO_SAKURA") or os.getenv("KR_MP_SMOKE_TEST") == "1" then
        self.disabled_for_test = true
        self.supported = false
        return
    end

    -- Backend 1: Windows WinMM isolated thread (zero-latency PC desktop)
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and ffi and ffi.os == "Windows"
        and love and love.thread and love.thread.newThread and love.thread.getChannel then
        self.ch_cmd = love.thread.getChannel("kr_mp_voice_cmd")
        self.ch_out = love.thread.getChannel("kr_mp_voice_out")
        self.ch_cmd:clear()
        self.ch_out:clear()

        local ok_th, th = pcall(love.thread.newThread, winmm_worker.WORKER_CODE)
        if ok_th and th then
            self.thread = th
            self.backend = "winmm"
            self.supported = true
            th:start("kr_mp_voice_cmd", "kr_mp_voice_out", package.path)
            self:log("Voice chat worker thread started (WinMM 16kHz IMA-ADPCM, mode=%s)", tostring(self.mode))
            return
        else
            self:log("Failed to spawn WinMM audio thread: %s", tostring(th))
        end
    end

    -- Backend 2: Cross-platform LÖVE 11/12 native audio (Android Oboe/OpenAL RecordingDevice + QueueableSource)
    if love and love.audio and love.audio.newQueueableSource and love.sound and love.sound.newSoundData then
        self.backend = "love_audio"
        self.supported = true
        local ok_d, devs = pcall(love.audio.getRecordingDevices)
        self.in_devs = (ok_d and type(devs) == "table") and #devs or 0
        self.out_devs = 1
        self:log("Voice chat initialized (LÖVE Audio 16kHz IMA-ADPCM, mic_devs=%d, mode=%s)",
            self.in_devs, tostring(self.mode))
        return
    end

    self.supported = false
end

function voice:shutdown()
    if self.backend == "love_audio" then
        la_close_mic(self)
        la_close_spk(self)
        return
    end
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
    elseif (self.peer_volume or 0) <= 0.01 then
        self.peer_volume = 1.0
    end
    self._last_cfg_sig = nil
    return self.peer_muted
end

function voice:set_mic_gain(val)
    local v = tonumber(val) or 1.0
    if v < 0.4 then v = 0.4 elseif v > 2.0 then v = 2.0 end
    self.mic_gain = math.floor(v * 20 + 0.5) / 20
    self._last_cfg_sig = nil
    return self.mic_gain
end

function voice:step_mic_gain(delta)
    return self:set_mic_gain((self.mic_gain or 1.0) + (tonumber(delta) or 0))
end

function voice:set_peer_volume(val)
    local v = tonumber(val) or 1.0
    if v < 0.0 then v = 0.0 elseif v > 1.8 then v = 1.8 end
    self.peer_volume = math.floor(v * 20 + 0.5) / 20
    if self.peer_volume <= 0.01 then
        self.peer_volume = 0.0
        self.peer_muted = true
        self.peer_talking = false
        self.peer_level = 0
    else
        self.peer_muted = false
    end
    self._last_cfg_sig = nil
    return self.peer_volume
end

function voice:step_peer_volume(delta)
    local base = self.peer_muted and 0.0 or (self.peer_volume or 1.0)
    return self:set_peer_volume(base + (tonumber(delta) or 0))
end

function voice:set_indicator_style(style)
    if style ~= "compact" and style ~= "off" and style ~= "card" then
        style = "compact"
    end
    self.indicator_style = style
    return self.indicator_style
end

function voice:cycle_indicator_style()
    if self.indicator_style == "compact" then
        return self:set_indicator_style("off")
    elseif self.indicator_style == "off" then
        return self:set_indicator_style("card")
    else
        return self:set_indicator_style("compact")
    end
end

function voice:get_indicator_style_label()
    if self.indicator_style == "off" then return "关闭" end
    if self.indicator_style == "card" then return "醒目" end
    return "极简"
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
    if self.mode == "ptt" then return proto.is_android() and "按住讲" or "按V麦" end
    return "已闭麦"
end

function voice:get_mode_lobby_label()
    if not self.supported then return "连麦:不可用" end
    if self.mode == "vad" then return "连麦:自由麦" end
    if self.mode == "ptt" then return proto.is_android() and "连麦:按住讲" or "连麦:按V说话" end
    return "连麦:已闭麦"
end

function voice:get_mode_toast()
    local mob = proto.is_android()
    if self.mode == "vad" then
        return mob
            and "连麦已切至【自由麦】：说话自动收音（建议戴耳机防回声，点按钮可切模式或闭麦）"
            or "连麦已切至【自由麦】：说话自动收音（建议戴耳机防回声，按 M 一键闭麦）"
    elseif self.mode == "ptt" then
        return mob
            and "连麦已切至【按住说话】：对局中按住顶部下方的「按住说话」绿色按钮讲话！"
            or "连麦已切至【按键说话】：按住键盘 V 键讲话（松开即静，零环境底噪）"
    else
        return mob
            and "连麦已【闭麦】：你暂时不会发声，但仍可听见队友声音"
            or "连麦已【闭麦】：你暂时不会发声，但仍可听见队友声音（按 M 恢复开麦）"
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

    if self.peer_muted then
        return
    end
    local bin = b64_decode(msg.d)
    if bin and #bin >= 6 then
        if self.backend == "love_audio" then
            if la_open_spk(self) then
                la_play_adpcm(self, bin)
            end
        elseif self.ch_cmd then
            self.ch_cmd:push({ kind = "rx", data = bin })
        end
    end
    -- Optional 2nd packed 40ms frame (80ms SakuraFrp Low-PPS mode, 100% backward compatible)
    if type(msg.d2) == "string" and #msg.d2 >= 8 then
        local bin2 = b64_decode(msg.d2)
        if bin2 and #bin2 >= 6 then
            if self.backend == "love_audio" then
                if la_open_spk(self) then
                    la_play_adpcm(self, bin2)
                end
            elseif self.ch_cmd then
                self.ch_cmd:push({ kind = "rx", data = bin2 })
            end
        end
    end
end

-- Automatically enable 2-frame (80ms) low-PPS packing on non-LAN / SakuraFrp connections (cuts voice PPS in half!)
function voice:should_use_low_pps()
    if not self.transport then return false end
    if self.transport.is_online and self.transport:is_online() then
        return true
    end
    local rtt = self.transport.get_rtt_ms and self.transport:get_rtt_ms() or 0
    if rtt >= 18 then return true end
    local lan = self.transport.lan_backend
    if not lan then return false end
    local ip = tostring(lan.peer_ip or "")
    if ip ~= "" and ip ~= "127.0.0.1" and not ip:match("^192%.168%.") and not ip:match("^10%.") then
        return true
    end
    return false
end

function voice:flush_tx_pack(now, force)
    if not self._tx_pack_buf then return end
    if not force and (now - (self._tx_pack_ts or 0)) < 0.075 then return end
    local d1 = self._tx_pack_buf
    local l1 = self._tx_pack_lvl or 25
    self._tx_pack_buf = nil
    self._tx_pack_lvl = 0
    self._tx_pack_ts = 0
    if self.transport and self.transport:is_connected() then
        local qlen = self.transport.get_send_queue_len and self.transport:get_send_queue_len() or 0
        if qlen < 8 then
            self.transport:send({ t = "VOICE", d = d1, l = l1 })
            self.tx_count = self.tx_count + 1
        end
    end
end

function voice:send_adpcm_frame(adpcm_bin, norm, now)
    if not self.transport or not self.transport:is_connected() then return false end
    local qlen = self.transport.get_send_queue_len and self.transport:get_send_queue_len() or 0
    if qlen >= 8 then return false end
    local lvl_int = math.min(100, math.max(1, math.floor(norm * 100 + 0.5)))
    local b64 = b64_encode(adpcm_bin)
    if self:should_use_low_pps() then
        if not self._tx_pack_buf then
            self._tx_pack_buf = b64
            self._tx_pack_lvl = lvl_int
            self._tx_pack_ts = now
            return true
        end
        local d1 = self._tx_pack_buf
        local l_max = math.max(self._tx_pack_lvl or 1, lvl_int)
        self._tx_pack_buf = nil
        self._tx_pack_lvl = 0
        self._tx_pack_ts = 0
        self.transport:send({ t = "VOICE", d = d1, d2 = b64, l = l_max })
        self.tx_count = self.tx_count + 1
        return true
    end
    self.transport:send({ t = "VOICE", d = b64, l = lvl_int })
    self.tx_count = self.tx_count + 1
    return true
end

function voice:_update_love_audio(now, peer_ok, srv_ok, want_mic, want_spk)
    if want_spk then
        la_open_spk(self)
    else
        la_close_spk(self)
    end
    if want_mic then
        la_open_mic(self, now)
    else
        la_close_mic(self)
    end

    if not self._rec_dev then return end
    local ok_cnt, avail = pcall(self._rec_dev.getSampleCount, self._rec_dev)
    if not ok_cnt or not avail or avail <= 0 then return end
    local ok_sd, sd = pcall(self._rec_dev.getData, self._rec_dev)
    if not ok_sd or not sd then return end

    local sc = sd:getSampleCount()
    local sr = (sd.getSampleRate and sd:getSampleRate()) or self._rec_rate or 16000
    local ch = (sd.getChannelCount and sd:getChannelCount()) or self._rec_ch or 1
    local buf = self._rec_pcm
    local nbuf = #buf

    if sr == 16000 then
        for i = 0, sc - 1 do
            local s = (ch > 1) and sd:getSample(i, 1) or sd:getSample(i)
            nbuf = nbuf + 1
            buf[nbuf] = math.floor(s * 32767 + 0.5)
        end
    else
        -- Clean linear resample from 48kHz / 44.1kHz down to canonical 16kHz
        local ratio = sr / 16000.0
        local out_n = math.floor(sc / ratio)
        for j = 0, out_n - 1 do
            local pos = j * ratio
            local i0 = math.floor(pos)
            local i1 = math.min(sc - 1, i0 + 1)
            local frac = pos - i0
            local s0 = (ch > 1) and sd:getSample(i0, 1) or sd:getSample(i0)
            local s1 = (ch > 1) and sd:getSample(i1, 1) or sd:getSample(i1)
            local s = s0 + (s1 - s0) * frac
            nbuf = nbuf + 1
            buf[nbuf] = math.floor(s * 32767 + 0.5)
        end
    end
    if sd.release then pcall(sd.release, sd) end

    -- Cap buffered samples so latency never grows unbounded
    if nbuf > LA_FRAME_SAMPLES * 6 then
        local keep = {}
        local start_i = nbuf - LA_FRAME_SAMPLES * 2 + 1
        for i = start_i, nbuf do keep[#keep + 1] = buf[i] end
        self._rec_pcm = keep
        buf = keep
        nbuf = #buf
    end

    local sent_this_tick = 0
    while #buf >= LA_FRAME_SAMPLES and sent_this_tick < 3 do
        local frame = {}
        for i = 1, LA_FRAME_SAMPLES do
            frame[i] = buf[i]
        end
        -- Shift remaining samples
        local rem = {}
        for i = LA_FRAME_SAMPLES + 1, #buf do
            rem[#rem + 1] = buf[i]
        end
        self._rec_pcm = rem
        buf = rem

        local adpcm, rms = la_encode_frame(self, frame)
        local should_send = false
        if self.mode == "ptt" then
            should_send = self.ptt_held or self.self_test
        elseif self.mode == "vad" then
            if rms >= (self.vad_threshold or 0.018) then
                self._rec_hang_until = now + 0.32
            end
            should_send = (now <= (self._rec_hang_until or 0))
        end

        local norm = math.min(1.0, (rms or 0) * 5.0)
        if should_send then
            self.local_level = math.max(self.local_level * 0.5, norm)
            self.local_talking = true
            self.local_talk_until = now + 0.35

            if self.self_test and not self.peer_muted and la_open_spk(self) then
                la_play_adpcm(self, adpcm)
            end
            if peer_ok and srv_ok and self.transport and self.transport:is_connected() then
                self:send_adpcm_frame(adpcm, norm, now)
            end
            sent_this_tick = sent_this_tick + 1
        else
            self.local_level = self.local_level * 0.55 + norm * 0.45
        end
    end
    if peer_ok and srv_ok then
        self:flush_tx_pack(now, false)
    else
        self._tx_pack_buf = nil
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

    if not self.supported then
        return
    end

    local in_room = (lobby ~= nil and (lobby.view == "room" or (coop ~= nil and coop:is_active())))
    local peer_ok = (lobby ~= nil and lobby.peer_connected == true) or (coop ~= nil and coop:is_active())
    local is_online = self.transport and self.transport:is_online()
    local srv_ok = (not is_online) or (lobby == nil) or (lobby.server_voice_ok ~= false)
    self.active_room = in_room
    self.peer_connected = peer_ok
    self.online_server_ok = srv_ok

    -- Hold-to-talk (PC V key OR Android touch PTT button) — ignored while typing inside a lobby text input box!
    local typing = (lobby ~= nil and lobby.open == true and lobby.focused_field ~= nil)
    local v_down = (not typing) and love and love.keyboard and love.keyboard.isDown and love.keyboard.isDown("v") or false
    self.ptt_held = v_down or (self.touch_ptt_held == true)

    -- Only open hardware mic when inside a room (or self-testing) and not muted
    local want_mic = (in_room or self.self_test) and (self.mode ~= "mute")
    local want_spk = (in_room or self.self_test) and (not self.peer_muted)
    if not in_room and self.self_test then
        self.self_test = false
    end

    if self.backend == "love_audio" then
        self:_update_love_audio(now, peer_ok, srv_ok, want_mic, want_spk)
        return
    end

    if not self.ch_cmd or not self.ch_out then
        return
    end

    local sig = string.format("%s|%s|%s|%s|%.2f|%s|%.2f|%s",
        tostring(want_mic), tostring(want_spk), tostring(self.mode),
        tostring(self.ptt_held), self.mic_gain or 1.0, tostring(self.peer_muted), self.peer_volume or 1.0, tostring(self.self_test))
    if sig ~= self._last_cfg_sig then
        self._last_cfg_sig = sig
        self.ch_cmd:push({
            kind = "cfg",
            want_mic = want_mic,
            want_spk = want_spk,
            mode = self.mode,
            ptt_held = self.ptt_held,
            mic_gain = self.mic_gain or 1.0,
            peer_muted = self.peer_muted,
            peer_volume = self.peer_volume or 1.0,
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
                if self:send_adpcm_frame(ev.data, norm, now) then
                    sent_this_tick = sent_this_tick + 1
                end
            end
        end
    end
    if peer_ok and srv_ok then
        self:flush_tx_pack(now, false)
    else
        self._tx_pack_buf = nil
    end
end

-- Inject a pre-encoded 40ms 16kHz IMA-ADPCM Base64 frame from an external companion (e.g. AI co-op TTS)
-- Sends directly to the remote peer without opening the local physical microphone or looping back locally.
function voice:send_external_adpcm(b64_data, lvl_int)
    if type(b64_data) ~= "string" or #b64_data < 8 then
        return false
    end
    local now = get_now()
    local lvl_n = math.min(100, math.max(1, math.floor((tonumber(lvl_int) or 35) + 0.5)))
    local norm = math.min(1.0, lvl_n / 100.0)
    self.local_level = math.max(self.local_level * 0.5, norm)
    self.local_talking = true
    self.local_talk_until = now + 0.35

    if not self.peer_connected or not self.online_server_ok then
        return false
    end
    if not self.transport or not self.transport:is_connected() then
        return false
    end
    local qlen = self.transport.get_send_queue_len and self.transport:get_send_queue_len() or 0
    if qlen >= 10 then
        return false
    end
    self.transport:send({
        t = "VOICE",
        d = b64_data,
        l = lvl_n,
    })
    self.tx_count = self.tx_count + 1
    return true
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

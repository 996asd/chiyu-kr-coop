-- KR-MP Shared Voice Codec (RFC 4648 Base64 + Bit-Identical 16kHz IMA-ADPCM)
-- Single source of truth shared by Windows WinMM worker thread and Android LÖVE Audio backend.
local ok_bit_mod, bit_mod = pcall(require, "bit")

local M = {
    SAMPLE_RATE = 16000,
    FRAME_SAMPLES = 640, -- 40ms @ 16kHz
}

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

M.STEP_TABLE = STEP_TABLE
M.INDEX_TABLE = INDEX_TABLE

-- === Pure-Lua Fast Base64 (RFC 4648) ===

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_ENC = {}
local B64_DEC = {}
for i = 1, 64 do
    local c = B64_CHARS:sub(i, i)
    B64_ENC[i - 1] = c
    B64_DEC[string.byte(c)] = i - 1
end

function M.b64_encode(data)
    if not data or #data == 0 then return "" end
    local out = {}
    local n, k, i = #data, 0, 1
    while i <= n do
        local a = string.byte(data, i) or 0
        local b = string.byte(data, i + 1)
        local c = string.byte(data, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        k = k + 1; out[k] = B64_ENC[math.floor(v / 262144) % 64]
        k = k + 1; out[k] = B64_ENC[math.floor(v / 4096) % 64]
        k = k + 1; out[k] = b and B64_ENC[math.floor(v / 64) % 64] or "="
        k = k + 1; out[k] = c and B64_ENC[v % 64] or "="
        i = i + 3
    end
    return table.concat(out)
end

function M.b64_decode(str)
    if type(str) ~= "string" or #str == 0 then return nil end
    local out = {}
    local k, n, i = 0, #str, 1
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

-- === Shared IMA-ADPCM Helpers ===

local rshift = ok_bit_mod and bit_mod.rshift or function(v, n) return math.floor(v / (2 ^ n)) end

local function clamp_s16(v)
    if v > 32767 then return 32767 end
    if v < -32768 then return -32768 end
    return v
end

local function clamp_idx(idx)
    if idx < 0 then return 0 end
    if idx > 88 then return 88 end
    return idx
end

local function adpcm_encode_sample(sample, valpred, index, step)
    local diff = sample - valpred
    local sign = 0
    if diff < 0 then
        sign = 8
        diff = -diff
    end
    local delta = 0
    local vpdiff = rshift(step, 3)
    if diff >= step then
        delta = 4
        diff = diff - step
        vpdiff = vpdiff + step
    end
    local half = rshift(step, 1)
    if diff >= half then
        delta = delta + 2
        diff = diff - half
        vpdiff = vpdiff + half
    end
    local quarter = rshift(step, 2)
    if diff >= quarter then
        delta = delta + 1
        vpdiff = vpdiff + quarter
    end
    valpred = clamp_s16(sign ~= 0 and (valpred - vpdiff) or (valpred + vpdiff))
    local code = delta + sign
    index = clamp_idx(index + INDEX_TABLE[code + 1])
    return code, valpred, index, STEP_TABLE[index + 1]
end

local function adpcm_decode_nibble(code, valpred, index, step)
    local sign = (code >= 8) and 8 or 0
    local delta = code % 8
    local vpdiff = rshift(step, 3)
    if delta >= 4 then vpdiff = vpdiff + step; delta = delta - 4 end
    if delta >= 2 then vpdiff = vpdiff + rshift(step, 1); delta = delta - 2 end
    if delta >= 1 then vpdiff = vpdiff + rshift(step, 2) end
    valpred = clamp_s16(sign ~= 0 and (valpred - vpdiff) or (valpred + vpdiff))
    index = clamp_idx(index + INDEX_TABLE[code + 1])
    return valpred, index, STEP_TABLE[index + 1]
end

-- === Pure-Lua Table / SoundData Backend (Android & LÖVE 11/12) ===

function M.encode_pcm_array(state, pcm_arr, gain)
    local n_samples = M.FRAME_SAMPLES
    local sum_sq = 0.0
    local prev_x, prev_y = state.hp_x or 0.0, state.hp_y or 0.0
    local g = gain or 1.0
    local filt = {}
    for i = 1, n_samples do
        local x = pcm_arr[i] or 0
        local y = x - prev_x + 0.992 * prev_y
        prev_x, prev_y = x, y
        local yi = math.floor(clamp_s16(y * g) + 0.5)
        filt[i] = yi
        local nf = yi / 32768.0
        sum_sq = sum_sq + nf * nf
    end
    state.hp_x, state.hp_y = prev_x, prev_y
    local rms = math.sqrt(sum_sq / n_samples)

    local valpred = filt[1] or 0
    local index = clamp_idx(state.step_idx or 0)
    local vp_u = valpred < 0 and (valpred + 65536) or valpred
    local out = {
        string.char(vp_u % 256),
        string.char(math.floor(vp_u / 256) % 256),
        string.char(index),
        "\0",
    }
    local k, step, low_nib = 4, STEP_TABLE[index + 1], 0
    for i = 0, n_samples - 1 do
        local code
        code, valpred, index, step = adpcm_encode_sample(filt[i + 1], valpred, index, step)
        if (i % 2) == 0 then
            low_nib = code
        else
            k = k + 1
            out[k] = string.char(low_nib + code * 16)
        end
    end
    state.step_idx = index
    return table.concat(out), rms
end

function M.decode_to_sounddata(bin, gain, sd)
    local len = #bin
    if len < 6 then return 0 end
    local b0, b1, b2 = string.byte(bin, 1, 3)
    local vp_u = b0 + b1 * 256
    local valpred = vp_u >= 32768 and (vp_u - 65536) or vp_u
    local index = clamp_idx(b2)
    local step = STEP_TABLE[index + 1]
    local n_samples = math.min(M.FRAME_SAMPLES, (len - 4) * 2)
    local g = gain or 1.0
    for i = 0, n_samples - 1 do
        local byte_val = string.byte(bin, 5 + math.floor(i / 2)) or 0
        local code = ((i % 2) == 0) and (byte_val % 16) or math.floor(byte_val / 16)
        valpred, index, step = adpcm_decode_nibble(code, valpred, index, step)
        local s = (valpred * g) / 32768.0
        if s > 1.0 then s = 1.0 elseif s < -1.0 then s = -1.0 end
        sd:setSample(i, s)
    end
    for i = n_samples, M.FRAME_SAMPLES - 1 do
        sd:setSample(i, 0)
    end
    return n_samples
end

-- === Zero-Allocation LuaJIT FFI Pointer Backend (Windows WinMM Worker Thread) ===

function M.encode_pcm_ptr(state, ffi, bit, pcm_ptr, n_samples, gain, out_buf, filt_buf)
    local sum_sq = 0.0
    local prev_x, prev_y = state.hp_x or 0.0, state.hp_y or 0.0
    local g = gain or 1.0
    local filtered = filt_buf or ffi.new("int16_t[?]", n_samples)
    for i = 0, n_samples - 1 do
        local x = tonumber(pcm_ptr[i])
        local y = x - prev_x + 0.992 * prev_y
        prev_x, prev_y = x, y
        local yi = math.floor(clamp_s16(y * g) + 0.5)
        filtered[i] = yi
        local nf = yi / 32768.0
        sum_sq = sum_sq + nf * nf
    end
    state.hp_x, state.hp_y = prev_x, prev_y
    local rms = math.sqrt(sum_sq / n_samples)

    local valpred = tonumber(filtered[0])
    local index = clamp_idx(state.step_idx or 0)
    local vp_u = valpred < 0 and (valpred + 65536) or valpred
    out_buf[0] = bit.band(vp_u, 0xFF)
    out_buf[1] = bit.band(bit.rshift(vp_u, 8), 0xFF)
    out_buf[2] = index
    out_buf[3] = 0

    local step, out_pos, low_nib = STEP_TABLE[index + 1], 4, 0
    for i = 0, n_samples - 1 do
        local code
        code, valpred, index, step = adpcm_encode_sample(tonumber(filtered[i]), valpred, index, step)
        if bit.band(i, 1) == 0 then
            low_nib = code
        else
            out_buf[out_pos] = bit.bor(low_nib, bit.lshift(code, 4))
            out_pos = out_pos + 1
        end
    end
    state.step_idx = index
    return ffi.string(out_buf, out_pos), rms
end

function M.decode_to_pcm_ptr(ffi, bit, adpcm_str, out_pcm_ptr, gain)
    local len = #adpcm_str
    if len < 6 then return 0, 0 end
    local raw = ffi.cast("const uint8_t*", adpcm_str)
    local vp_u = raw[0] + raw[1] * 256
    local valpred = vp_u >= 32768 and (vp_u - 65536) or vp_u
    local index = clamp_idx(raw[2])
    local step = STEP_TABLE[index + 1]
    local n_samples = math.min(M.FRAME_SAMPLES, (len - 4) * 2)
    local sum_sq, g = 0.0, gain or 1.0
    for i = 0, n_samples - 1 do
        local byte_val = raw[4 + bit.rshift(i, 1)]
        local code = (bit.band(i, 1) == 0) and bit.band(byte_val, 0x0F) or bit.rshift(byte_val, 4)
        valpred, index, step = adpcm_decode_nibble(code, valpred, index, step)
        local si = math.floor(clamp_s16(valpred * g) + 0.5)
        out_pcm_ptr[i] = si
        local nf = si / 32768.0
        sum_sq = sum_sq + nf * nf
    end
    for i = n_samples, M.FRAME_SAMPLES - 1 do
        out_pcm_ptr[i] = 0
    end
    return n_samples, math.sqrt(sum_sq / math.max(1, n_samples))
end

return M

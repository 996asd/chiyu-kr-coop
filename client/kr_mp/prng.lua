-- Deterministic 32-bit PRNG (Mulberry32 via LuaJIT bit library)
-- Strictly isolates battle simulation RNG from visual/audio/UI RNG.
local bit = require("bit")
local bxor = bit.bxor
local bor = bit.bor
local band = bit.band
local rshift = bit.rshift
local tobit = bit.tobit

local prng = {}

local orig_math_random = math.random

local function imul32(a, b)
    a = tobit(a)
    b = tobit(b)
    local ah = rshift(a, 16)
    local al = band(a, 0xffff)
    local bh = rshift(b, 16)
    local bl = band(b, 0xffff)
    local lo = al * bl
    local hi = band(ah * bl + al * bh, 0xffff) * 65536
    return tobit(lo + hi)
end

local function make_stream(seed)
    local s = {
        state = tobit(seed or 1),
        calls = 0,
    }
    if s.state == 0 then
        s.state = 0x6d2b79f5
    end
    return s
end

local trace_rng_from = tonumber(os.getenv("KR_MP_TRACE_RNG_FROM") or "0") or 0
local trace_rng_to = tonumber(os.getenv("KR_MP_TRACE_RNG_TO") or "0") or 0
local trace_tick_from = tonumber(os.getenv("KR_MP_TRACE_TICK_FROM") or "0") or 0
local trace_tick_to = tonumber(os.getenv("KR_MP_TRACE_TICK_TO") or "0") or 0

local function next_u32(stream)
    stream.calls = stream.calls + 1
    if (trace_rng_from > 0 or trace_tick_from > 0) and stream == prng.sim_stream then
        local tick = (game and game.store and game.store.tick) or -1
        local match_call = (trace_rng_from > 0 and stream.calls >= trace_rng_from and stream.calls <= trace_rng_to)
        local match_tick = (trace_tick_from > 0 and tick >= trace_tick_from and tick <= trace_tick_to)
        if match_call or match_tick then
            local info = debug.getinfo(4, "Sl")
            local info2 = debug.getinfo(5, "Sl")
            local msg = string.format("[TRACE_RNG] tick=%d call=%d at %s:%s <- %s:%s",
                tick, stream.calls,
                tostring(info and info.short_src), tostring(info and info.currentline),
                tostring(info2 and info2.short_src), tostring(info2 and info2.currentline))
            print(msg)
            if prng.on_trace then prng.on_trace(msg) end
        end
    end
    local t = tobit(stream.state + 0x6d2b79f5)
    stream.state = t
    t = imul32(bxor(t, rshift(t, 15)), bor(t, 1))
    t = bxor(t, tobit(t + imul32(bxor(t, rshift(t, 7)), bor(t, 61))))
    local res = bxor(t, rshift(t, 14))
    if res < 0 then
        return res + 4294967296
    end
    return res
end

local function stream_random(stream, m, n)
    local u = next_u32(stream)
    local f = u / 4294967296.0
    if m == nil then
        return f
    elseif n == nil then
        local hi = math.floor(m)
        if hi < 1 then
            return 1
        end
        return 1 + math.floor(f * hi)
    else
        local lo = math.floor(m)
        local hi = math.floor(n)
        if hi < lo then
            lo, hi = hi, lo
        end
        return lo + math.floor(f * (hi - lo + 1))
    end
end

prng.sim_stream = make_stream(123456)
prng.vis_stream = make_stream(os.time())
prng.mode_stack = {}
prng.current_mode = "vis"
prng.installed = false
prng.sim_seed = 123456

function prng:install()
    if self.installed then return end
    self.installed = true

    math.random = function(m, n)
        if prng.current_mode == "sim" then
            return stream_random(prng.sim_stream, m, n)
        else
            return stream_random(prng.vis_stream, m, n)
        end
    end

    math.randomseed = function(seed)
        if prng.current_mode == "vis" then
            prng.vis_stream = make_stream(tonumber(seed) or 1)
        end
    end
end

function prng:seed_sim(seed)
    self.sim_seed = tobit(tonumber(seed) or 1)
    self.sim_stream = make_stream(self.sim_seed)
end

function prng:enter_sim()
    self.mode_stack[#self.mode_stack + 1] = self.current_mode
    self.current_mode = "sim"
end

function prng:exit_sim()
    local n = #self.mode_stack
    if n > 0 then
        self.current_mode = self.mode_stack[n]
        self.mode_stack[n] = nil
    else
        self.current_mode = "vis"
    end
end

function prng:enter_visual()
    self.mode_stack[#self.mode_stack + 1] = self.current_mode
    self.current_mode = "vis"
end

function prng:exit_visual()
    local n = #self.mode_stack
    if n > 0 then
        self.current_mode = self.mode_stack[n]
        self.mode_stack[n] = nil
    else
        self.current_mode = "vis"
    end
end

function prng:get_sim_calls()
    return self.sim_stream.calls
end

function prng:get_sim_state_u32()
    local s = self.sim_stream.state
    if s < 0 then return s + 4294967296 end
    return s
end

function prng:raw_random(m, n)
    return orig_math_random(m, n)
end

return prng

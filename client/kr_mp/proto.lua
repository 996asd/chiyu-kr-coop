-- KR-MP Network Wire Protocol Codec (shared by M1 LAN and M2 Online Go Relay)
-- Produces single-line JSON messages (newline-delimited TCP framing) with zero external deps.
local bit = require("bit")

local proto = {
    MOD_VERSION = "2.5.0",
    PROTOCOL_VER = 3,
    DEFAULT_TCP_PORT = 17777,
    LAN_DISCOVERY_PORT = 17778,
    DEFAULT_ONLINE_HOST = "127.0.0.1",
    DEFAULT_ONLINE_PORT = 17780,
    TURN_TICKS = 3,        -- 3 ticks per lockstep turn (50ms @ 60Hz)
    INPUT_DELAY_TURNS = 2, -- 2 turns lookahead (100ms LAN; 4 turns = 200ms for SakuraFrp)
    _script_hash = nil,
}

function proto.is_android()
    if IS_ANDROID == true then return true end
    return (love and love.system and love.system.getOS and love.system.getOS() == "Android") == true
end

function proto.is_love11_plus()
    if proto.is_android() then return true end
    if love and love.getVersion then
        local major = select(1, love.getVersion())
        if tonumber(major) and tonumber(major) >= 11 then return true end
    end
    return false
end

function proto.get_writable_dir()
    if proto.is_android() then
        if love and love.filesystem and love.filesystem.getSaveDirectory then
            return love.filesystem.getSaveDirectory()
        end
        return "."
    end
    if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
        return love.filesystem.getSourceBaseDirectory()
    end
    return "."
end

function proto.path_join(dir, name)
    local sep = proto.is_android() and "/" or "\\"
    dir = tostring(dir or "."):gsub("[/\\]+$", "")
    return dir .. sep .. tostring(name or "")
end

-- Cleanly extract host[:port] (or P2P|Relay dual address) from clipboard / SakuraFrp / OpenFrp copy-paste strings
-- Handles SakuraLauncher log markers >>host:port<<, timestamps (ignores 12:34), fullwidth Chinese colon "：", "tcp://", etc.
local function extract_single_addr(raw)
    if type(raw) ~= "string" then return "" end
    local s = raw:gsub("\r", " "):gsub("\n", " ")
    s = s:gsub("：", ":") -- Chinese fullwidth colon -> ASCII colon
    s = s:gsub("^[%s]+", ""):gsub("[%s]+$", "")
    s = s:gsub("^%a+://", "")
    -- 1. Prefer official SakuraFrp log angle-bracket marker: >>frp-ski.com:54321<<
    local sakura_mark = s:match(">>([%w%-]+%.[%w%.%-]+:%d+)<<")
    if sakura_mark then return sakura_mark end
    -- 2. Dotted hostname / IPv4 + port (explicitly excludes log timestamps like "12:34" or "07:25")
    local hp = s:match("([%w%-]+%.[%w%.%-]+:%d+)")
    if hp then return hp end
    -- 3. localhost:port
    local lh = s:match("([lL][oO][cC][aA][lL][hH][oO][sS][tT]:%d+)")
    if lh then return lh:lower() end
    -- 4. Bare dotted IP / hostname
    local bare = s:match("([%w%-]+%.[%w%.%-]+)")
    if bare then return bare end
    local fallback = s:match("([%w%.%-]+)")
    return fallback or ""
end

function proto.sanitize_addr(raw)
    if type(raw) ~= "string" then return "" end
    local p1, p2 = raw:match("^([^|]+)|([^|]+)$")
    if p1 and p2 then
        local a1 = extract_single_addr(p1)
        local a2 = extract_single_addr(p2)
        if #a1 > 0 and #a2 > 0 then
            return a1 .. "|" .. a2
        end
    end
    return extract_single_addr(raw)
end

-- Split optional "p2p_host:port|relay_host:port" dual address into (primary, fallback_or_nil)
function proto.split_fallback_addr(raw)
    local clean = proto.sanitize_addr(raw or "")
    local p1, p2 = clean:match("^([^|]+)|([^|]+)$")
    if p1 and p2 then
        return p1, p2
    end
    return clean, nil
end

-- Core deterministic simulation & director scripts (100% identical between PC FL 8.2.0 and Android HD APK)
local CORE_HASH_FILES = {
    "all/simulation.lua",
    "lib/klove/simulation.lua",
    "all/systems.lua",
    "all/entity_db.lua",
    "all/grid_db.lua",
    "all/director.lua",
}

local function fnv1a_step(h, s)
    local bxor = bit.bxor
    local len = #s
    for i = 1, len do
        h = bxor(h, s:byte(i))
        -- Multiply by FNV prime 16777619 modulo 2^32 using exact 16-bit split (LuaJIT double safe)
        local lo = bit.band(h, 0xFFFF)
        local hi = bit.rshift(h, 16)
        local p_lo = lo * 16777619
        local p_hi = (hi * 16777619) % 65536
        h = bit.tobit(p_lo + p_hi * 65536)
    end
    return h
end

function proto.compute_script_hash()
    if proto._script_hash then
        return proto._script_hash
    end
    local h = bit.tobit(0x811c9dc5)
    h = fnv1a_step(h, tostring(KR_FL_VERSION or "8.2.0"))
    h = fnv1a_step(h, "|")
    if love and love.filesystem and love.filesystem.read then
        for i = 1, #CORE_HASH_FILES do
            local fpath = CORE_HASH_FILES[i]
            local ok, data = pcall(love.filesystem.read, fpath)
            if ok and type(data) == "string" then
                h = fnv1a_step(h, fpath)
                h = fnv1a_step(h, ":")
                h = fnv1a_step(h, tostring(#data))
                h = fnv1a_step(h, ":")
                -- Hash full contents of each core script for strong tamper/version mismatch detection
                h = fnv1a_step(h, data)
                h = fnv1a_step(h, "|")
            end
        end
    end
    local unsigned = (h < 0) and (h + 4294967296) or h
    proto._script_hash = string.format("%08X", unsigned)
    return proto._script_hash
end

local function escape_str(s)
    return (s:gsub('[\\"\r\n\t]', {
        ['\\'] = '\\\\',
        ['"'] = '\\"',
        ['\r'] = '\\r',
        ['\n'] = '\\n',
        ['\t'] = '\\t',
    }))
end

local function encode_val(v)
    local tv = type(v)
    if tv == "nil" then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            return "0"
        end
        return string.format("%.14g", v)
    elseif tv == "string" then
        return '"' .. escape_str(v) .. '"'
    elseif tv == "table" then
        local count = 0
        local max_i = 0
        local is_array = true
        for k in pairs(v) do
            count = count + 1
            if type(k) == "number" and k >= 1 and math.floor(k) == k then
                if k > max_i then max_i = k end
            else
                is_array = false
            end
        end
        if is_array and count > 0 and max_i == count then
            local parts = {}
            for i = 1, count do
                parts[i] = encode_val(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) == "string" or type(k) == "number" then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys, function(a, b)
                local ta, tb = type(a), type(b)
                if ta ~= tb then return ta < tb end
                return a < b
            end)
            local parts = {}
            for i = 1, #keys do
                local k = keys[i]
                local val = v[k]
                if val ~= nil and type(val) ~= "function" and type(val) ~= "userdata" and type(val) ~= "thread" then
                    parts[#parts + 1] = '"' .. escape_str(tostring(k)) .. '":' .. encode_val(val)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function codepoint_to_utf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
    else
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + (math.floor(cp / 64) % 64),
            0x80 + (cp % 64)
        )
    end
end

-- Pure-Lua safe JSON decoder (no loadstring / arbitrary execution)
local function decode_json(str)
    if type(str) ~= "string" then return nil, "not a string" end
    local pos = 1
    local len = #str

    local function skip_ws()
        while pos <= len do
            local c = str:byte(pos)
            if c == 32 or c == 9 or c == 10 or c == 13 then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parse_value

    local function parse_string()
        pos = pos + 1 -- skip opening "
        local buf = {}
        while pos <= len do
            local c = str:byte(pos)
            if c == 34 then -- "
                pos = pos + 1
                return table.concat(buf)
            elseif c == 92 then -- \
                pos = pos + 1
                local esc = str:sub(pos, pos)
                pos = pos + 1
                if esc == '"' or esc == '\\' or esc == '/' then
                    buf[#buf + 1] = esc
                elseif esc == 'n' then
                    buf[#buf + 1] = '\n'
                elseif esc == 'r' then
                    buf[#buf + 1] = '\r'
                elseif esc == 't' then
                    buf[#buf + 1] = '\t'
                elseif esc == 'b' then
                    buf[#buf + 1] = '\b'
                elseif esc == 'f' then
                    buf[#buf + 1] = '\f'
                elseif esc == 'u' then
                    local hex4 = str:sub(pos, pos + 3)
                    local cp = tonumber(hex4, 16)
                    if cp then
                        pos = pos + 4
                        buf[#buf + 1] = codepoint_to_utf8(cp)
                    else
                        buf[#buf + 1] = 'u'
                    end
                else
                    buf[#buf + 1] = esc
                end
            else
                local start = pos
                while pos <= len do
                    local b = str:byte(pos)
                    if b == 34 or b == 92 then break end
                    pos = pos + 1
                end
                buf[#buf + 1] = str:sub(start, pos - 1)
            end
        end
        return nil, "unterminated string"
    end

    local function parse_number()
        local start = pos
        while pos <= len do
            local c = str:byte(pos)
            if (c >= 48 and c <= 57) or c == 45 or c == 43 or c == 46 or c == 101 or c == 69 then
                pos = pos + 1
            else
                break
            end
        end
        local num = tonumber(str:sub(start, pos - 1))
        if not num then return nil, "bad number" end
        return num
    end

    local function parse_array()
        pos = pos + 1 -- skip [
        local arr = {}
        skip_ws()
        if pos <= len and str:byte(pos) == 93 then
            pos = pos + 1
            return arr
        end
        while pos <= len do
            local val, err = parse_value()
            if err then return nil, err end
            arr[#arr + 1] = val
            skip_ws()
            local c = str:byte(pos)
            if c == 44 then -- ,
                pos = pos + 1
            elseif c == 93 then -- ]
                pos = pos + 1
                return arr
            else
                return nil, "expected , or ] at " .. pos
            end
        end
        return nil, "unterminated array"
    end

    local function parse_object()
        pos = pos + 1 -- skip {
        local obj = {}
        skip_ws()
        if pos <= len and str:byte(pos) == 125 then
            pos = pos + 1
            return obj
        end
        while pos <= len do
            skip_ws()
            if str:byte(pos) ~= 34 then
                return nil, "expected string key at " .. pos
            end
            local key, kerr = parse_string()
            if kerr then return nil, kerr end
            skip_ws()
            if str:byte(pos) ~= 58 then -- :
                return nil, "expected : at " .. pos
            end
            pos = pos + 1
            local val, verr = parse_value()
            if verr then return nil, verr end
            -- Restore numeric keys when string is pure non-negative integer (for sparse Lua tables like slot.levels)
            local nk = key:match("^%d+$")
            if nk and #nk <= 9 then
                obj[tonumber(nk)] = val
            else
                obj[key] = val
            end
            skip_ws()
            local c = str:byte(pos)
            if c == 44 then -- ,
                pos = pos + 1
            elseif c == 125 then -- }
                pos = pos + 1
                return obj
            else
                return nil, "expected , or } at " .. pos
            end
        end
        return nil, "unterminated object"
    end

    parse_value = function()
        skip_ws()
        if pos > len then return nil, "unexpected eof" end
        local c = str:byte(pos)
        if c == 34 then
            return parse_string()
        elseif c == 123 then
            return parse_object()
        elseif c == 91 then
            return parse_array()
        elseif c == 116 and str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif c == 102 and str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif c == 110 and str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        elseif c == 45 or (c >= 48 and c <= 57) then
            return parse_number()
        end
        return nil, "unexpected char at " .. pos
    end

    local ok_val, err = parse_value()
    if err then return nil, err end
    return ok_val, nil
end

function proto.encode(msg)
    return encode_val(msg) .. "\n"
end

function proto.decode(line)
    if not line or #line == 0 then return nil, "empty" end
    return decode_json(line)
end

-- Safe cycle-aware deep table copy (strips functions / userdata / threads) shared across KR-MP modules.
function proto.deep_copy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, val in pairs(v) do
        local tk, tv = type(k), type(val)
        if tk ~= "function" and tk ~= "userdata" and tk ~= "thread"
            and tv ~= "function" and tv ~= "userdata" and tv ~= "thread" then
            out[proto.deep_copy(k, seen)] = proto.deep_copy(val, seen)
        end
    end
    return out
end

return proto

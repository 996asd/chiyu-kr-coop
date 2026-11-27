-- KR-MP Lobby Persistence, Clipboard & SakuraFrp Address Utilities
-- Extracted from lobby_ui.lua to keep modules cohesive and <= 1,000 lines.
local proto = require("kr_mp.proto")
local catalog = require("kr_mp.catalog")
local loadout = require("kr_mp.coop_loadout")
local autotest = require("kr_mp.autotest")

local M = {}

local function get_prefs_path()
    return proto.path_join(proto.get_writable_dir(), "kr_mp_prefs.json")
end

local function get_session_path()
    local env_p = os.getenv("KR_MP_SESSION_FILE")
    if env_p and env_p ~= "" then return env_p end
    local log_file = os.getenv("KR_MP_LOG_FILE")
    if log_file then
        local log_dir = log_file:match("^(.*)[/\\][^/\\]+$")
        if log_dir then return proto.path_join(log_dir, "last_session.json") end
    end
    return proto.path_join(proto.get_writable_dir(), "kr_mp_last_session.json")
end

local function parse_sakura_parts(addr)
    if type(addr) ~= "string" then return nil end
    local primary = proto.split_fallback_addr(addr)
    local host, port = primary:match("^([^:]+):(%d+)$")
    if not host or not port then return nil end
    local lower = host:lower()
    local prefix, base = lower:match("^(dx%.)(.+)$")
    if not prefix then prefix, base = lower:match("^(yd%.)(.+)$") end
    if not prefix then prefix, base = lower:match("^(lt%.)(.+)$") end
    base = base or lower
    if base:match("^frp%-[%w%-]+%.%w+$") then
        local carrier = (prefix == "dx.") and "dx" or ((prefix == "yd.") and "yd" or "default")
        return base, port, carrier, true
    elseif base:match("^[%w%-]+%.natfrp%.cloud$") or base:match("^[%w%-]+%.sakurafrp%.com$") then
        local carrier = (prefix == "dx.") and "dx" or ((prefix == "yd.") and "yd" or "default")
        return base, port, carrier, true
    elseif base:match("^[%w%.%-]+%.nyat%.app$") then
        return base, port, "default", false
    end
    return nil
end

M.parse_sakura_parts = parse_sakura_parts

function M.is_sakura_addr(addr)
    return parse_sakura_parts(addr) ~= nil
end

function M.supports_sakura_carrier(addr)
    local _, _, _, sup = parse_sakura_parts(addr)
    return sup == true
end

function M.get_sakura_carrier(addr)
    local _, _, carrier = parse_sakura_parts(addr)
    return carrier
end

function M.switch_sakura_carrier(addr, carrier)
    local primary, fallback = proto.split_fallback_addr(addr)
    local base, port, _, sup = parse_sakura_parts(primary)
    if not base or not port or not sup then return nil end
    local next_p
    if carrier == "dx" then
        next_p = "dx." .. base .. ":" .. port
    elseif carrier == "yd" then
        next_p = "yd." .. base .. ":" .. port
    else
        next_p = base .. ":" .. port
    end
    return fallback and (next_p .. "|" .. fallback) or next_p
end

local function is_private_lan_addr(addr)
    local clean = proto.split_fallback_addr(addr or "")
    local host = clean:match("^([^:]+)") or clean
    if host == "" or host == "localhost" or host == "127.0.0.1" then return true end
    if host:match("^192%.168%.") or host:match("^10%.") or host:match("^172%.1[6-9]%.")
        or host:match("^172%.2%d%.") or host:match("^172%.3[01]%.") then
        return true
    end
    return false
end

M.is_private_lan_addr = is_private_lan_addr

function M.record_recent_addr(lobby, raw_addr)
    local clean = proto.sanitize_addr(raw_addr or ""):sub(1, 96)
    if clean == "" or is_private_lan_addr(clean) then
        return
    end
    local list = lobby.recent_addrs or {}
    local next_list = { clean }
    for i = 1, #list do
        local item = list[i]
        if type(item) == "string" and item ~= "" and item ~= clean and not is_private_lan_addr(item) and #next_list < 3 then
            next_list[#next_list + 1] = item
        end
    end
    lobby.recent_addrs = next_list
end

function M.load_prefs(lobby)
    if autotest:is_active() or os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") or os.getenv("KR_MP_AUTO_SAKURA") then
        return
    end
    local f = io.open(get_prefs_path(), "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    local obj = proto.decode(raw)
    if type(obj) ~= "table" then return end

    if type(obj.sakura_ip_input) == "string" then
        lobby.sakura_ip_input = obj.sakura_ip_input:sub(1, 96)
    elseif type(obj.ip_input) == "string" and #obj.ip_input > 0 and not is_private_lan_addr(obj.ip_input) then
        -- Seamless migration from pre-split v2.3.0 prefs
        lobby.sakura_ip_input = obj.ip_input:sub(1, 96)
    end
    if type(obj.lan_ip_input) == "string" and #obj.lan_ip_input > 0 then
        lobby.lan_ip_input = obj.lan_ip_input:sub(1, 80)
    elseif type(obj.ip_input) == "string" and #obj.ip_input > 0 and is_private_lan_addr(obj.ip_input) then
        lobby.lan_ip_input = obj.ip_input:sub(1, 80)
    end
    lobby.ip_input = lobby.sakura_ip_input
    if type(obj.server_input) == "string" and #obj.server_input > 0 and not os.getenv("KR_MP_SERVER") then
        lobby.server_input = obj.server_input:sub(1, 80)
    end
    if type(obj.recent_addrs) == "table" then
        local rec = {}
        for i = 1, math.min(#obj.recent_addrs, 3) do
            local item = obj.recent_addrs[i]
            if type(item) == "string" and #item > 0 and not is_private_lan_addr(item) then
                rec[#rec + 1] = item:sub(1, 96)
            end
        end
        lobby.recent_addrs = rec
    end

    -- Restore persisted room configuration
    if obj.input_delay_turns ~= nil then
        lobby.room.input_delay_turns = lobby.normalize_delay_turns(obj.input_delay_turns)
    end
    if tonumber(obj.room_level_idx) then
        lobby.room.level_idx = math.floor(tonumber(obj.room_level_idx))
    end
    if tonumber(obj.room_level_difficulty) then
        local d = math.floor(tonumber(obj.room_level_difficulty))
        if d >= 1 and d <= 4 then lobby.room.level_difficulty = d end
    end
    if obj.room_econ_mode == "independent" or obj.room_econ_mode == "shared" then
        lobby.room.econ_mode = obj.room_econ_mode
    end
    if obj.room_tower_mode == "owned" or obj.room_tower_mode == "open" then
        lobby.room.tower_mode = obj.room_tower_mode
    end
    if type(obj.room_heroes) == "table" and tonumber(obj.room_heroes[1]) and tonumber(obj.room_heroes[2]) then
        lobby.room.heroes = { math.floor(tonumber(obj.room_heroes[1])), math.floor(tonumber(obj.room_heroes[2])) }
    end
    if type(obj.room_towers) == "table" and #obj.room_towers >= 1 then
        local max_tid = catalog.MAX_TOWER_ID or 59
        local deck, seen = {}, {}
        for i = 1, math.min(#obj.room_towers, 12) do
            local tid = tonumber(obj.room_towers[i])
            if tid and tid >= 1 and tid <= max_tid and not seen[tid] then
                seen[tid] = true
                deck[#deck + 1] = math.floor(tid)
            end
        end
        if #deck >= 1 then lobby.room.towers = deck end
    end
    if type(obj.room_cataclysm) == "string" then
        lobby.room.cataclysm = loadout.normalize_cataclysm(obj.room_cataclysm)
    end
    if type(obj.room_reinforcements) == "table" then
        lobby.room.reinforcements = {
            loadout.normalize_reinf(obj.room_reinforcements[1]),
            loadout.normalize_reinf(obj.room_reinforcements[2]),
        }
    end
    if obj.room_max_tech ~= nil then
        lobby.room.max_tech = (obj.room_max_tech == true)
    end
    if obj.room_auto_next_stage ~= nil then
        lobby.room.auto_next_stage = (obj.room_auto_next_stage == true)
    end
    lobby.ensure_room_defaults(lobby.room)

    if obj.show_tower_marks ~= nil and lobby.coop then
        lobby.coop.show_tower_marks = (obj.show_tower_marks ~= false)
    end
    if lobby.voice then
        if type(obj.voice_mode) == "string" then lobby.voice:set_mode(obj.voice_mode) end
        if tonumber(obj.voice_mic_gain) then lobby.voice:set_mic_gain(tonumber(obj.voice_mic_gain)) end
        if tonumber(obj.voice_peer_volume) then lobby.voice:set_peer_volume(tonumber(obj.voice_peer_volume)) end
        if obj.voice_peer_muted ~= nil then lobby.voice.peer_muted = (obj.voice_peer_muted == true) end
        if type(obj.voice_indicator_style) == "string" then lobby.voice:set_indicator_style(obj.voice_indicator_style) end
    end
    if lobby.overlay then
        if tonumber(obj.hud_mini_x) then lobby.overlay.mini_x = math.floor(tonumber(obj.hud_mini_x) + 0.5) end
        if tonumber(obj.hud_mini_y) then lobby.overlay.mini_y = math.floor(tonumber(obj.hud_mini_y) + 0.5) end
    end
    if obj.seen_guide ~= nil then
        lobby.seen_guide = (obj.seen_guide == true)
    end
    if obj.privacy_mask ~= nil then
        lobby.privacy_mask = (obj.privacy_mask == true)
    end
    if lobby.sakura then
        if type(obj.sakura_token) == "string" and #obj.sakura_token > 0 then
            lobby.sakura:set_token(obj.sakura_token)
        end
        if obj.sakura_public_mode ~= nil then
            lobby.sakura.public_mode = (obj.sakura_public_mode == true)
        end
    end
end

function M.save_prefs(lobby)
    if autotest:is_active() or os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") or os.getenv("KR_MP_AUTO_SAKURA") then
        return
    end
    local r = lobby.room or {}
    local prefs = {
        sakura_ip_input = lobby.sakura_ip_input or "",
        lan_ip_input = lobby.lan_ip_input or "127.0.0.1",
        ip_input = lobby.sakura_ip_input or lobby.lan_ip_input or "",
        server_input = lobby.server_input,
        recent_addrs = lobby.recent_addrs or {},
        input_delay_turns = lobby.normalize_delay_turns(r.input_delay_turns),
        room_level_idx = r.level_idx or 101,
        room_level_difficulty = r.level_difficulty or 2,
        room_econ_mode = r.econ_mode or "independent",
        room_tower_mode = r.tower_mode or "owned",
        room_heroes = r.heroes or { catalog.DEFAULT_HERO_1 or 53, catalog.DEFAULT_HERO_2 or 54 },
        room_towers = r.towers or catalog.DEFAULT_TOWERS,
        room_cataclysm = loadout.normalize_cataclysm(r.cataclysm),
        room_reinforcements = {
            loadout.normalize_reinf(r.reinforcements and r.reinforcements[1]),
            loadout.normalize_reinf(r.reinforcements and r.reinforcements[2]),
        },
        room_max_tech = (r.max_tech ~= false),
        room_auto_next_stage = (r.auto_next_stage ~= false),
        show_tower_marks = (lobby.coop == nil) or (lobby.coop.show_tower_marks ~= false),
        voice_mode = lobby.voice and lobby.voice.mode or "ptt",
        voice_mic_gain = lobby.voice and lobby.voice.mic_gain or 1.0,
        voice_peer_volume = lobby.voice and lobby.voice.peer_volume or 1.0,
        voice_peer_muted = lobby.voice and (lobby.voice.peer_muted == true) or false,
        voice_indicator_style = lobby.voice and lobby.voice.indicator_style or "compact",
        hud_mini_x = lobby.overlay and tonumber(lobby.overlay.mini_x) or nil,
        hud_mini_y = lobby.overlay and tonumber(lobby.overlay.mini_y) or nil,
        seen_guide = (lobby.seen_guide == true),
        privacy_mask = (lobby.privacy_mask == true),
        sakura_token = (lobby.sakura and type(lobby.sakura.token) == "string") and lobby.sakura.token or "",
        sakura_public_mode = (lobby.sakura and lobby.sakura.public_mode == true) or false,
    }
    local f = io.open(get_prefs_path(), "w")
    if f then
        f:write(proto.encode(prefs))
        f:flush()
        f:close()
    end
end

function M.copy_to_clipboard(lobby, text, toast_msg)
    if not love or not love.system or not love.system.setClipboardText then
        lobby.overlay:show_toast("当前环境不支持复制到剪贴板。", 2.2)
        return false
    end
    local ok = pcall(love.system.setClipboardText, tostring(text or ""))
    if ok and toast_msg then
        lobby.overlay:show_toast(toast_msg, 2.8)
    end
    return ok
end

function M.paste_into_field(lobby, field_name)
    if not love or not love.system or not love.system.getClipboardText then
        lobby.overlay:show_toast("当前环境不支持读取剪贴板，请手动输入。", 2.5)
        return false
    end
    local clip = love.system.getClipboardText()
    if type(clip) ~= "string" or #clip == 0 then
        lobby.overlay:show_toast("剪贴板为空！请先复制樱花映射或服务器地址。", 2.5)
        return false
    end
    if field_name == "sakura_ip" or field_name == "ip" then
        local clean = proto.sanitize_addr(clip):sub(1, 96)
        if #clean > 0 then
            lobby.sakura_ip_input = clean
            lobby.ip_input = clean
            M.record_recent_addr(lobby, clean)
            M.save_prefs(lobby)
            local shown = (lobby.privacy_mask and lobby.sakura) and lobby.sakura.mask_addr(clean) or clean
            lobby.overlay:show_toast("已粘贴樱花联机地址：" .. shown, 3.0)
            return true
        end
    elseif field_name == "lan_ip" then
        local clean = proto.sanitize_addr(clip):sub(1, 80)
        if #clean > 0 then
            lobby.lan_ip_input = clean
            M.save_prefs(lobby)
            lobby.overlay:show_toast("已粘贴局域网主机 IP：" .. clean, 2.5)
            return true
        end
    elseif field_name == "server" then
        local clean = proto.sanitize_addr(clip):sub(1, 80)
        if #clean > 0 then
            lobby.server_input = clean
            M.save_prefs(lobby)
            lobby.overlay:show_toast("已粘贴服务器/映射地址：" .. clean, 3.0)
            return true
        end
    elseif field_name == "code" then
        local clean = clip:upper():gsub("[^%dA-Z]", ""):sub(1, 6)
        if #clean > 0 then lobby.code_input = clean; return true end
    elseif field_name == "pw" then
        local clean = clip:gsub("[^%w%-%_@#]", ""):sub(1, 16)
        if #clean > 0 then lobby.pw_input = clean; return true end
    elseif field_name == "sakura_token" then
        if lobby.sakura then
            local clean = lobby.sakura:set_token(clip)
            if #clean >= 8 then
                M.save_prefs(lobby)
                lobby.overlay:show_toast("已粘贴樱花访问密钥（已隐藏显示），正在同步账号与节点...", 2.8)
                lobby.sakura:refresh_api()
                return true
            end
            lobby.overlay:show_toast("剪贴板内容不像有效的樱花访问密钥（长度不足）。", 2.8)
            return false
        end
    end
    lobby.overlay:show_toast("剪贴板里未识别到有效地址，请重新复制。", 2.8)
    return false
end

function M.load_saved_session(lobby)
    local f = io.open(get_session_path(), "r")
    if not f then
        lobby.saved_session = nil
        return nil
    end
    local raw = f:read("*a")
    f:close()
    local obj = proto.decode(raw)
    if type(obj) == "table" then
        if obj.mode == "direct" and obj.host and obj.port and obj.match_id then
            lobby.saved_session = obj
            return obj
        elseif obj.code and obj.token and obj.server and obj.pid then
            obj.mode = obj.mode or "online"
            lobby.saved_session = obj
            return obj
        end
    end
    lobby.saved_session = nil
    return nil
end

function M.save_online_session(lobby, code, pid, token)
    if not code or not token then return end
    local sess = {
        mode = "online",
        server = lobby.transport:get_server_addr() or lobby.server_input,
        code = code,
        pid = pid,
        token = token,
        level_idx = lobby.room and lobby.room.level_idx or 101,
    }
    lobby.saved_session = sess
    local f = io.open(get_session_path(), "w")
    if f then
        f:write(proto.encode(sess))
        f:flush()
        f:close()
    end
end

function M.save_direct_session(lobby, host, port, match_id, level_idx)
    if not host or not match_id then return end
    local sess = {
        mode = "direct",
        host = tostring(host),
        port = tonumber(port) or proto.DEFAULT_TCP_PORT,
        match_id = tostring(match_id),
        pid = 2,
        level_idx = tonumber(level_idx) or (lobby.room and lobby.room.level_idx) or 101,
    }
    lobby.saved_session = sess
    local f = io.open(get_session_path(), "w")
    if f then
        f:write(proto.encode(sess))
        f:flush()
        f:close()
    end
end

function M.clear_saved_session(lobby)
    lobby.saved_session = nil
    pcall(os.remove, get_session_path())
end

return M

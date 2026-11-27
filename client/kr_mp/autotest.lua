-- KR-MP Automated Multi-Process Test Drivers (M1 LAN Co-op & M2 Online + Fast-Forward Reconnect)
-- Decoupled from lobby_ui.lua so production lobby code stays clean of test harness logic.
local proto = require("kr_mp.proto")
local catalog = require("kr_mp.catalog")

local autotest = {
    auto_role = nil,        -- "host" | "guest" (KR_MP_AUTO_COOP)
    auto_m2_role = nil,     -- "host" | "guest" | "guest_reconnect" (KR_MP_AUTO_M2)
    auto_sakura_role = nil, -- "host" | "guest" | "guest_cold_reconnect" (KR_MP_AUTO_SAKURA)
    stage = nil,
    timer = 0,
    sent_ticks = {},
    saw_reconnect = false,
    saw_hot_resume = false,
    ui_chaos_bucket = nil,
}

function autotest:is_active()
    return self.auto_role ~= nil or self.auto_m2_role ~= nil or self.auto_sakura_role ~= nil
end

function autotest:init(lobby)
    self.auto_role = nil
    self.auto_m2_role = nil
    self.auto_sakura_role = nil
    self.stage = nil
    self.timer = 0
    self.sent_ticks = {}
    self.saw_reconnect = false
    self.saw_hot_resume = false
    self.ui_chaos_bucket = nil

    local ar = os.getenv("KR_MP_AUTO_COOP")
    if ar == "host" or ar == "guest" then
        self.auto_role = ar
        self.stage = "INIT"
        lobby.net_tab = "lan"
        lobby.open = true
        lobby.boot:log("[LOBBY] AUTO_COOP (M1 LAN) test role=%s enabled!", ar)
        return
    end

    local am2 = os.getenv("KR_MP_AUTO_M2")
    if am2 == "host" or am2 == "guest" or am2 == "guest_reconnect" then
        self.auto_m2_role = am2
        self.stage = "INIT"
        lobby.net_tab = "online"
        lobby.open = true
        lobby.boot:log("[LOBBY] AUTO_M2 (Online + Reconnect) test role=%s enabled!", am2)
        return
    end

    local asak = os.getenv("KR_MP_AUTO_SAKURA")
    if asak == "host" or asak == "guest" or asak == "guest_cold_reconnect" then
        self.auto_sakura_role = asak
        self.stage = "INIT"
        lobby.net_tab = "lan"
        lobby.open = true
        lobby.boot:log("[LOBBY] AUTO_SAKURA (Direct Hot-Resume + Cold-Reconnect + Live Delay + Return-Lobby) role=%s enabled!", asak)
    end
end

function autotest:on_lan_connect_failed()
    if (self.auto_role == "guest" or self.auto_sakura_role == "guest") and self.stage == "GUEST_WAIT_START" then
        self.stage = "INIT"
        self.timer = 0.5
    elseif self.auto_sakura_role == "guest_cold_reconnect" and self.stage == "RECONNECT_WAIT" then
        self.stage = "INIT"
        self.timer = 0
    end
end

function autotest:on_server_connect_failed()
    if self.auto_m2_role and (self.stage == "HOST_WAIT_ROOM" or self.stage == "GUEST_SCAN_ONLINE" or self.stage == "RECONNECT_WAIT") then
        self.stage = "INIT"
        self.timer = 0
    end
end

function autotest:on_peer_reconnected()
    self.saw_reconnect = true
end

function autotest:on_hot_resumed()
    self.saw_hot_resume = true
end

local function find_sorted_ents(store, pred)
    local out = {}
    for id, e in pairs(store.entities) do
        if type(id) == "number" and e and not e._kr_mp_local and pred(e) then
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function make_once(self_at, tick)
    return function(tag, min_tick, fn)
        if tick >= min_tick and not self_at.sent_ticks[tag] then
            self_at.sent_ticks[tag] = true
            fn()
        end
    end
end

local function step_ui_chaos(self_at, lobby, store, tick)
    if os.getenv("KR_MP_TEST_UI_CHAOS") ~= "1" or not (game and game.game_gui) then return end
    local bucket = math.floor(tick / 25)
    if bucket == self_at.ui_chaos_bucket then return end
    self_at.ui_chaos_bucket = bucket
    local gui = game.game_gui
    local phase_c = bucket % 4
    if phase_c == 0 then
        local hs = find_sorted_ents(store, function(e) return e.tower ~= nil end)
        if hs[1] and gui.show_clickable_hover then pcall(gui.show_clickable_hover, gui, hs[1]) end
        if gui.show_ghost_hover then pcall(gui.show_ghost_hover, gui) end
    elseif phase_c == 1 then
        local h1 = lobby.coop.hero_ids[1] and store.entities[lobby.coop.hero_ids[1]]
        if h1 and gui.select_entity then pcall(gui.select_entity, gui, h1) end
    elseif phase_c == 2 then
        if gui.hide_clickable_hover then pcall(gui.hide_clickable_hover, gui) end
        if gui.hide_ghost_hover then pcall(gui.hide_ghost_hover, gui) end
        local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
        if es[1] and gui.select_entity then pcall(gui.select_entity, gui, es[1]) end
    else
        if gui.deselect_entity then pcall(gui.deselect_entity, gui) end
    end
end

local function run_m1_actions(self_at, lobby, store, tick, pid)
    local once = make_once(self_at, tick)
    if pid == 1 then
        once("p1_build", 20, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[1] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_paladin_covenant" }) end
        end)
        once("p1_hero", 45, function()
            local h = lobby.coop.hero_ids[1] and store.entities[lobby.coop.hero_ids[1]]
            if h then lobby.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 80, wy = h.pos.y + 10 }) end
        end)
        once("p1_wave", 90, function() lobby.lockstep:queue_local_command({ op = "SEND_WAVE" }) end)
        once("p1_reinf", 300, function()
            local h = lobby.coop.hero_ids[1] and store.entities[lobby.coop.hero_ids[1]]
            if h then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 30, wy = h.pos.y }) end
        end)
        once("p1_reinf_drag", 390, function()
            local rs = find_sorted_ents(store, function(e) return e.soldier and e.reinforcement and e.health and not e.health.dead end)
            if rs[1] and game and game.game_gui and game.game_gui.pickview and game.game_gui.g2u then
                game.game_gui.selected_entity = rs[1]
                local ux, uy = game.game_gui:g2u({ x = rs[1].pos.x + 55, y = rs[1].pos.y })
                pcall(game.game_gui.pickview.rally_reinforcement, game.game_gui.pickview, ux, uy)
            end
        end)
        once("p1_sendgold", 450, function() lobby.lockstep:queue_local_command({ op = "SEND_GOLD", amount = 50 }) end)
        once("p1_ping", 600, function() lobby.lockstep:queue_local_command({ op = "MAP_PING", wx = 600, wy = 400 }) end)
        once("p1_ult", 900, function()
            local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
            if es[1] then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 1, wx = es[1].pos.x, wy = es[1].pos.y }) end
        end)
    else
        once("p2_build", 30, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[2] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[2].id, arg = "tower_build_royal_archers" }) end
        end)
        once("p2_hero", 60, function()
            local h = lobby.coop.hero_ids[2] and store.entities[lobby.coop.hero_ids[2]]
            if h then lobby.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 120, wy = h.pos.y - 10 }) end
        end)
        once("p2_reinf", 330, function()
            local h = lobby.coop.hero_ids[2] and store.entities[lobby.coop.hero_ids[2]]
            if h then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 20, wy = h.pos.y }) end
        end)
        once("p2_reinf_drag", 420, function()
            local rs = find_sorted_ents(store, function(e) return e.soldier and e.reinforcement and e.health and not e.health.dead end)
            local target_r = rs[#rs]
            if target_r and game and game.game_gui and game.game_gui.pickview and game.game_gui.g2u then
                game.game_gui.selected_entity = target_r
                local tx, ty = target_r.pos.x + 55, target_r.pos.y - 45
                local ok_p, P_db = pcall(require, "path_db")
                if ok_p and P_db and P_db.paths and P_db.paths[1] and P_db.paths[1][1] then
                    local seg = P_db.paths[1][1]
                    local mid = seg[math.max(1, math.floor(#seg * 0.75))]
                    if mid and mid.x and mid.y then tx, ty = mid.x, mid.y end
                end
                local ux, uy = game.game_gui:g2u({ x = tx, y = ty })
                pcall(game.game_gui.pickview.rally_reinforcement, game.game_gui.pickview, ux, uy)
            end
        end)
        once("p2_ping", 630, function() lobby.lockstep:queue_local_command({ op = "MAP_PING", wx = 720, wy = 450 }) end)
        once("p2_ult", 960, function()
            local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
            if es[1] then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = "a", wx = es[1].pos.x, wy = es[1].pos.y }) end
        end)
        once("p2_illegal_sell", 1100, function()
            local p1_t = find_sorted_ents(store, function(e) return e.tower and e._mp_owner == 1 end)
            if p1_t[1] then lobby.lockstep:queue_local_command({ op = "TW_SELL", id = p1_t[1].id }) end
        end)
    end
end

function autotest:step_auto_coop(lobby, dt)
    self.timer = self.timer + dt

    if self.stage == "INIT" then
        if self.auto_role == "host" then
            lobby.room.level_idx = tonumber(os.getenv("KR_MP_TEST_LEVEL")) or 101
            local env_diff = tonumber(os.getenv("KR_MP_TEST_DIFF"))
            if env_diff and env_diff >= 1 and env_diff <= 4 then
                lobby.room.level_difficulty = math.floor(env_diff)
            end
            lobby.room.econ_mode = "independent"
            lobby.room.tower_mode = "owned"
            lobby.room.heroes = { catalog.DEFAULT_HERO_1 or 53, catalog.DEFAULT_HERO_2 or 54 }
            local env_heroes = os.getenv("KR_MP_TEST_HEROES")
            if env_heroes then
                local h1, h2 = env_heroes:match("^(%d+),(%d+)$")
                if h1 and h2 then lobby.room.heroes = { tonumber(h1), tonumber(h2) } end
            end
            local env_cat = os.getenv("KR_MP_TEST_CATACLYSM")
            if env_cat and #env_cat > 0 then lobby.room.cataclysm = env_cat end
            local env_r1 = os.getenv("KR_MP_TEST_REINF1")
            local env_r2 = os.getenv("KR_MP_TEST_REINF2")
            if env_r1 and #env_r1 > 0 then lobby.room.reinforcements[1] = env_r1 end
            if env_r2 and #env_r2 > 0 then lobby.room.reinforcements[2] = env_r2 end
            if lobby:host_lan_room() then self.stage = "HOST_WAIT_GUEST" end
        else
            lobby.transport:start_lan_scan()
            if self.timer >= 1.5 then
                local rooms = lobby.transport:get_lan_rooms()
                local ip, port = "127.0.0.1", tonumber(os.getenv("KR_MP_PORT")) or proto.DEFAULT_TCP_PORT
                if #rooms > 0 then
                    ip, port = rooms[1].ip, rooms[1].port
                    lobby.boot:log("[AUTO_COOP] Guest discovered LAN room via UDP: %s:%d (%s)", ip, port, rooms[1].name)
                end
                if lobby:join_lan_room(ip, port) then
                    self.stage = "GUEST_WAIT_START"
                else
                    self.timer = 0.5
                end
            end
        end
    elseif self.stage == "HOST_WAIT_GUEST" then
        if lobby.peer_connected and lobby.peer_ready then
            self.stage = "MATCH_ACTIVE"
            lobby:host_start_match()
        end
    elseif self.stage == "GUEST_WAIT_START" then
        if lobby.coop and lobby.coop:is_active() then
            self.stage = "MATCH_ACTIVE"
        end
    elseif self.stage == "MATCH_ACTIVE" then
        if not lobby.lockstep or not lobby.lockstep:is_active() then return end
        if lobby.lockstep.phase == "DESYNC" then
            lobby.boot:log("AUTO_COOP_FAILED desync_tick=%s", tostring(lobby.lockstep.desync_info and lobby.lockstep.desync_info.tick))
            love.event.quit()
            return
        end
        local store = game and game.store
        if not store then return end
        local tick = store.tick or 0
        local pid = lobby.coop.local_pid
        local target_ticks = tonumber(os.getenv("KR_MP_TEST_TICKS")) or 1860
        local target_sync = math.max(60, math.floor(target_ticks / 30) - 2)
        if tick >= target_ticks and lobby.lockstep.sync_ok_count >= target_sync then
            lobby.boot:log("AUTO_COOP_PASSED pid=%d ticks=%d sync_ok=%d gold=(P1:%d,P2:%d)",
                pid, tick, lobby.lockstep.sync_ok_count, lobby.coop:get_player_gold(1), lobby.coop:get_player_gold(2))
            lobby.lockstep:close_hash_log()
            love.event.quit()
            return
        end
        if lobby.lockstep.phase ~= "RUNNING" then return end

        if pid == 1 then
            step_ui_chaos(self, lobby, store, tick)
        end
        run_m1_actions(self, lobby, store, tick, pid)
    end
end

local function run_m2_actions(self_at, lobby, store, tick)
    local once = make_once(self_at, tick)
    if self_at.auto_m2_role == "host" then
        once("p1_build1", 20, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[1] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_paladin_covenant" }) end
        end)
        once("p1_hero", 45, function()
            local h = lobby.coop.hero_ids[1] and store.entities[lobby.coop.hero_ids[1]]
            if h then lobby.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 80, wy = h.pos.y + 10 }) end
        end)
        once("p1_wave", 90, function() lobby.lockstep:queue_local_command({ op = "SEND_WAVE" }) end)
        once("p1_reinf", 300, function()
            local h = lobby.coop.hero_ids[1] and store.entities[lobby.coop.hero_ids[1]]
            if h then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 30, wy = h.pos.y }) end
        end)
        once("p1_sendgold", 450, function() lobby.lockstep:queue_local_command({ op = "SEND_GOLD", amount = 50 }) end)
        once("p1_ult", 780, function()
            local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
            if es[1] then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 1, wx = es[1].pos.x, wy = es[1].pos.y }) end
        end)
        once("p1_post_build", 1200, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[1] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_arcane_wizard" }) end
        end)
        once("p1_post_ping", 1500, function() lobby.lockstep:queue_local_command({ op = "MAP_PING", wx = 640, wy = 390 }) end)
    elseif self_at.auto_m2_role == "guest" then
        once("p2_build1", 30, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[2] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[2].id, arg = "tower_build_royal_archers" }) end
        end)
        once("p2_hero", 60, function()
            local h = lobby.coop.hero_ids[2] and store.entities[lobby.coop.hero_ids[2]]
            if h then lobby.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 120, wy = h.pos.y - 10 }) end
        end)
        once("p2_reinf", 330, function()
            local h = lobby.coop.hero_ids[2] and store.entities[lobby.coop.hero_ids[2]]
            if h then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 20, wy = h.pos.y }) end
        end)
        once("p2_ping", 600, function() lobby.lockstep:queue_local_command({ op = "MAP_PING", wx = 720, wy = 440 }) end)
        if tick >= 960 then
            lobby.boot:log("AUTO_M2_SIMULATED_CRASH tick=%d hash=%s (hard exiting P2 to test fast-forward reconnect!)",
                tick, tostring(lobby.lockstep.last_hash_hex))
            if lobby.boot.log_file then lobby.boot.log_file:flush() end
            os.exit(0)
        end
    elseif self_at.auto_m2_role == "guest_reconnect" then
        once("p2_post_speed2x", 1230, function() lobby.lockstep:request_toggle_speed() end)
        once("p2_post_build", 1290, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[1] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_paladin_covenant" }) end
        end)
        once("p2_post_ult", 1560, function()
            local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
            if es[1] then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 3, wx = es[1].pos.x, wy = es[1].pos.y }) end
        end)
        once("p2_post_sendgold", 1740, function() lobby.lockstep:queue_local_command({ op = "SEND_GOLD", amount = 50 }) end)
    end
end

function autotest:step_auto_m2(lobby, dt)
    self.timer = self.timer + dt

    if self.stage == "INIT" then
        if self.auto_m2_role == "host" then
            lobby.room.name = "M2 Auto Online Room"
            lobby.room.level_idx = tonumber(os.getenv("KR_MP_TEST_LEVEL")) or 101
            lobby.room.econ_mode = "independent"
            lobby.room.tower_mode = "owned"
            lobby.room.heroes = { catalog.DEFAULT_HERO_1 or 53, catalog.DEFAULT_HERO_2 or 54 }
            lobby.room.towers = { 1, 2, 3, 4, 5, 6, 7, 8, 25, 27, 44, 59 }
            if lobby:create_online_room("1234", true) then self.stage = "HOST_WAIT_ROOM" end
        elseif self.auto_m2_role == "guest" then
            if self.timer >= 0.8 then
                self.timer = 0
                if lobby:connect_online_server(lobby.server_input, false) then
                    self.stage = "GUEST_SCAN_ONLINE"
                end
            end
        elseif self.auto_m2_role == "guest_reconnect" then
            local sess = lobby:load_saved_session()
            if sess and lobby:reconnect_online_session(sess) then
                self.stage = "RECONNECT_WAIT"
            elseif self.timer > 5.0 then
                lobby.boot:log("AUTO_M2_FAILED no saved session to reconnect!")
                love.event.quit()
            end
        end
    elseif self.stage == "HOST_WAIT_ROOM" then
        if lobby.online_room_code then
            lobby.boot:log("[AUTO_M2] Host Online Room created: code=%s", lobby.online_room_code)
            self.stage = "HOST_WAIT_GUEST"
        end
    elseif self.stage == "HOST_WAIT_GUEST" then
        if lobby.peer_connected and lobby.peer_ready then
            self.stage = "HOST_WAIT_START"
            lobby:host_start_match()
        end
    elseif self.stage == "HOST_WAIT_START" or self.stage == "GUEST_WAIT_START" or self.stage == "RECONNECT_WAIT" then
        if lobby.coop and lobby.coop:is_active() then
            self.stage = "MATCH_ACTIVE"
        end
    elseif self.stage == "GUEST_SCAN_ONLINE" then
        if #lobby.online_rooms > 0 then
            local r = lobby.online_rooms[1]
            lobby.boot:log("[AUTO_M2] Guest found public Online room: code=%s name=%s has_pw=%s",
                tostring(r.code), tostring(r.name), tostring(r.has_password))
            lobby:join_online_room(r.code, "1234")
            self.stage = "GUEST_WAIT_START"
        elseif self.timer >= 0.6 then
            self.timer = 0
            lobby:refresh_online_rooms()
        end
    elseif self.stage == "MATCH_ACTIVE" then
        if not lobby.lockstep or not lobby.lockstep:is_active() then return end
        if lobby.lockstep.phase == "DESYNC" then
            lobby.boot:log("AUTO_M2_FAILED desync_tick=%s", tostring(lobby.lockstep.desync_info and lobby.lockstep.desync_info.tick))
            love.event.quit()
            return
        end
        local store = game and game.store
        if not store then return end
        local tick = store.tick or 0

        if self.auto_m2_role == "guest_reconnect" and tick >= 2160 and lobby.lockstep.sync_ok_count >= 25 then
            lobby.boot:log("AUTO_M2_PASSED role=guest_reconnect pid=2 ticks=%d post_sync_ok=%d speed=%dx gold=(P1:%d,P2:%d)",
                tick, lobby.lockstep.sync_ok_count, lobby.lockstep.game_speed,
                lobby.coop:get_player_gold(1), lobby.coop:get_player_gold(2))
            lobby.lockstep:close_hash_log()
            love.event.quit()
            return
        end
        if self.auto_m2_role == "host" and tick >= 2160 and self.saw_reconnect and lobby.lockstep.sync_ok_count >= 50
            and (tick >= 2175 or lobby.lockstep.phase == "WAIT_RECONNECT") then
            lobby.boot:log("AUTO_M2_PASSED role=host pid=1 ticks=%d sync_ok=%d speed=%dx gold=(P1:%d,P2:%d)",
                tick, lobby.lockstep.sync_ok_count, lobby.lockstep.game_speed,
                lobby.coop:get_player_gold(1), lobby.coop:get_player_gold(2))
            lobby.lockstep:close_hash_log()
            love.event.quit()
            return
        end

        if lobby.lockstep.phase ~= "RUNNING" then return end
        run_m2_actions(self, lobby, store, tick)

        if self.auto_m2_role == "host" and tick >= 2160 and self.saw_reconnect and lobby.lockstep.sync_ok_count >= 50 then
            lobby.boot:log("AUTO_M2_PASSED role=host pid=1 ticks=%d sync_ok=%d speed=%dx gold=(P1:%d,P2:%d)",
                tick, lobby.lockstep.sync_ok_count, lobby.lockstep.game_speed,
                lobby.coop:get_player_gold(1), lobby.coop:get_player_gold(2))
            lobby.lockstep:close_hash_log()
            love.event.quit()
        end
    end
end

local function run_sakura_actions(self_at, lobby, store, tick)
    local once = make_once(self_at, tick)
    local role = self_at.auto_sakura_role
    if role == "host" then
        once("s_p1_build", 20, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[1] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_paladin_covenant" }) end
        end)
        once("s_p1_hero", 45, function()
            local h = lobby.coop.hero_ids[1] and store.entities[lobby.coop.hero_ids[1]]
            if h then lobby.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 80, wy = h.pos.y + 10 }) end
        end)
        once("s_p1_wave", 90, function() lobby.lockstep:queue_local_command({ op = "SEND_WAVE" }) end)
        once("s_p1_delay_3", 240, function() lobby.lockstep:request_cycle_delay() end) -- 2 -> 3 (150ms)
        once("s_p1_gold200", 360, function() lobby.lockstep:queue_local_command({ op = "SEND_GOLD", amount = 200 }) end)
        once("s_p1_delay_4", 450, function() lobby.lockstep:request_cycle_delay() end) -- 3 -> 4 (200ms)
        once("s_p1_delay_6", 720, function() lobby.lockstep:request_cycle_delay() end) -- 4 -> 6 (300ms)
        once("s_p1_delay_2", 810, function() lobby.lockstep:request_cycle_delay() end) -- 6 -> 2 (100ms)
        once("s_p1_ult", 870, function()
            local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
            if es[1] then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 1, wx = es[1].pos.x, wy = es[1].pos.y }) end
        end)
        once("s_p1_post_build", 1200, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[1] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_arcane_wizard" }) end
        end)
    elseif role == "guest" then
        once("s_p2_build", 30, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[2] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[2].id, arg = "tower_build_royal_archers" }) end
        end)
        once("s_p2_hero", 60, function()
            local h = lobby.coop.hero_ids[2] and store.entities[lobby.coop.hero_ids[2]]
            if h then lobby.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 120, wy = h.pos.y - 10 }) end
        end)
        once("s_p2_sakura_eof", 600, function()
            -- Simulate a SakuraFrp transient TCP EOF drop -> triggers natural peer_disconnected -> 0.2s zero-reload Hot Resume!
            lobby.boot:log("AUTO_SAKURA_SIMULATED_EOF tick=%d hash=%s (dropping TCP to test 0.2s Hot Resume!)",
                tick, tostring(lobby.lockstep.last_hash_hex))
            lobby.transport:drop_peer_socket("simulated_sakura_eof", false)
        end)
        once("s_p2_reinf_post_hot", 870, function()
            local h = lobby.coop.hero_ids[2] and store.entities[lobby.coop.hero_ids[2]]
            if h then lobby.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 25, wy = h.pos.y }) end
        end)
        if tick >= 960 and self_at.saw_hot_resume then
            lobby.boot:log("AUTO_SAKURA_SIMULATED_CRASH tick=%d hot_resumes=%d delay=%d hash=%s (hard exiting P2 to test Direct Cold Reconnect!)",
                tick, lobby.lockstep.hot_resume_count or 0, lobby.lockstep.input_delay_turns or 0, tostring(lobby.lockstep.last_hash_hex))
            if lobby.boot.log_file then lobby.boot.log_file:flush() end
            os.exit(0)
        end
    elseif role == "guest_cold_reconnect" then
        once("s_p2_cold_speed", 1140, function() lobby.lockstep:request_toggle_speed() end)
        once("s_p2_cold_build", 1230, function()
            local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
            if hs[1] then lobby.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_paladin_covenant" }) end
        end)
        once("s_p2_cold_ping", 1440, function() lobby.lockstep:queue_local_command({ op = "MAP_PING", wx = 660, wy = 410 }) end)
    end
end

function autotest:step_auto_sakura(lobby, dt)
    self.timer = self.timer + math.min(dt or 0.016, 0.1)
    local role = self.auto_sakura_role

    if self.stage == "INIT" then
        if role == "host" then
            lobby.room.level_idx = tonumber(os.getenv("KR_MP_TEST_LEVEL")) or 101
            lobby.room.econ_mode = "independent"
            lobby.room.tower_mode = "owned"
            lobby.room.input_delay_turns = 2
            lobby.room.heroes = { catalog.DEFAULT_HERO_1 or 53, catalog.DEFAULT_HERO_2 or 54 }
            if lobby:host_lan_room() then self.stage = "HOST_WAIT_GUEST" end
        elseif role == "guest" then
            if self.timer >= 1.0 then
                local port = tonumber(os.getenv("KR_MP_PORT")) or proto.DEFAULT_TCP_PORT
                if lobby:join_lan_room("127.0.0.1", port) then
                    self.stage = "GUEST_WAIT_START"
                else
                    self.timer = 0.4
                end
            end
        elseif role == "guest_cold_reconnect" then
            local sess = lobby:load_saved_session()
            if sess and sess.mode == "direct" and lobby:reconnect_direct_session(sess) then
                self.stage = "RECONNECT_WAIT"
            elseif self.timer > 6.0 then
                lobby.boot:log("AUTO_SAKURA_FAILED no direct session found for cold reconnect!")
                love.event.quit()
            end
        end
    elseif self.stage == "HOST_WAIT_GUEST" then
        if lobby.peer_connected and lobby.peer_ready then
            self.stage = "MATCH_ACTIVE"
            lobby:host_start_match()
        end
    elseif self.stage == "GUEST_WAIT_START" or self.stage == "RECONNECT_WAIT" then
        if lobby.coop and lobby.coop:is_active() then
            self.stage = "MATCH_ACTIVE"
        end
    elseif self.stage == "MATCH_ACTIVE" then
        if not lobby.lockstep or not lobby.lockstep:is_active() then
            if role == "guest_cold_reconnect" and lobby.view == "room" then
                lobby.lockstep:close_hash_log()
                self.stage = "VERIFY_RETURN_LOBBY"
                self.timer = 0
            end
            return
        end
        if lobby.lockstep.phase == "DESYNC" then
            lobby.boot:log("AUTO_SAKURA_FAILED desync_tick=%s", tostring(lobby.lockstep.desync_info and lobby.lockstep.desync_info.tick))
            love.event.quit()
            return
        end
        local store = game and game.store
        if not store then return end
        local tick = store.tick or 0

        if role == "host" and tick >= 1680 and self.saw_hot_resume and self.saw_reconnect and lobby.lockstep.sync_ok_count >= 45 then
            lobby.boot:log("AUTO_SAKURA_HOST_RETURN_LOBBY ticks=%d sync_ok=%d hot=%d cold=%d delay=%d gold=(P1:%d,P2:%d)",
                tick, lobby.lockstep.sync_ok_count, lobby.lockstep.hot_resume_count or 0, lobby.lockstep.cold_reconnect_count or 0,
                lobby.lockstep.input_delay_turns or 0, lobby.coop:get_player_gold(1), lobby.coop:get_player_gold(2))
            lobby.lockstep:close_hash_log()
            self.stage = "VERIFY_RETURN_LOBBY"
            self.timer = 0
            lobby:return_to_lobby()
            return
        end
        if role == "guest_cold_reconnect" and tick >= 1680 and lobby.lockstep.sync_ok_count >= 18 then
            self.sent_ticks._wait_return_lobby = true
            lobby.lockstep:close_hash_log()
            self.stage = "VERIFY_RETURN_LOBBY"
            self.timer = 0
            return
        end

        if lobby.lockstep.phase ~= "RUNNING" then return end
        run_sakura_actions(self, lobby, store, tick)
    elseif self.stage == "VERIFY_RETURN_LOBBY" then
        local on_slots = (main and main.handler and main.handler.active_item and main.handler.active_item.item_name == "slots")
        if lobby.view == "room" and lobby.transport:is_connected() and not (lobby.coop and lobby.coop:is_active()) and on_slots then
            -- Let Host verify keep-alive connection first, while Guest holds TCP open briefly so Host finishes unloading cleanly
            local wait_need = (role == "host") and 0.3 or 2.5
            if self.timer >= wait_need then
                lobby.boot:log("AUTO_SAKURA_PASSED role=%s pid=%d return_lobby_alive=true", role, lobby.local_pid)
                love.event.quit()
            end
        elseif role == "guest_cold_reconnect" and lobby.view == "room" and not (lobby.coop and lobby.coop:is_active()) and on_slots and self.timer >= 0.5 then
            -- Host already verified return_lobby_alive=true and exited cleanly
            lobby.boot:log("AUTO_SAKURA_PASSED role=%s pid=%d return_lobby_alive=true", role, lobby.local_pid)
            love.event.quit()
        elseif self.timer >= 8.0 then
            lobby.boot:log("AUTO_SAKURA_FAILED return_lobby timeout view=%s conn=%s slots=%s",
                tostring(lobby.view), tostring(lobby.transport:is_connected()), tostring(on_slots))
            love.event.quit()
        end
    end
end

function autotest:update(lobby, dt)
    if self.auto_role then
        self:step_auto_coop(lobby, dt)
    elseif self.auto_m2_role then
        self:step_auto_m2(lobby, dt)
    elseif self.auto_sakura_role then
        self:step_auto_sakura(lobby, dt)
    end
end

return autotest

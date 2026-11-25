-- KR-MP 2P Co-op Gameplay Layer (M1)
-- Manages: Dual-hero ownership, independent/shared gold ledger, red/blue tower ownership,
-- independent reinforcements cooldowns, gold transfer, map pings, and world-space overlays.
local signal = require("hump.signal")
local E = require("entity_db")
local km = require("klua.macros")
local fonts = require("kr_mp.fonts")
local catalog = require("kr_mp.catalog")

local coop = {
    boot = nil,
    lockstep = nil,
    overlay = nil,

    active = false,
    local_pid = 1,
    cfg = nil,
    slot_snapshot = nil,

    econ_mode = "independent", -- "independent" | "shared"
    tower_mode = "owned",      -- "owned" | "open"

    gold = { [1] = 0, [2] = 0 },
    shared_gold = 0,
    gold_split_parity = 0,

    hero_ids = { [1] = nil, [2] = nil },
    reinf_ready_tick = { [1] = 0, [2] = 0 },

    pings = {}, -- { { wx, wy, pid, start_ts, end_ts }, ... }
    signal_registered = false,
    _pending_tower_ops = nil,
    show_tower_marks = true, -- Local-only visual toggle for 1P/2P pedestal arc & mini badge
}

-- Curated Alliance / FL 5th-gen dual-hero roster for Lobby selection
coop.HERO_ROSTER = {
    { idx = 48, name = "Vesper",    tpl = "hero_vesper" },
    { idx = 49, name = "Raelyn",    tpl = "hero_raelyn" },
    { idx = 50, name = "Nyru",      tpl = "hero_muyrn" },
    { idx = 51, name = "Grimson",   tpl = "hero_venom" },
    { idx = 52, name = "Torres",    tpl = "hero_builder" },
    { idx = 53, name = "Onagro",    tpl = "hero_robot" },
    { idx = 54, name = "Therien",   tpl = "hero_space_elf" },
    { idx = 55, name = "Warhead",   tpl = "hero_mecha" },
    { idx = 56, name = "Lumenir",   tpl = "hero_lumenir" },
    { idx = 58, name = "Kosmyr",    tpl = "hero_dragon_gem" },
    { idx = 60, name = "Bonehart",  tpl = "hero_dragon_bone" },
    { idx = 65, name = "Eiskalt",   tpl = "hero_eiskalt" },
    { idx = 66, name = "Dianyun",   tpl = "hero_dianyun" },
}

coop.LEVEL_PRESETS = {
    { idx = 101, label = "KR5-101 Sea of Trees 1" },
    { idx = 102, label = "KR5-102 Sea of Trees 2" },
    { idx = 103, label = "KR5-103 Sea of Trees 3" },
    { idx = 104, label = "KR5-104 Sea of Trees 4" },
    { idx = 1,   label = "KR3-01 Elven Woods 1" },
    { idx = 2,   label = "KR3-02 Elven Woods 2" },
    { idx = 3,   label = "KR3-03 Elven Woods 3" },
}

local function deep_copy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, val in pairs(v) do
        if type(k) ~= "function" and type(val) ~= "function" and type(val) ~= "userdata" and type(val) ~= "thread" then
            out[deep_copy(k, seen)] = deep_copy(val, seen)
        end
    end
    return out
end

function coop:init(boot, lockstep, overlay)
    self.boot = boot
    self.lockstep = lockstep
    self.overlay = overlay

    if not self.signal_registered then
        self.signal_registered = true
        signal.register("tower-upgraded", function(ne, e)
            if self.active and ne and e then
                local owner = e._mp_owner or (e.tower and e.tower._mp_actor)
                if owner then
                    ne._mp_owner = owner
                end
            end
        end)
    end
end

function coop:log(fmt, ...)
    if self.boot and self.boot.log then
        self.boot:log("[COOP] " .. fmt, ...)
    end
end

function coop:is_active()
    return self.active
end

function coop:get_slot_override()
    if self.active and self.slot_snapshot then
        return deep_copy(self.slot_snapshot)
    end
    return nil
end

function coop:build_host_slot_snapshot(heroes, towers)
    local storage = require("storage")
    if not storage:load_slot(1) then
        storage:create_slot(1)
    end
    storage:set_active_slot(1)
    local raw = storage:load_slot(nil, true) or {}
    local snap = deep_copy(raw)

    -- Keep packet compact by trimming bulky history tables not needed during battle
    snap.seen = snap.seen or {}
    snap.bag = snap.bag or {}
    snap.upgrades = snap.upgrades or {
        archers = 0, barracks = 0, mages = 0, engineers = 0, reinforcements = 0, rain = 0
    }
    snap.heroes = snap.heroes or { selected = "hero_vesper", status = {} }
    snap.heroes.status = snap.heroes.status or {}

    -- Apply room's custom tower deck (1..41, up to 12 towers)
    local deck = {}
    if type(towers) == "table" and #towers > 0 then
        local seen_t = {}
        for i = 1, math.min(#towers, 12) do
            local tid = tonumber(towers[i])
            if tid and tid >= 1 and tid <= 41 and not seen_t[tid] then
                seen_t[tid] = true
                deck[#deck + 1] = tid
            end
        end
    end
    if #deck == 0 then
        for i = 1, #catalog.DEFAULT_TOWERS do
            deck[i] = catalog.DEFAULT_TOWERS[i]
        end
    end
    snap.towers = deck
    snap.tower_pick = #deck
    snap.liuhui = snap.liuhui or {
        use3tower = true,
        impossiblerate = 1.5,
        cheat = false,
        cheat5 = false,
        cheathero = false,
        g3_hprate = false,
        balance = false,
        enemy_count = 1,
        g5_hero_dark_count = 2,
        cp_mode = false,
    }
    -- Force dual-hero mode with the room's exact 2 selected heroes!
    local h1 = (heroes and heroes[1]) or 48
    local h2 = (heroes and heroes[2]) or 49
    snap.liuhui_hero = {
        usedoublehero = true,
        herolist = { [1] = h1, [2] = h2 },
    }
    -- Ensure both chosen heroes have valid status entries
    local ok_md, map_data = pcall(require, "data.map_data")
    if ok_md and map_data and map_data.hero_data then
        for _, hidx in ipairs({ h1, h2 }) do
            local hd = map_data.hero_data[hidx]
            if hd and hd.name and not snap.heroes.status[hd.name] then
                snap.heroes.status[hd.name] = {
                    xp = 0,
                    skills = { ultimate = 1 },
                }
            end
        end
    end
    return snap
end

function coop:prepare_match(local_pid, cfg, reconnect_data)
    self.active = true
    self.local_pid = local_pid
    self.cfg = deep_copy(cfg)
    self.slot_snapshot = deep_copy(cfg.slot_snapshot)
    self.econ_mode = cfg.econ_mode or "independent"
    self.tower_mode = cfg.tower_mode or "owned"
    self.gold = { [1] = 0, [2] = 0 }
    self.shared_gold = 0
    self.gold_split_parity = 0
    self.hero_ids = { [1] = nil, [2] = nil }
    self.reinf_ready_tick = { [1] = 0, [2] = 0 }
    self.pings = {}

    if self.lockstep then
        if reconnect_data then
            self.lockstep:begin_reconnect(local_pid, cfg, reconnect_data)
        else
            self.lockstep:begin_loading(local_pid, cfg)
        end
    end

    -- Ensure active slot exists and trigger FL director to load the exact target level + hero atlases
    local storage = require("storage")
    if not storage:load_slot(1) then
        storage:create_slot(1)
    end
    storage:set_active_slot(1)

    if screen_map == nil then
        screen_map = { user_data = deep_copy(self.slot_snapshot) }
    else
        screen_map.user_data = deep_copy(self.slot_snapshot)
    end

    if main and main.handler then
        self:log("Scheduling synced Co-op level=%d mode=%d diff=%d econ=%s tower=%s heroes=(%s,%s)",
            cfg.level_idx or 101, cfg.level_mode or 1, cfg.level_difficulty or 2,
            self.econ_mode, self.tower_mode,
            tostring(cfg.heroes and cfg.heroes[1]), tostring(cfg.heroes and cfg.heroes[2]))
        self._pending_launch_args = {
            level_idx = cfg.level_idx or 101,
            level_mode = cfg.level_mode or 1,
            level_difficulty = cfg.level_difficulty or 2,
        }
        self:try_launch_pending()
    end
end

-- Wait until director has finished any in-flight screen load (e.g. initial 'slots' atlas threads)
-- before queueing 'game', avoiding FL image_db's active-thread QUIT race.
function coop:try_launch_pending()
    if not self._pending_launch_args or not main or not main.handler then return end
    local h = main.handler
    if h.active_item ~= nil and h.queued_item == nil and h.next_item_name == nil then
        local args = self._pending_launch_args
        self._pending_launch_args = nil
        self:log("Launching synced Co-op level=%d (director ready, active=%s)",
            args.level_idx or 101, tostring(h.active_item.item_name))
        h.next_item_name = "game"
        h.next_item_args = args
    end
end

function coop:leave_match()
    self._pending_launch_args = nil
    self.active = false
    self.cfg = nil
    self.slot_snapshot = nil
    self.pings = {}
    if self.lockstep then
        self.lockstep:reset()
    end
    if game and game.store then
        game.store.paused = false
    end
end

function coop:on_before_sim_init(store)
    if not self.active or not self.cfg then return end
    local prng = require("kr_mp.prng")
    prng:seed_sim(self.cfg.seed or 123456)
    self.hero_ids = { [1] = nil, [2] = nil }
    self.reinf_ready_tick = { [1] = 0, [2] = 0 }
    self.pings = {}
    self.gold_split_parity = 0
end

function coop:on_after_sim_init(store)
    if not self.active or not self.cfg then return end

    -- 1. Initialize deterministic gold balances
    local init_g = math.floor((store.player_gold or 300) + 0.5)
    if self.econ_mode == "independent" then
        self.gold[1] = math.ceil(init_g / 2)
        self.gold[2] = math.floor(init_g / 2)
        self.shared_gold = init_g
    else
        self.shared_gold = init_g
        self.gold[1] = init_g
        self.gold[2] = init_g
    end

    -- 2. Discover spawned heroes in deterministic ascending ID order (Hero 1 -> P1, Hero 2 -> P2)
    -- Note: some heroes are in pending_inserts right after sim:init before first do_tick
    local heroes = {}
    local seen_ids = {}
    for _, e in pairs(store.entities) do
        if e and e.hero and e.id and not seen_ids[e.id] then
            seen_ids[e.id] = true
            heroes[#heroes + 1] = e
        end
    end
    for _, e in ipairs(store.pending_inserts or {}) do
        if e and e.hero and e.id and not seen_ids[e.id] then
            seen_ids[e.id] = true
            heroes[#heroes + 1] = e
        end
    end
    table.sort(heroes, function(a, b) return a.id < b.id end)
    if heroes[1] then
        self.hero_ids[1] = heroes[1].id
        heroes[1]._mp_owner = 1
    end
    if heroes[2] then
        self.hero_ids[2] = heroes[2].id
        heroes[2]._mp_owner = 2
    end

    -- Sync local display gold immediately
    store.player_gold = self:get_local_display_gold()

    -- Hold simulation paused at tick 0 until BOTH peers complete LOAD_DONE -> BEGIN_SIM
    store.paused = true

    self:log("Co-op sim ready: init_gold=%d (P1=%d P2=%d) heroes=(P1:%s, P2:%s)",
        init_g, self.gold[1], self.gold[2], tostring(self.hero_ids[1]), tostring(self.hero_ids[2]))
end

function coop:on_game_ready()
    if not self.active then return end
    if self.lockstep then
        self.lockstep:on_local_loaded()
    end
end

function coop:on_entity_inserted(e)
    if not self.active or not e or not e.hero or not e.id or e._kr_mp_local then return end
    if not self.hero_ids[1] then
        self.hero_ids[1] = e.id
        e._mp_owner = 1
        self:log("Registered P1 Hero: id=%d tpl=%s", e.id, tostring(e.template_name))
    elseif self.hero_ids[1] ~= e.id and not self.hero_ids[2] then
        self.hero_ids[2] = e.id
        e._mp_owner = 2
        self:log("Registered P2 Hero: id=%d tpl=%s", e.id, tostring(e.template_name))
    end
end

-- === Economy Ledger Helpers ===

function coop:get_player_gold(pid)
    if self.econ_mode == "shared" then
        return self.shared_gold
    end
    return self.gold[pid] or 0
end

function coop:get_canonical_gold()
    if self.econ_mode == "shared" then
        return self.shared_gold
    end
    return (self.gold[1] or 0) + (self.gold[2] or 0)
end

function coop:get_local_display_gold()
    return self:get_player_gold(self.local_pid)
end

function coop:can_afford(pid, amount)
    return self:get_player_gold(pid) >= (amount or 0)
end

function coop:spend_gold(pid, amount)
    amount = math.floor((amount or 0) + 0.5)
    if amount <= 0 then return true end
    if self.econ_mode == "shared" then
        self.shared_gold = math.max(0, self.shared_gold - amount)
        self.gold[1] = self.shared_gold
        self.gold[2] = self.shared_gold
    else
        self.gold[pid] = math.max(0, (self.gold[pid] or 0) - amount)
    end
    return true
end

function coop:add_player_gold(pid, amount)
    amount = math.floor((amount or 0) + 0.5)
    if amount <= 0 then return end
    if self.econ_mode == "shared" then
        self.shared_gold = self.shared_gold + amount
        self.gold[1] = self.shared_gold
        self.gold[2] = self.shared_gold
    else
        self.gold[pid] = (self.gold[pid] or 0) + amount
    end
end

function coop:add_shared_income(amount)
    amount = math.floor((amount or 0) + 0.5)
    if amount <= 0 then return end
    if self.econ_mode == "shared" then
        self.shared_gold = self.shared_gold + amount
        self.gold[1] = self.shared_gold
        self.gold[2] = self.shared_gold
    else
        local half = math.floor(amount / 2)
        local rem = amount - half * 2
        local p1_add = half
        local p2_add = half
        if rem > 0 then
            if self.gold_split_parity == 0 then
                p1_add = p1_add + 1
                self.gold_split_parity = 1
            else
                p2_add = p2_add + 1
                self.gold_split_parity = 0
            end
        end
        self.gold[1] = (self.gold[1] or 0) + p1_add
        self.gold[2] = (self.gold[2] or 0) + p2_add
    end
end

function coop:transfer_gold(from_pid, amount)
    if self.econ_mode ~= "independent" then return 0 end
    local to_pid = (from_pid == 1) and 2 or 1
    local avail = self.gold[from_pid] or 0
    local actual = math.min(avail, math.max(0, math.floor(amount or 0)))
    if actual > 0 then
        self.gold[from_pid] = avail - actual
        self.gold[to_pid] = (self.gold[to_pid] or 0) + actual
        local catching = self.lockstep and self.lockstep:is_catching_up()
        if self.overlay and not catching then
            self.overlay:show_toast(string.format("%dP 向 %dP 转账了 %d 金币！", from_pid, to_pid, actual), 3.0)
        end
    end
    return actual
end

-- === Ownership & Permission Checks ===

function coop:get_upgrade_price(e, upgrade_to)
    if not e or not upgrade_to then return 0 end
    local ne = E:get_template(upgrade_to)
    if not ne or not ne.tower then return 0 end
    local price = ne.tower.price or 0
    if ne.tower.type == "build_animation" and ne.build_name then
        local bt = E:get_template(ne.build_name)
        price = (bt and bt.tower and bt.tower.price) or 0
    elseif e.tower and e.tower.type == "build_animation" then
        price = 0
    elseif e.tower_holder and (e.tower_holder.unblock_price or 0) > 0 then
        price = e.tower_holder.unblock_price
    end
    return price
end

function coop:can_control_tower(pid, e, action_kind)
    if not self.active or not e then return true end
    -- Unowned holders can always be built on by either player
    if not e._mp_owner then return true end
    if self.tower_mode == "open" then return true end
    return e._mp_owner == pid
end

function coop:can_control_hero(pid, hero_entity)
    if not self.active or not hero_entity then return true end
    local my_hero_id = self.hero_ids[pid]
    if not my_hero_id then return true end
    return hero_entity.id == my_hero_id
end

function coop:can_use_power(pid, power_idx)
    if not self.active then return true end
    if power_idx == 1 then
        return pid == 1
    elseif power_idx == 3 then
        return pid == 2
    elseif power_idx == 2 then
        -- Independent reinforcements: check deterministic tick cooldown
        local cur_tick = (game and game.store and game.store.tick) or 0
        return cur_tick >= (self.reinf_ready_tick[pid] or 0)
    end
    return true
end

function coop:on_power_fired(pid, power_idx, btn)
    if not self.active then return end
    if power_idx == 2 then
        local cd_sec = (btn and btn.cooldown_time) or 15
        local cd_ticks = math.floor(cd_sec / (TICK_LENGTH or (1 / 60)) + 0.5)
        local cur_tick = (game and game.store and game.store.tick) or 0
        self.reinf_ready_tick[pid] = cur_tick + cd_ticks
    end
end

function coop:add_map_ping(pid, wx, wy)
    if self.lockstep and self.lockstep:is_catching_up() then
        return
    end
    local now = (love.timer and love.timer.getTime()) or 0
    self.pings[#self.pings + 1] = {
        pid = pid,
        wx = wx,
        wy = wy,
        start_ts = now,
        end_ts = now + 3.5,
    }
    if self.overlay then
        self.overlay:show_toast(string.format("%dP 标记了地图位置！", pid), 2.5)
    end
end

-- === Per-Tick Gold Ledger Hooks (called from hooks.lua inside sim:do_tick) ===

function coop:on_tick_begin(store)
    if not self.active then return end
    store.player_gold = self:get_canonical_gold()
end

function coop:before_tower_upgrade(store)
    if not self.active then return end
    local ops = {}
    for _, e in E:filter_iter(store.entities, "tower") do
        if e.tower.sell then
            local refund = (store.wave_group_number == 0) and (e.tower.spent or 0)
                or km.round((e.tower.refund_factor or 0.6) * (e.tower.spent or 0))
            local actor = e._mp_owner or e.tower._mp_actor or 1
            ops[#ops + 1] = { kind = "sell", actor = actor, delta = refund }
        elseif e.tower.upgrade_to then
            local price = self:get_upgrade_price(e, e.tower.upgrade_to)
            local actor = e.tower._mp_actor or e._mp_owner or 1
            ops[#ops + 1] = { kind = "upgrade", actor = actor, delta = -price }
        end
    end
    self._pending_tower_ops = ops
end

function coop:after_tower_upgrade(store)
    if not self.active then return end
    local ops = self._pending_tower_ops
    self._pending_tower_ops = nil
    if ops then
        for i = 1, #ops do
            local op = ops[i]
            if op.delta > 0 then
                self:add_player_gold(op.actor, op.delta)
            elseif op.delta < 0 then
                self:spend_gold(op.actor, -op.delta)
            end
        end
    end
    store.player_gold = self:get_canonical_gold()
end

function coop:on_system_gold_delta(store, delta, owner_hint)
    if not self.active or delta == 0 then return end
    if delta > 0 then
        self:add_shared_income(delta)
    else
        self:spend_gold(owner_hint or 1, -delta)
    end
    store.player_gold = self:get_canonical_gold()
end

function coop:on_tick_end(store)
    if not self.active then return end
    -- Restore local player's purse so FL's native HUD & TowerMenu show YOUR affordability
    store.player_gold = self:get_local_display_gold()
end

-- === World-Space Co-op Visual Overlays (Red/Blue Tower Rings, P1/P2 Hero Tags, Map Pings) ===

local function world_to_screen(wx, wy)
    if not game or not game.game_scale or not game.game_ref_origin then
        return nil, nil
    end
    local sx = wx * game.game_scale + game.game_ref_origin.x
    local sy = (game.screen_h or 720) - (wy * game.game_scale + game.game_ref_origin.y)
    return sx, sy
end

function coop:draw_world_overlays()
    if not self.active or not game or not game.store or not game.store.entities or not love.graphics then
        return
    end
    if not main or not main.handler or main.handler.active_item ~= game then
        return
    end

    local G = love.graphics
    local scale = game.game_scale or 1

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")
    local badge_font = fonts.get(12)
    if badge_font then G.setFont(badge_font) end

    -- 1. Draw sleek lower-front pedestal crescent + compact 1P/2P mini pill (ONLY in 'owned' mode & when enabled!)
    -- Never draws across the upper tower body so original hand-drawn tower artwork stays 100% clean.
    if self.show_tower_marks and self.tower_mode == "owned" then
        local mini_font = fonts.get(10) or badge_font
        for _, e in pairs(game.store.entities) do
            if e and e.tower and e._mp_owner and e.pos and not e._kr_mp_local then
                local sx, sy = world_to_screen(e.pos.x, e.pos.y)
                if sx then
                    local is_p1 = (e._mp_owner == 1)
                    local cx = sx
                    local cy = sy - 7 * scale
                    local rx = 31 * scale
                    local ry = 13 * scale

                    -- Build smooth front-bottom arc points (strictly hugging tower stone pedestal lip)
                    local pts = {}
                    local segs = 18
                    local a0 = math.pi * 0.14
                    local a1 = math.pi * 0.86
                    for i = 0, segs do
                        local a = a0 + (a1 - a0) * (i / segs)
                        pts[#pts + 1] = cx + math.cos(a) * rx
                        pts[#pts + 1] = cy + math.sin(a) * ry
                    end

                    -- Soft outer ground glow
                    G.setLineWidth(4.0)
                    if is_p1 then
                        G.setColor(55, 165, 255, 60)
                    else
                        G.setColor(255, 78, 78, 60)
                    end
                    G.line(pts)

                    -- Crisp refined inner pedestal rim
                    G.setLineWidth(1.6)
                    if is_p1 then
                        G.setColor(95, 198, 255, 215)
                    else
                        G.setColor(255, 110, 105, 215)
                    end
                    G.line(pts)

                    -- Compact rounded glass mini pill nestled cleanly at the front tip of the pedestal
                    local pw, ph = 22, 13
                    local bx = cx - pw / 2
                    local by = cy + ry - 5
                    G.setColor(10, 16, 26, 200)
                    G.rectangle("fill", bx, by, pw, ph, 5, 5)
                    G.setLineWidth(1.1)
                    if is_p1 then
                        G.setColor(95, 198, 255, 235)
                    else
                        G.setColor(255, 110, 105, 235)
                    end
                    G.rectangle("line", bx, by, pw, ph, 5, 5)
                    if mini_font then G.setFont(mini_font) end
                    G.setColor(is_p1 and 155 or 255, is_p1 and 220 or 165, is_p1 and 255 or 165, 255)
                    G.printf(is_p1 and "1P" or "2P", bx, by, pw, "center")
                end
            end
        end
        if badge_font then G.setFont(badge_font) end
    end

    -- 2. Draw crisp P1 (Blue) / P2 (Red) floating badges above the two Heroes (auto-stagger if stacked at spawn)
    local hpos = {}
    for pid = 1, 2 do
        local hid = self.hero_ids[pid]
        local he = hid and game.store.entities[hid]
        if he and he.pos and he.health and not he.health.dead then
            local sx, sy = world_to_screen(he.pos.x, he.pos.y)
            if sx then
                hpos[pid] = { sx = sx, sy = sy }
            end
        end
    end
    local stacked = hpos[1] and hpos[2]
        and math.abs(hpos[1].sx - hpos[2].sx) < 42
        and math.abs(hpos[1].sy - hpos[2].sy) < 28
    for pid = 1, 2 do
        local p = hpos[pid]
        if p then
            local tag = (pid == self.local_pid) and (pid .. "P (你)") or (pid .. "P")
            local bw = (pid == self.local_pid) and 54 or 28
            local bx = p.sx - bw / 2
            local by = p.sy - 58 * scale - ((stacked and pid == 1) and 19 or 0)
            G.setColor(0, 0, 0, 195)
            G.rectangle("fill", bx, by, bw, 16, 4, 4)
            if pid == 1 then
                G.setColor(70, 180, 255, 255)
            else
                G.setColor(255, 90, 90, 255)
            end
            G.setLineWidth(1.5)
            G.rectangle("line", bx, by, bw, 16, 4, 4)
            G.printf(tag, bx, by + 1, bw, "center")
        end
    end

    -- 3. Draw animated pulsing Map Pings (Alt + Left Click)
    local now = (love.timer and love.timer.getTime()) or 0
    for i = #self.pings, 1, -1 do
        local p = self.pings[i]
        if now >= p.end_ts then
            table.remove(self.pings, i)
        else
            local sx, sy = world_to_screen(p.wx, p.wy)
            if sx then
                local age = now - p.start_ts
                local cycle = (age * 1.8) % 1.0
                local r = (12 + cycle * 44) * scale
                local alpha = math.floor((1 - cycle) * 235)
                if p.pid == 1 then
                    G.setColor(70, 200, 255, alpha)
                else
                    G.setColor(255, 95, 95, alpha)
                end
                G.setLineWidth(3)
                G.circle("line", sx, sy, r)
                G.circle("fill", sx, sy, 5 * scale)
                G.setColor(0, 0, 0, 200)
                G.rectangle("fill", sx - 36, sy - 26, 72, 18, 4, 4)
                G.setColor(255, 240, 120, 255)
                G.printf(p.pid .. "P 标记!", sx - 36, sy - 25, 72, "center")
            end
        end
    end

    G.pop()
end

return coop

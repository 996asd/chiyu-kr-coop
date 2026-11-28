-- KR-MP 2P Co-op Gameplay Layer (M1)
-- Manages: Dual-hero ownership, independent/shared gold ledger, red/blue tower ownership,
-- independent reinforcements cooldowns, gold transfer, map pings, and world-space overlays.
local signal = require("hump.signal")
local E = require("entity_db")
local km = require("klua.macros")
local fonts = require("kr_mp.fonts")
local proto = require("kr_mp.proto")
local catalog = require("kr_mp.catalog")
local loadout = require("kr_mp.coop_loadout")
local stage_flow = require("kr_mp.stage_flow")
local coop_draw = require("kr_mp.coop_draw")

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
    cataclysm = loadout.DEFAULT_CATACLYSM,
    reinforcements = { [1] = loadout.DEFAULT_REINF, [2] = loadout.DEFAULT_REINF },
    max_tech = true,
    local_ult_slot = nil,
    _active_power_actor = nil,
    _active_g4_branch = nil,
    _active_g5_branch = nil,

    gold = { [1] = 0, [2] = 0 },
    shared_gold = 0,
    gold_split_parity = 0,

    hero_ids = { [1] = nil, [2] = nil },
    reinf_ready_tick = { [1] = 0, [2] = 0 },
    shared_power_ready_tick = {},
    hero_ult_ready_tick = {},

    pings = {}, -- { { wx, wy, pid, start_ts, end_ts }, ... }
    signal_registered = false,
    _pending_tower_ops = nil,
    show_tower_marks = true, -- Local-only visual toggle for 1P/2P pedestal arc & mini badge
}

-- Curated Alliance + Genesis FL 8.2.0 dual-hero roster for quick cycling
coop.HERO_ROSTER = {
    { idx = 53, name = "Vesper",    tpl = "hero_vesper" },
    { idx = 54, name = "Raelyn",    tpl = "hero_raelyn" },
    { idx = 55, name = "Nyru",      tpl = "hero_muyrn" },
    { idx = 61, name = "Lumenir",   tpl = "hero_lumenir" },
    { idx = 63, name = "Kosmyr",    tpl = "hero_dragon_gem" },
    { idx = 65, name = "Bonehart",  tpl = "hero_dragon_bone" },
    { idx = 70, name = "Wukong",    tpl = "hero_wukong" },
    { idx = 84, name = "Eiskalt",   tpl = "hero_eiskalt" },
    { idx = 85, name = "Dianyun",   tpl = "hero_dianyun" },
    { idx = 91, name = "Gerald G6", tpl = "hero_gerald_g6" },
    { idx = 92, name = "Zefira",    tpl = "hero_zefira" },
    { idx = 98, name = "Ashbite",   tpl = "hero_ashbite" },
    { idx = 99, name = "Drakkan",   tpl = "hero_drakkan" },
}

coop.LEVEL_PRESETS = {
    { idx = 251, label = "KR6-251 Linirea Castle" },
    { idx = 101, label = "KR5-101 Sea of Trees 1" },
    { idx = 150, label = "KR4-150 Vez'nan's Tower" },
    { idx = 1,   label = "KR3-01 Elven Woods 1" },
}

local deep_copy = proto.deep_copy

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
        -- Keep deterministic Co-op power cooldown ticks aligned with FL 8.2.0's early-wave & skill cooldown reductions
        signal.register("early-wave-called", function(_group, _reward, remaining_time)
            if self.active and type(remaining_time) == "number" and remaining_time > 1 then
                local dt_ticks = math.floor(remaining_time / (TICK_LENGTH or (1 / 60)) + 0.5)
                for p = 1, 2 do
                    self.reinf_ready_tick[p] = math.max(0, (self.reinf_ready_tick[p] or 0) - dt_ticks)
                end
                for k, v in pairs(self.shared_power_ready_tick) do
                    self.shared_power_ready_tick[k] = math.max(0, (v or 0) - dt_ticks)
                end
                for k, v in pairs(self.hero_ult_ready_tick) do
                    self.hero_ult_ready_tick[k] = math.max(0, (v or 0) - dt_ticks)
                end
            end
        end)
        signal.register("reduce-user-power-cooldown", function(power_idx, amount)
            if self.active and power_idx ~= nil and type(amount) == "number" and amount > 0 then
                local dt_ticks = math.floor(amount / (TICK_LENGTH or (1 / 60)) + 0.5)
                local info = self:get_power_slot_info(power_idx)
                if info and info.kind == "reinforcement" then
                    for p = 1, 2 do
                        self.reinf_ready_tick[p] = math.max(0, (self.reinf_ready_tick[p] or 0) - dt_ticks)
                    end
                elseif info and info.kind == "hero_ult" then
                    self.hero_ult_ready_tick[power_idx] = math.max(0, (self.hero_ult_ready_tick[power_idx] or 0) - dt_ticks)
                else
                    self.shared_power_ready_tick[power_idx] = math.max(0, (self.shared_power_ready_tick[power_idx] or 0) - dt_ticks)
                end
            end
        end)
        -- Scheme B: automatically scale KR2..5 non-ultimate hero skills at Hero Lv.4 (Lv.2) and Lv.7 (Lv.3)
        signal.register("hero-level-increased", function(hero)
            if self.active and hero and game and game.store then
                loadout.upgrade_hero_skills_for_level(hero, game.store)
            end
        end)
        -- Post-match Victory / Defeat seamless stage chaining
        signal.register("game-victory", function(st)
            if self.active then
                stage_flow:on_outcome("victory", st)
            end
        end)
        signal.register("game-defeat", function(st)
            if self.active then
                stage_flow:on_outcome("defeat", st)
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

function coop:is_slot_override_bypassed()
    return self._bypass_slot_override == true
end

function coop:with_slot_bypass(fn)
    local prev = self._bypass_slot_override
    self._bypass_slot_override = true
    local ok, r1, r2 = pcall(fn)
    self._bypass_slot_override = prev
    if not ok then error(r1) end
    return r1, r2
end

function coop:get_active_power_actor()
    return self._active_power_actor or self.local_pid or 1
end

function coop:get_active_g4_branch()
    return self._active_g4_branch
end

function coop:get_active_g5_branch()
    return self._active_g5_branch
end

function coop:with_power_context(actor_pid, fn)
    local prev_actor = self._active_power_actor
    local prev_g4 = self._active_g4_branch
    local prev_g5 = self._active_g5_branch
    self._active_power_actor = actor_pid
    local spec = self:get_player_reinf_spec(actor_pid)
    self._active_g4_branch = (spec and spec.gen == 4 and spec.branch) or nil
    self._active_g5_branch = (spec and spec.gen == 5 and spec.branch) or nil
    local ok, res = pcall(fn)
    self._active_power_actor = prev_actor
    self._active_g4_branch = prev_g4
    self._active_g5_branch = prev_g5
    return ok, res
end

function coop:with_g5_branch(branch, fn)
    local prev = self._active_g5_branch
    self._active_g5_branch = branch
    local ok, res = pcall(fn)
    self._active_g5_branch = prev
    return ok, res
end

function coop:get_tick_reserved_gold(pid)
    local res = self._tick_reserved_gold
    if not res then return 0 end
    if self.econ_mode == "shared" then
        return (res[1] or 0) + (res[2] or 0)
    end
    return res[pid] or 0
end

function coop:get_slot_override()
    if self.active and self.slot_snapshot and not self._bypass_slot_override then
        return deep_copy(self.slot_snapshot)
    end
    return nil
end

-- Ensure storage.active_slot_idx always points to a REAL disk save slot without clobbering
-- an existing active slot (e.g. Android auto-created Slot 2/3 while Slot 1 is empty).
-- Must run inside with_slot_bypass so Co-op snapshot/save-suppression hooks do not
-- mask a missing disk file or block initial slot creation.
function coop:ensure_valid_disk_slot()
    local ok_st, storage = pcall(require, "storage")
    if not ok_st or type(storage) ~= "table" then return nil end
    local ok_find, chosen_idx = pcall(self.with_slot_bypass, self, function()
        local chosen = nil
        local cur = storage.active_slot_idx
        if cur and storage:load_slot(cur) then
            chosen = cur
        else
            for i = 1, 3 do
                if storage:load_slot(i) then
                    chosen = i
                    break
                end
            end
        end
        if not chosen then
            if love and love.filesystem and love.filesystem.createDirectory then
                pcall(love.filesystem.createDirectory, "fl_save")
            end
            storage:create_slot(1)
            if storage:load_slot(1) then
                chosen = 1
            end
        end
        if chosen and storage.active_slot_idx ~= chosen then
            storage:set_active_slot(chosen)
        end
        return chosen
    end)
    return ok_find and chosen_idx or nil
end

function coop:build_host_slot_snapshot(heroes, towers, room_loadout)
    local storage = require("storage")
    local chosen_idx = self:ensure_valid_disk_slot()
    local raw = self:with_slot_bypass(function()
        return (chosen_idx and storage:load_slot(chosen_idx, true)) or storage:load_slot(nil, true) or {}
    end)
    local snap = deep_copy(raw)

    -- Keep packet compact by trimming bulky history tables not needed during battle
    snap.seen = snap.seen or {}
    snap.bag = snap.bag or {}
    snap.upgrades = snap.upgrades or {
        archers = 0, barracks = 0, mages = 0, rocks = 0, thunder = 0, reinforcements = 0
    }
    snap.heroes = snap.heroes or { selected = "hero_vesper", status = {} }
    snap.heroes.status = snap.heroes.status or {}

    -- Apply room's custom tower deck (1..59 in FL 8.2.0, up to 12 towers)
    local max_tower_id = catalog.MAX_TOWER_ID or 59
    local deck = {}
    if type(towers) == "table" and #towers > 0 then
        local seen_t = {}
        for i = 1, math.min(#towers, 12) do
            local tid = tonumber(towers[i])
            if tid and tid >= 1 and tid <= max_tower_id and not seen_t[tid] then
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
    snap.liuhui = snap.liuhui or {}
    snap.liuhui.use3tower = true
    snap.liuhui.use3tower_count = 0
    snap.liuhui.tower_generations = { true, true, true, true, true }
    snap.liuhui.impossiblerate = 1.5
    snap.liuhui.cheat = false
    snap.liuhui.cheat5 = false
    snap.liuhui.cheat6 = false
    snap.liuhui.cheat5_special = false
    snap.liuhui.cheat5_dragon = false
    snap.liuhui.cheathero = false
    snap.liuhui.rand_hero = 0
    snap.liuhui.rand_tower = 0
    snap.liuhui.hero_auto_rally = false
    snap.liuhui.hero_enhance = false
    snap.liuhui.g3_hprate = false
    snap.liuhui.balance = false
    snap.liuhui.g4range_balance = true
    snap.liuhui.enemy_count = 1
    snap.liuhui.g5_hero_dark_count = 2
    snap.liuhui.cp_mode = false
    snap.liuhui.reinforcement_skins = 0
    snap.liuhui.rand_creep = 0
    snap.liuhui.g1_level10 = false
    snap.reinforcement_count = 0
    snap.campaign_variant = "regular"
    snap.xingyu = { balance = 0 }

    local ld = type(room_loadout) == "table" and room_loadout or {}
    local want_max_tech = (ld.max_tech ~= false)

    -- Apply Slot 1 (Cataclysm) + Slot 2 (P1 Reinforcement) + Slot 3 (Hero Ultimate)
    loadout.apply_power_slots_to_snapshot(snap, ld)

    -- Apply 1..6 gen maxed tech upgrades to in-memory snapshot only (when enabled)
    if want_max_tech then
        loadout.apply_max_tech_to_snapshot(snap, ld)
    end

    local ok_gu, gen_up = pcall(require, "generation_upgrades")
    if ok_gu and gen_up and gen_up.normalize then
        pcall(gen_up.normalize, snap)
    end
    local ok_h6, h6 = pcall(require, "hero_upgrades_6")
    if ok_h6 and h6 and h6.normalize then
        pcall(h6.normalize, snap)
    end
    local ok_ps, psel = pcall(require, "power_selection")
    if ok_ps and psel and psel.normalize then
        pcall(psel.normalize, snap)
    end

    -- Force dual-hero mode with the room's exact 2 selected heroes!
    local h1 = (heroes and heroes[1]) or catalog.DEFAULT_HERO_1 or 53
    local h2 = (heroes and heroes[2]) or catalog.DEFAULT_HERO_2 or 54
    snap.liuhui_hero = {
        usedoublehero = true,
        herolist = { [1] = h1, [2] = h2 },
        rallylist = { h1, h2, h1, h2 },
    }
    -- Scheme B hero initialization: Lv.1 start + max Lv.3 Ultimate + Lv.1 normal skills (auto-tier at Lv.4 & Lv.7)
    loadout.apply_hero_scheme_b_to_snapshot(snap, { h1, h2 })
    return snap
end

function coop:prepare_match(local_pid, cfg, reconnect_data)
    self.active = true
    self.local_pid = local_pid
    self.cfg = deep_copy(cfg)
    self.slot_snapshot = deep_copy(cfg.slot_snapshot)
    self.econ_mode = cfg.econ_mode or "independent"
    self.tower_mode = cfg.tower_mode or "owned"
    self.cataclysm = loadout.normalize_cataclysm(cfg.cataclysm)
    self.reinforcements = {
        [1] = loadout.normalize_reinf(cfg.reinforcements and cfg.reinforcements[1]),
        [2] = loadout.normalize_reinf(cfg.reinforcements and cfg.reinforcements[2]),
    }
    self.max_tech = (cfg.max_tech ~= false)
    self.local_ult_slot = nil
    self._active_power_actor = nil
    self._active_g4_branch = nil
    self._active_g5_branch = nil
    self.gold = { [1] = 0, [2] = 0 }
    self.shared_gold = 0
    self.gold_split_parity = 0
    self.hero_ids = { [1] = nil, [2] = nil }
    self.reinf_ready_tick = { [1] = 0, [2] = 0 }
    self.shared_power_ready_tick = {}
    self.hero_ult_ready_tick = {}
    self.pings = {}
    stage_flow:reset()
    local ok_sdb, S_db = pcall(require, "sound_db")
    if ok_sdb and S_db and S_db.stop_all then
        pcall(S_db.stop_all, S_db)
        if S_db.resume then pcall(S_db.resume, S_db) end
    end

    if self.lockstep then
        if reconnect_data then
            self.lockstep:begin_reconnect(local_pid, cfg, reconnect_data)
        else
            self.lockstep:begin_loading(local_pid, cfg)
        end
    end

    -- Ensure a real disk save slot is active BEFORE director loads 'game' (bypasses Co-op override so
    -- Android 2P phones without Slot 1 never end up with active_slot_idx pointing at a missing file!).
    self:ensure_valid_disk_slot()
    local storage = require("storage")
    -- Clear direct storage.slot cache so hero_enhance_mod always reads the synced Co-op slot_snapshot
    storage.slot = nil
    local ok_hem, hem = pcall(require, "hero_enhance_mod")
    if ok_hem and hem and hem.set_enabled and hem.is_enabled then
        pcall(hem.set_enabled, hem, false)
    end

    if screen_map == nil then
        screen_map = { user_data = deep_copy(self.slot_snapshot), reinforcement_skins = 0 }
    else
        screen_map.user_data = deep_copy(self.slot_snapshot)
        screen_map.reinforcement_skins = 0
    end

    -- Synchronize FL 8.2.0 global difficulty multipliers identically on both clients
    -- (prevents DESYNC if either player tweaked Impossible HP rate or debug speed factor in single-player!)
    local ok_gs, GS = pcall(require, "game_settings")
    if ok_gs and GS then
        local imp_rate = (self.slot_snapshot and self.slot_snapshot.liuhui and tonumber(self.slot_snapshot.liuhui.impossiblerate)) or 1.5
        if GS.difficulty_enemy_hp_max_factor then
            GS.difficulty_enemy_hp_max_factor[1] = 0.8
            GS.difficulty_enemy_hp_max_factor[2] = 1
            GS.difficulty_enemy_hp_max_factor[3] = 1.2
            GS.difficulty_enemy_hp_max_factor[4] = imp_rate
        end
        if GS.difficulty_enemy_speed_factor then
            GS.difficulty_enemy_speed_factor[1] = 1
            GS.difficulty_enemy_speed_factor[2] = 1
            GS.difficulty_enemy_speed_factor[3] = 1
            GS.difficulty_enemy_speed_factor[4] = 1.1
        end
        loadout.apply_coop_xp_boost(GS)
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

-- Wait until director has finished any in-flight screen load or previous 'game' unload
-- before queueing 'game', avoiding both image_db thread races and FL's singleton game.store=nil crash!
function coop:try_launch_pending()
    if not self._pending_launch_args or not main or not main.handler then return end
    local h = main.handler
    if h.queue_unload_item ~= nil or h.queued_item ~= nil or h.next_item_name ~= nil then
        return
    end
    if h.active_item == nil or h.active_item.is_transition then
        return
    end
    -- CRITICAL: FL's director shares a single 'game' table singleton. Queueing 'game' while active_item is
    -- already 'game' causes async unload_item(old game) to wipe game.store=nil BEFORE queued game:init() runs!
    -- Bounce cleanly through 'slots' first so the old match unloads completely before loading the new/reconnected match.
    if h.active_item == game or h.active_item.item_name == "game" then
        self:log("Active item is still 'game'; bouncing through 'slots' to unload cleanly before launching level=%d",
            self._pending_launch_args.level_idx or 101)
        h.next_item_name = "slots"
        h.next_item_args = {}
        return
    end
    local args = self._pending_launch_args
    self._pending_launch_args = nil
    self:log("Launching synced Co-op level=%d (director ready, active=%s)",
        args.level_idx or 101, tostring(h.active_item.item_name))
    h.next_item_name = "game"
    h.next_item_args = args
end

function coop:leave_match()
    self._pending_launch_args = nil
    stage_flow:reset()
    self.active = false
    self.cfg = nil
    self.slot_snapshot = nil
    self.pings = {}
    self.local_ult_slot = nil
    self._active_power_actor = nil
    self._active_g4_branch = nil
    self._active_g5_branch = nil
    local ok_gs, GS = pcall(require, "game_settings")
    if ok_gs and GS then
        loadout.restore_coop_xp_boost(GS)
    end
    if self.lockstep then
        self.lockstep:reset()
    end
    if game and game.store then
        game.store.paused = false
    end
    if game and game.game_gui and game.game_gui.pauseview then
        game.game_gui.pauseview.hidden = true
    end
    -- Always leave the Co-op battle (or any stray ending/map screen) cleanly back to 'slots' so players
    -- are never stranded inside a ghost battle or single-player screen after leaving/disconnecting.
    if main and main.handler and main.handler.active_item then
        local ai = main.handler.active_item
        local nm = ai.item_name
        if (ai == game or (nm ~= "slots" and nm ~= "splash" and not ai.is_transition))
            and main.handler.next_item_name == nil then
            main.handler.next_item_name = "slots"
            main.handler.next_item_args = {}
        end
    end
    -- Restore real local slot onto screen_map.user_data so temporary co-op snapshot never leaks to single-player map
    local ok_st, storage = pcall(require, "storage")
    if ok_st and storage and storage.load_slot then
        local ok_ld, local_slot = pcall(storage.load_slot, storage, nil, true)
        if ok_ld and type(local_slot) == "table" and screen_map then
            screen_map.user_data = local_slot
        end
    end
end

function coop:on_before_sim_init(store)
    if not self.active or not self.cfg then return end
    local prng = require("kr_mp.prng")
    prng:seed_sim(self.cfg.seed or 123456)
    self.hero_ids = { [1] = nil, [2] = nil }
    self.reinf_ready_tick = { [1] = 0, [2] = 0 }
    self.shared_power_ready_tick = {}
    self.hero_ult_ready_tick = {}
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

function coop:on_game_gui_ready(game_gui)
    if not self.active or not game_gui then return end
    loadout.configure_local_power_bar(self, game_gui)
end

function coop:get_player_reinf_spec(pid)
    return loadout.get_player_reinf_spec(self.reinforcements, pid or self.local_pid or 1)
end

function coop:on_game_ready()
    if not self.active then return end
    if self.lockstep then
        self.lockstep:on_local_loaded()
    end
end

function coop:on_entity_inserted(e)
    if not self.active or not e or not e.hero or not e.id or e._kr_mp_local then return end
    -- Durax clones & temporary summoned hero copies inherit owner from their original hero rather than taking P1/P2 seat
    if e.clone or e.template_name == "hero_durax_clone" then
        local st = game and game.store
        for pid = 1, 2 do
            local hid = self.hero_ids[pid]
            local he = hid and st and st.entities and st.entities[hid]
            if he and he.template_name == "hero_durax" then
                e._mp_owner = pid
                break
            end
        end
        return
    end
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
    if e.tower and e.tower.upgrade_price_multiplier then
        price = math.ceil(price * e.tower.upgrade_price_multiplier)
        price = math.floor(price / 10) * 10
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
    if hero_entity._mp_owner then
        return hero_entity._mp_owner == pid
    end
    if hero_entity.clone or hero_entity.template_name == "hero_durax_clone" then
        local st = game and game.store
        for p = 1, 2 do
            local hid = self.hero_ids[p]
            local he = hid and st and st.entities and st.entities[hid]
            if he and he.template_name == "hero_durax" then
                return p == pid
            end
        end
    end
    local my_hero_id = self.hero_ids[pid]
    if not my_hero_id then return true end
    return hero_entity.id == my_hero_id
end

-- Mirrors FL 8.2.0 game_gui.lua:hero_ultimate_assignments() & power_selection.get() so every
-- power slot (1, 2, 3, "a", "s") accurately identifies its true kind and hero owner across all 105 heroes!
function coop:get_power_slot_info(power_idx)
    local snap = self.slot_snapshot
    local ok_ps, psel = pcall(require, "power_selection")
    local ok_md, map_data = pcall(require, "data.map_data")
    local st = game and game.store

    local function hero_rank_has_ult(rank)
        local he = nil
        if st then
            if rank == 1 then
                he = st.main1_hero or (self.hero_ids[1] and st.entities and st.entities[self.hero_ids[1]])
            elseif rank == 2 then
                he = st.main_hero or (self.hero_ids[2] and st.entities and st.entities[self.hero_ids[2]])
            end
        end
        local tpl = nil
        if he and he.template_name then
            tpl = E:get_template(he.template_name)
        elseif ok_md and map_data and map_data.hero_data and snap and snap.liuhui_hero and snap.liuhui_hero.herolist then
            local hidx = snap.liuhui_hero.herolist[rank]
            local hd = hidx and map_data.hero_data[hidx]
            if hd and hd.name then
                tpl = E:get_template(hd.name)
            end
        end
        local skills = (he and he.hero and he.hero.skills) or (tpl and tpl.hero and tpl.hero.skills)
        local ult = skills and skills.ultimate
        return ult ~= nil and ult.controller_name ~= nil
    end

    local function get_opt(slot_num)
        if ok_ps and psel and psel.get and snap then
            local ok_g, opt = pcall(psel.get, snap, slot_num)
            if ok_g and type(opt) == "table" then return opt end
        end
        if slot_num == 1 then return { kind = "default_cataclysm" }
        elseif slot_num == 2 then return { kind = "reinforcement" }
        else return { kind = "empty" } end
    end

    local available_ranks = {}
    for rank = 1, 2 do
        if hero_rank_has_ult(rank) then
            available_ranks[#available_ranks + 1] = rank
        end
    end

    local base_slots = {}
    local assigned = {}
    local next_rank = 1
    for s = 1, 3 do
        local opt = get_opt(s)
        local rank = available_ranks[next_rank]
        if opt.kind == "empty" and rank then
            base_slots[s] = rank
            assigned[rank] = true
            next_rank = next_rank + 1
        end
    end

    local extra_slots = {}
    local extra_names = { "a", "s" }
    local extra_i = 1
    for i = 1, #available_ranks do
        local rank = available_ranks[i]
        if not assigned[rank] then
            local sname = extra_names[extra_i]
            if sname then
                extra_slots[sname] = rank
                extra_i = extra_i + 1
            end
        end
    end

    if type(power_idx) == "number" then
        if base_slots[power_idx] then
            return { kind = "hero_ult", owner = base_slots[power_idx], opt = nil }
        end
        local opt = get_opt(power_idx)
        if opt.kind == "reinforcement" then
            return { kind = "reinforcement", owner = nil, opt = opt }
        elseif opt.kind == "empty" then
            return { kind = "empty", owner = nil, opt = opt }
        else
            return { kind = "shared_spell", owner = nil, opt = opt }
        end
    elseif power_idx == "a" or power_idx == "s" then
        if extra_slots[power_idx] then
            return { kind = "hero_ult", owner = extra_slots[power_idx], opt = nil }
        end
        return { kind = "empty", owner = nil, opt = nil }
    end
    return { kind = "shared_spell", owner = nil, opt = nil }
end

function coop:can_use_power(pid, power_idx)
    if not self.active then return true end
    local cur_tick = (game and game.store and game.store.tick) or 0
    local info = self:get_power_slot_info(power_idx)
    if info.kind == "hero_ult" then
        if pid ~= info.owner then
            return false, info.owner, "hero_ult"
        end
        local ready = self.hero_ult_ready_tick[power_idx] or 0
        if cur_tick < ready then
            return false, info.owner, "cooldown"
        end
        return true, info.owner, "hero_ult"
    elseif info.kind == "reinforcement" then
        -- Independent reinforcements: per-player deterministic tick cooldown
        if cur_tick < (self.reinf_ready_tick[pid] or 0) then
            return false, pid, "cooldown"
        end
        return true, pid, "reinforcement"
    elseif info.kind == "shared_spell" then
        -- Slot 1 Cataclysm is exclusively controlled by 1P Host!
        if power_idx == 1 and pid ~= 1 then
            return false, 1, "host_cataclysm"
        end
        local ready = self.shared_power_ready_tick[power_idx] or 0
        if cur_tick < ready then
            return false, nil, "cooldown"
        end
        return true, 1, "shared_spell"
    end
    return true, nil, info.kind
end

function coop:on_power_fired(pid, power_idx, btn_or_cd)
    if not self.active then return end
    local info = self:get_power_slot_info(power_idx)
    local cd_sec = (type(btn_or_cd) == "number" and btn_or_cd)
        or (type(btn_or_cd) == "table" and tonumber(btn_or_cd.cooldown_time))
        or 15
    local cd_ticks = math.max(1, math.floor(cd_sec / (TICK_LENGTH or (1 / 60)) + 0.5))
    local cur_tick = (game and game.store and game.store.tick) or 0
    if info.kind == "reinforcement" then
        self.reinf_ready_tick[pid] = cur_tick + cd_ticks
    elseif info.kind == "hero_ult" then
        self.hero_ult_ready_tick[power_idx] = cur_tick + cd_ticks
    elseif info.kind == "shared_spell" then
        self.shared_power_ready_tick[power_idx] = cur_tick + cd_ticks
        if info.opt and info.opt.kind == "mermaid_gift" then
            self.hero_ult_ready_tick = {}
        end
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
    self._tick_reserved_gold = { [1] = 0, [2] = 0 }
    store.player_gold = self:get_canonical_gold()
end

function coop:reserve_tick_gold(pid, amount)
    amount = math.floor((amount or 0) + 0.5)
    if amount <= 0 then return true end
    local res = self._tick_reserved_gold
    if not res then
        res = { [1] = 0, [2] = 0 }
        self._tick_reserved_gold = res
    end
    local used = (self.econ_mode == "shared") and ((res[1] or 0) + (res[2] or 0)) or (res[pid] or 0)
    if self:get_player_gold(pid) < (used + amount) then
        return false
    end
    res[pid] = (res[pid] or 0) + amount
    return true
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
    self._tick_reserved_gold = { [1] = 0, [2] = 0 }
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

-- === World-Space Co-op Visual Overlays (delegated to coop_draw.lua) ===

function coop:draw_world_overlays()
    return coop_draw.draw_world_overlays(self)
end

return coop

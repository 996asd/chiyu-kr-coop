-- KR-MP Co-op Loadout, Tech Maxing & Scheme-B Hero Progression Module
-- Single source of truth shared across lobby UI, snapshot builder, and lockstep hooks.

local M = {}

local function get_E()
    local ok, mod = pcall(require, "entity_db")
    return ok and mod or nil
end

M.DEFAULT_CATACLYSM = "default_cataclysm"
M.DEFAULT_REINF = "default_reinforcement"

M.CATACLYSM_OPTIONS = {
    { id = "default_cataclysm", name = "默认天灾", short = "默认天灾", desc = "随关卡自带" },
    { id = "fireball_g1",       name = "1代火雨",  short = "1代火雨",  desc = "经典陨石雨" },
    { id = "fireball_g2",       name = "2代火雨",  short = "2代火雨",  desc = "前线烈焰陨石" },
    { id = "thunder_g3",        name = "3代闪电",  short = "3代闪电",  desc = "起源全图雷暴" },
    { id = "fireball_g6",       name = "6代火雨",  short = "6代火雨",  desc = "创世高能流星" },
}

M.REINF_OPTIONS = {
    { id = "default_reinforcement",  option_id = "default_reinforcement", name = "默认援军",      short = "默认援军", desc = "随关卡自带",    gen = nil, branch = nil },
    { id = "reinforcement_g1",       option_id = "reinforcement_g1",      name = "1代援军",       short = "1代援军",  desc = "王国矛兵",      gen = 1,   branch = nil },
    { id = "reinforcement_g2",       option_id = "reinforcement_g2",      name = "2代援军",       short = "2代援军",  desc = "沙漠军团",      gen = 2,   branch = nil },
    { id = "reinforcement_g3",       option_id = "reinforcement_g3",      name = "3代援军",       short = "3代援军",  desc = "精灵卫队",      gen = 3,   branch = nil },
    { id = "reinforcement_g4_dark",  option_id = "reinforcement_g4",      name = "4代·地狱三叉戟", short = "4代三叉戟", desc = "远程对空+领主", gen = 4,   branch = "dark" },
    { id = "reinforcement_g4_royal", option_id = "reinforcement_g4",      name = "4代·恶魔卫兵",  short = "4代恶魔卫", desc = "近战自爆+领主", gen = 4,   branch = "royal" },
    { id = "reinforcement_g5_dark",  option_id = "reinforcement_g5",      name = "5代·暗影弓手",  short = "5代暗影弓", desc = "远程对空+暗影", gen = 5,   branch = "dark" },
    { id = "reinforcement_g5_royal", option_id = "reinforcement_g5",      name = "5代·反叛民兵",  short = "5代民兵",  desc = "反伤近战+圣骑", gen = 5,   branch = "royal" },
    { id = "reinforcement_g6",       option_id = "reinforcement_g6",      name = "6代援军",       short = "6代援军",  desc = "创世强化卫兵",  gen = 6,   branch = nil },
}

M.CATACLYSM_BY_ID = {}
for _, it in ipairs(M.CATACLYSM_OPTIONS) do
    M.CATACLYSM_BY_ID[it.id] = it
end

M.REINF_BY_ID = {}
for _, it in ipairs(M.REINF_OPTIONS) do
    M.REINF_BY_ID[it.id] = it
end

-- Co-op 2P hero XP boost (~2x base multipliers across difficulties)
M.COOP_XP_MULTIPLIERS = {
    [1] = 3.0, -- Easy   (base 2.0)
    [2] = 2.2, -- Normal (base 1.1)
    [3] = 2.0, -- Hard   (base 1.0)
    [4] = 2.0, -- Imposs (base 1.0)
}

M._saved_xp_multipliers = nil

function M.normalize_cataclysm(id)
    if type(id) == "string" and M.CATACLYSM_BY_ID[id] then
        return id
    end
    return M.DEFAULT_CATACLYSM
end

function M.normalize_reinf(id)
    if type(id) == "string" and M.REINF_BY_ID[id] then
        return id
    end
    return M.DEFAULT_REINF
end

function M.get_cataclysm_info(id)
    return M.CATACLYSM_BY_ID[M.normalize_cataclysm(id)]
end

function M.get_reinf_info(id)
    return M.REINF_BY_ID[M.normalize_reinf(id)]
end

function M.normalize_room_loadout(room)
    if type(room) ~= "table" then return end
    room.cataclysm = M.normalize_cataclysm(room.cataclysm)
    if type(room.reinforcements) ~= "table" then
        room.reinforcements = { M.DEFAULT_REINF, M.DEFAULT_REINF }
    else
        room.reinforcements[1] = M.normalize_reinf(room.reinforcements[1])
        room.reinforcements[2] = M.normalize_reinf(room.reinforcements[2])
    end
    if room.max_tech == nil then
        room.max_tech = true
    else
        room.max_tech = (room.max_tech == true)
    end
end

function M.get_player_reinf_spec(reinf_table, pid)
    local raw_id = (type(reinf_table) == "table") and reinf_table[pid] or M.DEFAULT_REINF
    return M.get_reinf_info(raw_id)
end

local function has_in_list(list, val)
    if type(list) ~= "table" then return false end
    for i = 1, #list do
        if list[i] == val then return true end
    end
    return false
end

local G4_TOWER_ALL = {
    "g4_towers_blitz_tactics",
    "g4_towers_war_rations",
    "g4_towers_large_bombs",
    "g4_towers_gxr1",
    "g4_towers_rune_power",
    "g4_towers_merchant_guild",
    "g4_towers_master_architect",
    "g4_towers_death_coils",
}

local G5_TOWER_ALL = {
    "towers_war_rations",
    "towers_scoping_mechanism",
    "towers_wise_investment",
    "towers_royal_training",
    "towers_golden_time",
    "towers_improved_formulas",
    "towers_favorite_customer",
    "towers_keen_accuracy",
}

local G4_REINF_TREES = {
    dark = {
        "g4_reinforcements_death_burst",
        "g4_reinforcements_training",
        "g4_reinforcements_trident",
        "g4_reinforcements_flaming_trident",
        "g4_reinforcements_pit_lord",
    },
    royal = {
        "g4_reinforcements_death_burst",
        "g4_reinforcements_training",
        "g4_reinforcements_guard",
        "g4_reinforcements_guard_nova",
        "g4_reinforcements_pit_lord",
    },
}

local G5_REINF_TREES = {
    dark = {
        "reinforcements_master_blacksmiths",
        "reinforcements_intense_workout",
        "reinforcements_shadow_archer",
        "reinforcements_night_veil",
        "reinforcements_power_trio_dark",
    },
    royal = {
        "reinforcements_master_blacksmiths",
        "reinforcements_intense_workout",
        "reinforcements_rebel_militia",
        "reinforcements_thorny_armor",
        "reinforcements_power_trio",
    },
}

local G6_TREE_DEFAULTS = {
    { tree = "g6_archers",   prefix = "archers_",   def = "b" },
    { tree = "g6_barracks",  prefix = "barracks_",  def = "b" },
    { tree = "g6_mages",     prefix = "mages_",     def = "b" },
    { tree = "g6_artillery", prefix = "artillery_", def = "a" },
}

local function copy_list(src)
    local out = {}
    for i = 1, #src do out[i] = src[i] end
    return out
end

-- Max out all 1..6 gen tech upgrades in memory snapshot ONLY (never touches local disk save)
function M.apply_max_tech_to_snapshot(snap, loadout)
    if type(snap) ~= "table" then return end

    local function full_legacy()
        return {
            archers = 5,
            barracks = 5,
            mages = 5,
            rocks = 5,
            thunder = 5,
            reinforcements = 5,
        }
    end
    snap.upgrades_by_generation = {
        [1] = full_legacy(),
        [2] = full_legacy(),
        [3] = full_legacy(),
    }
    snap.upgrades = full_legacy()

    local gu = snap.generation_upgrades
    if type(gu) ~= "table" then
        gu = {}
        snap.generation_upgrades = gu
    end

    -- Choose default G4/G5 reinforcement branch: respect P1 explicit choice, else default "dark" (ranged anti-air)
    local r1 = M.get_player_reinf_spec(loadout and loadout.reinforcements, 1)
    local g4_branch = (r1.gen == 4 and r1.branch) or "dark"
    local g5_branch = (r1.gen == 5 and r1.branch) or "dark"

    gu.g4_towers = copy_list(G4_TOWER_ALL)
    gu.g5_towers = copy_list(G5_TOWER_ALL)
    gu.g4_reinforcements = copy_list(G4_REINF_TREES[g4_branch] or G4_REINF_TREES.dark)
    gu.g5_reinforcements = copy_list(G5_REINF_TREES[g5_branch] or G5_REINF_TREES.dark)

    for _, spec in ipairs(G6_TREE_DEFAULTS) do
        local cur = gu[spec.tree]
        local branch = spec.def
        if has_in_list(cur, spec.prefix .. "l3a") or has_in_list(cur, spec.prefix .. "l4a") then
            branch = "a"
        elseif has_in_list(cur, spec.prefix .. "l3b") or has_in_list(cur, spec.prefix .. "l4b") then
            branch = "b"
        end
        gu[spec.tree] = {
            spec.prefix .. "l1",
            spec.prefix .. "l2",
            spec.prefix .. "l3" .. branch,
            spec.prefix .. "l4" .. branch,
            spec.prefix .. "ulti",
        }
    end
end

-- Apply Slot 1 (Cataclysm) + Slot 2 (P1 default) + Slot 3 (empty -> Hero Ult) to snapshot
function M.apply_power_slots_to_snapshot(snap, loadout)
    if type(snap) ~= "table" then return end
    snap.liuhui = snap.liuhui or {}
    local cat_id = M.normalize_cataclysm(loadout and loadout.cataclysm)
    local r1 = M.get_player_reinf_spec(loadout and loadout.reinforcements, 1)
    snap.liuhui.power_selection = {
        slots = {
            [1] = cat_id,
            [2] = r1.option_id,
            [3] = "empty_spell",
        },
    }
end

-- Scheme B: Heroes start at Lv.1 with 2x XP gain; ultimate is Lv.3 (max) immediately;
-- KR2..5 non-ultimate skills start at Lv.1 and auto-upgrade to Lv.2 at Hero Lv.4 and Lv.3 at Hero Lv.7;
-- KR6 hero nodes are patched once at match start (including max ulti) while hero starts Lv.1.
function M.apply_hero_scheme_b_to_snapshot(snap, heroes)
    if type(snap) ~= "table" then return end
    snap.liuhui = snap.liuhui or {}
    snap.liuhui.g1_level10 = false
    snap.heroes = snap.heroes or { selected = "hero_vesper", status = {} }
    snap.heroes.status = snap.heroes.status or {}

    local ok_md, map_data = pcall(require, "data.map_data")
    local ok_st, slot_tpl = pcall(require, "data.slot_template")
    local ok_h6, h6 = pcall(require, "hero_upgrades_6")
    local ok_gs, GS = pcall(require, "game_settings")
    local tpl_statuses = (ok_st and slot_tpl and slot_tpl.heroes and slot_tpl.heroes.status) or {}
    local h1 = (heroes and heroes[1]) or 53
    local h2 = (heroes and heroes[2]) or 54

    if not (ok_md and map_data and map_data.hero_data) then return end

    for _, hidx in ipairs({ h1, h2 }) do
        local hd = map_data.hero_data[hidx]
        if hd and hd.name then
            local name = hd.name
            local is_g6 = (ok_h6 and h6 and h6.is_hero and h6.is_hero(name)) == true
            if is_g6 then
                snap.heroes.status[name] = { xp = 0, skills = {} }
                if h6.normalize and h6.reset and h6.buy and h6.node_order then
                    h6.normalize(snap)
                    local prefer_t2 = snap.hero_upgrades_6 and snap.hero_upgrades_6[name]
                        and snap.hero_upgrades_6[name].talent_2 == true
                    local skip_talent = prefer_t2 and "talent_1" or "talent_2"
                    h6.reset(snap, name)
                    local pts = (ok_gs and GS and GS.skill_points_for_hero_level) or { 0, 4, 8, 12, 16, 20, 24, 28, 32, 36 }
                    local max_lvl = #pts
                    for _, node_id in ipairs(h6.node_order) do
                        if node_id ~= skip_talent then
                            pcall(h6.buy, snap, name, node_id, max_lvl, pts)
                        end
                    end
                end
            else
                local skills = {}
                local has_tpl_skills = false
                local def_st = tpl_statuses[name]
                if def_st and type(def_st.skills) == "table" then
                    for sk in pairs(def_st.skills) do
                        has_tpl_skills = true
                        skills[sk] = (sk == "ultimate") and 3 or 1
                    end
                end
                local E = get_E()
                local etpl = E and E.entities and E.entities[name]
                if etpl and etpl.hero and type(etpl.hero.skills) == "table" then
                    for sk, sdef in pairs(etpl.hero.skills) do
                        if type(sdef) == "table" and sdef.hr_cost ~= nil then
                            skills[sk] = (sk == "ultimate") and 3 or 1
                            has_tpl_skills = true
                        end
                    end
                end
                if not has_tpl_skills then
                    skills = {}
                end
                snap.heroes.status[name] = {
                    xp = 0,
                    skills = skills,
                }
            end
        end
    end
end

-- Scheme B in-battle automatic skill tier upgrade on hero-level-increased (100% deterministic inside do_tick)
function M.upgrade_hero_skills_for_level(hero, store)
    if not (hero and hero.hero and type(hero.hero.skills) == "table") then return false end
    local lvl = tonumber(hero.hero.level) or 1
    local target_sl = (lvl >= 7) and 3 or ((lvl >= 4) and 2 or 1)
    if target_sl <= 1 then return false end

    local keys = {}
    for sk in pairs(hero.hero.skills) do
        keys[#keys + 1] = sk
    end
    table.sort(keys)

    local changed = false
    for i = 1, #keys do
        local sk = keys[i]
        local s = hero.hero.skills[sk]
        -- Skip ultimate (already max Lv.3) and KR1 auto-stepped skills (xp_level_steps)
        if sk ~= "ultimate" and type(s) == "table" and s.xp_level_steps == nil and s.hr_cost ~= nil then
            local cur = tonumber(s.level) or 0
            if cur < target_sl then
                s.level = target_sl
                changed = true
            end
        end
    end

    if changed and hero.hero.fn_level_up then
        local ok_lu = pcall(hero.hero.fn_level_up, hero, store, true)
        return ok_lu
    end
    return changed
end

-- Patch BOTH G5 reinforcement branch templates (rebel militia & shadow archer) when max_tech is active
-- so 1P & 2P can independently use different G5 reinforcement branches simultaneously!
function M.patch_both_g5_reinf_templates()
    local ok_b, balance = pcall(require, "balance/balance")
    if not (ok_b and balance and balance.upgrades) then return end
    local b = balance.upgrades
    local E = get_E()
    local function T(name) return E and E.get_template and E:get_template(name) end

    if b.reinforcements_thorny_armor then
        local portrait_idxs = { 31, 33 }
        for i = 1, 2 do
            local t = T("soldier_reinforcement_rebel_militia_0" .. i)
            if t and t.health and t.render and t.render.sprites and t.render.sprites[1] then
                t.health.spiked_armor = b.reinforcements_thorny_armor.spiked_armor
                t.render.sprites[1].prefix = "reinforcements_lvl4_0" .. i
                if t.info then t.info.portrait = "gui_bottom_info_image_soldiers_00" .. portrait_idxs[i] end
            end
        end
    end
    if b.reinforcements_night_veil then
        local t = T("soldier_reinforcement_shadow_archer_01")
        if t and t.ranged and t.ranged.attacks and t.ranged.attacks[1] and t.render and t.render.sprites and t.render.sprites[1] then
            if not t._kr_mp_night_veil_applied then
                t._kr_mp_night_veil_applied = true
                if t.render.sprites[1].prefix ~= "reinforcements_lvl4_03" then
                    t.ranged.attacks[1].max_range = t.ranged.attacks[1].max_range + b.reinforcements_night_veil.extra_range
                    t.ranged.attacks[1].cooldown = t.ranged.attacks[1].cooldown - b.reinforcements_night_veil.cooldown_red
                    t.render.sprites[1].prefix = "reinforcements_lvl4_03"
                    if t.info then t.info.portrait = "gui_bottom_info_image_soldiers_0032" end
                end
            end
        end
        local arrow = T("arrow_soldier_re_shadow_archer")
        if arrow and arrow.render and arrow.render.sprites and arrow.render.sprites[1] then
            arrow.render.sprites[1].name = "reinforcements_lvl4_03_arrow"
        end
    end
end

-- Merge resource dependencies for Slot 1 (Cataclysm) + P1 Reinforcement + P2 Reinforcement
function M.merge_power_dependencies(base_deps, psel, loadout)
    local result = {
        required_textures = {},
        scale_required_textures = {},
        required_sounds = {},
        required_exoskeletons = {},
        required_exoskeleton_groups = {},
    }
    local seen = {}
    local function add_list(field, list)
        if type(list) ~= "table" then return end
        for i = 1, #list do
            local v = list[i]
            local k = field .. ":" .. tostring(v)
            if not seen[k] then
                seen[k] = true
                result[field][#result[field] + 1] = v
            end
        end
    end
    local fields = {
        "required_textures", "scale_required_textures", "required_sounds",
        "required_exoskeletons", "required_exoskeleton_groups",
    }
    if type(base_deps) == "table" then
        for _, f in ipairs(fields) do add_list(f, base_deps[f]) end
    end
    if psel and psel.options and type(loadout) == "table" then
        local opt_ids = {
            M.normalize_cataclysm(loadout.cataclysm),
            M.get_player_reinf_spec(loadout.reinforcements, 1).option_id,
            M.get_player_reinf_spec(loadout.reinforcements, 2).option_id,
        }
        for _, oid in ipairs(opt_ids) do
            local opt = psel.options[oid]
            if type(opt) == "table" then
                for _, f in ipairs(fields) do add_list(f, opt[f]) end
            end
        end
    end
    return result
end

function M.apply_coop_xp_boost(GS)
    if not (GS and GS.hero_xp_gain_per_difficulty_mode) then return end
    if not M._saved_xp_multipliers then
        M._saved_xp_multipliers = {}
        for k, v in pairs(GS.hero_xp_gain_per_difficulty_mode) do
            M._saved_xp_multipliers[k] = v
        end
    end
    for k, v in pairs(M.COOP_XP_MULTIPLIERS) do
        GS.hero_xp_gain_per_difficulty_mode[k] = v
    end
end

function M.restore_coop_xp_boost(GS)
    if not (GS and GS.hero_xp_gain_per_difficulty_mode and M._saved_xp_multipliers) then return end
    for k, v in pairs(M._saved_xp_multipliers) do
        GS.hero_xp_gain_per_difficulty_mode[k] = v
    end
end

-- Align local bottom-left power bar so BOTH 1P & 2P see a clean 1/2/3 bar:
--   Slot 1: Cataclysm (Host 1P controls; 2P sees cooldown dimmed)
--   Slot 2: Local player's own Reinforcement (independent icon & CD)
--   Slot 3: Local player's own Hero Ultimate (hidden if local hero has no ult; no extra 'a'/'s' buttons!)
function M.configure_local_power_bar(coop, game_gui)
    if not (coop and coop:is_active() and game_gui) then return end
    local pid = coop.local_pid or 1
    local p1, p3, pa, ps = game_gui.power_1, game_gui.power_3, game_gui.power_a, game_gui.power_s
    local info3 = coop:get_power_slot_info(3)
    local infoa = coop:get_power_slot_info("a")

    -- Identify which button actually owns local_pid's hero ultimate
    local my_ult_btn = nil
    if info3 and info3.kind == "hero_ult" and info3.owner == pid and p3 then
        my_ult_btn = p3
    elseif infoa and infoa.kind == "hero_ult" and infoa.owner == pid and pa then
        my_ult_btn = pa
    end
    coop.local_ult_slot = (my_ult_btn == pa) and "a" or ((my_ult_btn == p3) and 3 or nil)

    -- Hide any extra slot 4/5 background and key badges ('a', 's')
    local container = (p3 and p3.parent) or (pa and pa.parent)
    local nbr3_view = nil
    if container and type(container.children) == "table" then
        for i = 1, #container.children do
            local ch = container.children[i]
            local img = ch and ch.image_name
            if img == "base_power_slot_bg" or img == "power_nbrs_a" or img == "power_nbrs_s" then
                ch.hidden = true
            elseif img == "power_nbrs_0003" then
                nbr3_view = ch
            end
        end
    end

    if ps then ps.hidden = true end

    if my_ult_btn == pa and p3 and pa then
        -- 2P's own hero ult lives in power_a: snap it cleanly into Slot 3's exact coordinates!
        pa.pos.x = p3.pos.x
        pa.pos.y = p3.pos.y
        pa.hidden = false
        p3.hidden = true
        if nbr3_view then nbr3_view.hidden = false end
    elseif my_ult_btn == p3 and p3 then
        p3.hidden = false
        if pa then pa.hidden = true end
        if nbr3_view then nbr3_view.hidden = false end
    else
        -- Local player's hero has no ultimate (e.g. KR1/KR2 classic hero): hide Slot 3 cleanly
        if p3 then p3.hidden = true end
        if pa then pa.hidden = true end
        if nbr3_view then nbr3_view.hidden = true end
    end

    -- Subtle visual cue on 2P's screen that Slot 1 Cataclysm is host-controlled
    if p1 and pid ~= 1 then
        p1.alpha = 0.72
    elseif p1 then
        p1.alpha = 1
    end
end

return M

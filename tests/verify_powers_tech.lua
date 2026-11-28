local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Comprehensive verification suite for Co-op Cataclysm, Independent Reinforcements,
-- Scheme B Hero Progression, Max Tech Snapshot, Power Bar Alignment & 780x486 UI Layout.
package.path = _KR_REPO .. "/client/?.lua;" .. _KR_REPO .. "/client/?/init.lua;D:/FL8.2.0/all/?.lua;D:/FL8.2.0/kr3/?.lua;" .. package.path

local pass_cnt, fail_cnt = 0, 0
local function check(cond, msg)
    if cond then
        pass_cnt = pass_cnt + 1
    else
        fail_cnt = fail_cnt + 1
        print("[FAIL] " .. tostring(msg))
    end
end

-- 1. Syntax-compile every client/kr_mp/*.lua file
local lfs_cmd = io.popen('dir /b "' .. _KR_REPO:gsub("/", "\\") .. '\\client\\kr_mp\\*.lua"')
for fname in lfs_cmd:lines() do
    local fn, err = loadfile(_KR_REPO .. "/client/kr_mp/" .. fname)
    check(fn ~= nil, "syntax compile " .. fname .. ": " .. tostring(err))
end
lfs_cmd:close()

-- Stub minimal FL globals for unit testing
local E_stub = {
    entities = {
        hero_vesper = {
            hero = {
                skills = {
                    arrow_to_the_knee = { hr_cost = { 1, 2, 3 } },
                    ricochet = { hr_cost = { 1, 2, 3 } },
                    martial_flourish = { hr_cost = { 1, 2, 3 } },
                    disengage = { hr_cost = { 1, 2, 3 } },
                    ultimate = { hr_cost = { 2, 3, 4 }, controller_name = "controller_hero_vesper_ult" },
                },
            },
        },
        hero_raelyn = {
            hero = {
                skills = {
                    dark_blade = { hr_cost = { 1, 2, 3 } },
                    unbreakable = { hr_cost = { 1, 2, 3 } },
                    onslaught = { hr_cost = { 1, 2, 3 } },
                    brutal_slash = { hr_cost = { 1, 2, 3 } },
                    ultimate = { hr_cost = { 2, 3, 4 }, controller_name = "controller_hero_raelyn_ult" },
                },
            },
        },
        hero_gerald = { hero = { skills = { block_counter = { xp_level_steps = { [2] = 1 } } } } },
        hero_gerald_g6 = { hero = { skills = { ultimate = { controller_name = "controller_hero_gerald_g6_ult" } } } },
    },
}
function E_stub:get_template(n) return self.entities[n] end
package.loaded["entity_db"] = E_stub
package.loaded["klua.macros"] = { round = function(x) return math.floor(x + 0.5) end }
package.loaded["klua.log"] = { new = function() return { debug = function() end, info = function() end, error = function() end } end }
package.loaded["klua.table"] = {}
table.deepclone = function(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = table.deepclone(v) end
    return r
end
table.contains = function(t, val)
    for _, v in ipairs(t) do if v == val then return true end end
    return false
end

local sig_cbs = {}
package.loaded["hump.signal"] = {
    register = function(ev, fn) sig_cbs[ev] = fn end,
    emit = function(ev, ...) if sig_cbs[ev] then sig_cbs[ev](...) end end,
}

-- Mock love graphics/font/mouse for 780x486 UI rendering verification
local mock_font = {
    getWidth = function(_, s) return #(tostring(s or "")) * 6 end,
    getHeight = function() return 13 end,
    getWrap = function(_, s, w)
        local lines = {}
        for line in (tostring(s or "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        return math.min(w or 200, 120), lines
    end,
}
_G.love = {
    graphics = setmetatable({
        getWidth = function() return 1280 end,
        getHeight = function() return 720 end,
        newFont = function() return mock_font end,
        getFont = function() return mock_font end,
    }, { __index = function() return function() end end }),
    mouse = { getPosition = function() return 0, 0 end },
    timer = { getTime = function() return 10 end },
    system = { getOS = function() return "Windows" end },
    filesystem = { getSaveDirectory = function() return "." end, exists = function() return false end },
}
_G.TICK_LENGTH = 1 / 60
_G.KR_FL_VERSION = "8.2.0"

-- Stub minimal FL modules needed by coop_loadout
local real_power_upgrades_6 = dofile("D:/FL8.2.0/all/power_upgrades_6.lua")
package.loaded["power_upgrades_6"] = real_power_upgrades_6
package.loaded["upgrades"] = { get_user_levels = function() return { reinforcements = 5, thunder = 5 } end }
package.loaded["upgrades_6"] = {
    tree_order = { "g6_archers", "g6_barracks", "g6_mages", "g6_artillery" },
    trees = {
        g6_archers = { items = { { key = "archers_l1", level = 1, price = 1 }, { key = "archers_l2", level = 2, price = 2, requires = { "archers_l1" } }, { key = "archers_l3a", level = 3, price = 3, requires = { "archers_l2" }, blocks = { "archers_l3b" } }, { key = "archers_l3b", level = 3, price = 3, requires = { "archers_l2" }, blocks = { "archers_l3a" } }, { key = "archers_l4a", level = 4, price = 3, requires = { "archers_l3a" }, blocks = { "archers_l4b" } }, { key = "archers_l4b", level = 4, price = 3, requires = { "archers_l3b" }, blocks = { "archers_l4a" } }, { key = "archers_ulti", level = 5, price = 5, requires_any = { "archers_l4a", "archers_l4b" } } } },
        g6_barracks = { items = { { key = "barracks_l1", level = 1, price = 1 }, { key = "barracks_l2", level = 2, price = 2, requires = { "barracks_l1" } }, { key = "barracks_l3a", level = 3, price = 3, requires = { "barracks_l2" }, blocks = { "barracks_l3b" } }, { key = "barracks_l3b", level = 3, price = 3, requires = { "barracks_l2" }, blocks = { "barracks_l3a" } }, { key = "barracks_l4a", level = 4, price = 3, requires = { "barracks_l3a" }, blocks = { "barracks_l4b" } }, { key = "barracks_l4b", level = 4, price = 3, requires = { "barracks_l3b" }, blocks = { "barracks_l4a" } }, { key = "barracks_ulti", level = 5, price = 5, requires_any = { "barracks_l4a", "barracks_l4b" } } } },
        g6_mages = { items = { { key = "mages_l1", level = 1, price = 1 }, { key = "mages_l2", level = 2, price = 2, requires = { "mages_l1" } }, { key = "mages_l3a", level = 3, price = 3, requires = { "mages_l2" }, blocks = { "mages_l3b" } }, { key = "mages_l3b", level = 3, price = 3, requires = { "mages_l2" }, blocks = { "mages_l3a" } }, { key = "mages_l4a", level = 4, price = 3, requires = { "mages_l3a" }, blocks = { "mages_l4b" } }, { key = "mages_l4b", level = 4, price = 3, requires = { "mages_l3b" }, blocks = { "mages_l4a" } }, { key = "mages_ulti", level = 5, price = 5, requires_any = { "mages_l4a", "mages_l4b" } } } },
        g6_artillery = { items = { { key = "artillery_l1", level = 1, price = 1 }, { key = "artillery_l2", level = 2, price = 2, requires = { "artillery_l1" } }, { key = "artillery_l3a", level = 3, price = 3, requires = { "artillery_l2" }, blocks = { "artillery_l3b" } }, { key = "artillery_l3b", level = 3, price = 3, requires = { "artillery_l2" }, blocks = { "artillery_l3a" } }, { key = "artillery_l4a", level = 4, price = 3, requires = { "artillery_l3a" }, blocks = { "artillery_l4b" } }, { key = "artillery_l4b", level = 4, price = 3, requires = { "artillery_l3b" }, blocks = { "artillery_l4a" } }, { key = "artillery_ulti", level = 5, price = 5, requires_any = { "artillery_l4a", "artillery_l4b" } } } },
    },
}
local real_gen_up = dofile("D:/FL8.2.0/all/generation_upgrades.lua")
package.loaded["generation_upgrades"] = real_gen_up
local real_psel = dofile("D:/FL8.2.0/all/power_selection.lua")
package.loaded["power_selection"] = real_psel
package.loaded["data.map_data"] = {
    hero_data = {
        [1]  = { name = "hero_gerald" },
        [53] = { name = "hero_vesper" },
        [54] = { name = "hero_raelyn" },
        [91] = { name = "hero_gerald_g6" },
    },
}
package.loaded["data.slot_template"] = {
    heroes = {
        status = {
            hero_vesper = { xp = 0, skills = { arrow_to_the_knee = 0, ricochet = 0, martial_flourish = 0, disengage = 0, ultimate = 0 } },
            hero_raelyn = { xp = 0, skills = { dark_blade = 0, unbreakable = 0, onslaught = 0, brutal_slash = 0, ultimate = 0 } },
            hero_gerald = { xp = 0, skills = {} },
            hero_gerald_g6 = { xp = 0, skills = {} },
        },
    },
}
package.loaded["hero_upgrades_6"] = {
    node_order = { "skill_a", "upg_sa1", "talent_1", "talent_2", "ulti" },
    is_hero = function(n) return n == "hero_gerald_g6" end,
    normalize = function(u) u.hero_upgrades_6 = u.hero_upgrades_6 or {} end,
    reset = function(u, n) u.hero_upgrades_6 = u.hero_upgrades_6 or {}; u.hero_upgrades_6[n] = {} end,
    buy = function(u, n, node_id) u.hero_upgrades_6[n][node_id] = true; return true end,
}
local GS_stub = {
    hero_xp_gain_per_difficulty_mode = { [1] = 2, [2] = 1.1, [3] = 1, [4] = 1 },
    skill_points_for_hero_level = { 0, 4, 8, 12, 16, 20, 24, 28, 32, 36 },
}
package.loaded["game_settings"] = GS_stub

local loadout = require("kr_mp.coop_loadout")

-- 2. Test Max Tech Snapshot + FL generation_upgrades.normalize validation
local snap = { generation_upgrades = { g6_archers = { "archers_l1", "archers_l2", "archers_l3a" } } }
local ld = { cataclysm = "fireball_g6", reinforcements = { "reinforcement_g4_royal", "reinforcement_g5_dark" }, max_tech = true }
loadout.apply_power_slots_to_snapshot(snap, ld)
loadout.apply_max_tech_to_snapshot(snap, ld)
real_gen_up.normalize(snap)
real_psel.normalize(snap)

check(snap.upgrades_by_generation[1].archers == 5 and snap.upgrades_by_generation[3].reinforcements == 5, "1..3 gen tech maxed to 5")
check(snap.upgrades.thunder == 5 and snap.upgrades.rocks == 5, "legacy upgrades thunder & rocks maxed to 5")
check(#snap.generation_upgrades.g4_towers == 8, "g4_towers all 8 unlocked")
check(#snap.generation_upgrades.g5_towers == 8, "g5_towers all 8 unlocked")
check(real_gen_up.level(snap, "g4_reinforcements") == 5, "g4_reinforcements level 5")
check(real_gen_up.g4_reinforcement_branch(snap) == "royal", "g4 branch respects P1 royal choice")
check(real_gen_up.level(snap, "g5_reinforcements") == 5, "g5_reinforcements level 5")
check(real_gen_up.has_key(snap, "archers_l4a") and real_gen_up.has_key(snap, "archers_ulti"), "g6_archers preserved host branch A and maxed to ulti")
check(real_gen_up.has_key(snap, "artillery_l4a") and real_gen_up.has_key(snap, "artillery_ulti"), "g6_artillery filled default branch A to ulti")
check(snap.liuhui.power_selection.slots[1] == "fireball_g6", "slot 1 = fireball_g6")
check(snap.liuhui.power_selection.slots[2] == "reinforcement_g4", "slot 2 = reinforcement_g4")
check(snap.liuhui.power_selection.slots[3] == "empty_spell", "slot 3 = empty_spell for hero ult")

-- 3. Test dependency merging for cross-gen P1 G4 + P2 G6 + Host G6 Fireball
local merged = loadout.merge_power_dependencies(
    real_psel.get_selected_dependencies(snap),
    real_psel,
    { cataclysm = "fireball_g6", reinforcements = { "reinforcement_g4_dark", "reinforcement_g6" } }
)
check(table.contains(merged.scale_required_textures, "kr4_power_reinforcements"), "merged deps include P1 G4 reinforcement texture")
check(table.contains(merged.required_textures, "go_power_reinforcements"), "merged deps include P2 G6 reinforcement texture")
check(table.contains(merged.required_textures, "go_power_rain_of_fire"), "merged deps include G6 fireball texture")
check(table.contains(merged.required_sounds, "powers_reinforcements"), "merged deps include P2 G6 reinforcement sound")

-- 4. Test Scheme B Hero Initialization & Auto-Tier Skill Leveling
snap.hero_upgrades_6 = { hero_gerald_g6 = { talent_2 = true } }
loadout.apply_hero_scheme_b_to_snapshot(snap, { 53, 91 })
check(snap.heroes.status.hero_vesper.xp == 0, "KR5 hero starts at xp=0 (Lv.1)")
check(snap.heroes.status.hero_vesper.skills.ultimate == 3, "KR5 hero ultimate defaults to max Lv.3")
check(snap.heroes.status.hero_vesper.skills.ricochet == 1, "KR5 hero normal skill starts at Lv.1")
check(snap.heroes.status.hero_gerald_g6.xp == 0, "KR6 hero starts at xp=0 (Lv.1)")
check(snap.hero_upgrades_6.hero_gerald_g6.ulti == true, "KR6 hero ulti node unlocked")
check(snap.hero_upgrades_6.hero_gerald_g6.talent_2 == true and snap.hero_upgrades_6.hero_gerald_g6.talent_1 == nil, "KR6 hero preserved host talent_2")

local lu_calls = 0
local mock_hero = {
    hero = {
        level = 3,
        skills = {
            ricochet = { level = 1, hr_cost = { 1, 2, 3 } },
            disengage = { level = 1, hr_cost = { 1, 2, 3 } },
            ultimate = { level = 3, hr_cost = { 2, 3, 4 } },
        },
        fn_level_up = function(self_h, st, init)
            if init then lu_calls = lu_calls + 1 end
        end,
    },
}
check(not loadout.upgrade_hero_skills_for_level(mock_hero, {}), "Lv.3 does not bump skills yet")
mock_hero.hero.level = 4
check(loadout.upgrade_hero_skills_for_level(mock_hero, {}), "Lv.4 bumps normal skills to Lv.2")
check(mock_hero.hero.skills.ricochet.level == 2 and mock_hero.hero.skills.ultimate.level == 3 and lu_calls == 1, "Lv.4 skills=2, ult=3, fn_level_up(initial=true) called")
mock_hero.hero.level = 7
check(loadout.upgrade_hero_skills_for_level(mock_hero, {}), "Lv.7 bumps normal skills to Lv.3")
check(mock_hero.hero.skills.ricochet.level == 3 and mock_hero.hero.skills.disengage.level == 3 and lu_calls == 2, "Lv.7 skills=3")

-- 5. Test XP multiplier apply & restore
loadout.apply_coop_xp_boost(GS_stub)
check(GS_stub.hero_xp_gain_per_difficulty_mode[2] == 2.2 and GS_stub.hero_xp_gain_per_difficulty_mode[4] == 2.0, "Co-op XP boost applied")
loadout.restore_coop_xp_boost(GS_stub)
check(GS_stub.hero_xp_gain_per_difficulty_mode[2] == 1.1 and GS_stub.hero_xp_gain_per_difficulty_mode[4] == 1, "Co-op XP boost restored cleanly")

-- 6. Test Coop permission rules (Host-only Cataclysm, Independent Reinf CD, Power Bar Alignment)
local coop = require("kr_mp.coop")
coop.active = true
coop.local_pid = 2
coop.slot_snapshot = snap
coop.cataclysm = "fireball_g6"
coop.reinforcements = { [1] = "reinforcement_g4_royal", [2] = "reinforcement_g5_dark" }
coop.reinf_ready_tick = { [1] = 0, [2] = 0 }
coop.shared_power_ready_tick = {}
coop.hero_ult_ready_tick = {}
_G.game = { store = { tick = 100 } }

local ok_cat1 = coop:can_use_power(1, 1)
local ok_cat2, cat_owner, cat_reason = coop:can_use_power(2, 1)
check(ok_cat1 == true, "1P Host CAN cast Slot 1 Cataclysm")
check(ok_cat2 == false and cat_owner == 1 and cat_reason == "host_cataclysm", "2P Guest BLOCKED from Slot 1 Cataclysm")

coop:on_power_fired(1, 2, 14)
check(coop:can_use_power(1, 2) == false, "1P Reinf enters CD after 1P fires")
check(coop:can_use_power(2, 2) == true, "2P Reinf stays READY independently when 1P fires")

-- Test power bar alignment for 2P when both heroes have ults (53 & 91)
snap.liuhui_hero = { usedoublehero = true, herolist = { [1] = 53, [2] = 91 } }
local bg_extra = { image_name = "base_power_slot_bg", hidden = false }
local nbr3 = { image_name = "power_nbrs_0003", hidden = false }
local nbra = { image_name = "power_nbrs_a", hidden = false }
local nbrs = { image_name = "power_nbrs_s", hidden = false }
local container = { children = { bg_extra, nbr3, nbra, nbrs } }
local mock_gui = {
    power_1 = { alpha = 1, hidden = false, pos = { x = 29, y = 30 }, parent = container },
    power_3 = { hidden = false, pos = { x = 155, y = 30 }, parent = container },
    power_a = { hidden = false, pos = { x = 218, y = 30 }, parent = container },
    power_s = { hidden = false, pos = { x = 281, y = 30 }, parent = container },
}
loadout.configure_local_power_bar(coop, mock_gui)
check(coop.local_ult_slot == "a", "2P local_ult_slot mapped to power_a")
check(mock_gui.power_3.hidden == true, "2P hides 1P's power_3")
check(mock_gui.power_a.hidden == false and mock_gui.power_a.pos.x == 155 and mock_gui.power_a.pos.y == 30, "2P snaps own power_a onto Slot 3 pos (155,30)")
check(bg_extra.hidden == true and nbra.hidden == true and nbrs.hidden == true and nbr3.hidden == false, "2P hides extra slot4 bg & a/s labels, keeps '3' badge")
check(mock_gui.power_1.alpha < 1, "2P dims host-only Slot 1 slightly")

-- Test 1P power bar alignment when 1P has no ult (hero_gerald #1) and 2P has ult (#53)
coop.local_pid = 1
snap.liuhui_hero = { usedoublehero = true, herolist = { [1] = 1, [2] = 53 } }
mock_gui.power_1.alpha = 1
mock_gui.power_3.hidden = false
mock_gui.power_a.hidden = true
nbr3.hidden = false
loadout.configure_local_power_bar(coop, mock_gui)
check(coop.local_ult_slot == nil and mock_gui.power_3.hidden == true and nbr3.hidden == true, "1P with no-ult hero hides Slot 3 (does not show 2P's ult)")

-- 7. Test 780x486 UI Layout & Button Collision Check for draw_room & draw_powers (Host & Client)
local lobby_draw = require("kr_mp.lobby_draw")
local function check_no_overlap(btns, label)
    for i = 1, #btns do
        local a = btns[i]
        check(a.x >= 0 and a.x + a.w <= 790 and a.y >= -12 and a.y + a.h <= 486,
            string.format("%s btn %s in bounds (%d,%d,%d,%d)", label, tostring(a.id), a.x, a.y, a.w, a.h))
        for j = i + 1, #btns do
            local b = btns[j]
            local ov = a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y
            check(not ov, string.format("%s overlap %s vs %s", label, tostring(a.id), tostring(b.id)))
        end
    end
end

local function mk_lobby(role, sub_modal)
    local l = {
        open = true, view = "room", role = role, local_pid = (role == "host") and 1 or 2,
        sub_modal = sub_modal, peer_connected = true, peer_ready = true, local_ready = true,
        reinf_edit_pid = (role == "host") and 1 or 2,
        room = {
            name = "Test", level_idx = 101, level_mode = 1, level_difficulty = 2,
            econ_mode = "independent", tower_mode = "owned", input_delay_turns = 2,
            heroes = { 53, 54 }, towers = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
            cataclysm = "fireball_g6", reinforcements = { "reinforcement_g4_dark", "reinforcement_g5_royal" },
            max_tech = true,
        },
        ensure_room_defaults = function(r) loadout.normalize_room_loadout(r) end,
        normalize_delay_turns = function(v) return v or 2 end,
        DELAY_LABELS = { [2] = "缓冲:局域网100ms" },
        transport = {
            is_online = function() return false end,
            get_rtt_ms = function() return 15 end,
            get_port = function() return 17777 end,
            is_port_drifted = function() return false end,
        },
        voice = {
            supported = true, mode = "ptt", local_talking = false, peer_muted = false, self_test = false,
            get_mode_lobby_label = function() return "按V说话" end,
            get_seat_state = function() return false, 0 end,
        },
        buttons = {},
    }
    return l
end

for _, case in ipairs({
    { "host", nil, "Room-Host" },
    { "client", nil, "Room-Client" },
    { "host", "powers", "PowersModal-Host" },
    { "client", "powers", "PowersModal-Client" },
}) do
    local l = mk_lobby(case[1], case[2])
    lobby_draw.draw(l)
    check(#l.buttons >= 5, case[3] .. " rendered buttons (" .. #l.buttons .. ")")
    check_no_overlap(l.buttons, case[3])
end

print(string.format("SUMMARY: %d PASS, %d FAIL", pass_cnt, fail_cnt))
if fail_cnt > 0 then error("suite failed: " .. tostring(fail_cnt) .. " failures") end

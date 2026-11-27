-- KR-MP Runtime Hook Coordinator for Kingdom Rush FL 8.2.0
-- Zero modification to original exe; attaches cleanly at runtime via UH.lua.
-- Submodules:
--   hooks_determinism.lua : PRNG/pairs/SSO/entity_db/storage/comic determinism
--   hooks_sim.lua         : simulation & game lifecycle, 60Hz lockstep, main_script isolation
--   hooks_gui_actions.lua : combat/tower/hero/reinf/power/wave/hotkey interception
--   hooks_gui_guards.lua  : UI-to-sim leak guards, PauseView/DragEntityView safety
local prng = require("kr_mp.prng")
local commands = require("kr_mp.commands")

local LOCAL_ID_BASE = 100000000
local LOCAL_UI_TEMPLATES = {
    clickable_hover_circle_controller = true,
    clickable_hover_circle = true,
    tower_ghost_hover_controller = true,
    tower_ghost_hover = true,
    entity_marker_controller = true,
    controller_path_direction = true,
    decal_path_hero_movement = true,
    path_marching_ants_controller = true,
    decal_path_marching_ant = true,
}

local VISUAL_SYSTEMS = {
    particle_system = true,
    render = true,
    sound_events = true,
    texts = true,
    seen_tracker = true,
    performance_monitor = true,
}

local orig_pairs = pairs
local orig_coroutine_create = coroutine.create
local wrapped_registry = setmetatable({}, { __mode = "k" })

local hooks = {
    LOCAL_ID_BASE = LOCAL_ID_BASE,
    VISUAL_SYSTEMS = VISUAL_SYSTEMS,
    orig_pairs = orig_pairs,
    orig_coroutine_create = orig_coroutine_create,

    boot = nil,
    replay = nil,
    overlay = nil,
    coop = nil,
    lockstep = nil,
    installed_core = false,
    installed_game = false,
    installed_gui = false,
    active_store = nil,
    sso_ref = nil,
    entity_ids = {},
    co_seq = setmetatable({}, { __mode = "k" }),
    co_counter = 0,
    sim_exec_depth = 0,
    local_entity_depth = 0,
    local_entity_id = LOCAL_ID_BASE,
}

function hooks.is_local_template(t)
    local name = (type(t) == "string") and t or (type(t) == "table" and t.template_name) or ""
    if LOCAL_UI_TEMPLATES[name] then return true end
    if name:sub(1, 20) == "decal_entity_marker_" then return true end
    if name:find("path_direction", 1, true) then return true end
    if name:find("clickable_hover", 1, true) then return true end
    if name:find("tower_ghost_hover", 1, true) then return true end
    return false
end

-- Entities whose main_script must NEVER enter FL 8.2.0's swap-remove simulation main_script array:
-- 1) pure local UI controllers/markers (_kr_mp_local / LOCAL_ID_BASE), and
-- 2) pure visual particle_system emitters that expire at render FPS via visual PRNG.
function hooks.is_isolated_main_script_entity(e)
    if not e then return false end
    if e._kr_mp_local then return true end
    if type(e.id) == "number" and e.id >= LOCAL_ID_BASE then return true end
    if hooks.is_local_template(e) then return true end
    if e.particle_system
        and not e.enemy and not e.soldier and not e.hero and not e.tower
        and not e.bullet and not e.modifier and not e.health and not e.aura then
        return true
    end
    return false
end

-- Idempotent hook registration backed by a weak-keyed table (zero `_kr_mp_*_wrapped` pollution on engine tables).
function hooks.wrap_once(tbl, key, tag, builder)
    if type(tbl) ~= "table" then return false end
    local orig = tbl[key]
    if type(orig) ~= "function" then return false end
    local rec = wrapped_registry[tbl]
    if not rec then
        rec = {}
        wrapped_registry[tbl] = rec
    end
    local reg_key = tostring(tag or "default") .. ":" .. tostring(key)
    if rec[reg_key] then return false end
    rec[reg_key] = true
    local wrapped = builder(orig)
    if type(wrapped) == "function" then
        tbl[key] = wrapped
    end
    return true
end

-- Wrap a pure-UI method so any temporary entities or random calls stay in local ID + visual PRNG isolation.
function hooks.wrap_local_ui(tbl, method_name)
    return hooks.wrap_once(tbl, method_name, "local_ui", function(orig_fn)
        return function(...)
            hooks.local_entity_depth = hooks.local_entity_depth + 1
            prng:enter_visual()
            local ok_u, r1, r2, r3 = pcall(orig_fn, ...)
            prng:exit_visual()
            hooks.local_entity_depth = hooks.local_entity_depth - 1
            if not ok_u then error(r1) end
            return r1, r2, r3
        end
    end)
end

function hooks:add_entity_id(id)
    if type(id) ~= "number" then return end
    local ids = self.entity_ids
    local n = #ids
    if n == 0 or id > ids[n] then
        ids[n + 1] = id
    else
        ids[n + 1] = id
        table.sort(ids)
    end
end

function hooks:compact_entity_ids(entities)
    local ids = self.entity_ids
    local out = {}
    local j = 0
    local prev = nil
    for i = 1, #ids do
        local id = ids[i]
        if id ~= prev and entities[id] ~= nil then
            j = j + 1
            out[j] = id
            prev = id
        end
    end
    self.entity_ids = out
end

function hooks:is_mp_active()
    return self.coop ~= nil and self.coop:is_active()
end

function hooks:is_sync_active()
    return self:is_mp_active() or (self.replay ~= nil and self.replay:is_active())
end

function hooks:submit_command(cmd)
    if self:is_mp_active() and self.lockstep then
        return self.lockstep:queue_local_command(cmd)
    elseif self.replay then
        return self.replay:record_command(cmd)
    end
    return false
end

local hooks_determinism = require("kr_mp.hooks_determinism")
local hooks_sim = require("kr_mp.hooks_sim")
local hooks_gui_actions = require("kr_mp.hooks_gui_actions")
local hooks_gui_guards = require("kr_mp.hooks_gui_guards")

function hooks:install_global_determinism()
    hooks_determinism.install(self)
end

function hooks:install_simulation_hooks()
    hooks_sim.install_simulation(self)
end

function hooks:install_game_hooks(g)
    hooks_sim.install_game(self, g)
end

function hooks:install_gui_hooks(gui)
    if self.installed_gui then return end
    gui = gui or (game and game.game_gui) or package.loaded["game_gui"]
    if not gui or not PickView or not TowerMenuButton then return end
    self.installed_gui = true

    hooks_gui_actions.install(self, gui)
    hooks_gui_guards.install(self, gui)
    self.boot:log("GUI command hooks installed successfully.")
end

function hooks:ensure_game_and_gui_hooks()
    if game and not self.installed_game then
        self:install_game_hooks(game)
    end
    local gui = (game and game.game_gui) or package.loaded["game_gui"]
    if gui and not self.installed_gui then
        self:install_gui_hooks(gui)
    end
end

function hooks:on_update(dt)
    if main and main.handler then
        local ai = main.handler.active_item and main.handler.active_item.item_name or "nil"
        local qi = main.handler.queued_item and main.handler.queued_item.item_name or "nil"
        local key = ai .. "->" .. qi
        if key ~= self._last_screen_key then
            self._last_screen_key = key
            self.boot:log("DIRECTOR state: active=%s queued=%s", ai, qi)
        end
    end
    if self.coop and self.coop.try_launch_pending then
        self.coop:try_launch_pending()
    end
    if not self.installed_game or not self.installed_gui then
        self:ensure_game_and_gui_hooks()
    end
    if self.replay and self.replay.on_frame_update then
        self.replay:on_frame_update()
    end
end

function hooks:init(boot, replay, overlay, coop, lockstep)
    if self.installed_core then return end
    self.installed_core = true
    self.boot = boot
    self.replay = replay
    self.overlay = overlay
    self.coop = coop
    self.lockstep = lockstep
    commands:set_mp(coop, lockstep)

    prng:install()
    self:install_global_determinism()
    self:install_simulation_hooks()
end

return hooks

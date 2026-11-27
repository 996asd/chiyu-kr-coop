-- KR-MP Lobby Input & Table-Driven Button Action Dispatcher
local proto = require("kr_mp.proto")
local fonts = require("kr_mp.fonts")
local catalog = require("kr_mp.catalog")
local updater = require("kr_mp.updater")
local lobby_prefs = require("kr_mp.lobby_prefs")
local ui = require("kr_mp.ui_assets")

local M = {}

local INPUT_BOX_IDS = {
    ip_box = true,
    server_box = true,
    code_box = true,
    pw_box = true,
}

local TAB_SFX_IDS = {
    tab_lan = true, tab_online = true,
    stage_pack = true, hero_pack = true, tower_pack = true,
    open_stages = true, open_hero1 = true, open_hero2 = true, open_towers = true,
    open_guide = true, guide_tab = true,
}

local function toggle_tower_in_deck(deck, tid)
    for i = 1, #deck do
        if deck[i] == tid then
            if #deck <= 1 then
                return false, "至少保留 1 座防御塔！"
            end
            table.remove(deck, i)
            return true
        end
    end
    if #deck >= 12 then
        return false, "最多携带 12 座防御塔！请先点掉 1 座已选塔。"
    end
    deck[#deck + 1] = tid
    table.sort(deck)
    return true
end

local BTN_HANDLERS = {}

function BTN_HANDLERS.close(lobby)
    lobby.open = false
    lobby.sub_modal = nil
    if lobby.overlay then lobby.overlay:clear_toast() end
end

function BTN_HANDLERS.check_update(lobby)
    if updater.ota_applied then
        updater:restart_game()
    elseif updater.ota_updating then
        lobby.overlay:show_toast("正在下载并校验热更新补丁，请稍候几秒...", 2.0)
    elseif updater.ota_ready then
        updater:start_ota_apply()
    elseif updater.has_update then
        updater:open_download_page()
    else
        updater:start_check(true)
    end
end

function BTN_HANDLERS.modal_back(lobby)
    lobby.sub_modal = nil
    if lobby.overlay then lobby.overlay:clear_toast() end
end

function BTN_HANDLERS.open_guide(lobby, btn)
    if lobby.overlay then lobby.overlay:clear_toast() end
    if not lobby.seen_guide then
        lobby.seen_guide = true
        lobby:save_prefs()
    end
    lobby.guide_tab = tonumber(btn.tab) or ((lobby.view == "room") and 2 or 1)
    lobby.sub_modal = "guide"
end

function BTN_HANDLERS.guide_tab(lobby, btn)
    if btn.tab then
        lobby.guide_tab = math.max(1, math.min(4, tonumber(btn.tab) or 1))
    end
end

function BTN_HANDLERS.guide_prev(lobby)
    lobby.guide_tab = math.max(1, (lobby.guide_tab or 1) - 1)
end

function BTN_HANDLERS.guide_next(lobby)
    lobby.guide_tab = math.min(4, (lobby.guide_tab or 1) + 1)
end

function BTN_HANDLERS.tab_lan(lobby)
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby:switch_tab("lan")
end

function BTN_HANDLERS.tab_online(lobby)
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby:switch_tab("online")
end

-- LAN / SakuraFrp Home
function BTN_HANDLERS.host_lan(lobby) lobby:host_lan_room() end
function BTN_HANDLERS.join_local(lobby) lobby:join_lan_room("127.0.0.1", proto.DEFAULT_TCP_PORT) end
function BTN_HANDLERS.ip_box(lobby) lobby:set_focus("ip") end
function BTN_HANDLERS.paste_ip(lobby) lobby:paste_into_field("ip") end
function BTN_HANDLERS.join_ip(lobby)
    lobby.ip_input = proto.sanitize_addr(lobby.ip_input):sub(1, 80)
    lobby_prefs.record_recent_addr(lobby, lobby.ip_input)
    lobby:save_prefs()
    lobby:join_lan_room(lobby.ip_input)
end
function BTN_HANDLERS.sakura_carrier(lobby, btn)
    local next_addr = lobby_prefs.switch_sakura_carrier(lobby.ip_input, btn.carrier)
    if next_addr then
        lobby.ip_input = next_addr
        lobby_prefs.record_recent_addr(lobby, next_addr)
        lobby:save_prefs()
        local names = { default = "默认线", dx = "电信专线 (dx.)", yd = "移动专线 (yd.)" }
        lobby.overlay:show_toast("已切至樱花" .. (names[btn.carrier] or "默认线") .. "：" .. next_addr, 2.5)
    end
end
function BTN_HANDLERS.use_recent_addr(lobby, btn)
    if type(btn.addr) == "string" and #btn.addr > 0 then
        lobby.ip_input = btn.addr
        lobby_prefs.record_recent_addr(lobby, btn.addr)
        lobby:save_prefs()
        lobby:join_lan_room(btn.addr)
    end
end
function BTN_HANDLERS.reconnect_direct(lobby) lobby:reconnect_direct_session(lobby.saved_session) end
function BTN_HANDLERS.join_lan_room(lobby, btn)
    if btn.room then lobby:join_lan_room(btn.room.ip, btn.room.port) end
end
function BTN_HANDLERS.copy_net_info(lobby)
    if lobby.transport:is_online() then
        local code = tostring(lobby.online_room_code or "")
        if #code > 0 then
            lobby:copy_to_clipboard(code, "已复制房间码：" .. code .. "，发给好友即可进房！")
        end
    elseif lobby.role == "host" then
        local port = lobby.transport:get_port()
        lobby:copy_to_clipboard("127.0.0.1:" .. tostring(port),
            string.format("已复制本机端口 127.0.0.1:%d（樱花隧道本地端口请设为 %d）", port, port))
    else
        local addr = tostring(lobby.last_direct_host or lobby.ip_input or "127.0.0.1")
        if lobby.last_direct_port and not addr:find(":", 1, true) then
            addr = addr .. ":" .. tostring(lobby.last_direct_port)
        end
        lobby:copy_to_clipboard(addr, "已复制房主地址：" .. addr)
    end
end

-- Online Home
function BTN_HANDLERS.server_box(lobby) lobby:set_focus("server") end
function BTN_HANDLERS.paste_server(lobby) lobby:paste_into_field("server") end
function BTN_HANDLERS.connect_server(lobby)
    lobby.server_input = proto.sanitize_addr(lobby.server_input):sub(1, 80)
    lobby:save_prefs()
    lobby:connect_online_server(lobby.server_input, false)
end
function BTN_HANDLERS.refresh_online(lobby) lobby:refresh_online_rooms() end
function BTN_HANDLERS.code_box(lobby) lobby:set_focus("code") end
function BTN_HANDLERS.pw_box(lobby) lobby:set_focus("pw") end
function BTN_HANDLERS.toggle_public(lobby) lobby.room_public = not lobby.room_public end
function BTN_HANDLERS.create_online(lobby) lobby:create_online_room(lobby.pw_input, lobby.room_public) end
function BTN_HANDLERS.join_code(lobby) lobby:join_online_room(lobby.code_input, lobby.pw_input) end
function BTN_HANDLERS.join_online_room(lobby, btn)
    if btn.room then lobby:join_online_room(btn.room.code, lobby.pw_input) end
end
function BTN_HANDLERS.reconnect_last(lobby) lobby:reconnect_online_session(lobby.saved_session) end

-- Room View
function BTN_HANDLERS.leave_room(lobby) lobby:leave_room() end
function BTN_HANDLERS.start_match(lobby) lobby:host_start_match() end

function BTN_HANDLERS.open_stages(lobby)
    if lobby.role ~= "host" then return end
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby.sub_modal = "stages"
end

function BTN_HANDLERS.open_hero1(lobby)
    if lobby.role ~= "host" then return end
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby.sub_modal = "hero1"
end

function BTN_HANDLERS.open_hero2(lobby)
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby.sub_modal = "hero2"
end

function BTN_HANDLERS.open_towers(lobby)
    if lobby.role ~= "host" then return end
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby.ensure_room_defaults(lobby.room)
    lobby.sub_modal = "towers"
end

function BTN_HANDLERS.diff_cycle(lobby)
    if lobby.role ~= "host" then return end
    lobby.room.level_difficulty = (lobby.room.level_difficulty % 4) + 1
    lobby:save_prefs()
    lobby:broadcast_room_state()
end

function BTN_HANDLERS.econ_toggle(lobby)
    if lobby.role ~= "host" then return end
    lobby.room.econ_mode = (lobby.room.econ_mode == "independent") and "shared" or "independent"
    lobby:save_prefs()
    lobby:broadcast_room_state()
end

function BTN_HANDLERS.tower_toggle(lobby)
    if lobby.role ~= "host" then return end
    lobby.room.tower_mode = (lobby.room.tower_mode == "owned") and "open" or "owned"
    lobby:save_prefs()
    lobby:broadcast_room_state()
end

function BTN_HANDLERS.delay_cycle(lobby)
    if lobby.role ~= "host" then return end
    local cur = lobby.normalize_delay_turns(lobby.room.input_delay_turns)
    lobby.room.input_delay_turns = (cur == 2) and 3 or ((cur == 3) and 4 or ((cur == 4) and 6 or 2))
    lobby:save_prefs()
    lobby:broadcast_room_state()
    local tips = {
        [2] = "已切至【局域网 100ms 缓冲】：同 Wi-Fi / 低延迟最跟手",
        [3] = "已切至【低抖动 150ms 缓冲】：适合同省低延迟樱花节点",
        [4] = "已切至【樱花映射 200ms 缓冲】：免费 FRP / 跨省联机更丝滑不卡顿！",
        [6] = "已切至【高延迟抗抖 300ms 缓冲】：适合晚高峰波动 / 热点联机",
    }
    lobby.overlay:show_toast(tips[lobby.room.input_delay_turns], 2.4)
end

function BTN_HANDLERS.toggle_tower_marks(lobby)
    if not lobby.coop then return end
    lobby.coop.show_tower_marks = not lobby.coop.show_tower_marks
    lobby:save_prefs()
    lobby.overlay:show_toast(
        lobby.coop.show_tower_marks and "已开启本地防御塔底座红蓝标志（仅对自己生效）" or "已关闭本地防御塔归属标志（纯净画面）",
        2.0
    )
end

-- Voice Controls & Mixer
function BTN_HANDLERS.voice_cycle(lobby)
    if not lobby.voice then return end
    if not lobby.voice.supported then
        lobby.overlay:show_toast("当前环境未检测到可用语音音频接口。", 2.2)
    else
        lobby.voice:cycle_mode()
        lobby:save_prefs()
        lobby.overlay:show_toast(lobby.voice:get_mode_toast(), 2.4)
    end
end

function BTN_HANDLERS.open_voice_mixer(lobby)
    if not lobby.voice then return end
    if not lobby.voice.supported then
        lobby.overlay:show_toast("当前环境未检测到可用语音音频接口。", 2.2)
    else
        if lobby.overlay then lobby.overlay:clear_toast() end
        lobby.sub_modal = "voice"
    end
end

function BTN_HANDLERS.voice_set_mode(lobby, btn)
    if lobby.voice and btn.mode then
        lobby.voice:set_mode(btn.mode)
        lobby:save_prefs()
    end
end

function BTN_HANDLERS.voice_mic_step(lobby, btn)
    if lobby.voice and btn.delta then
        lobby.voice:step_mic_gain(btn.delta)
        lobby:save_prefs()
    end
end

function BTN_HANDLERS.voice_mic_set(lobby, btn)
    if lobby.voice and tonumber(btn.val) then
        lobby.voice:set_mic_gain(tonumber(btn.val))
        lobby:save_prefs()
    end
end

function BTN_HANDLERS.voice_peer_step(lobby, btn)
    if lobby.voice and btn.delta then
        lobby.voice:step_peer_volume(btn.delta)
        lobby:save_prefs()
    end
end

function BTN_HANDLERS.voice_peer_set(lobby, btn)
    if lobby.voice and tonumber(btn.val) then
        lobby.voice:set_peer_volume(tonumber(btn.val))
        lobby:save_prefs()
    end
end

function BTN_HANDLERS.voice_peer_mute(lobby)
    if lobby.voice then
        lobby.voice:toggle_peer_mute()
        lobby:save_prefs()
    end
end

function BTN_HANDLERS.voice_self_test(lobby)
    if not lobby.voice then return end
    local testing = lobby.voice:toggle_self_test()
    lobby.overlay:show_toast(
        testing and "试麦已开启：现在说话可实时听见自己回放（请戴耳机，再点关闭）" or "已关闭本地试麦回放。",
        2.4
    )
end

function BTN_HANDLERS.voice_style_set(lobby, btn)
    if lobby.voice and btn.style_id then
        lobby.voice:set_indicator_style(btn.style_id)
        lobby:save_prefs()
    end
end

function BTN_HANDLERS.voice_aux(lobby)
    if not lobby.voice then return end
    if not lobby.voice.supported then
        lobby.overlay:show_toast("当前环境未检测到可用语音音频接口。", 2.2)
    elseif lobby.peer_connected then
        local muted = lobby.voice:toggle_peer_mute()
        lobby:save_prefs()
        lobby.overlay:show_toast(muted and "已静音队友语音（听筒关闭）" or "已恢复收听队友语音（听筒开启）", 1.8)
    else
        local testing = lobby.voice:toggle_self_test()
        lobby.overlay:show_toast(
            testing and "试麦已开启：现在说话可实时听见自己回放（请戴耳机，再点关闭）" or "已关闭本地试麦回放。",
            2.4
        )
    end
end

function BTN_HANDLERS.cycle_font_theme(lobby)
    local info = fonts.cycle_theme()
    lobby:save_prefs()
    lobby.overlay:show_toast("已切换字体风格：" .. info.desc, 2.8)
end

function BTN_HANDLERS.cycle_seal_style(lobby)
    local info = ui.cycle_seal_style()
    lobby:save_prefs()
    lobby.overlay:show_toast("已切换蜡封样式：" .. info.desc, 2.8)
end

function BTN_HANDLERS.toggle_ready(lobby)
    if lobby.role == "client" then lobby:toggle_ready() end
end

-- Sub-Modal Pickers
function BTN_HANDLERS.stage_pack(lobby, btn)
    if btn.pack_idx then
        lobby.stage_pack_idx = btn.pack_idx
        lobby.stage_page = 1
    end
end

function BTN_HANDLERS.stage_page_prev(lobby)
    lobby.stage_page = math.max(1, (lobby.stage_page or 1) - 1)
end

function BTN_HANDLERS.stage_page_next(lobby)
    lobby.stage_page = (lobby.stage_page or 1) + 1
end

function BTN_HANDLERS.pick_stage(lobby, btn)
    if btn.level_idx and lobby.role == "host" then
        lobby.room.level_idx = btn.level_idx
        lobby.sub_modal = nil
        lobby:save_prefs()
        lobby:broadcast_room_state()
    end
end

function BTN_HANDLERS.hero_pack(lobby, btn)
    if btn.pack_idx then lobby.hero_pack_idx = btn.pack_idx end
end

function BTN_HANDLERS.pick_hero(lobby, btn)
    if not btn.hero_idx then return end
    if lobby.sub_modal == "hero1" and lobby.role == "host" then
        lobby.room.heroes[1] = btn.hero_idx
        lobby.sub_modal = nil
        lobby:save_prefs()
        lobby:broadcast_room_state()
    elseif lobby.sub_modal == "hero2" then
        lobby.room.heroes[2] = btn.hero_idx
        lobby.sub_modal = nil
        if lobby.role == "host" then
            lobby:save_prefs()
            lobby:broadcast_room_state()
        elseif lobby.role == "client" then
            lobby.transport:send({ t = "SET_GUEST", hero_idx = btn.hero_idx, ready = lobby.local_ready })
        end
    end
end

function BTN_HANDLERS.tower_pack(lobby, btn)
    if btn.pack_idx then lobby.tower_pack_idx = btn.pack_idx end
end

function BTN_HANDLERS.pick_tower(lobby, btn)
    if not (btn.tower_idx and lobby.role == "host") then return end
    lobby.ensure_room_defaults(lobby.room)
    local ok, msg = toggle_tower_in_deck(lobby.room.towers, btn.tower_idx)
    if not ok and msg then
        lobby.overlay:show_toast(msg, 2.5)
    else
        lobby:save_prefs()
        lobby:broadcast_room_state()
    end
end

function BTN_HANDLERS.towers_default(lobby)
    if lobby.role ~= "host" then return end
    lobby.room.towers = lobby.copy_array(catalog.DEFAULT_TOWERS)
    lobby:save_prefs()
    lobby:broadcast_room_state()
    lobby.overlay:show_toast("已恢复默认 5 代 12 座防御塔！", 2.0)
end

function M.handle_button(lobby, btn)
    local id = btn.id
    if not INPUT_BOX_IDS[id] then
        lobby:set_focus(nil)
    end

    if id == "close" or id == "leave_room" then
        ui.play_sfx("close")
    elseif id == "start_match" or id == "toggle_ready" then
        ui.play_sfx("start")
    elseif TAB_SFX_IDS[id] then
        ui.play_sfx("tab")
    elseif id == "econ_toggle" then
        ui.play_sfx("coin")
    elseif not INPUT_BOX_IDS[id] then
        ui.play_sfx("click")
    end

    local fn = BTN_HANDLERS[id]
    if fn then
        fn(lobby, btn)
    end
end

function M.textinput(lobby, t)
    if not lobby.open or not lobby.focused_field or type(t) ~= "string" then return false end
    local f = lobby.focused_field
    local clean_t = t:gsub("：", ":")
    for i = 1, #clean_t do
        local c = clean_t:sub(i, i)
        if f == "ip" then
            if c:match("^[%d%.:a-zA-Z%-]$") and #lobby.ip_input < 80 then
                lobby.ip_input = lobby.ip_input .. c
            end
        elseif f == "server" then
            if c:match("^[%d%.:a-zA-Z%-]$") and #lobby.server_input < 80 then
                lobby.server_input = lobby.server_input .. c
            end
        elseif f == "code" then
            if c:match("^[%da-zA-Z]$") and #lobby.code_input < 6 then
                lobby.code_input = lobby.code_input .. c:upper()
            end
        elseif f == "pw" then
            if c:match("^[%w%-%_@#]$") and #lobby.pw_input < 16 then
                lobby.pw_input = lobby.pw_input .. c
            end
        end
    end
    return true
end

function M.keypressed(lobby, key)
    if key == "f10" then
        lobby:toggle()
        return true
    end
    if not lobby.open then return false end
    if key == "escape" or key == "acback" then
        if lobby.focused_field then
            lobby:set_focus(nil)
        elseif lobby.sub_modal then
            lobby.sub_modal = nil
        else
            lobby.open = false
            lobby:set_focus(nil)
        end
        return true
    end
    local f = lobby.focused_field
    if f then
        local ctrl = love and love.keyboard and love.keyboard.isDown
            and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl"))
        if ctrl and key == "v" then
            lobby:paste_into_field(f)
            return true
        elseif key == "backspace" then
            if f == "ip" then lobby.ip_input = lobby.ip_input:sub(1, -2)
            elseif f == "server" then lobby.server_input = lobby.server_input:sub(1, -2)
            elseif f == "code" then lobby.code_input = lobby.code_input:sub(1, -2)
            elseif f == "pw" then lobby.pw_input = lobby.pw_input:sub(1, -2)
            end
            return true
        elseif key == "return" or key == "kpenter" then
            lobby:set_focus(nil)
            if f == "ip" then
                lobby.ip_input = proto.sanitize_addr(lobby.ip_input):sub(1, 80)
                lobby:save_prefs()
                lobby:join_lan_room(lobby.ip_input)
            elseif f == "server" then
                lobby.server_input = proto.sanitize_addr(lobby.server_input):sub(1, 80)
                lobby:save_prefs()
                lobby:connect_online_server(lobby.server_input, false)
            elseif f == "code" then
                lobby:join_online_room(lobby.code_input, lobby.pw_input)
            end
            return true
        end
    end
    return true
end

function M.mousepressed(lobby, x, y, button)
    if not lobby.open then return false end
    if button == 1 then
        local s = lobby._ui_scale or 1
        local lx = (x - (lobby._ui_ox or 0)) / s
        local ly = (y - (lobby._ui_oy or 0)) / s
        for _, b in ipairs(lobby.buttons) do
            if lx >= b.x and lx <= b.x + b.w and ly >= b.y and ly <= b.y + b.h then
                lobby._consumed_down = true
                if b.slider_min ~= nil and b.slider_max ~= nil then
                    local frac = math.max(0, math.min(1, (lx - b.x) / math.max(1, b.w)))
                    b.val = b.slider_min + frac * (b.slider_max - b.slider_min)
                end
                lobby:handle_button(b)
                return true
            end
        end
        if lobby.overlay and lobby.overlay:dismiss_toast_at(x, y) then
            return true
        end
        lobby:set_focus(nil)
    end
    return true
end

function M.mousereleased(lobby, x, y, button)
    if lobby._consumed_down and button == 1 then
        lobby._consumed_down = false
        return true
    end
    return lobby.open
end

return M

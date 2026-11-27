-- KR-MP Lobby Input & Table-Driven Button Action Dispatcher
local proto = require("kr_mp.proto")
local fonts = require("kr_mp.fonts")
local catalog = require("kr_mp.catalog")
local updater = require("kr_mp.updater")
local lobby_prefs = require("kr_mp.lobby_prefs")
local ui = require("kr_mp.ui_assets")

local M = {}

local INPUT_BOX_IDS = {
    sakura_ip_box = true,
    lan_ip_box = true,
    ip_box = true,
    server_box = true,
    code_box = true,
    pw_box = true,
    sakura_token_box = true,
}

local TAB_SFX_IDS = {
    tab_sakura = true, tab_lan = true, tab_online = true,
    stage_pack = true, hero_pack = true, tower_pack = true,
    open_stages = true, open_hero1 = true, open_hero2 = true, open_towers = true,
    open_guide = true, guide_tab = true, open_sakura = true,
    sakura_toggle_wizard = true, sakura_nodes_prev = true, sakura_nodes_next = true,
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

function BTN_HANDLERS.tab_sakura(lobby)
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby:switch_tab("sakura")
end

function BTN_HANDLERS.tab_lan(lobby)
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby:switch_tab("lan")
end

function BTN_HANDLERS.tab_online(lobby)
    if lobby.overlay then lobby.overlay:clear_toast() end
    lobby:switch_tab("online")
end

-- SakuraFrp & LAN Home
function BTN_HANDLERS.host_lan(lobby) lobby:host_lan_room() end
function BTN_HANDLERS.join_local(lobby) lobby:join_lan_room("127.0.0.1", proto.DEFAULT_TCP_PORT) end
function BTN_HANDLERS.sakura_ip_box(lobby) lobby:set_focus("sakura_ip") end
function BTN_HANDLERS.paste_sakura_ip(lobby) lobby:paste_into_field("sakura_ip") end
function BTN_HANDLERS.join_sakura_ip(lobby)
    local clean = proto.sanitize_addr(lobby.sakura_ip_input or ""):sub(1, 96)
    lobby.sakura_ip_input = clean
    lobby.ip_input = clean
    if #clean == 0 then
        lobby.overlay:show_toast("请先粘贴房主的樱花映射地址（如 frp-xxx.com:12345）！", 3.0)
        return
    end
    lobby_prefs.record_recent_addr(lobby, clean)
    lobby:save_prefs()
    lobby:join_lan_room(clean)
end
function BTN_HANDLERS.lan_ip_box(lobby) lobby:set_focus("lan_ip") end
function BTN_HANDLERS.paste_lan_ip(lobby) lobby:paste_into_field("lan_ip") end
function BTN_HANDLERS.join_lan_ip(lobby)
    local clean = proto.sanitize_addr(lobby.lan_ip_input or ""):sub(1, 80)
    if #clean == 0 then clean = "127.0.0.1" end
    lobby.lan_ip_input = clean
    lobby:save_prefs()
    lobby:join_lan_room(clean)
end
function BTN_HANDLERS.ip_box(lobby) lobby:set_focus("sakura_ip") end
function BTN_HANDLERS.paste_ip(lobby) lobby:paste_into_field("sakura_ip") end
function BTN_HANDLERS.join_ip(lobby) BTN_HANDLERS.join_sakura_ip(lobby) end
function BTN_HANDLERS.sakura_carrier(lobby, btn)
    local next_addr = lobby_prefs.switch_sakura_carrier(lobby.sakura_ip_input or "", btn.carrier)
    if next_addr then
        lobby.sakura_ip_input = next_addr
        lobby.ip_input = next_addr
        lobby_prefs.record_recent_addr(lobby, next_addr)
        lobby:save_prefs()
        local names = { default = "默认线", dx = "电信专线 (dx.)", yd = "移动专线 (yd.)" }
        local shown = (lobby.privacy_mask and lobby.sakura) and lobby.sakura.mask_addr(next_addr) or next_addr
        lobby.overlay:show_toast("已切至樱花" .. (names[btn.carrier] or "默认线") .. "：" .. shown, 2.5)
    end
end
function BTN_HANDLERS.sakura_probe(lobby)
    if lobby.sakura then
        lobby.sakura:start_carrier_probe(lobby.sakura_ip_input or "")
    end
end
function BTN_HANDLERS.toggle_privacy(lobby)
    lobby.privacy_mask = not lobby.privacy_mask
    lobby:save_prefs()
    lobby.overlay:show_toast(
        lobby.privacy_mask and "已开启主播防窥打码：界面自动隐藏樱花地址与端口，点复制依然复制完整地址！"
            or "已关闭防窥打码：恢复明文显示连接地址。",
        2.8
    )
end
function BTN_HANDLERS.open_sakura(lobby)
    if lobby.overlay then lobby.overlay:clear_toast() end
    if lobby.sakura then
        lobby.sakura:scan_local(true)
        if type(lobby.sakura.token) == "string" and #lobby.sakura.token >= 8 and not lobby.sakura.user_info and not lobby.sakura.api_busy then
            lobby.sakura:refresh_api()
        end
    end
    lobby.sub_modal = "sakura"
end
function BTN_HANDLERS.sakura_rescan(lobby)
    if lobby.sakura then
        lobby.sakura:scan_local(true)
        lobby.overlay:show_toast("已刷新本机官方樱花启动器与隧道状态。", 2.0)
    end
end
function BTN_HANDLERS.sakura_launch_app(lobby)
    if lobby.sakura then lobby.sakura:launch_official_launcher() end
end
function BTN_HANDLERS.sakura_download_official(lobby)
    if lobby.sakura then lobby.sakura:start_official_installer_download() end
end
function BTN_HANDLERS.sakura_open_download_page(lobby)
    if lobby.sakura then
        lobby.sakura:open_url(lobby.sakura.DOWNLOAD_URL, "已在浏览器打开 SakuraFrp 官方下载页。")
    end
end
function BTN_HANDLERS.sakura_open_register(lobby)
    if lobby.sakura then
        lobby.sakura:open_url(lobby.sakura.REGISTER_URL, "已在浏览器打开樱花注册/登录页，注册完请继续第 2 步实名。")
    end
end
function BTN_HANDLERS.sakura_open_realname(lobby)
    if lobby.sakura then
        lobby.sakura:open_url(lobby.sakura.REALNAME_URL, "已在浏览器打开樱花实名认证页（支付宝实名，完成后点同步账号即可）。")
    end
end
function BTN_HANDLERS.sakura_open_profile(lobby)
    if lobby.sakura then
        lobby.sakura:open_url(lobby.sakura.PROFILE_URL, "已在浏览器打开用户信息页：复制「访问密钥」后回到游戏点「粘贴并登录」！")
    end
end
function BTN_HANDLERS.sakura_paste_and_sync(lobby)
    lobby:paste_into_field("sakura_token")
end
function BTN_HANDLERS.sakura_toggle_wizard(lobby)
    local sk = lobby.sakura
    local currently_wizard = (lobby.sakura_show_wizard == true)
        or (not (sk and sk.user_info) and lobby.sakura_wizard_dismissed ~= true)
    if currently_wizard then
        lobby.sakura_show_wizard = false
        lobby.sakura_wizard_dismissed = true
    else
        lobby.sakura_show_wizard = true
        lobby.sakura_wizard_dismissed = false
    end
end
function BTN_HANDLERS.sakura_nodes_prev(lobby, btn)
    if lobby.sakura then
        local tp = math.max(1, tonumber(btn and btn.total_pages) or 1)
        local cur = tonumber(lobby.sakura.node_page) or 1
        lobby.sakura.node_page = (cur > 1) and (cur - 1) or tp
    end
end
function BTN_HANDLERS.sakura_nodes_next(lobby, btn)
    if lobby.sakura then
        local tp = math.max(1, tonumber(btn and btn.total_pages) or 1)
        local cur = tonumber(lobby.sakura.node_page) or 1
        lobby.sakura.node_page = (cur < tp) and (cur + 1) or 1
    end
end
function BTN_HANDLERS.sakura_copy_detected(lobby, btn)
    local target = btn and btn.copy_addr
    if not target and lobby.sakura then
        local port = (lobby.role == "host" and lobby.transport and lobby.transport:get_port()) or proto.DEFAULT_TCP_PORT
        local _, copy = lobby.sakura:get_host_share_addr(port)
        target = copy
    end
    if target and #target > 0 then
        local has_p2p = (select(2, proto.split_fallback_addr(target)) ~= nil)
        local msg
        if lobby.privacy_mask then
            msg = has_p2p and "已复制免费 P2P + 樱花中继双地址（防窥隐藏），发给队友粘贴即可！"
                or "已复制樱花公网联机地址（防窥隐藏），发给队友粘贴即可进房！"
        else
            msg = (has_p2p and "已复制 P2P+中继双地址：" or "已复制樱花联机地址：") .. target
        end
        lobby:copy_to_clipboard(target, msg)
    else
        lobby.overlay:show_toast("暂未检测到可复制的活跃樱花地址，请先启动一条 TCP 17777 隧道。", 2.8)
    end
end
function BTN_HANDLERS.sakura_token_box(lobby) lobby:set_focus("sakura_token") end
function BTN_HANDLERS.paste_sakura_token(lobby) lobby:paste_into_field("sakura_token") end
function BTN_HANDLERS.sakura_api_refresh(lobby)
    if lobby.sakura then lobby.sakura:refresh_api() end
end
function BTN_HANDLERS.sakura_token_clear(lobby)
    if lobby.sakura then
        lobby.sakura:stop_managed_frpc()
        lobby.sakura:set_token("")
        lobby:save_prefs()
        lobby.overlay:show_toast("已清空本地保存的樱花访问密钥。", 2.2)
    end
end
function BTN_HANDLERS.sakura_toggle_public(lobby)
    if lobby.sakura then
        lobby.sakura.public_mode = not lobby.sakura.public_mode
        lobby.sakura:rebuild_filtered_nodes()
        lobby:save_prefs()
        lobby.overlay:show_toast(
            lobby.sakura.public_mode and "已开启【公开直播合规模式】：仅推荐樱花官方允许公开招人的「多线」节点！"
                or "已切为【熟人私密开黑模式】：可任选低负载普通/多线节点（请勿向公网大群公布普通节点地址）。",
            3.2
        )
    end
end
function BTN_HANDLERS.sakura_start_frpc(lobby, btn)
    if not lobby.sakura or not btn.tunnel then return end
    local ok, err = lobby.sakura:start_managed_frpc(btn.tunnel)
    if ok then
        lobby.overlay:show_toast("已后台静默启动隧道「" .. tostring(btn.tunnel.name) .. "」，可直接建房并一键复制地址！", 3.2)
    else
        lobby.overlay:show_toast("启动隧道失败：" .. tostring(err), 3.6)
    end
end
function BTN_HANDLERS.sakura_stop_frpc(lobby)
    if lobby.sakura and lobby.sakura:stop_managed_frpc() then
        lobby.overlay:show_toast("已停止 KR-MP 内置启动的樱花隧道。", 2.2)
    end
end
function BTN_HANDLERS.sakura_use_online(lobby, btn)
    if btn.tunnel and btn.tunnel.addr then
        local c = btn.tunnel.p2p_addr and (btn.tunnel.p2p_addr .. "|" .. btn.tunnel.addr) or btn.tunnel.addr
        BTN_HANDLERS.sakura_copy_detected(lobby, { copy_addr = c })
    end
end
function BTN_HANDLERS.sakura_create_tunnel(lobby, btn)
    if lobby.sakura and btn.node_id then
        local port = (lobby.role == "host" and lobby.transport and lobby.transport:get_port()) or proto.DEFAULT_TCP_PORT
        lobby.sakura:create_krmp_tunnel(btn.node_id, port)
    end
end
function BTN_HANDLERS.use_recent_addr(lobby, btn)
    if type(btn.addr) == "string" and #btn.addr > 0 then
        lobby.sakura_ip_input = btn.addr
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
        local sk_disp, sk_copy, sk_p2p = nil, nil, false
        if lobby.sakura and not lobby.transport:is_port_drifted() then
            sk_disp, sk_copy, sk_p2p = lobby.sakura:get_host_share_addr(port)
        end
        if sk_disp and sk_copy then
            local msg
            if lobby.privacy_mask then
                msg = sk_p2p and "已复制免费 P2P + 樱花中继双地址（防窥隐藏），发给队友粘贴即可！"
                    or "已复制本机樱花公网联机地址（防窥隐藏），发给队友粘贴即可！"
            else
                msg = (sk_p2p and "已复制 P2P+樱花双地址：" or "已复制本机樱花公网地址：") .. sk_copy
            end
            lobby:copy_to_clipboard(sk_copy, msg)
        else
            lobby:copy_to_clipboard("127.0.0.1:" .. tostring(port),
                string.format("已复制本机端口 127.0.0.1:%d（樱花隧道本地端口请设为 %d）", port, port))
        end
    else
        local addr = tostring(lobby.last_direct_host or lobby.ip_input or "127.0.0.1")
        if lobby.last_direct_port and not addr:find(":", 1, true) then
            addr = addr .. ":" .. tostring(lobby.last_direct_port)
        end
        local shown = (lobby.privacy_mask and lobby.sakura) and lobby.sakura.mask_addr(addr) or addr
        lobby:copy_to_clipboard(addr, "已复制房主地址：" .. shown)
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
        if f == "sakura_ip" or f == "ip" then
            if c:match("^[%d%.:a-zA-Z%-|]$") and #(lobby.sakura_ip_input or "") < 96 then
                lobby.sakura_ip_input = (lobby.sakura_ip_input or "") .. c
                lobby.ip_input = lobby.sakura_ip_input
            end
        elseif f == "lan_ip" then
            if c:match("^[%d%.:a-zA-Z%-]$") and #(lobby.lan_ip_input or "") < 80 then
                lobby.lan_ip_input = (lobby.lan_ip_input or "") .. c
            end
        elseif f == "sakura_token" then
            if lobby.sakura and c:match("^[%w%-%_]$") and #(lobby.sakura.token or "") < 96 then
                lobby.sakura.token = (lobby.sakura.token or "") .. c
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
            if f == "sakura_ip" or f == "ip" then
                lobby.sakura_ip_input = (lobby.sakura_ip_input or ""):sub(1, -2)
                lobby.ip_input = lobby.sakura_ip_input
            elseif f == "lan_ip" then
                lobby.lan_ip_input = (lobby.lan_ip_input or ""):sub(1, -2)
            elseif f == "sakura_token" and lobby.sakura then lobby.sakura.token = (lobby.sakura.token or ""):sub(1, -2)
            elseif f == "server" then lobby.server_input = lobby.server_input:sub(1, -2)
            elseif f == "code" then lobby.code_input = lobby.code_input:sub(1, -2)
            elseif f == "pw" then lobby.pw_input = lobby.pw_input:sub(1, -2)
            end
            return true
        elseif key == "return" or key == "kpenter" then
            lobby:set_focus(nil)
            if f == "sakura_ip" or f == "ip" then
                BTN_HANDLERS.join_sakura_ip(lobby)
            elseif f == "lan_ip" then
                BTN_HANDLERS.join_lan_ip(lobby)
            elseif f == "sakura_token" and lobby.sakura then
                lobby:save_prefs()
                lobby.sakura:refresh_api()
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

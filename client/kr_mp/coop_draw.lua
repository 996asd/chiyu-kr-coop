-- KR-MP 2P Co-op World-Space Visual Overlays (Pure Rendering — Zero Simulation Mutation)
-- Extracted from coop.lua to separate rendering from economic/ownership simulation logic.
local fonts = require("kr_mp.fonts")

local M = {}

-- Exact camera-aware world -> screen transform matching all/game.lua:draw_game()
-- Tracks Android 20:9 cover_zoom, pinch-to-zoom, camera pan, PC zoom, and world_offset shake.
local function get_world_view_transform()
    if not game or not game.game_scale or not game.game_ref_origin then
        return nil
    end
    local gs = game.game_scale
    local rox, roy
    if game.camera then
        local c = game.camera
        local vcx = (c.view_left or 0) + (c.view_w or game.screen_w or 0) * 0.5
        local vcy = (c.view_top or 0) + (c.view_h or game.screen_h or 0) * 0.5
        local z = c.zoom or 1
        rox = -(c.x * z - vcx)
        roy = -(c.y * z - vcy)
        gs = gs * z
    else
        rox = game.game_ref_origin.x
        roy = game.game_ref_origin.y
    end
    if game.store and game.store.world_offset then
        rox = rox + (game.store.world_offset.x or 0)
        roy = roy + (game.store.world_offset.y or 0)
    end
    return rox, roy, gs, (game.ref_h or REF_H or 768)
end

local function world_to_screen(wx, wy, rox, roy, gs, ref_h)
    if not rox then
        rox, roy, gs, ref_h = get_world_view_transform()
        if not rox then return nil, nil end
    end
    return rox + wx * gs, roy + (ref_h - wy) * gs
end

-- Precomputed 19-point lower pedestal crescent (zero per-frame trig & zero table GC)
local ARC_SEGS = 18
local ARC_COS, ARC_SIN = {}, {}
for i = 0, ARC_SEGS do
    local a = math.pi * (0.14 + 0.72 * (i / ARC_SEGS))
    ARC_COS[i + 1] = math.cos(a)
    ARC_SIN[i + 1] = math.sin(a)
end
local ARC_PTS = {}
local RAW_PAIRS = pairs

local function draw_tower_marks(coop, G, rox, roy, scale, ref_h, sw_scr, sh_scr, bs, badge_font)
    if not (coop.show_tower_marks and coop.tower_mode == "owned") then return end
    local mini_font = fonts.get(10.5 * bs, "bold") or badge_font
    local mfh = mini_font and mini_font:getHeight() or math.floor(11 * bs)
    local iter_pairs = coop._raw_pairs or RAW_PAIRS
    for _, e in iter_pairs(game.store.entities) do
        if e and e.tower and e._mp_owner and e.pos and not e._kr_mp_local then
            local sx, sy = world_to_screen(e.pos.x, e.pos.y, rox, roy, scale, ref_h)
            if sx and sx >= -90 and sx <= sw_scr + 90 and sy >= -90 and sy <= sh_scr + 90 then
                local is_p1 = (e._mp_owner == 1)
                local cx, cy = sx, sy - 7 * scale
                local rx, ry = 31 * scale, 13 * scale
                for i = 1, ARC_SEGS + 1 do
                    ARC_PTS[i * 2 - 1] = cx + ARC_COS[i] * rx
                    ARC_PTS[i * 2] = cy + ARC_SIN[i] * ry
                end

                G.setLineWidth(4.0 * bs)
                if is_p1 then G.setColor(55, 165, 255, 60) else G.setColor(255, 78, 78, 60) end
                G.line(ARC_PTS)

                G.setLineWidth(1.6 * bs)
                if is_p1 then G.setColor(95, 198, 255, 215) else G.setColor(255, 110, 105, 215) end
                G.line(ARC_PTS)

                local pw = math.floor(23 * bs + 0.5)
                local ph = math.floor(14 * bs + 0.5)
                local bx = math.floor(cx - pw / 2 + 0.5)
                local by = math.floor(cy + ry - 5 * bs + 0.5)
                G.setColor(10, 16, 26, 200)
                G.rectangle("fill", bx, by, pw, ph, 5 * bs, 5 * bs)
                G.setLineWidth(1.2 * bs)
                if is_p1 then G.setColor(95, 198, 255, 235) else G.setColor(255, 110, 105, 235) end
                G.rectangle("line", bx, by, pw, ph, 5 * bs, 5 * bs)
                if mini_font then G.setFont(mini_font) end
                G.setColor(is_p1 and 155 or 255, is_p1 and 220 or 165, is_p1 and 255 or 165, 255)
                G.printf(is_p1 and "1P" or "2P", bx, math.floor(by + (ph - mfh) * 0.5 + 0.5), pw, "center")
            end
        end
    end
    if badge_font then G.setFont(badge_font) end
end

local function draw_hero_badges(coop, G, rox, roy, scale, ref_h, sw_scr, sh_scr, bs, bfh)
    local hpos = {}
    for pid = 1, 2 do
        local hid = coop.hero_ids[pid]
        local he = hid and game.store.entities[hid]
        if he and he.pos and he.health and not he.health.dead then
            local sx, sy = world_to_screen(he.pos.x, he.pos.y, rox, roy, scale, ref_h)
            if sx and sx >= -90 and sx <= sw_scr + 90 and sy >= -90 and sy <= sh_scr + 120 then
                hpos[pid] = { sx = sx, sy = sy }
            end
        end
    end
    local stacked = hpos[1] and hpos[2]
        and math.abs(hpos[1].sx - hpos[2].sx) < 42 * bs
        and math.abs(hpos[1].sy - hpos[2].sy) < 28 * bs
    for pid = 1, 2 do
        local p = hpos[pid]
        if p then
            local tag = (pid == coop.local_pid) and (pid .. "P (你)") or (pid .. "P")
            local bw = math.floor(((pid == coop.local_pid) and 56 or 30) * bs + 0.5)
            local bh = math.floor(17 * bs + 0.5)
            local bx = math.floor(p.sx - bw / 2 + 0.5)
            local by = math.floor(p.sy - 58 * scale - ((stacked and pid == 1) and (20 * bs) or 0) + 0.5)
            G.setColor(0, 0, 0, 195)
            G.rectangle("fill", bx, by, bw, bh, 4 * bs, 4 * bs)
            if pid == 1 then G.setColor(70, 180, 255, 255) else G.setColor(255, 90, 90, 255) end
            G.setLineWidth(1.5 * bs)
            G.rectangle("line", bx, by, bw, bh, 4 * bs, 4 * bs)
            G.printf(tag, bx, math.floor(by + (bh - bfh) * 0.5 + 0.5), bw, "center")
        end
    end
end

local function draw_map_pings(coop, G, rox, roy, scale, ref_h, sw_scr, sh_scr, bs, bfh)
    local now = (love.timer and love.timer.getTime()) or 0
    for i = #coop.pings, 1, -1 do
        local p = coop.pings[i]
        if now >= p.end_ts then
            table.remove(coop.pings, i)
        else
            local sx, sy = world_to_screen(p.wx, p.wy, rox, roy, scale, ref_h)
            if sx and sx >= -120 and sx <= sw_scr + 120 and sy >= -120 and sy <= sh_scr + 120 then
                local age = now - p.start_ts
                local cycle = (age * 1.8) % 1.0
                local r = (12 + cycle * 44) * scale
                local alpha = math.floor((1 - cycle) * 235)
                if p.pid == 1 then G.setColor(70, 200, 255, alpha) else G.setColor(255, 95, 95, alpha) end
                G.setLineWidth(3 * bs)
                G.circle("line", sx, sy, r)
                G.circle("fill", sx, sy, 5 * scale)
                local pbw = math.floor(74 * bs + 0.5)
                local pbh = math.floor(19 * bs + 0.5)
                local pbx = math.floor(sx - pbw * 0.5 + 0.5)
                local pby = math.floor(sy - 28 * bs + 0.5)
                G.setColor(0, 0, 0, 200)
                G.rectangle("fill", pbx, pby, pbw, pbh, 4 * bs, 4 * bs)
                G.setColor(255, 240, 120, 255)
                G.printf(p.pid .. "P 标记!", pbx, math.floor(pby + (pbh - bfh) * 0.5 + 0.5), pbw, "center")
            end
        end
    end
end

function M.draw_world_overlays(coop)
    if not coop.active or not game or not game.store or not game.store.entities or not love.graphics then
        return
    end
    if not main or not main.handler or main.handler.active_item ~= game then
        return
    end
    local gui = game.game_gui
    if gui and ((gui.victoryview and not gui.victoryview.hidden) or (gui.defeatview and not gui.defeatview.hidden)) then
        return
    end

    local rox, roy, scale, ref_h = get_world_view_transform()
    if not rox then return end

    local G = love.graphics
    local sw_scr = G.getWidth and G.getWidth() or (game.screen_w or 1280)
    local sh_scr = G.getHeight and G.getHeight() or (game.screen_h or 720)
    local base_scale = game.game_scale or 1
    local bs = math.max(1.0, math.min(2.4, math.floor((base_scale * (1 + ((scale / math.max(0.01, base_scale)) - 1) * 0.35)) * 10 + 0.5) / 10))

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")
    local badge_font = fonts.get(12 * bs, "bold")
    if badge_font then G.setFont(badge_font) end
    local bfh = badge_font and badge_font:getHeight() or math.floor(13 * bs)

    draw_tower_marks(coop, G, rox, roy, scale, ref_h, sw_scr, sh_scr, bs, badge_font)
    draw_hero_badges(coop, G, rox, roy, scale, ref_h, sw_scr, sh_scr, bs, bfh)
    draw_map_pings(coop, G, rox, roy, scale, ref_h, sw_scr, sh_scr, bs, bfh)

    G.pop()
end

return M

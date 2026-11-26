-- KR-MP Ironhide Native Parchment & Hand-Hewn Oak UI Engine (V2)
-- Features:
--   1. Isolated lazy loader for FL 8.2.0 native art:
--      - 105/105 Hero Portraits (screen_map_123 / rebborn / room_hero / kr4_hero_room / kr6_hero_room_big ...)
--      - 59/59 Tower Medallions (gui_common_5 / kr4_map_towerroom / kr6_ui_icons with exact a_size UV scaling)
--      - 201/201 Stage Postcards (kr6/zeta/kr4/kr5/rebborn level thumbs & screen_map_123)
--   2. External 4x-supersampled Ironhide hardware PNGs (client/kr_mp/assets/*.png) loaded cleanly via io.open+FileData
--   3. Smooth GPU Mesh gradients + comic-inked tactile Oak/Parchment/Wax/3D-Emerald components
--   4. Safe native Ironhide UI Sound trigger (never touches sim or PRNG!)
local ui = {}

ui.THEME = {
    backdrop        = { 14, 9, 5, 192 },
    ink_dark        = { 26, 12, 4, 255 },
    wood_top        = { 107, 67, 38, 255 },
    wood_mid        = { 76, 45, 22, 255 },
    wood_bot        = { 46, 24, 10, 255 },
    wood_hi         = { 255, 220, 160, 88 },
    parchment_top   = { 248, 236, 206, 255 },
    parchment_bot   = { 226, 197, 142, 255 },
    parchment_edge  = { 130, 88, 38, 255 },
    parchment_line  = { 150, 108, 54, 118 },
    parchment_card  = { 252, 244, 222, 248 },
    parchment_card2 = { 237, 217, 174, 248 },
    ink_text        = { 54, 31, 14, 255 },
    ink_sub         = { 108, 72, 36, 245 },
    ink_muted       = { 134, 98, 56, 225 },
    gold_bright     = { 255, 236, 172, 255 },
    gold_mid        = { 234, 188, 98, 255 },
    gold_rim        = { 188, 138, 54, 245 },
    armory_top      = { 44, 25, 12, 255 },
    armory_bot      = { 60, 35, 18, 255 },
    p1_top          = { 42, 92, 150, 255 },
    p1_bot          = { 26, 62, 106, 255 },
    p1_border       = { 28, 72, 122, 255 },
    p1_light        = { 176, 226, 255, 255 },
    p2_top          = { 154, 42, 42, 255 },
    p2_bot          = { 106, 26, 26, 255 },
    p2_border       = { 118, 28, 28, 255 },
    p2_light        = { 255, 192, 196, 255 },
    emerald_top     = { 108, 222, 82, 255 },
    emerald_mid     = { 62, 178, 48, 255 },
    emerald_bot     = { 38, 126, 28, 255 },
    emerald_ink     = { 22, 62, 14, 255 },
    crimson_top     = { 222, 82, 72, 255 },
    crimson_bot     = { 146, 32, 28, 255 },
    crimson_ink     = { 72, 14, 12, 255 },
    ok_green        = { 48, 168, 86, 255 },
    ok_bright       = { 108, 238, 158, 255 },
    warn_amber      = { 224, 142, 32, 255 },
    err_red         = { 218, 54, 52, 255 },
}

-- FL 8.2.0 exact 59-tower icon index table (all-desktop/screen_map.lua global_icon_idx + KR6 44..59)
-- 1..21: KR5/Alliance towers (gui_common_5 main_icons_00XX); 22..43: KR4 towers (kr4_map_towerroom 401..423)
local TOWER_ICON_IDX = {
    1,   2,   3,   4,   -- 1..4   圣骑士/皇弓/奥术/三管
    6,   7,   8,   9,   -- 5..8   树灵/恶魔/观星/火箭
    10,  11,  12,  13,  -- 9..12  巨弩/死灵/喷火/沙丘
    16,  17,  18,  32,  -- 13..16 幽冥/酒桶/诡术/暮光
    34,  39,  42,  49,  -- 17..20 沼泽/炮兵/巨像/竹宗三侠
    51,                 -- 21     龙之孵育所
    417, 414, 421, 408, 411, -- 22..26 骚扰/红钻/火山/黑弓/黑骑
    407, 409, 404, 423, 410, -- 27..31 火法/熔炉/回旋/沉船/幽灵墓
    415, 419, 420, 416, 406, -- 32..36 腐森/少林/沼巨/女巫/飞艇
    413, 403, 402, 405, 412, -- 37..41 掷骨/兽人/萨满/火骑/墓地
    418, 422,                -- 42..43 鱼人/沙虫
}

local KR6_TOWER_NAMES = {
    [44] = "archers", [45] = "knights", [46] = "wizard", [47] = "catapult",
    [48] = "ranger", [49] = "culverine", [50] = "sunray_master", [51] = "light_priestess",
    [52] = "tree", [53] = "wildcat", [54] = "alchemist", [55] = "forger",
    [56] = "crossbows", [57] = "miners", [58] = "sniper", [59] = "owl",
}

local catalog = require("kr_mp.catalog")
local fonts = require("kr_mp.fonts")
local proto = require("kr_mp.proto")

local _tf = { s = 1, ox = 0, oy = 0 }

-- Responsive scale for the 780x486 Ironhide War-Table Lobby (scales cleanly from phone HD to 1080p/2K/4K)
function ui.compute_lobby_scale(sw, sh)
    sw = tonumber(sw) or 960
    sh = tonumber(sh) or 540
    local s = math.min((sw * 0.88) / 780, (sh * 0.86) / 486)
    if not proto.is_android() then
        s = math.min((sw * 0.86) / 780, (sh * 0.84) / 486)
    end
    if s < 1.0 and sw >= 812 and sh >= 526 then
        s = 1.0
    end
    s = math.floor(s * 20 + 0.5) / 20
    local min_s = proto.is_android() and 0.50 or 0.75
    return math.max(min_s, math.min(3.2, s))
end

-- Responsive scale for the top Battle HUD & Title Toolbar (leaves generous clearance for KR native corners)
function ui.compute_hud_scale(sw, sh)
    sw = tonumber(sw) or 960
    sh = tonumber(sh) or 540
    local s = proto.is_android()
        and math.min(sw / 1060, sh / 570)
        or math.min(sw / 1180, sh / 660)
    if s < 1.0 and sw >= 540 and sh >= 420 then
        s = 1.0
    end
    s = math.floor(s * 20 + 0.5) / 20
    local min_s = proto.is_android() and 0.65 or 0.8
    return math.max(min_s, math.min(2.6, s))
end

function ui.begin_transform(scale, ox, oy)
    local G = love.graphics
    _tf.s = scale or 1
    _tf.ox = math.floor((ox or 0) + 0.5)
    _tf.oy = math.floor((oy or 0) + 0.5)
    G.push()
    G.translate(_tf.ox, _tf.oy)
    G.scale(_tf.s, _tf.s)
end

function ui.end_transform()
    love.graphics.pop()
    _tf.s = 1
    _tf.ox = 0
    _tf.oy = 0
end

function ui.get_transform()
    return _tf.s, _tf.ox, _tf.oy
end

-- Set LÖVE scissor in logical coordinates (automatically mapped to raw screen pixels)
function ui.set_scissor_logical(x, y, w, h)
    local G = love.graphics
    local s, ox, oy = _tf.s, _tf.ox, _tf.oy
    local sx = math.floor(ox + x * s)
    local sy = math.floor(oy + y * s)
    local ex = math.ceil(ox + (x + w) * s)
    local ey = math.ceil(oy + (y + h) * s)
    G.setScissor(sx, sy, math.max(0, ex - sx), math.max(0, ey - sy))
end

-- Wax Seal style default: "callig" (Large smooth emerald/amber royal wax seal with JIMOJW 2-char stamp)
ui.seal_style = "callig"
ui.SEAL_STYLES = {
    { id = "callig", label = "圆章", desc = "翡翠/琥珀大蜡封 + 官配手绘双字盖印" },
    { id = "ribbon", label = "缎带", desc = "翡翠/琥珀徽标蜡封 + 底部金边小缎带" },
    { id = "stack",  label = "双行", desc = "经典朱红/琥珀蜡封 + 图标与双字双行" },
    { id = "medal",  label = "飘带", desc = "双飘带皇家勋章 + 图标与双字" },
}

function ui.get_seal_style_info(id)
    id = id or ui.seal_style
    for i = 1, #ui.SEAL_STYLES do
        if ui.SEAL_STYLES[i].id == id then
            return ui.SEAL_STYLES[i], i
        end
    end
    return ui.SEAL_STYLES[1], 1
end

function ui.set_seal_style(id)
    local info = ui.get_seal_style_info(id)
    ui.seal_style = info.id
    return info
end

function ui.cycle_seal_style()
    local _, idx = ui.get_seal_style_info(ui.seal_style)
    local next_idx = (idx % #ui.SEAL_STYLES) + 1
    ui.seal_style = ui.SEAL_STYLES[next_idx].id
    return ui.SEAL_STYLES[next_idx]
end

-- Build native physical-pixel font map for the active UI scale & font theme (zero stretched/blurred glyphs!)
function ui.make_font_map(scale)
    local s = scale or 1
    local tinfo = fonts.get_theme_info()
    local ds = (tinfo and tinfo.disp_scale) or 1.0
    return {
        scale      = s,
        banner     = fonts.get(16.5 * ds * s, "display"),
        title      = fonts.get(16 * ds * s, "display"),
        hero       = fonts.get(15 * ds * s, "display"),
        main       = fonts.get(13 * s, "regular"),
        main_bold  = fonts.get(13 * ds * s, "display"),
        small      = fonts.get(12 * s, "regular"),
        small_bold = fonts.get(12 * s, "bold"),
        tiny       = fonts.get(11 * s, "regular"),
        tiny_bold  = fonts.get(11 * s, "bold"),
        seal       = fonts.get(10.2 * s, "bold"),
        seal_disp  = fonts.get(11.0 * ds * s, "display"),
        seal_small = fonts.get(9.6 * ds * s, "display"),
    }
end

function ui.font_h(f)
    if not f then return 13 end
    return f:getHeight() / (_tf.s > 0 and _tf.s or 1)
end

function ui.font_w(f, text)
    if not f then return 0 end
    return f:getWidth(tostring(text or "")) / (_tf.s > 0 and _tf.s or 1)
end

-- Crisp 1:1 physical-pixel text draw (snapped to exact integer screen pixels, never bilinear-stretched)
function ui.text(text, x, y, col, font, align_w, align)
    local G = love.graphics
    local s, ox, oy = _tf.s, _tf.ox, _tf.oy
    local f = font or G.getFont()
    if f then G.setFont(f) end
    local px = math.floor(ox + x * s + 0.5)
    local py = math.floor(oy + y * s + 0.5)
    G.push()
    G.origin()
    if col then
        G.setColor(col[1], col[2], col[3], col[4] or 255)
    end
    if align_w then
        local pw = math.max(1, math.floor(align_w * s + 0.5))
        G.printf(tostring(text or ""), px, py, pw, align or "left")
    else
        G.print(tostring(text or ""), px, py)
    end
    G.pop()
end

local _base_dir = nil
local _atlas_meta = {}
local _img_cache = {}
local _sprite_cache = {}
local _ext_cache = {}
local _grad_cache = {}
local _hero_data = nil
local _hero_data_tried = false
local _sound_db = nil
local _sound_tried = false

local function get_source_base_dir()
    if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
        return love.filesystem.getSourceBaseDirectory()
    end
    return "."
end

local function get_atlas_base_dir()
    if _base_dir then return _base_dir end
    local candidates = { "kr3-desktop/assets/images/fullhd" }
    if type(KR_PATH_ASSETS_GAME_TARGET) == "string" then
        candidates[#candidates + 1] = KR_PATH_ASSETS_GAME_TARGET .. "/images/fullhd"
    end
    local FS = love and love.filesystem
    if FS and FS.isFile then
        for _, dir in ipairs(candidates) do
            if FS.isFile(dir .. "/room_hero.lua") or FS.isFile(dir .. "/room_tower.lua") then
                _base_dir = dir
                return _base_dir
            end
        end
    end
    _base_dir = candidates[1]
    return _base_dir
end

local function get_hero_data()
    if not _hero_data_tried then
        _hero_data_tried = true
        local ok, md = pcall(require, "data.map_data")
        if ok and type(md) == "table" and type(md.hero_data) == "table" then
            _hero_data = md.hero_data
        end
    end
    return _hero_data
end

-- Safe native Ironhide UI Sound trigger (visual/UI feedback only, never touches sim/PRNG)
function ui.play_sfx(kind)
    if not _sound_tried then
        _sound_tried = true
        local ok, sdb = pcall(require, "sound_db")
        if ok and type(sdb) == "table" and type(sdb.queue) == "function" then
            _sound_db = sdb
        end
    end
    if not _sound_db then return end
    local map = {
        click     = "GUIButtonCommon",
        tab       = "GUINotificationPaperOver",
        open      = "GUINotificationOpen",
        close     = "GUINotificationClose",
        coin      = "GUICoins",
        stamp     = "GUIButtonCommon",
        start     = "GUINextWaveReady",
    }
    local sid = map[kind] or kind
    if sid then
        pcall(_sound_db.queue, _sound_db, sid)
    end
end

-- Load external 4x-supersampled PNG plate from kr_mp/assets/<name> (supports both Android game.love & PC loose files)
function ui.get_ext_image(fname, wrap_repeat)
    local cached = _ext_cache[fname]
    if cached ~= nil then
        return cached or nil
    end
    local G = love and love.graphics
    local FS = love and love.filesystem
    if not G then
        _ext_cache[fname] = false
        return nil
    end
    local img = nil
    local rel = "kr_mp/assets/" .. fname
    -- Prefer love.filesystem (works natively inside Android game.love AND mounted PC folders!)
    if FS and ((FS.getInfo and FS.getInfo(rel)) or (FS.isFile and FS.isFile(rel))) then
        local ok_im, im = pcall(G.newImage, rel)
        if ok_im and im then img = im end
    end
    -- Fallback to raw io.open relative to source base directory (PC loose patch outside mounted root)
    if not img and FS and FS.newFileData then
        local full = get_source_base_dir() .. "/kr_mp/assets/" .. fname
        local f = io.open(full, "rb")
        if f then
            local bytes = f:read("*a")
            f:close()
            if bytes and #bytes > 0 then
                local ok_fd, fd = pcall(FS.newFileData, bytes, fname)
                if ok_fd and fd then
                    local ok_im, im = pcall(G.newImage, fd)
                    if ok_im and im then img = im end
                end
            end
        end
    end
    if not img then
        _ext_cache[fname] = false
        return nil
    end
    pcall(img.setFilter, img, "linear", "linear")
    if wrap_repeat then
        pcall(img.setWrap, img, "repeat", "repeat")
    end
    _ext_cache[fname] = img
    return img
end

-- Load FL 8.2.0 internal atlas metadata (.lua)
local function load_atlas_meta(atlas_name)
    local cached = _atlas_meta[atlas_name]
    if cached ~= nil then
        return cached or nil
    end
    local FS = love and love.filesystem
    if not FS or not FS.load then
        _atlas_meta[atlas_name] = false
        return nil
    end
    local path = get_atlas_base_dir() .. "/" .. atlas_name .. ".lua"
    local ok_c, chunk = pcall(FS.load, path)
    if not ok_c or type(chunk) ~= "function" then
        _atlas_meta[atlas_name] = false
        return nil
    end
    local ok_r, tbl = pcall(chunk)
    if not ok_r or type(tbl) ~= "table" then
        _atlas_meta[atlas_name] = false
        return nil
    end
    _atlas_meta[atlas_name] = tbl
    return tbl
end

-- Load FL 8.2.0 internal texture (.png / .jpg / .dds / .pkm / .ktx)
local function load_atlas_image(tex_name)
    local cached = _img_cache[tex_name]
    if cached ~= nil then
        return cached or nil
    end
    local G = love and love.graphics
    local LI = love and love.image
    if not G or not G.newImage then
        _img_cache[tex_name] = false
        return nil
    end
    local path = get_atlas_base_dir() .. "/" .. tex_name
    local img = nil
    local lower = tex_name:lower()
    if (lower:match("%.dds$") or lower:match("%.pkm$") or lower:match("%.ktx$") or lower:match("%.lz4$"))
        and LI and LI.newCompressedData then
        local ok_cd, cd = pcall(LI.newCompressedData, path)
        if ok_cd and cd then
            local ok_im, im = pcall(G.newImage, cd)
            if ok_im and im then img = im end
        end
    else
        local ok_im, im = pcall(G.newImage, path)
        if ok_im and im then img = im end
    end
    if not img then
        _img_cache[tex_name] = false
        return nil
    end
    pcall(img.setFilter, img, "linear", "linear")
    _img_cache[tex_name] = img
    return img
end

-- Retrieve cached sprite using exact FL 8.2.0 a_size reference coordinates!
local function get_sprite(atlas_name, sprite_name)
    local key = atlas_name .. ":" .. sprite_name
    local cached = _sprite_cache[key]
    if cached ~= nil then
        return cached or nil
    end
    local meta = load_atlas_meta(atlas_name)
    if not meta then
        _sprite_cache[key] = false
        return nil
    end
    local rec = meta[sprite_name]
    if not rec or not rec.a_name or not rec.f_quad then
        _sprite_cache[key] = false
        return nil
    end
    local img = load_atlas_image(rec.a_name)
    if not img then
        _sprite_cache[key] = false
        return nil
    end
    local fq = rec.f_quad
    local qw, qh = tonumber(fq[3]) or 0, tonumber(fq[4]) or 0
    if qw <= 0 or qh <= 0 then
        _sprite_cache[key] = false
        return nil
    end
    -- CRITICAL: Use rec.a_size just like lib/klove/image_db.lua (handles scaled atlases like kr4_map_towerroom & kr4_herogui!)
    local ref_w = (rec.a_size and tonumber(rec.a_size[1])) or img:getWidth()
    local ref_h = (rec.a_size and tonumber(rec.a_size[2])) or img:getHeight()
    local ok_q, quad = pcall(love.graphics.newQuad, fq[1], fq[2], qw, qh, ref_w, ref_h)
    if not ok_q or not quad then
        _sprite_cache[key] = false
        return nil
    end
    local entry = { img = img, quad = quad, qw = qw, qh = qh }
    _sprite_cache[key] = entry
    return entry
end

local function resolve_hero_tpl(idx)
    local hd_tbl = get_hero_data()
    local hd = hd_tbl and hd_tbl[idx]
    local hname = hd and hd.name
    if not hname then
        local info = catalog.get_hero_info(idx)
        hname = info and info.tpl
    end
    -- #71 hero_douzhanshengfo shares Wukong's portrait atlas in FL 8.2.0
    if hname == "hero_douzhanshengfo" then
        return "hero_wukong", hd
    end
    return hname, hd
end

-- Square crisp hero thumb (105/105 verified across KR1/2/3/Rebborn/KR5/KR4/KR6!)
function ui.get_hero_sprite(hero_idx)
    local idx = tonumber(hero_idx) or catalog.DEFAULT_HERO_1 or 53
    local hname, hd = resolve_hero_tpl(idx)

    if idx <= 47 then
        local thumb = (hd and tonumber(hd.thumb)) or idx
        local sp = string.format("heroroom_portraits_%04d", thumb)
        return get_sprite("screen_map_123", sp)
    elseif idx >= 48 and idx <= 52 then
        if not hname then return nil end
        local sp = string.format("hero_room_portraits_small_thumb_%s_0001", hname)
        return get_sprite("rebborn_heroes_gui", sp) or get_sprite("rebborn_heroes_room", "hero_room_portraits_big_" .. hname .. "_0001")
    elseif idx >= 53 and idx <= 72 then
        if not hname then return nil end
        local sp = string.format("hero_room_portraits_small_thumb_%s_0001", hname)
        return get_sprite("room_hero", sp) or get_sprite("room_hero", "hero_room_portraits_big_" .. hname .. "_0001")
    elseif idx >= 73 and idx <= 90 then
        if not hname then return nil end
        local sp = string.format("hero_room_portraits_small_thumb_%s_0001", hname)
        return get_sprite("kr4_hero_room", sp)
            or get_sprite("kr4_hero_room", "hero_room_portraits_big_" .. hname .. "_0001")
    else
        -- KR6 Genesis heroes (91..105)
        if not hname then return nil end
        local short = hname:gsub("^hero_", ""):gsub("_g6$", "")
        local th_sp = string.format("hero_room_portraits_small_thumb_%s_0001", hname)
        return get_sprite("kr6_hero_portraits", "kr6_hero_portraits_" .. short)
            or get_sprite("kr6_update1_ui", th_sp)
            or get_sprite("kr6_hero_silent_portraits", "kr6_hero_portraits_" .. short)
            or get_sprite("kr6_hero_silent_portraits", th_sp)
            or get_sprite("kr6_hero_room_big", "hero_room_portraits_big_" .. hname .. "_0001")
    end
end

-- Full vertical hero standing portrait (105/105 verified across KR1/2/3/Rebborn/KR5/KR4/KR6!)
function ui.get_hero_big_sprite(hero_idx)
    local idx = tonumber(hero_idx) or catalog.DEFAULT_HERO_1 or 53
    local hname, hd = resolve_hero_tpl(idx)

    if idx <= 47 then
        local pnum = (hd and tonumber(hd.portrait)) or (hd and tonumber(hd.thumb)) or idx
        local sp = string.format("portrait_notxt_%04d", pnum)
        return get_sprite("screen_map_123", sp) or ui.get_hero_sprite(idx)
    elseif not hname then
        return ui.get_hero_sprite(idx)
    end

    local big_sp = string.format("hero_room_portraits_big_%s_0001", hname)
    if idx >= 48 and idx <= 52 then
        return get_sprite("rebborn_heroes_room", big_sp) or ui.get_hero_sprite(idx)
    elseif idx >= 53 and idx <= 72 then
        return get_sprite("room_hero", big_sp) or ui.get_hero_sprite(idx)
    elseif idx >= 73 and idx <= 90 then
        return get_sprite("kr4_hero_room", big_sp) or ui.get_hero_sprite(idx)
    else
        return get_sprite("kr6_hero_room_big", big_sp)
            or get_sprite("kr6_update1_ui", big_sp)
            or get_sprite("kr6_hero_silent_portraits", big_sp)
            or ui.get_hero_sprite(idx)
    end
end

-- Crisp tower medallion (59/59 verified: KR5 gui_common_5 + KR4 kr4_map_towerroom + KR6 kr6_ui_icons/kr6_update1_ui!)
function ui.get_tower_sprite(tower_idx)
    local idx = tonumber(tower_idx) or 1
    local k6 = KR6_TOWER_NAMES[idx]
    if k6 then
        local sp = "kr6_icon_room_tower_" .. k6
        return get_sprite("kr6_ui_icons", sp) or get_sprite("kr6_update1_ui", sp)
    end
    local gi = TOWER_ICON_IDX[idx]
    if not gi then return nil end
    if gi > 400 then
        local sp = string.format("towerselect_quickmenu_icons_%04d", gi - 400)
        return get_sprite("kr4_map_towerroom", sp)
    else
        local sp_kra = string.format("kra_main_icons_%04d", gi)
        local spr = get_sprite("gui_common_5", sp_kra)
        if spr then return spr end
        local sp5 = string.format("main_icons_%04d", gi)
        spr = get_sprite("gui_common_5", sp5)
        if spr then return spr end
        local sp_rt = string.format("quickmenu_main_icons_main_icons_0%03d_0001", gi)
        return get_sprite("room_tower", sp_rt)
    end
end

-- Official hand-painted stage thumbnail postcard (all 6 generations + Rebborn/Zeta!)
function ui.get_stage_sprite(level_idx)
    local idx = tonumber(level_idx) or 101
    -- FL 8.2.0 screen_map.lua maps level 142 preview to 122
    local preview_idx = (idx == 142) and 122 or idx
    local sp = string.format("stage_thumbs_%04d", preview_idx)
    if preview_idx >= 251 then
        return get_sprite("kr6_level_thumbs", sp) or get_sprite("screen_map_123", sp)
    elseif preview_idx >= 193 and preview_idx <= 201 then
        return get_sprite("zeta_level_thumbs", sp) or get_sprite("kr4_level_thumbs", sp)
    elseif preview_idx >= 149 and preview_idx <= 201 then
        return get_sprite("kr4_level_thumbs", sp) or get_sprite("kr5_level_thumbs", sp)
    elseif preview_idx >= 101 and preview_idx <= 148 then
        return get_sprite("kr5_level_thumbs", sp) or get_sprite("screen_map_123", sp)
    elseif preview_idx >= 88 and preview_idx <= 90 then
        return get_sprite("rebborn_level_thumbs", sp) or get_sprite("screen_map_123", sp)
    elseif preview_idx == 91 then
        return get_sprite("stage91_level_thumb", sp) or get_sprite("screen_map_123", sp)
    else
        return get_sprite("screen_map_123", sp) or get_sprite("kr5_level_thumbs", sp)
    end
end

-- === Cached GPU Vertical Gradient Mesh (LÖVE 0.10 & LÖVE 11/12 Android safe, zero banding) ===
local function get_vgrad_mesh(c1, c2)
    local key = string.format("%d_%d_%d_%d|%d_%d_%d_%d",
        c1[1], c1[2], c1[3], c1[4] or 255,
        c2[1], c2[2], c2[3], c2[4] or 255)
    local m = _grad_cache[key]
    if m ~= nil then return m or nil end
    local G = love and love.graphics
    if not G or not G.newMesh then
        _grad_cache[key] = false
        return nil
    end
    local div = proto.is_love11_plus() and 255.0 or 1.0
    local r1, g1, b1, a1 = c1[1] / div, c1[2] / div, c1[3] / div, (c1[4] or 255) / div
    local r2, g2, b2, a2 = c2[1] / div, c2[2] / div, c2[3] / div, (c2[4] or 255) / div
    local ok, mesh = pcall(G.newMesh, {
        { 0, 0, 0, 0, r1, g1, b1, a1 },
        { 1, 0, 1, 0, r1, g1, b1, a1 },
        { 1, 1, 1, 1, r2, g2, b2, a2 },
        { 0, 1, 0, 1, r2, g2, b2, a2 },
    }, "fan", "static")
    if ok and mesh then
        _grad_cache[key] = mesh
        return mesh
    end
    _grad_cache[key] = false
    return nil
end

function ui.draw_vgrad_rect(x, y, w, h, c1, c2, radius)
    local G = love.graphics
    local r = radius or 0
    -- Base rounded fill (guarantees crisp rounded corners!)
    local mr = math.floor((c1[1] + c2[1]) * 0.5)
    local mg = math.floor((c1[2] + c2[2]) * 0.5)
    local mb = math.floor((c1[3] + c2[3]) * 0.5)
    local ma = math.floor(((c1[4] or 255) + (c2[4] or 255)) * 0.5)
    G.setColor(mr, mg, mb, ma)
    G.rectangle("fill", x, y, w, h, r, r)

    local mesh = get_vgrad_mesh(c1, c2)
    if mesh and w > 6 and h > 6 then
        local ins = math.min(math.floor(r * 0.45), 4)
        G.setColor(255, 255, 255, 255)
        G.draw(mesh, x + ins, y + ins, 0, w - ins * 2, h - ins * 2)
    end
end

-- Crisp shadow text helper (exact 1:1 physical pixel alignment + integer drop shadow)
function ui.print_shadow(text, x, y, col, align_w, align, shadow_col, font)
    local G = love.graphics
    local s, ox, oy = _tf.s, _tf.ox, _tf.oy
    local f = font or G.getFont()
    if f then G.setFont(f) end
    local px = math.floor(ox + x * s + 0.5)
    local py = math.floor(oy + y * s + 0.5)
    local sh_dy = math.max(1, math.floor(s * 0.85 + 0.5))
    local sc = shadow_col or { 20, 10, 4, 210 }
    local str = tostring(text or "")

    G.push()
    G.origin()
    if align_w then
        local pw = math.max(1, math.floor(align_w * s + 0.5))
        G.setColor(sc[1], sc[2], sc[3], sc[4] or 210)
        G.printf(str, px, py + sh_dy, pw, align or "left")
        G.setColor(col[1], col[2], col[3], col[4] or 255)
        G.printf(str, px, py, pw, align or "left")
    else
        G.setColor(sc[1], sc[2], sc[3], sc[4] or 210)
        G.print(str, px, py + sh_dy)
        G.setColor(col[1], col[2], col[3], col[4] or 255)
        G.print(str, px, py)
    end
    G.pop()
end

-- Draw sprite cleanly inside (x, y, w, h) with optional cover/top-align crop & frame
function ui.draw_sprite_box(sp, x, y, w, h, opts)
    local G = love.graphics
    opts = opts or {}
    local r = opts.radius or 6
    local pad = opts.pad or 2
    local bg = opts.bg or { 26, 15, 8, 245 }
    local border = opts.border or ui.THEME.gold_rim
    local border_w = opts.border_w or 1.6

    if not opts.no_frame then
        G.setColor(bg[1], bg[2], bg[3], bg[4] or 245)
        G.rectangle("fill", x, y, w, h, r, r)
    end

    if sp and sp.img and sp.quad then
        local inner_w = math.max(1, w - pad * 2)
        local inner_h = math.max(1, h - pad * 2)
        local sc = opts.cover
            and math.max(inner_w / sp.qw, inner_h / sp.qh)
            or math.min(inner_w / sp.qw, inner_h / sp.qh)
        local dw = sp.qw * sc
        local dh = sp.qh * sc
        local dx = x + (w - dw) * 0.5
        local dy
        if opts.align_top then
            dy = y + pad
        else
            dy = y + (h - dh) * 0.5
        end

        local prev_sx, prev_sy, prev_sw, prev_sh = G.getScissor()
        if opts.clip ~= false and inner_w > 0 and inner_h > 0 then
            ui.set_scissor_logical(x + pad, y + pad, inner_w, inner_h)
        end
        G.setColor(255, 255, 255, opts.alpha or 255)
        G.draw(sp.img, sp.quad, dx, dy, 0, sc, sc)
        if opts.clip ~= false then
            if prev_sx then G.setScissor(prev_sx, prev_sy, prev_sw, prev_sh)
            else G.setScissor() end
        end
    else
        G.setColor(64, 44, 24, 220)
        G.circle("fill", x + w * 0.5, y + h * 0.5, math.min(w, h) * 0.32)
    end

    if not opts.no_frame then
        G.setColor(border[1], border[2], border[3], border[4] or 240)
        G.setLineWidth(border_w)
        G.rectangle("line", x, y, w, h, r, r)
    end
end

function ui.draw_hero_portrait(hero_idx, x, y, w, h, opts)
    ui.draw_sprite_box(ui.get_hero_sprite(hero_idx), x, y, w, h, opts)
end

function ui.draw_hero_big_portrait(hero_idx, x, y, w, h, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.cover == nil then o.cover = true end
    if o.align_top == nil then o.align_top = true end
    ui.draw_sprite_box(ui.get_hero_big_sprite(hero_idx), x, y, w, h, o)
end

function ui.draw_tower_icon(tower_idx, x, y, w, h, opts)
    ui.draw_sprite_box(ui.get_tower_sprite(tower_idx), x, y, w, h, opts)
end

function ui.draw_stage_thumb(level_idx, x, y, w, h, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.cover == nil then o.cover = true end
    ui.draw_sprite_box(ui.get_stage_sprite(level_idx), x, y, w, h, o)
end

-- === Ironhide V2 Parchment & Hand-Hewn Oak War-Table Shell ===
function ui.draw_ironhide_war_table(px, py, pw, ph, banner_title, font_banner)
    local G = love.graphics
    local T = ui.THEME

    -- 1. Deep soft war-table drop shadow
    G.setColor(0, 0, 0, 88)
    G.rectangle("fill", px - 6, py + 8, pw + 12, ph + 8, 16, 16)
    G.setColor(0, 0, 0, 128)
    G.rectangle("fill", px - 2, py + 4, pw + 4, ph + 3, 14, 14)

    -- 2. Hand-Hewn Dark Oak Outer Timber Frame
    ui.draw_vgrad_rect(px, py, pw, ph, T.wood_top, T.wood_bot, 13)
    -- Subtle vertical oak grain lines
    G.setColor(255, 212, 148, 14)
    G.setLineWidth(1)
    for gx = px + 14, px + pw - 14, 16 do
        G.line(gx, py + 3, gx, py + ph - 3)
    end
    -- Upper timber bevel highlight & bottom dark groove
    G.setColor(T.wood_hi[1], T.wood_hi[2], T.wood_hi[3], T.wood_hi[4])
    G.setLineWidth(2)
    G.line(px + 12, py + 2.5, px + pw - 12, py + 2.5)
    -- Thick Ironhide comic ink outer outline
    G.setColor(T.ink_dark[1], T.ink_dark[2], T.ink_dark[3], 255)
    G.setLineWidth(3)
    G.rectangle("line", px, py, pw, ph, 13, 13)

    -- 3. Sunlit Aged Parchment Inner Spread
    local ix, iy, iw, ih = px + 11, py + 11, pw - 22, ph - 22
    ui.draw_vgrad_rect(ix, iy, iw, ih, T.parchment_top, T.parchment_bot, 9)

    -- Tiled handmade paper grain overlay
    local grain = ui.get_ext_image("parchment_grain.png", true)
    if grain then
        local prev_sx, prev_sy, prev_sw, prev_sh = G.getScissor()
        ui.set_scissor_logical(ix + 2, iy + 2, iw - 4, ih - 4)
        G.setColor(255, 255, 255, 165)
        local gw, gh = grain:getWidth(), grain:getHeight()
        for ty = iy, iy + ih, gh do
            for tx = ix, ix + iw, gw do
                G.draw(grain, tx, ty)
            end
        end
        if prev_sx then G.setScissor(prev_sx, prev_sy, prev_sw, prev_sh) else G.setScissor() end
    end

    -- Subtle burnt sepia bottom/side inner vignette
    G.setColor(138, 86, 32, 34)
    G.setLineWidth(6)
    G.rectangle("line", ix + 3, iy + 3, iw - 6, ih - 6, 7, 7)

    -- Subtle sepia compass rose watermark in upper-right
    local compass = ui.get_ext_image("compass_rose.png")
    if compass then
        G.setColor(255, 255, 255, 26)
        G.draw(compass, ix + iw - 178, iy + 18, 0, 0.92, 0.92)
    end

    -- Hand-inked double parchment inner border
    G.setColor(T.parchment_edge[1], T.parchment_edge[2], T.parchment_edge[3], 235)
    G.setLineWidth(2)
    G.rectangle("line", ix, iy, iw, ih, 9, 9)
    G.setColor(T.parchment_line[1], T.parchment_line[2], T.parchment_line[3], T.parchment_line[4])
    G.setLineWidth(1)
    G.rectangle("line", ix + 6, iy + 6, iw - 12, ih - 12, 6, 6)

    -- 4. Four Forged Wrought-Iron Corner Brackets with Brass Rivets
    local corner = ui.get_ext_image("iron_corner.png")
    if corner then
        local cw, ch = corner:getWidth(), corner:getHeight()
        local sc = 0.86
        local dw, dh = cw * sc, ch * sc
        G.setColor(255, 255, 255, 255)
        G.draw(corner, px - 3, py - 3, 0, sc, sc)                               -- TL
        G.draw(corner, px + pw + 3, py - 3, 0, -sc, sc)                         -- TR
        G.draw(corner, px - 3, py + ph + 3, 0, sc, -sc)                         -- BL
        G.draw(corner, px + pw + 3, py + ph + 3, 0, -sc, -sc)                   -- BR
        local _ = dw + dh
    end

    -- 5. Protruding Royal Crimson Silk Banner centered cleanly across top timber edge!
    local ribbon = ui.get_ext_image("ribbon_banner.png")
    if ribbon then
        local rw, rh = ribbon:getWidth(), ribbon:getHeight()
        local rsc = math.min(0.88, (pw * 0.56) / rw)
        local drw, drh = rw * rsc, rh * rsc
        local rx = math.floor(px + (pw - drw) * 0.5)
        local ry = math.floor(py - drh * 0.44)
        G.setColor(255, 255, 255, 255)
        G.draw(ribbon, rx, ry, 0, rsc, rsc)
        if banner_title and #banner_title > 0 then
            local fh = font_banner and ui.font_h(font_banner) or 16
            -- Perfectly centered INSIDE the inner stitched gold field!
            local ty = ry + drh * 0.48 - fh * 0.5
            ui.print_shadow(banner_title, rx, ty, T.gold_bright, drw, "center", { 52, 8, 5, 235 }, font_banner)
        end
    end
end

-- Recessed Dark-Oak Velvet Armory Tray (for 12-tower deck or room notice board)
function ui.draw_armory_tray(x, y, w, h, radius)
    local G = love.graphics
    local T = ui.THEME
    local r = radius or 9
    -- Warm parchment catch-light under tray lip
    G.setColor(255, 248, 224, 155)
    G.rectangle("fill", x, y + 2, w, h, r, r)
    -- Dark oak interior
    ui.draw_vgrad_rect(x, y, w, h, T.armory_top, T.armory_bot, r)
    -- Recessed top drop shadow inside tray
    G.setColor(0, 0, 0, 95)
    G.rectangle("fill", x + 3, y + 2, w - 6, 7, 3, 3)
    -- Dark comic ink border
    G.setColor(T.ink_dark[1], T.ink_dark[2], T.ink_dark[3], 255)
    G.setLineWidth(2.2)
    G.rectangle("line", x, y, w, h, r, r)
end

-- Pinned Parchment Card with optional 3D Brass Thumbtack at top center
function ui.draw_parchment_card(x, y, w, h, opts)
    local G = love.graphics
    local T = ui.THEME
    opts = opts or {}
    local r = opts.radius or 8
    -- Soft drop shadow onto parchment
    G.setColor(58, 32, 10, 52)
    G.rectangle("fill", x + 1, y + 3, w, h, r, r)
    ui.draw_vgrad_rect(x, y, w, h, opts.top or T.parchment_card, opts.bot or T.parchment_card2, r)
    local bc = opts.border or { 142, 98, 44, 235 }
    G.setColor(bc[1], bc[2], bc[3], bc[4] or 235)
    G.setLineWidth(opts.border_w or 1.6)
    G.rectangle("line", x, y, w, h, r, r)

    if opts.thumbtack then
        ui.draw_brass_rivet(x + w * 0.5, y, 6.5)
    end
end

-- 3D Hammered Brass Rivet / Map Thumbtack
function ui.draw_brass_rivet(cx, cy, r)
    local G = love.graphics
    r = r or 5
    G.setColor(28, 14, 4, 140)
    G.circle("fill", cx + 0.8, cy + 2.0, r + 0.6)
    G.setColor(186, 134, 50, 255)
    G.circle("fill", cx, cy, r)
    G.setColor(246, 206, 118, 255)
    G.circle("fill", cx - r * 0.12, cy - r * 0.14, r * 0.72)
    G.setColor(255, 248, 210, 230)
    G.circle("fill", cx - r * 0.3, cy - r * 0.32, r * 0.28)
    G.setColor(44, 22, 8, 255)
    G.setLineWidth(1.3)
    G.circle("line", cx, cy, r)
end

-- Crisp vector icons for wax seals
local function draw_seal_check(cx, cy, sz, col, sh)
    local G = love.graphics
    local x1, y1 = cx - sz * 0.48, cy + sz * 0.02
    local x2, y2 = cx - sz * 0.12, cy + sz * 0.38
    local x3, y3 = cx + sz * 0.52, cy - sz * 0.36
    G.setLineJoin("bevel")
    G.setLineWidth(sz * 0.28)
    G.setColor(sh[1], sh[2], sh[3], sh[4] or 220)
    G.line(x1, y1 + 1.1, x2, y2 + 1.1, x3, y3 + 1.1)
    G.setColor(col[1], col[2], col[3], col[4] or 255)
    G.line(x1, y1, x2, y2, x3, y3)
end

local function draw_seal_dots(cx, cy, r, col, sh)
    local G = love.graphics
    for i = -1, 1 do
        local dx = cx + i * r * 3.1
        G.setColor(sh[1], sh[2], sh[3], sh[4] or 210)
        G.circle("fill", dx, cy + 1, r)
        G.setColor(col[1], col[2], col[3], col[4] or 255)
        G.circle("fill", dx, cy, r)
    end
end

-- Smooth high-segment scalloped royal wax seal (emerald for ready, rich amber-gold for waiting/joined)
local function draw_scalloped_vector_seal(cx, cy, rad, is_emerald)
    local G = love.graphics
    local pts = {}
    local n = 36
    for i = 0, n - 1 do
        local a = (i / n) * math.pi * 2
        local rr = rad * ((i % 2 == 0) and 1.0 or 0.87)
        pts[#pts + 1] = cx + math.cos(a) * rr
        pts[#pts + 1] = cy + math.sin(a) * rr
    end
    local body_c = is_emerald and { 34, 146, 62, 255 } or { 166, 102, 28, 255 }
    local ink_c  = is_emerald and { 12, 54, 24, 255 }  or { 62, 32, 8, 255 }
    local disc_c = is_emerald and { 22, 108, 46, 255 } or { 126, 74, 16, 255 }
    local gloss_c = is_emerald and { 200, 255, 206, 155 } or { 255, 236, 186, 155 }

    -- Soft drop shadow
    G.setColor(14, 7, 3, 155)
    G.circle("fill", cx + 1.2, cy + 2.6, rad * 0.96, 48)
    -- Scalloped wax body + dark comic ink contour
    G.setColor(body_c[1], body_c[2], body_c[3], body_c[4])
    G.polygon("fill", pts)
    G.setColor(ink_c[1], ink_c[2], ink_c[3], ink_c[4])
    G.setLineWidth(2.0)
    G.polygon("line", pts)
    -- Recessed inner seal bed (smooth 48 segments!)
    G.setColor(disc_c[1], disc_c[2], disc_c[3], disc_c[4])
    G.circle("fill", cx, cy, rad * 0.74, 48)
    -- Subtle inner shadow ring for stamped depth
    G.setColor(ink_c[1], ink_c[2], ink_c[3], 90)
    G.setLineWidth(1.5)
    G.circle("line", cx, cy, rad * 0.69, 48)
    -- Specular glossy highlight arc on upper-left rim
    G.setColor(gloss_c[1], gloss_c[2], gloss_c[3], gloss_c[4])
    G.setLineWidth(2.2)
    G.arc("line", "open", cx, cy, rad * 0.80, -math.pi * 0.84, -math.pi * 0.36, 24)
    -- Smooth embossed gold inner circle (48 segments, generous clearance around text!)
    G.setColor(248, 224, 146, 242)
    G.setLineWidth(1.6)
    G.circle("line", cx, cy, rad * 0.72, 48)
end

local function draw_scalloped_emerald_seal(cx, cy, rad)
    draw_scalloped_vector_seal(cx, cy, rad, true)
end

local function draw_png_seal(cx, cy, rad, is_red)
    local G = love.graphics
    local img = ui.get_ext_image(is_red and "wax_seal_red.png" or "wax_seal_amber.png")
    local sz = rad * 2
    if img then
        local sc = sz / img:getWidth()
        G.setColor(255, 255, 255, 255)
        G.draw(img, cx - rad, cy - rad, 0, sc, sc)
    else
        G.setColor(is_red and 172 or 136, is_red and 32 or 88, is_red and 32 or 40, 255)
        G.circle("fill", cx, cy, rad)
        G.setColor(64, 12, 10, 255)
        G.setLineWidth(1.8)
        G.circle("line", cx, cy, rad)
    end
end

-- Redesigned Embossed Scalloped Wax Seal (supports 4 live-switchable styles: ribbon / callig / stack / medal)
-- status: "ready" | "joined" | "waiting"
function ui.draw_wax_seal(cx, cy, radius, status, font_map, style_override)
    local G = love.graphics
    local style = style_override or ui.seal_style or "ribbon"
    local is_ready = (status == "ready" or status == true)
    local is_joined = (status == "joined")
    local fm = type(font_map) == "table" and font_map or {}

    if style == "ribbon" then
        -- 方案 A：徽标蜡封 + 底部金边小缎带（已就绪 / 等待中 / 已入房）
        local rad = math.max(20, (radius or 24) - 2)
        if is_ready then
            draw_scalloped_emerald_seal(cx, cy - 2, rad)
            draw_seal_check(cx, cy - 2, 13.5, { 255, 248, 214, 255 }, { 14, 52, 22, 235 })
        else
            draw_png_seal(cx, cy - 2, rad, false)
            draw_seal_dots(cx + 0.5, cy - 1, 2.2, { 255, 244, 206, 255 }, { 54, 24, 6, 235 })
        end
        local rw, rh = 52, 16
        local rx, ry = cx - rw * 0.5, cy + 11
        local rc1 = is_ready and { 42, 152, 64, 255 } or { 166, 98, 24, 255 }
        local rc2 = is_ready and { 24, 96, 38, 255 } or { 112, 60, 12, 255 }
        G.setColor(18, 8, 4, 155)
        G.rectangle("fill", rx - 1, ry + 2, rw + 2, rh + 1, 4, 4)
        ui.draw_vgrad_rect(rx, ry, rw, rh, rc1, rc2, 4)
        G.setColor(246, 214, 134, 245)
        G.setLineWidth(1.3)
        G.rectangle("line", rx, ry, rw, rh, 4, 4)
        local lbl = is_ready and "已就绪" or (is_joined and "已入房" or "等待中")
        local tf = fm.seal or fm.tiny_bold
        ui.print_shadow(lbl, rx, ry + (rh - ui.font_h(tf)) * 0.5, { 255, 250, 230, 255 }, rw, "center", { 24, 12, 4, 235 }, tf)

    elseif style == "callig" then
        -- 方案 1 精修：大号平滑翡翠/琥珀皇家蜡封圆章 + 官配 JIMOJW 双字居中（内环留白充足、绝不穿模）
        local rad = math.max(27, radius or 28)
        draw_scalloped_vector_seal(cx, cy, rad, is_ready)
        local lbl = is_ready and "就绪" or (is_joined and "已入" or "等待")
        local tf = fm.seal_disp or fm.small_bold
        ui.print_shadow(lbl, cx - rad, cy - ui.font_h(tf) * 0.5,
            { 255, 248, 214, 255 }, rad * 2, "center",
            is_ready and { 10, 44, 18, 245 } or { 50, 22, 5, 245 }, tf)

    elseif style == "stack" then
        -- 方案 C：原版朱红/琥珀蜡封 + 内圈图标双行精排（√ 就绪 / ••• 等待）
        local rad = (radius or 24) + 1
        draw_png_seal(cx, cy, rad, is_ready)
        local tf = fm.seal or fm.tiny_bold
        if is_ready then
            draw_seal_check(cx + 0.5, cy - 6.5, 9.5, { 255, 236, 156, 255 }, { 54, 10, 8, 240 })
            ui.print_shadow("就绪", cx - rad + 0.5, cy + 1.5, { 255, 246, 214, 255 }, rad * 2, "center", { 54, 10, 8, 240 }, tf)
        else
            draw_seal_dots(cx + 0.5, cy - 6, 1.9, { 255, 236, 166, 255 }, { 54, 24, 6, 240 })
            ui.print_shadow(is_joined and "已入" or "等待", cx - rad + 0.5, cy + 1.5, { 255, 246, 214, 255 }, rad * 2, "center", { 54, 24, 6, 240 }, tf)
        end

    else
        -- 方案 D：双飘带皇家勋章 + 图标与主字体双行
        local rad = radius or 24
        local tc1 = is_ready and { 38, 134, 58, 255 } or { 158, 94, 24, 255 }
        local tbd = is_ready and { 16, 56, 24, 255 } or { 68, 36, 8, 255 }
        G.setColor(tc1[1], tc1[2], tc1[3], 255)
        G.polygon("fill", cx - 11, cy + 12, cx - 2, cy + 14, cx - 5, cy + 36, cx - 10, cy + 30, cx - 15, cy + 34)
        G.polygon("fill", cx + 2, cy + 14, cx + 11, cy + 12, cx + 15, cy + 34, cx + 10, cy + 30, cx + 5, cy + 36)
        G.setColor(tbd[1], tbd[2], tbd[3], 255)
        G.setLineWidth(1.4)
        G.polygon("line", cx - 11, cy + 12, cx - 2, cy + 14, cx - 5, cy + 36, cx - 10, cy + 30, cx - 15, cy + 34)
        G.polygon("line", cx + 2, cy + 14, cx + 11, cy + 12, cx + 15, cy + 34, cx + 10, cy + 30, cx + 5, cy + 36)
        if is_ready then
            draw_scalloped_emerald_seal(cx, cy, rad)
            draw_seal_check(cx, cy - 6.5, 9.5, { 255, 242, 168, 255 }, { 14, 52, 22, 240 })
            local tf = fm.seal_small or fm.seal
            ui.print_shadow("就绪", cx - rad, cy + 1.5, { 255, 250, 224, 255 }, rad * 2, "center", { 14, 52, 22, 240 }, tf)
        else
            draw_png_seal(cx, cy, rad, false)
            draw_seal_dots(cx + 0.5, cy - 6, 1.9, { 255, 238, 174, 255 }, { 54, 24, 6, 240 })
            local tf = fm.seal_small or fm.seal
            ui.print_shadow(is_joined and "已入" or "等待", cx - rad + 0.5, cy + 1.5, { 255, 246, 214, 255 }, rad * 2, "center", { 54, 24, 6, 240 }, tf)
        end
    end
end

-- Sleek Pill Badge
function ui.draw_pill(x, y, w, h, text, bg, border, fg, font)
    local G = love.graphics
    local r = math.floor(h * 0.5)
    G.setColor(bg[1], bg[2], bg[3], bg[4] or 235)
    G.rectangle("fill", x, y, w, h, r, r)
    if border then
        G.setColor(border[1], border[2], border[3], border[4] or 220)
        G.setLineWidth(1.2)
        G.rectangle("line", x, y, w, h, r, r)
    end
    if text and #text > 0 then
        local fh = font and ui.font_h(font) or 11
        local ty = y + (h - fh) * 0.5
        ui.text(text, x, ty, fg, font, w, "center")
    end
end

-- Crisp Vector Gold Coin Icon
function ui.draw_coin_icon(cx, cy, r)
    local G = love.graphics
    r = r or 5.5
    G.setColor(44, 22, 6, 220)
    G.circle("fill", cx, cy + 1, r + 0.8)
    G.setColor(178, 118, 22, 255)
    G.circle("fill", cx, cy, r)
    G.setColor(252, 210, 82, 255)
    G.circle("fill", cx, cy, r - 1.3)
    G.setColor(255, 246, 186, 235)
    G.circle("fill", cx - r * 0.25, cy - r * 0.25, r * 0.34)
    G.setColor(98, 56, 12, 235)
    G.setLineWidth(1.1)
    G.circle("line", cx, cy, r)
end

-- Live Latency Crystal Dot
function ui.draw_ping_dot(cx, cy, rtt, connected)
    local G = love.graphics
    local cr, cg, cb
    if connected == false then
        cr, cg, cb = 236, 168, 48
    elseif (rtt or 0) <= 55 then
        cr, cg, cb = 52, 216, 122
    elseif (rtt or 0) <= 130 then
        cr, cg, cb = 244, 184, 56
    else
        cr, cg, cb = 238, 76, 72
    end
    G.setColor(cr, cg, cb, 78)
    G.circle("fill", cx, cy, 6.2)
    G.setColor(cr, cg, cb, 255)
    G.circle("fill", cx, cy, 3.6)
    G.setColor(255, 255, 255, 155)
    G.circle("fill", cx - 1, cy - 1, 1.2)
end

-- === Tactile Ironhide Button Renderer ===
-- Supports styles: "battle" (3D glossy emerald CTA), "wood", "crimson", "parchment", "azure", "input", "hero_tile", "tower_tile"
function ui.draw_button(b, hover, font_map)
    local G = love.graphics
    local T = ui.THEME
    local r = b.radius or 7
    local style = b.style or "wood"
    local disabled = b.disabled == true

    -- 1. Recessed Parchment Input Box
    if style == "input" then
        local focused = b.focused == true
        G.setColor(255, 252, 242, 252)
        G.rectangle("fill", b.x, b.y, b.w, b.h, r, r)
        -- Inner top shadow
        G.setColor(96, 62, 24, 52)
        G.rectangle("fill", b.x + 2, b.y + 1, b.w - 4, 4, 2, 2)
        local bc = focused and { 196, 118, 22, 255 } or (hover and { 156, 102, 42, 255 } or { 138, 96, 46, 225 })
        G.setColor(bc[1], bc[2], bc[3], bc[4])
        G.setLineWidth(focused and 2.2 or 1.6)
        G.rectangle("line", b.x, b.y, b.w, b.h, r, r)

        local f = (b.small and font_map.small) or font_map.main
        local fh = f and ui.font_h(f) or 13
        local ty = b.y + (b.h - fh) * 0.5
        local tc = b.placeholder and T.ink_muted or T.ink_text
        ui.text(b.label or "", b.x + 9, ty, tc, f, b.w - 18, "left")
        return
    end

    -- 2. Hero Codex Vertical Card Button
    if style == "hero_tile" then
        local sel = b.selected == true
        local top_c = sel and (b.is_p1 and { 210, 232, 252, 255 } or { 252, 218, 218, 255 })
            or (hover and { 255, 248, 228, 255 } or { 248, 236, 206, 250 })
        local bot_c = sel and (b.is_p1 and { 182, 214, 248, 255 } or { 244, 194, 196, 255 })
            or (hover and { 244, 224, 180, 255 } or { 234, 212, 168, 250 })
        G.setColor(48, 26, 8, 55)
        G.rectangle("fill", b.x + 1, b.y + 2, b.w, b.h, r, r)
        ui.draw_vgrad_rect(b.x, b.y, b.w, b.h, top_c, bot_c, r)

        local bc = sel and (b.is_p1 and T.p1_border or T.p2_border)
            or (hover and { 126, 76, 26, 255 } or { 164, 124, 68, 225 })
        G.setColor(bc[1], bc[2], bc[3], bc[4])
        G.setLineWidth(sel and 2.4 or (hover and 1.8 or 1.3))
        G.rectangle("line", b.x, b.y, b.w, b.h, r, r)

        -- Square crisp portrait on left
        local isz = b.icon_size or (b.h - 10)
        ui.draw_hero_portrait(b.hero_idx, b.x + 5, b.y + math.floor((b.h - isz) * 0.5), isz, isz, {
            radius = 5, pad = 1, border = sel and bc or { 112, 74, 34, 235 }, border_w = 1.5,
        })
        local tx = b.x + isz + 9
        local tw = math.max(10, b.x + b.w - tx - (sel and 19 or 4))
        local lbl = b.label or ""
        local f = font_map.small_bold or font_map.small or font_map.main
        if f and font_map.tiny and ui.font_w(f, lbl) > tw then
            f = font_map.tiny
        end
        local fh = f and ui.font_h(f) or 12
        ui.text(lbl, tx, b.y + b.h * 0.5 - fh - 1, T.ink_text, f)
        if b.sub_label and font_map.tiny then
            ui.text(b.sub_label, tx, b.y + b.h * 0.5 + 3, T.ink_sub, font_map.tiny)
        end
        if sel then
            local bx, by = b.x + b.w - 17, b.y + 4
            local pcol = b.is_p1 and T.p1_top or T.p2_top
            G.setColor(pcol[1], pcol[2], pcol[3], 255)
            G.rectangle("fill", bx, by, 14, 14, 4, 4)
            G.setColor(255, 240, 190, 240)
            G.setLineWidth(1)
            G.rectangle("line", bx, by, 14, 14, 4, 4)
            local cf = font_map.tiny_bold or font_map.tiny
            local cfh = cf and ui.font_h(cf) or 11
            ui.text("√", bx, by + (14 - cfh) * 0.5, { 255, 255, 255, 255 }, cf, 14, "center")
        end
        return
    end

    -- 3. Tower Armory Medallion Card Button
    if style == "tower_tile" then
        local sel = b.selected == true
        local top_c = sel and { 222, 242, 206, 255 } or (hover and { 255, 248, 228, 255 } or { 246, 232, 198, 245 })
        local bot_c = sel and { 196, 228, 174, 255 } or (hover and { 242, 220, 174, 255 } or { 232, 210, 164, 245 })
        G.setColor(48, 26, 8, 48)
        G.rectangle("fill", b.x + 1, b.y + 2, b.w, b.h, r, r)
        ui.draw_vgrad_rect(b.x, b.y, b.w, b.h, top_c, bot_c, r)

        local bc = sel and { 42, 122, 52, 255 } or (hover and { 126, 76, 26, 255 } or { 166, 126, 70, 220 })
        G.setColor(bc[1], bc[2], bc[3], bc[4])
        G.setLineWidth(sel and 2.2 or (hover and 1.7 or 1.3))
        G.rectangle("line", b.x, b.y, b.w, b.h, r, r)

        local isz = b.icon_size or (b.h - 10)
        ui.draw_tower_icon(b.tower_idx, b.x + 5, b.y + math.floor((b.h - isz) * 0.5), isz, isz, {
            radius = 5, pad = 1, bg = { 34, 19, 9, 250 },
            border = sel and T.gold_mid or { 118, 82, 42, 230 }, border_w = 1.4,
        })
        local tx = b.x + isz + 10
        local tw = math.max(10, b.x + b.w - tx - (sel and 19 or 4))
        local lbl = b.label or ""
        local f = font_map.small_bold or font_map.small or font_map.main
        if f and font_map.tiny and ui.font_w(f, lbl) > tw then
            f = font_map.tiny
        end
        local fh = f and ui.font_h(f) or 12
        ui.text(lbl, tx, b.y + b.h * 0.5 - fh, T.ink_text, f, tw, "left")
        if b.sub_label and font_map.tiny then
            local sc = sel and { 34, 108, 42, 255 } or T.ink_muted
            ui.text(b.sub_label, tx, b.y + b.h * 0.5 + 2, sc, font_map.tiny, tw, "left")
        end
        if sel then
            local bx, by = b.x + b.w - 17, b.y + 4
            G.setColor(44, 138, 56, 255)
            G.rectangle("fill", bx, by, 14, 14, 4, 4)
            G.setColor(255, 248, 220, 240)
            G.setLineWidth(1)
            G.rectangle("line", bx, by, 14, 14, 4, 4)
            local cf = font_map.tiny_bold or font_map.tiny
            local cfh = cf and ui.font_h(cf) or 11
            ui.text("√", bx, by + (14 - cfh) * 0.5, { 255, 255, 255, 255 }, cf, 14, "center")
        end
        return
    end

    -- 4. Sculpted 3D Ironhide Battle / Wood / Crimson / Parchment / Azure Buttons
    local top_c, bot_c, lip_c, rim_c, fg_c, sh_c
    local bevel_h = 3
    if style == "battle" then
        bevel_h = 4
        if disabled then
            top_c, bot_c = { 132, 124, 110, 235 }, { 96, 88, 76, 235 }
            lip_c, rim_c = { 62, 56, 48, 240 }, { 56, 48, 38, 240 }
            fg_c, sh_c = { 226, 220, 206, 210 }, { 30, 24, 16, 160 }
        else
            top_c = hover and { 122, 234, 96, 255 } or T.emerald_top
            bot_c = hover and { 46, 144, 34, 255 } or T.emerald_bot
            lip_c, rim_c = { 24, 66, 16, 255 }, T.emerald_ink
            fg_c, sh_c = { 255, 254, 244, 255 }, { 12, 46, 8, 235 }
        end
    elseif style == "crimson" then
        top_c = hover and { 236, 98, 86, 255 } or T.crimson_top
        bot_c = hover and { 164, 42, 36, 255 } or T.crimson_bot
        lip_c, rim_c = { 76, 16, 14, 255 }, T.crimson_ink
        fg_c, sh_c = { 255, 244, 238, 255 }, { 54, 8, 6, 225 }
    elseif style == "azure" then
        top_c = hover and { 62, 128, 204, 255 } or { 46, 108, 178, 255 }
        bot_c = hover and { 36, 84, 144, 255 } or { 28, 68, 120, 255 }
        lip_c, rim_c = { 16, 40, 74, 255 }, { 18, 42, 76, 255 }
        fg_c, sh_c = { 244, 250, 255, 255 }, { 10, 24, 48, 225 }
    elseif style == "parchment" then
        bevel_h = 2
        local act = b.active or b.selected
        top_c = act and { 222, 242, 206, 255 } or (hover and { 255, 250, 234, 255 } or { 252, 242, 218, 255 })
        bot_c = act and { 192, 226, 170, 255 } or (hover and { 244, 224, 182, 255 } or { 234, 210, 162, 255 })
        lip_c = act and { 42, 104, 46, 255 } or { 126, 86, 38, 255 }
        rim_c = act and { 38, 114, 48, 255 } or { 138, 96, 44, 255 }
        fg_c = b.fg or T.ink_text
        sh_c = nil
    else -- "wood"
        local act = b.active or b.selected
        top_c = act and { 162, 104, 46, 255 } or (hover and { 150, 98, 56, 255 } or { 132, 85, 50, 255 })
        bot_c = act and { 114, 68, 26, 255 } or (hover and { 92, 54, 28, 255 } or { 74, 42, 20, 255 })
        lip_c, rim_c = { 34, 17, 6, 255 }, { 34, 17, 6, 255 }
        fg_c, sh_c = { 255, 240, 202, 255 }, { 22, 10, 3, 220 }
    end

    if b.fg then fg_c = b.fg end

    -- Physical 3D bottom extrusion bevel + drop shadow
    G.setColor(0, 0, 0, 72)
    G.rectangle("fill", b.x + 1, b.y + bevel_h + 2, b.w, b.h, r, r)
    G.setColor(lip_c[1], lip_c[2], lip_c[3], lip_c[4])
    G.rectangle("fill", b.x, b.y + bevel_h, b.w, b.h, r, r)

    -- Main gradient face
    ui.draw_vgrad_rect(b.x, b.y, b.w, b.h, top_c, bot_c, r)

    -- Signature Ironhide glossy cartoon specular bar on battle/crimson/azure/wood
    if not disabled then
        if style == "battle" then
            G.setColor(238, 255, 208, 76)
            G.rectangle("fill", b.x + 8, b.y + 3, b.w - 16, math.max(5, math.floor(b.h * 0.30)), r - 2, r - 2)
            -- Twin hammered gold rivets only on wide primary battle plaques (never crowd compact buttons!)
            if b.w >= 200 and b.rivets ~= false then
                ui.draw_brass_rivet(b.x + 22, b.y + b.h * 0.5, 4.5)
                ui.draw_brass_rivet(b.x + b.w - 22, b.y + b.h * 0.5, 4.5)
            end
        elseif style == "parchment" then
            G.setColor(255, 255, 255, 130)
            G.line(b.x + 6, b.y + 1.5, b.x + b.w - 6, b.y + 1.5)
        else
            G.setColor(255, 232, 185, hover and 56 or 38)
            G.rectangle("fill", b.x + 4, b.y + 2, b.w - 8, math.max(4, math.floor(b.h * 0.32)), r - 2, r - 2)
        end
    end

    -- Comic ink outer contour
    G.setColor(rim_c[1], rim_c[2], rim_c[3], rim_c[4])
    G.setLineWidth(style == "battle" and 2.4 or 1.8)
    G.rectangle("line", b.x, b.y, b.w, b.h, r, r)

    -- Crisp centered label (supports multi-line \n; uses bold on dark/colored 3D buttons for crisp contrast)
    local use_bold = (style ~= "parchment")
    local f
    if b.large and font_map.title then
        f = font_map.title
    elseif b.tiny then
        f = (use_bold and font_map.tiny_bold) or font_map.tiny
    elseif b.small then
        f = (use_bold and font_map.small_bold) or font_map.small
    else
        f = (use_bold and font_map.main_bold) or font_map.main
    end

    local lbl = b.label or ""
    local lines = 1
    for _ in lbl:gmatch("\n") do lines = lines + 1 end
    local fh = f and ui.font_h(f) or 13
    local total_h = fh * lines + (lines - 1) * 2
    local ty = b.y + (b.h - total_h) * 0.5
    if sh_c then
        ui.print_shadow(lbl, b.x + 4, ty, fg_c, b.w - 8, "center", sh_c, f)
    else
        ui.text(lbl, b.x + 4, ty, fg_c, f, b.w - 8, "center")
    end
end

-- Animated 5-bar broadcast voice equalizer (purely visual, driven by wall clock; never touches sim/PRNG)
function ui.draw_voice_eq(x, y, w, h, level, active, col_hi, col_lo)
    local G = love.graphics
    local n = 5
    local gap = 2
    local bw = math.max(2, math.floor((w - (n - 1) * gap) / n))
    local total_w = bw * n + gap * (n - 1)
    local sx = x + math.floor((w - total_w) * 0.5)
    local t = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
    local lvl = math.max(0, math.min(1, tonumber(level) or 0))
    local hi = col_hi or { 104, 244, 152, 255 }
    local lo = col_lo or { 52, 186, 98, 220 }
    local weights = { 0.62, 0.94, 1.0, 0.86, 0.58 }
    local freqs = { 13.5, 17.2, 11.8, 15.6, 19.1 }
    local phases = { 0.0, 1.4, 2.7, 0.8, 3.9 }

    for i = 1, n do
        local bx = sx + (i - 1) * (bw + gap)
        local bh
        if active then
            local wave = 0.55 + 0.45 * math.sin(t * freqs[i] + phases[i])
            local amp = math.max(0.20, math.min(1.0, (0.28 + lvl * 0.92) * weights[i] * wave))
            bh = math.max(3, math.floor(h * amp + 0.5))
            local c = (amp > 0.62) and hi or lo
            G.setColor(c[1], c[2], c[3], c[4] or 255)
        else
            bh = 2
            G.setColor(lo[1], lo[2], lo[3], 95)
        end
        local by = y + (h - bh) * 0.5
        G.rectangle("fill", bx, by, bw, bh, 1.2, 1.2)
    end
end

-- Pulsing emerald/gold livestream speaking highlight around a card or portrait frame
function ui.draw_speaking_glow(x, y, w, h, radius, col, level)
    local G = love.graphics
    local t = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
    local pulse = 0.65 + 0.35 * math.sin(t * 9.5)
    local lvl = math.max(0.25, math.min(1.0, tonumber(level) or 0.5))
    local r = radius or 10
    local c = col or { 96, 242, 146, 255 }
    G.setColor(c[1], c[2], c[3], math.floor(78 * pulse * lvl))
    G.setLineWidth(5.5)
    G.rectangle("line", x - 2, y - 2, w + 4, h + 4, r + 2, r + 2)
    G.setColor(c[1], c[2], c[3], math.floor(235 * (0.75 + 0.25 * pulse)))
    G.setLineWidth(2.4)
    G.rectangle("line", x, y, w, h, r, r)
end

return ui

-- KR-MP Built-in Chinese Font Loader (reuses FL 8.2.0 native fonts with zero extra bundle bloat)
-- Supports 4 curated built-in themes:
--   "official" (FL 8.2.0 native JIMOJW display + LXGW 975 Yuan rounded body)
--   "rounded"  (Full LXGW 975 Yuan 700W/400W cartoon rounded family)
--   "xinwei"   (STXINWEI royal calligraphy display + LXGW 975 Yuan body)
--   "harmony"  (HarmonyOS Sans SC Bold/Regular clean modern sans)
local fonts = {
    cache = {},
    cache_count = 0,
    paths = {},
    checked = false,
    theme = "official", -- "official" | "rounded" | "xinwei" | "harmony"
}

fonts.THEMES = {
    { id = "official", label = "官配", disp_scale = 1.14, desc = "FL原版官配（JIMOJW手绘标题 + 霞鹜圆体正文）" },
    { id = "rounded",  label = "圆体", disp_scale = 1.02, desc = "铁皮漫画圆体（全套霞鹜975圆体 粗/细）" },
    { id = "xinwei",   label = "新魏", disp_scale = 1.12, desc = "皇家战书古风（华文新魏标题 + 霞鹜圆体正文）" },
    { id = "harmony",  label = "鸿蒙", disp_scale = 1.00, desc = "经典鸿蒙黑体（简洁现代无衬线）" },
}

local ROLE_CANDIDATES = {
    jimo = {
        "all-desktop/assets/fonts/JIMOJW.ttf",
        "all-desktop/assets/fonts/LXGW975YuanSC-700W.ttf",
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC_Bold.ttf",
    },
    xinwei = {
        "all-desktop/assets/fonts/STXINWEI.TTF",
        "all-desktop/assets/fonts/LXGW975YuanSC-700W.ttf",
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC_Bold.ttf",
    },
    yuan_reg = {
        "all-desktop/assets/fonts/LXGW975YuanSC-400W.ttf",
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC.ttf",
        "all-desktop/assets/fonts/AlibabaPuHuiTi-3-55-Regular.ttf",
    },
    yuan_bold = {
        "all-desktop/assets/fonts/LXGW975YuanSC-700W.ttf",
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC_Bold.ttf",
        "all-desktop/assets/fonts/AlibabaPuHuiTi-3-85-Bold.ttf",
    },
    harmony_reg = {
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC.ttf",
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC_Regular-.ttf",
        "kr3-desktop/assets/fonts/HarmonyOS_Sans_SC_Regular.ttf",
        "all-desktop/assets/fonts/AlibabaPuHuiTi-3-55-Regular.ttf",
        "all-desktop/assets/fonts/msyh.ttf",
        "all-desktop/assets/fonts/DroidSans.ttf",
    },
    harmony_bold = {
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC_Bold.ttf",
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC_Bold-.ttf",
        "all-desktop/assets/fonts/AlibabaPuHuiTi-3-85-Bold.ttf",
        "all-desktop/assets/fonts/msyhbd.ttf",
        "all-desktop/assets/fonts/HarmonyOS_Sans_SC.ttf",
    },
}

local function find_first_file(list)
    if love and love.filesystem and love.filesystem.isFile then
        for i = 1, #list do
            local p = list[i]
            if love.filesystem.isFile(p) then
                return p
            end
        end
    end
    return nil
end

local function ensure_paths()
    if fonts.checked then return end
    fonts.checked = true
    for role, list in pairs(ROLE_CANDIDATES) do
        fonts.paths[role] = find_first_file(list)
    end
end

function fonts.get_theme_info(id)
    id = id or fonts.theme
    for i = 1, #fonts.THEMES do
        if fonts.THEMES[i].id == id then
            return fonts.THEMES[i], i
        end
    end
    return fonts.THEMES[1], 1
end

function fonts.set_theme(id)
    local info = fonts.get_theme_info(id)
    fonts.theme = info.id
    return info
end

function fonts.cycle_theme()
    local _, idx = fonts.get_theme_info(fonts.theme)
    local next_idx = (idx % #fonts.THEMES) + 1
    fonts.theme = fonts.THEMES[next_idx].id
    return fonts.THEMES[next_idx]
end

local function resolve_role(weight)
    local th = fonts.theme or "official"
    if weight == "display" then
        if th == "official" then return "jimo"
        elseif th == "rounded" then return "yuan_bold"
        elseif th == "xinwei" then return "xinwei"
        else return "harmony_bold" end
    elseif weight == "bold" or weight == true then
        if th == "harmony" then return "harmony_bold"
        else return "yuan_bold" end
    elseif weight == "xinwei" then
        return "xinwei"
    else
        if th == "harmony" then return "harmony_reg"
        else return "yuan_reg" end
    end
end

function fonts.get(size, weight)
    local sz = math.max(9, math.min(96, math.floor((tonumber(size) or 14) + 0.5)))
    local role = resolve_role(weight)
    local key = role .. ":" .. tostring(sz)
    if fonts.cache[key] then
        return fonts.cache[key]
    end
    if not love or not love.graphics or not love.graphics.newFont then
        return nil
    end

    if fonts.cache_count >= 128 then
        fonts.cache = {}
        fonts.cache_count = 0
    end

    ensure_paths()
    local path = fonts.paths[role] or fonts.paths.harmony_reg
    local ok, f
    if path then
        ok, f = pcall(love.graphics.newFont, path, sz, "normal")
        if not ok or not f then
            ok, f = pcall(love.graphics.newFont, path, sz)
        end
    end
    if not ok or not f then
        ok, f = pcall(love.graphics.newFont, sz)
    end
    if ok and f then
        pcall(f.setFilter, f, "nearest", "nearest")
        fonts.cache[key] = f
        fonts.cache_count = fonts.cache_count + 1
        return f
    end
    return nil
end

function fonts.get_path()
    ensure_paths()
    local role = resolve_role("display")
    return fonts.paths[role] or fonts.paths.harmony_reg or "(default)"
end

return fonts

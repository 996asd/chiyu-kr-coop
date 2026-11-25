-- KR-MP Built-in Chinese Font Loader (reuses FL 8.2.0's HarmonyOS Sans SC TTF with zero extra bundle bloat)
local fonts = {
    cache = {},
    font_path = nil,
    checked = false,
}

local CANDIDATE_FONTS = {
    "all-desktop/assets/fonts/HarmonyOS_Sans_SC.ttf",
    "all-desktop/assets/fonts/HarmonyOS_Sans_SC_Regular-.ttf",
    "kr3-desktop/assets/fonts/HarmonyOS_Sans_SC_Regular.ttf",
    "all-desktop/assets/fonts/AlibabaPuHuiTi-3-55-Regular.ttf",
    "all-desktop/assets/fonts/NotoSansCJKjp-Regular.otf",
    "all-desktop/assets/fonts/DroidSans.ttf",
}

local function find_font_path()
    if fonts.checked then
        return fonts.font_path
    end
    fonts.checked = true
    if love and love.filesystem and love.filesystem.isFile then
        for i = 1, #CANDIDATE_FONTS do
            local p = CANDIDATE_FONTS[i]
            if love.filesystem.isFile(p) then
                fonts.font_path = p
                break
            end
        end
    end
    return fonts.font_path
end

function fonts.get(size)
    size = size or 14
    if fonts.cache[size] then
        return fonts.cache[size]
    end
    if not love or not love.graphics or not love.graphics.newFont then
        return nil
    end
    local path = find_font_path()
    local ok, f
    if path then
        ok, f = pcall(love.graphics.newFont, path, size)
    end
    if not ok or not f then
        ok, f = pcall(love.graphics.newFont, size)
    end
    if ok and f then
        fonts.cache[size] = f
        return f
    end
    return nil
end

function fonts.get_path()
    return find_font_path() or "(default)"
end

return fonts

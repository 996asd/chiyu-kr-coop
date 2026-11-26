-- Zero-patch crash-proof auto-loader for Kingdom Rush FL 8.2.0 (loaded by mod.lua -> director:init)
-- Supports Android / PC SaveDirectory OTA hot-updates with automatic rollback to built-in game.love on error.
local UH = {}

local function purge_kr_mp_loaded()
    for k in pairs(package.loaded) do
        if type(k) == "string" and (k == "kr_mp" or k:sub(1, 6) == "kr_mp.") then
            package.loaded[k] = nil
        end
    end
end

local function remove_ota_overrides()
    if not (love and love.filesystem) then return false end
    local FS = love.filesystem
    local has_marker = (FS.getInfo and FS.getInfo("kr_mp_ota_active.txt")) or (FS.isFile and FS.isFile("kr_mp_ota_active.txt"))
    if not has_marker then return false end

    local function rm_dir_files(dir)
        local ok, items = pcall(FS.getDirectoryItems, dir)
        if not ok or type(items) ~= "table" then return end
        for _, name in ipairs(items) do
            local p = (dir == "") and name or (dir .. "/" .. name)
            pcall(FS.remove, p)
        end
    end
    rm_dir_files("kr_mp/assets")
    rm_dir_files("kr_mp")
    pcall(FS.remove, "kr_mp/assets")
    pcall(FS.remove, "kr_mp")
    pcall(FS.remove, "kr_mp_ota_active.txt")
    return true
end

local function try_boot(tag)
    local ok_req, boot = pcall(require, "kr_mp.boot")
    if not ok_req or not boot then
        return false, "require(kr_mp.boot): " .. tostring(boot)
    end
    local ok_init, err = pcall(boot.init, boot, tag)
    if not ok_init then
        return false, "boot:init: " .. tostring(err)
    end
    return true, nil
end

function UH:init()
    local ok, err = try_boot("UH")
    if ok then return end

    print("[KR-MP] Boot error: " .. tostring(err))
    -- If an OTA hot-update broke boot, automatically wipe SaveDir overrides and fall back to built-in!
    if remove_ota_overrides() then
        print("[KR-MP] Rolled back SaveDir OTA overrides; retrying built-in version...")
        purge_kr_mp_loaded()
        local ok2, err2 = try_boot("UH_ROLLBACK")
        if not ok2 then
            print("[KR-MP] Fallback boot also failed: " .. tostring(err2))
        end
    end
end

return UH

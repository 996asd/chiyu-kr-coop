-- Zero-patch auto-loader for Kingdom Rush FL 8.2.0 (loaded automatically by mod.lua -> director:init)
local UH = {}

function UH:init()
    local ok, boot = pcall(require, "kr_mp.boot")
    if not ok then
        print("[KR-MP] Failed to load kr_mp.boot: " .. tostring(boot))
        return
    end
    boot:init("UH")
end

return UH

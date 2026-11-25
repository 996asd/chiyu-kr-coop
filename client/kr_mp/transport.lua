-- KR-MP Unified Transport Facade (M1: LAN TCP+UDP; M2: Go Online Relay Server)
local net_lan = require("kr_mp.net_lan")
local net_online = require("kr_mp.net_online")

local transport = {
    mode = "lan", -- "lan" | "online"
    lan_backend = nil,
    online_backend = nil,
    backend = nil,
    boot = nil,
}

function transport:init(boot)
    self.boot = boot
    self.lan_backend = net_lan.new(boot)
    self.online_backend = net_online.new(boot)
    self.backend = self.lan_backend
    self.mode = "lan"
end

function transport:is_online()
    return self.mode == "online"
end

function transport:get_mode()
    return self.mode
end

function transport:switch_mode(new_mode)
    if self.mode == new_mode then return end
    if self.backend then
        self.backend:close()
    end
    self.mode = new_mode
    if new_mode == "online" then
        self.backend = self.online_backend
    else
        self.backend = self.lan_backend
    end
end

-- === LAN Mode Methods ===

function transport:host_lan(port, advert)
    self:switch_mode("lan")
    return self.lan_backend:start_host(port, advert)
end

function transport:update_advert(advert)
    if self.mode == "lan" and self.lan_backend and self.lan_backend.update_advert then
        self.lan_backend:update_advert(advert)
    end
end

function transport:start_lan_scan()
    if not self.lan_backend then self.lan_backend = net_lan.new(self.boot) end
    return self.lan_backend:start_scan()
end

function transport:stop_lan_scan()
    if self.lan_backend and self.lan_backend.stop_scan then
        self.lan_backend:stop_scan()
    end
end

function transport:get_lan_rooms()
    if self.lan_backend and self.lan_backend.get_discovered_rooms then
        return self.lan_backend:get_discovered_rooms()
    end
    return {}
end

function transport:join_lan(ip, port)
    self:switch_mode("lan")
    return self.lan_backend:connect(ip, port)
end

-- === Online Relay Mode Methods (M2) ===

function transport:connect_online(host, port)
    self:switch_mode("online")
    return self.online_backend:connect(host, port)
end

function transport:get_server_addr()
    if self.mode == "online" and self.online_backend then
        return self.online_backend:get_server_addr()
    end
    return nil
end

-- === Unified Send / Poll / State ===

function transport:send(msg)
    if self.backend then
        return self.backend:send(msg)
    end
    return false
end

function transport:poll()
    if self.backend then
        return self.backend:poll()
    end
    return {}
end

function transport:close()
    if self.lan_backend then
        self.lan_backend:close()
    end
    if self.online_backend then
        self.online_backend:close()
    end
end

function transport:is_connected()
    return self.backend ~= nil and self.backend.state == "connected"
end

function transport:get_role()
    return self.backend and self.backend.role or "none"
end

function transport:get_state()
    return self.backend and self.backend.state or "idle"
end

function transport:get_rtt_ms()
    return self.backend and self.backend.rtt_ms or 0
end

function transport:get_port()
    return self.backend and self.backend.port or 17777
end

function transport:get_last_error()
    return self.backend and self.backend.last_error or nil
end

return transport

-- VersaMerchantSniper - clock adapter (outbound).
-- The one time source the rest of the addon runs on; domain code and specs
-- stay deterministic by injecting this. Implements ClockPort.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.outbound = VMS.adapters.outbound or {}

---@class Clock : ClockPort
local M = {}

--- Wall-clock seconds (persisted stat stamps: lastSeen).
---@return number
function M.now()
    if time == nil then
        return 0
    end
    return time() or 0
end

--- Session seconds (diagnostics only, never persisted).
---@return number
function M.uptime()
    if GetTime == nil then
        return 0
    end
    return GetTime() or 0
end

--- "HH:MM:SS" wall-clock label for chat lines.
---@return string
function M.stamp()
    if date == nil then
        return "--:--:--"
    end
    return date("%H:%M:%S") or "--:--:--"
end

VMS.adapters.outbound.Clock = M
return M

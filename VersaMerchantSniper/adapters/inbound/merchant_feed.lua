-- VersaMerchantSniper - merchant event feed adapter (inbound).
-- Owns the event frame; translates MERCHANT_* events into MerchantFeedPort
-- calls with plain data (vendor name and zone are captured HERE - game
-- reads stay in adapters). Registration fails fast by design: RegisterEvent
-- errors on an unknown event, which is the wanted startup behavior for a
-- REQUIRED-tier event. The frame is created immediately; the events only
-- fire on merchant interaction, so pre-PLAYER_LOGIN construction is safe.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.inbound = VMS.adapters.inbound or {}

---@class MerchantFeed
---@field sink MerchantFeedPort
---@field frame any|nil the event frame (widget handles are typed any by house style)
local M = {}

--- Builds the feed over an injected sink (the sniping core).
---@param sink MerchantFeedPort
---@return MerchantFeed
function M.new(sink)
    ---@type MerchantFeed
    local self = setmetatable({}, { __index = M })
    self.sink = sink
    self.frame = CreateFrame("Frame", "VersaMerchantSniperFeedFrame")
    self.frame:SetScript("OnEvent", function(_, event, ...)
        self:onEvent(event, ...)
    end)
    self.frame:RegisterEvent("MERCHANT_SHOW")
    self.frame:RegisterEvent("MERCHANT_CLOSED")
    self.frame:RegisterEvent("MERCHANT_UPDATE")
    return self
end

--- One event frame tick: route to the sink with captured context.
--- Purchases belong to the caller's context: live Midnight refuses
--- BuyMerchantItem from this dispatch - VMS.Buyout() is the click path.
---@param event string
---@return nil
function M:onEvent(event, ...)
    if event == "MERCHANT_SHOW" then
        self.sink:onMerchantShow(self:vendorName(), self:zone())
    elseif event == "MERCHANT_CLOSED" then
        self.sink:onMerchantClosed()
    elseif event == "MERCHANT_UPDATE" then
        self.sink:onMerchantUpdate()
    end
end

--- The vendor behind the open merchant session ("npc" unit); nil when the
--- API or the name is unavailable.
---@return string|nil
function M:vendorName()
    if UnitName == nil then
        return nil
    end
    local ok, name = pcall(UnitName, "npc")
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

--- "Zone: Subzone" composite for visit rows; nil when nothing resolves.
---@return string|nil
function M:zone()
    local zoneText, subZoneText
    if GetZoneText ~= nil then
        local ok, value = pcall(GetZoneText)
        if ok and type(value) == "string" and value ~= "" then
            zoneText = value
        end
    end
    if GetSubZoneText ~= nil then
        local ok, value = pcall(GetSubZoneText)
        if ok and type(value) == "string" and value ~= "" and value ~= zoneText then
            subZoneText = value
        end
    end
    if zoneText == nil and subZoneText == nil then
        return nil
    end
    if zoneText ~= nil and subZoneText ~= nil then
        return zoneText .. ": " .. subZoneText
    end
    return zoneText or subZoneText
end

VMS.adapters.inbound.MerchantFeed = M
return M

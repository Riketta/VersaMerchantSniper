-- VersaMerchantSniper - chat alert adapter (outbound).
-- AlertPort: prefixed chat lines (the legacy script's "[VMS]" prefix).
-- Result lines always print; verbose lines honor settings.verbose, read
-- live from the db on every call so a settings flip applies without a
-- reload.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.outbound = VMS.adapters.outbound or {}

local PREFIX = "[VMS]"

---@class AlertChat : AlertPort
---@field db DB|nil injected by new
local M = {}

--- Builds the alert adapter over an attached db adapter.
---@param db DB
---@return AlertChat
function M.new(db)
    ---@type AlertChat
    local self = setmetatable({}, { __index = M })
    self.db = db
    return self
end

---@param text string
---@return nil
function M:say(text)
    print(PREFIX, text)
end

---@param text string
---@return nil
function M:verbose(text)
    local shape = self.db.get()
    if shape ~= nil and shape.settings.verbose then
        self:say(text)
    end
end

VMS.adapters.outbound.AlertChat = M
return M

-- VersaMerchantSniper - activity log adapter (outbound).
-- LogStorePort over the db engine: owns the visit ring (newest-first) and
-- honors settings.logSize on every append. Lifetime per-entry aggregates
-- live on the entries themselves (domain/snipe_log mutates them); this
-- adapter only keeps rows.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.outbound = VMS.adapters.outbound or {}

local SnipeLog = VMS.domain and VMS.domain.SnipeLog

---@class ActivityLog : LogStorePort
---@field db DB|nil injected by new
local M = {}

--- Builds the store over an attached db adapter.
---@param db DB
---@return ActivityLog
function M.new(db)
    ---@type ActivityLog
    local self = setmetatable({}, { __index = M })
    self.db = db
    return self
end

--- Appends one row at the ring head and prunes past settings.logSize.
---@param record VisitRecord
---@return nil
function M:appendVisit(record)
    local shape = self.db.get()
    if shape == nil then
        return
    end
    SnipeLog.append(shape.log, record, shape.settings.logSize)
end

--- The live ring (newest first).
---@return VisitRecord[]
function M:ring()
    local shape = self.db.get()
    if shape == nil then
        return {}
    end
    return shape.log
end

--- Drops every row (Settings tab / /vms clearlog).
---@return nil
function M:clear()
    local shape = self.db.get()
    if shape == nil then
        return
    end
    for i = #shape.log, 1, -1 do
        shape.log[i] = nil
    end
end

VMS.adapters.outbound.ActivityLog = M
return M

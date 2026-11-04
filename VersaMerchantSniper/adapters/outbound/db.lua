-- VersaMerchantSniper - SavedVariables adapter (outbound).
-- Storage engine behind the LogStorePort and the settings surface. The
-- composition root attaches the real VersaMerchantSniperDB global at
-- ADDON_LOADED (SavedVariables are only real then; attaching earlier would
-- orphan every write). Validation drops corrupt records and counts them;
-- flush timing is the game's (logout/reload).

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.outbound = VMS.adapters.outbound or {}

local Types = VMS.domain and VMS.domain.Types

---@class DB
---@field shape DBShape|nil attached+validated blob
---@field droppedEntries number corrupt entries dropped at the last attach
---@field droppedLog number corrupt rows dropped at the last attach
local M = {}

--- Attaches (and validates/defaults) the persisted blob. Call once at
--- ADDON_LOADED; re-attaching re-validates in place.
---@param raw any the VersaMerchantSniperDB global (nil on first run)
---@return DBShape
---@return number droppedEntries
---@return number droppedLog
function M.attach(raw)
    local db, droppedEntries, droppedLog = Types.validateDB(raw)
    M.shape = db
    M.droppedEntries = droppedEntries
    M.droppedLog = droppedLog
    return db, droppedEntries, droppedLog
end

--- The attached shape (nil before attach; bootstrap attaches before any
--- consumer can run).
---@return DBShape|nil
function M.get()
    return M.shape
end

--- Stores a settings table (already sanitized by the caller) into the
--- shape. The game flushes on logout/reload.
---@param settings VMSSettings
---@return nil
function M.setSettings(settings)
    if M.shape ~= nil then
        M.shape.settings = settings
    end
end

VMS.adapters.outbound.DB = M
return M

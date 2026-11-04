-- VersaMerchantSniper - domain types and boundary validators.
-- Pure Lua: must not reference any game API (lint-enforced via .luacheckrc).
-- Validators keep `any` params by design (untrusted boundary input: UI text,
-- slash args and the SavedVariables blob).

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.domain = VMS.domain or {}

---@class EntryStats lifetime per-entry tracking statistics
---@field lastSeen number|nil time() of the most recent sighting (any visit)
---@field lastSeenVendor string|nil vendor name at the last sighting
---@field lastSeenZone string|nil zone at the last sighting
---@field lastSeenCount number|nil merchant stock at the last sighting
---@field visitsSeen number visits where the entry matched a merchant slot
---@field visitsMissed number visits where the entry matched nothing
---@field boughtTotal number lifetime bought units
---@field spentTotal number lifetime spend, copper

---@class TrackedEntry
---@field key string stable identity, "id:<n>" or "name:<s>"
---@field itemID number|nil primary match key (nil = name-only entry)
---@field name string|nil display name and fallback match key
---@field quantity number remaining units to buy
---@field quantityInitial number units requested at creation (raised on merge)
---@field stopOnSuccess boolean stop tracking at zero remaining
---@field enabled boolean excluded from matching while false
---@field priceCeiling number|nil max unit price, copper (nil = no ceiling)
---@field status string "active" | "done"
---@field stats EntryStats

--- One merchant stock row as the merchant_api adapter produces it (the
--- adapter is the boundary: it defaults every field it cannot read).
---@class MerchantSlot
---@field index number 1-based merchant slot index, global across pages
---@field itemID number|nil GetMerchantItemID result
---@field name string|nil GetMerchantItemInfo result (nil on some rows)
---@field price number unit price, copper (0 for alt-currency rows)
---@field stackCount number units per sold stack (display)
---@field numAvailable number stock, -1 = unlimited
---@field maxStack number GetMerchantItemMaxStack result
---@field hasExtendedCost boolean alt-currency/item-cost purchase
---@field isPurchasable boolean Blizzard's buy gate (reputation etc.)

---@class VisitRecord one ring-buffer row
---@field t number time() stamp
---@field kind string "arm"|"disarm"|"visit"|"buy"|"blocked"|"notfound"|"closed"
---@field vendor string|nil vendor name (UnitName("npc"))
---@field zone string|nil GetZoneText / GetSubZoneText composite
---@field itemKey string|nil TrackedEntry key the row refers to
---@field quantity number|nil bought or blocked units
---@field price number|nil unit price at the visit, copper
---@field spent number|nil total spend of the row, copper
---@field note string|nil verdict reason fragment

---@class VMSSettings
---@field verbose boolean verbose scan chatter in chat
---@field defaultQuantity number quantity default for new entries
---@field defaultStopOnSuccess boolean stop-on-success default for new entries
---@field logSize number visit ring buffer size

---@class DBShape the persisted VersaMerchantSniperDB layout
---@field version number schema version
---@field settings VMSSettings
---@field list TrackedEntry[]
---@field log VisitRecord[]

--- The visit-record kinds Types.isVisitRecord accepts.
---@type table<string, boolean>
local VISIT_KINDS = {
    arm = true,
    disarm = true,
    visit = true,
    buy = true,
    blocked = true,
    notfound = true,
    closed = true,
}

---@class Types
local M = {}

--- Public: isVisitRecord accepts exactly these row kinds.
M.VISIT_KINDS = VISIT_KINDS

--- Fresh zeroed lifetime stats.
---@return EntryStats
function M.makeEntryStats()
    return {
        lastSeen = nil,
        lastSeenVendor = nil,
        lastSeenZone = nil,
        lastSeenCount = nil,
        visitsSeen = 0,
        visitsMissed = 0,
        boughtTotal = 0,
        spentTotal = 0,
    }
end

--- Defaults applied wherever a setting is missing or corrupt.
---@return VMSSettings
function M.defaultSettings()
    return {
        verbose = false,
        defaultQuantity = 1,
        defaultStopOnSuccess = true,
        logSize = 300,
    }
end

--- Sanitizes a persisted or incoming settings blob: every field missing,
--- wrong-typed or out of range falls back to the documented default. Never
--- returns nil; callers can hand it any SavedVariables remnant.
---@param raw any untrusted settings blob (or nil)
---@return VMSSettings
function M.sanitizeSettings(raw)
    local src = type(raw) == "table" and raw or {}
    local out = M.defaultSettings()
    if type(src.verbose) == "boolean" then
        out.verbose = src.verbose
    end
    if type(src.defaultStopOnSuccess) == "boolean" then
        out.defaultStopOnSuccess = src.defaultStopOnSuccess
    end
    local quantity = tonumber(src.defaultQuantity)
    if quantity and quantity >= 1 then
        out.defaultQuantity = math.floor(quantity)
    end
    local size = tonumber(src.logSize)
    if size then
        out.logSize = math.floor(math.min(math.max(size, 10), 2000))
    end
    return out
end

--- Validates untrusted entry input and builds a fresh TrackedEntry. Identity
--- is an itemID (> 0, < 2^31) or a non-blank name; a ceiling of 0 is stored
--- as nil (no ceiling). Quantity accepts numeric strings (UI/slash leniency).
---@param raw any untrusted entry fields
---@param defaults VMSSettings|nil quantity/stop defaults when the input omits them
---@return TrackedEntry|nil
---@return string|nil reason when validation fails
function M.validateEntry(raw, defaults)
    if type(raw) ~= "table" then
        return nil, "not-a-table"
    end
    local d = defaults or M.defaultSettings()

    local itemID = tonumber(raw.itemID)
    if itemID ~= nil then
        if itemID < 1 or itemID >= 2 ^ 31 or itemID ~= math.floor(itemID) then
            return nil, "bad-itemID"
        end
        itemID = math.floor(itemID)
    end

    local name = raw.name
    if type(name) ~= "string" or (name:gsub("^%s+", ""):gsub("%s+$", "")) == "" then
        name = nil
    end
    if not itemID and not name then
        return nil, "no-identity"
    end

    local requested = tonumber(raw.quantity)
    local quantity = math.floor(requested or d.defaultQuantity)
    if quantity < 1 or (requested ~= nil and requested ~= quantity) then
        return nil, "bad-quantity"
    end

    local ceiling = tonumber(raw.priceCeiling)
    if ceiling ~= nil then
        if ceiling < 0 or ceiling ~= math.floor(ceiling) then
            return nil, "bad-ceiling"
        end
        ceiling = math.floor(ceiling)
        if ceiling == 0 then
            ceiling = nil
        end
    end

    local stop = raw.stopOnSuccess
    if stop == nil then
        stop = d.defaultStopOnSuccess
    end

    ---@type TrackedEntry
    local entry = {
        key = itemID and ("id:" .. itemID) or ("name:" .. name),
        itemID = itemID,
        name = name,
        quantity = quantity,
        quantityInitial = quantity,
        stopOnSuccess = stop == true,
        enabled = true,
        priceCeiling = ceiling,
        status = "active",
        stats = M.makeEntryStats(),
    }
    return entry
end

--- Raises an existing entry's quantity by the incoming request and
--- re-activates done/disabled entries (duplicate add merge per PLAN).
--- Configuration stays on the existing entry; only quantities move.
---@param existing TrackedEntry
---@param added TrackedEntry the validated incoming entry (consumed, not stored)
---@return nil
function M.mergeQuantity(existing, added)
    existing.quantity = existing.quantity + added.quantity
    existing.quantityInitial = existing.quantityInitial + added.quantity
    if existing.status ~= "active" or not existing.enabled then
        existing.status = "active"
        existing.enabled = true
    end
end

--- Shape check for entries read back from SavedVariables: identity, core
--- numerics and a complete stats table must be intact; corrupt entries are
--- dropped by validateDB, never repaired.
---@param v any
---@return boolean
function M.isEntry(v)
    if type(v) ~= "table" or type(v.key) ~= "string" then
        return false
    end
    local hasID = type(v.itemID) == "number" and v.itemID >= 1
    local hasName = type(v.name) == "string" and v.name ~= ""
    if not hasID and not hasName then
        return false
    end
    if type(v.quantity) ~= "number" or v.quantity < 0 then
        return false
    end
    if type(v.quantityInitial) ~= "number" or v.quantityInitial < 0 then
        return false
    end
    if type(v.stopOnSuccess) ~= "boolean" or type(v.enabled) ~= "boolean" then
        return false
    end
    if v.priceCeiling ~= nil and type(v.priceCeiling) ~= "number" then
        return false
    end
    if v.status ~= "active" and v.status ~= "done" then
        return false
    end
    local s = v.stats
    if type(s) ~= "table" then
        return false
    end
    if type(s.visitsSeen) ~= "number" or type(s.visitsMissed) ~= "number" then
        return false
    end
    if type(s.boughtTotal) ~= "number" or type(s.spentTotal) ~= "number" then
        return false
    end
    return true
end

--- Shape check for persisted visit rows.
---@param v any
---@return boolean
function M.isVisitRecord(v)
    if type(v) ~= "table" or type(v.t) ~= "number" then
        return false
    end
    if not M.VISIT_KINDS[v.kind] then
        return false
    end
    if v.vendor ~= nil and type(v.vendor) ~= "string" then
        return false
    end
    if v.zone ~= nil and type(v.zone) ~= "string" then
        return false
    end
    if v.itemKey ~= nil and type(v.itemKey) ~= "string" then
        return false
    end
    if v.quantity ~= nil and type(v.quantity) ~= "number" then
        return false
    end
    if v.price ~= nil and type(v.price) ~= "number" then
        return false
    end
    if v.spent ~= nil and type(v.spent) ~= "number" then
        return false
    end
    if v.note ~= nil and type(v.note) ~= "string" then
        return false
    end
    return true
end

--- Validates a raw SavedVariables blob into a DBShape: settings are
--- sanitized, list/log entries are shape-checked and corrupt records are
--- dropped (counted, never repaired).
---@param raw any untrusted SavedVariables blob (or nil)
---@return DBShape db
---@return number droppedEntries
---@return number droppedLog
function M.validateDB(raw)
    local src = type(raw) == "table" and raw or {}
    ---@type DBShape
    local db = {
        version = 1,
        settings = M.sanitizeSettings(src.settings),
        list = {},
        log = {},
    }
    local droppedEntries, droppedLog = 0, 0
    if type(src.list) == "table" then
        for _, entry in ipairs(src.list) do
            if M.isEntry(entry) then
                db.list[#db.list + 1] = entry
            else
                droppedEntries = droppedEntries + 1
            end
        end
    end
    if type(src.log) == "table" then
        for _, record in ipairs(src.log) do
            if M.isVisitRecord(record) then
                db.log[#db.log + 1] = record
            else
                droppedLog = droppedLog + 1
            end
        end
    end
    return db, droppedEntries, droppedLog
end

VMS.domain.Types = M
return M

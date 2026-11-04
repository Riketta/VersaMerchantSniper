-- VersaMerchantSniper - sniping core (domain).
-- Orchestration only: the visit flow (snapshot -> resolve -> narrate),
-- clicker bookkeeping, the slot plan the clicker macro executes, settings
-- and the list management surface. All game I/O flows through injected
-- ports; no game globals beyond the namespace registration (lint-enforced).
-- POLICY: the addon NEVER calls BuyMerchantItem or CloseMerchant - live
-- Midnight refuses purchase calls whose stack passes through addon frames.
-- Buying belongs to the clicker macro (VMS.ClickerMacro), which executes
-- the plan this module computes (buyableSlots) and hands the bought counts
-- back for bookkeeping (recordBuys). The addon never closes the vendor
-- window either - the macro always does, since vendor stock only refreshes
-- on open.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.domain = VMS.domain or {}

local Purchase = VMS.domain.Purchase
local SnipeLog = VMS.domain.SnipeLog
local Types = VMS.domain.Types

---@class SnipingCore : ControlPort, MerchantFeedPort
---@field query MerchantQueryPort
---@field store LogStorePort
---@field alerts AlertPort
---@field clock ClockPort
---@field db DB storage engine (settings + list + log shape)
local Core = {}

--- Builds the core over injected ports.
---@param deps {query: MerchantQueryPort, store: LogStorePort, alerts: AlertPort, clock: ClockPort, db: DB}
---@return SnipingCore
function Core.new(deps)
    ---@type SnipingCore
    local self = setmetatable({}, { __index = Core })
    self.query = deps.query
    self.store = deps.store
    self.alerts = deps.alerts
    self.clock = deps.clock
    self.db = deps.db
    return self
end

---@return TrackedEntry[]
function Core:entries()
    local shape = self.db.get()
    if shape == nil then
        return {} -- defensive: only reachable before the bootstrap attach
    end
    return shape.list
end

--- Active entries: enabled, not done, still wanted.
---@return TrackedEntry[]
function Core:activeEntries()
    local active = {}
    for _, entry in ipairs(self:entries()) do
        if entry.enabled and entry.status == "active" and entry.quantity > 0 then
            active[#active + 1] = entry
        end
    end
    return active
end

---@return VMSSettings
function Core:settings()
    local shape = self.db.get()
    if shape == nil then
        return Types.defaultSettings() -- defensive: only reachable before the bootstrap attach
    end
    return shape.settings
end

--- Chat label for an entry: the slot's item link when available, else the
--- known name, else the bare ID.
---@param entry TrackedEntry
---@param slot MerchantSlot|nil
---@return string
function Core:displayName(entry, slot)
    if slot ~= nil then
        local link = self.query:linkFor(slot.index)
        if link ~= nil then
            return link
        end
    end
    if entry.name ~= nil then
        return entry.name
    end
    return "id:" .. tostring(entry.itemID)
end

--- MERCHANT_SHOW: the visit tick - observation only. Sightings, misses and
--- a visit row; no purchases, no closing (the clicker macro owns both).
---@param vendor string|nil
---@param zone string|nil
---@return nil
function Core:onMerchantShow(vendor, zone)
    self:runVisit(vendor, zone)
end

--- One visit: snapshot -> resolve -> narrate. Purchases happen ONLY through
--- the clicker macro (live Midnight refuses BuyMerchantItem from any stack
--- passing through addon frames), so this tick never touches the purchase
--- surface - it records sightings, misses and the visit row.
---@param vendor string|nil
---@param zone string|nil
---@return nil
function Core:runVisit(vendor, zone)
    local now = self.clock.now()
    local slots = self.query:snapshot()
    local active = self:activeEntries()
    local matches = Purchase.resolveMatches(slots, active)
    local matched = {}
    for _, match in ipairs(matches) do
        matched[match.entry.key] = true
        -- Every match is a sighting ("last seen").
        SnipeLog.noteSighting(match.entry, match.slot.numAvailable, now, vendor, zone)
    end
    local missed = 0
    for _, entry in ipairs(active) do
        if not matched[entry.key] then
            SnipeLog.noteMiss(entry)
            missed = missed + 1
        end
    end
    self.store:appendVisit(SnipeLog.makeVisit("visit", now, {
        vendor = vendor,
        zone = zone,
        note = ("%d matched, %d missed"):format(#matches, missed),
    }))
end

--- The clicker macro's plan: slots whose tracked match resolves to an
--- "order" verdict (stock, no extended cost, purchasable, within ceiling,
--- affordable), itemID-backed entries only - RecordBuys books by ID. Pure
--- data: the macro's BuyMerchantItem calls carry no addon frames, which is
--- the only shape live Midnight accepts.
---@return {index: number, itemID: number}[]
function Core:buyableSlots()
    local money = self.query:money()
    local result = {}
    for _, match in ipairs(Purchase.resolveMatches(self.query:snapshot(), self:activeEntries())) do
        local order = Purchase.decide(match.entry, match.slot, money)
        if order.verdict == "order" and match.entry.itemID ~= nil then
            result[#result + 1] = { index = match.slot.index, itemID = match.entry.itemID }
        end
    end
    return result
end

--- Clicker bookkeeping: the macro buys with pure Blizzard calls, then hands
--- the bought counts here. Entries decrement exactly like a purchase would
--- (no engine calls involved); stop-on-success completion, narration and
--- log rows match too. There is no armed gating.
---@param bought table<number, number>|nil itemID -> units bought this press
---@return nil
function Core:recordBuys(bought)
    if type(bought) ~= "table" or next(bought) == nil then
        return
    end
    local now = self.clock.now()
    for _, entry in ipairs(self:entries()) do
        local count = entry.itemID ~= nil and bought[entry.itemID] or nil
        if count ~= nil and count > 0 and entry.quantity > 0 and entry.status == "active" and entry.enabled then
            local n = math.min(count, entry.quantity)
            entry.quantity = entry.quantity - n
            local done = false
            if entry.quantity == 0 and entry.stopOnSuccess then
                entry.status = "done"
                entry.enabled = false
                done = true
            end
            SnipeLog.notePurchase(entry, n, 0)
            self.store:appendVisit(SnipeLog.makeVisit("buy", now, {
                itemKey = entry.key,
                quantity = n,
                note = "clicker",
            }))
            local line = ("Sniped %s x%d (clicker buyout)"):format(self:displayName(entry, nil), n)
            if done then
                line = line .. " - entry complete"
            end
            self.alerts:say(line)
        end
    end
end

--- MERCHANT_CLOSED: telemetry only (the macro's CloseMerchant fires it).
---@return nil
function Core:onMerchantClosed()
    self.alerts:verbose("Vendor closed.")
end

--- MERCHANT_UPDATE: telemetry only - never a purchase trigger (the addon
--- does not purchase; the clicker macro does).
---@return nil
function Core:onMerchantUpdate()
    self.alerts:verbose("Merchant stock update.")
end

--- Validates untrusted entry input and adds (or merges) a tracked entry.
---@param raw any
---@return TrackedEntry|nil
---@return string|nil reason
function Core:addEntry(raw)
    local entry, reason = Types.validateEntry(raw, self:settings())
    if entry == nil then
        return nil, reason
    end
    for _, existing in ipairs(self:entries()) do
        if existing.key == entry.key then
            Types.mergeQuantity(existing, entry)
            self.alerts:say(("Tracking %s - now x%d."):format(self:displayName(existing, nil), existing.quantity))
            return existing
        end
    end
    local list = self:entries()
    list[#list + 1] = entry
    self.alerts:say(("Tracking %s x%d."):format(self:displayName(entry, nil), entry.quantity))
    return entry
end

--- Replaces one tracked entry in place (list-tab edit flow, the AuctiMogger
--- alt-click pattern). The raw input must validate AND resolve to the edited
--- key - a rejected or mismatched edit never touches the stored entry (the
--- GUI falls back to a plain add on a swapped identity). Updating restarts
--- the want cycle: quantity resets to the request, the entry re-arms, and
--- the bought/spent counters zero; sightings and visit counters survive.
---@param key string the tracked entry key being edited
---@param raw any untrusted entry fields
---@return TrackedEntry|nil
---@return string|nil reason
function Core:updateEntry(key, raw)
    local entry, reason = Types.validateEntry(raw, self:settings())
    if entry == nil then
        return nil, reason
    end
    if entry.key ~= key then
        return nil, "key-mismatch"
    end
    for _, existing in ipairs(self:entries()) do
        if existing.key == key then
            Types.applyUpdate(existing, entry)
            self.alerts:say(("Updated %s - want x%d."):format(self:displayName(existing, nil), existing.quantity))
            return existing
        end
    end
    return nil, "not-tracked"
end

--- Removes an entry by 1-based list index (number), key or exact name.
---@param ref any
---@return boolean
function Core:removeEntry(ref)
    local list = self:entries()
    local index
    if type(ref) == "number" then
        index = math.floor(ref)
    else
        for i, entry in ipairs(list) do
            if entry.key == ref or entry.name == ref then
                index = i
                break
            end
        end
    end
    if index == nil or index < 1 or index > #list then
        return false
    end
    local removed = table.remove(list, index)
    self.alerts:say("Stopped tracking " .. self:displayName(removed, nil) .. ".")
    return true
end

--- Validates and applies one settings change; logSize changes prune the
--- ring immediately.
---@param field string
---@param value any
---@return boolean
---@return string|nil reason
function Core:setSetting(field, value)
    local settings = self:settings()
    if field == "verbose" or field == "defaultStopOnSuccess" then
        if type(value) ~= "boolean" then
            return false, "expected boolean"
        end
        settings[field] = value
    elseif field == "defaultQuantity" then
        local n = tonumber(value)
        if n == nil or n < 1 or n ~= math.floor(n) then
            return false, "expected whole number >= 1"
        end
        settings[field] = math.floor(n)
    elseif field == "logSize" then
        local n = tonumber(value)
        if n == nil or n < 10 then
            return false, "expected number >= 10"
        end
        settings[field] = math.min(math.floor(n), 2000)
        SnipeLog.prune(self.store:ring(), settings[field])
    else
        return false, "unknown setting"
    end
    return true
end

---@return boolean
function Core:toggleVerbose()
    local settings = self:settings()
    settings.verbose = not settings.verbose
    return settings.verbose
end

--- The visit ring, newest first.
---@return VisitRecord[]
function Core:ring()
    return self.store:ring()
end

---@return nil
function Core:clearLog()
    self.store:clear()
    self.alerts:say("Log cleared.")
end

---@return string
function Core:statusLine()
    local total = #self:entries()
    local active = #self:activeEntries()
    return ("Tracking %d items - %d active, %d done."):format(total, active, total - active)
end

VMS.domain.Core = Core
return Core

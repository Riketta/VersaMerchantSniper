-- VersaMerchantSniper - domain snipe log.
-- Pure Lua: must not reference any game API (lint-enforced via .luacheckrc).
-- Lifetime per-entry aggregates (last seen, time to find, totals) plus the
-- newest-first visit ring buffer. Rows are plain VisitRecord tables; the
-- activity_log adapter owns persistence and the row kinds are defined in
-- Types.VISIT_KINDS.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.domain = VMS.domain or {}

---@class SnipeLog
local M = {}

--- Newest-first ring append: the newest row lands at index 1 and the oldest
--- rows fall off past max.
---@param ring VisitRecord[]
---@param record VisitRecord
---@param max number
---@return nil
function M.append(ring, record, max)
    table.insert(ring, 1, record)
    while #ring > max do
        table.remove(ring)
    end
end

--- Shrinks the ring past max without appending (e.g. after a settings change).
---@param ring VisitRecord[]
---@param max number
---@return nil
function M.prune(ring, max)
    while #ring > max do
        table.remove(ring)
    end
end

--- Builds a VisitRecord row. `fields` accepts vendor, zone, itemKey,
--- quantity, price, spent, note (all optional).
---@param kind string one of Types.VISIT_KINDS
---@param now number time() stamp
---@param fields table|nil optional row fields
---@return VisitRecord
function M.makeVisit(kind, now, fields)
    local f = fields or {}
    return {
        t = now,
        kind = kind,
        vendor = f.vendor,
        zone = f.zone,
        itemKey = f.itemKey,
        quantity = f.quantity,
        price = f.price,
        spent = f.spent,
        note = f.note,
    }
end

--- Records a sighting (the entry matched a merchant slot at this visit).
---@param entry TrackedEntry
---@param count number|nil merchant stock observed (nil when unknown)
---@param now number
---@param vendor string|nil
---@param zone string|nil
---@return nil
function M.noteSighting(entry, count, now, vendor, zone)
    local s = entry.stats
    s.lastSeen = now
    s.lastSeenVendor = vendor
    s.lastSeenZone = zone
    s.lastSeenCount = count
    s.visitsSeen = s.visitsSeen + 1
end

--- Records a clean miss: a visit where the entry matched nothing.
--- The last-seen block is intentionally left alone.
---@param entry TrackedEntry
---@return nil
function M.noteMiss(entry)
    entry.stats.visitsMissed = entry.stats.visitsMissed + 1
end

--- Human "time seen ago" label for a sighting stamp, at sighting-scale
--- granularity (just now / minutes / hours / days). Nil or future stamps
--- yield nil - callers render a dash.
---@param lastSeen number|nil time() of the sighting
---@param now number time()
---@return string|nil
function M.agoLabel(lastSeen, now)
    if lastSeen == nil or now == nil or now < lastSeen then
        return nil
    end
    local delta = now - lastSeen
    if delta < 60 then
        return "just now"
    elseif delta < 3600 then
        return ("%dm ago"):format(math.floor(delta / 60))
    elseif delta < 86400 then
        return ("%dh ago"):format(math.floor(delta / 3600))
    end
    return ("%dd ago"):format(math.floor(delta / 86400))
end

--- Records a completed purchase: lifetime totals.
---@param entry TrackedEntry
---@param qty number
---@param spent number
---@return nil
function M.notePurchase(entry, qty, spent)
    local s = entry.stats
    s.boughtTotal = s.boughtTotal + qty
    s.spentTotal = s.spentTotal + spent
end

VMS.domain.SnipeLog = M
return M

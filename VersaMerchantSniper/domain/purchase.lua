-- VersaMerchantSniper - domain purchase math.
-- Pure Lua: must not reference any game API (lint-enforced via .luacheckrc).
-- This module COMPUTES; the merchant_api adapter EXECUTES. One purchase
-- call per entry per visit (no loop): unlimited stock (-1) is capped by
-- maxStack and the remaining wanted quantity, and money gates the clamped
-- batch - never a partial buy.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.domain = VMS.domain or {}

---@class MatchPair one resolved entry/slot pairing for this visit
---@field entry TrackedEntry
---@field slot MerchantSlot

---@class PurchaseOrder the verdict for one matched pair
---@field verdict string "order"|"no-stock"|"extended-cost"|"not-purchasable"|"ceiling"|"unaffordable"
---@field qty number|nil units the order buys ("order") or would buy ("unaffordable")
---@field cost number|nil total copper of the order batch ("order"/"unaffordable")
---@field entry TrackedEntry
---@field slot MerchantSlot

---@class Purchase
local M = {}

--- Identity match between one merchant slot and one tracked entry: ID first
--- (the entry's name is ignored once an ID is known), name fallback for
--- name-only entries. Nil slot names never match.
---@param slot MerchantSlot
---@param entry TrackedEntry
---@return boolean
function M.slotMatches(slot, entry)
    if entry.itemID then
        return slot.itemID ~= nil and slot.itemID == entry.itemID
    end
    if entry.name then
        return slot.name ~= nil and slot.name == entry.name
    end
    return false
end

--- Resolves the visit's matches: each active, enabled entry claims at most
--- one slot (its first match) and each slot serves at most one entry (the
--- first matching entry in list order - list order is the user's priority).
---@param slots MerchantSlot[]
---@param entries TrackedEntry[]
---@return MatchPair[]
function M.resolveMatches(slots, entries)
    local claimed = {}
    local matches = {}
    for _, slot in ipairs(slots) do
        for _, entry in ipairs(entries) do
            if entry.status == "active" and entry.enabled and not claimed[entry.key] and M.slotMatches(slot, entry) then
                claimed[entry.key] = true
                matches[#matches + 1] = { entry = entry, slot = slot }
                break
            end
        end
    end
    return matches
end

--- The purchase decision for one matched pair. Verdicts never mutate the
--- entry - applyPurchase does. Verdict order: no-stock -> extended-cost ->
--- not-purchasable -> ceiling -> unaffordable -> order.
---@param entry TrackedEntry
---@param slot MerchantSlot
---@param money number the player's copper on hand
---@return PurchaseOrder
function M.decide(entry, slot, money)
    ---@type PurchaseOrder
    local order = { verdict = "order", qty = nil, cost = nil, entry = entry, slot = slot }
    if slot.numAvailable == 0 then
        order.verdict = "no-stock"
        return order
    end
    if slot.hasExtendedCost then
        order.verdict = "extended-cost"
        return order
    end
    if not slot.isPurchasable then
        order.verdict = "not-purchasable"
        return order
    end
    local available = slot.numAvailable == -1 and math.huge or slot.numAvailable
    local qty = math.min(entry.quantity, available, slot.maxStack)
    if qty <= 0 then
        -- Degenerate caps (maxStack < 1): nothing buyable this visit.
        order.verdict = "no-stock"
        return order
    end
    if entry.priceCeiling ~= nil and slot.price > entry.priceCeiling then
        order.verdict = "ceiling"
        return order
    end
    local cost = slot.price * qty
    if cost > money then
        order.verdict = "unaffordable"
        order.qty = qty
        order.cost = cost
        return order
    end
    order.qty = qty
    order.cost = cost
    return order
end

--- Commits a successful order to the entry: decrements the remaining
--- quantity and completes the entry at zero when stop-on-success is set.
--- Lifetime totals (boughtTotal/spentTotal) are snipe_log's concern.
---@param entry TrackedEntry
---@param slot MerchantSlot
---@param qty number units bought (the order's clamped qty)
---@return {bought: number, spent: number, done: boolean}
function M.applyPurchase(entry, slot, qty)
    local spent = slot.price * qty
    entry.quantity = math.max(0, entry.quantity - qty)
    local done = false
    if entry.quantity == 0 and entry.stopOnSuccess then
        entry.status = "done"
        entry.enabled = false
        done = true
    end
    return { bought = qty, spent = spent, done = done }
end

VMS.domain.Purchase = M
return M

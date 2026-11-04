-- VersaMerchantSniper - debug dump formatting (domain).
-- Pure Lua: must not reference any game API (lint-enforced via .luacheckrc).
-- Text rendering of the tracked list and a live merchant stock scan for the
-- /vms debug command. The match preview runs the SAME resolveMatches +
-- decide the visit tick runs, so a dump explains a silent visit: which
-- entries matched, what verdict each got, and why nothing bought.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.domain = VMS.domain or {}

local Money = VMS.domain.Money
local Purchase = VMS.domain.Purchase

--- Display label for an entry: the caller's labeler when given (slash uses
--- the resolved-name chain), else the known name, else the stable key.
---@param entry TrackedEntry
---@param labeler (fun(entry: TrackedEntry): string)|nil
---@return string
local function labelFor(entry, labeler)
    if labeler ~= nil then
        return labeler(entry)
    end
    if entry.name ~= nil then
        return ("\"%s\""):format(entry.name)
    end
    return tostring(entry.key)
end

---@class DebugDump
local M = {}

--- One line per tracked entry: identity, remaining/initial want, stop flag,
--- ceiling, lifecycle state and the hunting stats (seen/missed/bought -
--- zeroes across the board prove visits never even matched anything).
---@param entries TrackedEntry[]
---@param labeler (fun(entry: TrackedEntry): string)|nil pretty label override
---@return string[]
function M.entryLines(entries, labeler)
    local lines = {}
    for index, entry in ipairs(entries) do
        local bits = { ("%d. %s"):format(index, labelFor(entry, labeler)) }
        bits[#bits + 1] = entry.itemID ~= nil and ("id:%d"):format(entry.itemID) or "no-id"
        bits[#bits + 1] = ("want x%d/%d"):format(entry.quantity, entry.quantityInitial)
        bits[#bits + 1] = entry.stopOnSuccess and "stop" or "nostop"
        if entry.priceCeiling ~= nil then
            bits[#bits + 1] = "max " .. Money.format(entry.priceCeiling)
        end
        bits[#bits + 1] = entry.enabled and entry.status or (entry.status .. " (disabled)")
        local stats = entry.stats
        if stats ~= nil then
            bits[#bits + 1] = ("seen %d, missed %d, bought %d"):format(
                stats.visitsSeen,
                stats.visitsMissed,
                stats.boughtTotal
            )
        end
        lines[#lines + 1] = table.concat(bits, " | ")
    end
    return lines
end

--- One line per stock slot: identity, price, stack, availability (-1 =
--- unlimited), batch cap and the buy gates (extended cost, not purchasable).
--- A run of id:- "(unnamed)" rows means the item-info read is broken on the
--- running client.
---@param slots MerchantSlot[]
---@return string[]
function M.slotLines(slots)
    local lines = {}
    for _, slot in ipairs(slots) do
        local bits = { ("#%d"):format(slot.index) }
        bits[#bits + 1] = slot.itemID ~= nil and ("id:%d"):format(slot.itemID) or "id:-"
        bits[#bits + 1] = slot.name ~= nil and ("\"%s\""):format(slot.name) or "(unnamed)"
        bits[#bits + 1] = "price " .. Money.format(slot.price)
        bits[#bits + 1] = ("stack %d"):format(slot.stackCount)
        bits[#bits + 1] = slot.numAvailable == -1 and "avail unlimited" or ("avail %d"):format(slot.numAvailable)
        bits[#bits + 1] = ("max %d"):format(slot.maxStack)
        if slot.hasExtendedCost then
            bits[#bits + 1] = "[extended-cost]"
        end
        if not slot.isPurchasable then
            bits[#bits + 1] = "[not-purchasable]"
        end
        lines[#lines + 1] = table.concat(bits, " | ")
    end
    return lines
end

--- Verdict preview for the hunt: matches and decisions for the ACTIVE
--- entries, exactly as the visit tick's hunt pass resolves them, then one
--- NO MATCH line per active entry the stock scan did not claim. Done and
--- disabled entries never appear - the core still records their sightings
--- (presence), but this preview is about buying.
---@param slots MerchantSlot[]
---@param entries TrackedEntry[]
---@param money number copper on hand
---@param labeler (fun(entry: TrackedEntry): string)|nil pretty label override
---@return string[]
function M.matchLines(slots, entries, money, labeler)
    local lines = {}
    local matched = {}
    local active = {}
    for _, entry in ipairs(entries) do
        if entry.status == "active" and entry.enabled then
            active[#active + 1] = entry
        end
    end
    for _, match in ipairs(Purchase.resolveMatches(slots, active)) do
        local entry, slot = match.entry, match.slot
        matched[entry.key] = true
        local order = Purchase.decide(entry, slot, money)
        local bits = { ("%s -> slot #%d: %s"):format(labelFor(entry, labeler), slot.index, order.verdict) }
        if order.qty ~= nil then
            bits[#bits + 1] = ("qty %d"):format(order.qty)
        end
        if order.cost ~= nil then
            bits[#bits + 1] = "cost " .. Money.format(order.cost)
        end
        if order.verdict == "ceiling" then
            bits[#bits + 1] = "unit " .. Money.format(slot.price)
        end
        lines[#lines + 1] = table.concat(bits, ", ")
    end
    for _, entry in ipairs(active) do
        if not matched[entry.key] then
            lines[#lines + 1] = ("%s -> NO MATCH in stock"):format(labelFor(entry, labeler))
        end
    end
    return lines
end

VMS.domain.DebugDump = M
return M

-- VersaMerchantSniper - merchant API adapter (outbound).
-- The ONLY place the game's merchant READ surface is touched. Reads use the
-- legacy FrameXML globals - the same ones Blizzard's MerchantFrame calls on
-- BOTH target flavors (dump-verified) - so no flavor variance enters this
-- adapter. Implements MerchantQueryPort. The addon NEVER buys or closes:
-- live Midnight refuses BuyMerchantItem calls whose stack passes through
-- so purchases live in the clicker macro (VMS.ClickerMacro,
-- see clicker_api).

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.outbound = VMS.adapters.outbound or {}

--- Reads one slot's item info across flavors: mainline 12.x exposes the
--- typed C_MerchantFrame.GetItemInfo struct (the legacy positional global
--- is gone there - dump: Mainline/MerchantFrame.lua reads the namespace,
--- Vanilla keeps the global). Degrades to empty stock rather than crashing.
---@param index number
---@return string|nil name
---@return number price
---@return number stackCount
---@return number numAvailable
---@return boolean isPurchasable
---@return boolean hasExtendedCost
local function itemInfoFor(index)
    if C_MerchantFrame ~= nil and C_MerchantFrame.GetItemInfo ~= nil then
        local info = C_MerchantFrame.GetItemInfo(index)
        if type(info) == "table" then
            return info.name,
                info.price or 0,
                info.stackCount or 0,
                info.numAvailable or 0,
                info.isPurchasable ~= false,
                info.hasExtendedCost == true
        end
    end
    if GetMerchantItemInfo == nil then
        return nil, 0, 1, 0, true, false
    end
    local name, _, price, stackCount, numAvailable, isPurchasable, _, hasExtendedCost = GetMerchantItemInfo(index)
    return name, price or 0, stackCount or 0, numAvailable or 0, isPurchasable ~= false, hasExtendedCost == true
end

---@class MerchantAPI : MerchantQueryPort
local M = {}

--- Stock snapshot: one MerchantSlot per merchant slot index (global across
--- pages). Every field is defaulted defensively - this adapter is the
--- boundary that guarantees the domain's MerchantSlot shape.
---@return MerchantSlot[]
function M.snapshot()
    local count = GetMerchantNumItems() or 0
    local slots = {}
    for index = 1, count do
        local name, price, stackCount, numAvailable, isPurchasable, hasExtendedCost = itemInfoFor(index)
        slots[#slots + 1] = {
            index = index,
            itemID = GetMerchantItemID ~= nil and GetMerchantItemID(index) or nil,
            name = name,
            price = price,
            stackCount = stackCount,
            numAvailable = numAvailable,
            maxStack = GetMerchantItemMaxStack ~= nil and GetMerchantItemMaxStack(index) or 1,
            hasExtendedCost = hasExtendedCost,
            isPurchasable = isPurchasable,
        }
    end
    return slots
end

--- Item link for one slot index (visit-row display for matched slots).
--- Midnight degraded: the legacy merchant link export exists but reads nil
--- on 12.1.5 (the modern merchant contract moved to C_MerchantFrame struct
--- reads, and legacy GetItemInfo is gone entirely); rebuild the link from
--- the slot's item ID through C_Item.GetItemInfo - the modern read returns
--- name, link, quality, ... positionally (dump: ItemDocumentation.lua).
---@param index number merchant slot index
---@return string|nil
function M.linkFor(index)
    if GetMerchantItemLink ~= nil then
        local ok, link = pcall(GetMerchantItemLink, index)
        if ok and type(link) == "string" then
            return link
        end
    end
    local itemID
    if GetMerchantItemID ~= nil then
        local okID, value = pcall(GetMerchantItemID, index)
        if okID and type(value) == "number" and value >= 1 then
            itemID = value
        end
    end
    if itemID ~= nil and C_Item ~= nil and type(C_Item.GetItemInfo) == "function" then
        local okInfo, _, link = pcall(C_Item.GetItemInfo, itemID)
        if okInfo and type(link) == "string" then
            return link
        end
    end
    return nil
end

--- Copper on hand. Absent API degrades to huge so the unaffordable verdict
--- never blocks a buyable slot.
---@return number
function M.money()
    if GetMoney == nil then
        return math.huge
    end
    return GetMoney() or 0
end

VMS.adapters.outbound.MerchantAPI = M
return M

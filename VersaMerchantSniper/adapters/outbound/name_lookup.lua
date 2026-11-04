-- VersaMerchantSniper - item identity lookup adapter (outbound).
-- Cache-first, best-effort names/icons/links for list and log rows: the own
-- cache first, then C_Item.GetItemInfo, then legacy GetItemInfo. HITS are
-- cached; misses stay uncached on purpose - early-session nils (client item
-- cache cold) must not lock wrong data in until reload. Never throws, never
-- gates anything.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.outbound = VMS.adapters.outbound or {}

---@class NameInfo
---@field name string|nil
---@field icon number|nil fileID
---@field link string|nil

---@class NameLookup : NameLookupPort
---@field cache table<number, NameInfo>
local M = {}

--- Builds the lookup instance.
---@return NameLookup
function M.new()
    ---@type NameLookup
    local self = setmetatable({}, { __index = M })
    self.cache = {}
    return self
end

--- Probe chain: C_Item.GetItemInfo first (the modern read), legacy
--- GetItemInfo second (names/links/icons), nothing last.
---@param itemID number
---@return string|nil name
---@return number|nil icon
---@return string|nil link
function M:probe(itemID)
    local name, icon, link
    if C_Item ~= nil and C_Item.GetItemInfo ~= nil then
        local ok, resolved = pcall(C_Item.GetItemInfo, itemID)
        if ok then
            name = resolved
        end
    end
    if GetItemInfo ~= nil then
        -- GetItemInfo returns: name, link, quality, iLevel, reqLevel, class,
        -- subclass, maxStack, equipSlot, iconTexture, ...
        local ok, resolved, gotLink, _, _, _, _, _, _, gotIcon = pcall(GetItemInfo, itemID)
        if ok then
            if name == nil then
                name = resolved
            end
            link = gotLink
            icon = gotIcon
        end
    end
    return name, icon, link
end

--- Fills the cache once per itemID; misses leave the slot empty.
---@param itemID number
---@return nil
function M:fill(itemID)
    if self.cache[itemID] ~= nil then
        return
    end
    local name, icon, link = self:probe(itemID)
    if name == nil and icon == nil and link == nil then
        return
    end
    self.cache[itemID] = { name = name, icon = icon, link = link }
end

---@param itemID number
---@return string|nil
function M:nameFor(itemID)
    self:fill(itemID)
    local hit = self.cache[itemID]
    if hit ~= nil then
        return hit.name
    end
    return nil
end

---@param itemID number
---@return number|nil
function M:iconFor(itemID)
    self:fill(itemID)
    local hit = self.cache[itemID]
    if hit ~= nil then
        return hit.icon
    end
    if C_Item ~= nil and C_Item.GetItemIconByID ~= nil then
        local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
        if ok then
            return icon
        end
    end
    return nil
end

---@param itemID number
---@return string|nil
function M:linkFor(itemID)
    self:fill(itemID)
    local hit = self.cache[itemID]
    if hit ~= nil then
        return hit.link
    end
    return nil
end

VMS.adapters.outbound.NameLookup = M
return M

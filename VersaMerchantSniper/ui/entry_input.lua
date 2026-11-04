-- VersaMerchantSniper - entry input parsing (ui).
-- Maps pasted item links / bare IDs / typed names and the optional
-- x<qty>, max <money>, stop/nostop tokens onto a raw entry table the core
-- validates. Pure Lua: no game globals (lint-enforced). Loads after the
-- domain block (reads domain.Money through the namespace).
--
-- Grammar (tokens, order-free): item:<id> (any pasted link's ID), a bare
-- numeric ID, bracketed or plain name words (when no ID was found),
-- x<qty>, max:<money> / max <money...> (g/s/c or plain copper),
-- "stop" / "nostop".

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.ui = VMS.ui or {}

local Money = VMS.domain and VMS.domain.Money

---@class RawEntry untrusted entry fields handed to the core's validator
---@field itemID number|nil
---@field name string|nil
---@field quantity number|nil
---@field stopOnSuccess boolean|nil
---@field priceCeiling number|nil

---@class EntryInput
local M = {}

--- Money-ish token: bare copper ("500"), one unit ("500g"), or a glued
--- multi-unit token ("12g34s56c"). Whether it parses is Money's job.
---@param token string
---@return boolean
local function moneyish(token)
    return token:match("^%d+[gsc%d]*$") ~= nil
end

--- Item ID out of one token: an `item:<id>` segment (any pasted link
--- carries one) or a bare numeric token.
---@param token string
---@return number|nil
local function extractID(token)
    local id = token:match("[iI]tem:(%d+)")
    if id ~= nil then
        return tonumber(id)
    end
    local bare = token:match("^(%d+)$")
    if bare ~= nil then
        return tonumber(bare)
    end
    return nil
end

--- Parses free-form entry text into a raw entry.
---@param text any
---@return RawEntry|nil
---@return string|nil reason when nothing usable or a token is invalid
function M.parse(text)
    if type(text) ~= "string" then
        return nil, "empty-input"
    end
    local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return nil, "empty-input"
    end

    ---@type RawEntry
    local raw = {}
    local nameFragments = {}
    local pendingMax = false
    local maxFilled = false

    for token in trimmed:gmatch("%S+") do
        local lowered = token:lower()
        local id = extractID(token)
        if id ~= nil then
            raw.itemID = id
        elseif token:match("^[xX]%d+$") then
            raw.quantity = tonumber(token:sub(2))
        elseif lowered == "stop" then
            raw.stopOnSuccess = true
        elseif lowered == "nostop" then
            raw.stopOnSuccess = false
        elseif lowered:match("^max:") then
            local money = Money.parseCopper(token:sub(5))
            if money == nil then
                return nil, "bad-money"
            end
            raw.priceCeiling = money
            pendingMax = false
        elseif lowered == "max" then
            pendingMax = true
        elseif pendingMax and moneyish(token) then
            local money = Money.parseCopper(token)
            if money == nil then
                return nil, "bad-money"
            end
            raw.priceCeiling = (raw.priceCeiling or 0) + money
            maxFilled = true
        elseif pendingMax then
            return nil, "missing-money"
        elseif raw.itemID == nil then
            -- Name words only count when no ID was found (a pasted link
            -- with spaces in its name spills extra tokens).
            nameFragments[#nameFragments + 1] = token
        end
    end
    if pendingMax and not maxFilled then
        -- "max" seen but no money token followed before the input ended.
        return nil, "missing-money"
    end

    if raw.itemID == nil and #nameFragments > 0 then
        local name = table.concat(nameFragments, " "):gsub("[%[%]]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then
            raw.name = name
        end
    end
    if raw.itemID == nil and raw.name == nil then
        return nil, "no-identity"
    end
    return raw
end

VMS.ui.EntryInput = M
return M

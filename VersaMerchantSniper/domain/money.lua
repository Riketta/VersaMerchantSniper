-- VersaMerchantSniper - money helpers (ported from the AuctiMogger money
-- module). Copper amounts fit comfortably in Lua doubles (< 2^53).

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.domain = VMS.domain or {}

--- Lua doubles lose integer precision at 2^53; beyond it the copper math
--- (and every consumer comparing amounts) would silently drift.
local MAX_COPPER = 2 ^ 53

---@class Money
local M = {}

--- Splits a copper amount into gold/silver/copper. Negative amounts are
--- split by magnitude (the sign is handled by the callers, e.g. format
--- prints it in front).
---@param copper number
---@return number gold
---@return number silver
---@return number rem
function M.split(copper)
    copper = math.floor(math.abs(copper) + 0.5)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local rem = copper % 100
    return gold, silver, rem
end

---@param copper number
---@return string
function M.format(copper)
    local sign = copper < 0 and "-" or ""
    local gold, silver, rem = M.split(copper)
    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = gold .. "g"
    end
    if silver > 0 then
        parts[#parts + 1] = silver .. "s"
    end
    if rem > 0 or #parts == 0 then
        parts[#parts + 1] = rem .. "c"
    end
    return sign .. table.concat(parts, " ")
end

--- Compact single-unit form for dense tables: "1.2k" gold-dominant,
--- silver fallback under 1g, "-" for absent/zero values.
---@param copper number|nil
---@return string
function M.compact(copper)
    if not copper or copper <= 0 then
        return "-"
    end
    local gold = copper / 10000
    if gold >= 1000 then
        return ("%.0fk"):format(gold / 1000)
    end
    if gold >= 100 then
        return ("%.0fg"):format(gold)
    end
    if gold >= 1 then
        return ("%.1fg"):format(gold)
    end
    if copper < 100 then
        return ("%dc"):format(copper) -- sub-silver: "45c", not "0s"
    end
    return ("%ds"):format(copper / 100)
end

--- Price per unit, floored; falls back to the total when quantity is degenerate.
---@param total number
---@param quantity number|nil
---@return number
function M.perUnit(total, quantity)
    if not quantity or quantity <= 0 then
        return total
    end
    return math.floor(total / quantity)
end

--- Parses free-form money text into copper: "500g", "12g34s56c",
--- "12g 34s", plain "5000000" (copper). Tokens may appear in any order
--- (g > s > c enforced by the caller's intent, not by position). Returns nil
--- when nothing usable remains - callers treat that as an empty input.
---@param text string|nil
---@return number|nil copper
function M.parseCopper(text)
    if type(text) ~= "string" then
        return nil
    end
    local cleaned = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if cleaned == "" then
        return nil
    end
    if cleaned:match("^%d+$") then
        local total = tonumber(cleaned)
        if not total or total >= MAX_COPPER then
            return nil -- beyond the double-precision bound: refuse, do not drift
        end
        return total
    end
    local gold, silver, copper = 0, 0, 0
    for amount, unit in cleaned:gmatch("(%d+)%s*([gsc])") do
        if unit == "g" then
            gold = gold + tonumber(amount)
        elseif unit == "s" then
            silver = silver + tonumber(amount)
        else
            copper = copper + tonumber(amount)
        end
    end
    if gold + silver + copper == 0 then
        return nil
    end
    -- Reject leftovers: "12x34g" must not silently become 34g.
    local leftover = cleaned:gsub("%d+%s*[gsc]", "")
    if leftover:find("%S") then
        return nil
    end
    local total = gold * 10000 + silver * 100 + copper
    if total >= MAX_COPPER then
        return nil -- beyond the double-precision bound: refuse, do not drift
    end
    return total
end

VMS.domain.Money = M
return M

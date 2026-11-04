-- VersaMerchantSniper - clicker API adapter (inbound).
-- The macro-execution surface: publishes the canonical clicker macro
-- (VMS.ClickerMacro) and the two calls a self-contained /run chunk uses.
-- Live Midnight refuses ANY BuyMerchantItem call whose stack passes through
-- addon frames, so buying lives in the chunk itself (pure Blizzard reads +
-- buys; a chat /run is a keypress-rooted dispatch and is accepted) - this
-- adapter only feeds it data before (BuyableSlots) and books the results
-- after (RecordBuys), never between.
--
-- Registered on both namespaces: /run VMS.BuyableSlots() == /run
-- VersaMerchantSniper.BuyableSlots(). VMS.ClickerMacro is the canonical
-- macro text, shown on the dashboard's Settings tab.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.inbound = VMS.adapters.inbound or {}

-- The canonical clicker macro: buys one unit of every tracked, wanted item
-- still buyable (order verdict - stock, no extended cost, purchasable,
-- within ceiling, affordable), closes the vendor when something was bought,
-- then hands the bought counts to the addon for bookkeeping. Kept as one
-- constant so the Settings-tab copy box cannot drift from the documented
-- behavior.
local CLICKER_MACRO = "/run local b={} local s=VMS.BuyableSlots()"
    .. " for _,x in ipairs(s) do BuyMerchantItem(x.index,1) b[x.itemID]=(b[x.itemID] or 0)+1 end"
    .. " if next(b)~=nil then CloseMerchant() end VMS.RecordBuys(b)"

---@class ClickerAPI
---@field core ControlPort|nil injected by new
---@field alerts AlertPort|nil injected by new
local M = {}

--- Wires the clicker globals over the core. The functions are built on a
--- plain local table and merged dynamically - defining them directly on the
--- shared namespace trips duplicate-set-field diagnostics.
---@param core ControlPort
---@param alerts AlertPort
---@return ClickerAPI
function M.new(core, alerts)
    ---@type ClickerAPI
    local self = setmetatable({}, { __index = M })
    self.core = core
    self.alerts = alerts

    local surface = {}

    --- Slots the clicker macro may buy right now: order-verdict matches
    --- (stock, no extended cost, purchasable, within ceiling, affordable)
    --- with an itemID for bookkeeping.
    surface.BuyableSlots = function()
        return core:buyableSlots()
    end

    --- Clicker bookkeeping: the macro buys with pure Blizzard calls, then
    --- hands the bought counts here (decrement, complete, narrate, log).
    surface.RecordBuys = function(bought)
        return core:recordBuys(bought)
    end

    local api = _G.VersaMerchantSniper
    for name, fn in pairs(surface) do
        api[name] = fn
    end
    api.ClickerMacro = CLICKER_MACRO

    -- The addon's second global name.
    _G.VMS = api

    return self
end

VMS.adapters.inbound.ClickerAPI = M
return M

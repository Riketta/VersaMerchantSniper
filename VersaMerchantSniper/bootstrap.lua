-- VersaMerchantSniper - composition root. The ONLY file that instantiates
-- adapters and injects dependencies; the TOC loads it last.
--
-- Construction defers to ADDON_LOADED: SavedVariables are only real then.
-- The validated shape is written BACK to the VersaMerchantSniperDB global -
-- the game flushes the table it holds, not our locals, so skipping that
-- write would orphan every persisted record. A GUI build failure degrades
-- to "GUI unavailable"; the headless sniper keeps running.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS

VMS.bootstrap = VMS.bootstrap or {}

--- Builds the object graph once the addon's SavedVariables exist.
---@return nil
local function bootstrap()
    local DB = VMS.adapters.outbound.DB
    local Clock = VMS.adapters.outbound.Clock
    local MerchantAPI = VMS.adapters.outbound.MerchantAPI
    local NameLookup = VMS.adapters.outbound.NameLookup
    local ActivityLog = VMS.adapters.outbound.ActivityLog
    local AlertChat = VMS.adapters.outbound.AlertChat
    local Compat = VMS.adapters.inbound.Compat
    local MerchantFeed = VMS.adapters.inbound.MerchantFeed
    local Slash = VMS.adapters.inbound.Slash
    local ClickerAPI = VMS.adapters.inbound.ClickerAPI
    local Gui = VMS.ui.Gui
    local Core = VMS.domain.Core

    -- Storage first: validate + default the blob, anchor the validated
    -- shape back onto the global the game persists.
    local db, droppedEntries, droppedLog = DB.attach(_G.VersaMerchantSniperDB)
    _G.VersaMerchantSniperDB = db

    local alerts = AlertChat.new(DB)
    local names = NameLookup.new()
    local store = ActivityLog.new(DB)
    local core = Core.new({
        query = MerchantAPI,
        store = store,
        alerts = alerts,
        clock = Clock,
        db = DB,
    })

    MerchantFeed.new(core)
    -- Legacy API first: it publishes VMS.ClickerMacro, which the GUI's
    -- Settings tab copy box reads at build time.
    ClickerAPI.new(core, alerts)
    local gui = Gui.new({ core = core, names = names, alerts = alerts, query = MerchantAPI })
    Slash.new(core, alerts, names, MerchantAPI)

    -- Expose the live graph for /run diagnostics.
    VMS.bootstrap.core = core
    VMS.bootstrap.gui = gui
    VMS.bootstrap.store = store

    -- Startup reports: compat tiers first, then persistence losses.
    local result = Compat.check()
    local warning = Compat.warningFor(result)
    if warning ~= nil then
        alerts:say(warning .. (result.build and (" [client " .. result.build .. "]") or ""))
    end
    if droppedEntries + droppedLog > 0 then
        alerts:say(
            ("SavedVariables: dropped %d corrupt list %s and %d log %s."):format(
                droppedEntries,
                droppedEntries == 1 and "entry" or "entries",
                droppedLog,
                droppedLog == 1 and "row" or "rows"
            )
        )
    end
    if gui.available == false and gui.buildError ~= nil then
        alerts:say("GUI unavailable: " .. gui.buildError)
    end
end

local bootFrame = CreateFrame("Frame", "VersaMerchantSniperBootstrapFrame")
bootFrame:RegisterEvent("ADDON_LOADED")
bootFrame:SetScript("OnEvent", function(_, event, addonName)
    if event ~= "ADDON_LOADED" or addonName ~= "VersaMerchantSniper" then
        return
    end
    bootFrame:UnregisterEvent("ADDON_LOADED")
    bootFrame:SetScript("OnEvent", nil)
    bootstrap()
end)

return VMS.bootstrap

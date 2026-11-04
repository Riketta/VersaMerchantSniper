-- VersaMerchantSniper - compatibility probe adapter.
-- The addon targets the legacy merchant API family (the same globals
-- Blizzard's own MerchantFrame calls on BOTH target flavors). Clients,
-- private servers and beta forks may lag behind; this probe verifies the
-- exact surface the addon calls and reports loudly at startup instead of
-- dying mysteriously mid-snipe later.
--
-- The manifest below is organized in TIERS, each with its own failure
-- semantics. Every game surface the addon touches must be listed in exactly
-- one tier: scripts/check_compat.lua scans the game-facing sources at CI
-- time and fails the build when code uses a name no tier lists.
--
--   REQUIRED  the core loop breaks without it; a missing entry fails the
--             check (result.ok = false) and the startup warning fires.
--   OPTIONAL  graceful degradation: the feature that needs it has a
--             documented fallback (per-entry comment); a missing entry
--             degrades the result (result.degraded), never gates.
--   PROBE     manual diagnostics only (compat report build stamp); reported
--             in result.probeMissing, never gates.
--   GUI       GUI-only globals; missing entries keep the GUI unavailable
--             (result.guiMissing) while the headless sniper keeps running.
--   DEFERRED  authored-later globals (slash registration written by
--             slash.lua itself; the close-button fallback global) -
--             recorded in result.deferred, never gates, every touchpoint
--             nil-guards at call time.
--
-- Event names cannot be probed by existence; REQUIRED/OPTIONAL event tiers
-- exist for the CI scanner. The merchant_feed adapter fails fast at
-- RegisterEvent if a client dropped one.
--
-- Usage: /run VersaMerchantSniper.adapters.inbound.Compat.check()

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.inbound = VMS.adapters.inbound or {}

---@class CompatManifest
---@field requiredEvents string[] events whose absence fails the probe (CI scanner only)
---@field requiredFunctions string[] reserved for dotted C_ functions the core needs (none today)
---@field requiredGlobals string[] plain globals the core loop needs
---@field requiredAlternatives string[][] any-of REQUIRED groups: at least one entry per group must exist (flavor-split reads)
---@field optionalEvents string[] events with a documented fallback
---@field optionalGlobals string[] globals with a documented fallback
---@field probeEvents string[] diagnostics-only events
---@field probeGlobals string[] diagnostics-only globals
---@field guiGlobals string[] GUI-only globals (missing keeps the GUI unavailable)
---@field guiDeferredGlobals string[] globals written/loaded later (slash registration, LOD frames)
---@field guiAlternatives table<string, string[]> per-surface alternatives (any-of lists)

---@class CompatResult
---@field ok boolean REQUIRED tier intact
---@field degraded boolean at least one OPTIONAL entry missing (feature falls back)
---@field missing string[] REQUIRED names absent at check time
---@field optionalMissing string[] OPTIONAL names absent at check time
---@field probeMissing string[] PROBE names absent at check time
---@field guiMissing string[] GUI names absent at check time
---@field deferred string[] DEFERRED names absent at check time (expected; never gates)
---@field build string|nil GetBuildInfo stamp when available

---@class Compat
---@field manifest CompatManifest
---@field check fun(): CompatResult
---@field warningFor fun(result: CompatResult): string|nil
local M = {}

local manifest = {
    -- The core loop: sees the vendor opens/ends, reads stock, buys, closes.
    requiredEvents = {
        "ADDON_LOADED", -- the composition root cannot build without it
        "MERCHANT_SHOW",
        "MERCHANT_CLOSED",
    },
    requiredFunctions = {}, -- reserved for dotted C_ functions the core needs (none today)
    requiredGlobals = {
        "CreateFrame", -- the feed/GUI event frames
        "GetMerchantItemID", -- ID-first matching
        "GetMerchantItemLink", -- visit-row links for matched slots
        "GetMerchantItemMaxStack", -- batch clamp
        "GetMerchantNumItems", -- snapshot loop bound
        "GetMoney", -- the unaffordable verdict gate (absent never blocks: money() degrades to huge)
        "SlashCmdList", -- slash.lua writes SlashCmdList["VMS"]; nil would error the slash adapter at bootstrap
        "time", -- wall-clock stat stamps
    },
    requiredAlternatives = {
        -- The item-info read is flavor-split: mainline 12.x exposes the typed
        -- C_ struct (the legacy positional global is gone there), vanilla-era
        -- builds keep GetMerchantItemInfo. Either satisfies the probe.
        { "C_MerchantFrame.GetItemInfo", "GetMerchantItemInfo" },
    },
    optionalEvents = {
        "MERCHANT_UPDATE", -- telemetry only; never a purchase trigger
    },
    optionalGlobals = {
        "ChatEdit_InsertLink", -- shift-click link-insert home (classic era); the GUI hooks it
        "ChatFrameUtil.InsertLink", -- shift-click link-insert home (mainline); the GUI hooks it
        "C_Item.GetItemIconByID", -- direct icon read; falls back to GetItemInfo's icon field
        "C_Item.GetItemInfo", -- the modern name chain; falls back to legacy GetItemInfo
        "GetBuildInfo", -- hmm PROBE tier
        "GetItemInfo", -- legacy names/links/icons; degrades to bare IDs
        "GetSubZoneText", -- visit zone stamp; degrades to nil
        "GetTime", -- session-seconds diagnostics; degrades to 0
        "GetZoneText", -- visit zone stamp; degrades to nil
        "IsModifiedClick", -- vendor-row link-capture guard; absent: the focused-box insert-home capture still works
        "MerchantItemButton_OnModifiedClick", -- vendor-row link-capture hook point; absent: the focused-box capture still works
        "UnitName", -- vendor name for log rows; degrades to nil
        "date", -- chat line stamps; degrades to "--:--:--"
    },
    probeEvents = {},
    probeGlobals = {
        "GetBuildInfo", -- compat report build stamp
    },
    guiGlobals = {
        "ClearCursor", -- cursor release after link-driven entry adds
        "GameTooltip", -- merchant-button + row tooltips
        "GetCursorInfo", -- link-driven entry adds (bag item on cursor)
        "MerchantFrame", -- the toggle button's parent (exists by ADDON_LOADED)
        "PanelTemplates_SetTab", -- tab-highlight updates; absent: the GUI highlights tabs itself
        "UIParent", -- GUI frame parent
    },
    guiDeferredGlobals = {
        "MerchantFrameCloseButton", -- classic-era close-button anchor (rawget'd; primary path is MerchantFrame.CloseButton)
        "SLASH_VMS1", -- written by slash.lua itself
        "SLASH_VMS2", -- written by slash.lua itself
    },
    guiAlternatives = {
        closeButton = { "MerchantFrame.CloseButton", "MerchantFrameCloseButton" },
    },
}

M.manifest = manifest

--- Existence probe for one manifest path: plain global or two-segment
--- dotted path (our whole surface is one level deep).
---@param path string
---@return boolean
local function exists(path)
    if path:find(".", 1, true) then
        local base, member = path:match("^([^.]+)%.(.+)$")
        local baseValue = rawget(_G, base)
        if type(baseValue) ~= "table" then
            return false
        end
        return rawget(baseValue, member) ~= nil
    end
    return rawget(_G, path) ~= nil
end

--- Probes the manifest against the running client. Event tiers are not
--- probed (existence is not observable); the CI scanner covers them.
---@return CompatResult
function M.check()
    local result = {
        ok = true,
        degraded = false,
        missing = {},
        optionalMissing = {},
        probeMissing = {},
        guiMissing = {},
        deferred = {},
        build = nil,
    }
    for _, name in ipairs(manifest.requiredGlobals) do
        if not exists(name) then
            result.missing[#result.missing + 1] = name
            result.ok = false
        end
    end
    for _, group in ipairs(manifest.requiredAlternatives) do
        local anyExists = false
        for _, name in ipairs(group) do
            if exists(name) then
                anyExists = true
                break
            end
        end
        if not anyExists then
            result.missing[#result.missing + 1] = table.concat(group, " or ")
            result.ok = false
        end
    end
    for _, name in ipairs(manifest.optionalGlobals) do
        if not exists(name) then
            result.optionalMissing[#result.optionalMissing + 1] = name
            result.degraded = true
        end
    end
    for _, name in ipairs(manifest.probeGlobals) do
        if not exists(name) then
            result.probeMissing[#result.probeMissing + 1] = name
        end
    end
    for _, name in ipairs(manifest.guiGlobals) do
        if not exists(name) then
            result.guiMissing[#result.guiMissing + 1] = name
        end
    end
    for _, name in ipairs(manifest.guiDeferredGlobals) do
        if not exists(name) then
            result.deferred[#result.deferred + 1] = name
        end
    end
    if rawget(_G, "GetBuildInfo") ~= nil then
        local ok, build = pcall(GetBuildInfo)
        if ok then
            result.build = build
        end
    end
    return result
end

--- One chat-ready line describing anything worth attention (nil when all
--- tiers are intact). No colors - the alert adapter owns presentation.
---@param result CompatResult
---@return string|nil
function M.warningFor(result)
    local parts = {}
    if not result.ok and #result.missing > 0 then
        parts[#parts + 1] = "missing core APIs (" .. table.concat(result.missing, ", ") .. ")"
    end
    if #result.optionalMissing > 0 then
        parts[#parts + 1] = "degraded (" .. table.concat(result.optionalMissing, ", ") .. ")"
    end
    if #result.guiMissing > 0 then
        parts[#parts + 1] = "GUI unavailable (" .. table.concat(result.guiMissing, ", ") .. ")"
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "; ")
end

VMS.adapters.inbound.Compat = M

return M

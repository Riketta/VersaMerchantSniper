-- VersaMerchantSniper lint + architecture boundary rules.
--
-- Hexagonal boundary enforcement:
--   * VersaMerchantSniper/domain and VersaMerchantSniper/ports get NO game
--     globals: any WoW API reference fails CI.
--   * VersaMerchantSniper/adapters and ui get the explicit WoW API
--     allowlists below.
--   * spec files get the busted harness globals.
--   * legacy/ holds the historical script verbatim; it is never loaded by
--     the TOC and is excluded from the gates entirely.

std = "lua51"
cache = true

-- LuaLS annotations are single-line by design (`@field fun(...)` types do
-- not wrap), so this limit sits above stylua's 120 code columns (which the
-- formatter enforces on its own).
max_line_length = 150
-- OO adapters are stateless: methods legitimately ignore the implicit self.
self = false

exclude_files = { ".luarocks/**", "tools/**", "legacy/**" }

globals = {
    "VersaMerchantSniper",
    "VMS",
    "VersaMerchantSniperDB",
}

files["VersaMerchantSniper/adapters"] = {
    globals = {
        "VersaMerchantSniper",
        "VMS",
        "C_Item",
        "C_MerchantFrame",
        "CreateFrame",
        "date",
        "GetBuildInfo",
        "GetItemInfo",
        "GetMerchantItemID",
        "GetMerchantItemInfo",
        "GetMerchantItemLink",
        "GetMerchantItemMaxStack",
        "GetMerchantNumItems",
        "GetMoney",
        "GetSubZoneText",
        "GetTime",
        "GetZoneText",
        "hooksecurefunc",
        "SLASH_VMS1",
        "SLASH_VMS2",
        "SlashCmdList",
        "time",
        "UIParent",
        "UnitName",
    },
}

-- The GUI adapter: frames + the driving surface. Same adapter surface plus
-- the widget globals the compat probe gates separately (GUI tier).
files["VersaMerchantSniper/ui"] = {
    globals = {
        "VersaMerchantSniper",
        "C_Item",
        "ClearCursor",
        "CreateFrame",
        "date",
        "GameTooltip",
        "GetCursorInfo",
        "GetItemInfo",
        "GetTime",
        "hooksecurefunc",
        "IsModifiedClick",
        "MerchantFrame",
        "MerchantItemButton_OnModifiedClick",
        "time",
        "UIParent",
    },
}

-- The composition root is at VersaMerchantSniper/bootstrap.lua, not in
-- adapters/: it only creates the bootstrap event frame itself (everything
-- else is delegated to adapters).
files["VersaMerchantSniper/bootstrap.lua"] = {
    globals = {
        "CreateFrame",
        "VersaMerchantSniper",
        "VersaMerchantSniperDB",
    },
}

-- Spec stubs type the WoW globals for LuaLS (see the `rawset(_G, ...)`
-- stubs), so they are variadic on purpose and 212 (unused vararg argument)
-- is expected noise here. Keep the rest of the checks on.
files["spec"] = {
    ignore = { "212" },
    globals = {
        "VersaMerchantSniper",
        "VMS",
        "describe",
        "it",
        "before_each",
        "after_each",
        "setup",
        "teardown",
        "pending",
        "insulate",
        "expose",
    },
}

files["scripts"] = {
    globals = {
        "arg",
        "assert",
        "describe",
        "it",
        "before_each",
        "after_each",
        "setup",
        "teardown",
    },
}

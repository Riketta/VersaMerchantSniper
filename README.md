# VersaMerchantSniper

Vendor-stand sniping addon for World of Warcraft: it watches the default
merchant frame, buys your tracked items automatically the moment a vendor
opens, and keeps a hunting log — when the item was last seen, how long you
waited for it, what was bought where.

Evolution of the legacy `VersaUtils_MerchantSniper.lua` script (kept in
`legacy/`; the addon preserves its `/run` API).

## Features

- Tracked buy list: paste an item link or type an ID; per-entry quantity,
  stop-on-success and a price ceiling.
- Hunting log: per-visit records plus per-item stats (last seen — when,
  where, how many in stock; time from arming to the first buy; totals).
- Toggle button on the default vendor frame (next to the close button) and
  an own window with List / Log / Settings tabs.
- Auto-closes the vendor after an armed visit; auto-disarms when everything
  is bought (the list itself is preserved; entries show as done).
- Guarded purchases: extended-cost items are never auto-bought; per-entry
  price ceiling and a money gate.

## Compatibility

`## Interface: 16001, 120100` — camelot beta client and retail Midnight.
Other game flavors are out of scope (see `AGENTS.md` for the policy and the
interface dump of record).

## Install

Symlink (or copy) the `VersaMerchantSniper/` folder into
`World of Warcraft/_retail_/Interface/AddOns/` (or the beta client's
equivalent).

## Usage

- `/vms help` — command overview.
- `/vms add <item link|id> [x<qty>] [max <money>] [nostop]` — track an item.
- `/vms start` / `/vms stop` — arm / disarm the sniper.
- `/vms list`, `/vms log [n]`, `/vms remove <n|id|name>`, `/vms clearlog`.
- Legacy `/run` API: `VersaMerchantSniper` (alias `VMS`) keeps
  `StartSniping`, `StopSniping`, `TryStopSniping`, `SnipeItemByID`,
  `SnipeItemByName`, `PrintItemsToBuy`.

## Development

```
bash scripts/bootstrap-tools.sh   # one-time local toolchain fetch
bash scripts/ci_local.sh          # full gate: stylua, luacheck, busted,
                                  # TOC coverage, compat manifest, LuaLS
```

Architecture, contracts and rules: `AGENTS.md`. Behavior spec and data
contracts: `SPEC.md`.

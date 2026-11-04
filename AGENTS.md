# AGENTS.md — VersaMerchantSniper project guide

Rules, conventions, contracts and constraints for anyone (human or agent)
changing this repository. If a change violates something here, fix the change
— or update this file and the CI config together, deliberately.

## What this project is

VersaMerchantSniper is a World of Warcraft **vendor-stand sniper**: it watches
the default merchant frame, tracks sightings of the wanted items (last seen
where/when/stock), keeps a hunting log (what was bought where via the
clicker macro), and manages the tracked list through its own UI. It is the
addon evolution of the legacy `legacy/VersaUtils_MerchantSniper.lua`
script (kept verbatim for reference; the addon publishes the `/run`
clicker API).

The behavior spec and data contracts live in `SPEC.md` — the source
of truth for WHAT the addon does. This file is the source of truth for HOW
changes are made.

### Compatibility policy

- Dual-TOC `## Interface: 16001, 120100`: the camelot beta client (game type
  vanilla — `Vanilla\MerchantFrame` loads) and retail Midnight (mainline —
  `[Family]\` = `Mainline\`). Other classic flavors are out of scope.
- Flavor variance lives in adapters and nil-guarded compat tiers, never in
  domain code.
- **Interface dump of record** (source of truth for every Blizzard claim —
  verify there before trusting any framework-specific statement):
  `D:\Dev External\Blizzard\1.60.1.70634\BlizzardInterfaceCode`
  - Merchant frame: `Interface/AddOns/Blizzard_UIPanels_Game/{Vanilla,Mainline}/MerchantFrame.{lua,xml}`
  - Merchant API + events: `Interface/AddOns/Blizzard_APIDocumentationGenerated/MerchantFrameDocumentation.lua`
  - Frame/close-button templates: `Interface/AddOns/Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml`
- Reference addon for proven UI patterns on the same client (same author):
  `D:\Dev\WoW Goop\AuctiMogger`.

### Hard runtime facts (dump-verified)

- `BuyMerchantItem(index, qty)` is **hardware-context-gated on live
  Midnight 12.1.5**: calls from addon event/timer dispatches throw
  `Usage: BuyMerchantItem(index [,quantity])` from the engine itself, while
  the identical call succeeds from hardware-rooted surfaces (frame clicks,
  chat `/run` - a keypress). The dump cannot show this: every Blizzard call
  site sits in a click/dialog context, so the API is used correctly by
  FrameXML on both flavors. **Policy**: the addon NEVER calls
  `BuyMerchantItem`/`CloseMerchant` — any call passing through addon frames
  fails (live-verified: the same call succeeds from a `/run` chunk and
  fails through one addon wrapper). Buying is the self-contained macro (see
  SPEC.md): pure Blizzard reads + `VMS.BuyableSlots()` filter +
  `BuyMerchantItem` per slot + `VMS.RecordBuys()` + `CloseMerchant`
  (always - vendor stock only refreshes on open) inside the chunk.
  `VMS.ClickerMacro` is the canonical text, shown on the
  dashboard's Settings tab.
- Merchant reads are flavor-split (dump: Mainline/MerchantFrame.lua reads
  the namespace, Vanilla keeps the global): the item-info read is
  `C_MerchantFrame.GetItemInfo` (typed `MerchantItemInfo` struct) on
  mainline 12.x and positional `GetMerchantItemInfo` on vanilla-era
  builds — the adapter branches, compat requires one-of. The rest is
  shared: `GetMerchantNumItems`, `GetMerchantItemID`,
  `GetMerchantItemMaxStack`, `GetMerchantItemLink`, close: `CloseMerchant`.
  `numAvailable == -1` means unlimited stock; `name` can be nil.
- Events: `MERCHANT_SHOW`, `MERCHANT_CLOSED`, `MERCHANT_UPDATE`,
  `MERCHANT_FILTER_ITEM_UPDATE`.
- `MerchantFrame` inherits `ButtonFrameTemplate` → `parentKey="CloseButton"`
  (global `$parentCloseButton` = `MerchantFrameCloseButton`) on both
  flavors; the frame is not protected; parenting a child button to it is
  safe (AuctiMogger proves the pattern on this client).
- SavedVariables flush only on logout/reload; stock is visible only while a
  merchant session is open (treat stock as refreshed on re-open).

## Architecture: hexagonal (ports & adapters) — non-negotiable

Dependency direction, strictly one-way:

    adapters (in/out) + ui -> ports -> domain -> (nothing)

- `domain/` — **pure Lua**. No WoW API, no `io`/`os`, no game globals.
  CI-enforced (per-folder luacheck globals; see `.luacheckrc`).
- `ports/` — contract annotations only (`---@meta` style, no runtime code).
- `adapters/` — the only place game APIs are touched. Translators between a
  medium (game events, slash text, `/run` calls, widgets) and ports.
- `ui/` — the GUI driving adapter and its presentation helpers.
- `bootstrap.lua` — composition root. The only file that instantiates
  adapters and injects dependencies; must be last in the TOC; construction
  defers to `ADDON_LOADED` (SavedVariables are only real then).

## Project structure

```
VersaMerchantSniper/            deployable addon folder (symlink into AddOns)
  VersaMerchantSniper.toc       ## Interface: 16001, 120100
  domain/                       types, money, purchase, snipe_log, core (pure)
  ports/                        inbound/outbound contract annotations
  adapters/outbound/            clock, db, activity_log, name_lookup, merchant_api, alert_chat
  adapters/inbound/             compat, merchant_feed, slash, clicker_api
  ui/                           gui, table_view, feed_rows, entry_input
  bootstrap.lua                 composition root (last)
legacy/                         the original script, verbatim, excluded from gates
spec/                           busted specs (run without the game)
scripts/                        run_tests.lua, check_toc.lua, assert_lls_clean.lua,
                                check_compat.lua, ci_local.sh, bootstrap-tools.sh
tools/                          vendored stylua + lls (gitignored; bootstrap-tools.sh refetches)
.github/workflows/ci.yml        the gate
SPEC.md                         behavior spec, data contracts
```

## Code contracts & typing

- **EmmyLua annotations everywhere**: every public function `@param`/`@return`;
  every class `@class` + complete `@field` list covering every
  runtime-assigned field. No blank `table`/`any` annotations for values whose
  shape is knowable.
- Module pattern (dual-mode): every module registers into the
  `VersaMerchantSniper` global namespace **and** returns its table, so
  `require("VersaMerchantSniper.domain.x")` works from the repo root via the
  default `./?.lua` package.path.
- Lua 5.1 syntax only. `self` parameter may be unused in method-style modules
  (luacheck `self = false`).
- Type gate: `lua-language-server --checklevel=Warning` must report **zero**
  problems (`scripts/assert_lls_clean.lua` parses the report, fails safe).
- Outbound adapters implement their port (`---@class XAdapter : Port`);
  driving adapters consume ports via injected fields and inherit nothing.
- Boundary exceptions (untrusted input validators may keep `any`/`table`
  params) mirror the AuctiMogger contract.

## Game constraints

- The addon never calls `BuyMerchantItem`/`CloseMerchant` (engine gate on
  addon-context calls, see hard runtime facts). Buying and vendor closing
  happen via the clicker macro (`VMS.ClickerMacro`): one call per matching
  slot per press; `CloseMerchant` always fires - reopening the vendor is
  how the stock refreshes. `MERCHANT_UPDATE` is telemetry only.
- Verdict order per matched slot (filters `VMS.BuyableSlots()` and the `/vms
  debug` preview): `no-stock` → `extended-cost` → `not-purchasable` →
  `ceiling` → `unaffordable` → order. Extended-cost items are never bought.
- Fully bought entries become `done`, not deleted (the list itself is
  preserved); there is no armed/sniping mode.
- ID-first matching (`GetMerchantItemID`); name only as fallback/display.
- Duplicate adds merge into the existing entry (raise quantity).

## Gates (maximum strictness)

One command: `bash scripts/ci_local.sh` — format → lint → tests → TOC
coverage → compat manifest → type check, same as `.github/workflows/ci.yml`.

- StyLua canonical: 4 spaces, double quotes, column 120, Unix line endings;
  never hand-format. `legacy/` is excluded (`.styluaignore`).
- luacheck clean; every new game global lands in BOTH `.luacheckrc` and
  `.luarc.json` in the same change; adapters/ui surfaces must also be listed
  in the compat manifest (`scripts/check_compat.lua` fails on drift).
- Specs for all pure logic run through the repo's busted-compatible shim
  (`scripts/run_tests.lua`), locally and in CI: busted's dependency
  resolution needs the luarocks.org manifest, which outgrew LuaJIT's
  65536-constant parse limit (CI installs luacheck from direct pinned rock
  URLs for the same reason). Spec files must require the shim order: load
  dependencies before the module under test.
- In-game validation: `/console scriptErrors 1`; exercise every touched
  feature in and out of combat; taint errors surface delayed and silently.

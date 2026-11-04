# PLAN — VersaMerchantSniper addon

Turn the legacy `VersaUtils_MerchantSniper.lua` script into a proper addon with
its own UI, a hunting log, and a toggle button on the default vendor frame.
Structure and gates mirror the reference addon (`D:\Dev\WoW Goop\AuctiMogger`).

## Targets & compatibility policy

- Dual-TOC: `## Interface: 16001, 120100` — camelot beta client + retail
  Midnight, same policy as AuctiMogger.
- Other classic flavors (tbc/wrath/cata/mists) are out of scope.
- Flavor variance lives in adapters + nil-guarded compat tiers, never in
  domain code. Dump of record:
  `D:\Dev External\Blizzard\1.60.1.70634\BlizzardInterfaceCode`
  (on this client `Vanilla\MerchantFrame` loads; retail loads
  `[Family]\` = Mainline).

## Fixed decisions

1. Dual target (see above). 2. Maximum-strictness gates. 3. Hexagonal-lite
architecture. 4. NO purchase loop: one `BuyMerchantItem` call per tracked
entry per visit, exactly like the old script. 5. Global (account-wide)
SavedVariables for both list and log. 6. Auto-close the merchant after a
visit only while sniping is armed. 7. Keep `VersaMerchantSniper` / `VMS`
namespace, addon folder name, and the old `/run` API surface.

## Runtime facts (dump-verified)

| Fact | Evidence |
| --- | --- |
| `BuyMerchantItem(index, qty)` is a plain API — not protected, no hardware-event requirement | Blizzard calls it from a `MERCHANT_UPDATE` handler (`MerchantItemBuybackButton_OnLoad`, SplitStack) and StaticPopup accept callbacks, both flavors; the legacy script bought from `MERCHANT_SHOW` context in production |
| Shared merchant reads exist on both flavors: `GetMerchantNumItems`, `GetMerchantItemID`, `GetMerchantItemMaxStack`, `GetMerchantItemLink` | Used by both `Vanilla/` and `Mainline/MerchantFrame.lua` |
| The item-info read is flavor-split: `C_MerchantFrame.GetItemInfo(index) -> MerchantItemInfo` struct (`price`, `stackCount`, `numAvailable`, `hasExtendedCost`, `currencyID`, `isPurchasable`, `isUsable`; `name` nilable) on Mainline — the positional `GetMerchantItemInfo` global is gone there; vanilla-era builds keep the global | Mainline `MerchantFrame_UpdateMerchantInfo` reads the namespace; `Vanilla/MerchantFrame.lua:200` reads the global; `Blizzard_APIDocumentationGenerated/MerchantFrameDocumentation.lua` |
| Events: `MERCHANT_SHOW`, `MERCHANT_CLOSED`, `MERCHANT_UPDATE`, `MERCHANT_FILTER_ITEM_UPDATE` | same |
| `MerchantFrame` inherits `ButtonFrameTemplate` → `parentKey="CloseButton"` (`$parentCloseButton`) on BOTH flavors; frame is not protected; parenting a child is safe | `Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml` (`ButtonFrameBaseTemplate`), both MerchantFrame.xml |
| `PanelTabButtonTemplate`, `UIPanelButtonTemplate`, portrait+NineSlice window construction all work on the beta client; UISpecialFrames frames are swept by the panel manager on every managed-window close (`CloseWindows` → `CloseSpecialWindows`) — do not use it for windows that must outlive vendor panels | AuctiMogger `ui/gui.lua` runs in production on this client; `Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua` |
| Vendors' stock changes are visible only via an open merchant session; per decision #4 stock is treated as refreshed on re-open | game constraint |
| SavedVariables flush only on logout/reload | AuctiMogger AGENTS.md runtime fact |

Note on decision #4: hardware input is NOT required for `BuyMerchantItem`
(see table); the no-loop rule is adopted as policy anyway — one attempt per
visit, no retry, no re-scan-triggered buying.

## Architecture (hexagonal-lite, AuctiMogger contract)

Dependency direction, strictly one-way: `adapters (in/out) -> ports -> domain
-> (nothing)`. `domain/` and `ports/` reference NO game globals
(luacheck-enforced per folder); `adapters/` and `ui/` carry explicit game
global allowlists (`.luacheckrc`); `bootstrap.lua` is the composition root
and loads last; construction deferred to `ADDON_LOADED` (SavedVariables).

## Repo layout

```
VersaMerchantSniper/            deployable addon folder (symlink into AddOns)
  VersaMerchantSniper.toc       ## Interface: 16001, 120100
                                ## SavedVariables: VersaMerchantSniperDB
                                load order: domain -> ports -> core -> outbound -> inbound -> ui -> bootstrap
  domain/
    types.lua                   TrackedEntry / VisitRecord / Settings schemas + boundary validators
    money.lua                   copper math + format/parse (adapted from AuctiMogger, pure)
    purchase.lua                visit scan + buy math: match resolution, clamping, verdicts (pure)
    debug_dump.lua              /vms debug rendering: entry lines, stock lines, verdict preview (pure)
    snipe_log.lua               visit ring buffer + per-item aggregates (pure)
    core.lua                    SnipingCore: visit flow, clicker plan (buyableSlots), macro bookkeeping, narration
  ports/
    inbound.lua                 ControlPort, MerchantFeedPort, ClockPort (@meta only)
    outbound.lua                MerchantQueryPort, LogStorePort, NameLookupPort, AlertPort (@meta only)
  adapters/outbound/
    merchant_api.lua            stock snapshot + money + link reads (compat CORE tier)
    clock.lua                   GetTime()/time()/date() wrappers (injectable fake in specs)
    db.lua                      SavedVariables anchor + validation + defaults
    activity_log.lua            LogStorePort over DB (ring prune, aggregate updates)
    name_lookup.lua             cache-first item name resolution (C_Item.GetItemInfo)
    alert_chat.lua              prefixed chat lines; verbose gate
  adapters/inbound/
    merchant_feed.lua           MERCHANT_SHOW/CLOSED/UPDATE frame -> snapshot -> core
    slash.lua                   /vms commands
    clicker_api.lua             clicker macro surface (VMS.ClickerMacro, BuyableSlots, RecordBuys)
    compat.lua                  tiered global manifest (CORE/GUI/PROBE) + probe, adapted from AuctiMogger
  ui/
    gui.lua                     window (portrait + 3 tabs: List / Log / Settings), merchant toggle button
    table_view.lua              shared table renderer (adapted)
    feed_rows.lua               pooled log-row viewport, no ScrollBox (adapted)
    entry_input.lua             paste parsing: item link / bare id / `x<qty>` / `max <money>` tokens
  bootstrap.lua                 composition root (last)
legacy/                         old script kept for reference
spec/                           busted specs for every domain module + entry_input
scripts/                        run_tests.lua, check_toc.lua, assert_lls_clean.lua, check_compat.lua,
                                ci_local.sh, bootstrap-tools.sh
tools/                          vendored stylua + lls binaries, wsl-rocks (copied from AuctiMogger)
.github/workflows/ci.yml        format -> lint -> tests -> TOC -> compat -> type check
AGENTS.md                       project rules (records dump path + this contract)
README.md                       usage + compatibility policy
.gitignore
```

## Data contracts

```lua
---@class TrackedEntry
---@field key string                 -- "id:<n>" or "name:<s>", stable identity
---@field itemID number|nil          -- primary match key (nil => name match)
---@field name string|nil            -- display + fallback match key
---@field quantity number            -- remaining to buy
---@field quantityInitial number
---@field stopOnSuccess boolean
---@field enabled boolean
---@field priceCeiling number|nil    -- copper; nil = no ceiling
---@field status string              -- "active" | "done"
---@field stats EntryStats

---@class EntryStats
---@field lastSeen number|nil        -- time() of last sighting (any visit)
---@field lastSeenVendor string|nil
---@field lastSeenZone string|nil
---@field lastSeenCount number|nil   -- numAvailable at last sighting
---@field visitsSeen number
---@field visitsMissed number
---@field boughtTotal number
---@field spentTotal number          -- copper

---@class VisitRecord
---@field t number                   -- time()
---@field kind string                -- "arm"|"disarm"|"visit"|"buy"|"blocked"|"notfound"|"closed"
---@field vendor string|nil          -- UnitName("npc")
---@field zone string|nil            -- GetZoneText / GetSubZoneText
---@field itemKey string|nil
---@field quantity number|nil        -- bought qty (or wanted, for blocked)
---@field price number|nil           -- unit price
---@field spent number|nil
---@field note string|nil            -- verdict reason fragment

---@class VMSSettings
---@field verbose boolean            -- old Debug-style scan chatter, default false
---@field defaultQuantity number     -- default 1
---@field defaultStopOnSuccess boolean -- default true
---@field logSize number             -- ring size, default 300
```

`VersaMerchantSniperDB` = `{ version, settings, list: TrackedEntry[], log:
VisitRecord[] }` — account-wide (`SavedVariables`), validated on load
(`domain/types.lua`), invalid records dropped with a chat warning.

## Behavior spec

Visit pipeline (MERCHANT_SHOW - observation only; there is no armed mode):

1. Build snapshot of slots `1..GetMerchantNumItems()` — id, name, price,
   numAvailable, maxStack, hasExtendedCost, isPurchasable.
2. Match: ID first (`GetMerchantItemID`), name fallback for entries without
   an ID; first entry per slot wins, one slot per entry; nil names skipped.
3. Stats: `lastSeen*` updates on ANY sighting; misses counted for
   matched-nothing entries; a per-visit row lands in the ring.
4. `MERCHANT_UPDATE` is TELEMETRY ONLY. `MERCHANT_CLOSED` is telemetry.

The addon NEVER calls `BuyMerchantItem`/`CloseMerchant` (live Midnight
refuses purchase calls whose stack passes through addon frames). Buying is
the clicker macro (see Slash + clicker API): `VMS.BuyableSlots()` returns the
slots whose tracked match resolves to ORDER (verdicts below), the chunk buys
one unit per slot and closes the vendor when something was bought, and
`VMS.RecordBuys(bought)` does the bookkeeping: `stopOnSuccess` decrements
quantity; at 0 the entry flips to `status = "done"` (kept visible in the
list UI, excluded from matching) — the list itself is preserved.

Verdicts per matched slot (in order — used by `BuyableSlots` and the `/vms
debug` preview):
   `no-stock` (numAvailable == 0), `extended-cost` (hasExtendedCost —
   never bought), `not-purchasable` (isPurchasable false —
   Blizzard's buy gate), `ceiling` (unit price > priceCeiling),
   `unaffordable` (price * qty > GetMoney — skip, no partial buy),
   otherwise ORDER: buy `qty = min(quantity, maxStack, numAvailable > 0 and
   numAvailable or quantity)` — one call per slot, no loop
   (`numAvailable == -1` = unlimited).

Duplicate adds merge: same key raises quantity instead of creating a second
entry (old script allowed duplicates; intentional change).

Editing (list tab): alt+click a row loads it into the input row (identity
plus `max`/`nostop` tokens, quantity box) and flips Add to Update. Applying
updates the entry in place and restarts its want cycle: quantity and the
initial baseline reset to the request, the entry re-arms, and the
bought/spent counters zero - sightings and visit counters survive (only the
counting restarts). A swapped identity or rejected input falls through to a
plain add; a blank item box (or Esc) cancels the edit. The quantity box is
the GUI's quantity surface (1 default) and wins over any `x<qty>` token in
the text; the slash path keeps the `x<qty>` spelling.

## UI spec

- Window: portrait + NineSlice frame (AuctiMogger construction), ESC-close
  via `UISpecialFrames`, movable, clamped. Tabs: **List**, **Log**,
  **Settings**.
- List tab: entry input (paste item link / bare ID / name; optional `max
  <money>`, `stop`/`nostop` tokens) + quantity-to-buy box (1 default) +
  Add/Update button; alt+click a row to edit it in place, right-click to
  remove; columns: Item | Want | Ceiling | Last seen | Stop | Status. Status
  line ("Tracking N items - X active, Y done").
- Log tab: pooled rows (time, kind, item, vendor, zone, qty, price, note);
  Clear-log button; newest first.
- Settings tab: verbose, defaultQuantity, defaultStopOnSuccess, logSize,
  Clear log + the clicker buyout macro box (self-healing copy source:
  focus selects all, edits snap back; text is `VMS.ClickerMacro`).
- Merchant toggle button: lazy `ensure` on every `MERCHANT_SHOW` (+ first
  attempt at build/`PLAYER_LOGIN`), parented to `MerchantFrame`, anchored
  `RIGHT` of `MerchantFrame.CloseButton` (fallback `rawget(_G,
  "MerchantFrameCloseButton")`, then fixed TOPRIGHT), `SetFrameLevel(+100)`,
  tooltip, opens/closes the window (AuctiMogger pattern, lines 492–546).

## Slash + clicker API

`/vms status | add <link|id> [x<qty>] [max <money>] [nostop|stop] |
remove <n|id|name> | list | log [n] | clearlog | verbose | debug | help`.
`debug` dumps the tracked list and a live stock scan with a verdict preview
(the same resolve/decide `VMS.BuyableSlots()` takes; it never buys). The
legacy sniping toggle (`StartSniping`/`StopSniping`/`TryStopSniping`) is
REMOVED - there is no armed mode. The buy surface is a self-contained
clicker macro: the engine refuses ANY `BuyMerchantItem` call whose stack
passes through addon frames (live 12.1.5 - verified: the same call succeeds
from the `/run` chunk and fails through one wrapper function), so the macro
does pure Blizzard reads + buys inside the chunk and only hands the bought
counts to the addon:
`/run local b={} local s=VMS.BuyableSlots() for _,x in ipairs(s) do
BuyMerchantItem(x.index,1) b[x.itemID]=(b[x.itemID] or 0)+1 end if
next(b)~=nil then CloseMerchant() end VMS.RecordBuys(b)`.
`BuyableSlots()` is the order-verdict plan (stock, no extended cost,
purchasable, within ceiling, affordable, itemID-backed); `RecordBuys(b)`
decrements, completes stop-on-success entries, narrates and logs; the macro
closes the vendor window when something was bought. Canonical text is
`VMS.ClickerMacro`, shown on the Settings tab as a self-healing copy box.
The legacy `/run` item-macro helpers (`SnipeItemByID`, `SnipeItemByName`,
`PrintItemsToBuy`, `WantedIDs`, the `Buyout()` stub) were removed with the
sniping mode - entry management lives in `/vms` + the GUI; the clicker
surface above is the whole `/run` API.

## Gates (maximum strictness)

Copied/adapted from AuctiMogger: `.luacheckrc` (per-folder game-global
allowlists; domain/ports forbidden), `.luarc.json` (LLS `--checklevel=
Warning`, zero problems), vendored `tools/stylua` + `tools/lls`,
`tools/wsl-rocks` (offline pinned luacheck/busted), `scripts/check_toc.lua`,
`scripts/assert_lls_clean.lua`, `scripts/check_compat.lua` (compat manifest
in sync with allowlists), `scripts/ci_local.sh` (one-command local parity),
`.github/workflows/ci.yml`. StyLua canonical: 4 spaces, double quotes,
column 120, Unix line endings. Busted specs for all pure modules; every new
game global lands in BOTH `.luacheckrc` and `.luarc.json` in the same change.

## Phases

1. **Scaffold + harness**: repo tree above, TOC stubs, harness copied,
   legacy script moved to `legacy/`, `git init`. Gate: `ci_local.sh` green
   on stubs.
2. **Domain + specs**: `types`, `money`, `purchase`, `snipe_log` + busted
   specs (injected clock; verdict table; clamp math; ring prune;
   aggregates). Gate: domain pure (luacheck), tests green, LLS clean.
3. **Ports + outbound adapters**: contracts, `compat` tiers, `merchant_api`,
   `clock`, `db`, `activity_log`, `name_lookup`, `alert_chat`.
4. **Core + inbound**: `core.lua` flow + `merchant_feed`, `slash`,
   `clicker_api`. Gate: full lint/type pass.
5. **UI**: `gui` (window, tabs, merchant button), `table_view`, `feed_rows`,
   `entry_input`, `bootstrap.lua` wiring. Gate: TOC coverage + full gates.
6. **In-game validation** (both clients where possible): `/console
   scriptErrors 1`; clicker macro buys + closes the vendor; observation
   visit rows + stats log correctly; stats and log survive reload;
   ESC-close; toggle button; `/vms` + clicker API; buyback tab and paging
   merchants.

## Behavior changes vs the legacy script

- ID-first matching; name match only for entries without an ID.
- Duplicates merge instead of stacking duplicate entries.
- `TryStopSniping` no longer destructively clears the list — entries become
  `done`, the list is preserved for the UI; disarm is automatic when all
  done.
- Money, ceiling and extended-cost guards added (old script bought blindly).
- Debug chatter off by default (`verbose`), results always reported.
- List + log persist across sessions (old script had no persistence).
- Automatic buying removed: live Midnight refuses purchases from any call
  passing through addon frames - buying is the clicker macro
  (`VMS.ClickerMacro`); vendor visits are observation-only.

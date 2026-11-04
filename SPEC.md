# SPEC — VersaMerchantSniper addon

Behavior spec and data contracts — WHAT the addon does. HOW changes are made
(rules, structure, gates, runtime facts) lives in `AGENTS.md`.

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
---@field defaultPriceCeiling number -- default unit buyout limit, copper (100g); 0 = no limit
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
3. Stats: `lastSeen*` updates on ANY sighting, for EVERY tracked entry -
   done and disabled included (presence record: "last time the item was on
   an opened vendor"); misses counted only for active entries; a per-visit
   row lands in the ring.
4. `MERCHANT_UPDATE` is TELEMETRY ONLY. `MERCHANT_CLOSED` is telemetry.

The addon NEVER calls `BuyMerchantItem`/`CloseMerchant` (live Midnight
refuses purchase calls whose stack passes through addon frames). Buying is
the clicker macro (see Slash + clicker API): `VMS.BuyableSlots()` returns the
slots whose tracked match resolves to ORDER (verdicts below), the chunk buys
one unit per slot, books the counts, and ALWAYS closes the vendor - stock
only refreshes on open, so a dry press still closes for the next scan - and
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

Entry defaults: an entry added WITHOUT an explicit `max <money>` takes the
settings' default buyout limit (`defaultPriceCeiling`, default 100g; 0 = no
limit). An explicit `max 0` always means "no ceiling" - the list-tab edit
flow emits `max 0` for limit-less entries so an update round-trips them
unchanged.

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

- Window: portrait + NineSlice frame (AuctiMogger construction), movable,
  clamped. Tabs: **List**, **Log**, **Settings**. Starts closed on
  login/reload - `/vms` and the merchant toggle button are the only openers.
  ESC closes while the cursor is over the window (keyboard-enabled frame;
  deliberately NOT `UISpecialFrames` — the panel manager's
  `CloseSpecialWindows` sweeps those whenever a managed window like the
  vendor panel closes, which would kill the dashboard with the vendor).
- List tab: entry input (paste item link / bare ID / name; optional `max
  <money>`, `stop`/`nostop` tokens) + quantity-to-buy box (1 default) +
  Add/Update button; alt+click a row to edit it in place, right-click to
  remove; columns: Item | Want | Ceiling | Last seen | Stop | Status. Status
  line ("Tracking N items - X active, Y done").
- Log tab: pooled rows (time, kind, item, vendor, zone, qty, price, note);
  Clear-log button; newest first.
- Settings tab: verbose, defaultQuantity, defaultStopOnSuccess, default
  buyout limit (money-format box, `0` = no limit), logSize,
  Clear log + the clicker buyout macro box (self-healing copy source:
  focus selects all, edits snap back; text is `VMS.ClickerMacro`).
- Merchant toggle button: lazy `ensure` on every `MERCHANT_SHOW` (+ first
  attempt at build/`PLAYER_LOGIN`), parented to `MerchantFrame`, anchored
  `RIGHT` of `MerchantFrame.CloseButton` (fallback `rawget(_G,
  "MerchantFrameCloseButton")`, then fixed TOPRIGHT), `SetFrameLevel(+100)`,
  tooltip, opens/closes the window (AuctiMogger pattern).

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
BuyMerchantItem(x.index,1) b[x.itemID]=(b[x.itemID] or 0)+1 end
VMS.RecordBuys(b) CloseMerchant()`.
`BuyableSlots()` is the order-verdict plan (stock, no extended cost,
purchasable, within ceiling, affordable, itemID-backed); `RecordBuys(b)`
decrements, completes stop-on-success entries, narrates and logs; the macro
ALWAYS closes the vendor window — stock refreshes only on open, so the
close-then-reopen cycle is how a dry press resets the scan. Canonical text
is `VMS.ClickerMacro`, shown on the Settings tab as a self-healing copy box.
The legacy `/run` item-macro helpers (`SnipeItemByID`, `SnipeItemByName`,
`PrintItemsToBuy`, `WantedIDs`, the `Buyout()` stub) were removed with the
sniping mode - entry management lives in `/vms` + the GUI; the clicker
surface above is the whole `/run` API.

## In-game validation

`/console scriptErrors 1`; clicker macro buys + closes the vendor; observation
visit rows + stats log correctly; stats and log survive reload; ESC-close;
toggle button; `/vms` + clicker API; buyback tab and paging merchants.
Taint errors surface delayed and silently - exercise touched features in and
out of combat.

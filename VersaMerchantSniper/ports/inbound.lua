-- VersaMerchantSniper - inbound port contracts (annotations only, no
-- runtime code). Driving adapters (merchant_feed, slash, clicker_api, gui)
-- consume these; the sniping core implements them.

---@meta

--- Time source the domain and specs run on (wall-clock seconds for stat
--- stamps; session seconds for diagnostics; a label for chat lines).
---@class ClockPort
---@field now fun(): number time() seconds (persisted stat stamps)
---@field uptime fun(): number GetTime() session seconds (diagnostics only)
---@field stamp fun(): string "HH:MM:SS" wall-clock label

--- The core's driving surface for slash/clicker/GUI consumers. `raw` inputs
--- are untrusted (validators run inside the core). Purchases are NOT part
--- of this surface: the clicker macro owns them (see clicker_api).
---@class ControlPort
---@field addEntry fun(self: any, raw: any): TrackedEntry|nil, string|nil validated entry (merged on duplicate key) or failure reason
---@field updateEntry fun(self: any, key: string, raw: any): TrackedEntry|nil, string|nil in-place edit (list tab); restarts the want cycle; nil + reason on rejection or key mismatch
---@field removeEntry fun(self: any, ref: any): boolean key or 1-based list index; true when removed
---@field buyableSlots fun(self: any): {index: number, itemID: number}[] slots the clicker macro may buy (order verdict, itemID-backed)
---@field recordBuys fun(self: any, bought: table<number, number>|nil): nil clicker bookkeeping after a macro buyout (no engine calls)
---@field entries fun(self: any): TrackedEntry[] the persisted list, list order
---@field statusLine fun(self: any): string one-line tracking summary
---@field settings fun(self: any): VMSSettings
---@field setSetting fun(self: any, field: string, value: any): boolean, string|nil accepted or rejected with reason
---@field toggleVerbose fun(self: any): boolean the new verbose value
---@field ring fun(self: any): VisitRecord[] newest first
---@field clearLog fun(self: any): nil

--- The merchant event sink the feed adapter calls; the core implements it.
---@class MerchantFeedPort
---@field onMerchantShow fun(self: any, vendor: string|nil, zone: string|nil): nil a vendor session opened (snapshot+decide+execute tick)
---@field onMerchantClosed fun(self: any): nil the session ended (telemetry)
---@field onMerchantUpdate fun(self: any): nil stock-change telemetry while open (never a purchase trigger)

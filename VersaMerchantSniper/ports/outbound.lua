-- VersaMerchantSniper - outbound port contracts (annotations only, no
-- runtime code). Outbound adapters implement these; the core consumes the
-- injected instances. Port method `self` is any by house style.

---@meta

--- Read-only merchant surface (the legacy FrameXML globals - dump-verified
--- on both target flavors). The addon NEVER buys or closes: live Midnight
--- refuses BuyMerchantItem calls whose stack passes through addon frames,
--- so purchases live in the clicker macro (VMS.ClickerMacro, clicker_api).
---@class MerchantQueryPort
---@field snapshot fun(self: any): MerchantSlot[] stock rows for slots 1..GetMerchantNumItems()
---@field money fun(self: any): number copper on hand (huge when the API is absent: the gate never blocks)
---@field linkFor fun(self: any, index: number): string|nil item link for a slot index (nil when unavailable)

--- Visit-row store over the persisted DB (newest-first ring).
---@class LogStorePort
---@field appendVisit fun(self: any, record: VisitRecord)
---@field ring fun(self: any): VisitRecord[]
---@field clear fun(self: any): nil

--- Best-effort item identity resolution; never throws, never gates.
---@class NameLookupPort
---@field nameFor fun(self: any, itemID: number): string|nil
---@field iconFor fun(self: any, itemID: number): number|nil
---@field linkFor fun(self: any, itemID: number): string|nil

--- Chat narration: result lines always print; verbose lines honor the
--- setting read live from the DB.
---@class AlertPort
---@field say fun(self: any, text: string)
---@field verbose fun(self: any, text: string)

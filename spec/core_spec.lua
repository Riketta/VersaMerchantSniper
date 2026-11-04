-- Core binds Purchase/SnipeLog/Types off the shared namespace at load time,
-- so the requires below ARE the load order: busted discovers files
-- alphabetically and runs this file first, with no other spec having
-- loaded them yet.
local Types = require("VersaMerchantSniper.domain.types")
require("VersaMerchantSniper.domain.purchase")
require("VersaMerchantSniper.domain.snipe_log")
local ActivityLog = require("VersaMerchantSniper.adapters.outbound.activity_log")
local Core = require("VersaMerchantSniper.domain.core")

--- Valid entry builder for the specs.
---@param fields table
---@return TrackedEntry
local function entry(fields)
    return assert(Types.validateEntry(fields))
end

--- Merchant slot builder with the adapter's defaults (unlimited stock,
--- purchasable, maxStack 20, price 0).
---@param fields table|nil
---@return MerchantSlot
local function slot(fields)
    local f = fields or {}
    return {
        index = f.index or 1,
        itemID = f.itemID,
        name = f.name,
        price = f.price or 0,
        stackCount = f.stackCount or 1,
        numAvailable = f.numAvailable == nil and -1 or f.numAvailable,
        maxStack = f.maxStack or 20,
        hasExtendedCost = f.hasExtendedCost == true,
        isPurchasable = f.isPurchasable ~= false,
    }
end

--- Builds a core over pure fakes plus the real (pure) ActivityLog store.
--- opts: slots, money (copper on the fake query), entry (pre-seeded tracked
--- entry), now (initial clock time).
---@param opts table|nil
---@return SnipingCore
---@return table harness with snapshots/alerts/shape/setTime
local function makeCore(opts)
    opts = opts or {}
    local shape = Types.validateDB(nil)
    if opts.entry ~= nil then
        shape.list[1] = opts.entry
    end
    local db = {
        get = function()
            return shape
        end,
    }
    local store = ActivityLog.new(db)

    local querySnapshots = 0
    local moneyLeft = opts.money or 0
    local query = {
        snapshot = function()
            querySnapshots = querySnapshots + 1
            return opts.slots or {}
        end,
        money = function()
            return moneyLeft
        end,
        linkFor = function()
            return nil
        end,
    }
    local alerts = {
        lines = {},
        say = function(self, text)
            self.lines[#self.lines + 1] = text
        end,
        verbose = function() end,
    }
    local clockNow = opts.now or 1000
    local clock = {
        now = function()
            return clockNow
        end,
        uptime = function()
            return 0
        end,
        stamp = function()
            return "00:00:00"
        end,
    }
    local core = Core.new({ query = query, store = store, alerts = alerts, clock = clock, db = db })
    return core,
        {
            snapshots = function()
                return querySnapshots
            end,
            alerts = alerts,
            shape = shape,
            setTime = function(value)
                clockNow = value
            end,
        }
end

describe("SnipingCore", function()
    it("the visit tick is observation-only: sightings, misses, no purchases", function()
        local e = entry({ itemID = 4357, quantity = 3 })
        local core = makeCore({ slots = { slot({ itemID = 4357, price = 100, numAvailable = 5 }) }, entry = e })
        core:onMerchantShow("Osli Menet", "Stormwind City")
        assert.equals(3, e.quantity) -- untouched: buying is the macro's job
        assert.equals(1, e.stats.visitsSeen)
        assert.equals(0, e.stats.boughtTotal)
        local ring = core:ring()
        assert.equals(1, #ring)
        assert.equals("visit", ring[1].kind)
        assert.equals(true, (ring[1].note or ""):find("1 matched", 1, true) ~= nil)
    end)

    it("counts no-stock as a sighting without a purchase", function()
        local e = entry({ itemID = 4357, quantity = 2 })
        local core = makeCore({ slots = { slot({ itemID = 4357, price = 50, numAvailable = 0 }) }, entry = e })
        core:onMerchantShow("Vendor", nil)
        assert.equals(1, e.stats.visitsSeen)
        assert.equals(0, e.stats.lastSeenCount)
        assert.equals(2, e.quantity)
    end)

    it("never scans on MERCHANT_UPDATE", function()
        local core, h = makeCore({})
        core:addEntry({ itemID = 4357 })
        core:onMerchantUpdate()
        assert.equals(0, h.snapshots())
    end)

    it("buyableSlots returns order-verdict slots with IDs", function()
        local e = entry({ itemID = 4357, quantity = 2 })
        local core = makeCore({ slots = { slot({ itemID = 4357, price = 100, index = 3 }) }, money = 1000, entry = e })
        local plan = core:buyableSlots()
        assert.equals(1, #plan)
        assert.equals(3, plan[1].index)
        assert.equals(4357, plan[1].itemID)
    end)

    it("buyableSlots filters held matches and unknown ids", function()
        local e = entry({ itemID = 4357, quantity = 2, priceCeiling = 50 })
        local core = makeCore({
            slots = {
                slot({ itemID = 4357, price = 100, index = 1 }), -- over ceiling: held
                slot({ itemID = 4358, price = 10, index = 2, hasExtendedCost = true }), -- not tracked
            },
            money = 1000,
            entry = e,
        })
        assert.equals(0, #core:buyableSlots())
    end)

    it("counts misses for unmatched active entries", function()
        local e = entry({ itemID = 4357, quantity = 2 })
        local core = makeCore({ slots = { slot({ itemID = 999 }) }, entry = e })
        core:onMerchantShow("Vendor", nil)
        assert.equals(1, e.stats.visitsMissed)
        assert.equals(nil, e.stats.lastSeen)
        local ring = core:ring()
        assert.equals(true, ring[1].note:find("1 missed", 1, true) ~= nil)
    end)

    it("records presence for done and disabled entries without hunting them", function()
        local core, h = makeCore({
            slots = { slot({ itemID = 6052, index = 1 }), slot({ itemID = 9305, index = 2 }) },
        })
        local done = entry({ itemID = 6052 })
        done.status = "done"
        done.enabled = false
        local disabled = entry({ itemID = 9305 })
        disabled.enabled = false
        local active = entry({ itemID = 4357 })
        h.shape.list[1] = done
        h.shape.list[2] = disabled
        h.shape.list[3] = active
        core:onMerchantShow("Innkeeper", "Stormwind")
        -- Presence: last seen updates for every tracked entry, active or not.
        assert.equals(1, done.stats.visitsSeen)
        assert.equals(1, disabled.stats.visitsSeen)
        assert.is_true(done.stats.lastSeen ~= nil)
        assert.equals("Innkeeper", done.stats.lastSeenVendor)
        -- Hunting: no miss counters for entries out of the hunt.
        assert.equals(0, done.stats.visitsMissed)
        assert.equals(0, disabled.stats.visitsMissed)
        assert.equals(1, active.stats.visitsMissed) -- 4357 was not in stock
    end)

    it("statusLine summarizes tracking without armed state", function()
        local core, h = makeCore({ entry = entry({ itemID = 4357, quantity = 1 }) })
        local done = entry({ itemID = 1936, quantity = 1 })
        done.status = "done"
        done.enabled = false
        h.shape.list[2] = done
        assert.equals("Tracking 2 items - 1 active, 1 done.", core:statusLine())
    end)

    it("addEntry merges duplicates", function()
        local core, h = makeCore({})
        local first = core:addEntry({ itemID = 4357, quantity = 2 })
        local merged = core:addEntry({ itemID = 4357, quantity = 2 })
        assert.equals(1, #h.shape.list)
        assert.equals(4, h.shape.list[1].quantity)
        assert.equals(first, merged)
    end)

    it("updateEntry replaces config in place and restarts the want cycle", function()
        local core, h = makeCore({})
        local original = core:addEntry({ itemID = 4357, quantity = 2, name = "Silk Cloth" })
        core:recordBuys({ [4357] = 1 }) -- one unit bought: want x1/2, bought counter 1
        local updated, reason = core:updateEntry("id:4357", { itemID = 4357, quantity = 3, priceCeiling = 500 })
        assert.equals(nil, reason)
        assert.equals(original, updated) -- in place: the same table object
        assert.equals(1, #h.shape.list)
        assert.equals(3, h.shape.list[1].quantity)
        assert.equals(3, h.shape.list[1].quantityInitial)
        assert.equals(500, h.shape.list[1].priceCeiling)
        assert.equals("active", h.shape.list[1].status)
        assert.equals(0, h.shape.list[1].stats.boughtTotal)
        assert.equals("Silk Cloth", h.shape.list[1].name) -- bare-ID edit keeps the known name
    end)

    it("updateEntry re-arms a done entry and honors the stop flag", function()
        local core = makeCore({})
        local tracked = assert(core:addEntry({ itemID = 4357, quantity = 1, stopOnSuccess = true }))
        core:recordBuys({ [4357] = 1 }) -- stop-on-success completes the entry
        assert.equals("done", tracked.status)
        assert.is_false(tracked.enabled)
        local updated = core:updateEntry("id:4357", { itemID = 4357, quantity = 2, stopOnSuccess = false })
        assert.equals(tracked, updated)
        assert.equals("active", tracked.status)
        assert.is_true(tracked.enabled)
        assert.is_false(tracked.stopOnSuccess)
        assert.equals(2, tracked.quantity)
    end)

    it("updateEntry refuses mismatches, bad input and unknown keys untouched", function()
        local core, h = makeCore({})
        local original = assert(core:addEntry({ itemID = 4357, quantity = 2, priceCeiling = 100 }))
        local a, mismatch = core:updateEntry("id:4357", { itemID = 6052 })
        assert.equals(nil, a)
        assert.equals("key-mismatch", mismatch)
        local b, invalid = core:updateEntry("id:4357", { itemID = 4357, quantity = 0 })
        assert.equals(nil, b)
        assert.equals("bad-quantity", invalid)
        local c, unknown = core:updateEntry("id:6052", { itemID = 6052, quantity = 1 })
        assert.equals(nil, c)
        assert.equals("not-tracked", unknown)
        assert.equals(2, original.quantity)
        assert.equals(100, original.priceCeiling)
        assert.equals(1, #h.shape.list)
    end)

    it("removeEntry works by index, key and name", function()
        local core, h = makeCore({})
        h.shape.list[1] = entry({ itemID = 4357, name = "Silk Cloth" })
        h.shape.list[2] = entry({ itemID = 9999, name = "Wool Cloth" })
        assert.is_true(core:removeEntry(2)) -- by index
        assert.is_true(core:removeEntry("id:4357")) -- by key
        h.shape.list[1] = entry({ itemID = 111, name = "Linen Cloth" })
        assert.is_true(core:removeEntry("Linen Cloth")) -- by name
        assert.equals(0, #h.shape.list)
        assert.is_false(core:removeEntry("id:1"))
        assert.is_false(core:removeEntry(3))
    end)

    it("setSetting validates, clamps and prunes", function()
        local core, h = makeCore({ entry = entry({ itemID = 4357 }) })
        assert.is_false(core:setSetting("logSize", 5))
        assert.is_true(core:setSetting("logSize", 5000))
        assert.equals(2000, h.shape.settings.logSize)
        assert.is_false(core:setSetting("nope", 1))
        assert.is_true(core:setSetting("verbose", true))
        assert.is_true(h.shape.settings.verbose)
    end)
end)

describe("SnipingCore.recordBuys", function()
    it("decrements, completes stop-on-success entries and narrates", function()
        local e = entry({ itemID = 4357 })
        local core, h = makeCore({ entry = e })
        core:recordBuys({ [4357] = 1 })
        assert.equals(0, e.quantity)
        assert.equals("done", e.status)
        assert.equals(1, e.stats.boughtTotal)
        assert.equals(1, #h.alerts.lines)
        assert.equals("buy", h.shape.log[1].kind)
    end)

    it("clamps to the remaining want and ignores unknown ids", function()
        local e = entry({ itemID = 4357, quantity = 2, stopOnSuccess = false })
        local core = makeCore({ entry = e })
        core:recordBuys({ [4357] = 5, [9999] = 3 })
        assert.equals(0, e.quantity)
        assert.equals("active", e.status)
        assert.equals(2, e.stats.boughtTotal)
    end)

    it("ignores nil and empty input", function()
        local e = entry({ itemID = 4357 })
        local core, h = makeCore({ entry = e })
        core:recordBuys(nil)
        core:recordBuys({})
        assert.equals(1, e.quantity)
        assert.equals(0, #h.shape.log)
    end)
end)

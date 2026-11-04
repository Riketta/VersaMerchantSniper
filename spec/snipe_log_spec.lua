local Types = require("VersaMerchantSniper.domain.types")
local Log = require("VersaMerchantSniper.domain.snipe_log")

--- Valid entry builder for the specs.
---@param fields table
---@return TrackedEntry
local function entry(fields)
    return assert(Types.validateEntry(fields))
end

describe("SnipeLog", function()
    describe("visit counters", function()
        it("records sightings with the last-seen block", function()
            local e = entry({ itemID = 4357 })
            Log.noteSighting(e, 3, 250, "Osli Menet", "Stormwind City: Old Town")
            assert.equals(250, e.stats.lastSeen)
            assert.equals("Osli Menet", e.stats.lastSeenVendor)
            assert.equals("Stormwind City: Old Town", e.stats.lastSeenZone)
            assert.equals(3, e.stats.lastSeenCount)
            assert.equals(1, e.stats.visitsSeen)
            assert.equals(0, e.stats.visitsMissed)
        end)

        it("records misses without touching the last-seen block", function()
            local e = entry({ itemID = 4357 })
            Log.noteSighting(e, 1, 100, "Vendor", "Zone")
            Log.noteMiss(e)
            Log.noteMiss(e)
            assert.equals(100, e.stats.lastSeen)
            assert.equals(1, e.stats.visitsSeen)
            assert.equals(2, e.stats.visitsMissed)
        end)
    end)

    describe("agoLabel", function()
        it("returns nil for nil stamps and future stamps", function()
            assert.equals(nil, (Log.agoLabel(nil, 1000)))
            assert.equals(nil, (Log.agoLabel(2000, 1000)))
        end)

        it("renders just now under a minute", function()
            assert.equals("just now", Log.agoLabel(1000, 1000))
            assert.equals("just now", Log.agoLabel(950, 1000))
        end)

        it("renders minutes, hours and days", function()
            assert.equals("1m ago", Log.agoLabel(940, 1000)) -- delta 60
            assert.equals("59m ago", Log.agoLabel(-2599, 1000)) -- delta 3599
            assert.equals("1h ago", Log.agoLabel(-2600, 1000)) -- delta 3600
            assert.equals("23h ago", Log.agoLabel(-85399, 1000)) -- delta 86399
            assert.equals("1d ago", Log.agoLabel(-85400, 1000)) -- delta 86400
            assert.equals("45d ago", Log.agoLabel(1000 - 45 * 86400, 1000))
        end)
    end)

    describe("purchase stats", function()
        it("accumulates lifetime totals", function()
            local e = entry({ itemID = 4357 })
            Log.notePurchase(e, 2, 300)
            assert.equals(2, e.stats.boughtTotal)
            assert.equals(300, e.stats.spentTotal)
            Log.notePurchase(e, 1, 100)
            assert.equals(3, e.stats.boughtTotal)
            assert.equals(400, e.stats.spentTotal)
        end)
    end)

    describe("ring", function()
        it("appends newest-first", function()
            local ring = {}
            Log.append(ring, Log.makeVisit("visit", 100), 10)
            Log.append(ring, Log.makeVisit("buy", 200), 10)
            assert.equals(2, #ring)
            assert.equals("buy", ring[1].kind)
            assert.equals("visit", ring[2].kind)
        end)

        it("prunes the oldest rows past max", function()
            local ring = {}
            Log.append(ring, Log.makeVisit("visit", 100), 2)
            Log.append(ring, Log.makeVisit("visit", 200), 2)
            Log.append(ring, Log.makeVisit("visit", 300), 2)
            assert.equals(2, #ring)
            assert.equals(300, ring[1].t)
            assert.equals(200, ring[2].t)
        end)

        it("shrinks an oversized ring on prune", function()
            local ring = {}
            for i = 5, 1, -1 do
                ring[#ring + 1] = Log.makeVisit("visit", i) -- newest-first: ring[1].t = 5
            end
            Log.prune(ring, 3)
            assert.equals(3, #ring)
            assert.equals(5, ring[1].t) -- newest survives
            assert.equals(3, ring[3].t)
        end)
    end)

    it("builds rows that pass Types.isVisitRecord for every kind", function()
        for kind in pairs(Types.VISIT_KINDS) do
            local row = Log.makeVisit(
                kind,
                100,
                { vendor = "V", itemKey = "id:4357", quantity = 1, price = 5, spent = 5, note = "ok" }
            )
            assert.is_true(Types.isVisitRecord(row))
        end
    end)
end)

local Types = require("VersaMerchantSniper.domain.types")

describe("Types", function()
    describe("sanitizeSettings", function()
        it("returns the defaults for nil input", function()
            local s = Types.sanitizeSettings(nil)
            assert.is_false(s.verbose)
            assert.equals(1, s.defaultQuantity)
            assert.is_true(s.defaultStopOnSuccess)
            assert.equals(300, s.logSize)
        end)

        it("keeps valid values", function()
            local s = Types.sanitizeSettings({
                verbose = true,
                defaultQuantity = 4,
                defaultStopOnSuccess = false,
                logSize = 500,
            })
            assert.is_true(s.verbose)
            assert.equals(4, s.defaultQuantity)
            assert.is_false(s.defaultStopOnSuccess)
            assert.equals(500, s.logSize)
        end)

        it("falls back to defaults for wrong types", function()
            local s = Types.sanitizeSettings({
                verbose = 1,
                defaultQuantity = "abc",
                defaultStopOnSuccess = nil,
                logSize = {},
            })
            assert.is_false(s.verbose)
            assert.equals(1, s.defaultQuantity)
            assert.is_true(s.defaultStopOnSuccess)
            assert.equals(300, s.logSize)
        end)

        it("clamps logSize into 10..2000", function()
            assert.equals(10, Types.sanitizeSettings({ logSize = 1 }).logSize)
            assert.equals(2000, Types.sanitizeSettings({ logSize = 999999 }).logSize)
            assert.equals(500, Types.sanitizeSettings({ logSize = 500 }).logSize)
        end)

        it("floors and rejects non-positive defaultQuantity", function()
            assert.equals(2, Types.sanitizeSettings({ defaultQuantity = 2.7 }).defaultQuantity)
            assert.equals(1, Types.sanitizeSettings({ defaultQuantity = 0.5 }).defaultQuantity)
        end)
    end)

    describe("validateEntry", function()
        it("builds an ID entry with defaults", function()
            local e = assert(Types.validateEntry({ itemID = 4357 }))
            assert.equals("id:4357", e.key)
            assert.equals(4357, e.itemID)
            assert.equals(nil, e.name)
            assert.equals(1, e.quantity)
            assert.equals(1, e.quantityInitial)
            assert.is_true(e.stopOnSuccess)
            assert.is_true(e.enabled)
            assert.equals("active", e.status)
            assert.equals(nil, e.priceCeiling)
            assert.equals(0, e.stats.boughtTotal)
            assert.equals(0, e.stats.visitsSeen)
        end)

        it("builds a name-only entry", function()
            local e = assert(Types.validateEntry({ name = "Recipe: Frost Oil" }))
            assert.equals("name:Recipe: Frost Oil", e.key)
            assert.equals(nil, e.itemID)
            assert.equals("Recipe: Frost Oil", e.name)
        end)

        it("accepts numeric-string ids and quantities", function()
            local e = assert(Types.validateEntry({ itemID = "4357", quantity = "5" }))
            assert.equals(4357, e.itemID)
            assert.equals(5, e.quantity)
        end)

        it("applies injected defaults when the input omits fields", function()
            local defaults = Types.sanitizeSettings({ defaultQuantity = 7, defaultStopOnSuccess = false })
            local e = assert(Types.validateEntry({ itemID = 4357 }, defaults))
            assert.equals(7, e.quantity)
            assert.is_false(e.stopOnSuccess)
        end)

        it("honors an explicit stopOnSuccess=false", function()
            local e = assert(Types.validateEntry({ itemID = 4357, stopOnSuccess = false }))
            assert.is_false(e.stopOnSuccess)
        end)

        it("requires an identity", function()
            assert.equals(nil, (Types.validateEntry({})))
            assert.equals(nil, (Types.validateEntry({ name = "   " })))
            assert.equals(nil, (Types.validateEntry({ itemID = 0 })))
            assert.equals(nil, (Types.validateEntry("nope")))
            assert.equals(nil, (Types.validateEntry(nil)))
        end)

        it("rejects non-positive quantities and out-of-range ids", function()
            assert.equals(nil, (Types.validateEntry({ itemID = 4357, quantity = 0 })))
            assert.equals(nil, (Types.validateEntry({ itemID = 4357, quantity = -3 })))
            assert.equals(nil, (Types.validateEntry({ itemID = 1e15 })))
            assert.equals(nil, (Types.validateEntry({ itemID = 4357.9 })))
        end)

        it("treats a zero ceiling as no ceiling and rejects negatives", function()
            local e = assert(Types.validateEntry({ itemID = 4357, priceCeiling = 0 }))
            assert.equals(nil, e.priceCeiling)
            local kept = assert(Types.validateEntry({ itemID = 4357, priceCeiling = "500000" }))
            assert.equals(500000, kept.priceCeiling)
            assert.equals(nil, (Types.validateEntry({ itemID = 4357, priceCeiling = -5 })))
        end)
    end)

    describe("mergeQuantity", function()
        it("raises the quantities and re-activates done entries", function()
            local base = assert(Types.validateEntry({ itemID = 4357, quantity = 2 }))
            local add = assert(Types.validateEntry({ itemID = 4357, quantity = 3 }))
            Types.mergeQuantity(base, add)
            assert.equals(5, base.quantity)
            assert.equals(5, base.quantityInitial)
            base.status = "done"
            base.enabled = false
            Types.mergeQuantity(base, add)
            assert.equals("active", base.status)
            assert.is_true(base.enabled)
            assert.equals(8, base.quantity)
        end)
    end)

    describe("applyUpdate", function()
        it("swaps config, resets the want cycle and zeroes bought/spent counters", function()
            local base = assert(Types.validateEntry({ itemID = 4357, quantity = 2, stopOnSuccess = true }))
            base.status = "done"
            base.enabled = false
            base.stats.boughtTotal = 5
            base.stats.spentTotal = 1234
            local update =
                assert(Types.validateEntry({ itemID = 4357, quantity = 3, stopOnSuccess = false, priceCeiling = 500 }))
            Types.applyUpdate(base, update)
            assert.equals(3, base.quantity)
            assert.equals(3, base.quantityInitial)
            assert.is_false(base.stopOnSuccess)
            assert.equals(500, base.priceCeiling)
            assert.equals("active", base.status)
            assert.is_true(base.enabled)
            assert.equals(0, base.stats.boughtTotal)
            assert.equals(0, base.stats.spentTotal)
        end)

        it("keeps sightings and visit counters, refreshes the name only when given", function()
            local base = assert(Types.validateEntry({ itemID = 4357, name = "Silk Cloth", quantity = 1 }))
            base.stats.lastSeen = 99
            base.stats.lastSeenVendor = "Innkeeper"
            base.stats.visitsSeen = 3
            base.stats.visitsMissed = 7
            -- Bare-ID update: the known name survives.
            Types.applyUpdate(base, assert(Types.validateEntry({ itemID = 4357, quantity = 2 })))
            assert.equals("Silk Cloth", base.name)
            assert.equals(99, base.stats.lastSeen)
            assert.equals("Innkeeper", base.stats.lastSeenVendor)
            assert.equals(3, base.stats.visitsSeen)
            assert.equals(7, base.stats.visitsMissed)
            -- A named update refreshes the display name in place.
            Types.applyUpdate(base, assert(Types.validateEntry({ itemID = 4357, name = "Wool Cloth", quantity = 1 })))
            assert.equals("Wool Cloth", base.name)
        end)
    end)

    describe("isEntry", function()
        it("accepts a valid entry", function()
            local e = assert(Types.validateEntry({ itemID = 4357 }))
            assert.is_true(Types.isEntry(e))
        end)

        it("rejects corrupt entries", function()
            -- Corrupt shapes are built as raw literals: the cases must not
            -- fight the type checker to construct deliberately broken data.
            local stats = Types.makeEntryStats()
            assert.is_false(Types.isEntry({ -- missing key
                itemID = 4357,
                quantity = 1,
                quantityInitial = 1,
                stopOnSuccess = true,
                enabled = true,
                status = "active",
                stats = stats,
            }))
            assert.is_false(Types.isEntry({ -- mistyped quantity
                key = "id:4357",
                itemID = 4357,
                quantity = "5",
                quantityInitial = 1,
                stopOnSuccess = true,
                enabled = true,
                status = "active",
                stats = stats,
            }))
            assert.is_false(Types.isEntry({ -- unknown status
                key = "id:4357",
                itemID = 4357,
                quantity = 1,
                quantityInitial = 1,
                stopOnSuccess = true,
                enabled = true,
                status = "weird",
                stats = stats,
            }))
            assert.is_false(Types.isEntry({ -- missing stats
                key = "id:4357",
                itemID = 4357,
                quantity = 1,
                quantityInitial = 1,
                stopOnSuccess = true,
                enabled = true,
                status = "active",
                stats = nil,
            }))
            assert.is_false(Types.isEntry({ -- mistyped stats field
                key = "id:4357",
                itemID = 4357,
                quantity = 1,
                quantityInitial = 1,
                stopOnSuccess = true,
                enabled = true,
                status = "active",
                stats = { boughtTotal = "many", visitsSeen = 0, visitsMissed = 0, spentTotal = 0 },
            }))
            assert.is_false(Types.isEntry({ -- no identity
                key = "id:x",
                quantity = 1,
                quantityInitial = 1,
                stopOnSuccess = true,
                enabled = true,
                status = "active",
                stats = Types.makeEntryStats(),
            }))
            assert.is_false(Types.isEntry("nope"))
        end)
    end)

    describe("isVisitRecord", function()
        it("accepts rows with known kinds and typed fields", function()
            local row = {
                t = 100,
                kind = "buy",
                vendor = "Vendor",
                zone = "Stormwind",
                itemKey = "id:4357",
                quantity = 2,
                price = 100,
                spent = 200,
                note = nil,
            }
            assert.is_true(Types.isVisitRecord(row))
            assert.is_true(Types.isVisitRecord({ t = 1, kind = "visit" }))
        end)

        it("rejects unknown kinds, missing stamps and mistyped fields", function()
            assert.is_false(Types.isVisitRecord({ t = 1, kind = "nonsense" }))
            assert.is_false(Types.isVisitRecord({ kind = "buy" }))
            assert.is_false(Types.isVisitRecord({ t = "x", kind = "buy" }))
            assert.is_false(Types.isVisitRecord({ t = 1, kind = "buy", quantity = "2" }))
            assert.is_false(Types.isVisitRecord({ t = 1, kind = "buy", note = 5 }))
            assert.is_false(Types.isVisitRecord("nope"))
        end)
    end)

    describe("validateDB", function()
        it("returns a fresh shape for nil input", function()
            local db, droppedEntries, droppedLog = Types.validateDB(nil)
            assert.equals(1, db.version)
            assert.equals(1, db.settings.defaultQuantity)
            assert.equals(0, #db.list)
            assert.equals(0, #db.log)
            assert.equals(0, droppedEntries)
            assert.equals(0, droppedLog)
        end)

        it("drops corrupt entries and rows, keeps and sanitizes the rest", function()
            local ok = assert(Types.validateEntry({ itemID = 4357 }))
            local db, droppedEntries, droppedLog = Types.validateDB({
                settings = { logSize = 999999, verbose = true },
                list = { ok, { key = "id:2" } },
                log = { { t = 5, kind = "buy" }, { t = "x", kind = "buy" } },
            })
            assert.equals(1, #db.list)
            assert.equals(1, droppedEntries)
            assert.equals(1, #db.log)
            assert.equals(1, droppedLog)
            assert.is_true(db.settings.verbose)
            assert.equals(2000, db.settings.logSize)
        end)
    end)
end)

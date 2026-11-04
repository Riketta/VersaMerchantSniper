local Types = require("VersaMerchantSniper.domain.types")
local Money = require("VersaMerchantSniper.domain.money")
local Purchase = require("VersaMerchantSniper.domain.purchase")
local DebugDump = require("VersaMerchantSniper.domain.debug_dump")

-- debug_dump binds Money/Purchase off the shared namespace at load time, so
-- the requires above ARE the load order. These pins also document the exact
-- money forms the line assertions below expect, and the engine the verdict
-- preview mirrors.
assert.equals("1s 50c", Money.format(150))
assert.equals("5s", Money.format(500))
assert.equals(0, #Purchase.resolveMatches({}, {}))

--- Valid entry builder for the specs.
---@param fields table
---@return TrackedEntry
local function entry(fields)
    return assert(Types.validateEntry(fields))
end

--- Merchant slot builder with the adapter's defaults: unlimited stock,
--- purchasable, maxStack 20, price 0.
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

describe("DebugDump.entryLines", function()
    it("renders identity, want, ceiling, state and stats", function()
        local e = entry({ itemID = 4357, name = "Silk Cloth", quantity = 5, priceCeiling = 150000 })
        e.stats.visitsSeen, e.stats.visitsMissed, e.stats.boughtTotal = 2, 7, 3
        local lines = DebugDump.entryLines({ e })
        assert.equals(1, #lines)
        local line = lines[1]
        assert.is_true(line:find("Silk Cloth", 1, true) ~= nil)
        assert.is_true(line:find("id:4357", 1, true) ~= nil)
        assert.is_true(line:find("want x5/5", 1, true) ~= nil)
        assert.is_true(line:find("max 15g", 1, true) ~= nil)
        assert.is_true(line:find("active", 1, true) ~= nil)
        assert.is_true(line:find("seen 2", 1, true) ~= nil)
        assert.is_true(line:find("missed 7", 1, true) ~= nil)
        assert.is_true(line:find("bought 3", 1, true) ~= nil)
    end)

    it("marks disabled entries and honors the labeler", function()
        local e = entry({ itemID = 4357 })
        e.enabled = false
        local lines = DebugDump.entryLines({ e }, function()
            return "Resolvable Name"
        end)
        assert.equals(1, #lines)
        assert.is_true(lines[1]:find("Resolvable Name", 1, true) ~= nil)
        assert.is_true(lines[1]:find("disabled", 1, true) ~= nil)
    end)

    it("renders empty input as no lines", function()
        assert.equals(0, #DebugDump.entryLines({}))
    end)

    it("falls back to the stable key for name-less entries", function()
        local lines = DebugDump.entryLines({ entry({ itemID = 1936 }) })
        assert.is_true(lines[1]:find("id:1936", 1, true) ~= nil)
    end)
end)

describe("DebugDump.slotLines", function()
    it("renders the full stock row", function()
        local lines = DebugDump.slotLines({ slot({ index = 3, itemID = 1936, name = "Copper Rod", price = 150 }) })
        assert.equals(1, #lines)
        local line = lines[1]
        assert.is_true(line:find("#3", 1, true) ~= nil)
        assert.is_true(line:find("id:1936", 1, true) ~= nil)
        assert.is_true(line:find("Copper Rod", 1, true) ~= nil)
        assert.is_true(line:find("price 1s 50c", 1, true) ~= nil)
        assert.is_true(line:find("avail unlimited", 1, true) ~= nil)
        assert.is_true(line:find("max 20", 1, true) ~= nil)
    end)

    it("flags extended cost, not-purchasable, finite stock and unnamed slots", function()
        local lines = DebugDump.slotLines({
            slot({ index = 2, numAvailable = 0, hasExtendedCost = true, isPurchasable = false }),
        })
        assert.equals(1, #lines)
        local line = lines[1]
        assert.is_true(line:find("id:-", 1, true) ~= nil)
        assert.is_true(line:find("(unnamed)", 1, true) ~= nil)
        assert.is_true(line:find("avail 0", 1, true) ~= nil)
        assert.is_true(line:find("[extended-cost]", 1, true) ~= nil)
        assert.is_true(line:find("[not-purchasable]", 1, true) ~= nil)
    end)

    it("renders an empty scan as no lines", function()
        assert.equals(0, #DebugDump.slotLines({}))
    end)
end)

describe("DebugDump.matchLines", function()
    it("previews an order verdict with qty and cost", function()
        local e = entry({ itemID = 4357, quantity = 5 })
        local lines = DebugDump.matchLines({ slot({ itemID = 4357, price = 100 }) }, { e }, 1000000)
        assert.equals(1, #lines)
        local line = lines[1]
        assert.is_true(line:find("slot #1", 1, true) ~= nil)
        assert.is_true(line:find("order", 1, true) ~= nil)
        assert.is_true(line:find("qty 5", 1, true) ~= nil)
        assert.is_true(line:find("cost 5s", 1, true) ~= nil)
    end)

    it("reports the no-stock verdict", function()
        local e = entry({ itemID = 4357 })
        local lines = DebugDump.matchLines({ slot({ itemID = 4357, numAvailable = 0 }) }, { e }, 1000)
        assert.equals(1, #lines)
        assert.is_true(lines[1]:find("no-stock", 1, true) ~= nil)
    end)

    it("shows the unit price on a ceiling verdict", function()
        local e = entry({ itemID = 4357, priceCeiling = 50 })
        local lines = DebugDump.matchLines({ slot({ itemID = 4357, price = 100 }) }, { e }, 100000)
        assert.equals(1, #lines)
        assert.is_true(lines[1]:find("ceiling", 1, true) ~= nil)
        assert.is_true(lines[1]:find("unit 1s", 1, true) ~= nil)
    end)

    it("lists unmatched active entries as NO MATCH", function()
        local e = entry({ itemID = 4357 })
        local other = entry({ itemID = 1936 })
        local lines = DebugDump.matchLines({ slot({ itemID = 4357 }) }, { e, other }, 1000)
        assert.equals(2, #lines)
        assert.is_true(lines[1]:find("slot #1", 1, true) ~= nil)
        assert.is_true(lines[2]:find("NO MATCH", 1, true) ~= nil)
    end)

    it("omits done and disabled entries like the visit tick does", function()
        local done = entry({ itemID = 1936 })
        done.status = "done"
        local off = entry({ itemID = 19040 })
        off.enabled = false
        local lines = DebugDump.matchLines({}, { done, off }, 1000)
        assert.equals(0, #lines)
    end)
end)

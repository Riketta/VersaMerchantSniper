local Types = require("VersaMerchantSniper.domain.types")
local Purchase = require("VersaMerchantSniper.domain.purchase")

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

describe("Purchase", function()
    describe("slotMatches", function()
        it("matches by ID first and ignores the entry's name", function()
            local e = entry({ itemID = 4357, name = "Silk Cloth" })
            assert.is_true(Purchase.slotMatches(slot({ itemID = 4357, name = "Wool Dust" }), e))
        end)

        it("falls back to the name for name-only entries", function()
            local e = entry({ name = "Recipe: Frost Oil" })
            assert.is_true(Purchase.slotMatches(slot({ name = "Recipe: Frost Oil", itemID = 99 }), e))
        end)

        it("never matches nil slot names", function()
            local e = entry({ name = "Recipe: Frost Oil" })
            assert.is_false(Purchase.slotMatches(slot({ name = nil, itemID = 99 }), e))
        end)

        it("keeps ID-first semantics on a name collision", function()
            -- The entry's ID rules: a same-name slot with another ID is not
            -- a match (locale-proof identity).
            local e = entry({ itemID = 1, name = "Potion" })
            assert.is_false(Purchase.slotMatches(slot({ itemID = 2, name = "Potion" }), e))
        end)
    end)

    describe("resolveMatches", function()
        it("claims the first slot when the stock repeats", function()
            local e = entry({ itemID = 4357 })
            local matches = Purchase.resolveMatches(
                { slot({ itemID = 4357, index = 1 }), slot({ itemID = 4357, index = 2 }) },
                { e }
            )
            assert.equals(1, #matches)
            assert.equals(1, matches[1].slot.index)
        end)

        it("gives each slot to the first matching entry in list order", function()
            local first = entry({ itemID = 4357 })
            local second = entry({ name = "Silk Cloth" })
            local matches = Purchase.resolveMatches({ slot({ itemID = 4357, name = "Silk Cloth" }) }, { first, second })
            assert.equals(1, #matches)
            assert.equals("id:4357", matches[1].entry.key)
        end)

        it("matches different entries on different slots", function()
            local a = entry({ itemID = 4357 })
            local b = entry({ name = "Silk Cloth" })
            local matches = Purchase.resolveMatches(
                { slot({ itemID = 999, name = "Silk Cloth" }), slot({ itemID = 4357, name = "Cloth" }) },
                { a, b }
            )
            assert.equals(2, #matches)
        end)

        it("matches entries in any state - activity filtering is the caller's policy", function()
            local done = entry({ itemID = 4357 })
            done.status = "done"
            done.enabled = false
            local disabled = entry({ itemID = 4358 })
            disabled.enabled = false
            local live = entry({ itemID = 4359 })
            local matches = Purchase.resolveMatches(
                { slot({ itemID = 4357 }), slot({ itemID = 4358 }), slot({ itemID = 4359 }) },
                { done, disabled, live }
            )
            assert.equals(3, #matches)
            assert.equals("id:4357", matches[1].entry.key)
            assert.equals("id:4358", matches[2].entry.key)
            assert.equals("id:4359", matches[3].entry.key)
        end)
    end)

    describe("decide", function()
        it("orders the wanted quantity when everything is fine", function()
            local order = Purchase.decide(
                entry({ itemID = 4357, quantity = 3 }),
                slot({ itemID = 4357, price = 100, numAvailable = 5 }),
                10000
            )
            assert.equals("order", order.verdict)
            assert.equals(3, order.qty)
            assert.equals(300, order.cost)
        end)

        it("clamps by available stock", function()
            local order = Purchase.decide(
                entry({ itemID = 4357, quantity = 5 }),
                slot({ itemID = 4357, price = 100, numAvailable = 2 }),
                10000
            )
            assert.equals("order", order.verdict)
            assert.equals(2, order.qty)
        end)

        it("clamps by maxStack", function()
            local order = Purchase.decide(
                entry({ itemID = 4357, quantity = 12 }),
                slot({ itemID = 4357, price = 100, maxStack = 5, numAvailable = 30 }),
                10000
            )
            assert.equals("order", order.verdict)
            assert.equals(5, order.qty)
        end)

        it("treats -1 as unlimited but still caps at maxStack", function()
            local order = Purchase.decide(
                entry({ itemID = 4357, quantity = 40 }),
                slot({ itemID = 4357, price = 100, maxStack = 20, numAvailable = -1 }),
                10000
            )
            assert.equals("order", order.verdict)
            assert.equals(20, order.qty)
        end)

        it("reports no-stock before anything else", function()
            -- Extended cost AND zero stock: no-stock wins (verdict order).
            local order = Purchase.decide(
                entry({ itemID = 4357 }),
                slot({ itemID = 4357, numAvailable = 0, hasExtendedCost = true }),
                10000
            )
            assert.equals("no-stock", order.verdict)
        end)

        it("never buys extended-cost items", function()
            local order = Purchase.decide(
                entry({ itemID = 4357 }),
                slot({ itemID = 4357, hasExtendedCost = true, numAvailable = 3 }),
                10000
            )
            assert.equals("extended-cost", order.verdict)
        end)

        it("reports non-purchasable rows after extended-cost", function()
            local order = Purchase.decide(
                entry({ itemID = 4357 }),
                slot({ itemID = 4357, hasExtendedCost = true, isPurchasable = false, numAvailable = 3 }),
                10000
            )
            assert.equals("extended-cost", order.verdict)
            local onlyGate = Purchase.decide(
                entry({ itemID = 4357 }),
                slot({ itemID = 4357, isPurchasable = false, numAvailable = 3 }),
                10000
            )
            assert.equals("not-purchasable", onlyGate.verdict)
        end)

        it("reports a ceiling breach regardless of stock", function()
            local e = entry({ itemID = 4357, priceCeiling = 500 })
            local order = Purchase.decide(e, slot({ itemID = 4357, price = 1000, numAvailable = 3 }), 100000)
            assert.equals("ceiling", order.verdict)
        end)

        it("lets a price equal to the ceiling pass", function()
            local e = entry({ itemID = 4357, priceCeiling = 1000 })
            local order = Purchase.decide(e, slot({ itemID = 4357, price = 1000, numAvailable = 3 }), 100000)
            assert.equals("order", order.verdict)
        end)

        it("reports unaffordable batches without partial buys", function()
            local order = Purchase.decide(
                entry({ itemID = 4357, quantity = 3 }),
                slot({ itemID = 4357, price = 100, numAvailable = 5 }),
                250
            )
            assert.equals("unaffordable", order.verdict)
            assert.equals(3, order.qty)
            assert.equals(300, order.cost)
        end)

        it("orders free items at zero money", function()
            local order = Purchase.decide(
                entry({ itemID = 4357, quantity = 2 }),
                slot({ itemID = 4357, price = 0, numAvailable = 5 }),
                0
            )
            assert.equals("order", order.verdict)
            assert.equals(0, order.cost)
        end)

        it("reports no-stock on a degenerate maxStack", function()
            local order = Purchase.decide(
                entry({ itemID = 4357, quantity = 2 }),
                slot({ itemID = 4357, price = 100, maxStack = 0, numAvailable = 5 }),
                10000
            )
            assert.equals("no-stock", order.verdict)
        end)
    end)

    describe("applyPurchase", function()
        it("decrements the remaining quantity", function()
            local e = entry({ itemID = 4357, quantity = 5 })
            local result = Purchase.applyPurchase(e, slot({ itemID = 4357, price = 100 }), 2)
            assert.equals(3, e.quantity)
            assert.equals(200, result.spent)
            assert.equals(2, result.bought)
            assert.is_false(result.done)
            assert.equals("active", e.status)
        end)

        it("completes a stop-on-success entry at zero", function()
            local e = entry({ itemID = 4357, quantity = 2 })
            local result = Purchase.applyPurchase(e, slot({ itemID = 4357, price = 100 }), 2)
            assert.equals(0, e.quantity)
            assert.is_true(result.done)
            assert.equals("done", e.status)
            assert.is_false(e.enabled)
        end)

        it("keeps a no-stop entry active at zero", function()
            local e = entry({ itemID = 4357, quantity = 2, stopOnSuccess = false })
            local result = Purchase.applyPurchase(e, slot({ itemID = 4357, price = 100 }), 2)
            assert.equals(0, e.quantity)
            assert.is_false(result.done)
            assert.equals("active", e.status)
            assert.is_true(e.enabled)
        end)
    end)
end)

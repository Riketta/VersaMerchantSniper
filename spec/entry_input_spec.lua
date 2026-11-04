-- The money module must load before entry_input (the parser reads it
-- through the namespace at load time).
require("VersaMerchantSniper.domain.money")

local EntryInput = require("VersaMerchantSniper.ui.entry_input")

describe("EntryInput", function()
    it("extracts the ID out of a pasted link", function()
        local raw = assert(EntryInput.parse("|cff9d9d9d|Hitem:4357:0:0:0:0:0:0:0|h[Silk Cloth]|h|r"))
        assert.equals(4357, raw.itemID)
    end)

    it("parses a bare numeric ID", function()
        local raw = assert(EntryInput.parse("4357"))
        assert.equals(4357, raw.itemID)
    end)

    it("joins name words when no ID is present", function()
        local raw = assert(EntryInput.parse("Silk Cloth"))
        assert.equals("Silk Cloth", raw.name)
        local recipe = assert(EntryInput.parse("Recipe: Frost Oil"))
        assert.equals("Recipe: Frost Oil", recipe.name)
    end)

    it("parses quantities, stop flags and ceilings in any order", function()
        local raw = assert(EntryInput.parse("4357 x5 max:500g nostop"))
        assert.equals(4357, raw.itemID)
        assert.equals(5, raw.quantity)
        assert.equals(5000000, raw.priceCeiling)
        assert.is_false(raw.stopOnSuccess)
        local flagged = assert(EntryInput.parse("[Silk Cloth] x3 max 1g 30s stop"))
        assert.equals("Silk Cloth", flagged.name)
        assert.equals(3, flagged.quantity)
        assert.equals(13000, flagged.priceCeiling)
        assert.is_true(flagged.stopOnSuccess)
    end)

    it("keeps link name spill-out out of the entry", function()
        -- A pasted link with spaces in its name tokenizes; the ID wins and
        -- the spill fragments are ignored.
        local raw = assert(EntryInput.parse("|Hitem:4357:0|h[Silk Cloth]|h:r x2"))
        assert.equals(4357, raw.itemID)
        assert.equals(nil, raw.name)
        assert.equals(2, raw.quantity)
    end)

    it("rejects unusable input with reasons", function()
        assert.equals(nil, (EntryInput.parse(nil)))
        assert.equals(nil, (EntryInput.parse("   ")))
        assert.equals(nil, (EntryInput.parse("x5")))
        assert.equals(nil, (EntryInput.parse("4357 max:abc")))
        assert.equals(nil, (EntryInput.parse("4357 max")))
    end)
end)

local Money = require("VersaMerchantSniper.domain.money")

describe("Money", function()
    it("formats gold/silver/copper", function()
        assert.equals("123g 45s 67c", Money.format(1234567))
    end)

    it("omits empty segments", function()
        assert.equals("50g", Money.format(500000))
        assert.equals("5s", Money.format(500))
    end)

    it("formats zero as copper", function()
        assert.equals("0c", Money.format(0))
    end)

    it("formats negative amounts with the sign out front", function()
        assert.equals("-123g 45s 67c", Money.format(-1234567))
        assert.equals("-5s", Money.format(-500))
        assert.equals("-1g", Money.format(-10000))
        -- split works on the magnitude; the caller owns the sign
        local gold, silver, rem = Money.split(-1234567)
        assert.equals(123, gold)
        assert.equals(45, silver)
        assert.equals(67, rem)
    end)

    it("computes per-unit prices", function()
        assert.equals(333, Money.perUnit(1000, 3))
        assert.equals(100, Money.perUnit(100, 0))
        assert.equals(100, Money.perUnit(100, nil))
    end)

    describe("parseCopper", function()
        it("parses plain copper", function()
            assert.equals(5000000, Money.parseCopper("5000000"))
        end)

        it("parses g/s/c tokens in any order and spacing", function()
            assert.equals(1234567, Money.parseCopper("123g 45s 67c"))
            assert.equals(1234567, Money.parseCopper("123g45s67c"))
            assert.equals(500000, Money.parseCopper("50g"))
            assert.equals(500, Money.parseCopper("5s"))
            assert.equals(3405, Money.parseCopper("34s 5c 0g"))
        end)

        it("is case-insensitive and trims", function()
            assert.equals(10000, Money.parseCopper("  1G "))
        end)

        it("rejects garbage and leftovers", function()
            assert.equals(nil, Money.parseCopper("abc"))
            assert.equals(nil, Money.parseCopper(""))
            assert.equals(nil, Money.parseCopper("12x34g"))
            assert.equals(nil, Money.parseCopper(nil))
        end)

        it("refuses totals at or beyond the double-precision bound", function()
            -- 2^53 = 9007199254740992: integer precision ends here, so both
            -- parse paths refuse rather than drift.
            assert.equals(nil, Money.parseCopper("9007199254740992"))
            assert.equals(nil, Money.parseCopper("9007199254740993"))
            assert.equals(nil, Money.parseCopper("900719925475g"))
            -- just below the bound still parses exactly
            assert.equals(9007199254740991, Money.parseCopper("9007199254740991"))
        end)
    end)

    describe("compact", function()
        it("degrades to dashes for absent values", function()
            assert.equals("-", Money.compact(nil))
            assert.equals("-", Money.compact(0))
        end)

        it("renders gold with sensible precision", function()
            assert.equals("12.3g", Money.compact(123456))
            assert.equals("120g", Money.compact(1200000))
            assert.equals("1k", Money.compact(10000000))
        end)

        it("falls back to silver under one gold", function()
            assert.equals("50s", Money.compact(5000))
        end)

        it("renders sub-silver amounts as copper, not 0s", function()
            assert.equals("45c", Money.compact(45))
            assert.equals("99c", Money.compact(99))
        end)
    end)
end)

-- > Part of the VersaUtils.
-- Gate note: this file is historical reference and is excluded from the
-- luacheck/stylua gates; the pragma below silences its unused-local and
-- undefined-global warnings for the LuaLS batch check only (the engine
-- globals it calls are no longer allowlisted for the addon itself).
---@diagnostic disable: unused-local, undefined-global
-- # Usage
-- /run VersaMerchantSniper.PrintItemsToBuy()
-- /run VersaMerchantSniper.StartSniping()
-- /run VersaMerchantSniper.SnipeItemByID(4357, 4);
-- /run VMS.SnipeItemByID(4364, 2, false);
-- /run VMS.SnipeItemByName("Healing Potion", 5, false);
-- /run VersaMerchantSniper.SnipeItemByName("Recipe: Free Action Potion")
-- /run VersaMerchantSniper.StopSniping()
--
-- /run VersaMerchantSniper.SnipeItemByName("Recipe: Frost Oil"); VersaMerchantSniper.StartSniping()
-- /run VMS.SnipeItemByName("Recipe: Shadow Protection Potion"); VMS.SnipeItemByName("Healing Potion", 5, false); VMS.SnipeItemByName("Lesser Mana Potion", 5, false); VMS.StartSniping()

VMS = {}
VersaMerchantSniper = VMS
VersaMerchantSniper.Debug = true
VersaMerchantSniper.Prefix = "[VMS]"
VersaMerchantSniper.Print = function(...) if VersaMerchantSniper.Debug then print(VersaMerchantSniper.Prefix, ...) end end
VersaMerchantSniper.ItemsToBuy = { -- Entries: { ["Name"] as string, ["ID"] as int, ["Quantity"] as int, ["StopOnSuccess"] as bool }.
    -- {
    --     Name = nil,
    --     ID = nil,
    --     Quantity = 1,
    --     StopOnSuccess = true, -- If true - stop sniping after designated quantity of sniped item successfully purchased, otherwise keep sniping. True by default. If set to false, expected to buy all available items every time.
    -- },
}

VersaMerchantSniper.IndicatorState = 0 -- 0 to start with (0 + 1) = 1st symbol of array, instead of second in case of start with 1.
VersaMerchantSniper.IndicatorSymbols = { "\\", "|", "/" }
VersaMerchantSniper.GetIndicatorSymbol = function()
    --VersaMerchantSniper.IndicatorState = (VersaMerchantSniper.IndicatorState + 1) % #VersaMerchantSniper.IndicatorSymbols
    VersaMerchantSniper.IndicatorState = VersaMerchantSniper.IndicatorState + 1
    if VersaMerchantSniper.IndicatorState > #VersaMerchantSniper.IndicatorSymbols then
        VersaMerchantSniper.IndicatorState = 1
    end

    return VersaMerchantSniper.IndicatorSymbols[VersaMerchantSniper.IndicatorState] or "?"
end

VersaMerchantSniper.Frame = CreateFrame("FRAME", "VersaMerchantSniperFrame")
VersaMerchantSniper.Callback = function(self, event, ...)
    local merchantNumItems = GetMerchantNumItems()
    VersaMerchantSniper.Print(string.format("{%s} [%s] Scanning %d merchant items...", VersaMerchantSniper.GetIndicatorSymbol(), date("%H:%M:%S"), merchantNumItems))

    local items = "->"
    for merchantItemIndex = 1, merchantNumItems do
        local itemName, _, _, _, numAvailable = GetMerchantItemInfo(merchantItemIndex) -- numAvailable - The number of this item that the merchant has in stock. -1 for unlimited stock.
        local itemID = GetMerchantItemID(merchantItemIndex)
        local maxStack = GetMerchantItemMaxStack(merchantItemIndex) -- The maximum stack size for the item merchant will sell at once.
        items = string.format("%s [%s]%s", items, itemName or "-", numAvailable > 0 and ("x" .. numAvailable) or "")

        for itemIndex, itemData in ipairs(VersaMerchantSniper.ItemsToBuy) do
            if (itemName == itemData.Name or itemID == itemData.ID) and itemData.Quantity > 0 then
                VersaMerchantSniper.Print(string.format("> Found item to buy: [%s]x%d", itemData.Name or ("ID:" .. tostring(itemData.ID)), itemData.Quantity))
                VersaMerchantSniper.Print(string.format("  [?] Merchant has: %d; Willing to buy: %d; MaxStack: %d", numAvailable, itemData.Quantity, maxStack))

                local buyNowQuantity = math.min(itemData.Quantity, maxStack)
                if numAvailable > 0 then -- If numAvailable == -1 - merchant has unlimited stock for this item.
                    buyNowQuantity = math.min(numAvailable, buyNowQuantity)
                end

                BuyMerchantItem(merchantItemIndex, buyNowQuantity) -- TODO: buy items in a loop one by one instead of using a second argument?
                VersaMerchantSniper.Print(string.format("  [+] Success! Sniped: %d/%d", buyNowQuantity, itemData.Quantity))

                if itemData.StopOnSuccess then
                    itemData.Quantity = itemData.Quantity - buyNowQuantity
                    VersaMerchantSniper.Print("  [-] New quantity:", itemData.Quantity)
                    if itemData.Quantity == 0 then
                        VersaMerchantSniper.Print("  [-] Excluding this item from sniping:", itemData.Name or itemData.ID)
                        VersaMerchantSniper.TryStopSniping() -- TODO: check if there is other items to keep sniping
                    end
                end
                break
            end
        end
    end
    if merchantNumItems > 0 then VersaMerchantSniper.Print(items) end

    CloseMerchant()
end
VersaMerchantSniper.Frame:SetScript("OnEvent", VersaMerchantSniper.Callback);

-- Start sniping actions.
-- Interact with the vendor manually or using the "Interact With Target" key.
-- The sniper will then do the following:
-- will check the items the merchant is selling (at the moment the merchant frame opens);
-- compare them to the item(s) the sniper is looking for;
-- and attempt to purchase the required number of instances;
-- and in the end will close the merchant trading frame.
-- To try again, you will have to interact with merchant again.
VersaMerchantSniper.StartSniping = function()
    VersaMerchantSniper.Frame:RegisterEvent("MERCHANT_SHOW");
    VersaMerchantSniper.Print(string.format("Sniping of %d items started.", #VersaMerchantSniper.ItemsToBuy))
    VersaMerchantSniper.Print("Sniping:")
    VersaMerchantSniper.PrintItemsToBuy()
end

-- Stop sniping actions.
VersaMerchantSniper.StopSniping = function()
    VersaMerchantSniper.Frame:UnregisterEvent("MERCHANT_SHOW");
    VersaMerchantSniper.Print("Sniping stopped.")
    return nil
end

-- Try to stop sniping if there is no more items with Quantity to buy greater than 0, keep sniping otherwise.
VersaMerchantSniper.TryStopSniping = function()
    for _, itemData in ipairs(VersaMerchantSniper.ItemsToBuy) do
        if itemData.Quantity > 0 then return false end
    end

    VersaMerchantSniper.Print(string.format("All %d items was successfully sniped!", #VersaMerchantSniper.ItemsToBuy))
    VersaMerchantSniper.ItemsToBuy = {}
    VersaMerchantSniper.StopSniping()
    return true
end

-- Snipe an item sold by a merchant by the name of the item.
-- It is allowed to pass the quantity of items to purchase as the second argument, otherwise only 1 instance of selling item will be purchased at a time.
-- It is allowed to pass the true to keep sniping that item as the third argument, otherwise sniper will exclude that item from snipe list after remaining quantity to buy will became equal to zero.
VersaMerchantSniper.SnipeItemByName = function(itemName, quantityToBuy, stopOnSuccess)
    local itemData = { Name = itemName, ID = nil, Quantity = quantityToBuy or 1, StopOnSuccess = stopOnSuccess == nil and true or stopOnSuccess }
    table.insert(VersaMerchantSniper.ItemsToBuy, itemData)

    VersaMerchantSniper.Print("Sniping:", itemData.Name, itemData.Quantity, itemData.StopOnSuccess)
end

-- Snipe merchant item by item ID. Other than first arguments same as VersaMerchantSniper.SnipeItemByName.
VersaMerchantSniper.SnipeItemByID = function(itemID, quantityToBuy, stopOnSuccess)
    local itemData = { Name = nil, ID = itemID, Quantity = quantityToBuy or 1, StopOnSuccess = stopOnSuccess == nil and true or stopOnSuccess }
    table.insert(VersaMerchantSniper.ItemsToBuy, itemData)

    VersaMerchantSniper.Print("Sniping:", itemData.ID, itemData.Quantity, itemData.StopOnSuccess)
end

VersaMerchantSniper.PrintItemsToBuy = function()
    for index, itemData in ipairs(VersaMerchantSniper.ItemsToBuy) do
        VersaMerchantSniper.Print(string.format("%d. [%s]x%d, Stop: %s", index, itemData.Name or ("ID:" .. tostring(itemData.ID)), itemData.Quantity, tostring(itemData.StopOnSuccess)))
    end
end

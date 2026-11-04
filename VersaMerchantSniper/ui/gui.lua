-- VersaMerchantSniper - GUI dashboard adapter (inbound).
-- Own window (portrait frame, List / Log / Settings tabs) plus the
-- merchant-frame toggle button: lazily parented to MerchantFrame, anchored
-- left of its CloseButton (generation-resolved, classic fallback global
-- next), created on every MERCHANT_SHOW and at build - the AuctiMogger
-- pattern, proven on both target clients. A build failure degrades to
-- "GUI unavailable" (chat reports why) while the headless sniper keeps
-- running. Loads after domain (reads Money through the namespace).

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.ui = VMS.ui or {}

local Money = VMS.domain and VMS.domain.Money

local FRAME_WIDTH = 620
local FRAME_HEIGHT = 470
local PORTRAIT_ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local TABS = { "list", "log", "settings" }

--- Generation differences: mainline nests the portrait and title inside
--- containers; older generations expose direct regions + globals.
---@param frame any
---@param frameName string
---@return any|nil
local function resolvePortraitRegion(frame, frameName)
    local container = frame.PortraitContainer
    if container ~= nil then
        local portrait = container.portrait or container.Portrait
        if portrait ~= nil then
            return portrait
        end
    end
    return rawget(_G, frameName .. "Portrait")
end

---@param frame any
---@param frameName string
---@return any|nil
local function resolveTitleRegion(frame, frameName)
    local container = frame.TitleContainer
    if container ~= nil then
        local title = container.TitleText or container.Title
        if title ~= nil then
            return title
        end
    end
    return rawget(_G, frameName .. "TitleText")
end

--- The link-insert home the client routes CHATLINKs through (mainline:
--- ChatFrameUtil.InsertLink; classic era: ChatEdit_InsertLink). The GUI
--- post-hooks it so shift-clicked links land in the focused input box.
---@return any|nil home
---@return string|nil member
local function resolveLinkInsertHome()
    local util = rawget(_G, "ChatFrameUtil")
    if type(util) == "table" and util.InsertLink ~= nil then
        return util, "InsertLink"
    end
    if rawget(_G, "ChatEdit_InsertLink") ~= nil then
        return _G, "ChatEdit_InsertLink"
    end
    return nil, nil
end

---@class Gui
---@field core ControlPort
---@field names NameLookupPort
---@field alerts AlertPort
---@field query MerchantQueryPort live merchant surface (vendor-row link reads)
---@field available boolean false when the widget build failed (chat reports why)
---@field buildError string|nil first build error when unavailable
---@field frame any|nil window frame
---@field merchantButton any|nil the MerchantFrame toggle button
---@field activeTab string
---@field lastBoxCapture {text: string, at: number}|nil last focused-box capture (vendor-hook dedupe)
local Gui = {}

--- Builds the GUI over the injected core surface.
---@param deps {core: ControlPort, names: NameLookupPort, alerts: AlertPort, query: MerchantQueryPort}
---@return Gui
function Gui.new(deps)
    ---@type Gui
    local self = setmetatable({}, { __index = Gui })
    self.core = deps.core
    self.names = deps.names
    self.alerts = deps.alerts
    self.query = deps.query
    self.available = false
    self.frame = nil
    self.merchantButton = nil
    self.lastBoxCapture = nil
    self.activeTab = "list"

    -- The dashboard degrades independently of the sniper: a failed widget
    -- build must never take the buy loop down.
    local ok, err = pcall(function()
        self:buildWindow()
    end)
    if ok then
        self.available = true
        self:setTab("list")
        self:refresh()
    else
        self.buildError = tostring(err)
    end

    -- Independent of the window: the toggle button alone is worth having.
    pcall(function()
        self:buildMerchantHook()
    end)
    return self
end

--- Native template chrome: PortraitFrameTemplate ships a portrait texture
--- and a title row; resolve the generation's regions, self-draw otherwise.
---@return nil
function Gui:buildWindow()
    local frame = CreateFrame("Frame", "VersaMerchantSniperGUI", UIParent, "PortraitFrameTemplate")
    self.frame = frame
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetUserPlaced(true)

    self.portrait = resolvePortraitRegion(frame, "VersaMerchantSniperGUI")
    if self.portrait ~= nil then
        self.portrait:SetTexture(PORTRAIT_ICON)
        self.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        self.portrait = frame:CreateTexture(nil, "OVERLAY")
        self.portrait:SetSize(38, 38)
        self.portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -8)
        self.portrait:SetTexture(PORTRAIT_ICON)
        self.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    self.titleText = resolveTitleRegion(frame, "VersaMerchantSniperGUI")
    if self.titleText ~= nil then
        self.titleText:SetText("Versa Merchant Sniper")
    else
        self.titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        self.titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", 64, -12)
        self.titleText:SetText("Versa Merchant Sniper")
    end
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnShow", function()
        self:refresh()
    end)
    -- ESC-close WITHOUT UISpecialFrames: the panel manager's CloseWindows()
    -- (run whenever a managed window like the vendor panel closes) ends with
    -- securecall("CloseSpecialWindows"), which hides every UISpecialFrames
    -- frame - the dashboard would die with the vendor. Keyboard-enable the
    -- frame instead: ESC closes while the cursor is over the window, and the
    -- game menu is untouched otherwise. The X button and the merchant toggle
    -- button close it from anywhere.
    frame:EnableKeyboard(true)
    frame:SetScript("OnKeyDown", function(selfFrame, key)
        if key == "ESCAPE" then
            selfFrame:Hide()
        end
    end)

    -- Header status line, reachable from every tab.
    self.statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.statusText:SetPoint("TOPLEFT", frame, "TOPLEFT", 64, -34)
    self.statusText:SetJustifyH("LEFT")

    -- Native retail tab row: tabs sit flush; the active tab flips its art
    -- through the PanelTemplates system in setTab.
    frame.tabPadding = 8
    frame.numTabs = #TABS
    frame.Tabs = frame.Tabs or {}
    local prevTab = nil
    self.tabButtons = {}
    self.content = {}
    for index, name in ipairs(TABS) do
        local button = CreateFrame("Button", nil, frame, "PanelTabButtonTemplate")
        button:SetID(index)
        button:SetText(name:upper())
        if prevTab ~= nil then
            button:SetPoint("TOPLEFT", prevTab, "TOPRIGHT", -6, 0)
        else
            button:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -62)
        end
        button:SetScript("OnClick", function()
            self:setTab(name)
        end)
        self.tabButtons[name] = button
        frame.Tabs[index] = button
        prevTab = button
    end

    for _, name in ipairs(TABS) do
        local content = CreateFrame("Frame", nil, frame)
        content:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -96)
        content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, -30)
        content:Hide()
        self.content[name] = content
    end

    self:buildListTab()
    self:buildLogTab()
    self:buildSettingsTab()
    self:buildMerchantHook()
end

--- List tab: entry input + add, pooled tracked-entry table (right-click a
--- row to remove).
---@return nil
function Gui:buildListTab()
    local content = self.content.list
    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -4)
    hint:SetJustifyH("LEFT")
    hint:SetText(
        "Paste an item link (shift-click a bag item while the box is focused, or a vendor row while this window shows the List tab)"
            .. " or type an ID / name, then Add. Right-click a row to remove."
    )

    self.inputBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    self.inputBox:SetSize(300, 20)
    self.inputBox:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -24)
    self.inputBox:SetAutoFocus(false)
    self.inputBox:SetScript("OnEnterPressed", function(box)
        self:addFromInput(box:GetText())
        box:SetText("")
        box:ClearFocus()
    end)
    self.inputBox:SetScript("OnEscapePressed", function(box)
        box:SetText("")
        box:ClearFocus()
    end)

    -- Shift-click capture: the client routes CHATLINK inserts (shift-clicked
    -- bag items / chat links) through the link-insert home; while our input
    -- box has keyboard focus the link belongs to us - the same capture the
    -- AH search box gets (AuctiMogger pattern).
    local home, member = resolveLinkInsertHome()
    if home ~= nil and hooksecurefunc ~= nil then
        hooksecurefunc(home, member, function(text)
            if type(text) ~= "string" then
                return
            end
            if self.inputBox ~= nil and self.inputBox:IsShown() and self.inputBox:HasFocus() then
                self.inputBox:Insert(text)
                self.lastBoxCapture = { text = text, at = GetTime() }
            end
        end)
    end

    -- Vendor-row capture: vendor modified-clicks DO end in the insert home
    -- (dump: Mainline/Vanilla MerchantItemButton_OnModifiedClick ->
    -- HandleModifiedItemClick), but two blind spots defeat the focused-box
    -- hook: with the chat edit box open Blizzard SetFocuses the chat frame
    -- BEFORE any post-hook runs, and on Midnight the legacy
    -- GetMerchantItemLink export reads nil so InsertLink is never called at
    -- all. Gate on visibility instead (the AuctiMogger sell-slot pattern)
    -- and take the link from the merchant query port, whose linkFor rebuilds
    -- Midnight-degraded links from the slot's item ID. When the focused-box
    -- hook DID capture this click, the same text lands here within
    -- milliseconds - the freshness window keeps it the single writer.
    local vendorClickHandler = rawget(_G, "MerchantItemButton_OnModifiedClick")
    if vendorClickHandler ~= nil and hooksecurefunc ~= nil then
        hooksecurefunc(_G, "MerchantItemButton_OnModifiedClick", function(itemButton)
            if self.frame == nil or not self.frame:IsShown() or self.activeTab ~= "list" then
                return
            end
            local box = self.inputBox
            if box == nil or not box:IsShown() then
                return
            end
            if IsModifiedClick ~= nil and not IsModifiedClick("CHATLINK") then
                return
            end
            local frame = rawget(_G, "MerchantFrame")
            if frame == nil or frame.selectedTab ~= 1 then
                return
            end
            if self.query == nil then
                return
            end
            local link = self.query:linkFor(itemButton:GetID())
            if type(link) ~= "string" then
                return
            end
            local last = self.lastBoxCapture
            if last ~= nil and last.text == link and GetTime() - last.at < 0.5 then
                return
            end
            box:Insert(link)
        end)
    end

    self.addButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    self.addButton:SetSize(64, 22)
    self.addButton:SetPoint("LEFT", self.inputBox, "RIGHT", 10, 0)
    self.addButton:SetText("Add")
    self.addButton:SetScript("OnClick", function()
        self:addFromInput(self.inputBox:GetText())
        self.inputBox:SetText("")
    end)

    self.listTable = VMS.ui.TableView.new(content, CreateFrame, {
        {
            width = 220,
            title = "Item",
            text = function(record)
                return record.label
            end,
        },
        {
            width = 60,
            justify = "RIGHT",
            title = "Want",
            text = function(record)
                return record.want
            end,
        },
        {
            width = 64,
            justify = "RIGHT",
            title = "Ceiling",
            text = function(record)
                return record.ceiling
            end,
        },
        {
            width = 96,
            title = "Last seen",
            text = function(record)
                return record.lastSeen
            end,
        },
        {
            width = 48,
            title = "Stop",
            text = function(record)
                return record.stop
            end,
        },
        {
            width = 120,
            title = "Status",
            text = function(record)
                return record.status
            end,
        },
    }, { rowCount = 15, rowHeight = 18 })
    self.listTable.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -52)
    self.listTable.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -52)
    self.listTable.frame:SetHeight(15 * 18)
    self.listTable.onWheel = function(delta)
        self.listTable:setOffset(self.listTable:getOffset() - delta * 3)
    end
    self.listTable.onClick = function(entryData, mouseButton)
        if mouseButton == "RightButton" and entryData.entry ~= nil then
            self.core:removeEntry(entryData.entry.key)
            self:refresh()
        end
    end
end

--- Log tab: clear button + pooled visit-row viewport (wheel scrolls).
---@return nil
function Gui:buildLogTab()
    local content = self.content.log
    self.logHeadText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.logHeadText:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -4)
    self.logHeadText:SetJustifyH("LEFT")

    self.clearLogButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    self.clearLogButton:SetSize(80, 20)
    self.clearLogButton:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    self.clearLogButton:SetText("Clear")
    self.clearLogButton:SetScript("OnClick", function()
        self.core:clearLog()
        self:refresh()
    end)

    self.logRows = VMS.ui.FeedRows.new(content, CreateFrame, self.names)
    self.logRows.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -24)
    self.logRows.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -24)
    self.logRows.frame:EnableMouseWheel(true)
    self.logRows.frame:SetScript("OnMouseWheel", function(_, delta)
        local ring = self.core:ring()
        local window = 16
        local maxOffset = math.max(0, #ring - window)
        self.logOffset = math.max(0, math.min((self.logOffset or 0) - delta * 3, maxOffset))
        self:renderLog()
    end)
end

--- Settings tab: checkboxes + numeric edit boxes over the validated
--- settings surface.
---@return nil
function Gui:buildSettingsTab()
    local content = self.content.settings

    local function makeCheck(label, field, yOffset)
        -- UICheckButtonTemplate's text child differs per client generation:
        -- name the button so a template text resolves as a global, and
        -- self-draw the label when the generation ships none.
        local name = "VMSCheck" .. field
        local check = CreateFrame("CheckButton", name, content, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", content, "TOPLEFT", 8, yOffset)
        check:SetText(label)
        local text = rawget(_G, name .. "Text")
        if text == nil then
            text = check:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            text:SetPoint("LEFT", check, "RIGHT", 2, 1)
        end
        text:SetText(label)
        check:SetScript("OnClick", function(button)
            self.core:setSetting(field, button:GetChecked())
            self:refresh()
        end)
        self.checks[field] = check
        return check
    end

    self.checks = {}
    makeCheck("Verbose scan chatter", "verbose", -8)
    makeCheck("Stop tracking entries when fully bought", "defaultStopOnSuccess", -38)

    self.quantityBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    self.quantityBox:SetSize(60, 20)
    self.quantityBox:SetPoint("TOPLEFT", content, "TOPLEFT", 34, -78)
    self.quantityBox:SetNumeric(true)
    self.quantityBox:SetAutoFocus(false)
    self.quantityBox:SetScript("OnEnterPressed", function(box)
        local ok, reason = self.core:setSetting("defaultQuantity", tonumber(box:GetText()))
        if not ok then
            self.alerts:say("Rejected: " .. (reason or "?"))
        end
        box:ClearFocus()
        self:refreshSettings()
    end)

    local quantityLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    quantityLabel:SetPoint("LEFT", self.quantityBox, "RIGHT", 8, 0)
    quantityLabel:SetJustifyH("LEFT")
    quantityLabel:SetText("default quantity for new entries")

    self.logSizeBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    self.logSizeBox:SetSize(60, 20)
    self.logSizeBox:SetPoint("TOPLEFT", content, "TOPLEFT", 34, -108)
    self.logSizeBox:SetNumeric(true)
    self.logSizeBox:SetAutoFocus(false)
    self.logSizeBox:SetScript("OnEnterPressed", function(box)
        local ok, reason = self.core:setSetting("logSize", tonumber(box:GetText()))
        if not ok then
            self.alerts:say("Rejected: " .. (reason or "?"))
        end
        box:ClearFocus()
        self:refreshSettings()
    end)

    local logSizeLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    logSizeLabel:SetPoint("LEFT", self.logSizeBox, "RIGHT", 8, 0)
    logSizeLabel:SetJustifyH("LEFT")
    logSizeLabel:SetText("visit log size (10-2000)")

    -- Clicker buyout macro: a COPY SOURCE, not an editor. Focus selects all
    -- (Ctrl+C copies); any user edit heals back to the canonical text that
    -- clicker_api publishes as VMS.ClickerMacro.
    local macroCaption = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    macroCaption:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -142)
    macroCaption:SetJustifyH("LEFT")
    macroCaption:SetWidth(330)
    macroCaption:SetWordWrap(true)
    macroCaption:SetText(
        "Clicker buyout macro - click the box, press Ctrl+C (buys tracked items, closes the vendor when something was bought):"
    )

    local macroText = VMS.ClickerMacro or ""
    self.macroBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    self.macroBox:SetSize(330, 20)
    self.macroBox:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -180)
    self.macroBox:SetAutoFocus(false)
    self.macroBox:SetText(macroText)
    self.macroBox:SetScript("OnEditFocusGained", function(box)
        box:HighlightText()
    end)
    self.macroBox:SetScript("OnTextChanged", function(box, userInput)
        if userInput then
            box:SetText(macroText)
        end
    end)
    self.macroBox:SetScript("OnEscapePressed", function(box)
        box:SetText(macroText)
        box:ClearFocus()
    end)
end

--- The MerchantFrame toggle button: lazy ensure (the frame may not exist at
--- build), parented to MerchantFrame so it shows/hides with it.
---@return nil
function Gui:buildMerchantHook()
    local hook = CreateFrame("Frame", "VersaMerchantSniperMerchantHook")
    hook:RegisterEvent("MERCHANT_SHOW")
    hook:SetScript("OnEvent", function()
        self:ensureMerchantButton()
    end)
    self:ensureMerchantButton()
end

---@return nil
function Gui:ensureMerchantButton()
    if self.merchantButton ~= nil or MerchantFrame == nil then
        return
    end
    local button = CreateFrame("Button", "VersaMerchantSniperMerchantButton", MerchantFrame, "UIPanelButtonTemplate")
    button:SetSize(90, 22)
    button:SetText("VMS")
    -- The close button has different homes per client generation: retail
    -- frames expose a CloseButton region, classic-era frames keep the
    -- $parentCloseButton global (the AuctiMogger resolution chain).
    local closeButton = MerchantFrame.CloseButton or rawget(_G, "MerchantFrameCloseButton")
    if closeButton ~= nil then
        button:SetPoint("RIGHT", closeButton, "LEFT", -4, 0)
    else
        button:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -30, -6)
    end
    -- XML children use explicit high frame levels; lift above the frame's
    -- own decorations or the button draws UNDER the background art.
    button:SetFrameLevel(MerchantFrame:GetFrameLevel() + 100)
    button:SetScript("OnClick", function()
        self:toggleWindow()
    end)
    button:SetScript("OnEnter", function()
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Versa Merchant Sniper")
        GameTooltip:AddLine("Toggle the sniper dashboard.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    self.merchantButton = button
end

--- Opens/closes the dashboard.
---@return nil
function Gui:toggleWindow()
    if self.frame == nil then
        return
    end
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end

--- Flips the visible tab and repaints its data.
---@param name string
---@return nil
function Gui:setTab(name)
    self.activeTab = name
    for _, tabName in ipairs(TABS) do
        local content = self.content[tabName]
        if content ~= nil then
            if tabName == name then
                content:Show()
            else
                content:Hide()
            end
        end
    end
    local frame = self.frame
    if frame ~= nil then
        local setTabArt = rawget(_G, "PanelTemplates_SetTab")
        for index, tabName in ipairs(TABS) do
            if tabName == name then
                if setTabArt ~= nil then
                    setTabArt(frame, index)
                elseif self.tabButtons[tabName].Text ~= nil then
                    self.tabButtons[tabName].Text:SetTextColor(1, 0.82, 0)
                end
            elseif setTabArt == nil and self.tabButtons[tabName].Text ~= nil then
                self.tabButtons[tabName].Text:SetTextColor(0.8, 0.8, 0.8)
            end
        end
    end
    self:refresh()
end

--- Parses the input box through the shared entry parser and hands the raw
--- fields to the core (validation + merge live there).
---@param text string
---@return nil
function Gui:addFromInput(text)
    local raw, reason = VMS.ui.EntryInput.parse(text)
    if raw == nil then
        self.alerts:say("Add failed: " .. (reason or "unparseable") .. ".")
        return
    end
    local entry, addReason = self.core:addEntry(raw)
    if entry == nil then
        self.alerts:say("Add failed: " .. (addReason or "unparseable") .. ".")
    end
    self:refresh()
end

--- Resolved row label: lookup name first, known name, bare ID last; done
--- entries gray out.
---@param entry TrackedEntry
---@return string
function Gui:labelFor(entry)
    if self.names ~= nil and entry.itemID ~= nil then
        local name = self.names:nameFor(entry.itemID)
        if name ~= nil then
            if entry.status == "done" then
                return "|cff909090" .. name .. "|r"
            end
            return name
        end
    end
    if entry.name ~= nil then
        return entry.name
    end
    return "id:" .. tostring(entry.itemID)
end

---@return nil
function Gui:refresh()
    if not self.available or self.frame == nil then
        return
    end
    self.statusText:SetText(self.core:statusLine())
    if self.activeTab == "list" then
        self:refreshList()
    elseif self.activeTab == "log" then
        self:refreshLog()
    else
        self:refreshSettings()
    end
end

---@return nil
function Gui:refreshList()
    local now = time and time() or 0
    local records = {}
    for _, entry in ipairs(self.core:entries()) do
        records[#records + 1] = {
            entry = entry,
            label = self:labelFor(entry),
            want = ("x%d/%d"):format(entry.quantity, entry.quantityInitial),
            ceiling = entry.priceCeiling ~= nil and Money.compact(entry.priceCeiling) or "-",
            lastSeen = VMS.domain.SnipeLog.agoLabel(entry.stats.lastSeen, now) or "-",
            stop = entry.stopOnSuccess and "stop" or "keep",
            status = entry.status ~= "active" and entry.status or (entry.enabled and "waiting" or "disabled"),
        }
    end
    self.listTable:render(records)
end

---@return nil
function Gui:refreshLog()
    local ring = self.core:ring()
    self.logOffset = math.max(0, math.min(self.logOffset or 0, math.max(0, #ring - 16)))
    self.logHeadText:SetText(("Recent visits (%d rows, newest first):"):format(#ring))
    self:renderLog()
end

--- Renders the current log window (offset clamped by refreshLog/wheel).
---@return nil
function Gui:renderLog()
    local ring = self.core:ring()
    local first = (self.logOffset or 0) + 1
    local window = {}
    for i = first, math.min(first + 15, #ring) do
        window[#window + 1] = ring[i]
    end
    self.logRows:render(window)
end

---@return nil
function Gui:refreshSettings()
    local settings = self.core:settings()
    self.checks.verbose:SetChecked(settings.verbose)
    self.checks.defaultStopOnSuccess:SetChecked(settings.defaultStopOnSuccess)
    self.quantityBox:SetText(tostring(settings.defaultQuantity))
    self.logSizeBox:SetText(tostring(settings.logSize))
    if self.macroBox ~= nil then
        local macroText = VMS.ClickerMacro or ""
        if self.macroBox:GetText() ~= macroText then
            self.macroBox:SetText(macroText)
        end
    end
end

VMS.ui.Gui = Gui
return Gui

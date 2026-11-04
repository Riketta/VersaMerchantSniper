-- VersaMerchantSniper - generic pooled table view for the GUI tabs
-- (adapted from the AuctiMogger table view). A fixed viewport of button
-- rows split into fixed-width fontstring columns, refreshed wholesale.
-- Deliberately NOT a ScrollBox: the datasets are bounded (tracked list +
-- ring buffer), so pooled rows keep the widget surface tiny. The viewport
-- slides by a 0-based offset (wheel input) - the pool stays fixed.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.ui = VMS.ui or {}

local HEADER_HEIGHT = 16

---@class TableColumn
---@field width number column width in px (callers keep the sum inside the frame)
---@field justify string|nil "LEFT" (default) or "RIGHT"
---@field text fun(entry: any): string cell renderer
---@field title string|nil header label; titling any column builds the header strip

---@class TableView
---@field frame any container (widget handles are typed any by house style)
---@field columns TableColumn[]
---@field rowCount number pooled viewport height
---@field offset number 0-based first visible row, clamped against the list
---@field entries any[]|nil the last rendered list
---@field headerHeight number 0 = no header strip
---@field rows {row: any, cells: any[]}[] pooled rows (elementData + column fontstrings)
---@field onWheel (fun(delta: number))|nil set by the adapter
---@field onClick (fun(entry: any, mouseButton: string))|nil set by the adapter
local TableView = {}
TableView.__index = TableView

--- Wheel plumbing on one frame; scripts do not consume clicks.
local function enableWheel(self, frame)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        if self.onWheel ~= nil then
            self.onWheel(delta)
        end
    end)
end

---@param parent any container frame
---@param createFrame fun(kind: string, name: string|nil, parent: any, template: string|nil): any
---@param columns TableColumn[]
---@param opts {rowCount: number, rowHeight: number|nil}|nil
---@return TableView
function TableView.new(parent, createFrame, columns, opts)
    opts = opts or {}
    local rowCount = opts.rowCount or 14
    local rowHeight = opts.rowHeight or 18
    local self = setmetatable({}, TableView)
    self.rows = {}
    self.rowCount = rowCount
    self.offset = 0
    self.entries = nil
    self.columns = columns
    self.onWheel = nil
    self.onClick = nil

    local container = createFrame("Frame", nil, parent)
    self.frame = container
    container:SetAllPoints()
    enableWheel(self, container)

    local hasHeader = false
    for _, column in ipairs(columns) do
        if column.title ~= nil then
            hasHeader = true
            break
        end
    end
    self.headerHeight = hasHeader and HEADER_HEIGHT or 0
    if hasHeader then
        local cursor = 2
        for c = 1, #columns do
            local column = columns[c]
            local cell = createFrame("Frame", nil, container)
            cell:SetHeight(HEADER_HEIGHT)
            cell:SetPoint("TOPLEFT", container, "TOPLEFT", cursor, -2)
            cell:SetWidth(column.width)
            local text = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetAllPoints()
            text:SetJustifyH(column.justify or "LEFT")
            text:SetText(column.title)
            cursor = cursor + column.width
        end
        -- Hairline under the strip so it reads as a table head.
        local divider = container:CreateTexture(nil, "BACKGROUND")
        divider:SetColorTexture(1, 1, 1, 0.15)
        divider:SetHeight(1)
        divider:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -HEADER_HEIGHT)
        divider:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -HEADER_HEIGHT)
    end

    for i = 1, rowCount do
        local row = createFrame("Button", nil, container)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -(self.headerHeight + (i - 1) * rowHeight))
        row:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -(self.headerHeight + (i - 1) * rowHeight))
        row:EnableMouse(true)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        local cursor = 2
        local cells = {}
        for c = 1, #columns do
            local cell = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            cell:SetPoint("TOPLEFT", row, "TOPLEFT", cursor, -2)
            cell:SetWidth(columns[c].width)
            cell:SetJustifyH(columns[c].justify or "LEFT")
            -- Clip instead of wrapping: a long name must not push the row up.
            cell:SetHeight(rowHeight)
            cursor = cursor + columns[c].width
            cells[c] = cell
        end
        -- elementData: implicit row-to-entry contract; render() stores the
        -- typed entry here, handlers read it back (widgets are any).
        row.elementData = nil
        row:SetScript("OnClick", function(_, clickButton)
            if self.onClick ~= nil and row.elementData ~= nil then
                self.onClick(row.elementData, clickButton)
            end
        end)
        enableWheel(self, row)
        self.rows[i] = { row = row, cells = cells }
    end
    return self
end

--- Paints the viewport from a newest-first entry list.
---@param entries any[]
---@return nil
function TableView:render(entries)
    self.entries = entries
    local count = entries and #entries or 0
    -- The list may have shrunk under a deep offset (removals): clamp first.
    local maxOffset = math.max(0, count - self.rowCount)
    if self.offset > maxOffset then
        self.offset = maxOffset
    end
    self:paint()
end

--- Paints the current offset window of the stored list.
---@return nil
function TableView:paint()
    local entries = self.entries
    local first = self.offset + 1
    for i = 1, self.rowCount do
        local handle = self.rows[i]
        local entry = entries and entries[first + i - 1] or nil
        if entry ~= nil then
            handle.row.elementData = entry
            for c = 1, #self.columns do
                handle.cells[c]:SetText(self.columns[c].text(entry) or "")
            end
            handle.row:Show()
        else
            handle.row.elementData = nil
            handle.row:Hide()
        end
    end
end

--- Slides the window (0-based rows), clamped, and repaints.
---@param offset number
---@return nil
function TableView:setOffset(offset)
    local count = self.entries and #self.entries or 0
    local maxOffset = math.max(0, count - self.rowCount)
    if offset < 0 then
        offset = 0
    elseif offset > maxOffset then
        offset = maxOffset
    end
    if offset == self.offset then
        return
    end
    self.offset = offset
    self:paint()
end

--- The current 0-based window start.
---@return number
function TableView:getOffset()
    return self.offset
end

VMS.ui.TableView = TableView
return TableView

-- VersaMerchantSniper - GUI log viewport (adapted from the AuctiMogger
-- feed rows): a fixed pool of recent visit rows, newest on top. Deliberately
-- NOT a ScrollBox: the ring buffer is bounded, so a pooled view keeps the
-- widget surface tiny. Column layout fits the GUI's 600px content width.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.ui = VMS.ui or {}

local Money = VMS.domain and VMS.domain.Money

local ROW_COUNT = 16
local ROW_HEIGHT = 18
local KIND_COLORS = {
    buy = "|cff00ff00",
    blocked = "|cffffd100",
    arm = "|cff00ccff",
    disarm = "|cff00ccff",
    visit = "|cffdddddd",
    notfound = "|cff909090",
    closed = "|cff909090",
}

---@class FeedRowHandles
---@field row any pooled row button
---@field timeText any
---@field kindText any
---@field itemText any
---@field qtyText any
---@field spentText any
---@field vendorText any
---@field noteText any

---@class FeedRows
---@field frame any container
---@field rows FeedRowHandles[]
---@field names NameLookupPort|nil item labels resolve through it when possible
local FeedRows = {}
FeedRows.__index = FeedRows

---@param parent any frame to attach to
---@param createFrame fun(kind: string, name: string|nil, parent: any, template: string|nil): any
---@param names NameLookupPort|nil optional item label resolution
---@return FeedRows
function FeedRows.new(parent, createFrame, names)
    local self = setmetatable({}, FeedRows)
    self.rows = {}
    self.names = names
    local container = createFrame("Frame", nil, parent)
    self.frame = container
    container:SetAllPoints()

    for i = 1, ROW_COUNT do
        local row = createFrame("Button", nil, container)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -((i - 1) * ROW_HEIGHT))

        local timeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        timeText:SetPoint("LEFT", row, "LEFT", 4, 0)
        timeText:SetWidth(56)
        timeText:SetJustifyH("LEFT")

        local kindText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        kindText:SetPoint("LEFT", timeText, "RIGHT", 4, 0)
        kindText:SetWidth(52)
        kindText:SetJustifyH("LEFT")

        local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        itemText:SetPoint("LEFT", kindText, "RIGHT", 4, 0)
        itemText:SetWidth(190)
        itemText:SetJustifyH("LEFT")

        local qtyText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        qtyText:SetPoint("LEFT", itemText, "RIGHT", 4, 0)
        qtyText:SetWidth(34)
        qtyText:SetJustifyH("RIGHT")

        local spentText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        spentText:SetPoint("LEFT", qtyText, "RIGHT", 4, 0)
        spentText:SetWidth(64)
        spentText:SetJustifyH("RIGHT")

        local vendorText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        vendorText:SetPoint("LEFT", spentText, "RIGHT", 4, 0)
        vendorText:SetWidth(100)
        vendorText:SetJustifyH("LEFT")

        local noteText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        noteText:SetPoint("LEFT", vendorText, "RIGHT", 4, 0)
        noteText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        noteText:SetJustifyH("LEFT")

        self.rows[i] = {
            row = row,
            timeText = timeText,
            kindText = kindText,
            itemText = itemText,
            qtyText = qtyText,
            spentText = spentText,
            vendorText = vendorText,
            noteText = noteText,
        }
    end
    return self
end

--- "m/d HH:MM" wall stamp; degrades to the raw number without `date`.
---@param record VisitRecord
---@return string
local function stampFor(record)
    if date ~= nil then
        return date("%m/%d %H:%M", record.t) or tostring(record.t)
    end
    return tostring(record.t)
end

--- Best-effort label for a row's itemKey: the id part resolves through the
--- name lookup; everything else shows the raw key.
---@param record VisitRecord
---@return string
function FeedRows:labelFor(record)
    local key = record.itemKey
    if key == nil then
        return "-"
    end
    local idPart = key:match("^id:(%d+)")
    if idPart ~= nil and self.names ~= nil then
        local itemID = tonumber(idPart)
        if itemID ~= nil then
            local name = self.names:nameFor(itemID)
            if name ~= nil then
                return name
            end
        end
    end
    return key
end

--- Paints the viewport from the newest-first ring.
---@param ring VisitRecord[]
---@return nil
function FeedRows:render(ring)
    for i = 1, ROW_COUNT do
        local handle = self.rows[i]
        local record = ring[i]
        if record ~= nil then
            handle.timeText:SetText(stampFor(record))
            local color = KIND_COLORS[record.kind] or "|cff909090"
            handle.kindText:SetText(color .. (record.kind or "?"):upper() .. "|r")
            handle.itemText:SetText(self:labelFor(record))
            handle.qtyText:SetText(record.quantity ~= nil and ("x" .. record.quantity) or "-")
            handle.spentText:SetText(Money.compact(record.spent))
            handle.vendorText:SetText(record.vendor or "-")
            handle.noteText:SetText(record.note or "")
            handle.row:Show()
        else
            handle.row:Hide()
        end
    end
end

VMS.ui.FeedRows = FeedRows
return FeedRows

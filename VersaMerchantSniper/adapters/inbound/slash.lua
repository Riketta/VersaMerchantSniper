-- VersaMerchantSniper - slash adapter (inbound).
-- /vms driving surface. Loads after the ui block (reads ui.EntryInput and
-- domain.Money through the namespace). Registration writes the DEFERRED
-- slash globals itself.

local VMS = _G.VersaMerchantSniper or {}
_G.VersaMerchantSniper = VMS
VMS.adapters = VMS.adapters or {}
VMS.adapters.inbound = VMS.adapters.inbound or {}

local Money = VMS.domain and VMS.domain.Money
local DebugDump = VMS.domain and VMS.domain.DebugDump
local EntryInput = VMS.ui and VMS.ui.EntryInput

---@class Slash
---@field core ControlPort
---@field alerts AlertPort
---@field names NameLookupPort|nil
---@field query MerchantQueryPort
local M = {}

--- Builds the slash adapter and registers /vms + /vmsniper.
---@param core ControlPort
---@param alerts AlertPort
---@param names NameLookupPort|nil optional prettier list labels
---@param query MerchantQueryPort live stock surface for the debug dump
---@return Slash
function M.new(core, alerts, names, query)
    ---@type Slash
    local self = setmetatable({}, { __index = M })
    self.core = core
    self.alerts = alerts
    self.names = names
    self.query = query
    SLASH_VMS1 = "/vms"
    SLASH_VMS2 = "/vmsniper"
    SlashCmdList["VMS"] = function(msg)
        self:run(msg)
    end
    return self
end

---@param text string|nil
---@return string|nil
local function trim(text)
    if type(text) ~= "string" then
        return nil
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Number when the ref is an index, raw string (key/name) otherwise.
---@param rest string|nil
---@return any
local function resolveRef(rest)
    local n = tonumber(rest)
    if n ~= nil then
        return n
    end
    return rest
end

--- Routes one /vms invocation.
---@param msg string|nil
---@return nil
function M:run(msg)
    local text = trim(msg) or ""
    local command, rest = text:match("^(%S+)%s*(.*)$")
    command = (command and command:lower()) or "status"

    if command == "status" then
        self.alerts:say(self.core:statusLine())
    elseif command == "add" then
        self:add(rest)
    elseif command == "remove" then
        if not self.core:removeEntry(resolveRef(trim(rest))) then
            self.alerts:say("Remove failed: no such entry (" .. tostring(trim(rest)) .. ").")
        end
    elseif command == "list" then
        self:printList()
    elseif command == "log" then
        local count = rest and rest:match("^(%d+)")
        self:printLog(count and tonumber(count) or 10)
    elseif command == "clearlog" then
        self.core:clearLog()
    elseif command == "verbose" then
        self.alerts:say("Verbose " .. (self.core:toggleVerbose() and "on" or "off") .. ".")
    elseif command == "debug" then
        self:printDebug()
    else
        self:help()
    end
end

--- `add`: parse, hand to the core, report failures.
---@param rest string|nil
---@return nil
function M:add(rest)
    local raw, reason = EntryInput.parse(trim(rest))
    if raw == nil then
        self.alerts:say("Add failed: " .. (reason or "unparseable") .. ".")
        return
    end
    local entry, addReason = self.core:addEntry(raw)
    if entry == nil then
        self.alerts:say("Add failed: " .. (addReason or "unparseable") .. ".")
    end
end

--- Pretty label for an entry: resolved name first, known name, bare ID last.
---@param entry TrackedEntry
---@return string
function M:labelFor(entry)
    if self.names ~= nil and entry.itemID ~= nil then
        local name = self.names:nameFor(entry.itemID)
        if name ~= nil then
            return name
        end
    end
    return entry.name or ("id:" .. tostring(entry.itemID))
end

--- `list`: one line per entry.
---@return nil
function M:printList()
    local entries = self.core:entries()
    if #entries == 0 then
        self.alerts:say("List empty - /vms add <link|id> [x<qty>] [max <money>] [nostop|stop].")
        return
    end
    for i, entry in ipairs(entries) do
        local bits = { ("%d. %s"):format(i, self:labelFor(entry)) }
        bits[#bits + 1] = ("x%d/%d"):format(entry.quantity, entry.quantityInitial)
        bits[#bits + 1] = entry.stopOnSuccess and "stop" or "nostop"
        if entry.priceCeiling ~= nil then
            bits[#bits + 1] = "max " .. Money.format(entry.priceCeiling)
        end
        bits[#bits + 1] = entry.status
        if not entry.enabled then
            bits[#bits + 1] = "(disabled)"
        end
        self.alerts:say(table.concat(bits, " "))
    end
end

--- `log [n]`: the last n ring rows, newest first.
---@param count number|nil
---@return nil
function M:printLog(count)
    local ring = self.core:ring()
    if #ring == 0 then
        self.alerts:say("Log empty.")
        return
    end
    for i = 1, math.min(count or 10, #ring) do
        local row = ring[i]
        local stamp = date and date("%H:%M:%S", row.t) or tostring(row.t)
        local bits = { ("[%s] %s"):format(stamp, row.kind) }
        if row.itemKey ~= nil then
            bits[#bits + 1] = row.itemKey
        end
        if row.quantity ~= nil then
            bits[#bits + 1] = "x" .. row.quantity
        end
        if row.spent ~= nil then
            bits[#bits + 1] = Money.format(row.spent)
        end
        if row.vendor ~= nil then
            bits[#bits + 1] = "@" .. row.vendor
        end
        if row.note ~= nil then
            bits[#bits + 1] = "(" .. row.note .. ")"
        end
        self.alerts:say(table.concat(bits, " "))
    end
end

--- `debug`: dumps the tracked list and a live stock scan with the verdict
--- preview (the same resolve/decide the visit tick runs). Diagnostic
--- surface for silent-visit reports: it shows what the sniper sees and
--- what it would decide, without buying anything.
---@return nil
function M:printDebug()
    ---@param entry TrackedEntry
    ---@return string
    local labeler = function(entry)
        return self:labelFor(entry)
    end
    local entries = self.core:entries()
    self.alerts:say(("Debug: %d tracked entr%s."):format(#entries, #entries == 1 and "y" or "ies"))
    for _, line in ipairs(DebugDump.entryLines(entries, labeler)) do
        self.alerts:say(line)
    end
    local slots = self.query:snapshot()
    self.alerts:say(("Debug: %d stock row(s)."):format(#slots))
    if #slots == 0 then
        self.alerts:say("Debug: stock only reads while a vendor is open - open one and run /vms debug again.")
        return
    end
    local money = self.query:money()
    self.alerts:say(("Debug: verdict preview, money %s:"):format(Money.format(money)))
    for _, line in ipairs(DebugDump.slotLines(slots)) do
        self.alerts:say(line)
    end
    for _, line in ipairs(DebugDump.matchLines(slots, entries, money, labeler)) do
        self.alerts:say(line)
    end
end

--- Command overview.
---@return nil
function M:help()
    self.alerts:say("/vms status | add <link|id> [x<qty>] [max <money>] [nostop|stop] | remove <n|id|name>")
    self.alerts:say("/vms list | log [n] | clearlog | verbose | debug")
end

VMS.adapters.inbound.Slash = M
return M

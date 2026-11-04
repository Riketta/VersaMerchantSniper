-- CI guard: keeps the compat manifest from drifting. The manifest in
-- adapters/inbound/compat.lua is the machine-checkable "mainline-compatible"
-- contract; this script scans every game-facing Lua file the addon actually
-- loads and fails the build when code uses a game surface no manifest tier
-- lists. The manifest module itself publishes its tier lists as
-- Compat.manifest - this script diffs against that, never against source
-- text, so the two cannot disagree about what is listed.
--
-- Scan set: the Lua files listed in the addon TOC (default
-- VersaMerchantSniper/VersaMerchantSniper.toc, override with the first
-- argument).
-- scripts/check_toc.lua already guarantees TOC <-> disk coverage in both
-- directions, so the TOC entries ARE the game surface; spec/ and scripts/
-- are dev tooling and stay out of scope. The manifest module is excluded
-- (it defines the lists being diffed against).
--
-- Scanned dimensions:
--   * event-name string literals (ALL_CAPS with a known event prefix),
--   * C_-namespace member accesses (C_MerchantFrame.X, C_Item.X, ...),
--     matched against exact dotted manifest paths,
--   * curated global-name families (the merchant frame family, the slash
--     registration pair, C_ namespaces, Enum),
--     matched against the manifest's plain names and dotted-path segments.
--
-- Known limitations (accepted, conservative by design):
--   * string scan of comment-stripped source, not a parse: member access
--     through a local alias (`local ca = C_AuctionHouse` ... `ca.X`) is
--     invisible here; the aliasing call sites stay pinned by specs instead.
--   * the global layer is curated families, not all of _G: a brand-new
--     game-global family needs a pattern in WATCHED_FAMILIES before drift
--     on it is caught.
--   * dotted frame paths (the DEFERRED tier) are curated manifest-side
--     only: aliases (`list.SetSelectedEntryByCondition` after
--     `local list = frame.ItemList`) make a reliable reverse check
--     impossible without a real parser.
--   * bracket access (`C_AuctionHouse["SendSearchQuery"]`) and Enum member
--     drift (`Enum.X.Y` - the bare `Enum` family whitelists any member)
--     are invisible; dotted/global matching is accept-biased (a watched
--     name passes when ANY manifest dotted path ends with it).
--   * event recognition is prefix-curated (EVENT_PREFIXES below): an event
--     outside the known families is never classified as one.
--   * only the TOC given (default: the addon) is scanned.
--   * reverse drift (manifest names nothing uses) is never flagged; for
--     plain names a non-gating warning would be cheap to add later.
--
-- Usage: lua scripts/check_compat.lua [<addon .toc path>]
-- Exit code 0 = every used surface is listed; 1 = drift or broken setup.

local scriptDir = ((arg and arg[0]) or ""):match("^(.*)[/\\][^/\\]+$") or "."
local repoRoot = scriptDir .. "/.."
package.path = repoRoot .. "/?.lua;" .. repoRoot .. "/?/init.lua;" .. package.path

local function fail(message)
    io.stderr:write("check_compat: " .. message .. "\n")
    os.exit(1)
end

local modOk, Compat = pcall(require, "VersaMerchantSniper.adapters.inbound.compat")
if not modOk or type(Compat) ~= "table" or type(Compat.manifest) ~= "table" then
    fail("cannot load VersaMerchantSniper.adapters.inbound.compat or its published manifest")
end
---@type CompatManifest
local manifest = Compat.manifest

local tocPath = (arg and arg[1]) or repoRoot .. "/VersaMerchantSniper/VersaMerchantSniper.toc"
local toc = assert(io.open(tocPath, "r"), "cannot open TOC: " .. tocPath)
local addonDir = tocPath:match("^(.*)[/\\][^/\\]+$") or "."
local files = {}
for line in toc:lines() do
    local entry = line:match("^(%S+%.lua)%s*$")
    if entry and entry:gsub("\\", "/") ~= "adapters/inbound/compat.lua" then
        files[#files + 1] = addonDir .. "/" .. entry
    end
end
toc:close()
if #files == 0 then
    fail("no Lua entries found in " .. tocPath)
end

---@param ... string[]|nil string lists to index
---@return table<string, boolean>
local function indexAll(...)
    local set = {}
    for i = 1, select("#", ...) do
        local list = select(i, ...)
        if type(list) == "table" then
            for _, value in ipairs(list) do
                set[value] = true
            end
        end
    end
    return set
end

local eventSet = indexAll(manifest.requiredEvents, manifest.optionalEvents, manifest.probeEvents)

-- Every dotted path and plain name across all tiers (GUI alternatives
-- included) forms the "listed" universe the scan diffs against.
local pathLists = {
    manifest.requiredFunctions,
    manifest.requiredGlobals,
    manifest.optionalGlobals,
    manifest.probeGlobals,
    manifest.guiGlobals,
    manifest.guiDeferredGlobals,
}
for _, alternatives in ipairs(manifest.requiredAlternatives or {}) do
    pathLists[#pathLists + 1] = alternatives
end
for _, alternatives in pairs(manifest.guiAlternatives) do
    pathLists[#pathLists + 1] = alternatives
end
local dottedSet, plainSet, firstSegment, lastSegment = {}, {}, {}, {}
for _, list in ipairs(pathLists) do
    for _, path in ipairs(list or {}) do
        if path:find(".", 1, true) then
            dottedSet[path] = true
            firstSegment[path:match("^([^.]+)")] = true
            lastSegment[path:match("([^.]+)$")] = true
        else
            plainSet[path] = true
        end
    end
end

local EVENT_PREFIXES = {
    "MERCHANT_",
    "ADDON_",
    "PLAYER_",
    "UI_",
}

-- Curated ALL_CAPS prefixed string literals that are NOT events, with a
-- reason each; extend only when the event scan flags a real constant.
local NON_EVENT_LITERALS = {}

---@param value string
---@return boolean
local function isEventLiteral(value)
    if NON_EVENT_LITERALS[value] then
        return false
    end
    if not value:match("^%u[%u%d_]*$") then
        return false
    end
    for _, prefix in ipairs(EVENT_PREFIXES) do
        if value:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

-- Global-name families whose use must always have a manifest entry. A new
-- game-global family used by adapters needs a pattern here to be policed.
local WATCHED_FAMILIES = {
    "^MerchantFrame[%w_]*$",
    "^SLASH_VMS%d+$",
    "^SlashCmdList$",
    "^C_[%a]+$",
    "^Enum$",
}

---@param name string
---@return boolean
local function isWatchedGlobal(name)
    for _, pattern in ipairs(WATCHED_FAMILIES) do
        if name:match(pattern) then
            return true
        end
    end
    return false
end

---@param name string
---@return boolean
local function isManifestedGlobal(name)
    return (plainSet[name] or firstSegment[name] or lastSegment[name]) == true
end

--- Walks Lua source once: comments and string literals are replaced by
--- spaces (line structure preserved) and every short-string literal is
--- recorded with its start line. Short strings (with backslash escapes),
--- long strings, long comments and line comments are all handled, so `--`
--- inside a string never swallows code and commented-out code is never
--- scanned. Long-string literals are blanked but not recorded (event names
--- never live in them).
---@param text string
---@return string code source with comments and strings blanked (identifiers remain)
---@return {value: string, line: number}[] literals every short-string literal, in source order
local function stripCommentsAndCollect(text)
    local out = {}
    local literals = {}
    local n = #text
    local line = 1

    --- Appends one blanking char per source byte, preserving newlines.
    ---@param from number
    ---@param to number
    local function blank(from, to)
        for k = from, to do
            if text:byte(k) == 10 then
                line = line + 1
                out[#out + 1] = "\n"
            else
                out[#out + 1] = " "
            end
        end
    end

    local i = 1
    while i <= n do
        local c = text:sub(i, i)
        if c == "\"" or c == "'" then
            local startLine = line
            local j = i + 1
            local value = {}
            while j <= n do
                local d = text:sub(j, j)
                if d == "\\" then
                    value[#value + 1] = text:sub(j, j + 1)
                    j = j + 2
                elseif d == c then
                    break
                else
                    if d == "\n" then
                        line = line + 1
                    end
                    value[#value + 1] = d
                    j = j + 1
                end
            end
            literals[#literals + 1] = { value = table.concat(value), line = startLine }
            blank(i, math.min(j, n))
            i = j + 1
        elseif c == "-" and text:sub(i + 1, i + 1) == "-" then
            local eqs = text:match("^%-%-%[(=*)%[", i)
            if eqs then
                local closer = "]" .. eqs .. "]"
                local closeAt = text:find(closer, i + 2, true)
                local stop = closeAt and (closeAt + #closer - 1) or n
                blank(i, stop)
                i = stop + 1
            else
                local nl = text:find("\n", i, true)
                blank(i, (nl or n + 1) - 1)
                i = nl or n + 1
            end
        elseif c == "[" then
            local eqs = text:match("^%[(=*)%[", i)
            if eqs then
                local closer = "]" .. eqs .. "]"
                local closeAt = text:find(closer, i + 1, true)
                local stop = closeAt and (closeAt + #closer - 1) or n
                blank(i, stop)
                i = stop + 1
            else
                out[#out + 1] = c
                i = i + 1
            end
        else
            if c == "\n" then
                line = line + 1
            end
            out[#out + 1] = c
            i = i + 1
        end
    end

    return table.concat(out), literals
end

--- Builds a byte-index -> 1-based line map so every match reports its line.
---@param text string
---@return number[]
local function buildLineMap(text)
    local map = {}
    local line = 1
    for i = 1, #text do
        map[i] = line
        if text:byte(i) == 10 then
            line = line + 1
        end
    end
    return map
end

--- Finds every `pattern` match in ascending order and calls `visit` with the
--- match start and up to two captures (fixed arity - no spread call, so the
--- walker runs identically on Lua 5.1 and newer shims).
---@param text string
---@param pattern string with exactly one or two capture groups
---@param visit fun(start: number, first: string|nil, second: string|nil)
local function scanMatches(text, pattern, visit)
    local pos = 1
    while true do
        local start, stop, first, second = text:find(pattern, pos)
        if not start then
            break
        end
        visit(start, first, second)
        pos = stop + 1
    end
end

---@param set table<string, boolean>
---@return number
local function countKeys(set)
    local count = 0
    for _ in pairs(set) do
        count = count + 1
    end
    return count
end

local problems = {}
local filesScanned = 0
local eventsSeen, membersSeen, globalsSeen = {}, {}, {}

--- Records one drift problem with a file:line prefix.
---@param path string
---@param line number
---@param message string
local function addProblem(path, line, message)
    problems[#problems + 1] = ("%s:%d: %s"):format(path, line, message)
end

for _, path in ipairs(files) do
    local handle = assert(io.open(path, "r"), "cannot read " .. path)
    local text = handle:read("*a")
    handle:close()
    filesScanned = filesScanned + 1

    local code, literals = stripCommentsAndCollect(text)
    local lineOf = buildLineMap(code)

    for _, literal in ipairs(literals) do
        if isEventLiteral(literal.value) then
            eventsSeen[literal.value] = true
            if not eventSet[literal.value] then
                local message = ("event \"%s\" is used but not listed in the compat manifest"):format(literal.value)
                addProblem(path, literal.line, message)
            end
        end
    end

    scanMatches(code, "(C_%a+)%.([%a_][%w_]*)", function(start, namespace, member)
        local memberPath = namespace .. "." .. member
        membersSeen[memberPath] = true
        if not dottedSet[memberPath] then
            addProblem(path, lineOf[start], memberPath .. " is used but not listed in the compat manifest")
        end
    end)

    scanMatches(code, "([%a_][%w_]*)", function(start, name)
        if type(name) == "string" and isWatchedGlobal(name) then
            globalsSeen[name] = true
            if not isManifestedGlobal(name) then
                addProblem(path, lineOf[start], name .. " is used but not listed in the compat manifest")
            end
        end
    end)
end

if #problems > 0 then
    io.stderr:write(("compat manifest drift: %d problem(s)\n"):format(#problems))
    for _, problem in ipairs(problems) do
        io.stderr:write("  " .. problem .. "\n")
    end
    os.exit(1)
end

print(
    ("compat manifest ok: %d file(s) scanned, %d event(s), %d C_ member(s), %d watched global(s), all listed"):format(
        filesScanned,
        countKeys(eventsSeen),
        countKeys(membersSeen),
        countKeys(globalsSeen)
    )
)

-- CI guard, two directions:
--   1. every Lua file in the addon folder must be listed in the TOC (busted/
--      LLS load modules via require/filesystem and would never notice a
--      missing TOC entry, but the game only loads what the TOC lists);
--   2. every .lua file listed in the TOC must exist on disk (the game errors
--      on a missing load entry; require-based tooling would never notice).
--
-- NOTE: the directory walk uses `find` via io.popen, which is Unix-only and
-- therefore a silent no-op on Windows shells (it exits 0 with no output).
-- CI runs this on Linux; treat a local "ok" on Windows as unverified.

local tocPath = assert(arg and arg[1], "usage: lua scripts/check_toc.lua <Addon.toc> [source root]")
local srcRoot = (arg and arg[2]) or "."

local file = assert(io.open(tocPath, "r"), "cannot open TOC: " .. tocPath)
local listed = {}
local tocEntries = {}
for line in file:lines() do
    local entry = line:match("^(%S+%.lua)%s*$")
    if entry then
        listed[entry:gsub("/", "\\")] = true
        listed[entry] = true
        tocEntries[#tocEntries + 1] = entry
    end
end
file:close()

local missing = {}
local handles = {
    -- `srcRoot` is honored so the guard works from any checkout root (Unix CI).
    io.popen(("find %s -name \"*.lua\" 2>/dev/null"):format(srcRoot)),
}
for _, handle in ipairs(handles) do
    if handle then
        for path in handle:lines() do
            -- `find .` prefixes entries with ./; TOC entries are root-relative.
            path = path:gsub("^%./", "")
            if not listed[path] then
                missing[#missing + 1] = path
            end
        end
        handle:close()
    end
end

if #missing > 0 then
    io.stderr:write("lua files present under " .. srcRoot .. " but missing from the TOC:\n")
    for _, path in ipairs(missing) do
        io.stderr:write("  " .. path .. "\n")
    end
    os.exit(1)
end

-- Reverse check: the TOC is relative to its own folder; every listed file
-- must exist there or the client hard-errors at load.
local tocDir = tocPath:match("^(.*)[/\\][^/\\]+$") or "."
local absent = {}
for _, entry in ipairs(tocEntries) do
    local handle = io.open(tocDir .. "/" .. entry, "r")
    if handle then
        handle:close()
    else
        absent[#absent + 1] = entry
    end
end

if #absent > 0 then
    io.stderr:write("files listed in " .. tocPath .. " but missing on disk:\n")
    for _, path in ipairs(absent) do
        io.stderr:write("  " .. path .. "\n")
    end
    os.exit(1)
end

print(("toc coverage ok: every lua file under %s is listed and every TOC entry exists"):format(srcRoot))

-- luacheck: globals assert
-- Minimal busted-compatible harness shim so the specs can run with any plain
-- Lua interpreter (5.1+) without native rocks. CI still uses real busted; this
-- exists for quick local verification on machines without a compiler toolchain.
--
-- Busted parity: spec files are only LOADED first (collection phase, which
-- registers every it-block), and tests run after ALL files are loaded with `_G`
-- shared across files. Load-time-only global stubs therefore do not survive
-- into the run phase — exactly like busted — so specs must manage stubs with
-- before_each/after_each to stay green locally and in CI.
--
-- Usage: lua scripts/run_tests.lua <spec file> [...]

local passed, failures = 0, 0

-- Module resolution: specs require the `AuctiMogger.*` namespace, which the
-- default `./?.lua` path resolves from the repo root (AuctiMogger/domain/…).
package.path = "./?.lua;./?/init.lua;" .. package.path

if not arg or #arg == 0 then
    io.stderr:write("usage: lua scripts/run_tests.lua <spec file> [...]")
    os.exit(1)
end

-- Describe frames collect their own before/after lists (busted semantics) and
-- an it-block runs its whole active frame chain, outermost first.
local hookStack = { { before = {}, after = {} } }
local queue = {}

--- Define a suite frame: the body runs immediately (collection phase) and
--- its before_each/after_each calls attach to this frame.
---@param name string suite title, printed by the harness
---@param fn fun() suite body; registers nested blocks and hooks
function describe(name, fn)
    print(name)
    local frame = { before = {}, after = {} }
    hookStack[#hookStack + 1] = frame
    fn()
    hookStack[#hookStack] = nil
end

--- Register a hook run before every it-block of the current frame.
---@param fn fun()
function before_each(fn)
    hookStack[#hookStack].before[#hookStack[#hookStack].before + 1] = fn
end

--- Register a hook run after every it-block of the current frame.
---@param fn fun()
function after_each(fn)
    hookStack[#hookStack].after[#hookStack[#hookStack].after + 1] = fn
end

--- busted alias for before_each.
---@param fn fun()
function setup(fn)
    before_each(fn)
end

--- busted alias for after_each.
---@param fn fun()
function teardown(fn)
    after_each(fn)
end

--- Registration only: cases run after every file has been loaded.
---@param name string case title, printed by the harness
---@param fn fun() case body, invoked with no arguments at run time
function it(name, fn)
    local chain = {}
    for i = 1, #hookStack do
        chain[i] = hookStack[i]
    end
    queue[#queue + 1] = { name = name, fn = fn, chain = chain }
end

-- Replace the global assert with a callable table: direct assert(...) calls
-- still work (via __call), busted-style assertions come via __index.
local shim = {}

--- busted-style equality: fails (level 2) unless both values are equal.
---@param actual any value produced by the code under test
---@param expected any value it is expected to equal
function shim.equals(actual, expected)
    -- busted argument order: (actual, expected)
    if actual ~= expected then
        error(("expected %s, got %s"):format(tostring(expected), tostring(actual)), 2)
    end
end

--- Fails unless `value` is exactly `true`.
---@param value any
function shim.is_true(value)
    if value ~= true then
        error("expected true, got " .. tostring(value), 2)
    end
end

--- Fails unless `value` is exactly `false`.
---@param value any
function shim.is_false(value)
    if value ~= false then
        error("expected false, got " .. tostring(value), 2)
    end
end

--- busted-style nil check: fails (level 2) unless the value is exactly nil.
---@param value any
function shim.is_nil(value)
    if value ~= nil then
        error("expected nil, got " .. tostring(value), 2)
    end
end

--- busted-style non-nil check: fails (level 2) when the value is nil.
---@param value any
function shim.is_not_nil(value)
    if value == nil then
        error("expected a value other than nil, got nil", 2)
    end
end

--- busted-style inequality: fails (level 2) when both values are equal.
---@param actual any value produced by the code under test
---@param expected any value it is expected to differ from
function shim.not_equals(actual, expected)
    -- busted argument order: (actual, expected)
    if actual == expected then
        error(("expected any value but %s, got %s"):format(tostring(expected), tostring(actual)), 2)
    end
end

assert = setmetatable({}, {
    --- Raw assert: fails with `message` (or a default) when `value` is falsy
    --- or `nil`, and returns `value` on success.
    ---@param _ table the assert shim itself (via __call)
    ---@param value any condition to check
    ---@param message string|nil custom failure message
    __call = function(_, value, message)
        if not value then
            error(message or "assertion failed", 2)
        end
        return value
    end,
    __index = shim,
})

-- Collection phase: load every file so top-level requires, module captures and
-- stubs run once, in one shared environment, before any test executes.
for _, path in ipairs(arg) do
    local chunk, err = loadfile(path)
    if not chunk then
        failures = failures + 1
        print("[FAIL] loading " .. path .. " -> " .. tostring(err))
    else
        chunk()
    end
end

-- Run phase: every registered it-block, with the hooks of its frame chain.
for _, case in ipairs(queue) do
    local ok, err = pcall(function()
        for i = 1, #case.chain do
            for _, hook in ipairs(case.chain[i].before) do
                hook()
            end
        end
        case.fn()
        for i = #case.chain, 1, -1 do
            for _, hook in ipairs(case.chain[i].after) do
                hook()
            end
        end
    end)
    if ok then
        passed = passed + 1
        print("  [ok]   " .. case.name)
    else
        failures = failures + 1
        print("  [FAIL] " .. case.name .. " -> " .. tostring(err))
    end
end

print(("\n%d passed, %d failed"):format(passed, failures))
os.exit(failures > 0 and 1 or 0)

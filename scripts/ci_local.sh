#!/usr/bin/env bash
# Local CI parity: one command that runs every gate of
# .github/workflows/ci.yml with the same pinned tool versions.
#
#   bash scripts/ci_local.sh
#
# Gates and where they run:
#   stylua --check .      vendored Windows binary (tools/stylua)
#   luacheck .            real luacheck 1.2.0 inside WSL (user rock tree)
#   busted --verbose      real busted 2.2.0 inside WSL (user rock tree)
#   TOC coverage check    WSL lua (needs a Unix walk, like CI)
#   compat manifest guard plain lua (pure Lua 5.1, no rocks)
#   lua-language-server   vendored Windows binary (tools/lls)
#
# The WSL gates use the user rock tree (~/.luarocks): no sudo, and no
# network — the pinned rocks are vendored offline in tools/wsl-rocks/
# and installed on first run.
set -euo pipefail
cd "$(dirname "$0")/.."

ROCKS=(
    luafilesystem-1.8.0-1
    argparse-0.7.1-1
    lua_cliargs-3.0-2
    luasystem-0.3.0-1
    say-1.4.1-3
    luassert-1.9.0-1
    penlight-1.13.1-1
    luacheck-1.2.0-1
    busted-2.2.0-1
)

if [[ "$(uname -s)" == Linux* ]]; then
    # Already inside WSL/another Linux: run the Unix gates natively.
    eval "$(luarocks path --lua-version=5.1)"
    export PATH="$HOME/.luarocks/bin:$PATH"
    echo "== luacheck (pinned 1.2.0)"
    luacheck .
    echo "== busted (pinned 2.2.0)"
    busted --verbose
    echo "== TOC coverage"
    (
        cd VersaMerchantSniper
        lua ../scripts/check_toc.lua VersaMerchantSniper.toc
    )
    echo "== compat manifest guard"
    lua scripts/check_compat.lua
    echo "== stylua + LuaLS are vendored as Windows binaries; run them from Windows"
    exit 0
fi

command -v wsl.exe >/dev/null 2>&1 || {
    echo "error: WSL is required for the luacheck/busted/TOC gates" >&2
    exit 2
}

# Translate the Windows cwd (D:/Dev/... ) to the WSL mount (/mnt/d/Dev/...).
win="$(pwd -W 2>/dev/null || pwd)"
lin="/mnt/$(printf %s "${win:0:1}" | tr 'A-Z' 'a-z')${win:2}"

# Run a command inside WSL at the repo mount, with the user rock tree active.
wsl_run() {
    wsl.exe -e bash -lc 'eval "$(luarocks path --lua-version=5.1)"; export PATH="$HOME/.luarocks/bin:$PATH"; cd "'"$lin"'" || exit 1; '"$1"
}

echo "== luacheck (pinned 1.2.0, WSL)"
wsl_run '
if ! command -v luacheck >/dev/null 2>&1 || ! busted --version >/dev/null 2>&1; then
    echo "[ci_local] bootstrapping pinned rocks from tools/wsl-rocks (offline)..."
    cd tools/wsl-rocks
    for r in '"${ROCKS[*]}"'; do
        luarocks install --local --deps-mode=none "$r.src.rock" >/dev/null
    done
    (cd lua-term-0.08 && luarocks make --local --deps-mode=none >/dev/null)
    (cd mediator_lua-1.1.2-0 && luarocks make --local --deps-mode=none >/dev/null)
    cd ../..
fi
luacheck .'

echo "== busted (pinned 2.2.0, WSL)"
wsl_run 'busted --verbose'

echo "== TOC coverage (WSL)"
wsl_run 'cd VersaMerchantSniper && lua ../scripts/check_toc.lua VersaMerchantSniper.toc'

echo "== compat manifest guard"
wsl_run 'lua scripts/check_compat.lua'

echo "== stylua --check (2.6.0)"
tools/stylua/stylua.exe --check .

echo "== lua-language-server (3.19.1, checklevel=Warning)"
# Same invocation as ci.yml: stdout IS the report. (--out= writes a different
# summary file that assert_lls_clean cannot parse and that reports 0 problems
# even when stdout lists diagnostics.)
tools/lls/bin/lua-language-server.exe --check=./ --checklevel=Warning > ./lls.log 2>&1 || true
lua scripts/assert_lls_clean.lua ./lls.log

echo "ci_local: all gates passed"

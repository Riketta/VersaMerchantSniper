#!/usr/bin/env bash
# One-time bootstrap for the gitignored local CI toolchain (Windows host).
#
#   bash scripts/bootstrap-tools.sh
#
# Fetches the pinned Windows binaries scripts/ci_local.sh expects from the
# official GitHub releases, verifying pinned sha256 checksums:
#   StyLua 2.6.0              -> tools/stylua/stylua.exe
#   lua-language-server 3.19.1 -> tools/lls/ (bin/lua-language-server.exe + runtime)
#
# NOT downloaded (offline-vendored, see ci_local.sh): the WSL rock tree in
# tools/wsl-rocks/ - instructions are printed below instead.
set -euo pipefail
cd "$(dirname "$0")/.."

STYLUA_VERSION=2.6.0
STYLUA_URL="https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-windows-x86_64.zip"
STYLUA_SHA256=fd13b4014e3b779c244bbc03f2c282e357f15bc526de6a6fa5ecbc447538313c

LLS_VERSION=3.19.1
LLS_URL="https://github.com/LuaLS/lua-language-server/releases/download/${LLS_VERSION}/lua-language-server-${LLS_VERSION}-win32-x64.zip"
LLS_SHA256=fdb9a59108cf62517813c97fa5549b0e16d1ef0688306bac728b08434db7e4cd

command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required (bundled with Git for Windows)" >&2
    exit 2
}

# sha256 of a file: sha256sum when present (Git Bash/WSL), else certutil
# (always available on Windows).
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        certutil -hashfile "$(cygpath -w "$1")" SHA256 | sed -n 2p | tr -d ' \r'
        # normalize to lowercase (certutil prints uppercase)
    fi
}

unzip_into() {
    # unzip_into <zip> <target-dir>
    if command -v unzip >/dev/null 2>&1; then
        unzip -o -q "$1" -d "$2"
    else
        powershell.exe -NoProfile -Command "\$d='$2' -replace '/', '\\'; Expand-Archive -Force -Path '$1' -DestinationPath \$d"
    fi
}

fetch_and_check() {
    # fetch_and_check <url> <expected-sha256> <dest-zip>
    echo "[bootstrap-tools] downloading $(basename "$3") ..."
    curl -fL --retry 3 -o "$3" "$1"
    local actual
    actual=$(sha256_of "$3")
    if [ "$(printf %s "$actual" | tr 'A-Z' 'a-z')" != "$(printf %s "$2" | tr 'A-Z' 'a-z')" ]; then
        echo "error: checksum mismatch for $3" >&2
        echo "  expected: $2" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

mkdir -p tools/stylua tools/lls

# --- StyLua -----------------------------------------------------------------
if tools/stylua/stylua.exe --version 2>/dev/null | grep -q "$STYLUA_VERSION"; then
    echo "[bootstrap-tools] stylua $STYLUA_VERSION already present"
else
    tmp=$(mktemp -d)
    fetch_and_check "$STYLUA_URL" "$STYLUA_SHA256" "$tmp/stylua.zip"
    unzip_into "$tmp/stylua.zip" tools/stylua
    rm -rf "$tmp"
    tools/stylua/stylua.exe --version
fi

# --- lua-language-server ----------------------------------------------------
# The release zip's root already has bin/ (exe + runtime dlls + main.lua);
# extracting it INTO tools/lls yields exactly the tools/lls/bin/... layout
# ci_local.sh invokes.
if tools/lls/bin/lua-language-server.exe --version 2>/dev/null | grep -q "$LLS_VERSION"; then
    echo "[bootstrap-tools] lua-language-server $LLS_VERSION already present"
else
    tmp=$(mktemp -d)
    fetch_and_check "$LLS_URL" "$LLS_SHA256" "$tmp/lls.zip"
    unzip_into "$tmp/lls.zip" tools/lls
    rm -rf "$tmp"
    tools/lls/bin/lua-language-server.exe --version
fi

# --- WSL rocks (vendored offline; NOT downloadable silently) -----------------
if [ -d tools/wsl-rocks ]; then
    echo "[bootstrap-tools] tools/wsl-rocks present"
else
    cat <<'EOF'

[bootstrap-tools] NOTE: tools/wsl-rocks/ is missing. ci_local.sh runs the
luacheck/busted/TOC gates inside WSL and installs the pinned rocks from that
vendored tree on first run (no network). If your WSL user rock tree
(~/.luarocks, lua 5.1) already has luacheck 1.2.0 + busted 2.2.0 + their
dependencies, you can ignore this and run ci_local.sh as-is. Otherwise
populate tools/wsl-rocks/ with:

  *.src.rock files (from luarocks.org, exact pinned versions):
    luafilesystem-1.8.0-1.src.rock
    argparse-0.7.1-1.src.rock
    lua_cliargs-3.0-2.src.rock
    luasystem-0.3.0-1.src.rock
    say-1.4.1-3.src.rock
    luassert-1.9.0-1.src.rock
    penlight-1.13.1-1.src.rock
    luacheck-1.2.0-1.src.rock
    busted-2.2.0-1.src.rock
  plus unpacked source dirs (installed via `luarocks make` by ci_local.sh):
    lua-term-0.08/
    mediator_lua-1.1.2-0/

EOF
fi

echo "bootstrap-tools: done - bash scripts/ci_local.sh runs the full gate"

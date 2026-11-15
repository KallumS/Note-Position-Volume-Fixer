#!/bin/sh
# Every suite: the page's engine, the REAPER scripts' Lua, the two against each other,
# the REAPER windows in the mock, and the page in Chromium.
set -e
cd "$(dirname "$0")/.."
echo "== engine";            node tests/run_tests.js | tail -1
echo "== lua";               lua5.4 tests/lua/test_fix.lua | tail -1
echo "== maps";              lua5.4 tests/lua/test_maps.lua | tail -1
echo "== lua vs engine";     node tests/lua_parity.js | tail -1
echo "== REAPER windows";    lua5.4 tests/lua/test_scripts.lua | tail -1
echo "== page";              node tools/build.js >/dev/null && NODE_PATH=$(npm root -g) node tests/ui_test.js | tail -1

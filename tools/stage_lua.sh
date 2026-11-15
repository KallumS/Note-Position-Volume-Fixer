#!/bin/sh
# Copies the Lua the Mac app runs into one folder: the shared modules from reaper/ and the app's own API.
#   sh tools/stage_lua.sh <folder>
set -e
cd "$(dirname "$0")/.."
out="$1"
[ -n "$out" ] || { echo "usage: stage_lua.sh <folder>" >&2; exit 2; }
mkdir -p "$out"
for f in npvf_json.lua npvf_measure.lua npvf_maps.lua npvf_library.lua; do cp "reaper/$f" "$out/"; done
cp mac/Lua/npvf_app.lua "$out/"

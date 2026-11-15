#!/bin/sh
# Builds "Note Fixer.app" for Apple Silicon, signs it ad hoc and zips it with the install notes.
# Runs on a Mac (GitHub Actions' macos-14): sh mac/build-app.sh
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/mac/build"
APP="$OUT/Note Fixer.app"

(cd mac && swift build -c release --arch arm64)
BIN=$(cd mac && swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NoteFixer" "$APP/Contents/MacOS/NoteFixer"
cp mac/Info.plist "$APP/Contents/Info.plist"
sh tools/stage_lua.sh "$APP/Contents/Resources/lua"
cp Note-Position-Volume-Fixer.html "$APP/Contents/Resources/"
cp mac/Sources/CLua/LICENSE-Lua.txt "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

# Ad hoc: no Apple Developer ID here, so macOS asks once before opening it (INSTALL-MAC.txt).
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$OUT/NoteFixer-macOS.zip"
mkdir -p "$OUT/zip"
rm -rf "$OUT/zip/"*
cp -R "$APP" "$OUT/zip/"
cp mac/INSTALL-MAC.txt "$OUT/zip/"
(cd "$OUT/zip" && ditto -c -k --sequesterRsrc --keepParent . ../NoteFixer-macOS.zip >/dev/null 2>&1 || ditto -c -k . ../NoteFixer-macOS.zip)
echo "built $APP and $OUT/NoteFixer-macOS.zip"

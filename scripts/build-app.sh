#!/bin/bash
# Builds "Display Buddy Free.app" (runs on a Mac, used by the GitHub build).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
APP="build/Display Buddy Free.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DisplayBuddy"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DisplayBuddyFree"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# "Ad-hoc" signature: free, lets macOS run the app on Apple Silicon.
codesign --force --deep --sign - "$APP"

(cd build && ditto -c -k --keepParent "Display Buddy Free.app" "DisplayBuddy.zip")
echo "Built build/DisplayBuddy.zip"

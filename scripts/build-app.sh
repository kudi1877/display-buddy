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

# Signing identity: $SIGN_IDENTITY, else the first line of the (git-ignored)
# scripts/signing-identity.local, else an "ad-hoc" signature (free, used by the
# GitHub build). An ad-hoc signature changes with every build, so macOS forgets
# the Accessibility and Automation permissions after each update; signing local
# builds with one fixed certificate keeps them.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f scripts/signing-identity.local ]; then
    IDENTITY="$(head -n 1 scripts/signing-identity.local | tr -d '[:space:]')"
fi
if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP"
    echo "Signed with $IDENTITY"
else
    [ -n "$IDENTITY" ] && echo "Signing identity $IDENTITY not found; using an ad-hoc signature."
    codesign --force --deep --sign - "$APP"
fi

(cd build && ditto -c -k --keepParent "Display Buddy Free.app" "DisplayBuddy.zip")
echo "Built build/DisplayBuddy.zip"

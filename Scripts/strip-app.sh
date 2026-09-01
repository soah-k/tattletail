#!/bin/bash
# Strip the debug symbols from a built .app's executable and re-sign ad-hoc.
#
# `xcodebuild build` (unlike `archive`) never strips, so the shipped binary
# carries ~3 MB of dead symbol tables. Stripping cuts the universal binary
# by ~60%. strip invalidates the code signature, so we re-sign afterward
# (ad-hoc here; a Developer ID build re-signs during export instead).
#
# Usage: Scripts/strip-app.sh <path/to/App.app> <path/to/entitlements>

set -euo pipefail

APP="${1:?usage: strip-app.sh <App.app> <entitlements>}"
ENTITLEMENTS="${2:?usage: strip-app.sh <App.app> <entitlements>}"

EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
BIN="$APP/Contents/MacOS/$EXEC"

before=$(stat -f%z "$BIN")
strip -rSTx "$BIN"
# Re-sign (strip invalidated the signature). Keep the hardened runtime.
codesign --force --options runtime --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$APP"
after=$(stat -f%z "$BIN")

echo "Stripped $EXEC: $before → $after bytes ($(( (before - after) * 100 / before ))% smaller)"

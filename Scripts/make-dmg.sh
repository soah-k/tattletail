#!/bin/bash
# Package a built Tattletail.app into a distributable DMG.
#
# Usage: Scripts/make-dmg.sh <path/to/Tattletail.app> <output.dmg> [volume-name]
#
# The disk-image volume name defaults to "Tattletail" but can be overridden by
# a third positional argument or the VOLUME_NAME env var (positional wins), so
# the same script packages either edition. The output path is the second arg.
#
# Uses plain hdiutil (no Finder/AppleScript) so it works on headless CI
# runners, with a retry loop for hdiutil's occasional transient
# "resource busy" failures on GitHub-hosted macOS runners.

set -euo pipefail

APP="${1:?usage: make-dmg.sh <Tattletail.app> <output.dmg> [volume-name]}"
OUT="${2:?usage: make-dmg.sh <Tattletail.app> <output.dmg> [volume-name]}"
VOLUME_NAME="${3:-${VOLUME_NAME:-Tattletail}}"

[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
for attempt in $(seq 1 10); do
  if hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT"; then
    echo "Created $OUT (volume: $VOLUME_NAME)"
    exit 0
  fi
  echo "hdiutil failed (attempt $attempt), retrying in 3s…" >&2
  sleep 3
done

echo "error: hdiutil failed after 10 attempts" >&2
exit 1

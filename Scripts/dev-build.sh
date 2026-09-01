#!/bin/bash
# Dev build for Tattletail using only Command Line Tools (no Xcode required).
#
# Compiles a universal (arm64 + x86_64) binary with swiftc, assembles a proper
# .app bundle (Info.plist, icns icon), and signs it.
#
# Signing: if a valid "Apple Development" identity is in the keychain it is used
# (a stable Designated Requirement, so Accessibility + Input Monitoring grants
# PERSIST across rebuilds). Otherwise it falls back to ad-hoc signing, which
# macOS treats as a new app every rebuild — meaning you re-grant permissions
# each time. Create the stable identity with a free Apple ID in
# Xcode → Settings → Accounts.
#
# First signed build with a real identity may pop a keychain prompt
# ("codesign wants to use a key…"); click "Always Allow" once and every later
# build is silent. To avoid the prompt entirely, run once:
#   security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
#     -k "<your login password>" ~/Library/Keychains/login.keychain-db
#
# Once Xcode is installed you can also use:
#   xcodegen generate && xcodebuild -project Tattletail.xcodeproj \
#     -scheme Tattletail -configuration Debug build
# which additionally compiles the asset catalog.

set -euo pipefail
cd "$(dirname "$0")/.."

# --- Edition selection -----------------------------------------------------
# Default build = the full (paid) app. Pass --free (or set TT_FREE=1) to build
# the free edition: it defines FREE_BUILD for swiftc and drops the paid-only
# sources under Tattletail/Paid/ from the compile. Everything else — bundle id,
# product name, output path, signing — is identical between editions, since a
# paid install replaces the free one in place.
FREE="${TT_FREE:-0}"
for arg in "$@"; do
  case "$arg" in
    --free) FREE=1 ;;
    -h|--help)
      echo "usage: dev-build.sh [--free]"; exit 0 ;;
    *)
      echo "error: unknown argument '$arg' (usage: dev-build.sh [--free])" >&2
      exit 2 ;;
  esac
done

# If the paid boundary is absent, this checkout can ONLY be the free edition
# (e.g. the public open-source repo, where Tattletail/Paid/ is never synced).
# Force FREE_BUILD so the shared `#if !FREE_BUILD` glue compiles out instead of
# referencing paid symbols that don't exist here.
if [ ! -d "Tattletail/Paid" ]; then FREE=1; fi

BUILD_DIR="build/dev"
APP="$BUILD_DIR/Tattletail.app"
BUNDLE_ID="com.soahk.Tattletail"
# Read the version from project.yml (single source of truth) so the dev build's
# About box matches release builds.
MARKETING_VERSION="$(awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' project.yml)"
BUILD_NUMBER="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/{print $2; exit}' project.yml)"

# Assemble the compile inputs. The default build compiles every Swift file one
# level under Tattletail/ (Tattletail/*/*.swift). The free edition additionally
# excludes the paid boundary Tattletail/Paid/** and defines FREE_BUILD. In the
# default (paid) build DEFINES is empty and every source is kept, so the swiftc
# invocations are byte-for-byte identical to before.
DEFINES=()
if [ "$FREE" = 1 ]; then
  DEFINES=(-D FREE_BUILD)
  echo "==> Free edition (defines FREE_BUILD; excluding Tattletail/Paid/)"
fi

SOURCES=()
for f in Tattletail/*/*.swift; do
  if [ "$FREE" = 1 ]; then
    case "$f" in Tattletail/Paid/*) continue ;; esac
  fi
  SOURCES+=("$f")
done

echo "==> Compiling arm64…"
mkdir -p "$BUILD_DIR"
swiftc -O -parse-as-library -target arm64-apple-macosx26.0 \
  ${DEFINES[@]+"${DEFINES[@]}"} \
  -o "$BUILD_DIR/Tattletail-arm64" "${SOURCES[@]}"

echo "==> Compiling x86_64…"
swiftc -O -parse-as-library -target x86_64-apple-macosx26.0 \
  ${DEFINES[@]+"${DEFINES[@]}"} \
  -o "$BUILD_DIR/Tattletail-x86_64" "${SOURCES[@]}"

echo "==> Creating universal binary…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD_DIR/Tattletail-arm64" "$BUILD_DIR/Tattletail-x86_64" \
  -output "$APP/Contents/MacOS/Tattletail"
lipo -info "$APP/Contents/MacOS/Tattletail"

echo "==> Building icon (.icns)…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
SRC="Tattletail/Resources/Assets.xcassets/AppIcon.appiconset"
for f in "$SRC"/icon_*.png; do
  cp "$f" "$ICONSET/$(basename "$f")"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist…"
sed -e 's/\$(EXECUTABLE_NAME)/Tattletail/' \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e 's/\$(PRODUCT_NAME)/Tattletail/' \
    -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" \
    -e 's/\$(MACOSX_DEPLOYMENT_TARGET)/26.0/' \
    Tattletail/Resources/Info.plist > "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
echo 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer the Developer ID Application identity so local builds share the SAME
# code-signing Designated Requirement as notarized releases (identifier + Team
# ID based). TCC grants (Accessibility + Input Monitoring) then persist across
# local rebuilds AND between local builds and installed releases. Locally-built
# apps aren't quarantined, so an un-notarized Developer ID build still launches.
# Fall back to a free "Apple Development" identity, then ad-hoc.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/{print $2; exit}')
fi

if [ -n "${SIGN_ID:-}" ]; then
  echo "==> Signing with stable identity: $SIGN_ID"
  codesign --force --timestamp=none \
    --sign "$SIGN_ID" \
    --entitlements Tattletail/Resources/Tattletail.entitlements \
    "$APP"
else
  echo "==> Signing (ad-hoc — no Apple Development identity found; permissions will re-prompt each rebuild)…"
  codesign --force --sign - \
    --entitlements Tattletail/Resources/Tattletail.entitlements \
    "$APP"
fi
codesign --verify --strict "$APP" && echo "signature OK"

echo
echo "Built: $APP"
echo "Run with: open \"$APP\""

#!/bin/bash
#
#  PinWall — build, sign, and package a distributable DMG.
#
#  Auto-detects a "Developer ID Application" cert:
#    • present  -> signs with it + hardened runtime + timestamp, then notarizes
#                  and staples the DMG (needs a stored notary profile, see below).
#    • absent   -> ad-hoc signs (runs on THIS Mac; other Macs will show Gatekeeper
#                  warnings until you notarize). See scripts/NOTARIZE.md.
#
#  Usage:  bash scripts/package.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."          # -> app/

APP=PinWall
CONFIG=Release
DERIVED=build
PRODUCT="$DERIVED/Build/Products/$CONFIG/$APP.app"
SAVER="$PRODUCT/Contents/Resources/$APP.saver"
DIST=dist
DMG="$DIST/$APP.dmg"
NOTARY_PROFILE="PinWall"          # created via: xcrun notarytool store-credentials

# --- pick a signing identity ------------------------------------------------
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -n "${IDENTITY:-}" ]; then
  echo "==> Signing with Developer ID: $IDENTITY"
  SIGN=(--force --options runtime --timestamp -s "$IDENTITY")
  NOTARIZE=1
else
  echo "==> No 'Developer ID Application' cert — ad-hoc signing (local use only)."
  SIGN=(--force --options runtime -s -)
  NOTARIZE=0
fi

# --- build ------------------------------------------------------------------
echo "==> Generating project + building $CONFIG…"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project "$APP.xcodeproj" -scheme "$APP" -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build >/dev/null

# --- sign (inner-out) -------------------------------------------------------
echo "==> Signing (inner-out)…"
codesign "${SIGN[@]}" "$SAVER/Contents/MacOS/$APP"
codesign "${SIGN[@]}" "$SAVER"
codesign "${SIGN[@]}" "$PRODUCT"
codesign --verify --strict "$PRODUCT" && echo "    signature OK"

# --- build the DMG ----------------------------------------------------------
echo "==> Building DMG…"
rm -rf "$DIST/stage" "$DMG"; mkdir -p "$DIST/stage"
cp -R "$PRODUCT" "$DIST/stage/"
ln -s /Applications "$DIST/stage/Applications"
hdiutil create -volname "$APP" -srcfolder "$DIST/stage" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/stage"
echo "    $DMG"

# --- notarize (only with a Developer ID cert + stored profile) --------------
if [ "$NOTARIZE" = "1" ]; then
  echo "==> Notarizing (profile: $NOTARY_PROFILE)…"
  codesign "${SIGN[@]}" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG" && echo "    notarized + stapled ✓"
else
  echo "==> Skipped notarization (no Developer ID cert). See scripts/NOTARIZE.md"
fi

echo "DONE → $DMG"

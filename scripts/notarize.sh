#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Notarizes dist/Lanthorn.app (built by scripts/bundle.sh with a Developer ID) and writes dist/Lanthorn-<version>.dmg.
#   NOTARY_PROFILE=<notarytool keychain profile>  (xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password <app-specific>)
#   scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP=dist/Lanthorn.app
PROFILE=${NOTARY_PROFILE:?set NOTARY_PROFILE to the notarytool keychain profile name}
[[ -d "$APP" ]] || { echo "build first: CODESIGN_IDENTITY='Developer ID Application: …' scripts/bundle.sh"; exit 1; }
codesign --display --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "$APP is not signed with a Developer ID (ad-hoc builds cannot be notarized)"; exit 1; }
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
DMG="dist/Lanthorn-$VERSION.dmg"
rm -f "$DMG" dist/Lanthorn.zip
ditto -c -k --keepParent "$APP" dist/Lanthorn.zip
xcrun notarytool submit dist/Lanthorn.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
hdiutil create -volname "Lanthorn $VERSION" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
rm -f dist/Lanthorn.zip
echo "notarized and stapled: $APP and $DMG"

#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Assembles dist/Lanthorn.app from SwiftPM products and web/dist, then signs it.
#   CONFIG=debug|release (default release)   CODESIGN_IDENTITY="Developer ID Application: …" (default ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION=$(sed -n 's/.*public static let string = "\(.*\)"/\1/p' Sources/LanthornCore/Attribution.swift)

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)
if [[ ! -f web/dist/index.html || "${WEB_BUILD:-1}" == 1 ]]; then (cd web && npm run build); fi

APP=dist/Lanthorn.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/LanthornShell" "$APP/Contents/MacOS/Lanthorn"
cp "$BIN/lanthornd" "$APP/Contents/MacOS/lanthornd"
cp -R web/dist "$APP/Contents/Resources/web"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.lanthorn.app</string>
  <key>CFBundleName</key><string>Lanthorn</string>
  <key>CFBundleDisplayName</key><string>Lanthorn</string>
  <key>CFBundleExecutable</key><string>Lanthorn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Tim de Bruijn. GPL-3.0-only with additional terms.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSMicrophoneUsageDescription</key><string>Lanthorn reads LTC timecode from an audio input when you select one under Show › Timecode.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Lanthorn receives Art-Net, sACN and OSC from your lighting console and announces itself to consoles over CITP and Bonjour.</string>
  <key>NSBonjourServices</key><array><string>_lanthorn._tcp</string></array>
</dict></plist>
PLIST

cat > "$APP/Contents/Library/LaunchAgents/org.lanthorn.engine.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.lanthorn.engine</string>
  <key>BundleProgram</key><string>Contents/MacOS/lanthornd</string>
  <key>AssociatedBundleIdentifiers</key><string>org.lanthorn.app</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST

# The agent shares the app's Info.plist keys (usage strings) through the bundle; it gets the same entitlements.
cp scripts/entitlements.plist "$APP/Contents/Resources/entitlements.plist"
IDENTITY=${CODESIGN_IDENTITY:--}
SIGN=(codesign --force --sign "$IDENTITY" --options runtime --entitlements scripts/entitlements.plist)
[[ "$IDENTITY" != "-" ]] && SIGN+=(--timestamp)
"${SIGN[@]}" "$APP/Contents/MacOS/lanthornd"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "built $APP ($VERSION, signed with: $IDENTITY, hardened runtime)"

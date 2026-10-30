#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
# Assembles dist/Fanous.app from SwiftPM products and web/dist, then signs it.
#   CONFIG=debug|release (default release)   CODESIGN_IDENTITY="Developer ID Application: …" (default ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION=$(sed -n 's/.*public static let string = "\(.*\)"/\1/p' Sources/FanousCore/Attribution.swift)

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)
if [[ ! -f web/dist/index.html || "${WEB_BUILD:-1}" == 1 ]]; then (cd web && npm run build); fi

APP=dist/Fanous.app
rm -rf "$APP"
# The engine is a helper app with its own bundle id (org.fanous.engine): inside the main bundle's Contents/MacOS it
# registered with LaunchServices as org.fanous.app, and opening the app only activated the window-less engine.
HELPER="$APP/Contents/Helpers/FanousEngine.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" "$HELPER/Contents/MacOS"
cp "$BIN/FanousShell" "$APP/Contents/MacOS/Fanous"
cp "$BIN/fanousd" "$HELPER/Contents/MacOS/fanousd"
cp -R web/dist "$APP/Contents/Resources/web"
cp assets/Fanous.icns "$APP/Contents/Resources/Fanous.icns"
# license texts travel with the binary (GPL, our §7 terms, BSD/Apache notices of what is compiled in)
L="$APP/Contents/Resources/licenses"
mkdir -p "$L"
cp LICENSE LICENSE-ADDITIONAL-TERMS.md THIRD-PARTY-NOTICES.md "$L/"
cp Sources/CHap/LICENSE "$L/hap-LICENSE.txt"
cp Sources/CSnappy/LICENSE "$L/snappy-LICENSE.txt"
cp Sources/Syphon/LICENSE "$L/Syphon-LICENSE.txt"
SWIFT_LOG_LICENSE=$(find .build/checkouts/swift-log -maxdepth 1 -name "LICENSE*" | head -1)
[[ -n "$SWIFT_LOG_LICENSE" ]] && cp "$SWIFT_LOG_LICENSE" "$L/swift-log-LICENSE.txt"
cp web/node_modules/svelte/LICENSE.md "$L/svelte-LICENSE.md"  # the Svelte runtime is compiled into the web UI

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.fanous.app</string>
  <key>CFBundleName</key><string>Fanous</string>
  <key>CFBundleDisplayName</key><string>Fanous</string>
  <key>CFBundleExecutable</key><string>Fanous</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Tim de Bruijn. GPL-3.0-only with additional terms.</string>
  <key>CFBundleIconFile</key><string>Fanous</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSMicrophoneUsageDescription</key><string>Fanous reads LTC timecode from an audio input when you select one under Show › Timecode.</string>
  <key>NSCameraUsageDescription</key><string>Fanous shows a camera or capture card as layer content when you select one in folder 0.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Fanous receives Art-Net, sACN and OSC from your lighting console and announces itself to consoles over CITP and Bonjour.</string>
  <key>NSBonjourServices</key><array><string>_fanous._tcp</string><string>_https._tcp</string></array>
</dict></plist>
PLIST

cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.fanous.engine</string>
  <key>CFBundleName</key><string>Fanous Engine</string>
  <key>CFBundleExecutable</key><string>fanousd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Fanous reads LTC timecode from an audio input when you select one under Show › Timecode.</string>
  <key>NSCameraUsageDescription</key><string>Fanous shows a camera or capture card as layer content when you select one in folder 0.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Fanous receives Art-Net, sACN and OSC from your lighting console and announces itself to consoles over CITP and Bonjour.</string>
  <key>NSBonjourServices</key><array><string>_fanous._tcp</string><string>_https._tcp</string></array>
</dict></plist>
PLIST

cat > "$APP/Contents/Library/LaunchAgents/org.fanous.engine.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.fanous.engine</string>
  <key>BundleProgram</key><string>Contents/Helpers/FanousEngine.app/Contents/MacOS/fanousd</string>
  <key>AssociatedBundleIdentifiers</key><string>org.fanous.app</string>
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
"${SIGN[@]}" "$HELPER"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "built $APP ($VERSION, signed with: $IDENTITY, hardened runtime)"

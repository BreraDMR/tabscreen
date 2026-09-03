#!/bin/bash
# Builds TabScreen.app - the whole Mac side in one bundle: capture, encoder, server, UI.
set -e
cd "$(dirname "$0")"

APP=TabScreen.app
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library \
  -o "$APP/Contents/MacOS/TabScreen" \
  TabScreen/App.swift TabScreen/Strings.swift TabScreen/Capture.swift TabScreen/Server.swift TabScreen/VirtualDisplay.swift \
  -framework ScreenCaptureKit -framework VideoToolbox -framework CoreMedia \
  -framework SwiftUI -framework AppKit -framework Network

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TabScreen</string>
    <key>CFBundleIdentifier</key><string>com.tabscreen.mac</string>
    <key>CFBundleName</key><string>TabScreen</string>
    <key>CFBundleDisplayName</key><string>TabScreen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>TabScreen показывает выбранный экран на планшете</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>TabScreen передаёт картинку планшету в вашей локальной сети</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
echo "собрано: $(pwd)/$APP"

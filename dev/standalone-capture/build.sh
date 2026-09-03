#!/bin/bash
# Builds the screen capture and wraps it in a signed .app bundle.
# ScreenCaptureKit refuses to work from a plain command-line binary - macOS can't
# attribute the process and kills the stream with error -3805. A bundle with an
# Info.plist and an ad-hoc signature is enough to make it happy.
set -e
cd "$(dirname "$0")"

swiftc -O -o capture capture.swift \
  -framework ScreenCaptureKit -framework VideoToolbox -framework CoreMedia

rm -rf TabCapture.app
mkdir -p TabCapture.app/Contents/MacOS
cp capture TabCapture.app/Contents/MacOS/TabCapture

cat > TabCapture.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TabCapture</string>
    <key>CFBundleIdentifier</key><string>com.tabscreen.capture</string>
    <key>CFBundleName</key><string>TabCapture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Shows the Mac screen on a tablet</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - TabCapture.app
echo "собрано: swift/TabCapture.app"

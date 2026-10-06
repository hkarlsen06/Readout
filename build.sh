#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p UsageBar.app/Contents/MacOS
swiftc -O -swift-version 5 UsageBar.swift -o UsageBar.app/Contents/MacOS/UsageBar
cat > UsageBar.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundleIdentifier</key><string>dev.hkarlsen06.usagebar</string>
  <key>CFBundleName</key><string>UsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - --force UsageBar.app
echo "Built $(pwd)/UsageBar.app"

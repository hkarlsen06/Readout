#!/bin/bash
# Usage: ./build.sh [version]   (default 0.0.0 for dev builds)
# Env:   SIGN_ID  codesign identity (default: Developer ID; "-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.0.0}"
MIN_MACOS=13.0   # SMAppService (launch at login), SwiftUI Grid and Task.sleep(for:) need macOS 13
BUNDLE_ID=dev.hkarlsen06.readout
SIGN_ID="${SIGN_ID:-Developer ID Application: Hjalmar Karlsen (48ZSLD4RMP)}"
APP=Readout.app
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" -import-objc-header IOHIDPrivate.h Readout.swift -o "$TMP/Readout-$arch"
done
lipo -create "$TMP"/Readout-* -output "$APP/Contents/MacOS/Readout"

# Icon: drawn in code (two usage bars on a rounded tile), then iconutil -> .icns
cat > "$TMP/icon.swift" <<'SWIFT'
import AppKit
func png(_ px: Int, _ path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let tile = NSRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8046, height: s * 0.8046)  // macOS icon grid
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.21, blue: 0.25, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18), angle: -90)
    for (i, (frac, color)) in [(0.72, NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)),
                               (0.45, NSColor.systemBlue)].enumerated() {
        let x = tile.minX + tile.width * 0.16, w = tile.width * 0.68, h = tile.height * 0.14
        let y = tile.minY + tile.height * (0.58 - 0.28 * CGFloat(i))
        NSColor(white: 1, alpha: 0.15).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w * frac, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
let dir = CommandLine.arguments[1]
for base in [16, 32, 128, 256, 512] {
    png(base, "\(dir)/icon_\(base)x\(base).png")
    png(base * 2, "\(dir)/icon_\(base)x\(base)@2x.png")
}
SWIFT
mkdir "$TMP/AppIcon.iconset"
swiftc "$TMP/icon.swift" -o "$TMP/icon" && "$TMP/icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Readout</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Readout</string>
  <key>CFBundleDisplayName</key><string>Readout</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © $(date +%Y) Hjalmar Karlsen. MIT License.</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Hardened runtime needs no entitlements (verified: no JIT, no sandbox, no dylib injection).
TS=--timestamp; [ "$SIGN_ID" = - ] && TS=--timestamp=none
codesign --force --sign "$SIGN_ID" --options runtime "$TS" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $(pwd)/$APP v$VERSION (min macOS $MIN_MACOS, $(lipo -archs "$APP/Contents/MacOS/Readout"))"

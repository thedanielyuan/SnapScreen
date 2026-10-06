#!/bin/sh
set -eu
native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bundle="$native_dir/../build/SnapScreenPhase1.app"
mkdir -p "$bundle/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -framework AppKit \
  "$native_dir/Protocol.swift" "$native_dir/SelfTests.swift" "$native_dir/main.swift" \
  -o "$bundle/Contents/MacOS/SnapScreenPhase1"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.snapscreen.phase1</string>
  <key>CFBundleName</key><string>SnapScreen Phase 1</string>
  <key>CFBundleDisplayName</key><string>SnapScreen Phase 1</string>
  <key>CFBundleExecutable</key><string>SnapScreenPhase1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf '%s\n' "$bundle/Contents/MacOS/SnapScreenPhase1"

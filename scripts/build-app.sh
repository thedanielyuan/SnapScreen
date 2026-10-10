#!/bin/sh
# Builds the standalone app into build/SnapScreen.app and prints its executable path.
#
# It signs with the "SnapScreen Local" certificate when it exists, because macOS ties Screen
# Recording and Keychain approvals to the signature. Ad hoc builds lose both on every rebuild.

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
identity='SnapScreen Local'

# The version lives in package.json until the extension is removed.
version=$(plutil -extract version raw -o - "$root/package.json")
case $version in
  '' | *[!0-9.]*)
    echo "error: package.json needs a numeric version, not \"$version\"." >&2
    exit 1
    ;;
esac

swift build --package-path "$root" -c release --product SnapScreen >&2
binary="$(swift build --package-path "$root" -c release --show-bin-path)/SnapScreen"

mkdir -p "$root/build"
staging=$(mktemp -d "$root/build/.snapscreen-app-XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/SnapScreen.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/SnapScreen"
# LSMinimumSystemVersion matches the platforms entry in Package.swift.
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.snapscreen.app</string>
  <key>CFBundleName</key><string>SnapScreen</string>
  <key>CFBundleDisplayName</key><string>SnapScreen</string>
  <key>CFBundleExecutable</key><string>SnapScreen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

if security find-identity -p codesigning | grep -Fq "\"$identity\""; then
  codesign --force --sign "$identity" "$app" >&2
else
  echo "warning: no \"$identity\" code-signing certificate, so signing ad hoc." \
    "macOS will forget Screen Recording and Keychain approvals after every rebuild." >&2
  codesign --force --sign - "$app" >&2
fi

rm -rf "$root/build/SnapScreen.app"
mv "$app" "$root/build/SnapScreen.app"
echo "$root/build/SnapScreen.app/Contents/MacOS/SnapScreen"

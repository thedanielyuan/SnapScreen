#!/bin/sh
# Builds the standalone app into build/SnapScreen.app and prints its executable path.
#
# It signs with your Apple Development certificate when there is one. macOS recognizes a rebuilt
# app by that signature's team, so the app keeps reading its API key from the Keychain without
# asking for your password, and keeps Screen Recording. Ad hoc builds, as in CI, lose both on
# every rebuild.
#
# --test-hooks builds the live test's app (scripts/test-app-live.sh) into build/test-hooks
# instead, with its own bundle ID and build folder, signed ad hoc, so it never shares the real
# app's Keychain item, settings or approvals.

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

case ${1-} in
  '')
    hooks=false
    scratch=$root/.build
    identifier=com.snapscreen.app
    name=SnapScreen
    destination=$root/build/SnapScreen.app
    ;;
  --test-hooks)
    hooks=true
    scratch=$root/.build/test-hooks
    identifier=com.snapscreen.app.test-hooks
    name="SnapScreen Test"
    destination=$root/build/test-hooks/SnapScreen.app
    set -- -Xswiftc -DSNAPSCREEN_TEST_HOOKS
    ;;
  *)
    echo "usage: $0 [--test-hooks]" >&2
    exit 2
    ;;
esac

# The version lives in package.json until the extension is removed.
version=$(plutil -extract version raw -o - "$root/package.json")
case $version in
  '' | *[!0-9.]*)
    echo "error: package.json needs a numeric version, not \"$version\"." >&2
    exit 1
    ;;
esac
# Unchanged sources build an identical, identically signed app. SNAPSCREEN_BUILD_NUMBER, when
# set, joins CFBundleVersion and changes the signature as a code change would, for Phase 4's
# check that approvals survive a rebuild (docs/standalone-app-plan.md).
build=$version
case ${SNAPSCREEN_BUILD_NUMBER-} in
  '') ;;
  *[!0-9]*)
    echo "error: SNAPSCREEN_BUILD_NUMBER needs to be a number, not \"$SNAPSCREEN_BUILD_NUMBER\"." >&2
    exit 1
    ;;
  *) build=$version.$SNAPSCREEN_BUILD_NUMBER ;;
esac

swift build --package-path "$root" --scratch-path "$scratch" -c release --product SnapScreen "$@" >&2
binary="$(swift build --package-path "$root" --scratch-path "$scratch" -c release --show-bin-path "$@")/SnapScreen"
# The production app never carries the live test's hooks, which print this.
if [ "$hooks" = false ] && LC_ALL=C grep -a -F -q '(test hooks build)' "$binary"; then
  echo "error: the production build contains the live test's hooks." >&2
  exit 1
fi

mkdir -p "$(dirname "$destination")"
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
  <key>CFBundleIdentifier</key><string>$identifier</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>SnapScreen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

# The first valid Apple Development identity, by its hash in case there are several.
identity=$(security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2; exit }')
if [ "$hooks" = true ]; then
  codesign --force --sign - "$app" >&2
elif [ -n "$identity" ]; then
  codesign --force --timestamp=none --sign "$identity" "$app" >&2
else
  if security find-identity -p codesigning | grep -Fq '"Apple Development: '; then
    echo "warning: your Apple Development certificate can't be verified, usually because Apple's" \
      "intermediate certificate is missing (docs/standalone-app-plan.md, Phase 0), so signing ad hoc." >&2
  else
    echo "warning: no Apple Development certificate, so signing ad hoc." >&2
  fi
  echo "warning: macOS will ask again for Keychain and Screen Recording access after every rebuild." >&2
  codesign --force --sign - "$app" >&2
fi

rm -rf "$destination"
mv "$app" "$destination"
echo "$destination/Contents/MacOS/SnapScreen"

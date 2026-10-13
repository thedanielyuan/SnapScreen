#!/bin/sh
# The app's live test. It builds the test-hooks app, which snips a made-up capture through the real
# overlay and conversation windows with scripted API answers, asks one follow-up and opens the
# preview, snips again to replace them, and closes the new conversation and its preview as a click
# in another app does. Its windows show for a few seconds, so CI runs it in the macOS runner's GUI
# session. The app fails itself after 45 seconds.
#
# --focus also tests real global hotkey and WindowServer pointer events against a focused local
# webpage in an isolated helper app, then has that app launch a copy of the real app shell through
# LaunchServices and uses its notice, menu bar item, Settings and reopening. It needs an existing
# Accessibility approval for the launching terminal, and the production app must be quit first so
# its hotkey is available. --fullscreen runs the same checks in an actual fullscreen Space. Neither
# mode reads the user's API key, captures their display or contacts the API. The helper reports
# only its made-up webpage state.

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case ${1-} in
  '') mode=live ;;
  --focus) mode=focus; shift ;;
  *) echo "usage: $0 [--focus [--fullscreen]]" >&2; exit 2 ;;
esac
case ${1-} in
  '' | --fullscreen) ;;
  *) echo "usage: $0 [--focus [--fullscreen]]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [--focus [--fullscreen]]" >&2
  exit 2
fi
binary=$("$root/scripts/build-app.sh" --test-hooks)
if [ "$mode" = live ]; then
  "$binary" --live-test
else
  # A different ID prevents the helper from being mistaken for an already-running test app.
  # Its only interprocess interface is compiled under SNAPSCREEN_TEST_HOOKS.
  helper="$root/build/test-hooks/SnapScreen Focus Target.app"
  rm -rf "$helper"
  ditto "$root/build/test-hooks/SnapScreen.app" "$helper"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.snapscreen.app.test-hooks.focus-target' "$helper/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName SnapScreen Focus Target' "$helper/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$helper/Contents/Info.plist"
  codesign --force --sign - "$helper" >&2
  # The app shell copy runs the real AppDelegate with a key kept in memory. Its own ID keeps it
  # from being taken for the test app, and its Settings from sharing the test app's defaults.
  shell="$root/build/test-hooks/SnapScreen Focus App.app"
  rm -rf "$shell"
  ditto "$root/build/test-hooks/SnapScreen.app" "$shell"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.snapscreen.app.test-hooks.focus-app' "$shell/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName SnapScreen Focus App' "$shell/Contents/Info.plist"
  codesign --force --sign - "$shell" >&2
  SNAPSCREEN_FOCUS_TARGET="$helper/Contents/MacOS/SnapScreen" SNAPSCREEN_FOCUS_APP="$shell" \
    "$binary" --focus-test "$@"
fi

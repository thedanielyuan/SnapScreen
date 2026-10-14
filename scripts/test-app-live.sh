#!/bin/sh
# The app's live test. It builds the test-hooks app, which snips a made-up capture through the real
# overlay and conversation windows with scripted API answers, copies its code and opens the
# preview, snips again to replace them, and closes the new conversation and its preview as a click
# in another app does. Its windows show for a few seconds, so CI runs it in the macOS runner's GUI
# session. The app fails itself after 45 seconds.
#
# --focus also tests real global hotkey and WindowServer pointer events against a focused local
# webpage in an isolated helper app, then has that app launch a copy of the real app shell through
# LaunchServices and uses its notice, menu bar item, Settings and reopening. It needs an existing
# Accessibility approval for the launching terminal, and the production app must be quit first so
# its hotkey is available. --chrome makes the webpage scripts/fixtures/focus-recorder.html in an
# isolated instance of the installed Google Chrome, with a temporary profile, and no debugger or
# extension attached. --fullscreen runs the same checks in an actual fullscreen Space. No mode
# reads the user's API key, captures their display or contacts the API. The helper reports only
# its made-up webpage's state.

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
usage() {
  echo "usage: $0 [--focus [--chrome] [--fullscreen]]" >&2
  exit 2
}
mode=live
result_mode=live
browser=
if [ "$#" -gt 0 ]; then
  if [ "$1" != --focus ] || [ "$#" -gt 3 ]; then usage; fi
  mode=focus
  result_mode=focus
  shift
fi
if [ "$#" -gt 0 ] && [ "$1" = --chrome ]; then
  browser=chrome
  result_mode="$result_mode chrome"
  shift
fi
if [ "$#" -gt 1 ] || { [ "$#" -gt 0 ] && [ "$1" != --fullscreen ]; }; then usage; fi
if [ "$#" -gt 0 ]; then result_mode="$result_mode fullscreen"; fi
"$root/scripts/test-live-runner.sh"
binary=$("$root/scripts/build-app.sh" --test-hooks)
if [ "$mode" = live ]; then
  "$root/scripts/run-verified-test.sh" "$result_mode" "$binary" --live-test
else
  # A different ID prevents the helper from being mistaken for an already-running test app.
  # Its only interprocess interface is compiled under SNAPSCREEN_TEST_HOOKS. Watching Chrome, it
  # has no window of its own, so it stays out of the Dock.
  helper="$root/build/test-hooks/SnapScreen Focus Target.app"
  rm -rf "$helper"
  ditto "$root/build/test-hooks/SnapScreen.app" "$helper"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.snapscreen.app.test-hooks.focus-target' "$helper/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName SnapScreen Focus Target' "$helper/Contents/Info.plist"
  if [ -z "$browser" ]; then
    /usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$helper/Contents/Info.plist"
  fi
  codesign --force --sign - "$helper" >&2
  # The app shell copy runs the real AppDelegate with a key kept in memory. Its own ID keeps it
  # from being taken for the test app, and its Settings from sharing the test app's defaults.
  shell="$root/build/test-hooks/SnapScreen Focus App.app"
  rm -rf "$shell"
  ditto "$root/build/test-hooks/SnapScreen.app" "$shell"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.snapscreen.app.test-hooks.focus-app' "$shell/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName SnapScreen Focus App' "$shell/Contents/Info.plist"
  codesign --force --sign - "$shell" >&2
  if [ -n "$browser" ]; then
    # The helper quits its Chrome when the test ends. This also stops anything still running with
    # the temporary profile, and deletes it, whatever happened.
    profile=$(mktemp -d "${TMPDIR:-/tmp}/snapscreen-focus-chrome.XXXXXX")
    stop_chrome() {
      tries=0
      while pgrep -f -- "--user-data-dir=$profile" > /dev/null && [ "$tries" -lt 50 ]; do
        if [ "$tries" -eq 20 ]; then pkill -f -- "--user-data-dir=$profile" || true; fi
        sleep 0.1
        tries=$((tries + 1))
      done
      pkill -9 -f -- "--user-data-dir=$profile" || true
      rm -rf "$profile"
    }
    trap stop_chrome EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    SNAPSCREEN_FOCUS_CHROME_PROFILE=$profile
    SNAPSCREEN_FOCUS_PAGE="$root/scripts/fixtures/focus-recorder.html"
    export SNAPSCREEN_FOCUS_CHROME_PROFILE SNAPSCREEN_FOCUS_PAGE
  fi
  SNAPSCREEN_FOCUS_TARGET="$helper/Contents/MacOS/SnapScreen" SNAPSCREEN_FOCUS_APP="$shell" \
    "$root/scripts/run-verified-test.sh" "$result_mode" "$binary" --focus-test ${browser:+--chrome} "$@"
fi

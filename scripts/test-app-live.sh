#!/bin/sh
# The app's live test. It builds the test-hooks app, which snips a made-up capture through the real
# overlay and conversation windows with scripted API answers, asks one follow-up and opens the
# preview, snips again to replace them, and closes the new conversation and its preview as a click
# in another app does. Its windows show for a few seconds, so CI runs it in the macOS runner's GUI
# session. The app fails itself after 45 seconds.

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
binary=$("$root/scripts/build-app.sh" --test-hooks)
"$binary" --live-test

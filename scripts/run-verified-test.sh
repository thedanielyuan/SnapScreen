#!/bin/sh
# Accept a test run only when it exits successfully and reports the requested mode's completion.
# Test output contains fixture data only. Keep it intact for diagnostics, including failed runs.

set -eu

mode=${1-}
case "$mode" in
  live | focus | 'focus fullscreen') shift ;;
  *) echo "usage: $0 <live|focus|focus fullscreen> command [arguments...]" >&2; exit 2 ;;
esac
if [ "$#" -eq 0 ]; then
  echo "error: no test command supplied" >&2
  exit 2
fi

log=$(mktemp "${TMPDIR:-/tmp}/snapscreen-test-output.XXXXXX")
trap 'rm -f "$log"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
status=0
"$@" > "$log" 2>&1 || status=$?
cat "$log"
if [ "$status" -ne 0 ]; then
  exit "$status"
fi
if LC_ALL=C grep -Eq '^SnapScreen (live|focus) test failed:' "$log"; then
  echo "error: the $mode test reported failure despite exiting successfully" >&2
  exit 1
fi
if ! LC_ALL=C grep -Fxq "SnapScreen test completed: $mode" "$log"; then
  echo "error: the $mode test exited without its completion marker; no passing run was verified" >&2
  exit 1
fi

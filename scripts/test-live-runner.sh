#!/bin/sh
# No GUI or real input: exercise the same result gate used by test-app-live.sh with small stubs.

set -eu

# An argument-parser regression may accidentally reach this script from an invalid wrapper call
# below. Fail before building or launching anything, rather than recursively running these tests.
if [ "${SNAPSCREEN_RUNNER_TEST_ACTIVE-}" = 1 ]; then
  echo 'runner regression failed: invalid arguments reached the live test setup' >&2
  exit 3
fi

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/snapscreen-runner-tests.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
checks=0

expect_result() {
  expected=$1
  mode=$2
  output=$3
  command_status=$4
  diagnostic=$5
  actual=0
  "$root/scripts/run-verified-test.sh" "$mode" /bin/sh -c \
    'printf "%s\n" "$1"; exit "$2"' test-stub "$output" "$command_status" \
    > "$temporary/result" 2>&1 || actual=$?
  if [ "$actual" -ne "$expected" ] || ! grep -Fq -- "$diagnostic" "$temporary/result"; then
    echo "runner regression failed: mode=$mode, expected=$expected, actual=$actual" >&2
    cat "$temporary/result" >&2
    exit 1
  fi
  checks=$((checks + 1))
}

expect_result 1 live 'SnapScreen is already running.' 0 'without its completion marker'
expect_result 1 live '' 0 'without its completion marker'
expect_result 0 live 'SnapScreen test completed: live' 0 'SnapScreen test completed: live'
expect_result 0 focus 'SnapScreen test completed: focus' 0 'SnapScreen test completed: focus'
expect_result 0 'focus fullscreen' 'SnapScreen test completed: focus fullscreen' 0 \
  'SnapScreen test completed: focus fullscreen'
expect_result 1 live 'SnapScreen test completed: focus' 0 'without its completion marker'
expect_result 1 focus 'SnapScreen test completed: focus fullscreen' 0 'without its completion marker'
expect_result 1 'focus fullscreen' 'SnapScreen test completed: focus' 0 'without its completion marker'
expect_result 1 live 'prefix SnapScreen test completed: live suffix' 0 'without its completion marker'
expect_result 7 live 'fixture diagnostic' 7 'fixture diagnostic'
expect_result 9 focus 'SnapScreen test completed: focus' 9 'SnapScreen test completed: focus'
expect_result 1 live 'SnapScreen live test failed: fixture failure
SnapScreen test completed: live' 0 'reported failure despite exiting successfully'
expect_result 1 focus 'SnapScreen focus test failed: fixture failure
SnapScreen test completed: focus' 0 'reported failure despite exiting successfully'

actual=0
"$root/scripts/run-verified-test.sh" live /bin/sh -c 'echo "stderr diagnostic" >&2; exit 5' \
  > "$temporary/result" 2>&1 || actual=$?
if [ "$actual" -ne 5 ] || ! grep -Fq 'stderr diagnostic' "$temporary/result"; then
  echo 'runner regression failed: stderr or the command failure was lost' >&2
  cat "$temporary/result" >&2
  exit 1
fi
checks=$((checks + 1))

# Invalid modes must fail before build-app.sh can build or launch anything. The inherited guard
# also bounds a broken parser: entering the test setup again fails instead of recursing.
SNAPSCREEN_RUNNER_TEST_ACTIVE=1
export SNAPSCREEN_RUNNER_TEST_ACTIVE
expect_invalid_arguments() {
  actual=0
  "$root/scripts/test-app-live.sh" "$@" > "$temporary/result" 2>&1 || actual=$?
  if [ "$actual" -ne 2 ] || ! grep -Fq 'usage:' "$temporary/result"; then
    echo "runner regression failed: invalid arguments were accepted: $*" >&2
    cat "$temporary/result" >&2
    exit 1
  fi
  checks=$((checks + 1))
}

expect_invalid_arguments --fullscreen
expect_invalid_arguments --focus --unknown
expect_invalid_arguments --focus --fullscreen --extra
expect_invalid_arguments --focus --focus
expect_invalid_arguments ''
expect_invalid_arguments '' --fullscreen
expect_invalid_arguments --focus ''
printf 'SnapScreen live runner tests: %s checks passed\n' "$checks"

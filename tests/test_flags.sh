#!/bin/sh
# Source bootstrap.sh without running main, then exercise its pure functions.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
BOOTSTRAP_SOURCE_ONLY=1 . "$here/bootstrap.sh"

fail() { echo "FAIL: $1"; exit 1; }

parse_flags --desktop            || fail "desktop should parse"
[ "$PROFILE" = desktop ] && [ "$WORK" = false ] || fail "desktop defaults"

parse_flags --headless --work    || fail "headless work should parse"
[ "$PROFILE" = headless ] && [ "$WORK" = true ] || fail "headless work values"

if parse_flags 2>/dev/null; then fail "missing profile must fail"; fi
if parse_flags --desktop --headless 2>/dev/null; then fail "both profiles must fail"; fi
if parse_flags --bogus 2>/dev/null; then fail "unknown flag must fail"; fi

[ "$(detect_os_from darwin '')" = macos ]    || fail "darwin"
[ "$(detect_os_from linux ubuntu)" = debian ] || fail "ubuntu maps to debian family"
[ "$(detect_os_from linux debian)" = debian ] || fail "debian"
[ "$(detect_os_from linux arch)" = arch ]    || fail "arch"
if detect_os_from linux fedora >/dev/null 2>&1; then fail "fedora unsupported"; fi
echo "PASS: flags"

#!/bin/sh
# Source bootstrap.sh without running main, then exercise its pure functions (flags and OS detection).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../bootstrap.sh
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
[ "$(detect_os_from linux cachyos arch)" = arch ]          || fail "cachyos (ID_LIKE=arch) maps to arch"
[ "$(detect_os_from linux manjaro 'archlinux arch')" = arch ] || fail "arch among several ID_LIKE words"
[ "$(detect_os_from linux ubuntu debian)" = debian ]       || fail "ID wins over ID_LIKE"
if detect_os_from linux fedora 'rhel fedora' >/dev/null 2>&1; then fail "fedora with ID_LIKE still unsupported"; fi
if detect_os_from linux other notarch >/dev/null 2>&1; then fail "ID_LIKE must match a whole word"; fi

echo "PASS: flags"

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

# finish: the closing line comes first and the checklist from the dotfiles checkout is the very last output.
fin_dir=$(mktemp -d)
mkdir -p "$fin_dir/scripts"
printf 'echo CHECKLIST-LAST\n' > "$fin_dir/scripts/checklist.sh"
SOURCE_DIR="$fin_dir"
out=$(finish)
[ "$(printf '%s\n' "$out" | head -n 1)" = "Bootstrap finished." ] || fail "finish must print the closing line first"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "CHECKLIST-LAST" ] || fail "the checklist must be the last output"
printf 'echo FINISH-LAST\n' > "$fin_dir/scripts/finish.sh"
out=$(finish)
[ "$(printf '%s\n' "$out" | tail -n 1)" = "FINISH-LAST" ] || fail "finish.sh must win over checklist.sh and be last"
printf '%s\n' "$out" | grep -q CHECKLIST-LAST && fail "checklist.sh must not run when finish.sh exists"
rm -f "$fin_dir/scripts/finish.sh" "$fin_dir/scripts/checklist.sh"
out=$(finish)
printf '%s\n' "$out" | grep -q 'just secrets' || fail "without a checklist script the closing text must name the next step"
rm -rf "$fin_dir"
echo "PASS: flags"

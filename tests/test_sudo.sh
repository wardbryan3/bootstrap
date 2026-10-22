#!/bin/sh
# setup_sudo: writes a checked sudoers drop-in once, falls back to a keepalive, and skips when it should.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
BOOTSTRAP_SOURCE_ONLY=1 . "$here/bootstrap.sh"
fail() { echo "FAIL: $1"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sudoers.d"
# Fake sudo: logs calls; -v/-k/visudo succeed; install copies; -n true succeeds only if the drop-in exists.
cat > "$tmp/sudo" <<'FAKE'
#!/bin/sh
echo "$*" >> "$FAKE_SUDO_LOG"
case "$1" in
  -v|-k) exit 0 ;;
  -n) [ -f "$SUDOERS_DIR"/90-bootstrap-* ] 2>/dev/null; exit $? ;;
  test) shift; test "$@" ;;
  visudo) exit 0 ;;
  install) cp "$6" "$7" && chmod 0440 "$7" ;;
esac
FAKE
chmod +x "$tmp/sudo"
export SUDO_BIN="$tmp/sudo" SUDOERS_DIR="$tmp/sudoers.d" FAKE_SUDO_LOG="$tmp/log" BOOTSTRAP_UID=1000 BOOTSTRAP_USER=alice
: > "$tmp/log"

SUDO_SETUP=true
setup_sudo >/dev/null
f="$tmp/sudoers.d/90-bootstrap-alice"
[ -f "$f" ] || fail "drop-in not written"
[ "$(cat "$f")" = "alice ALL=(ALL) NOPASSWD:ALL" ] || fail "drop-in content"
ls -l "$f" | grep -q '^-r--r-----' || fail "drop-in mode must be 0440"
grep -q '^visudo -cf' "$tmp/log" || fail "the drop-in must be checked with visudo"

: > "$tmp/log"
setup_sudo >/dev/null
grep -q '^install' "$tmp/log" && fail "second run must not rewrite the drop-in"

SUDO_SETUP=false; rm -f "$f"; : > "$tmp/log"
setup_sudo >/dev/null
[ ! -s "$tmp/log" ] || fail "--no-sudo-setup must not call sudo"
parse_flags --headless --no-sudo-setup
[ "$SUDO_SETUP" = false ] || fail "flag must turn it off"
parse_flags --headless
[ "$SUDO_SETUP" = true ] || fail "default is on"

SUDO_SETUP=true; : > "$tmp/log"
BOOTSTRAP_UID=0 setup_sudo >/dev/null
[ ! -s "$tmp/log" ] || fail "root needs nothing"
BOOTSTRAP_USER='Bad.User' setup_sudo >/dev/null 2>&1
[ ! -s "$tmp/log" ] || fail "an unusual user name must skip"
BOOTSTRAP_LOCAL_REPO=/x setup_sudo >/dev/null
[ ! -s "$tmp/log" ] || fail "test mode must skip"

# Rule not in effect (sudo -n keeps failing): fall back to the keepalive and still return 0.
rm -f "$f"; : > "$tmp/log"
cat > "$tmp/sudo2" <<'FAKE'
#!/bin/sh
echo "$*" >> "$FAKE_SUDO_LOG"
case "$1" in -n) exit 1 ;; test) shift; test "$@" ;; install) exit 1 ;; *) exit 0 ;; esac
FAKE
chmod +x "$tmp/sudo2"
SUDO_BIN="$tmp/sudo2" setup_sudo >/dev/null 2>&1 || fail "fallback must not fail"
echo "PASS: sudo"

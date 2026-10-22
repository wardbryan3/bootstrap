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
# Already passwordless (sudo -n works), but "sudo -v" would still ask, as when a "%wheel ALL=(ALL) ALL" rule also matches:
# no prompt, no sudoers file written, and it says so.
# (Some shells keep the VAR=x prefix of an earlier function call, so reset what those calls set.)
unset BOOTSTRAP_LOCAL_REPO; BOOTSTRAP_USER=alice; BOOTSTRAP_UID=1000; SUDO_SETUP=true
rm -f "$f"; : > "$tmp/log"
cat > "$tmp/sudo3" <<'FAKE'
#!/bin/sh
echo "$*" >> "$FAKE_SUDO_LOG"
case "$1" in -n) exit 0 ;; -k) exit 0 ;; -v) echo "FAKE: password required" >&2; exit 1 ;; test) shift; test "$@" ;; install) exit 1 ;; *) exit 0 ;; esac
FAKE
chmod +x "$tmp/sudo3"
out=$(SUDO_BIN="$tmp/sudo3" setup_sudo 2>&1) || fail "an already passwordless sudo must not fail"
grep -q '^-v' "$tmp/log" && fail "an already passwordless sudo must not run sudo -v"
grep -q '^install' "$tmp/log" && fail "an already passwordless sudo must not write a sudoers file"
case "$out" in *"Sudo password needed"*) fail "must not announce a password prompt: $out" ;; esac
case "$out" in *"already passwordless"*) ;; *) fail "must say sudo is already passwordless: $out" ;; esac
[ ! -f "$f" ] || fail "no drop-in may be written when sudo is already passwordless"
echo "PASS: sudo"

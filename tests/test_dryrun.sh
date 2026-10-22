#!/bin/sh
# --dry-run: the stub only finds a checkout and hands off to the entry with --dry-run. No sudo setup, no prerequisites,
# no mise, and no gh sign-in or git wiring (gh auth setup-git rewrites ~/.gitconfig, which is one of the files previewed).
# Only fakes are used: a local git repo stands in for GitHub, and a fake gh clones from it.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../bootstrap.sh
BOOTSTRAP_SOURCE_ONLY=1 . "$here/bootstrap.sh"
fail() { echo "FAIL: $1"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/tmpdir"
git config --global --get user.name >/dev/null 2>&1 || export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
log="$tmp/log"

# the flag
parse_flags --desktop || fail "desktop should parse"
[ "$DRY_RUN" = false ] || fail "a real run is the default"
parse_flags --headless --dry-run --work || fail "--dry-run should parse"
[ "$DRY_RUN" = true ] && [ "$PROFILE" = headless ] && [ "$WORK" = true ] || fail "--dry-run keeps the other flags"
parse_flags --dry-run --desktop || fail "--dry-run may come first"
if parse_flags --dry-run 2>/dev/null; then fail "--dry-run still needs a profile"; fi

# fake gh: signed in unless FAKE_GH_LOGGED_IN=0; "repo clone OWNER/NAME DIR" clones the local remote
cat > "$tmp/bin/gh" <<'EOT'
#!/bin/sh
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "auth status") [ "${FAKE_GH_LOGGED_IN:-1}" = 1 ]; exit $? ;;
  "repo clone") exec git clone -q "$FAKE_REMOTE" "$4" ;;
esac
exit 0
EOT
chmod +x "$tmp/bin/gh"

# the "remote": a Dotfiles repo whose fake entry records how it was called
mkdir -p "$tmp/remote/scripts"
cat > "$tmp/remote/scripts/bootstrap-run.sh" <<'EOT'
echo "ENTRY from $(cd "$(dirname "$0")/.." && pwd) args: $*"
exit "${FAKE_ENTRY_RC:-0}"
EOT
git -C "$tmp/remote" init -q -b main
git -C "$tmp/remote" add -A && git -C "$tmp/remote" commit -q -m one

export FAKE_LOG="$log" FAKE_REMOTE="$tmp/remote" HOME="$tmp/home" TMPDIR="$tmp/tmpdir" PATH="$tmp/bin:$PATH"
SOURCE_DIR="$tmp/home/code/dotfiles"
# every step that changes the machine is replaced by a recorder
detect_os() { echo debian; }
setup_sudo() { echo setup_sudo >> "$log"; }
install_prereqs() { echo install_prereqs >> "$log"; }
install_mise() { echo install_mise >> "$log"; }
get_checkout() { echo get_checkout >> "$log"; }
handoff() { echo handoff >> "$log"; }

# 1. no checkout: gh clones into a temp dir, the entry runs from there, the temp dir is removed, ~/code is untouched
: > "$log"
out=$(main --headless --dry-run 2>&1) || fail "dry run must succeed: $out"
case "$out" in *"ENTRY from $tmp/tmpdir/"*" args: --profile headless --work false --dry-run") ;; *) fail "wrong entry call: $out" ;; esac
grep -q "^gh repo clone wardbryan3/dotfiles $tmp/tmpdir/" "$log" || fail "gh must clone into a temp dir: $(cat "$log")"
for step in setup_sudo install_prereqs install_mise get_checkout handoff; do
  grep -qx "$step" "$log" && fail "dry run must not run $step"
done
grep -q "^gh auth login\|^gh auth setup-git" "$log" && fail "dry run must not sign in or wire git: $(cat "$log")"
[ ! -e "$tmp/home/code" ] || fail "dry run must not create ~/code"
[ -z "$(ls -A "$tmp/tmpdir")" ] || fail "the temporary clone must be removed: $(ls -A "$tmp/tmpdir")"

# 2. an existing checkout is used as it is: no gh, no pull
mkdir -p "$tmp/home/code" && git clone -q "$tmp/remote" "$SOURCE_DIR"
echo two > "$tmp/remote/two.txt"; git -C "$tmp/remote" add -A; git -C "$tmp/remote" commit -q -m two
: > "$log"
out=$(main --desktop --work --dry-run 2>&1) || fail "dry run with a checkout must succeed: $out"
case "$out" in *"ENTRY from $SOURCE_DIR args: --profile desktop --work true --dry-run"*) ;; *) fail "must run the existing checkout's entry: $out" ;; esac
[ ! -s "$log" ] || fail "an existing checkout needs no gh and no setup: $(cat "$log")"
[ ! -f "$SOURCE_DIR/two.txt" ] || fail "an existing checkout must not be pulled"
case "$out" in *"not updated"*) ;; *) fail "must say the checkout was not updated: $out" ;; esac
rm -rf "$SOURCE_DIR"

# 3. no checkout and gh signed out: stop with a message, never log in
: > "$log"
rc=0; out=$(FAKE_GH_LOGGED_IN=0 main --headless --dry-run 2>&1) || rc=$?
[ "$rc" != 0 ] || fail "a signed-out gh must fail the dry run"
case "$out" in *"gh auth login"*) ;; *) fail "must tell the user to run gh auth login: $out" ;; esac
grep -q "^gh auth login\|^gh repo clone" "$log" && fail "must not log in or clone: $(cat "$log")"

# 4. no checkout and no gh at all
rc=0; out=$(PATH="$tmp/nobin" main --headless --dry-run 2>&1) || rc=$?
[ "$rc" != 0 ] || fail "a missing gh must fail the dry run"
case "$out" in *"gh"*) ;; *) fail "must name gh: $out" ;; esac

# 5. the entry's exit code is the stub's, and the temp clone is still removed
rc=0; (FAKE_ENTRY_RC=7 main --headless --dry-run >/dev/null 2>&1) || rc=$?
[ "$rc" = 7 ] || fail "the entry's exit code must be the stub's, got $rc"
[ -z "$(ls -A "$tmp/tmpdir")" ] || fail "the temporary clone must be removed after a failure"

# 6. an unknown distro is still refused first
detect_os() { echo "error: unsupported Linux distribution: fedora" >&2; return 1; }
: > "$log"
rc=0; (main --headless --dry-run >/dev/null 2>&1) || rc=$?
[ "$rc" != 0 ] || fail "an unknown distro must still be refused"
[ ! -s "$log" ] || fail "nothing may run for an unknown distro: $(cat "$log")"
echo "PASS: dry-run"

#!/bin/sh
# The stub's last two steps: get the dotfiles checkout, then exec the Bootstrap entry in it.
# Only fakes are used: a local git repo stands in for GitHub, and fake mise and gh stand in for the real tools.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../bootstrap.sh
BOOTSTRAP_SOURCE_ONLY=1 . "$here/bootstrap.sh"
fail() { echo "FAIL: $1"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
git config --global --get user.name >/dev/null 2>&1 || export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
log="$tmp/log"

# fake mise: "mise x gh@latest -- CMD..." logs the call and runs CMD with the fake gh on PATH
cat > "$tmp/bin/mise" <<'EOT'
#!/bin/sh
echo "mise $*" >> "$FAKE_LOG"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
EOT
cat > "$tmp/bin/gh" <<'EOT'
#!/bin/sh
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in "auth status") [ "${FAKE_GH_LOGGED_IN:-1}" = 1 ]; exit $? ;; esac
exit 0
EOT
chmod +x "$tmp/bin/mise" "$tmp/bin/gh"
export FAKE_LOG="$log" HOME="$tmp/home" PATH="$tmp/bin:$PATH"
: > "$log"

# the "remote": a local repo holding a fake Bootstrap entry that records how it was called
mkdir -p "$tmp/remote/scripts"
cat > "$tmp/remote/scripts/bootstrap-run.sh" <<'EOT'
echo "ENTRY args: $*"
exit "${FAKE_ENTRY_RC:-0}"
EOT
git -C "$tmp/remote" init -q -b main
git -C "$tmp/remote" add -A && git -C "$tmp/remote" commit -q -m one
# shellcheck disable=SC2034  # read by get_checkout
DOTFILES_URL="$tmp/remote"
SOURCE_DIR="$tmp/home/code/dotfiles"

# 1. fresh machine: signed-in gh, clone, no login
get_checkout
[ -f "$SOURCE_DIR/scripts/bootstrap-run.sh" ] || fail "the checkout must be cloned"
grep -q "^gh auth login" "$log" && fail "no login when gh is already signed in"
grep -q "^gh auth setup-git" "$log" || fail "git must be wired to gh's credentials"
grep -q "^mise x gh@latest -- " "$log" || fail "git must run with gh on PATH: $(cat "$log")"

# 2. re-run: an existing checkout is fast-forwarded to the new commit
echo two > "$tmp/remote/two.txt"; git -C "$tmp/remote" add -A; git -C "$tmp/remote" commit -q -m two
get_checkout
[ -f "$SOURCE_DIR/two.txt" ] || fail "a re-run must pull the new commit"

# 3. re-run when the pull cannot fast-forward: warn, keep the checkout, succeed
echo local > "$SOURCE_DIR/local.txt"; git -C "$SOURCE_DIR" add -A; git -C "$SOURCE_DIR" commit -q -m local
echo three > "$tmp/remote/three.txt"; git -C "$tmp/remote" add -A; git -C "$tmp/remote" commit -q -m three
out=$(get_checkout 2>&1) || fail "a failed pull must not fail the stub"
case "$out" in *"continuing with the checkout as it is"*) ;; *) fail "missing warning: $out" ;; esac
[ -f "$SOURCE_DIR/local.txt" ] || fail "the local checkout must be left as it was"

# 4. signed-out gh: the login runs first
rm -rf "$SOURCE_DIR"; : > "$log"
FAKE_GH_LOGGED_IN=0 get_checkout
grep -q "^gh auth login --git-protocol https --web" "$log" || fail "a signed-out gh must log in: $(cat "$log")"

# 5. test mode: copy the local checkout, no GitHub at all; refuses to overwrite
rm -rf "$SOURCE_DIR"; : > "$log"
BOOTSTRAP_LOCAL_REPO="$tmp/remote" get_checkout
[ -f "$SOURCE_DIR/scripts/bootstrap-run.sh" ] || fail "test mode must copy the checkout"
[ ! -s "$log" ] || fail "test mode must not call mise or gh: $(cat "$log")"
if (BOOTSTRAP_LOCAL_REPO="$tmp/remote" get_checkout) 2>/dev/null; then fail "test mode must refuse to overwrite an existing checkout"; fi

# 6. handoff: exec the entry with the normalized answers; its exit code is the stub's
# shellcheck disable=SC2034  # read by handoff
PROFILE=desktop WORK=true
out=$(handoff) || fail "handoff must succeed when the entry does"
[ "$out" = "ENTRY args: --profile desktop --work true" ] || fail "wrong handoff arguments: $out"
# shellcheck disable=SC2034
PROFILE=headless WORK=false
out=$(handoff); [ "$out" = "ENTRY args: --profile headless --work false" ] || fail "wrong handoff arguments: $out"
rc=0; (FAKE_ENTRY_RC=7 handoff >/dev/null) || rc=$?
[ "$rc" = 7 ] || fail "the entry's exit code must be the stub's, got $rc"
echo "PASS: handoff"

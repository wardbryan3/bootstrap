#!/bin/sh
# Bootstrap stub: does only what must run before a clone exists (flags, sudo, prereqs, mise, the GitHub login, the
# clone), then hands off to scripts/bootstrap-run.sh in the dotfiles checkout, which does the rest.
# Usage: sh -c "$(curl -fsSL https://raw.githubusercontent.com/wardbryan3/bootstrap/main/bootstrap.sh)" -- --headless
# (Use the sh -c form, not "curl | sh", so gh can prompt on your terminal.)
set -eu

GITHUB_USER="wardbryan3"
DOTFILES_URL="https://github.com/$GITHUB_USER/dotfiles.git"
SOURCE_DIR="$HOME/code/dotfiles"

usage() {
  cat <<'EOF'
usage: bootstrap.sh (--desktop | --headless) [--work] [--no-sudo-setup] [--dry-run]

  --desktop   GUI machine: also installs kitty
  --headless  server or VM: terminal tools only
  --work      also installs the work-profile extras
  --no-sudo-setup  keep sudo as it is (by default it asks for the sudo password once and makes sudo
                   passwordless for you via /etc/sudoers.d, so the install never stops for it)

  --dry-run   show what a real run would change on this machine, and change nothing: no sudo, no installs, no
              sign-ins. Needs git, plus gh signed in unless ~/code/dotfiles already exists (it is then used as is).

Test hook: BOOTSTRAP_LOCAL_REPO=/path/to/dotfiles skips GitHub login and applies that checkout.
EOF
}

parse_flags() {
  PROFILE=""
  WORK=false
  SUDO_SETUP=true
  DRY_RUN=false
  for arg in "$@"; do
    case "$arg" in
      --desktop)
        [ -z "$PROFILE" ] || [ "$PROFILE" = desktop ] || { echo "error: choose one of --desktop or --headless" >&2; return 2; }
        PROFILE=desktop ;;
      --headless)
        [ -z "$PROFILE" ] || [ "$PROFILE" = headless ] || { echo "error: choose one of --desktop or --headless" >&2; return 2; }
        PROFILE=headless ;;
      --work) WORK=true ;;
      --no-sudo-setup) SUDO_SETUP=false ;;
      --dry-run) DRY_RUN=true ;;
      -h|--help) usage; return 0 ;;
      *) echo "error: unknown flag: $arg" >&2; usage >&2; return 2 ;;
    esac
  done
  [ -n "$PROFILE" ] || { echo "error: --desktop or --headless is required" >&2; usage >&2; return 2; }
}

# detect_os_from <uname-lowercase> <os-release-id> [<os-release-id-like>]: prints macos, debian or arch.
# ID decides first. ID_LIKE (a space-separated list) only rescues an Arch derivative such as CachyOS.
detect_os_from() {
  case "$1" in
    darwin) echo macos ;;
    linux)
      case "$2" in
        debian|ubuntu) echo debian; return 0 ;;
        arch) echo arch; return 0 ;;
      esac
      case " ${3:-} " in
        *" arch "*) echo arch ;;
        *) echo "error: unsupported Linux distribution: $2" >&2; return 1 ;;
      esac ;;
    *) echo "error: unsupported OS: $1" >&2; return 1 ;;
  esac
}

detect_os() {
  kernel=$(uname -s | tr '[:upper:]' '[:lower:]')
  id=""
  id_like=""
  if [ -r /etc/os-release ]; then
    id=$(. /etc/os-release && echo "$ID")
    id_like=$(. /etc/os-release && echo "${ID_LIKE:-}")
  fi
  detect_os_from "$kernel" "$id" "$id_like"
}

# Ask for the sudo password once and make sudo passwordless for this user, so nothing later stops for it.
# If sudo is already passwordless for this user, it asks for nothing and changes nothing.
# The drop-in is checked with visudo first. Remove it with: sudo rm /etc/sudoers.d/90-bootstrap-<user>
# If the rule does not take effect (no includedir), keep the sudo timestamp alive for this run instead.
setup_sudo() {
  [ "$SUDO_SETUP" = true ] || return 0
  [ -z "${BOOTSTRAP_LOCAL_REPO:-}" ] || return 0
  [ "${BOOTSTRAP_UID:-$(id -u)}" != 0 ] || return 0
  sudo_bin="${SUDO_BIN:-sudo}"
  if ! command -v "$sudo_bin" >/dev/null 2>&1; then
    echo "sudo is not installed: skipping the passwordless sudo setup." >&2
    return 0
  fi
  user="${BOOTSTRAP_USER:-$(id -un)}"
  case "$user" in
    ''|*[!a-z0-9_-]*|[!a-z_]*) echo "unusual user name '$user': skipping the passwordless sudo setup." >&2; return 0 ;;
  esac
  sudoers_file="${SUDOERS_DIR:-/etc/sudoers.d}/90-bootstrap-$user"
  # Already passwordless (a NOPASSWD rule from an earlier run or from elsewhere)? Then there is nothing to ask or write.
  # The cached timestamp is dropped first, so only a real NOPASSWD rule counts. "sudo -v" is not used for this test:
  # it still asks for a password when any other matching rule (such as the installer's "%wheel ALL=(ALL) ALL") needs one.
  "$sudo_bin" -k
  if "$sudo_bin" -n true 2>/dev/null; then
    echo "sudo is already passwordless for $user: no password needed."
    return 0
  fi
  echo "Sudo password needed once. This also makes sudo passwordless for $user (undo: sudo rm $sudoers_file)."
  "$sudo_bin" -v || { echo "error: sudo is required" >&2; exit 1; }
  if ! "$sudo_bin" test -f "$sudoers_file"; then
    sudoers_tmp=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "$sudoers_tmp"
    if "$sudo_bin" visudo -cf "$sudoers_tmp" >/dev/null && "$sudo_bin" install -m 0440 -o root "$sudoers_tmp" "$sudoers_file"; then
      :
    else
      echo "could not install $sudoers_file." >&2
    fi
    rm -f "$sudoers_tmp"
  fi
  "$sudo_bin" -k
  if "$sudo_bin" -n true 2>/dev/null; then
    return 0
  fi
  echo "Passwordless sudo is not in effect; keeping the sudo password cached for this run instead."
  "$sudo_bin" -v || { echo "error: sudo is required" >&2; exit 1; }
  ( while kill -0 "$$" 2>/dev/null; do "$sudo_bin" -n true 2>/dev/null || true; sleep 50; done ) >/dev/null 2>&1 </dev/null &
}

install_prereqs() {
  case "$1" in
    macos)
      xcode-select -p >/dev/null 2>&1 || { xcode-select --install; echo "Finish the Command Line Tools install, then re-run this command." >&2; exit 1; } ;;
    debian)
      sudo apt-get update
      sudo apt-get install -y git curl ca-certificates ;;
    arch)
      # -Syu, not -S: Arch is rolling, so installing from a stale database can leave a partial upgrade.
      sudo pacman -Syu --needed --noconfirm git curl ca-certificates ;;
  esac
}

install_mise() {
  export PATH="$HOME/.local/bin:$PATH"
  command -v mise >/dev/null 2>&1 || curl -fsSL https://mise.run | sh
}

# Put the dotfiles checkout in $SOURCE_DIR. On a re-run an existing checkout is only fast-forwarded; if that fails
# (local edits, diverged history) it warns and carries on with the checkout as it is.
# Test mode: BOOTSTRAP_LOCAL_REPO=/path/to/dotfiles copies that checkout instead (no GitHub login, no clone).
get_checkout() {
  mkdir -p "$HOME/code"
  if [ -n "${BOOTSTRAP_LOCAL_REPO:-}" ]; then
    if [ -e "$SOURCE_DIR" ]; then
      echo "error: test mode refuses to overwrite existing $SOURCE_DIR" >&2
      exit 1
    fi
    cp -R "$BOOTSTRAP_LOCAL_REPO" "$SOURCE_DIR"
    return 0
  fi
  # gh must be on PATH while git runs: setup-git makes it git's credential helper.
  # The inner script is single-quoted on purpose: $1 and $2 expand in the inner shell.
  # shellcheck disable=SC2016
  mise x gh@latest -- sh -c '
    set -eu
    gh auth status >/dev/null 2>&1 || gh auth login --git-protocol https --web
    gh auth setup-git
    if [ -d "$1/.git" ]; then
      git -C "$1" pull --ff-only || echo "warning: could not update $1; continuing with the checkout as it is" >&2
    else
      git clone "$2" "$1"
    fi
  ' sh "$SOURCE_DIR" "$DOTFILES_URL"
}

# Everything after the clone (chezmoi init, the sign-ins, the apply, the finish) lives in the dotfiles repo.
# exec: this process becomes the entry, so its exit code is the Bootstrap's.
handoff() {
  exec sh "$SOURCE_DIR/scripts/bootstrap-run.sh" --profile "$PROFILE" --work "$WORK"
}

# Dry run: the same hand-off, but nothing on the machine changes. No sudo setup, prerequisites or mise; gh is the one
# already installed, and it is never signed in or wired into git (that rewrites ~/.gitconfig, which is being previewed).
# With no checkout yet, one is cloned into a temp dir and removed afterwards (over https, so ~/.ssh is untouched). The entry's exit code is returned.
dry_run() {
  checkout="$SOURCE_DIR"
  cleanup=""
  if [ -d "$SOURCE_DIR/.git" ]; then
    echo "Using the existing checkout at $SOURCE_DIR as it is (not updated)."
  else
    command -v gh >/dev/null 2>&1 || { echo "error: --dry-run needs gh, or a checkout at $SOURCE_DIR" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "error: --dry-run needs gh signed in (run: gh auth login) or a checkout at $SOURCE_DIR" >&2; exit 1; }
    cleanup=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-dry-run.XXXXXX")
    # https with gh's credentials for this one command: nothing is written to ~/.gitconfig, and gh repo clone is avoided
    # because it follows gh's own protocol setting (ssh would add github.com to ~/.ssh/known_hosts).
    git -c "credential.https://github.com.helper=!gh auth git-credential" clone "$DOTFILES_URL" "$cleanup/dotfiles" || { rm -rf "$cleanup"; exit 1; }
    checkout="$cleanup/dotfiles"
  fi
  rc=0
  sh "$checkout/scripts/bootstrap-run.sh" --profile "$PROFILE" --work "$WORK" --dry-run || rc=$?
  [ -z "$cleanup" ] || rm -rf "$cleanup"
  exit "$rc"
}

main() {
  parse_flags "$@" || exit $?
  os=$(detect_os) || exit 1
  if [ "$DRY_RUN" = true ]; then dry_run; fi
  setup_sudo
  install_prereqs "$os"
  install_mise
  get_checkout
  handoff
}

if [ -z "${BOOTSTRAP_SOURCE_ONLY:-}" ]; then
  main "$@"
fi

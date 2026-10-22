#!/bin/sh
# Bootstrap stub: gets a wiped machine from nothing to a chezmoi-applied environment.
# Usage: sh -c "$(curl -fsSL https://raw.githubusercontent.com/wardbryan3/bootstrap/main/bootstrap.sh)" -- --headless
# (Use the sh -c form, not "curl | sh", so gh can prompt on your terminal.)
set -eu

GITHUB_USER="wardbryan3"
DOTFILES_URL="https://github.com/$GITHUB_USER/dotfiles.git"
SOURCE_DIR="$HOME/code/dotfiles"

usage() {
  cat <<'EOF'
usage: bootstrap.sh (--desktop | --headless) [--work] [--no-sudo-setup]

  --desktop   GUI machine: also installs kitty
  --headless  server or VM: terminal tools only
  --work      also installs the work-profile extras
  --no-sudo-setup  keep sudo as it is (by default it asks for the sudo password once and makes sudo
                   passwordless for you via /etc/sudoers.d, so the install never stops for it)

Test hook: BOOTSTRAP_LOCAL_REPO=/path/to/dotfiles skips GitHub login and applies that checkout.
EOF
}

parse_flags() {
  PROFILE=""
  WORK=false
  SUDO_SETUP=true
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
      -h|--help) usage; return 0 ;;
      *) echo "error: unknown flag: $arg" >&2; usage >&2; return 2 ;;
    esac
  done
  [ -n "$PROFILE" ] || { echo "error: --desktop or --headless is required" >&2; usage >&2; return 2; }
}

# detect_os_from <uname-lowercase> <os-release-id>: prints macos, debian or arch.
detect_os_from() {
  case "$1" in
    darwin) echo macos ;;
    linux)
      case "$2" in
        debian|ubuntu) echo debian ;;
        arch) echo arch ;;
        *) echo "error: unsupported Linux distribution: $2" >&2; return 1 ;;
      esac ;;
    *) echo "error: unsupported OS: $1" >&2; return 1 ;;
  esac
}

detect_os() {
  kernel=$(uname -s | tr '[:upper:]' '[:lower:]')
  id=""
  if [ -r /etc/os-release ]; then
    id=$(. /etc/os-release && echo "$ID")
  fi
  detect_os_from "$kernel" "$id"
}

# Ask for the sudo password once and make sudo passwordless for this user, so nothing later stops for it.
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
      sudo pacman -S --needed --noconfirm git curl ca-certificates ;;
  esac
}

install_mise() {
  export PATH="$HOME/.local/bin:$PATH"
  command -v mise >/dev/null 2>&1 || curl -fsSL https://mise.run | sh
}

# All sign-ins happen here, before the long install, so you can walk away afterwards.
# The script is sourced (not run) so BW_SESSION stays in this process and reaches the install and finish.
preauth() {
  if [ -f "$SOURCE_DIR/scripts/preauth.sh" ]; then
    # set -e is off while it runs: some shells exit on a failing sourced script even inside a "||" list.
    set +e
    # shellcheck disable=SC1091
    . "$SOURCE_DIR/scripts/preauth.sh"
    preauth_rc=$?
    set -e
    [ "$preauth_rc" = 0 ] || echo "preauth had a problem; the sign-ins will be asked at the end instead." >&2
  fi
  return 0
}

# The install runs third-party installers (curl | sh, npm), so it must not inherit the Vault session token.
run_apply() {
  env -u BW_SESSION mise x "$@" -- chezmoi apply
}

apply_dotfiles() {
  work_answer=$WORK
  mkdir -p "$HOME/code"
  if [ -n "${BOOTSTRAP_LOCAL_REPO:-}" ]; then
    # Test mode: copy the local checkout instead of cloning the private repo.
    if [ -e "$SOURCE_DIR" ]; then
      echo "error: test mode refuses to overwrite existing $SOURCE_DIR" >&2
      exit 1
    fi
    cp -R "$BOOTSTRAP_LOCAL_REPO" "$SOURCE_DIR"
    mise x chezmoi@latest -- chezmoi init --source "$SOURCE_DIR" \
      --promptChoice "Profile=$PROFILE" --promptBool "Work profile=$work_answer"
    preauth
    run_apply chezmoi@latest
    return
  fi
  # The inner script is single-quoted on purpose: $1..$4 expand in the inner shell.
  # shellcheck disable=SC2016
  mise x gh@latest chezmoi@latest -- sh -c '
    set -eu
    gh auth status >/dev/null 2>&1 || gh auth login --git-protocol https --web
    gh auth setup-git
    chezmoi init --source "$1" \
      --promptChoice "Profile=$2" --promptBool "Work profile=$3" "$4"
  ' sh "$SOURCE_DIR" "$PROFILE" "$work_answer" "$DOTFILES_URL"
  preauth
  run_apply gh@latest chezmoi@latest
}

# finish.sh joins Tailscale, runs the Secrets step, then prints the manual steps last.
finish() {
  echo "Bootstrap finished."
  if [ -f "$SOURCE_DIR/scripts/finish.sh" ]; then
    sh "$SOURCE_DIR/scripts/finish.sh"
  elif [ -f "$SOURCE_DIR/scripts/checklist.sh" ]; then
    sh "$SOURCE_DIR/scripts/checklist.sh"
  else
    echo "Open a new terminal. Manual steps: run claude and pi once and sign in, join Tailscale, then run 'just secrets' in $SOURCE_DIR."
  fi
}

main() {
  parse_flags "$@" || exit $?
  os=$(detect_os)
  setup_sudo
  install_prereqs "$os"
  install_mise
  apply_dotfiles
  finish
}

if [ -z "${BOOTSTRAP_SOURCE_ONLY:-}" ]; then
  main "$@"
fi

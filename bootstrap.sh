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
usage: bootstrap.sh (--desktop | --headless) [--work]

  --desktop   GUI machine: also installs kitty
  --headless  server or VM: terminal tools only
  --work      also installs the work-profile extras

Test hook: BOOTSTRAP_LOCAL_REPO=/path/to/dotfiles skips GitHub login and applies that checkout.
EOF
}

parse_flags() {
  PROFILE=""
  WORK=false
  for arg in "$@"; do
    case "$arg" in
      --desktop)
        [ -z "$PROFILE" ] || [ "$PROFILE" = desktop ] || { echo "error: choose one of --desktop or --headless" >&2; return 2; }
        PROFILE=desktop ;;
      --headless)
        [ -z "$PROFILE" ] || [ "$PROFILE" = headless ] || { echo "error: choose one of --desktop or --headless" >&2; return 2; }
        PROFILE=headless ;;
      --work) WORK=true ;;
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
    mise x chezmoi@latest -- chezmoi init --source "$SOURCE_DIR" --apply \
      --promptChoice "Profile=$PROFILE" --promptBool "Work profile=$work_answer"
    return
  fi
  # The inner script is single-quoted on purpose: $1..$4 expand in the inner shell.
  # shellcheck disable=SC2016
  mise x gh@latest chezmoi@latest -- sh -c '
    set -eu
    gh auth status >/dev/null 2>&1 || gh auth login --git-protocol https --web
    gh auth setup-git
    chezmoi init --source "$1" --apply \
      --promptChoice "Profile=$2" --promptBool "Work profile=$3" "$4"
  ' sh "$SOURCE_DIR" "$PROFILE" "$work_answer" "$DOTFILES_URL"
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
  install_prereqs "$os"
  install_mise
  apply_dotfiles
  finish
}

if [ -z "${BOOTSTRAP_SOURCE_ONLY:-}" ]; then
  main "$@"
fi

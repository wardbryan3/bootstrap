# bootstrap

Public stub for rebuilding a machine. It contains no secrets.

    sh -c "$(curl -fsSL https://raw.githubusercontent.com/wardbryan3/bootstrap/main/bootstrap.sh)" -- --headless

Flags: `--desktop` or `--headless` (required), `--work` (optional).
You approve one GitHub device login in the browser. Everything else is automatic.

On a machine that already has config, preview first. Add `--dry-run` to the same command: it lists the files a real run would replace, the scripts it would run and the side effects (sudo, installs, login shell), shows the diff of each replaced file, and changes nothing. It needs `gh` signed in (or an existing `~/code/dotfiles`) and never signs you in itself.

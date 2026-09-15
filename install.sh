#!/usr/bin/env bash
#
# agent-vm installer.
#
#   ./install.sh            install (idempotent, safe to re-run)
#   ./install.sh --uninstall  remove what this script added
#
# Does two things, both optional and both reversible:
#
#   1. Puts `agent-vm` on your PATH, as a symlink to agent-vm.sh in this repo.
#      The script already dispatches when executed rather than sourced, so the
#      link is all that is needed. Being a link (not a copy) means `git pull`
#      updates the command with no reinstall.
#
#   2. Adds `source <repo>/agent-vm.sh` to your shell rc, which additionally
#      defines `agent-vm` as a shell *function*.
#
# Sourcing has always been the documented install and KEEPS WORKING EXACTLY AS
# BEFORE — an existing install needs nothing but `git pull`. The PATH entry is
# additive: it makes `agent-vm` reachable from scripts and other tools, which a
# shell function is not (functions are not inherited by child processes).
#
# If you already source agent-vm.sh, the function wins inside your interactive
# shell and the symlink serves everything else. The two agree: same file.

set -euo pipefail

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$REPO_DIR/agent-vm.sh"
BIN_DIR="${AGENT_VM_BIN_DIR:-$HOME/.local/bin}"
LINK="$BIN_DIR/agent-vm"

c_g=''; c_y=''; c_r=''; c_0=''
if [ -t 1 ]; then c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_0=$'\033[0m'; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
err()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; }

# The rc file where a shell *function* belongs: the interactive one.
# (A PATH entry would go elsewhere for zsh — ~/.zshenv — but that is not what
# this line is for.)
rc_file() {
  case "${SHELL##*/}" in
    zsh)  printf '%s' "$HOME/.zshrc" ;;
    bash) case "$(uname -s)" in
            Darwin) printf '%s' "$HOME/.bash_profile" ;;
            *)      printf '%s' "$HOME/.bashrc" ;;
          esac ;;
    *)    printf '%s' "$HOME/.profile" ;;
  esac
}

# Is agent-vm.sh already sourced from any of the usual rc files?
already_sourced() {
  local f
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshenv"; do
    [ -f "$f" ] || continue
    grep -q '^[^#]*agent-vm\.sh' "$f" 2>/dev/null && return 0
  done
  return 1
}

uninstall() {
  if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SCRIPT" ]; then
    rm -f "$LINK"
    ok "removed $LINK"
  else
    [ -e "$LINK" ] && warn "$LINK is not our symlink — left alone." || ok "no symlink to remove"
  fi
  if already_sourced; then
    warn "The 'source ...agent-vm.sh' line in your shell rc is left in place."
    warn "Remove it by hand if you want the shell function gone too."
  fi
  ok "Done. The repository itself was not touched."
}

if [ "${1:-}" = "--uninstall" ]; then
  uninstall
  exit 0
fi

[ -r "$SCRIPT" ] || { err "agent-vm.sh not found next to this installer."; exit 1; }
chmod +x "$SCRIPT" 2>/dev/null || true

# --- 1. agent-vm on PATH -------------------------------------------------------
mkdir -p "$BIN_DIR"
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SCRIPT" ]; then
  ok "agent-vm already linked at $LINK"
elif [ -e "$LINK" ]; then
  err "$LINK already exists and is not a link to $SCRIPT."
  err "Move it aside, or set AGENT_VM_BIN_DIR to another directory."
  exit 1
else
  ln -s "$SCRIPT" "$LINK"
  ok "linked $LINK -> $SCRIPT"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR is on your PATH" ;;
  *)
    warn "$BIN_DIR is not on your PATH. Add this to your shell rc:"
    printf '    export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
esac

# --- 2. shell function (optional, additive) ------------------------------------
if already_sourced; then
  ok "agent-vm.sh is already sourced by your shell — nothing to add"
else
  RC="$(rc_file)"
  printf 'Also define agent-vm as a shell function in %s? [Y/n] ' "$RC"
  reply=''
  # Test the terminal before redirecting from it: `< /dev/tty` on a machine
  # without one (CI, a pipe) fails loudly before any `||` can catch it.
  if [ -r /dev/tty ]; then
    IFS= read -r reply </dev/tty || reply='n'
  else
    reply='n'
    printf '(no terminal — skipping)\n'
  fi
  case "${reply:-Y}" in
    [Nn]*)
      ok "Skipped. The command on your PATH is enough for everyday use." ;;
    *)
      printf '\n# agent-vm\nsource "%s"\n' "$SCRIPT" >> "$RC"
      ok "added the source line to $RC (effective in a new terminal)" ;;
  esac
fi

echo
ok "agent-vm $("$SCRIPT" version) installed."
echo "  Next: agent-vm setup     # build the base VM (once)"
echo "        agent-vm help"

# --- install / uninstall: agent-vm on the PATH ----------------------------------
# `install` puts agent-vm on the PATH as a symlink to agent-vm.sh in the clone:
# the script dispatches when executed, so a link is all a command needs, and
# `git pull` updates it (a launcher script where there are no symlinks, see
# _agent_vm_launcher). It then offers to source agent-vm.sh from the shell
# rc, which also defines agent-vm as a shell function. Safe to re-run.
# AGENT_VM_BIN_DIR picks the directory (default ~/.local/bin).

_agent_vm_bin_link() {
  printf '%s/agent-vm\n' "${AGENT_VM_BIN_DIR:-$HOME/.local/bin}"
}

# Where `ln -s` makes no link (Git Bash copies the file unless Windows grants
# symlinks), a copy of agent-vm.sh would look for lib/ next to itself and not
# find it. `install` writes this launcher instead: it runs the real file.
_agent_vm_launcher() {
  printf '#!/usr/bin/env bash\n# Written by agent-vm install: this system makes no symlinks.\nexec bash '"'"'%s'"'"' "$@"\n' \
    "$(_agent_vm_sq_escape "$1")"
}

# 0 when <path> is what `install` puts there for <script>: a link to it, or
# the launcher running it.
# Not `path`: zsh ties that name to PATH.
_agent_vm_installed_ours() {
  local target="$1" script="$2"
  if [[ -L "$target" ]]; then
    [[ "$(readlink "$target")" == "$script" ]]
  else
    [[ -f "$target" && "$(cat "$target" 2>/dev/null)" == "$(_agent_vm_launcher "$script")" ]]
  fi
}

# The rc file where a shell function belongs: the interactive one.
_agent_vm_rc_file() {
  case "${SHELL##*/}" in
    zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    bash)
      case "$(uname -s 2>/dev/null)" in
        # Git Bash login shells read .bash_profile (like Terminal.app),
        # not .bashrc.
        Darwin|MINGW*|MSYS*|CYGWIN*) printf '%s\n' "$HOME/.bash_profile" ;;
        *)      printf '%s\n' "$HOME/.bashrc" ;;
      esac ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}

# 0 when an uncommented line of a usual rc file names agent-vm.sh.
_agent_vm_rc_sources_us() {
  local f
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshenv"; do
    [[ -f "$f" ]] || continue
    grep -q '^[^#]*agent-vm\.sh' "$f" 2>/dev/null && return 0
  done
  return 1
}

_agent_vm_install() {
  if [[ $# -gt 0 ]]; then
    echo "Usage: agent-vm install" >&2
    return 2
  fi
  local script="$AGENT_VM_SCRIPT_DIR/agent-vm.sh" link bin_dir rc
  link="$(_agent_vm_bin_link)"
  bin_dir="$(dirname "$link")"
  if [[ ! -r "$script" ]]; then
    echo "Error: agent-vm.sh not found in $AGENT_VM_SCRIPT_DIR." >&2
    return 1
  fi
  chmod +x "$script" 2>/dev/null || true
  mkdir -p "$bin_dir" || return 1
  if _agent_vm_installed_ours "$link" "$script"; then
    echo "agent-vm is already linked at $link"
  elif [[ -e "$link" || -L "$link" ]]; then
    # -L too: a dangling link is not -e, and ln would fail on it.
    echo "Error: $link already exists and is not a link to $script." >&2
    echo "  Move it aside, or set AGENT_VM_BIN_DIR to another directory." >&2
    return 1
  else
    ln -s "$script" "$link" 2>/dev/null
    if [[ -L "$link" ]]; then
      echo "Linked $link -> $script"
    else
      rm -f "$link"
      _agent_vm_launcher "$script" > "$link" && chmod +x "$link" || return 1
      echo "Installed $link, a launcher for $script (no symlinks on this system)"
    fi
  fi
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
      echo "$bin_dir is not on your PATH. Add this line to your shell rc:"
      printf '  export PATH="%s:$PATH"\n' "$bin_dir" ;;
  esac
  if _agent_vm_rc_sources_us; then
    echo "agent-vm.sh is already sourced by your shell rc."
  else
    rc="$(_agent_vm_rc_file)"
    if _agent_vm_have_tty \
       && [[ "$(_agent_vm_ask_yn "Also define agent-vm as a shell function in $rc?" Y)" == "1" ]]; then
      printf '\n# agent-vm\nsource "%s"\n' "$script" >> "$rc" || return 1
      echo "Added the source line to $rc (in effect in new terminals)."
    fi
  fi
  echo ""
  echo "agent-vm $AGENT_VM_VERSION installed."
  if _agent_vm_base_exists; then
    echo "Next:  cd your-project && agent-vm claude   # or opencode, codex, vibe"
    return 0
  fi
  if _agent_vm_have_tty \
     && [[ "$(_agent_vm_ask_yn "Build the base VM now with 'agent-vm setup'? It takes a few minutes." Y)" == "1" ]]; then
    echo ""
    _agent_vm_setup
    return
  fi
  echo "Next:"
  echo "  agent-vm setup     # build the base VM, once"
}

# Removes the link `install` made, and nothing else: the rc line is named, not
# edited, and the VMs, ~/.agent-vm and the clone stay.
_agent_vm_uninstall() {
  if [[ $# -gt 0 ]]; then
    echo "Usage: agent-vm uninstall" >&2
    return 2
  fi
  local script="$AGENT_VM_SCRIPT_DIR/agent-vm.sh" link
  link="$(_agent_vm_bin_link)"
  if _agent_vm_installed_ours "$link" "$script"; then
    rm -f "$link" || return 1
    echo "Removed $link"
  elif [[ -e "$link" || -L "$link" ]]; then
    echo "$link is not a link to this agent-vm: left alone."
  else
    echo "No link to remove at $link"
  fi
  if _agent_vm_rc_sources_us; then
    echo "Your shell rc still sources agent-vm.sh: remove that line to drop the shell function."
  fi
  echo "The VMs, ~/.agent-vm and this clone are left as they are ('agent-vm destroy-all' deletes the VMs)."
}

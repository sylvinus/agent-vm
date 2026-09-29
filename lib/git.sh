# --- .git protection ------------------------------------------------------------
# Git on the host runs what a repository's .git/config and hooks name
# (core.fsmonitor on every `git status`, hooks on commit), and editors and
# shell prompts run git on their own. A VM able to write a .git in a shared
# folder could therefore run commands on the host.
#
# Lima's `sshfs.readonlyNames` makes every path with a `.git` component
# read-only for the guest, at any depth, while the rest of the share stays
# writable. Lima's builtin SFTP server enforces it on the host, so root in the
# guest cannot lift it. It needs mountType reverse-sshfs and the builtin driver
# on every mount.
#
# Upstream Lima does not have it yet (lima-vm/lima#5529). Until it does, a
# Lima build that has it: the Homebrew formula, or the tag it is built from.
AGENT_VM_LIMA_FORMULA="sylvinus/tap/lima-sylvinus"
AGENT_VM_LIMA_FORK_TAG="v2.3.0-sylvinus.1"
AGENT_VM_LIMA_ISSUE="https://github.com/lima-vm/lima/issues/5529"

# 0 when this Lima enforces sshfs.readonlyNames. Stock Lima accepts the field
# and ignores it, with a mere warning, so support is probed, never assumed:
# `limactl validate` on a config pairing it with virtiofs, which a Lima that
# knows the field rejects, naming it. One that does not know it warns about an
# "unknown field" and accepts the file. Anything else counts as no.
#
# Not cached: agent-vm is also a shell function, where a cached answer would
# outlive a Lima upgrade.
_agent_vm_lima_protects_git() {
  local dir out accepted=""
  dir="$(mktemp -d 2>/dev/null)" || return 1
  printf 'images: [{location: "/"}]\nmountType: virtiofs\nmounts: [{location: "%s", sshfs: {sftpDriver: builtin, readonlyNames: [.git]}}]\n' \
    "$dir" > "$dir/probe.yaml"
  out="$(limactl validate "$dir/probe.yaml" 2>&1)" && accepted=1
  rm -rf "$dir"
  [[ -z "$accepted" && "$out" == *readonlyNames* && "$out" != *"unknown field"* ]]
}

# The `limactl edit --set` expression applying a mounts JSON, and the mount
# type that goes with it. With every .git read-only ($2 = 1): reverse-sshfs,
# which readonlyNames needs. Without: Lima's default, and not a reverse-sshfs
# left over from a Lima that had readonlyNames: on a Lima without it, a
# compromised guest can reach host paths outside the shares through the SFTP
# server (Lima's mount documentation says so for both drivers).
_agent_vm_mounts_expr() {
  if [[ "${2:-}" == 1 ]]; then
    printf '.mountType = "reverse-sshfs" | .mounts = %s' "$1"
  else
    printf 'del(.mountType) | .mounts = %s' "$1"
  fi
}

# Why .git is not protected, and how to install a Lima that does it, on stdout.
# With Homebrew (macOS, or Linux): the formula, which conflicts with brew's own
# lima, hence the unlink. Without: a build from source, as the formula does it.
# One paragraph per line: _agent_vm_wrap and _agent_vm_box fit it to the screen.
_agent_vm_git_protection_hint() {
  cat <<EOF
An agent could write .git/config or .git/hooks in your projects, and git on this machine would run them, even when your editor or shell prompt calls git.

A Lima build with sshfs.readonlyNames prevents it, until upstream merges it ($AGENT_VM_LIMA_ISSUE):
EOF
  if command -v brew >/dev/null 2>&1; then
    echo "  brew unlink lima 2>/dev/null; brew install $AGENT_VM_LIMA_FORMULA"
  else
    echo "  git clone --depth 1 -b $AGENT_VM_LIMA_FORK_TAG https://github.com/sylvinus/lima"
    echo "  cd lima && make native && sudo make install   # needs Go and make"
  fi
}

# AGENT_VM_UNSAFE_WRITABLE_GIT=1, or --unsafe-writable-git for one command,
# turns the protection off, for those who let the agent commit in the shared
# project. Only the host can ask for it: a setting in a file of the project
# would be one the VM can write. _agent_vm_ensure_running sets
# _agent_vm_unsafe_git_flag, as a local, for the flag.
_agent_vm_writable_git_optout() {
  [[ "${AGENT_VM_UNSAFE_WRITABLE_GIT:-}" == 1 || -n "${_agent_vm_unsafe_git_flag:-}" ]]
}

# What turned it off, to name it back to the user.
_agent_vm_writable_git_why() {
  if [[ -n "${_agent_vm_unsafe_git_flag:-}" ]]; then
    printf '%s\n' "--unsafe-writable-git"
  else
    printf '%s\n' "AGENT_VM_UNSAFE_WRITABLE_GIT=1"
  fi
}

_agent_vm_writable_git_warning() {
  cat <<EOF
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! WARNING: $(_agent_vm_writable_git_why). The VM can write every .git.
!!
!! The agent can change .git/config and .git/hooks in the shared folders, and
!! git on this machine runs what they name: on your next commit, and whenever
!! your editor or shell prompt calls git. That is running commands on your
!! host, outside the VM. Without it, .git stays read-only.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
}

# --- setup: a Lima that keeps .git read-only ------------------------------------
# Run by `setup` once Lima is there, and by nothing else: nothing to do when it
# already protects .git. Otherwise it says why that matters and, with Homebrew
# and a terminal to ask on, offers to install the formula.
#
# brew refuses the formula next to its own lima (both install limactl) and asks
# for that one to be unlinked. Unlinking keeps it installed, so
# `brew uninstall lima-sylvinus && brew link lima` goes back. VMs are not
# touched either way. This never fails setup: the VMs work without it.
_agent_vm_offer_git_protection() {
  _agent_vm_lima_protects_git && return 0
  _agent_vm_git_protection_hint | _agent_vm_box "Lima cannot keep .git read-only"
  if ! command -v brew >/dev/null 2>&1 || ! _agent_vm_have_tty \
     || [[ "$(_agent_vm_ask_yn "Install $AGENT_VM_LIMA_FORMULA now (built from source, takes a few minutes)?" Y)" != "1" ]]; then
    echo "Continuing without .git protection." >&2
    return 0
  fi
  local unlinked=""
  if brew list --formula lima >/dev/null 2>&1; then
    brew unlink lima && unlinked=1
  fi
  if ! brew install "$AGENT_VM_LIMA_FORMULA"; then
    # Unlinked and nothing in its place would leave no limactl at all.
    [[ -n "$unlinked" ]] && brew link lima
    echo "Warning: the install failed. Continuing without .git protection." >&2
    return 0
  fi
  hash -r 2>/dev/null
  if _agent_vm_lima_protects_git; then
    echo "Lima now keeps every .git read-only for the VMs."
  else
    echo "Warning: the limactl on PATH ($(command -v limactl)) still cannot keep .git read-only." >&2
    echo "  Another Lima install comes first on PATH. Continuing without .git protection." >&2
  fi
}

# --- git on this machine: repositories not named .git ---------------------------
# readonlyNames protects a name, and a bare repository has none: a folder with
# HEAD, objects/ and refs/ is a repository to git, found by the same upward
# search from the current directory as a .git. Its config then applies, and
# some of it names commands git runs: core.pager on `git log`, for one. The VM
# can create such a folder anywhere in a share. safe.bareRepository=explicit (git 2.38+)
# makes git use a bare repository only when --git-dir or GIT_DIR names it.

# ok, unset, old (git before 2.38, which ignores the setting) or nogit. Read
# from /, outside any repository: git only honours the setting from the system
# and global config, so a repository's own config must not answer.
_agent_vm_bare_repo_state() {
  command -v git >/dev/null 2>&1 || { echo nogit; return 0; }
  local v
  v="$(git --version 2>/dev/null)"
  v="${v#git version }"
  v="${v%% *}"
  if ! _agent_vm_ver_ge "$v" 2.38.0; then
    echo old
  elif [[ "$(cd / && git config --get safe.bareRepository 2>/dev/null)" == "explicit" ]]; then
    echo ok
  else
    echo unset
  fi
}

# One paragraph per line, as for _agent_vm_git_protection_hint.
_agent_vm_bare_repo_hint() {
  cat <<'EOF'
Git treats any folder with HEAD, objects/ and refs/ as a repository, even without .git, and runs commands its config names (on `git log`, for one). A VM could create one in your projects, and the .git protection does not cover it.

This makes git ignore such folders unless named with --git-dir:
  git config --global safe.bareRepository explicit
EOF
}

# Run by `setup`. Asks to run the command above, with a terminal to ask on;
# without one, or on a no, says what is left open. Never fails setup.
_agent_vm_offer_bare_repo_setting() {
  case "$(_agent_vm_bare_repo_state)" in
    ok|nogit) return 0 ;;
    old)
      _agent_vm_bare_repo_hint | _agent_vm_box "Recommended: one git setting"
      echo "Warning: $(git --version) is older than 2.38 and ignores that setting. Upgrade git, then run the command above." >&2
      return 0 ;;
  esac
  _agent_vm_bare_repo_hint | _agent_vm_box "Recommended: one git setting"
  if ! _agent_vm_have_tty \
     || [[ "$(_agent_vm_ask_yn "Run it now? It changes your global git config." Y)" != "1" ]]; then
    echo "Warning: not set. Until you run the command above, git on this machine can run what a VM writes." >&2
    return 0
  fi
  if git config --global safe.bareRepository explicit && [[ "$(_agent_vm_bare_repo_state)" == "ok" ]]; then
    echo "Git on this machine now ignores repositories not named .git unless you name them."
  else
    echo "Warning: the setting did not take. Run the command above yourself." >&2
  fi
}

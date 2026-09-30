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
AGENT_VM_LIMA_FORK_TAG="v2.3.0-sylvinus.2"
# The Windows zips of that tag, in SHA256SUMS format. The download is checked
# against these, not against the SHA256SUMS of the release, which whoever can
# replace the zips can replace too. Updated with the tag.
AGENT_VM_LIMA_FORK_SHA256="053f3479b397628b79fe46b0268a50a7f1fc51073691d7d8bce78c9be2ae2787  lima-2.3.0-sylvinus.2-Windows-AMD64.zip
a0828aa4518e21c9519d341be9f32adf07cbeb74a3f8beadaa2f350c45b5933b  lima-additional-guestagents-2.3.0-sylvinus.2-Windows-AMD64.zip
1cb2d94a9a5f38b2f38f9c14715d850a861a9623b9a7f7ae7b0f6431b75aaa81  lima-2.3.0-sylvinus.2-Windows-ARM64.zip
1ae0b7b054191f4197898bd59697ee99350d3b7e95b895c1b0ec061c7ea87e7f  lima-additional-guestagents-2.3.0-sylvinus.2-Windows-ARM64.zip"
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
    "$(_agent_vm_host_path "$dir")" > "$dir/probe.yaml"
  out="$(limactl validate "$(_agent_vm_host_path "$dir/probe.yaml")" 2>&1)" && accepted=1
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
# lima, hence the unlink. On Windows: the fork's release zips, which `setup`
# offers to download. Without either: a build from source, as the formula
# does it. One paragraph per line: _agent_vm_wrap and _agent_vm_box fit it to
# the screen.
_agent_vm_git_protection_hint() {
  cat <<EOF
An agent could write .git/config or .git/hooks in your projects, and git on this machine would run them, even when your editor or shell prompt calls git.

A Lima build with sshfs.readonlyNames prevents it, until upstream merges it ($AGENT_VM_LIMA_ISSUE):
EOF
  if _agent_vm_on_windows; then
    echo "  agent-vm setup offers the download, or get it by hand:"
    echo "  $(_agent_vm_lima_fork_release) (both Windows zips, verified, on PATH)"
  elif command -v brew >/dev/null 2>&1; then
    echo "  brew unlink lima 2>/dev/null; brew install $AGENT_VM_LIMA_FORMULA"
  else
    echo "  git clone --depth 1 -b $AGENT_VM_LIMA_FORK_TAG https://github.com/sylvinus/lima"
    echo "  cd lima && make native && sudo make install   # needs Go and make"
  fi
}

# The fork release holding the Windows builds, and this machine's asset names
# in it. Names follow upstream's `make artifacts-windows` convention:
# lima-<version>-Windows-<ARCH>.zip, where <version> is the fork tag without
# its leading v. Fails when the architecture is not one assets are built for.
_agent_vm_lima_fork_release() {
  printf 'https://github.com/sylvinus/lima/releases/download/%s\n' "$AGENT_VM_LIMA_FORK_TAG"
}

# Windows architecture as the asset names spell it (AMD64/ARM64), from uname.
_agent_vm_lima_fork_arch() {
  case "$(uname -m 2>/dev/null)" in
    x86_64) printf 'AMD64\n' ;;
    aarch64|arm64) printf 'ARM64\n' ;;
    *)
      echo "Error: no Lima fork build for this architecture: $(uname -m 2>/dev/null)" >&2
      return 1 ;;
  esac
}

# The fork release's files for this machine: both zips. One per line, so the
# installer loops over it and the tests pin the names.
_agent_vm_lima_fork_files() {
  local arch tag
  arch="$(_agent_vm_lima_fork_arch)" || return 1
  tag="${AGENT_VM_LIMA_FORK_TAG#v}"
  printf 'lima-%s-Windows-%s.zip\n' "$tag" "$arch"
  printf 'lima-additional-guestagents-%s-Windows-%s.zip\n' "$tag" "$arch"
}

# Every file named in "$@" inside <dir> must match its SHA256SUMS entry
# there. Fails closed (a missing tool, an unlisted file, a mismatch) naming
# the culprit, so a half-downloaded Lima never lands on PATH.
_agent_vm_sha256_sums_check() {
  local dir="$1" f expected actual
  shift
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || { echo "Error: neither sha256sum nor shasum is installed." >&2; return 1; }
  for f in "$@"; do
    # A leading * marks binary mode (`sha256sum -b`, and Git Bash's default).
    expected="$(awk -v f="$f" '{ n = $2; sub(/^\*/, "", n) } n == f { print $1; exit }' "$dir/SHA256SUMS")"
    if [[ -z "$expected" ]]; then
      echo "Error: SHA256SUMS lists no checksum for $f." >&2
      return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$dir/$f" 2>/dev/null | cut -d' ' -f1)"
    else
      actual="$(shasum -a 256 "$dir/$f" 2>/dev/null | cut -d' ' -f1)"
    fi
    if [[ -z "$actual" || "$actual" != "$expected" ]]; then
      echo "Error: checksum mismatch for $f (expected $expected, got ${actual:-unreadable})." >&2
      return 1
    fi
  done
}

# Download and install the fork's Windows build: both zips, verified against
# AGENT_VM_LIMA_FORK_SHA256, then unpacked into a staging dir next to AGENT_VM_LIMA_DIR
# (default ~/.local/share/lima-sylvinus), which takes its place only once
# complete. A failed run leaves the previous install, or none, as it was.
#
# An install of AGENT_VM_LIMA_FORK_TAG is reused. One of another tag (or
# unmarked) is replaced, in the same directory, so the PATH line the user
# already has keeps working. Windows cannot move a directory whose limactl.exe
# is running, which is the case while a VM runs: that is said, and the old
# install stays.
#
# The bin dir goes on PATH for the rest of this shell when it is not there
# already, with the line making it permanent printed alongside: setup needs
# limactl immediately, and the user needs it in the next terminal.
_agent_vm_install_fork_windows() {
  local base dir tmp f bin="" stage old=""
  base="$(_agent_vm_lima_fork_release)"
  dir="${AGENT_VM_LIMA_DIR:-$HOME/.local/share/lima-sylvinus}"
  if [[ -x "$dir/bin/limactl.exe" \
        && "$(cat "$dir/.agent-vm-lima-tag" 2>/dev/null)" == "$AGENT_VM_LIMA_FORK_TAG" ]]; then
    bin="$dir/bin"
    echo "Lima $AGENT_VM_LIMA_FORK_TAG is already installed at $bin."
  else
    if [[ -e "$dir" && ! -x "$dir/bin/limactl.exe" ]]; then
      echo "Error: $dir exists and is not a Lima install: move it, or set AGENT_VM_LIMA_DIR." >&2
      return 1
    fi
    command -v curl >/dev/null 2>&1 \
      || { echo "Error: curl is required to download Lima." >&2; return 1; }
    local files
    files="$(_agent_vm_lima_fork_files)" || return 1
    mkdir -p "$(dirname "$dir")" || return 1
    tmp="$(mktemp -d 2>/dev/null)" || return 1
    # The || keeps the last line: command substitution strips its newline.
    while IFS= read -r f || [[ -n "$f" ]]; do
      [[ -n "$f" ]] || continue
      echo "Downloading $f..."
      if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 \
           -o "$tmp/$f" "$base/$f"; then
        echo "Error: could not download $base/$f." >&2
        rm -rf "$tmp"
        return 1
      fi
    done <<< "$files"
    printf '%s\n' "$AGENT_VM_LIMA_FORK_SHA256" > "$tmp/SHA256SUMS"
    # In a subshell under $tmp, so the glob below names the downloads and not
    # whatever lima-*.zip the caller's directory happens to hold.
    if ! ( cd "$tmp" && _agent_vm_sha256_sums_check "$tmp" lima-*.zip ); then
      rm -rf "$tmp"
      return 1
    fi
    stage="$dir.new.$$"
    rm -rf "$stage"
    mkdir -p "$stage" || { rm -rf "$tmp"; return 1; }
    # The || keeps the last line: command substitution strips its newline.
    while IFS= read -r f || [[ -n "$f" ]]; do
      case "$f" in lima-*.zip) ;;
        *) continue ;;
      esac
      if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$tmp/$f" -d "$stage" || { echo "Error: could not unpack $f." >&2; rm -rf "$tmp" "$stage"; return 1; }
      elif tar -tf "$tmp/$f" >/dev/null 2>&1; then
        tar -xf "$tmp/$f" -C "$stage" || { echo "Error: could not unpack $f." >&2; rm -rf "$tmp" "$stage"; return 1; }
      else
        echo "Error: neither unzip nor tar can unpack $f." >&2
        rm -rf "$tmp" "$stage"
        return 1
      fi
    done <<< "$files"
    rm -rf "$tmp"
    if [[ ! -x "$stage/bin/limactl.exe" ]]; then
      echo "Error: the download unpacked without bin/limactl.exe; nothing was installed." >&2
      rm -rf "$stage"
      return 1
    fi
    printf '%s\n' "$AGENT_VM_LIMA_FORK_TAG" > "$stage/.agent-vm-lima-tag"
    if [[ -e "$dir" ]]; then
      old="$dir.old.$$"
      if ! mv "$dir" "$old" 2>/dev/null; then
        echo "Error: could not replace the Lima install in $dir: stop the running VMs ('agent-vm status'), then retry." >&2
        rm -rf "$stage"
        return 1
      fi
    fi
    if ! mv "$stage" "$dir"; then
      [[ -n "$old" ]] && mv "$old" "$dir"
      rm -rf "$stage"
      return 1
    fi
    [[ -n "$old" ]] && rm -rf "$old"
    bin="$dir/bin"
    echo "Lima $AGENT_VM_LIMA_FORK_TAG is installed at $bin."
  fi
  case ":$PATH:" in
    *":$bin:"*) ;;
    *)
      export PATH="$bin:$PATH"
      echo "Added $bin to PATH for this shell. To keep it, add this line to ~/.bash_profile:"
      printf '  export PATH="%s:$PATH"\n' "$bin" ;;
  esac
}

# On Windows, when the Lima that _agent_vm_install_fork_windows put in place
# is of another tag than AGENT_VM_LIMA_FORK_TAG, offer to replace it. Never
# fails setup: the installed one keeps working.
_agent_vm_offer_fork_windows_update() {
  _agent_vm_on_windows || return 0
  local dir="${AGENT_VM_LIMA_DIR:-$HOME/.local/share/lima-sylvinus}" have
  [[ -x "$dir/bin/limactl.exe" ]] || return 0
  have="$(cat "$dir/.agent-vm-lima-tag" 2>/dev/null)"
  [[ "$have" != "$AGENT_VM_LIMA_FORK_TAG" ]] || return 0
  _agent_vm_have_tty || { echo "Note: Lima ${have:-(unknown version)} in $dir; 'agent-vm setup' in a terminal offers $AGENT_VM_LIMA_FORK_TAG." >&2; return 0; }
  [[ "$(_agent_vm_ask_yn "Update the Lima in $dir from ${have:-an unknown version} to $AGENT_VM_LIMA_FORK_TAG?" Y)" == "1" ]] || return 0
  _agent_vm_install_fork_windows || echo "Warning: the update failed; the installed Lima stays." >&2
  hash -r 2>/dev/null
  return 0
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
# already protects .git. Otherwise it says why that matters and, with a
# terminal to ask on, offers to install the build that has it: the formula
# with Homebrew, the release zips on Windows.
#
# brew refuses the formula next to its own lima (both install limactl) and asks
# for that one to be unlinked. Unlinking keeps it installed, so
# `brew uninstall lima-sylvinus && brew link lima` goes back. VMs are not
# touched either way. This never fails setup: the VMs work without it.
_agent_vm_offer_git_protection() {
  _agent_vm_offer_fork_windows_update
  _agent_vm_lima_protects_git && return 0
  _agent_vm_git_protection_hint | _agent_vm_box "Lima cannot keep .git read-only"
  if _agent_vm_on_windows; then
    if ! _agent_vm_have_tty \
       || [[ "$(_agent_vm_ask_yn "Download the Lima build that has it now (both Windows zips, about 60 MB)?" Y)" != "1" ]]; then
      echo "Continuing without .git protection." >&2
      return 0
    fi
    if ! _agent_vm_install_fork_windows; then
      echo "Warning: the download failed. Continuing without .git protection." >&2
      return 0
    fi
    hash -r 2>/dev/null
    if _agent_vm_lima_protects_git; then
      echo "Lima now keeps every .git read-only for the VMs."
    else
      echo "Warning: the limactl on PATH ($(_agent_vm_limactl_path)) still cannot keep .git read-only." >&2
      echo "  Another Lima install comes first on PATH. Continuing without .git protection." >&2
    fi
    return 0
  fi
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
    echo "Warning: the limactl on PATH ($(_agent_vm_limactl_path)) still cannot keep .git read-only." >&2
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

# git, for agent-vm's own calls in a directory the VM can write. The VM may have
# planted a repository there: a bare one, whatever the user's
# safe.bareRepository, or a .git where Lima cannot protect it. -c is honoured
# for safe.bareRepository (command-line config is trusted, a repository's own
# is not), which refuses the bare one. core.fsmonitor=false stops the command
# a repository's config names from running on commands that read the index,
# and --no-pager the one pager.<cmd> and core.pager would start on a terminal.
_agent_vm_git_untrusted() {
  git --no-pager -c safe.bareRepository=explicit -c core.fsmonitor=false "$@"
}

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

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

# Does this Lima enforce sshfs.readonlyNames? 0 yes, 1 no, 2 cannot tell.
# Stock Lima accepts the field and ignores it, with a mere warning, so support
# is probed, never assumed: `limactl validate` on a config pairing it with
# virtiofs, which a Lima that knows the field rejects, naming it. One that
# does not know it warns about an "unknown field". Any other answer (no
# limactl, a failure that names neither, a Lima that accepts the file without
# a word) is "cannot tell", never "no": callers must not drop the protection
# of a VM on an answer they could not read.
#
# Not cached: agent-vm is also a shell function, where a cached answer would
# outlive a Lima upgrade.
_agent_vm_lima_protects_git() {
  local dir out accepted=""
  dir="$(mktemp -d 2>/dev/null)" || return 2
  printf 'images: [{location: "/"}]\nmountType: virtiofs\nmounts: [{location: "%s", sshfs: {sftpDriver: builtin, readonlyNames: [.git]}}]\n' \
    "$(_agent_vm_host_path "$dir")" > "$dir/probe.yaml"
  out="$(limactl validate "$(_agent_vm_host_path "$dir/probe.yaml")" 2>&1)" && accepted=1
  rm -rf "$dir"
  if [[ "$out" == *"unknown field"* && "$out" == *readonlyNames* ]]; then
    return 1
  elif [[ -z "$accepted" && "$out" == *readonlyNames* ]]; then
    return 0
  fi
  return 2
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

# The names readonlyNames always lists, one per line. .hg: Mercurial runs the
# hooks of .hg/hgrc in a repository the user owns, which files written through
# a share are.
_agent_vm_base_readonly_names() {
  printf '%s\n' .git .hg
}

# 0 when the relative path <rel> goes through one of the names above, matched
# as the SFTP server does: per component, whatever the case.
_agent_vm_under_readonly_name() {
  local rest="$1/" c names
  names=$'\n'"$(_agent_vm_base_readonly_names)"$'\n'
  while [[ -n "$rest" ]]; do
    c="$(printf '%s' "${rest%%/*}" | tr '[:upper:]' '[:lower:]')"
    rest="${rest#*/}"
    [[ "$names" == *$'\n'"$c"$'\n'* ]] && return 0
  done
  return 1
}

# 0 on the hosts whose file systems ignore case by default: macOS, Windows.
_agent_vm_fs_nocase() {
  [[ "$(uname -s 2>/dev/null)" == Darwin ]] || _agent_vm_on_windows
}

# <s> lowercased on those hosts, as is elsewhere: paths compared as the file
# system does.
_agent_vm_fold() {
  if _agent_vm_fs_nocase; then
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
  else
    printf '%s\n' "$1"
  fi
}

# <path> relative to <dir>, "." for <dir> itself; fails when it is not inside.
# Compared whatever the case where the file system ignores it, so a path
# spelled with other capitals is still found inside.
_agent_vm_rel_in() {
  local target="${1%/}" dir="${2%/}" p d
  p="$(_agent_vm_fold "$target")"
  d="$(_agent_vm_fold "$dir")"
  if [[ "$p" == "$d" ]]; then
    printf '.\n'
    return 0
  fi
  [[ -n "$d" && "$p" == "$d/"* ]] || return 1
  printf '%s\n' "${target:$(( ${#dir} + 1 ))}"
}

# <dir> as git spells it: the physical path, C:/... on Windows.
_agent_vm_git_spelling() {
  local p
  p="$(CDPATH= cd -P -- "$1" 2>/dev/null && pwd)" || return 1
  _agent_vm_host_path "$p"
}

# <path> made absolute against <base> (both in git's spelling), `.` and `..`
# resolved in the text.
_agent_vm_git_abs() {
  case "$1" in
    /*) _agent_vm_path_join / "$1" ;;
    [A-Za-z]:/*) _agent_vm_path_join "${1%%/*}" "${1#*/}" ;;
    *) _agent_vm_path_join "$2" "$1" ;;
  esac
}

# The git repositories git on this machine uses in the project <dir>: the one
# holding <dir>, then those up to two levels below it (node_modules skipped),
# fifty at most. One directory per line, to run git in.
_agent_vm_project_repos() {
  local dir="$1"
  command -v git >/dev/null 2>&1 || return 0
  _agent_vm_git_untrusted -C "$dir" rev-parse --git-dir >/dev/null 2>&1 && printf '%s\n' "$dir"
  find "$dir" -mindepth 2 -maxdepth 3 \( -name node_modules -prune \) -o \( -name .git -print -prune \) 2>/dev/null \
    | awk 'NR <= 50' | while IFS= read -r g; do
        printf '%s\n' "${g%/.git}"
      done
}

# The folder git on the host runs the hooks of the repository at <repo> from,
# when core.hooksPath puts it in the project <proj> (in git's spelling) and
# outside the names above (husky sets .husky/_). Two fields, tab-separated:
# the folder relative to the project, "." for the project itself, then
# relative to the top of the repository when that is in the project (what
# names it: lib/x/.githooks is .githooks), or the same again. Fails otherwise,
# or when git cannot tell. `--git-path` without --path-format (git 2.31)
# answers relative to <repo>.
_agent_vm_repo_hooks() {
  local repo="$1" proj="$2" base top top_rel hooks rel in_repo
  base="$(_agent_vm_git_spelling "$repo")" || return 1
  hooks="$(_agent_vm_git_untrusted -C "$repo" rev-parse --git-path hooks 2>/dev/null)" || return 1
  [[ -n "$hooks" && "$hooks" != *$'\n'* && "$hooks" != *$'\t'* ]] || return 1
  hooks="$(_agent_vm_git_abs "$hooks" "$base")"
  rel="$(_agent_vm_rel_in "$hooks" "$proj")" || return 1
  [[ "$rel" == . ]] || ! _agent_vm_under_readonly_name "$rel" || return 1
  in_repo="$rel"
  if top="$(_agent_vm_git_untrusted -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
     && top_rel="$(_agent_vm_rel_in "$top" "$proj")" && [[ "$top_rel" != . ]]; then
    in_repo="$(_agent_vm_rel_in "$hooks" "$top")" || in_repo="$rel"
  fi
  printf '%s\t%s\n' "$rel" "$in_repo"
}

# Every hooks folder of the project <dir>'s repositories that is in the
# project and outside the names above (see _agent_vm_repo_hooks), one per
# line, with its two fields.
_agent_vm_project_hooks() {
  local dir="$1" proj repo
  proj="$(_agent_vm_git_spelling "$dir")" || return 0
  _agent_vm_project_repos "$dir" | while IFS= read -r repo; do
    _agent_vm_repo_hooks "$repo" "$proj"
  done | awk '!seen[$0]++'
}

# The name that keeps the hooks folder <rel> read-only: its first component,
# which covers the folder and whatever it calls next to it (husky's hooks call
# .husky/<hook>). Fails for the project itself, and for a name the mounts JSON
# cannot carry.
_agent_vm_hooks_name() {
  local name="${1%%/*}"
  [[ "$1" != . && -n "$name" && "$name" != *[\"\\]* && "$name" != *[[:cntrl:]]* ]] || return 1
  printf '%s\n' "$name"
}

# The readonlyNames JSON array: the names always listed, then "$@", each once.
_agent_vm_names_json() {
  local n out="" seen=$'\n'
  for n in $(_agent_vm_base_readonly_names) "$@"; do
    [[ "$seen" == *$'\n'"$n"$'\n'* ]] && continue
    seen="$seen$n"$'\n'
    out="${out:+$out, }\"$n\""
  done
  printf '[%s]\n' "$out"
}

# The readonlyNames JSON array a start gives the project <dir> unless the user
# declines a name: the names always listed, and those keeping its hooks
# folders read-only.
_agent_vm_readonly_names() {
  local rel in_repo name names=()
  while IFS=$'\t' read -r rel in_repo; do
    [[ -n "$rel" ]] || continue
    name="$(_agent_vm_hooks_name "$in_repo")" && names+=("$name")
  done <<< "$(_agent_vm_project_hooks "$1")"
  _agent_vm_names_json ${names[@]+"${names[@]}"}
}

# A readonlyNames JSON array as text: [".git", ".hg"] is ".git, .hg".
_agent_vm_names_text() {
  local s="${1#\[}"
  s="${s%\]}"
  printf '%s\n' "${s//\"/}"
}

_agent_vm_hooks_note() {
  echo "Note: git runs hooks from $1 (core.hooksPath): every '$2' in the project is read-only for the VM too."
}

# What git on this machine takes from files the VM can write, for the
# repository at <repo> in the project <proj> (git's spelling), one line each:
# a config file included from the project (whether it exists yet or not),
# and a setting whose command names
# a file in the project. The protected names are excepted, and core.hooksPath,
# which _agent_vm_repo_hooks covers. A relative path in a command is taken
# from the top of the repository, where git runs most of them.
#
# awk sorts the config first, so the shell only sees each file once and the
# settings that hold a command (section and key names lowercased, as
# `git config --list` prints them) with a path in their value: a start runs
# this, and a fork per line would show.
_agent_vm_repo_config_risks() {
  local repo="$1" proj="$2" base top kind a b w rel
  base="$(_agent_vm_git_spelling "$repo")" || return 0
  top="$(_agent_vm_git_untrusted -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 0
  _agent_vm_git_untrusted -C "$repo" config --list --show-origin --includes 2>/dev/null \
    | awk -F '\t' '
        {
          origin = $1; kv = substr($0, length($1) + 2)
          if (origin ~ /^file:/ && !(origin in seen)) {
            seen[origin] = 1; f = substr(origin, 6); gsub(/^"|"$/, "", f); print "O\t" f
          }
          key = kv; sub(/=.*/, "", key); val = substr(kv, length(key) + 2); lk = tolower(key)
          if (lk == "include.path" || lk ~ /^includeif\..*\.path$/) {
            if (origin ~ /^file:/) { f = substr(origin, 6); gsub(/^"|"$/, "", f); print "I\t" f "\t" val }
            next
          }
          if (lk !~ /^(core\.(fsmonitor|sshcommand|editor|pager|askpass|gitproxy|alternaterefscommand)|sequence\.editor|gpg\.program|gpg\..*\.program|diff\.external|diff\..*\.(command|textconv)|(difftool|mergetool|browser|man)\..*\.cmd|merge\..*\.driver|filter\..*\.(clean|smudge|process)|credential\.helper|credential\..*\.helper|pager\..*|alias\..*|interactive\.difffilter|uploadpack\.packobjectshook|web\.browser)$/) next
          if (lk ~ /^alias\./ && val !~ /^!/) next
          if (val ~ /\//) print "K\t" key "\t" val
        }' \
    | while IFS=$'\t' read -r kind a b; do
        if [[ "$kind" == O ]]; then
          rel="$(_agent_vm_rel_in "$(_agent_vm_git_abs "$a" "$base")" "$proj")" \
            && ! _agent_vm_under_readonly_name "$rel" \
            && printf 'config file %s\n' "$rel"
          continue
        fi
        # An include, by its value: git skips a file that does not exist, so
        # --includes does not list it, and the VM can create it once the VM
        # runs. Relative to the file holding it, as git takes it.
        if [[ "$kind" == I ]]; then
          [[ "$b" == "~/"* ]] && b="$HOME/${b#\~/}"
          a="$(_agent_vm_git_abs "$a" "$base")"
          rel="$(_agent_vm_rel_in "$(_agent_vm_git_abs "$b" "${a%/*}")" "$proj")" \
            && ! _agent_vm_under_readonly_name "$rel" \
            && printf 'config file %s\n' "$rel"
          continue
        fi
        # Word by word, through awk: an unquoted expansion would glob them.
        printf '%s\n' "${b#!}" | awk '{ for (i = 1; i <= NF; i++) print $i }' \
          | while IFS= read -r w; do
              w="${w#[\"\']}"; w="${w%[\"\']}"
              # Not an option, an assignment or a URL: a path.
              [[ "$w" == */* && "$w" != -* && "$w" != *=* && "$w" != *://* ]] || continue
              [[ "$w" == "~/"* ]] && w="$HOME/${w#\~/}"
              rel="$(_agent_vm_rel_in "$(_agent_vm_git_abs "$w" "$top")" "$proj")" || continue
              _agent_vm_under_readonly_name "$rel" && continue
              printf '%s = %s\n' "$a" "$b"
              break
            done
      done
}

# The same for every repository of the project <dir>, each line once.
_agent_vm_project_config_risks() {
  local dir="$1" proj repo
  proj="$(_agent_vm_git_spelling "$dir")" || return 0
  _agent_vm_project_repos "$dir" | while IFS= read -r repo; do
    _agent_vm_repo_config_risks "$repo" "$proj"
  done | awk '!seen[$0]++'
}

# What a Lima without readonlyNames exposes when the shares are reverse-sshfs
# (see _agent_vm_unprotected_mount_is_sshfs), one paragraph, before
# _agent_vm_git_protection_hint.
_agent_vm_sshfs_exposure_note() {
  echo "Here the shares then use Lima's reverse-sshfs, which this Lima does not confine: root in the VM may reach files outside the shares (Lima's mount documentation says so), your SSH keys and the rest of your disk included, and write the read-only volumes."
  echo ""
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

# The URL of the fork release holding the Windows builds.
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

# The fork release's files for this machine, one per line: both zips, named
# as upstream's `make artifacts-windows` does,
# lima-<tag without v>-Windows-<ARCH>.zip.
_agent_vm_lima_fork_files() {
  local arch tag
  arch="$(_agent_vm_lima_fork_arch)" || return 1
  tag="${AGENT_VM_LIMA_FORK_TAG#v}"
  printf 'lima-%s-Windows-%s.zip\n' "$tag" "$arch"
  printf 'lima-additional-guestagents-%s-Windows-%s.zip\n' "$tag" "$arch"
}

# Every file named in "$@" inside <dir> must match its entry in <sums>, text
# in SHA256SUMS format. Fails closed (an unlisted file, a checksum that cannot
# be computed, a mismatch) naming the culprit, so a half-downloaded Lima never
# lands on PATH.
_agent_vm_sha256_sums_check() {
  local sums="$1" dir="$2" f expected actual
  shift 2
  for f in "$@"; do
    # A leading * marks binary mode (`sha256sum -b`, and Git Bash's default).
    expected="$(printf '%s\n' "$sums" | awk -v f="$f" '{ n = $2; sub(/^\*/, "", n) } n == f { print $1; exit }')"
    if [[ -z "$expected" ]]; then
      echo "Error: no checksum listed for $f." >&2
      return 1
    fi
    actual="$(_agent_vm_sha256 < "$dir/$f" 2>/dev/null | cut -d' ' -f1)"
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
      if ! _agent_vm_sha256_sums_check "$AGENT_VM_LIMA_FORK_SHA256" "$tmp" "$f"; then
        rm -rf "$tmp"
        return 1
      fi
    done <<< "$files"
    stage="$dir.new.$$"
    rm -rf "$stage"
    mkdir -p "$stage" || { rm -rf "$tmp"; return 1; }
    while IFS= read -r f || [[ -n "$f" ]]; do
      [[ -n "$f" ]] || continue
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
        echo "Error: could not replace the Lima install in $dir: stop the running VMs ('agent-vm list'), then retry." >&2
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
  local st=0
  _agent_vm_lima_protects_git || st=$?
  [[ "$st" == 0 ]] && return 0
  if [[ "$st" == 2 ]]; then
    echo "Warning: cannot tell whether this Lima keeps .git read-only: 'limactl validate' gave no answer agent-vm knows. A start with writable shares stops until it can tell ('agent-vm doctor')." >&2
    return 0
  fi
  _agent_vm_git_protection_hint | _agent_vm_box "Lima cannot keep .git read-only"
  local without="Continuing without .git protection: every start with writable shares will ask first." unlinked=""
  if _agent_vm_on_windows; then
    if ! _agent_vm_have_tty \
       || [[ "$(_agent_vm_ask_yn "Download the Lima build that has it now (both Windows zips, about 60 MB)?" Y)" != "1" ]]; then
      echo "$without" >&2
      return 0
    fi
    if ! _agent_vm_install_fork_windows; then
      echo "Warning: the download failed. $without" >&2
      return 0
    fi
  else
    if ! command -v brew >/dev/null 2>&1 || ! _agent_vm_have_tty \
       || [[ "$(_agent_vm_ask_yn "Install $AGENT_VM_LIMA_FORMULA now (built from source, takes a few minutes)?" Y)" != "1" ]]; then
      echo "$without" >&2
      return 0
    fi
    if brew list --formula lima >/dev/null 2>&1; then
      brew unlink lima && unlinked=1
    fi
    if ! brew install "$AGENT_VM_LIMA_FORMULA"; then
      # Unlinked and nothing in its place would leave no limactl at all.
      [[ -n "$unlinked" ]] && brew link lima
      echo "Warning: the install failed. $without" >&2
      return 0
    fi
  fi
  hash -r 2>/dev/null
  if _agent_vm_lima_protects_git; then
    echo "Lima now keeps every .git read-only for the VMs."
  else
    echo "Warning: the limactl on PATH ($(_agent_vm_limactl_path)) still cannot keep .git read-only." >&2
    echo "  Another Lima install comes first on PATH. $without" >&2
  fi
  return 0
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

# Run when a VM starts with writable shares. Offers to run the command above,
# when it can ask. Not set (no answer, a no, a git that ignores it): the
# security question of _agent_vm_confirm_unsafe, whose default stops the
# start. Fails when the start must stop. With the questions disabled, nothing
# is offered either: the global git config is not changed unasked. With $1
# set, the VM already runs, so a question would protect nothing: a warning
# only.
_agent_vm_check_bare_repo_setting() {
  local state
  state="$(_agent_vm_bare_repo_state)"
  case "$state" in
    ok|nogit) return 0 ;;
  esac
  if [[ -n "${1:-}" ]]; then
    echo "Warning: git on this machine uses repositories a VM creates under another name than .git ('agent-vm doctor' says more)." >&2
    return 0
  fi
  _agent_vm_bare_repo_hint | _agent_vm_box "Git: repositories not named .git"
  if [[ "$state" == old ]]; then
    echo "Warning: $(git --version) is older than 2.38 and ignores that setting." >&2
    _agent_vm_confirm_unsafe && return 0
    echo "Aborted. Upgrade git, then run the command above." >&2
    return 1
  fi
  if ! _agent_vm_prompts_disabled_by >/dev/null && _agent_vm_can_ask \
     && [[ "$(_agent_vm_ask_yn "Run it now? It changes your global git config." Y)" == "1" ]]; then
    if git config --global safe.bareRepository explicit && [[ "$(_agent_vm_bare_repo_state)" == "ok" ]]; then
      echo "Git on this machine now ignores repositories not named .git unless you name them."
      return 0
    fi
    echo "Warning: the setting did not take." >&2
  fi
  echo "Warning: not set. Until it is, git on this machine can run what a VM writes." >&2
  _agent_vm_confirm_unsafe && return 0
  echo "Aborted. Run the command above, then run agent-vm again." >&2
  return 1
}

# --- mounts: the shares a VM gets, and ~/.agent-vm/volumes --------------------

# Stage a single host file at <dst> via hardlink, falling back to copy if the
# source and destination live on different filesystems. Hardlinking keeps the
# content live-synced with the host (same inode) without exposing the source's
# parent directory to the VM. The copy fallback preserves the no-exposure
# property but loses live sync until the next VM (re)start.
_agent_vm_stage_file() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 1
  rm -f "$dst"
  if ln "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  if cp -p "$src" "$dst" 2>/dev/null; then
    echo "Warning: Staged '${src}' via copy (cross-filesystem hardlink failed); live host changes will not propagate until VM (re)start." >&2
    return 0
  fi
  return 1
}

# 0 when the project directory <dir> matches <filter>, the 4th field of a
# ~/.agent-vm/volumes entry: a path, `~` expanded, where `*` matches anything,
# `/` included. A filter that is not absolute matches nothing, with a warning.
# `~user/...` is not expanded: it counts as not absolute.
_agent_vm_volume_matches() {
  local filter="$1" dir="$2"
  case "$filter" in
    "~"|"~/"*) filter="$HOME${filter#\~}" ;;
  esac
  [[ "$filter" == / ]] || filter="${filter%/}"
  if [[ "$filter" != /* ]]; then
    echo "Warning: Project filter '$1' (from ~/.agent-vm/volumes) is not an absolute path, skipping the entry." >&2
    return 1
  fi
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    # zsh takes a pattern from a parameter literally unless asked with ~.
    [[ "$dir" == ${~filter} ]]
  else
    [[ "$dir" == $filter ]]
  fi
}

# A relative destination in ~/.agent-vm/volumes is inside the project. Prints
# its absolute path, after creating it on the host (a directory, or an empty
# file for a file source): virtiofs and 9p create mount points before the
# project is mounted, and --readonly refuses the write from the guest.
# No component may be ".." or a symlink: the agent can write the project, and
# mkdir would follow a link it planted there to anywhere on the host.
_agent_vm_project_mountpoint() {
  local dir="$1" rel="$2" src="$3" p="$1" comp rest="$2/"
  while [[ -n "$rest" ]]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    [[ -z "$comp" || "$comp" == . ]] && continue
    if [[ "$comp" == .. ]]; then
      echo "Warning: Mount destination '${rel}' (from ~/.agent-vm/volumes) goes out of the project with '..', skipping." >&2
      return 1
    fi
    p="$p/$comp"
    if [[ -L "$p" ]]; then
      echo "Warning: Mount destination '${rel}' (from ~/.agent-vm/volumes) goes through a symlink in the project ($p), skipping." >&2
      return 1
    fi
  done
  if [[ "$p" == "$dir" ]]; then
    echo "Warning: Mount destination '${rel}' (from ~/.agent-vm/volumes) is the project itself, skipping." >&2
    return 1
  fi
  if [[ -d "$src" ]]; then
    mkdir -p "$p" 2>/dev/null
  else
    mkdir -p "$(dirname "$p")" 2>/dev/null && { [[ -f "$p" ]] || : > "$p"; } 2>/dev/null
  fi || {
    echo "Warning: Cannot create the mount point '$p' (from ~/.agent-vm/volumes), skipping." >&2
    return 1
  }
  printf '%s\n' "$p"
}

# Build the .mounts JSON array for a VM. The first entry is always the project
# dir; $3 ("true"/"false", default "true") decides whether it is writable.
# Additional entries come from ~/.agent-vm/volumes, parsed as Docker-Compose-ish
# `source[:destination][:mode][:project]` (mode ∈ {ro,rw}, default ro).
#
# $3 = false is --readonly, and it makes EVERY share read-only, `rw` volumes
# included. The hypervisor enforces read-only per share, not per host file: a
# writable volume containing the project (`~/work:/mnt/work:rw`) would let the
# agent write the project through /mnt/work. With no writable share at all,
# there is no such path to find.
#
# `writable: false` is not a guest-side mount option: Lima turns it into a
# read-only flag on the host side of the share, so root inside the VM cannot
# undo it. That holds for the two mount types Lima defaults to since v1.0 —
# virtiofs on vz (readOnly passed to Virtualization.framework) and 9p on QEMU
# (`readonly=on` on -virtfs) — and for reverse-sshfs with the builtin SFTP
# server of a Lima that has readonlyNames, which is what $4 selects. It does
# NOT hold for reverse-sshfs otherwise, which only passes `-o ro` to the
# guest's sshfs; _agent_vm_mount_is_host_enforced checks for that case.
#
# $4 = 1 keeps every .git read-only for the guest (see _agent_vm_lima_protects_git):
# each entry gets the builtin SFTP driver and readonlyNames. The caller also
# has to set the mount type, see _agent_vm_mounts_expr.
#
# Side effects: stages any file mounts as hardlinks under
# ~/.agent-vm/file-mounts/<vm>/ and persists the file mount metadata to
# ~/.agent-vm/.agent-vm-file-mounts-<vm> so subsequent starts can re-apply the
# inside-VM bind mounts without re-parsing the volumes file. Stdout: the
# mounts JSON array (consumed by `limactl edit --set ".mounts = ..."`).
_agent_vm_build_mounts_json() {
  local vm_name="$1" host_dir="$2" project_writable="${3:-true}" sshfs=""
  [[ "${4:-}" == 1 ]] && sshfs=", \"sshfs\": {\"sftpDriver\": \"builtin\", \"readonlyNames\": [\".git\"]}"
  # Every entry names its mount point: agent-vm addresses the guest side by the
  # shell's spelling of the path (--workdir, the write probe), which on Windows
  # is not the C:/... form Lima reads the location in.
  local mounts_json="[{\"location\": \"$(_agent_vm_host_path "$host_dir")\", \"mountPoint\": \"${host_dir}\", \"writable\": ${project_writable}${sshfs}}"
  local mounts_file="$AGENT_VM_STATE_DIR/volumes"
  local file_mount_entries=()
  local file_mounts_cache="$AGENT_VM_STATE_DIR/.agent-vm-file-mounts-${vm_name}"

  if [[ -f "$mounts_file" ]]; then
    local staging_idx=0 raw line
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      line="${raw%%#*}"                                           # strip comments
      line="${line#"${line%%[![:space:]]*}"}"                     # trim leading whitespace
      line="${line%"${line##*[![:space:]]}"}"                     # trim trailing whitespace
      [[ -z "$line" ]] && continue
      # A control character (a tab, an ESC...) is invalid unescaped in the JSON
      # handed to limactl. The CR of a CRLF file went with the trim above.
      if [[ "$line" == *[[:cntrl:]]* ]]; then
        echo "Warning: Mount entry '${raw}' (from ~/.agent-vm/volumes) contains a control character, skipping." >&2
        continue
      fi
      # An optional 4th field, after an explicit mode, limits the entry to the
      # projects it matches: source:destination:mode:filter. An empty one
      # (`src:dst:rw:`) is refused, not read as "no filter": that would mount
      # an entry meant for one project in every project.
      local filter="" has_filter="" before="${line%:*}"
      if [[ "$line" == *:* && ( "$before" == *:ro || "$before" == *:rw ) ]]; then
        filter="${line##*:}"
        has_filter=1
        line="$before"
      fi
      if [[ -n "$has_filter" ]]; then
        if [[ -z "$filter" ]]; then
          echo "Warning: Mount entry '${raw}' (from ~/.agent-vm/volumes) has an empty project filter; refusing to mount it in every project. Skipping." >&2
          continue
        fi
        _agent_vm_volume_matches "$filter" "$host_dir" || continue
      fi
      # Parse source[:destination][:mode] syntax (like docker compose volumes).
      # The trailing mode segment is only recognized when it equals "ro" or
      # "rw" — anything else is treated as a destination path.
      local src="$line" dst="" mode="ro"
      if [[ "$line" == *:ro || "$line" == *:rw ]]; then
        mode="${line##*:}"
        line="${line%:*}"
      fi
      if [[ "$line" == *:* ]]; then
        src="${line%%:*}"
        dst="${line#*:}"
      else
        src="$line"
      fi
      # A ':' left in the destination is a field out of place: a project
      # without a mode before it (`src:dst:/p`), a mode after it
      # (`src:dst:/p:rw`), a second mode, a fifth field. Read as a destination,
      # the entry would be mounted in every project, the project filter lost.
      if [[ "$dst" == *:* ]]; then
        echo "Warning: Mount entry '${raw}' (from ~/.agent-vm/volumes) does not read as source:destination:mode:project (the mode goes before the project, and is needed with one). Skipping." >&2
        continue
      fi
      src="${src/#\~/$HOME}"                                      # expand ~
      # Reject characters that would break JSON interpolation below or the
      # pipe-separated cache format used for file mounts.
      if [[ "$src" == *[$'"\\\n|']* || "$dst" == *[$'"\\\n|']* ]]; then
        echo "Warning: Mount entry '${raw}' (from ~/.agent-vm/volumes) contains invalid characters (quote/backslash/newline/pipe), skipping." >&2
        continue
      fi
      if [[ ! -e "$src" ]]; then
        echo "Warning: Mount path '${src}' (from ~/.agent-vm/volumes) does not exist, skipping." >&2
        continue
      fi
      if [[ -n "$dst" && "$dst" != /* ]]; then
        dst="$(_agent_vm_project_mountpoint "$host_dir" "$dst" "$src")" || continue
      fi
      if [[ -f "$src" ]]; then
        if [[ "$mode" == "rw" ]]; then
          echo "Warning: Mount entry '${line}' (from ~/.agent-vm/volumes) requests rw on a file; only directories support rw. Mount the parent directory instead. Skipping." >&2
          continue
        fi
        # File mount: hardlink the source into a per-VM host staging dir so
        # the VM sees only this file (never the source's parent). Lima mounts
        # the staging dir; a bind mount inside the VM (applied after boot)
        # exposes the file at its final destination.
        local filename
        filename="$(basename "$src")"
        local file_staging_dir="$AGENT_VM_STATE_DIR/file-mounts/${vm_name}/${staging_idx}"
        local host_staging="${file_staging_dir}/${filename}"
        if ! _agent_vm_stage_file "$src" "$host_staging"; then
          echo "Warning: Failed to stage '${src}', skipping." >&2
          rm -rf "$file_staging_dir"
          continue
        fi
        local staging_mount="/tmp/.agent-vm-file-mounts/${staging_idx}"
        local bind_dst="${dst:-${src}}"
        file_mount_entries+=("${src}|${host_staging}|${staging_mount}/${filename}|${bind_dst}")
        mounts_json+=", {\"location\": \"$(_agent_vm_host_path "$file_staging_dir")\", \"mountPoint\": \"${staging_mount}\", \"writable\": false${sshfs}}"
        staging_idx=$((staging_idx + 1))
        continue
      fi
      if [[ ! -d "$src" ]]; then
        echo "Warning: Mount path '${src}' (from ~/.agent-vm/volumes) is not a regular file or directory, skipping." >&2
        continue
      fi
      local writable="false"
      if [[ "$mode" == "rw" ]]; then
        if [[ "$project_writable" == "true" ]]; then
          writable="true"
        else
          echo "Note: --readonly: '${src}' (rw in ~/.agent-vm/volumes) is mounted read-only too." >&2
        fi
      fi
      mounts_json+=", {\"location\": \"$(_agent_vm_host_path "$src")\", \"mountPoint\": \"${dst:-$src}\", \"writable\": ${writable}${sshfs}}"
    done < "$mounts_file"
  fi
  mounts_json+="]"

  rm -f "$file_mounts_cache"
  if [[ ${#file_mount_entries[@]} -gt 0 ]]; then
    printf '%s\n' "${file_mount_entries[@]}" > "$file_mounts_cache"
  fi

  printf '%s' "$mounts_json"
}

# The mounts JSON last applied to <vm>, kept so --readonly can tell whether
# any share is still writable: the guest cannot be asked, since after a mode
# change it still believes the old one (see _agent_vm_project_writable).
_agent_vm_record_mounts() {
  mkdir -p "$AGENT_VM_STATE_DIR" 2>/dev/null
  printf '%s\n' "$2" > "$AGENT_VM_STATE_DIR/.agent-vm-mounts-$1"
}

# 0 when <vm> is recorded with no writable share at all. A missing record
# counts as "not known to be read-only".
_agent_vm_mounts_all_readonly() {
  local record="$AGENT_VM_STATE_DIR/.agent-vm-mounts-$1" mounts
  [[ -f "$record" ]] || return 1
  mounts="$(cat "$record")"
  [[ "$mounts" != *'"writable": true'* ]]
}

# 0 when <vm> is recorded with every .git read-only (see
# _agent_vm_build_mounts_json). A missing record counts as "not protected".
_agent_vm_mounts_protect_git() {
  local record="$AGENT_VM_STATE_DIR/.agent-vm-mounts-$1"
  [[ -f "$record" ]] && grep -q '"readonlyNames"' "$record"
}

# Can the guest actually write into the project share?
#
# `test -w` cannot answer this. Lima writes the guest's /etc/fstab from
# cloud-init, whose `mounts` module runs on the FIRST boot only, while the
# host-side share config (virtiofs readOnly, 9p readonly=on) is rebuilt on
# every start. So after a mode change on an existing VM the guest still
# believes the old mode — `test -w` consults that stale belief and says
# "writable" while the VMM is already refusing the writes.
#
# Only attempting a write goes through the whole path, which is also exactly
# the property --readonly claims. Returns 0 when the write succeeded.
_agent_vm_project_writable() {
  local vm_name="$1" host_dir="$2"
  limactl shell "$vm_name" sh -c \
    'p="$1/.agent-vm-write-probe.$$"; touch "$p" 2>/dev/null || exit 1; rm -f "$p"' \
    sh "$host_dir" &>/dev/null
}

# _agent_vm_push_env_and_probe <vm> <dir> <payload> — the same probe, in the
# same `limactl shell` as the env push every start makes: each one is a round
# trip. Prints env-ok once the env file is written; returns the probe's answer.
#
# The payload (~/.agent-vm/env, then the project's env, see
# _agent_vm_env_payload) becomes $HOME/.agent-vm.env, which the base VM's
# ~/.zshenv sources with `set -a`: plain KEY=value lines, the project's last so
# it wins. On every start, so edits on the host need no --reset, and when
# empty too, so env removed on the host goes from the VM. `umask 077`: it
# usually holds secrets.
_agent_vm_push_env_and_probe() {
  local vm_name="$1" host_dir="$2" payload="$3"
  { [ -z "$payload" ] || printf '%s\n' "$payload"; } \
    | limactl shell "$vm_name" sh -c '
        (umask 077 && rm -f "$HOME/.agent-vm.env" && cat > "$HOME/.agent-vm.env") && echo env-ok
        p="$1/.agent-vm-write-probe.$$"; touch "$p" 2>/dev/null || exit 1; rm -f "$p"' \
      sh "$host_dir" 2>/dev/null
}

# Is the project share one whose read-only flag is enforced outside the guest?
# Answers from the mount that is actually there, not from the configured
# mountType: what matters is what got mounted, and a stale VM can disagree with
# the config. 9p is enforced by QEMU (`readonly=on` on -virtfs). virtiofs is
# enforced on vz only, by Virtualization.framework: under QEMU, virtiofsd has
# no read-only mode and Lima passes none (virtio-fs/virtiofsd#97), so the flag
# only reaches the guest's fstab. fuse.sshfs (Lima's reverse-sshfs) is
# enforced only when served by the builtin SFTP server of a Lima with
# readonlyNames, which the guest cannot tell apart from the OpenSSH one: that
# part is answered from the mounts agent-vm last applied. Otherwise it only
# gets `-o ro` inside the guest, where root can remount it rw.
# Returns 0 (enforced), 1 (not enforced), or 2 (could not tell).
_agent_vm_mount_is_host_enforced() {
  local vm_name="$1" host_dir="$2" fstype vmtype
  fstype=$(limactl shell "$vm_name" findmnt -no FSTYPE "$host_dir" 2>/dev/null) || return 2
  [[ -z "$fstype" ]] && return 2
  case "$fstype" in
    9p) return 0 ;;
    virtiofs)
      vmtype=$(limactl list --format '{{.VMType}}' "$vm_name" 2>/dev/null) || return 2
      case "$vmtype" in
        vz)   return 0 ;;
        qemu) return 1 ;;
        *)    return 2 ;;
      esac ;;
    fuse.sshfs)
      _agent_vm_mounts_protect_git "$vm_name" && return 0
      return 1 ;;
    *)           return 1 ;;
  esac
}

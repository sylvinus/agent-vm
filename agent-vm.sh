#!/usr/bin/env bash
#
# agent-vm: Run AI coding agents inside sandboxed Lima VMs
# Part of https://github.com/sylvinus/agent-vm
#
# Source this file in your shell config:
#   source /path/to/agent-vm/agent-vm.sh
#
# Usage:
#   agent-vm setup    - Create the base VM template (run once)
#   agent-vm claude   - Run Claude Code in a persistent VM for cwd
#   agent-vm opencode - Run OpenCode in a persistent VM for cwd
#   agent-vm codex    - Run Codex CLI in a persistent VM for cwd
#   agent-vm vibe     - Run Mistral Vibe in a persistent VM for cwd
#   agent-vm shell    - Open a shell in the persistent VM for cwd
#                       (alias: 'sh'; add -c "..." for a one-shot command)
#   agent-vm stop     - Stop the VM for cwd
#   agent-vm rm       - Stop and delete the VM for cwd
#   agent-vm list     - List all agent-vm VMs
#   agent-vm status   - Show status of all VMs (current dir marked with >)
#   agent-vm help     - Show help
#

AGENT_VM_TEMPLATE="agent-vm-base"
AGENT_VM_STATE_DIR="${HOME}/.agent-vm"
AGENT_VM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Prompt for a value with a default. Reads from /dev/tty so this still works
# when called inside command substitution. Writes the prompt to stderr and the
# answer (or the default if the user just pressed Enter) to stdout.
_agent_vm_ask() {
  local prompt="$1" default="$2" reply=""
  printf '  %s [%s]: ' "$prompt" "$default" >&2
  IFS= read -r reply </dev/tty 2>/dev/null || reply=""
  printf '%s\n' "${reply:-$default}"
}

# Yes/no prompt. Second arg is the default: Y or N (case-insensitive). Prints
# 1 (yes) or 0 (no) to stdout. Empty input picks the default.
_agent_vm_ask_yn() {
  local prompt="$1" default="${2:-Y}" reply="" indicator
  case "$default" in
    [Yy]*) indicator="[Y/n]"; default=Y ;;
    *)     indicator="[y/N]"; default=N ;;
  esac
  printf '  %s %s: ' "$prompt" "$indicator" >&2
  IFS= read -r reply </dev/tty 2>/dev/null || reply=""
  reply="${reply:-$default}"
  case "$reply" in
    [Yy]*) printf '1\n' ;;
    *)     printf '0\n' ;;
  esac
}

# Prompt for a positive integer with default. Re-prompts on invalid input.
# Used for disk/memory/cpus where a typo (e.g. "10G") would otherwise produce
# a cryptic limactl error several seconds later.
_agent_vm_ask_int() {
  local prompt="$1" default="$2" reply
  while true; do
    reply=$(_agent_vm_ask "$prompt" "$default")
    if [[ "$reply" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s\n' "$reply"
      return 0
    fi
    printf '  (must be a positive integer, e.g. 10 — got: %s)\n' "$reply" >&2
  done
}

# Validate a positive-integer arg from the CLI (no retry — fail fast).
_agent_vm_validate_int() {
  local name="$1" val="$2"
  if [[ ! "$val" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: $name must be a positive integer (got: '$val')" >&2
    return 1
  fi
}

# Check Linux prerequisites Lima needs to spin up a QEMU+KVM VM. macOS uses
# different backends (vz/qemu-via-brew) so this is a no-op there. Returns
# non-zero with actionable install/permission hints when something's missing —
# without this, the user gets a generic `Error: Failed to create base VM` and
# has to dig into `~/.lima/<vm>/ha.stderr.log` to figure out why.
_agent_vm_check_linux_prereqs() {
  [[ "$(uname -s)" == "Linux" ]] || return 0

  local arch_bin arch_pkg
  case "$(uname -m)" in
    x86_64)        arch_bin="qemu-system-x86_64"; arch_pkg="qemu-system-x86" ;;
    aarch64|arm64) arch_bin="qemu-system-aarch64"; arch_pkg="qemu-system-arm" ;;
    *)             arch_bin="qemu-system-$(uname -m)"; arch_pkg="qemu-system" ;;
  esac

  local errs=0

  if ! command -v "$arch_bin" &>/dev/null; then
    echo "Error: Lima needs '$arch_bin' on PATH (not found)." >&2
    echo "  Install with: sudo apt-get install $arch_pkg" >&2
    errs=1
  fi

  if [[ ! -e /dev/kvm ]]; then
    echo "Error: /dev/kvm does not exist (KVM unavailable)." >&2
    echo "  Hardware virtualization may be disabled in BIOS, or the kernel" >&2
    echo "  lacks KVM support (nested virt in a guest VM, etc.)." >&2
    errs=1
  elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "Error: /dev/kvm exists but you don't have read/write access." >&2
    if ! id -nG 2>/dev/null | grep -qw kvm; then
      echo "  Fix: sudo usermod -aG kvm \"\$USER\"" >&2
      echo "  Then log out and back in (or run 'newgrp kvm') so the new" >&2
      echo "  group membership takes effect." >&2
    else
      echo "  You're already in the kvm group but /dev/kvm denies access." >&2
      echo "  Check ownership/mode: ls -l /dev/kvm" >&2
    fi
    errs=1
  fi

  [[ $errs -eq 0 ]]
}

# Lima leaves a partial state dir behind if `limactl create` is interrupted
# (Ctrl-C before lima.yaml is written). After that every subsequent limactl
# call on that name dies with `open ~/.lima/<vm>/lima.yaml: no such file or
# directory` — pre-emptively clean the dir so the next setup/start works.
_agent_vm_clean_partial_state() {
  local vm_name="$1"
  local lima_dir="$HOME/.lima/$vm_name"
  if [[ -d "$lima_dir" ]] && [[ ! -f "$lima_dir/lima.yaml" ]]; then
    echo "Detected partial VM state at $lima_dir (no lima.yaml) — cleaning up." >&2
    rm -rf "$lima_dir"
  fi
}

# Generate a deterministic VM name for a directory
_agent_vm_name() {
  local dir="${1:-$(pwd)}"
  local hash
  hash=$(echo -n "$dir" | shasum -a 256 | cut -c1-8)
  local base
  base=$(basename "$dir" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')
  echo "agent-vm-${base}-${hash}"
}

# Check if a VM exists (any state)
_agent_vm_exists() {
  limactl list -q 2>/dev/null | grep -q "^${1}$"
}

# Check if a VM is running
_agent_vm_running() {
  limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -q "^${1} Running$"
}

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

# Remove all per-VM state files (version marker, terminfo cache, file mount
# cache, staging dirs). Called after a VM is deleted or before it is re-cloned
# via --reset.
_agent_vm_cleanup_state() {
  local vm_name="$1"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-term-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-file-mounts-${vm_name}"
  rm -rf "$AGENT_VM_STATE_DIR/file-mounts/${vm_name}"
}

# Build the .mounts JSON array for a VM. The first entry is always the project
# dir (writable). Additional entries come from ~/.agent-vm/volumes, parsed as
# Docker-Compose-ish `source[:destination][:mode]` (mode ∈ {ro,rw}, default ro).
#
# Side effects: stages any file mounts as hardlinks under
# ~/.agent-vm/file-mounts/<vm>/ and persists the file mount metadata to
# ~/.agent-vm/.agent-vm-file-mounts-<vm> so subsequent starts can re-apply the
# inside-VM bind mounts without re-parsing the volumes file. Stdout: the
# mounts JSON array (consumed by `limactl edit --set ".mounts = ..."`).
_agent_vm_build_mounts_json() {
  local vm_name="$1" host_dir="$2"
  local mounts_json="[{\"location\": \"${host_dir}\", \"writable\": true}"
  local mounts_file="$AGENT_VM_STATE_DIR/volumes"
  local file_mount_entries=()
  local file_mounts_cache="$AGENT_VM_STATE_DIR/.agent-vm-file-mounts-${vm_name}"

  if [[ -f "$mounts_file" ]]; then
    local staging_idx=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"                                          # strip comments
      line="${line#"${line%%[![:space:]]*}"}"                     # trim leading whitespace
      line="${line%"${line##*[![:space:]]}"}"                     # trim trailing whitespace
      [[ -z "$line" ]] && continue
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
      src="${src/#\~/$HOME}"                                      # expand ~
      # Reject characters that would break JSON interpolation below or the
      # pipe-separated cache format used for file mounts.
      if [[ "$src" == *[$'"\\\n|']* || "$dst" == *[$'"\\\n|']* ]]; then
        echo "Warning: Mount entry '${line}' (from ~/.agent-vm/volumes) contains invalid characters (quote/backslash/newline/pipe), skipping." >&2
        continue
      fi
      if [[ ! -e "$src" ]]; then
        echo "Warning: Mount path '${src}' (from ~/.agent-vm/volumes) does not exist, skipping." >&2
        continue
      fi
      if [[ -f "$src" ]]; then
        if [[ "$mode" == "rw" ]]; then
          echo "Warning: Mount entry '${line}' (from ~/.agent-vm/volumes) requests rw on a file; only directories support rw. Mount the parent directory instead. Skipping." >&2
          continue
        fi
        # File mount: hardlink the source into a per-VM host staging dir so
        # the VM sees only this file (never the source's parent). Lima mounts
        # the staging dir via virtiofs; a bind mount inside the VM (applied
        # after boot) exposes the file at its final destination.
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
        mounts_json+=", {\"location\": \"${file_staging_dir}\", \"mountPoint\": \"${staging_mount}\", \"writable\": false}"
        staging_idx=$((staging_idx + 1))
        continue
      fi
      if [[ ! -d "$src" ]]; then
        echo "Warning: Mount path '${src}' (from ~/.agent-vm/volumes) is not a regular file or directory, skipping." >&2
        continue
      fi
      local writable="false"
      [[ "$mode" == "rw" ]] && writable="true"
      if [[ -n "$dst" ]]; then
        mounts_json+=", {\"location\": \"${src}\", \"mountPoint\": \"${dst}\", \"writable\": ${writable}}"
      else
        mounts_json+=", {\"location\": \"${src}\", \"writable\": ${writable}}"
      fi
    done < "$mounts_file"
  fi
  mounts_json+="]"

  rm -f "$file_mounts_cache"
  if [[ ${#file_mount_entries[@]} -gt 0 ]]; then
    printf '%s\n' "${file_mount_entries[@]}" > "$file_mounts_cache"
  fi

  printf '%s' "$mounts_json"
}

# Print VM resource details (CPUs, memory, disk)
_agent_vm_print_resources() {
  local vm_name="$1"
  local info
  info=$(limactl list --format '{{.Name}}|{{.CPUs}}|{{.Memory}}|{{.Disk}}' 2>/dev/null | grep "^${vm_name}|" | head -1)
  if [[ -n "$info" ]]; then
    local cpus mem_bytes disk_bytes
    IFS='|' read -r _ cpus mem_bytes disk_bytes <<< "$info"
    local mem_gib=$((mem_bytes / 1073741824))
    local disk_gib=$((disk_bytes / 1073741824))
    echo "  Resources: CPUs: ${cpus}, Memory: ${mem_gib} GiB, Disk: ${disk_gib} GiB"
  fi
}

# Ensure the VM for cwd exists and is running, creating/starting as needed
# Usage: _agent_vm_ensure_running <vm_name> <host_dir> [--disk GB] [--memory GB] [--reset]
_agent_vm_ensure_running() {
  local vm_name="$1"
  local host_dir="$2"
  shift 2
  local disk="" memory="" cpus="" reset="" offline="" rdonly="" git_ro=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     disk="$2"; shift 2 ;;
      --memory|--ram)   memory="$2"; shift 2 ;;
      --cpus)     cpus="$2"; shift 2 ;;
      --reset)    reset=1; shift ;;
      --offline)  offline=1; shift ;;
      --readonly) rdonly=1; shift ;;
      --git-read-only|--git-ro) git_ro=1; shift ;;
      *)          shift ;;
    esac
  done

  # Lima's host mount cannot share a path containing whitespace: the mount
  # fails silently and the VM starts with a bare, root-owned mountpoint, so
  # every write into the project (e.g. creating .claude) fails with
  # "Permission denied". Fail fast with an actionable message instead.
  if [[ "$host_dir" == *[[:space:]]* ]]; then
    echo "Error: project path contains whitespace, which Lima cannot mount:" >&2
    echo "  $host_dir" >&2
    echo "Rename the directory to remove spaces (e.g. with '-'), then retry." >&2
    return 1
  fi

  # Recover from an interrupted previous run that left ~/.lima/<vm>/ without
  # a lima.yaml — otherwise every limactl call on this name aborts with a
  # cryptic "no such file or directory".
  _agent_vm_clean_partial_state "$vm_name"

  if ! limactl list -q 2>/dev/null | grep -q "^${AGENT_VM_TEMPLATE}$"; then
    echo "Error: Base VM not found. Run 'agent-vm setup' first." >&2
    return 1
  fi

  # Destroy existing VM if --reset was requested
  if [[ -n "$reset" ]] && _agent_vm_exists "$vm_name"; then
    echo "Resetting VM '$vm_name'..."
    limactl stop "$vm_name" &>/dev/null
    limactl delete "$vm_name" --force &>/dev/null
    _agent_vm_cleanup_state "$vm_name"
  fi

  local is_new_vm=""
  local file_mount_entries=()
  local file_mounts_cache="$AGENT_VM_STATE_DIR/.agent-vm-file-mounts-${vm_name}"

  if ! _agent_vm_exists "$vm_name"; then
    is_new_vm=1
    echo "Creating VM '$vm_name'..."
    limactl clone "$AGENT_VM_TEMPLATE" "$vm_name" --tty=false &>/dev/null
    # Apply mount and resource settings via edit after clone
    # Mount and memory/cpus are applied separately from disk, because
    # Lima rejects the entire edit if disk shrinking is attempted.
    local mounts_json
    mounts_json=$(_agent_vm_build_mounts_json "$vm_name" "$host_dir")
    local edit_args=()
    edit_args+=(--set ".mounts = ${mounts_json}")
    [[ -n "$memory" ]] && edit_args+=(--memory "$memory")
    [[ -n "$cpus" ]]   && edit_args+=(--cpus "$cpus")
    (cd /tmp && limactl edit "$vm_name" "${edit_args[@]}") &>/dev/null
    if [[ -n "$disk" ]]; then
      if ! (cd /tmp && limactl edit "$vm_name" --disk "$disk") &>/dev/null; then
        echo "Warning: Cannot set disk to ${disk} GiB (shrinking is not supported). Re-run 'agent-vm setup --disk ${disk}' for a smaller base." >&2
      fi
    fi
    _agent_vm_print_resources "$vm_name"
    # Record which base version this VM was cloned from
    local base_ver="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
    if [[ -f "$base_ver" ]]; then
      cp "$base_ver" "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
    fi
  elif [[ -n "$disk" || -n "$memory" || -n "$cpus" ]]; then
    # Auto-resize existing VM if --disk, --memory, or --cpus changed
    if _agent_vm_running "$vm_name"; then
      echo "VM '$vm_name' is currently running. It must be stopped to apply new resource settings."
      printf "Stop the VM and apply changes? [y/N] " >&2
      local reply=""
      IFS= read -r reply </dev/tty 2>/dev/null || reply=""
      if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborted. Starting with current settings."
        return 0
      fi
      echo "Stopping VM..."
      limactl stop "$vm_name" &>/dev/null
    fi
    echo "Updating VM resources..."
    # Don't touch .mounts here — those are baked in at creation (including any
    # entries from ~/.agent-vm/volumes). Re-setting them would clobber extras.
    local edit_args=()
    [[ -n "$memory" ]] && edit_args+=(--memory "$memory")
    [[ -n "$cpus" ]]   && edit_args+=(--cpus "$cpus")
    local edit_output
    if ! edit_output=$(cd /tmp && limactl edit "$vm_name" "${edit_args[@]}" 2>&1); then
      echo "Error: Failed to update VM resources:" >&2
      echo "$edit_output" >&2
      return 1
    fi
    if [[ -n "$disk" ]]; then
      if ! edit_output=$(cd /tmp && limactl edit "$vm_name" --disk "$disk" 2>&1); then
        echo "Warning: Cannot set disk to ${disk} GiB (shrinking is not supported). Re-run 'agent-vm setup --disk ${disk}' for a smaller base." >&2
      fi
    fi
    _agent_vm_print_resources "$vm_name"
  fi

  # Warn if this VM was cloned from an older base
  local base_ver="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
  local vm_ver="$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
  if [[ -f "$base_ver" ]] && { [[ ! -f "$vm_ver" ]] || [[ "$(cat "$base_ver")" != "$(cat "$vm_ver")" ]]; }; then
    echo "Warning: Base VM has been updated since this VM was cloned. Use --reset to re-clone from the new base." >&2
  fi

  if ! _agent_vm_running "$vm_name"; then
    echo "Starting VM '$vm_name'..."
    local start_log
    if ! start_log=$(limactl start "$vm_name" 2>&1); then
      echo "Error: Failed to start VM '$vm_name'." >&2
      echo "--- limactl start output ---" >&2
      echo "$start_log" >&2
      echo "Full log: ~/.lima/$vm_name/ha.stderr.log" >&2
      return 1
    fi
  fi

  # Sanity-check that the project directory is actually shared and writable.
  # A silently-failed or stale mount leaves a bare, root-owned mountpoint;
  # without this check every later write (runtime scripts, the agent itself)
  # fails with a confusing cascade of "Permission denied" instead of one clear
  # error. Runs before the optional --readonly remount below, so it reflects
  # the mount itself, not the requested read-only restriction.
  #
  # If the mount is broken, try to self-heal once: re-apply the mount config
  # (Lima only allows editing a stopped VM) and restart. This repairs a stale
  # or silently-missing mount without forcing a full --reset, and adds no
  # overhead on the common path where the mount is already healthy.
  if ! limactl shell "$vm_name" test -w "$host_dir" &>/dev/null; then
    echo "Project mount is not writable; repairing..." >&2
    limactl stop "$vm_name" &>/dev/null
    # Rebuild the full mounts JSON so any ~/.agent-vm/volumes entries are
    # preserved across the repair (a plain project-dir-only set would silently
    # drop them).
    local repair_mounts_json
    repair_mounts_json=$(_agent_vm_build_mounts_json "$vm_name" "$host_dir")
    (cd /tmp && limactl edit "$vm_name" \
      --set ".mounts = ${repair_mounts_json}") &>/dev/null
    limactl start "$vm_name" &>/dev/null
    if ! limactl shell "$vm_name" test -w "$host_dir" &>/dev/null; then
      echo "Error: project directory is still not writable inside the VM:" >&2
      echo "  $host_dir" >&2
      echo "The host mount failed to attach. Try 'agent-vm --reset <command>'" >&2
      echo "to re-clone the VM from the base template." >&2
      return 1
    fi
  fi

  # Install the host's terminfo entry inside the VM so non-standard terminals
  # (xterm-ghostty, xterm-kitty, …) work correctly. Without this, zsh/ZLE
  # can't decode keys → broken backspace, arrows, etc. Cached per-VM so we only
  # pay the limactl shell roundtrip when $TERM actually changes.
  local term_cache="$AGENT_VM_STATE_DIR/.agent-vm-term-${vm_name}"
  if [[ -n "${TERM:-}" ]] && [[ "$(cat "$term_cache" 2>/dev/null)" != "$TERM" ]] \
     && infocmp -x "$TERM" &>/dev/null; then
    if infocmp -x "$TERM" | limactl shell "$vm_name" sudo tic -x - &>/dev/null; then
      echo "$TERM" > "$term_cache"
    else
      echo "Warning: failed to install '$TERM' terminfo inside VM." >&2
    fi
  fi

  # Push ~/.agent-vm/env (a dotenv-style file of tokens / API keys) into the VM
  # at $HOME/.agent-vm.env on every start, so updates on the host propagate
  # without --reset. The base VM's ~/.zshenv auto-sources it via `set -a`, so
  # the contents stay a plain KEY=value file (no `export` needed). `umask 077`
  # creates the file mode-600 since it usually holds secrets.
  if [ -f "$AGENT_VM_STATE_DIR/env" ]; then
    if ! limactl shell "$vm_name" sh -c 'umask 077 && rm -f "$HOME/.agent-vm.env" && cat > "$HOME/.agent-vm.env"' \
         < "$AGENT_VM_STATE_DIR/env" 2>/dev/null; then
      echo "Warning: failed to push ~/.agent-vm/env into VM '$vm_name'." >&2
    fi
  fi

  # Run per-user runtime script if it exists
  if [ -f "$AGENT_VM_STATE_DIR/runtime.sh" ]; then
    echo "Running user runtime setup..."
    limactl shell --workdir "$host_dir" "$vm_name" zsh -l < "$AGENT_VM_STATE_DIR/runtime.sh"
  fi

  # Run project-specific runtime script if it exists
  if [ -f "${host_dir}/.agent-vm.runtime.sh" ]; then
    echo "Running project runtime setup..."
    limactl shell --workdir "$host_dir" "$vm_name" zsh -l < "${host_dir}/.agent-vm.runtime.sh"
  fi

  # Apply per-session restrictions
  if [[ -n "$offline" ]]; then
    echo "Enabling offline mode..."
    limactl shell "$vm_name" sudo iptables -F OUTPUT 2>/dev/null
    limactl shell "$vm_name" sudo iptables -A OUTPUT -o lo -j ACCEPT
    limactl shell "$vm_name" sudo iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
    limactl shell "$vm_name" sudo iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
    limactl shell "$vm_name" sudo iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
    limactl shell "$vm_name" sudo iptables -P OUTPUT DROP
  fi

  if [[ -n "$rdonly" ]]; then
    # `mount -o remount,ro` on the host share fails silently when Lima uses
    # a FUSE-backed mount (sshfs/virtiofs in some configurations) — FUSE
    # rejects the `remount` option and the FS stays writable. Self-bind the
    # directory first so we have a plain Linux bind-mount layer to remount,
    # which works regardless of what's underneath.
    echo "Mounting project directory as read-only..."
    if ! limactl shell "$vm_name" sudo mount --bind "$host_dir" "$host_dir" \
       || ! limactl shell "$vm_name" sudo mount -o remount,ro,bind "$host_dir"; then
      echo "Error: Failed to mount project directory as read-only." >&2
      return 1
    fi
  fi

  if [[ -n "$git_ro" ]] && [[ -d "$host_dir/.git" ]]; then
    echo "Mounting .git directory as read-only..."
    if ! limactl shell "$vm_name" sudo mount --bind "$host_dir/.git" "$host_dir/.git" \
       || ! limactl shell "$vm_name" sudo mount -o remount,ro,bind "$host_dir/.git"; then
      echo "Error: Failed to mount .git directory as read-only." >&2
      return 1
    fi
  fi

  # Load file mount entries from the cache. _agent_vm_build_mounts_json writes
  # them there (from its own local scope) for both new and existing VMs, so we
  # always read them back here to drive the inside-VM bind mounts below.
  if [[ -f "$file_mounts_cache" ]]; then
    local entry
    while IFS= read -r entry; do
      [[ -n "$entry" ]] && file_mount_entries+=("$entry")
    done < "$file_mounts_cache"

    # For existing VMs, refresh host-side hardlinks so atomic-rename edits on the
    # host propagate after a VM restart (ln/cp against the cached staging path).
    # New VMs just staged fresh copies in _agent_vm_build_mounts_json, so there
    # is nothing to refresh.
    if [[ -z "$is_new_vm" ]]; then
      local host_src host_staging _bind_src _bind_dst
      for entry in "${file_mount_entries[@]}"; do
        IFS='|' read -r host_src host_staging _bind_src _bind_dst <<< "$entry"
        [[ -z "$host_staging" ]] && continue
        if [[ ! -e "$host_src" ]]; then
          echo "Warning: Mount source '${host_src}' no longer exists; VM will see the last-staged copy." >&2
          continue
        fi
        _agent_vm_stage_file "$host_src" "$host_staging" \
          || echo "Warning: Failed to refresh staged '${host_src}'; VM may see stale content." >&2
      done
    fi
  fi

  # Apply inside-VM bind mounts so each staged file appears at its final path.
  # Lima re-mounts staging dirs on each start, but the bind onto the final dest
  # is ephemeral. Batched into one limactl shell call (roundtrips cost ~1-2s)
  # and made idempotent so re-runs on a running VM are cheap no-ops.
  if [[ ${#file_mount_entries[@]} -gt 0 ]]; then
    local file_bind_payload=()
    local _host_src _host_staging bind_src bind_dst
    for entry in "${file_mount_entries[@]}"; do
      IFS='|' read -r _host_src _host_staging bind_src bind_dst <<< "$entry"
      [[ -n "$bind_src" && -n "$bind_dst" ]] && file_bind_payload+=("${bind_src}|${bind_dst}")
    done
    if [[ ${#file_bind_payload[@]} -gt 0 ]]; then
      echo "Mounting individual files..."
      # Paths are passed as positional args (single-quoted script) so entries
      # containing quotes or metacharacters cannot be interpreted as shell code.
      limactl shell "$vm_name" sudo bash -c '
        set -e
        for entry in "$@"; do
          bind_src="${entry%%|*}"
          bind_dst="${entry#*|}"
          if ! findmnt -no TARGET "$bind_dst" >/dev/null 2>&1; then
            mkdir -p "$(dirname "$bind_dst")" && touch "$bind_dst"
            mount --bind "$bind_src" "$bind_dst"
            mount -o remount,ro,bind "$bind_dst"
          fi
        done
      ' -- "${file_bind_payload[@]}"
    fi
  fi
}

agent-vm() {
  local vm_opts=()
  # Parse global options before the subcommand
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)
        vm_opts+=(--disk "$2"); shift 2 ;;
      --disk=*)
        vm_opts+=(--disk "${1#*=}"); shift ;;
      --memory|--ram)
        vm_opts+=(--memory "$2"); shift 2 ;;
      --memory=*|--ram=*)
        vm_opts+=(--memory "${1#*=}"); shift ;;
      --cpus)
        vm_opts+=(--cpus "$2"); shift 2 ;;
      --cpus=*)
        vm_opts+=(--cpus "${1#*=}"); shift ;;
      --reset)
        vm_opts+=(--reset); shift ;;
      --offline)
        vm_opts+=(--offline); shift ;;
      --readonly)
        vm_opts+=(--readonly); shift ;;
      --git-read-only|--git-ro)
        vm_opts+=(--git-read-only); shift ;;
      --rm)
        vm_opts+=(--rm); shift ;;
      *)
        break ;;
    esac
  done

  local cmd="${1:-help}"
  shift 2>/dev/null || true

  # Every command except help/setup needs limactl present. (setup installs it
  # itself; help needs nothing.) Without this, stop/list/status/etc. would fail
  # with confusing empty output instead of a clear, actionable message.
  case "$cmd" in
    help|--help|-h|setup) ;;
    *)
      if ! command -v limactl &>/dev/null; then
        echo "Error: limactl (Lima) not found. Run 'agent-vm setup' first, or install" >&2
        echo "it from https://lima-vm.io/docs/installation/" >&2
        return 1
      fi ;;
  esac

  case "$cmd" in
    setup)
      _agent_vm_setup "${vm_opts[@]}" "$@"
      ;;
    claude)
      _agent_vm_claude "${vm_opts[@]}" "$@"
      ;;
    opencode)
      _agent_vm_opencode "${vm_opts[@]}" "$@"
      ;;
    codex)
      _agent_vm_codex "${vm_opts[@]}" "$@"
      ;;
    vibe)
      _agent_vm_vibe "${vm_opts[@]}" "$@"
      ;;
    shell|sh)
      _agent_vm_shell "${vm_opts[@]}" "$@"
      ;;
    run)
      _agent_vm_run "${vm_opts[@]}" "$@"
      ;;
    stop)
      _agent_vm_stop "$@"
      ;;
    rm|destroy)
      _agent_vm_destroy "$@"
      ;;
    destroy-all)
      _agent_vm_destroy_all "$@"
      ;;
    list)
      _agent_vm_list "$@"
      ;;
    status)
      _agent_vm_status "$@"
      ;;
    help|--help|-h)
      _agent_vm_help
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      echo "Run 'agent-vm help' for usage." >&2
      return 1
      ;;
  esac
}

_agent_vm_help() {
  cat << 'EOF'
Usage: agent-vm [options] <command> [args]

Commands:
  setup              Create the base VM template (run once)
  claude [args]      Run Claude Code in the VM for the current directory
  opencode [args]    Run OpenCode in the VM for the current directory
  codex [args]       Run Codex CLI in the VM for the current directory
  vibe [args]        Run Mistral Vibe in the VM for the current directory
  shell, sh          Open a shell in the VM. Add -c "..." to run a one-shot
                     command via login zsh and exit.
  run <cmd> [args]   Run a command in the VM (no shell — for pipes/redirects
                     use 'shell -c "..."' instead; pass --tty for TUIs like
                     opencode, vibe, htop, etc.)
  stop               Stop the VM for the current directory
  rm                 Stop and delete the VM for the current directory
  destroy-all        Stop and delete all agent-vm VMs
  list               List all agent-vm VMs
  status             Show status of all VMs (current dir marked with >)
  help               Show this help

VM options (for claude, opencode, codex, vibe, shell, run):
  --disk GB          VM disk size (default: 10)
  --memory GB        VM memory (default: 3)
  --cpus N           Number of CPUs (default: 1)
  --reset            Destroy and re-clone the VM from the base template
  --offline          Block outbound internet (keeps host/VM communication)
  --readonly         Mount the project directory as read-only
  --git-read-only    Mount .git directory as read-only (allows git diff/log but not commit/stash)
  --rm               Automatically destroy the VM after the command exits

Examples:
  agent-vm setup                             # Create base VM
  agent-vm claude                            # Run Claude in a VM
  agent-vm opencode                          # Run OpenCode in a VM
  agent-vm codex                             # Run Codex in a VM
  agent-vm vibe                              # Run Mistral Vibe in a VM
  agent-vm --disk 50 --memory 16 --cpus 8 claude  # Custom resources
  agent-vm --reset claude                    # Fresh VM from base template
  agent-vm --rm claude                       # Destroy VM after Claude exits
  agent-vm --offline claude                  # No internet access
  agent-vm --readonly shell                  # Read-only project mount
  agent-vm --git-ro claude                   # Protect .git from writes
  agent-vm shell                             # Shell into the VM
  agent-vm sh -c "ls -la | grep config"      # One-shot command via login zsh
  agent-vm run npm install                   # Run a command in the VM
  agent-vm run --tty opencode -p "..."       # Run a TUI with PTY allocated
  agent-vm claude -p "fix lint errors"       # Pass args to claude

VMs are persistent and unique per directory. Running "agent-vm shell" or
"agent-vm claude" in the same directory will reuse the same VM.

Customization:
  ~/.agent-vm/env                   Shared env vars / tokens (dotenv-style;
                                     auto-loaded into every VM shell)
  ~/.agent-vm/volumes               Extra host paths to mount in VMs (one per
                                     line, supports both directories and files)
  ~/.agent-vm/setup.sh              Per-user setup (runs during "agent-vm setup")
  ~/.agent-vm/runtime.sh            Per-user runtime (runs on each VM start)
  <project>/.agent-vm.runtime.sh    Per-project runtime (runs on each VM start)

More info: https://github.com/sylvinus/agent-vm
EOF
}

_agent_vm_setup() {
  local disk=10
  local memory=3
  local cpus=1
  local preinstall=""
  local preinstall_seen=""
  # Defaults match the "default install" set: every component on EXCEPT the
  # opt-in languages (Ruby, Rust, Go). These apply when --preinstall isn't
  # passed and either the wizard's first prompt is accepted or stdin is not a
  # terminal (e.g. CI). `--preinstall=all` turns everything on;
  # `--preinstall=default,rust` composes the default set with an opt-in.
  local install_python=1 install_node=1
  local install_ruby=0 install_rust=0 install_golang=0
  local install_docker=1 install_chromium=1 install_gh=1
  local install_claude=1 install_opencode=1 install_codex=1 install_vibe=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        cat << 'EOF'
Usage: agent-vm setup [options]

Create a base VM template with dev tools and agents pre-installed. Runs an
interactive wizard by default; the first prompt offers a "default install"
(everything except the opt-in languages Ruby, Rust, Go). Answer 'n' for
per-component prompts. Pass --preinstall=... to skip the wizard and pick a
specific subset non-interactively. When stdin is not a terminal (e.g. CI),
the wizard is skipped automatically and the default set is installed.

Options:
  --disk GB           VM disk size (default: 10)
  --memory GB         VM memory (default: 3)
  --cpus N            Number of CPUs (default: 1)
  --preinstall=LIST   Comma-separated list of tools to preinstall in the base
                      VM image (skips the wizard). Anything not listed is
                      skipped. Use:
                        'default' for the default set
                                  (everything except Ruby, Rust, Go),
                        'all' for everything,
                        'none' for nothing.
                      Available names:
                        python, node, ruby, rust, golang, docker, chromium,
                        gh, claude, opencode, codex, vibe
                      Selecting codex, or chromium with any AI agent, also
                      installs node because those paths require npm/npx.
                      Examples:
                        --preinstall=default,rust       # default set plus Rust
                        --preinstall=python,docker,claude
  --help              Show this help
EOF
        return 0
        ;;
      --disk)
        disk="$2"
        shift 2
        _agent_vm_validate_int --disk "$disk" || return 1
        ;;
      --disk=*)
        disk="${1#*=}"
        shift
        _agent_vm_validate_int --disk "$disk" || return 1
        ;;
      --memory|--ram)
        memory="$2"
        shift 2
        _agent_vm_validate_int --memory "$memory" || return 1
        ;;
      --memory=*|--ram=*)
        memory="${1#*=}"
        shift
        _agent_vm_validate_int --memory "$memory" || return 1
        ;;
      --cpus)
        cpus="$2"
        shift 2
        _agent_vm_validate_int --cpus "$cpus" || return 1
        ;;
      --cpus=*)
        cpus="${1#*=}"
        shift
        _agent_vm_validate_int --cpus "$cpus" || return 1
        ;;
      --preinstall)
        preinstall_seen=1
        # Only consume the next argument as the value when it is an actual
        # value, not another option. Bare `--preinstall` falls back to the
        # default set (handled below) without swallowing e.g. a following
        # `--disk`.
        if [[ -n "$2" && "$2" != -* ]]; then
          preinstall="$2"
          shift 2
        else
          shift
        fi
        ;;
      --preinstall=*)
        preinstall="${1#*=}"
        preinstall_seen=1
        shift
        ;;
      --reset|--offline|--readonly|--git-read-only|--git-ro)
        shift ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Usage: agent-vm setup [--disk GB] [--memory GB] [--cpus N] [--preinstall=LIST]" >&2
        return 1
        ;;
    esac
  done

  # Apply --preinstall=LIST: start with everything OFF and turn on what's
  # listed. 'default' / 'all' / 'none' are shortcuts. Setting this also
  # bypasses the interactive wizard below. `--preinstall=` with no value
  # (or `--preinstall` swallowed by a following flag) falls back to the
  # default set — explicitly opting into the wizard's recommended install.
  # Pass `--preinstall=none` if you really want nothing.
  if [[ -n "$preinstall_seen" ]]; then
    install_python=0 install_node=0 install_ruby=0 install_rust=0 install_golang=0
    install_docker=0 install_chromium=0 install_gh=0
    install_claude=0 install_opencode=0 install_codex=0 install_vibe=0
    [[ -z "$preinstall" ]] && preinstall="default"
    # Iterate the comma-list portably across bash and zsh by appending a
    # trailing comma and peeling off one token per iteration.
    local rest="${preinstall}," f
    while [[ -n "$rest" ]]; do
      f="${rest%%,*}"
      rest="${rest#*,}"
      # Trim whitespace. Use bash/zsh-portable substitutions only.
      f="${f# }"; f="${f% }"
      [[ -z "$f" ]] && continue
      case "$f" in
        all)
          install_python=1 install_node=1 install_ruby=1
          install_rust=1 install_golang=1
          install_docker=1 install_chromium=1 install_gh=1
          install_claude=1 install_opencode=1 install_codex=1 install_vibe=1
          ;;
        default)
          install_python=1 install_node=1
          install_docker=1 install_chromium=1 install_gh=1
          install_claude=1 install_opencode=1 install_codex=1 install_vibe=1
          ;;
        none) ;;  # explicit no-op token; with the all-off reset above,
                  # `--preinstall=none` ships nothing.
        python)   install_python=1 ;;
        node)     install_node=1 ;;
        ruby)     install_ruby=1 ;;
        rust)     install_rust=1 ;;
        golang)   install_golang=1 ;;
        docker)   install_docker=1 ;;
        chromium) install_chromium=1 ;;
        gh)       install_gh=1 ;;
        claude)   install_claude=1 ;;
        opencode) install_opencode=1 ;;
        codex)    install_codex=1 ;;
        vibe)     install_vibe=1 ;;
        *)
          echo "Unknown preinstall name: $f (names are lowercase)" >&2
          echo "Valid: python, node, ruby, rust, golang, docker, chromium, gh, claude, opencode, codex, vibe, default, all, none" >&2
          return 1
          ;;
      esac
    done
  fi

  # Fail-fast checks before the (potentially long) wizard so the user doesn't
  # answer 15 prompts only to be told their host is missing Lima or KVM.
  if ! command -v limactl &>/dev/null; then
    if command -v brew &>/dev/null; then
      echo "Installing Lima..."
      brew install lima
    else
      echo "Error: Lima is required. Install from https://lima-vm.io/docs/installation/" >&2
      return 1
    fi
  fi

  _agent_vm_check_linux_prereqs || return 1

  # Interactive wizard, unless --preinstall was passed or no terminal is
  # attached (e.g. running under CI). Defaults shown in [] are prefilled from
  # any --disk/--memory/--cpus flags the user already passed, so they can
  # confirm or override. Components default to the "default install" set
  # (everything except Ruby/Rust/Go). The first prompt offers that whole set
  # as a one-tap shortcut — answer 'n' for per-component prompts.
  if [[ -z "$preinstall_seen" ]] && [[ -r /dev/tty ]]; then
    printf '\nagent-vm setup wizard\n' >&2
    printf '─────────────────────\n\n' >&2
    printf 'These settings apply to the base VM image. Every per-project VM is\n' >&2
    printf 'cloned from it, so anything preinstalled here is available in all\n' >&2
    printf 'future agent VMs. You can still install extra tools inside any\n' >&2
    printf 'individual VM later (e.g. via `agent-vm shell`).\n\n' >&2
    printf 'For more: https://github.com/sylvinus/agent-vm\n\n' >&2

    # Software first — the more interesting choice for most users.
    printf 'Software\n' >&2
    printf '────────\n' >&2
    printf '  Install:  Python, Node.js, Docker, Chromium, gh,\n' >&2
    printf '            Claude Code, OpenCode, Codex CLI, Mistral Vibe\n' >&2
    printf '  Skip:     Ruby, Rust, Go\n\n' >&2
    local use_default_software
    use_default_software=$(_agent_vm_ask_yn "Use this default" Y)
    if [[ "$use_default_software" != "1" ]]; then
      printf '\nAI coding agents\n' >&2
      printf '────────────────\n' >&2
      install_claude=$(_agent_vm_ask_yn "Claude Code" Y)
      install_opencode=$(_agent_vm_ask_yn "OpenCode" Y)
      install_codex=$(_agent_vm_ask_yn "Codex CLI" Y)
      install_vibe=$(_agent_vm_ask_yn "Mistral Vibe" Y)

      printf '\nSystem tools\n' >&2
      printf '────────────\n' >&2
      install_docker=$(_agent_vm_ask_yn "Docker" Y)
      install_chromium=$(_agent_vm_ask_yn "Chromium (headless browser)" Y)
      install_gh=$(_agent_vm_ask_yn "GitHub CLI (gh)" Y)

      local node_forced_reason=""
      if [[ "$install_codex" == "1" ]]; then
        node_forced_reason="Codex CLI requires Node.js"
      elif [[ "$install_chromium" == "1" && ( "$install_claude" == "1" || "$install_opencode" == "1" || "$install_vibe" == "1" ) ]]; then
        node_forced_reason="Chrome DevTools MCP uses npx"
      fi

      printf '\nLanguages\n' >&2
      printf '─────────\n' >&2
      install_python=$(_agent_vm_ask_yn "Python 3" Y)
      if [[ -n "$node_forced_reason" ]]; then
        install_node=1
        printf 'Node.js 24: yes (%s)\n' "$node_forced_reason" >&2
      else
        install_node=$(_agent_vm_ask_yn "Node.js 24" Y)
      fi
      install_ruby=$(_agent_vm_ask_yn "Ruby" Y)
      install_rust=$(_agent_vm_ask_yn "Rust" Y)
      install_golang=$(_agent_vm_ask_yn "Go" Y)
    fi

    # Resources second — same pattern, accept-in-one-go shortcut. Current
    # values reflect any --disk/--memory/--cpus already passed on the CLI.
    # These are starting values: any later `agent-vm` command can resize the
    # per-project VM with --disk/--memory/--cpus.
    printf '\nDefault resources\n' >&2
    printf '─────────────────\n' >&2
    printf '(per-VM override with --disk / --memory / --cpus on any agent-vm command)\n\n' >&2
    printf '  Disk     %s GB\n' "$disk" >&2
    printf '  Memory   %s GB\n' "$memory" >&2
    printf '  CPUs     %s\n\n'  "$cpus" >&2
    local use_default_resources
    use_default_resources=$(_agent_vm_ask_yn "Use these defaults" Y)
    if [[ "$use_default_resources" != "1" ]]; then
      disk=$(_agent_vm_ask_int "Disk size in GB" "$disk")
      memory=$(_agent_vm_ask_int "Memory in GB" "$memory")
      cpus=$(_agent_vm_ask_int "Number of CPUs" "$cpus")
    fi
    printf '\n' >&2
  fi

  if [[ "$install_chromium" == "1" ]]; then
    local wants_chrome_mcp=0
    [[ "$install_claude" == "1" || "$install_opencode" == "1" || "$install_codex" == "1" || "$install_vibe" == "1" ]] && wants_chrome_mcp=1
    if [[ "$wants_chrome_mcp" == "1" && "$install_node" != "1" ]]; then
      echo "Enabling Node.js because Chrome DevTools MCP uses npx." >&2
      install_node=1
    fi
  fi

  if [[ "$install_codex" == "1" && "$install_node" != "1" ]]; then
    echo "Enabling Node.js because Codex CLI requires npm." >&2
    install_node=1
  fi

  _agent_vm_clean_partial_state "$AGENT_VM_TEMPLATE"

  limactl stop "$AGENT_VM_TEMPLATE" &>/dev/null
  limactl delete "$AGENT_VM_TEMPLATE" --force &>/dev/null

  echo "Creating base VM..."
  local create_args=(
    --set '.mounts=[]'
    --disk="$disk"
    --memory="$memory"
    --cpus="$cpus"
    --tty=false
  )
  local create_log
  if ! create_log=$(limactl create --name="$AGENT_VM_TEMPLATE" template:debian-13 "${create_args[@]}" 2>&1); then
    echo "Error: Failed to create base VM." >&2
    echo "--- limactl create output ---" >&2
    echo "$create_log" >&2
    return 1
  fi

  _agent_vm_print_resources "$AGENT_VM_TEMPLATE"

  local start_log
  if ! start_log=$(limactl start "$AGENT_VM_TEMPLATE" 2>&1); then
    echo "Error: Failed to start base VM." >&2
    echo "--- limactl start output ---" >&2
    echo "$start_log" >&2
    echo "Full log: ~/.lima/$AGENT_VM_TEMPLATE/ha.stderr.log" >&2
    return 1
  fi

  # Run the setup script inside the VM. Component selections are passed by
  # prepending `export` lines to the script on stdin — keeps the integration
  # to one knob (env vars) and avoids quoting headaches with `limactl shell
  # env KEY=VAL`. The setup script's defaults for each flag match the host
  # wizard's "default install" set (Ruby/Rust/Go off, everything else on),
  # so invoking the in-VM script standalone — without these exports — still
  # produces the same default install.
  echo "Installing packages inside VM..."
  if [[ ! -r "${AGENT_VM_SCRIPT_DIR}/agent-vm.setup.sh" ]]; then
    echo "Error: Setup script not found at ${AGENT_VM_SCRIPT_DIR}/agent-vm.setup.sh" >&2
    return 1
  fi
  {
    printf 'export AGENT_VM_INSTALL_PYTHON=%s\n'    "$install_python"
    printf 'export AGENT_VM_INSTALL_NODE=%s\n'      "$install_node"
    printf 'export AGENT_VM_INSTALL_RUBY=%s\n'      "$install_ruby"
    printf 'export AGENT_VM_INSTALL_RUST=%s\n'      "$install_rust"
    printf 'export AGENT_VM_INSTALL_GOLANG=%s\n'    "$install_golang"
    printf 'export AGENT_VM_INSTALL_DOCKER=%s\n'    "$install_docker"
    printf 'export AGENT_VM_INSTALL_CHROMIUM=%s\n'  "$install_chromium"
    printf 'export AGENT_VM_INSTALL_GH=%s\n'        "$install_gh"
    printf 'export AGENT_VM_INSTALL_CLAUDE=%s\n'    "$install_claude"
    printf 'export AGENT_VM_INSTALL_OPENCODE=%s\n'  "$install_opencode"
    printf 'export AGENT_VM_INSTALL_CODEX=%s\n'     "$install_codex"
    printf 'export AGENT_VM_INSTALL_VIBE=%s\n'      "$install_vibe"
    cat "${AGENT_VM_SCRIPT_DIR}/agent-vm.setup.sh"
  } | limactl shell "$AGENT_VM_TEMPLATE" bash -l || { echo "Error: Setup script failed." >&2; return 1; }

  # Run user's custom setup script if it exists
  local user_setup="$AGENT_VM_STATE_DIR/setup.sh"
  if [ -f "$user_setup" ]; then
    echo "Running custom setup from $user_setup..."
    limactl shell "$AGENT_VM_TEMPLATE" zsh -l < "$user_setup" || { echo "Error: Custom setup script failed." >&2; return 1; }
  fi

  limactl stop "$AGENT_VM_TEMPLATE" &>/dev/null

  # Record base VM version so we can warn about stale clones
  mkdir -p "$AGENT_VM_STATE_DIR"
  date +%s > "$AGENT_VM_STATE_DIR/.agent-vm-base-version"

  echo ""
  echo "Base VM ready. Try one of these in any project directory:"
  echo "  agent-vm shell"
  [[ "$install_claude"   == "1" ]] && echo "  agent-vm claude"
  [[ "$install_opencode" == "1" ]] && echo "  agent-vm opencode"
  [[ "$install_codex"    == "1" ]] && echo "  agent-vm codex"
  [[ "$install_vibe"     == "1" ]] && echo "  agent-vm vibe"
  echo ""
  echo "Note: Existing VMs were not updated. Use --reset to re-clone them from the new base."
}

_agent_vm_claude() {
  local vm_opts=()
  local args=()
  local rm=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     vm_opts+=(--disk "$2"); shift 2 ;;
      --memory|--ram)   vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)     vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)    vm_opts+=(--reset); shift ;;
      --offline)  vm_opts+=(--offline); shift ;;
      --readonly) vm_opts+=(--readonly); shift ;;
      --git-read-only|--git-ro) vm_opts+=(--git-read-only); shift ;;
      --rm)       rm=1; shift ;;
      *)          args+=("$1"); shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1
  _agent_vm_print_resources "$vm_name"

  local exit_code=0
  limactl shell --workdir "$host_dir" "$vm_name" -- claude --dangerously-skip-permissions "${args[@]}"
  exit_code=$?
  [[ -n "$rm" ]] && { echo "Removing VM..."; _agent_vm_destroy; }
  return $exit_code
}

_agent_vm_opencode() {
  local vm_opts=()
  local args=()
  local rm=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     vm_opts+=(--disk "$2"); shift 2 ;;
      --memory|--ram)   vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)     vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)    vm_opts+=(--reset); shift ;;
      --offline)  vm_opts+=(--offline); shift ;;
      --readonly) vm_opts+=(--readonly); shift ;;
      --git-read-only|--git-ro) vm_opts+=(--git-read-only); shift ;;
      --rm)       rm=1; shift ;;
      *)          args+=("$1"); shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1
  _agent_vm_print_resources "$vm_name"

  # --auto auto-approves permission prompts that aren't explicitly denied,
  # giving full autonomy (safe inside the sandbox). This is OpenCode's shipped
  # equivalent of a "yolo" mode; the proposed --yolo flag was never merged.
  local exit_code=0
  limactl shell --tty --workdir "$host_dir" "$vm_name" opencode --auto "${args[@]}"
  exit_code=$?
  [[ -n "$rm" ]] && { echo "Removing VM..."; _agent_vm_destroy; }
  return $exit_code
}

_agent_vm_codex() {
  local vm_opts=()
  local args=()
  local rm=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     vm_opts+=(--disk "$2"); shift 2 ;;
      --memory|--ram)   vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)     vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)    vm_opts+=(--reset); shift ;;
      --offline)  vm_opts+=(--offline); shift ;;
      --readonly) vm_opts+=(--readonly); shift ;;
      --git-read-only|--git-ro) vm_opts+=(--git-read-only); shift ;;
      --rm)       rm=1; shift ;;
      *)          args+=("$1"); shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1
  _agent_vm_print_resources "$vm_name"

  local exit_code=0
  limactl shell --workdir "$host_dir" "$vm_name" codex --dangerously-bypass-approvals-and-sandbox "${args[@]}"
  exit_code=$?
  [[ -n "$rm" ]] && { echo "Removing VM..."; _agent_vm_destroy; }
  return $exit_code
}

_agent_vm_vibe() {
  local vm_opts=()
  local args=()
  local rm=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     vm_opts+=(--disk "$2"); shift 2 ;;
      --memory|--ram)   vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)     vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)    vm_opts+=(--reset); shift ;;
      --offline)  vm_opts+=(--offline); shift ;;
      --readonly) vm_opts+=(--readonly); shift ;;
      --git-read-only|--git-ro) vm_opts+=(--git-read-only); shift ;;
      --rm)       rm=1; shift ;;
      *)          args+=("$1"); shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1
  _agent_vm_print_resources "$vm_name"

  # Vibe is a full-screen TUI, so allocate a tty (like opencode).
  # --agent auto-approve gives full autonomy (safe inside the sandbox).
  local exit_code=0
  limactl shell --tty --workdir "$host_dir" "$vm_name" vibe --agent auto-approve "${args[@]}"
  exit_code=$?
  [[ -n "$rm" ]] && { echo "Removing VM..."; _agent_vm_destroy; }
  return $exit_code
}

_agent_vm_shell() {
  local vm_opts=()
  local rm=""
  local cmd_string=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     vm_opts+=(--disk "$2"); shift 2 ;;
      --memory|--ram)   vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)     vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)    vm_opts+=(--reset); shift ;;
      --offline)  vm_opts+=(--offline); shift ;;
      --readonly) vm_opts+=(--readonly); shift ;;
      --git-read-only|--git-ro) vm_opts+=(--git-read-only); shift ;;
      --rm)       rm=1; shift ;;
      -c|--command)
        if [[ $# -lt 2 || -z "$2" ]]; then
          echo "Error: -c/--command requires a command string." >&2
          return 1
        fi
        cmd_string="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1
  _agent_vm_print_resources "$vm_name"

  local exit_code=0
  if [[ -n "$cmd_string" ]]; then
    # One-shot: run the command via a login zsh so ~/.zshenv (mise, PATH,
    # ~/.agent-vm.env, …) is loaded. No "Type 'exit'..." chatter.
    limactl shell --workdir "$host_dir" "$vm_name" zsh -l -c "$cmd_string"
    exit_code=$?
  else
    echo "VM: $vm_name | Dir: $host_dir"
    if [[ -n "$rm" ]]; then
      echo "Type 'exit' to leave. VM will be destroyed after exit."
    else
      echo "Type 'exit' to leave (VM keeps running). Use 'agent-vm stop' to stop it."
    fi
    limactl shell --workdir "$host_dir" "$vm_name" zsh -l
    exit_code=$?
  fi
  [[ -n "$rm" ]] && { echo "Removing VM..."; _agent_vm_destroy; }
  return $exit_code
}

_agent_vm_run() {
  local vm_opts=()
  local args=()
  local rm=""
  local tty_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     vm_opts+=(--disk "$2"); shift 2 ;;
      --memory|--ram)   vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)     vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)    vm_opts+=(--reset); shift ;;
      --offline)  vm_opts+=(--offline); shift ;;
      --readonly) vm_opts+=(--readonly); shift ;;
      --git-read-only|--git-ro) vm_opts+=(--git-read-only); shift ;;
      --rm)       rm=1; shift ;;
      --tty)      tty_flag=1; shift ;;
      *)          args+=("$1"); shift ;;
    esac
  done
  if [[ ${#args[@]} -eq 0 ]]; then
    echo "Usage: agent-vm run [--tty] <command> [args]" >&2
    return 1
  fi
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1
  _agent_vm_print_resources "$vm_name"

  # `--tty` forces limactl to allocate a pseudo-terminal in the VM, which
  # full-screen TUIs (opencode, vibe, htop, …) need to render correctly when
  # invoked through `agent-vm run`. Without it, line-mode tools work fine but
  # ncurses-style UIs break.
  local shell_opts=(--workdir "$host_dir")
  [[ -n "$tty_flag" ]] && shell_opts+=(--tty)

  local exit_code=0
  limactl shell "${shell_opts[@]}" "$vm_name" "${args[@]}"
  exit_code=$?
  [[ -n "$rm" ]] && { echo "Removing VM..."; _agent_vm_destroy; }
  return $exit_code
}

_agent_vm_stop() {
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  if ! _agent_vm_exists "$vm_name"; then
    echo "No VM found for this directory." >&2
    return 1
  fi

  echo "Stopping VM '$vm_name'..."
  limactl stop "$vm_name" &>/dev/null
  echo "VM stopped."
}

_agent_vm_destroy() {
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  if ! _agent_vm_exists "$vm_name"; then
    echo "No VM found for this directory." >&2
    return 1
  fi

  echo "Stopping and deleting VM '$vm_name'..."
  limactl stop "$vm_name" &>/dev/null
  limactl delete "$vm_name" --force &>/dev/null
  _agent_vm_cleanup_state "$vm_name"
  echo "VM destroyed."
}

_agent_vm_destroy_all() {
  local vms
  vms=$(limactl list -q 2>/dev/null | grep "^agent-vm-" || true)
  if [[ -z "$vms" ]]; then
    echo "No agent-vm VMs found."
    return 0
  fi
  echo "This will destroy the following VMs:"
  echo "$vms"
  printf "Continue? [y/N] " >&2
  local reply=""
  IFS= read -r reply </dev/tty 2>/dev/null || reply=""
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi
  echo "$vms" | while read -r vm; do
    echo "Destroying $vm..."
    limactl stop "$vm" &>/dev/null
    limactl delete "$vm" --force &>/dev/null
    _agent_vm_cleanup_state "$vm"
  done
  echo "All VMs destroyed."
}

_agent_vm_list() {
  limactl list | head -1
  limactl list | grep "^agent-vm-" || echo "(no VMs)"
}

_agent_vm_status() {
  local host_dir
  host_dir="$(pwd)"
  local current_vm_name
  current_vm_name="$(_agent_vm_name "$host_dir")"

  local header
  header=$(limactl list | head -1)

  echo "VMs (current directory: $host_dir):"
  echo ""
  echo "$header" | sed 's/^/  /'
  limactl list | grep "^agent-vm-" | while read -r line; do
    local vm_name
    vm_name=$(echo "$line" | awk '{print $1}')
    if [[ "$vm_name" == "$current_vm_name" ]]; then
      echo "$line" | sed 's/^/> /'
    else
      echo "$line" | sed 's/^/  /'
    fi
  done || echo "  (no VMs)"
}

# When the file is executed directly (`./agent-vm.sh setup`) rather than
# sourced, dispatch to the agent-vm function so it doesn't silently no-op.
# Sourcing remains the canonical install path because it makes `agent-vm`
# available as a shell function across all future commands. Detection is
# shell-specific:
#   bash: BASH_SOURCE[0] differs from $0 when sourced
#   zsh:  ZSH_EVAL_CONTEXT contains ':file' when sourced
_agent_vm_is_sourced() {
  if [[ -n "${BASH_VERSION:-}" ]]; then
    [[ "${BASH_SOURCE[0]}" != "$0" ]]
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    [[ "${ZSH_EVAL_CONTEXT:-}" == *:file* ]]
  else
    return 0  # unknown shell — assume sourced and don't auto-run
  fi
}

if ! _agent_vm_is_sourced; then
  unset -f _agent_vm_is_sourced
  agent-vm "$@"
  # Preserve agent-vm's exit code — without the explicit exit, the script
  # would end on the implicit `unset -f` below, which always returns 0 and
  # would mask command failures (`./agent-vm.sh bad-cmd; echo $?` → 0).
  exit $?
fi
unset -f _agent_vm_is_sourced

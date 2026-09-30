# --- vm: naming, state, resources, SSH port -----------------------------------

# Lima leaves a partial state dir behind if `limactl create` is interrupted
# (Ctrl-C before lima.yaml is written). After that every subsequent limactl
# call on that name dies with `open ~/.lima/<vm>/lima.yaml: no such file or
# directory` — pre-emptively clean the dir so the next setup/start works.
_agent_vm_clean_partial_state() {
  local vm_name="$1"
  local lima_dir
  lima_dir="$(_agent_vm_lima_home)/$vm_name"
  if [[ -d "$lima_dir" ]] && [[ ! -f "$lima_dir/lima.yaml" ]]; then
    echo "Detected partial VM state at $lima_dir (no lima.yaml) — cleaning up." >&2
    rm -rf "$lima_dir"
  fi
}

# Resolve a user-supplied directory argument to the same absolute form the
# VM-running commands use.
#
# Those commands all derive the name from `$(pwd)`, so they never see a relative
# or trailing-slash path. `name` and `info` do take a directory argument, and the
# name is a hash of that *string*: without this, `agent-vm name /tmp` and
# `agent-vm name /tmp/` return two different VMs for one directory, and neither
# need match what `cd /tmp && agent-vm opencode` produces.
#
# Logical pwd (no `-P`), to agree with the `$(pwd)` the other commands use.
# A directory that does not exist is rejected rather than hashed: a name derived
# from an unresolvable path is wrong in a way nothing downstream would catch.
#
# `CDPATH=` is not cosmetic. With CDPATH set in the environment, `cd <relative>`
# searches it *before* the current directory and prints where it landed — so
# this would both emit a stray line into the captured value and resolve a
# DIFFERENT directory than the `-d` test above just validated. Clearing it keeps
# the argument meaning "relative to cwd", like every other path-taking tool.
_agent_vm_abs_dir() {
  local dir="${1:-$(pwd)}"
  if [[ ! -d "$dir" ]]; then
    echo "Error: no such directory: $dir" >&2
    return 1
  fi
  (CDPATH= cd -- "$dir" >/dev/null && pwd)
}

# SHA-256 of stdin, hex first. shasum ships with macOS and with perl on most
# Linux systems; minimal ones (Fedora, Arch containers) only have sha256sum.
# Both print the same digest, so a VM keeps its name across the two.
_agent_vm_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    return 1
  fi
}

# Generate a deterministic VM name for a directory. Fails rather than print a
# name without its hash: two projects with the same basename would then share
# one VM, and see each other's files.
_agent_vm_name() {
  local dir="${1:-$(pwd)}"
  local hash
  hash=$(echo -n "$dir" | _agent_vm_sha256 | cut -c1-8)
  if [[ ! "$hash" =~ ^[0-9a-f]{8}$ ]]; then
    echo "Error: cannot hash the directory name: install shasum or sha256sum." >&2
    return 1
  fi
  local base
  base=$(basename "$dir" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')
  echo "agent-vm-${base}-${hash}"
}

# Exact-line match against an already-captured string, with no pipe.
#
# `cmd | grep -q needle` is unsafe for anyone who sources this file from a
# script running under `set -o pipefail`: grep -q closes the pipe as soon as it
# matches, limactl takes a SIGPIPE and exits 141, and pipefail fails the whole
# pipeline. The result is an intermittent false negative that depends on how
# much limactl still had to write — it looks like "the VM doesn't exist". So
# capture the output first, then match it in the shell.
_agent_vm_has_line() {
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Check if a VM exists (any state).
# 0 = yes · 1 = no · 2 = could not ask (limactl itself failed).
# The third status matters: an empty answer from a failed query is otherwise
# indistinguishable from "no such VM", and `info` would report a confident 0.
_agent_vm_exists() {
  local list
  list="$(limactl list -q 2>/dev/null)" || return 2
  _agent_vm_has_line "$list" "$1"
}

# Check if a VM is running. Same three statuses as _agent_vm_exists.
_agent_vm_running() {
  local list
  list="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null)" || return 2
  _agent_vm_has_line "$list" "$1 Running"
}

# Check if the base VM template exists AND is usable. Kept as a named helper so
# integrators don't have to hardcode the template name to answer "do I need to
# run setup?". Same three statuses as _agent_vm_exists.
#
# Usable, not merely present: a setup interrupted while provisioning (apt
# failing behind a proxy, a Ctrl-C) leaves the template in Lima with none of
# the packages, and a clone of it answers every command with
# `zsh: command not found`. The version marker is written only at the very end
# of a successful setup, so it says the base can be cloned from, which Lima's
# inventory does not.
_agent_vm_base_exists() {
  _agent_vm_exists "$AGENT_VM_TEMPLATE" || return $?
  [[ -f "$AGENT_VM_STATE_DIR/.agent-vm-base-version" ]]
}

# Turn one of those exit statuses into the value `info` publishes.
_agent_vm_tristate() {
  case "$1" in
    0) echo 1 ;;
    1) echo 0 ;;
    *) echo unknown ;;
  esac
}

# Was <vm_name> cloned from an older base than the current one?
# Prints 1 (stale), 0 (up to date), or "unknown" when there is nothing recorded
# to compare against — never guess from a missing file. A VM with no version
# marker but a known base predates the marker, which makes it stale.
_agent_vm_stale_state() {
  local vm_name="$1"
  local base_ver="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
  local vm_ver="$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
  if [[ ! -f "$base_ver" ]]; then
    echo unknown
  elif [[ ! -f "$vm_ver" ]]; then
    echo 1
  elif [[ "$(cat "$base_ver" 2>/dev/null)" != "$(cat "$vm_ver" 2>/dev/null)" ]]; then
    echo 1
  else
    echo 0
  fi
}

# Remove all per-VM state files (version marker, terminfo cache, file mount
# cache, staging dirs). Called after a VM is deleted or before it is re-cloned
# via --reset.
_agent_vm_cleanup_state() {
  local vm_name="$1"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-term-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-file-mounts-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-mounts-${vm_name}"
  rm -rf "$AGENT_VM_STATE_DIR/file-mounts/${vm_name}"
  # Deleting the template retires the marker that says it is usable.
  if [[ "$vm_name" == "$AGENT_VM_TEMPLATE" ]]; then
    rm -f "$AGENT_VM_STATE_DIR/.agent-vm-base-version"
  fi
}

# Stop and delete <vm_name>, then forget its state. Fails, saying so, when
# Lima still lists it (or cannot be asked): --reset would otherwise go on with
# the old VM and the shares it was given, which a changed ~/.agent-vm/volumes
# may no longer allow. limactl gets /dev/null as stdin, for callers reading
# names from theirs.
_agent_vm_delete_vm() {
  local vm_name="$1" st=0
  limactl stop "$vm_name" </dev/null &>/dev/null
  limactl delete "$vm_name" --force </dev/null &>/dev/null
  _agent_vm_exists "$vm_name" || st=$?
  if [[ "$st" -ne 1 ]]; then
    echo "Error: could not delete VM '$vm_name'. See 'limactl list', then retry." >&2
    return 1
  fi
  _agent_vm_cleanup_state "$vm_name"
}

# Current resources of <vm_name> as "cpus|memory_bytes|disk_bytes".
# Prints nothing (and returns 1) when the VM is unknown to Lima or answers
# non-numeric values. No pipe into grep/head: see _agent_vm_has_line for why
# that is unsafe under pipefail.
_agent_vm_resources_bytes() {
  local vm_name="$1" all line
  all="$(limactl list --format '{{.Name}}|{{.CPUs}}|{{.Memory}}|{{.Disk}}' 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      "${vm_name}|"*)
        local cpus mem_bytes disk_bytes
        IFS='|' read -r _ cpus mem_bytes disk_bytes <<< "$line"
        [[ "$cpus" =~ ^[0-9]+$ ]] || return 1
        [[ "$mem_bytes" =~ ^[0-9]+$ ]] || return 1
        [[ "$disk_bytes" =~ ^[0-9]+$ ]] || return 1
        printf '%s|%s|%s\n' "$cpus" "$mem_bytes" "$disk_bytes"
        return 0 ;;
    esac
  done <<< "$all"
  return 1
}

# Current resources of <vm_name> as "cpus|memory_gib|disk_gib", for display.
# GiB values are truncated: only use this for printing, never for comparing
# (see _agent_vm_resources_differ).
_agent_vm_resources() {
  local raw cpus mem_bytes disk_bytes
  raw="$(_agent_vm_resources_bytes "$1")" || return 1
  IFS='|' read -r cpus mem_bytes disk_bytes <<< "$raw"
  printf '%s|%s|%s\n' "$cpus" "$((mem_bytes / 1073741824))" "$((disk_bytes / 1073741824))"
}

# Print VM resource details (CPUs, memory, disk), and when the base the VM was
# cloned from was built: its agents and packages are that old.
_agent_vm_print_resources() {
  local res cpus mem_gib disk_gib built day age
  if res="$(_agent_vm_resources "$1")"; then
    IFS='|' read -r cpus mem_gib disk_gib <<< "$res"
    echo "  Resources: CPUs: ${cpus}, Memory: ${mem_gib} GiB, Disk: ${disk_gib} GiB"
  fi
  # The base's timestamp, copied when this VM was cloned. None for the base
  # itself, or for a VM cloned before it was recorded.
  built="$(cat "$AGENT_VM_STATE_DIR/.agent-vm-version-$1" 2>/dev/null)"
  [[ "$built" =~ ^[0-9]+$ ]] || return 0
  # BSD date first: GNU date takes -r for a file, and fails on a number.
  day="$(date -r "$built" +%F 2>/dev/null || date -d "@$built" +%F 2>/dev/null)" || return 0
  age=$(( ($(date +%s) - built) / 86400 ))
  case "$age" in
    0) age="today" ;;
    1) age="1 day ago" ;;
    *) age="$age days ago" ;;
  esac
  echo "  Base VM: built $day, $age"
}

# Would the requested resources actually change anything on <vm_name>?
# Empty request fields mean "not specified". Returns 0 when something differs
# (or when the current values can't be read — never claim "no change" from
# missing information), 1 when the VM already matches the request.
#
# Compared in bytes, not in truncated GiB: a VM holding a fractional size
# (set outside agent-vm, or by an older agent-vm) must converge to the
# requested integer GiB with one apply, not be misread as already matching
# it on every call.
#
# Disk is compared one-way on purpose: Lima can grow a disk but not shrink it,
# so a request below the current size is not a change that stopping could apply.
_agent_vm_resources_differ() {
  local vm_name="$1" want_cpus="$2" want_mem="$3" want_disk="$4"
  local cur cur_cpus cur_mem_bytes cur_disk_bytes
  if ! cur="$(_agent_vm_resources_bytes "$vm_name")"; then
    return 0
  fi
  IFS='|' read -r cur_cpus cur_mem_bytes cur_disk_bytes <<< "$cur"
  if [[ -n "$want_cpus" && "$want_cpus" != "$cur_cpus" ]]; then
    return 0
  fi
  # Requested values are validated integers where they are parsed, so a
  # non-integer here is treated as "cannot tell", not as "no change".
  if [[ -n "$want_mem" ]]; then
    [[ "$want_mem" =~ ^[0-9]+$ ]] || return 0
    [[ "$((10#$want_mem * 1073741824))" != "$cur_mem_bytes" ]] && return 0
  fi
  if [[ -n "$want_disk" ]]; then
    [[ "$want_disk" =~ ^[0-9]+$ ]] || return 0
    [[ "$((10#$want_disk * 1073741824))" -gt "$cur_disk_bytes" ]] && return 0
  fi
  return 1
}

# The SSH port set in <vm_name>'s config, 0 when Lima picks one on each start.
# Empty when it cannot be read.
_agent_vm_ssh_port_config() {
  local port
  port="$(limactl list "$1" --format '{{.Config.SSH.LocalPort}}' 2>/dev/null)" || return 1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  echo "$port"
}

# 0 when --ssh-port <port> asks for a change to <vm_name>. A config that cannot
# be read is left alone, with a warning, rather than stopping the VM each run.
_agent_vm_ssh_port_differs() {
  local vm_name="$1" want="$2" have
  [[ -n "$want" ]] || return 1
  if ! have="$(_agent_vm_ssh_port_config "$vm_name")"; then
    echo "Warning: cannot read the SSH port of VM '$vm_name'; --ssh-port $want is not applied." >&2
    return 1
  fi
  [[ "$have" != "$want" ]]
}

# The agent-vm VMs other than the base template, one per line. Empty when
# there are none, or when limactl cannot answer.
_agent_vm_project_vms() {
  local list
  list="$(limactl list -q 2>/dev/null)" || return 0
  printf '%s\n' "$list" | grep "^agent-vm-" | grep -v "^${AGENT_VM_TEMPLATE}\$" || true
}

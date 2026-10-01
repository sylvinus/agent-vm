# --- vm: naming, state, resources, SSH port -----------------------------------

# An interrupted `limactl create` leaves ~/.lima/<vm> without lima.yaml, and
# every later limactl call on that name fails: removed first.
_agent_vm_clean_partial_state() {
  local vm_name="$1"
  local lima_dir
  lima_dir="$(_agent_vm_lima_home)/$vm_name"
  if [[ -d "$lima_dir" ]] && [[ ! -f "$lima_dir/lima.yaml" ]]; then
    echo "Detected partial VM state at $lima_dir (no lima.yaml): cleaning up." >&2
    rm -rf "$lima_dir"
  fi
}

# The directory argument of `name` and `info` as the other commands spell
# theirs, `$(pwd)` (logical): the VM name hashes that string, so `/tmp/` and
# `/tmp` must give one. A directory that does not exist is refused.
_agent_vm_abs_dir() {
  local dir="${1:-$(pwd)}"
  if [[ ! -d "$dir" ]]; then
    echo "Error: no such directory: $dir" >&2
    return 1
  fi
  dir="$(CDPATH= cd -- "$dir" >/dev/null && pwd)" || return 1
  # A newline in it would forge lines of `info`'s key=value output (a folder
  # the VM made, named "x<newline>security_questions=none"). Checked on the
  # whole path, the current directory's included. Starting a VM there is
  # refused anyway.
  if [[ "$dir" == *[[:cntrl:]]* ]]; then
    echo "Error: the directory name contains a control character." >&2
    return 1
  fi
  printf '%s\n' "$dir"
}

# Why Lima cannot be given <dir> as a share, on stdout; fails when it can.
# Whitespace: the mount fails silently, leaving a bare, root-owned mount
# point where every write fails. A quote, a backslash or a control character:
# the path is spliced into the mounts JSON of `limactl edit --set`, where it
# would end the string and add mounts of its own.
_agent_vm_unmountable_path() {
  if [[ "$1" == *[[:space:]]* ]]; then
    echo "contains whitespace, which Lima cannot mount"
  elif [[ "$1" == *[\"\\]* || "$1" == *[[:cntrl:]]* ]]; then
    echo "contains a quote, a backslash or a control character"
  else
    return 1
  fi
}

# Prints why <dir> must not be shared with a VM ("is, or contains, ..." or "is
# inside ..."), and returns 0, when it is or contains your home directory
# (dotfiles, SSH keys, every other project), or is, contains or is inside
# agent-vm itself (the host runs its files), agent-vm's state (every VM's env)
# or Lima's (the VMs' SSH key and disks, override.yaml adding mounts to every
# VM). A project inside the home directory is what is expected. Returns 1
# when it is none of them.
# Compared as physical paths: a share is the directory a path resolves to.
# And whatever the case where the file system ignores it: `cd /c/users/me`
# reaches the home directory in Git Bash, which keeps the spelling typed.
_agent_vm_unsafe_project() {
  local dir p rp what
  dir="$(CDPATH= cd -P -- "$1" 2>/dev/null && pwd)" || dir="$1"
  dir="$(_agent_vm_fold "$dir")"
  for what in "your home directory" "agent-vm itself" "agent-vm's state" "Lima's state"; do
    case "$what" in
      "your home directory") p="$HOME" ;;
      "agent-vm itself")     p="$AGENT_VM_SCRIPT_DIR" ;;
      "agent-vm's state")    p="$AGENT_VM_STATE_DIR" ;;
      *)                     p="$(_agent_vm_lima_home)" ;;
    esac
    [[ -n "$p" ]] || continue
    # Not resolved when it does not exist: as typed, never emptied, or every
    # path would be inside it.
    if rp="$(CDPATH= cd -P -- "$p" 2>/dev/null && pwd)" && [[ -n "$rp" ]]; then
      p="$rp"
    else
      p="${p%/}"
    fi
    [[ -n "$p" ]] || continue
    p="$(_agent_vm_fold "$p")"
    case "${p%/}/" in
      "${dir%/}/"*)
        printf 'is, or contains, %s\n' "$what"
        return 0 ;;
    esac
    [[ "$what" == "your home directory" ]] && continue
    case "${dir%/}/" in
      "${p%/}/"*)
        printf 'is inside %s\n' "$what"
        return 0 ;;
    esac
  done
  return 1
}

# Stop <vm> and check that it did: limactl's status does not say (it fails on
# a VM that was already stopped). 1 when it still runs or Lima cannot tell.
_agent_vm_stop_vm() {
  local st=0
  limactl stop "$1" </dev/null &>/dev/null
  _agent_vm_running "$1" || st=$?
  [[ "$st" -eq 1 ]]
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

# A name for a --scratch VM started in <dir>: its own, so it is never the
# folder's VM and several can run at once. Short enough for Lima (76
# characters, and a socket path under ~/.lima of at most 104 on macOS).
_agent_vm_scratch_name() {
  local base rand
  base=$(basename "$1" | tr -cs 'a-zA-Z0-9' '-' | cut -c1-20 | sed 's/^-*//;s/-*$//')
  rand="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  if [[ ! "$rand" =~ ^[0-9a-f]{8}$ ]]; then
    echo "Error: cannot read /dev/urandom to name the VM." >&2
    return 1
  fi
  echo "agent-vm-${base:-project}-scratch-$rand"
}

# Where a --scratch run records its VM, with the pid of the shell running it.
_agent_vm_scratch_marker() {
  printf '%s/.agent-vm-scratch-%s\n' "$AGENT_VM_STATE_DIR" "$1"
}

# --scratch VMs a run could not delete (killed, its terminal closed), one per
# line: recorded by a run whose pid is gone. A reused pid only delays the
# cleanup. Only names _agent_vm_scratch_name makes: these are deleted unasked.
_agent_vm_scratch_leftovers() {
  local f pid vm
  find "$AGENT_VM_STATE_DIR" -maxdepth 1 -name '.agent-vm-scratch-*' 2>/dev/null \
    | while IFS= read -r f; do
        vm="${f##*/.agent-vm-scratch-}"
        [[ "$vm" =~ ^agent-vm-[A-Za-z0-9-]+-scratch-[0-9a-f]{8}$ ]] || continue
        pid="$(cat "$f" 2>/dev/null)"
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && continue
        printf '%s\n' "$vm"
      done
}

# Exact-line match against an already-captured string, with no pipe: under a
# caller's pipefail, `limactl list | grep -q` fails when grep exits before
# limactl is done (SIGPIPE), a VM then read as missing.
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

# Whether the base template exists and can be cloned from, with the statuses
# of _agent_vm_exists. An interrupted setup leaves a template without its
# packages: only its marker, written at the very end, says it is usable.
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
# to compare against, never a guess from a missing file. A VM with no version
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
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-built-by-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-sshfs-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-term-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-file-mounts-${vm_name}"
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-mounts-${vm_name}"
  rm -f "$(_agent_vm_scratch_marker "$vm_name")"
  rm -rf "$AGENT_VM_STATE_DIR/file-mounts/${vm_name}"
  # Deleting the template retires the marker that says it is usable.
  if [[ "$vm_name" == "$AGENT_VM_TEMPLATE" ]]; then
    rm -f "$AGENT_VM_STATE_DIR/.agent-vm-base-version" "$AGENT_VM_STATE_DIR/.agent-vm-base-built-by"
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
  local res cpus mem_gib disk_gib built day
  if res="$(_agent_vm_resources "$1")"; then
    IFS='|' read -r cpus mem_gib disk_gib <<< "$res"
    echo "  Resources: CPUs: ${cpus}, Memory: ${mem_gib} GiB, Disk: ${disk_gib} GiB"
  fi
  # The base's timestamp, copied when this VM was cloned. None for the base
  # itself, or for a VM cloned before it was recorded.
  built="$(cat "$AGENT_VM_STATE_DIR/.agent-vm-version-$1" 2>/dev/null)"
  [[ "$built" =~ ^[0-9]+$ ]] || return 0
  day="$(_agent_vm_epoch_date "$built" +%F)" || return 0
  echo "  Base VM: built $day"
}

# Epoch <t> formatted with <format>, in the local zone. GNU date takes -r for
# a file: a file named <t> in the current directory, which the VM can write,
# would answer. So -d there, -r for BSD date, and either for busybox.
_agent_vm_epoch_date() {
  if date --version >/dev/null 2>&1; then
    date -d "@$1" "$2" 2>/dev/null
  else
    date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2" 2>/dev/null
  fi
}

# The base <vm> was cloned from, for `list`: the agent-vm version that built
# it and the day. The base template describes itself. 0.1.0 recorded no
# version: a base without one was built by it.
_agent_vm_base_label() {
  local ver_file="$AGENT_VM_STATE_DIR/.agent-vm-version-$1"
  local by_file="$AGENT_VM_STATE_DIR/.agent-vm-built-by-$1"
  local built by day=""
  if [[ "$1" == "$AGENT_VM_TEMPLATE" ]]; then
    ver_file="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
    by_file="$AGENT_VM_STATE_DIR/.agent-vm-base-built-by"
  fi
  built="$(cat "$ver_file" 2>/dev/null)"
  by="$(cat "$by_file" 2>/dev/null)"
  [[ "$by" =~ ^[0-9A-Za-z.+-]+$ ]] || by=0.1.0
  [[ "$built" =~ ^[0-9]+$ ]] && day="$(_agent_vm_epoch_date "$built" +%F)"
  printf '%s %s\n' "$by" "${day:--}"
}

# agent-vm 0.1.0 made its VMs, and its bases, without sshfs and without the
# wrapper agent-vm.setup.sh installs, and gave them Lima's default mount type.
# Moved to reverse-sshfs to keep .git read-only, such a VM would get Debian's
# sshfs from Lima's boot scripts, which refuses absolute and ".." symlinks
# (node_modules/.bin), and only with apt reachable during the boot. So it
# boots once with no shares (nothing writable before its shares are
# protected), gets both, and stops. To be removed in a future release.
_agent_vm_migrate_0_1() {
  local vm_name="$1" out
  if ! out=$(cd /tmp && limactl edit "$vm_name" --set 'del(.mountType) | .mounts = []' 2>&1); then
    echo "Error: could not remove the shares of '$vm_name' to install sshfs:" >&2
    echo "$out" >&2
    return 1
  fi
  echo "Starting VM '$vm_name' without shares to install sshfs..."
  if ! out=$(limactl start "$vm_name" 2>&1); then
    echo "Error: Failed to start VM '$vm_name' to install sshfs:" >&2
    echo "$out" >&2
    return 1
  fi
  # The same wrapper as agent-vm.setup.sh. sudo drops the proxy settings on
  # these VMs (no env_keep before 0.2.0), so they are passed to apt by name.
  # shellcheck disable=SC2016
  if ! out=$(limactl shell --workdir / "$vm_name" sh -c '
    set -e
    if [ ! -x /usr/bin/sshfs ]; then
      set -- DEBIAN_FRONTEND=noninteractive
      for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
        eval "x=\${$v-}"
        [ -z "$x" ] || set -- "$@" "$v=$x"
      done
      sudo env "$@" apt-get -o DPkg::Lock::Timeout=120 update
      sudo env "$@" apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends sshfs
    fi
    sudo tee /usr/local/bin/sshfs > /dev/null <<"EOF"
#!/bin/sh
# Installed by agent-vm: see agent-vm.setup.sh.
if /usr/bin/sshfs -h 2>&1 | grep -q no_contain_symlinks; then
  exec /usr/bin/sshfs "$@" -o no_contain_symlinks
fi
exec /usr/bin/sshfs "$@"
EOF
    sudo chmod 755 /usr/local/bin/sshfs' </dev/null 2>&1); then
    echo "Error: could not install sshfs in VM '$vm_name':" >&2
    echo "$out" | tail -n 20 >&2
    _agent_vm_stop_vm "$vm_name"
    return 1
  fi
  if ! _agent_vm_stop_vm "$vm_name"; then
    echo "Error: could not stop VM '$vm_name' after installing sshfs." >&2
    return 1
  fi
}

# Called on the stopped <vm> before it is given protected shares: migrates it
# (see above) when it comes from a base built by 0.1.0, which recorded no
# version, and was not migrated yet. Made by 0.1.0 or cloned by 0.2.0 from
# such a base: neither has the version of its base recorded.
_agent_vm_migrate_0_1_if_needed() {
  local vm_name="$1"
  [[ -f "$AGENT_VM_STATE_DIR/.agent-vm-built-by-$vm_name" ]] && return 0
  [[ -f "$AGENT_VM_STATE_DIR/.agent-vm-sshfs-$vm_name" ]] && return 0
  echo "Warning: VM '$vm_name' comes from a base built by agent-vm 0.1.0, without the sshfs of the shares that keep .git read-only. It boots once without shares to install it. This migration will be removed in a future release: 'agent-vm setup', then '--reset', gives a VM from a current base." >&2
  _agent_vm_migrate_0_1 "$vm_name" || return 1
  mkdir -p "$AGENT_VM_STATE_DIR" && : > "$AGENT_VM_STATE_DIR/.agent-vm-sshfs-$vm_name"
}

# Would the requested resources actually change anything on <vm_name>?
# Empty request fields mean "not specified". Returns 0 when something differs
# (or when the current values can't be read: never claim "no change" from
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

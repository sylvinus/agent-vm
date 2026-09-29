# --- host capacity ------------------------------------------------------------
# A VM handed more CPU or RAM than the host can spare makes the host unusable
# for as long as the agent runs — and agents are meant to run unattended, for
# a while. So a --cpus/--memory above this host's share is clamped to it, out
# loud rather than silently. Nothing new to type: the flags stay plain
# integers, and a request that fits is applied as asked.
#
# The share is half the host by default. Not a measurement, a policy: it leaves
# the machine usable while the VM works. AGENT_VM_HOST_SHARE overrides it for
# anyone who knows better (1 = the whole host, no clamping in practice).
AGENT_VM_HOST_SHARE="${AGENT_VM_HOST_SHARE:-2}"

# Host CPU count, empty when it cannot be determined. Never guess: an unknown
# host must leave the requested value alone, not silently shrink it.
_agent_vm_host_cpus() {
  local n
  if n=$(sysctl -n hw.ncpu 2>/dev/null) && [[ -n "$n" ]]; then printf '%s\n' "$n"
  elif n=$(nproc 2>/dev/null) && [[ -n "$n" ]]; then printf '%s\n' "$n"
  fi
}

# Host RAM in GiB, empty when it cannot be determined.
_agent_vm_host_mem_gib() {
  local bytes kib
  if bytes=$(sysctl -n hw.memsize 2>/dev/null) && [[ -n "$bytes" ]]; then
    printf '%s\n' "$((bytes / 1073741824))"
  elif [[ -r /proc/meminfo ]] && kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null) \
       && [[ -n "$kib" ]]; then
    printf '%s\n' "$((kib / 1048576))"
  fi
}

# _agent_vm_host_share <total> <floor> — the share of <total> this host will
# give a VM, never below <floor>. An AGENT_VM_HOST_SHARE that is not a positive
# integer falls back to 2: it goes into arithmetic, where 0 divides by zero,
# "08" is bad octal and a name is evaluated as a variable.
_agent_vm_host_share() {
  local total="$1" floor="$2" div="$AGENT_VM_HOST_SHARE" share
  if [[ ! "$div" =~ ^[1-9][0-9]*$ ]]; then
    echo "Warning: AGENT_VM_HOST_SHARE='$div' is not a positive integer; using 2." >&2
    div=2
  fi
  share=$((10#$total / 10#$div))
  [[ "$share" -lt "$floor" ]] && share="$floor"
  printf '%s\n' "$share"
}

# _agent_vm_cap_resource <cpus|memory> <value> — the value to actually apply.
# Above this host's share it comes back clamped, with a notice; at or below it
# comes back untouched. An empty value (nothing requested) and an unreadable
# host both mean "don't touch": guessing low on an unknown machine would hand
# out a 1-CPU VM on a 64-core host, which is worse than not guessing.
_agent_vm_cap_resource() {
  local kind="$1" val="$2" total floor share
  [[ -z "$val" ]] && { printf '\n'; return 0; }

  case "$kind" in
    cpus)   total="$(_agent_vm_host_cpus)";    floor=1 ;;
    memory) total="$(_agent_vm_host_mem_gib)"; floor=2 ;;
    *)      printf '%s\n' "$val"; return 0 ;;
  esac
  if [[ -z "$total" || "$total" -le 0 ]]; then
    printf '%s\n' "$val"
    return 0
  fi

  share="$(_agent_vm_host_share "$total" "$floor")"
  if [[ "$val" -gt "$share" ]]; then
    echo "Note: --$kind $val exceeds this host's share ($total detected); using $share." >&2
    printf '%s\n' "$share"
    return 0
  fi
  printf '%s\n' "$val"
}

# Warn when the host has less free space than the disk being asked for. Lima
# images are sparse, so this is a warning and not an error: the disk is
# allocated as it fills, and a smaller host can still work for a while.
_agent_vm_warn_disk_space() {
  local want="$1" avail_kib avail_gib
  [[ -n "$want" ]] || return 0
  avail_kib=$(df -Pk "${LIMA_HOME:-$HOME}" 2>/dev/null | awk 'NR==2 {print $4}')
  case "$avail_kib" in ''|*[!0-9]*) return 0 ;; esac
  avail_gib=$((avail_kib / 1048576))
  if [[ "$avail_gib" -lt "$want" ]]; then
    echo "Warning: ~${avail_gib} GiB free for a ${want} GiB VM disk (sparse: allocated as used)." >&2
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
    local groups
    groups="$(id -nG 2>/dev/null || true)"
    if [[ " $groups " != *" kvm "* ]]; then
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

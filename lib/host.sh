# --- host capacity ------------------------------------------------------------
# A VM handed more CPU or RAM than the host can spare makes the host unusable
# for as long as the agent runs, and agents are meant to run unattended, for
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

# _agent_vm_host_share <total> <floor>: the share of <total> this host will
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

# _agent_vm_cap_resource <cpus|memory> <value>: the value to actually apply.
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

# Free space in GiB where Lima keeps the VMs' disks, in $HOME until Lima has
# made its directory. "/.": the directory a link there leads to. Fails when
# df cannot say.
_agent_vm_free_gib() {
  local kib dir
  dir="$(_agent_vm_lima_home)"
  [[ -d "$dir" ]] || dir="$HOME"
  kib=$(df -Pk "$dir/." 2>/dev/null | awk 'NR==2 {print $4}')
  case "$kib" in ''|*[!0-9]*) return 1 ;; esac
  echo $((kib / 1048576))
}

# Warn when the host has less free space than the disk being asked for. Lima
# images are sparse, so this is a warning and not an error: the disk is
# allocated as it fills, and a smaller host can still work for a while.
_agent_vm_warn_disk_space() {
  local want="$1" avail_gib
  [[ -n "$want" ]] || return 0
  avail_gib="$(_agent_vm_free_gib)" || return 0
  if [[ "$avail_gib" -lt "$want" ]]; then
    echo "Warning: ~${avail_gib} GiB free for a ${want} GiB VM disk (sparse: allocated as used)." >&2
  fi
}

# Check Linux prerequisites Lima needs to spin up a QEMU+KVM VM. macOS uses
# different backends (vz/qemu-via-brew) so this is a no-op there. Returns
# non-zero with actionable install/permission hints when something's missing:
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
    # Inside WSL the fix is on the Windows side, by the user: WSL1 has no
    # Linux kernel and can never run VMs, while WSL2 needs the host to let
    # KVM through (nested virtualization). Neither is anything setup can do.
    case "$(_agent_vm_wsl_version)" in
      1)
        echo "  This looks like WSL1, which cannot run VMs." >&2
        echo "  Upgrade the distribution to WSL2: wsl --set-version <distro> 2" >&2
        ;;
      2)
        echo "  This looks like WSL2 without nested virtualization: KVM is not" >&2
        echo "  passed through from the Windows host. Update WSL (wsl --update)," >&2
        echo "  enable virtualization on the host, then retry." >&2
        ;;
      *)
        echo "  Hardware virtualization may be disabled in BIOS, or the kernel" >&2
        echo "  lacks KVM support (nested virt in a guest VM, etc.)." >&2
        ;;
    esac
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

# 0 when running on Windows (Git Bash, MSYS2 or Cygwin), as reported by
# uname: MINGW64_NT-..., MSYS_NT-... or CYGWIN_NT-....
_agent_vm_on_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Git Bash and MSYS2 rewrite every argument that looks like a POSIX path when
# they start a native Windows program: `--workdir /c/proj` reaches limactl.exe
# as `C:/proj`, and so does a path meant for the guest. On Windows, limactl is
# therefore called with that rewriting off, and the host paths Lima itself
# reads are converted by _agent_vm_host_path.
if _agent_vm_on_windows; then
  limactl() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command limactl "$@"; }
fi

# Path of the limactl binary, empty when there is none. `command -v` cannot
# answer where the function above shadows it.
_agent_vm_limactl_path() {
  type -P limactl 2>/dev/null
}

# A host path as Lima reads it: C:/Users/... on Windows, unchanged elsewhere.
_agent_vm_host_path() {
  if _agent_vm_on_windows && command -v cygpath >/dev/null 2>&1; then
    cygpath -m -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Lima's state directory: LIMA_HOME, or ~/.lima.
_agent_vm_lima_home() {
  printf '%s\n' "${LIMA_HOME:-$HOME/.lima}"
}

# WSL generation from the kernel release: prints 2 or 1, or nothing when not
# on WSL. Only meaningful on Linux (WSL1 reports Microsoft without WSL2).
_agent_vm_wsl_version() {
  local rel
  rel="$(uname -r 2>/dev/null)" || return 0
  case "$rel" in
    *WSL2*) printf '2\n' ;;
    *[Mm]icrosoft*) printf '1\n' ;;
  esac
  return 0
}

# Check Windows prerequisites Lima needs for its QEMU driver. A no-op
# everywhere else, like the Linux check above.
#
# Only the QEMU binary is checked: whether the "Windows Hypervisor Platform"
# feature is enabled cannot be read without administrator rights, so a host
# without it fails at the first start instead, where
# _agent_vm_windows_start_hint explains it. winget ships with Windows 11, so
# it is the install path named here. Its QEMU installer does not add itself
# to PATH: when QEMU is in its default directory, that goes on PATH for this
# shell, with the line making it permanent.
_agent_vm_check_windows_prereqs() {
  _agent_vm_on_windows || return 0

  local arch_bin qemu_dir
  # uname -m under Git Bash reports the Windows architecture.
  case "$(uname -m)" in
    x86_64)        arch_bin="qemu-system-x86_64" ;;
    aarch64|arm64) arch_bin="qemu-system-aarch64" ;;
    *)             arch_bin="qemu-system-$(uname -m)" ;;
  esac

  command -v "$arch_bin" &>/dev/null && return 0
  qemu_dir="${AGENT_VM_QEMU_DIR:-/c/Program Files/qemu}"
  if [[ -x "$qemu_dir/$arch_bin.exe" ]]; then
    export PATH="$qemu_dir:$PATH"
    echo "Added $qemu_dir to PATH for this shell. To keep it, add this line to ~/.bash_profile:"
    printf '  export PATH="%s:$PATH"\n' "$qemu_dir"
    return 0
  fi
  echo "Error: Lima needs '$arch_bin' on PATH (not found)." >&2
  echo "  Install QEMU with: winget install SoftwareFreedom.QEMU" >&2
  echo "  QEMU also needs the 'Windows Hypervisor Platform' Windows feature (see 'agent-vm doctor')." >&2
  return 1
}

# What an administrator runs, once, then reboots, for QEMU to use WHPX.
AGENT_VM_WHPX_ON="DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All"

# Printed after a failed VM start on Windows when one of the <log>s shows QEMU
# could not use WHPX, Windows' hypervisor API. Lima uses it unconditionally on
# Windows, with no slower fallback, and turning it on takes an administrator.
_agent_vm_windows_start_hint() {
  _agent_vm_on_windows || return 0
  grep -qi 'whpx' "$@" 2>/dev/null || return 0
  cat >&2 <<EOF
QEMU could not use the Windows hypervisor. It needs the "Windows Hypervisor
Platform" Windows feature, which an administrator turns on once, followed by
a reboot: in Windows Features, or from an administrator terminal:
  $AGENT_VM_WHPX_ON
On a managed laptop, that is a request to your IT department.
EOF
}

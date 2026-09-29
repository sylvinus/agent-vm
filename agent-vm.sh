#!/usr/bin/env bash
#
# agent-vm: Run AI coding agents inside sandboxed Lima VMs
# Part of https://www.agent-vm.org/
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
#   agent-vm pi       - Run Pi in a persistent VM for cwd
#   agent-vm shell    - Open a shell in the persistent VM for cwd
#                       (alias: 'sh'; add -c "..." for a one-shot command)
#   agent-vm stop     - Stop the VM for cwd
#   agent-vm rm       - Stop and delete the VM for cwd
#   agent-vm list     - List all agent-vm VMs
#   agent-vm status   - Show status of all VMs (current dir marked with >)
#   agent-vm doctor   - Check the host, Lima, the base and this directory
#   agent-vm name     - Print the VM name for cwd
#   agent-vm info     - Print machine-readable state (key=value)
#   agent-vm version  - Print the agent-vm version
#   agent-vm help     - Show help
#

# Semantic version of this file. Bumped by hand on release. Integrators gate on
# it via `agent-vm version`; a build with no `version` command predates it.
AGENT_VM_VERSION="0.2.0"

AGENT_VM_TEMPLATE="agent-vm-base"
# Overridable so a test, a CI job or a second install can keep its own state
# without moving HOME — moving HOME also moves Lima's own state, which makes a
# sandboxed run rebuild every VM. Integrators must not rebuild this path from
# $HOME: `agent-vm info` publishes it as state_dir=.
AGENT_VM_STATE_DIR="${AGENT_VM_STATE_DIR:-${HOME}/.agent-vm}"

# Directory holding the real agent-vm.sh, symlinks followed.
#
# `agent-vm install` puts a symlink on PATH (~/.local/bin/agent-vm -> <repo>/agent-vm.sh)
# so `agent-vm` works as an ordinary command. Without resolving the link, this
# would point at ~/.local/bin and `agent-vm setup` would fail to find
# agent-vm.setup.sh, which lives next to the real file.
#
# `readlink -f` would do it in one call but is GNU-only — macOS ships a readlink
# without it — so walk the chain by hand.
#
# `CDPATH=` because `dirname` can yield a bare relative path (running
# `bash sub/agent-vm.sh`). With CDPATH set, `cd <relative>` searches it before
# the current directory and prints where it landed, so without clearing it this
# would resolve the wrong directory and capture a stray line — leaving
# `agent-vm setup` unable to find agent-vm.setup.sh next to the real file.
_agent_vm_script_dir() {
  local src="${BASH_SOURCE[0]:-$0}" dir
  while [ -L "$src" ]; do
    dir="$(CDPATH= cd -P -- "$(dirname "$src")" >/dev/null && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;                  # absolute: use as-is
      *) src="$dir/$src" ;;   # relative: to the link's directory
    esac
  done
  (CDPATH= cd -P -- "$(dirname "$src")" >/dev/null && pwd)
}
AGENT_VM_SCRIPT_DIR="$(_agent_vm_script_dir)"

# Can a terminal actually be opened? `-r /dev/tty` does not answer that: the
# device node is world-readable even with no controlling terminal (CI, cron),
# and only opening it fails.
_agent_vm_have_tty() {
  ( exec </dev/tty ) 2>/dev/null
}

# Prompt for a value with a default. Reads from /dev/tty so this still works
# when called inside command substitution. Writes the prompt to stderr and the
# answer (or the default if the user just pressed Enter) to stdout.
#
# `2>/dev/null` comes before `</dev/tty` in every read below: redirections
# apply left to right, so the other order prints the open error first.
_agent_vm_ask() {
  local prompt="$1" default="$2" reply=""
  printf '  %s [%s]: ' "$prompt" "$default" >&2
  IFS= read -r reply 2>/dev/null </dev/tty || reply=""
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
  IFS= read -r reply 2>/dev/null </dev/tty || reply=""
  reply="${reply:-$default}"
  case "$reply" in
    [Yy]*) printf '1\n' ;;
    *)     printf '0\n' ;;
  esac
}

# _agent_vm_wrap <width> — word-wrap stdin to <width> columns. Lines indented
# by two spaces are commands, kept whole so they can be copied.
_agent_vm_wrap() {
  awk -v w="$1" '
    /^  / || length($0) <= w { print; next }
    {
      line = ""; n = split($0, word, " ")
      for (i = 1; i <= n; i++) {
        if (line == "") line = word[i]
        else if (length(line) + 1 + length(word[i]) <= w) line = line " " word[i]
        else { print line; line = word[i] }
      }
      print line
    }'
}

# _agent_vm_box <title> — print stdin on stderr as a boxed notice, for setup's
# warnings and offers: one paragraph per line, wrapped to the terminal (72
# columns at most). A question asked right after reads as being about the box.
# No right border: it would need every line padded to its display width, which
# bash and zsh count differently for non-ASCII text.
_agent_vm_box() {
  local title="$1" size width rule n
  size="$(stty size 2>/dev/null </dev/tty)"
  width="${size#* }"
  [[ "$width" =~ ^[0-9]+$ ]] || width=72
  [[ "$width" -gt 72 ]] && width=72
  [[ "$width" -lt 30 ]] && width=30
  rule="$(printf '%*s' "$width" '' | tr ' ' '-')"
  n=$((width - ${#title} - 4))
  [[ "$n" -lt 1 ]] && n=1
  {
    printf '\n+- %s %s\n|\n' "$title" "${rule:0:$n}"
    _agent_vm_wrap $((width - 2)) | sed 's/^/| /; s/ *$//'
    printf '|\n+%s\n' "${rule:0:$((width - 1))}"
  } >&2
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

# --- version ------------------------------------------------------------------
# _agent_vm_ver_ge <a> <b> — status 0 when version a >= b. Components compare
# one by one as base-10 numbers: a string comparison gets "1.10.0" < "1.9.0"
# wrong, and "08" must not be read as octal. Missing components count as 0, a
# "-rc1" suffix is ignored. No arrays: this file is also sourced by zsh.
_agent_vm_ver_ge() {
  local a="${1%%-*}" b="${2%%-*}" x y
  while [[ -n "$a" || -n "$b" ]]; do
    x="${a%%.*}"; y="${b%%.*}"
    if [[ "$a" == *.* ]]; then a="${a#*.}"; else a=""; fi
    if [[ "$b" == *.* ]]; then b="${b#*.}"; else b=""; fi
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    [[ "$x" -gt "$y" ]] && return 0
    [[ "$x" -lt "$y" ]] && return 1
  done
  return 0
}

# How this copy of agent-vm is updated: a git clone, a Homebrew keg, or a
# release put there by www.agent-vm.org/install.sh.
_agent_vm_update_command() {
  if [[ -e "$AGENT_VM_SCRIPT_DIR/.git" ]]; then
    printf 'git -C "%s" pull\n' "$AGENT_VM_SCRIPT_DIR"
  elif [[ "$AGENT_VM_SCRIPT_DIR" == */Cellar/agent-vm/* ]]; then
    echo "brew upgrade agent-vm"
  else
    echo "curl -fsSL https://www.agent-vm.org/install.sh | sh"
  fi
}

# `version` prints the version. `version --min X.Y.Z` turns it into a check an
# integrator can put in front of everything else: silent with status 0 when
# this engine is recent enough, one actionable line on stderr and status 1
# when it is not.
#
# Status 2 is reserved for a malformed call. A typo in the required version
# must not read as "engine too old" and send a user chasing an upgrade they
# don't need.
#
# Known limit, and the reason this can't be the only check an integrator has:
# an engine older than the one that introduced --min ignores the flag, prints
# its version and exits 0. A tool whose floor is below that version still
# needs its own comparison for the bootstrap check.
_agent_vm_version() {
  if [[ $# -eq 0 ]]; then
    echo "$AGENT_VM_VERSION"
    return 0
  fi

  local want=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --min)
        if [[ $# -lt 2 ]]; then
          echo "Error: --min needs a version (e.g. --min 0.2.0)" >&2
          return 2
        fi
        want="$2"; shift 2 ;;
      --min=*)
        want="${1#*=}"; shift ;;
      *)
        echo "Error: unknown option for version: $1" >&2
        return 2 ;;
    esac
  done

  if [[ ! "$want" =~ ^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9.]+)?$ ]]; then
    echo "Error: --min expects a version like 1.2.3 (got: '$want')" >&2
    return 2
  fi

  _agent_vm_ver_ge "$AGENT_VM_VERSION" "$want" && return 0

  echo "Error: agent-vm $AGENT_VM_VERSION is older than the required $want." >&2
  echo "  Update it:  $(_agent_vm_update_command)" >&2
  return 1
}

# --- runtime scripts ----------------------------------------------------------
# Interpreter a runtime script asks for, read from its shebang: bash, sh or
# zsh. Anything else — another language, or no shebang at all — falls back to
# zsh, which is what every runtime script got before this existed.
#
# Only shells are honoured because the script is fed on stdin, and `-s` (read
# the program from stdin) is a shell convention. A python runtime piped into
# zsh was already broken; it stays broken, loudly, rather than being executed
# by the wrong thing in a new way.
_agent_vm_runtime_interpreter() {
  local first
  IFS= read -r first < "$1" || true
  case "$first" in
    '#!'*) ;;
    *) printf 'zsh\n'; return 0 ;;
  esac
  # Last word of the shebang covers both "#!/bin/bash" and "#!/usr/bin/env bash".
  local last="${first##* }"
  case "${last##*/}" in
    bash) printf 'bash\n' ;;
    sh)   printf 'sh\n' ;;
    *)    printf 'zsh\n' ;;
  esac
}

# Where this project's runtime script lives.
#
# AGENT_VM_PROJECT_RUNTIME lets an integrator keep it in its own directory
# (".mytool/runtime.sh") instead of cluttering the project root. A relative
# path is resolved against the project directory; an absolute one is used
# as-is. Unset, the historical location applies, so nothing changes for anyone
# who never heard of the variable.
_agent_vm_project_runtime_path() {
  local host_dir="$1" rel="${AGENT_VM_PROJECT_RUNTIME:-.agent-vm.runtime.sh}"
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s\n' "${host_dir}/${rel}" ;;
  esac
}

# Run a runtime script inside the VM, with the interpreter it declares.
#
# It goes through a login zsh first, so the script sees the VM's PATH and the
# auto-sourced ~/.agent-vm.env, then execs the declared shell. Before this,
# every runtime ran under zsh whatever its shebang said: a script starting
# with `#!/usr/bin/env bash` silently got zsh's arrays and globbing, which
# differ where it matters.
#
# The script is still piped rather than executed by path: the per-user runtime
# lives in ~/.agent-vm on the host and is not mounted inside the VM, so its
# path means nothing there. One transport for both runtimes beats two.
_agent_vm_run_runtime() {
  local vm_name="$1" host_dir="$2" file="$3" interp
  interp="$(_agent_vm_runtime_interpreter "$file")"
  limactl shell --workdir "$host_dir" "$vm_name" zsh -lc "exec $interp -s" < "$file"
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
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-mounts-${vm_name}"
  rm -rf "$AGENT_VM_STATE_DIR/file-mounts/${vm_name}"
  # Deleting the template retires the marker that says it is usable.
  if [[ "$vm_name" == "$AGENT_VM_TEMPLATE" ]]; then
    rm -f "$AGENT_VM_STATE_DIR/.agent-vm-base-version"
  fi
}

# Build the .mounts JSON array for a VM. The first entry is always the project
# dir; $3 ("true"/"false", default "true") decides whether it is writable.
# Additional entries come from ~/.agent-vm/volumes, parsed as Docker-Compose-ish
# `source[:destination][:mode]` (mode ∈ {ro,rw}, default ro).
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
  local mounts_json="[{\"location\": \"${host_dir}\", \"writable\": ${project_writable}${sshfs}}"
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
        mounts_json+=", {\"location\": \"${file_staging_dir}\", \"mountPoint\": \"${staging_mount}\", \"writable\": false${sshfs}}"
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
      if [[ -n "$dst" ]]; then
        mounts_json+=", {\"location\": \"${src}\", \"mountPoint\": \"${dst}\", \"writable\": ${writable}${sshfs}}"
      else
        mounts_json+=", {\"location\": \"${src}\", \"writable\": ${writable}${sshfs}}"
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

# Current resources of <vm_name> as "cpus|memory_gib|disk_gib".
# Prints nothing (and returns 1) when the VM is unknown to Lima. No pipe into
# grep/head: see _agent_vm_has_line for why that is unsafe under pipefail.
_agent_vm_resources() {
  local vm_name="$1" all line
  all="$(limactl list --format '{{.Name}}|{{.CPUs}}|{{.Memory}}|{{.Disk}}' 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      "${vm_name}|"*)
        local cpus mem_bytes disk_bytes
        IFS='|' read -r _ cpus mem_bytes disk_bytes <<< "$line"
        printf '%s|%s|%s\n' "$cpus" "$((mem_bytes / 1073741824))" "$((disk_bytes / 1073741824))"
        return 0 ;;
    esac
  done <<< "$all"
  return 1
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
# Disk is compared one-way on purpose: Lima can grow a disk but not shrink it,
# so a request below the current size is not a change that stopping could apply.
#
# Both sides are integer GiB, so a VM whose memory is not a whole number of GiB
# can still compare unequal every time. That is the pre-existing behaviour
# (prompt on every call), not a new failure mode.
_agent_vm_resources_differ() {
  local vm_name="$1" want_cpus="$2" want_mem="$3" want_disk="$4"
  local cur cur_cpus cur_mem cur_disk
  if ! cur="$(_agent_vm_resources "$vm_name")"; then
    return 0
  fi
  IFS='|' read -r cur_cpus cur_mem cur_disk <<< "$cur"
  if [[ -n "$want_cpus" && "$want_cpus" != "$cur_cpus" ]]; then
    return 0
  fi
  if [[ -n "$want_mem" && "$want_mem" != "$cur_mem" ]]; then
    return 0
  fi
  if [[ -n "$want_disk" && "$want_disk" -gt "$cur_disk" ]]; then
    return 0
  fi
  return 1
}

# Ensure the VM for cwd exists and is running, creating/starting as needed
# Usage: _agent_vm_ensure_running <vm_name> <host_dir> [--disk GB] [--memory GB] [--reset]
_agent_vm_ensure_running() {
  local vm_name="$1"
  local host_dir="$2"
  shift 2
  local disk="" memory="" cpus="" reset="" rdonly="" _agent_vm_unsafe_git_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     disk="$2"; shift 2 ;;
      --memory|--ram)   memory="$2"; shift 2 ;;
      --cpus)     cpus="$2"; shift 2 ;;
      --reset)    reset=1; shift ;;
      --readonly) rdonly=1; shift ;;
      --unsafe-writable-git) _agent_vm_unsafe_git_flag=1; shift ;;
      *)          shift ;;
    esac
  done

  # The project mount's mode is decided once, here, so the create path bakes it
  # into the new VM's config instead of creating it writable and immediately
  # restarting it to flip the flag.
  local want_writable="true"
  [[ -n "$rdonly" ]] && want_writable="false"

  # Clamp to this host's share once, here: every path below (create, edit,
  # resource comparison) then sees the values that will actually be applied.
  cpus="$(_agent_vm_cap_resource cpus "$cpus")"
  memory="$(_agent_vm_cap_resource memory "$memory")"
  _agent_vm_warn_disk_space "$disk"

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

  # The path is spliced into the mounts JSON handed to `limactl edit --set`,
  # which is a yq expression. A quote or a backslash in a directory name would
  # end the string and let the name add mounts of its own (the home directory,
  # read-write) or undo --readonly. Same rule as ~/.agent-vm/volumes entries.
  if [[ "$host_dir" == *[\"\\]* || "$host_dir" == *[[:cntrl:]]* ]]; then
    echo "Error: project path contains a quote, a backslash or a control character:" >&2
    echo "  $host_dir" >&2
    echo "Rename the directory, then retry." >&2
    return 1
  fi

  # Recover from an interrupted previous run that left ~/.lima/<vm>/ without
  # a lima.yaml — otherwise every limactl call on this name aborts with a
  # cryptic "no such file or directory".
  _agent_vm_clean_partial_state "$vm_name"

  if ! _agent_vm_base_exists; then
    # Distinguish "never set up" from "setup died halfway": the second one
    # leaves a template that looks fine in `limactl list` but is empty.
    if _agent_vm_exists "$AGENT_VM_TEMPLATE"; then
      echo "Error: Base VM setup did not complete. Run 'agent-vm setup' again." >&2
    else
      echo "Error: Base VM not found. Run 'agent-vm setup' first." >&2
    fi
    return 1
  fi

  # Every .git read-only for the guest, when this Lima can enforce it and it
  # was not turned off. Asked once here: the mounts built below, on every
  # path, follow the answer.
  local protect_git=""
  if _agent_vm_writable_git_optout; then
    _agent_vm_writable_git_warning >&2
  elif _agent_vm_lima_protects_git; then
    protect_git=1
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
    mounts_json=$(_agent_vm_build_mounts_json "$vm_name" "$host_dir" "$want_writable" "$protect_git")
    local edit_args=()
    edit_args+=(--set "$(_agent_vm_mounts_expr "$mounts_json" "$protect_git")")
    [[ -n "$memory" ]] && edit_args+=(--memory "$memory")
    [[ -n "$cpus" ]]   && edit_args+=(--cpus "$cpus")
    if (cd /tmp && limactl edit "$vm_name" ${edit_args[@]+"${edit_args[@]}"}) &>/dev/null; then
      _agent_vm_record_mounts "$vm_name" "$mounts_json"
    fi
    if [[ -n "$disk" ]]; then
      if ! (cd /tmp && limactl edit "$vm_name" --disk "$disk") &>/dev/null; then
        echo "Warning: Cannot set disk to ${disk} GiB (shrinking is not supported). Re-run 'agent-vm setup --disk ${disk}' for a smaller base." >&2
      fi
    fi
    # Resources are printed by the caller, once the VM is up.
    # Record which base version this VM was cloned from
    local base_ver="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
    if [[ -f "$base_ver" ]]; then
      cp "$base_ver" "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
    fi
  elif [[ -n "$disk" || -n "$memory" || -n "$cpus" ]] \
       && _agent_vm_resources_differ "$vm_name" "$cpus" "$memory" "$disk"; then
    # Resize the existing VM, but only when the request actually differs from
    # what the VM already has. Prompting on the mere *presence* of a resource
    # flag means every caller that passes its defaults on each invocation gets
    # "Stop the VM and apply changes?" forever, for a no-op.
    if _agent_vm_running "$vm_name"; then
      echo "VM '$vm_name' is currently running. It must be stopped to apply new resource settings."
      printf "Stop the VM and apply changes? [y/N] " >&2
      local reply=""
      IFS= read -r reply 2>/dev/null </dev/tty || reply=""
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
    # Only call limactl when there is something to set: `limactl edit <vm>` with
    # no flags drops into $EDITOR, which would hang a non-interactive caller
    # that passed --disk on its own.
    if [[ ${#edit_args[@]} -gt 0 ]]; then
      local edit_output
      if ! edit_output=$(cd /tmp && limactl edit "$vm_name" "${edit_args[@]}" 2>&1); then
        echo "Error: Failed to update VM resources:" >&2
        echo "$edit_output" >&2
        return 1
      fi
    fi
    if [[ -n "$disk" ]]; then
      if ! edit_output=$(cd /tmp && limactl edit "$vm_name" --disk "$disk" 2>&1); then
        echo "Warning: Cannot set disk to ${disk} GiB (shrinking is not supported). Re-run 'agent-vm setup --disk ${disk}' for a smaller base." >&2
      fi
    fi
  fi

  # Warn if this VM was cloned from an older base. `agent-vm info` exposes the
  # same verdict as vm_stale= so integrators can ask before starting instead of
  # reading this warning after the fact.
  if [[ "$(_agent_vm_stale_state "$vm_name")" == "1" ]]; then
    echo "Warning: Base VM has been updated since this VM was cloned. Use --reset to re-clone from the new base." >&2
  fi

  # Whether someone else was already using this VM, captured BEFORE we start it.
  # Asking the question after the `limactl start` below would always answer
  # "yes", since we would be the ones who started it.
  local was_running=""
  _agent_vm_running "$vm_name" && was_running=1

  # A VM whose shares were set up for another Lima or another opt-out setting:
  # .git writable while it should be protected, or reverse-sshfs while it
  # should not (see _agent_vm_mounts_expr). The shares only change on a
  # stopped VM, so before starting it. A running one keeps what it has until
  # it stops.
  local was_protected=""
  _agent_vm_mounts_protect_git "$vm_name" && was_protected=1
  if [[ "$was_protected" != "$protect_git" ]]; then
    if [[ -n "$was_running" ]]; then
      if [[ -n "$protect_git" ]]; then
        echo "Warning: VM '$vm_name' is running with .git writable, so the agent can still write .git. 'agent-vm stop', then run again." >&2
      elif _agent_vm_writable_git_optout; then
        echo "Note: VM '$vm_name' keeps .git read-only until it stops." >&2
      else
        echo "Warning: this Lima cannot keep .git read-only; VM '$vm_name' keeps its current shares until it stops." >&2
      fi
    else
      # Names of their own: zsh prints a local declared twice in one function.
      local shares_json shares_out
      if [[ -n "$protect_git" ]]; then
        echo "Making every .git read-only for VM '$vm_name'..."
      elif _agent_vm_writable_git_optout; then
        echo "Making .git writable for VM '$vm_name' ($(_agent_vm_writable_git_why))..." >&2
      else
        echo "Warning: this Lima cannot keep .git read-only; VM '$vm_name' goes back to Lima's default mount type." >&2
      fi
      shares_json=$(_agent_vm_build_mounts_json "$vm_name" "$host_dir" "$want_writable" "$protect_git")
      if ! shares_out=$(cd /tmp && limactl edit "$vm_name" \
        --set "$(_agent_vm_mounts_expr "$shares_json" "$protect_git")" 2>&1); then
        echo "Error: could not change the shares of '$vm_name':" >&2
        echo "$shares_out" >&2
        return 1
      fi
      _agent_vm_record_mounts "$vm_name" "$shares_json"
    fi
  fi

  if [[ -z "$was_running" ]]; then
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

  # Reconcile the project mount with the mode that was asked for. This is one
  # step and not two because the two directions share a mechanism: the mount
  # mode lives in the Lima config, so changing it means stop, edit, start.
  #
  #   want writable, is not  -> a stale or silently-failed mount. Left alone it
  #                             leaves a bare, root-owned mountpoint and every
  #                             later write fails with a cascade of "Permission
  #                             denied" instead of one clear error. Self-heal.
  #   want read-only, is not -> --readonly was passed. Re-mount it read-only on
  #                             the host side, where the guest cannot undo it.
  #   want writable, is read-only -> a previous --readonly session. Restore.
  #
  # --readonly covers every share, not only the project. The write probe only
  # sees the project, so for the others this relies on the mounts the VM was
  # last given. A VM with no record (created before they were recorded) is
  # treated as having a writable share: one extra restart, never a silent gap.
  #
  # On the common path both agree and nothing happens.
  # The env push rides along with the first probe: see
  # _agent_vm_push_env_and_probe. The file is on the VM's disk, so a restart
  # below keeps it.
  local is_writable="false" probe_out
  probe_out="$(_agent_vm_push_env_and_probe "$vm_name" "$host_dir" "$(_agent_vm_env_payload "$host_dir")")" \
    && is_writable="true"
  [[ "$probe_out" == *env-ok* ]] || echo "Warning: failed to push the env files into VM '$vm_name'." >&2
  local needs_remount=""
  [[ "$is_writable" != "$want_writable" ]] && needs_remount=1
  if [[ "$want_writable" == "false" ]] && ! _agent_vm_mounts_all_readonly "$vm_name"; then
    needs_remount=1
  fi

  if [[ -n "$needs_remount" ]]; then
    # Stopping kills whatever else is using this VM, so ask first rather than
    # yanking a running session out from under another terminal. The repair
    # direction does not ask: a broken mount is already unusable.
    if [[ "$want_writable" == "false" ]] && [[ -n "$was_running" ]]; then
      echo "VM '$vm_name' was already running. It must be restarted to make its shares read-only."
      printf "Stop the VM and apply --readonly? [y/N] " >&2
      local ro_reply=""
      IFS= read -r ro_reply 2>/dev/null </dev/tty || ro_reply=""
      if [[ ! "$ro_reply" =~ ^[Yy]$ ]]; then
        # Not "continue with current settings" like the resize path does:
        # carrying on writable after --readonly was asked for is the one
        # outcome that must not be silent.
        echo "Error: --readonly was requested but not applied. Aborting." >&2
        return 1
      fi
    elif [[ "$want_writable" == "true" ]] && _agent_vm_mounts_all_readonly "$vm_name"; then
      echo "VM '$vm_name' was left read-only by --readonly; making it writable again..."
    elif [[ "$want_writable" == "true" ]]; then
      echo "Project mount is not writable; repairing..." >&2
    fi

    limactl stop "$vm_name" &>/dev/null
    # Rebuild the full mounts JSON so any ~/.agent-vm/volumes entries are
    # preserved (a plain project-dir-only set would silently drop them).
    local reconcile_mounts_json
    reconcile_mounts_json=$(_agent_vm_build_mounts_json "$vm_name" "$host_dir" "$want_writable" "$protect_git")
    local edit_out
    if ! edit_out=$(cd /tmp && limactl edit "$vm_name" \
      --set "$(_agent_vm_mounts_expr "$reconcile_mounts_json" "$protect_git")" 2>&1); then
      # Swallowing this left the caller with "failed" and no reason, which is
      # the one thing a security flag must not do.
      echo "Error: could not change the mount mode on '$vm_name':" >&2
      echo "$edit_out" >&2
      return 1
    fi
    _agent_vm_record_mounts "$vm_name" "$reconcile_mounts_json"
    if ! limactl start "$vm_name" &>/dev/null; then
      # Checked, because the verification below cannot tell a dead VM from a
      # successfully read-only one: both answer "not writable".
      echo "Error: VM '$vm_name' did not come back up after changing the project mount." >&2
      return 1
    fi

    is_writable="false"
    _agent_vm_project_writable "$vm_name" "$host_dir" && is_writable="true"
    if [[ "$is_writable" != "$want_writable" ]]; then
      if [[ "$want_writable" == "true" ]]; then
        echo "Error: project directory is still not writable inside the VM:" >&2
        echo "  $host_dir" >&2
        echo "The host mount failed to attach. Try 'agent-vm --reset <command>'" >&2
        echo "to re-clone the VM from the base template." >&2
      else
        echo "Error: failed to mount the project directory read-only:" >&2
        echo "  $host_dir" >&2
      fi
      return 1
    fi
  fi

  # Under reverse-sshfs without readonlyNames the flag reaches the guest's sshfs
  # and nothing else, so refuse rather than report a restriction that root in
  # the VM can lift. "Could not tell" is refused too: the caller asked for a
  # boundary, and the only honest answers are "it is there" or an error.
  if [[ -n "$rdonly" ]]; then
    _agent_vm_mount_is_host_enforced "$vm_name" "$host_dir"
    case $? in
      0) echo "Read-only: the project and every other share (enforced on the host)." ;;
      1) echo "Error: --readonly cannot be enforced with this mount type." >&2
         echo "  Lima only applies it inside the guest for reverse-sshfs (without" >&2
         echo "  readonlyNames) and for virtiofs under QEMU, where root in the VM" >&2
         echo "  can remount it read-write. Use virtiofs on vz, or 9p on QEMU (both" >&2
         echo "  enforce it on the host), in your Lima config, then --reset." >&2
         return 1 ;;
      *) echo "Error: could not determine the project mount type, so --readonly" >&2
         echo "  cannot be confirmed as enforced outside the VM. Aborting." >&2
         return 1 ;;
    esac
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

  # Run per-user runtime script if it exists
  if [ -f "$AGENT_VM_STATE_DIR/runtime.sh" ]; then
    echo "Running user runtime setup..."
    _agent_vm_run_runtime "$vm_name" "$host_dir" "$AGENT_VM_STATE_DIR/runtime.sh"
  fi

  # Run project-specific runtime script if it exists.
  local project_runtime
  project_runtime="$(_agent_vm_project_runtime_path "$host_dir")"
  if [ -f "$project_runtime" ]; then
    echo "Running project runtime setup..."
    _agent_vm_run_runtime "$vm_name" "$host_dir" "$project_runtime"
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
    if [[ -z "$is_new_vm" ]] && [[ ${#file_mount_entries[@]} -gt 0 ]]; then
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
  # Parse global options before the subcommand.
  #
  # Resource values are validated here, as `setup` already does for its own
  # flags. Without it a typo like `--disk 10G` travels all the way into the
  # resource comparison and surfaces as a raw bash diagnostic
  # ("[[: 10G: value too great for base") before anything actionable is said.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)
        _agent_vm_validate_int --disk "$2" || return 1
        vm_opts+=(--disk "$2"); shift 2 ;;
      --disk=*)
        _agent_vm_validate_int --disk "${1#*=}" || return 1
        vm_opts+=(--disk "${1#*=}"); shift ;;
      --memory|--ram)
        _agent_vm_validate_int --memory "$2" || return 1
        vm_opts+=(--memory "$2"); shift 2 ;;
      --memory=*|--ram=*)
        _agent_vm_validate_int --memory "${1#*=}" || return 1
        vm_opts+=(--memory "${1#*=}"); shift ;;
      --cpus)
        _agent_vm_validate_int --cpus "$2" || return 1
        vm_opts+=(--cpus "$2"); shift 2 ;;
      --cpus=*)
        _agent_vm_validate_int --cpus "${1#*=}" || return 1
        vm_opts+=(--cpus "${1#*=}"); shift ;;
      --reset)
        vm_opts+=(--reset); shift ;;
      --readonly)
        vm_opts+=(--readonly); shift ;;
      --unsafe-writable-git|--unsafe-writable-git=1)
        vm_opts+=(--unsafe-writable-git); shift ;;
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
    help|--help|-h|setup|version|--version|-V|name|info|env|project-env|doctor|install|uninstall) ;;
    *)
      if ! command -v limactl &>/dev/null; then
        echo "Error: limactl (Lima) not found. Run 'agent-vm setup' first, or install" >&2
        echo "it from https://lima-vm.io/docs/installation/" >&2
        return 1
      fi ;;
  esac

  case "$cmd" in
    setup)
      _agent_vm_setup ${vm_opts[@]+"${vm_opts[@]}"} "$@"
      ;;
    claude)
      _agent_vm_claude ${vm_opts[@]+"${vm_opts[@]}"} "$@"
      ;;
    opencode)
      _agent_vm_opencode ${vm_opts[@]+"${vm_opts[@]}"} "$@"
      ;;
    codex)
      _agent_vm_codex ${vm_opts[@]+"${vm_opts[@]}"} "$@"
      ;;
    vibe)
      _agent_vm_vibe ${vm_opts[@]+"${vm_opts[@]}"} "$@"
      ;;
    pi)
      _agent_vm_pi ${vm_opts[@]+"${vm_opts[@]}"} "$@"
      ;;
    shell|sh)
      _agent_vm_shell ${vm_opts[@]+"${vm_opts[@]}"} "$@"
      ;;
    run)
      _agent_vm_run ${vm_opts[@]+"${vm_opts[@]}"} "$@"
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
    name)
      local name_dir
      name_dir="$(_agent_vm_abs_dir "${1:-}")" || return 1
      _agent_vm_name "$name_dir"
      ;;
    info)
      local info_dir
      info_dir="$(_agent_vm_abs_dir "${1:-}")" || return 1
      _agent_vm_info "$info_dir"
      ;;
    env)
      _agent_vm_env env "$AGENT_VM_STATE_DIR/env" "$@"
      ;;
    project-env)
      local project_env_file
      project_env_file="$(_agent_vm_project_env_file)"
      _agent_vm_env project-env "$project_env_file" "$@" || return $?
      # Only after a write, and only if it worked: that is when the file is
      # new to the repository and when the user is looking.
      if [ "${1:-}" = "set" ]; then
        _agent_vm_warn_unignored "$project_env_file"
      fi
      ;;
    version|--version|-V)
      _agent_vm_version "$@"
      ;;
    doctor)
      if [[ $# -gt 0 ]]; then
        echo "Usage: agent-vm doctor" >&2
        return 2
      fi
      _agent_vm_doctor
      ;;
    install)
      _agent_vm_install "$@"
      ;;
    uninstall)
      _agent_vm_uninstall "$@"
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

# --- install / uninstall: agent-vm on the PATH ----------------------------------
# `install` puts agent-vm on the PATH as a symlink to agent-vm.sh in the clone:
# the script dispatches when executed, so a link is all a command needs, and
# `git pull` updates it. It then offers to source agent-vm.sh from the shell
# rc, which also defines agent-vm as a shell function. Safe to re-run.
# AGENT_VM_BIN_DIR picks the directory (default ~/.local/bin).

_agent_vm_bin_link() {
  printf '%s/agent-vm\n' "${AGENT_VM_BIN_DIR:-$HOME/.local/bin}"
}

# The rc file where a shell function belongs: the interactive one.
_agent_vm_rc_file() {
  case "${SHELL##*/}" in
    zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    bash)
      case "$(uname -s)" in
        Darwin) printf '%s\n' "$HOME/.bash_profile" ;;
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
  if [[ -L "$link" && "$(readlink "$link")" == "$script" ]]; then
    echo "agent-vm is already linked at $link"
  elif [[ -e "$link" || -L "$link" ]]; then
    # -L too: a dangling link is not -e, and ln would fail on it.
    echo "Error: $link already exists and is not a link to $script." >&2
    echo "  Move it aside, or set AGENT_VM_BIN_DIR to another directory." >&2
    return 1
  else
    ln -s "$script" "$link" || return 1
    echo "Linked $link -> $script"
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
  if [[ -L "$link" && "$(readlink "$link")" == "$script" ]]; then
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

# Machine-readable state, one key=value per line. This is the supported way for
# another tool to ask what agent-vm knows, instead of reverse-engineering VM
# naming, the template name, or the state-dir version markers — all of which
# are internal and free to change.
#
# Keys: version, template, state_dir, project_env, dir, vm_name, base_exists,
# vm_exists, vm_running, vm_stale. Booleans are 1/0; anything that cannot be
# determined is "unknown" rather than a guess.
_agent_vm_info() {
  local dir="${1:-$(pwd)}"
  local vm_name
  vm_name="$(_agent_vm_name "$dir")" || return 1

  echo "version=$AGENT_VM_VERSION"
  echo "template=$AGENT_VM_TEMPLATE"
  echo "state_dir=$AGENT_VM_STATE_DIR"
  echo "project_env=$(_agent_vm_project_env_file "$dir")"
  echo "dir=$dir"
  echo "vm_name=$vm_name"

  if ! command -v limactl &>/dev/null; then
    # Still useful without Lima: the static keys above answer "what would this
    # VM be called", which is all a caller needs before setup has ever run.
    echo "base_exists=unknown"
    echo "vm_exists=unknown"
    echo "vm_running=unknown"
    echo "vm_stale=unknown"
    return 0
  fi

  # Keep the three-way answer from the query helpers: a failed query reports
  # `unknown`, never a confident 0. A caller told `base_exists=0` when the truth
  # was "could not ask" would offer to build a base VM that already exists.
  local base_exists vm_exists vm_running
  _agent_vm_base_exists;        base_exists="$(_agent_vm_tristate $?)"
  _agent_vm_exists "$vm_name";  vm_exists="$(_agent_vm_tristate $?)"
  _agent_vm_running "$vm_name"; vm_running="$(_agent_vm_tristate $?)"
  echo "base_exists=$base_exists"
  echo "vm_exists=$vm_exists"
  echo "vm_running=$vm_running"
  # Staleness compares this VM against the base it was cloned from; with no VM
  # (or no way to tell) there is nothing to compare.
  if [[ "$vm_exists" == "1" ]]; then
    echo "vm_stale=$(_agent_vm_stale_state "$vm_name")"
  else
    echo "vm_stale=unknown"
  fi
}

# --- doctor -------------------------------------------------------------------
# Checks the host, Lima, the base template and the current directory, and says
# what to do about each problem. Read-only: it never creates, starts or stops
# a VM, so it is safe to run first and to paste into an issue (no secret
# values, only names). Exit 1 when a check failed, 0 otherwise.

_agent_vm_doctor_line() {
  # <ok|warn|fail|info> <message> [hint...]
  local level="$1" msg="$2"
  shift 2
  case "$level" in
    ok)   printf '  ok    %s\n' "$msg" ;;
    warn) printf '  warn  %s\n' "$msg"; AGENT_VM_DOCTOR_WARN=$((AGENT_VM_DOCTOR_WARN + 1)) ;;
    fail) printf '  FAIL  %s\n' "$msg"; AGENT_VM_DOCTOR_FAIL=$((AGENT_VM_DOCTOR_FAIL + 1)) ;;
    *)    printf '  -     %s\n' "$msg" ;;
  esac
  while [[ $# -gt 0 ]]; do
    printf '        %s\n' "$1"
    shift
  done
}

_agent_vm_doctor() {
  # Local, and still visible to _agent_vm_doctor_line: bash and zsh both scope
  # locals dynamically, so the helper updates these and nothing leaks.
  local AGENT_VM_DOCTOR_WARN=0 AGENT_VM_DOCTOR_FAIL=0
  local d=_agent_vm_doctor_line

  echo "agent-vm doctor"
  echo ""
  echo "agent-vm"
  $d info "version $AGENT_VM_VERSION, from $AGENT_VM_SCRIPT_DIR"
  if [[ ! -r "$AGENT_VM_SCRIPT_DIR/agent-vm.setup.sh" ]]; then
    $d fail "agent-vm.setup.sh is missing next to agent-vm.sh" \
      "'agent-vm setup' needs it. Reinstall, or run agent-vm from its clone."
  fi
  if _agent_vm_sha256 </dev/null >/dev/null 2>&1; then
    $d ok "SHA-256 tool available (VM names)"
  else
    $d fail "neither shasum nor sha256sum is installed" \
      "VM names hash the project path. Install perl (shasum) or coreutils (sha256sum)."
  fi

  echo ""
  echo "Host"
  $d info "$(uname -sm)"
  local cpus mem avail_kib
  cpus="$(_agent_vm_host_cpus)"
  mem="$(_agent_vm_host_mem_gib)"
  if [[ -n "$cpus" && -n "$mem" ]]; then
    $d info "${cpus} CPUs, ${mem} GiB RAM; a VM gets at most $(_agent_vm_host_share "$cpus" 1) CPUs and $(_agent_vm_host_share "$mem" 2) GiB (AGENT_VM_HOST_SHARE=$AGENT_VM_HOST_SHARE)"
  else
    $d warn "could not read the host's CPU or RAM: --cpus and --memory are not clamped"
  fi
  avail_kib=$(df -Pk "${LIMA_HOME:-$HOME}" 2>/dev/null | awk 'NR==2 {print $4}')
  case "$avail_kib" in
    ''|*[!0-9]*) $d warn "could not read the free disk space" ;;
    *)
      if [[ $((avail_kib / 1048576)) -lt 10 ]]; then
        $d warn "$((avail_kib / 1048576)) GiB free for Lima's VMs" "A default VM disk is 10 GiB (sparse)."
      else
        $d ok "$((avail_kib / 1048576)) GiB free for Lima's VMs"
      fi ;;
  esac

  echo ""
  echo "Lima"
  local have_lima=""
  if command -v limactl >/dev/null 2>&1; then
    have_lima=1
    local lima_ver
    lima_ver="$(limactl --version 2>/dev/null)"
    lima_ver="${lima_ver##* }"
    if [[ -z "$lima_ver" ]]; then
      $d warn "limactl is installed but did not report a version"
    elif ! _agent_vm_ver_ge "$lima_ver" 1.0.0; then
      $d warn "Lima $lima_ver is older than 1.0" \
        "Before 1.0 the default mount type can be reverse-sshfs, where --readonly is refused."
    else
      $d ok "Lima $lima_ver"
    fi
    if _agent_vm_lima_protects_git; then
      $d ok "Lima keeps every .git read-only for the VMs (sshfs.readonlyNames)"
    else
      $d warn "this Lima cannot keep .git read-only for the VMs"
      _agent_vm_git_protection_hint | _agent_vm_wrap 70 | sed 's/^/        /'
    fi
    if _agent_vm_writable_git_optout; then
      $d warn "AGENT_VM_UNSAFE_WRITABLE_GIT=1: the VMs can write .git, and git on this machine runs what .git/config and hooks name" \
        "Unset it to keep .git read-only."
    fi
  else
    $d fail "Lima is not installed" "Install it from https://lima-vm.io/docs/installation/ (or 'brew install $AGENT_VM_LIMA_FORMULA')."
  fi
  if [[ "$(uname -s)" == "Linux" ]]; then
    local prereq_out
    if prereq_out="$(_agent_vm_check_linux_prereqs 2>&1)"; then
      $d ok "QEMU and /dev/kvm are usable"
    else
      $d fail "QEMU or KVM is not usable"
      printf '%s\n' "$prereq_out" | sed 's/^/        /'
    fi
  fi

  # A bare repository is not named .git, so readonlyNames does not cover one
  # the VM plants in a project (see _agent_vm_bare_repo_state).
  local bare_state
  bare_state="$(_agent_vm_bare_repo_state)"
  if [[ "$bare_state" != "nogit" ]]; then
    echo ""
    echo "Git on this machine"
    case "$bare_state" in
      ok) $d ok "safe.bareRepository = explicit" ;;
      old) $d warn "$(git --version) is older than 2.38: it would use a repository a VM creates under another name than .git, and run what its config names" \
             "Upgrade git, then: git config --global safe.bareRepository explicit" ;;
      *) $d warn "safe.bareRepository is not 'explicit': git would use a repository a VM creates under another name than .git, and run what its config names" \
           "git config --global safe.bareRepository explicit" ;;
    esac
  fi

  echo ""
  echo "Base template"
  local st=0
  if [[ -z "$have_lima" ]]; then
    $d info "not checked (see above)"
  else
    _agent_vm_base_exists || st=$?
    case "$st" in
      0)
        local built age
        built="$(cat "$AGENT_VM_STATE_DIR/.agent-vm-base-version" 2>/dev/null)"
        if [[ "$built" =~ ^[0-9]+$ ]]; then
          age=$(( ($(date +%s) - built) / 86400 ))
          $d ok "$AGENT_VM_TEMPLATE is ready, built $age day(s) ago"
          if [[ "$age" -gt 90 ]]; then
            $d warn "the base template is over 90 days old" \
              "Its agents and packages are as old. 'agent-vm setup' rebuilds it."
          fi
        else
          $d ok "$AGENT_VM_TEMPLATE is ready"
        fi ;;
      1)
        if _agent_vm_exists "$AGENT_VM_TEMPLATE"; then
          $d fail "$AGENT_VM_TEMPLATE exists but its setup did not complete" "Run 'agent-vm setup' again."
        else
          $d fail "no base template yet" "Run 'agent-vm setup'."
        fi ;;
      *) $d warn "could not query Lima" ;;
    esac
  fi

  echo ""
  echo "Settings ($AGENT_VM_STATE_DIR)"
  local f
  if [[ -f "$AGENT_VM_STATE_DIR/env" ]]; then
    if [[ "$(ls -ld "$AGENT_VM_STATE_DIR/env" 2>/dev/null)" == -rw-------* ]]; then
      $d ok "env: $(_agent_vm_env env "$AGENT_VM_STATE_DIR/env" list | wc -l | tr -d ' ') key(s), mode 600"
    else
      $d warn "env is readable by other users on this machine" "chmod 600 '$AGENT_VM_STATE_DIR/env'"
    fi
  else
    $d info "env: none (agent-vm env set KEY VALUE)"
  fi
  for f in volumes setup.sh runtime.sh; do
    [[ -f "$AGENT_VM_STATE_DIR/$f" ]] && $d info "$f: present"
  done

  echo ""
  local host_dir vm_name
  host_dir="$(pwd)"
  echo "This directory ($host_dir)"
  if [[ "$host_dir" == *[[:space:]]* || "$host_dir" == *[\"\\]* || "$host_dir" == *[[:cntrl:]]* ]]; then
    $d fail "the path contains whitespace, a quote, a backslash or a control character" \
      "agent-vm refuses to mount it. Rename the directory."
  fi
  if vm_name="$(_agent_vm_name "$host_dir" 2>/dev/null)"; then
    if [[ -z "$have_lima" ]]; then
      $d info "VM name: $vm_name"
    else
      st=0
      _agent_vm_exists "$vm_name" || st=$?
      case "$st" in
        0)
          if [[ "$(_agent_vm_stale_state "$vm_name")" == "1" ]]; then
            $d warn "$vm_name was cloned from an older base template" "'agent-vm --reset <command>' re-clones it."
          else
            $d ok "$vm_name exists"
          fi
          if _agent_vm_running "$vm_name"; then
            local mst=0
            _agent_vm_mount_is_host_enforced "$vm_name" "$host_dir" || mst=$?
            case "$mst" in
              0) $d ok "running; the project share is enforced on the host (--readonly works)" ;;
              1) $d warn "running; the host does not enforce read-only on the project share, so --readonly is refused" \
                   "Use virtiofs on vz or 9p on QEMU, then --reset." ;;
              *) $d warn "running, but the project mount type could not be read" ;;
            esac
          else
            $d info "stopped"
          fi
          # What the VM was given, which may predate the Lima installed now:
          # the next start brings it in line (see _agent_vm_ensure_running).
          if _agent_vm_mounts_protect_git "$vm_name"; then
            $d ok "its shares keep every .git read-only"
          elif _agent_vm_writable_git_optout; then
            $d warn "its shares leave .git writable (AGENT_VM_UNSAFE_WRITABLE_GIT=1)"
          else
            $d warn "its shares leave .git writable" \
              "With a Lima that can protect it, the next start (after 'agent-vm stop' if it runs) fixes that."
          fi ;;
        1) $d info "$vm_name will be created on the first agent-vm command here" ;;
        *) $d warn "could not query Lima" ;;
      esac
    fi
  fi
  local runtime project_env
  runtime="$(_agent_vm_project_runtime_path "$host_dir")"
  [[ -f "$runtime" ]] && $d info "project runtime: $runtime ($(_agent_vm_runtime_interpreter "$runtime"))"
  project_env="$(_agent_vm_project_env_file "$host_dir")"
  if [[ -f "$project_env" ]]; then
    local unignored
    unignored="$(_agent_vm_warn_unignored "$project_env" 2>&1)"
    if [[ -n "$unignored" ]]; then
      $d warn "project env: $project_env"
      printf '%s\n' "$unignored" | sed 's/^ */        /'
    else
      $d ok "project env: $project_env"
    fi
  fi

  if [[ -n "$have_lima" ]]; then
    # VMs persist and each is clamped on its own, so several running at once
    # can promise more than the host has.
    # Not `status`: that name is read-only in zsh.
    local all name vstatus vcpus vmem run_n=0 run_cpus=0 run_mem=0
    all="$(limactl list --format '{{.Name}}|{{.Status}}|{{.CPUs}}|{{.Memory}}' 2>/dev/null || true)"
    while IFS='|' read -r name vstatus vcpus vmem; do
      case "$name" in agent-vm-*) ;; *) continue ;; esac
      [[ "$vstatus" == "Running" ]] || continue
      run_n=$((run_n + 1))
      run_cpus=$((run_cpus + ${vcpus:-0}))
      run_mem=$((run_mem + ${vmem:-0} / 1073741824))
    done <<< "$all"
    echo ""
    echo "All VMs"
    if [[ "$run_n" -eq 0 ]]; then
      $d info "none running"
    elif [[ -n "$mem" && "$run_mem" -gt "$mem" ]]; then
      $d warn "$run_n running, ${run_cpus} CPUs and ${run_mem} GiB in total: more memory than the host has" \
        "'agent-vm status' lists them; 'agent-vm stop <name>' frees one."
    else
      $d info "$run_n running, ${run_cpus} CPUs and ${run_mem} GiB in total"
    fi
  fi

  echo ""
  if [[ "$AGENT_VM_DOCTOR_FAIL" -gt 0 ]]; then
    echo "$AGENT_VM_DOCTOR_FAIL problem(s), $AGENT_VM_DOCTOR_WARN warning(s)."
    return 1
  fi
  echo "No problems found, $AGENT_VM_DOCTOR_WARN warning(s)."
}

# Escape a value for a single-quoted shell literal: ' becomes '"'"'.
#
# Via sed, NOT `${v//\'/\'\"\'\"\'}`: bash 3.2 — what macOS ships — keeps the
# backslashes in the replacement half of that substitution and emits
# `O\'"\'"\'Brien`. The resulting line is a syntax error, and a shell sourcing
# ~/.agent-vm.env then abandons the WHOLE file, losing every secret in it, not
# just the one with the quote.
_agent_vm_sq_escape() {
  printf '%s' "$1" | sed "s/'/'\"'\"'/g"
}

# _agent_vm_env_read <file> <key> — print the value the file assigns to <key>,
# as a shell would, without running the shell.
# 0 = found (value on stdout) · 1 = not assigned · 3 = assigned with syntax
# this reader refuses to interpret.
#
# Accepted: optional leading `export `, then a value made of single-quoted
# parts (possibly spanning lines, as `set` writes a value with a newline),
# double-quoted parts with nothing to expand, and bare characters other than
# $ ` \ ; & | < > ( ) ~. A trailing `# comment` is allowed. The last
# assignment wins, like in the shell.
_agent_vm_env_read() {
  awk -v k="$2" -v q="'" '
    function parse(s,    v, c, e, more) {
      v = ""
      while (s != "") {
        c = substr(s, 1, 1)
        if (c == q) {
          s = substr(s, 2)
          while (!(e = index(s, q))) {
            if ((getline more) <= 0) { VAL = v; return 3 }
            v = v s "\n"; s = more
          }
          v = v substr(s, 1, e - 1); s = substr(s, e + 1)
        } else if (c == "\"") {
          s = substr(s, 2); e = index(s, "\"")
          if (!e || substr(s, 1, e - 1) ~ /[$`\\]/) { VAL = v; return 3 }
          v = v substr(s, 1, e - 1); s = substr(s, e + 1)
        } else if (c == " " || c == "\t") {
          VAL = v
          return (s ~ /^[ \t]+(#.*)?$/) ? 0 : 3
        } else if (index("$`\\;&|<>()~\r", c)) {
          VAL = v
          return (c == "\r" && s == "\r") ? 0 : 3
        } else {
          v = v c; s = substr(s, 2)
        }
      }
      VAL = v
      return 0
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/^export[ \t]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
      eq = index(line, "=")
      rc = parse(substr(line, eq + 1))
      if (substr(line, 1, eq - 1) == k) { found = 1; bad = rc; val = VAL }
    }
    END {
      if (!found) exit 1
      if (bad) exit 3
      printf "%s", val
    }
  ' "$1"
}

# Read, write and delete entries in ~/.agent-vm/env — the dotenv file pushed
# into every VM on each start and auto-sourced there.
#
# Exists so integrators don't hand-roll the quoting: the file is *sourced* by a
# shell, so one bad escape costs every secret in it (see _agent_vm_sq_escape).
#
#   agent-vm env set KEY VALUE   replace or add KEY (value never echoed)
#   agent-vm env get KEY         print KEY's value
#   agent-vm env has KEY         exit 0 if KEY is set, 1 otherwise (no output)
#   agent-vm env unset KEY       remove KEY
#   agent-vm env list            print the key NAMES only, never the values
#
# Writes are atomic (temp file then mv) and the file is kept mode 600. Lines
# this command does not manage are preserved untouched.
# Where this project's env file lives. Same shape as the runtime script above,
# same override rule: AGENT_VM_PROJECT_ENV holds it somewhere else (typically
# an integrator's own directory, ".mytool/env"), relative paths resolve against
# the project, absolute ones are used as-is.
#
# In the project, not in the state dir: a per-project value belongs with the
# project. It follows a clone, a move and a delete without the engine having to
# track which directory was which — and nothing outlives a project that is
# gone.
#
# The flip side, and it is on the integrator: this file is inside a git
# repository. Put a secret in it and it is one `git add` away from being
# published. Secrets shared by every VM belong in `agent-vm env`, which lives
# outside any repository.
_agent_vm_project_env_file() {
  local host_dir="${1:-$(pwd)}" rel="${AGENT_VM_PROJECT_ENV:-.agent-vm.env}"
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s\n' "${host_dir}/${rel}" ;;
  esac
}

# A project env file is a file in someone's repository, so the failure that
# matters is committing it. Say so when it is WRITTEN — the only moment the
# user is thinking about this file — and give the exact line that prevents it:
# a warning without the fix is just noise someone learns to scroll past.
#
# `git check-ignore` is the authority here: it accounts for .gitignore at every
# level, .git/info/exclude and the user's global excludes, none of which a grep
# over .gitignore would see. Exit 1 means "not ignored"; anything else (no
# repository, git missing, an error) is not something to lecture about.
#
# Already tracked is the worse case and a different fix: ignoring a tracked
# file changes nothing, git keeps staging its edits. Saying "add this line"
# there would be wrong advice.
_agent_vm_warn_unignored() {
  local file="$1" top rel rc=0
  command -v git >/dev/null 2>&1 || return 0
  top="$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  rel="${file#"$top"/}"

  if git -C "$top" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    echo "Warning: $rel is tracked by git — its contents are in the repository." >&2
    echo "         git rm --cached '$rel' && echo '/$rel' >> .gitignore" >&2
    return 0
  fi

  git -C "$top" check-ignore -q "$file" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || return 0
  echo "Warning: $rel is not ignored by git — it can be committed by accident." >&2
  echo "         echo '/$rel' >> $top/.gitignore" >&2
}

# What gets pushed into a VM: the shared file first, this project's next.
# The guest sources it, so the last assignment wins and the project's value
# overrides the shared one. A function of its own so that order is testable
# without starting a VM — it is the whole meaning of "per project".
_agent_vm_env_payload() {
  local host_dir="${1:-$(pwd)}" project_env
  project_env="$(_agent_vm_project_env_file "$host_dir")"
  # The echo keeps a shared file with no trailing newline from gluing its last
  # line to the project's first one.
  [ -f "$AGENT_VM_STATE_DIR/env" ] && { cat "$AGENT_VM_STATE_DIR/env"; echo; }
  [ -f "$project_env" ] && cat "$project_env"
  return 0
}

# The env verbs, shared by `env` (one file for every VM) and `project-env`
# (one file per project). Same code for both on purpose: this file is SOURCED
# by the VM's shell, so the quoting and the atomic replace below are the whole
# point of the engine owning it. A second copy would be a second set of bugs.
_agent_vm_env() {
  local verb="$1" file="$2"; shift 2
  local action="${1:-list}"
  local key="${2:-}"

  case "$action" in
    set|get|has|unset)
      if [[ -z "$key" ]]; then
        echo "Error: 'agent-vm $verb $action' needs a KEY." >&2
        return 1
      fi
      # A key must be a shell-assignable name: anything else would produce a
      # line that breaks the file for every reader.
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Error: '$key' is not a valid environment variable name." >&2
        return 1
      fi ;;
  esac

  case "$action" in
    set)
      if [[ $# -lt 3 ]]; then
        echo "Error: 'agent-vm $verb set' needs a VALUE." >&2
        return 1
      fi
      local value="$3" tmp line
      mkdir -p "$(dirname "$file")"
      tmp="$(mktemp "${file}.XXXXXX")"
      chmod 600 "$tmp"
      if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
          case "$line" in
            "${key}="*) : ;;
            *) printf '%s\n' "$line" >> "$tmp" ;;
          esac
        done < "$file"
      fi
      printf "%s='%s'\n" "$key" "$(_agent_vm_sq_escape "$value")" >> "$tmp"
      # A silently-dropped write here means the caller is told the secret was
      # stored when it was not — the worst possible failure for this file.
      if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        echo "Error: could not write $file" >&2
        return 1
      fi
      chmod 600 "$file"
      ;;
    unset)
      [[ -f "$file" ]] || return 0
      local tmp line
      tmp="$(mktemp "${file}.XXXXXX")"
      chmod 600 "$tmp"
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          "${key}="*) : ;;
          *) printf '%s\n' "$line" >> "$tmp" ;;
        esac
      done < "$file"
      if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        echo "Error: could not write $file" >&2
        return 1
      fi
      chmod 600 "$file"
      ;;
    get|has)
      [[ -f "$file" ]] || return 1
      # Read, never source. The project file sits in a directory the VM can
      # write to, and sourcing it here would run whatever the agent put in it
      # on the host. Only the forms `set` writes and plain dotenv lines are
      # accepted; anything the shell would expand is refused, not evaluated.
      local value rc=0
      value="$(_agent_vm_env_read "$file" "$key")" || rc=$?
      case "$rc" in
        0) ;;
        1) return 1 ;;
        *)
          echo "Error: $key in $file uses shell syntax agent-vm does not evaluate" >&2
          echo "  (\$, backquotes, backslashes, ~, ;, | ...). Rewrite it with 'agent-vm $verb set'." >&2
          return 2 ;;
      esac
      [[ "$action" == "has" ]] && return 0
      printf '%s\n' "$value"
      ;;
    list)
      [[ -f "$file" ]] || return 0
      # Names only — never values, so this stays safe to paste into an issue.
      sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$file"
      ;;
    *)
      echo "Usage: agent-vm $verb {set KEY VALUE|get KEY|has KEY|unset KEY|list}" >&2
      return 1 ;;
  esac
}

_agent_vm_help() {
  cat << 'EOF'
Usage: agent-vm [options] <command> [args]

Commands:
  install            Put agent-vm on your PATH (a link in ~/.local/bin, or
                     AGENT_VM_BIN_DIR) and offer to source it from your shell
                     rc. Run it from the clone: ./agent-vm.sh install
  uninstall          Remove that link. VMs and ~/.agent-vm are left alone.
  setup              Create the base VM template (run once)
  claude [args]      Run Claude Code in the VM for the current directory
  opencode [args]    Run OpenCode in the VM for the current directory
  codex [args]       Run Codex CLI in the VM for the current directory
  vibe [args]        Run Mistral Vibe in the VM for the current directory
  pi [args]          Run Pi in the VM for the current directory (opt-in at
                     setup: --preinstall=default,pi)
  shell, sh          Open a shell in the VM. Add -c "..." to run a one-shot
                     command via login zsh and exit.
  run <cmd> [args]   Run a command in the VM (no shell — for pipes/redirects
                     use 'shell -c "..."' instead; pass --tty for TUIs like
                     opencode, vibe, htop, etc.)
  stop [vm-name]     Stop the VM for the current directory, or the named one
  rm [vm-name]       Stop and delete the VM for the current directory, or the
                     named one. Pass a name from 'agent-vm list' to reach a VM
                     whose directory was renamed or deleted: its name is a
                     hash of the old path, so no 'cd' can name it any more.
  destroy-all        Stop and delete every agent-vm VM, the base template
                     included ('agent-vm setup' rebuilds it)
  list               List all agent-vm VMs
  status             Show status of all VMs (current dir marked with >)
  doctor             Check the host, Lima, the base template and this
                     directory, and say how to fix what is wrong. Read-only.
  name [dir]         Print the VM name for a directory (default: cwd)
  info [dir]         Print machine-readable state as key=value lines
                     (version, template, state_dir, dir, vm_name,
                     base_exists, vm_exists, vm_running, vm_stale).
                     Use this from scripts instead of parsing the output
                     of the human-facing commands.
  env <sub> [args]   Read/write ~/.agent-vm/env, the secrets pushed into every
                     VM. Subcommands: set KEY VALUE, get KEY, has KEY (exit
                     status only), unset KEY, list (key names, never values).
                     Use this rather than editing the file: it is sourced by a
                     shell, so one bad quote costs every secret in it.
  project-env <sub>  Same subcommands, for THIS directory's project only. Its
                     values are pushed after the shared ones, so a key set in
                     both takes the project's value. Stored IN the project
                     (.agent-vm.env by default, AGENT_VM_PROJECT_ENV to put it
                     elsewhere) — so it follows the project and dies with it.
                     Being in a repository, it is the wrong place for a secret:
                     `agent-vm env` is outside any. `set` warns, with the line
                     to run, when the file is not ignored by git. `info` prints
                     the path as project_env=.
  version            Print the agent-vm version
  version --min X.Y.Z
                     Check it: silent and 0 when this engine is at least
                     X.Y.Z, an actionable error and 1 when it is older
                     (2 when the call itself is wrong). For integrators.
  help               Show this help

VM options (for claude, opencode, codex, vibe, pi, shell, run), read before the
command or right after its name, never later: in 'agent-vm run docker run
--rm x', --rm belongs to docker.
  --disk GB          VM disk size (default: 10)
  --memory GB        VM memory (default: 3)
  --cpus N           Number of CPUs (default: 1)
                     Both are clamped to a share of the host (half of it, with
                     a notice) so the VM cannot starve the machine it runs on.
                     AGENT_VM_HOST_SHARE overrides the divisor.
  --reset            Destroy and re-clone the VM from the base template
  --readonly         Make every host share read-only: the project and the
                     ~/.agent-vm/volumes entries, rw ones included. Enforced
                     on the host side, so root in the VM cannot lift it.
                     Changing the mode restarts the VM.
  --unsafe-writable-git
                     Leave every .git writable, so the agent can commit (see
                     below). Also accepted as --unsafe-writable-git=1.
  --rm               Automatically destroy the VM after the command exits

Examples:
  agent-vm setup                             # Create base VM
  agent-vm claude                            # Run Claude in a VM
  agent-vm opencode                          # Run OpenCode in a VM
  agent-vm codex                             # Run Codex in a VM
  agent-vm vibe                              # Run Mistral Vibe in a VM
  agent-vm pi                                # Run Pi in a VM
  agent-vm --disk 50 --memory 16 --cpus 8 claude  # Custom resources
  agent-vm --reset claude                    # Fresh VM from base template
  agent-vm --rm claude                       # Destroy VM after Claude exits
  agent-vm --readonly shell                  # Nothing on the host is writable
  agent-vm shell                             # Shell into the VM
  agent-vm sh -c "ls -la | grep config"      # One-shot command via login zsh
  agent-vm run npm install                   # Run a command in the VM
  agent-vm run --tty opencode -p "..."       # Run a TUI with PTY allocated
  agent-vm claude -p "fix lint errors"       # Pass args to claude
  agent-vm rm agent-vm-old-name-1a2b3c4d     # Delete a VM by name (see 'list')

VMs are persistent and unique per directory. Running "agent-vm shell" or
"agent-vm claude" in the same directory will reuse the same VM.

Every .git in the shared folders is read-only for the VMs when Lima supports
it (sshfs.readonlyNames, not merged upstream yet: 'agent-vm setup' offers a
Lima build that has it). Otherwise a VM can write .git/config and hooks, which
git on this machine runs. 'agent-vm doctor' says which case you are in.
--unsafe-writable-git, or AGENT_VM_UNSAFE_WRITABLE_GIT=1 in your shell, leaves
.git writable anyway, so the agent can commit in the project; a warning is
printed on every run. Changing it applies when the VM is next started.
A folder with HEAD, objects/ and refs/ is a repository to git under any name:
'setup' asks to set safe.bareRepository=explicit so git ignores those.

Customization:
  ~/.agent-vm/env                   Shared env vars / tokens (dotenv-style;
                                     auto-loaded into every VM shell)
  ~/.agent-vm/volumes               Extra host paths to mount in VMs (one per
                                     line, supports both directories and files)
  ~/.agent-vm/setup.sh              Per-user setup (runs during "agent-vm setup")
  ~/.agent-vm/env                   Shared env pushed into every VM
  <project>/.agent-vm.env           Per-project env (agent-vm project-env)
                                    Override the path with AGENT_VM_PROJECT_ENV
  ~/.agent-vm/runtime.sh            Per-user runtime (runs on each VM start)
  <project>/.agent-vm.runtime.sh    Per-project runtime (runs on each VM start)
                                    Override the path with AGENT_VM_PROJECT_RUNTIME
                                    (relative to the project, or absolute).
                                    Runtimes run under the shell their shebang
                                    names (bash, sh; zsh otherwise).

More info: https://www.agent-vm.org/
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

# Report a setup failure and leave nothing running. The half-provisioned
# template stays on disk on purpose (the next `setup` deletes and recreates
# it, and keeping it lets the user look inside), but it has no reason to keep
# burning CPU and RAM meanwhile.
_agent_vm_setup_aborted() {
  echo "Error: $1" >&2
  limactl stop "$AGENT_VM_TEMPLATE" &>/dev/null
}

# _agent_vm_scroll_window <log> — copy stdin to <log>. On a terminal, show only
# the last 10 lines, redrawn in place and cleared at the end; otherwise pass
# every line through. Lines are cut to the terminal width, since a wrapped line
# would break the redraw, and colour codes are dropped, since a cut one would
# leave the terminal coloured. No arrays and no fork per line: this file is also
# sourced by zsh, and apt prints thousands of lines.
_agent_vm_scroll_window() {
  local log="$1"
  if [[ ! -t 1 ]]; then
    tee -a "$log"
    return 0
  fi
  local height=10 size width rows line rest buf="" n=0 drawn=0
  # "rows cols". Not tput: with stdout captured and stderr silenced it has no
  # terminal left to ask, and answers 80.
  size="$(stty size 2>/dev/null </dev/tty)"
  rows="${size% *}"; width="${size#* }"
  [[ "$width" =~ ^[0-9]+$ && "$width" -gt 1 ]] || width=80
  [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -lt $((height + 2)) ]] && height=$((rows > 3 ? rows - 2 : 1))
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >&3
    # A progress bar redraws with \r: keep what the last redraw left.
    line="${line%$'\r'}"; line="${line##*$'\r'}"
    # Lima logs `time="…" level=info msg="…" key=value`: the message is what
    # fits and what says something.
    if [[ "$line" == time=*' msg="'* ]]; then
      line="${line#* msg=\"}"; line="${line%%\"*}"
    fi
    while [[ "$line" == *$'\e'* ]]; do
      rest="${line#*$'\e'}"
      line="${line%%$'\e'*}${rest#\[*[A-Za-z]}"
    done
    line="${line//$'\t'/ }"
    line="${line:0:$((width - 1))}"
    if [[ "$n" -lt "$height" ]]; then
      n=$((n + 1))
    else
      buf="${buf#*$'\n'}"
    fi
    buf="$buf$line"$'\n'
    [[ "$drawn" -gt 0 ]] && printf '\e[%dA' "$drawn"
    printf '\r\e[J\e[2m%s\e[0m' "$buf"
    drawn="$n"
  done 3>>"$log"
  [[ "$drawn" -gt 0 ]] && printf '\e[%dA\r\e[J' "$drawn"
  return 0
}

# _agent_vm_windowed <log> <command> [args...] — run the command, stdin
# included, with its output in _agent_vm_scroll_window and appended to <log>.
# Returns the command's status, which goes through a file: a pipeline returns
# its last command's, and bash's PIPESTATUS is zsh's pipestatus. On failure,
# the end of the log is shown again, since the window is gone.
_agent_vm_windowed() {
  local log="$1" status_file="$1.status" rc
  shift
  echo 1 > "$status_file"
  { "$@" 2>&1; echo $? > "$status_file"; } | _agent_vm_scroll_window "$log"
  rc="$(cat "$status_file" 2>/dev/null)"
  rm -f "$status_file"
  if [[ "$rc" != "0" ]]; then
    [[ -t 1 ]] && tail -n 20 "$log" >&2
    return 1
  fi
  return 0
}

# The agent-vm VMs other than the base template, one per line. Empty when
# there are none, or when limactl cannot answer.
_agent_vm_project_vms() {
  local list
  list="$(limactl list -q 2>/dev/null)" || return 0
  printf '%s\n' "$list" | grep "^agent-vm-" | grep -v "^${AGENT_VM_TEMPLATE}\$" || true
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
  # Pi is opt-in: still 0.x, with releases several times a week.
  local install_pi=0
  # MCP servers wired into the agents' configs. Named mcp-* in --preinstall so
  # future MCP servers share one obvious namespace. Only servers with a
  # dependency worth baking into the image belong here: a remote MCP server is
  # a URL (and often a secret), which belongs in per-project config rather than
  # in an image every VM is cloned from. Both current ones drive the installed
  # Chromium. mcp-playwright is opt-in like the Ruby/Rust/Go languages: a second
  # browser-driving server is redundant for most users, and every wired server
  # costs tool definitions in the agent's context.
  local install_mcp_chrome=1 install_mcp_playwright=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        cat << 'EOF'
Usage: agent-vm setup [options]

Create a base VM template with dev tools and agents pre-installed. Runs an
interactive wizard by default; the first prompt offers a "default install"
(everything except the opt-in Ruby, Rust, Go, Pi, Playwright MCP). Answer 'n' for
per-component prompts. Pass --preinstall=... to skip the wizard and pick a
specific subset non-interactively. When no terminal is available (e.g. CI),
the wizard is skipped automatically and the default set is installed.

Options:
  --disk GB           VM disk size (default: 10)
  --memory GB         VM memory (default: 3)
  --cpus N            Number of CPUs (default: 1)
  --preinstall=LIST   Comma-separated list of tools to preinstall in the base
                      VM image (skips the wizard). Anything not listed is
                      skipped. Use:
                        'default' for the default set
                                  (everything except Ruby, Rust, Go, Pi,
                                  mcp-playwright),
                        'all' for everything,
                        'none' for nothing.
                      Available names:
                        python, node, ruby, rust, golang, docker, chromium,
                        gh, claude, opencode, codex, vibe, pi, mcp-chrome,
                        mcp-playwright
                      Selecting codex or pi also installs node (npm). So does
                      mcp-chrome when chromium and an agent are selected
                      (npx). mcp-playwright does not: list node yourself.
                      The mcp-* names wire an MCP server into each installed
                      agent's config. Both 'mcp-chrome' (Chrome DevTools) and
                      'mcp-playwright' drive the preinstalled Chromium, so
                      both need node and chromium and are skipped, with a
                      notice, without them. Pi has no MCP support, so they
                      are not wired into it. 'mcp-playwright' is opt-in and not
                      part of 'default' — a second browser-driving server is
                      redundant for most users. Omit them to leave the agents'
                      MCP config untouched — useful when MCP servers are
                      managed per project rather than baked into the image.
                      Examples:
                        --preinstall=default,rust       # default set plus Rust
                        --preinstall=python,docker,claude
                        --preinstall=node,chromium,opencode   # no chrome MCP
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
    install_pi=0
    install_mcp_chrome=0 install_mcp_playwright=0
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
          install_pi=1
          install_mcp_chrome=1 install_mcp_playwright=1
          ;;
        default)
          install_python=1 install_node=1
          install_docker=1 install_chromium=1 install_gh=1
          install_claude=1 install_opencode=1 install_codex=1 install_vibe=1
          install_mcp_chrome=1
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
        pi)       install_pi=1 ;;
        mcp-chrome)     install_mcp_chrome=1 ;;
        mcp-playwright) install_mcp_playwright=1 ;;
        *)
          echo "Unknown preinstall name: $f (names are lowercase)" >&2
          echo "Valid: python, node, ruby, rust, golang, docker, chromium, gh, claude, opencode, codex, vibe, pi, mcp-chrome, mcp-playwright, default, all, none" >&2
          return 1
          ;;
      esac
    done
  fi

  # Fail-fast checks before the (potentially long) wizard so the user doesn't
  # answer 15 prompts only to be told their host is missing Lima or KVM.
  # Installing software on the host is asked, never assumed. Without a
  # terminal to ask on, say what to run instead.
  # The Lima that keeps .git read-only is offered first, so that it is not
  # brew's lima installed now and replaced a minute later.
  echo "Starting agent-vm setup..."
  local declined_protection=""
  if ! command -v limactl &>/dev/null; then
    if command -v brew &>/dev/null && _agent_vm_have_tty; then
      if [[ "$(_agent_vm_ask_yn "Lima is not installed. Install it now with 'brew install $AGENT_VM_LIMA_FORMULA' (keeps .git read-only for the VMs, built from source)?" Y)" == "1" ]]; then
        brew install "$AGENT_VM_LIMA_FORMULA" || return 1
      else
        declined_protection=1
        if [[ "$(_agent_vm_ask_yn "Install brew's lima instead, which lets the VMs write .git?" Y)" == "1" ]]; then
          brew install lima || return 1
        fi
      fi
    fi
    if ! command -v limactl &>/dev/null; then
      echo "Error: Lima is required." >&2
      if command -v brew &>/dev/null; then
        echo "  Install it with: brew install $AGENT_VM_LIMA_FORMULA" >&2
        echo "  (or brew install lima, which lets the VMs write .git)" >&2
      else
        echo "  Install it from https://lima-vm.io/docs/installation/" >&2
      fi
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
  if [[ -z "$preinstall_seen" ]] && _agent_vm_have_tty; then
    printf '\nagent-vm setup wizard\n' >&2
    printf '─────────────────────\n\n' >&2
    printf 'These settings apply to the base VM image. Every per-project VM is\n' >&2
    printf 'cloned from it, so anything preinstalled here is available in all\n' >&2
    printf 'future agent VMs. You can still install extra tools inside any\n' >&2
    printf 'individual VM later (e.g. via `agent-vm shell`).\n\n' >&2
    printf 'For more: https://www.agent-vm.org/\n\n' >&2

    # Software first — the more interesting choice for most users.
    printf 'Software\n' >&2
    printf '────────\n' >&2
    printf '  Agents:   Claude Code, OpenCode, Codex CLI, Mistral Vibe\n' >&2
    printf '  Tools:    Python, Node.js, Docker, Chromium, gh,\n' >&2
    printf '            Chrome DevTools MCP\n' >&2
    printf '  Skip:     Pi, Ruby, Rust, Go, Playwright MCP\n\n' >&2
    local use_default_software
    use_default_software=$(_agent_vm_ask_yn "Use this default" Y)
    if [[ "$use_default_software" != "1" ]]; then
      printf '\nAI coding agents\n' >&2
      printf '────────────────\n' >&2
      install_claude=$(_agent_vm_ask_yn "Claude Code" Y)
      install_opencode=$(_agent_vm_ask_yn "OpenCode" Y)
      install_codex=$(_agent_vm_ask_yn "Codex CLI" Y)
      install_vibe=$(_agent_vm_ask_yn "Mistral Vibe" Y)
      install_pi=$(_agent_vm_ask_yn "Pi" N)

      printf '\nSystem tools\n' >&2
      printf '────────────\n' >&2
      install_docker=$(_agent_vm_ask_yn "Docker" Y)
      install_chromium=$(_agent_vm_ask_yn "Chromium (headless browser)" Y)
      install_gh=$(_agent_vm_ask_yn "GitHub CLI (gh)" Y)

      # MCP servers, wired into each installed agent's config. Chrome DevTools
      # drives the Chromium above, so it is only worth asking when that is on.
      # Playwright brings its own browser download, hence the N default.
      if [[ "$install_chromium" == "1" ]]; then
        install_mcp_chrome=$(_agent_vm_ask_yn "Chrome DevTools MCP (wired into each agent's config)" Y)
      else
        install_mcp_chrome=0
      fi
      if [[ "$install_chromium" == "1" ]]; then
        install_mcp_playwright=$(_agent_vm_ask_yn "Playwright MCP (also drives that Chromium)" N)
      else
        install_mcp_playwright=0
      fi

      local node_forced_reason=""
      if [[ "$install_codex" == "1" ]]; then
        node_forced_reason="Codex CLI requires Node.js"
      elif [[ "$install_pi" == "1" ]]; then
        node_forced_reason="Pi requires Node.js"
      elif [[ "$install_chromium" == "1" && "$install_mcp_chrome" == "1" && ( "$install_claude" == "1" || "$install_opencode" == "1" || "$install_vibe" == "1" ) ]]; then
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

  # After the wizard: its questions are the familiar ones (which agents, how
  # much RAM), these are not, and a first run should not open on them. Still
  # before the VM is created, since one of them can replace Lima. Announced, so
  # a warning reads as the result of a check and not out of the blue.
  echo "Running security checks..."
  [[ -n "$declined_protection" ]] || _agent_vm_offer_git_protection
  _agent_vm_offer_bare_repo_setting

  if [[ "$install_chromium" == "1" && "$install_mcp_chrome" == "1" ]]; then
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

  if [[ "$install_pi" == "1" && "$install_node" != "1" ]]; then
    echo "Enabling Node.js because Pi requires npm." >&2
    install_node=1
  fi

  _agent_vm_clean_partial_state "$AGENT_VM_TEMPLATE"

  # Retire the marker with the base it describes, before anything can fail.
  # It is only rewritten at the end of a successful setup, so leaving the old
  # one in place would make an interrupted re-setup look like a ready base.
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-base-version"

  limactl stop "$AGENT_VM_TEMPLATE" &>/dev/null
  limactl delete "$AGENT_VM_TEMPLATE" --force &>/dev/null

  # Same clamp as the per-project path. Done here rather than at parse time so
  # the wizard above still shows what was asked for.
  local eff_cpus eff_memory
  eff_cpus="$(_agent_vm_cap_resource cpus "$cpus")"
  eff_memory="$(_agent_vm_cap_resource memory "$memory")"
  [[ -n "$eff_cpus" ]] && cpus="$eff_cpus"
  [[ -n "$eff_memory" ]] && memory="$eff_memory"
  _agent_vm_warn_disk_space "$disk"

  echo "Creating base VM..."
  local create_args=(
    --set '.mounts=[]'
    --disk="$disk"
    --memory="$memory"
    --cpus="$cpus"
    --tty=false
    # No Lima containerd: Docker (optional) ships its own, and Lima's unit in
    # /usr/local shadows Docker's. Also skips unpacking nerdctl on every boot.
    --containerd=none
  )
  # Every step from here shows its output in a 10-line window, all of it kept
  # in one log for when something fails.
  mkdir -p "$AGENT_VM_STATE_DIR"
  local setup_log="$AGENT_VM_STATE_DIR/setup.log"
  : > "$setup_log"
  if ! _agent_vm_windowed "$setup_log" \
       limactl create --name="$AGENT_VM_TEMPLATE" template:debian-13 "${create_args[@]}" </dev/null; then
    echo "Error: Failed to create base VM. Full log: $setup_log" >&2
    return 1
  fi

  _agent_vm_print_resources "$AGENT_VM_TEMPLATE"

  echo "Starting base VM (the first run downloads a Debian image)..."
  if ! _agent_vm_windowed "$setup_log" limactl start "$AGENT_VM_TEMPLATE" </dev/null; then
    echo "Error: Failed to start base VM. Full log: $setup_log" >&2
    echo "Lima's own log: ~/.lima/$AGENT_VM_TEMPLATE/ha.stderr.log" >&2
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
    printf 'export AGENT_VM_INSTALL_PI=%s\n'        "$install_pi"
    printf 'export AGENT_VM_INSTALL_MCP_CHROME=%s\n'     "$install_mcp_chrome"
    printf 'export AGENT_VM_INSTALL_MCP_PLAYWRIGHT=%s\n' "$install_mcp_playwright"
    cat "${AGENT_VM_SCRIPT_DIR}/agent-vm.setup.sh"
  } | _agent_vm_windowed "$setup_log" limactl shell "$AGENT_VM_TEMPLATE" bash -l \
    || { _agent_vm_setup_aborted "Setup script failed. Full log: $setup_log"; return 1; }

  # Run user's custom setup script if it exists
  local user_setup="$AGENT_VM_STATE_DIR/setup.sh"
  if [ -f "$user_setup" ]; then
    echo "Running custom setup from $user_setup..."
    limactl shell "$AGENT_VM_TEMPLATE" zsh -l < "$user_setup" || { _agent_vm_setup_aborted "Custom setup script failed."; return 1; }
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
  [[ "$install_pi"       == "1" ]] && echo "  agent-vm pi"
  # Only worth saying to someone who has a VM to re-clone: on a first install
  # there is nothing to reset, and the advice reads like a missed step.
  if [[ -n "$(_agent_vm_project_vms)" ]]; then
    echo ""
    echo "Note: Existing VMs were not updated. Use --reset to re-clone them from the new base."
  fi
}

# Run a command in the VM through a login zsh.
#
# `limactl shell VM cmd` runs cmd under the shell configured for the instance,
# and Lima >= 2.2.0 defaults that to /bin/bash whatever the guest login shell
# is (lima-vm/lima#5194); older versions used "$SHELL", i.e. the login shell
# `agent-vm.setup.sh` sets with chsh. Agent PATH entries and the
# ~/.agent-vm.env sourcing both live in ~/.zshenv, so under bash the agents are
# not found and anything that is found starts without its API keys. Forcing
# `zsh -l -c` here works on every Lima version.
#
# The command and its arguments are passed as positional parameters, so the
# guest shell never re-parses them; `env` runs the command and keeps leading
# VAR=value assignments working.
#
# Usage: _agent_vm_lima_run <vm_name> <host_dir> <tty:1|""> <command> [args...]
_agent_vm_lima_run() {
  local vm_name="$1" host_dir="$2" want_tty="$3"
  shift 3
  local shell_opts=(--workdir "$host_dir")
  [[ -n "$want_tty" ]] && shell_opts+=(--tty)
  limactl shell "${shell_opts[@]}" "$vm_name" -- zsh -l -c 'exec env "$@"' agent-vm "$@"
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
      --readonly) vm_opts+=(--readonly); shift ;;
      --unsafe-writable-git|--unsafe-writable-git=1) vm_opts+=(--unsafe-writable-git); shift ;;
      --rm)       rm=1; shift ;;
      # Options are only read before the command: everything from the first
      # other word on belongs to it, so `run docker run --rm x` keeps its --rm.
      --)         shift; args=("$@"); break ;;
      *)          args=("$@"); break ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")" || return 1

  _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"} || return 1
  _agent_vm_print_resources "$vm_name"

  local exit_code=0
  _agent_vm_lima_run "$vm_name" "$host_dir" "" claude --dangerously-skip-permissions ${args[@]+"${args[@]}"}
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
      --readonly) vm_opts+=(--readonly); shift ;;
      --unsafe-writable-git|--unsafe-writable-git=1) vm_opts+=(--unsafe-writable-git); shift ;;
      --rm)       rm=1; shift ;;
      # Options are only read before the command: everything from the first
      # other word on belongs to it, so `run docker run --rm x` keeps its --rm.
      --)         shift; args=("$@"); break ;;
      *)          args=("$@"); break ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")" || return 1

  _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"} || return 1
  _agent_vm_print_resources "$vm_name"

  # --auto auto-approves permission prompts that aren't explicitly denied,
  # giving full autonomy (safe inside the sandbox). This is OpenCode's shipped
  # equivalent of a "yolo" mode; the proposed --yolo flag was never merged.
  local exit_code=0
  _agent_vm_lima_run "$vm_name" "$host_dir" 1 opencode --auto ${args[@]+"${args[@]}"}
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
      --readonly) vm_opts+=(--readonly); shift ;;
      --unsafe-writable-git|--unsafe-writable-git=1) vm_opts+=(--unsafe-writable-git); shift ;;
      --rm)       rm=1; shift ;;
      # Options are only read before the command: everything from the first
      # other word on belongs to it, so `run docker run --rm x` keeps its --rm.
      --)         shift; args=("$@"); break ;;
      *)          args=("$@"); break ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")" || return 1

  _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"} || return 1
  _agent_vm_print_resources "$vm_name"

  local exit_code=0
  _agent_vm_lima_run "$vm_name" "$host_dir" "" codex --dangerously-bypass-approvals-and-sandbox ${args[@]+"${args[@]}"}
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
      --readonly) vm_opts+=(--readonly); shift ;;
      --unsafe-writable-git|--unsafe-writable-git=1) vm_opts+=(--unsafe-writable-git); shift ;;
      --rm)       rm=1; shift ;;
      # Options are only read before the command: everything from the first
      # other word on belongs to it, so `run docker run --rm x` keeps its --rm.
      --)         shift; args=("$@"); break ;;
      *)          args=("$@"); break ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")" || return 1

  _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"} || return 1
  _agent_vm_print_resources "$vm_name"

  # Vibe is a full-screen TUI, so allocate a tty (like opencode).
  # --agent auto-approve gives full autonomy (safe inside the sandbox).
  local exit_code=0
  _agent_vm_lima_run "$vm_name" "$host_dir" 1 vibe --agent auto-approve ${args[@]+"${args[@]}"}
  exit_code=$?
  [[ -n "$rm" ]] && { echo "Removing VM..."; _agent_vm_destroy; }
  return $exit_code
}

_agent_vm_pi() {
  local vm_opts=()
  local args=()
  local rm=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     vm_opts+=(--disk "$2"); shift 2 ;;
      --memory|--ram)   vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)     vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)    vm_opts+=(--reset); shift ;;
      --readonly) vm_opts+=(--readonly); shift ;;
      --unsafe-writable-git|--unsafe-writable-git=1) vm_opts+=(--unsafe-writable-git); shift ;;
      --rm)       rm=1; shift ;;
      # Options are only read before the command: everything from the first
      # other word on belongs to it, so `run docker run --rm x` keeps its --rm.
      --)         shift; args=("$@"); break ;;
      *)          args=("$@"); break ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")" || return 1

  _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"} || return 1
  _agent_vm_print_resources "$vm_name"

  # Pi has no permission prompts, so no flag: it runs every tool as asked.
  # Full-screen TUI, so allocate a tty (like opencode).
  local exit_code=0
  _agent_vm_lima_run "$vm_name" "$host_dir" 1 pi ${args[@]+"${args[@]}"}
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
      --readonly) vm_opts+=(--readonly); shift ;;
      --unsafe-writable-git|--unsafe-writable-git=1) vm_opts+=(--unsafe-writable-git); shift ;;
      --rm)       rm=1; shift ;;
      -c|--command)
        if [[ $# -lt 2 || -z "$2" ]]; then
          echo "Error: -c/--command requires a command string." >&2
          return 1
        fi
        cmd_string="$2"; shift 2 ;;
      *)
        echo "Error: unknown argument for shell: $1" >&2
        echo "Usage: agent-vm [vm options] shell [-c \"command\"]" >&2
        return 1 ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")" || return 1

  _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"} || return 1
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
      --readonly) vm_opts+=(--readonly); shift ;;
      --unsafe-writable-git|--unsafe-writable-git=1) vm_opts+=(--unsafe-writable-git); shift ;;
      --rm)       rm=1; shift ;;
      --tty)      tty_flag=1; shift ;;
      # Options are only read before the command: everything from the first
      # other word on belongs to it, so `run docker run --rm x` keeps its --rm.
      --)         shift; args=("$@"); break ;;
      *)          args=("$@"); break ;;
    esac
  done
  if [[ ${#args[@]} -eq 0 ]]; then
    echo "Usage: agent-vm run [--tty] <command> [args]" >&2
    return 1
  fi
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")" || return 1

  _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"} || return 1
  _agent_vm_print_resources "$vm_name"

  # `--tty` forces limactl to allocate a pseudo-terminal in the VM, which
  # full-screen TUIs (opencode, vibe, htop, …) need to render correctly when
  # invoked through `agent-vm run`. Without it, line-mode tools work fine but
  # ncurses-style UIs break.
  local exit_code=0
  _agent_vm_lima_run "$vm_name" "$host_dir" "$tty_flag" "${args[@]}"
  exit_code=$?
  [[ -n "$rm" ]] && { echo "Removing VM..."; _agent_vm_destroy; }
  return $exit_code
}

# Resolve the VM that `stop` / `rm` acts on, and prove it exists.
# Prints the name on stdout; diagnostics go to stderr.
#
# With no argument: the current directory's VM, as before.
#
# With one argument: a VM name as printed by `agent-vm list`. It has to be a
# NAME and not a directory, because the case it exists for is a VM no directory
# can reach any more: the name embeds a hash of the path, so renaming or
# deleting the project folder orphans the VM, and `_agent_vm_abs_dir` would
# refuse the old path anyway. `list` remains the only handle on it.
#
# The `agent-vm-` prefix is required: without it a typo could stop or delete an
# unrelated Lima instance on the same machine.
_agent_vm_resolve_target() {
  local verb="$1"
  shift

  local vm_name
  case $# in
    0) vm_name="$(_agent_vm_name "$(pwd)")" || return 1 ;;
    1)
      vm_name="$1"
      case "$vm_name" in
        agent-vm-*) ;;
        *)
          echo "Error: '$vm_name' is not an agent-vm VM name (they start with 'agent-vm-')." >&2
          echo "Run 'agent-vm list' to see them." >&2
          return 1 ;;
      esac ;;
    *)
      echo "Usage: agent-vm $verb [vm-name]" >&2
      return 1 ;;
  esac

  local st=0
  _agent_vm_exists "$vm_name" || st=$?
  case "$st" in
    0) ;;
    1)
      if [[ $# -eq 0 ]]; then
        echo "No VM found for this directory." >&2
        echo "Run 'agent-vm list' to see existing VMs, then 'agent-vm $verb <vm-name>'." >&2
      else
        echo "Error: no such VM: $vm_name" >&2
        echo "Run 'agent-vm list' to see existing VMs." >&2
      fi
      return 1 ;;
    *)
      echo "Error: could not query Lima. Is it installed and working?" >&2
      return 1 ;;
  esac

  echo "$vm_name"
}

_agent_vm_stop() {
  local vm_name
  vm_name="$(_agent_vm_resolve_target stop "$@")" || return 1

  echo "Stopping VM '$vm_name'..."
  limactl stop "$vm_name" &>/dev/null
  echo "VM stopped."
}

_agent_vm_destroy() {
  local vm_name
  vm_name="$(_agent_vm_resolve_target rm "$@")" || return 1

  echo "Stopping and deleting VM '$vm_name'..."
  limactl stop "$vm_name" &>/dev/null
  limactl delete "$vm_name" --force &>/dev/null
  _agent_vm_cleanup_state "$vm_name"
  echo "VM destroyed."
}

# Every agent-vm VM, the base template included: this is the command that
# gives the disk space back. `agent-vm setup` rebuilds the template.
_agent_vm_destroy_all() {
  local list vms
  if ! list="$(limactl list -q 2>/dev/null)"; then
    echo "Error: could not query Lima. Is it installed and working?" >&2
    return 1
  fi
  vms="$(printf '%s\n' "$list" | grep "^agent-vm-" || true)"
  if [[ -z "$vms" ]]; then
    echo "No agent-vm VMs found."
    return 0
  fi
  echo "This will destroy the following VMs:"
  echo "$vms"
  if _agent_vm_has_line "$vms" "$AGENT_VM_TEMPLATE"; then
    echo "($AGENT_VM_TEMPLATE is the base template: 'agent-vm setup' rebuilds it.)"
  fi
  printf "Continue? [y/N] " >&2
  local reply=""
  IFS= read -r reply 2>/dev/null </dev/tty || reply=""
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi
  _agent_vm_destroy_vms "$vms"
  echo "All VMs destroyed."
}

# Stop, delete and forget each VM named on its own line in $1.
# limactl gets /dev/null as stdin: the names are read from stdin, and a limactl
# that reads it would swallow the ones still to come.
_agent_vm_destroy_vms() {
  local vm
  while IFS= read -r vm; do
    [[ -n "$vm" ]] || continue
    echo "Destroying $vm..."
    limactl stop "$vm" </dev/null &>/dev/null
    limactl delete "$vm" --force </dev/null &>/dev/null
    _agent_vm_cleanup_state "$vm"
  done <<< "$1"
}

_agent_vm_list() {
  limactl list | head -1
  limactl list | grep "^agent-vm-" || echo "(no VMs)"
}

_agent_vm_status() {
  local host_dir
  host_dir="$(pwd)"
  local current_vm_name
  current_vm_name="$(_agent_vm_name "$host_dir")" || return 1

  local list
  if ! list="$(limactl list 2>/dev/null)"; then
    echo "Error: could not query Lima. Is it installed and working?" >&2
    return 1
  fi

  echo "VMs (current directory: $host_dir):"
  echo ""
  # Read from a here-string, not a pipe: the exit status of a piped loop is
  # the loop's own, so a `|| echo "(no VMs)"` after it could never fire.
  local line header="" found=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ -z "$header" ]]; then
      header=1
      echo "  $line"
      continue
    fi
    case "$line" in
      "$current_vm_name "*) echo "> $line"; found=1 ;;
      agent-vm-*)           echo "  $line"; found=1 ;;
    esac
  done <<< "$list"
  [[ -n "$found" ]] || echo "  (no VMs)"
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

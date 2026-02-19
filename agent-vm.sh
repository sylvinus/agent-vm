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
#   agent-vm shell    - Open a shell in the persistent VM for cwd
#   agent-vm stop     - Stop the VM for cwd
#   agent-vm destroy  - Stop and delete the VM for cwd
#   agent-vm list     - List all agent-vm VMs
#   agent-vm status   - Show VM status for cwd
#   agent-vm help     - Show help
#

AGENT_VM_TEMPLATE="agent-vm-base"
AGENT_VM_STATE_DIR="${HOME}/.agent-vm"
AGENT_VM_CONFIG_DIR="${HOME}/.claude"
AGENT_VM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

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

# Ensure the VM for cwd exists and is running, creating/starting as needed
# Usage: _agent_vm_ensure_running <vm_name> <host_dir> [--disk GB] [--memory GB] [--reset]
_agent_vm_ensure_running() {
  local vm_name="$1"
  local host_dir="$2"
  shift 2
  local disk="" memory="" reset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)   disk="$2"; shift 2 ;;
      --memory) memory="$2"; shift 2 ;;
      --reset)  reset=1; shift ;;
      *)        shift ;;
    esac
  done

  if ! limactl list -q 2>/dev/null | grep -q "^${AGENT_VM_TEMPLATE}$"; then
    echo "Error: Base VM not found. Run 'agent-vm setup' first." >&2
    return 1
  fi

  mkdir -p "$AGENT_VM_CONFIG_DIR"

  # Destroy existing VM if --reset was requested
  if [[ -n "$reset" ]] && _agent_vm_exists "$vm_name"; then
    echo "Resetting VM '$vm_name'..."
    limactl stop "$vm_name" &>/dev/null
    limactl delete "$vm_name" --force &>/dev/null
    rm -f "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
  fi

  if ! _agent_vm_exists "$vm_name"; then
    echo "Creating VM '$vm_name'..."
    local clone_args=(
      --set ".mounts=[{\"location\":\"${host_dir}\",\"writable\":true},{\"location\":\"${AGENT_VM_CONFIG_DIR}\",\"mountPoint\":\"/home/${USER}.linux/.claude\",\"writable\":true}]"
      --tty=false
    )
    [[ -n "$disk" ]]   && clone_args+=(--set ".disk=\"${disk}GiB\"")
    [[ -n "$memory" ]] && clone_args+=(--set ".memory=\"${memory}GiB\"")
    limactl clone "$AGENT_VM_TEMPLATE" "$vm_name" "${clone_args[@]}" &>/dev/null
    # Record which base version this VM was cloned from
    local base_ver="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
    if [[ -f "$base_ver" ]]; then
      cp "$base_ver" "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
    fi
  elif [[ -n "$disk" || -n "$memory" ]]; then
    # Auto-resize existing VM if --disk or --memory changed
    local edit_args=()
    [[ -n "$disk" ]]   && edit_args+=(--set ".disk=\"${disk}GiB\"")
    [[ -n "$memory" ]] && edit_args+=(--set ".memory=\"${memory}GiB\"")
    if _agent_vm_running "$vm_name"; then
      echo "VM '$vm_name' is currently running. It must be stopped to apply new resource settings."
      printf "Stop the VM and apply changes? [y/N] "
      local reply
      read -r reply
      if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborted. Starting with current settings."
        return 0
      fi
      echo "Stopping VM..."
      limactl stop "$vm_name" &>/dev/null
    fi
    echo "Updating VM resources..."
    limactl edit "$vm_name" "${edit_args[@]}" &>/dev/null
  fi

  # Warn if this VM was cloned from an older base
  local base_ver="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
  local vm_ver="$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
  if [[ -f "$base_ver" ]] && { [[ ! -f "$vm_ver" ]] || [[ "$(cat "$base_ver")" != "$(cat "$vm_ver")" ]]; }; then
    echo "Warning: Base VM has been updated since this VM was cloned. Use --reset to re-clone from the new base." >&2
  fi

  if ! _agent_vm_running "$vm_name"; then
    echo "Starting VM '$vm_name'..."
    limactl start "$vm_name" &>/dev/null
  fi

  # Run project-specific runtime script if it exists
  if [ -f "${host_dir}/.agent-vm.runtime.sh" ]; then
    echo "Running project runtime setup..."
    limactl shell --workdir "$host_dir" "$vm_name" zsh -l < "${host_dir}/.agent-vm.runtime.sh"
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
      --memory)
        vm_opts+=(--memory "$2"); shift 2 ;;
      --memory=*)
        vm_opts+=(--memory "${1#*=}"); shift ;;
      --reset)
        vm_opts+=(--reset); shift ;;
      *)
        break ;;
    esac
  done

  local cmd="${1:-help}"
  shift 2>/dev/null || true

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
    shell)
      _agent_vm_shell "${vm_opts[@]}" "$@"
      ;;
    stop)
      _agent_vm_stop "$@"
      ;;
    destroy)
      _agent_vm_destroy "$@"
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
  shell              Open a shell in the VM for the current directory
  stop               Stop the VM for the current directory
  destroy            Stop and delete the VM for the current directory
  list               List all agent-vm VMs
  status             Show VM status for the current directory
  help               Show this help

VM options (for claude, opencode, codex, shell):
  --disk GB          VM disk size (default: 20)
  --memory GB        VM memory (default: 8)
  --reset            Destroy and re-clone the VM from the base template

Examples:
  agent-vm setup                             # Create base VM
  agent-vm claude                            # Run Claude in a VM
  agent-vm opencode                          # Run OpenCode in a VM
  agent-vm codex                             # Run Codex in a VM
  agent-vm --disk 50 --memory 16 claude      # With custom resources
  agent-vm --reset claude                    # Fresh VM from base template
  agent-vm shell                             # Shell into the VM
  agent-vm claude -p "fix lint errors"       # Pass args to claude

VMs are persistent and unique per directory. Running "agent-vm shell" or
"agent-vm claude" in the same directory will reuse the same VM.

Customization:
  ~/.agent-vm.setup.sh              Per-user setup (runs during "agent-vm setup")
  <project>/.agent-vm.runtime.sh    Per-project setup (runs on each VM start)

More info: https://github.com/sylvinus/agent-vm
EOF
}

_agent_vm_setup() {
  local disk=20
  local memory=8

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: agent-vm setup [--disk GB] [--memory GB]"
        echo ""
        echo "Create a base VM template with dev tools and agents pre-installed."
        echo ""
        echo "Options:"
        echo "  --disk GB      VM disk size (default: 20)"
        echo "  --memory GB    VM memory (default: 8)"
        echo "  --help         Show this help"
        return 0
        ;;
      --disk)
        disk="$2"
        shift 2
        ;;
      --disk=*)
        disk="${1#*=}"
        shift
        ;;
      --memory)
        memory="$2"
        shift 2
        ;;
      --memory=*)
        memory="${1#*=}"
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Usage: agent-vm setup [--disk GB] [--memory GB]" >&2
        return 1
        ;;
    esac
  done

  if ! command -v limactl &>/dev/null; then
    if command -v brew &>/dev/null; then
      echo "Installing Lima..."
      brew install lima
    else
      echo "Error: Lima is required. Install from https://lima-vm.io/docs/installation/" >&2
      return 1
    fi
  fi

  limactl stop "$AGENT_VM_TEMPLATE" &>/dev/null
  limactl delete "$AGENT_VM_TEMPLATE" --force &>/dev/null

  echo "Creating base VM..."
  limactl create --name="$AGENT_VM_TEMPLATE" template:debian-13 \
    --set '.mounts=[]' \
    --disk="$disk" \
    --memory="$memory" \
    --tty=false &>/dev/null || { echo "Error: Failed to create base VM." >&2; return 1; }
  limactl start "$AGENT_VM_TEMPLATE" &>/dev/null || { echo "Error: Failed to start base VM." >&2; return 1; }

  # Run the setup script inside the VM
  echo "Installing packages inside VM..."
  limactl shell "$AGENT_VM_TEMPLATE" bash -l < "${AGENT_VM_SCRIPT_DIR}/agent-vm.setup.sh" || { echo "Error: Setup script failed." >&2; return 1; }

  # Run user's custom setup script if it exists
  local user_setup="$HOME/.agent-vm.setup.sh"
  if [ -f "$user_setup" ]; then
    echo "Running custom setup from $user_setup..."
    limactl shell "$AGENT_VM_TEMPLATE" zsh -l < "$user_setup" || { echo "Error: Custom setup script failed." >&2; return 1; }
  fi

  limactl stop "$AGENT_VM_TEMPLATE" &>/dev/null

  mkdir -p "$AGENT_VM_CONFIG_DIR"

  # Record base VM version so we can warn about stale clones
  mkdir -p "$AGENT_VM_STATE_DIR"
  date +%s > "$AGENT_VM_STATE_DIR/.agent-vm-base-version"

  echo ""
  echo "Base VM ready. Run 'agent-vm shell', 'agent-vm claude', 'agent-vm opencode', or 'agent-vm codex' in any project directory."
  echo "Note: Existing VMs were not updated. Use --reset to re-clone them from the new base."
}

_agent_vm_claude() {
  local vm_opts=()
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)   vm_opts+=(--disk "$2"); shift 2 ;;
      --memory) vm_opts+=(--memory "$2"); shift 2 ;;
      --reset)  vm_opts+=(--reset); shift ;;
      *)        args+=("$1"); shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1

  limactl shell --workdir "$host_dir" "$vm_name" claude --dangerously-skip-permissions "${args[@]}"
}

_agent_vm_opencode() {
  local vm_opts=()
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)   vm_opts+=(--disk "$2"); shift 2 ;;
      --memory) vm_opts+=(--memory "$2"); shift 2 ;;
      --reset)  vm_opts+=(--reset); shift ;;
      *)        args+=("$1"); shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1

  limactl shell --workdir "$host_dir" "$vm_name" opencode --dangerously-skip-permissions "${args[@]}"
}

_agent_vm_codex() {
  local vm_opts=()
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)   vm_opts+=(--disk "$2"); shift 2 ;;
      --memory) vm_opts+=(--memory "$2"); shift 2 ;;
      --reset)  vm_opts+=(--reset); shift ;;
      *)        args+=("$1"); shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1

  limactl shell --workdir "$host_dir" "$vm_name" codex --full-auto "${args[@]}"
}

_agent_vm_shell() {
  local vm_opts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)   vm_opts+=(--disk "$2"); shift 2 ;;
      --memory) vm_opts+=(--memory "$2"); shift 2 ;;
      --reset)  vm_opts+=(--reset); shift ;;
      *)        shift ;;
    esac
  done
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  _agent_vm_ensure_running "$vm_name" "$host_dir" "${vm_opts[@]}" || return 1

  echo "VM: $vm_name | Dir: $host_dir"
  echo "Type 'exit' to leave (VM keeps running). Use 'agent-vm stop' to stop it."
  limactl shell --workdir "$host_dir" "$vm_name" zsh -l
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
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
  echo "VM destroyed."
}

_agent_vm_list() {
  limactl list | head -1
  limactl list | grep "^agent-vm-" || echo "(no VMs)"
}

_agent_vm_status() {
  local host_dir
  host_dir="$(pwd)"
  local vm_name
  vm_name="$(_agent_vm_name "$host_dir")"

  if ! _agent_vm_exists "$vm_name"; then
    echo "No VM for this directory."
    echo "VM name: $vm_name"
    return 0
  fi

  echo "VM name: $vm_name"
  limactl list | head -1
  limactl list | grep "$vm_name"
}

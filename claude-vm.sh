#!/usr/bin/env bash
#
# agent-vm / claude-vm: Run Claude Code inside a sandboxed Lima VM
# Part of https://github.com/sylvinus/agent-vm
#
# Source this file in your shell config:
#   source /path/to/agent-vm/claude-vm.sh
#
# Functions:
#   claude-vm-setup  - Create the VM template (run once)
#   claude-vm [args] - Run Claude in a fresh VM with cwd mounted (args forwarded to claude)
#   claude-vm-shell  - Open a debug shell in a fresh VM

CLAUDE_VM_TEMPLATE="claude-template"

claude-vm-setup() {
  local minimal=false
  local disk=20
  local memory=8

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: claude-vm-setup [--minimal] [--disk GB] [--memory GB]"
        echo ""
        echo "Create a VM template with Claude Code pre-installed."
        echo ""
        echo "Options:"
        echo "  --minimal      Only install git, curl, jq, and Claude Code"
        echo "  --disk GB      VM disk size (default: 20)"
        echo "  --memory GB    VM memory (default: 8)"
        echo "  --help         Show this help"
        return 0
        ;;
      --minimal)
        minimal=true
        shift
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
        echo "Usage: claude-vm-setup [--minimal] [--disk GB] [--memory GB]" >&2
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

  limactl stop "$CLAUDE_VM_TEMPLATE" &>/dev/null
  limactl delete "$CLAUDE_VM_TEMPLATE" --force &>/dev/null

  echo "Creating VM template..."
  limactl create --name="$CLAUDE_VM_TEMPLATE" template:debian-13 \
    --set '.mounts=[]' \
    --disk="$disk" \
    --memory="$memory" \
    --tty=false
  limactl start "$CLAUDE_VM_TEMPLATE"

  # Disable needrestart's interactive prompts
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo bash -c 'mkdir -p /etc/needrestart/conf.d && echo "\$nrconf{restart} = '"'"'a'"'"';" > /etc/needrestart/conf.d/no-prompt.conf'

  echo "Installing base packages..."
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get update
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl jq

  if ! $minimal; then
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      wget build-essential \
      python3 python3-pip python3-venv \
      ripgrep fd-find htop \
      unzip zip \
      ca-certificates

    # Install Docker from official repo (includes docker compose)
    echo "Installing Docker..."
    limactl shell "$CLAUDE_VM_TEMPLATE" bash -c '
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      sudo chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    '
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get update
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Add user to docker group
    limactl shell "$CLAUDE_VM_TEMPLATE" bash -c 'sudo usermod -aG docker $(whoami)'

    # Install Node.js 22 (needed for MCP servers)
    echo "Installing Node.js 22..."
    limactl shell "$CLAUDE_VM_TEMPLATE" bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

    # Install Chromium and dependencies for headless browsing
    echo "Installing Chromium..."
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      chromium \
      fonts-liberation \
      xvfb
    # Symlink so tools looking for google-chrome find Chromium
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome-stable
    limactl shell "$CLAUDE_VM_TEMPLATE" bash -c 'sudo mkdir -p /opt/google/chrome && sudo ln -sf /usr/bin/chromium /opt/google/chrome/chrome'
  fi

  # Install Claude Code
  echo "Installing Claude Code..."
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -c "curl -fsSL https://claude.ai/install.sh | bash"
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -c 'echo "export PATH=\$HOME/.local/bin:\$HOME/.claude/local/bin:\$PATH" >> ~/.bashrc'

  # Authenticate Claude (saves token in template, inherited by clones)
  echo "Setting up Claude authentication..."
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -lc "claude 'Ok I am logged in, I can exit now.'"

  if ! $minimal; then
    # Configure Chrome DevTools MCP server for Claude
    echo "Configuring Chrome MCP server..."
    limactl shell "$CLAUDE_VM_TEMPLATE" bash << 'VMEOF'
CONFIG="$HOME/.claude.json"
if [ -f "$CONFIG" ]; then
  jq '.mcpServers["chrome-devtools"] = {
    "command": "npx",
    "args": ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
  }' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
else
  cat > "$CONFIG" << 'JSON'
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
    }
  }
}
JSON
fi
VMEOF
  fi

  # Run user's custom setup script if it exists
  local user_setup="$HOME/.claude-vm.setup.sh"
  if [ -f "$user_setup" ]; then
    echo "Running custom setup from $user_setup..."
    limactl shell "$CLAUDE_VM_TEMPLATE" bash < "$user_setup"
  fi

  limactl stop "$CLAUDE_VM_TEMPLATE"

  echo "Template ready. Run 'claude-vm' in any project directory."
}

claude-vm() {
  local args=("$@")
  local vm_name="claude-$(basename "$(pwd)" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')-$$"
  local host_dir="$(pwd)"

  if ! limactl list -q 2>/dev/null | grep -q "^${CLAUDE_VM_TEMPLATE}$"; then
    echo "Error: Template VM not found. Run 'claude-vm-setup' first." >&2
    return 1
  fi

  _claude_vm_cleanup() {
    echo "Cleaning up VM..."
    limactl stop "$vm_name" &>/dev/null
    limactl delete "$vm_name" --force &>/dev/null
  }
  trap _claude_vm_cleanup EXIT INT TERM

  echo "Starting VM '$vm_name'..."
  limactl clone "$CLAUDE_VM_TEMPLATE" "$vm_name" \
    --set ".mounts=[{\"location\":\"${host_dir}\",\"writable\":true}]" \
    --tty=false &>/dev/null

  limactl start "$vm_name" &>/dev/null

  # Run project-specific runtime script if it exists
  if [ -f "${host_dir}/.claude-vm.runtime.sh" ]; then
    echo "Running project runtime setup..."
    limactl shell --workdir "$host_dir" "$vm_name" bash -l < "${host_dir}/.claude-vm.runtime.sh"
  fi

  limactl shell --workdir "$host_dir" "$vm_name" claude --dangerously-skip-permissions "${args[@]}"

  _claude_vm_cleanup
  trap - EXIT INT TERM
}

claude-vm-shell() {
  local vm_name="claude-debug-$$"
  local host_dir="$(pwd)"

  if ! limactl list -q 2>/dev/null | grep -q "^${CLAUDE_VM_TEMPLATE}$"; then
    echo "Error: Template VM not found. Run 'claude-vm-setup' first." >&2
    return 1
  fi

  _claude_vm_shell_cleanup() {
    echo "Cleaning up VM..."
    limactl stop "$vm_name" &>/dev/null
    limactl delete "$vm_name" --force &>/dev/null
  }
  trap _claude_vm_shell_cleanup EXIT INT TERM

  limactl clone "$CLAUDE_VM_TEMPLATE" "$vm_name" \
    --set ".mounts=[{\"location\":\"${host_dir}\",\"writable\":true}]" \
    --tty=false &>/dev/null

  limactl start "$vm_name" &>/dev/null

  # Run project-specific runtime script if it exists
  if [ -f "${host_dir}/.claude-vm.runtime.sh" ]; then
    limactl shell --workdir "$host_dir" "$vm_name" bash -l < "${host_dir}/.claude-vm.runtime.sh"
  fi

  echo "VM: $vm_name | Dir: $host_dir"
  echo "Type 'exit' to stop and delete the VM"
  limactl shell --workdir "$host_dir" "$vm_name" bash -l

  _claude_vm_shell_cleanup
  trap - EXIT INT TERM
}

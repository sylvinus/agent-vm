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
#   claude-vm        - Run Claude in a fresh VM with cwd mounted
#   claude-vm-shell  - Open a debug shell in a fresh VM

CLAUDE_VM_TEMPLATE="claude-template"

claude-vm-setup() {
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
    --disk=20 \
    --memory=8 \
    --tty=false
  limactl start "$CLAUDE_VM_TEMPLATE"

  # Disable needrestart's interactive prompts
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo bash -c 'mkdir -p /etc/needrestart/conf.d && echo "\$nrconf{restart} = '"'"'a'"'"';" > /etc/needrestart/conf.d/no-prompt.conf'

  echo "Installing base packages..."
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get update
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl wget build-essential \
    python3 python3-pip python3-venv \
    jq ripgrep fd-find htop \
    unzip zip \
    docker.io

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

  # Install Claude Code
  echo "Installing Claude Code..."
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -c "curl -fsSL https://claude.ai/install.sh | bash"
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -c 'echo "export PATH=\$HOME/.local/bin:\$HOME/.claude/local/bin:\$PATH" >> ~/.bashrc'

  # Authenticate Claude (saves token in template, inherited by clones)
  echo "Setting up Claude authentication..."
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -lc "claude setup-token"

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
  local vm_name="claude-$(basename "$(pwd)" | tr -cs 'a-zA-Z0-9-' '-')-$$"
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

  limactl shell --workdir "$host_dir" "$vm_name" claude --dangerously-skip-permissions

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

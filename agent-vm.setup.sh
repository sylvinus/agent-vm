#!/usr/bin/env bash
#
# agent-vm.setup.sh: Package installation script that runs inside the base VM
# Part of https://github.com/sylvinus/agent-vm
#
# This script is executed inside the VM during "agent-vm setup".
#

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Disable needrestart's interactive prompts
sudo mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = '"'"'a'"'"';' | sudo tee /etc/needrestart/conf.d/no-prompt.conf > /dev/null

echo "Installing base packages..."
sudo apt-get update
sudo apt-get install -y \
  git curl jq zsh \
  wget build-essential \
  python3 python3-pip python3-venv \
  ripgrep fd-find htop \
  unzip zip \
  ca-certificates \
  iptables \
  libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev

# Set zsh as default shell
sudo chsh -s /usr/bin/zsh "$(whoami)"

# Install mise (polyglot version manager for Ruby, Python, Node, etc.)
echo "Installing mise..."
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshenv

# Install Docker from official repo (includes docker compose)
echo "Installing Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$(whoami)"

# Install Node.js 24 LTS (needed for MCP servers)
echo "Installing Node.js 24..."
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install Chromium and dependencies for headless browsing
echo "Installing Chromium..."
sudo apt-get install -y chromium fonts-liberation xvfb
sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome
sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome-stable
sudo mkdir -p /opt/google/chrome
sudo ln -sf /usr/bin/chromium /opt/google/chrome/chrome

# Install GitHub CLI from official repo
echo "Installing GitHub CLI..."
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

# Install Claude Code
echo "Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash
echo 'export PATH=$HOME/.local/bin:$HOME/.claude/local/bin:$PATH' >> ~/.zshrc
echo 'export PS1="vm:%1~%% "' >> ~/.zshrc

# Install OpenCode
echo "Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash
echo 'export PATH=$HOME/.opencode/bin:$PATH' >> ~/.zshrc

# Add PATH to .zshenv so non-interactive shells (limactl shell vmname cmd) also find the tools
echo 'export PATH=$HOME/.local/bin:$HOME/.claude/local/bin:$HOME/.opencode/bin:$PATH' >> ~/.zshenv

# Install Codex CLI
echo "Installing Codex CLI..."
sudo npm i -g @openai/codex

# Install Mistral Vibe (installs uv and the `vibe`/`vibe-acp` commands into ~/.local/bin).
# This setup script runs under bash, but the PATH export lives in ~/.zshrc/~/.zshenv, so
# ~/.local/bin isn't on PATH here yet. The Vibe installer exits non-zero (aborting setup
# under `set -e`) if it can't find its install dir on PATH, so export it for this session.
echo "Installing Mistral Vibe..."
export PATH="$HOME/.local/bin:$PATH"
curl -LsSf https://mistral.ai/vibe/install.sh | bash

# Configure Chrome DevTools MCP server for Claude
echo "Configuring Chrome MCP server for Claude..."
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

# Configure Chrome DevTools MCP server for OpenCode
echo "Configuring Chrome MCP server for OpenCode..."
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
mkdir -p "$OPENCODE_CONFIG_DIR"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"
if [ -f "$OPENCODE_CONFIG" ]; then
  jq '.mcp["chrome-devtools"] = {
    "type": "local",
    "command": ["npx", "-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"],
    "enabled": true
  }' "$OPENCODE_CONFIG" > "$OPENCODE_CONFIG.tmp" && mv "$OPENCODE_CONFIG.tmp" "$OPENCODE_CONFIG"
else
  cat > "$OPENCODE_CONFIG" << 'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "chrome-devtools": {
      "type": "local",
      "command": ["npx", "-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"],
      "enabled": true
    }
  }
}
JSON
fi

# Configure Chrome DevTools MCP server for Vibe
# Vibe uses TOML; append an array-of-tables entry (valid even if the wizard later
# writes to the same file). Guard against duplicates on repeated setup runs.
echo "Configuring Chrome MCP server for Vibe..."
VIBE_CONFIG_DIR="$HOME/.vibe"
mkdir -p "$VIBE_CONFIG_DIR"
VIBE_CONFIG="$VIBE_CONFIG_DIR/config.toml"
if ! grep -q 'name = "chrome-devtools"' "$VIBE_CONFIG" 2>/dev/null; then
  cat >> "$VIBE_CONFIG" << 'TOML'

[[mcp_servers]]
name = "chrome-devtools"
transport = "stdio"
command = "npx"
args = ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
TOML
fi

echo "VM setup complete."

#!/usr/bin/env bash
#
# agent-vm.setup.sh: Package installation script that runs inside the base VM
# Part of https://github.com/sylvinus/agent-vm
#
# This script is executed inside the VM during "agent-vm setup".
#

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Component toggles. The host wizard prepends `export` lines for these before
# piping the script in. Members of the default install set (everything except
# Ruby/Rust/Go) default to 1 so running this script standalone (without the
# wizard) produces the same install you'd get from `agent-vm setup --preinstall=default`.
INSTALL_PYTHON="${AGENT_VM_INSTALL_PYTHON:-1}"
INSTALL_NODE="${AGENT_VM_INSTALL_NODE:-1}"
INSTALL_RUBY="${AGENT_VM_INSTALL_RUBY:-0}"
INSTALL_RUST="${AGENT_VM_INSTALL_RUST:-0}"
INSTALL_GOLANG="${AGENT_VM_INSTALL_GOLANG:-0}"
INSTALL_DOCKER="${AGENT_VM_INSTALL_DOCKER:-1}"
INSTALL_CHROMIUM="${AGENT_VM_INSTALL_CHROMIUM:-1}"
INSTALL_GH="${AGENT_VM_INSTALL_GH:-1}"
INSTALL_CLAUDE="${AGENT_VM_INSTALL_CLAUDE:-1}"
INSTALL_OPENCODE="${AGENT_VM_INSTALL_OPENCODE:-1}"
INSTALL_CODEX="${AGENT_VM_INSTALL_CODEX:-1}"
INSTALL_VIBE="${AGENT_VM_INSTALL_VIBE:-1}"

# Several installers (Claude Code, Vibe, …) check PATH at install time and
# print a "~/.local/bin is not in your PATH" warning otherwise. The persistent
# PATH lives in ~/.zshrc / ~/.zshenv (added below), so once the user opens a
# VM shell it's fine — but this bash script runs under a fresh session that
# doesn't see those edits yet. Export it here so installers stay quiet.
export PATH="$HOME/.local/bin:$PATH"

# Disable needrestart's interactive prompts
sudo mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = '"'"'a'"'"';' | sudo tee /etc/needrestart/conf.d/no-prompt.conf > /dev/null

# Base packages always installed: core CLI tools plus the dev libraries needed
# to compile Ruby/Python/Node versions via mise (kept here so that toggling a
# language off doesn't strip the libs the user may still want to build with).
echo "Installing base packages..."
sudo apt-get update
sudo apt-get install -y \
  git curl jq zsh \
  wget build-essential \
  ripgrep fd-find htop \
  unzip zip \
  ca-certificates \
  iptables \
  libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev

if [[ "$INSTALL_PYTHON" == "1" ]]; then
  echo "Installing Python 3..."
  sudo apt-get install -y python3 python3-pip python3-venv
fi

if [[ "$INSTALL_RUBY" == "1" ]]; then
  echo "Installing Ruby..."
  sudo apt-get install -y ruby-full
fi

if [[ "$INSTALL_GOLANG" == "1" ]]; then
  echo "Installing Go..."
  sudo apt-get install -y golang-go
fi

if [[ "$INSTALL_RUST" == "1" ]]; then
  # Rustup is the canonical Rust installer. --no-modify-path keeps it from
  # editing ~/.profile/~/.bashrc — we add ~/.cargo/bin to zsh's PATH below.
  echo "Installing Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable
  echo 'export PATH=$HOME/.cargo/bin:$PATH' >> ~/.zshrc
  echo 'export PATH=$HOME/.cargo/bin:$PATH' >> ~/.zshenv
fi

# Set zsh as default shell
sudo chsh -s /usr/bin/zsh "$(whoami)"

# Always set the VM prompt and put ~/.local/bin on PATH (mise installs there;
# Vibe's installer puts `vibe`/`vibe-acp` there too).
echo 'export PS1="vm:%1~%% "' >> ~/.zshrc
echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.zshrc
echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.zshenv

# Auto-source ~/.agent-vm.env if present. The host pushes ~/.agent-vm/env into
# this path on every `agent-vm` invocation (see _agent_vm_ensure_running), so
# tokens/API keys defined there propagate to every shell in the VM. `set -a`
# auto-exports each KEY=value line, so the file content stays a plain dotenv.
echo '[ -f "$HOME/.agent-vm.env" ] && { set -a; . "$HOME/.agent-vm.env"; set +a; }' >> ~/.zshenv

# Install mise (polyglot version manager for Ruby, Python, Node, etc.).
# Always installed so users can `mise install ruby@latest`, etc., even when
# they've opted out of preinstalled Node.
echo "Installing mise..."
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshenv

if [[ "$INSTALL_DOCKER" == "1" ]]; then
  # Install Docker from official repo (includes docker compose)
  echo "Installing Docker..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$(whoami)"
fi

if [[ "$INSTALL_NODE" == "1" ]]; then
  # Install Node.js 24 LTS (needed for MCP servers and Codex CLI)
  echo "Installing Node.js 24..."
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

if [[ "$INSTALL_CHROMIUM" == "1" ]]; then
  # Install Chromium and dependencies for headless browsing
  echo "Installing Chromium..."
  sudo apt-get install -y chromium fonts-liberation xvfb
  sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome
  sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome-stable
  sudo mkdir -p /opt/google/chrome
  sudo ln -sf /usr/bin/chromium /opt/google/chrome/chrome
fi

if [[ "$INSTALL_GH" == "1" ]]; then
  # Install GitHub CLI from official repo
  echo "Installing GitHub CLI..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y gh
fi

if [[ "$INSTALL_CLAUDE" == "1" ]]; then
  echo "Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
  echo 'export PATH=$HOME/.claude/local/bin:$PATH' >> ~/.zshrc
  echo 'export PATH=$HOME/.claude/local/bin:$PATH' >> ~/.zshenv

  # Enforce full autonomy via *managed* settings (highest precedence), not the
  # user's ~/.claude/. A user can bind-mount or overwrite their own ~/.claude/
  # dir freely; this system-level policy is untouched and always wins.
  #
  # Why not just rely on the `claude --dangerously-skip-permissions` launch flag:
  # Claude Code relaunches itself in-process on self-update and on the first-run
  # fullscreen-TUI opt-in, and the relaunched process drops the CLI flag (see
  # https://github.com/anthropics/claude-code/issues/72479), reverting to the
  # "ask" permission mode. Settings are re-read on every (re)launch, so encoding
  # the policy here makes it survive those relaunches. `tui: fullscreen` also
  # pins fullscreen from the first launch, so the opt-in relaunch never fires.
  echo "Configuring Claude managed settings (bypass permissions + fullscreen)..."
  sudo mkdir -p /etc/claude-code
  cat << 'JSON' | sudo tee /etc/claude-code/managed-settings.json > /dev/null
{
  "permissions": { "defaultMode": "bypassPermissions" },
  "tui": "fullscreen"
}
JSON
fi

if [[ "$INSTALL_OPENCODE" == "1" ]]; then
  echo "Installing OpenCode..."
  curl -fsSL https://opencode.ai/install | bash
  echo 'export PATH=$HOME/.opencode/bin:$PATH' >> ~/.zshrc
  echo 'export PATH=$HOME/.opencode/bin:$PATH' >> ~/.zshenv
fi

if [[ "$INSTALL_CODEX" == "1" ]]; then
  if [[ "$INSTALL_NODE" != "1" ]]; then
    echo "Skipping Codex CLI: requires Node.js (re-run setup with Node.js enabled)." >&2
  else
    echo "Installing Codex CLI..."
    sudo npm i -g @openai/codex
  fi
fi

if [[ "$INSTALL_VIBE" == "1" ]]; then
  # Vibe installs `uv` and the `vibe`/`vibe-acp` commands into ~/.local/bin.
  # PATH was already exported at the top of this script so the installer
  # doesn't abort on its own PATH check.
  echo "Installing Mistral Vibe..."
  curl -LsSf https://mistral.ai/vibe/install.sh | bash
fi

# Chrome DevTools MCP runs via `npx` and controls the local Chromium binary, so
# only configure it when both dependencies and at least one target agent exist.
if [[ "$INSTALL_NODE" == "1" && "$INSTALL_CHROMIUM" == "1" ]]; then
  if [[ "$INSTALL_CLAUDE" == "1" ]]; then
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
  fi

  if [[ "$INSTALL_OPENCODE" == "1" ]]; then
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
  fi

  if [[ "$INSTALL_VIBE" == "1" ]]; then
    # Vibe uses TOML; append an array-of-tables entry (valid even if the wizard
    # later writes to the same file). Guard against duplicates on repeated runs.
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
  fi

  if [[ "$INSTALL_CODEX" == "1" ]]; then
    # Codex CLI uses TOML at ~/.codex/config.toml with [mcp_servers.NAME]
    # tables. Append the chrome-devtools entry; guard against duplicates on
    # repeated setup runs.
    echo "Configuring Chrome MCP server for Codex..."
    CODEX_CONFIG_DIR="$HOME/.codex"
    mkdir -p "$CODEX_CONFIG_DIR"
    CODEX_CONFIG="$CODEX_CONFIG_DIR/config.toml"
    if ! grep -q '\[mcp_servers\.chrome-devtools\]' "$CODEX_CONFIG" 2>/dev/null; then
      cat >> "$CODEX_CONFIG" << 'TOML'

[mcp_servers.chrome-devtools]
command = "npx"
args = ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
TOML
    fi
  fi
elif [[ "$INSTALL_CLAUDE" == "1" || "$INSTALL_OPENCODE" == "1" || "$INSTALL_CODEX" == "1" || "$INSTALL_VIBE" == "1" ]]; then
  echo "Skipping Chrome MCP config: requires Node.js and Chromium." >&2
fi

echo "VM setup complete."

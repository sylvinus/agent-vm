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
# MCP servers wired into every installed agent's config. Only servers with a
# dependency worth baking into the image get a toggle; remote MCP servers are
# a URL (and often a secret) and belong in per-project config, not in an image
# every VM is cloned from. mcp-playwright is opt-in: a second browser-driving
# MCP alongside mcp-chrome is redundant for most users, and every wired server
# costs tool definitions in the agent's context.
INSTALL_MCP_CHROME="${AGENT_VM_INSTALL_MCP_CHROME:-1}"
INSTALL_MCP_PLAYWRIGHT="${AGENT_VM_INSTALL_MCP_PLAYWRIGHT:-0}"

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

# Wire one stdio MCP server into every installed agent's config. Each agent
# stores MCP servers in its own format, so that mapping is written once here
# instead of being copy-pasted per server.
#
# Usage: configure_mcp <server-name> <command> [arg...]
#   configure_mcp chrome-devtools npx -y chrome-devtools-mcp@latest --headless=true
#
# Passing a command (rather than assuming npx) is what lets a server be
# launched through `env VAR=value npx ...`: every one of the four formats below
# runs a command with arguments, but only some support a separate env block.
#
# The args are rendered once as a JSON array; a JSON array of strings is also a
# valid TOML array, so the same value serves all four formats.
configure_mcp() {
  # Not named `command`: that is a shell builtin, and shadowing its name in a
  # file that uses `command -v` elsewhere invites a double-take.
  local name="$1" cmd="$2"
  shift 2
  # One arg per line into jq -R, so an argument containing a newline would be
  # split. None of the callers pass one.
  local args_json
  args_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"

  if [[ "$INSTALL_CLAUDE" == "1" ]]; then
    echo "Configuring $name MCP server for Claude..."
    local config="$HOME/.claude.json"
    [ -f "$config" ] || echo '{}' > "$config"
    # Guarded: `a && b` is exempt from `set -e`, and this is not the last
    # statement of the function, so a jq failure (invalid JSON in an existing
    # config, full disk) would otherwise leave a stray .tmp behind and let setup
    # finish "successfully" without the MCP server.
    if ! { jq --arg n "$name" --arg c "$cmd" --argjson a "$args_json" \
             '.mcpServers[$n] = {"command": $c, "args": $a}' \
             "$config" > "$config.tmp" && mv "$config.tmp" "$config"; }; then
      rm -f "$config.tmp"
      echo "Error: failed to write '$name' into $config" >&2
      return 1
    fi
  fi

  if [[ "$INSTALL_OPENCODE" == "1" ]]; then
    echo "Configuring $name MCP server for OpenCode..."
    mkdir -p "$HOME/.config/opencode"
    local config="$HOME/.config/opencode/opencode.json"
    [ -f "$config" ] || echo '{"$schema": "https://opencode.ai/config.json"}' > "$config"
    if ! { jq --arg n "$name" --arg c "$cmd" --argjson a "$args_json" \
             '.mcp[$n] = {"type": "local", "command": ([$c] + $a), "enabled": true}' \
             "$config" > "$config.tmp" && mv "$config.tmp" "$config"; }; then
      rm -f "$config.tmp"
      echo "Error: failed to write '$name' into $config" >&2
      return 1
    fi
  fi

  if [[ "$INSTALL_VIBE" == "1" ]]; then
    # Vibe uses TOML; append an array-of-tables entry (valid even if the wizard
    # later writes to the same file). Guard against duplicates on repeated runs.
    echo "Configuring $name MCP server for Vibe..."
    mkdir -p "$HOME/.vibe"
    local config="$HOME/.vibe/config.toml"
    if ! grep -qF "name = \"$name\"" "$config" 2>/dev/null; then
      {
        printf '\n[[mcp_servers]]\n'
        printf 'name = "%s"\n' "$name"
        printf 'transport = "stdio"\n'
        printf 'command = "%s"\n' "$cmd"
        printf 'args = %s\n' "$args_json"
      } >> "$config"
    fi
  fi

  if [[ "$INSTALL_CODEX" == "1" ]]; then
    # Codex CLI uses TOML at ~/.codex/config.toml with [mcp_servers.NAME]
    # tables. Guard against duplicates on repeated setup runs.
    echo "Configuring $name MCP server for Codex..."
    mkdir -p "$HOME/.codex"
    local config="$HOME/.codex/config.toml"
    if ! grep -qF "[mcp_servers.$name]" "$config" 2>/dev/null; then
      {
        printf '\n[mcp_servers.%s]\n' "$name"
        printf 'command = "%s"\n' "$cmd"
        printf 'args = %s\n' "$args_json"
      } >> "$config"
    fi
  fi
}

# True when at least one agent is installed — nothing to configure otherwise,
# and no reason to print a "skipping" notice either.
any_agent_installed() {
  [[ "$INSTALL_CLAUDE" == "1" || "$INSTALL_OPENCODE" == "1" \
     || "$INSTALL_CODEX" == "1" || "$INSTALL_VIBE" == "1" ]]
}

# Chrome DevTools MCP runs via `npx` and drives the Chromium installed above,
# so it needs both dependencies plus at least one target agent.
if [[ "$INSTALL_MCP_CHROME" == "1" ]] && any_agent_installed; then
  if [[ "$INSTALL_NODE" == "1" && "$INSTALL_CHROMIUM" == "1" ]]; then
    configure_mcp chrome-devtools npx -y chrome-devtools-mcp@latest --headless=true --isolated=true
  else
    echo "Skipping Chrome MCP config: requires Node.js and Chromium." >&2
  fi
fi

# Playwright MCP drives the Chromium installed above instead of pulling its own
# browser build, so it needs the same two dependencies as the Chrome MCP.
#
# Two things are needed for that reuse, and --executable-path alone is not
# enough: @playwright/mcp depends on the `playwright` package, whose postinstall
# downloads every browser marked installByDefault in playwright-core's
# browsers.json — chromium, chromium-headless-shell, firefox, webkit and ffmpeg,
# several hundred MB — regardless of which binary ends up being launched.
# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD suppresses that. It is set through `env` on
# this one command rather than in the VM's ~/.zshenv, so a user's own
# `npx playwright test` in a project still downloads the browsers it expects.
#
# Consequence to know: this server is pinned to Chromium. Pointing it at another
# engine means editing the MCP entry (drop --executable-path, add e.g.
# --browser firefox), and the first launch then fails with Playwright's usual
# "run npx playwright install" message — which works inside the VM and lands the
# download in that project VM rather than in the base image.
#
# The trade-off: Playwright pins and tests against its own browser build, so a
# distro Chromium can drift from what playwright-core expects. Re-add
# `npx playwright install chromium` here if that ever bites.
if [[ "$INSTALL_MCP_PLAYWRIGHT" == "1" ]] && any_agent_installed; then
  if [[ "$INSTALL_NODE" == "1" && "$INSTALL_CHROMIUM" == "1" ]]; then
    configure_mcp playwright env PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
      npx -y @playwright/mcp@latest --headless --isolated \
      --executable-path /usr/bin/chromium
  else
    echo "Skipping Playwright MCP config: requires Node.js and Chromium." >&2
  fi
fi

echo "VM setup complete."

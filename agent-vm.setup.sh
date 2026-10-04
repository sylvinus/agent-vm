#!/usr/bin/env bash
#
# agent-vm.setup.sh: Package installation script that runs inside the base VM
# Part of https://www.agent-vm.org/
#
# This script is executed inside the VM during "agent-vm setup".
#

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# apt under sudo, with the noninteractive frontend actually reaching it.
#
# The export above does not survive sudo: `Defaults env_reset` drops every
# variable that is not in env_keep, so each `sudo apt-get install` started
# debconf's Dialog frontend, failed to load it, fell back to Readline, failed
# again, and printed that warning block, once per install step.
#
# `sudo env VAR=value` rather than `sudo -E` or `sudo VAR=value cmd`: both of
# those need the sudoers policy to allow setting the environment, while
# passing the variable to `env` is just a command with arguments.
#
# </dev/null: this script reaches bash on its stdin, so a command reading
# stdin (dpkg asking about a changed config file, an npm install script)
# would swallow the lines after it, which then never run.
apt_get() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@" </dev/null
}

# Component toggles. The host wizard prepends `export` lines for these before
# piping the script in. Members of the default install set (everything except
# Ruby/Rust/Go/Pi/Playwright MCP/code-server and its extensions) default to 1 so running this
# script standalone (without the wizard) produces the same install you'd get from
# `agent-vm setup --preinstall=default`.
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
INSTALL_PI="${AGENT_VM_INSTALL_PI:-0}"
INSTALL_CODE_SERVER="${AGENT_VM_INSTALL_CODE_SERVER:-0}"
# Each agent's code-server extension, which brings its own copy of the agent.
INSTALL_CODE_CLAUDE="${AGENT_VM_INSTALL_CODE_CLAUDE:-0}"
INSTALL_CODE_CODEX="${AGENT_VM_INSTALL_CODE_CODEX:-0}"
INSTALL_CODE_VIBE="${AGENT_VM_INSTALL_CODE_VIBE:-0}"
# An extension needs the editor: `agent-vm setup` says so already, a run of
# this script on its own may not.
if [[ "$INSTALL_CODE_CLAUDE$INSTALL_CODE_CODEX$INSTALL_CODE_VIBE" == *1* ]]; then
  INSTALL_CODE_SERVER=1
fi
# MCP servers wired into every installed agent's config (see `agent-vm setup --help`).
INSTALL_MCP_CHROME="${AGENT_VM_INSTALL_MCP_CHROME:-1}"
INSTALL_MCP_PLAYWRIGHT="${AGENT_VM_INSTALL_MCP_PLAYWRIGHT:-0}"

# An agent there in either form: its command line and its extension read the
# same config, which is written for both.
HAS_CLAUDE=0 HAS_CODEX=0 HAS_VIBE=0
[[ "$INSTALL_CLAUDE$INSTALL_CODE_CLAUDE" == *1* ]] && HAS_CLAUDE=1
[[ "$INSTALL_CODEX$INSTALL_CODE_CODEX" == *1* ]] && HAS_CODEX=1
[[ "$INSTALL_VIBE$INSTALL_CODE_VIBE" == *1* ]] && HAS_VIBE=1

# For this session too: installers (Claude Code, Vibe) warn when ~/.local/bin
# is not on PATH, which ~/.zshenv only sets for the next ones.
export PATH="$HOME/.local/bin:$PATH"

# Behind a proxy: Lima copies the host's proxy settings into /etc/environment,
# which ssh sessions (this script, `agent-vm shell`) load. sudo drops them
# (env_reset), and Debian's sudo does not read that file, so every `sudo
# apt-get` below went out without the proxy and failed (#25). Keeping them
# through sudo covers this script and every VM cloned from this base. Checked
# with visudo before it is installed: a broken sudoers file breaks sudo.
printf 'Defaults env_keep += "http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY"\n' \
  > /tmp/agent-vm-proxy.sudoers
sudo visudo -cqf /tmp/agent-vm-proxy.sudoers
sudo install -m 0440 -o root -g root /tmp/agent-vm-proxy.sudoers /etc/sudoers.d/10-agent-vm-proxy
rm -f /tmp/agent-vm-proxy.sudoers

# Disable needrestart's interactive prompts
sudo mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = '"'"'a'"'"';' | sudo tee /etc/needrestart/conf.d/no-prompt.conf > /dev/null

# Base packages always installed: core CLI tools plus the dev libraries needed
# to compile Ruby/Python/Node versions via mise (kept here so that toggling a
# language off doesn't strip the libs the user may still want to build with).
# sshfs: the project VMs use Lima's reverse-sshfs when it can keep .git
# read-only. Lima would install it on each clone's first boot otherwise.
#
# Every install passes --no-install-recommends. Recommends pulled in hundreds
# of MB nobody uses here (Chromium alone brought printer config, Samba,
# avahi-daemon, upower, Vulkan drivers), some of them running daemons. The
# recommended packages that are used are listed by name instead.
echo "Installing base packages..."
apt_get update
apt_get install -y --no-install-recommends \
  git curl jq zsh \
  wget build-essential pkgconf patch \
  ripgrep fd-find htop \
  unzip zip \
  ca-certificates sshfs \
  libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev

# sshfs 3.7.6 (and Debian's 3.7.3-1.2~deb13u1) refuses symlinks whose target
# is absolute or contains "..", with EPERM: contain_symlinks, on by default
# (CVE-2026-47187). That breaks every node_modules/.bin link in a share. It
# protects a client from a rogue SFTP server; here the server is the user's
# own host, and a link followed in the VM only reaches the VM's files. Lima
# runs `sshfs` from PATH and takes no extra option, so the wrapper adds it.
sudo tee /usr/local/bin/sshfs > /dev/null <<'EOF'
#!/bin/sh
# Installed by agent-vm: see agent-vm.setup.sh.
if /usr/bin/sshfs -h 2>&1 | grep -q no_contain_symlinks; then
  exec /usr/bin/sshfs "$@" -o no_contain_symlinks
fi
exec /usr/bin/sshfs "$@"
EOF
sudo chmod 755 /usr/local/bin/sshfs

if [[ "$INSTALL_PYTHON" == "1" ]]; then
  echo "Installing Python 3..."
  # python3-dev: headers for pip builds of C extensions.
  apt_get install -y --no-install-recommends python3 python3-pip python3-venv python3-dev
fi

if [[ "$INSTALL_RUBY" == "1" ]]; then
  echo "Installing Ruby..."
  apt_get install -y --no-install-recommends ruby-full
fi

if [[ "$INSTALL_GOLANG" == "1" ]]; then
  echo "Installing Go..."
  apt_get install -y --no-install-recommends golang-go
fi

if [[ "$INSTALL_RUST" == "1" ]]; then
  # Rustup is the canonical Rust installer. --no-modify-path keeps it from
  # editing ~/.profile/~/.bashrc: ~/.cargo/bin goes on zsh's PATH below.
  echo "Installing Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable
  echo 'export PATH=$HOME/.cargo/bin:$PATH' >> ~/.zshenv
fi

# Set zsh as default shell
sudo chsh -s /usr/bin/zsh "$(whoami)"

# Always set the VM prompt and put ~/.local/bin on PATH (mise installs there;
# Vibe's installer puts `vibe`/`vibe-acp` there too).
#
# PATH additions go in ~/.zshenv only: every zsh reads it, and nothing in
# Debian 13's /etc/zsh/{zprofile,zshrc} resets PATH afterwards.
echo 'export PS1="vm:%1~%% "' >> ~/.zshrc

# Shell history, kept across sessions and restarts: zsh saves none unless told
# where (#20). It lives on the VM's disk, where the agent can read it, like
# everything else there. A command started with a space is left out of it.
cat >> ~/.zshrc <<'ZSHRC'
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt INC_APPEND_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE
ZSHRC
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
curl -fsSL https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshenv

if [[ "$INSTALL_DOCKER" == "1" ]]; then
  # Install Docker from official repo (includes docker compose)
  echo "Installing Docker..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt_get update
  # buildx and pigz are Recommends: `docker build` needs buildx, pigz speeds
  # up layer decompression. docker-ce-rootless-extras is left out: the user is
  # in the docker group of the rootful daemon.
  apt_get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io \
    docker-compose-plugin docker-buildx-plugin pigz
  sudo usermod -aG docker "$(whoami)"
fi

if [[ "$INSTALL_NODE" == "1" ]]; then
  # Install Node.js 24 LTS (needed for MCP servers and Codex CLI)
  # The NodeSource repo is set up by hand, as their setup_24.x script does,
  # rather than piping that script to a root shell: it also installs gnupg
  # just to dearmor the key, while apt reads an armored .asc key as is. The pin
  # keeps apt on NodeSource's nodejs over Debian's older one.
  echo "Installing Node.js 24..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /etc/apt/keyrings/nodesource.asc
  sudo chmod a+r /etc/apt/keyrings/nodesource.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_24.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null
  printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' | sudo tee /etc/apt/preferences.d/nodejs > /dev/null
  apt_get update
  apt_get install -y --no-install-recommends nodejs
fi

if [[ "$INSTALL_CHROMIUM" == "1" ]]; then
  # Install Chromium and dependencies for headless browsing
  echo "Installing Chromium..."
  # xauth: xvfb-run needs it, and it is only a Recommends of xvfb.
  # fonts-dejavu-core: with Liberation alone, fontconfig resolves the generic
  # sans-serif and serif to Liberation Mono.
  apt_get install -y --no-install-recommends chromium fonts-liberation fonts-dejavu-core xvfb xauth
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
  apt_get update
  apt_get install -y --no-install-recommends gh
fi

if [[ "$INSTALL_CLAUDE" == "1" ]]; then
  echo "Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
  echo 'export PATH=$HOME/.claude/local/bin:$PATH' >> ~/.zshenv
fi

if [[ "$HAS_CLAUDE" == "1" ]]; then
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
  # The extension's own copy of Claude Code reads it too.
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
  echo 'export PATH=$HOME/.opencode/bin:$PATH' >> ~/.zshenv
fi

if [[ "$INSTALL_CODEX" == "1" ]]; then
  if [[ "$INSTALL_NODE" != "1" ]]; then
    echo "Skipping Codex CLI: requires Node.js (re-run setup with Node.js enabled)." >&2
  else
    echo "Installing Codex CLI..."
    sudo npm i -g @openai/codex </dev/null
  fi
fi

if [[ "$INSTALL_VIBE" == "1" ]]; then
  # Vibe installs `uv` and the `vibe`/`vibe-acp` commands into ~/.local/bin.
  # PATH was already exported at the top of this script so the installer
  # doesn't abort on its own PATH check.
  echo "Installing Mistral Vibe..."
  curl -LsSf https://mistral.ai/vibe/install.sh | bash
fi

if [[ "$INSTALL_PI" == "1" ]]; then
  if [[ "$INSTALL_NODE" != "1" ]]; then
    echo "Skipping Pi: requires Node.js (re-run setup with Node.js enabled)." >&2
  else
    # @earendil-works is the maintained scope; @mariozechner/pi-coding-agent is
    # deprecated and misses security fixes. --ignore-scripts as Pi's docs say.
    echo "Installing Pi..."
    sudo npm i -g --ignore-scripts @earendil-works/pi-coding-agent </dev/null
    # Pi never asks before running tools. Its one gate is trust for a project's
    # .pi/ extensions and skills, which the VM makes moot and which `pi -p`
    # silently skips. Telemetry covers the install ping and the attribution
    # headers Pi adds to some providers' requests.
    mkdir -p "$HOME/.pi/agent"
    cat > "$HOME/.pi/agent/settings.json" << 'JSON'
{
  "defaultProjectTrust": "always",
  "enableInstallTelemetry": false
}
JSON
  fi
fi

# A top-level TOML key as the first line of <file>, where the tables the MCP
# config appends later cannot capture it. Skipped when the key is there.
toml_prepend() {
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]] && grep -q "^$key *=" "$file"; then
    return 0
  fi
  { printf '%s = %s\n' "$key" "$value"; [[ ! -f "$file" ]] || cat "$file"; } > "$file.tmp"
  mv "$file.tmp" "$file"
}

# The URL <ref> points to from the http(s) URL <base>, fragments dropped:
# absolute, scheme-relative, absolute-path or relative, its . and ..
# segments resolved (RFC 3986). Fails for another scheme (vscode://..., the
# editor's own schemas).
schema_url_resolve() {
  local base="${1%%#*}" ref="${2%%#*}" scheme rest host path seg
  local -a segs=() kept=()
  case "$ref" in
    http://*|https://*) base="$ref" ref="" ;;
    *://*) return 1 ;;
  esac
  scheme="${base%%://*}"
  rest="${base#*://}"
  host="${rest%%/*}"
  path=/
  [[ "$rest" != */* ]] || path="/${rest#*/}"
  case "$ref" in
    "") ;;
    //*)
      host="${ref#//}"
      path=/
      if [[ "$host" == */* ]]; then path="/${host#*/}"; host="${host%%/*}"; fi ;;
    /*) path="$ref" ;;
    *) path="${path%/*}/$ref" ;;
  esac
  IFS=/ read -ra segs <<< "$path"
  for seg in ${segs[@]+"${segs[@]}"}; do
    case "$seg" in
      ""|.) ;;
      ..) [[ ${#kept[@]} -eq 0 ]] || unset 'kept[-1]' ;;
      *) kept+=("$seg") ;;
    esac
  done
  local IFS=/
  printf '%s://%s/%s\n' "$scheme" "$host" "${kept[*]}"
}

# Write to <out> code-server's machine settings with every JSON schema its
# built-in extensions (in <ext-dir>) name by URL, and every schema those refer
# to, downloaded now, a level of references at a time, in parallel. A
# json.schemas entry with a URL and its content makes the editor use the
# content instead of fetching the URL, so with downloads off (the user
# settings) opening a file sends no request. A failed download only leaves
# its files unvalidated.
# The editor resolves a schema's relative references against its $id when it
# has one (www.schemastore.org/package says json.schemastore.org/package.json),
# else against the URL it loaded it from: so are they here, for each to be
# stored under the URL the editor asks for.
# These are the machine settings: a json.schemas of the user settings would
# be replaced by this one, not added to (VS Code merges objects across
# settings, not arrays). A schema of your own goes in a workspace's settings.
code_server_schemas() {
  local ext_dir="$1" out="$2" dir u f r base i n=0
  local -a level next fetch
  local -A seen urls
  dir="$(mktemp -d)"
  : > "$dir/entries"
  mapfile -t level < <(jq -r '.contributes.jsonValidation[]?.url | select(test("^https?://"))' \
    "$ext_dir"/*/package.json | sort -u)
  while [[ ${#level[@]} -gt 0 ]]; do
    fetch=() urls=() next=()
    for u in "${level[@]}"; do
      u="${u%%#*}"
      [[ -z "${seen[$u]:-}" ]] || continue
      seen[$u]=1
      n=$((n + 1))
      urls[$n]="$u"
      # Fetched where json.schemastore.org redirects to, stored under the URL
      # the editor asks for.
      fetch+=(-o "$dir/$n.json" "${u/#https:\/\/json.schemastore.org\//https://www.schemastore.org/}")
    done
    # Each file checked below: one failed download fails curl as a whole.
    [[ ${#fetch[@]} -eq 0 ]] || curl -fsSL --max-time 30 --parallel --parallel-max 8 "${fetch[@]}" </dev/null || true
    for i in "${!urls[@]}"; do
      u="${urls[$i]}"
      f="$dir/$i.json"
      if ! jq -c --arg u "$u" '{url: $u, schema: .}' "$f" > "$f.entry" 2>/dev/null; then
        echo "Warning: could not download the JSON schema $u: files using it are not validated." >&2
        continue
      fi
      cat "$f.entry" >> "$dir/entries"
      # A schema may be true or false, which has no $id to read.
      base="$(jq -r 'objects | (."$id" // .id // empty) | strings | select(test("^https?://"))' "$f")"
      [[ -n "$base" ]] || base="$u"
      while IFS= read -r r; do
        r="$(schema_url_resolve "$base" "$r")" && next+=("$r")
      done < <(jq -r '[.. | objects | ."$ref"? | strings | select(startswith("#") | not)] | unique[]' "$f")
    done
    level=(${next[@]+"${next[@]}"})
  done
  mkdir -p "$(dirname "$out")"
  jq -sc '{"json.schemas": .}' "$dir/entries" > "$out"
  rm -rf "$dir"
}

if [[ "$INSTALL_CODE_SERVER" == "1" ]]; then
  # The editor of `agent-vm code` (internal/cli/code.go). No password here: every VM
  # is a copy of this disk, so each one makes its own on first use.
  echo "Installing code-server..."
  curl -fsSL https://code-server.dev/install.sh | sh
  extensions=()
  [[ "$INSTALL_CODE_CLAUDE" == "1" ]] && extensions+=(--install-extension anthropic.claude-code)
  [[ "$INSTALL_CODE_CODEX" == "1" ]] && extensions+=(--install-extension openai.chatgpt)
  [[ "$INSTALL_CODE_VIBE" == "1" ]] && extensions+=(--install-extension mistralai.mistral-vibe-code)
  if [[ ${#extensions[@]} -gt 0 ]]; then
    echo "Installing the agents' extensions..."
    code-server "${extensions[@]}" </dev/null
  fi
  # chat.disableAIFeatures turns off the GitHub Copilot chat and completions
  # that code-server ships (code.go also disables the extension), and
  # chat.mcp.gallery.enabled its MCP gallery. telemetry.*: code-server's
  # --disable-telemetry leaves the built-in extensions sending telemetry. The
  # editor downloads no JSON schema: setup does, once, into the machine
  # settings (code_server_schemas). remote.autoForwardPorts: Lima forwards
  # the VM's ports already. update.*: setup installs code-server, the editor
  # does not update itself. The rest is the look (dark theme, no secondary
  # side bar), the welcome page, tips, recommendations, experiments, online
  # settings search, and Claude's onboarding checklist.
  mkdir -p "$HOME/.local/share/code-server/User"
  jq -n --arg claude "$INSTALL_CODE_CLAUDE" '
    {
      "workbench.colorTheme": "Dark 2026",
      "chat.disableAIFeatures": true,
      "chat.mcp.gallery.enabled": false,
      "telemetry.telemetryLevel": "off",
      "telemetry.feedback.enabled": false,
      "json.schemaDownload.enable": false,
      "workbench.enableExperiments": false,
      "workbench.settings.enableNaturalLanguageSearch": false,
      "workbench.settings.showAISearchToggle": false,
      "extensions.ignoreRecommendations": true,
      "workbench.startupEditor": "none",
      "workbench.tips.enabled": false,
      "workbench.welcomePage.walkthroughs.openOnInstall": false,
      "workbench.secondarySideBar.defaultVisibility": "hidden",
      "remote.autoForwardPorts": false,
      "update.mode": "none",
      "update.showReleaseNotes": false
    } + if $claude == "1" then {
      "claudeCode.hideOnboarding": true
    } else {} end' > "$HOME/.local/share/code-server/User/settings.json"
  # The .deb's /usr/bin/code-server is a script running /usr/lib/code-server;
  # a standalone install is a link into its own directory.
  cs_root=/usr/lib/code-server
  if [[ ! -d "$cs_root/lib/vscode/extensions" ]]; then
    cs_root="$(dirname "$(dirname "$(readlink -f "$(command -v code-server)")")")"
  fi
  echo "Downloading the JSON schemas the editor uses..."
  cs_machine="$HOME/.local/share/code-server/Machine/settings.json"
  code_server_schemas "$cs_root/lib/vscode/extensions" "$cs_machine"
  # Claude's conversations start in bypass mode, as the managed settings above
  # do for the CLI. These keys are machine-scoped: code-server ignores them in
  # the user settings.
  if [[ "$INSTALL_CODE_CLAUDE" == "1" ]]; then
    jq -c '. + {
      "claudeCode.allowDangerouslySkipPermissions": true,
      "claudeCode.initialPermissionMode": "bypassPermissions"
    }' "$cs_machine" > "$cs_machine.tmp"
    mv "$cs_machine.tmp" "$cs_machine"
  fi
  # Codex and Vibe have no setting for it: their extensions start in the mode
  # the agent's own config names. These match the flags the command line gets
  # (agents in internal/cli/commands.go).
  if [[ "$INSTALL_CODE_CODEX" == "1" ]]; then
    toml_prepend "$HOME/.codex/config.toml" sandbox_mode '"danger-full-access"'
    toml_prepend "$HOME/.codex/config.toml" approval_policy '"never"'
  fi
  if [[ "$INSTALL_CODE_VIBE" == "1" ]]; then
    toml_prepend "$HOME/.vibe/config.toml" default_agent '"auto-approve"'
  fi
  # Written by code-server on its first run, with a password of its own.
  rm -rf "$HOME/.config/code-server"
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

  if [[ "$HAS_CLAUDE" == "1" ]]; then
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

  if [[ "$HAS_VIBE" == "1" ]]; then
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

  if [[ "$HAS_CODEX" == "1" ]]; then
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

# True when at least one agent is installed: nothing to configure otherwise,
# and no reason to print a "skipping" notice either.
any_agent_installed() {
  [[ "$HAS_CLAUDE" == "1" || "$INSTALL_OPENCODE" == "1" \
     || "$HAS_CODEX" == "1" || "$HAS_VIBE" == "1" ]]
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

# Playwright MCP drives the Chromium installed above (--executable-path), not
# a browser of its own: PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD, on this command only,
# skips the several hundred MB of browsers the `playwright` package downloads
# on install, while a project's own `npx playwright test` still gets them. A
# distro Chromium can drift from what playwright-core expects:
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

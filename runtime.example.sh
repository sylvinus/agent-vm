#!/bin/bash
# =============================================================================
# runtime.example.sh — Template for ~/.agent-vm/runtime.sh
# =============================================================================
#
# This file runs inside every agent-vm on each start, before the per-project
# .agent-vm.runtime.sh script. Copy it to ~/.agent-vm/runtime.sh and uncomment
# the sections you need.
#
# To get started:
#   cp runtime.example.sh ~/.agent-vm/runtime.sh
#   # Edit the file with your own values
#   chmod +x ~/.agent-vm/runtime.sh


# =============================================================================
# 1. SSH authentication for GitHub
# =============================================================================
#
# Embed your SSH private key (base64-encoded) so the VM can push/pull over SSH.
#
#   To encode your key:
#     cat ~/.ssh/id_ed25519 | base64
#
#   Paste the output below:

# SSH_KEY_B64="<your-base64-encoded-private-key>"
# mkdir -p ~/.ssh && chmod 700 ~/.ssh
# echo "$SSH_KEY_B64" | base64 -d > ~/.ssh/id_ed25519
# chmod 600 ~/.ssh/id_ed25519
# ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null


# =============================================================================
# 2. Git configuration
# =============================================================================

# git config --global user.name "Your Name"
# git config --global user.email "you@example.com"

# Force SSH for all GitHub remotes (avoids HTTPS credential prompts)
# git config --global url."git@github.com:".insteadOf "https://github.com/"


# =============================================================================
# 3. GitHub CLI authentication
# =============================================================================
#
# Required for creating PRs, commenting on issues, etc. from inside the VM.
# (If you only need `gh` for CLI calls, setting GH_TOKEN in ~/.agent-vm/env is
# simpler — see "Sharing tokens" in the README.)
#
#   To create a token: https://github.com/settings/tokens
#   Scopes needed: repo, read:org
#
# echo "<your-github-pat>" | gh auth login --with-token


# =============================================================================
# 4. Claude Code skills
# =============================================================================
#
# Clone shared skills into the global skills directory.
# These will be available in all projects.

# mkdir -p ~/.claude/skills
# git clone git@github.com:your-org/claude-skills.git ~/.claude/skills/your-org-skills

# You can also install skills into the current project's directory.
# These will only be available when working in that project.

# PROJECT_DIR="$(pwd)"
# mkdir -p "$PROJECT_DIR/.claude/skills"
# git clone git@github.com:your-org/project-skills.git "$PROJECT_DIR/.claude/skills/project-skills"


# =============================================================================
# 5. MCP servers
# =============================================================================
#
# Add MCP servers available to Claude Code in all projects (--scope user).
#
# claude mcp add --scope user my-mcp-server npx -y my-mcp-server@latest


# =============================================================================
# 6. Claude Code status line
# =============================================================================
#
# Install a custom status line command in ~/.claude/settings.json.
# The command output is displayed at the bottom of the Claude Code interface.
#
# For example, to show the current git branch:
#
# cat > /tmp/statusline-patch.json << 'PATCH'
# {"statusLine": {"command": "git branch --show-current 2>/dev/null || echo ''"}}
# PATCH
#
# if [ -f ~/.claude/settings.json ]; then
#   jq -s '.[0] * .[1]' ~/.claude/settings.json /tmp/statusline-patch.json > /tmp/settings-merged.json
#   mv /tmp/settings-merged.json ~/.claude/settings.json
# else
#   mkdir -p ~/.claude
#   cp /tmp/statusline-patch.json ~/.claude/settings.json
# fi
# rm -f /tmp/statusline-patch.json

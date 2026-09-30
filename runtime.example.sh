#!/bin/bash
# =============================================================================
# runtime.example.sh — Template for ~/.agent-vm/runtime.sh
# =============================================================================
#
# This file runs inside the VM on every agent-vm command that enters one,
# before the per-project .agent-vm.runtime.sh script, so keep it safe to run
# again. Copy it to ~/.agent-vm/runtime.sh and uncomment the sections you
# need.
#
# To get started:
#   cp runtime.example.sh ~/.agent-vm/runtime.sh
#   # Edit the file with your own values
#   chmod +x ~/.agent-vm/runtime.sh
#
# Keep private keys out of this file: it runs in every VM, where the agent can
# read whatever it sets up. For GitHub, a fine-grained GH_TOKEN in
# ~/.agent-vm/env is revocable in one click; an SSH key is not.


# =============================================================================
# 1. Git configuration
# =============================================================================
#
# The identity can also come from GIT_AUTHOR_* / GIT_COMMITTER_* in
# ~/.agent-vm/env, see "Letting the agent commit and push" in the README.

# git config --global user.name "Your Name"
# git config --global user.email "you@example.com"


# =============================================================================
# 2. Pushing over HTTPS with GH_TOKEN
# =============================================================================
#
# `gh` reads GH_TOKEN from ~/.agent-vm/env on its own. Plain `git push` over
# HTTPS needs a credential helper, which `gh` knows how to install.
#
# gh auth setup-git


# =============================================================================
# 3. Claude Code skills
# =============================================================================
#
# Clone shared skills into the global skills directory.
# These will be available in all projects.

# mkdir -p ~/.claude/skills
# git clone https://github.com/your-org/claude-skills.git ~/.claude/skills/your-org-skills

# You can also install skills into the current project's directory.
# These will only be available when working in that project.

# PROJECT_DIR="$(pwd)"
# mkdir -p "$PROJECT_DIR/.claude/skills"
# git clone https://github.com/your-org/project-skills.git "$PROJECT_DIR/.claude/skills/project-skills"


# =============================================================================
# 4. MCP servers
# =============================================================================
#
# Add MCP servers available to Claude Code in all projects (--scope user).
#
# claude mcp add --scope user my-mcp-server npx -y my-mcp-server@latest


# =============================================================================
# 5. Claude Code status line
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

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
#
# It is piped into the interpreter its first line names (bash, sh or zsh), so
# it needs no execute bit. It runs in the project directory.
#
# Keep private keys out of this file: it runs in every VM, where the agent can
# read whatever it sets up. For GitHub, a fine-grained GH_TOKEN in
# ~/.agent-vm/env is revocable in one click; an SSH key is not.


# =============================================================================
# 1. Git configuration
# =============================================================================
#
# The identity can also come from GIT_AUTHOR_* / GIT_COMMITTER_* in
# ~/.agent-vm/env: https://www.agent-vm.org/#letting-the-agent-commit

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
# Clone shared skills into the global skills directory, once per VM (this
# script runs again on every command), and update them after that.
# These will be available in all projects.

# mkdir -p ~/.claude/skills
# if [ -d ~/.claude/skills/your-org-skills ]; then
#   git -C ~/.claude/skills/your-org-skills pull --ff-only --quiet
# else
#   git clone https://github.com/your-org/claude-skills.git ~/.claude/skills/your-org-skills
# fi

# Skills for the current project only belong in that project's
# .agent-vm.runtime.sh: this file runs in every project. There, the same
# pattern, in "$PWD/.claude/skills/project-skills" (which fails under
# --readonly, where the project cannot be written).


# =============================================================================
# 4. MCP servers
# =============================================================================
#
# Add MCP servers available to Claude Code in all projects (--scope user).
# `add` fails on a name that exists, so only when it is not there yet.
#
# claude mcp get my-mcp-server >/dev/null 2>&1 \
#   || claude mcp add --scope user my-mcp-server npx -y my-mcp-server@latest


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
# {"statusLine": {"type": "command", "command": "git branch --show-current 2>/dev/null || echo ''"}}
# PATCH
#
# if [ -f ~/.claude/settings.json ]; then
#   jq -s '.[0] * .[1]' ~/.claude/settings.json /tmp/statusline-patch.json > /tmp/settings-merged.json \
#     && mv /tmp/settings-merged.json ~/.claude/settings.json
# else
#   mkdir -p ~/.claude
#   cp /tmp/statusline-patch.json ~/.claude/settings.json
# fi
# rm -f /tmp/statusline-patch.json

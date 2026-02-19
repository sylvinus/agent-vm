# agent-vm

Run AI coding agents inside sandboxed Linux VMs. The agent gets full autonomy while your host system stays safe.

Uses [Lima](https://lima-vm.io/) to create lightweight Debian VMs on macOS and Linux. Ships with dev tools, Docker, and a headless Chrome browser with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) pre-configured.

Supports [Claude Code](https://claude.ai/code), [OpenCode](https://github.com/opencode-ai/opencode), and [Codex CLI](https://github.com/openai/codex) out of the box. Other agents can be run via `agent-vm shell`.

Never install attack vectors such as npm, claude or even Docker on your host machine again!

Feedbacks welcome!

## Prerequisites

- macOS or Linux
- [Lima](https://lima-vm.io/docs/installation/) (installed automatically via Homebrew if available)
- A subscription or API key for your agent of choice

## Install

```bash
git clone https://github.com/sylvinus/agent-vm.git
cd agent-vm

# Add to your shell config
echo "source $(pwd)/agent-vm.sh" >> ~/.zshrc   # zsh
echo "source $(pwd)/agent-vm.sh" >> ~/.bashrc  # or bash
```

## Usage

### One-time setup

```bash
agent-vm setup
```

Creates a base VM template with dev tools, Docker, Chromium, and AI coding agents pre-installed.

Options:

| Flag | Description | Default |
|------|-------------|---------|
| `--disk GB` | VM disk size in GB | 20 |
| `--memory GB` | VM memory in GB | 8 |

```bash
agent-vm setup --disk 50 --memory 16      # Larger VM for heavy workloads
```

### Run an agent in a VM

```bash
cd your-project
agent-vm claude                # Claude Code
agent-vm opencode              # OpenCode
agent-vm codex                 # Codex CLI
```

Creates a persistent VM for the current directory (or reuses it if one already exists), mounts your working directory, and runs the agent with full permissions. The VM persists after the agent exits so you can reconnect later.

Each agent runs with its respective auto-approve flag:
- `claude` runs with `--dangerously-skip-permissions`
- `opencode` runs with `--dangerously-skip-permissions`
- `codex` runs with `--full-auto`

Any extra arguments are forwarded to the agent command:

```bash
agent-vm claude -p "fix all lint errors"        # Run with a prompt
agent-vm claude --resume                         # Resume previous session
agent-vm opencode -p "refactor auth module"      # OpenCode with a prompt
agent-vm codex -q "explain this codebase"        # Codex with a query
```

### Shell access

```bash
agent-vm shell
```

Opens a zsh shell in the same persistent VM for the current directory. Useful for debugging, running commands alongside an agent, or using agents not built in.

### VM lifecycle

Each directory gets its own persistent VM. You can manage it with:

```bash
agent-vm status     # Show VM status for the current directory
agent-vm stop       # Stop the VM (can be restarted later)
agent-vm destroy    # Stop and permanently delete the VM
```

To resize an existing VM's disk or memory, just pass `--disk` or `--memory` again — the VM will be stopped, reconfigured, and restarted automatically:

```bash
agent-vm --disk 50 claude              # Grow disk to 50GB, then run Claude
agent-vm --memory 16 shell             # Increase memory to 16GB, then open shell
```

Note: disk can only be grown, not shrunk.

Running `agent-vm setup` again updates the base template but does **not** update existing VMs. You'll see a warning when using a VM cloned from an older base. Use `--reset` to re-clone:

```bash
agent-vm --reset claude                   # Destroy and re-clone VM, then run Claude
```

## Customization

### Per-user: `~/.agent-vm.setup.sh`

Create this file in your home directory to install extra tools into the base VM template. It runs once during `agent-vm setup`, as the default VM user (with sudo available):

```bash
# ~/.agent-vm.setup.sh
sudo apt-get install -y postgresql-client
pip install pandas numpy
```

### Per-project: `.agent-vm.runtime.sh`

Create this file at the root of any project. It runs inside the VM each time a new VM is created for the project, just before you get access. Use it for project-specific setup like installing dependencies or starting services:

```bash
# your-project/.agent-vm.runtime.sh
npm install
docker compose up -d
```

### MCP servers

The base VM comes with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) pre-configured for Claude, giving the agent headless browser access.

To add more MCP servers, add them to `~/.claude.json` in your `~/.agent-vm.setup.sh`, or edit the file directly inside a VM via `agent-vm shell`. Add entries to the `mcpServers` object:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
    },
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost:5432/mydb"]
    }
  }
}
```

## Shared configuration

The VM mounts your host's `~/.claude/` directory. Login credentials, skills, user-level `CLAUDE.md`, conversation history, and settings all persist across VMs automatically.

On first use, you'll need to authenticate. Credentials are stored in `~/.claude/.credentials.json` and reused by all subsequent VMs.

This also means the configuration is shared with any Claude Code installation on the host — though we recommend running Claude exclusively in VMs for security.

## How it works

1. **`agent-vm setup`** creates a Debian 13 VM with Lima, runs `agent-vm.setup.sh` inside it to install dev tools + Chrome + agents, and stops it as a reusable base template
2. **`agent-vm claude|opencode|codex [args]`** clones the base template into a persistent per-directory VM, mounts your working directory and `~/.claude/`, runs optional `.agent-vm.runtime.sh`, then launches the agent with full permissions
3. The VM persists after exit. Running any agent command or `agent-vm shell` in the same directory reuses the same VM
4. Use `agent-vm stop` to stop the VM or `agent-vm destroy` to delete it

Ports opened inside the VM (e.g. by Docker containers) are automatically forwarded to your host by Lima.

## Project structure

| File | Description |
|------|-------------|
| `agent-vm.sh` | Main script — source this in your shell config |
| `agent-vm.setup.sh` | Package installation script that runs inside the base VM during setup |

## What's in the VM by default

| Category | Packages |
|----------|----------|
| Core | git, curl, wget, jq, build-essential, unzip, zip |
| Python | python3, pip, venv |
| Node.js | Node.js 24 LTS (via NodeSource) |
| Search | ripgrep, fd-find |
| Utilities | htop, GitHub CLI (gh) |
| Browser | Chromium (headless), xvfb |
| Containers | Docker Engine, Docker Compose |
| AI | Claude Code, OpenCode, Codex CLI, Chrome DevTools MCP server |

## Security model

AI coding agents need full permissions to be useful — they install dependencies, run builds, execute tests, start servers. But running `npm install` or `pip install` means executing arbitrary third-party code on your machine.

This is not a theoretical risk. The [Shai-Hulud](https://unit42.paloaltonetworks.com/npm-supply-chain-attack/) worm compromised thousands of npm packages in 2025 by injecting malicious code that runs during `npm install`. It harvested npm tokens, GitHub PATs, SSH keys, and cloud credentials from developers' machines, then used those credentials to spread to other packages the developer maintained. All of this happened silently, in the background, while the legitimate install appeared normal.

An AI agent running with `--dangerously-skip-permissions` on your host would give such an attack full access to everything: your SSH keys, your cloud credentials, your browser sessions, your entire filesystem.

**agent-vm keeps your credentials on the host and runs all code inside the VM.** The VM only has access to:

- Your project directory (read-write mount)
- `~/.claude/` for agent credentials and settings

It has **no access** to your SSH keys, npm tokens, cloud credentials, git config, browser sessions, or anything else on your host. If a supply chain attack executes inside the VM, it finds nothing to steal (except your source code) and nowhere to spread.

Meanwhile, your host machine stays clean. You don't need Node.js, Docker, or any dev tooling installed locally. The only host dependency is Lima. Your SSH keys and signing credentials never enter the VM as we recommend running `git commit` on the host yourself.

### Why not Docker?

| | No sandbox | Docker | VM (agent-vm) |
|---|---|---|---|
| Agent can run any command | Yes | Yes | Yes |
| File system isolation | None | Partial (shared kernel) | Full |
| Network isolation | None | Partial | Full |
| Can run Docker inside | Yes | Requires DinD or socket mount | Yes (native) |
| Kernel-level isolation | None | None (shares host kernel) | Full (separate kernel) |
| Protection from container escapes | None | None | Yes |
| Browser / GUI tools | Host only | Complex setup | Built-in (headless Chromium) |

Docker containers share the host kernel. A motivated attacker (or a compromised dependency running inside the container) could exploit kernel vulnerabilities to escape. A VM runs its own kernel — even root access inside the VM can't reach the host.

A VM also avoids the practical headaches of Docker sandboxing. Docker runs natively inside the VM without Docker-in-Docker hacks. Headless Chromium works out of the box. Lima automatically forwards ports to your host. The agent gets a normal Linux environment where everything just works.

This workflow also replaces Docker Desktop on the Mac, which has become more and more bloated over the years.

## License

MIT

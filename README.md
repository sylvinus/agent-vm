# agent-vm

Run AI coding agents inside sandboxed Linux VMs. The agent gets full autonomy while your host system stays safe.

Uses [Lima](https://lima-vm.io/) to create lightweight Debian VMs on macOS and Linux. Ships with dev tools, Docker, and a headless Chrome browser with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) pre-configured.

Currently supports [Claude Code](https://claude.ai/code). Other agents (Codex, etc.) can be added in the future.

Feedbacks welcome!

## Prerequisites

- macOS or Linux
- [Lima](https://lima-vm.io/docs/installation/) (installed automatically via Homebrew if available)
- A [Claude subscription](https://claude.ai/) (Pro, Max, or Team)

## Install

```bash
git clone https://github.com/sylvinus/agent-vm.git
cd agent-vm

# Add to your shell config
echo "source $(pwd)/claude-vm.sh" >> ~/.zshrc   # zsh
echo "source $(pwd)/claude-vm.sh" >> ~/.bashrc  # or bash
```

## Usage

### One-time setup

```bash
claude-vm-setup
```

Creates a VM template with dev tools, Docker, Chromium, and Claude Code pre-installed. During setup, Claude will launch once for authentication. After it responds, type `/exit` to continue with the rest of the setup. (We haven't found a way to automate this step yet.)

### Run Claude in a VM

```bash
cd your-project
claude-vm
```

Clones the template into a fresh VM, mounts your current directory, and runs `claude --dangerously-skip-permissions`. The VM is deleted when Claude exits.

### Debug shell

```bash
claude-vm-shell
```

Same as `claude-vm` but drops you into a bash shell instead.

## Customization

### Per-user: `~/.claude-vm.setup.sh`

Create this file in your home directory to install extra tools into the VM template. It runs once during `claude-vm-setup`, as the default VM user (with sudo available):

```bash
# ~/.claude-vm.setup.sh
sudo apt-get install -y postgresql-client
pip install pandas numpy
```

### Per-project: `.claude-vm.runtime.sh`

Create this file at the root of any project. It runs inside the cloned VM each time you call `claude-vm`, just before Claude starts. Use it for project-specific setup like installing dependencies or starting services:

```bash
# your-project/.claude-vm.runtime.sh
npm install
docker compose up -d
```

## How it works

1. **`claude-vm-setup`** creates a Debian 13 VM with Lima, installs dev tools + Chrome + Claude Code, and stops it as a reusable template
2. **`claude-vm`** clones the template, mounts your working directory read-write, runs optional `.claude-vm.runtime.sh`, then launches Claude with full permissions
3. On exit, the cloned VM is stopped and deleted. The template persists for reuse

Ports opened inside the VM (e.g. by Docker containers) are automatically forwarded to your host by Lima.

## What's in the VM

| Category | Packages |
|----------|----------|
| Core | git, curl, wget, build-essential, jq |
| Python | python3, pip, venv |
| Node.js | Node.js 22 (via NodeSource) |
| Search | ripgrep, fd-find |
| Browser | Chromium (headless), xvfb |
| Containers | docker |
| AI | Claude Code, Chrome DevTools MCP server |

## Why a VM?

Running an AI agent with full permissions is powerful but risky. Here's how the options compare:

| | No sandbox | Docker | VM (agent-vm) |
|---|---|---|---|
| Agent can run any command | Yes | Yes | Yes |
| File system isolation | None | Partial (shared kernel) | Full |
| Network isolation | None | Partial | Full |
| Can run Docker inside | Yes | Requires DinD or socket mount | Yes (native) |
| Kernel-level isolation | None | None (shares host kernel) | Full (separate kernel) |
| Protection from container escapes | None | None | Yes |
| Browser / GUI tools | Host only | Complex setup | Built-in (headless Chromium) |

Docker containers share the host kernel, so a motivated agent could exploit kernel vulnerabilities or misconfigurations to escape. A VM runs its own kernel — even if the agent gains root inside the VM, it can't reach the host.

A VM also avoids the practical headaches of Docker sandboxing. Docker runs natively inside the VM without Docker-in-Docker hacks or socket mounts. Headless Chromium works out of the box without fiddling with `--no-sandbox` flags or shared memory settings. Lima automatically forwards ports from the VM to your host, so if the agent starts a server on port 3000, it's immediately accessible at `localhost:3000`. The agent gets a normal Linux environment where everything just works.

Finally, using a VM means you don't need Node.js, npm, Docker, or any other dev tooling installed on your host machine. The only host dependency is Lima. All the tools (and their vulnerabilities) live inside the VM.

For AI agents running with `--dangerously-skip-permissions`, a VM is the only sandbox that provides meaningful security.

## License

MIT

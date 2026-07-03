# agent-vm

Run AI coding agents inside sandboxed Linux VMs. The agent gets full autonomy while your host system stays safe.

Uses [Lima](https://lima-vm.io/) to create lightweight Debian VMs on macOS and Linux. Ships with dev tools, Docker, and a headless Chrome browser with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) pre-configured.

Supports [Claude Code](https://claude.ai/code), [OpenCode](https://github.com/anomalyco/opencode), [Codex CLI](https://github.com/openai/codex), and [Mistral Vibe](https://docs.mistral.ai/vibe/code/cli/install-setup) out of the box. Other agents can be run via `agent-vm shell`.

Never install attack vectors such as npm, claude or even Docker on your host machine again!

Feedback welcome!

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

Sourcing puts `agent-vm` in your shell as a function. You can also invoke the script directly (`./agent-vm.sh setup`) without sourcing — useful for one-off runs.

## Usage

### One-time setup

```bash
agent-vm setup
```

Creates a base VM template with dev tools, Docker, Chromium, and AI coding agents pre-installed. Run interactively to open the wizard; its first prompt offers a one-tap "default install" (everything except the opt-in languages Ruby, Rust, Go), answer `n` for per-component prompts. Pass `--preinstall=...` to skip the wizard. When stdin is not a terminal (CI), the wizard is auto-skipped and the default set is installed.

Options:

| Flag | Description | Default |
|------|-------------|---------|
| `--disk GB` | VM disk size in GB | 10 |
| `--memory GB` | VM memory in GB | 3 |
| `--cpus N` | Number of CPUs | 1 |
| `--preinstall=LIST` | Preinstall only this comma-separated subset in the base image (skips the wizard) | — |

Names are lowercase: `python`, `node`, `ruby`, `rust`, `golang`, `docker`, `chromium`, `gh`, `claude`, `opencode`, `codex`, `vibe`. Use `default` for the default set (everything except Ruby/Rust/Go), `all` for everything, or `none` for nothing. Selecting `codex`, or `chromium` with any AI agent, also installs `node` because those paths require `npm`/`npx`.

```bash
agent-vm setup                                       # Interactive wizard
agent-vm setup --preinstall=default                  # Default set, no prompts
agent-vm setup --preinstall=default,rust             # Default set plus Rust
agent-vm setup --preinstall=python,docker,claude     # Minimal Claude-only setup
agent-vm setup --disk 50 --memory 16 --cpus 8        # Larger VM for heavy workloads
```

### Run an agent in a VM

```bash
cd your-project
agent-vm claude                # Claude Code
agent-vm opencode              # OpenCode
agent-vm codex                 # Codex CLI
agent-vm vibe                  # Mistral Vibe
```

Creates a persistent VM for the current directory (or reuses it if one already exists), mounts your working directory, and runs the agent with full permissions. The VM persists after the agent exits so you can reconnect later. Ports opened inside the VM (e.g. by Docker containers or dev servers) are automatically forwarded to your host by Lima.

Each agent runs with its respective auto-approve flag:
- `claude` runs with `--dangerously-skip-permissions`
- `opencode` does not yet have an auto-approve flag (waiting on [this PR](https://github.com/anomalyco/opencode/pull/11833))
- `codex` runs with `--dangerously-bypass-approvals-and-sandbox`
- `vibe` runs with `--agent auto-approve`

Any extra arguments are forwarded to the agent command:

```bash
agent-vm claude -p "fix all lint errors"        # Run with a prompt
agent-vm claude --resume                         # Resume previous session
agent-vm opencode -p "refactor auth module"      # OpenCode with a prompt
agent-vm codex -q "explain this codebase"        # Codex with a query
agent-vm vibe -p "fix all lint errors"           # Mistral Vibe with a prompt
```

### Shell access and running commands

```bash
agent-vm shell                         # Open a zsh shell in the VM
agent-vm run npm install               # Run a one-off command in the VM
agent-vm run docker compose up -d      # Start services
```

### VM lifecycle

Each directory gets its own persistent VM. You can manage it with:

```bash
agent-vm status      # Show status of all VMs (current dir marked with >)
agent-vm stop        # Stop the VM (can be restarted later)
agent-vm rm          # Stop and permanently delete the VM
agent-vm destroy-all # Stop and delete all agent-vm VMs
```

To automatically destroy a VM after the agent exits (like `docker run --rm`):

```bash
agent-vm --rm claude                   # Run Claude, then destroy the VM
agent-vm --rm run npm test             # Run tests, then destroy the VM
```

To resize an existing VM's disk or memory, just pass `--disk` or `--memory` again — the VM will be stopped, reconfigured, and restarted automatically:

```bash
agent-vm --disk 50 claude              # Grow disk to 50GB, then run Claude
agent-vm --memory 16 --cpus 8 shell    # Increase memory and CPUs, then open shell
```

Note: disk can only be grown, not shrunk.

Running `agent-vm setup` again updates the base template but does **not** update existing VMs. You'll see a warning when using a VM cloned from an older base. Use `--reset` to re-clone:

```bash
agent-vm --reset claude                # Destroy and re-clone VM, then run Claude
```

### Offline mode and read-only mounts

```bash
agent-vm --offline claude              # Block outbound internet access
agent-vm --readonly shell              # Mount project directory as read-only
agent-vm --offline --readonly claude   # Both
```

`--offline` blocks outbound internet from the VM using iptables while preserving host/VM communication (mounts, port forwarding). Useful for ensuring agents don't phone home or download unexpected packages.

`--readonly` remounts the project directory as read-only. Useful for code review or audit tasks where the agent shouldn't modify files. Both flags are per-session and reset when the VM restarts.

## Customization

### Sharing tokens across VMs: `~/.agent-vm/env`

Put environment variables (API tokens, secrets, etc.) in this file as plain `KEY=value` lines — no `export` prefix, `#` for comments. They're auto-loaded into every shell in every VM:

```bash
# ~/.agent-vm/env
GH_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxxxxxx
ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxx
MISTRAL_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxx
```

These are picked up automatically by the tools that look for them: `gh` reads `GH_TOKEN`, Claude Code uses `ANTHROPIC_API_KEY` when not signed in, Codex uses `OPENAI_API_KEY`, Vibe uses `MISTRAL_API_KEY`, etc. The file is pushed into the VM at `~/.agent-vm.env` (mode 0600) on every `agent-vm` invocation, so edits propagate without `--reset`.

For subscription-based auth (where you've already run `claude login` / `gh auth login` on the host), share the host's credentials directory via [`~/.agent-vm/volumes`](#extra-host-mounts-agent-vmvolumes) instead.

### Extra host mounts: `~/.agent-vm/volumes`

List host files or directories to mount inside every VM. One path per line, `~` is expanded, `#` starts a comment. Uses Docker Compose-style `source[:destination][:mode]` syntax, where `mode` is `ro` (default) or `rw`:

```bash
# ~/.agent-vm/volumes

# Mount at the same path in the VM (read-only)
~/.gitconfig
~/.gitignore

# Mount at a different path in the VM (read-only)
# Note: the destination is used verbatim (no shell expansion) — replace
# $USER with your actual username. Only the source (left) side expands a
# leading ~.
~/.claude:/home/youruser.linux/.claude

# Writable directory
~/.cache/shared:/home/youruser.linux/.cache/shared:rw
```

When no destination is specified, the path is mounted at the same location inside the VM. Non-existent paths are skipped with a warning. Changes to this file take effect on new VMs (use `--reset` to re-apply to existing ones).

`rw` is only supported for **directories**. Files are always read-only: with the hardlink/staging strategy used below, writable file mounts would silently desync on cross-filesystem setups. If you need a writable single file, mount its parent directory as `rw` instead. A destination literally named `ro` or `rw` is treated as a mode keyword — append an explicit `:ro`/`:rw` to disambiguate.

Individual files are supported without exposing their parent directory: agent-vm hardlinks the source into a per-VM staging dir under `~/.agent-vm/file-mounts/<vm>/`, then bind-mounts it at the final destination on each VM start. If the source sits on a different filesystem (hardlink impossible), it falls back to a copy and live host changes won't propagate until the next VM restart. The staged hardlink is refreshed on each `agent-vm` invocation, so atomic-rename edits (common in editors) are picked up at the next VM (re)start.

### Per-user setup: `~/.agent-vm/setup.sh`

Create this file to install extra tools into the base VM template. It runs once during `agent-vm setup`, as the default VM user (with sudo available):

```bash
# ~/.agent-vm/setup.sh
sudo apt-get install -y postgresql-client
pip install pandas numpy
```

### Per-user runtime: `~/.agent-vm/runtime.sh`

Create this file to run commands inside every VM on each start. It runs **before** the per-project `.agent-vm.runtime.sh` script.

Use it for anything that should be available in all your VMs: SSH keys, git config, GitHub CLI auth, Claude Code skills, MCP servers, etc.

**Getting started:**

```bash
cp runtime.example.sh ~/.agent-vm/runtime.sh
# Edit with your own values
```

See [`runtime.example.sh`](runtime.example.sh) for a fully commented template covering:
- SSH key injection for GitHub (base64-encoded private key)
- Git identity and SSH-forced remotes (`url.insteadOf`)
- GitHub CLI authentication (`gh auth login --with-token`)
- Claude Code skills installation (global and per-project)
- MCP server registration (`claude mcp add --scope user`)
- Status line configuration in `~/.claude/settings.json`

**Encoding your SSH key:**

```bash
cat ~/.ssh/id_ed25519 | base64
```

Paste the output into your `runtime.sh` — the script decodes it at boot and sets up `~/.ssh` with proper permissions.

**Global vs per-project runtime:**

| File | Scope | Runs when |
|------|-------|-----------|
| `~/.agent-vm/runtime.sh` | All VMs | Every VM start, first |
| `.agent-vm.runtime.sh` | Current project only | Every VM start, after global |

**Important:** Always launch `agent-vm` from a path without spaces. macOS iCloud paths contain spaces (`~/Library/Mobile Documents/...`), which can break mounts. Create a symlink instead:

```bash
ln -s ~/Library/Mobile\ Documents/com~apple~CloudDocs/Dev ~/Dev
cd ~/Dev/your-project
agent-vm claude
```

### Per-project: `.agent-vm.runtime.sh`

Create this file at the root of any project. It runs inside the VM each time a new VM is created for the project, just before you get access. Use it for project-specific setup like installing dependencies or starting services:

```bash
# your-project/.agent-vm.runtime.sh
npm install
docker compose up -d
```

For projects using a specific language version (Ruby, Python, etc.), install it via mise in the runtime script. mise automatically picks up `.ruby-version`, `.python-version`, `.node-version`, and `.tool-versions` files:

```bash
# your-project/.agent-vm.runtime.sh
mise install
bundle install
```

### MCP servers

The base VM comes with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) pre-configured for Claude, giving the agent headless browser access.

To add more MCP servers, add them to `~/.claude.json` in your `~/.agent-vm/setup.sh`, or edit the file directly inside a VM via `agent-vm shell`. Add entries to the `mcpServers` object:

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

## How it works

1. **`agent-vm setup`** creates a Debian 13 VM with Lima, runs `agent-vm.setup.sh` inside it to install dev tools + Chrome + agents, and stops it as a reusable base template
2. **`agent-vm claude|opencode|codex [args]`** clones the base template into a persistent per-directory VM, mounts your working directory, runs optional runtime scripts (`~/.agent-vm/runtime.sh` then `.agent-vm.runtime.sh`), then launches the agent with full permissions
3. The VM persists after exit. Running any agent command or `agent-vm shell` in the same directory reuses the same VM
4. Use `agent-vm stop` to stop the VM or `agent-vm rm` to delete it. Use `--rm` to auto-delete after the command exits

Each VM is fully isolated — agents must authenticate independently inside their VM (e.g. `claude login`). Credentials persist within the VM across restarts but are not shared between VMs or with the host.

## Project structure

| File | Description |
|------|-------------|
| `agent-vm.sh` | Main script — source this in your shell config |
| `agent-vm.setup.sh` | Package installation script that runs inside the base VM during setup |

## What's in the VM

The wizard's "default install" and `--preinstall=default` produce the same set: everything in the table below except the opt-in languages (Ruby, Rust, Go). Pass a different `--preinstall=` to install a different subset.

| Category | Packages | Name | Installed by default? |
|----------|----------|------|----------------------|
| Core | git, curl, wget, jq, zsh, ca-certificates, build-essential, unzip, zip, ripgrep, fd-find, htop, iptables | (always) | always |
| Build libs | libssl-dev, libreadline-dev, zlib1g-dev, libyaml-dev, libffi-dev | (always) | always |
| Version manager | [mise](https://mise.jdx.dev/) | (always) | always |
| Python | python3, pip, venv | `python` | yes |
| Node.js | Node.js 24 LTS (via NodeSource) | `node` | yes |
| Ruby | ruby-full | `ruby` | no |
| Rust | rustup (stable toolchain) | `rust` | no |
| Go | golang-go | `golang` | no |
| GitHub CLI | gh | `gh` | yes |
| Browser | Chromium (headless), xvfb | `chromium` | yes |
| Containers | Docker Engine, Docker Compose | `docker` | yes |
| AI agents | Claude Code, OpenCode, Codex CLI, Mistral Vibe | `claude`, `opencode`, `codex`, `vibe` | yes |
| MCP | Chrome DevTools MCP (Claude/OpenCode/Codex/Vibe) | — | auto, when Node.js + Chromium + agent installed |

## Security model

AI coding agents need full permissions to be useful — they install dependencies, run builds, execute tests, start servers. But running `npm install` or `pip install` means executing arbitrary third-party code on your machine.

This is not a theoretical risk. The [Shai-Hulud](https://unit42.paloaltonetworks.com/npm-supply-chain-attack/) worm compromised thousands of npm packages in 2025 by injecting malicious code that runs during `npm install`. It harvested npm tokens, GitHub PATs, SSH keys, and cloud credentials from developers' machines, then used those credentials to spread to other packages the developer maintained. All of this happened silently, in the background, while the legitimate install appeared normal.

An AI agent running with `--dangerously-skip-permissions` on your host would give such an attack full access to everything: your SSH keys, your cloud credentials, your browser sessions, your entire filesystem.

**agent-vm runs all code inside the VM.** The VM only has access to your project directory (read-write mount, or read-only with `--readonly`). It has **no access** to your SSH keys, npm tokens, cloud credentials, git config, browser sessions, or anything else on your host. If a supply chain attack executes inside the VM, it finds nothing to steal (except your source code) and nowhere to spread. Use `--offline` to block internet access entirely.

Meanwhile, your host machine stays clean. You don't need Node.js, Docker, or any dev tooling installed locally. The only host dependency is Lima. Your SSH keys and signing credentials never enter the VM — we recommend running `git commit` on the host yourself.

### Why not Docker?

| | No sandbox | Docker | VM (agent-vm) |
|---|---|---|---|
| Agent can run any command | Yes | Yes | Yes |
| File system isolation | None | Partial (shared kernel) | Full |
| Network isolation | None | Partial | Optional (`--offline`) |
| Can run Docker inside | Yes | Requires DinD or socket mount | Yes (native) |
| Kernel-level isolation | None | None (shares host kernel) | Full (separate kernel) |
| Protection from container escapes | None | None | Yes |
| Browser / GUI tools | Host only | Complex setup | Built-in (headless Chromium) |

Docker containers share the host kernel. A motivated attacker (or a compromised dependency running inside the container) could exploit kernel vulnerabilities to escape. A VM runs its own kernel — even root access inside the VM can't reach the host.

A VM also avoids the practical headaches of Docker sandboxing. Docker runs natively inside the VM without Docker-in-Docker hacks. Headless Chromium works out of the box. Lima automatically forwards ports to your host. The agent gets a normal Linux environment where everything just works.

This workflow also replaces Docker Desktop on the Mac, which has become more and more bloated over the years.

## License

MIT

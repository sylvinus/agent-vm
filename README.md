# agent-vm

Run AI coding agents inside sandboxed Linux VMs. The agent runs with permissions bypassed inside the VM, where it has your project directory and not the rest of your machine.

Uses [Lima](https://lima-vm.io/) to create lightweight Debian VMs on macOS and Linux. Ships with dev tools, Docker, and a headless Chrome browser with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) pre-configured.

Supports [Claude Code](https://claude.ai/code), [OpenCode](https://github.com/anomalyco/opencode), [Codex CLI](https://github.com/openai/codex) and [Mistral Vibe](https://docs.mistral.ai/vibe/code/cli/install-setup) out of the box, and [Pi](https://pi.dev) as an opt-in. Other agents can be run via `agent-vm shell`.

Never install potential attack vectors such as npm, claude or even Docker on your host machine again!

Feedback welcome!

## Prerequisites

- macOS or Linux
- [Lima](https://lima-vm.io/docs/installation/) (`agent-vm setup` offers to install it with Homebrew if available). To keep `.git` read-only for the VMs, a Lima build with `sshfs.readonlyNames`, until it is merged upstream: see [Protecting `.git`](#protecting-git)
- On Linux: QEMU and `/dev/kvm`
- A subscription or API key for your agent of choice

## Install

```bash
git clone https://github.com/sylvinus/agent-vm.git
cd agent-vm
./agent-vm.sh install
```

`install` puts `agent-vm` on your `PATH` as a symlink to `agent-vm.sh` in the
clone (in `~/.local/bin`, or `AGENT_VM_BIN_DIR`), so a `git pull` updates the
command and there is nothing to reinstall. `agent-vm uninstall` removes the
link; your VMs and `~/.agent-vm` stay. `./install.sh` still works, as a wrapper
for `./agent-vm.sh install`, and will go in a later release.

It also offers to define `agent-vm` as a shell function. Prefer the symlink: a
shell function is not inherited by child processes, so anything that calls
agent-vm from a script needs the `PATH` entry anyway.

## Usage

### One-time setup

```bash
agent-vm setup
```

Creates a base VM template with dev tools, Docker, Chromium, and AI coding agents pre-installed. Run interactively to open the wizard; its first prompt offers a one-tap "default install" (everything except the opt-in Ruby, Rust, Go, Pi and Playwright MCP), answer `n` for per-component prompts. Pass `--preinstall=...` to skip the wizard. When no terminal is available (CI), the wizard is skipped and the default set is installed.

Creating the base VM (the first run downloads a Debian image) and installing its packages show their last 10 lines only, scrolling in place; the full output is in `~/.agent-vm/setup.log`.

Options:

| Flag | Description | Default |
|------|-------------|---------|
| `--disk GB` | VM disk size in GB | 10 |
| `--memory GB` | VM memory in GB | 3 |
| `--cpus N` | Number of CPUs | 1 |
| `--preinstall=LIST` | Preinstall only this comma-separated subset in the base image (skips the wizard) | — |

Names are lowercase: `python`, `node`, `ruby`, `rust`, `golang`, `docker`, `chromium`, `gh`, `claude`, `opencode`, `codex`, `vibe`, `pi`, `mcp-chrome`, `mcp-playwright`. Use `default` for the default set (everything except Ruby/Rust/Go, `pi` and `mcp-playwright`), `all` for everything, or `none` for nothing. Selecting `codex` or `pi` also installs `node` (they need `npm`), and so does `mcp-chrome` when `chromium` and an agent are selected (it needs `npx`). `mcp-playwright` does not pull `node` in: list it yourself.

The `mcp-*` names wire an MCP server into every installed agent's config, Pi excepted: it has no MCP support. Both current ones drive the preinstalled Chromium, so both need `node` and `chromium` and are skipped with a notice without them. Omit them to leave the agents' MCP config untouched — useful when MCP servers are managed per project rather than baked into the base image.

```bash
agent-vm setup                                       # Interactive wizard
agent-vm setup --preinstall=default                  # Default set, no prompts
agent-vm setup --preinstall=default,rust             # Default set plus Rust
agent-vm setup --preinstall=default,mcp-playwright   # Default set plus Playwright MCP
agent-vm setup --preinstall=default,pi               # Default set plus Pi
agent-vm setup --preinstall=python,docker,claude     # Minimal Claude-only setup
agent-vm setup --preinstall=node,chromium,opencode   # OpenCode, no MCP wired in
agent-vm setup --disk 50 --memory 16 --cpus 8        # Larger VM for heavy workloads
```

### Run an agent in a VM

```bash
cd your-project
agent-vm claude                # Claude Code
agent-vm opencode              # OpenCode
agent-vm codex                 # Codex CLI
agent-vm vibe                  # Mistral Vibe
agent-vm pi                    # Pi (opt-in at setup)
```

Creates a persistent VM for the current directory (or reuses it if one already exists), mounts your working directory, and runs the agent with full permissions. The VM persists after the agent exits so you can reconnect later. Ports opened inside the VM (e.g. by Docker containers or dev servers) are automatically forwarded to your host by Lima.

Each agent runs with its respective auto-approve flag:
- `claude` runs with `--dangerously-skip-permissions`, and the VM also enforces bypass mode via managed settings (`/etc/claude-code/managed-settings.json`) so autonomy survives Claude Code's self-update/fullscreen relaunches — which otherwise drop the CLI flag ([#72479](https://github.com/anthropics/claude-code/issues/72479))
- `opencode` runs with `--auto` (auto-approves permission prompts that aren't explicitly denied)
- `codex` runs with `--dangerously-bypass-approvals-and-sandbox`
- `vibe` runs with `--agent auto-approve`
- `pi` needs no flag: it has no permission prompts. Setup sets `defaultProjectTrust: "always"` in `~/.pi/agent/settings.json`, so a project's `.pi/` extensions and skills load (`pi -p` skips them otherwise)

Lima passes your terminal's `COLORTERM` into the VM, so TUIs draw 24-bit colour when it says `truecolor`. On a terminal that has 24-bit colour but does not set it (Terminal.app on macOS 26 may not), `export COLORTERM=truecolor` in your shell.

Any extra arguments are forwarded to the agent command:

```bash
agent-vm claude -p "fix all lint errors"        # Run with a prompt
agent-vm claude --resume                         # Resume previous session
agent-vm opencode -p "refactor auth module"      # OpenCode with a prompt
agent-vm codex -q "explain this codebase"        # Codex with a query
agent-vm vibe -p "fix all lint errors"           # Mistral Vibe with a prompt
agent-vm pi -p "fix all lint errors"             # Pi with a prompt
```

agent-vm's own options (`--rm`, `--readonly`, `--disk`…) go before the command
(`agent-vm --rm claude`) or right after its name (`agent-vm claude --rm`). From
the first other argument on, everything belongs to the command:
`agent-vm run docker run --rm alpine` passes `--rm` to docker.

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
agent-vm destroy-all # Stop and delete every agent-vm VM, base template included
agent-vm doctor      # Check the host, Lima, the base template and this directory
```

`destroy-all` gives all the disk space back, so it deletes the base template too;
`agent-vm setup` rebuilds it. `doctor` changes nothing: it reports what is
wrong and what to run about it, and prints no secret, so its output can go
into an issue as is. It exits 1 when a check failed.

`stop` and `rm` also take a VM name, as printed by `agent-vm list`:

```bash
agent-vm list
agent-vm rm agent-vm-old-name-1a2b3c4d
```

That is how you reach a VM whose directory was renamed or deleted: the VM name
embeds a hash of the directory path, so once the path changes, no `cd` leads
back to it and `agent-vm list` is the only handle left.

### Scripting against agent-vm

Wrapping agent-vm from another tool? Use these instead of parsing human-facing
output or reading `~/.agent-vm` internals — VM naming, the template name and the
state files are implementation details.

```bash
agent-vm version         # 0.2.0 - gate on this; a build without it predates the command
agent-vm name [dir]      # VM name for a directory (default: cwd)
agent-vm info [dir]      # machine-readable state, one key=value per line
agent-vm env set K V     # store a secret for every VM (see below)
agent-vm env get K       # read it back
agent-vm env has K       # exit 0 if stored, 1 if not, 2 if unreadable (see below)
agent-vm env unset K
agent-vm env list        # key NAMES only, never values
agent-vm project-env …   # same subcommands, for THIS project only
```

Use `agent-vm env` rather than writing `~/.agent-vm/env` yourself: that file is
*sourced* by a shell, so a single mis-escaped quote costs every secret in it, not
just the mis-quoted one. `get`/`has` answer about the file, never about the
ambient environment — which matters because callers often run inside a VM that
already exports those very variables.

`get`/`has` read the file, they do not source it: the project env file sits in
a directory the VM can write to, and sourcing it on the host would run whatever
was put there. They understand what `set` writes and plain dotenv lines
(`KEY=value`, `export KEY=value`, single or double quotes, a trailing
`# comment`). A value that needs the shell to be interpreted (`$`, backquotes,
backslashes, an unquoted `~`, `;`, `|`…) is refused with exit status 2 and a
message; `set` writes it back in a form they can read.

`agent-vm project-env` is the same thing scoped to the current project: same
subcommands, same quoting, same file format. Its values are pushed into the VM
**after** the shared ones, so a key set in both takes the project's value. The
file lives **in the project** (`.agent-vm.env`, like the project runtime
script), so it follows a clone or a move and disappears with the project;
`AGENT_VM_PROJECT_ENV` puts it somewhere else, typically an integrator's own
directory (`.mytool/env`), exactly like `AGENT_VM_PROJECT_RUNTIME`. Being a
file in a repository, it is the wrong place for a secret — `agent-vm env` is
outside any repository. `project-env set` says so out loud: if the file is not
ignored by git it prints the exact `echo … >> .gitignore` line to run (and, if
the file is already tracked, the `git rm --cached` that a gitignore line alone
would not fix). `info` prints the path as `project_env=`, so nobody has to
rebuild it.

`AGENT_VM_STATE_DIR` moves the whole state directory (default `~/.agent-vm`).
Set it to give a test, a CI job or a second install its own state without
moving `HOME` — moving `HOME` also moves Lima's state, which makes a sandboxed
run rebuild every VM. Integrators should read `state_dir` from `info` rather
than rebuilding the path from `$HOME`.

`info` prints `version`, `template`, `state_dir`, `project_env`, `dir`,
`vm_name`, `base_exists`, `vm_exists`, `vm_running` and `vm_stale`. Booleans are `1`/`0`;
anything that cannot be determined is `unknown` rather than a guess — including
`vm_stale` when no base version has been recorded to compare against.
`version`, `name`, `info` and `env` all work without Lima installed (the
Lima-dependent keys of `info` read `unknown`).

`base_exists=1` means the base VM is *usable*, not merely listed by Lima: a
`setup` interrupted while it provisions leaves the template behind with none
of the packages installed, and a VM cloned from that answers every command
with `zsh: command not found`. Running `setup` again deletes and rebuilds it.

Call the command rather than sourcing the file: a shell function is not
inherited by child processes, so a tool that spawns a shell cannot see one.

To require a minimum engine version, ask it rather than parsing `version`:

```bash
agent-vm version --min 0.2.0 || exit 1   # silent when satisfied
```

Exit status is `0` when this engine is at least that version, `1` with an
actionable message when it is older, and `2` when the call itself is malformed
— a typo in the required version must not read as "engine too old". Note that
an engine predating `--min` ignores the flag and exits `0`, so a tool whose
floor is below 0.2.0 still needs its own check to bootstrap.
`agent-vm.sh` does remain safe to `source` from a script running under `set -u`
and `set -o pipefail`; it is *not* written for the caller's `set -e`, since like
most shell libraries it uses `test && action` internally.

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

CPUs and memory are clamped to a share of the host — half of it — so a VM
cannot starve the machine it runs on while the agent works unattended. Asking
for more than that share is not an error: you get the share, and a notice on
stderr rather than silence. `AGENT_VM_HOST_SHARE` changes the divisor (`1`
gives the whole host, `4` a quarter). When the host capacity cannot be read,
nothing is clamped — guessing low on an unknown machine would be worse than
not guessing.

Running `agent-vm setup` again updates the base template but does **not** update existing VMs. You'll see a warning when using a VM cloned from an older base. Use `--reset` to re-clone:

```bash
agent-vm --reset claude                # Destroy and re-clone VM, then run Claude
```

### Read-only mounts

```bash
agent-vm --readonly shell              # Nothing on the host is writable from the VM
```

`--readonly` makes every host share read-only: the project directory, and every `~/.agent-vm/volumes` entry, `rw` ones included (a notice names them). Useful for code review or audit tasks where the agent should not modify anything of yours. The VM's own disk stays writable, so the agent can still install packages and write caches.

All shares, and not just the project, because read-only is enforced per share and not per file: a writable volume that contains the project (`~/work:/mnt/work:rw`) would be a second way to write the same files. With no writable share left, there is none.

It is set on the Lima shares, so the host is what refuses the writes: root inside the VM cannot remount them read-write. That holds for the mount types Lima defaults to (virtiofs on `vz`, 9p on QEMU), and for the `reverse-sshfs` shares agent-vm sets up to [protect `.git`](#protecting-git), whose SFTP server runs on the host. Under any other `reverse-sshfs` the flag only reaches the guest's sshfs, and under QEMU virtiofs only reaches the guest's mount table (virtiofsd has no read-only mode, [virtio-fs/virtiofsd#97](https://gitlab.com/virtio-fs/virtiofsd/-/issues/97)): agent-vm refuses `--readonly` in both cases. QEMU's default, 9p, is fine; only a Lima config that sets `mountType: virtiofs` for QEMU runs into it. Because the mode lives in the VM's config, switching it restarts the VM. agent-vm records the mounts it gave each VM, so a VM that still has a writable share is restarted when `--readonly` is asked for, even if its project is already read-only.

The mode is applied before the runtime scripts run, so a `~/.agent-vm/runtime.sh`
or `.agent-vm.runtime.sh` that writes into the project fails under `--readonly`.

`--offline` and `--git-read-only` were removed in 0.2.0: see [CHANGELOG.md](CHANGELOG.md).

## Customization

### Sharing tokens across VMs: `~/.agent-vm/env`

Put environment variables (API tokens, secrets, etc.) in this file as plain `KEY=value` lines — no `export` prefix, `#` for comments. They're auto-loaded into every shell in every VM.

Edit it by hand, or let agent-vm handle the quoting for you:

```bash
agent-vm env set GH_TOKEN github_pat_xxxx
agent-vm env list                          # names only, never values
```

Scripts should always use `agent-vm env` — the file is *sourced* by a shell, so one mis-escaped quote breaks every secret in it, not just that one.

```bash
# ~/.agent-vm/env
GH_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxxxxxx
ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxx
MISTRAL_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxx
```

For a value that belongs to **one** project (a config path, a per-project
setting), use `agent-vm project-env set K V` from that directory instead. It
writes `.agent-vm.env` in the project and tells you to gitignore it if you have
not; keep secrets in the shared file, which lives outside any repository. Both files are
pushed into the same guest file, the project's one last, so it wins on a key
present in both.

These are picked up automatically by the tools that look for them: `gh` reads `GH_TOKEN`, Claude Code uses `ANTHROPIC_API_KEY` when not signed in, Codex uses `OPENAI_API_KEY`, Vibe uses `MISTRAL_API_KEY`, etc. agent-vm itself knows none of these names: it transports the file, whatever is in it. The file is pushed into the VM on every `agent-vm` invocation, so edits propagate without `--reset`.

#### Letting the agent commit and push

With a Lima that keeps `.git` read-only ([Protecting `.git`](#protecting-git)),
the agent cannot commit in the shared project: this is for repositories it
clones onto the VM's own disk, for a Lima without that protection, or with the
protection turned off by `--unsafe-writable-git` or
`AGENT_VM_UNSAFE_WRITABLE_GIT=1` (read what that costs first).

git reads its identity from the environment too, so the same file covers it —
no `git config` inside the VM, and nothing for agent-vm to configure on your
behalf:

```bash
# ~/.agent-vm/env
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=12345+you@users.noreply.github.com
GIT_COMMITTER_NAME=Your Name
GIT_COMMITTER_EMAIL=12345+you@users.noreply.github.com
```

All four are needed: git refuses to commit without a committer, not just an
author. Note that environment variables win over `git config`, so this
identity applies to every repository in the VM and a per-repo
`git config user.email` will not override it. If you need per-repo identities,
set `user.name`/`user.email` from a runtime script instead.

`gh` picks up `GH_TOKEN` on its own, so `gh pr create` works with nothing else.
Plain `git push` over HTTPS does not: git needs a credential helper. Add one
line to your runtime script if you want it:

```bash
# ~/.agent-vm/runtime.sh
gh auth setup-git    # points git at gh for github.com credentials
```

For subscription-based auth (where you've already run `claude login` / `gh auth login` on the host), share the host's credentials directory via [`~/.agent-vm/volumes`](#extra-host-mounts-agent-vmvolumes) instead.

**What the sandbox does and does not protect here.** Anything in this file is
readable by *everything* running in the VM — the agent, its dependencies, any
code it fetches. The VM keeps those secrets away from your host, but it does not
keep them from the agent, and an agent that has been prompt-injected or a
dependency that has been tampered with can send them out over the network. So:
put a **dedicated, revocable, narrowly-scoped** token here rather than your main
one. Nothing agent-vm offers today stops code in the VM from reading this file
and sending it somewhere; the mitigation is that the token is cheap to revoke.

### Extra host mounts: `~/.agent-vm/volumes`

List host files or directories to mount inside every VM. One path per line, `~` is expanded, `#` starts a comment. Uses Docker Compose-style `source[:destination][:mode]` syntax, where `mode` is `ro` (default) or `rw`:

```bash
# ~/.agent-vm/volumes

# Mount at the same path in the VM (read-only)
~/.gitconfig
~/.gitignore

# Mount at a different path in the VM (read-only)
# Note: the destination is used verbatim (no shell expansion) — replace
# youruser with your actual username. The VM home is /home/youruser.guest
# (Lima 2.1+; /home/youruser.linux before). Only the source (left) side
# expands a leading ~.
~/.claude:/home/youruser.guest/.claude

# Writable directory
~/.cache/shared:/home/youruser.guest/.cache/shared:rw
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

Use it for anything that should be available in all your VMs: git config, `gh auth setup-git`, Claude Code skills, MCP servers, etc. Keep private keys out of it: whatever it sets up, the agent can read. For GitHub, a fine-grained `GH_TOKEN` in `~/.agent-vm/env` can be revoked in one click.

**Getting started:**

```bash
cp runtime.example.sh ~/.agent-vm/runtime.sh
# Edit with your own values
```

See [`runtime.example.sh`](runtime.example.sh) for a fully commented template covering:
- Git identity
- `git push` over HTTPS with `GH_TOKEN` (`gh auth setup-git`)
- Claude Code skills installation (global and per-project)
- MCP server registration (`claude mcp add --scope user`)
- Status line configuration in `~/.claude/settings.json`

**Global vs per-project runtime:**

| File | Scope | Runs when |
|------|-------|-----------|
| `~/.agent-vm/runtime.sh` | All VMs | Every VM start, first |
| `.agent-vm.runtime.sh` | Current project only | Every VM start, after global |

The per-project path is overridable with `AGENT_VM_PROJECT_RUNTIME` (see below).

**Important:** Always launch `agent-vm` from a path without spaces. macOS iCloud paths contain spaces (`~/Library/Mobile Documents/...`), which can break mounts. Create a symlink instead:

```bash
ln -s ~/Library/Mobile\ Documents/com~apple~CloudDocs/Dev ~/Dev
cd ~/Dev/your-project
agent-vm claude
```

### Per-project: `.agent-vm.runtime.sh`

Create this file at the root of any project. It runs inside the VM on every `agent-vm` command in the project, just before you get access, so keep it safe to run again. Use it for project-specific setup like installing dependencies or starting services:

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

**Interpreter.** The script runs under the shell its shebang names — `bash` and
`sh` are honoured, anything else (another language, or no shebang) runs under
`zsh` as before. It is fed on standard input, so `$0` is the shell, not the
file.

**Another location.** Set `AGENT_VM_PROJECT_RUNTIME` to keep the script in your
own directory instead of the project root — useful for a tool that already has
a folder there and would rather not add a second entry to `git status`:

```bash
AGENT_VM_PROJECT_RUNTIME=.mytool/runtime.sh agent-vm claude
```

A relative path resolves against the project directory, an absolute one is used
as-is. Unset, the historical `.agent-vm.runtime.sh` applies.

### Node.js: `node_modules` on the VM's disk

A `node_modules` is often hundreds of thousands of files, and every one of them
crosses the share, which is slowest with the `reverse-sshfs` shares that
[protect `.git`](#protecting-git). It also cannot be shared with the host
anyway: packages with native binaries (esbuild, sharp, the Rollup and SWC
builds) install the Linux build in the VM and the macOS one on a Mac.

So keep it on the VM's own disk: bind-mount a folder of the VM over the
project's `node_modules`, from the project's runtime script, which runs on
every `agent-vm` command:

```bash
#!/bin/bash
# your-project/.agent-vm.runtime.sh
set -e
mkdir -p "$HOME/node_modules" node_modules
mountpoint -q node_modules ||
  sudo mount --bind "$HOME/node_modules" node_modules
```

Each project has its own VM, so `$HOME/node_modules` is this project's. The
host sees an empty `node_modules` folder, or keeps its own if it had one:
install there too if your editor needs the packages. In a workspace, the root
`node_modules` holds nearly everything (npm hoists, pnpm keeps its store in
`node_modules/.pnpm`); repeat the two lines for a package that gets a large one
of its own.

A dev server in the VM reloads on the agent's edits. Lima does not pass file
events from the host by default, so your own edits on the host may need the
watcher's polling mode (for Vite, `server.watch.usePolling`).

### MCP servers

The base VM comes with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) pre-configured for every installed agent, giving it headless browser access. [Playwright MCP](https://github.com/microsoft/playwright-mcp) is available too via `--preinstall=...,mcp-playwright`; it is pointed at the same Chromium with `--executable-path` and launched through `env PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` so it does not pull its own copies of Chromium, Firefox and WebKit into every VM. To drive another engine, edit its entry (drop `--executable-path`, add e.g. `--browser firefox`) and run `npx playwright install firefox` inside the VM.

Drop either one with `--preinstall`: the names are opt-in like any other component, so `--preinstall=node,chromium,opencode` installs OpenCode with no MCP server wired in. That is the switch to use when MCP servers are managed per project instead.

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

## Tests

```bash
./test.sh
```

Runs against a stub `limactl` in a throwaway `HOME`: no VM is created, started or
deleted, your real `~/.agent-vm` is untouched, and no network is needed. It covers
VM naming, resource comparison, staleness, the `info`/`version`/`name` surface,
the `--preinstall` parser, the MCP config writer, and how the shares follow
what Lima can do for `.git` (the stub answers like stock Lima or like a build
with `readonlyNames`, and a stub `brew` stands in for the install).

Worth running under bash 3.2 as well — it is what macOS ships, and it is stricter
about empty array expansion under `set -u`, which modern bash forgives:

```bash
docker run --rm -v "$PWD:/w" -w /w bash:3.2 ./test.sh
zsh ./test.sh
```

### End-to-end, against a real VM

```bash
./test-e2e.sh
```

The other half. A stub `limactl` cannot tell you whether `--readonly` is a real
boundary, so this one builds a VM with `--preinstall=none`, writes into the
project from inside it, and then has root in the guest try to remount the share
read-write. That last check is the one that matters: it is what `--offline` and
`--git-read-only` would have failed before they were removed.

With a Lima that has `sshfs.readonlyNames`, it also checks that root in the VM
cannot change `.git/config`, add a hook, move `.git` away, write a nested
repository or create a `.GIT`, while the rest of the project stays writable.
With stock Lima those checks are reported as skipped.

It runs in a throwaway `LIMA_HOME` with its own state directory, so your
`agent-vm-base` and your project VMs are never read, edited or deleted, and
everything it created is removed on exit, Ctrl-C included. It needs Lima on the
host and a few minutes.

## Project structure

| File | Description |
|------|-------------|
| `agent-vm.sh` | The whole command — put it on your PATH |
| `agent-vm.setup.sh` | Package installation script that runs inside the base VM during setup |
| `install.sh` | Former installer, now a wrapper for `./agent-vm.sh install` |
| `test.sh` | Test suite — runs against a stub `limactl`, creates no VMs |
| `test-e2e.sh` | End-to-end suite — builds a real VM in a throwaway `LIMA_HOME` |
| `runtime.example.sh` | Commented template for `~/.agent-vm/runtime.sh` |
| `CHANGELOG.md` | What changed in each release |
| `release.sh` | Tags and publishes a release after checking it (`./release.sh X.Y.Z --dry-run` first) |
| `www/` | The www.agent-vm.org website |

## What's in the VM

The wizard's "default install" and `--preinstall=default` produce the same set: everything in the table below except the opt-in languages (Ruby, Rust, Go). Pass a different `--preinstall=` to install a different subset.

| Category | Packages | Name | Installed by default? |
|----------|----------|------|----------------------|
| Core | git, curl, wget, jq, zsh, ca-certificates, build-essential, unzip, zip, ripgrep, fd-find, htop | (always) | always |
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
| AI agents | Pi | `pi` | no |
| MCP | Chrome DevTools MCP (Claude/OpenCode/Codex/Vibe) | `mcp-chrome` | yes, when Node.js + Chromium + an agent are installed |
| MCP | Playwright MCP, reusing the Chromium above | `mcp-playwright` | no |

## Security model

AI coding agents need full permissions to be useful — they install dependencies, run builds, execute tests, start servers. But running `npm install` or `pip install` means executing arbitrary third-party code on your machine.

This is not a theoretical risk. The [Shai-Hulud](https://unit42.paloaltonetworks.com/npm-supply-chain-attack/) worm compromised thousands of npm packages in 2025 by injecting malicious code that runs during `npm install`. It harvested npm tokens, GitHub PATs, SSH keys, and cloud credentials from developers' machines, then used those credentials to spread to other packages the developer maintained. All of this happened silently, in the background, while the legitimate install appeared normal.

An AI agent running with `--dangerously-skip-permissions` on your host would give such an attack full access to everything: your SSH keys, your cloud credentials, your browser sessions, your entire filesystem.

**agent-vm runs all code inside the VM.** Its filesystem is your project directory (read-write, or read-only with `--readonly`, which also makes any extra mount read-only) and nothing else of yours: no SSH keys, no npm tokens, no cloud credentials, no git config, no browser sessions. A supply chain attack that executes in there finds your source code and whatever you put in `~/.agent-vm/env`. It does still have the network, and that includes your own machine: Lima puts the host loopback at `192.168.5.2`, which is the VM's default gateway, so anything you have listening on `localhost` (a dev Postgres, Redis, an unauthenticated local API) is reachable from inside the VM. Blocking that is [on the roadmap](https://www.agent-vm.org/#roadmap), not something agent-vm can do today.

Meanwhile, your host machine stays clean. You don't need Node.js, Docker, or any dev tooling installed locally. The only host dependency is Lima. Your SSH keys and signing credentials never enter the VM — we recommend running `git commit` on the host yourself.

### Protecting `.git`

A shared project folder is a way back to the host, through git. Git on your machine runs what a repository's `.git/config` and `.git/hooks` name: `core.fsmonitor` on every `git status` or `git diff`, hooks on commit, filters, diff drivers. None of it shows in `git diff`, and you do not have to run git yourself: editors and many shell prompts run `git status` in the background. If the VM could write those files, it could run commands on your host within seconds.

So every `.git` in the shared folders is read-only for the VMs, at any depth (nested repositories included) and whatever the case of the name, while the rest of the project stays writable. Lima's SFTP server enforces it on the host, so root in the VM cannot lift it. The agent can still read `.git`: `git status`, `git diff` and `git log` work in the VM, `git commit` does not. Review and commit from the host.

This needs Lima's `sshfs.readonlyNames`, which is not merged upstream yet ([lima-vm/lima#5529](https://github.com/lima-vm/lima/issues/5529)). Until it is, a Lima build that has it:

```bash
# macOS, or Linux with Homebrew. brew refuses it next to its own lima, hence the unlink.
brew unlink lima; brew install sylvinus/tap/lima-sylvinus

# Linux without Homebrew: build it (needs Go and make; installs to /usr/local)
git clone --depth 1 -b v2.3.0-sylvinus.1 https://github.com/sylvinus/lima
cd lima && make native && sudo make install
```

`agent-vm setup` checks which Lima you have. Without the protection it says so, and with Homebrew and a terminal it offers to run the Homebrew line above (and offers this build first when Lima is not installed at all). The formula builds from source, so it takes a few minutes. Going back is `brew uninstall lima-sylvinus && brew link lima`. `agent-vm doctor` shows where you stand, for Lima and for the current directory's VM.

What changes when Lima has it:

- **The shares use Lima's `reverse-sshfs`** with its builtin SFTP server, which `readonlyNames` needs, instead of virtiofs or 9p. It is slower on workloads that touch many files.
- **Existing VMs switch on their next start.** A VM that is already running keeps its shares until it stops (`agent-vm stop`); agent-vm says so. The reverse holds too: with a Lima that does not have it, a VM goes back to Lima's default mount type on its next start, since `reverse-sshfs` without it is the weaker option.
- **The agent cannot commit in the shared project.** To let it anyway, pass `--unsafe-writable-git` (or `--unsafe-writable-git=1`) as a VM option, or set `AGENT_VM_UNSAFE_WRITABLE_GIT=1` in your shell for every command (exactly `1`). Only the command line and your shell's environment count, never a file in the project, which the VM could write. The VM then gets Lima's default mount type and a writable `.git`, which puts back everything described at the top of this section: the agent can make git on your machine run commands. agent-vm prints a warning on every run that asks for it, and `doctor` reports the variable. The mount type only changes on a stopped VM: a running VM keeps its read-only `.git` until it stops, and one started with the flag keeps a writable `.git` until it is stopped and run again without it (agent-vm warns).

What this does not cover:

- **A repository under another name than `.git`.** A folder holding `HEAD`, `objects/`, `refs/` and a `config` is a (bare) repository to git, whatever its name, found by the same upward search from the current directory. The VM can create one anywhere in the project, and git on your machine then runs the commands its `config` names when you use git in that folder: `core.pager`, the command git pipes its output through, runs as soon as you type `git log` there. `git config --global safe.bareRepository explicit` (git 2.38 or later) makes git use a bare repository only when `--git-dir` or `GIT_DIR` names it. `agent-vm setup` asks to set it, prints it when there is no terminal to ask on, and `doctor` warns while it is not set or git is too old to honour it.
- **Tracked files your own tools run on their own**, such as a `.vscode/tasks.json`, a `build.rs` run by rust-analyzer, an `eslint.config.js` loaded by your editor, a `core.hooksPath` pointing into the working tree, or husky and pre-commit hooks kept in the repository. Those changes do show in `git status` and `git diff`: read them before your tools do. When VS Code asks, leave the project untrusted (Restricted Mode), which keeps tasks and code-running extensions off, and do not trust a parent folder, which trusts everything below it. JetBrains IDEs have the same choice (Safe Mode).

### Why not Docker?

| | No sandbox | Docker | agent-vm |
|---|---|---|---|
| Agent can run any command | Yes | Yes | Yes |
| Host files it can reach | All of them | What you mount | The project directory |
| Outbound network | Open | Open by default | Open |
| Shares the host kernel | Yes | Yes | No |
| Reaching the host needs | Nothing | A kernel bug | A hypervisor bug |
| Can run Docker inside | Yes | Requires DinD or socket mount | Yes (native) |
| Browser / GUI tools | Host only | Complex setup | Built-in (headless Chromium) |

Docker containers share the host kernel. A motivated attacker (or a compromised dependency running inside the container) could exploit kernel vulnerabilities to escape. A VM runs its own kernel — even root access inside the VM can't reach the host.

A VM also avoids the practical headaches of Docker sandboxing. Docker runs natively inside the VM without Docker-in-Docker hacks. Headless Chromium works out of the box. Lima automatically forwards ports to your host. The agent gets a normal Linux environment where everything just works.

This workflow also replaces Docker Desktop on the Mac, which has become more and more bloated over the years.

## License

MIT

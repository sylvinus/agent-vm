# agent-vm

Run AI coding agents in a disposable Linux VM per project, with permissions bypassed. The VM gets your project directory and nothing else of yours: no SSH keys, no browser sessions, no rest of your disk.

One binary with [Lima](https://lima-vm.io/) built in. Ships dev tools, Docker, headless Chromium with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp), and [Claude Code](https://claude.ai/code), [OpenCode](https://github.com/anomalyco/opencode), [Codex CLI](https://github.com/openai/codex), [Mistral Vibe](https://docs.mistral.ai/vibe/code/cli/install-setup) and, opt-in, [Pi](https://pi.dev). macOS and Linux; Windows is experimental.

**Documentation: [www.agent-vm.org](https://www.agent-vm.org/)** · Chat: [#agent-vm:matrix.org](https://matrix.to/#/#agent-vm:matrix.org)

## Install

```bash
curl -fsSL https://www.agent-vm.org/install.sh | sh
```

Or `brew install sylvinus/tap/agent-vm`. From a clone, with Go (and on macOS the Xcode command line tools): `./agent-vm.sh install` builds it and links it onto your `PATH`; after a `git pull`, run it again. See [Install](https://www.agent-vm.org/#install) for prerequisites.

## Use

```bash
agent-vm setup                 # build the base template, once
cd your-project
agent-vm claude                # or opencode, codex, vibe, pi
agent-vm shell                 # a shell in this project's VM
agent-vm run npm test          # one command in it
agent-vm code                  # VS Code in the browser (setup --preinstall=default,code-claude)
agent-vm --readonly shell      # nothing on the host writable from the VM
agent-vm --scratch claude      # nothing of yours mounted, VM deleted on exit
agent-vm stop                  # or rm; list for all VMs
agent-vm doctor                # what is wrong, and what to run
```

Everyday use: [Usage](https://www.agent-vm.org/#usage). Every command, option, file and variable: [Reference](https://www.agent-vm.org/#reference).

## Security

The agent is root in its VM and has the network. What it can reach on your machine is what crosses the shares:

- Every `.git` and `.hg`, and the folder of a `core.hooksPath` inside the project, are read-only for the VM: the file server built into agent-vm enforces it on your machine. Before a VM boots, agent-vm stops on what it cannot protect and asks whether to go on: [Protecting .git](https://www.agent-vm.org/#git).
- Files your machine runs without asking (`.envrc`, `.vscode/tasks.json`, `.pre-commit-config.yaml`...) are guarded: when the VM writes one, a dialog asks you first, and the write is refused where none can be shown. Add or remove paths in `~/.agent-vm/guarded`.
- The agent writes the project folder: on your machine, open it in your editor and use git there, and run everything else in the VM. Open agent-vm projects in VS Code's Restricted Mode, and never connect an editor to the VM over SSH (Remote-SSH trusts the VM with your machine: [SSH from your machine](https://www.agent-vm.org/#ssh-from-your-machine)). Editors, agents, commit hooks and commands you run on the host can run code the agent wrote: [What else reads the project](https://www.agent-vm.org/#what-else-on-your-machine-reads-the-project).
- The VM reaches the internet, not your machine nor your local network: what it may reach there, or the only domains it may reach, go in `~/.agent-vm/network`. A port the VM listens on is forwarded to your machine's loopback, unless something there uses it already.

## Development

```bash
make                                       # _output/bin/agent-vm
make test-go                               # no VM; 0.2's recorded behavior where it is compared
go test -tags e2e ./internal/vm/ ./internal/cli/   # real VMs
make check-third-party test-third-party    # Lima, sshocker, pkg/sftp, gvisor-tap-vsock: upstream + patches/
make fuzz FUZZTIME=5m                      # each fuzzer; their seeds run with the tests
```

Releases: [RELEASING.md](RELEASING.md). Plan: [PLAN_0.3.0.md](PLAN_0.3.0.md). The website is in [`www/`](www/README.md). Changes: [CHANGELOG.md](CHANGELOG.md).

## License

MIT

# agent-vm

Run AI coding agents in a disposable Linux VM per project, with permissions bypassed. The VM gets your project directory and nothing else of yours: no SSH keys, no browser sessions, no rest of your disk.

Built on [Lima](https://lima-vm.io/). Ships dev tools, Docker, headless Chromium with [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp), and [Claude Code](https://claude.ai/code), [OpenCode](https://github.com/anomalyco/opencode), [Codex CLI](https://github.com/openai/codex), [Mistral Vibe](https://docs.mistral.ai/vibe/code/cli/install-setup) and, opt-in, [Pi](https://pi.dev). macOS, Linux, and Windows (Git Bash, experimental).

**Documentation: [www.agent-vm.org](https://www.agent-vm.org/)** · Chat: [#agent-vm:matrix.org](https://matrix.to/#/#agent-vm:matrix.org)

## Install

```bash
git clone https://github.com/sylvinus/agent-vm.git
cd agent-vm && ./agent-vm.sh install
```

`git pull` in the clone updates it. Or `curl -fsSL https://www.agent-vm.org/install.sh | sh`, or `brew install sylvinus/tap/agent-vm`. See [Install](https://www.agent-vm.org/#install) for prerequisites and Windows.

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

- Every `.git` and `.hg`, and the folder of a `core.hooksPath` inside the project, are read-only for the VM with a Lima that has `sshfs.readonlyNames`, which `agent-vm setup` offers to install. Before a VM boots, agent-vm stops on what it cannot protect and asks whether to go on: [Protecting .git](https://www.agent-vm.org/#git).
- The agent writes the project folder: on your machine, open it in your editor and use git there, and run everything else in the VM. Open agent-vm projects in VS Code's Restricted Mode, and never connect an editor to the VM over SSH (Remote-SSH trusts the VM with your machine: [SSH from your machine](https://www.agent-vm.org/#ssh-from-your-machine)). Editors, agents, commit hooks and commands you run on the host can run code the agent wrote: [What else reads the project](https://www.agent-vm.org/#what-else-on-your-machine-reads-the-project).
- The VM reaches your machine's loopback and prints to your terminal: [Security](https://www.agent-vm.org/#security).

## Development

```bash
./test.sh                                              # stub limactl, no VM, no network
docker run --rm -v "$PWD:/w" -w /w bash:3.2 ./test.sh  # what macOS ships
./test-e2e.sh                                          # a real VM, needs Lima
```

Layout and guidelines: [Contribute](https://www.agent-vm.org/#contribute). Releases: `./release.sh X.Y.Z --dry-run`, then without it. The website is in [`www/`](www/README.md). Changes: [CHANGELOG.md](CHANGELOG.md).

## License

MIT

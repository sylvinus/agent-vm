# Changelog

## 0.2.0

### Security

- Every `.git` in the shared folders is read-only for the VMs, at any depth,
  when Lima has `sshfs.readonlyNames`. Before, a VM could write a project's
  `.git/config` or hooks, and git on the host (editors and shell prompts
  included) would run what they name: commands on your machine. Lima's SFTP
  server enforces it on the host, so root in the VM cannot lift it. The shares
  then use `reverse-sshfs` with the builtin SFTP driver, and existing VMs
  switch on their next start. The field is not in upstream Lima yet
  (lima-vm/lima#5529): `setup` checks for it, says what is at stake without
  it, and offers to install `sylvinus/tap/lima-sylvinus` with Homebrew.
  `doctor` reports it too. `--unsafe-writable-git`, or
  `AGENT_VM_UNSAFE_WRITABLE_GIT=1` in the shell, turns it off, for those who
  let the agent commit in the project, with a warning on every run.
- `setup` asks to set `safe.bareRepository=explicit` in the global git config,
  and `doctor` warns while it is not set, or while git is older than 2.38 and
  ignores it. A folder holding `HEAD`, `objects/`, `refs/` and a `config` is a
  repository to git under any name, so `readonlyNames` does not cover it: a VM
  could create one in a project, and git on the host would run the commands its
  `config` names (`core.pager` as soon as `git log` is typed there).
- `--readonly` is now set on the Lima shares, so the host refuses the writes
  and root in the VM cannot lift it. It used to be a remount inside the
  guest. Under `reverse-sshfs` without `readonlyNames`, where Lima only passes
  the flag to the guest, agent-vm refuses `--readonly` instead of pretending.
  Switching the mode restarts the VM.
- `--readonly` is refused on virtiofs under QEMU, where Lima's virtiofsd has no
  read-only mode and the flag only reaches the guest. It was accepted there as
  enforced on the host. 9p, QEMU's default, and virtiofs on `vz` are enforced.
- `--readonly` covers every share, `rw` entries of `~/.agent-vm/volumes`
  included. Read-only is enforced per share, so a writable volume containing
  the project was a second way to write it.
- `agent-vm env get/has` and `project-env get/has` read the file instead of
  sourcing it. The project env file sits in a directory the VM can write to,
  so sourcing it on the host could run code the agent wrote there. Values that
  need a shell to be interpreted are refused with exit status 2.
- A project path containing a quote, a backslash or a control character is
  refused. It was spliced into the Lima mount config and could add mounts of
  its own (the home directory, read-write).
- Declining to stop a running VM for a `--disk`, `--memory`, `--cpus` or
  `--ssh-port` change, or having no terminal to accept it on, no longer skips
  the rest of the start: `--readonly` was then never applied and the command
  ran on a writable VM. The VM now keeps its settings and everything else
  applies.

### Removed

Both flags claimed a restriction they could not hold: inside the VM the agent
has passwordless sudo, so anything enforced there is advisory at best.

- `--offline` set `iptables` rules in the guest; one
  `sudo iptables -P OUTPUT ACCEPT` undid them. Blocking outbound traffic has to
  happen on the host, and Lima exposes no setting for it: see
  [the roadmap](https://www.agent-vm.org/#roadmap).
- `--git-read-only` bind-mounted `.git` read-only in the guest; one
  `sudo umount` undid it. A nested read-only share over a writable parent is not
  a boundary either, since unmounting the child exposes the same files through
  the parent. Keep commits on the host and review the diff yourself.
- `iptables` is no longer in the base packages (Docker still pulls it in).
- `runtime.example.sh` no longer suggests copying an SSH private key into every
  VM. Use a revocable `GH_TOKEN` in `~/.agent-vm/env`.

### Changed

- `agent-vm.sh` loads the rest of agent-vm from `lib/`, next to it, and stops
  with the name of the missing file when it is not there: a copy of
  `agent-vm.sh` on its own no longer works. Clones, the curl installer and
  release tarballs have it.
- agent-vm's options are read the same way before the command and right after
  its name: `agent-vm claude --disk=50` resizes the VM instead of passing
  `--disk=50` to Claude, and `agent-vm claude --disk 10G` is refused with the
  reason instead of failing later with a bash error.
- `--readonly` is applied before the runtime scripts run, not after. A
  `~/.agent-vm/runtime.sh` or `.agent-vm.runtime.sh` that writes into the project
  fails under the flag.
- VM options are only read before the command or right after its name:
  `agent-vm run docker run --rm alpine` passes `--rm` to docker. It used to be
  taken as agent-vm's own `--rm`, which deleted the VM afterwards.
- `destroy-all` says it deletes the base template too, and forgets it properly.
- `agent-vm setup` asks before installing Lima with Homebrew, offering the
  build that keeps `.git` read-only first, and without a terminal prints the
  command instead.
- The setup wizard is skipped when no terminal can be opened. It used to test
  `-r /dev/tty`, which is true in CI too.
- `--cpus` and `--memory` are clamped to half the host (`AGENT_VM_HOST_SHARE`
  changes the divisor), with a notice.
- Runtime scripts run under the shell their shebang names (bash, sh; zsh
  otherwise).
- `agent-vm shell` rejects arguments it does not know instead of skipping them.
- `setup` rejects `--reset` and `--readonly` instead of ignoring them, and
  the other commands that start no VM (`stop`, `status`, `env`…) reject
  every VM option: `agent-vm --readonly stop` read as if something had been
  made read-only.
- The wizard's per-component prompts default Ruby, Rust and Go to no, like
  the default set.
- The base VM is about 300 MB smaller and runs fewer daemons: apt no longer
  installs Recommends. Those brought in, through Chromium, printer
  configuration, Samba libraries, `avahi-daemon`, `upower` and Vulkan
  drivers. The recommended packages that are used (`docker-buildx-plugin`,
  `xauth`, `python3-dev`...) are installed by name, as is `pkgconf`, which
  mise builds use and which was only there with Go.
- Node.js comes from the NodeSource repository configured directly, instead
  of running NodeSource's setup script as root, which also installed `gnupg`.
- `fonts-dejavu-core` is installed with Chromium. With Liberation alone, pages
  asking for the generic `sans-serif` or `serif` rendered in Liberation Mono.
- The base VM is created without Lima's containerd. Its unit shadowed Docker's
  `containerd.service`, and `docker` could not reach its daemon. Existing VMs
  keep it until `agent-vm setup` and `--reset`.
- Every agent-vm command that uses a VM makes one `limactl shell` round trip
  fewer: the env push and the check that the project share is writable share
  one.
- `setup` shows the creation and first start of the base VM (which downloads
  the Debian image) and the package install in a 10-line window that scrolls
  in place and is cleared when done. The full output goes to
  `~/.agent-vm/setup.log`, whose end is printed again if a step fails. Without
  a terminal, the output is printed as before.
- `setup` opens on the wizard, agents first, and runs its security checks
  (`.git` protection, `safe.bareRepository`) last, before creating the VM.
  Their warnings are shorter, in a box fitted to the terminal, with the
  question right below.

### Added

- Windows, experimental, from Git Bash, with QEMU. `setup` offers to
  download a Lima build for Windows that keeps `.git` read-only (checked
  against its `SHA256SUMS`, and replaced when agent-vm moves to a newer one),
  finds winget's QEMU where it installs it, and explains a start that fails
  on WHPX: QEMU needs the "Windows Hypervisor Platform" feature, which only
  an administrator can turn on. Paths go to Lima in Windows form, with Git
  Bash's argument rewriting off for `limactl`. `install` writes a small
  launcher where Git Bash makes no symlinks. Runtime scripts and env files
  saved with CRLF reach the VM without the CRs.
- Inside WSL, `setup` and `doctor` say when KVM is missing because of WSL1 or
  of nested virtualization on the Windows side.
- An entry of `~/.agent-vm/volumes` can be limited to some projects with a
  fourth field, after an explicit mode: `source:destination:mode:project`,
  where `project` is a path, `~` expanded, and `*` matches anything
  (`~/.cache/pip:/home/you.guest/.cache/pip:rw:~/work/*`).
- A relative destination in `~/.agent-vm/volumes` is inside the project
  (`~/.claude-vm/webapp:.claude:ro:~/work/webapp`). The mount point is created in
  the project on the host when missing. One that leaves the project with `..`
  or goes through a symlink in it is skipped. It used to reach Lima as is,
  which refuses a relative mount point.
- `--ssh-port N` gives a VM a fixed host port for SSH, for IDEs and GUI agents
  that save the port rather than an alias (#28). `0` goes back to a new port on
  each start. A port another agent-vm VM has is refused. `info` gains
  `ssh_host` and `ssh_config`: Lima's alias for the VM and the SSH config file
  it keeps current. The README has the `~/.ssh/config` lines to use them, which
  keep the host's SSH agent out of the VM.
- `curl -fsSL https://www.agent-vm.org/install.sh | sh` installs the latest
  release, checked against its `SHA256SUMS`, in `~/.local/share/agent-vm`, and
  runs `agent-vm install`. Running it again updates. `--version X.Y.Z` picks a
  release, `--git` installs a clone instead. `version --min` now names the
  update command that fits the install: `git pull`, `brew upgrade` or the
  installer.
- `agent-vm install` and `agent-vm uninstall` replace `install.sh`, which
  stays for now as a wrapper (`--uninstall` included). `uninstall` works from
  anywhere, not only from the clone, and `install` refuses a dangling link in
  the way instead of failing on it. When the base VM is not built yet,
  `install` offers to run `setup` right away.
- `agent-vm doctor`: read-only checks of the host, Lima, the base template and
  the current directory, with what to run about each problem. It also says
  whether Lima and the current directory's VM keep `.git` read-only, and
  whether git ignores repositories not named `.git`.
- `sshfs` in the base packages, for the `reverse-sshfs` shares.
- `agent-vm version --min X.Y.Z`, `agent-vm project-env`,
  `AGENT_VM_PROJECT_ENV`, `AGENT_VM_PROJECT_RUNTIME` and `AGENT_VM_STATE_DIR`,
  and `project_env=` / `state_dir=` in `agent-vm info`.
- `test-e2e.sh`, which builds a real VM in a throwaway `LIMA_HOME` and checks
  that root in the guest cannot lift `--readonly`, nor write `.git` when Lima
  has `readonlyNames`.
- `agent-vm pi` runs [Pi](https://pi.dev), opt-in at setup (`pi` in
  `--preinstall`, not in `default`). It pulls in `node`. Pi has no permission
  prompts, so it takes no flag; setup trusts a project's `.pi/` extensions and
  skills, which `pi -p` would skip otherwise. Pi has no MCP support, so the
  `mcp-*` servers are not wired into it.
- Starting a VM prints when its base VM was built (`Base VM: built
  2026-09-28, 3 days ago`): its agents and packages are that old.

### Fixed

- Creating a VM fails loudly, with Lima's message, when `limactl clone` or
  the edit that gives the VM its shares, memory, CPUs and SSH port fails, and
  the half-made VM is deleted so the next run starts over (#21). Both used to
  be silent: the VM then ran with the template's config, without the
  `~/.agent-vm/volumes` entries or the requested resources.
- Symlinks to an absolute path or through `..` work again in `reverse-sshfs`
  shares, `node_modules/.bin` included (#22). Debian's sshfs security update
  (CVE-2026-47187) refuses them by default, with `EPERM`, to protect a client
  from a rogue server. Here the server is your host, so the base VM runs sshfs
  with `-o no_contain_symlinks`. Rebuild the base with `setup`, then `--reset`
  the project VMs.
- VM names fall back to `sha256sum` when `shasum` is missing, and naming fails
  rather than dropping the hash (two projects with the same directory name
  would have shared one VM).
- `status` says "(no VMs)" when there are none.
- A new VM prints its resources once instead of twice.
- `destroy-all` no longer risks skipping VMs when `limactl` reads stdin.
- Prompts no longer print a `/dev/tty` error when there is no terminal.
- The VM's mise install uses `curl -f`, so an HTTP error fails setup instead of
  piping an error page into `sh`.
- Version checks compare each component as a decimal number: `1.0.1000` no
  longer outranks `1.1.0`, and `08` is no longer an octal error.
- `AGENT_VM_HOST_SHARE` that is not a positive integer falls back to 2 with a
  warning, instead of a division error or being evaluated as a variable name.
- A shared env file without a final newline no longer merges its last line
  into the project env's first one.
- Removing every env entry on the host now empties `~/.agent-vm.env` in the
  VM, instead of leaving the previous values there.
- `env set` and `env unset` on a key holding a multi-line value remove all of
  it. They removed the first line only, leaving an unterminated quote that
  broke the file in the VM for every key after it. `unset` also removes an
  `export KEY=` line, and `list` no longer shows a line inside a value as a
  key.
- `LIMA_HOME` is honoured when cleaning up an interrupted VM creation and in
  the log paths printed on a failed start.
- A runtime script with an option in its shebang (`#!/bin/bash -e`,
  `#!/usr/bin/env -S bash -e`) runs under bash, not zsh.

## 0.1.0

- `install.sh` puts `agent-vm` on the `PATH`, so other tools can call it.
- New commands for integrators: `version`, `name`, `info`, `env`.
- `mcp-chrome` and `mcp-playwright` in `--preinstall`.

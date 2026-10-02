# Changelog

## Unreleased

### Added

- `agent-vm code`: VS Code (code-server) served from the VM and opened in
  the browser, until Ctrl-C. Opt-in at setup: `--preinstall=code-server`
  for the editor alone, `code-claude`, `code-codex` and `code-vibe` for it
  with that agent's extension, each starting with no permission prompts.
  The wizard asks about the editor after the agents, then whether the
  agents that have an extension get it, the command line, or both. An
  extension ships its own copy of its agent: without the command line,
  `agent-vm claude` (or `codex`, `vibe`) says it is not installed. Dark
  theme, GitHub Copilot disabled, no telemetry, no welcome page, tips,
  recommendations or experiments. The JSON schemas the editor validates
  files with (`package.json`, `tsconfig.json`...) are downloaded once by
  `setup`: opening a file sends no request.
- The editor's password is made in each VM on first use, never in the base,
  of which every VM is a copy, and printed. Each VM's editor is at
  `http://<vm-name>.localhost:<port>/`, a port of its own from 20000 to
  29999, the same on every start: browsers keep cookies per host name, not
  per port, so at `127.0.0.1` a page served by any VM would get the session
  of every editor, which logs into it. Safari may not resolve `*.localhost`:
  then `127.0.0.1` in a private window kept for the editor. code-server's
  port proxy is off.

### Changed

- A command that is not in the VM (`agent-vm run foo`, or an agent not
  installed) says so, with status 127, instead of `env`'s error.

## 0.2.0

### Security

- The host no longer reads the project's `.agent-vm.runtime.sh` by its
  path. The VM can write the project and make it a symlink to any file of
  yours: the host followed it on every start and handed the content to the
  VM (`ln -s ~/.ssh/id_ed25519 .agent-vm.runtime.sh` got the key on the next
  command). The VM now reads it itself, where a link only reaches the VM's
  own files. The project's `.agent-vm.env`, new here, is read the same way,
  and `project-env` refuses a file that is a link, or reached through one,
  without a window the VM could race; it needs `perl` for that. Whether a
  file is in the project is decided by where its path leads, not by how it
  is spelled (the project's real path while it is used through a link). A
  file kept outside the project with `AGENT_VM_PROJECT_ENV` or
  `AGENT_VM_PROJECT_RUNTIME` is read on the host.
- The home directory, `/`, agent-vm's own directory, its state directory,
  Lima's, any directory containing one of them, and any directory inside one
  of the last three are refused as a project: `cd ~ && agent-vm shell`
  shared `~/.ssh` and every dotfile read-write, and from inside agent-vm's
  folder the VM could change the files the host runs next.
- `--readonly` on a stopped VM that last ran writable makes it read-only
  before it boots. It used to start it writable, then stop it and apply the
  change.
- Whether `--readonly` is enforced on the host is decided from what Lima
  reports for the VM, not by asking the guest, which could lie.
- A `limactl stop` that did not stop the VM is caught before its shares are
  changed.
- Every `.git` in the shared folders is read-only for the VMs, at any depth,
  when Lima has `sshfs.readonlyNames`. Before, a VM could write a project's
  `.git/config` or hooks, and git on the host (editors and shell prompts
  included) would run what they name: commands on your machine. Lima's SFTP
  server enforces it on the host, so root in the VM cannot lift it. The shares
  then use `reverse-sshfs` with the builtin SFTP driver, and existing VMs
  switch on their next start. A VM made by agent-vm 0.1.0, or cloned from a
  base it built, has no `sshfs`: it boots once without shares to install it,
  with a warning, before it gets them. Without it, Lima installed Debian's at
  boot, which needs apt then and breaks symlinks (see #22 below). `doctor`
  reports a base built by 0.1.0. This migration will be removed in a future
  release: `setup`, then `--reset`. The field is not in upstream Lima yet
  (lima-vm/lima#5529): `setup` checks for it, says what is at stake without
  it, and offers to install `sylvinus/tap/lima-sylvinus` with Homebrew.
  `doctor` reports it too. `--unsafe-writable-git`, or
  `AGENT_VM_UNSAFE_WRITABLE_GIT=1` in the shell, turns it off, for those who
  let the agent commit in the project, with a warning on every run.
- Every `.hg` is read-only as well: Mercurial runs the hooks of `.hg/hgrc`
  in a repository you own. When git's `core.hooksPath` puts the hooks in the
  project (husky sets `.husky/_`), the first folder of that path, from the
  top of its repository, joins the names too, so the agent cannot change the
  hooks git runs on your commits. The repository holding the project and
  those up to two levels below it are checked, with git before 2.31 too. A
  name that does not start with a dot would lock every folder of that name
  in the project, so the start asks first (yes by default). Hooks at the top
  of a repository cannot be protected by name. `doctor` reports all of it.
- Before a VM boots with writable shares, agent-vm stops on each risk it
  cannot remove and asks whether to go on; Enter, or no terminal, aborts,
  and nothing has changed. The risks: a Lima that cannot keep `.git`
  read-only (on Windows, where the shares are then `reverse-sshfs`, the
  rest of the disk is at stake, and the box says so); hooks that cannot be
  protected, or a name declined; a git config file included from the
  project, there yet or not, or a setting (`core.fsmonitor`, a
  filter, a `!` alias...) whose command is a file in it; and
  `safe.bareRepository=explicit` missing from the global git config, which
  it offers to set, or ignored by a git older than 2.38. Without that
  setting, a folder holding `HEAD`, `objects/`, `refs/` and a `config` is a
  repository to git under any name, which `readonlyNames` does not cover,
  and git on the host runs the commands its `config` names (`core.pager` as
  soon as `git log` is typed there). A question is only asked when stderr is
  a terminal too, so a caller capturing it gets "no" rather than a question
  nobody sees. For a VM that already runs, the warnings are printed without
  a question; one that lacks a protection it should have is offered a
  restart, and continuing without it is the same kind of risk. A running VM
  that is stopped to boot again (new resources, a protection, a repair) is
  asked once stopped, as any VM about to boot. `--readonly` asks none of
  these questions, and `--unsafe-writable-git` none about `.git`.
  `--unsafe-disable-security-prompts`, or
  `AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1` in the shell, goes on without
  asking, and without offering to change the git config; the warnings are
  still printed.
- A Lima whose answer to the `readonlyNames` probe cannot be read (a failing
  `limactl validate`, a wording agent-vm does not know) stops the start with
  an error, rather than being taken for a Lima without `readonlyNames`,
  which would drop the protection of a stopped VM on its next start.
- The home directory and agent-vm's directories are refused as a project
  whatever the case they are typed in, on macOS and Windows: Git Bash keeps
  the spelling typed, so `cd /c/users/me` got past the check.
- `--readonly` is now set on the Lima shares, so the host refuses the writes
  and root in the VM cannot lift it. It used to be a remount inside the
  guest. Under `reverse-sshfs` without `readonlyNames`, where Lima only passes
  the flag to the guest, agent-vm refuses `--readonly` instead of pretending.
  Switching the mode of a running VM restarts it, asked first (no by
  default): declined, or with no terminal, the command fails, in both
  directions, so another session's `--readonly` VM is not made writable
  under it.
- `--readonly` is refused on virtiofs under QEMU, where Lima's virtiofsd has no
  read-only mode and the flag only reaches the guest. It was accepted there as
  enforced on the host. 9p, QEMU's default, and virtiofs on `vz` are enforced.
- `--readonly` covers every share, `rw` entries of `~/.agent-vm/volumes`
  included. Read-only is enforced per share, so a writable volume containing
  the project was a second way to write it.
- `agent-vm env get/has` read the file instead of sourcing it, as the new
  `project-env get/has` do: the project env file sits in a directory the VM
  can write to. Values that need a shell to be interpreted are refused with
  exit status 2, and so is every key once one line is: after an open quote,
  a trailing backslash or a command, the shell reads the file differently
  than it looks, and could assign any key.
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

- For scripts and tools that run agent-vm without a terminal: a start can
  now stop on a security question (see Security above), with the reason on
  stderr and a failing status. `agent-vm info` says beforehand what it would
  stop on (`security_questions=`). Pass `--unsafe-disable-security-prompts`,
  or set `AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1`, once the user has
  agreed; or use `--readonly`.
- `agent-vm.sh` loads the rest of agent-vm from `lib/`, next to it, and stops
  with the name of the missing file when it is not there: a copy of
  `agent-vm.sh` on its own no longer works. Clones, the curl installer and
  release tarballs have it.
- Sourced by zsh (the `~/.zshrc` line of the 0.1.0 installer), `agent-vm.sh`
  only defines an `agent-vm` function that runs it with bash, like the
  command on `PATH`: agent-vm no longer runs inside zsh, with its semantics
  and your options. Its internal `_agent_vm_*` functions are no longer
  defined there. Sourcing it from bash is unchanged.
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
- `setup` opens on the wizard, agents first, and runs its security check
  (`.git` protection) last, before creating the VM. Its warnings are
  shorter, in a box fitted to the terminal, with the question right below.

### Added

- `--scratch`: a new VM with nothing of yours mounted, neither the project
  nor `~/.agent-vm/volumes`, deleted when the command ends, Ctrl-C included.
  On a terminal the deletion is asked first, yes by default: no opens a
  shell in the VM, to look at what the command left, and leaving it asks
  again. It has a name of its own (`agent-vm-<folder>-scratch-<random>`), so the
  folder's VM is left alone and several can run at once. The project's env
  file and runtime script stay out; `~/.agent-vm/env` and
  `~/.agent-vm/runtime.sh` go in. Sharing nothing, it asks none of the
  security questions and works on any Lima. A run killed outright leaves its
  VM recorded, and the next `--scratch` run deletes it; `doctor` lists it
  meanwhile.
- `agent-vm env set KEY` and `project-env set KEY` without a value read it
  from stdin, or have you type it unseen: a value on the command line lands
  in the shell history and in `ps`.
- `info` prints `git_protected=` (whether a start keeps `.git` read-only)
  and `security_questions=` (what a start would stop on: `lima`,
  `lima-unknown`, `hooks`, `git-config`, `bare-repo`, or `none`).
- Windows, experimental, from Git Bash, with QEMU. `setup` offers to
  download a Lima build for Windows that keeps `.git` read-only (checked
  against checksums pinned in agent-vm, not the release's `SHA256SUMS`, and
  replaced when agent-vm moves to a newer one),
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
  (`~/.cache/pip:/home/you.guest/.cache/pip:rw:~/work/*`). An entry that
  does not read that way (an empty project, a project without a mode before
  it, a mode after it, more fields, a control character) is skipped with a
  warning rather than mounted in every project. Based on #30 by Manuel
  Raynaud.
- A relative destination in `~/.agent-vm/volumes` is inside the project
  (`~/.claude-vm/webapp:.claude:ro:~/work/webapp`). The mount point is created in
  the project on the host when missing. One that leaves the project with `..`
  or goes through a symlink in it is skipped. It used to reach Lima as is,
  which refuses a relative mount point.
- `--ssh-port N` gives a VM a fixed host port for SSH, for IDEs and GUI agents
  that save the port rather than an alias (#28). `0` goes back to a new port on
  each start. A port another agent-vm VM has is refused. `info` gains
  `ssh_host` and `ssh_config`: Lima's alias for the VM and the SSH config file
  it keeps current. [The website](https://www.agent-vm.org/#connect-an-ide-over-ssh)
  has the `~/.ssh/config` lines to use them, which keep the host's SSH agent out
  of the VM.
- `curl -fsSL https://www.agent-vm.org/install.sh | sh` installs the latest
  release, checked against its `SHA256SUMS`, in `~/.local/share/agent-vm`, and
  runs `agent-vm install`. Running it again updates. `--version X.Y.Z` picks a
  release, `--git` installs a clone instead. `version --min` now names the
  update command that fits the install: `git pull`, `brew upgrade` or the
  installer, with `--dir` when it is not in the installer's default place.
- `agent-vm install` and `agent-vm uninstall` replace `install.sh`, which
  stays for now as a wrapper (`--uninstall` included). `uninstall` works from
  anywhere, not only from the clone, and `install` refuses a dangling link in
  the way instead of failing on it. When the base VM is not built yet,
  `install` offers to run `setup` right away. It no longer adds
  `source agent-vm.sh` to a shell rc: the command on `PATH` works from every
  shell, fish included, and an rc line left by an earlier install is named
  as no longer needed.
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
  2026-09-28`): its agents and packages are that old.
- `list` adds a BASE column: the agent-vm version that built the base each
  VM was cloned from, and the day (`0.2.0 2026-09-28`). A base built before
  0.2.0 shows `0.1.0`. It marks the current directory's VM with `>`, as
  `status` did: `status` is now the same command.

### Fixed

- With zsh, two or more files in `~/.agent-vm/volumes` no longer break the
  VM's shares: a variable of the loop was printed into the mounts config
  (agent-vm now runs under bash, see Changed).
- `agent-vm run -i foo` (any command starting with `-`) runs it, instead of
  handing the option to `env` in the VM.
- Sourced into a shell with `noclobber` (`set -C`), agent-vm rewrites its
  files: `env set` failed, and the record of a VM's shares kept its old
  value.
- `env set KEY a b`, and `get`, `has`, `unset` or `list` with a word too
  many, are refused instead of keeping the first word.
- `list` fails, saying so, when Lima cannot be queried, instead of printing
  "(no VMs)".
- `info` and `name` refuse a directory whose name holds a control
  character: a newline added lines of its own to `info`'s output.
- `setup` only marks the base ready once it has stopped: Lima cannot clone a
  running instance, so every new project VM failed after a stop that did not
  take.
- `setup --disk`, `--memory` or `--cpus` without a value is one clear error,
  also under a caller's `set -u`.
- The base setup script no longer loses its own lines to a command reading
  standard input (a dpkg prompt, an npm install script): it reaches bash on
  stdin, so such a command read the rest of the script, which never ran.
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
- When an agent, a shell or `run` in the VM ends, the terminal's mouse
  tracking, focus reports, bracketed paste and keyboard modes are turned off.
  A program that did not restore them (a crash, a dropped connection) left
  the host shell typing escape sequences on every mouse move. The screen is
  not cleared.
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
- `--reset`, `rm` and `destroy-all` fail, naming the VM, when Lima still
  lists it after the delete. `--reset` used to carry on with the old VM and
  the shares it was given, and `rm` to report it destroyed.
- Behind a proxy, `sudo` in the VM keeps the proxy settings Lima copies from
  the host (`env_keep` in `/etc/sudoers.d/10-agent-vm-proxy`). Debian's sudo
  dropped them, so `setup` failed at its first `apt-get` (#25), and so did
  `sudo apt install` in the VMs. Rebuild the base with `setup`, then
  `--reset` the project VMs.
- The VM's zsh keeps its history in `~/.zsh_history`, across sessions and
  restarts (#20); a command typed with a leading space is left out. New
  bases only: `setup`, then `--reset`.
- `LIMA_HOME` is honoured when cleaning up an interrupted VM creation and in
  the log paths printed on a failed start.
- A runtime script with an option in its shebang (`#!/bin/bash -e`,
  `#!/usr/bin/env -S bash -e`) runs under bash, not zsh.

## 0.1.0

- `install.sh` puts `agent-vm` on the `PATH`, so other tools can call it.
- New commands for integrators: `version`, `name`, `info`, `env`.
- `mcp-chrome` and `mcp-playwright` in `--preinstall`.

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
- `setup` rejects `--reset` and `--readonly` instead of ignoring them.

### Added

- `agent-vm install` and `agent-vm uninstall` replace `install.sh`, which
  stays for now as a wrapper (`--uninstall` included). `uninstall` works from
  anywhere, not only from the clone, and `install` refuses a dangling link in
  the way instead of failing on it.
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

### Fixed

- VM names fall back to `sha256sum` when `shasum` is missing, and naming fails
  rather than dropping the hash (two projects with the same directory name
  would have shared one VM).
- `status` says "(no VMs)" when there are none.
- A new VM prints its resources once instead of twice.
- `destroy-all` no longer risks skipping VMs when `limactl` reads stdin.
- Prompts no longer print a `/dev/tty` error when there is no terminal.
- The VM's mise install uses `curl -f`, so an HTTP error fails setup instead of
  piping an error page into `sh`.

## 0.1.0

- `install.sh` puts `agent-vm` on the `PATH`, so other tools can call it.
- New commands for integrators: `version`, `name`, `info`, `env`.
- `mcp-chrome` and `mcp-playwright` in `--preinstall`.

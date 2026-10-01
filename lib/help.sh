# --- help ---------------------------------------------------------------------

_agent_vm_help() {
  cat << 'EOF'
Usage: agent-vm [options] <command> [args]

Commands:
  install            Put agent-vm on your PATH (a link in ~/.local/bin, or
                     AGENT_VM_BIN_DIR). Run it from the clone:
                     ./agent-vm.sh install
  uninstall          Remove that link. VMs and ~/.agent-vm are left alone.
  setup              Create the base VM template (run once)
  claude [args]      Run Claude Code in the VM for the current directory
  opencode [args]    Run OpenCode in the VM for the current directory
  codex [args]       Run Codex CLI in the VM for the current directory
  vibe [args]        Run Mistral Vibe in the VM for the current directory
  pi [args]          Run Pi in the VM for the current directory (opt-in at
                     setup: --preinstall=default,pi)
  shell, sh          Open a shell in the VM. Add -c "..." to run a one-shot
                     command via login zsh and exit.
  run <cmd> [args]   Run a command in the VM (no shell: for pipes/redirects
                     use 'shell -c "..."' instead; pass --tty for TUIs like
                     opencode, vibe, htop, etc.)
  stop [vm-name]     Stop the VM for the current directory, or the named one
  rm [vm-name]       Stop and delete the VM for the current directory, or the
                     named one. Pass a name from 'agent-vm list' to reach a VM
                     whose directory was renamed or deleted: its name is a
                     hash of the old path, so no 'cd' can name it any more.
  destroy-all        Stop and delete every agent-vm VM, the base template
                     included ('agent-vm setup' rebuilds it)
  list, status       List all agent-vm VMs, the current directory's marked
                     with >, with the agent-vm version and date of the base
                     each was cloned from
  doctor             Check the host, Lima, the base template and this
                     directory, and say how to fix what is wrong. Read-only.
  name [dir]         Print the VM name for a directory (default: cwd)
  info [dir]         Print machine-readable state as key=value lines
                     (version, template, state_dir, project_env, dir,
                     vm_name, base_exists, vm_exists, vm_running, vm_stale,
                     ssh_host, ssh_config, git_protected,
                     security_questions).
                     Use this from scripts instead of parsing the output
                     of the human-facing commands.
  env <sub> [args]   Read/write ~/.agent-vm/env, the secrets pushed into every
                     VM. Subcommands: set KEY [VALUE] (without VALUE, read
                     from stdin, or typed unseen: out of your shell history),
                     get KEY, has KEY (exit status only), unset KEY, list
                     (key names, never values).
                     Use this rather than editing the file: it is sourced by a
                     shell, so one bad quote costs every secret in it.
  project-env <sub>  Same subcommands, for THIS directory's project only. Its
                     values are pushed after the shared ones, so a key set in
                     both takes the project's value. Stored IN the project
                     (.agent-vm.env by default, AGENT_VM_PROJECT_ENV to put it
                     elsewhere): so it follows the project and dies with it.
                     Being in a repository, it is the wrong place for a secret:
                     `agent-vm env` is outside any. `set` warns, with the line
                     to run, when the file is not ignored by git. `info` prints
                     the path as project_env=.
  version            Print the agent-vm version
  version --min X.Y.Z
                     Check it: silent and 0 when this engine is at least
                     X.Y.Z, an actionable error and 1 when it is older
                     (2 when the call itself is wrong). For integrators.
  help               Show this help

VM options (for claude, opencode, codex, vibe, pi, shell, run), read before the
command or right after its name, never later: in 'agent-vm run docker run
--rm x', --rm belongs to docker.
  --disk GB          VM disk size
  --memory GB        VM memory
  --cpus N           Number of CPUs
                     Without them, a new VM has the base template's: 10, 3
                     and 1 unless 'setup' was given others.
                     Memory and CPUs are clamped to a share of the host (half
                     of it, with a notice) so the VM cannot starve the
                     machine it runs on.
                     AGENT_VM_HOST_SHARE overrides the divisor.
  --ssh-port N       Fixed host port for the VM's SSH, for tools that save the
                     port (default: a new one on each start; 0 goes back)
  --reset            Destroy and re-clone the VM from the base template
  --readonly         Make every host share read-only: the project and the
                     ~/.agent-vm/volumes entries, rw ones included. Enforced
                     on the host side, so root in the VM cannot lift it.
                     A running VM in the other mode is restarted, asked first
                     (no by default; declined or with no terminal, the
                     command fails). The resource options ask the same, and
                     declined, the VM keeps its settings.
  --unsafe-writable-git
                     Leave every .git writable, so the agent can commit (see
                     below). Also accepted as --unsafe-writable-git=1.
  --unsafe-disable-security-prompts
                     Go on where a start would stop to ask about a security
                     risk (below), without offering to change your git
                     config; the warnings are still printed. For scripts
                     with no terminal. Also
                     AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1 in your shell.
  --rm               Automatically destroy the VM after the command exits
  --scratch          A new VM with nothing of yours mounted (no project, no
                     volumes), deleted when the command ends, Ctrl-C included.
                     On a terminal, the deletion is asked first: no opens a
                     shell in the VM, and its exit asks again.
                     The project's env file and runtime script stay out;
                     ~/.agent-vm/env and runtime.sh go in. The folder's own
                     VM is left alone, and several can run at once.

Examples:
  agent-vm setup                             # Create base VM
  agent-vm claude                            # Run Claude in a VM
  agent-vm opencode                          # Run OpenCode in a VM
  agent-vm codex                             # Run Codex in a VM
  agent-vm vibe                              # Run Mistral Vibe in a VM
  agent-vm pi                                # Run Pi in a VM
  agent-vm --disk 50 --memory 16 --cpus 8 claude  # Custom resources
  agent-vm --reset claude                    # Fresh VM from base template
  agent-vm --rm claude                       # Destroy VM after Claude exits
  agent-vm --readonly shell                  # Nothing on the host is writable
  agent-vm --scratch claude                  # Nothing of yours mounted, then deleted
  agent-vm shell                             # Shell into the VM
  agent-vm sh -c "ls -la | grep config"      # One-shot command via login zsh
  agent-vm run npm install                   # Run a command in the VM
  agent-vm run --tty opencode -p "..."       # Run a TUI with PTY allocated
  agent-vm claude -p "fix lint errors"       # Pass args to claude
  agent-vm rm agent-vm-old-name-1a2b3c4d     # Delete a VM by name (see 'list')

VMs are persistent and unique per directory. Running "agent-vm shell" or
"agent-vm claude" in the same directory will reuse the same VM.

Every .git in the shared folders is read-only for the VMs when Lima supports
it (sshfs.readonlyNames, not merged upstream yet: 'agent-vm setup' offers a
Lima build that has it). Every .hg is too, and so is the folder of each
core.hooksPath in the project (.husky for husky). 'agent-vm doctor' says
where you stand.

Before a VM boots with writable shares, agent-vm stops on what it cannot
protect, and asks whether to go on (no by default, and when it cannot ask):
a Lima without readonlyNames, hooks at the top of the project, git config or
commands it names in files of the project, and git ignoring
safe.bareRepository=explicit (which it offers to set: git would otherwise use
a folder with HEAD, objects/ and refs/ as a repository, under any name). A
VM that already runs gets the warnings only, and a restart when it lacks a
protection; once stopped to boot again, it is asked like any other.
'agent-vm info' lists what a start would ask
(security_questions=).
--unsafe-writable-git, or AGENT_VM_UNSAFE_WRITABLE_GIT=1 in your shell, leaves
.git writable anyway, so the agent can commit in the project; a warning is
printed on every run. Changing it applies when the VM is next started.

Customization:
  ~/.agent-vm/env                   Shared env vars / tokens (dotenv-style;
                                    pushed into every VM, loaded in its shells)
  ~/.agent-vm/volumes               Extra host paths to mount in VMs, one per
                                    line, directories or files:
                                    source[:destination][:ro|rw[:project]]
                                    (ro by default; a relative destination is
                                    in the project; project, after an explicit
                                    mode, limits the entry to the projects it
                                    matches, * as wildcard)
  ~/.agent-vm/setup.sh              Per-user setup (runs under zsh during
                                    "agent-vm setup")
  <project>/.agent-vm.env           Per-project env (agent-vm project-env)
                                    Override the path with AGENT_VM_PROJECT_ENV
  ~/.agent-vm/runtime.sh            Per-user runtime (runs on every command
                                    that enters a VM)
  <project>/.agent-vm.runtime.sh    Per-project runtime (same, after the
                                    per-user one)
                                    Override the path with AGENT_VM_PROJECT_RUNTIME
                                    (relative to the project, or absolute).
                                    Runtimes run under the shell their shebang
                                    names (bash, sh; zsh otherwise).

More info: https://www.agent-vm.org/
EOF
}

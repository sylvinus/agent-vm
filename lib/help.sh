# --- help ---------------------------------------------------------------------

_agent_vm_help() {
  cat << 'EOF'
Usage: agent-vm [options] <command> [args]

Commands:
  install            Put agent-vm on your PATH (a link in ~/.local/bin, or
                     AGENT_VM_BIN_DIR) and offer to source it from your shell
                     rc. Run it from the clone: ./agent-vm.sh install
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
  run <cmd> [args]   Run a command in the VM (no shell — for pipes/redirects
                     use 'shell -c "..."' instead; pass --tty for TUIs like
                     opencode, vibe, htop, etc.)
  stop [vm-name]     Stop the VM for the current directory, or the named one
  rm [vm-name]       Stop and delete the VM for the current directory, or the
                     named one. Pass a name from 'agent-vm list' to reach a VM
                     whose directory was renamed or deleted: its name is a
                     hash of the old path, so no 'cd' can name it any more.
  destroy-all        Stop and delete every agent-vm VM, the base template
                     included ('agent-vm setup' rebuilds it)
  list               List all agent-vm VMs
  status             Show status of all VMs (current dir marked with >)
  doctor             Check the host, Lima, the base template and this
                     directory, and say how to fix what is wrong. Read-only.
  name [dir]         Print the VM name for a directory (default: cwd)
  info [dir]         Print machine-readable state as key=value lines
                     (version, template, state_dir, dir, vm_name,
                     base_exists, vm_exists, vm_running, vm_stale).
                     Use this from scripts instead of parsing the output
                     of the human-facing commands.
  env <sub> [args]   Read/write ~/.agent-vm/env, the secrets pushed into every
                     VM. Subcommands: set KEY VALUE, get KEY, has KEY (exit
                     status only), unset KEY, list (key names, never values).
                     Use this rather than editing the file: it is sourced by a
                     shell, so one bad quote costs every secret in it.
  project-env <sub>  Same subcommands, for THIS directory's project only. Its
                     values are pushed after the shared ones, so a key set in
                     both takes the project's value. Stored IN the project
                     (.agent-vm.env by default, AGENT_VM_PROJECT_ENV to put it
                     elsewhere) — so it follows the project and dies with it.
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
  --disk GB          VM disk size (default: 10)
  --memory GB        VM memory (default: 3)
  --cpus N           Number of CPUs (default: 1)
                     Both are clamped to a share of the host (half of it, with
                     a notice) so the VM cannot starve the machine it runs on.
                     AGENT_VM_HOST_SHARE overrides the divisor.
  --ssh-port N       Fixed host port for the VM's SSH, for tools that save the
                     port (default: a new one on each start; 0 goes back)
  --reset            Destroy and re-clone the VM from the base template
  --readonly         Make every host share read-only: the project and the
                     ~/.agent-vm/volumes entries, rw ones included. Enforced
                     on the host side, so root in the VM cannot lift it.
                     Changing the mode restarts the VM.
  --unsafe-writable-git
                     Leave every .git writable, so the agent can commit (see
                     below). Also accepted as --unsafe-writable-git=1.
  --rm               Automatically destroy the VM after the command exits

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
Lima build that has it). Otherwise a VM can write .git/config and hooks, which
git on this machine runs. 'agent-vm doctor' says which case you are in.
--unsafe-writable-git, or AGENT_VM_UNSAFE_WRITABLE_GIT=1 in your shell, leaves
.git writable anyway, so the agent can commit in the project; a warning is
printed on every run. Changing it applies when the VM is next started.
A folder with HEAD, objects/ and refs/ is a repository to git under any name:
'setup' asks to set safe.bareRepository=explicit so git ignores those.

Customization:
  ~/.agent-vm/env                   Shared env vars / tokens (dotenv-style;
                                     auto-loaded into every VM shell)
  ~/.agent-vm/volumes               Extra host paths to mount in VMs (one per
                                     line, supports both directories and files)
  ~/.agent-vm/setup.sh              Per-user setup (runs during "agent-vm setup")
  ~/.agent-vm/env                   Shared env pushed into every VM
  <project>/.agent-vm.env           Per-project env (agent-vm project-env)
                                    Override the path with AGENT_VM_PROJECT_ENV
  ~/.agent-vm/runtime.sh            Per-user runtime (runs on each VM start)
  <project>/.agent-vm.runtime.sh    Per-project runtime (runs on each VM start)
                                    Override the path with AGENT_VM_PROJECT_RUNTIME
                                    (relative to the project, or absolute).
                                    Runtimes run under the shell their shebang
                                    names (bash, sh; zsh otherwise).

More info: https://www.agent-vm.org/
EOF
}

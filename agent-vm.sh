#!/usr/bin/env bash
#
# agent-vm: Run AI coding agents inside sandboxed Lima VMs
# Part of https://www.agent-vm.org/
#
# Put it on your PATH with `./agent-vm.sh install`. It can also be sourced
# from bash or zsh, which defines agent-vm as a shell function.
#
# Usage:
#   agent-vm setup    - Create the base VM template (run once)
#   agent-vm claude   - Run Claude Code in a persistent VM for cwd
#   agent-vm opencode - Run OpenCode in a persistent VM for cwd
#   agent-vm codex    - Run Codex CLI in a persistent VM for cwd
#   agent-vm vibe     - Run Mistral Vibe in a persistent VM for cwd
#   agent-vm pi       - Run Pi in a persistent VM for cwd
#   agent-vm shell    - Open a shell in the persistent VM for cwd
#                       (alias: 'sh'; add -c "..." for a one-shot command)
#   agent-vm stop     - Stop the VM for cwd
#   agent-vm rm       - Stop and delete the VM for cwd
#   agent-vm list     - List all agent-vm VMs
#   agent-vm status   - Show status of all VMs (current dir marked with >)
#   agent-vm doctor   - Check the host, Lima, the base and this directory
#   agent-vm name     - Print the VM name for cwd
#   agent-vm info     - Print machine-readable state (key=value)
#   agent-vm version  - Print the agent-vm version
#   agent-vm help     - Show help
#

# Semantic version of this file. Bumped by hand on release. Integrators gate on
# it via `agent-vm version`; a build with no `version` command predates it.
AGENT_VM_VERSION="0.2.0"

AGENT_VM_TEMPLATE="agent-vm-base"
# Overridable so a test, a CI job or a second install can keep its own state
# without moving HOME — moving HOME also moves Lima's own state, which makes a
# sandboxed run rebuild every VM. Integrators must not rebuild this path from
# $HOME: `agent-vm info` publishes it as state_dir=.
AGENT_VM_STATE_DIR="${AGENT_VM_STATE_DIR:-${HOME}/.agent-vm}"

# Directory holding the real agent-vm.sh, symlinks followed.
#
# `agent-vm install` puts a symlink on PATH (~/.local/bin/agent-vm -> <repo>/agent-vm.sh)
# so `agent-vm` works as an ordinary command. Without resolving the link, this
# would point at ~/.local/bin, where neither lib/ nor agent-vm.setup.sh is.
#
# `readlink -f` would do it in one call but is GNU-only — macOS ships a readlink
# without it — so walk the chain by hand.
#
# `CDPATH=` because `dirname` can yield a bare relative path (running
# `bash sub/agent-vm.sh`). With CDPATH set, `cd <relative>` searches it before
# the current directory and prints where it landed, so without clearing it this
# would resolve the wrong directory and capture a stray line.
_agent_vm_script_dir() {
  local src="$1" dir
  while [ -L "$src" ]; do
    dir="$(CDPATH= cd -P -- "$(dirname "$src")" >/dev/null && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;                  # absolute: use as-is
      *) src="$dir/$src" ;;   # relative: to the link's directory
    esac
  done
  (CDPATH= cd -P -- "$(dirname "$src")" >/dev/null && pwd)
}
# The path of this file, read here at the top level and not in the function:
# in a zsh function, $0 is the function's name, so lib/ was looked up in the
# current directory, and a lib/ui.sh planted there ran on the host. zsh has no
# BASH_SOURCE; its %x prompt escape is the file being sourced. The eval keeps
# bash from parsing zsh syntax.
if [[ -n "${ZSH_VERSION:-}" ]]; then
  eval '_agent_vm_src="${(%):-%x}"'
else
  _agent_vm_src="${BASH_SOURCE[0]:-$0}"
fi
AGENT_VM_SCRIPT_DIR="$(_agent_vm_script_dir "$_agent_vm_src")"
unset _agent_vm_src
if [[ -z "$AGENT_VM_SCRIPT_DIR" ]]; then
  echo "agent-vm: cannot find the directory of agent-vm.sh" >&2
  return 1 2>/dev/null || exit 1
fi

# The rest of agent-vm, one file per concern, sourced like this one. Only
# functions and settings: nothing runs until a command does. A file that is
# missing stops here, not half-way through a command.
for _agent_vm_lib in ui options host vm mounts git runtime env info install doctor help setup; do
  _agent_vm_lib="$AGENT_VM_SCRIPT_DIR/lib/$_agent_vm_lib.sh"
  if [[ ! -r "$_agent_vm_lib" ]] || ! . "$_agent_vm_lib"; then
    echo "agent-vm: cannot load $_agent_vm_lib" >&2
    unset _agent_vm_lib
    return 1 2>/dev/null || exit 1
  fi
done
unset _agent_vm_lib

# --- starting a project's VM --------------------------------------------------

# Ensure the VM for cwd exists and is running, creating/starting as needed
# Usage: _agent_vm_ensure_running <vm_name> <host_dir> [vm_opts...], the options
# as _agent_vm_take_opt collects them (checked already).
_agent_vm_ensure_running() {
  local vm_name="$1"
  local host_dir="$2"
  shift 2
  local disk="" memory="" cpus="" ssh_port="" reset="" rdonly="" scratch="" _agent_vm_unsafe_git_flag="" _agent_vm_unsafe_no_prompts=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)     disk="$2"; shift 2 ;;
      --memory)   memory="$2"; shift 2 ;;
      --cpus)     cpus="$2"; shift 2 ;;
      --ssh-port) ssh_port="$2"; shift 2 ;;
      --reset)    reset=1; shift ;;
      --readonly) rdonly=1; shift ;;
      --scratch)  scratch=1; shift ;;
      --unsafe-writable-git) _agent_vm_unsafe_git_flag=1; shift ;;
      --unsafe-disable-security-prompts) _agent_vm_unsafe_no_prompts=1; shift ;;
      *)          shift ;;
    esac
  done

  # --scratch (see _agent_vm_run_scratch): a new VM with no share at all, so
  # nothing to reset or make read-only, and none of the checks below that
  # are about a share apply.
  if [[ -n "$scratch" && ( -n "$reset" || -n "$rdonly" ) ]]; then
    echo "Error: --scratch makes a new VM that shares nothing: --reset and --readonly do not go with it." >&2
    return 1
  fi

  # The project mount's mode is decided once, here, so the create path bakes it
  # into the new VM's config instead of creating it writable and immediately
  # restarting it to flip the flag.
  local want_writable="true"
  [[ -n "$rdonly" ]] && want_writable="false"

  # Clamp to this host's share once, here: every path below (create, edit,
  # resource comparison) then sees the values that will actually be applied.
  cpus="$(_agent_vm_cap_resource cpus "$cpus")"
  memory="$(_agent_vm_cap_resource memory "$memory")"
  _agent_vm_warn_disk_space "$disk"

  # Two VMs set to one port: the second would fail to start.
  if [[ -n "$ssh_port" && "$ssh_port" != 0 ]]; then
    local other
    other="$(limactl list --format '{{.Name}} {{.Config.SSH.LocalPort}}' 2>/dev/null \
      | awk -v vm="$vm_name" -v p="$ssh_port" '$1 != vm && $2 == p { print $1; exit }')"
    if [[ -n "$other" ]]; then
      echo "Error: SSH port $ssh_port is already set for VM '$other'." >&2
      return 1
    fi
  fi

  # `cd ~ && agent-vm shell` would hand the VM your dotfiles and SSH keys,
  # read-write, and a share holding agent-vm's own files lets the VM change
  # what the host runs next.
  local unsafe
  if [[ -z "$scratch" ]] && unsafe="$(_agent_vm_unsafe_project "$host_dir")"; then
    echo "Error: refusing to share $host_dir with a VM: it is, or contains, $unsafe." >&2
    echo "Run agent-vm from a project directory." >&2
    return 1
  fi

  # Lima's host mount cannot share a path containing whitespace: the mount
  # fails silently and the VM starts with a bare, root-owned mountpoint, so
  # every write into the project (e.g. creating .claude) fails with
  # "Permission denied". Fail fast with an actionable message instead.
  if [[ -z "$scratch" && "$host_dir" == *[[:space:]]* ]]; then
    echo "Error: project path contains whitespace, which Lima cannot mount:" >&2
    echo "  $host_dir" >&2
    echo "Rename the directory to remove spaces (e.g. with '-'), then retry." >&2
    return 1
  fi

  # The path is spliced into the mounts JSON handed to `limactl edit --set`,
  # which is a yq expression. A quote or a backslash in a directory name would
  # end the string and let the name add mounts of its own (the home directory,
  # read-write) or undo --readonly. Same rule as ~/.agent-vm/volumes entries.
  if [[ "$host_dir" == *[\"\\]* || "$host_dir" == *[[:cntrl:]]* ]]; then
    echo "Error: project path contains a quote, a backslash or a control character:" >&2
    echo "  $host_dir" >&2
    echo "Rename the directory, then retry." >&2
    return 1
  fi

  # Recover from an interrupted previous run that left ~/.lima/<vm>/ without
  # a lima.yaml — otherwise every limactl call on this name aborts with a
  # cryptic "no such file or directory".
  _agent_vm_clean_partial_state "$vm_name"

  if ! _agent_vm_base_exists; then
    # Distinguish "never set up" from "setup died halfway": the second one
    # leaves a template that looks fine in `limactl list` but is empty.
    if _agent_vm_exists "$AGENT_VM_TEMPLATE"; then
      echo "Error: Base VM setup did not complete. Run 'agent-vm setup' again." >&2
    else
      echo "Error: Base VM not found. Run 'agent-vm setup' first." >&2
    fi
    return 1
  fi

  # The security checks, before anything changes. A risk agent-vm cannot
  # remove stops the start unless the user says to go on (see
  # _agent_vm_confirm_unsafe). Asked only for a VM about to boot: for one that
  # already runs, stopping here would protect nothing, so the warning alone is
  # printed (a running VM that lacks a protection is offered a restart further
  # down).
  local vm_up=""
  [[ -z "$reset" ]] && _agent_vm_running "$vm_name" && vm_up=1

  # Every .git read-only for the guest, when this Lima can enforce it and it
  # was not turned off. Asked once here: the mounts built below, on every
  # path, follow the answer. A Lima that cannot, with shares left writable
  # and nobody having asked for a writable .git, is a risk to accept. One
  # whose answer could not be read stops the start: taking it for a no would
  # drop the protection of the VM.
  local protect_git="" lima_st=0
  if [[ -n "$scratch" ]]; then
    :
  elif _agent_vm_writable_git_optout; then
    _agent_vm_writable_git_warning >&2
  else
    _agent_vm_lima_protects_git || lima_st=$?
    if [[ "$lima_st" == 0 ]]; then
      protect_git=1
    elif [[ -n "$rdonly" ]]; then
      :
    elif [[ "$lima_st" == 2 ]]; then
      echo "Error: cannot tell whether this Lima keeps .git read-only: 'limactl validate' gave no answer agent-vm knows ('agent-vm doctor' shows more)." >&2
      echo "  --readonly, or --unsafe-writable-git to accept a writable .git, still starts the VM." >&2
      return 1
    elif [[ -n "$vm_up" ]]; then
      echo "Warning: this Lima cannot keep .git read-only, so the VM can write .git ('agent-vm doctor' says more)." >&2
    else
      _agent_vm_git_protection_hint | _agent_vm_box "Lima cannot keep .git read-only"
      if ! _agent_vm_confirm_unsafe; then
        echo "Aborted. Install that Lima build, or use --readonly; --unsafe-writable-git accepts a writable .git." >&2
        return 1
      fi
    fi
  fi

  # With it, the names the shares need: those always listed, and one per
  # hooks folder git runs from in the project (see _agent_vm_project_hooks),
  # its first component. A dot-name (.husky, .githooks) is taken as is; any
  # other is read-only in every folder of the project, so it is asked first
  # (yes by default, and when no one can answer). A folder that cannot be
  # protected, or one declined, is a risk to accept. So are git config files
  # in the project, and settings running commands from it. Under --readonly
  # the VM writes none of them: the names are taken as they come, with no
  # warning and no question.
  local ro_names="" hooks_rel hooks_in hooks_name hooks_names=() hooks_notes=""
  if [[ -n "$protect_git" ]]; then
    while IFS=$'\t' read -r hooks_rel hooks_in; do
      [[ -n "$hooks_rel" ]] || continue
      if [[ -n "$rdonly" ]]; then
        hooks_name="$(_agent_vm_hooks_name "$hooks_in")" && hooks_names+=("$hooks_name")
        continue
      fi
      if ! hooks_name="$(_agent_vm_hooks_name "$hooks_in")"; then
        if [[ "$hooks_rel" == . ]]; then
          echo "Warning: git's core.hooksPath is the project directory itself, which the VM can write: git on this machine runs the hooks the agent puts there." >&2
        else
          echo "Warning: git's core.hooksPath is '$hooks_rel', in the project, and its name cannot be made read-only: git on this machine runs the hooks the agent puts there." >&2
        fi
        if [[ -z "$vm_up" ]] && ! _agent_vm_confirm_unsafe; then
          echo "Aborted. Point core.hooksPath to a folder of the project (agent-vm keeps it read-only), or outside it." >&2
          return 1
        fi
        continue
      fi
      if [[ "$hooks_name" != .* && -z "$vm_up" ]] && ! _agent_vm_prompts_disabled_by >/dev/null \
         && _agent_vm_can_ask \
         && [[ "$(_agent_vm_ask_yn "Git runs hooks from $hooks_rel. Make every '$hooks_name' folder in the project read-only for the VM?" Y)" != "1" ]]; then
        echo "Warning: '$hooks_name' stays writable, and git on this machine runs the hooks the agent puts in $hooks_rel." >&2
        if ! _agent_vm_confirm_unsafe; then
          echo "Aborted. Answer yes to protect it, or point core.hooksPath outside the project." >&2
          return 1
        fi
        continue
      fi
      hooks_names+=("$hooks_name")
      hooks_notes="$hooks_notes$(_agent_vm_hooks_note "$hooks_rel" "$hooks_name")"$'\n'
    done <<< "$(_agent_vm_project_hooks "$host_dir")"
    ro_names="$(_agent_vm_names_json ${hooks_names[@]+"${hooks_names[@]}"})"

    local git_risks=""
    [[ -n "$rdonly" ]] || git_risks="$(_agent_vm_project_config_risks "$host_dir")"
    if [[ -n "$git_risks" ]]; then
      echo "Warning: git on this machine uses these, and the VM can write them:" >&2
      printf '%s\n' "$git_risks" | sed 's/^/  /' >&2
      if [[ -z "$vm_up" ]] && ! _agent_vm_confirm_unsafe; then
        echo "Aborted. Move them out of the project, or have them name commands outside it." >&2
        return 1
      fi
    fi
  fi
  # A repository not named .git, which no name protects (see
  # _agent_vm_bare_repo_state): only a VM that can write needs the setting.
  if [[ -z "$rdonly" && -z "$scratch" ]]; then
    _agent_vm_check_bare_repo_setting "$vm_up" || return 1
  fi

  # Destroy existing VM if --reset was requested
  if [[ -n "$reset" ]] && _agent_vm_exists "$vm_name"; then
    echo "Resetting VM '$vm_name'..."
    _agent_vm_delete_vm "$vm_name" || return 1
  fi

  local is_new_vm="" apply_resize=""
  local file_mount_entries=()
  local file_mounts_cache="$AGENT_VM_STATE_DIR/.agent-vm-file-mounts-${vm_name}"

  if ! _agent_vm_exists "$vm_name"; then
    is_new_vm=1
    echo "Creating VM '$vm_name'..."
    local create_out
    if ! create_out=$(limactl clone "$AGENT_VM_TEMPLATE" "$vm_name" --tty=false 2>&1); then
      echo "Error: could not clone the base template into '$vm_name':" >&2
      echo "$create_out" >&2
      return 1
    fi
    # Apply mount and resource settings via edit after clone
    # Mount and memory/cpus are applied separately from disk, because
    # Lima rejects the entire edit if disk shrinking is attempted.
    local mounts_json="[]"
    [[ -n "$scratch" ]] \
      || mounts_json=$(_agent_vm_build_mounts_json "$vm_name" "$host_dir" "$want_writable" "${protect_git:+$ro_names}")
    local edit_args=()
    edit_args+=(--set "$(_agent_vm_mounts_expr "$mounts_json" "$protect_git")")
    [[ -n "$memory" ]] && edit_args+=(--memory "$memory")
    [[ -n "$cpus" ]]   && edit_args+=(--cpus "$cpus")
    [[ -n "$ssh_port" ]] && edit_args+=(--set ".ssh.localPort = $ssh_port")
    # A failure here used to be silent, and the VM went on with the template's
    # config: no ~/.agent-vm/volumes entries, no --memory, --cpus or
    # --ssh-port (#21). The clone is new and holds nothing yet, so it goes, and
    # the next run starts over.
    if ! create_out=$(cd /tmp && limactl edit "$vm_name" ${edit_args[@]+"${edit_args[@]}"} 2>&1); then
      echo "Error: could not configure the new VM '$vm_name' (shares, memory, CPUs):" >&2
      echo "$create_out" >&2
      _agent_vm_delete_vm "$vm_name"
      return 1
    fi
    _agent_vm_record_mounts "$vm_name" "$mounts_json"
    printf '%s' "$hooks_notes"
    if [[ -n "$disk" ]]; then
      if ! create_out=$(cd /tmp && limactl edit "$vm_name" --disk "$disk" 2>&1); then
        echo "Warning: Cannot set disk to ${disk} GiB (it can grow, not shrink: 'agent-vm setup --disk ${disk}' for a smaller base):" >&2
        echo "$create_out" >&2
      fi
    fi
    # Resources are printed by the caller, once the VM is up.
    # Record which base version this VM was cloned from
    local base_ver="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
    if [[ -f "$base_ver" ]]; then
      cp "$base_ver" "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
    fi
  elif { [[ -n "$disk" || -n "$memory" || -n "$cpus" ]] \
         && _agent_vm_resources_differ "$vm_name" "$cpus" "$memory" "$disk"; } \
       || _agent_vm_ssh_port_differs "$vm_name" "$ssh_port"; then
    # Resize the existing VM, but only when the request actually differs from
    # what the VM already has. Prompting on the mere *presence* of a resource
    # flag means every caller that passes its defaults on each invocation gets
    # "Stop the VM and apply changes?" forever, for a no-op.
    #
    # Declining keeps the current settings and goes on: everything below
    # (--readonly, the .git shares, env, runtime scripts) still applies.
    apply_resize=1
    if _agent_vm_running "$vm_name"; then
      echo "VM '$vm_name' is currently running. It must be stopped to apply new settings."
      if _agent_vm_can_ask && [[ "$(_agent_vm_ask_yn "Stop the VM and apply changes?" N)" == "1" ]]; then
        echo "Stopping VM..."
        if ! _agent_vm_stop_vm "$vm_name"; then
          echo "Error: could not stop VM '$vm_name'; its settings are unchanged." >&2
          return 1
        fi
      else
        echo "Not applied: the VM keeps its current settings."
        apply_resize=""
      fi
    fi
  fi
  if [[ -n "$apply_resize" ]]; then
    echo "Updating VM settings..."
    # Don't touch .mounts here — those are baked in at creation (including any
    # entries from ~/.agent-vm/volumes). Re-setting them would clobber extras.
    local edit_args=() edit_output=""
    [[ -n "$memory" ]] && edit_args+=(--memory "$memory")
    [[ -n "$cpus" ]]   && edit_args+=(--cpus "$cpus")
    [[ -n "$ssh_port" ]] && edit_args+=(--set ".ssh.localPort = $ssh_port")
    # Only call limactl when there is something to set: `limactl edit <vm>` with
    # no flags drops into $EDITOR, which would hang a non-interactive caller
    # that passed --disk on its own.
    if [[ ${#edit_args[@]} -gt 0 ]]; then
      if ! edit_output=$(cd /tmp && limactl edit "$vm_name" "${edit_args[@]}" 2>&1); then
        echo "Error: Failed to update VM settings:" >&2
        echo "$edit_output" >&2
        return 1
      fi
    fi
    if [[ -n "$disk" ]]; then
      if ! edit_output=$(cd /tmp && limactl edit "$vm_name" --disk "$disk" 2>&1); then
        echo "Warning: Cannot set disk to ${disk} GiB (shrinking is not supported). Re-run 'agent-vm setup --disk ${disk}' for a smaller base." >&2
      fi
    fi
  fi

  # Warn if this VM was cloned from an older base. `agent-vm info` exposes the
  # same verdict as vm_stale= so integrators can ask before starting instead of
  # reading this warning after the fact.
  if [[ "$(_agent_vm_stale_state "$vm_name")" == "1" ]]; then
    echo "Warning: Base VM has been updated since this VM was cloned. Use --reset to re-clone from the new base." >&2
  fi

  # Whether someone else was already using this VM, captured BEFORE we start it.
  # Asking the question after the `limactl start` below would always answer
  # "yes", since we would be the ones who started it.
  local was_running=""
  _agent_vm_running "$vm_name" && was_running=1

  # A VM whose shares were set up for another Lima or another opt-out setting:
  # .git writable while it should be protected, or reverse-sshfs while it
  # should not (see _agent_vm_mounts_expr). Or set up for another mode than
  # the one asked: --readonly on a VM that last ran writable (or has no
  # record), or the reverse. The shares only change on a stopped VM, so before
  # starting it: booting it with the old shares first would give whatever
  # starts with the VM (a service, a job of the agent's) a writable window. A
  # running one keeps what it has until it stops; for the mode, the reconcile
  # step after the start asks to restart it.
  # Or protected, with other names than the ones asked: from before .hg, or
  # before core.hooksPath changed.
  local was_protected="" git_stale="" names_stale="" mode_stale=""
  _agent_vm_mounts_protect_git "$vm_name" && was_protected=1
  [[ "$was_protected" != "$protect_git" ]] && git_stale=1
  if [[ -n "$protect_git" && -n "$was_protected" ]] \
     && ! _agent_vm_mounts_have_readonly_names "$vm_name" "$ro_names"; then
    names_stale=1
  fi
  if [[ -n "$scratch" ]]; then
    # Shares nothing, as made: nothing to bring in line.
    git_stale=""
  elif [[ "$want_writable" == "false" ]]; then
    _agent_vm_mounts_all_readonly "$vm_name" || mode_stale=1
  elif _agent_vm_mounts_all_readonly "$vm_name"; then
    mode_stale=1
  fi
  # A running VM that lacks a protection it should have lets the agent go on
  # writing what it covers: a restart applies it, which cuts whatever else uses
  # the VM, so it is asked. Declined, or with no one to ask, it is a risk to
  # accept (see _agent_vm_confirm_unsafe). Not under --readonly: a read-only
  # VM writes nothing, and a writable one is restarted below to apply it.
  if [[ -z "$rdonly" && -n "$was_running" && -n "$protect_git" && ( -n "$git_stale" || -n "$names_stale" ) ]]; then
    if [[ -n "$git_stale" ]]; then
      echo "Warning: VM '$vm_name' is running with .git writable, so the agent can still write .git." >&2
    else
      echo "Warning: VM '$vm_name' runs with an older list of read-only names (it needs $(_agent_vm_names_text "$ro_names")), so the agent can still write the new ones." >&2
    fi
    if ! _agent_vm_prompts_disabled_by >/dev/null && _agent_vm_can_ask \
       && [[ "$(_agent_vm_ask_yn "Restart it now to apply them? Sessions using it are cut." Y)" == "1" ]]; then
      if ! _agent_vm_stop_vm "$vm_name"; then
        echo "Error: could not stop VM '$vm_name'; its shares are unchanged." >&2
        return 1
      fi
      was_running=""
    elif ! _agent_vm_confirm_unsafe; then
      echo "Aborted. 'agent-vm stop', then run again." >&2
      return 1
    fi
  fi
  if [[ -n "$git_stale" && -n "$was_running" ]]; then
    if [[ -n "$protect_git" ]]; then
      :
    elif _agent_vm_writable_git_optout; then
      echo "Note: VM '$vm_name' keeps .git read-only until it stops." >&2
    else
      echo "Warning: this Lima cannot keep .git read-only; VM '$vm_name' keeps its current shares until it stops." >&2
    fi
  elif [[ -n "$names_stale" && -n "$was_running" ]]; then
    :
  elif [[ -z "$was_running" && ( -n "$git_stale" || -n "$names_stale" || -n "$mode_stale" ) ]]; then
    # Names of their own: zsh prints a local declared twice in one function.
    local shares_json shares_out
    if [[ -n "$git_stale" ]]; then
      if [[ -n "$protect_git" ]]; then
        echo "Making every .git read-only for VM '$vm_name'..."
      elif _agent_vm_writable_git_optout; then
        echo "Making .git writable for VM '$vm_name' ($(_agent_vm_writable_git_why))..." >&2
      else
        echo "Warning: this Lima cannot keep .git read-only; VM '$vm_name' goes back to Lima's default mount type." >&2
      fi
    elif [[ -n "$names_stale" ]]; then
      echo "Making $(_agent_vm_names_text "$ro_names") read-only for VM '$vm_name'..."
    fi
    [[ -n "$git_stale" || -n "$names_stale" ]] && printf '%s' "$hooks_notes"
    if [[ -n "$mode_stale" && "$want_writable" == "false" ]]; then
      echo "Making every share of VM '$vm_name' read-only..."
    elif [[ -n "$mode_stale" ]]; then
      echo "VM '$vm_name' was left read-only by --readonly; making it writable again..."
    fi
    shares_json=$(_agent_vm_build_mounts_json "$vm_name" "$host_dir" "$want_writable" "${protect_git:+$ro_names}")
    if ! shares_out=$(cd /tmp && limactl edit "$vm_name" \
      --set "$(_agent_vm_mounts_expr "$shares_json" "$protect_git")" 2>&1); then
      echo "Error: could not change the shares of '$vm_name':" >&2
      echo "$shares_out" >&2
      return 1
    fi
    _agent_vm_record_mounts "$vm_name" "$shares_json"
  fi

  if [[ -z "$was_running" ]]; then
    echo "Starting VM '$vm_name'..."
    local start_log
    if ! start_log=$(limactl start "$vm_name" 2>&1); then
      local ha_log
      ha_log="$(_agent_vm_lima_home)/$vm_name/ha.stderr.log"
      echo "Error: Failed to start VM '$vm_name'." >&2
      echo "--- limactl start output ---" >&2
      echo "$start_log" >&2
      echo "Full log: $ha_log" >&2
      _agent_vm_windows_start_hint "$ha_log"
      return 1
    fi
  fi

  # Reconcile the project mount with the mode that was asked for. This is one
  # step and not two because the two directions share a mechanism: the mount
  # mode lives in the Lima config, so changing it means stop, edit, start.
  #
  #   want writable, is not  -> a stale or silently-failed mount. Left alone it
  #                             leaves a bare, root-owned mountpoint and every
  #                             later write fails with a cascade of "Permission
  #                             denied" instead of one clear error. Self-heal.
  #   want read-only, is not -> --readonly was passed. Re-mount it read-only on
  #                             the host side, where the guest cannot undo it.
  #   want writable, is read-only -> a previous --readonly session. Restore.
  #
  # --readonly covers every share, not only the project. The write probe only
  # sees the project, so for the others this relies on the mounts the VM was
  # last given. A VM with no record (created before they were recorded) is
  # treated as having a writable share: one extra restart, never a silent gap.
  #
  # On the common path both agree and nothing happens.
  # The env push rides along with the first probe: see
  # _agent_vm_push_env_and_probe. The file is on the VM's disk, so a restart
  # below keeps it. So does the question of whether the project's runtime
  # script is there, which only the VM reads when it is in the project.
  #
  # --scratch takes nothing of the project: no env file, no runtime script,
  # only ~/.agent-vm/env. It works at the project's path on the VM's own disk,
  # made here, which the probe then finds writable.
  local is_writable="false" probe_out guest_env="" guest_runtime="" project_env="" project_runtime="" env_payload
  if [[ -n "$scratch" ]]; then
    if ! limactl shell "$vm_name" sh -c 'sudo install -d -o "$(id -u)" -g "$(id -g)" "$1"' sh "$host_dir" </dev/null >/dev/null 2>&1; then
      echo "Error: could not make $host_dir in VM '$vm_name'." >&2
      return 1
    fi
    env_payload="$( [ ! -f "$AGENT_VM_STATE_DIR/env" ] || _agent_vm_strip_cr < "$AGENT_VM_STATE_DIR/env" )"
  else
    project_env="$(_agent_vm_project_env_file "$host_dir")"
    project_runtime="$(_agent_vm_project_runtime_path "$host_dir")"
    _agent_vm_in_project "$host_dir" "$project_env" && guest_env="$project_env"
    _agent_vm_in_project "$host_dir" "$project_runtime" && guest_runtime="$project_runtime"
    env_payload="$(_agent_vm_env_payload "$host_dir")"
  fi
  probe_out="$(_agent_vm_push_env_and_probe "$vm_name" "$host_dir" "$env_payload" \
    "$guest_env" "$guest_runtime")" && is_writable="true"
  [[ "$probe_out" == *env-ok* ]] || echo "Warning: failed to push the env files into VM '$vm_name'." >&2
  # A scratch VM has no share to repair: the repair below would mount the
  # project into it.
  if [[ -n "$scratch" && "$is_writable" != "true" ]]; then
    echo "Error: $host_dir is not writable in VM '$vm_name'." >&2
    return 1
  fi
  local needs_remount=""
  [[ "$is_writable" != "$want_writable" ]] && needs_remount=1
  if [[ "$want_writable" == "false" ]] && ! _agent_vm_mounts_all_readonly "$vm_name"; then
    needs_remount=1
  fi

  if [[ -n "$needs_remount" ]]; then
    # Stopping kills whatever else is using this VM, so ask first rather than
    # yanking a running session out from under another terminal. The repair
    # direction does not ask: a broken mount is already unusable.
    if [[ "$want_writable" == "false" ]] && [[ -n "$was_running" ]]; then
      echo "VM '$vm_name' was already running. It must be restarted to make its shares read-only."
      if ! _agent_vm_can_ask || [[ "$(_agent_vm_ask_yn "Stop the VM and apply --readonly?" N)" != "1" ]]; then
        # Not "continue with current settings" like the resize path does:
        # carrying on writable after --readonly was asked for is the one
        # outcome that must not be silent.
        echo "Error: --readonly was requested but not applied. Aborting." >&2
        return 1
      fi
    elif [[ "$want_writable" == "true" ]] && _agent_vm_mounts_all_readonly "$vm_name"; then
      echo "VM '$vm_name' was left read-only by --readonly; making it writable again..."
    elif [[ "$want_writable" == "true" ]]; then
      echo "Project mount is not writable; repairing..." >&2
    fi

    # Checked: editing the config and recording read-only shares while the VM
    # still runs with its writable ones would claim what is not true.
    if ! _agent_vm_stop_vm "$vm_name"; then
      echo "Error: could not stop VM '$vm_name' to change its shares; nothing was changed." >&2
      return 1
    fi
    # Rebuild the full mounts JSON so any ~/.agent-vm/volumes entries are
    # preserved (a plain project-dir-only set would silently drop them).
    local reconcile_mounts_json
    reconcile_mounts_json=$(_agent_vm_build_mounts_json "$vm_name" "$host_dir" "$want_writable" "${protect_git:+$ro_names}")
    local edit_out
    if ! edit_out=$(cd /tmp && limactl edit "$vm_name" \
      --set "$(_agent_vm_mounts_expr "$reconcile_mounts_json" "$protect_git")" 2>&1); then
      # Swallowing this left the caller with "failed" and no reason, which is
      # the one thing a security flag must not do.
      echo "Error: could not change the mount mode on '$vm_name':" >&2
      echo "$edit_out" >&2
      return 1
    fi
    _agent_vm_record_mounts "$vm_name" "$reconcile_mounts_json"
    if ! limactl start "$vm_name" &>/dev/null; then
      # Checked, because the verification below cannot tell a dead VM from a
      # successfully read-only one: both answer "not writable".
      echo "Error: VM '$vm_name' did not come back up after changing the project mount." >&2
      return 1
    fi

    # The push again, with the probe: the first one ran on the old mount, which
    # in the repair case did not show the project, so its env file and runtime
    # script were not found.
    is_writable="false"
    probe_out="$(_agent_vm_push_env_and_probe "$vm_name" "$host_dir" "$env_payload" \
      "$guest_env" "$guest_runtime")" && is_writable="true"
    [[ "$probe_out" == *env-ok* ]] || echo "Warning: failed to push the env files into VM '$vm_name'." >&2
    if [[ "$is_writable" != "$want_writable" ]]; then
      if [[ "$want_writable" == "true" ]]; then
        echo "Error: project directory is still not writable inside the VM:" >&2
        echo "  $host_dir" >&2
        echo "The host mount failed to attach. Try 'agent-vm --reset <command>'" >&2
        echo "to re-clone the VM from the base template." >&2
      else
        echo "Error: failed to mount the project directory read-only:" >&2
        echo "  $host_dir" >&2
      fi
      return 1
    fi
  fi

  # Under reverse-sshfs without readonlyNames the flag reaches the guest's sshfs
  # and nothing else, so refuse rather than report a restriction that root in
  # the VM can lift. "Could not tell" is refused too: the caller asked for a
  # boundary, and the only honest answers are "it is there" or an error.
  if [[ -n "$rdonly" ]]; then
    _agent_vm_mount_is_host_enforced "$vm_name"
    case $? in
      0) echo "Read-only: the project and every other share (enforced on the host)." ;;
      1) echo "Error: --readonly cannot be enforced with this mount type." >&2
         echo "  Lima only applies it inside the guest for reverse-sshfs (without" >&2
         echo "  readonlyNames) and for virtiofs under QEMU, where root in the VM" >&2
         echo "  can remount it read-write. Use virtiofs on vz, or 9p on QEMU (both" >&2
         echo "  enforce it on the host), in your Lima config, then --reset." >&2
         return 1 ;;
      *) echo "Error: could not determine the project mount type, so --readonly" >&2
         echo "  cannot be confirmed as enforced outside the VM. Aborting." >&2
         return 1 ;;
    esac
  fi

  # Install the host's terminfo entry inside the VM so non-standard terminals
  # (xterm-ghostty, xterm-kitty, …) work correctly. Without this, zsh/ZLE
  # can't decode keys → broken backspace, arrows, etc. Cached per-VM so we only
  # pay the limactl shell roundtrip when $TERM actually changes.
  local term_cache="$AGENT_VM_STATE_DIR/.agent-vm-term-${vm_name}"
  if [[ -n "${TERM:-}" ]] && [[ "$(cat "$term_cache" 2>/dev/null)" != "$TERM" ]] \
     && infocmp -x "$TERM" &>/dev/null; then
    if infocmp -x "$TERM" | limactl shell "$vm_name" sudo tic -x - &>/dev/null; then
      echo "$TERM" > "$term_cache"
    else
      echo "Warning: failed to install '$TERM' terminfo inside VM." >&2
    fi
  fi

  # Run per-user runtime script if it exists
  if [ -f "$AGENT_VM_STATE_DIR/runtime.sh" ]; then
    echo "Running user runtime setup..."
    _agent_vm_run_runtime "$vm_name" "$host_dir" "$AGENT_VM_STATE_DIR/runtime.sh"
  fi

  # Run project-specific runtime script if it exists: by its path in the VM
  # when it is in the project (the probe above said whether it is there),
  # piped from the host when AGENT_VM_PROJECT_RUNTIME puts it elsewhere.
  if [[ -n "$guest_runtime" ]]; then
    if [[ "$probe_out" == *runtime-found* ]]; then
      echo "Running project runtime setup..."
      _agent_vm_run_project_runtime "$vm_name" "$host_dir" "$guest_runtime"
    fi
  elif [ -f "$project_runtime" ]; then
    echo "Running project runtime setup..."
    _agent_vm_run_runtime "$vm_name" "$host_dir" "$project_runtime"
  fi

  # Load file mount entries from the cache. _agent_vm_build_mounts_json writes
  # them there (from its own local scope) for both new and existing VMs, so we
  # always read them back here to drive the inside-VM bind mounts below.
  if [[ -f "$file_mounts_cache" ]]; then
    local entry
    while IFS= read -r entry; do
      [[ -n "$entry" ]] && file_mount_entries+=("$entry")
    done < "$file_mounts_cache"

    # For existing VMs, refresh host-side hardlinks so atomic-rename edits on the
    # host propagate after a VM restart (ln/cp against the cached staging path).
    # New VMs just staged fresh copies in _agent_vm_build_mounts_json, so there
    # is nothing to refresh.
    if [[ -z "$is_new_vm" ]] && [[ ${#file_mount_entries[@]} -gt 0 ]]; then
      local host_src host_staging _bind_src _bind_dst
      for entry in "${file_mount_entries[@]}"; do
        IFS='|' read -r host_src host_staging _bind_src _bind_dst <<< "$entry"
        [[ -z "$host_staging" ]] && continue
        if [[ ! -e "$host_src" ]]; then
          echo "Warning: Mount source '${host_src}' no longer exists; VM will see the last-staged copy." >&2
          continue
        fi
        _agent_vm_stage_file "$host_src" "$host_staging" \
          || echo "Warning: Failed to refresh staged '${host_src}'; VM may see stale content." >&2
      done
    fi
  fi

  # Apply inside-VM bind mounts so each staged file appears at its final path.
  # Lima re-mounts staging dirs on each start, but the bind onto the final dest
  # is ephemeral. Batched into one limactl shell call (roundtrips cost ~1-2s)
  # and made idempotent so re-runs on a running VM are cheap no-ops.
  if [[ ${#file_mount_entries[@]} -gt 0 ]]; then
    local file_bind_payload=()
    local _host_src _host_staging bind_src bind_dst
    for entry in "${file_mount_entries[@]}"; do
      IFS='|' read -r _host_src _host_staging bind_src bind_dst <<< "$entry"
      [[ -n "$bind_src" && -n "$bind_dst" ]] && file_bind_payload+=("${bind_src}|${bind_dst}")
    done
    if [[ ${#file_bind_payload[@]} -gt 0 ]]; then
      echo "Mounting individual files..."
      # Paths are passed as positional args (single-quoted script) so entries
      # containing quotes or metacharacters cannot be interpreted as shell code.
      limactl shell "$vm_name" sudo bash -c '
        set -e
        for entry in "$@"; do
          bind_src="${entry%%|*}"
          bind_dst="${entry#*|}"
          if ! findmnt -no TARGET "$bind_dst" >/dev/null 2>&1; then
            mkdir -p "$(dirname "$bind_dst")" && touch "$bind_dst"
            mount --bind "$bind_src" "$bind_dst"
            mount -o remount,ro,bind "$bind_dst"
          fi
        done
      ' -- "${file_bind_payload[@]}"
    fi
  fi
}

# --- agent-vm: the command, dispatching to the rest ---------------------------

agent-vm() {
  # Options before the command are checked here and handed to it as written:
  # the commands that start a VM read them again, with their own.
  local lead=() vm_opts=() rm="" taken
  while [[ $# -gt 0 ]]; do
    _agent_vm_take_opt "$@" || return 1
    [[ $taken -gt 0 ]] || break
    lead+=("${@:1:$taken}")
    shift "$taken"
  done

  local cmd="${1:-help}"
  shift 2>/dev/null || true

  # VM options mean nothing to the other commands: `agent-vm --readonly stop`
  # must not read as if something had been made read-only.
  if [[ ${#lead[@]} -gt 0 ]]; then
    case "$cmd" in
      stop|rm|destroy|destroy-all|list|status|name|info|env|project-env|version|--version|-V|doctor|install|uninstall|help|--help|-h)
        echo "Error: ${lead[*]:0:1} is an option for the commands that start a VM (claude, opencode, codex, vibe, pi, shell, run), not for '$cmd'." >&2
        return 1 ;;
    esac
  fi

  # Every command except help/setup needs limactl present. (setup installs it
  # itself; help needs nothing.) Without this, stop/list/status/etc. would fail
  # with confusing empty output instead of a clear, actionable message.
  case "$cmd" in
    help|--help|-h|setup|version|--version|-V|name|info|env|project-env|doctor|install|uninstall) ;;
    *)
      if [[ -z "$(_agent_vm_limactl_path)" ]]; then
        echo "Error: limactl (Lima) not found. Run 'agent-vm setup' first, or install" >&2
        echo "it from https://lima-vm.io/docs/installation/" >&2
        return 1
      fi ;;
  esac

  case "$cmd" in
    setup)
      _agent_vm_setup ${lead[@]+"${lead[@]}"} "$@"
      ;;
    claude|opencode|codex|vibe|pi)
      _agent_vm_agent "$cmd" ${lead[@]+"${lead[@]}"} "$@"
      ;;
    shell|sh)
      _agent_vm_shell ${lead[@]+"${lead[@]}"} "$@"
      ;;
    run)
      _agent_vm_run ${lead[@]+"${lead[@]}"} "$@"
      ;;
    stop)
      _agent_vm_stop "$@"
      ;;
    rm|destroy)
      _agent_vm_destroy "$@"
      ;;
    destroy-all)
      _agent_vm_destroy_all "$@"
      ;;
    list)
      _agent_vm_list "$@"
      ;;
    status)
      _agent_vm_status "$@"
      ;;
    name)
      local name_dir
      name_dir="$(_agent_vm_abs_dir "${1:-}")" || return 1
      _agent_vm_name "$name_dir"
      ;;
    info)
      local info_dir
      info_dir="$(_agent_vm_abs_dir "${1:-}")" || return 1
      _agent_vm_info "$info_dir"
      ;;
    env)
      _agent_vm_env env "$AGENT_VM_STATE_DIR/env" "" "$@"
      ;;
    project-env)
      local project_env_file project_top=""
      project_env_file="$(_agent_vm_project_env_file)"
      _agent_vm_in_project "$(pwd)" "$project_env_file" && project_top="$(pwd)"
      _agent_vm_env project-env "$project_env_file" "$project_top" "$@" || return $?
      # Only after a write, and only if it worked: that is when the file is
      # new to the repository and when the user is looking.
      if [ "${1:-}" = "set" ]; then
        _agent_vm_warn_unignored "$project_env_file"
      fi
      ;;
    version|--version|-V)
      _agent_vm_version "$@"
      ;;
    doctor)
      if [[ $# -gt 0 ]]; then
        echo "Usage: agent-vm doctor" >&2
        return 2
      fi
      _agent_vm_doctor
      ;;
    install)
      _agent_vm_install "$@"
      ;;
    uninstall)
      _agent_vm_uninstall "$@"
      ;;
    help|--help|-h)
      _agent_vm_help
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      echo "Run 'agent-vm help' for usage." >&2
      return 1
      ;;
  esac
}

# --- commands -----------------------------------------------------------------

# Run a command in the VM through a login zsh.
#
# `limactl shell VM cmd` runs cmd under the shell configured for the instance,
# and Lima >= 2.2.0 defaults that to /bin/bash whatever the guest login shell
# is (lima-vm/lima#5194); older versions used "$SHELL", i.e. the login shell
# `agent-vm.setup.sh` sets with chsh. Agent PATH entries and the
# ~/.agent-vm.env sourcing both live in ~/.zshenv, so under bash the agents are
# not found and anything that is found starts without its API keys. Forcing
# `zsh -l -c` here works on every Lima version.
#
# The command and its arguments are passed as positional parameters, so the
# guest shell never re-parses them; `env` runs the command and keeps leading
# VAR=value assignments working.
#
# Usage: _agent_vm_lima_run <vm_name> <host_dir> <tty:1|""> <command> [args...]
_agent_vm_lima_run() {
  local vm_name="$1" host_dir="$2" want_tty="$3"
  shift 3
  local shell_opts=(--workdir "$host_dir")
  [[ -n "$want_tty" ]] && shell_opts+=(--tty)
  limactl shell "${shell_opts[@]}" "$vm_name" -- zsh -l -c 'exec env "$@"' agent-vm "$@"
}

# Starts this directory's VM with the caller's vm_opts, runs <function> with
# the VM name and the directory before its own arguments, then deletes the VM
# when the caller's rm is set. Returns the function's status. With --scratch,
# see _agent_vm_run_scratch.
_agent_vm_in_vm() {
  local fn="$1" host_dir vm_name st=0 o
  shift
  host_dir="$(pwd)"
  for o in ${vm_opts[@]+"${vm_opts[@]}"}; do
    if [[ "$o" == --scratch ]]; then
      _agent_vm_run_scratch "$fn" "$host_dir" "$@"
      return
    fi
  done
  vm_name="$(_agent_vm_name "$host_dir")" || return 1
  _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"} || return 1
  _agent_vm_print_resources "$vm_name"
  "$fn" "$vm_name" "$host_dir" "$@" || st=$?
  if [[ -n "$rm" ]]; then
    echo "Removing VM..."
    _agent_vm_destroy
  fi
  return "$st"
}

# --scratch: a new VM of its own (see _agent_vm_scratch_name), sharing
# nothing, deleted once <function> returns, whatever it returns, unless the
# user keeps it a while to look inside (asked below). Ctrl-C
# included: the trap lets the run go on to the deletion instead of ending
# the shell with the interrupted command (bash ends a script whose child dies
# of SIGINT, unless it traps it). A run that is killed outright leaves its VM
# recorded with its pid, and the next --scratch run deletes it.
_agent_vm_run_scratch() {
  local fn="$1" host_dir="$2" vm_name st=0 old_int="" leftover
  shift 2
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions localtraps
  while IFS= read -r leftover; do
    [[ -n "$leftover" ]] || continue
    echo "Deleting scratch VM '$leftover', left by a run that did not finish..."
    _agent_vm_delete_vm "$leftover"
  done <<< "$(_agent_vm_scratch_leftovers)"
  vm_name="$(_agent_vm_scratch_name "$host_dir")" || return 1
  mkdir -p "$AGENT_VM_STATE_DIR" && printf '%s\n' "$$" > "$(_agent_vm_scratch_marker "$vm_name")" || return 1
  # The caller's: the shell session says the VM goes on exit.
  rm=1
  [[ -n "${BASH_VERSION:-}" ]] && old_int="$(trap -p INT)"
  trap ':' INT
  if _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"}; then
    _agent_vm_print_resources "$vm_name"
    "$fn" "$vm_name" "$host_dir" "$@" || st=$?
    # Asked before the deletion, when it can be (yes by default): a no opens
    # a shell in the VM, to look at what the command left, and asks again on
    # its exit. Only an explicit no keeps it: no terminal, or a question cut
    # short, deletes.
    while _agent_vm_can_ask \
          && [[ "$(_agent_vm_ask_yn "Delete scratch VM '$vm_name'?" Y)" == "0" ]]; do
      echo "A shell in scratch VM '$vm_name'. Type 'exit' to be asked again."
      limactl shell --workdir "$host_dir" "$vm_name" zsh -l
    done
  else
    st=1
  fi
  echo "Deleting scratch VM '$vm_name'..."
  _agent_vm_delete_vm "$vm_name" || st=1
  if [[ -n "${BASH_VERSION:-}" ]]; then
    trap - INT
    [[ -z "$old_int" ]] || eval "$old_int"
  fi
  return "$st"
}

# `agent-vm <agent> [options] [args]`: the agent, with the flag that lets it
# work unattended (safe in the VM), and a TTY for the full-screen ones.
_agent_vm_agent() {
  local agent="$1" cmd=() tty="" vm_opts=() rm="" args=()
  shift
  case "$agent" in
    # The VM also enforces bypass mode with managed settings (see
    # agent-vm.setup.sh): Claude Code drops the flag when it relaunches itself.
    claude)   cmd=(claude --dangerously-skip-permissions) ;;
    # Approves every prompt that is not explicitly denied: OpenCode's shipped
    # "yolo" (a --yolo flag was proposed, never merged).
    opencode) cmd=(opencode --auto); tty=1 ;;
    codex)    cmd=(codex --dangerously-bypass-approvals-and-sandbox) ;;
    vibe)     cmd=(vibe --agent auto-approve); tty=1 ;;
    # No permission prompts: it runs every tool as asked.
    pi)       cmd=(pi); tty=1 ;;
    *)        echo "Error: unknown agent: $agent" >&2; return 1 ;;
  esac
  _agent_vm_split_args "$@" || return 1
  _agent_vm_in_vm _agent_vm_lima_run "$tty" "${cmd[@]}" ${args[@]+"${args[@]}"}
}

# `agent-vm shell [-c "command"]`: a login zsh in the VM, so ~/.zshenv (mise,
# PATH, ~/.agent-vm.env) is loaded. Takes no command of its own, so a word it
# does not know is an error, not something skipped as if it had applied.
_agent_vm_shell() {
  local vm_opts=() rm="" cmd_string="" taken
  while [[ $# -gt 0 ]]; do
    _agent_vm_take_opt "$@" || return 1
    if [[ $taken -gt 0 ]]; then
      shift "$taken"
      continue
    fi
    case "$1" in
      -c|--command)
        if [[ $# -lt 2 || -z "$2" ]]; then
          echo "Error: -c/--command requires a command string." >&2
          return 1
        fi
        cmd_string="$2"; shift 2 ;;
      *)
        echo "Error: unknown argument for shell: $1" >&2
        echo "Usage: agent-vm [vm options] shell [-c \"command\"]" >&2
        return 1 ;;
    esac
  done
  _agent_vm_in_vm _agent_vm_shell_session "$cmd_string"
}

_agent_vm_shell_session() {
  local vm_name="$1" host_dir="$2" cmd_string="$3"
  if [[ -n "$cmd_string" ]]; then
    limactl shell --workdir "$host_dir" "$vm_name" zsh -l -c "$cmd_string"
    return
  fi
  echo "VM: $vm_name | Dir: $host_dir"
  if [[ -n "$rm" ]]; then
    echo "Type 'exit' to leave. VM will be destroyed after exit."
  else
    echo "Type 'exit' to leave (VM keeps running). Use 'agent-vm stop' to stop it."
  fi
  limactl shell --workdir "$host_dir" "$vm_name" zsh -l
}

# `agent-vm run [--tty] <command> [args]`. --tty gives the command a
# pseudo-terminal, which full-screen TUIs (htop, …) need to draw.
_agent_vm_run() {
  local vm_opts=() rm="" tty="" args=()
  _agent_vm_split_args "$@" || return 1
  if [[ ${#args[@]} -eq 0 ]]; then
    echo "Usage: agent-vm run [--tty] <command> [args]" >&2
    return 1
  fi
  _agent_vm_in_vm _agent_vm_lima_run "$tty" "${args[@]}"
}

# Resolve the VM that `stop` / `rm` acts on, and prove it exists.
# Prints the name on stdout; diagnostics go to stderr.
#
# With no argument: the current directory's VM, as before.
#
# With one argument: a VM name as printed by `agent-vm list`. It has to be a
# NAME and not a directory, because the case it exists for is a VM no directory
# can reach any more: the name embeds a hash of the path, so renaming or
# deleting the project folder orphans the VM, and `_agent_vm_abs_dir` would
# refuse the old path anyway. `list` remains the only handle on it.
#
# The `agent-vm-` prefix is required: without it a typo could stop or delete an
# unrelated Lima instance on the same machine.
_agent_vm_resolve_target() {
  local verb="$1"
  shift

  local vm_name
  case $# in
    0) vm_name="$(_agent_vm_name "$(pwd)")" || return 1 ;;
    1)
      vm_name="$1"
      case "$vm_name" in
        agent-vm-*) ;;
        *)
          echo "Error: '$vm_name' is not an agent-vm VM name (they start with 'agent-vm-')." >&2
          echo "Run 'agent-vm list' to see them." >&2
          return 1 ;;
      esac ;;
    *)
      echo "Usage: agent-vm $verb [vm-name]" >&2
      return 1 ;;
  esac

  local st=0
  _agent_vm_exists "$vm_name" || st=$?
  case "$st" in
    0) ;;
    1)
      if [[ $# -eq 0 ]]; then
        echo "No VM found for this directory." >&2
        echo "Run 'agent-vm list' to see existing VMs, then 'agent-vm $verb <vm-name>'." >&2
      else
        echo "Error: no such VM: $vm_name" >&2
        echo "Run 'agent-vm list' to see existing VMs." >&2
      fi
      return 1 ;;
    *)
      echo "Error: could not query Lima. Is it installed and working?" >&2
      return 1 ;;
  esac

  echo "$vm_name"
}

_agent_vm_stop() {
  local vm_name
  vm_name="$(_agent_vm_resolve_target stop "$@")" || return 1

  echo "Stopping VM '$vm_name'..."
  if ! _agent_vm_stop_vm "$vm_name"; then
    echo "Error: VM '$vm_name' is still running, or Lima cannot say. See 'limactl list'." >&2
    return 1
  fi
  echo "VM stopped."
}

_agent_vm_destroy() {
  local vm_name
  vm_name="$(_agent_vm_resolve_target rm "$@")" || return 1

  echo "Stopping and deleting VM '$vm_name'..."
  _agent_vm_delete_vm "$vm_name" || return 1
  echo "VM destroyed."
}

# Every agent-vm VM, the base template included: this is the command that
# gives the disk space back. `agent-vm setup` rebuilds the template.
_agent_vm_destroy_all() {
  local list vms
  if ! list="$(limactl list -q 2>/dev/null)"; then
    echo "Error: could not query Lima. Is it installed and working?" >&2
    return 1
  fi
  vms="$(printf '%s\n' "$list" | grep "^agent-vm-" || true)"
  if [[ -z "$vms" ]]; then
    echo "No agent-vm VMs found."
    return 0
  fi
  echo "This will destroy the following VMs:"
  echo "$vms"
  if _agent_vm_has_line "$vms" "$AGENT_VM_TEMPLATE"; then
    echo "($AGENT_VM_TEMPLATE is the base template: 'agent-vm setup' rebuilds it.)"
  fi
  if ! _agent_vm_can_ask || [[ "$(_agent_vm_ask_yn "Continue?" N)" != "1" ]]; then
    echo "Aborted."
    return 0
  fi
  _agent_vm_destroy_vms "$vms" || return 1
  echo "All VMs destroyed."
}

# Stop, delete and forget each VM named on its own line in $1. Goes through
# all of them, and fails if one could not be deleted.
# limactl gets /dev/null as stdin (see _agent_vm_delete_vm): the names are
# read from stdin, and a limactl that reads it would swallow the ones still to
# come.
_agent_vm_destroy_vms() {
  local vm st=0
  while IFS= read -r vm; do
    [[ -n "$vm" ]] || continue
    echo "Destroying $vm..."
    _agent_vm_delete_vm "$vm" || st=1
  done <<< "$1"
  return "$st"
}

_agent_vm_list() {
  limactl list | head -1
  limactl list | grep "^agent-vm-" || echo "(no VMs)"
}

_agent_vm_status() {
  local host_dir
  host_dir="$(pwd)"
  local current_vm_name
  current_vm_name="$(_agent_vm_name "$host_dir")" || return 1

  local list
  if ! list="$(limactl list 2>/dev/null)"; then
    echo "Error: could not query Lima. Is it installed and working?" >&2
    return 1
  fi

  echo "VMs (current directory: $host_dir):"
  echo ""
  # Read from a here-string, not a pipe: the exit status of a piped loop is
  # the loop's own, so a `|| echo "(no VMs)"` after it could never fire.
  local line header="" found=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ -z "$header" ]]; then
      header=1
      echo "  $line"
      continue
    fi
    case "$line" in
      "$current_vm_name "*) echo "> $line"; found=1 ;;
      agent-vm-*)           echo "  $line"; found=1 ;;
    esac
  done <<< "$list"
  [[ -n "$found" ]] || echo "  (no VMs)"
}

# When the file is executed (the command `install` puts on PATH, or
# `./agent-vm.sh setup`) rather than sourced, dispatch to the agent-vm
# function so it doesn't silently no-op. Detection is shell-specific:
#   bash: BASH_SOURCE[0] differs from $0 when sourced
#   zsh:  ZSH_EVAL_CONTEXT contains ':file' when sourced
_agent_vm_is_sourced() {
  if [[ -n "${BASH_VERSION:-}" ]]; then
    [[ "${BASH_SOURCE[0]}" != "$0" ]]
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    [[ "${ZSH_EVAL_CONTEXT:-}" == *:file* ]]
  else
    return 0  # unknown shell — assume sourced and don't auto-run
  fi
}

if ! _agent_vm_is_sourced; then
  unset -f _agent_vm_is_sourced
  agent-vm "$@"
  # Preserve agent-vm's exit code — without the explicit exit, the script
  # would end on the implicit `unset -f` below, which always returns 0 and
  # would mask command failures (`./agent-vm.sh bad-cmd; echo $?` → 0).
  exit $?
fi
unset -f _agent_vm_is_sourced

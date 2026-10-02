#!/usr/bin/env bash
#
# agent-vm: Run AI coding agents inside sandboxed Lima VMs
# Part of https://www.agent-vm.org/
#
# Put it on your PATH with `./agent-vm.sh install`. It can also be sourced
# from bash, which defines agent-vm as a shell function. Commands:
# `agent-vm help` (lib/help.sh).

# zsh, which 0.1.0's installer had source this file from ~/.zshrc: only a
# function that runs this file with bash. %x is the file being sourced, :A
# makes it absolute with links resolved. The eval keeps bash from parsing zsh
# syntax.
if [[ -n "${ZSH_VERSION:-}" ]]; then
  eval '
    [[ "${ZSH_EVAL_CONTEXT:-}" == *:file* ]] || exec bash "$0" "$@"
    eval "agent-vm() { command bash ${(qq)${(%):-%x}:A} \"\$@\"; }"
  '
  return 0
fi

# Semantic version of this file. Bumped by hand on release. Integrators gate on
# it via `agent-vm version`; a build with no `version` command predates it.
AGENT_VM_VERSION="0.2.0"

AGENT_VM_TEMPLATE="agent-vm-base"
# Overridable, for a test or a second install, without moving HOME (and
# Lima's state with it). `agent-vm info` publishes it as state_dir=.
AGENT_VM_STATE_DIR="${AGENT_VM_STATE_DIR:-${HOME}/.agent-vm}"

# Directory of the real agent-vm.sh, symlinks followed: the PATH entry
# `install` makes is one. By hand, as macOS's readlink has no -f. `CDPATH=`
# everywhere a relative path is cd'ed to: with it set, cd searches it first.
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
AGENT_VM_SCRIPT_DIR="$(_agent_vm_script_dir "${BASH_SOURCE[0]:-$0}")"
if [[ -z "$AGENT_VM_SCRIPT_DIR" ]]; then
  echo "agent-vm: cannot find the directory of agent-vm.sh" >&2
  return 1 2>/dev/null || exit 1
fi

# The rest of agent-vm, one file per concern, sourced like this one. Only
# functions and settings: nothing runs until a command does. A file that is
# missing stops here, not half-way through a command.
for _agent_vm_lib in ui options host vm mounts git runtime env info install doctor help setup code; do
  _agent_vm_lib="$AGENT_VM_SCRIPT_DIR/lib/$_agent_vm_lib.sh"
  if [[ ! -r "$_agent_vm_lib" ]] || ! . "$_agent_vm_lib"; then
    echo "agent-vm: cannot load $_agent_vm_lib" >&2
    unset _agent_vm_lib
    return 1 2>/dev/null || exit 1
  fi
done
unset _agent_vm_lib

# --- starting a project's VM --------------------------------------------------

# The security checks of a start, for the project <dir> and its VM <vm>. Reads the caller's
# vm_up, scratch and rdonly, and sets its protect_git, ro_names and
# hooks_notes. With vm_up set (a running VM that keeps running), the risks are
# printed and nothing is asked. Fails when the start must stop.
_agent_vm_start_checks() {
  local host_dir="$1" vm_name="$2" lima_st=0
  protect_git="" ro_names="" hooks_notes=""

  # Every .git read-only for the guest, when this Lima can enforce it and it
  # was not turned off. The mounts built afterwards, on every path, follow the
  # answer. A Lima that cannot, with shares left writable and nobody having
  # asked for a writable .git, is a risk to accept. One whose answer could not
  # be read stops the start: taking it for a no would drop the protection of
  # the VM.
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
    elif _agent_vm_unprotected_mount_is_sshfs "$vm_name"; then
      # Asked below, with the rest of the disk.
      :
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

  # Not only .git: shares Lima does not confine leave the rest of the disk
  # in reach (see _agent_vm_unprotected_mount_is_sshfs), --unsafe-writable-git
  # or not. --readonly cannot be enforced on them either: refused before
  # anything boots.
  if [[ -z "$scratch" && -z "$protect_git" ]] && _agent_vm_unprotected_mount_is_sshfs "$vm_name"; then
    if [[ -n "$rdonly" ]]; then
      echo "Error: --readonly cannot be enforced here: the shares would be reverse-sshfs, which this Lima does not confine. Install the Lima build 'agent-vm setup' offers, or use --scratch." >&2
      return 1
    elif [[ -n "$vm_up" ]]; then
      echo "Warning: this Lima cannot keep the VM to its shares: root in the VM may reach files outside them, your SSH keys included ('agent-vm doctor' says more)." >&2
    else
      { _agent_vm_sshfs_exposure_note; _agent_vm_git_protection_hint; } | _agent_vm_box "Lima cannot keep the VM to its shares"
      if ! _agent_vm_confirm_unsafe; then
        echo "Aborted. Install that Lima build, or use --scratch, which shares nothing." >&2
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
  local hooks_rel hooks_in hooks_name hooks_names=()
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
}

# A VM that ran when the start began, so whose start asked nothing (see
# _agent_vm_start_checks), has just been stopped to boot again: ask now, as
# for any VM about to boot. Reads and clears the caller's vm_up. Fails, with
# the VM left stopped, when the start must stop.
_agent_vm_recheck_after_stop() {
  [[ -n "$vm_up" ]] || return 0
  vm_up=""
  if ! _agent_vm_start_checks "$1" "$2"; then
    echo "VM '$2' is stopped." >&2
    return 1
  fi
}

# Stops <vm>, for the project <dir>, to boot it again changed, then asks what
# its start did not (see above). Fails, saying so, when it did not stop.
_agent_vm_stop_to_change() {
  if ! _agent_vm_stop_vm "$1"; then
    echo "Error: could not stop VM '$1': nothing was changed." >&2
    return 1
  fi
  _agent_vm_recheck_after_stop "$2" "$1"
}

# Gives the stopped <vm> its shares for the project <dir>, writable or not
# (<writable> true/false), with the caller's protect_git and ro_names, or none
# for its scratch, and records them (see _agent_vm_record_mounts).
_agent_vm_apply_shares() {
  local vm="$1" dir="$2" writable="$3" json="[]" out
  [[ -n "$scratch" ]] || json="$(_agent_vm_build_mounts_json "$vm" "$dir" "$writable" "${protect_git:+$ro_names}")"
  if ! out=$(cd /tmp && limactl edit "$vm" --set "$(_agent_vm_mounts_expr "$json" "$protect_git")" 2>&1); then
    echo "Error: could not set the shares of VM '$vm':" >&2
    echo "$out" >&2
    return 1
  fi
  _agent_vm_record_mounts "$vm" "$json"
}

# The caller's memory, cpus, ssh_port and disk, on the stopped <vm>. The disk
# apart, with a warning only: Lima rejects a whole edit that would shrink it.
_agent_vm_apply_resources() {
  local vm="$1" out args=()
  [[ -z "$memory" ]] || args+=(--memory "$memory")
  [[ -z "$cpus" ]] || args+=(--cpus "$cpus")
  [[ -z "$ssh_port" ]] || args+=(--set ".ssh.localPort = $ssh_port")
  # Never without arguments: `limactl edit <vm>` alone opens $EDITOR.
  if [[ ${#args[@]} -gt 0 ]] && ! out=$(cd /tmp && limactl edit "$vm" "${args[@]}" 2>&1); then
    echo "Error: could not set the memory, CPUs or SSH port of VM '$vm':" >&2
    echo "$out" >&2
    return 1
  fi
  if [[ -n "$disk" ]] && ! out=$(cd /tmp && limactl edit "$vm" --disk "$disk" 2>&1); then
    echo "Warning: cannot set the disk of VM '$vm' to $disk GiB: it can grow, not shrink ('agent-vm setup --disk $disk' for a smaller base)." >&2
    echo "$out" >&2
  fi
  return 0
}

# The env push and the write probe (see _agent_vm_push_env_and_probe), with
# the caller's vm_name, host_dir, env_payload, guest_env and guest_runtime,
# into its probe_out and is_writable.
_agent_vm_push_and_probe() {
  is_writable="false"
  probe_out="$(_agent_vm_push_env_and_probe "$vm_name" "$host_dir" "$env_payload" \
    "$guest_env" "$guest_runtime")" && is_writable="true"
  [[ "$probe_out" == *env-ok* ]] || echo "Warning: failed to push the env files into VM '$vm_name'." >&2
}

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

  # --scratch (see _agent_vm_run_scratch) shares nothing: no share check
  # below applies to it.
  if [[ -n "$scratch" && ( -n "$reset" || -n "$rdonly" ) ]]; then
    echo "Error: --scratch makes a new VM that shares nothing: --reset and --readonly do not go with it." >&2
    return 1
  fi

  local want_writable="true"
  [[ -n "$rdonly" ]] && want_writable="false"

  # Clamped once, so every path below compares and applies the same values.
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
    echo "Error: refusing to share $host_dir with a VM: it $unsafe." >&2
    echo "Run agent-vm from a project directory." >&2
    return 1
  fi

  local bad
  if [[ -z "$scratch" ]] && bad="$(_agent_vm_unmountable_path "$host_dir")"; then
    echo "Error: project path $bad:" >&2
    echo "  $host_dir" >&2
    echo "Rename the directory, then retry." >&2
    return 1
  fi

  # A run interrupted while Lima created it leaves a folder without lima.yaml.
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

  # The security checks, before anything changes. A running VM is asked
  # nothing until stopped (see _agent_vm_recheck_after_stop).
  local vm_up="" protect_git="" ro_names="" hooks_notes=""
  [[ -z "$reset" ]] && _agent_vm_running "$vm_name" && vm_up=1
  _agent_vm_start_checks "$host_dir" "$vm_name" || return 1

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
    # Which agent-vm built its base: none recorded for a base of 0.1.0, which
    # has no sshfs for the protected shares. Then migrated before the edit,
    # on the bare clone (see _agent_vm_migrate_0_1).
    rm -f "$AGENT_VM_STATE_DIR/.agent-vm-built-by-${vm_name}" "$AGENT_VM_STATE_DIR/.agent-vm-sshfs-${vm_name}"
    if [[ -f "$AGENT_VM_STATE_DIR/.agent-vm-base-built-by" ]]; then
      cp "$AGENT_VM_STATE_DIR/.agent-vm-base-built-by" "$AGENT_VM_STATE_DIR/.agent-vm-built-by-${vm_name}"
    fi
    if [[ -n "$protect_git" ]] && ! _agent_vm_migrate_0_1_if_needed "$vm_name"; then
      _agent_vm_delete_vm "$vm_name"
      return 1
    fi
    # Configured before its first start. A clone that could not be holds
    # nothing yet: it goes, and the next run starts over (#21).
    if ! _agent_vm_apply_shares "$vm_name" "$host_dir" "$want_writable" \
       || ! _agent_vm_apply_resources "$vm_name"; then
      _agent_vm_delete_vm "$vm_name"
      return 1
    fi
    printf '%s' "$hooks_notes"
    # Which base it was cloned from, for the stale warning below.
    local base_ver="$AGENT_VM_STATE_DIR/.agent-vm-base-version"
    if [[ -f "$base_ver" ]]; then
      cp "$base_ver" "$AGENT_VM_STATE_DIR/.agent-vm-version-${vm_name}"
    fi
  elif { [[ -n "$disk" || -n "$memory" || -n "$cpus" ]] \
         && _agent_vm_resources_differ "$vm_name" "$cpus" "$memory" "$disk"; } \
       || _agent_vm_ssh_port_differs "$vm_name" "$ssh_port"; then
    # Only when the request differs from what the VM has: a caller passing
    # its defaults every time would otherwise be asked every time. Declined,
    # the VM keeps its settings and everything below still applies.
    apply_resize=1
    if _agent_vm_running "$vm_name"; then
      echo "VM '$vm_name' is currently running. It must be stopped to apply new settings."
      if _agent_vm_can_ask && [[ "$(_agent_vm_ask_yn "Stop the VM and apply changes?" N)" == "1" ]]; then
        echo "Stopping VM..."
        _agent_vm_stop_to_change "$vm_name" "$host_dir" || return 1
      else
        echo "Not applied: the VM keeps its current settings."
        apply_resize=""
      fi
    fi
  fi
  if [[ -n "$apply_resize" ]]; then
    echo "Updating VM settings..."
    _agent_vm_apply_resources "$vm_name" || return 1
  fi

  # The same verdict as `info`'s vm_stale=.
  if [[ "$(_agent_vm_stale_state "$vm_name")" == "1" ]]; then
    echo "Warning: Base VM has been updated since this VM was cloned. Use --reset to re-clone from the new base." >&2
  fi

  # Whether another session may be using it: read before the start below.
  local was_running=""
  _agent_vm_running "$vm_name" && was_running=1

  # Shares recorded otherwise than asked: the .git protection (git_stale), its
  # names (names_stale), the mode (mode_stale). A stopped VM is changed before
  # it boots, so nothing starting with it gets a writable window; a running
  # one keeps its shares until stopped, or is offered a restart.
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
  # A running VM lacking a protection it should have: restarting it cuts its
  # other sessions, so it is asked; declined, it is a risk to accept. Not
  # under --readonly, which restarts it below anyway.
  if [[ -z "$rdonly" && -n "$was_running" && -n "$protect_git" && ( -n "$git_stale" || -n "$names_stale" ) ]]; then
    if [[ -n "$git_stale" ]]; then
      echo "Warning: VM '$vm_name' is running with .git writable, so the agent can still write .git." >&2
    else
      echo "Warning: VM '$vm_name' runs with an older list of read-only names (it needs $(_agent_vm_names_text "$ro_names")), so the agent can still write the new ones." >&2
    fi
    if ! _agent_vm_prompts_disabled_by >/dev/null && _agent_vm_can_ask \
       && [[ "$(_agent_vm_ask_yn "Restart it now to apply them? Sessions using it are cut." Y)" == "1" ]]; then
      _agent_vm_stop_to_change "$vm_name" "$host_dir" || return 1
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
    if [[ -n "$protect_git" ]]; then
      _agent_vm_migrate_0_1_if_needed "$vm_name" || return 1
    fi
    if [[ -n "$mode_stale" && "$want_writable" == "false" ]]; then
      echo "Making every share of VM '$vm_name' read-only..."
    elif [[ -n "$mode_stale" ]]; then
      echo "VM '$vm_name' was left read-only by --readonly; making it writable again..."
    fi
    _agent_vm_apply_shares "$vm_name" "$host_dir" "$want_writable" || return 1
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

  # Bring the shares of the running VM in line with the mode asked: a write
  # probe on the project (see _agent_vm_push_env_and_probe, which pushes the
  # env too), and the record for the other shares, a missing one counting as
  # writable. A mismatch is a stop, edit and start: a broken mount repaired,
  # --readonly applied, or a --readonly VM made writable again.
  # --scratch takes nothing of the project but ~/.agent-vm/env, and works at
  # the project's path on the VM's own disk.
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
    # By their path in the project, the one the VM has.
    local in_rel
    in_rel="$(_agent_vm_project_rel "$host_dir" "$project_env")" && guest_env="$host_dir/$in_rel"
    in_rel="$(_agent_vm_project_rel "$host_dir" "$project_runtime")" && guest_runtime="$host_dir/$in_rel"
    env_payload="$(_agent_vm_env_payload "$host_dir")"
  fi
  _agent_vm_push_and_probe
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
    # yanking a running session out from under another terminal, in both
    # directions. The repair direction does not ask: a broken mount is
    # already unusable.
    if [[ "$want_writable" == "true" && -n "$was_running" ]] && _agent_vm_mounts_all_readonly "$vm_name"; then
      echo "VM '$vm_name' runs read-only (--readonly). It must be restarted to make its shares writable."
      if ! _agent_vm_can_ask || [[ "$(_agent_vm_ask_yn "Stop the VM and make it writable? Sessions using it are cut." N)" != "1" ]]; then
        echo "Error: not restarted. Pass --readonly to use it as it is, or 'agent-vm stop' it first." >&2
        return 1
      fi
    elif [[ "$want_writable" == "false" ]] && [[ -n "$was_running" ]]; then
      echo "VM '$vm_name' was already running. It must be restarted to make its shares read-only."
      if ! _agent_vm_can_ask || [[ "$(_agent_vm_ask_yn "Stop the VM and apply --readonly?" N)" != "1" ]]; then
        # Not "continue with current settings" like the resize path does:
        # carrying on writable after --readonly was asked for is the one
        # outcome that must not be silent.
        echo "Error: --readonly was requested but not applied. Aborting." >&2
        return 1
      fi
    elif [[ "$want_writable" == "true" ]]; then
      echo "Project mount is not writable; repairing..." >&2
    fi

    # Stopped for sure first: recording read-only shares while it still runs
    # writable would claim what is not true.
    _agent_vm_stop_to_change "$vm_name" "$host_dir" || return 1
    if [[ -n "$protect_git" ]]; then
      _agent_vm_migrate_0_1_if_needed "$vm_name" || return 1
    fi
    _agent_vm_apply_shares "$vm_name" "$host_dir" "$want_writable" || return 1
    # Checked: the probe below cannot tell a dead VM from a read-only one.
    if ! limactl start "$vm_name" &>/dev/null; then
      echo "Error: VM '$vm_name' did not come back up after changing the project mount." >&2
      return 1
    fi
    # Again: in the repair case the first probe could not see the project's
    # env file and runtime script.
    _agent_vm_push_and_probe
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

  # --readonly is only claimed where the host enforces it (see
  # _agent_vm_mount_is_host_enforced); "could not tell" is refused too.
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

  # The host's terminfo entry in the VM, for terminals Debian does not know
  # (xterm-ghostty, xterm-kitty): zsh cannot read their keys otherwise. Once
  # per VM and $TERM.
  local term_cache="$AGENT_VM_STATE_DIR/.agent-vm-term-${vm_name}"
  if [[ -n "${TERM:-}" ]] && [[ "$(cat "$term_cache" 2>/dev/null)" != "$TERM" ]] \
     && infocmp -x "$TERM" &>/dev/null; then
    if infocmp -x "$TERM" | limactl shell "$vm_name" sudo tic -x - &>/dev/null; then
      echo "$TERM" >| "$term_cache"
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

  # Single files of ~/.agent-vm/volumes (see _agent_vm_build_mounts_json, which
  # lists them in the cache): an existing VM's staged copy refreshed, so an
  # edit saved by rename on the host shows, then each bound at its place in
  # the VM, in one round trip. The bind does not survive a restart, and is
  # skipped when there.
  if [[ -f "$file_mounts_cache" ]]; then
    local host_src host_staging bind_src bind_dst
    while IFS='|' read -r host_src host_staging bind_src bind_dst; do
      [[ -n "$host_staging" ]] || continue
      if [[ -n "$is_new_vm" ]]; then
        :
      elif [[ ! -e "$host_src" ]]; then
        echo "Warning: Mount source '${host_src}' no longer exists; VM will see the last-staged copy." >&2
      else
        _agent_vm_stage_file "$host_src" "$host_staging" \
          || echo "Warning: Failed to refresh staged '${host_src}'; VM may see stale content." >&2
      fi
      [[ -n "$bind_src" && -n "$bind_dst" ]] && file_mount_entries+=("${bind_src}|${bind_dst}")
    done < "$file_mounts_cache"
    if [[ ${#file_mount_entries[@]} -gt 0 ]]; then
      echo "Mounting individual files..."
      # The paths as arguments, never in the script.
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
      ' -- "${file_mount_entries[@]}"
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
        echo "Error: ${lead[*]:0:1} is an option for the commands that start a VM (claude, opencode, codex, vibe, pi, shell, run, code), not for '$cmd'." >&2
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
    code)
      _agent_vm_code ${lead[@]+"${lead[@]}"} "$@"
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
    list|status)
      _agent_vm_list
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
      local project_env_file project_top="" project_rel
      project_env_file="$(_agent_vm_project_env_file)"
      if project_rel="$(_agent_vm_project_rel "$(pwd)" "$project_env_file")"; then
        project_top="$(pwd)"
        project_env_file="$project_top/$project_rel"
      fi
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
# VAR=value assignments working. `env --`: GNU env still reads assignments
# after it, and a command starting with `-` (`run -i foo`) is not taken for
# one of its options. A command that is not there is said so, with env's
# status: an agent installed only as an editor extension has no command.
#
# Usage: _agent_vm_lima_run <vm_name> <host_dir> <tty:1|""> <command> [args...]
_agent_vm_lima_run() {
  local vm_name="$1" host_dir="$2" want_tty="$3"
  shift 3
  local shell_opts=(--workdir "$host_dir")
  [[ -n "$want_tty" ]] && shell_opts+=(--tty)
  limactl shell "${shell_opts[@]}" "$vm_name" -- zsh -l -c \
    'case "$1" in *=*) ;; *) command -v -- "$1" >/dev/null || { print -r -- "agent-vm: $1 is not installed in this VM." >&2; exit 127; } ;; esac; exec env -- "$@"' \
    agent-vm "$@"
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
  _agent_vm_reset_term_modes
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
  while IFS= read -r leftover; do
    [[ -n "$leftover" ]] || continue
    echo "Deleting scratch VM '$leftover', left by a run that did not finish..."
    _agent_vm_delete_vm "$leftover"
  done <<< "$(_agent_vm_scratch_leftovers)"
  vm_name="$(_agent_vm_scratch_name "$host_dir")" || return 1
  mkdir -p "$AGENT_VM_STATE_DIR" && printf '%s\n' "$$" > "$(_agent_vm_scratch_marker "$vm_name")" || return 1
  # The caller's: the shell session says the VM goes on exit.
  rm=1
  old_int="$(trap -p INT)"
  trap ':' INT
  if _agent_vm_ensure_running "$vm_name" "$host_dir" ${vm_opts[@]+"${vm_opts[@]}"}; then
    _agent_vm_print_resources "$vm_name"
    "$fn" "$vm_name" "$host_dir" "$@" || st=$?
    _agent_vm_reset_term_modes
    # Asked before the deletion, when it can be (yes by default): a no opens
    # a shell in the VM, to look at what the command left, and asks again on
    # its exit. Only an explicit no keeps it: no terminal, or a question cut
    # short, deletes.
    while _agent_vm_can_ask \
          && [[ "$(_agent_vm_ask_yn "Delete scratch VM '$vm_name'?" Y)" == "0" ]]; do
      echo "A shell in scratch VM '$vm_name'. Type 'exit' to be asked again."
      limactl shell --workdir "$host_dir" "$vm_name" zsh -l
      _agent_vm_reset_term_modes
    done
  else
    st=1
  fi
  echo "Deleting scratch VM '$vm_name'..."
  _agent_vm_delete_vm "$vm_name" || st=1
  trap - INT
  [[ -z "$old_int" ]] || eval "$old_int"
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

# Lima's table of the agent-vm VMs, with the base each was cloned from (see
# _agent_vm_base_label) in a last column. Lima pads every column but its last,
# so the lines are padded here to line it up.
# `list` and `status`: Lima's table of the agent-vm VMs, the current
# directory's marked with >, and the base each was cloned from (see
# _agent_vm_base_label) in a last column. Lima pads every column but its last,
# so the lines are padded here to line it up.
_agent_vm_list() {
  local list line lines=() w=0 header=1 current mark
  current="$(_agent_vm_name "$(pwd)" 2>/dev/null)" || current=""
  if ! list="$(limactl list 2>/dev/null)"; then
    echo "Error: could not query Lima. Is it installed and working?" >&2
    return 1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ ${#lines[@]} -eq 0 || "$line" == agent-vm-* ]]; then
      lines+=("$line")
      [[ ${#line} -gt $w ]] && w=${#line}
    fi
  done <<< "$list"
  if [[ ${#lines[@]} -lt 2 ]]; then
    [[ ${#lines[@]} -eq 0 ]] || printf '  %s\n' "${lines[@]}"
    echo "  (no VMs)"
    return 0
  fi
  for line in "${lines[@]}"; do
    if [[ -n "$header" ]]; then
      header=""
      printf '  %-*s   %s\n' "$w" "$line" "BASE"
    else
      mark=" "
      [[ "${line%% *}" == "$current" ]] && mark=">"
      printf '%s %-*s   %s\n' "$mark" "$w" "$line" "$(_agent_vm_base_label "${line%% *}")"
    fi
  done
}

# When the file is executed (the command `install` puts on PATH, or
# `./agent-vm.sh setup`) rather than sourced, dispatch to the agent-vm
# function so it doesn't silently no-op. BASH_SOURCE[0] differs from $0 when
# sourced.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  agent-vm "$@"
  exit $?
fi

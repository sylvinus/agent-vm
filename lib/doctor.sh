# --- doctor -------------------------------------------------------------------
# Checks the host, Lima, the base template and the current directory, and says
# what to do about each problem. Read-only: it never creates, starts or stops
# a VM, so it is safe to run first and to paste into an issue (no secret
# values, only names). Exit 1 when a check failed, 0 otherwise.

# Octal mode of <file> (e.g. 600), without file-type bits. Prints nothing
# and returns 1 when it cannot be read. GNU stat first, BSD/macOS second;
# both are probed rather than assumed from uname, so a PATH with only one
# of them still works.
_agent_vm_file_mode() {
  local mode
  mode="$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" || return 1
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  printf '%s\n' "$mode"
}

# 0 when no group/other permission bit is set on <file> (600, 400 and 700
# all count as private). 1 when group/other can read, write or execute it.
# 2 when the mode could not be read: never claim "private" from missing
# information, and never claim "exposed" from a failed stat either.
_agent_vm_file_is_private() {
  local mode
  if ! mode="$(_agent_vm_file_mode "$1")"; then
    return 2
  fi
  # 8# for base-8: $mode may carry a leading zero.
  (( 8#$mode & 8#77 )) && return 1
  return 0
}

_agent_vm_doctor_line() {
  # <ok|warn|fail|info> <message> [hint...]
  local level="$1" msg="$2"
  shift 2
  case "$level" in
    ok)   printf '  ok    %s\n' "$msg" ;;
    warn) printf '  warn  %s\n' "$msg"; AGENT_VM_DOCTOR_WARN=$((AGENT_VM_DOCTOR_WARN + 1)) ;;
    fail) printf '  FAIL  %s\n' "$msg"; AGENT_VM_DOCTOR_FAIL=$((AGENT_VM_DOCTOR_FAIL + 1)) ;;
    *)    printf '  -     %s\n' "$msg" ;;
  esac
  while [[ $# -gt 0 ]]; do
    printf '        %s\n' "$1"
    shift
  done
}

_agent_vm_doctor() {
  # Local, and still visible to _agent_vm_doctor_line: bash scopes locals
  # dynamically, so the helper updates these and nothing leaks.
  local AGENT_VM_DOCTOR_WARN=0 AGENT_VM_DOCTOR_FAIL=0
  local d=_agent_vm_doctor_line

  echo "agent-vm doctor"
  echo ""
  echo "agent-vm"
  $d info "version $AGENT_VM_VERSION, from $AGENT_VM_SCRIPT_DIR"
  if [[ ! -r "$AGENT_VM_SCRIPT_DIR/agent-vm.setup.sh" ]]; then
    $d fail "agent-vm.setup.sh is missing next to agent-vm.sh" \
      "'agent-vm setup' needs it. Reinstall, or run agent-vm from its clone."
  fi
  if _agent_vm_sha256 </dev/null >/dev/null 2>&1; then
    $d ok "SHA-256 tool available (VM names)"
  else
    $d fail "neither shasum nor sha256sum is installed" \
      "VM names hash the project path. Install perl (shasum) or coreutils (sha256sum)."
  fi
  if ! command -v perl >/dev/null 2>&1; then
    $d warn "perl is not installed: 'agent-vm project-env' and relative destinations in ~/.agent-vm/volumes need it" \
      "They use files in the project without following symlinks, which the shell cannot do."
  fi

  echo ""
  echo "Host"
  $d info "$(uname -sm)"
  local cpus mem free_gib
  cpus="$(_agent_vm_host_cpus)"
  mem="$(_agent_vm_host_mem_gib)"
  if [[ -n "$cpus" && -n "$mem" ]]; then
    $d info "${cpus} CPUs, ${mem} GiB RAM; a VM gets at most $(_agent_vm_host_share "$cpus" 1) CPUs and $(_agent_vm_host_share "$mem" 2) GiB (AGENT_VM_HOST_SHARE=$AGENT_VM_HOST_SHARE)"
  else
    $d warn "could not read the host's CPU or RAM: --cpus and --memory are not clamped"
  fi
  if ! free_gib="$(_agent_vm_free_gib)"; then
    $d warn "could not read the free disk space"
  elif [[ "$free_gib" -lt 10 ]]; then
    $d warn "$free_gib GiB free for Lima's VMs" "A default VM disk is 10 GiB (sparse)."
  else
    $d ok "$free_gib GiB free for Lima's VMs"
  fi

  echo ""
  echo "Lima"
  local have_lima="" protects_git=""
  if [[ -n "$(_agent_vm_limactl_path)" ]]; then
    have_lima=1
    local lima_ver
    lima_ver="$(limactl --version 2>/dev/null)"
    lima_ver="${lima_ver##* }"
    if [[ -z "$lima_ver" ]]; then
      $d warn "limactl is installed but did not report a version"
    elif ! _agent_vm_ver_ge "$lima_ver" 1.0.0; then
      $d warn "Lima $lima_ver is older than 1.0" \
        "Before 1.0 the default mount type can be reverse-sshfs, where --readonly is refused."
    else
      $d ok "Lima $lima_ver"
    fi
    local lima_st=0
    _agent_vm_lima_protects_git || lima_st=$?
    case "$lima_st" in
      0)
        _agent_vm_writable_git_optout || protects_git=1
        $d ok "Lima keeps every .git read-only for the VMs (sshfs.readonlyNames)" ;;
      1)
        $d warn "this Lima cannot keep .git read-only for the VMs, so a start with writable shares asks first"
        # Where a start would ask about it: Windows, Lima's config, or this
        # directory's VM if Lima made it before 1.0 (else the base's).
        if _agent_vm_unprotected_mount_is_sshfs "$(_agent_vm_name "$(pwd)" 2>/dev/null)"; then
          $d warn "it cannot keep the VMs to their shares either"
          _agent_vm_sshfs_exposure_note | _agent_vm_wrap 70 | sed 's/^/        /'
        fi
        _agent_vm_git_protection_hint | _agent_vm_wrap 70 | sed 's/^/        /' ;;
      *)
        $d fail "cannot tell whether this Lima keeps .git read-only: 'limactl validate' gave no answer agent-vm knows" \
          "A start with writable shares stops until it can tell. Check that 'limactl validate' works." ;;
    esac
    if _agent_vm_writable_git_optout; then
      $d warn "AGENT_VM_UNSAFE_WRITABLE_GIT=1: the VMs can write .git, and git on this machine runs what .git/config and hooks name" \
        "Unset it to keep .git read-only."
    fi
  else
    $d fail "Lima is not installed" "Install it from https://lima-vm.io/docs/installation/ (or 'brew install $AGENT_VM_LIMA_FORMULA')."
  fi
  if [[ "$(uname -s)" == "Linux" ]]; then
    local prereq_out
    if prereq_out="$(_agent_vm_check_linux_prereqs 2>&1)"; then
      $d ok "QEMU and /dev/kvm are usable"
    else
      $d fail "QEMU or KVM is not usable"
      printf '%s\n' "$prereq_out" | sed 's/^/        /'
    fi
  fi
  if _agent_vm_on_windows; then
    local win_prereq_out
    if win_prereq_out="$(_agent_vm_check_windows_prereqs 2>&1)"; then
      $d ok "QEMU is installed"
    else
      $d fail "QEMU is not usable"
      printf '%s\n' "$win_prereq_out" | sed 's/^/        /'
    fi
    $d info "QEMU also needs the 'Windows Hypervisor Platform' feature, which only an administrator can check or turn on" \
      "Without it, VMs fail to start with a WHPX error. An administrator runs, once, then reboots:" \
      "$AGENT_VM_WHPX_ON"
  fi

  # A bare repository is not named .git, so readonlyNames does not cover one
  # the VM plants in a project (see _agent_vm_bare_repo_state).
  local bare_state
  bare_state="$(_agent_vm_bare_repo_state)"
  if [[ "$bare_state" != "nogit" ]]; then
    echo ""
    echo "Git on this machine"
    case "$bare_state" in
      ok) $d ok "safe.bareRepository = explicit" ;;
      old) $d warn "$(git --version) is older than 2.38: it would use a repository a VM creates under another name than .git, and run what its config names" \
             "Upgrade git, then: git config --global safe.bareRepository explicit" ;;
      *) $d warn "safe.bareRepository is not 'explicit': git would use a repository a VM creates under another name than .git, and run what its config names" \
           "git config --global safe.bareRepository explicit" ;;
    esac
  fi

  echo ""
  echo "Base template"
  local st=0
  if [[ -z "$have_lima" ]]; then
    $d info "not checked (see above)"
  else
    _agent_vm_base_exists || st=$?
    case "$st" in
      0)
        local built
        built="$(cat "$AGENT_VM_STATE_DIR/.agent-vm-base-version" 2>/dev/null)"
        if [[ "$built" =~ ^[0-9]+$ ]]; then
          $d ok "$AGENT_VM_TEMPLATE is ready, built $(_agent_vm_epoch_date "$built" +%F)"
          if [[ $(( ($(date +%s) - built) / 86400 )) -gt 90 ]]; then
            $d warn "the base template is over 90 days old" \
              "Its agents and packages are as old. 'agent-vm setup' rebuilds it."
          fi
        else
          $d ok "$AGENT_VM_TEMPLATE is ready"
        fi
        # 0.1.0 support, to be removed with _agent_vm_migrate_0_1.
        if [[ ! -f "$AGENT_VM_STATE_DIR/.agent-vm-base-built-by" ]]; then
          $d warn "the base template was built by agent-vm 0.1.0, without the sshfs of the shares that keep .git read-only: each VM made from it boots once more to install it" \
            "'agent-vm setup' rebuilds it, then '--reset' the VMs made from it."
        fi ;;
      1)
        if _agent_vm_exists "$AGENT_VM_TEMPLATE"; then
          $d fail "$AGENT_VM_TEMPLATE exists but its setup did not complete" "Run 'agent-vm setup' again."
        else
          $d fail "no base template yet" "Run 'agent-vm setup'."
        fi ;;
      *) $d warn "could not query Lima" ;;
    esac
  fi

  echo ""
  echo "Settings ($AGENT_VM_STATE_DIR)"
  local f
  if [[ -f "$AGENT_VM_STATE_DIR/env" ]]; then
    local env_mode
    # Git Bash emulates permission bits (chmod 600 reads back as 644): the
    # file's ACL is what protects it there, and it cannot be read from here.
    if _agent_vm_on_windows; then
      $d info "env: $(_agent_vm_env env "$AGENT_VM_STATE_DIR/env" "" list | wc -l | tr -d ' ') key(s)"
    elif env_mode="$(_agent_vm_file_mode "$AGENT_VM_STATE_DIR/env")" \
       && _agent_vm_file_is_private "$AGENT_VM_STATE_DIR/env"; then
      $d ok "env: $(_agent_vm_env env "$AGENT_VM_STATE_DIR/env" "" list | wc -l | tr -d ' ') key(s), private to you (mode $env_mode)"
    elif [[ -n "$env_mode" ]]; then
      $d warn "env is readable by other users on this machine (mode $env_mode)" "chmod 600 '$AGENT_VM_STATE_DIR/env'"
    else
      $d warn "env permissions could not be checked" "chmod 600 '$AGENT_VM_STATE_DIR/env'"
    fi
  else
    $d info "env: none (agent-vm env set KEY VALUE)"
  fi
  for f in volumes setup.sh runtime.sh; do
    [[ -f "$AGENT_VM_STATE_DIR/$f" ]] && $d info "$f: present"
  done

  echo ""
  local host_dir vm_name vm_exists="" ro_names=""
  host_dir="$(pwd)"
  [[ -n "$protects_git" ]] && ro_names="$(_agent_vm_readonly_names "$host_dir")"
  echo "This directory ($host_dir)"
  local bad
  if bad="$(_agent_vm_unmountable_path "$host_dir")"; then
    $d fail "the path $bad" "agent-vm refuses to mount it. Rename the directory."
  fi
  local unsafe
  if unsafe="$(_agent_vm_unsafe_project "$host_dir")"; then
    $d fail "this directory $unsafe" \
      "agent-vm refuses to share it with a VM. Run it from a project directory."
  fi
  if vm_name="$(_agent_vm_name "$host_dir" 2>/dev/null)"; then
    if [[ -z "$have_lima" ]]; then
      $d info "VM name: $vm_name"
    else
      st=0
      _agent_vm_exists "$vm_name" || st=$?
      case "$st" in
        0)
          vm_exists=1
          if [[ "$(_agent_vm_stale_state "$vm_name")" == "1" ]]; then
            $d warn "$vm_name was cloned from an older base template" "'agent-vm --reset <command>' re-clones it."
          else
            $d ok "$vm_name exists"
          fi
          if _agent_vm_running "$vm_name"; then
            local mst=0
            _agent_vm_mount_is_host_enforced "$vm_name" || mst=$?
            case "$mst" in
              0) $d ok "running; the project share is enforced on the host (--readonly works)" ;;
              1) $d warn "running; the host does not enforce read-only on the project share, so --readonly is refused" \
                   "Use virtiofs on vz or 9p on QEMU, then --reset." ;;
              *) $d warn "running, but the project mount type could not be read" ;;
            esac
          else
            $d info "stopped"
          fi
          # What the VM was given, which may predate the Lima installed now:
          # the next start brings it in line (see _agent_vm_ensure_running).
          if [[ -n "$protects_git" ]] && _agent_vm_mounts_protect_git "$vm_name" \
             && ! _agent_vm_mounts_have_readonly_names "$vm_name" "$ro_names"; then
            $d warn "its shares keep .git read-only, but not all of $(_agent_vm_names_text "$ro_names")" \
              "The next start (after 'agent-vm stop' if it runs) fixes that."
          elif _agent_vm_mounts_protect_git "$vm_name"; then
            $d ok "its shares keep every .git read-only"
          elif _agent_vm_writable_git_optout; then
            $d warn "its shares leave .git writable (AGENT_VM_UNSAFE_WRITABLE_GIT=1)"
          else
            $d warn "its shares leave .git writable" \
              "With a Lima that can protect it, the next start (after 'agent-vm stop' if it runs) fixes that."
          fi ;;
        1) $d info "$vm_name will be created on the first agent-vm command here" ;;
        *) $d warn "could not query Lima" ;;
      esac
    fi
  fi
  # Hooks folders the VM can write, and git on this machine runs (see
  # _agent_vm_project_hooks), in this project and the repositories below it.
  local hooks_rel hooks_in hooks_name hooks_what
  while IFS=$'\t' read -r hooks_rel hooks_in; do
    [[ -n "$hooks_rel" ]] || continue
    hooks_what="git runs hooks from $hooks_rel (core.hooksPath)"
    [[ "$hooks_rel" == . ]] && hooks_what="git runs hooks from the project directory itself (core.hooksPath)"
    if ! hooks_name="$(_agent_vm_hooks_name "$hooks_in")"; then
      $d warn "$hooks_what, which the VM can write" \
        "agent-vm can only keep a folder of the project read-only, by a name without quotes or backslashes: point core.hooksPath to one."
    elif [[ -z "$protects_git" ]]; then
      $d warn "$hooks_what, which the VM can write" \
        "agent-vm keeps it read-only when it keeps .git read-only (see above)."
    elif [[ -z "$vm_exists" ]]; then
      $d info "$hooks_what: every '$hooks_name' in the project will be read-only for the VM"
    elif _agent_vm_mounts_have_readonly_names "$vm_name" "$ro_names"; then
      $d ok "$hooks_what: every '$hooks_name' in the project is read-only for the VM"
    else
      $d warn "$hooks_what, which the VM can still write" \
        "The next start (after 'agent-vm stop' if it runs) makes every '$hooks_name' in the project read-only."
    fi
  done <<< "$(_agent_vm_project_hooks "$host_dir")"
  # Git config the VM can write, or commands it names in the project (see
  # _agent_vm_repo_config_risks).
  local git_risks
  git_risks="$(_agent_vm_project_config_risks "$host_dir")"
  if [[ -n "$git_risks" ]]; then
    $d warn "git on this machine uses these, and the VM can write them:"
    printf '%s\n' "$git_risks" | sed 's/^/        /'
    printf '        %s\n' "Move them out of the project, or have them name commands outside it."
  fi
  local runtime runtime_text runtime_rel project_env
  runtime="$(_agent_vm_project_runtime_path "$host_dir")"
  if runtime_rel="$(_agent_vm_project_rel "$host_dir" "$runtime")"; then
    # Not by its path: the VM can make it a symlink (see _agent_vm_project_rel).
    if runtime_text="$(_agent_vm_nofollow read "$host_dir" "$runtime_rel" 2>/dev/null && printf x)"; then
      $d info "project runtime: $runtime ($(printf '%s' "${runtime_text%x}" | awk "$_AGENT_VM_SHEBANG_AWK"))"
    fi
  elif [[ -f "$runtime" ]]; then
    $d info "project runtime: $runtime ($(_agent_vm_runtime_interpreter "$runtime"))"
  fi
  project_env="$(_agent_vm_project_env_file "$host_dir")"
  if [[ -f "$project_env" ]]; then
    local unignored
    unignored="$(_agent_vm_warn_unignored "$project_env" 2>&1)"
    if [[ -n "$unignored" ]]; then
      $d warn "project env: $project_env"
      printf '%s\n' "$unignored" | sed 's/^ */        /'
    else
      $d ok "project env: $project_env"
    fi
  fi

  if [[ -n "$have_lima" ]]; then
    # VMs persist and each is clamped on its own, so several running at once
    # can promise more than the host has.
    local all name vstatus vcpus vmem run_n=0 run_cpus=0 run_mem=0
    all="$(limactl list --format '{{.Name}}|{{.Status}}|{{.CPUs}}|{{.Memory}}' 2>/dev/null || true)"
    while IFS='|' read -r name vstatus vcpus vmem; do
      case "$name" in agent-vm-*) ;; *) continue ;; esac
      [[ "$vstatus" == "Running" ]] || continue
      run_n=$((run_n + 1))
      run_cpus=$((run_cpus + ${vcpus:-0}))
      run_mem=$((run_mem + ${vmem:-0} / 1073741824))
    done <<< "$all"
    echo ""
    echo "All VMs"
    if [[ "$run_n" -eq 0 ]]; then
      $d info "none running"
    elif [[ -n "$mem" && "$run_mem" -gt "$mem" ]]; then
      $d warn "$run_n running, ${run_cpus} CPUs and ${run_mem} GiB in total: more memory than the host has" \
        "'agent-vm list' lists them; 'agent-vm stop <name>' frees one."
    else
      $d info "$run_n running, ${run_cpus} CPUs and ${run_mem} GiB in total"
    fi
    local leftover
    while IFS= read -r leftover; do
      [[ -n "$leftover" ]] || continue
      $d warn "scratch VM $leftover was left by a run that did not finish" \
        "The next --scratch run deletes it, or: agent-vm rm $leftover"
    done <<< "$(_agent_vm_scratch_leftovers)"
  fi

  echo ""
  if [[ "$AGENT_VM_DOCTOR_FAIL" -gt 0 ]]; then
    echo "$AGENT_VM_DOCTOR_FAIL problem(s), $AGENT_VM_DOCTOR_WARN warning(s)."
    return 1
  fi
  echo "No problems found, $AGENT_VM_DOCTOR_WARN warning(s)."
}

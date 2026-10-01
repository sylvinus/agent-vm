# --- version and info: what integrators read ----------------------------------
# _agent_vm_ver_ge <a> <b>: status 0 when version a >= b. Components compare
# one by one as base-10 numbers: a string comparison gets "1.10.0" < "1.9.0"
# wrong, and "08" must not be read as octal. Missing components count as 0, a
# "-rc1" suffix is ignored. Compared as digit strings, leading zeros dropped,
# the longer the larger: shell arithmetic overflows past 19 digits.
_agent_vm_ver_ge() {
  local a="${1%%-*}" b="${2%%-*}" x y
  while [[ -n "$a" || -n "$b" ]]; do
    x="${a%%.*}"; y="${b%%.*}"
    if [[ "$a" == *.* ]]; then a="${a#*.}"; else a=""; fi
    if [[ "$b" == *.* ]]; then b="${b#*.}"; else b=""; fi
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    x="${x#"${x%%[!0]*}"}"; y="${y#"${y%%[!0]*}"}"
    [[ "${#x}" -gt "${#y}" ]] && return 0
    [[ "${#x}" -lt "${#y}" ]] && return 1
    [[ "$x" > "$y" ]] && return 0
    [[ "$x" < "$y" ]] && return 1
  done
  return 0
}

# How this copy of agent-vm is updated: a git clone, a Homebrew keg, or a
# release put there by www.agent-vm.org/install.sh. The installer's --dir
# goes with it when this copy is not in the installer's default directory:
# without it, the update lands next to this one and this one stays old.
_agent_vm_update_command() {
  local default="${XDG_DATA_HOME:-$HOME/.local/share}/agent-vm"
  # Physical, as AGENT_VM_SCRIPT_DIR is.
  default="$(CDPATH= cd -P -- "$default" 2>/dev/null && pwd)" || default=""
  if [[ -e "$AGENT_VM_SCRIPT_DIR/.git" ]]; then
    printf "git -C '%s' pull\n" "$(_agent_vm_sq_escape "$AGENT_VM_SCRIPT_DIR")"
  elif [[ "$AGENT_VM_SCRIPT_DIR" == */Cellar/agent-vm/* ]]; then
    echo "brew upgrade agent-vm"
  elif [[ "$AGENT_VM_SCRIPT_DIR" == "$default" ]]; then
    echo "curl -fsSL https://www.agent-vm.org/install.sh | sh"
  else
    printf "curl -fsSL https://www.agent-vm.org/install.sh | sh -s -- --dir '%s'\n" \
      "$(_agent_vm_sq_escape "$AGENT_VM_SCRIPT_DIR")"
  fi
}

# `version` prints the version. `version --min X.Y.Z` turns it into a check an
# integrator can put in front of everything else: silent with status 0 when
# this engine is recent enough, one actionable line on stderr and status 1
# when it is not.
#
# Status 2 is reserved for a malformed call. A typo in the required version
# must not read as "engine too old" and send a user chasing an upgrade they
# don't need.
#
# Known limit, and the reason this can't be the only check an integrator has:
# an engine older than the one that introduced --min ignores the flag, prints
# its version and exits 0. A tool whose floor is below that version still
# needs its own comparison for the bootstrap check.
_agent_vm_version() {
  if [[ $# -eq 0 ]]; then
    echo "$AGENT_VM_VERSION"
    return 0
  fi

  local want=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --min)
        if [[ $# -lt 2 ]]; then
          echo "Error: --min needs a version (e.g. --min 0.2.0)" >&2
          return 2
        fi
        want="$2"; shift 2 ;;
      --min=*)
        want="${1#*=}"; shift ;;
      *)
        echo "Error: unknown option for version: $1" >&2
        return 2 ;;
    esac
  done

  if [[ ! "$want" =~ ^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9.]+)?$ ]]; then
    echo "Error: --min expects a version like 1.2.3 (got: '$want')" >&2
    return 2
  fi

  _agent_vm_ver_ge "$AGENT_VM_VERSION" "$want" && return 0

  echo "Error: agent-vm $AGENT_VM_VERSION is older than the required $want." >&2
  echo "  Update it:  $(_agent_vm_update_command)" >&2
  return 1
}

# Machine-readable state, one key=value per line. This is the supported way for
# another tool to ask what agent-vm knows, instead of reverse-engineering VM
# naming, the template name, or the state-dir version markers, all of which
# are internal and free to change.
#
# Keys: version, template, state_dir, project_env, dir, vm_name, base_exists,
# vm_exists, vm_running, vm_stale, ssh_host, ssh_config, git_protected,
# security_questions. Booleans are 1/0; anything that cannot be determined is
# "unknown" rather than a guess.
#
# git_protected: whether a start keeps .git read-only for the VM (see
# _agent_vm_lima_protects_git and the --unsafe-writable-git opt-out).
# security_questions: what a start with writable shares of a stopped VM would
# stop on unless answered yes (see _agent_vm_confirm_unsafe), comma-separated,
# or "none": lima (this Lima cannot keep .git read-only), lima-unknown (it
# cannot tell, which stops the start with an error), hooks (a hooks folder that
# cannot be protected), git-config (git config or commands in the project),
# bare-repo (safe.bareRepository). A script with no terminal passes
# --unsafe-disable-security-prompts to accept them, or --readonly.
#
# ssh_host is the Host alias in ssh_config, the file Lima rewrites with the
# current port on each start (https://www.agent-vm.org/#connect-an-ide-over-ssh).
_agent_vm_info() {
  local dir="${1:-$(pwd)}"
  local vm_name
  vm_name="$(_agent_vm_name "$dir")" || return 1

  echo "version=$AGENT_VM_VERSION"
  echo "template=$AGENT_VM_TEMPLATE"
  echo "state_dir=$AGENT_VM_STATE_DIR"
  echo "project_env=$(_agent_vm_project_env_file "$dir")"
  echo "dir=$dir"
  echo "vm_name=$vm_name"

  if [[ -z "$(_agent_vm_limactl_path)" ]]; then
    # Still useful without Lima: the static keys above answer "what would this
    # VM be called", which is all a caller needs before setup has ever run.
    echo "base_exists=unknown"
    echo "vm_exists=unknown"
    echo "vm_running=unknown"
    echo "vm_stale=unknown"
    echo "ssh_host=lima-$vm_name"
    echo "ssh_config=unknown"
    echo "git_protected=unknown"
    echo "security_questions=unknown"
    return 0
  fi

  # Keep the three-way answer from the query helpers: a failed query reports
  # `unknown`, never a confident 0. A caller told `base_exists=0` when the truth
  # was "could not ask" would offer to build a base VM that already exists.
  local base_exists vm_exists vm_running
  _agent_vm_base_exists;        base_exists="$(_agent_vm_tristate $?)"
  _agent_vm_exists "$vm_name";  vm_exists="$(_agent_vm_tristate $?)"
  _agent_vm_running "$vm_name"; vm_running="$(_agent_vm_tristate $?)"
  echo "base_exists=$base_exists"
  echo "vm_exists=$vm_exists"
  echo "vm_running=$vm_running"
  # Staleness compares this VM against the base it was cloned from; with no VM
  # (or no way to tell) there is nothing to compare.
  if [[ "$vm_exists" == "1" ]]; then
    echo "vm_stale=$(_agent_vm_stale_state "$vm_name")"
  else
    echo "vm_stale=unknown"
  fi
  # Lima names the alias after the instance ("lima-" and the name, whose dots
  # and underscores become dashes: agent-vm names have neither).
  echo "ssh_host=lima-$vm_name"
  local ssh_config=""
  [[ "$vm_exists" == "1" ]] \
    && ssh_config="$(limactl list "$vm_name" --format '{{.SSHConfigFile}}' 2>/dev/null)"
  echo "ssh_config=${ssh_config:-unknown}"

  local lima_st=0 protected questions="" rel in_repo
  _agent_vm_lima_protects_git || lima_st=$?
  if _agent_vm_writable_git_optout; then
    protected=0
    # The opt-out leaves .git, not the rest of the disk: still asked there.
    _agent_vm_unprotected_mount_is_sshfs "$vm_name" && questions="lima"
  else
    case "$lima_st" in
      0) protected=1 ;;
      1) protected=0; questions="lima" ;;
      *) protected=unknown; questions="lima-unknown" ;;
    esac
  fi
  if [[ "$protected" == 1 ]]; then
    while IFS=$'\t' read -r rel in_repo; do
      [[ -n "$rel" ]] || continue
      if ! _agent_vm_hooks_name "$in_repo" >/dev/null; then
        questions="${questions:+$questions,}hooks"
        break
      fi
    done <<< "$(_agent_vm_project_hooks "$dir")"
    [[ -z "$(_agent_vm_project_config_risks "$dir")" ]] || questions="${questions:+$questions,}git-config"
  fi
  case "$(_agent_vm_bare_repo_state)" in
    unset|old) questions="${questions:+$questions,}bare-repo" ;;
  esac
  echo "git_protected=$protected"
  echo "security_questions=${questions:-none}"
}

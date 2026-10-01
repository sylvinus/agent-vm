# --- options: agent-vm's own, for the commands that start a VM ----------------

# Validate a positive-integer arg from the CLI (no retry: fail fast).
_agent_vm_validate_int() {
  local name="$1" val="$2"
  if [[ ! "$val" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: $name must be a positive integer (got: '$val')" >&2
    return 1
  fi
}

# --ssh-port: 0 gives the port back to Lima (a new one on each start). Below
# 1024 the host agent, which runs as the user, could not bind it.
_agent_vm_validate_port() {
  local val="${1:-}"
  if [[ "$val" == 0 ]] || { [[ "$val" =~ ^[1-9][0-9]*$ ]] && (( val >= 1024 && val <= 65535 )); }; then
    return 0
  fi
  echo "Error: --ssh-port must be 0 or a port from 1024 to 65535 (got: '$val')" >&2
  return 1
}

# Reads the option at the start of "$@", if it is one of agent-vm's, and sets
# in the caller's scope (bash scopes locals dynamically):
#   taken    the number of words it used, 0 when "$1" is not an option
#   vm_opts  the option appended, as _agent_vm_ensure_running takes it
#   rm       1 for --rm
# Values are checked here, so a typo like `--disk 10G` is one clear error and
# not a bash diagnostic later on. Returns 1 when a value is missing or wrong.
_agent_vm_take_opt() {
  local opt="$1" val
  taken=0
  case "$opt" in
    --disk|--memory|--ram|--cpus|--ssh-port)
      if [[ $# -lt 2 ]]; then
        echo "Error: $opt needs a value." >&2
        return 1
      fi
      val="$2"; taken=2 ;;
    --disk=*|--memory=*|--ram=*|--cpus=*|--ssh-port=*)
      val="${opt#*=}"; opt="${opt%%=*}"; taken=1 ;;
    --reset|--readonly|--scratch)
      vm_opts+=("$opt"); taken=1; return 0 ;;
    --unsafe-writable-git|--unsafe-writable-git=1)
      vm_opts+=(--unsafe-writable-git); taken=1; return 0 ;;
    --unsafe-disable-security-prompts)
      vm_opts+=(--unsafe-disable-security-prompts); taken=1; return 0 ;;
    --rm)
      rm=1; taken=1; return 0 ;;
    *)
      return 0 ;;
  esac
  [[ "$opt" == --ram ]] && opt=--memory
  if [[ "$opt" == --ssh-port ]]; then
    _agent_vm_validate_port "$val" || return 1
  else
    _agent_vm_validate_int "$opt" "$val" || return 1
  fi
  vm_opts+=("$opt" "$val")
}

# Splits "$@" into agent-vm's options (see _agent_vm_take_opt) and the
# command's own words, set as args in the caller's scope. Options are only read
# before the command: from the first other word on, everything belongs to it,
# so `run docker run --rm x` keeps its --rm. `--` ends the options, and --tty
# sets tty=1.
_agent_vm_split_args() {
  local taken
  while [[ $# -gt 0 ]]; do
    _agent_vm_take_opt "$@" || return 1
    if [[ $taken -gt 0 ]]; then
      shift "$taken"
      continue
    fi
    case "$1" in
      --tty) tty=1; shift ;;
      --)    shift; break ;;
      *)     break ;;
    esac
  done
  args=("$@")
}

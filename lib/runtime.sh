# --- runtime scripts ----------------------------------------------------------
# Interpreter a runtime script asks for, read from its shebang: bash, sh or
# zsh. Anything else — another language, or no shebang at all — falls back to
# zsh, which is what every runtime script got before this existed.
#
# Only shells are honoured because the script is fed on stdin, and `-s` (read
# the program from stdin) is a shell convention. A python runtime piped into
# zsh was already broken; it stays broken, loudly, rather than being executed
# by the wrong thing in a new way.
_agent_vm_runtime_interpreter() {
  local first rest w
  IFS= read -r first < "$1" || true
  # A file saved with CRLF (Windows editors) ends its shebang with a CR.
  first="${first%$'\r'}"
  case "$first" in
    '#!'*) ;;
    *) printf 'zsh\n'; return 0 ;;
  esac
  # The program is the first word: "#!/bin/bash -e". Through env, the first
  # word after env's own options and VAR=value assignments:
  # "#!/usr/bin/env -S bash -e".
  rest="${first#??}"
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    w="${rest%%[[:space:]]*}"
    rest="${rest#"$w"}"
    case "$w" in
      */env|env|-*|*=*) [[ -n "$rest" ]] && continue ;;
    esac
    break
  done
  case "${w##*/}" in
    bash) printf 'bash\n' ;;
    sh)   printf 'sh\n' ;;
    *)    printf 'zsh\n' ;;
  esac
}

# Where this project's runtime script lives.
#
# AGENT_VM_PROJECT_RUNTIME lets an integrator keep it in its own directory
# (".mytool/runtime.sh") instead of cluttering the project root. A relative
# path is resolved against the project directory; an absolute one is used
# as-is. Unset, the historical location applies, so nothing changes for anyone
# who never heard of the variable.
_agent_vm_project_runtime_path() {
  local host_dir="$1" rel="${AGENT_VM_PROJECT_RUNTIME:-.agent-vm.runtime.sh}"
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s\n' "${host_dir}/${rel}" ;;
  esac
}

# Run a runtime script inside the VM, with the interpreter it declares.
#
# It goes through a login zsh first, so the script sees the VM's PATH and the
# auto-sourced ~/.agent-vm.env, then execs the declared shell. Before this,
# every runtime ran under zsh whatever its shebang said: a script starting
# with `#!/usr/bin/env bash` silently got zsh's arrays and globbing, which
# differ where it matters.
#
# The script is still piped rather than executed by path: the per-user runtime
# lives in ~/.agent-vm on the host and is not mounted inside the VM, so its
# path means nothing there. One transport for both runtimes beats two.
#
# Line-ending CRs are dropped on the way: Git for Windows checks files out
# with CRLF by default, and the shells in the VM read the CR as part of each
# command.
_agent_vm_run_runtime() {
  local vm_name="$1" host_dir="$2" file="$3" interp
  interp="$(_agent_vm_runtime_interpreter "$file")"
  _agent_vm_strip_cr < "$file" \
    | limactl shell --workdir "$host_dir" "$vm_name" zsh -lc "exec $interp -s"
}

# stdin to stdout without a CR at the end of each line.
_agent_vm_strip_cr() {
  awk '{ sub(/\r$/, ""); print }'
}

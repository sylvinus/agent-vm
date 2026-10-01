# --- runtime scripts ----------------------------------------------------------
# Interpreter a runtime script asks for, read from its shebang: bash, sh or
# zsh. Anything else — another language, or no shebang at all — falls back to
# zsh, which is what every runtime script got before this existed.
#
# Only shells are honoured because the script is fed on stdin, and `-s` (read
# the program from stdin) is a shell convention. A python runtime piped into
# zsh was already broken; it stays broken, loudly, rather than being executed
# by the wrong thing in a new way.
#
# An awk program, so the VM runs the same one on a project's runtime script,
# which only the VM reads (see _agent_vm_run_project_runtime). The program is
# the first word of the shebang ("#!/bin/bash -e") or, through env, the first
# word after env's own options and VAR=value assignments
# ("#!/usr/bin/env -S bash -e"). A CRLF file ends its shebang with a CR.
_AGENT_VM_SHEBANG_AWK='
  NR == 1 {
    sub(/\r$/, "")
    if (substr($0, 1, 2) == "#!") {
      n = split(substr($0, 3), w)
      for (i = 1; i < n; i++)
        if (w[i] != "env" && w[i] !~ /\/env$/ && w[i] !~ /^-/ && w[i] !~ /=/) break
      p = w[i]
      sub(/.*\//, "", p)
    }
    exit
  }
  END { print ((p == "bash" || p == "sh") ? p : "zsh") }
'
_agent_vm_runtime_interpreter() {
  awk "$_AGENT_VM_SHEBANG_AWK" "$1"
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
    /*) _agent_vm_path_join / "$rel" ;;
    *)  _agent_vm_path_join "$host_dir" "$rel" ;;
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
# This one pipes a script the host reads: the per-user runtime lives in
# ~/.agent-vm on the host and is not mounted inside the VM, so its path means
# nothing there. A project's runtime is the other way round, see
# _agent_vm_run_project_runtime.
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

# A runtime script inside the project, run the same way but read by the VM, by
# its path: the host never reads it. The VM can make it a symlink, which on the
# host would lead to any file of the user's, and the content would go to the
# VM. In the VM, it resolves among the VM's own files. A script that is not
# there (any more) is skipped.
_agent_vm_run_project_runtime() {
  local vm_name="$1" host_dir="$2" file="$3"
  limactl shell --workdir "$host_dir" "$vm_name" zsh -lc \
    '[ -f "$3" ] || exit 0; i="$(awk "$1" "$3")" && awk "$2" "$3" | "$i" -s' \
    agent-vm "$_AGENT_VM_SHEBANG_AWK" '{ sub(/\r$/, ""); print }' "$file"
}

# stdin to stdout without a CR at the end of each line.
_agent_vm_strip_cr() {
  awk '{ sub(/\r$/, ""); print }'
}

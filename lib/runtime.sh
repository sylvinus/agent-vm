# --- runtime scripts ----------------------------------------------------------
# Interpreter a runtime script asks for, read from its shebang: bash or sh,
# zsh otherwise. Only shells: the script is fed on stdin, read with -s. The
# program is the shebang's first word ("#!/bin/bash -e"), or after env, its
# options and assignments ("#!/usr/bin/env -S bash -e"). An awk program, so
# the VM runs the same one on a project's script, which only it reads (see
# _agent_vm_run_project_runtime).
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

# This project's runtime script (see _agent_vm_project_path).
_agent_vm_project_runtime_path() {
  _agent_vm_project_path "$1" "${AGENT_VM_PROJECT_RUNTIME:-.agent-vm.runtime.sh}"
}

# Run a runtime script the host reads (~/.agent-vm/runtime.sh, or a project's
# kept outside it) in the VM, piped in, CRs dropped (Git for Windows checks
# out CRLF), under the shell it declares, from a login zsh: the VM's PATH and
# ~/.agent-vm.env apply.
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

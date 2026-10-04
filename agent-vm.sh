#!/usr/bin/env bash
#
# Runs agent-vm: in a release, the binary next to this script; in a clone,
# the one `make` builds, built first when missing or when HEAD moved (a git
# pull). `agent-vm.sh install` links the binary onto the PATH; the curl
# installer runs it so.
#
# What 0.2 left behind keeps working through it: a link to this file on the
# PATH (0.2's install), and a shell rc that sources it (0.1 and 0.2), which
# gets an agent-vm function running it.

# Sourced: nothing below runs in the user's shell, where set -e or exec would
# end it.
if [ -n "${ZSH_VERSION:-}" ]; then
  case "${ZSH_EVAL_CONTEXT:-}" in
    *:file*)
      eval '_agent_vm_sh=${(%):-%x}'
      _agent_vm_sh="$(cd -P -- "$(dirname -- "$_agent_vm_sh")" >/dev/null && pwd)/$(basename -- "$_agent_vm_sh")"
      agent-vm() { bash "$_agent_vm_sh" "$@"; }
      return 0 ;;
  esac
elif [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  _agent_vm_sh="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
  agent-vm() { bash "$_agent_vm_sh" "$@"; }
  return 0
fi

set -euo pipefail

# This file's folder, through the links to it (0.2's on the PATH).
src="${BASH_SOURCE[0]:-$0}"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -L "$src" ] || break
  t="$(readlink "$src")"
  case "$t" in /*) src="$t" ;; *) src="$(dirname "$src")/$t" ;; esac
done
dir="$(CDPATH= cd -P -- "$(dirname "$src")" >/dev/null && pwd)"

# Windows (Git Bash): agent-vm.exe.
exe=""
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) exe=.exe ;; esac

if [ -f "$dir/agent-vm$exe" ]; then
  exec "$dir/agent-vm$exe" "$@"
fi

bin="$dir/_output/bin/agent-vm$exe"
head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
if [ ! -x "$bin" ] || [ "$(cat "$dir/_output/built-from" 2>/dev/null)" != "$head" ]; then
  echo "agent-vm: building (Go needed, and on macOS the Xcode command line tools; a few minutes the first time)..." >&2
  mkdir -p "$dir/_output"
  make -C "$dir" agent-vm >"$dir/_output/build.log" 2>&1 \
    || { tail -n 20 "$dir/_output/build.log" >&2; echo "agent-vm: the build failed, full log: $dir/_output/build.log" >&2; exit 1; }
  echo "$head" > "$dir/_output/built-from"
fi
exec "$bin" "$@"

#!/usr/bin/env bash
#
# agent-vm test suite.
#
#   ./test.sh
#
# Runs against a stub limactl in a throwaway HOME, so it never creates, starts
# or deletes a VM and never touches your real ~/.agent-vm. No network needed.
#
# Scope: the pure logic and the machine-readable surface — VM naming, list
# matching, resource comparison, staleness, `info`/`version`/`name`, the
# --preinstall parser, and the MCP config writer. Anything that genuinely needs
# Lima is out of scope here.
#
# Also worth running under bash 3.2 (what macOS ships), which is stricter about
# empty array expansion under `set -u`:
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 ./test.sh

set -uo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
AGENT_VM_SH="${AGENT_VM_SH:-$SELF_DIR/agent-vm.sh}"
SETUP_SH="${SETUP_SH:-$SELF_DIR/agent-vm.setup.sh}"

FAIL=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1"; printf '         expected: %s\n         actual:   %s\n' "$3" "$2"; fi
}
section() { printf '\n%s\n' "$1"; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB/home"
# A real directory: `name` and `info` resolve their argument and reject a
# path that does not exist, so the tests cannot use a made-up one.
PROJ="$SB/proj"
mkdir -p "$HOME" "$SB/bin" "$PROJ"

# --- stubs --------------------------------------------------------------------
# One base VM plus one project VM, running, 4 CPUs / 8 GiB / 32 GiB.
# `shell` dumps stdin so we can assert on what setup pipes into the VM.
cat > "$SB/bin/limactl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    case "$*" in
      *"{{.Name}}|{{.CPUs}}|{{.Memory}}|{{.Disk}}"*)
        echo "agent-vm-base|4|8589934592|34359738368"
        echo "agent-vm-proj-deadbeef|4|8589934592|34359738368" ;;
      *"{{.Name}} {{.Status}}"*)
        echo "agent-vm-base Stopped"
        echo "agent-vm-proj-deadbeef Running" ;;
      *-q*)
        echo "agent-vm-base"
        echo "agent-vm-proj-deadbeef" ;;
    esac ;;
  shell) cat > "${AGENT_VM_TEST_CAPTURE:-/dev/null}" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$SB/bin/limactl"

# Minimal images (and some Linux hosts) have no shasum; _agent_vm_name needs one.
if ! command -v shasum >/dev/null 2>&1; then
  cat > "$SB/bin/shasum" <<'STUB'
#!/usr/bin/env bash
if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
else echo "0000000000000000"; fi
STUB
  chmod +x "$SB/bin/shasum"
fi
export PATH="$SB/bin:$PATH"

# shellcheck source=./agent-vm.sh
source "$AGENT_VM_SH"

# The machine running the tests has no /dev/kvm; that check is not under test.
_agent_vm_check_linux_prereqs() { return 0; }

printf 'agent-vm test suite (sandbox: %s)\n' "$SB"

# =============================================================================
section "sourcing under a strict caller"
# =============================================================================
# agent-vm is meant to be sourced by other tools. Empty array expansion under
# `set -u` is an error on bash 3.2, and `cmd | grep -q` under `pipefail` can
# fail from a SIGPIPE race — both would show up here.
( set -u; set -o pipefail
  _agent_vm_exists agent-vm-base >/dev/null
  _agent_vm_running agent-vm-proj-deadbeef >/dev/null
  _agent_vm_base_exists >/dev/null
  agent-vm version >/dev/null
  agent-vm info "$PROJ" >/dev/null
  # The mount builder is called from command substitution inside
  # _agent_vm_ensure_running, so a stray unbound variable there would also
  # only surface for a strict caller.
  VOL_STRICT_HOME="$SB/strict-home"
  mkdir -p "$VOL_STRICT_HOME/.agent-vm" "$VOL_STRICT_HOME/proj"
  HOME="$VOL_STRICT_HOME" _agent_vm_build_mounts_json \
    agent-vm-proj-deadbeef "$VOL_STRICT_HOME/proj" >/dev/null
) 2>"$SB/strict.err"
if [ -s "$SB/strict.err" ]; then
  fail "no diagnostics under set -u / pipefail"; sed 's/^/         /' "$SB/strict.err"
else
  pass "no diagnostics under set -u / pipefail"
fi

# =============================================================================
section "VM naming"
# =============================================================================
n1="$(_agent_vm_name /tmp/some-project)"
n2="$(_agent_vm_name /tmp/some-project)"
check "deterministic for the same directory" "$n1" "$n2"
if [ "$(_agent_vm_name /tmp/a)" != "$(_agent_vm_name /tmp/b)" ]; then
  pass "different directories get different names"
else
  fail "different directories collide"
fi
case "$(_agent_vm_name /tmp/some-project)" in
  agent-vm-some-project-*) pass "name carries the directory basename" ;;
  *) fail "unexpected name shape: $(_agent_vm_name /tmp/some-project)" ;;
esac
case "$(_agent_vm_name '/tmp/Weird Name!')" in
  *[!a-zA-Z0-9-]*) fail "name not sanitised: $(_agent_vm_name '/tmp/Weird Name!')" ;;
  *) pass "odd characters are sanitised out of the name" ;;
esac

# =============================================================================
section "exact line matching (no pipe into grep -q)"
# =============================================================================
if _agent_vm_has_line "$(printf 'alpha\nbeta\n')" beta; then pass "finds an exact line"
else fail "missed an exact line"; fi
if _agent_vm_has_line "$(printf 'alphabet\n')" alpha; then fail "matched a prefix"
else pass "does not match a prefix"; fi
if _agent_vm_has_line "" alpha; then fail "matched in empty input"
else pass "no match in empty input"; fi

# =============================================================================
section "resource comparison (only prompt on a real change)"
# =============================================================================
VM=agent-vm-proj-deadbeef
check "reads current resources" "$(_agent_vm_resources "$VM")" "4|8|32"
if _agent_vm_resources_differ "$VM" 4 8 32; then
  fail "identical request (4/8/32) seen as a change"
else
  pass "identical request (4/8/32) is not a change"
fi
_agent_vm_resources_differ "$VM" 8 8 32 && pass "cpus 4->8 detected" || fail "cpus 4->8 missed"
_agent_vm_resources_differ "$VM" 4 16 32 && pass "memory 8->16 detected" || fail "memory 8->16 missed"
_agent_vm_resources_differ "$VM" 4 8 64 && pass "disk grow 32->64 detected" || fail "disk grow missed"
if _agent_vm_resources_differ "$VM" 4 8 10; then
  fail "disk shrink 32->10 treated as a change (Lima cannot shrink)"
else
  pass "disk shrink 32->10 ignored (Lima cannot shrink)"
fi
if _agent_vm_resources_differ "$VM" "" "" ""; then
  fail "empty request seen as a change"
else
  pass "empty request is not a change"
fi
_agent_vm_resources_differ agent-vm-unknown 4 8 32 \
  && pass "unknown VM does not claim 'no change'" \
  || fail "unknown VM treated as identical"

# =============================================================================
section "staleness (never guess from a missing file)"
# =============================================================================
mkdir -p "$HOME/.agent-vm"
check "no markers at all -> unknown" "$(_agent_vm_stale_state vmx)" "unknown"
echo 111 > "$HOME/.agent-vm/.agent-vm-base-version"
check "base known, VM unmarked -> stale" "$(_agent_vm_stale_state vmx)" "1"
echo 111 > "$HOME/.agent-vm/.agent-vm-version-vmx"
check "same version -> up to date" "$(_agent_vm_stale_state vmx)" "0"
echo 222 > "$HOME/.agent-vm/.agent-vm-base-version"
check "base newer -> stale" "$(_agent_vm_stale_state vmx)" "1"
rm -f "$HOME/.agent-vm/.agent-vm-base-version" "$HOME/.agent-vm/.agent-vm-version-vmx"

# =============================================================================
section "machine-readable surface"
# =============================================================================
check "version" "$(agent-vm version)" "$AGENT_VM_VERSION"
check "--version" "$(agent-vm --version)" "$AGENT_VM_VERSION"
check "name matches the internal helper" "$(agent-vm name "$PROJ")" "$(_agent_vm_name "$PROJ")"

info_out="$(agent-vm info "$PROJ")"
get() { printf '%s\n' "$info_out" | grep "^$1=" | cut -d= -f2-; }
check "info: version"      "$(get version)"     "$AGENT_VM_VERSION"
check "info: template"     "$(get template)"    "agent-vm-base"
check "info: dir"          "$(get dir)"         "$PROJ"
check "info: base_exists"  "$(get base_exists)" "1"
check "info: vm_exists"    "$(get vm_exists)"   "0"
check "info: vm_stale unknown with no VM" "$(get vm_stale)" "unknown"
check "info: key count"    "$(printf '%s\n' "$info_out" | grep -c '^[a-z_]*=')" "9"

# Every key must be present even with no Lima on the box. Build a PATH with the
# limactl-bearing directories dropped rather than a hardcoded one, so this also
# holds on a machine where Lima is genuinely installed.
# Peel one entry per iteration instead of `for d in $PATH` with IFS=: — zsh does
# not word-split unquoted expansions, so that form would hand back the whole
# PATH as a single word and quietly keep the stub limactl visible.
nolima_path=""
_rest="$PATH:"
while [ -n "$_rest" ]; do
  _d="${_rest%%:*}"
  _rest="${_rest#*:}"
  [ -z "$_d" ] && continue
  [ -x "$_d/limactl" ] && continue
  nolima_path="${nolima_path:+$nolima_path:}$_d"
done
nolima="$(PATH="$nolima_path" bash -c 'source "$1"; agent-vm info "$2"' _ "$AGENT_VM_SH" "$PROJ" 2>/dev/null)"
check "info without limactl still prints 9 keys" \
  "$(printf '%s\n' "$nolima" | grep -c '^[a-z_]*=')" "9"
case "$nolima" in
  *"base_exists=unknown"*) pass "info without limactl says unknown, not 0" ;;
  *) fail "info without limactl should report unknown" ;;
esac

# =============================================================================
section "directory arguments are normalised"
# =============================================================================
# The VM name is a hash of the directory STRING, and the VM-running commands
# always feed it `$(pwd)`. Without normalising, `name /tmp` and `name /tmp/`
# would be two different VMs for one directory, and neither need match what
# `cd /tmp && agent-vm opencode` produces.
canon="$(agent-vm name "$PROJ")"
check "trailing slash agrees"   "$(agent-vm name "$PROJ/")"        "$canon"
check "relative path agrees"    "$(cd "$PROJ" && agent-vm name .)" "$canon"
check "no argument means cwd"   "$(cd "$PROJ" && agent-vm name)"   "$canon"
check "info agrees with name"   "$(agent-vm info "$PROJ/" | grep '^vm_name=' | cut -d= -f2)" "$canon"
if agent-vm name "$SB/does-not-exist" >/dev/null 2>&1; then
  fail "a nonexistent directory should be rejected, not hashed"
else
  pass "a nonexistent directory is rejected"
fi

# CDPATH must not leak into the resolution. With it set, `cd <relative>` searches
# it before the current directory AND prints where it landed — so an unprotected
# `cd "$dir" && pwd` both emits a stray line and resolves a different directory
# than the `-d` test validated. Two decoys with the same basename make the
# difference observable.
mkdir -p "$SB/decoy/twin" "$SB/real/twin"
check "CDPATH does not redirect the lookup" \
  "$(cd "$SB/real" && CDPATH="$SB/decoy" agent-vm name twin)" \
  "$(agent-vm name "$SB/real/twin")"

# Stray `cd` output has to be observed on `info`, not on `name`: the name is run
# through `tr -cs 'a-zA-Z0-9' '-'`, which would quietly turn the extra newline
# into a dash. `info` prints the resolved path raw, so a leaked line shows up as
# a tenth line among the nine key=value pairs.
check "no stray cd output leaks into info" \
  "$(cd "$SB/real" && CDPATH="$SB/decoy" agent-vm info twin | wc -l | tr -d ' ')" "9"

# =============================================================================
section "--preinstall parsing"
# =============================================================================
preinstall_exports() {
  export AGENT_VM_TEST_CAPTURE="$SB/piped.sh"
  : > "$AGENT_VM_TEST_CAPTURE"
  _agent_vm_setup --preinstall="$1" >/dev/null 2>&1
  grep -E "^export AGENT_VM_INSTALL_$2=" "$AGENT_VM_TEST_CAPTURE" | cut -d= -f2
}
check "default: node on"            "$(preinstall_exports default NODE)"       "1"
check "default: ruby off"           "$(preinstall_exports default RUBY)"       "0"
check "all: ruby on"                "$(preinstall_exports all RUBY)"           "1"
check "none: node off"              "$(preinstall_exports none NODE)"          "0"
check "explicit subset: gh on"      "$(preinstall_exports node,gh GH)"         "1"
check "explicit subset: docker off" "$(preinstall_exports node,gh DOCKER)"     "0"

section "--preinstall: MCP names"
check "default wires the chrome MCP"      "$(preinstall_exports default MCP_CHROME)"     "1"
check "default leaves playwright out"     "$(preinstall_exports default MCP_PLAYWRIGHT)" "0"
check "all wires both"                    "$(preinstall_exports all MCP_CHROME)"         "1"
check "all wires playwright too"          "$(preinstall_exports all MCP_PLAYWRIGHT)"     "1"
# The point of the mcp-* names: a caller that manages MCP servers per project
# just omits them. Nothing new has to be passed, so older builds stay compatible.
check "omitting mcp-chrome disables it"   "$(preinstall_exports node,gh,chromium,opencode MCP_CHROME)" "0"
check "naming mcp-chrome enables it"      "$(preinstall_exports node,chromium,opencode,mcp-chrome MCP_CHROME)" "1"
check "naming mcp-playwright enables it"  "$(preinstall_exports node,chromium,opencode,mcp-playwright MCP_PLAYWRIGHT)" "1"

if _agent_vm_setup --preinstall=node,not-a-real-name >/dev/null 2>&1; then
  fail "an unknown --preinstall name should be fatal"
else
  pass "an unknown --preinstall name is fatal"
fi

# =============================================================================
section "script dir resolves through symlinks"
# =============================================================================
# install.sh puts a symlink on PATH. Without following it, AGENT_VM_SCRIPT_DIR
# points at the link's directory and `agent-vm setup` cannot find
# agent-vm.setup.sh, which lives next to the real file.
REALDIR="$(CDPATH= cd -P -- "$(dirname "$AGENT_VM_SH")" >/dev/null && pwd)"
mkdir -p "$SB/link1" "$SB/link2"
ln -sf "$AGENT_VM_SH" "$SB/link1/agent-vm"
ln -sf "$SB/link1/agent-vm" "$SB/link2/agent-vm"
# Paths go in as positional parameters: interpolating them into single-quoted
# shell text would break on a path containing a single quote.
script_dir_of() {
  bash -c 'source "$1" 2>/dev/null; printf "%s" "$AGENT_VM_SCRIPT_DIR"' _ "$1"
}
check "direct symlink"                     "$(script_dir_of "$SB/link1/agent-vm")" "$REALDIR"
check "chain of two symlinks"              "$(script_dir_of "$SB/link2/agent-vm")" "$REALDIR"
check "no symlink (the historical sourcing)" "$(script_dir_of "$AGENT_VM_SH")"     "$REALDIR"

# =============================================================================
section "env: the shared secrets file"
# =============================================================================
# This file is SOURCED by the VM's shell, so one bad escape costs every secret
# in it — not just the one that was mis-quoted. That is why the quoting lives
# here rather than in each integrator.
ENVHOME="$SB/envhome"; mkdir -p "$ENVHOME"
avenv() { HOME="$ENVHOME" bash "$AGENT_VM_SH" env "$@"; }

avenv set ALBERT_API_KEY "k1" >/dev/null
avenv set AC_GIT_USER_NAME "O'Brien" >/dev/null
check "get returns the value"        "$(avenv get ALBERT_API_KEY)" "k1"
check "a single quote survives"      "$(avenv get AC_GIT_USER_NAME)" "O'Brien"
avenv set ALBERT_API_KEY "k2" >/dev/null
check "rotation replaces, not appends" "$(grep -c '^ALBERT_API_KEY=' "$ENVHOME/.agent-vm/env")" "1"
check "rotation keeps the fresh value" "$(avenv get ALBERT_API_KEY)" "k2"
check "the quoted entry still reads back" "$(avenv get AC_GIT_USER_NAME)" "O'Brien"

printf 'SOMEONE_ELSE=keep-me\n' >> "$ENVHOME/.agent-vm/env"
avenv set ALBERT_API_KEY "k3" >/dev/null
check "unmanaged lines are preserved" "$(grep -c '^SOMEONE_ELSE=keep-me$' "$ENVHOME/.agent-vm/env")" "1"

avenv has ALBERT_API_KEY && pass "has: present key" || fail "has: present key"
avenv has NOPE_NOT_HERE && fail "has: absent key" || pass "has: absent key"

# `has`/`get` must answer about the FILE. The subshell inherits this shell's
# environment, so without unsetting first, a merely-exported variable reads as
# stored — and agent-vm's own callers often run inside a VM that exports these.
if HOME="$ENVHOME" AMBIENT_ONLY=x bash "$AGENT_VM_SH" env has AMBIENT_ONLY; then
  fail "has must ignore the ambient environment"
else
  pass "has ignores the ambient environment"
fi

check "list prints names only" "$(avenv list | sort | tr '\n' ' ')" "AC_GIT_USER_NAME ALBERT_API_KEY SOMEONE_ELSE "
if avenv list | grep -q "O'Brien\|k3"; then fail "list must never print values"; else pass "list never prints values"; fi

avenv unset ALBERT_API_KEY >/dev/null
avenv has ALBERT_API_KEY && fail "unset removed the key" || pass "unset removes the key"
check "unset keeps the others" "$(grep -c '^SOMEONE_ELSE=' "$ENVHOME/.agent-vm/env")" "1"
check "file is mode 600" "$(ls -l "$ENVHOME/.agent-vm/env" | cut -c2-10)" "rw-------"

if avenv set "not-a-name" x >/dev/null 2>&1; then
  fail "an invalid variable name must be rejected"
else
  pass "an invalid variable name is rejected"
fi

# The file has to survive being sourced the way the VM sources it.
val="$(set -a; . "$ENVHOME/.agent-vm/env"; set +a; printf '%s' "${AC_GIT_USER_NAME:-BROKEN}")"
check "the file sources cleanly in a shell" "$val" "O'Brien"

# =============================================================================
section "mounts: global + per-project volumes"
# =============================================================================
# The mounts JSON is built from ~/.agent-vm/volumes (global) merged with
# <project>/.agent-vm.volumes (per-project, appended after the global ones).
# Calling the builder directly keeps this independent of a real VM.
VOLHOME="$SB/volhome"; mkdir -p "$VOLHOME/.agent-vm" "$VOLHOME/.ssh"
printf 'secret' > "$VOLHOME/.ssh/id_rsa"
VOLPROJ="$SB/volproj"; mkdir -p "$VOLPROJ/sub" "$VOLPROJ/fix"
printf 'x' > "$VOLPROJ/token.txt"
printf 'x' > "$VOLHOME/gitconfig"
VOL_VM="agent-vm-proj-deadbeef"
# The builder is invoked through bash explicitly (test.sh itself also runs
# under zsh) and with HOME pointed at a scratch dir, so the real ~/.agent-vm
# is never read or written.
# The extra flag args exercise the --readonly/--git-read-only downgrades; the
# plain form keeps the other checks independent of them.
mounts_of() { HOME="$VOLHOME" bash -c '
  source "$1"; _agent_vm_build_mounts_json "$2" "$3"' _ "$AGENT_VM_SH" "$VOL_VM" "$VOLPROJ"; }
mounts_ro_of() { HOME="$VOLHOME" bash -c '
  source "$1"; _agent_vm_build_mounts_json "$2" "$3" --readonly --git-read-only' \
  _ "$AGENT_VM_SH" "$VOL_VM" "$VOLPROJ"; }
# True when the substrings appear in the given order in "$1".
substrings_in_order() {
  local rest="$1" piece
  shift
  for piece in "$@"; do
    case "$rest" in
      *"$piece"*) rest="${rest#*"$piece"}" ;;
      *) return 1 ;;
    esac
  done
}

# 1. No volumes files anywhere: just the project dir, writable.
check "no volumes files -> project dir only" \
  "$(mounts_of)" "[{\"location\": \"$VOLPROJ\", \"writable\": true}]"

# 2. Global-only: an ro dir and a file mount (with an explicit destination).
printf '%s\n' \
  "$VOLPROJ/fix" \
  "$VOLPROJ/token.txt:~/.token.txt" \
  > "$VOLHOME/.agent-vm/volumes"
m="$(mounts_of)"
case "$m" in
  *"\"location\": \"$VOLPROJ/fix\", \"writable\": false"*) pass "global ro dir mounted" ;;
  *) fail "global ro dir missing: $m" ;;
esac
# The staging dir path appears in the JSON with its index; a file entry is
# recognizable by that location shape.
case "$m" in
  *"\"location\": \"$VOLHOME/.agent-vm/file-mounts/$VOL_VM/0\""*) pass "global file staged at index 0" ;;
  *) fail "global file mount missing: $m" ;;
esac
check "global file mount cache written" \
  "$(cut -d'|' -f1,4 "$VOLHOME/.agent-vm/.agent-vm-file-mounts-$VOL_VM" | tr '\n' ' ')" \
  "$VOLPROJ/token.txt|~/.token.txt "

# 3. Per-project file: comments/blanks ignored, entries appended after the
# global ones, a relative source resolves against the project dir, and the
# file-mount indices advance across both files (no staging collision).
printf '%s\n' \
  "# comment" \
  "" \
  "sub:/home/me/sub:rw" \
  "token.txt:/tmp/committed-token" \
  "./missing-thing" \
  > "$VOLPROJ/.agent-vm.volumes"
m="$(mounts_of 2>"$SB/vol.err")"
if substrings_in_order "$m" \
    "$VOLPROJ/fix\", \"writable\": false" \
    "file-mounts/$VOL_VM/0" \
    "$VOLPROJ/sub\", \"mountPoint\": \"/home/me/sub\", \"writable\": true" \
    "file-mounts/$VOL_VM/1"; then
  pass "global then per-project entries, in order"
else
  fail "global/per-project merge wrong: $m"
fi
check "per-project relative file mount cache entry" \
  "$(cut -d'|' -f1,4 "$VOLHOME/.agent-vm/.agent-vm-file-mounts-$VOL_VM" | tail -n 1)" \
  "$VOLPROJ/token.txt|/tmp/committed-token"
case "$(cat "$SB/vol.err")" in
  *"missing-thing"*) pass "missing relative path skipped with a warning" ;;
  *) fail "no warning for the missing relative path: $(cat "$SB/vol.err")" ;;
esac

# 4. A relative path in the GLOBAL file is rejected (it would silently depend
# on the caller's cwd), while ~ still expands there.
# shellcheck disable=SC2088  # the tilde is deliberately literal: it tests the file's own ~ expansion
printf '%s\n' "../elsewhere" "~/gitconfig" > "$VOLHOME/.agent-vm/volumes"
printf '%s\n' "fix" > "$VOLPROJ/.agent-vm.volumes"
m="$(mounts_of 2>"$SB/vol.err")"
case "$(cat "$SB/vol.err")" in
  *"relative path"*) pass "relative path in the global file is rejected" ;;
  *) fail "relative global path not rejected: $(cat "$SB/vol.err")" ;;
esac
case "$m" in
  *"\"location\": \"$VOLPROJ/fix\", \"writable\": false"*)
    pass "per-project file still parsed after a bad global line" ;;
  *) fail "per-project entry lost after global warning: $m" ;;
esac
check "~ expansion still works in the global file" \
  "$(cut -d'|' -f1 "$VOLHOME/.agent-vm/.agent-vm-file-mounts-$VOL_VM" 2>/dev/null | tr '\n' ' ')" \
  "$VOLHOME/gitconfig "

# 5. Security: repository content must not choose host paths (CWE-552). A
# per-project entry pointing at ~/.ssh (directly, via .., or via a symlink —
# including a symlinked *file*, which the hardlink staging would happily
# link) is skipped; the same entries are fine in the global file, which is
# the user's own decision.
rm -f "$VOLHOME/.agent-vm/volumes"
ln -s "$VOLHOME/.ssh" "$VOLPROJ/ssh-link"
ln -s "$VOLHOME/.ssh/id_rsa" "$VOLPROJ/key-link"
printf '%s\n' \
  "$VOLHOME/.ssh" \
  "../$(basename "$VOLHOME")/ssh-link" \
  "ssh-link" \
  "key-link:/tmp/key" \
  > "$VOLPROJ/.agent-vm.volumes"
m="$(mounts_of 2>"$SB/vol.err")"
case "$(cat "$SB/vol.err")" in
  *"resolves outside the project"*) pass "outside paths in the project file are rejected" ;;
  *) fail "project file escaped the project without a warning: $(cat "$SB/vol.err")" ;;
esac
case "$m" in
  *"id_rsa"*) fail "host credentials leaked into the mount list: $m" ;;
  *) pass "no ~/.ssh path reached the mount list" ;;
esac
case "$m" in
  *"\"location\": \"$VOLPROJ\""*) pass "the project dir mount itself survived" ;;
  *) fail "project dir mount missing: $m" ;;
esac
# The user-owned global file may mount the same paths: nothing is skipped.
printf '%s\n' "$VOLHOME/.ssh" > "$VOLHOME/.agent-vm/volumes"
printf '%s\n' "fix" > "$VOLPROJ/.agent-vm.volumes"
m="$(mounts_of 2>"$SB/vol.err")"
check "the same path is allowed in the global file" \
  "$(cat "$SB/vol.err")" ""
case "$m" in
  *"\"location\": \"$VOLHOME/.ssh\", \"writable\": false"*) pass "global file mounts outside paths" ;;
  *) fail "global outside path not mounted: $m" ;;
esac
rm -f "$VOLHOME/.agent-vm/volumes" "$VOLPROJ/ssh-link" "$VOLPROJ/key-link"

# 6. Security: --readonly/--git-read-only must also cover the mount *list*
# (CWE-284). The flags bind+remount one guest path; a second mountPoint for
# the same host data would stay writable. Any rw entry under the project (or
# under .git) is therefore forced to ro — from either file.
printf '%s\n' "$VOLPROJ/sub:/home/me/sub:rw" > "$VOLHOME/.agent-vm/volumes"
printf '%s\n' "sub:/home/me/sub-rw:rw" > "$VOLPROJ/.agent-vm.volumes"
m="$(mounts_ro_of 2>"$SB/vol.err")"
if substrings_in_order "$m" \
    "\"location\": \"$VOLPROJ/sub\", \"mountPoint\": \"/home/me/sub\", \"writable\": false" \
    "\"location\": \"$VOLPROJ/sub\", \"mountPoint\": \"/home/me/sub-rw\", \"writable\": false"; then
  pass "rw aliases of the project are forced to ro under --readonly"
else
  fail "writable alias survived --readonly: $m"
fi
check "both downgrades warned about" \
  "$(grep -c 'forcing it to ro' "$SB/vol.err")" "2"
# Without the flags the same entries stay writable.
m="$(mounts_of)"
case "$m" in
  *"\"mountPoint\": \"/home/me/sub-rw\", \"writable\": true"*) pass "rw allowed again without the flags" ;;
  *) fail "no rw alias without --readonly: $m" ;;
esac

# 7. .git protection: same downgrade logic, for --git-read-only. A plain
# directory stands in for .git — the bash 3.2 CI container has no git, and the
# downgrade logic only cares that the path exists.
mkdir -p "$VOLPROJ/.git"
printf '%s\n' ".git:/home/me/git:rw" > "$VOLPROJ/.agent-vm.volumes"
m="$(mounts_ro_of 2>"$SB/vol.err")"
case "$m" in
  *"\"location\": \"$VOLPROJ/.git\", \"mountPoint\": \"/home/me/git\", \"writable\": false"*)
    pass "rw .git alias forced to ro under --git-read-only" ;;
  *) fail "writable .git alias survived --git-read-only: $m" ;;
esac
m="$(mounts_of)"
case "$m" in
  *"\"mountPoint\": \"/home/me/git\", \"writable\": true"*) pass ".git rw allowed without the flag" ;;
  *) fail ".git alias downgraded without --git-read-only: $m" ;;
esac

# 8. The mount record (persisted for alias protection on later sessions):
# one line per mount, resolved host source first, canonical project dir
# included, mode keyword last. Built from the section-7 state: the global
# file's `sub` entry, the project file's `.git` entry, plus the project dir.
check "mount record: canonical project dir first, resolved sources" \
  "$(cat "$VOLHOME/.agent-vm/.agent-vm-mounts-$VOL_VM")" \
  "$VOLPROJ|$VOLPROJ|rw
$VOLPROJ/sub|/home/me/sub|rw
$VOLPROJ/.git|/home/me/git|rw"

# 9. Alias extraction from the record (CWE-284 on existing VMs): with the
# flags, every writable alias under a protected path is listed for the
# per-session remount; ro aliases, outside paths and the canonical mounts
# are not.
REC="$VOLHOME/.agent-vm/.agent-vm-mounts-$VOL_VM"
printf '%s\n' \
  "$VOLPROJ|$VOLPROJ|rw" \
  "$VOLPROJ/.git|$VOLPROJ/.git|rw" \
  "$VOLPROJ/sub|/home/me/sub|rw" \
  "$VOLPROJ/sub|/home/me/sub-ro|ro" \
  "$VOLPROJ/token.txt|/tmp/committed-token|ro" \
  "$VOLHOME/elsewhere|/tmp/out|rw" \
  > "$REC"
aliases_of() {
  local ro="${1:-}" git_ro="${2:-}"
  HOME="$VOLHOME" bash -c '
    source "$1"; _agent_vm_protected_aliases "$2" "$3" "$4" "$5"' \
    _ "$AGENT_VM_SH" "$VOL_VM" "$VOLPROJ" \
    "${ro:+--readonly}" "${git_ro:+--git-read-only}"
}
check "aliases: only the writable in-project alias under --readonly" \
  "$(aliases_of 1)" "/home/me/sub|$VOLPROJ/sub"
check "aliases: none without flags" "$(aliases_of)" ""
check "aliases: an in-project alias is covered by either flag" \
  "$(aliases_of 1 1)" "/home/me/sub|$VOLPROJ/sub"
# The .git subdirectory (not the whole project) must NOT be treated as
# protected by plain --readonly: that flag remounts the project root, which
# already covers .git through the parent mount, and blindly listing .git
# aliases under --readonly would produce a confusing second remount of the
# same data. Only --git-read-only targets .git specifically.
printf '%s\n' "$VOLPROJ/.git|/tmp/git-only|rw" > "$REC"
check "aliases: a .git-only alias needs --git-read-only, not --readonly" \
  "$(aliases_of 1 1)" "/tmp/git-only|$VOLPROJ/.git"

rm -rf "$VOLHOME" "$VOLPROJ"

# =============================================================================
section "alias enforcement fails closed"
# =============================================================================
# A session that requests --readonly must not launch if a recorded writable
# alias cannot be remounted read-only: warning-and-continue would launch the
# agent with weaker isolation than requested (CWE-284). The enforcement loop
# is exercised directly — stubbing limactl's `sudo` plumbing is not needed
# because the failure is injected the same way the VM would produce it: a
# failing shell call. Run through the real _agent_vm_ensure_running would need
# a full VM; instead replicate its alias block's inputs and check the
# contract of the pieces it composes.
FA_HOME="$SB/fa-home"; FA_PROJ="$SB/fa-proj"
mkdir -p "$FA_HOME/.agent-vm" "$FA_PROJ/sub"
printf '%s|%s|%s\n' "$FA_PROJ/sub" /tmp/fa-alias rw \
  > "$FA_HOME/.agent-vm/.agent-vm-mounts-$VOL_VM"
fa_aliases() { HOME="$FA_HOME" bash -c '
  source "$1"; _agent_vm_protected_aliases "$2" "$3" --readonly' \
  _ "$AGENT_VM_SH" "$VOL_VM" "$FA_PROJ"; }
check "fail-closed setup: the alias is selected for enforcement" \
  "$(fa_aliases)" "/tmp/fa-alias|$FA_PROJ/sub"
# And the failure path in ensure_running is a `return 1` right after the
# warning: assert the source keeps that contract so a refactor cannot
# silently reintroduce warn-and-continue.
if grep -A6 'could not enforce read-only on alias' "$AGENT_VM_SH" \
   | grep -q 'alias_failed=1'; then
  pass "a failed alias remount is recorded, not ignored"
else
  fail "alias remount failure is not tracked"
fi
if grep -A16 'alias_failed=1' "$AGENT_VM_SH" | grep -q 'return 1'; then
  pass "any failed alias remount aborts the session (fail closed)"
else
  fail "failed alias remount does not abort the session"
fi
# A MISSING record must not read as "no aliases": the metadata that should
# describe the VM is gone, so a protected session cannot be verified — it must
# fail closed instead of launching unchecked.
rm -f "$FA_HOME/.agent-vm/.agent-vm-mounts-$VOL_VM"
if fa_aliases >/dev/null 2>&1; then
  fail "a missing mount record is treated as 'no aliases'"
else
  pass "a missing mount record fails closed (non-zero exit)"
fi
if HOME="$FA_HOME" bash -c '
  source "$1"; _agent_vm_protected_aliases "$2" "$3"' \
  _ "$AGENT_VM_SH" "$VOL_VM" "$FA_PROJ" >/dev/null 2>&1; then
  pass "without flags a missing record is irrelevant (exit 0)"
else
  fail "missing record errors even without protection flags"
fi
rm -rf "$FA_HOME" "$FA_PROJ"

# =============================================================================
section "file-mount refresh revalidates the project boundary"
# =============================================================================
# The per-VM file-mount cache stores the lexical source. A symlink that pointed
# inside the project at VM creation can be retargeted outside afterwards; the
# refresh must re-check the resolved target before re-staging, or the next
# session would copy an outside-project host file into the VM (CWE-552).
RF_HOME="$SB/rf-home"; RF_PROJ="$SB/rf-proj"
mkdir -p "$RF_HOME/.agent-vm" "$RF_HOME/.ssh" "$RF_PROJ"
printf 'SECRET' > "$RF_HOME/.ssh/id_rsa"
printf 'x' > "$RF_PROJ/token.txt"
printf 'token.txt:/tmp/vm-token\n' > "$RF_PROJ/.agent-vm.volumes"
HOME="$RF_HOME" bash -c '
  source "$1"
  _agent_vm_build_mounts_json "'"$VOL_VM"'" "'"$RF_PROJ"'" >/dev/null 2>&1
' _ "$AGENT_VM_SH"
RF_CACHE="$RF_HOME/.agent-vm/.agent-vm-file-mounts-$VOL_VM"
check "refresh setup: cache holds the lexical source" \
  "$(cut -d'|' -f1 "$RF_CACHE")" "$RF_PROJ/token.txt"
# Retarget the (previously in-project, real-file) source outside the project.
rm -f "$RF_PROJ/token.txt"
ln -s "$RF_HOME/.ssh/id_rsa" "$RF_PROJ/token.txt"
rf_err="$SB/rf.err"
# Drive the refresh through the real ensure_running branch: stub limactl so
# the VM counts as existing + running (existing-VM => is_new_vm empty => the
# refresh path is what runs). Everything limactl would do is a no-op; only
# the staging loop has real effects on the host.
mkdir -p "$SB/rfbin"
cat > "$SB/rfbin/limactl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    case "$*" in
      *"{{.Name}} {{.Status}}"*)
        echo "agent-vm-base Stopped"
        echo "agent-vm-proj-deadbeef Running" ;;
      *-q*)
        echo "agent-vm-base"
        echo "agent-vm-proj-deadbeef" ;;
      *"{{.Name}}|"*)
        echo "agent-vm-proj-deadbeef|4|8589934592|34359738368" ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$SB/rfbin/limactl"
# ensure_running needs a base VM too; the stub list already reports one.
HOME="$RF_HOME" PATH="$SB/rfbin:$PATH" bash -c '
  _agent_vm_check_linux_prereqs() { return 0; }
  source "$1"
  _agent_vm_ensure_running "'"$VOL_VM"'" "'"$RF_PROJ"'" >/dev/null
' _ "$AGENT_VM_SH" 2>"$rf_err"
case "$(cat "$rf_err")" in
  *"now resolves outside the project"*) pass "a retargeted symlink is not refreshed" ;;
  *) fail "retargeted symlink refreshed without revalidation: $(cat "$rf_err")" ;;
esac
case "$(cat "$RF_HOME/.agent-vm/file-mounts/$VOL_VM/0/token.txt")" in
  SECRET) fail "the outside target content was staged" ;;
  x)      pass "staged content is still the last in-project copy" ;;
  *)      fail "unexpected staged content" ;;
esac
rm -rf "$RF_HOME" "$RF_PROJ" "$SB/rfbin"

# =============================================================================
section "release hygiene"
# =============================================================================
# Every dispatched command must appear in `help`: a command nobody can discover
# is a command nobody uses. (`sh`/`destroy` are aliases documented inline.)
help_text="$(agent-vm help)"
missing=""
for verb in setup claude opencode codex vibe shell run stop rm destroy-all \
            list status name info env version help; do
  case "$help_text" in
    *"  $verb"*) ;;
    *) missing="$missing $verb" ;;
  esac
done
# One verdict, not a pass that fires whatever the loop found.
if [ -n "$missing" ]; then
  fail "dispatched but missing from help:$missing"
else
  pass "every dispatched command appears in help"
fi
check "the version in help output matches the constant" \
  "$(agent-vm version)" "$AGENT_VM_VERSION"

# A bad resource value must produce an actionable message, not a raw bash
# arithmetic diagnostic leaking from the comparison helper.
bad="$( (agent-vm --disk 10G version) 2>&1 )" || true
case "$bad" in
  *"must be a positive integer"*) pass "a non-numeric --disk is rejected clearly" ;;
  *"value too great for base"*)   fail "raw bash arithmetic error leaked: $bad" ;;
  *) fail "unexpected output for --disk 10G: $bad" ;;
esac
check "a valid resource value still passes" "$(agent-vm --disk 32 --cpus 4 version)" "$AGENT_VM_VERSION"

# A failed write of the secrets file must not be reported as success: a caller
# told the secret was stored when it was not is the worst outcome for this file.
# Root ignores permission bits, so the condition cannot be staged as root —
# which is exactly what the bash 3.2 container runs as.
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip env-set-failure test (running as root: permission bits do not apply)\n'
else
  RO="$SB/readonly-home"
  mkdir -p "$RO/.agent-vm"
  printf "K='v'\n" > "$RO/.agent-vm/env"
  chmod 500 "$RO/.agent-vm"
  if HOME="$RO" bash "$AGENT_VM_SH" env set OTHER x >/dev/null 2>&1; then
    fail "env set reported success on an unwritable directory"
  else
    pass "env set fails loudly when the write cannot happen"
  fi
  chmod 700 "$RO/.agent-vm"
fi

# =============================================================================
section "MCP config writer"
# =============================================================================
# configure_mcp lives in the in-VM setup script, whose top level performs the
# actual installs — so lift just that function out rather than sourcing it.
if ! command -v jq >/dev/null 2>&1; then
  printf '  skip configure_mcp tests (jq not installed)\n'
else
  MCPHOME="$SB/mcp"; mkdir -p "$MCPHOME"
  (
    HOME="$MCPHOME"
    eval "$(awk '/^configure_mcp\(\) \{/,/^\}/' "$SETUP_SH")"
    INSTALL_CLAUDE=1 INSTALL_OPENCODE=1 INSTALL_VIBE=1 INSTALL_CODEX=1
    for _ in 1 2; do   # twice: the writer must be idempotent
      configure_mcp chrome-devtools npx -y chrome-devtools-mcp@latest --headless=true
      configure_mcp playwright env PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npx -y @playwright/mcp@latest
    done
  ) >/dev/null 2>&1

  oc="$MCPHOME/.config/opencode/opencode.json"
  check "opencode: two servers"  "$(jq '.mcp | length' "$oc")" "2"
  check "opencode: \$schema kept" "$(jq -r '."$schema"' "$oc")" "https://opencode.ai/config.json"
  check "opencode: command starts with the launcher" \
    "$(jq -r '.mcp.playwright.command[0]' "$oc")" "env"
  check "opencode: env assignment survives as its own argv entry" \
    "$(jq -r '.mcp.playwright.command[1]' "$oc")" "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1"
  check "claude: two servers" \
    "$(jq '.mcpServers | length' "$MCPHOME/.claude.json")" "2"
  check "codex: no duplicate table after two runs" \
    "$(grep -cF '[mcp_servers.playwright]' "$MCPHOME/.codex/config.toml")" "1"
  check "vibe: no duplicate entry after two runs" \
    "$(grep -c '^\[\[mcp_servers\]\]' "$MCPHOME/.vibe/config.toml")" "2"
fi

# =============================================================================
printf '\n%s passed, %s failed\n' "$PASSED" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

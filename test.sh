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
# AGENT_VM_TEST_EXTRA_VM adds one more name to the inventory, so a test can
# make the VM of an arbitrary directory exist. AGENT_VM_TEST_CALLS records the
# destructive calls, to assert which VM they hit.
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
        echo "agent-vm-proj-deadbeef"
        [ -n "${AGENT_VM_TEST_EXTRA_VM:-}" ] && echo "$AGENT_VM_TEST_EXTRA_VM" ;;
    esac ;;
  shell) cat > "${AGENT_VM_TEST_CAPTURE:-/dev/null}" ;;
  stop|delete) echo "$*" >> "${AGENT_VM_TEST_CALLS:-/dev/null}" ;;
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
  _agent_vm_project_vms >/dev/null
  agent-vm version >/dev/null
  agent-vm info "$PROJ" >/dev/null
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
section "base readiness (a half-provisioned template is not a base)"
# =============================================================================
# The stub always lists agent-vm-base, so what changes below is only the
# marker, which is exactly the state a setup interrupted while provisioning
# leaves: the template is in Lima, nothing is installed in it.
if _agent_vm_base_exists; then
  fail "template listed but no version marker -> treated as a usable base"
else
  pass "template listed but no version marker -> not a usable base"
fi
echo 111 > "$HOME/.agent-vm/.agent-vm-base-version"
if _agent_vm_base_exists; then
  pass "template listed and marked -> usable base"
else
  fail "a completed setup is not recognised"
fi
# And a failed query still answers "could not ask", not "no base": info turns
# that status into `unknown`, and a caller told 0 would offer to rebuild a
# base VM that exists.
mkdir -p "$SB/brokenlima"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/brokenlima/limactl"
chmod +x "$SB/brokenlima/limactl"
( PATH="$SB/brokenlima:$PATH"; _agent_vm_base_exists; [ "$?" = 2 ] ) \
  && pass "a failing limactl keeps the 'unknown' status" \
  || fail "a failing limactl no longer reports status 2"

# =============================================================================
section "project VMs (who the post-setup --reset note is for)"
# =============================================================================
check "the template is not a project VM" \
  "$(_agent_vm_project_vms)" "agent-vm-proj-deadbeef"
# A first install: the base is there, nothing has been cloned from it yet, and
# suggesting --reset would point at nothing.
mkdir -p "$SB/baseonly"
cat > "$SB/baseonly/limactl" <<'STUB'
#!/usr/bin/env bash
[ "$1" = list ] && echo "agent-vm-base"
exit 0
STUB
chmod +x "$SB/baseonly/limactl"
check "nothing cloned yet -> no project VM" \
  "$( PATH="$SB/baseonly:$PATH"; _agent_vm_project_vms )" ""
check "a failing limactl lists nothing rather than erroring" \
  "$( PATH="$SB/brokenlima:$PATH"; _agent_vm_project_vms )" ""

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
check "info: key count"    "$(printf '%s\n' "$info_out" | grep -c '^[a-z_]*=')" "10"

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
check "info without limactl still prints 10 keys" \
  "$(printf '%s\n' "$nolima" | grep -c '^[a-z_]*=')" "10"
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
# one line too many among the key=value pairs.
check "no stray cd output leaks into info" \
  "$(cd "$SB/real" && CDPATH="$SB/decoy" agent-vm info twin | wc -l | tr -d ' ')" "10"

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
section "state dir: overridable, and published"
# =============================================================================
# Integrators must not rebuild this path from $HOME. They can only stop doing
# that if the engine both publishes it and honours an override.
STATE_ALT="$SB/state-alt"
check "AGENT_VM_STATE_DIR is honoured" \
  "$(AGENT_VM_STATE_DIR="$STATE_ALT" bash "$AGENT_VM_SH" info "$SB" | sed -n 's/^state_dir=//p')" \
  "$STATE_ALT"
AGENT_VM_STATE_DIR="$STATE_ALT" bash "$AGENT_VM_SH" env set SOME_KEY v >/dev/null
if [ -f "$STATE_ALT/env" ]; then
  pass "writes land in the overridden state dir"
else
  fail "the override is published but not used for writes"
fi

# =============================================================================
section "project-env: one env per project"
# =============================================================================
# Same file format and same quoting as the shared env — deliberately the same
# code — but it lives WITH the project, like the project runtime script, and
# moves, clones and disappears with it.
PENV="$SB/penv"; mkdir -p "$PENV/pa/.mytool" "$PENV/pb" "$PENV/state"
pe() { ( cd "$1" && AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" project-env "${@:2}" ); }

pe "$PENV/pa" set OPENCODE_CONFIG "/a/.albert-code/opencode.json" >/dev/null
pe "$PENV/pb" set OPENCODE_CONFIG "/b/.albert-code/opencode.json" >/dev/null
check "each project keeps its own value (a)" "$(pe "$PENV/pa" get OPENCODE_CONFIG)" "/a/.albert-code/opencode.json"
check "each project keeps its own value (b)" "$(pe "$PENV/pb" get OPENCODE_CONFIG)" "/b/.albert-code/opencode.json"
check "the file sits in the project, at the documented default" \
  "$(ls -A "$PENV/pa" | grep '^\.agent-vm\.env$')" ".agent-vm.env"
if [ -z "$(ls -A "$PENV/state" 2>/dev/null)" ]; then
  pass "nothing about a project is written into the state dir"
else
  fail "project state leaked outside the project: $(ls -A "$PENV/state" | tr '\n' ' ')"
fi
pe "$PENV/pa" set NAME "O'Brien" >/dev/null
check "the shared quoting applies here too" "$(pe "$PENV/pa" get NAME)" "O'Brien"
check "the file is mode 600" "$(ls -l "$PENV/pa/.agent-vm.env" | cut -c2-10)" "rw-------"
if pe "$PENV/pa" list | grep -q "O'Brien"; then fail "list must never print values"; else pass "list never prints values"; fi

# AGENT_VM_PROJECT_ENV, like AGENT_VM_PROJECT_RUNTIME: an integrator keeps its
# files in its own directory instead of cluttering the project root.
_pe_alt() { ( cd "$PENV/pa" && AGENT_VM_PROJECT_ENV=.mytool/env AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" project-env "$@" ); }
_pe_alt set OPENCODE_CONFIG "/elsewhere" >/dev/null
check "AGENT_VM_PROJECT_ENV relocates the file" "$(cat "$PENV/pa/.mytool/env")" "OPENCODE_CONFIG='/elsewhere'"
check "and the default file is untouched by it" "$(pe "$PENV/pa" get OPENCODE_CONFIG)" "/a/.albert-code/opencode.json"
check "info publishes the path, so nobody rebuilds it" \
  "$( ( cd "$PENV/pa" && AGENT_VM_PROJECT_ENV=.mytool/env AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" info | sed -n 's/^project_env=//p' ) )" \
  "$PENV/pa/.mytool/env"

# Precedence: the payload pushed into the VM is shared-then-project, because it
# is sourced — so a key set in both ends up with the project's value. Without
# this order, "per project" would mean nothing.
( AGENT_VM_STATE_DIR="$PENV/state"
  mkdir -p "$AGENT_VM_STATE_DIR"
  printf "SHARED_ONLY='s'\nBOTH='shared'\n" > "$AGENT_VM_STATE_DIR/env"
  printf "BOTH='project'\n" > "$PENV/pa/.agent-vm.env"
  payload="$(_agent_vm_env_payload "$PENV/pa")"
  val="$(set -a; eval "$payload"; set +a; printf '%s' "${BOTH:-MISSING}")"
  shared="$(set -a; eval "$payload"; set +a; printf '%s' "${SHARED_ONLY:-MISSING}")"
  [ "$val" = "project" ] || { echo "      BOTH=$val" >&2; exit 1; }
  [ "$shared" = "s" ] || { echo "      SHARED_ONLY=$shared" >&2; exit 1; } )
if [ $? -eq 0 ]; then
  pass "the project's value wins, and shared keys still come through"
else
  fail "wrong precedence between the shared env and the project env"
fi

# =============================================================================
section "project-env: the file is in a repository, so say so"
# =============================================================================
# The failure that matters for this file is committing it. The warning has to
# name the fix, and the fix has to work — a printed line nobody can apply is
# worse than no warning.
if command -v git >/dev/null 2>&1; then
  GI="$SB/gitrepo"; mkdir -p "$GI"
  ( cd "$GI" && git init -q && git config user.email t@t && git config user.name t )
  gpe() { ( cd "$GI" && AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" project-env "$@" ); }

  err_out="$(gpe set K v 2>&1 >/dev/null)"
  case "$err_out" in
    *"not ignored by git"*) pass "warns when the file is not ignored" ;;
    *) fail "no warning on an unignored file: $err_out" ;;
  esac
  check "the warning stays on stderr" "$(gpe set K v 2>/dev/null)" ""

  # The printed line, applied verbatim, must silence the warning.
  line="$(printf '%s\n' "$err_out" | sed -n 's/^ *echo //p' | sed "s/ >>.*//; s/^'//; s/'$//")"
  printf '%s\n' "$line" >> "$GI/.gitignore"
  if [ -n "$(gpe set K v2 2>&1 >/dev/null)" ]; then
    fail "the suggested line does not silence the warning: $(gpe set K v2 2>&1 >/dev/null)"
  else
    pass "the suggested line is the one that fixes it"
  fi

  # .git/info/exclude counts too — a grep over .gitignore would miss it.
  rm -f "$GI/.gitignore"
  printf '.agent-vm.env\n' >> "$GI/.git/info/exclude"
  if [ -n "$(gpe set K v3 2>&1 >/dev/null)" ]; then
    fail "warns although .git/info/exclude covers the file"
  else
    pass "an exclude outside .gitignore is honoured"
  fi

  # Already tracked: ignoring changes nothing, so the advice must differ.
  : > "$GI/.git/info/exclude"
  ( cd "$GI" && git add -f .agent-vm.env >/dev/null 2>&1 )
  case "$(gpe set K v4 2>&1 >/dev/null)" in
    *"tracked by git"*) pass "a tracked file gets the fix that actually applies" ;;
    *) fail "a tracked file must not be told to add a gitignore line" ;;
  esac

  # Outside a repository there is nothing to warn about.
  OUTSIDE="$SB/outside"; mkdir -p "$OUTSIDE"
  if [ -n "$( ( cd "$OUTSIDE" && AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" project-env set K v ) 2>&1 >/dev/null )" ]; then
    fail "warns outside a git repository"
  else
    pass "silent outside a git repository"
  fi
else
  echo "  (git absent: gitignore warning not exercised)"
fi

# =============================================================================
section "host capacity: clamping"
# =============================================================================
# The policy is "a VM must not starve the host it runs on". These assertions
# pin the arithmetic, the floors, and the two cases where the value must be
# left alone: nothing asked, and an unreadable host.
check "half of 8 CPUs"                 "$(_agent_vm_host_share 8 1)" "4"
check "floor of 1 CPU on a 1-CPU host" "$(_agent_vm_host_share 1 1)" "1"
check "floor of 2 GiB on a 3 GiB host" "$(_agent_vm_host_share 3 2)" "2"

# A known host: 8 CPUs / 16 GiB.
_agent_vm_host_cpus()    { echo 8; }
_agent_vm_host_mem_gib() { echo 16; }

check "nothing asked stays nothing"    "$(_agent_vm_cap_resource cpus '')"  ""
check "a value under the share passes" "$(_agent_vm_cap_resource cpus 2)"   "2"
check "a value at the share passes"    "$(_agent_vm_cap_resource cpus 4)"   "4"
check "a value above the share is clamped" \
  "$(_agent_vm_cap_resource cpus 16 2>/dev/null)" "4"
check "memory is clamped too" \
  "$(_agent_vm_cap_resource memory 64 2>/dev/null)" "8"
# Clamping must be said, not done behind the user's back.
clamp_msg="$(_agent_vm_cap_resource cpus 16 2>&1 >/dev/null)"
case "$clamp_msg" in
  *"exceeds this host's share"*) pass "clamping is announced on stderr" ;;
  *) fail "clamping was silent (got: '$clamp_msg')" ;;
esac
# The share is a policy, so it is overridable.
check "AGENT_VM_HOST_SHARE=1 gives the whole host" \
  "$(AGENT_VM_HOST_SHARE=1 _agent_vm_cap_resource cpus 8)" "8"
check "AGENT_VM_HOST_SHARE=4 clamps to a quarter" \
  "$(AGENT_VM_HOST_SHARE=4 _agent_vm_cap_resource cpus 8 2>/dev/null)" "2"

# An unreadable host must never shrink anything.
_agent_vm_host_cpus()    { echo ""; }
_agent_vm_host_mem_gib() { echo ""; }
check "unknown host: the value is honoured as asked" \
  "$(_agent_vm_cap_resource cpus 16)" "16"

# Restore the real probes for anything running after this section.
unset -f _agent_vm_host_cpus _agent_vm_host_mem_gib
# shellcheck source=./agent-vm.sh
source "$AGENT_VM_SH"

# The flags stay plain integers — no new value to learn, no new way to be wrong.
check "a resource value still reaches the command" \
  "$(agent-vm --cpus 4 --memory 8 version)" "$AGENT_VM_VERSION"

# =============================================================================
section "version --min: a floor an integrator can oppose"
# =============================================================================
# Without this, every integrator reimplements the comparison — and some get
# "1.10.0 > 1.9.0" wrong, which a string comparison does.
check "1.2.3 compares as a number"  "$(_agent_vm_ver_num 1.2.3)"  "1002003"
check "1.10.0 outranks 1.9.0" \
  "$([ "$(_agent_vm_ver_num 1.10.0)" -gt "$(_agent_vm_ver_num 1.9.0)" ] && echo yes)" "yes"
check "a short version is padded"   "$(_agent_vm_ver_num 1)"      "1000000"
check "a -rc suffix is ignored"     "$(_agent_vm_ver_num 2.0.0-rc1)" "2000000"

check "plain version still prints" "$(agent-vm version)" "$AGENT_VM_VERSION"

if agent-vm version --min 0.0.1 >/dev/null 2>&1; then
  pass "a floor below the installed version passes"
else
  fail "a satisfied floor was rejected"
fi
check "a satisfied floor prints nothing" "$(agent-vm version --min 0.0.1 2>/dev/null)" ""
check "--min= spelling works too" \
  "$( (agent-vm version --min=0.0.1 >/dev/null 2>&1) && echo yes )" "yes"

agent-vm version --min 99.0.0 >/dev/null 2>&1
check "an unmet floor exits 1" "$?" "1"
# The case that separates a numeric comparison from a lexical one: against
# 0.2.0, "0.10.0" is higher as a number and lower as a string. A lexical
# implementation passes every other assertion in this section.
agent-vm version --min 0.10.0 >/dev/null 2>&1
check "0.10.0 is a higher floor than 0.2.0" "$?" "1"
too_old="$(agent-vm version --min 99.0.0 2>&1 >/dev/null)"
case "$too_old" in
  *"older than the required 99.0.0"*"git pull"*) pass "an unmet floor says what to do" ;;
  *) fail "unhelpful message for an unmet floor: $too_old" ;;
esac

# A malformed call must be distinguishable from "too old": a typo in the
# caller's own code should not send a user chasing an upgrade.
agent-vm version --min oups >/dev/null 2>&1
check "a malformed version exits 2" "$?" "2"
agent-vm version --min >/dev/null 2>&1
check "a missing value exits 2" "$?" "2"
agent-vm version --max 1 >/dev/null 2>&1
check "an unknown option exits 2" "$?" "2"

# =============================================================================
section "runtime scripts: location and interpreter"
# =============================================================================
# Before this, every runtime ran under zsh whatever its shebang said — a bash
# script silently got zsh's arrays and globbing.
RT="$SB/rt"; mkdir -p "$RT"
printf '#!/usr/bin/env bash\ntrue\n' > "$RT/env-bash.sh"
printf '#!/bin/bash\ntrue\n'         > "$RT/bin-bash.sh"
printf '#!/bin/sh\ntrue\n'           > "$RT/sh.sh"
printf '#!/usr/bin/env python3\n'    > "$RT/py.sh"
printf 'echo no shebang\n'           > "$RT/none.sh"
: > "$RT/empty.sh"
check "#!/usr/bin/env bash → bash" "$(_agent_vm_runtime_interpreter "$RT/env-bash.sh")" "bash"
check "#!/bin/bash → bash"         "$(_agent_vm_runtime_interpreter "$RT/bin-bash.sh")" "bash"
check "#!/bin/sh → sh"             "$(_agent_vm_runtime_interpreter "$RT/sh.sh")"       "sh"
check "another language → zsh (unchanged behaviour)" \
  "$(_agent_vm_runtime_interpreter "$RT/py.sh")" "zsh"
check "no shebang → zsh"           "$(_agent_vm_runtime_interpreter "$RT/none.sh")"     "zsh"
check "empty file → zsh"           "$(_agent_vm_runtime_interpreter "$RT/empty.sh")"    "zsh"

# Where the project runtime is looked up.
check "default location is the project root" \
  "$(_agent_vm_project_runtime_path "$PROJ")" "$PROJ/.agent-vm.runtime.sh"
check "a relative override resolves against the project" \
  "$(AGENT_VM_PROJECT_RUNTIME=.mytool/runtime.sh _agent_vm_project_runtime_path "$PROJ")" \
  "$PROJ/.mytool/runtime.sh"
check "an absolute override is used as-is" \
  "$(AGENT_VM_PROJECT_RUNTIME=/tmp/elsewhere.sh _agent_vm_project_runtime_path "$PROJ")" \
  "/tmp/elsewhere.sh"

# The script still reaches the VM whole: it is piped, because the per-user
# runtime lives outside the mount and its path means nothing inside the VM.
export AGENT_VM_TEST_CAPTURE="$SB/runtime-stdin"
_agent_vm_run_runtime agent-vm-proj-deadbeef "$PROJ" "$RT/env-bash.sh"
unset AGENT_VM_TEST_CAPTURE
check "the runtime is piped into the VM intact" \
  "$(cat "$SB/runtime-stdin")" "$(cat "$RT/env-bash.sh")"

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
section "setup script: apt runs with a working debconf frontend"
# =============================================================================
# `export DEBIAN_FRONTEND=noninteractive` does not survive sudo's env_reset,
# so an apt call that does not carry the variable itself prints debconf's
# "unable to initialize frontend: Dialog" block on every install step.
if grep -qE '^[^#]*sudo apt-get' "$SETUP_SH"; then
  fail "an apt call bypasses apt_get: $(grep -nE '^[^#]*sudo apt-get' "$SETUP_SH" | head -1)"
else
  pass "every apt call goes through apt_get"
fi
if grep -q 'sudo env DEBIAN_FRONTEND=noninteractive apt-get' "$SETUP_SH"; then
  pass "apt_get hands the frontend to sudo"
else
  fail "apt_get no longer passes DEBIAN_FRONTEND through sudo"
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
section "stop / rm target selection"
# =============================================================================
# The whole point of the optional name is the orphan case: a directory that was
# renamed or deleted leaves a VM no `cd` can reach, because the name hashes the
# old path. So the argument is a VM name, and it has to reach limactl untouched.
CALLS="$SB/calls"

: > "$CALLS"
out="$( export AGENT_VM_TEST_CALLS="$CALLS"; agent-vm stop agent-vm-proj-deadbeef 2>&1 )"
check "stop <name> stops the named VM" "$(cat "$CALLS")" "stop agent-vm-proj-deadbeef"

: > "$CALLS"
out="$( export AGENT_VM_TEST_CALLS="$CALLS"; agent-vm rm agent-vm-proj-deadbeef 2>&1 )"
check "rm <name> stops then deletes the named VM" \
  "$(cat "$CALLS")" "$(printf 'stop agent-vm-proj-deadbeef\ndelete agent-vm-proj-deadbeef --force')"

# A name that is not ours must not reach limactl at all: `agent-vm rm` is not a
# way to delete someone else's Lima instance by typo.
: > "$CALLS"
if out="$( export AGENT_VM_TEST_CALLS="$CALLS"; agent-vm rm some-other-lima-vm 2>&1 )"; then
  fail "rm accepted a non-agent-vm name"
else
  case "$out" in
    *"not an agent-vm VM name"*) pass "rm rejects a name outside the agent-vm- namespace" ;;
    *) fail "unexpected rejection message: $out" ;;
  esac
fi
check "the rejected name never reached limactl" "$(cat "$CALLS")" ""

: > "$CALLS"
if out="$( export AGENT_VM_TEST_CALLS="$CALLS"; agent-vm stop agent-vm-does-not-exist 2>&1 )"; then
  fail "stop accepted a VM that does not exist"
else
  case "$out" in
    *"no such VM: agent-vm-does-not-exist"*) pass "stop reports an unknown VM by name" ;;
    *) fail "unexpected message for an unknown VM: $out" ;;
  esac
fi
check "the unknown name never reached limactl" "$(cat "$CALLS")" ""

if out="$( agent-vm stop agent-vm-proj-deadbeef agent-vm-base 2>&1 )"; then
  fail "stop accepted two names"
else
  case "$out" in
    *"Usage: agent-vm stop [vm-name]"*) pass "stop refuses more than one name" ;;
    *) fail "unexpected message for two names: $out" ;;
  esac
fi

# Without an argument, the current directory still selects the VM.
PROJ_VM="$(_agent_vm_name "$PROJ")"
: > "$CALLS"
out="$( cd "$PROJ" || exit 1
        export AGENT_VM_TEST_CALLS="$CALLS" AGENT_VM_TEST_EXTRA_VM="$PROJ_VM"
        agent-vm stop 2>&1 )"
check "stop with no argument targets the current directory's VM" \
  "$(cat "$CALLS")" "stop $PROJ_VM"

: > "$CALLS"
if out="$( cd "$PROJ" || exit 1
           export AGENT_VM_TEST_CALLS="$CALLS"
           agent-vm stop 2>&1 )"; then
  fail "stop succeeded with no VM for the current directory"
else
  case "$out" in
    *"No VM found for this directory."*) pass "stop with no argument reports the empty directory" ;;
    *) fail "unexpected message for a directory with no VM: $out" ;;
  esac
fi

# =============================================================================
printf '\n%s passed, %s failed\n' "$PASSED" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

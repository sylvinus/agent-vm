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

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
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
REALDIR="$(cd -P "$(dirname "$AGENT_VM_SH")" && pwd)"
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

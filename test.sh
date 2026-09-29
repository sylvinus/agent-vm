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
  shell)
    cat > "${AGENT_VM_TEST_CAPTURE:-/dev/null}"
    if [ -n "${AGENT_VM_TEST_SHELL_FAIL:-}" ]; then echo "E: boom" >&2; exit 1; fi ;;
  start)
    echo 'time="2026-01-01T00:00:00Z" level=info msg="Attempting to download the image" arch=aarch64' >&2
    if [ -n "${AGENT_VM_TEST_START_FAIL:-}" ]; then echo 'level=fatal msg="no start"' >&2; exit 1; fi ;;
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
check "info: ssh_host is Lima's alias" "$(get ssh_host)" "lima-$(_agent_vm_name "$PROJ")"
check "info: ssh_config unknown with no VM" "$(get ssh_config)" "unknown"
check "info: key count"    "$(printf '%s\n' "$info_out" | grep -c '^[a-z_]*=')" "12"

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
check "info without limactl still prints 12 keys" \
  "$(printf '%s\n' "$nolima" | grep -c '^[a-z_]*=')" "12"
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
  "$(cd "$SB/real" && CDPATH="$SB/decoy" agent-vm info twin | wc -l | tr -d ' ')" "12"

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
check "default leaves pi out"       "$(preinstall_exports default PI)"         "0"
check "all installs pi"             "$(preinstall_exports all PI)"             "1"
check "naming pi installs it"       "$(preinstall_exports default,pi PI)"      "1"
check "pi pulls node in"            "$(preinstall_exports pi NODE)"            "1"

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

section "startup: the base VM's age"
( AGENT_VM_STATE_DIR="$SB/base-age"; mkdir -p "$AGENT_VM_STATE_DIR"
  _agent_vm_resources() { echo '1|3|10'; }
  echo $(( $(date +%s) - 3 * 86400 - 60 )) > "$AGENT_VM_STATE_DIR/.agent-vm-version-vmx"
  out="$(_agent_vm_print_resources vmx)"
  case "$out" in
    *"Base VM: built "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]", 3 days ago") echo ok ;;
    *) echo "3 days: $out" ;;
  esac
  date +%s > "$AGENT_VM_STATE_DIR/.agent-vm-version-vmx"
  case "$(_agent_vm_print_resources vmx)" in *", today") echo ok ;; *) echo "today: wrong" ;; esac
  case "$(_agent_vm_print_resources agent-vm-base)" in *"Base VM"*) echo "base: said" ;; *) echo ok ;; esac
  echo junk > "$AGENT_VM_STATE_DIR/.agent-vm-version-vmx"
  case "$(_agent_vm_print_resources vmx)" in *"Base VM"*) echo "junk: said" ;; *) echo ok ;; esac
) > "$SB/base-age.out" 2>&1
check "the date and age of the VM's base, nothing without a record" \
  "$(cat "$SB/base-age.out")" "$(printf 'ok\nok\nok\nok')"

section "boxed notices"
check "a paragraph wraps at the width" \
  "$(printf 'aaa bbb ccc ddd\n' | _agent_vm_wrap 8)" "$(printf 'aaa bbb\nccc ddd')"
check "an indented command is kept whole" \
  "$(printf '  git config --global x y\n' | _agent_vm_wrap 8)" "  git config --global x y"
box="$(printf 'one two\n\n  cmd --flag\n' | _agent_vm_box "Title" 2>&1)"
check "the box: title rule, body, bottom rule, on stderr" "$box" "$(printf '\n+- Title %s\n|\n| one two\n|\n|   cmd --flag\n|\n+%s' \
  "$(printf '%*s' 63 '' | tr ' ' -)" "$(printf '%*s' 71 '' | tr ' ' -)")"
check "nothing on stdout" "$(printf 'x\n' | _agent_vm_box "T" 2>/dev/null)" ""
if script -qec true /dev/null >/dev/null 2>&1; then
  narrow="$(script -qec "stty rows 40 cols 40; bash -c 'source \"$AGENT_VM_SH\"; _agent_vm_bare_repo_hint | _agent_vm_box \"Git: repositories not named .git\"'" /dev/null 2>&1 | tr -d '\r')"
  # Wider lines than the terminal are only the commands, kept whole.
  wide="$(printf '%s\n' "$narrow" | awk 'length($0) > 40 && $0 !~ /^\|   /')"
  check "a 40-column terminal gets a 40-column box" "$wide" ""
else
  printf '  skip narrow box test (no util-linux script)\n'
fi

section "setup: the install output"
# A pipe into the output window must not swallow the install's failure, and
# the log must keep what the window drops.
out="$(AGENT_VM_TEST_SHELL_FAIL=1 _agent_vm_setup --preinstall=none 2>&1)"
check "a failed install still fails setup" "$?" "1"
case "$out" in
  *"Setup script failed. Full log: $HOME/.agent-vm/setup.log"*) pass "the failure names the log" ;;
  *) fail "no log named: $out" ;;
esac
case "$(cat "$HOME/.agent-vm/setup.log")" in
  *"Attempting to download the image"*"E: boom") pass "one log, every step in order: the start, then the install" ;;
  *) fail "setup.log: $(cat "$HOME/.agent-vm/setup.log")" ;;
esac
out="$(AGENT_VM_TEST_START_FAIL=1 _agent_vm_setup --preinstall=none 2>&1)"
check "a failed start fails setup" "$?" "1"
case "$out" in
  *"Failed to start base VM. Full log: $HOME/.agent-vm/setup.log"*) pass "and names the log" ;;
  *) fail "start failure: $out" ;;
esac
case "$(cat "$HOME/.agent-vm/setup.log")" in
  *'msg="no start"'*) pass "which has Lima's error" ;;
  *) fail "setup.log after a failed start: $(cat "$HOME/.agent-vm/setup.log")" ;;
esac
_agent_vm_setup --preinstall=none >/dev/null 2>&1
check "a good install passes" "$?" "0"
check "no status file is left behind" "$([ -e "$HOME/.agent-vm/setup.log.status" ] && echo left || echo gone)" "gone"
check "without a terminal, every line passes through" \
  "$(printf 'a\nb' | _agent_vm_scroll_window "$SB/window.log")" "$(printf 'a\nb')"
check "and reaches the log" "$(cat "$SB/window.log")" "$(printf 'a\nb')"
# On a terminal: never more than 10 lines redrawn, and cleared at the end.
if script -qec true /dev/null >/dev/null 2>&1; then
  win="$(script -qec "stty rows 40 cols 80; bash -c 'source \"$AGENT_VM_SH\"; seq 1 30 | _agent_vm_scroll_window \"$SB/tty.log\"'" /dev/null 2>&1 | cat -v)"
  case "$win" in
    *'^[[11A'*) fail "the window grew past 10 lines" ;;
    *'^[[10A'*'^[[10A^M^[[J') pass "a 10-line window, cleared at the end" ;;
    *) fail "unexpected window output: $(printf '%s' "$win" | tail -c 200)" ;;
  esac
  check "the log keeps all 30 lines" "$(wc -l < "$SB/tty.log" | tr -d ' ')" "30"
  lima_line='time="2026-01-01T00:00:00Z" level=info msg="Attempting to download the image" arch=aarch64 digest=sha256:0123'
  win="$(script -qec "stty rows 40 cols 80; bash -c 'source \"$AGENT_VM_SH\"; printf \"%s\\n\" '\''$lima_line'\'' | _agent_vm_scroll_window \"$SB/lima.log\"'" /dev/null 2>&1 | cat -v)"
  case "$win" in
    *'[2mAttempting to download the image^M'*) pass "a Lima log line shows its message only" ;;
    *) fail "Lima line in the window: $win" ;;
  esac
  check "and the log keeps it whole" "$(cat "$SB/lima.log")" "$lima_line"
else
  printf '  skip terminal window test (no util-linux script)\n'
fi

if _agent_vm_setup --preinstall=node,not-a-real-name >/dev/null 2>&1; then
  fail "an unknown --preinstall name should be fatal"
else
  pass "an unknown --preinstall name is fatal"
fi

# =============================================================================
section "script dir resolves through symlinks"
# =============================================================================
# `agent-vm install` puts a symlink on PATH. Without following it, AGENT_VM_SCRIPT_DIR
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
section "install / uninstall"
# =============================================================================
# A throwaway HOME and bin directory. TTY=1 stands for a terminal to ask on,
# ANSWER for the reply (1 yes, 0 no), BASE=1 for a base VM already built.
IH="$SB/ihome"; IBIN="$SB/ibin"
mkdir -p "$IH"
inst() {
  ( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN" SHELL=/bin/zsh PATH="$IBIN:$PATH"
    _agent_vm_have_tty() { [ -n "${TTY:-}" ]; }
    _agent_vm_ask_yn() { echo "${ANSWER:-1}"; }
    _agent_vm_base_exists() { [ -n "${BASE:-}" ]; }
    _agent_vm_setup() { echo "SETUP RAN $#"; return "${SETUP_RC:-0}"; }
    agent-vm "$@" ) 2>&1
}
out="$(inst install)"
check "install: the link points at this agent-vm.sh" "$(readlink "$IBIN/agent-vm" 2>/dev/null)" "$REALDIR/agent-vm.sh"
case "$out" in *"not on your PATH"*) fail "install: PATH hint while the directory is on PATH" ;; *) pass "install: no PATH hint when the directory is on PATH" ;; esac
[ -e "$IH/.zshrc" ] && fail "install: rc written without a terminal to ask on" || pass "install: no terminal, the rc is left alone"
out="$( ( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; _agent_vm_have_tty() { return 1; }; agent-vm install ) 2>&1)"
case "$out" in *"already linked"*"$IBIN is not on your PATH"*'export PATH="'"$IBIN"':$PATH"'*) pass "install again: already linked, and the PATH line to add" ;; *) fail "install again: $out" ;; esac
out="$(TTY=1 inst install)"
check "yes: the rc sources agent-vm.sh" "$(grep -c "source \"$REALDIR/agent-vm.sh\"" "$IH/.zshrc" 2>/dev/null)" "1"
TTY=1 inst install >/dev/null
check "yes, twice: one source line" "$(grep -c 'agent-vm.sh' "$IH/.zshrc")" "1"
rm -f "$IH/.zshrc"
TTY=1 ANSWER=0 inst install >/dev/null
[ -e "$IH/.zshrc" ] && fail "no: the rc was written" || pass "no: the rc is left alone"
check "install takes no argument (exit 2)" "$(inst install --force >/dev/null; echo $?)" "2"

# Then setup, when there is no base yet and a terminal to ask on.
case "$(TTY=1 inst install)" in *"SETUP RAN 0"*) pass "no base, yes: setup runs" ;; *) fail "no base, yes: setup did not run" ;; esac
check "no base, setup fails: install says so" "$(TTY=1 SETUP_RC=3 inst install >/dev/null; echo $?)" "3"
out="$(TTY=1 ANSWER=0 inst install)"
case "$out" in *"SETUP RAN"*) fail "no base, no: setup ran" ;; *"agent-vm setup "*) pass "no base, no: setup is named, not run" ;; *) fail "no base, no: $out" ;; esac
out="$(inst install)"
case "$out" in *"SETUP RAN"*) fail "no terminal: setup ran" ;; *"agent-vm setup "*) pass "no terminal: setup is named, not run" ;; *) fail "no terminal: $out" ;; esac
out="$(TTY=1 BASE=1 inst install)"
case "$out" in *"SETUP RAN"*|*"agent-vm setup "*) fail "base built: setup offered again" ;; *"agent-vm claude"*) pass "base built: points at an agent instead" ;; *) fail "base built: $out" ;; esac

# Someone else's file or link at that path is never replaced.
rm -f "$IBIN/agent-vm"; echo mine > "$IBIN/agent-vm"
check "a file of the user's: refused" "$(inst install >/dev/null; echo $?)" "1"
check "and left as it was" "$(cat "$IBIN/agent-vm")" "mine"
out="$(inst uninstall)"
check "uninstall: a file of the user's is left" "$(cat "$IBIN/agent-vm")" "mine"
rm -f "$IBIN/agent-vm"; ln -s "$SB/nowhere" "$IBIN/agent-vm"
out="$(inst install)"
check "a dangling link: refused, not overwritten" "$(inst install >/dev/null; echo $?):$(readlink "$IBIN/agent-vm")" "1:$SB/nowhere"
case "$out" in *"already exists and is not a link to"*"AGENT_VM_BIN_DIR"*) pass "and says why, with the way out" ;; *) fail "dangling link: $out" ;; esac
rm -f "$IBIN/agent-vm"

# uninstall removes our link and names the rc line it leaves.
inst install >/dev/null
printf 'source "%s"\n' "$REALDIR/agent-vm.sh" > "$IH/.zshrc"
out="$(inst uninstall)"
[ ! -e "$IBIN/agent-vm" ] && [ ! -L "$IBIN/agent-vm" ] && pass "uninstall: our link is removed" || fail "uninstall: the link is still there"
case "$out" in *"still sources agent-vm.sh"*) pass "uninstall: names the rc line it leaves" ;; *) fail "uninstall: $out" ;; esac
check "uninstall: the rc is not edited" "$(cat "$IH/.zshrc")" "source \"$REALDIR/agent-vm.sh\""
case "$(inst uninstall)" in *"No link to remove"*) pass "uninstall again: nothing to remove, said" ;; *) fail "uninstall twice" ;; esac

# The wrapper kept for the previous way: install.sh, and --uninstall. The rc
# already sources agent-vm.sh here, so nothing asks on a terminal.
( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; bash "$REALDIR/install.sh" >/dev/null 2>&1 )
check "install.sh: installs" "$(readlink "$IBIN/agent-vm" 2>/dev/null)" "$REALDIR/agent-vm.sh"
( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; bash "$REALDIR/install.sh" --uninstall >/dev/null 2>&1 )
[ ! -L "$IBIN/agent-vm" ] && pass "install.sh --uninstall: uninstalls" || fail "install.sh --uninstall left the link"

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
# A shared file without a trailing newline must not glue onto the project's.
( AGENT_VM_STATE_DIR="$PENV/state"
  printf "SHARED_LAST='s'" > "$AGENT_VM_STATE_DIR/env"
  printf "BOTH='project'\n" > "$PENV/pa/.agent-vm.env"
  payload="$(_agent_vm_env_payload "$PENV/pa")"
  printf '%s\n' "$payload" | grep -qx "BOTH='project'" )
check "a shared file with no final newline stays separate" "$?" "0"

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
# It goes into arithmetic: anything but a positive integer falls back to 2,
# never to a division error, an empty value or an evaluated name.
# HOME and not an unset name: under set -u that aborts before the subscript runs.
for bad in 0 08 abc -1 '' 'HOME[$(touch '"$SB"'/pwned-share)]'; do
  check "AGENT_VM_HOST_SHARE='$bad' falls back to half" \
    "$(AGENT_VM_HOST_SHARE="$bad" _agent_vm_cap_resource cpus 8 2>/dev/null)" "4"
done
check "and nothing in it was evaluated" "$([ -e "$SB/pwned-share" ] && echo yes || echo no)" "no"
case "$(AGENT_VM_HOST_SHARE=0 _agent_vm_host_share 8 1 2>&1 >/dev/null)" in
  *"not a positive integer"*) pass "an invalid AGENT_VM_HOST_SHARE is reported" ;;
  *) fail "an invalid AGENT_VM_HOST_SHARE was silent" ;;
esac

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
vge() { if _agent_vm_ver_ge "$1" "$2" 2>/dev/null; then echo yes; else echo no; fi; }
check "1.10.0 outranks 1.9.0"          "$(vge 1.10.0 1.9.0)"     "yes"
check "1.9.0 does not reach 1.10.0"    "$(vge 1.9.0 1.10.0)"     "no"
check "equal versions pass"            "$(vge 1.2.3 1.2.3)"      "yes"
check "a short version is padded"      "$(vge 1 1.0.0)"          "yes"
check "and compared once padded"       "$(vge 1 1.0.1)"          "no"
check "a -rc suffix is ignored"        "$(vge 2.0.0-rc1 2.0.0)"  "yes"
check "0.08.0 is decimal, not octal"   "$(vge 0.8.0 0.08.0)"     "yes"
check "0.09.0 outranks 0.8.0"          "$(vge 0.09.0 0.8.0)"     "yes"
check "a component past 999 still orders" "$(vge 1.1000.0 2.0.0)" "no"
check "and does not spill into the next"  "$(vge 1.0.1000 1.1.0)" "no"

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
  *"older than the required 99.0.0"*"Update it:  "*) pass "an unmet floor says what to do" ;;
  *) fail "unhelpful message for an unmet floor: $too_old" ;;
esac
mkdir -p "$SB/upd/clone/.git" "$SB/upd/Cellar/agent-vm/1.0.0/libexec" "$SB/upd/release"
update_of() { ( AGENT_VM_SCRIPT_DIR="$1"; _agent_vm_update_command ); }
check "update: a clone pulls"        "$(update_of "$SB/upd/clone")" "git -C \"$SB/upd/clone\" pull"
check "update: a keg upgrades"       "$(update_of "$SB/upd/Cellar/agent-vm/1.0.0/libexec")" "brew upgrade agent-vm"
check "update: a release reinstalls" "$(update_of "$SB/upd/release")" "curl -fsSL https://www.agent-vm.org/install.sh | sh"

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
for verb in setup claude opencode codex vibe pi shell run stop rm destroy-all \
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
# Recommends pull in Samba, avahi-daemon, printer config... via Chromium.
if grep -E '^[^#]*apt_get install' "$SETUP_SH" | grep -qv -- '--no-install-recommends'; then
  fail "an install pulls in Recommends: $(grep -nE '^[^#]*apt_get install' "$SETUP_SH" | grep -v -- '--no-install-recommends' | head -1)"
else
  pass "every apt install skips Recommends"
fi
if grep -qE '^[^#]*\| *sudo( -E)? bash' "$SETUP_SH"; then
  fail "a remote script is piped to a root shell: $(grep -nE '^[^#]*\| *sudo( -E)? bash' "$SETUP_SH" | head -1)"
else
  pass "no remote script runs as root"
fi

# The sshfs wrapper, run against a stub that stands for /usr/bin/sshfs:
# no_contain_symlinks is added only when that sshfs knows it (#22).
sed -n '/^sudo tee \/usr\/local\/bin\/sshfs/,/^EOF$/p' "$SETUP_SH" | sed '1d;$d' \
  | sed "s|/usr/bin/sshfs|$SB/sshfs-real|g" > "$SB/sshfs-wrapper"
sshfs_stub() {  # <help text>
  printf '#!/bin/sh\n[ "$1" = -h ] && { echo "%s"; exit 1; }\necho "$*"\n' "$1" > "$SB/sshfs-real"
  chmod +x "$SB/sshfs-real"
}
sshfs_stub '    -o no_contain_symlinks allow all symlink targets'
check "sshfs wrapper: turns contain_symlinks off where it exists" \
  "$(sh "$SB/sshfs-wrapper" ':/p' /p -o slave -o allow_other)" ":/p /p -o slave -o allow_other -o no_contain_symlinks"
sshfs_stub '    -o follow_symlinks'
check "sshfs wrapper: an older sshfs gets the arguments unchanged" \
  "$(sh "$SB/sshfs-wrapper" ':/p' /p -o slave)" ":/p /p -o slave"

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
section "Pi install block"
# =============================================================================
# Lifted out like configure_mcp, with sudo recorded instead of run.
if ! command -v jq >/dev/null 2>&1; then
  printf '  skip Pi install tests (jq not installed)\n'
else
  pi_block="$(awk '/^if \[\[ "\$INSTALL_PI" == "1" \]\]; then/,/^fi$/' "$SETUP_SH")"
  run_pi_block() {
    ( HOME="$1"; INSTALL_PI=1 INSTALL_NODE="$2"
      sudo() { echo "sudo $*" >> "$HOME/sudo.log"; }
      eval "$pi_block" ) >/dev/null 2>&1
  }
  PIH="$SB/pi-home"; mkdir -p "$PIH"
  run_pi_block "$PIH" 1
  check "pi: the maintained package, without install scripts" "$(cat "$PIH/sudo.log" 2>/dev/null)" \
    "sudo npm i -g --ignore-scripts @earendil-works/pi-coding-agent"
  check "pi: project files trusted" \
    "$(jq -r .defaultProjectTrust "$PIH/.pi/agent/settings.json" 2>/dev/null)" "always"
  check "pi: telemetry off" \
    "$(jq -r .enableInstallTelemetry "$PIH/.pi/agent/settings.json" 2>/dev/null)" "false"
  PIH0="$SB/pi-home-nonode"; mkdir -p "$PIH0"
  run_pi_block "$PIH0" 0
  check "pi: skipped without node" "$( [ -e "$PIH0/sudo.log" ] || [ -e "$PIH0/.pi" ]; echo $?)" "1"
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
section "project mount mode (--readonly is a host-side flag)"
# =============================================================================
# The read-only decision has to reach Lima's mount config, the only place the
# guest cannot undo it. Assert on the JSON handed to limactl, so a revert to a
# guest-side `mount -o remount,ro` fails here instead of passing quietly.
mounts_default="$(_agent_vm_build_mounts_json agent-vm-t "$PROJ")"
mounts_rw="$(_agent_vm_build_mounts_json agent-vm-t "$PROJ" true)"
mounts_ro="$(_agent_vm_build_mounts_json agent-vm-t "$PROJ" false)"

check "default is a writable project mount" \
  "$mounts_default" "[{\"location\": \"$PROJ\", \"writable\": true}]"
check "an explicit true agrees with the default" "$mounts_rw" "$mounts_default"
check "false marks the project mount read-only" \
  "$mounts_ro" "[{\"location\": \"$PROJ\", \"writable\": false}]"

# The mode must ride on the project entry, not on whatever happens to be first
# once ~/.agent-vm/volumes contributes extra mounts.
mkdir -p "$SB/extra-vol"
printf '%s:ro\n' "$SB/extra-vol" > "$HOME/.agent-vm/volumes"
mounts_ro_vols="$(_agent_vm_build_mounts_json agent-vm-t "$PROJ" false)"
rm -f "$HOME/.agent-vm/volumes"
case "$mounts_ro_vols" in
  "[{\"location\": \"$PROJ\", \"writable\": false},"*"extra-vol"*)
    pass "read-only project mount keeps the ~/.agent-vm/volumes entries" ;;
  *) fail "volumes entries lost or reordered: $mounts_ro_vols" ;;
esac

# .git protection: Lima refuses readonlyNames unless EVERY mount uses the
# builtin driver, so the volumes entries need it as much as the project.
SSHFS_RO='"sshfs": {"sftpDriver": "builtin", "readonlyNames": [".git"]}'
printf '%s:/mnt/v:rw\n' "$SB/extra-vol" > "$HOME/.agent-vm/volumes"
mounts_prot="$(_agent_vm_build_mounts_json agent-vm-t "$PROJ" true 1)"
rm -f "$HOME/.agent-vm/volumes"
case "$mounts_prot" in
  "[{\"location\": \"$PROJ\", \"writable\": true, $SSHFS_RO}, "*) pass "protected: the project entry carries readonlyNames" ;;
  *) fail "protected project entry: $mounts_prot" ;;
esac
check "protected: every entry has the builtin driver" \
  "$(printf '%s' "$mounts_prot" | grep -o '"sftpDriver": "builtin"' | wc -l | tr -d ' ')" "2"
case "$(_agent_vm_mounts_expr '[]' 1)" in
  '.mountType = "reverse-sshfs" | .mounts = []') pass "protected: the mount type is reverse-sshfs" ;;
  *) fail "protected expression: $(_agent_vm_mounts_expr '[]' 1)" ;;
esac
# Without the protection, a reverse-sshfs left by a Lima that had it must go:
# without readonlyNames it is the weaker mount type.
case "$(_agent_vm_mounts_expr '[]' '')" in
  'del(.mountType) | .mounts = []') pass "unprotected: back to Lima's default mount type" ;;
  *) fail "unprotected expression: $(_agent_vm_mounts_expr '[]' '')" ;;
esac

# Read-only is only a real boundary for mount types the host enforces. Lima
# applies it inside the guest for reverse-sshfs and for virtiofs under QEMU,
# where root can remount it rw. $2: the VM type `limactl list` reports.
mount_fstype() {
  cat > "$SB/bin/limactl" <<STUB
#!/usr/bin/env bash
[ "\$1" = shell ] && { printf '%s\n' "$1"; exit 0; }
[ "\$1" = list ] && { printf '%s\n' "${2:-}"; exit 0; }
exit 1
STUB
  chmod +x "$SB/bin/limactl"
  _agent_vm_mount_is_host_enforced agent-vm-t "$PROJ"
  printf '%s' "$?"
}
check "virtiofs on vz is host-enforced"  "$(mount_fstype virtiofs vz)"   "0"
check "virtiofs under QEMU is not"      "$(mount_fstype virtiofs qemu)" "1"
check "virtiofs, VM type unknown: undecided" "$(mount_fstype virtiofs '')" "2"
check "9p is host-enforced"            "$(mount_fstype 9p)"         "0"
check "reverse-sshfs is not"           "$(mount_fstype fuse.sshfs)" "1"
check "an empty answer is undecided"   "$(mount_fstype '')"         "2"
# Served by the builtin server of a Lima with readonlyNames, it is. The guest
# cannot tell the servers apart: the record of the applied mounts does.
mkdir -p "$HOME/.agent-vm"
printf '[{"location": "%s", "writable": false, %s}]\n' "$PROJ" "$SSHFS_RO" > "$HOME/.agent-vm/.agent-vm-mounts-agent-vm-t"
check "reverse-sshfs with readonlyNames is" "$(mount_fstype fuse.sshfs)" "0"
rm -f "$HOME/.agent-vm/.agent-vm-mounts-agent-vm-t"
# Restore the shared stub: mount_fstype replaced it with its own.
cat > "$SB/bin/limactl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$SB/bin/limactl"

# The prompt before restarting a VM to apply --readonly must key off whether
# the VM was ALREADY running, not off whether it is running by the time we
# ask — the reconcile step sits after `limactl start`, so asking then always
# answers yes and every scripted --readonly on an existing VM would abort on
# a prompt nobody can answer.
ro_guard="$(sed -n '/want_writable" == "false" \]\] &&/p' "$AGENT_VM_SH")"
case "$ro_guard" in
  *'-n "$was_running"'*) pass "the --readonly prompt keys off was_running" ;;
  *_agent_vm_running*)   fail "the --readonly prompt re-asks after we started the VM" ;;
  *)                     fail "could not find the --readonly prompt guard" ;;
esac
case "$(sed -n '/^  local was_running=""/,/^  if \[\[ -z "$was_running" \]\]/p' "$AGENT_VM_SH")" in
  *'_agent_vm_running "$vm_name" && was_running=1'*)
    pass "was_running is sampled before the VM is started" ;;
  *) fail "was_running is not sampled before the start" ;;
esac

# =============================================================================
section "unenforceable flags are gone, not just hidden"
# =============================================================================
# Both were removed for the same reason: they were applied inside the VM, where
# the agent has passwordless sudo and could undo them. --offline was iptables
# rules, --git-read-only a bind mount. Neither can come back without the
# enforcement moving to the host, so fail here if one reappears — including as
# a silently-ignored argument, which reads to a caller like it worked.
for flag in --offline --git-read-only --git-ro; do
  if grep -q -- "$flag" "$AGENT_VM_SH"; then
    fail "$flag still referenced in agent-vm.sh"
  else
    pass "no $flag left in agent-vm.sh"
  fi
  if agent-vm "$flag" shell >/dev/null 2>&1; then
    fail "$flag was silently accepted"
  else
    pass "$flag is rejected rather than ignored"
  fi
done

# =============================================================================
section "env get/has read the file, they never run it"
# =============================================================================
# The project env file sits in a directory the VM can write to, and can arrive
# with a cloned repository. Sourcing it on the host to answer `get` ran
# whatever it contained, as the user, outside the sandbox.
RD="$SB/envread"; mkdir -p "$RD"
rd() { ( cd "$RD" && AGENT_VM_STATE_DIR="$SB/envread-state" bash "$AGENT_VM_SH" project-env "$@" ); }

printf 'X=$(touch %s/pwned-dollar)\nY=`touch %s/pwned-tick`\n' "$SB" "$SB" > "$RD/.agent-vm.env"
rd get X >/dev/null 2>&1
check "get refuses a \$(...) value (exit 2)" "$?" "2"
rd has Y >/dev/null 2>&1
check "has refuses a backquoted value (exit 2)" "$?" "2"
if [ -e "$SB/pwned-dollar" ] || [ -e "$SB/pwned-tick" ]; then
  fail "a value in the project env file was executed on the host"
else
  pass "nothing in the project env file was executed on the host"
fi
case "$(rd get X 2>&1)" in
  *"Rewrite it with 'agent-vm project-env set'"*) pass "the refusal says how to fix the entry" ;;
  *) fail "the refusal does not say what to do" ;;
esac

# Everything `set` can write must read back unchanged, including the values
# that would be code if the reader evaluated them.
: > "$RD/.agent-vm.env"
for v in "O'Brien" '$(echo hi)' '`id`' 'a\b' 'two words' '"dq"' '~/x' "line1
line2"; do
  rd set K "$v" >/dev/null 2>&1
  check "set/get round trip: $(printf '%s' "$v" | tr '\n' '|')" "$(rd get K)" "$v"
done
rd set EMPTY "" >/dev/null 2>&1
rd has EMPTY && pass "an empty value is present" || fail "an empty value reads as absent"
check "an empty value reads back empty" "$(rd get EMPTY)" ""

# A value spanning lines must not create keys out of its own content.
rd set MULTI "first
PHANTOM=injected" >/dev/null 2>&1
rd has PHANTOM && fail "a line inside a quoted value was read as a key" \
  || pass "a line inside a quoted value is not a key"

# Plain dotenv lines written by hand.
cat > "$RD/.agent-vm.env" <<'EOF'
# a comment
A=plain
export B=exported
  C="double quoted"
D=value # trailing comment
E='a'"b"c
F=first
F=second
H=~/somewhere
I="$HOME"
EOF
printf 'G=crlf\r\n' >> "$RD/.agent-vm.env"
check "plain value"                  "$(rd get A)" "plain"
check "export prefix"                "$(rd get B)" "exported"
check "leading blanks, double quotes" "$(rd get C)" "double quoted"
check "trailing comment"             "$(rd get D)" "value"
check "concatenated quoting"         "$(rd get E)" "abc"
check "the last assignment wins"     "$(rd get F)" "second"
check "a CRLF line ending is dropped" "$(rd get G)" "crlf"
rd get H >/dev/null 2>&1
check "an unquoted ~ (host-dependent) is refused" "$?" "2"
rd get I >/dev/null 2>&1
check "an expansion inside double quotes is refused" "$?" "2"
rd get NOT_THERE >/dev/null 2>&1
check "an absent key exits 1" "$?" "1"

# =============================================================================
section "project paths that would rewrite the mount config are refused"
# =============================================================================
# The path is spliced into the yq expression given to `limactl edit --set`. A
# quote in a directory name used to end the string and let the name add mounts
# of its own: `a","writable":true},{"location":"~",...` mounted the home
# directory read-write, --readonly or not.
for d in "$SB/"'q"uote' "$SB/"'back\slash'; do
  mkdir -p "$d"
  out="$(_agent_vm_ensure_running agent-vm-x "$d" 2>&1)"
  rc=$?
  case "$rc:$out" in
    1:*"a quote, a backslash or a control character"*) pass "refused: $(basename "$d")" ;;
    *) fail "not refused: $(basename "$d") ($rc: $out)" ;;
  esac
done

# =============================================================================
section "VM names need a hash, and get one without shasum"
# =============================================================================
# Without a hash, every directory named `proj` shared the VM `agent-vm-proj-`.
HB="$SB/hashbin"; mkdir -p "$HB/none" "$HB/sha256sum-only"
for t in cut basename tr sed; do
  ln -sf "$(command -v "$t")" "$HB/none/$t"
  ln -sf "$(command -v "$t")" "$HB/sha256sum-only/$t"
done
out="$(PATH="$HB/none"; _agent_vm_name /x/proj 2>&1)"
rc=$?
case "$rc:$out" in
  1:*"install shasum or sha256sum"*) pass "no hash tool: naming fails instead of dropping the hash" ;;
  *) fail "no hash tool: got $rc '$out'" ;;
esac
if command -v sha256sum >/dev/null 2>&1; then
  ln -sf "$(command -v sha256sum)" "$HB/sha256sum-only/sha256sum"
  check "sha256sum gives the same name as shasum" \
    "$(PATH="$HB/sha256sum-only"; _agent_vm_name /x/proj)" "$(_agent_vm_name /x/proj)"
else
  printf '  skip sha256sum fallback (not installed here)\n'
fi

# =============================================================================
section "commands against a recording limactl"
# =============================================================================
# One stub for the sections below. It logs every call, lists the base template
# and the VM named by AGENT_VM_TEST_VM, and reports the project share as
# virtiofs (AGENT_VM_TEST_FSTYPE to change it) on vz (AGENT_VM_TEST_VMTYPE). With AGENT_VM_TEST_CLONED set,
# that VM only exists once `clone` has created the file. AGENT_VM_TEST_STOPPED
# lists it as stopped, and AGENT_VM_TEST_RO makes the project write probe fail,
# as a read-only share would. `validate` answers like stock Lima 2.2 does to
# readonlyNames, or, while the file $PROTECTS exists, like a Lima that has it
# (both messages copied from the real binaries).
REC="$SB/rec.log"
PROTECTS="$SB/lima-protects"
cat > "$SB/bin/limactl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENT_VM_TEST_REC"
listed() { [ -z "${AGENT_VM_TEST_CLONED:-}" ] || [ -e "$AGENT_VM_TEST_CLONED" ]; }
case "$1" in
  --version) echo "limactl version 2.0.3" ;;
  validate)
    if [ -e "${AGENT_VM_TEST_PROTECTS:-/nonexistent}" ]; then
      echo 'level=fatal msg="failed to validate YAML file `probe.yaml`: field `mounts[*].sshfs.readonlyNames` requires `mountType` to be `reverse-sshfs`"' >&2
      exit 1
    fi
    echo 'level=warning msg="Non-strict YAML detected; please check for typos" error="[3:158] unknown field \"readonlyNames\""' >&2
    echo 'level=info msg="`probe.yaml`: OK"' >&2 ;;
  clone)
    [ -z "${AGENT_VM_TEST_CLONE_FAIL:-}" ] || { echo 'level=fatal msg="clone boom"' >&2; exit 1; }
    [ -n "${AGENT_VM_TEST_CLONED:-}" ] && touch "$AGENT_VM_TEST_CLONED" ;;
  edit) [ -z "${AGENT_VM_TEST_EDIT_FAIL:-}" ] || { echo 'level=fatal msg="edit boom"' >&2; exit 1; } ;;
  list)
    case "$*" in
      *"{{.Name}} {{.Config.SSH.LocalPort}}"*)
        echo "agent-vm-base 0"
        [ -z "${AGENT_VM_TEST_OTHER_PORT:-}" ] || echo "agent-vm-other-00000000 $AGENT_VM_TEST_OTHER_PORT"
        listed && echo "$AGENT_VM_TEST_VM ${AGENT_VM_TEST_SSH_PORT:-0}" ;;
      *"{{.Config.SSH.LocalPort}}"*) listed && echo "${AGENT_VM_TEST_SSH_PORT:-0}" ;;
      *"{{.SSHConfigFile}}"*) listed && echo "/lima/$AGENT_VM_TEST_VM/ssh.config" ;;
      *"{{.VMType}}"*) echo "${AGENT_VM_TEST_VMTYPE:-vz}" ;;
      *"{{.CPUs}}"*"{{.Disk}}"*) listed && echo "$AGENT_VM_TEST_VM|1|3221225472|10737418240" ;;
      *"{{.Status}}|"*) listed && echo "$AGENT_VM_TEST_VM|Running|1|3221225472" ;;
      *"{{.Status}}"*)
        echo "agent-vm-base Stopped"
        listed && echo "$AGENT_VM_TEST_VM ${AGENT_VM_TEST_STOPPED:+Stopped}${AGENT_VM_TEST_STOPPED:-Running}" ;;
      *-q*) echo "agent-vm-base"; listed && echo "$AGENT_VM_TEST_VM" ;;
      *)
        echo "NAME STATUS"
        [ -n "${AGENT_VM_TEST_NOVMS:-}" ] && exit 0
        echo "agent-vm-base Stopped"; listed && echo "$AGENT_VM_TEST_VM Running" ;;
    esac ;;
  shell)
    case "$*" in
      *findmnt*) echo "${AGENT_VM_TEST_FSTYPE:-virtiofs}" ;;
      *agent-vm-write-probe*)
        case "$*" in *'.agent-vm.env'*) cat >/dev/null; [ -n "${AGENT_VM_TEST_ENV_FAIL:-}" ] || echo env-ok ;; esac
        [ -z "${AGENT_VM_TEST_RO:-}" ] || exit 1 ;;
    esac ;;
  stop) cat >/dev/null ;;
  delete) [ -z "${AGENT_VM_TEST_CLONED:-}" ] || rm -f "$AGENT_VM_TEST_CLONED"; cat >/dev/null ;;
esac
exit 0
STUB
chmod +x "$SB/bin/limactl"
mkdir -p "$HOME/.agent-vm"
echo 1 > "$HOME/.agent-vm/.agent-vm-base-version"
PV="$(_agent_vm_name "$PROJ")"
# Re-sourced by an earlier section, so stubbed again: no KVM on a test runner.
_agent_vm_check_linux_prereqs() { return 0; }
rec() {
  : > "$REC"
  ( cd "$PROJ" || exit 1
    export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$PV" AGENT_VM_TEST_PROTECTS="$PROTECTS"
    agent-vm "$@" </dev/null 2>&1 )
}
rec_has() { grep -qF -- "$1" "$REC"; }

section "VM options are read before the command only"
# `agent-vm run docker run --rm x` used to take docker's --rm for its own: the
# container ran without it, and the VM was deleted afterwards.
rec run docker run --rm hello >/dev/null
rec_has "agent-vm docker run --rm hello" && pass "run: --rm reaches the command" \
  || fail "run: --rm was taken from the command: $(grep ' zsh ' "$REC")"
rec_has "delete" && fail "run: the VM was deleted" || pass "run: the VM is kept"

rec claude -p hi --rm >/dev/null
rec_has "claude --dangerously-skip-permissions -p hi --rm" && pass "claude: a later --rm is claude's" \
  || fail "claude: arguments changed: $(grep ' zsh ' "$REC")"
rec_has "delete" && fail "claude: the VM was deleted" || pass "claude: the VM is kept"

rec --rm run true >/dev/null
rec_has "delete $PV" && pass "--rm before the command still deletes the VM" \
  || fail "--rm before the command was lost"
rec claude --rm >/dev/null
rec_has "delete $PV" && pass "--rm right after the agent name is still agent-vm's" \
  || fail "--rm right after the agent name was passed to the agent"
rec run --tty htop >/dev/null
rec_has "shell --workdir $PROJ --tty $PV" && pass "run --tty still allocates a PTY" \
  || fail "run --tty lost: $(grep ' zsh ' "$REC")"
rec run -- --weird-name >/dev/null
rec_has "agent-vm --weird-name" && pass "-- ends the options" || fail "-- not honoured"

rec pi -p hi --rm >/dev/null
rec_has "shell --workdir $PROJ --tty $PV" && rec_has "agent-vm pi -p hi --rm" \
  && pass "pi: a TTY, and the arguments are pi's" || fail "pi: $(grep 'zsh' "$REC")"

# With no env left on the host, the guest copy must go too, not keep old secrets.
rm -f "$HOME/.agent-vm/env" "$PROJ/.agent-vm.env"
rec run true >/dev/null
rec_has 'cat > "$HOME/.agent-vm.env"' && pass "an empty env still replaces the guest file" \
  || fail "an empty env left the guest file as it was"

# Each `limactl shell` is a round trip: the env push and the write probe share one.
out="$(rec run true)"
# The script is multi-line, so one call spans lines of the record: the push's
# line is followed by the probe's, which is not a new `shell …` call of its own.
check "one round trip for the env push and the probe" \
  "$(grep -c 'agent-vm.env' "$REC") $(grep -c 'agent-vm-write-probe' "$REC") $(grep -A1 'agent-vm.env' "$REC" | tail -1 | grep -v '^shell ' | grep -c 'agent-vm-write-probe')" "1 1 1"
check "a push that worked is not warned about" \
  "$(printf '%s\n' "$out" | grep -c 'failed to push the env')" "0"
out="$(AGENT_VM_TEST_ENV_FAIL=1 rec run true)"
case "$out" in
  *"Warning: failed to push the env files"*) pass "a failed push is still said" ;;
  *) fail "a failed push went unsaid: $out" ;;
esac

# `shell` takes no command, so a word it does not know is a mistake: it used to
# be skipped, which reads to the caller as if the flag had applied.
out="$(rec shell --offline)"
case "$out" in
  *"unknown argument for shell: --offline"*) pass "shell rejects an unknown argument" ;;
  *) fail "shell accepted --offline: $out" ;;
esac
rec_has "shell --workdir" && fail "shell opened a session anyway" || pass "no session is opened"

section "--ssh-port and the SSH alias"
check "info: ssh_config once the VM exists" \
  "$(rec info | grep '^ssh_config=')" "ssh_config=/lima/$PV/ssh.config"
out="$(AGENT_VM_TEST_STOPPED=1 rec --ssh-port 2222 run true)"
rec_has "edit $PV --set .ssh.localPort = 2222" && pass "--ssh-port: set on a stopped VM" \
  || fail "--ssh-port not set: $(grep '^edit' "$REC") $out"
AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_SSH_PORT=2222 rec --ssh-port 2222 run true >/dev/null
rec_has "localPort" && fail "--ssh-port: the same port was set again" || pass "--ssh-port: the same port is left alone"
AGENT_VM_TEST_STOPPED=1 rec run claude --ssh-port 2222 >/dev/null
rec_has "localPort" && fail "--ssh-port after the command was taken" || pass "--ssh-port after the command is the command's"
AGENT_VM_TEST_STOPPED=1 rec claude --ssh-port 2223 >/dev/null
rec_has "edit $PV --set .ssh.localPort = 2223" && pass "--ssh-port right after the agent name is agent-vm's" \
  || fail "claude --ssh-port lost: $(grep '^edit' "$REC")"
AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_SSH_PORT=2222 rec --ssh-port 0 run true >/dev/null
rec_has "edit $PV --set .ssh.localPort = 0" && pass "--ssh-port 0: back to a port Lima picks" \
  || fail "--ssh-port 0 not set: $(grep '^edit' "$REC")"
out="$(AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_OTHER_PORT=2222 rec --ssh-port 2222 run true)"
case "$?:$out" in
  1:*"SSH port 2222 is already set for VM 'agent-vm-other-00000000'"*) pass "--ssh-port: a port another VM has is refused" ;;
  *) fail "--ssh-port: taken port not refused: $out" ;;
esac
rec_has "localPort =" && fail "a taken port was set anyway" || pass "and nothing is changed"
for bad in 80 70000 abc ""; do
  out="$(rec --ssh-port "$bad" run true)"
  case "$?:$out" in
    1:*"--ssh-port must be 0 or a port from 1024 to 65535"*) pass "--ssh-port '$bad' refused" ;;
    *) fail "--ssh-port '$bad' accepted: $out" ;;
  esac
done
out="$(rec claude --ssh-port 80)"
case "$?:$out" in
  1:*"--ssh-port must be"*) pass "claude --ssh-port 80 refused too" ;;
  *) fail "claude --ssh-port 80 accepted: $out" ;;
esac
CLONED="$SB/cloned-port"; rm -f "$CLONED"
AGENT_VM_TEST_CLONED="$CLONED" rec --ssh-port 2224 run true >/dev/null
grep '^edit' "$REC" | head -1 | grep -qF -- "--set .ssh.localPort = 2224" \
  && pass "new VM: the port is set with the mounts, before the first start" \
  || fail "new VM: $(grep '^edit' "$REC")"

section "a VM that cannot be configured is not kept (#21)"
# The edit giving a new VM its shares and resources used to fail in silence:
# the VM then ran with the template's config, ~/.agent-vm/volumes entries gone.
CLONED="$SB/cloned-fail"; rm -f "$CLONED"
out="$(AGENT_VM_TEST_CLONED="$CLONED" AGENT_VM_TEST_EDIT_FAIL=1 rec --memory 2 run true)"
case "$?:$out" in
  1:*"could not configure the new VM '$PV'"*"edit boom"*) pass "a failed edit is said, with Lima's message" ;;
  *) fail "a failed edit: $out" ;;
esac
rec_has "delete $PV --force" && pass "and the half-made VM is deleted" || fail "the half-made VM is kept"
rec_has "start $PV" && fail "the VM was started anyway" || pass "and it is not started"
[ -e "$HOME/.agent-vm/.agent-vm-mounts-$PV" ] && fail "its mounts are still recorded" \
  || pass "and no mounts are recorded for it"
out="$(AGENT_VM_TEST_CLONED="$CLONED" AGENT_VM_TEST_CLONE_FAIL=1 rec run true)"
case "$?:$out" in
  1:*"could not clone the base template into '$PV'"*"clone boom"*) pass "a failed clone is said too" ;;
  *) fail "a failed clone: $out" ;;
esac
rec_has "edit $PV" && fail "a failed clone was edited anyway" || pass "and nothing is done after it"

section "~/.agent-vm/volumes: entries limited to some projects"
mkdir -p "$SB/vol-f"
vols() { printf '%s\n' "$@" > "$HOME/.agent-vm/volumes"; _agent_vm_build_mounts_json "$PV" "$PROJ" true 2>"$SB/vols-err"; }
has_vol() { case "$1" in *"\"location\": \"$SB/vol-f\""*) echo yes ;; *) echo no ;; esac; }
check "filter: the project's own path" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$PROJ")")" yes
check "filter: a trailing slash is the same path" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$PROJ/")")" yes
check "filter: another project's path" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$SB/other")")" no
check "filter: a parent is not a match" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$SB")")" no
check "filter: * matches below a directory" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$SB/*")")" yes
check "filter: * does not match elsewhere" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:/nowhere/*")")" no
check "filter: ~ is expanded" \
  "$( HOME="$SB"; _agent_vm_volume_matches '~/proj' "$PROJ" && echo yes || echo no )" yes
check "filter: mode rw is kept" \
  "$(vols "$SB/vol-f:/mnt/f:rw:$PROJ" | grep -o "\"location\": \"$SB/vol-f\", \"mountPoint\": \"/mnt/f\", \"writable\": true")" \
  "\"location\": \"$SB/vol-f\", \"mountPoint\": \"/mnt/f\", \"writable\": true"
check "filter: no destination mounts at the same path" \
  "$(vols "$SB/vol-f::ro:$PROJ" | grep -c "{\"location\": \"$SB/vol-f\", \"writable\": false}")" 1
check "filter: no destination, short form" \
  "$(vols "$SB/vol-f:ro:$PROJ" | grep -c "{\"location\": \"$SB/vol-f\", \"writable\": false}")" 1
out="$(vols "$SB/vol-f:/mnt/f:ro:relative/path")"
check "filter: a relative one matches nothing" "$(has_vol "$out")" no
grep -q "Project filter 'relative/path'.*not an absolute path" "$SB/vols-err" \
  && pass "filter: and says why" || fail "filter: relative filter not reported: $(cat "$SB/vols-err")"
# A relative destination is inside the project, and made on the host.
out="$(vols "$SB/vol-f:.claude:ro:$PROJ")"
check "relative: inside the project" \
  "$(printf '%s' "$out" | grep -c "\"location\": \"$SB/vol-f\", \"mountPoint\": \"$PROJ/.claude\"")" 1
[ -d "$PROJ/.claude" ] && pass "relative: the mount point is made on the host" || fail "relative: no $PROJ/.claude"
vols "$SB/vol-f:./a/b:ro" >/dev/null
[ -d "$PROJ/a/b" ] && pass "relative: ./ and subdirectories" || fail "relative: no $PROJ/a/b"
mkdir -p "$SB/outside"
out="$(vols "$SB/vol-f:../outside/x:ro")"
check "relative: .. is refused" "$(has_vol "$out")" no
grep -q "goes out of the project with '..'" "$SB/vols-err" && [ ! -e "$SB/outside/x" ] \
  && pass "relative: and nothing is made outside" || fail "relative ..: $(cat "$SB/vols-err")"
ln -s "$SB/outside" "$PROJ/planted"
out="$(vols "$SB/vol-f:planted/x:ro")"
check "relative: a symlink in the project is refused" "$(has_vol "$out")" no
grep -q "goes through a symlink in the project" "$SB/vols-err" && [ ! -e "$SB/outside/x" ] \
  && pass "relative: and mkdir does not follow it" || fail "relative symlink: $(cat "$SB/vols-err"); $(ls "$SB/outside")"
out="$(vols "$SB/vol-f:.:ro")"
check "relative: the project itself is refused" "$(has_vol "$out")" no
echo x > "$SB/vol-file.toml"
vols "$SB/vol-file.toml:conf/app.toml" >/dev/null
[ -f "$PROJ/conf/app.toml" ] && pass "relative, a file: an empty file is its mount point" || fail "relative file: no placeholder"
grep -q "|$PROJ/conf/app.toml\$" "$HOME/.agent-vm/.agent-vm-file-mounts-$PV" \
  && pass "relative, a file: bound at that path" || fail "relative file: $(cat "$HOME/.agent-vm/.agent-vm-file-mounts-$PV")"
rm -rf "$PROJ/.claude" "$PROJ/a" "$PROJ/planted" "$PROJ/conf" "$SB/outside" "$SB/vol-file.toml"
check "no filter: every project, as before" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro")")" yes
check "no filter, no mode: as before" \
  "$(vols "$SB/vol-f:/mnt/f" | grep -c "\"mountPoint\": \"/mnt/f\", \"writable\": false")" 1
rm -f "$HOME/.agent-vm/volumes"

section "--readonly makes every share read-only"
# The hypervisor enforces read-only per share, not per host file. A writable
# volume containing the project (~/work:/mnt/work:rw) was a way to write the
# project under --readonly without root.
mkdir -p "$SB/vol-rw" "$SB/vol-ro"
printf '%s:/mnt/rw:rw\n%s:/mnt/ro\n' "$SB/vol-rw" "$SB/vol-ro" > "$HOME/.agent-vm/volumes"
ro_json="$(_agent_vm_build_mounts_json "$PV" "$PROJ" false 2>"$SB/ro-notice")"
rw_json="$(_agent_vm_build_mounts_json "$PV" "$PROJ" true 2>/dev/null)"
case "$ro_json" in
  *'"writable": true'*) fail "a share stays writable under --readonly: $ro_json" ;;
  *) pass "no share is writable under --readonly" ;;
esac
case "$rw_json" in
  *"\"location\": \"$SB/vol-rw\", \"mountPoint\": \"/mnt/rw\", \"writable\": true"*)
    pass "without it, an rw volume is writable again" ;;
  *) fail "rw volume not restored: $rw_json" ;;
esac
case "$(cat "$SB/ro-notice")" in
  *"'$SB/vol-rw' (rw in ~/.agent-vm/volumes) is mounted read-only too"*) pass "the downgrade is announced" ;;
  *) fail "no notice for the downgraded volume" ;;
esac

# An existing VM whose project is already read-only: the probe agrees with
# --readonly, so only the record of applied mounts can say a volume is still
# writable. Stopped, so no prompt is needed.
REC_MOUNTS="$HOME/.agent-vm/.agent-vm-mounts-$PV"
ro_run() { AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 rec --readonly run true >/dev/null; }
printf '%s\n' "[{\"location\": \"$PROJ\", \"writable\": false}, {\"location\": \"$SB/vol-rw\", \"writable\": true}]" > "$REC_MOUNTS"
ro_run
rec_has "edit $PV --set del(.mountType) | .mounts" && pass "a recorded writable volume forces a remount" \
  || fail "a writable volume survived --readonly"
_agent_vm_mounts_all_readonly "$PV" && pass "the new record has no writable share" \
  || fail "the record still has a writable share: $(cat "$REC_MOUNTS")"
ro_run
rec_has "edit $PV" && fail "an all read-only VM was remounted again" \
  || pass "an all read-only VM is left alone"
# Back to writable: the end of a --readonly session is said as such, not as a
# broken mount being repaired.
out="$(AGENT_VM_TEST_RO=1 rec run true)"
case "$out" in *"left read-only by --readonly; making it writable again"*) pass "after --readonly: says it is making the VM writable again" ;; *) fail "after --readonly: $out" ;; esac
printf '[{"location": "%s", "writable": true}]\n' "$PROJ" > "$REC_MOUNTS"
out="$(AGENT_VM_TEST_RO=1 rec run true)"
case "$out" in *"Project mount is not writable; repairing"*) pass "a writable VM that cannot write: a repair" ;; *) fail "broken mount: $out" ;; esac
rm -f "$REC_MOUNTS"
ro_run
rec_has "edit $PV --set del(.mountType) | .mounts" && pass "no record (an older VM): remounted to be sure" \
  || fail "an unrecorded VM was trusted"
_agent_vm_cleanup_state "$PV"
[ -e "$REC_MOUNTS" ] && fail "rm/--reset left the mounts record" || pass "rm/--reset drops the mounts record"
rm -f "$HOME/.agent-vm/volumes"

section ".git protection follows what Lima can do"
# Stock Lima accepts readonlyNames with a warning and ignores it, so only a
# refusal that names the field counts. Stock Lima failing for another reason
# still names it, in its "unknown field" warning: that is not support either.
probe() {
  ( export AGENT_VM_TEST_REC="$SB/probe.log" AGENT_VM_TEST_PROTECTS="$PROTECTS" TMPDIR="$SB/probe-tmp"
    _agent_vm_lima_protects_git ) && echo yes || echo no
}
mkdir -p "$SB/probe-tmp"
rm -f "$PROTECTS"
check "stock Lima: no protection" "$(probe)" "no"
touch "$PROTECTS"
check "a Lima with readonlyNames: protection" "$(probe)" "yes"
check "the probe leaves no temporary file" "$(ls -A "$SB/probe-tmp")" ""
mkdir -p "$SB/stock-err"
cat > "$SB/stock-err/limactl" <<'STUB'
#!/usr/bin/env bash
echo 'level=warning msg="Non-strict YAML detected" error="[2:47] unknown field \"readonlyNames\""' >&2
echo 'level=fatal msg="failed to validate YAML file `probe.yaml`: field `images` must be set"' >&2
exit 1
STUB
chmod +x "$SB/stock-err/limactl"
check "stock Lima failing for another reason: no protection" "$(PATH="$SB/stock-err:$PATH" probe)" "no"
mkdir -p "$SB/nolimactl"
for t in mktemp rm; do ln -sf "$(command -v "$t")" "$SB/nolimactl/$t"; done
check "no limactl: no protection" "$(PATH="$SB/nolimactl" probe)" "no"

# A new VM gets reverse-sshfs and readonlyNames on every share.
CLONED="$SB/cloned-prot"; rm -f "$CLONED" "$REC_MOUNTS"
AGENT_VM_TEST_CLONED="$CLONED" rec run true >/dev/null
rec_has "edit $PV --set .mountType = \"reverse-sshfs\" | .mounts = [{\"location\": \"$PROJ\", \"writable\": true, $SSHFS_RO}]" \
  && pass "new VM: reverse-sshfs, every .git read-only" || fail "new VM not protected: $(grep '^edit' "$REC")"
_agent_vm_mounts_protect_git "$PV" && pass "new VM: recorded as protected" || fail "new VM: record not protected"

# An existing VM set up before: changed while it is stopped, before it starts,
# so it is not started a second time.
unprotected_rec() { printf '[{"location": "%s", "writable": true}]\n' "$PROJ" > "$REC_MOUNTS"; }
protected_rec() { printf '[{"location": "%s", "writable": %s, %s}]\n' "$PROJ" "${1:-true}" "$SSHFS_RO" > "$REC_MOUNTS"; }
unprotected_rec
out="$(AGENT_VM_TEST_STOPPED=1 rec run true)"
e="$(grep -n "^edit $PV --set .mountType = \"reverse-sshfs\"" "$REC" | head -1 | cut -d: -f1)"
s="$(grep -n "^start $PV" "$REC" | head -1 | cut -d: -f1)"
if [ -n "$e" ] && [ -n "$s" ] && [ "$e" -lt "$s" ]; then
  pass "stopped VM from before: protected before it starts"
else
  fail "stopped VM from before: edit at '${e:-none}', start at '${s:-none}'"
fi
check "stopped VM from before: started once" "$(grep -c "^start $PV" "$REC")" "1"
case "$out" in *"Making every .git read-only for VM '$PV'"*) pass "and it says so" ;; *) fail "no notice: $out" ;; esac

# A running one is not restarted behind another session's back: warned.
unprotected_rec
out="$(rec run true)"
rec_has "edit $PV" && fail "a running VM was changed" || pass "running VM from before: left running"
case "$out" in *"can still write .git"*"'agent-vm stop'"*) pass "running VM from before: says how to protect it" ;; *) fail "no warning: $out" ;; esac

# Back to a Lima without readonlyNames: reverse-sshfs goes, before the start.
rm -f "$PROTECTS"
protected_rec
AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
rec_has "edit $PV --set del(.mountType) | .mounts = [{\"location\": \"$PROJ\", \"writable\": true}]" \
  && pass "Lima without readonlyNames: the VM goes back to the default mount type" \
  || fail "reverse-sshfs kept without readonlyNames: $(grep '^edit' "$REC")"
_agent_vm_mounts_protect_git "$PV" && fail "the record still says protected" || pass "and the record says so"

# --readonly on reverse-sshfs: enforced on the host by the builtin server of a
# Lima with readonlyNames, and refused otherwise.
touch "$PROTECTS"
protected_rec false
out="$(AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 AGENT_VM_TEST_FSTYPE=fuse.sshfs rec --readonly run true)"
case "$out" in *"enforced on the host"*) pass "--readonly on protected reverse-sshfs: accepted" ;; *) fail "--readonly on protected reverse-sshfs: $out" ;; esac
rm -f "$PROTECTS"
printf '[{"location": "%s", "writable": false}]\n' "$PROJ" > "$REC_MOUNTS"
out="$(AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 AGENT_VM_TEST_FSTYPE=fuse.sshfs rec --readonly run true)"
case "$out" in *"--readonly cannot be enforced"*) pass "--readonly on plain reverse-sshfs: refused" ;; *) fail "--readonly on plain reverse-sshfs: $out" ;; esac

# The opt-out: .git writable although this Lima could protect it, said on
# every run.
touch "$PROTECTS"
protected_rec
out="$(AGENT_VM_UNSAFE_WRITABLE_GIT=1 rec run true)"
rec_has "edit $PV" && fail "opt-out: a running VM was changed" || pass "opt-out: a running VM is left running"
case "$out" in *"keeps .git read-only until it stops"*) pass "and it says .git stays read-only until then" ;; *) fail "opt-out, running VM: $out" ;; esac
out="$(AGENT_VM_UNSAFE_WRITABLE_GIT=1 AGENT_VM_TEST_STOPPED=1 rec run true)"
rec_has "edit $PV --set del(.mountType) | .mounts = [{\"location\": \"$PROJ\", \"writable\": true}]" \
  && pass "opt-out: a stopped protected VM gets .git writable, on the default mount type" \
  || fail "opt-out: shares kept protected: $(grep '^edit' "$REC")"
case "$out" in *"WARNING: AGENT_VM_UNSAFE_WRITABLE_GIT=1"*) pass "opt-out: the warning is printed" ;; *) fail "opt-out: no warning: $out" ;; esac
out="$(AGENT_VM_UNSAFE_WRITABLE_GIT=1 rec run true)"
rec_has "edit $PV" && fail "opt-out: an unprotected VM was edited again" || pass "opt-out: nothing to change the next time"
case "$out" in *"WARNING: AGENT_VM_UNSAFE_WRITABLE_GIT=1"*) pass "opt-out: the warning is printed on every run" ;; *) fail "opt-out: no warning the next time: $out" ;; esac
AGENT_VM_UNSAFE_WRITABLE_GIT=yes AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
rec_has "edit $PV --set .mountType = \"reverse-sshfs\"" && pass "only 1 is the opt-out: 'yes' keeps .git protected" \
  || fail "AGENT_VM_UNSAFE_WRITABLE_GIT=yes turned the protection off"

# The same as a VM option, before the command or right after its name.
out="$(AGENT_VM_TEST_STOPPED=1 rec --unsafe-writable-git run true)"
rec_has "edit $PV --set del(.mountType) | .mounts = [{\"location\": \"$PROJ\", \"writable\": true}]" \
  && pass "--unsafe-writable-git: .git writable" || fail "--unsafe-writable-git ignored: $(grep '^edit' "$REC")"
case "$out" in *"WARNING: --unsafe-writable-git."*) pass "--unsafe-writable-git: the warning names the flag" ;; *) fail "--unsafe-writable-git: $out" ;; esac
protected_rec
AGENT_VM_TEST_STOPPED=1 rec run --unsafe-writable-git=1 true >/dev/null
rec_has "edit $PV --set del(.mountType)" && pass "run --unsafe-writable-git=1: .git writable" \
  || fail "run --unsafe-writable-git=1 ignored: $(grep '^edit' "$REC")"
rec_has "agent-vm-write-probe" && ! rec_has "unsafe-writable-git" && pass "and the flag does not reach the command" \
  || fail "the flag reached the command: $(grep -v '^edit' "$REC" | tail -2)"
# Without it, the next run protects again. agent-vm is a shell function too,
# where a flag leaking out of its call would stay on for the rest of the shell.
unset _agent_vm_unsafe_git_flag
( cd "$PROJ" && export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$PV" AGENT_VM_TEST_PROTECTS="$PROTECTS" AGENT_VM_TEST_STOPPED=1
  agent-vm --unsafe-writable-git run true >/dev/null 2>&1
  [ -z "${_agent_vm_unsafe_git_flag:-}" ] || echo leaked
  : > "$REC"
  agent-vm run true >/dev/null 2>&1 ) > "$SB/leak.out"
check "the flag does not outlive its command" "$(cat "$SB/leak.out")" ""
rec_has "edit $PV --set .mountType = \"reverse-sshfs\"" && pass "the next run without it protects .git again" \
  || fail "not protected after the flag: $(grep '^edit' "$REC")"
case "$(agent-vm setup --unsafe-writable-git 2>&1 </dev/null)" in
  *"Unknown option: --unsafe-writable-git"*) pass "setup rejects --unsafe-writable-git" ;;
  *) fail "setup accepted --unsafe-writable-git" ;;
esac
rm -f "$PROTECTS"
_agent_vm_cleanup_state "$PV"

section "a new VM prints its resources once"
CLONED="$SB/cloned"; rm -f "$CLONED"
out="$(AGENT_VM_TEST_CLONED="$CLONED" rec run true)"
check "one Resources line on the first run" "$(printf '%s\n' "$out" | grep -c 'Resources:')" "1"

section "status"
out="$(rec status)"
case "$out" in
  *"> $PV Running"*) pass "the current directory's VM is marked" ;;
  *) fail "current VM not marked: $out" ;;
esac
case "$out" in *"(no VMs)"*) fail "(no VMs) printed next to VMs" ;; *) pass "no '(no VMs)' when there are VMs" ;; esac
# Without pipefail, as in an interactive shell: the old piped loop only said
# "(no VMs)" when the caller happened to have pipefail on.
out="$(set +o pipefail; AGENT_VM_TEST_NOVMS=1 rec status)"
case "$out" in
  *"(no VMs)"*) pass "no VM: says so" ;;
  *) fail "no VM: nothing said: $out" ;;
esac

section "destroy-all"
# The names are read on stdin; each limactl call must not eat the next ones.
echo 1 > "$HOME/.agent-vm/.agent-vm-base-version"
: > "$REC"
( export AGENT_VM_TEST_REC="$REC"
  _agent_vm_destroy_vms "$(printf 'agent-vm-a\nagent-vm-b\nagent-vm-base\n')" >/dev/null )
check "every listed VM is deleted" "$(grep -c '^delete' "$REC")" "3"
if [ -e "$HOME/.agent-vm/.agent-vm-base-version" ]; then
  fail "deleting the base template left its ready marker"
else
  pass "deleting the base template retires its ready marker"
fi
echo 1 > "$HOME/.agent-vm/.agent-vm-base-version"

section "doctor"
date +%s > "$HOME/.agent-vm/.agent-vm-base-version"
# A stub git that keeps safe.bareRepository in a file; FAKE_GIT_VERSION and
# FAKE_GIT_SET_FAILS change its answers. Used here and by the setup offer.
mkdir -p "$SB/fakegit"
cat > "$SB/fakegit/git" <<STUB
#!/usr/bin/env bash
echo "git \$*" >> "$SB/git.log"
case "\$*" in
  --version) echo "git version \${FAKE_GIT_VERSION:-2.47.0}" ;;
  "config --get safe.bareRepository") cat "$SB/git-bare" 2>/dev/null || exit 1 ;;
  "config --global safe.bareRepository explicit")
    [ -n "\${FAKE_GIT_SET_FAILS:-}" ] && exit 1
    echo explicit > "$SB/git-bare" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$SB/fakegit/git"
# With the setting made: a healthy host has it.
DOCTOR_OLD_PATH="$PATH"
export PATH="$SB/fakegit:$PATH"
echo explicit > "$SB/git-bare"
out="$(rec doctor)"
rc=$?
check "doctor exits 0 on a healthy setup" "$rc" "0"
[ "$rc" = 0 ] || printf '%s\n' "$out" | sed 's/^/         /'
for want in "ok    Lima 2.0.3" "ok    agent-vm-base is ready" "(--readonly works)" "No problems found"; do
  case "$out" in
    *"$want"*) pass "doctor: $want" ;;
    *) fail "doctor: missing '$want'"; printf '%s\n' "$out" | tail -3 | sed 's/^/         /' ;;
  esac
done
if grep -Eq '^(start|stop|delete|clone|create|edit)( |$)' "$REC"; then
  fail "doctor changed something: $(grep -E '^(start|stop|delete|clone|create|edit)' "$REC" | head -1)"
else
  pass "doctor is read-only"
fi
case "$out" in
  *"warn  this Lima cannot keep .git read-only"*"$AGENT_VM_LIMA_ISSUE"*) pass "doctor: a Lima without readonlyNames is a warning, with the way out" ;;
  *) fail "doctor: no warning about .git protection" ;;
esac
case "$out" in *"warn  its shares leave .git writable"*) pass "doctor: a VM with a writable .git is a warning" ;; *) fail "doctor: VM shares not reported" ;; esac
touch "$PROTECTS"
printf '[{"location": "%s", "writable": true, %s}]\n' "$PROJ" "$SSHFS_RO" > "$HOME/.agent-vm/.agent-vm-mounts-$PV"
out="$(rec doctor)"
case "$out" in *"ok    Lima keeps every .git read-only"*) pass "doctor: a Lima with readonlyNames is ok" ;; *) fail "doctor: protection not reported" ;; esac
case "$out" in *"ok    its shares keep every .git read-only"*) pass "doctor: a protected VM is ok" ;; *) fail "doctor: protected VM not reported" ;; esac
case "$out" in *"AGENT_VM_UNSAFE_WRITABLE_GIT"*) fail "doctor: opt-out reported while unset" ;; *) pass "doctor: no opt-out reported while unset" ;; esac
out="$(AGENT_VM_UNSAFE_WRITABLE_GIT=1 rec doctor)"
case "$out" in *"warn  AGENT_VM_UNSAFE_WRITABLE_GIT=1: the VMs can write .git"*) pass "doctor: the opt-out is a warning" ;; *) fail "doctor: opt-out not reported" ;; esac
rm -f "$PROTECTS" "$HOME/.agent-vm/.agent-vm-mounts-$PV"
case "$out" in *"ok    safe.bareRepository = explicit"*) pass "doctor: safe.bareRepository set is ok" ;; *) fail "doctor: safe.bareRepository not reported" ;; esac
rm -f "$SB/git-bare"
out="$(rec doctor)"
case "$out" in
  *"warn  safe.bareRepository is not 'explicit'"*"git config --global safe.bareRepository explicit"*) pass "doctor: safe.bareRepository unset is a warning, with the command" ;;
  *) fail "doctor: unset safe.bareRepository not a warning" ;;
esac
out="$(FAKE_GIT_VERSION=2.30.1 rec doctor)"
case "$out" in *"warn  git version 2.30.1 is older than 2.38"*) pass "doctor: a git older than 2.38 is a warning" ;; *) fail "doctor: old git not reported" ;; esac
export PATH="$DOCTOR_OLD_PATH"
# PATH without any limactl. Commands run under it are called by absolute path,
# in case the directory that held limactl also held them.
nolima_path() {
  local rest="$PATH:" p out=""
  while [ -n "$rest" ]; do
    p="${rest%%:*}"; rest="${rest#*:}"
    [ -x "$p/limactl" ] || out="${out:+$out:}$p"
  done
  printf '%s' "$out"
}
BASH_BIN="$(command -v bash)"
out="$(cd "$PROJ" && PATH="$(nolima_path)" "$BASH_BIN" "$AGENT_VM_SH" doctor 2>&1)"
rc=$?
case "$rc:$out" in
  1:*"FAIL  Lima is not installed"*) pass "doctor without Lima: fails and says so" ;;
  *) fail "doctor without Lima: $rc" ;;
esac
agent-vm doctor extra >/dev/null 2>&1
check "doctor takes no argument (exit 2)" "$?" "2"

section "setup options"
case "$(agent-vm setup --reset 2>&1 </dev/null)" in
  *"Unknown option: --reset"*) pass "setup rejects --reset instead of ignoring it" ;;
  *) fail "setup accepted --reset" ;;
esac

section "release.sh"
REL="$SELF_DIR/release.sh"
notes="$("$REL" notes "$AGENT_VM_VERSION" 2>&1)"
case "$notes" in
  ""|*"has no '## "*) fail "CHANGELOG.md has no section for $AGENT_VM_VERSION, the version agent-vm.sh reports" ;;
  *) pass "CHANGELOG.md has a section for $AGENT_VM_VERSION" ;;
esac
# On a changelog of our own: the section stops at the next heading and loses
# its surrounding blank lines.
mkdir -p "$SB/rel"
cp "$REL" "$SB/rel/release.sh"
printf '# Changelog\n\n## 2.0.0\n\n- two\n\n## 1.0.0\n\n- one\n' > "$SB/rel/CHANGELOG.md"
check "notes: only that version's section" "$("$SB/rel/release.sh" notes 2.0.0)" "- two"
check "notes: the last section too"        "$("$SB/rel/release.sh" notes 1.0.0)" "- one"
"$SB/rel/release.sh" notes 3.0.0 >/dev/null 2>&1
check "notes: an absent version fails" "$?" "1"
"$REL" 1.2 >/dev/null 2>&1
check "a malformed version is refused before anything else" "$?" "1"
"$REL" >/dev/null 2>&1
check "no argument prints the usage (exit 2)" "$?" "2"

section "no terminal: detected by opening it"
# `-r /dev/tty` is true with no controlling terminal; only opening it fails.
# setsid gives a process no controlling terminal, which is the CI case.
if command -v setsid >/dev/null 2>&1; then
  SETSID="$(command -v setsid)"
  # Runs $1 in bash with no controlling terminal. The exit status comes back as
  # a last `rc=N` line: busybox setsid has no -w to wait and pass it through.
  notty() {
    "$SETSID" "$BASH_BIN" -c "source '$AGENT_VM_SH'; $1"'; echo "rc=$?"' </dev/null 2>&1
  }

  out="$(notty '_agent_vm_have_tty')"
  check "no controlling terminal: _agent_vm_have_tty says no" "${out##*rc=}" "1"

  # Lima missing, brew present, nobody to ask: say what to run, install nothing.
  mkdir -p "$SB/fakebrew"
  printf '#!/bin/sh\necho "brew $*" >> "%s/brew.log"\n' "$SB" > "$SB/fakebrew/brew"
  chmod +x "$SB/fakebrew/brew"
  rm -f "$SB/brew.log"
  out="$(PATH="$SB/fakebrew:$(nolima_path)" notty 'agent-vm setup --preinstall=none')"
  [ ! -e "$SB/brew.log" ] && pass "no terminal: brew is not run without asking" \
    || fail "brew ran without a prompt: $(cat "$SB/brew.log")"
  case "${out##*rc=}:$out" in
    1:*"Install it with: brew install sylvinus/tap/lima-sylvinus"*"brew install lima"*) pass "no terminal: says how to install Lima, the one keeping .git read-only first" ;;
    *) fail "no terminal: '$out'" ;;
  esac
  case "$out" in
    */dev/tty*) fail "a /dev/tty error leaked: $out" ;;
    *) pass "no /dev/tty error is printed" ;;
  esac

  # The wizard is skipped too, rather than run and answered with its defaults
  # because every read fails.
  rm -f "$SB/brew.log" "$PROTECTS"
  out="$(AGENT_VM_STATE_DIR="$SB/wizard-state" AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_PROTECTS="$PROTECTS" \
         PATH="$SB/fakebrew:$PATH" notty '_agent_vm_check_linux_prereqs() { return 0; }; agent-vm setup')"
  case "${out##*rc=}:$out" in
    *"setup wizard"*) fail "the wizard ran with no terminal" ;;
    0:*) pass "no terminal: the wizard is skipped and setup completes" ;;
    *) fail "setup with no terminal: '$out'" ;;
  esac
  # Lima's containerd is never installed: Docker brings its own when chosen.
  grep -q "^create .*--containerd=none" "$REC" && pass "Lima's containerd is off" \
    || fail "Lima's containerd stays on: $(grep '^create' "$REC")"
  # A Lima that cannot keep .git read-only: said, with the command, and setup
  # goes on without installing anything.
  case "$out" in
    *"cannot keep .git read-only"*"brew install sylvinus/tap/lima-sylvinus"*"Continuing without .git protection"*)
      pass "no terminal: setup says .git is not protected, and how to fix it" ;;
    *) fail "no terminal: no .git protection warning: '$out'" ;;
  esac
  [ ! -e "$SB/brew.log" ] && pass "no terminal: nothing is installed" \
    || fail "brew ran without a prompt: $(cat "$SB/brew.log")"
else
  printf '  skip terminal detection (no setsid here)\n'
fi

# =============================================================================
section "setup offers a Lima that keeps .git read-only"
# =============================================================================
# With a terminal and Homebrew. A stub brew records its calls; installing the
# formula makes the limactl stub answer like a Lima with readonlyNames.
# FAKE_BREW_HAS_LIMA: brew's own lima is installed. FAKE_BREW_FAIL: the
# install fails.
mkdir -p "$SB/fakebrew"
cat > "$SB/fakebrew/brew" <<STUB
#!/bin/sh
echo "brew \$*" >> "$SB/brew.log"
case "\$1 \$2" in
  "list --formula") [ -n "\${FAKE_BREW_HAS_LIMA:-}" ] ;;
  "install sylvinus/tap/lima-sylvinus") [ -z "\${FAKE_BREW_FAIL:-}" ] && touch "$PROTECTS" ;;
esac
STUB
chmod +x "$SB/fakebrew/brew"
# ANSWER is the reply to the prompt (1 yes, 0 no).
offer() {
  rm -f "$SB/brew.log"
  ( export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_PROTECTS="$PROTECTS" PATH="$SB/fakebrew:$PATH"
    _agent_vm_have_tty() { return 0; }
    _agent_vm_ask_yn() { echo "${ANSWER:-1}"; }
    _agent_vm_offer_git_protection ) 2>&1
}
brew_calls() { tr '\n' ';' < "$SB/brew.log" 2>/dev/null; }

rm -f "$PROTECTS"
out="$(FAKE_BREW_HAS_LIMA=1 offer)"
check "yes, over brew's lima: unlink it, then install the formula" \
  "$(brew_calls)" "brew list --formula lima;brew unlink lima;brew install sylvinus/tap/lima-sylvinus;"
case "$out" in *"Lima now keeps every .git read-only"*) pass "yes: says it worked, checked afresh" ;; *) fail "yes: $out" ;; esac

rm -f "$PROTECTS"
offer >/dev/null
check "yes, no brew lima: nothing to unlink" \
  "$(brew_calls)" "brew list --formula lima;brew install sylvinus/tap/lima-sylvinus;"

rm -f "$PROTECTS"
out="$(FAKE_BREW_HAS_LIMA=1 FAKE_BREW_FAIL=1 offer)"
case "$(brew_calls)" in
  *"brew install sylvinus/tap/lima-sylvinus;brew link lima;") pass "a failed install links brew's lima back" ;;
  *) fail "failed install: $(brew_calls)" ;;
esac
case "$out" in *"the install failed. Continuing without .git protection"*) pass "and says so" ;; *) fail "failed install: $out" ;; esac

rm -f "$PROTECTS"
out="$(ANSWER=0 offer)"
[ ! -e "$SB/brew.log" ] && pass "no: brew is not run" || fail "no: brew ran: $(brew_calls)"
case "$out" in *"cannot keep .git read-only"*"Continuing without .git protection"*) pass "no: the risk is said" ;; *) fail "no: $out" ;; esac

touch "$PROTECTS"
out="$(offer)"
check "already protected: nothing said" "$out" ""
[ ! -e "$SB/brew.log" ] && pass "already protected: brew is not run" || fail "already protected: brew ran: $(brew_calls)"

section "setup: git on this machine ignores bare repositories"
# A folder holding HEAD, objects/ and refs/ is a repository to git, whatever
# its name, so .git protection does not cover it. Setup asks to set
# safe.bareRepository=explicit. The stub git is the doctor section's.
# ANSWER is the reply (1 yes, 0 no); NOTTY=1 means no terminal to ask on.
bare_offer() {
  rm -f "$SB/git.log"
  ( export PATH="$SB/fakegit:$PATH"
    _agent_vm_have_tty() { [ -z "${NOTTY:-}" ]; }
    _agent_vm_ask_yn() { echo "${ANSWER:-1}"; }
    _agent_vm_offer_bare_repo_setting ) 2>&1
}
git_set_called() { grep -q 'config --global safe.bareRepository explicit' "$SB/git.log" 2>/dev/null; }

rm -f "$SB/git-bare"
out="$(bare_offer)"
[ "$(cat "$SB/git-bare" 2>/dev/null)" = "explicit" ] && pass "yes: the setting is made" || fail "yes: not set: $out"
case "$out" in
  *"HEAD, objects/ and refs/"*"git config --global safe.bareRepository explicit"*"now ignores"*) pass "yes: the risk, the command, then the result" ;;
  *) fail "yes: $out" ;;
esac
rm -f "$SB/git-bare"
out="$(ANSWER=0 bare_offer)"
git_set_called && fail "no: the setting was made anyway" || pass "no: git config is not run"
case "$out" in *"Warning: not set"*) pass "no: says what is left open" ;; *) fail "no: $out" ;; esac
out="$(NOTTY=1 bare_offer)"
git_set_called && fail "no terminal: the setting was made without asking" || pass "no terminal: nothing is changed"
case "$out" in *"git config --global safe.bareRepository explicit"*"Warning: not set"*) pass "no terminal: the command is printed" ;; *) fail "no terminal: $out" ;; esac
out="$(FAKE_GIT_SET_FAILS=1 bare_offer)"
case "$out" in *"did not take"*) pass "a failed git config is said" ;; *) fail "failed git config: $out" ;; esac
out="$(FAKE_GIT_VERSION=2.30.1 bare_offer)"
git_set_called && fail "old git: set on a git that ignores it" || pass "old git: nothing is set"
case "$out" in *"older than 2.38"*"Upgrade git"*) pass "old git: says to upgrade" ;; *) fail "old git: $out" ;; esac
echo explicit > "$SB/git-bare"
check "already set: nothing said" "$(bare_offer)" ""
git_set_called && fail "already set: git config was run" || pass "already set: git config is not run"
check "no git on this machine: nothing to protect" "$(PATH="$SB/nolimactl" _agent_vm_bare_repo_state)" "nogit"
check "setup makes the offer" "$(declare -f _agent_vm_setup | grep -c '_agent_vm_offer_bare_repo_setting')" "1"
# A first run opens on the familiar questions: the security ones come after the
# wizard, and before the VM exists.
check "security checks: after the wizard, before the VM" \
  "$(declare -f _agent_vm_setup | grep -o -e 'Use these defaults' -e 'Running security checks' -e 'Creating base VM' | tr '\n' '|')" \
  "Use these defaults|Running security checks|Creating base VM|"

# Against the real git, when it is recent enough: only the system and global
# config count, as for git itself. A repository's own setting must not answer.
real_git_ver="$(git --version 2>/dev/null)"; real_git_ver="${real_git_ver#git version }"; real_git_ver="${real_git_ver%% *}"
if [ -n "$real_git_ver" ] && _agent_vm_ver_ge "$real_git_ver" 2.38.0; then
  mkdir -p "$SB/realgit/home" "$SB/realgit/repo"
  ( export HOME="$SB/realgit/home" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$SB/realgit/xdg"
    cd "$SB/realgit/repo" && git init -q . && git config safe.bareRepository explicit
    printf '%s ' "$(_agent_vm_bare_repo_state)"
    git config --global safe.bareRepository explicit
    printf '%s' "$(_agent_vm_bare_repo_state)" ) > "$SB/realgit/out"
  check "real git: a repository's own setting does not count, the global one does" "$(cat "$SB/realgit/out")" "unset ok"
else
  printf '  skip real git (absent or older than 2.38)\n'
fi
rm -f "$PROTECTS"

# =============================================================================
section "www/public/install.sh (curl | sh)"
# =============================================================================
# Stub curl and git serve releases from $WF, one directory per tag, and log
# what was asked for. A release is agent-vm.sh plus a MARK file naming it.
INSTALLER="$SELF_DIR/www/public/install.sh"
WF="$SB/wfix"; WBIN="$SB/wbin"; WH="$SB/whome"
mkdir -p "$WBIN" "$WH"
cat > "$WBIN/curl" <<'STUB'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; https://*) url="$1" ;; esac
  shift
done
echo "$url" >> "$WF/log"
case "$url" in
  */releases/latest/download/*) f="$WF/$(cat "$WF/latest")/${url##*/}" ;;
  */releases/download/*) t="${url%/*}"; f="$WF/${t##*/}/${url##*/}" ;;
  *) exit 22 ;;
esac
[ -f "$f" ] || exit 22
cp "$f" "$out"
STUB
cat > "$WBIN/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$WF/log"
case "$1" in
  clone) mkdir -p "$3/.git" && cp "$WF/src/agent-vm.sh" "$3/" ;;
  -C) [ -d "$2/.git" ] ;;
esac
STUB
chmod +x "$WBIN/curl" "$WBIN/git"
make_release() {  # <version> [corrupt]
  local d="$WF/v$1" s="$WF/stage/agent-vm-$1"
  mkdir -p "$d" "$s"
  cp "$AGENT_VM_SH" "$s/agent-vm.sh"; echo "$1" > "$s/MARK"
  tar -czf "$d/agent-vm-$1.tar.gz" -C "$WF/stage" "agent-vm-$1"
  local sum; sum="$(_agent_vm_sha256 < "$d/agent-vm-$1.tar.gz" | cut -d' ' -f1)"
  [ -z "${2:-}" ] || sum="0000$sum"
  printf '%s  agent-vm-%s.tar.gz\n' "$sum" "$1" > "$d/SHA256SUMS"
  echo "v$1" > "$WF/latest"
}
mkdir -p "$WF/src"; cp "$AGENT_VM_SH" "$WF/src/agent-vm.sh"
# The rc already names agent-vm.sh and the base is built (the stub limactl
# lists it), so `install` has nothing to ask on a terminal.
echo ': agent-vm.sh' > "$WH/.zshrc"
mkdir -p "$WH/state"; echo 1 > "$WH/state/.agent-vm-base-version"
winst() {
  ( export HOME="$WH" WF XDG_DATA_HOME= AGENT_VM_BIN_DIR="$WH/bin" SHELL=/bin/zsh PATH="$WBIN:$PATH" \
      AGENT_VM_STATE_DIR="$WH/state"
    sh "${WINSTALLER:-$INSTALLER}" "$@" ) 2>&1
}
WDIR="$WH/.local/share/agent-vm"

make_release 1.0.0
: > "$WF/log"
out="$(winst)"; rc=$?
check "release: installs" "$rc" "0"
case "$out" in *"agent-vm claude"*) pass "release: base built, nothing asked" ;; *) fail "release: $out" ;; esac
check "release: the latest tarball is in place" "$(cat "$WDIR/MARK" 2>/dev/null)" "1.0.0"
check "release: linked onto the PATH" "$(readlink "$WH/bin/agent-vm")" "$WDIR/agent-vm.sh"
check "release: sums from latest/, the tarball from its tag" "$(tr '\n' ' ' < "$WF/log")" \
  "https://github.com/sylvinus/agent-vm/releases/latest/download/SHA256SUMS https://github.com/sylvinus/agent-vm/releases/download/v1.0.0/agent-vm-1.0.0.tar.gz "

make_release 1.1.0
out="$(winst)"; rc=$?
check "rerun: replaced by the new release" "$rc:$(cat "$WDIR/MARK")" "0:1.1.0"
check "rerun: no staging or old copy left" "$(ls -A "$WH/.local/share")" "agent-vm"
case "$out" in *"already linked"*) pass "rerun: the link is kept" ;; *) fail "rerun: $out" ;; esac

make_release 1.2.0 corrupt
out="$(winst)"; rc=$?
check "bad checksum: refused, the install is untouched" "$rc:$(cat "$WDIR/MARK")" "1:1.1.0"
case "$out" in *"checksum mismatch"*) pass "bad checksum: said" ;; *) fail "bad checksum: $out" ;; esac

: > "$WF/log"
out="$(winst --version v1.0.0)"; rc=$?
check "--version: that release" "$rc:$(cat "$WDIR/MARK")" "0:1.0.0"
check "--version: its sums, from its tag" "$(head -n 1 "$WF/log")" \
  "https://github.com/sylvinus/agent-vm/releases/download/v1.0.0/SHA256SUMS"
check "--version: not a version (exit 1)" "$(winst --version 1.0 >/dev/null; echo $?)" "1"
check "--version with --git (exit 1)" "$(winst --version 1.0.0 --git >/dev/null; echo $?)" "1"
check "unknown option (exit 2)" "$(winst --nope >/dev/null; echo $?)" "2"

make_release 1.3.0
mkdir -p "$SB/wother"; echo mine > "$SB/wother/notes"
out="$(winst --dir "$SB/wother")"; rc=$?
check "a directory of the user's: refused, left as it was" "$rc:$(ls "$SB/wother")" "1:notes"

rm -rf "$WDIR" "$WH/bin"
: > "$WF/log"
out="$(winst --git)"; rc=$?
check "--git: clones" "$rc:$(head -n 1 "$WF/log")" "0:git clone https://github.com/sylvinus/agent-vm.git $WDIR"
check "--git: linked onto the PATH" "$(readlink "$WH/bin/agent-vm")" "$WDIR/agent-vm.sh"
out="$(winst --git)"; rc=$?
check "--git again: pulls" "$rc:$(tail -n 1 "$WF/log")" "0:git -C $WDIR pull --ff-only"
out="$(winst)"; rc=$?
check "release over a clone: refused" "$rc" "1"
case "$out" in *"is a git clone"*"git -C"*) pass "release over a clone: says how to update it" ;; *) fail "release over a clone: $out" ;; esac

# A download cut short must run nothing: only the last line calls main.
rm -rf "$WDIR"
sed '$d' "$INSTALLER" > "$SB/install-cut.sh"
out="$(WINSTALLER="$SB/install-cut.sh" winst)"; rc=$?
check "cut short: runs nothing" "$rc:$([ -e "$WDIR" ] && echo there)" "0:"

# =============================================================================
printf '\n%s passed, %s failed\n' "$PASSED" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

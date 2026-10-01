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
# This limactl answers `validate` with nothing: a Lima agent-vm cannot read.
check "info: git_protected unknown when Lima cannot tell" "$(get git_protected)" "unknown"
case "$(get security_questions)" in
  lima-unknown|lima-unknown,*) pass "info: security_questions names the Lima that cannot tell" ;;
  *) fail "info: security_questions: $(get security_questions)" ;;
esac
check "info: key count"    "$(printf '%s\n' "$info_out" | grep -c '^[a-z_]*=')" "14"

# Every key must be present even with no Lima on the box. Build a PATH with the
# limactl-bearing directories dropped rather than a hardcoded one, so this also
# holds on a machine where Lima is genuinely installed.
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
check "info without limactl still prints 14 keys" \
  "$(printf '%s\n' "$nolima" | grep -c '^[a-z_]*=')" "14"
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
  "$(cd "$SB/real" && CDPATH="$SB/decoy" agent-vm info twin | wc -l | tr -d ' ')" "14"

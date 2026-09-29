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

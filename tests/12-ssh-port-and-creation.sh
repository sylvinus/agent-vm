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

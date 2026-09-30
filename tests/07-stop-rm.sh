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

: > "$CALLS"; : > "$SB/deleted"
out="$( export AGENT_VM_TEST_CALLS="$CALLS" AGENT_VM_TEST_DELETED="$SB/deleted"; agent-vm rm agent-vm-proj-deadbeef 2>&1 )"
check "rm <name> stops then deletes the named VM" \
  "$(cat "$CALLS")" "$(printf 'stop agent-vm-proj-deadbeef\ndelete agent-vm-proj-deadbeef --force')"
case "$out" in *"VM destroyed."*) pass "rm: says it is done once Lima no longer lists it" ;; *) fail "rm: $out" ;; esac

# A delete that did not take is said, not reported as done.
out="$( export AGENT_VM_TEST_CALLS="$CALLS"; agent-vm rm agent-vm-proj-deadbeef 2>&1 )"
case "$?:$out" in
  1:*"could not delete VM 'agent-vm-proj-deadbeef'"*) pass "rm: a VM Lima still lists is an error" ;;
  *) fail "rm, delete did not take: $out" ;;
esac
case "$out" in *"VM destroyed."*) fail "rm: a failed delete was reported as done" ;; *) pass "rm: and not reported as done" ;; esac

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

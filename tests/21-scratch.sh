# =============================================================================
section "--scratch: a new VM sharing nothing, deleted on exit"
# =============================================================================
# The recording limactl of 11-recorded-commands.sh lists one VM, so the
# scratch name is fixed here, and the VM exists once `clone` made it.
SCR="agent-vm-proj-scratch-00000000"
SCR_CLONED="$SB/scr-cloned"
sc() {
  : > "$REC"
  rm -f "$REC.stopped" "$SCR_CLONED"
  ( cd "${SC_DIR:-$PROJ}" || exit 1
    export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$SCR" AGENT_VM_TEST_PROTECTS="$PROTECTS" AGENT_VM_TEST_CLONED="$SCR_CLONED"
    _agent_vm_scratch_name() { echo "$SCR"; }
    agent-vm "$@" </dev/null 2>&1 )
}
check "a scratch name is the folder's, marked, with 8 random hex digits" \
  "$(_agent_vm_scratch_name /work/My_App | sed 's/[0-9a-f]\{8\}$/RAND/')" "agent-vm-My-App-scratch-RAND"
check "a long folder name is cut, and a name of symbols still makes a valid one" \
  "$(_agent_vm_scratch_name /work/a-very-long-folder-name-indeed | sed 's/[0-9a-f]\{8\}$/RAND/') $(_agent_vm_scratch_name /work/___ | sed 's/[0-9a-f]\{8\}$/RAND/')" \
  "agent-vm-a-very-long-folder-n-scratch-RAND agent-vm-project-scratch-RAND"
[ "$(_agent_vm_scratch_name /w/x)" != "$(_agent_vm_scratch_name /w/x)" ] \
  && pass "two scratch runs in one folder get two VMs" || fail "a scratch name repeats"

# Made, given no share at all, used, deleted. The folder's own VM is never
# touched.
out="$(sc --scratch run true)"
rec_has "clone $AGENT_VM_TEMPLATE $SCR" && pass "a new VM, cloned from the base" || fail "not cloned: $(head -3 "$REC")"
rec_has "edit $SCR --set del(.mountType) | .mounts = []" && pass "no share at all" || fail "shares: $(grep '^edit' "$REC")"
rec_has "agent-vm-write-probe" && pass "the command runs" || fail "the command did not run: $out"
d="$(grep -n "^delete $SCR" "$REC" | head -1 | cut -d: -f1)"
p="$(grep -n "agent-vm-write-probe" "$REC" | tail -1 | cut -d: -f1)"
if [ -n "$d" ] && [ -n "$p" ] && [ "$d" -gt "$p" ]; then pass "then the VM is deleted"; else fail "deleted at '${d:-never}': $out"; fi
case "$out" in *"Deleting scratch VM '$SCR'"*) pass "and it says so" ;; *) fail "no notice: $out" ;; esac
grep -Eq "^(stop|delete|edit|start) $PV( |$)" "$REC" && fail "the folder's own VM was touched" || pass "the folder's own VM is left alone"
[ -e "$(_agent_vm_scratch_marker "$SCR")" ] && fail "the run's record outlived it" || pass "nothing left recorded"

# Before the deletion, asked when it can be: a no opens a shell in the VM,
# and asks again on its exit. Yes, or an answer cut short, deletes. ANSWERS
# are the replies in order, in a file: each question is asked in a subshell.
answers() { printf '%s\n' "$@" > "$SB/scr-answers"; echo 0 > "$SB/scr-asked"; }
ask_stubs='_agent_vm_can_ask() { return 0; }
  _agent_vm_ask_yn() { n=$(( $(cat "$SB/scr-asked") + 1 )); echo "$n" > "$SB/scr-asked"; sed -n "${n}p" "$SB/scr-answers"; }'
shells() { grep -c "^shell --workdir $PROJ $SCR zsh -l$" "$REC"; }
answers 0 1
out="$( eval "$ask_stubs"; sc --scratch run true )"
check "no, then yes: one shell in the VM, then the deletion" "$(shells) $(cat "$SB/scr-asked")" "1 2"
s="$(grep -n "zsh -l$" "$REC" | head -1 | cut -d: -f1)"; d="$(grep -n "^delete $SCR" "$REC" | head -1 | cut -d: -f1)"
[ -n "$s" ] && [ -n "$d" ] && [ "$s" -lt "$d" ] && pass "the shell comes before the deletion" || fail "shell at '${s:-none}', delete at '${d:-none}'"
case "$out" in *"Type 'exit' to be asked again"*) pass "the shell says how to come back" ;; *) fail "no shell notice: $out" ;; esac
answers 0 0 1
( eval "$ask_stubs"; sc --scratch run true ) >/dev/null
check "asked again after each shell" "$(shells)" "2"
answers 1
( eval "$ask_stubs"; sc --scratch run true ) >/dev/null
check "yes: deleted, no shell" "$(shells) $(grep -c "^delete $SCR" "$REC")" "0 1"
answers ""
( eval "$ask_stubs"; sc --scratch run true ) >/dev/null
check "an answer cut short deletes" "$(shells) $(grep -c "^delete $SCR" "$REC")" "0 1"
answers 0
( eval "$ask_stubs"; AGENT_VM_TEST_EDIT_FAIL=1 sc --scratch run true ) >/dev/null
check "a failed start asks nothing, and deletes" "$(cat "$SB/scr-asked") $(shells)" "0 0"
out="$( _agent_vm_can_ask() { return 1; }; sc --scratch run true )"
check "no terminal: deleted, no shell" "$(shells) $(grep -c "^delete $SCR" "$REC")" "0 1"

# Nothing is shared, so none of the share questions: here a Lima without
# readonlyNames, no terminal, and the questions on.
rm -f "$PROTECTS"
out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; sc --scratch run true )"
case "$out" in *"Aborted"*|*"Lima cannot keep .git read-only"*) fail "a share question for a VM that shares nothing: $out" ;; *) pass "no share question" ;; esac
rec_has "agent-vm-write-probe" && pass "and the command runs" || fail "did not run: $out"

# Nothing of the project goes in: not its env file, not its runtime script.
# The shared env does.
printf 'SHARED_KEY=shared\n' > "$HOME/.agent-vm/env"
printf 'PROJECT_KEY=project\n' > "$PROJ/.agent-vm.env"
printf '#!/bin/sh\necho project-runtime\n' > "$PROJ/.agent-vm.runtime.sh"
: > "$SB/scr-stdin"
out="$(AGENT_VM_TEST_STDIN="$SB/scr-stdin" sc --scratch run true)"
grep -q 'SHARED_KEY=shared' "$SB/scr-stdin" && pass "the shared env goes in" || fail "shared env missing: $(cat "$SB/scr-stdin")"
grep -q 'PROJECT_KEY' "$SB/scr-stdin" && fail "the project's env file went in" || pass "the project's env file stays out"
grep -q 'project-runtime\|\.agent-vm\.runtime\.sh' "$REC" "$SB/scr-stdin" && fail "the project's runtime script went in" || pass "the project's runtime script stays out"
case "$out" in *"project runtime"*) fail "a project runtime ran: $out" ;; *) pass "no project runtime run" ;; esac
# Nor one kept outside the project, which a start with a share reads on the
# host.
printf 'OUTSIDE_KEY=outside\n' > "$SB/outside.env"
: > "$SB/scr-stdin"
AGENT_VM_PROJECT_ENV="$SB/outside.env" AGENT_VM_TEST_STDIN="$SB/scr-stdin" sc --scratch run true >/dev/null
grep -q 'OUTSIDE_KEY' "$SB/scr-stdin" && fail "a project env file outside the project went in" || pass "nor one outside the project"
rm -f "$HOME/.agent-vm/env" "$PROJ/.agent-vm.env" "$PROJ/.agent-vm.runtime.sh" "$SB/outside.env"

# The home directory is refused as a share; with nothing shared, it is fine.
out="$(SC_DIR="$HOME" sc --scratch run true)"
case "$out" in *"refusing to share"*) fail "--scratch refused the home directory: $out" ;; *) pass "--scratch runs from the home directory" ;; esac

# Nothing to reset, nothing to make read-only.
for o in --reset --readonly; do
  out="$(sc --scratch "$o" run true)"
  case "$out" in *"--reset and --readonly do not go with it"*) pass "--scratch $o is refused" ;; *) fail "--scratch $o: $out" ;; esac
done

# A failed start still deletes what it made.
out="$(AGENT_VM_TEST_EDIT_FAIL=1 sc --scratch run true)"
rec_has "delete $SCR" && pass "a failed start deletes the VM" || fail "a failed start left the VM: $out"
[ -e "$(_agent_vm_scratch_marker "$SCR")" ] && fail "a failed start left its record" || pass "and its record"

# A scratch VM whose folder cannot be written is an error, never a repair:
# the repair of a VM with a share mounts the project.
out="$(AGENT_VM_TEST_RO=1 sc --scratch run true)"
case "$out" in *"is not writable in VM '$SCR'"*) pass "a scratch folder that cannot be written: an error" ;; *) fail "unwritable scratch folder: $out" ;; esac
grep -q "\"location\"" <<< "$(grep "^edit $SCR" "$REC")" && fail "the project was mounted into the scratch VM: $(grep "^edit $SCR" "$REC")" \
  || pass "and the project is never mounted into it"
rec_has "delete $SCR" && pass "and the VM is deleted" || fail "not deleted: $out"

# Only names a scratch run makes are deleted unasked.
mkdir -p "$AGENT_VM_STATE_DIR"
echo 999999 > "$AGENT_VM_STATE_DIR/.agent-vm-scratch-$AGENT_VM_TEMPLATE"
echo 999999 > "$AGENT_VM_STATE_DIR/.agent-vm-scratch-agent-vm-proj-1a2b3c4d"
check "a record that does not name a scratch VM is not a leftover" "$(_agent_vm_scratch_leftovers)" ""
rm -f "$AGENT_VM_STATE_DIR/.agent-vm-scratch-$AGENT_VM_TEMPLATE" "$AGENT_VM_STATE_DIR/.agent-vm-scratch-agent-vm-proj-1a2b3c4d"

# A run killed outright leaves a record with a pid that is gone: the next
# scratch run deletes that VM. One whose run still goes on is left alone.
mkdir -p "$AGENT_VM_STATE_DIR"
dead_pid=999999; while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
printf '%s\n' "$dead_pid" > "$(_agent_vm_scratch_marker agent-vm-old-scratch-11111111)"
printf '%s\n' "$$" > "$(_agent_vm_scratch_marker agent-vm-live-scratch-22222222)"
check "leftovers: the run that is gone, not the one that goes on" "$(_agent_vm_scratch_leftovers)" "agent-vm-old-scratch-11111111"
case "$(rec doctor)" in *"warn  scratch VM agent-vm-old-scratch-11111111 was left by a run that did not finish"*) pass "doctor: a leftover is a warning" ;; *) fail "doctor: no leftover warning" ;; esac
out="$(sc --scratch run true)"
rec_has "delete agent-vm-old-scratch-11111111" && pass "the next scratch run deletes the leftover" || fail "leftover not deleted: $out"
rec_has "delete agent-vm-live-scratch-22222222" && fail "a scratch VM still in use was deleted" || pass "one still in use is left alone"
rm -f "$(_agent_vm_scratch_marker agent-vm-live-scratch-22222222)"

# The run's Ctrl-C trap does not outlive it: agent-vm is a shell function
# too, and the user's own trap comes back.
trap_after="$( cd "$PROJ" && export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$SCR" AGENT_VM_TEST_CLONED="$SCR_CLONED"
  _agent_vm_scratch_name() { echo "$SCR"; }
  trap 'echo mine' INT
  agent-vm --scratch run true </dev/null >/dev/null 2>&1
  trap )"
case "$trap_after" in *"echo mine"*) pass "the user's INT trap is back after a scratch run" ;; *) fail "INT trap after a scratch run: '$trap_after'" ;; esac

# The flag comes right after the command's name too, and never reaches it.
out="$(sc run --scratch true)"
rec_has "edit $SCR --set del(.mountType) | .mounts = []" && pass "run --scratch: taken" || fail "run --scratch not taken: $out"
grep -q -- "--scratch" <<< "$(grep -v '^edit' "$REC")" && fail "--scratch reached the command" || pass "and it does not reach the command"
case "$(agent-vm --scratch stop 2>&1)" in *"is an option for the commands that start a VM"*) pass "--scratch before 'stop' is refused" ;; *) fail "--scratch stop accepted" ;; esac
_agent_vm_cleanup_state "$SCR"

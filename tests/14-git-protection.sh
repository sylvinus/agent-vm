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
# Wrappers, not symlinks (see 10-names-and-paths.sh): the probe must run its
# mktemp while limactl stays missing, on machines without link privilege too.
for t in mktemp rm; do
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$t")" > "$SB/nolimactl/$t"
  chmod +x "$SB/nolimactl/$t"
done
check "no limactl: no protection" "$(PATH="$SB/nolimactl" probe)" "no"

# A new VM gets reverse-sshfs and readonlyNames on every share.
CLONED="$SB/cloned-prot"; rm -f "$CLONED" "$REC_MOUNTS"
AGENT_VM_TEST_CLONED="$CLONED" rec run true >/dev/null
rec_has "edit $PV --set .mountType = \"reverse-sshfs\" | .mounts = [{$(mnt "$PROJ"), \"writable\": true, $SSHFS_RO}]" \
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
rec_has "edit $PV --set del(.mountType) | .mounts = [{$(mnt "$PROJ"), \"writable\": true}]" \
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
rec_has "edit $PV --set del(.mountType) | .mounts = [{$(mnt "$PROJ"), \"writable\": true}]" \
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
rec_has "edit $PV --set del(.mountType) | .mounts = [{$(mnt "$PROJ"), \"writable\": true}]" \
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

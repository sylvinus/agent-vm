section ".git protection follows what Lima can do"
# Stock Lima accepts readonlyNames with a warning and ignores it, so only a
# refusal that names the field counts. Stock Lima failing for another reason
# still names it, in its "unknown field" warning: that is not support either.
# An answer that says neither is "cannot tell", never "no".
probe() {
  ( export AGENT_VM_TEST_REC="$SB/probe.log" AGENT_VM_TEST_PROTECTS="$PROTECTS" TMPDIR="$SB/probe-tmp"
    _agent_vm_lima_protects_git; case $? in 0) echo yes ;; 1) echo no ;; *) echo unknown ;; esac )
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
check "no limactl: cannot tell" "$(PATH="$SB/nolimactl" probe)" "unknown"
check "a Lima accepting the probe without a word: cannot tell" \
  "$(AGENT_VM_TEST_VALIDATE_SILENT=1 probe)" "unknown"

# Cannot tell: the start stops before anything changes, even for a VM that is
# protected today, and whatever the security questions say. --readonly and
# --unsafe-writable-git still start it.
protected_rec_early() { printf '[{"location": "%s", "writable": true, %s}]\n' "$PROJ" "$SSHFS_RO" > "$REC_MOUNTS"; }
protected_rec_early
out="$(AGENT_VM_TEST_VALIDATE_SILENT=1 AGENT_VM_TEST_STOPPED=1 rec run true)"
case "$out" in *"Error: cannot tell whether this Lima keeps .git read-only"*) pass "cannot tell: the start stops, and says why" ;; *) fail "cannot tell: $out" ;; esac
if grep -Eq '^(edit|start|clone) ' "$REC"; then fail "cannot tell: the VM was touched: $(grep -E '^(edit|start)' "$REC" | head -1)"
else pass "cannot tell: the protected VM is left as it is"; fi
AGENT_VM_TEST_VALIDATE_SILENT=1 AGENT_VM_TEST_STOPPED=1 rec --unsafe-writable-git run true >/dev/null
rec_has "start $PV" && pass "cannot tell: --unsafe-writable-git still starts it" || fail "cannot tell: --unsafe-writable-git did not start it"

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

# A running one is not restarted behind another session's back: asked, and
# with no one to answer, a risk that stops the start. With the questions off,
# warned and left running.
unprotected_rec
out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; rec run true )"
rec_has "edit $PV" && fail "a running VM was changed" || pass "running VM from before: left running"
case "$out" in *"can still write .git"*"Aborted. 'agent-vm stop', then run again."*) pass "running VM from before, no terminal: stops, and says how to protect it" ;; *) fail "no abort: $out" ;; esac
rec_has "agent-vm-write-probe" && fail "running VM from before, no terminal: the command ran" || pass "and the command did not run"
unprotected_rec
out="$(rec run true)"
rec_has "edit $PV" && fail "questions off: a running VM was changed" || pass "questions off: left running"
case "$out" in *"can still write .git"*"Continuing: AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1."*) pass "questions off: warned, then on" ;; *) fail "questions off: $out" ;; esac
unprotected_rec
out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 0; }; _agent_vm_ask_yn() { echo 1; }; rec run true )"
s="$(grep -n "^stop $PV" "$REC" | head -1 | cut -d: -f1)"
e="$(grep -n "^edit $PV --set .mountType = \"reverse-sshfs\"" "$REC" | head -1 | cut -d: -f1)"
t="$(grep -n "^start $PV" "$REC" | head -1 | cut -d: -f1)"
if [ -n "$s" ] && [ -n "$e" ] && [ -n "$t" ] && [ "$s" -lt "$e" ] && [ "$e" -lt "$t" ]; then
  pass "running VM from before, restart accepted: stopped, protected, started"
else
  fail "restart accepted: stop '${s:-none}', edit '${e:-none}', start '${t:-none}': $out"
fi

# From a base built by agent-vm 0.1.0 (no version of it recorded for the VM):
# no sshfs in it, so it boots once with no shares to get it, then gets the
# protected ones. Line numbers of the calls, in the order they must come.
BUILT_BY="$HOME/.agent-vm/.agent-vm-built-by-$PV"
MIGRATED="$HOME/.agent-vm/.agent-vm-sshfs-$PV"
old_vm() { rm -f "$BUILT_BY" "$MIGRATED" "$REC_MOUNTS"; }
at() { grep -n -- "$1" "$REC" | head -1 | cut -d: -f1; }
in_order() {
  local prev=0 n
  for n in "$@"; do
    [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1
    prev="$n"
  done
}
migration_order() {
  in_order "$(at "^edit $PV --set del(.mountType) | .mounts = \[\]")" "$(at "^start $PV")" \
    "$(at "/usr/local/bin/sshfs")" "$(at "^stop $PV")" \
    "$(at "^edit $PV --set .mountType = \"reverse-sshfs\"")"
}
old_vm
out="$(AGENT_VM_TEST_STOPPED=1 rec run true)"
migration_order && pass "0.1.0 VM: booted without shares, sshfs installed, stopped, then protected" \
  || fail "0.1.0 VM: $(grep -E '^(edit|start|stop|shell)' "$REC" | cut -c1-80)"
check "0.1.0 VM: started twice in all" "$(grep -c "^start $PV" "$REC")" "2"
case "$out" in *"base built by agent-vm 0.1.0"*"removed in a future release"*) pass "0.1.0 VM: warned" ;; *) fail "0.1.0 VM: no warning: $out" ;; esac
_agent_vm_mounts_protect_git "$PV" && pass "0.1.0 VM: recorded as protected" || fail "0.1.0 VM: not recorded"
[ -e "$MIGRATED" ] && pass "0.1.0 VM: recorded as migrated" || fail "0.1.0 VM: not recorded as migrated"
unprotected_rec
AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
rec_has "/usr/local/bin/sshfs" && fail "0.1.0 VM: migrated again" || pass "0.1.0 VM: migrated once"

old_vm
out="$(AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_SSHFS_FAIL=1 rec run true; echo "rc=$?")"
case "$out" in *"could not install sshfs"*"E: no sshfs"*"rc=1") pass "0.1.0 VM, install failed: stops with the reason" ;; *) fail "0.1.0 VM, install failed: $out" ;; esac
rec_has "reverse-sshfs" && fail "0.1.0 VM, install failed: shares changed" || pass "0.1.0 VM, install failed: no protected shares"
rec_has "agent-vm-write-probe" && fail "0.1.0 VM, install failed: the command ran" || pass "0.1.0 VM, install failed: the command did not run"
[ -e "$MIGRATED" ] && fail "0.1.0 VM, install failed: recorded as migrated" || pass "0.1.0 VM, install failed: tried again next time"

old_vm
rm -f "$PROTECTS"
AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
touch "$PROTECTS"
rec_has "/usr/local/bin/sshfs" && fail "0.1.0 VM on stock Lima: migrated" || pass "0.1.0 VM on stock Lima: its shares stay as they were"

# Cloned by 0.2.0 from a 0.1.0 base on stock Lima: its shares are recorded,
# unprotected. With readonlyNames later, it is migrated all the same.
old_vm
unprotected_rec
AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
migration_order && pass "recorded VM from a 0.1.0 base: migrated before it is protected" \
  || fail "recorded VM from a 0.1.0 base: $(grep -E '^(edit|start|stop|shell)' "$REC" | cut -c1-80)"

# Running, under --readonly: no question before the start, the shares change
# in the restart that applies --readonly. Migrated there too.
old_vm
out="$( _agent_vm_can_ask() { return 0; }; _agent_vm_ask_yn() { echo 1; }; AGENT_VM_TEST_RO=1 rec --readonly run true )"
in_order "$(at "^stop $PV")" "$(at "^edit $PV --set del(.mountType) | .mounts = \[\]")" \
  "$(at "/usr/local/bin/sshfs")" "$(at "^edit $PV --set .mountType = \"reverse-sshfs\"")" \
  && pass "running 0.1.0 VM, --readonly: migrated in the restart, before it is protected" \
  || fail "running 0.1.0 VM, --readonly: $(grep -E '^(edit|start|stop|shell)' "$REC" | cut -c1-80): $out"

# Its base recorded: no migration, with or without a record of its shares.
rm -f "$MIGRATED" "$REC_MOUNTS"
echo 0.2.0 > "$BUILT_BY"
AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
rec_has "/usr/local/bin/sshfs" && fail "VM from a current base: migrated" || pass "VM from a current base: not migrated"

# A new VM from a base 0.1.0 built: the same, on the bare clone, before its
# shares are set.
mv "$HOME/.agent-vm/.agent-vm-base-built-by" "$SB/built-by.saved"
echo 0.2.0 > "$HOME/.agent-vm/.agent-vm-built-by-$PV"
CLONED="$SB/cloned-old-base"; rm -f "$CLONED" "$REC_MOUNTS"
out="$(AGENT_VM_TEST_CLONED="$CLONED" rec run true)"
in_order "$(at "^clone ")" "$(at "/usr/local/bin/sshfs")" "$(at "^edit $PV --set .mountType = \"reverse-sshfs\"")" \
  && migration_order && pass "new VM from a 0.1.0 base: sshfs installed before its shares are set" \
  || fail "new VM from a 0.1.0 base: $(grep -E '^(clone|edit|start|stop|shell)' "$REC" | cut -c1-80)"
case "$out" in *"base built by agent-vm 0.1.0"*"agent-vm setup"*) pass "new VM from a 0.1.0 base: warned" ;; *) fail "new VM from a 0.1.0 base: $out" ;; esac
[ -e "$HOME/.agent-vm/.agent-vm-built-by-$PV" ] && fail "new VM from a 0.1.0 base: given a version" || pass "new VM from a 0.1.0 base: no version of its own"
rm -f "$CLONED" "$REC_MOUNTS"
out="$(AGENT_VM_TEST_CLONED="$CLONED" AGENT_VM_TEST_SSHFS_FAIL=1 rec run true; echo "rc=$?")"
case "$out" in *"could not install sshfs"*"rc=1") pass "new VM from a 0.1.0 base, install failed: stops" ;; *) fail "new VM, install failed: $out" ;; esac
rec_has "delete $PV" && pass "and the clone is deleted" || fail "new VM, install failed: clone kept"
mv "$SB/built-by.saved" "$HOME/.agent-vm/.agent-vm-base-built-by"
rm -f "$CLONED" "$REC_MOUNTS"
AGENT_VM_TEST_CLONED="$CLONED" rec run true >/dev/null
rec_has "/usr/local/bin/sshfs" && fail "new VM from a current base: migrated" || pass "new VM from a current base: not migrated"
check "new VM from a current base: its base version recorded" "$(cat "$HOME/.agent-vm/.agent-vm-built-by-$PV" 2>/dev/null)" "0.2.0"
rm -f "$CLONED"
protected_rec

# Back to a Lima without readonlyNames: reverse-sshfs goes, before the start.
rm -f "$PROTECTS"
protected_rec
AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
rec_has "edit $PV --set del(.mountType) | .mounts = [{$(mnt "$PROJ"), \"writable\": true}]" \
  && pass "Lima without readonlyNames: the VM goes back to the default mount type" \
  || fail "reverse-sshfs kept without readonlyNames: $(grep '^edit' "$REC")"
_agent_vm_mounts_protect_git "$PV" && fail "the record still says protected" || pass "and the record says so"

# A running VM asks nothing at the start, but stopped to apply new settings,
# it boots again: asked then, as any VM about to boot. Declined, it stays
# stopped and unchanged.
protected_rec
out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 0; }
        _agent_vm_ask_yn() { if [[ "$1" == "Stop the VM and apply changes?" ]]; then echo 1; else echo 0; fi; }
        rec --ssh-port 2299 run true; echo "rc=$?" )"
case "$out" in *"Lima cannot keep .git read-only"*"Aborted."*"is stopped"*"rc=1") pass "resize of a running VM: the questions are asked once it is stopped" ;; *) fail "resize of a running VM: $out" ;; esac
rec_has "stop $PV" && ! rec_has "start $PV" && ! rec_has "edit $PV" \
  && pass "declined: stopped, not changed, not started" || fail "declined: $(grep -E '^(stop|edit|start)' "$REC")"

# Where the shares would be reverse-sshfs (Windows, a QEMU VM of a Lima before
# 1.0), a Lima without readonlyNames does not keep the VM to its shares: the
# box says so, not only .git.
out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }
        _agent_vm_unprotected_mount_is_sshfs() { return 0; }
        AGENT_VM_TEST_STOPPED=1 rec run true; echo "rc=$?" )"
case "$out" in *"Lima cannot keep the VM to its shares"*"SSH keys"*"Aborted."*"--scratch"*"rc=1") pass "reverse-sshfs without readonlyNames: the box says the disk is at stake" ;; *) fail "reverse-sshfs box: $out" ;; esac
# --unsafe-writable-git gives up .git, not the rest of the disk: still asked.
out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }
        _agent_vm_unprotected_mount_is_sshfs() { return 0; }
        AGENT_VM_TEST_STOPPED=1 rec --unsafe-writable-git run true; echo "rc=$?" )"
case "$out" in *"Lima cannot keep the VM to its shares"*"Aborted."*"rc=1") pass "reverse-sshfs, --unsafe-writable-git: still asked" ;; *) fail "reverse-sshfs opt-out: $out" ;; esac
case "$( _agent_vm_unprotected_mount_is_sshfs() { return 0; }; AGENT_VM_UNSAFE_WRITABLE_GIT=1 rec info | grep '^security_questions=' )" in
  *lima*) pass "info: the same question with the opt-out" ;; *) fail "info: opt-out on reverse-sshfs asks nothing" ;;
esac
# --readonly cannot be enforced there: refused before the VM is touched.
out="$( _agent_vm_unprotected_mount_is_sshfs() { return 0; }
        AGENT_VM_TEST_STOPPED=1 rec --readonly run true; echo "rc=$?" )"
case "$out" in *"--readonly cannot be enforced here"*"rc=1") pass "reverse-sshfs, --readonly: refused" ;; *) fail "reverse-sshfs --readonly: $out" ;; esac
grep -Eq '^(edit|start|clone) ' "$REC" && fail "reverse-sshfs --readonly: the VM was touched" || pass "and nothing was touched"
# The real function: tests/11 stubs it on Windows.
sshfs_default() {
  ( . "$SELF_DIR/lib/mounts.sh"
    export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$PV" AGENT_VM_TEST_VMTYPE=qemu LIMA_HOME="$SB/old-lima"
    mkdir -p "$SB/old-lima/$PV"; echo "$1" > "$SB/old-lima/$PV/lima-version"
    _agent_vm_unprotected_mount_is_sshfs "$PV" && echo yes || echo no )
}
check "a QEMU VM of a Lima before 1.0: reverse-sshfs" "$(sshfs_default 0.23.2)" "yes"
check "a QEMU VM of Lima 2: 9p" "$(sshfs_default 2.1.0)" "$(_agent_vm_on_windows && echo yes || echo no)"
# Lima's own config can set the type for every VM: override.yaml first.
mkdir -p "$SB/old-lima/_config"
printf 'mountType: "reverse-sshfs"\n' > "$SB/old-lima/_config/default.yaml"
check "default.yaml setting reverse-sshfs" "$(sshfs_default 2.1.0)" "yes"
printf 'mountType: 9p # mine\n' > "$SB/old-lima/_config/override.yaml"
check "override.yaml wins over it" "$(sshfs_default 2.1.0)" "$(_agent_vm_on_windows && echo yes || echo no)"
rm -rf "$SB/old-lima/_config"
check "a VM on vz: not" \
  "$( . "$SELF_DIR/lib/mounts.sh"
      AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$PV" _agent_vm_unprotected_mount_is_sshfs "$PV" && echo yes || echo no )" \
  "$(_agent_vm_on_windows && echo yes || echo no)"

# --readonly on reverse-sshfs: enforced on the host by the builtin server of a
# Lima with readonlyNames, and refused otherwise.
touch "$PROTECTS"
protected_rec false
out="$(AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 AGENT_VM_TEST_MOUNTTYPE=reverse-sshfs rec --readonly run true)"
case "$out" in *"enforced on the host"*) pass "--readonly on protected reverse-sshfs: accepted" ;; *) fail "--readonly on protected reverse-sshfs: $out" ;; esac
rm -f "$PROTECTS"
printf '[{"location": "%s", "writable": false}]\n' "$PROJ" > "$REC_MOUNTS"
out="$(AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 AGENT_VM_TEST_MOUNTTYPE=reverse-sshfs rec --readonly run true)"
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

# A VM from before .hg: the names change while it is stopped, and a running
# one is offered the restart (here with the questions off: warned, left
# running).
names_rec() { printf '[{"location": "%s", "writable": true, "sshfs": {"sftpDriver": "builtin", "readonlyNames": %s}}]\n' "$PROJ" "$1" > "$REC_MOUNTS"; }
names_rec '[".git"]'
out="$(rec run true)"
rec_has "edit $PV" && fail "names: a running VM was changed" || pass "names: a running VM is left running"
case "$out" in *"older list of read-only names (it needs .git, .hg)"*"Continuing"*) pass "names: and warned" ;; *) fail "names, running VM: $out" ;; esac
names_rec '[".git"]'
out="$(AGENT_VM_TEST_STOPPED=1 rec run true)"
rec_has "edit $PV --set .mountType = \"reverse-sshfs\" | .mounts = [{$(mnt "$PROJ"), \"writable\": true, $SSHFS_RO}]" \
  && pass "names: a stopped VM from before .hg gets it" || fail "names: not updated: $(grep '^edit' "$REC")"
case "$out" in *"Making .git, .hg read-only for VM '$PV'"*) pass "names: and it says so" ;; *) fail "names: no notice: $out" ;; esac
_agent_vm_mounts_have_readonly_names "$PV" '[".git", ".hg"]' && pass "names: recorded" || fail "names: record: $(cat "$REC_MOUNTS")"
out="$(AGENT_VM_TEST_STOPPED=1 rec run true)"
rec_has "edit $PV" && fail "names: edited again with nothing to change" || pass "names: nothing to change the next time"

# core.hooksPath in the project: its first component joins the names.
if command -v git >/dev/null 2>&1; then
  # In subshells: bash 3.2 would keep git hashed for a later test that hides
  # it with PATH.
  ( git -C "$PROJ" init -q )
  hp() { ( git -C "$PROJ" config core.hooksPath "$1" ); }
  names() { _agent_vm_readonly_names "$PROJ"; }
  check "hooks: git's default, in .git" "$(names)" '[".git", ".hg"]'
  hp .husky/_
  check "hooks: husky's .husky/_ adds .husky" "$(names)" '[".git", ".hg", ".husky"]'
  hp tools/../.githooks
  check "hooks: the path is normalized" "$(names)" '[".git", ".hg", ".githooks"]'
  hp .Git/hooks
  check "hooks: under .git, whatever the case, adds nothing" "$(names)" '[".git", ".hg"]'
  hp "$SB/elsewhere"
  check "hooks: outside the project, nothing" "$(names)" '[".git", ".hg"]'
  hp .
  check "hooks: the project itself cannot be a name" "$(names)" '[".git", ".hg"]'
  hp 'a"b/x'
  check "hooks: a name the JSON cannot carry is left out" "$(names)" '[".git", ".hg"]'
  # The project below the top of the repository: paths are relative to it.
  mkdir -p "$PROJ/sub"
  hp .husky/_
  check "hooks: in the repository, outside a subdirectory project" "$(_agent_vm_readonly_names "$PROJ/sub")" '[".git", ".hg"]'
  hp sub/hooks
  check "hooks: inside a subdirectory project" "$(_agent_vm_readonly_names "$PROJ/sub")" '[".git", ".hg", "hooks"]'
  rmdir "$PROJ/sub"

  # A stopped VM gets the name before it starts, with a note; a running one
  # is offered the restart (questions off here: warned).
  hp .husky/_
  names_rec '[".git", ".hg"]'
  out="$(rec run true)"
  rec_has "edit $PV" && fail "hooks: a running VM was changed" || pass "hooks: a running VM is left running"
  case "$out" in *"older list of read-only names (it needs .git, .hg, .husky)"*) pass "hooks: and warned" ;; *) fail "hooks, running VM: $out" ;; esac
  names_rec '[".git", ".hg"]'
  out="$(AGENT_VM_TEST_STOPPED=1 rec run true)"
  rec_has "\"readonlyNames\": [\".git\", \".hg\", \".husky\"]}}]" && pass "hooks: a stopped VM gets .husky read-only" \
    || fail "hooks: not applied: $(grep '^edit' "$REC")"
  case "$out" in *"hooks from .husky/_ (core.hooksPath): every '.husky' in the project is read-only"*) pass "hooks: and it says so" ;; *) fail "hooks: no note: $out" ;; esac
  out="$(rec doctor)"
  case "$out" in *"ok    git runs hooks from .husky/_ (core.hooksPath): every '.husky' in the project is read-only for the VM"*) pass "doctor: protected hooks are ok" ;; *) fail "doctor: hooks: $out" ;; esac

  # Git before 2.31 has no --path-format: the hooks folder is still found.
  mkdir -p "$SB/oldgit"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --path-format=absolute ] && { echo "unknown option" >&2; exit 129; }; done\nexec "%s" "$@"\n' \
    "$(command -v git)" > "$SB/oldgit/git"
  chmod +x "$SB/oldgit/git"
  check "hooks: found without --path-format" "$(PATH="$SB/oldgit:$PATH" names)" '[".git", ".hg", ".husky"]'

  # Case: where the file system ignores it, a hooks path spelled with other
  # capitals is still in the project.
  check "a path in other capitals is inside, where case is ignored" \
    "$( _agent_vm_fs_nocase() { return 0; }; _agent_vm_rel_in /Work/Proj/.Husky/_ /work/proj )" ".Husky/_"
  ( _agent_vm_fs_nocase() { return 1; }; _agent_vm_rel_in /Work/Proj/x /work/proj ) >/dev/null \
    && fail "a path in other capitals counted as inside where case matters" \
    || pass "and not where case matters"

  # A repository below the project has hooks of its own.
  mkdir -p "$PROJ/lib/inner"
  ( git -C "$PROJ/lib/inner" init -q && git -C "$PROJ/lib/inner" config core.hooksPath .githooks )
  check "hooks: a nested repository's folder joins the names" "$(names)" '[".git", ".hg", ".husky", ".githooks"]'
  case "$(_agent_vm_project_hooks "$PROJ")" in *"lib/inner/.githooks"*) pass "hooks: named from the project" ;; *) fail "hooks: nested: $(_agent_vm_project_hooks "$PROJ")" ;; esac
  names_rec '[".git", ".hg"]'
  AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
  rec_has "\"readonlyNames\": [\".git\", \".hg\", \".husky\", \".githooks\"]}}]" \
    && pass "hooks: a start protects the nested folder by its own name, not the project's 'lib'" \
    || fail "hooks: nested, start: $(grep '^edit' "$REC")"
  rm -rf "$PROJ/lib"

  # A name that is not a dot-name is read-only in every folder of the
  # project, so it is asked first: yes by default, and when no one can answer.
  hp tools/hooks
  names_rec '[".git", ".hg", "tools"]'
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; AGENT_VM_TEST_STOPPED=1 rec run true )"
  rec_has "start $PV" && pass "hooks: a plain name, no terminal: protected, started" || fail "hooks: plain name, no terminal: $out"
  names_rec '[".git", ".hg"]'
  # if, not case: bash 3.2 misreads a case pattern's ) inside $( ).
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 0; }
          _agent_vm_ask_yn() { echo 0; }
          AGENT_VM_TEST_STOPPED=1 rec run true; echo "rc=$?" )"
  case "$out" in *"'tools' stays writable"*"Aborted."*"rc=1") pass "hooks: a plain name declined: a risk, stopped by default" ;; *) fail "hooks: plain name declined: $out" ;; esac
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 0; }
          _agent_vm_ask_yn() { if [ "$1" = "Continue anyway?" ]; then echo 1; else echo 0; fi; }
          AGENT_VM_TEST_STOPPED=1 rec run true )"
  rec_has "start $PV" && ! grep -q '"tools"' "$REC_MOUNTS" && ! rec_has '"tools"' \
    && pass "hooks: declined, then accepted as a risk: left writable" || fail "hooks: declined name: $(cat "$REC_MOUNTS") $out"

  # Hooks that cannot be protected stop the start, before anything changes,
  # unless the user answers yes. No terminal, or the default answer, aborts.
  hp .
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; AGENT_VM_TEST_STOPPED=1 rec run true )"
  rc=$?
  case "$out" in *"Warning: git's core.hooksPath is the project directory itself"*"Aborted."*) pass "hooks: the project itself, no terminal: aborted" ;; *) fail "hooks: no abort for '.': $out" ;; esac
  check "hooks: and it fails" "$rc" "1"
  if grep -Eq '^(edit|start|clone) ' "$REC"; then fail "hooks: the VM was touched before the abort: $(grep -E '^(edit|start|clone) ' "$REC" | head -1)"
  else pass "hooks: nothing touched before the abort"; fi
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 0; }; _agent_vm_ask_yn() { [ "$2" = N ] && echo 0 || echo 1; }; AGENT_VM_TEST_STOPPED=1 rec run true )"
  case "$out" in *"Aborted."*) pass "hooks: the default answer aborts" ;; *) fail "hooks: default answer went on: $out" ;; esac
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 0; }; _agent_vm_ask_yn() { echo 1; }; AGENT_VM_TEST_STOPPED=1 rec run true )"
  rc=$?
  check "hooks: a yes goes on" "$rc" "0"
  rec_has "start $PV" && pass "hooks: and the VM starts" || fail "hooks: not started after a yes: $out"
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; AGENT_VM_TEST_STOPPED=1 rec --unsafe-disable-security-prompts run true )"
  case "$out" in *"Continuing: --unsafe-disable-security-prompts."*) pass "hooks: --unsafe-disable-security-prompts goes on, and says so" ;; *) fail "hooks: the flag did not skip the question: $out" ;; esac
  # A VM already running: stopping would protect nothing, so no question.
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; rec run true )"
  case "$out" in *"project directory itself"*"Aborted."*) fail "hooks: a running VM was stopped on: $out" ;; *"project directory itself"*) pass "hooks: a running VM: warned, not asked" ;; *) fail "hooks: running VM: $out" ;; esac
  case "$(rec info | grep '^security_questions=')" in *hooks*) pass "info: security_questions names the hooks" ;; *) fail "info: hooks not named: $(rec info)" ;; esac
  hp 'a"b/x'
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; AGENT_VM_TEST_STOPPED=1 rec run true )"
  case "$out" in *"its name cannot be made read-only"*"Aborted."*) pass "hooks: a name that cannot be carried, no terminal: aborted" ;; *) fail "hooks: no abort for a bad name: $out" ;; esac
  hp .
  out="$(rec doctor)"
  case "$out" in *"warn  git runs hooks from the project directory itself (core.hooksPath), which the VM can write"*) pass "doctor: and a warning there" ;; *) fail "doctor: '.' hooks: $out" ;; esac
  hp .husky/_
  names_rec '[".git", ".hg"]'
  out="$(rec doctor)"
  case "$out" in *"warn  git runs hooks from .husky/_ (core.hooksPath), which the VM can still write"*) pass "doctor: a VM without the name yet is a warning" ;; *) fail "doctor: stale hooks: $out" ;; esac

  # Git config the VM can write: a file included from the project, and
  # commands named by a path in it. Commands found on PATH, options and URLs
  # are not paths in the project.
  ( git -C "$PROJ" config --unset core.hooksPath
    git -C "$PROJ" config core.pager less
    git -C "$PROJ" config core.sshCommand "ssh -o ProxyCommand=/usr/bin/nc"
    git -C "$PROJ" config alias.st status )
  check "config: nothing in the project, nothing said" "$(_agent_vm_project_config_risks "$PROJ")" ""
  ( printf '[core]\n\tfsmonitor = ./watch.sh\n' > "$PROJ/.gitconfig"
    git -C "$PROJ" config include.path ../.gitconfig
    git -C "$PROJ" config filter.x.clean "scripts/clean.sh %f"
    git -C "$PROJ" config alias.t '!./t.sh' )
  risks="$(_agent_vm_project_config_risks "$PROJ")"
  case "$risks" in *"config file .gitconfig"*) pass "config: an included file in the project" ;; *) fail "config: include: $risks" ;; esac
  case "$risks" in *"core.fsmonitor = ./watch.sh"*) pass "config: a command it sets" ;; *) fail "config: fsmonitor: $risks" ;; esac
  case "$risks" in *"filter.x.clean = scripts/clean.sh %f"*) pass "config: a relative command path" ;; *) fail "config: filter: $risks" ;; esac
  case "$risks" in *"alias.t = !./t.sh"*) pass "config: a shell alias" ;; *) fail "config: alias: $risks" ;; esac
  case "$risks" in *"core.pager"*|*sshcommand*|*"alias.st"*) fail "config: false positive: $risks" ;; *) pass "config: PATH commands, options and plain aliases left out" ;; esac
  check "config: an included file listed once" "$(grep -c 'config file .gitconfig' <<< "$risks")" "1"
  # An include of a file not there yet: git skips it, and the VM can create
  # it. includeIf too, and relative to the file holding it.
  ( git -C "$PROJ" config includeIf.gitdir:/.path ../later.gitconfig
    git -C "$PROJ" config --add include.path ../.git/x.gitconfig
    git -C "$PROJ" config --add include.path "$SB/outside.gitconfig" )
  risks="$(_agent_vm_project_config_risks "$PROJ")"
  case "$risks" in *"config file later.gitconfig"*) pass "config: an include of a file not there yet" ;; *) fail "config: missing include: $risks" ;; esac
  case "$risks" in *x.gitconfig*|*outside.gitconfig*) fail "config: an include in .git or outside the project listed: $risks" ;; *) pass "config: includes in .git or outside left out" ;; esac
  ( git -C "$PROJ" config --unset-all includeIf.gitdir:/.path
    git -C "$PROJ" config --unset-all include.path
    git -C "$PROJ" config include.path ../.gitconfig )
  names_rec '[".git", ".hg"]'
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; AGENT_VM_TEST_STOPPED=1 rec run true )"
  case "$out" in *"git on this machine uses these"*".gitconfig"*"Aborted."*) pass "config: a start stops on it" ;; *) fail "config: start: $out" ;; esac
  grep -Eq '^(edit|start|clone) ' "$REC" && fail "config: the VM was touched before the abort" || pass "config: nothing touched"
  case "$(rec info | grep '^security_questions=')" in *git-config*) pass "info: security_questions names the config" ;; *) fail "info: config not named: $(rec info)" ;; esac
  out="$(rec doctor)"
  case "$out" in *"warn  git on this machine uses these, and the VM can write them:"*"config file .gitconfig"*) pass "doctor: the config is a warning" ;; *) fail "doctor: config: $out" ;; esac
  # Under --readonly the VM writes none of it: no warning and no question,
  # for hooks, git config, or the restart of a running VM, and the names
  # are still given to the shares.
  hp .
  ro_names_rec() { printf '[{"location": "%s", "writable": false, "sshfs": {"sftpDriver": "builtin", "readonlyNames": %s}}]\n' "$PROJ" "$1" > "$REC_MOUNTS"; }
  ro_names_rec '[".git", ".hg"]'
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }
          AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 AGENT_VM_TEST_MOUNTTYPE=reverse-sshfs rec --readonly run true; echo "rc=$?" )"
  case "$out" in
    *"Aborted"*|*"git on this machine uses these"*|*"core.hooksPath is the project directory"*) fail "--readonly: warned or asked about what the VM cannot write: $out" ;;
    *"rc=0") pass "--readonly: no hooks or config question, and it starts" ;;
    *) fail "--readonly: $out" ;;
  esac
  hp tools/hooks
  ro_names_rec '[".git", ".hg"]'
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }
          AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 AGENT_VM_TEST_MOUNTTYPE=reverse-sshfs rec --readonly run true )"
  rec_has "\"readonlyNames\": [\".git\", \".hg\", \"tools\"]}}]" && pass "--readonly: the hooks folder name still goes to the shares" \
    || fail "--readonly: names: $(grep '^edit' "$REC")"
  ro_names_rec '[".git", ".hg"]'
  out="$( unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }
          AGENT_VM_TEST_RO=1 AGENT_VM_TEST_MOUNTTYPE=reverse-sshfs rec --readonly run true; echo "rc=$?" )"
  case "$out" in
    *"Restart it now"*|*"Aborted"*) fail "--readonly, running VM: asked to restart for names it cannot write: $out" ;;
    *"rc=0") pass "--readonly, running read-only VM with older names: no question" ;;
    *) fail "--readonly, running VM: $out" ;;
  esac
  rm -f "$PROJ/.gitconfig"

  rm -f "$PROTECTS"
  hp .husky/_
  out="$(rec doctor)"
  case "$out" in *"warn  git runs hooks from .husky/_ (core.hooksPath), which the VM can write"*) pass "doctor: without the protection, a warning" ;; *) fail "doctor: unprotected hooks: $out" ;; esac
  rm -rf "$PROJ/.git"
else
  printf '  skip core.hooksPath (git is not installed)\n'
fi
rm -f "$PROTECTS"

# A Lima without readonlyNames: a start with writable shares asks first, and
# stops before anything changes unless the answer is yes.
noprompt() { unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }; }
touched() { grep -Eq '^(edit|start|clone) ' "$REC"; }
# A question is only asked where it is seen: with stderr captured, it would
# wait unseen, so it counts as no terminal.
( _agent_vm_have_tty() { return 0; }; _agent_vm_can_ask ) 2>/dev/null \
  && fail "a question asked with stderr captured" || pass "stderr captured: no question"
case "$(rec info | grep -E '^(git_protected|security_questions)=' | tr '\n' ' ')" in
  "git_protected=0 security_questions=lima "*) pass "info: this Lima, named as a question" ;;
  *) fail "info: $(rec info | grep -E '^(git_protected|security_questions)=')" ;;
esac
out="$( noprompt; AGENT_VM_TEST_STOPPED=1 rec run true )"
rc=$?
case "$out" in *"Lima cannot keep .git read-only"*"Aborted."*) pass "no readonlyNames, no terminal: aborted, with why" ;; *) fail "no readonlyNames: no abort: $out" ;; esac
check "no readonlyNames: and it fails" "$rc" "1"
touched && fail "no readonlyNames: the VM was touched before the abort" || pass "no readonlyNames: nothing touched"
rec_has "agent-vm-write-probe" && fail "no readonlyNames: the command ran" || pass "no readonlyNames: the command did not run"
out="$( noprompt; _agent_vm_can_ask() { return 0; }; _agent_vm_ask_yn() { [ "$2" = N ] && echo 0 || echo 1; }; AGENT_VM_TEST_STOPPED=1 rec run true )"
case "$out" in *"Aborted."*) pass "no readonlyNames: the default answer aborts" ;; *) fail "no readonlyNames: default answer went on: $out" ;; esac
out="$( noprompt; _agent_vm_can_ask() { return 0; }; _agent_vm_ask_yn() { echo 1; }; AGENT_VM_TEST_STOPPED=1 rec run true )"
check "no readonlyNames: a yes goes on" "$?" "0"
rec_has "start $PV" && pass "no readonlyNames: and the VM starts" || fail "no readonlyNames: not started after a yes: $out"
# A VM already running: the risk is there already, so a warning, no question.
out="$( noprompt; rec run true )"
case "$out" in *"Aborted."*) fail "running VM: stopped on the question: $out" ;; *"this Lima cannot keep .git read-only, so the VM can write .git"*) pass "running VM: warned, not asked" ;; *) fail "running VM: $out" ;; esac
# No question where nothing is at stake, or where it was already answered.
printf '[{"location": "%s", "writable": false}]\n' "$PROJ" > "$REC_MOUNTS"
out="$( noprompt; AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 rec --readonly run true )"
case "$out" in *"Continue anyway"*|*"Aborted."*) fail "--readonly: asked anyway: $out" ;; *) pass "--readonly: no question" ;; esac
rec_has "start $PV" && pass "--readonly: the VM starts" || fail "--readonly: not started: $out"
out="$( noprompt; AGENT_VM_TEST_STOPPED=1 rec --unsafe-writable-git run true )"
case "$out" in *"Aborted."*) fail "--unsafe-writable-git: asked anyway: $out" ;; *) pass "--unsafe-writable-git: no question, .git writable was asked for" ;; esac
# The way past it: the flag, before the command or right after its name, or
# exactly 1 in the environment.
out="$( noprompt; AGENT_VM_TEST_STOPPED=1 rec --unsafe-disable-security-prompts run true )"
case "$out" in *"Lima cannot keep .git read-only"*"Continuing: --unsafe-disable-security-prompts."*) pass "--unsafe-disable-security-prompts: the warning, then on" ;; *) fail "--unsafe-disable-security-prompts: $out" ;; esac
out="$( noprompt; AGENT_VM_TEST_STOPPED=1 rec run --unsafe-disable-security-prompts true )"
case "$out" in *"Aborted."*) fail "run --unsafe-disable-security-prompts: not taken: $out" ;; *) pass "run --unsafe-disable-security-prompts: taken" ;; esac
rec_has "agent-vm-write-probe" && ! rec_has " true --unsafe" && ! grep -q "unsafe-disable-security-prompts" <<< "$(grep -v '^edit' "$REC")" \
  && pass "and the flag does not reach the command" || fail "the flag reached the command: $(grep -v '^edit' "$REC" | tail -2)"
out="$( noprompt; export AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1; AGENT_VM_TEST_STOPPED=1 rec run true )"
case "$out" in *"Continuing: AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1."*) pass "AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1: on, and says so" ;; *) fail "the env var: $out" ;; esac
out="$( noprompt; export AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=yes; AGENT_VM_TEST_STOPPED=1 rec run true )"
case "$out" in *"Aborted."*) pass "only 1 disables the prompts: 'yes' still asks" ;; *) fail "AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=yes went on: $out" ;; esac
case "$(agent-vm setup --unsafe-disable-security-prompts 2>&1 </dev/null)" in
  *"Unknown option: --unsafe-disable-security-prompts"*) pass "setup rejects --unsafe-disable-security-prompts" ;;
  *) fail "setup accepted --unsafe-disable-security-prompts" ;;
esac

# Home, in other capitals where case is ignored (Git Bash keeps the spelling
# typed), is still refused.
upper_home="$(printf '%s' "$HOME" | tr '[:lower:]' '[:upper:]')"
check "the home directory in other capitals is refused where case is ignored" \
  "$( _agent_vm_fs_nocase() { return 0; }; _agent_vm_unsafe_project "$upper_home" )" "is, or contains, your home directory"
_agent_vm_cleanup_state "$PV"

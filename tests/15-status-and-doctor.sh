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
# This limactl reads its stdin, and a VM it deleted leaves its listing, except
# the one named by STUCK.
mkdir -p "$SB/destroylima"
cat > "$SB/destroylima/limactl" <<STUB
#!/bin/sh
case "\$1" in
  list) printf 'agent-vm-a\nagent-vm-b\nagent-vm-base\n' \
          | if [ -s "$SB/destroyed" ]; then grep -vxF -f "$SB/destroyed"; else cat; fi ;;
  delete) cat >/dev/null; echo "delete \$2" >> "$SB/destroy.log"
          [ "\$2" = "\${STUCK:-}" ] || echo "\$2" >> "$SB/destroyed" ;;
  stop) cat >/dev/null ;;
esac
exit 0
STUB
chmod +x "$SB/destroylima/limactl"
destroy_three() {
  : > "$SB/destroyed"; : > "$SB/destroy.log"
  echo 1 > "$HOME/.agent-vm/.agent-vm-base-version"
  ( PATH="$SB/destroylima:$PATH"; _agent_vm_destroy_vms "$(printf 'agent-vm-a\nagent-vm-b\nagent-vm-base\n')" ) 2>&1
}
out="$(destroy_three)"; rc=$?
check "every listed VM is deleted" "$rc $(grep -c '^delete' "$SB/destroy.log")" "0 3"
if [ -e "$HOME/.agent-vm/.agent-vm-base-version" ]; then
  fail "deleting the base template left its ready marker"
else
  pass "deleting the base template retires its ready marker"
fi
out="$(STUCK=agent-vm-a destroy_three)"; rc=$?
case "$rc:$out" in
  1:*"could not delete VM 'agent-vm-a'"*) pass "a VM that stays is said, and fails destroy-all" ;;
  *) fail "a VM that stays: $rc $out" ;;
esac
check "the others are still deleted" "$(grep -c '^delete' "$SB/destroy.log")" "3"
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

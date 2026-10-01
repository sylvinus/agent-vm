#!/usr/bin/env bash
#
# agent-vm end-to-end tests. Run this ON A HOST that has Lima.
#
#   ./test-e2e.sh
#
# Unlike ./test.sh, this one builds a real VM and boots it. It is here for the
# claims that a stub limactl cannot check — above all that --readonly and the
# read-only .git are enforced on the host and not by a rule the guest could
# lift.
#
# It does not touch anything of yours. LIMA_HOME and the state directory are
# throwaways, so your `agent-vm-base` and your project VMs are never read,
# edited or deleted, and everything is removed on exit, Ctrl-C included.
#
# The .git checks run when this Lima has sshfs.readonlyNames (see
# `agent-vm doctor`), and are reported as skipped otherwise.
#
# Cost: one Debian image download (the throwaway LIMA_HOME starts with an
# empty cache) and a few minutes. `--preinstall=none` keeps the template to the
# base system.

set -uo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
AGENT_VM="${AGENT_VM:-$SELF_DIR/agent-vm.sh}"

FAIL=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
info() { printf '       %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }

if ! command -v limactl >/dev/null 2>&1; then
  echo "This suite needs Lima on the host. Install it, or run ./test.sh instead." >&2
  exit 2
fi

# --- isolation ----------------------------------------------------------------
# LIMA_HOME moves every instance out of ~/.lima; otherwise `agent-vm setup`
# would rebuild the `agent-vm-base` you actually use, since that name is not
# configurable.
# Under /tmp, not $TMPDIR: Lima puts a socket under LIMA_HOME/<vm>/, and macOS's
# $TMPDIR (/var/folders/...) is long enough to push its path past the 104
# bytes a Unix socket path may have, which fails `limactl create`.
SB="$(mktemp -d /tmp/agent-vm-e2e.XXXXXX)"
export AGENT_VM_STATE_DIR="$SB/state"
export LIMA_HOME="$SB/lima"
PROJ="$SB/project"
mkdir -p "$AGENT_VM_STATE_DIR" "$LIMA_HOME" "$PROJ"
git -C "$PROJ" init -q

cleanup() {
  printf '\nCleaning up (%s)...\n' "$SB"
  # Best effort: the VMs are in our own LIMA_HOME, so a stray one cannot
  # collide with the user's.
  for vm in $(limactl list -q 2>/dev/null); do
    limactl stop --force "$vm" >/dev/null 2>&1
    limactl delete --force "$vm" >/dev/null 2>&1
  done
  rm -rf "$SB"
}
trap cleanup EXIT
# Exiting runs the EXIT trap. A trap on INT that only cleaned up let the suite
# carry on against the deleted sandbox, reporting failures (and passes) that
# meant nothing.
trap 'exit 130' INT TERM

# The same probe agent-vm uses to decide.
PROTECTS_GIT=""
bash -c 'source "$1"; _agent_vm_lima_protects_git' _ "$AGENT_VM" && PROTECTS_GIT=1
# A start asks before going on when this Lima has no readonlyNames, or when
# your git config lacks safe.bareRepository, and offers to change that config.
# The output is captured here, so a question would wait unseen: they are
# answered yes, and nothing is offered. The suite is about what the VM can
# reach, not about those questions (./test.sh covers them).
export AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1

printf 'agent-vm end-to-end suite\n'
printf '  agent-vm:   %s\n' "$AGENT_VM"
printf '  LIMA_HOME:  %s\n' "$LIMA_HOME"
printf '  project:    %s\n' "$PROJ"
if [[ -n "$PROTECTS_GIT" ]]; then
  printf '  .git:       read-only for the VMs (this Lima has readonlyNames)\n'
else
  printf '  .git:       writable (this Lima has no readonlyNames)\n'
fi
printf '  your own VMs, ~/.lima and ~/.agent-vm are not touched.\n'

vm_name="$("$AGENT_VM" name "$PROJ")"

# Changing the mount mode of a RUNNING VM asks on the terminal first, and the
# output is captured here, so the question would wait unseen. Stop it first.
stop_vm() { (cd "$PROJ" && "$AGENT_VM" stop >/dev/null 2>&1); }

# A --readonly run. Its output ends up in $ro_out; a check on a missing file
# proves nothing unless agent-vm also said the mode is in force, since an
# aborted run leaves no file either.
ro_run() { ro_out="$(cd "$PROJ" && "$AGENT_VM" --readonly "$@" 2>&1)"; }
ro_applied() { case "$ro_out" in *"Read-only: the project"*) return 0 ;; esac; return 1; }

# =============================================================================
section "build the base template (--preinstall=none)"
# =============================================================================
printf '  this downloads a Debian image on the first run; be patient\n'
if "$AGENT_VM" setup --preinstall=none </dev/null; then
  pass "setup completed"
else
  fail "setup failed — nothing below can run"
  exit 1
fi

# =============================================================================
section "first run in a project directory"
# =============================================================================
echo "hello" > "$PROJ/host-file.txt"

if grep -q hello <<< "$(cd "$PROJ" && "$AGENT_VM" run cat "$PROJ/host-file.txt" 2>/dev/null)"; then
  pass "the project directory is mounted and readable in the VM"
else
  fail "the project directory is not readable in the VM"
fi

if (cd "$PROJ" && "$AGENT_VM" run sh -c "echo from-vm > '$PROJ/vm-file.txt'") \
   && [ "$(cat "$PROJ/vm-file.txt" 2>/dev/null)" = "from-vm" ]; then
  pass "a write from the VM lands on the host"
else
  fail "a write from the VM did not reach the host"
fi

# Last line: `run` prints the VM's resources first. reverse-sshfs is only
# host-enforced when it is the one agent-vm sets up for readonlyNames.
fstype="$(cd "$PROJ" && "$AGENT_VM" run findmnt -no FSTYPE "$PROJ" 2>/dev/null | tail -1)"
case "$fstype:$PROTECTS_GIT" in
  virtiofs:|9p:)  pass "the share uses a host-enforced mount type ($fstype)" ;;
  fuse.sshfs:1)   pass "the share is reverse-sshfs, as readonlyNames needs" ;;
  fuse.sshfs:)    fail "reverse-sshfs without readonlyNames: --readonly cannot be a boundary here" ;;
  *)              fail "unexpected project mount type: '$fstype'" ;;
esac

# =============================================================================
section ".git is read-only for the VM, root included"
# =============================================================================
# Git on the host runs what .git/config and hooks name. Enforced by Lima's
# SFTP server on the host, so root in the guest cannot lift it, at any depth,
# whatever the case of the name. The rest of the working tree stays writable.
# Repository layouts are made with plain shell: the template has no git.
if [ -n "$PROTECTS_GIT" ]; then
  git -C "$PROJ" init -q nested
  config_sum="$(cksum < "$PROJ/.git/config")"
  (cd "$PROJ" && "$AGENT_VM" run sudo sh -c 'echo "# e2e" >> .git/config' >/dev/null 2>&1)
  [ "$(cksum < "$PROJ/.git/config")" = "$config_sum" ] && pass "root in the VM cannot change .git/config" \
    || fail "root in the VM changed .git/config"
  (cd "$PROJ" && "$AGENT_VM" run sudo touch .git/hooks/e2e-hook >/dev/null 2>&1)
  [ ! -e "$PROJ/.git/hooks/e2e-hook" ] && pass "root in the VM cannot add a hook" || fail "root in the VM added a hook"
  (cd "$PROJ" && "$AGENT_VM" run sudo sh -c 'mv .git .git-moved' >/dev/null 2>&1)
  [ -d "$PROJ/.git" ] && [ ! -e "$PROJ/.git-moved" ] && pass "root in the VM cannot move .git away" \
    || fail "root in the VM moved .git"
  (cd "$PROJ" && "$AGENT_VM" run sudo sh -c 'echo x >> nested/.git/config' >/dev/null 2>&1)
  grep -q '^x$' "$PROJ/nested/.git/config" && fail "root in the VM changed a nested repository" \
    || pass "a nested repository is protected too"
  (cd "$PROJ" && "$AGENT_VM" run sh -c 'mkdir -p planted/.GIT' >/dev/null 2>&1)
  [ ! -e "$PROJ/planted/.GIT" ] && pass "the VM cannot plant a .git, whatever the case" \
    || fail "the VM planted planted/.GIT"
  (cd "$PROJ" && "$AGENT_VM" run sh -c "echo still > '$PROJ/worktree-file.txt'") \
    && [ "$(cat "$PROJ/worktree-file.txt" 2>/dev/null)" = "still" ] \
    && pass "the working tree stays writable" || fail "the working tree is not writable"
  grep -q '^ref:' <<< "$(cd "$PROJ" && "$AGENT_VM" run cat .git/HEAD 2>/dev/null)" \
    && pass "the VM can still read .git" || fail "the VM cannot read .git"
  (cd "$PROJ" && "$AGENT_VM" run sh -c 'mkdir -p planted/.hg' >/dev/null 2>&1)
  [ ! -e "$PROJ/planted/.hg" ] && pass "the VM cannot plant a .hg" || fail "the VM planted planted/.hg"
  # core.hooksPath in the project: its folder joins the names at the next start.
  git -C "$PROJ" config core.hooksPath .husky/_
  stop_vm
  (cd "$PROJ" && "$AGENT_VM" run sh -c 'mkdir -p .husky/_ && echo x > .husky/pre-commit' >/dev/null 2>&1)
  [ ! -e "$PROJ/.husky" ] && pass "the VM cannot write the core.hooksPath folder" \
    || fail "the VM wrote .husky although core.hooksPath points there"
  git -C "$PROJ" config --unset core.hooksPath
  rm -rf "$PROJ/.husky"
  stop_vm
else
  info "skipped: this Lima has no sshfs.readonlyNames, the VM can write .git"
fi

# =============================================================================
section "--readonly is enforced outside the guest"
# =============================================================================
# The whole point. A guest-side restriction would pass the first check and fail
# the second, which is what --offline and --git-read-only did before they were
# removed.
stop_vm
ro_run run sh -c "echo nope > '$PROJ/should-not-exist.txt'"
ro_status=$?

if ! ro_applied; then
  fail "--readonly was not applied"
  info "$ro_out"
elif [ "$ro_status" -ne 0 ] && [ ! -e "$PROJ/should-not-exist.txt" ]; then
  pass "a write from the VM is refused under --readonly"
else
  fail "the VM could write under --readonly"
  info "$ro_out"
  rm -f "$PROJ/should-not-exist.txt"
fi

# root in the VM tries to lift it. Under a bind-mount or an fstab flag this
# succeeds; under a host-side share it cannot.
#
# Verified on macOS/M2 + vz + virtiofs: the `remount,rw` itself SUCCEEDS (the
# guest kernel happily flips its own mount flag) and the write still fails with
# EPERM. Note the errno: a guest-side read-only mount would give EROFS, so
# EPERM is the signature of the backend refusing. Which is why this test writes
# after the remount instead of trusting the remount's exit status.
ro_run run sudo sh -c \
  "mount -o remount,rw '$PROJ' 2>/dev/null; echo escaped > '$PROJ/escaped.txt'"

if ! ro_applied; then
  fail "--readonly was not applied for the remount attempt"
  info "$ro_out"
elif [ ! -e "$PROJ/escaped.txt" ]; then
  pass "root in the VM cannot remount the project read-write"
else
  fail "root in the VM lifted --readonly: it is NOT a boundary"
  info "$ro_out"
  rm -f "$PROJ/escaped.txt"
fi

# The host side is unaffected: you keep editing while the agent cannot.
if echo "still mine" > "$PROJ/host-write.txt" 2>/dev/null; then
  pass "the host can still write while the VM is read-only"
else
  fail "the host lost write access to its own directory"
fi

# =============================================================================
section "--readonly covers every share, not just the project"
# =============================================================================
# A writable volume that contains the project is a second path to the same
# files, and the hypervisor enforces read-only per share. Under --readonly it
# has to be read-only as well. $SB is the project's parent.
#
# Volumes are mounted when a VM is created, so --reset: on the existing VM the
# volume would simply be absent, and the write would fail for that reason.
printf '%s:/mnt/sb:rw\n' "$SB" > "$AGENT_VM_STATE_DIR/volumes"
ro_run --reset run sudo sh -c \
  "test -d /mnt/sb/project || exit 3; echo x > /mnt/sb/project/via-volume.txt"
via_status=$?
if ! ro_applied; then
  fail "--readonly was not applied with the volume"
  info "$ro_out"
elif [ "$via_status" -eq 3 ]; then
  fail "the rw volume is not mounted in the VM: nothing was tested"
elif [ ! -e "$PROJ/via-volume.txt" ]; then
  pass "root cannot write the project through an rw volume under --readonly"
else
  fail "the project was written through a volume under --readonly"
  info "$ro_out"
  rm -f "$PROJ/via-volume.txt"
fi

# =============================================================================
section "the mode goes back"
# =============================================================================
if (cd "$PROJ" && "$AGENT_VM" run sh -c "echo back > '$PROJ/writable-again.txt'") \
   && [ -e "$PROJ/writable-again.txt" ]; then
  pass "dropping --readonly restores write access"
else
  fail "the project stayed read-only after --readonly was dropped"
fi
if (cd "$PROJ" && "$AGENT_VM" run sh -c "echo back > /mnt/sb/volume-again.txt") \
   && [ -e "$SB/volume-again.txt" ]; then
  pass "and an rw volume is writable again"
else
  fail "the rw volume stayed read-only after --readonly was dropped"
fi
rm -f "$AGENT_VM_STATE_DIR/volumes"

# =============================================================================
section "the rest of the VM stays writable under --readonly"
# =============================================================================
# --readonly is about the project share only: an agent still needs to install
# packages and write its own state.
stop_vm
if ro_run run sh -c 'touch /tmp/probe && touch "$HOME/probe"' && ro_applied; then
  pass "/tmp and \$HOME in the VM are writable under --readonly"
else
  fail "--readonly made the whole VM read-only"
fi

# =============================================================================
section "what the VM can reach on the host"
# =============================================================================
# Not a pass/fail: it reports a documented Lima behaviour that the site
# discloses. Lima NATs the guest's gateway to the host's 127.0.0.1, so
# whatever you have listening on localhost answers from inside the VM.
reachable=""
for port in 5432 6379 3306 11434; do
  if (cd "$PROJ" && "$AGENT_VM" run timeout 2 bash -c "echo > /dev/tcp/192.168.5.2/$port") >/dev/null 2>&1; then
    reachable="$reachable $port"
  fi
done
if [ -n "$reachable" ]; then
  info "host services reachable from the VM on 192.168.5.2:$reachable"
  info "expected, and disclosed. Put auth on local dev services."
else
  info "no common host service answered on 192.168.5.2 (nothing listening)"
fi

# =============================================================================
section "--scratch: nothing of the host mounted, deleted after"
# =============================================================================
# stderr captured: the question before the deletion is not asked, so the VM
# goes, as for any caller without a terminal.
echo "host-only" > "$PROJ/scratch-probe.txt"
scr_out="$(cd "$PROJ" && "$AGENT_VM" --scratch run sh -c \
  "test ! -e '$PROJ/scratch-probe.txt' && echo no-host-file; touch '$PROJ/from-scratch.txt' && echo wrote-own-disk; echo \"shares=\$(findmnt -rn -t virtiofs,9p,fuse.sshfs | wc -l | tr -d ' ')\"" 2>&1)"
case "$scr_out" in *no-host-file*) pass "the project's files are not in a scratch VM" ;; *) fail "a scratch VM sees the project: $scr_out" ;; esac
case "$scr_out" in *wrote-own-disk*) pass "it works at the project's path, on its own disk" ;; *) fail "the scratch folder is not writable: $scr_out" ;; esac
[ ! -e "$PROJ/from-scratch.txt" ] && pass "what it writes there does not reach the host" || fail "a scratch VM wrote into the project"
case "$scr_out" in *shares=0*) pass "no share is mounted in it" ;; *) fail "a share is mounted in a scratch VM: $scr_out" ;; esac
if grep -q -- '-scratch-' <<< "$(limactl list -q 2>/dev/null)"; then
  fail "the scratch VM is still there: $(limactl list -q | grep -- '-scratch-')"
else
  pass "the scratch VM is deleted"
fi
grep -qx "vm_exists=1" <<< "$("$AGENT_VM" info "$PROJ")" && pass "the folder's own VM is still there" || fail "the folder's own VM went"
rm -f "$PROJ/scratch-probe.txt"

# =============================================================================
section "the integrator surface against a real VM"
# =============================================================================
info_out="$(cd "$PROJ" && "$AGENT_VM" info "$PROJ")"
get() { printf '%s\n' "$info_out" | grep "^$1=" | cut -d= -f2-; }

[ "$(get vm_exists)" = "1" ]   && pass "info: vm_exists=1"    || fail "info: vm_exists is $(get vm_exists)"
[ "$(get base_exists)" = "1" ] && pass "info: base_exists=1"  || fail "info: base_exists is $(get base_exists)"
[ "$(get vm_name)" = "$vm_name" ] && pass "info: vm_name agrees with name" || fail "info: vm_name disagrees with name"

if "$AGENT_VM" version --min 0.2.0 >/dev/null 2>&1; then
  pass "version --min 0.2.0 is satisfied"
else
  fail "version --min 0.2.0 refused this build"
fi

# =============================================================================
section "teardown"
# =============================================================================
if (cd "$PROJ" && "$AGENT_VM" rm >/dev/null 2>&1) \
   && grep -qx "vm_exists=0" <<< "$("$AGENT_VM" info "$PROJ")"; then
  pass "rm deletes the project VM"
else
  fail "the project VM survived rm"
fi

# =============================================================================
printf '\n%s passed, %s failed\n' "$PASSED" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

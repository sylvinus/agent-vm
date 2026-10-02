# =============================================================================
section "commands against a recording limactl"
# =============================================================================
# One stub for the sections below. It logs every call, lists the base template
# and the VM named by AGENT_VM_TEST_VM, and reports its mount type as
# virtiofs (AGENT_VM_TEST_MOUNTTYPE to change it) on vz (AGENT_VM_TEST_VMTYPE). With AGENT_VM_TEST_CLONED set,
# that VM only exists once `clone` has created the file. AGENT_VM_TEST_STOPPED
# lists it as stopped, as does a `stop` until the next `start`, and
# AGENT_VM_TEST_RO makes the project write probe fail, as a read-only share
# would. AGENT_VM_TEST_STOP_FAIL makes `stop` leave it running.
# AGENT_VM_TEST_SSHFS_FAIL fails the sshfs install of a 0.1.0 VM.
# AGENT_VM_TEST_RUNTIME_FOUND makes the probe find the project's runtime
# script. What is piped into the env push goes to AGENT_VM_TEST_STDIN.
# `validate` answers like stock Lima 2.2 does to readonlyNames, or, while the
# file $PROTECTS exists, like a Lima that has it (both messages copied from
# the real binaries). AGENT_VM_TEST_VALIDATE_SILENT makes it accept the file
# without a word, an answer agent-vm cannot read.
REC="$SB/rec.log"
PROTECTS="$SB/lima-protects"
cat > "$SB/bin/limactl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENT_VM_TEST_REC"
listed() { [ -z "${AGENT_VM_TEST_CLONED:-}" ] || [ -e "$AGENT_VM_TEST_CLONED" ]; }
case "$1" in
  --version) echo "limactl version 2.0.3" ;;
  validate)
    [ -z "${AGENT_VM_TEST_VALIDATE_SILENT:-}" ] || exit 0
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
      *"{{.VMType}}"*) echo "${AGENT_VM_TEST_VMTYPE:-vz} ${AGENT_VM_TEST_MOUNTTYPE:-virtiofs}" ;;
      *"{{.CPUs}}"*"{{.Disk}}"*) listed && echo "$AGENT_VM_TEST_VM|1|3221225472|10737418240" ;;
      *"{{.Status}}|"*) listed && echo "$AGENT_VM_TEST_VM|Running|1|3221225472" ;;
      *"{{.Status}}"*)
        if [ -n "${AGENT_VM_TEST_BASE_RUNNING:-}" ]; then echo "agent-vm-base Running"; else echo "agent-vm-base Stopped"; fi
        if [ -n "${AGENT_VM_TEST_STOPPED:-}" ] || [ -e "$AGENT_VM_TEST_REC.stopped" ]; then st=Stopped; else st=Running; fi
        listed && echo "$AGENT_VM_TEST_VM $st" ;;
      *-q*) echo "agent-vm-base"; listed && echo "$AGENT_VM_TEST_VM" ;;
      *)
        echo "NAME STATUS"
        [ -n "${AGENT_VM_TEST_NOVMS:-}" ] && exit 0
        echo "agent-vm-base Stopped"; listed && echo "$AGENT_VM_TEST_VM Running" ;;
    esac ;;
  shell)
    case "$*" in
      # A guest asked for its mount type lies: agent-vm must not ask it.
      *findmnt*) echo 9p ;;
      *"/usr/local/bin/sshfs"*) [ -z "${AGENT_VM_TEST_SSHFS_FAIL:-}" ] || { echo "E: no sshfs" >&2; exit 1; } ;;
      *agent-vm-write-probe*)
        case "$*" in *'.agent-vm.env'*)
          cat >> "${AGENT_VM_TEST_STDIN:-/dev/null}"
          [ -n "${AGENT_VM_TEST_ENV_FAIL:-}" ] || echo env-ok
          [ -z "${AGENT_VM_TEST_RUNTIME_FOUND:-}" ] || echo runtime-found ;;
        esac
        [ -z "${AGENT_VM_TEST_RO:-}" ] || exit 1 ;;
      *"exec "*" -s"*) cat >> "${AGENT_VM_TEST_STDIN:-/dev/null}" ;;
      # The editor's prep (lib/code.sh): AGENT_VM_TEST_CODE_PREP is its answer.
      *"agent-vm-code "*)
        printf '%b' "${AGENT_VM_TEST_CODE_PREP-config=/home/u/.config/code-server/agent-vm-lima-x.yaml\npassword=0123456789abcdef0123456789abcdef\n}" ;;
    esac ;;
  start) rm -f "$AGENT_VM_TEST_REC.stopped" ;;
  stop) cat >/dev/null; [ -n "${AGENT_VM_TEST_STOP_FAIL:-}" ] || touch "$AGENT_VM_TEST_REC.stopped" ;;
  delete) [ -z "${AGENT_VM_TEST_CLONED:-}" ] || rm -f "$AGENT_VM_TEST_CLONED"; cat >/dev/null ;;
esac
exit 0
STUB
chmod +x "$SB/bin/limactl"
mkdir -p "$HOME/.agent-vm"
echo 1 > "$HOME/.agent-vm/.agent-vm-base-version"
echo 0.2.0 > "$HOME/.agent-vm/.agent-vm-base-built-by"
PV="$(_agent_vm_name "$PROJ")"
# Re-sourced by an earlier section, so stubbed again: no KVM and no QEMU on
# a test runner. Both checks: host probing is covered in lib/host.sh and
# tests/18-windows.sh, not here.
_agent_vm_check_linux_prereqs() { return 0; }
_agent_vm_check_windows_prereqs() { return 0; }
# The stub Lima runs its VMs on vz, which keeps them to their shares. On
# Windows a VM's shares are reverse-sshfs whatever Lima says: the tests of
# that case stub it, and tests/14 checks the real answer.
if _agent_vm_on_windows; then
  _agent_vm_unprotected_mount_is_sshfs() { return 1; }
fi
rec() {
  : > "$REC"
  rm -f "$REC.stopped"
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
rec_has "exec env -- \"\$@\"" && pass "the guest's env takes no option from the command (run -i foo)" \
  || fail "env options reachable: $(grep ' zsh ' "$REC")"

rec pi -p hi --rm >/dev/null
rec_has "shell --workdir $PROJ --tty $PV" && rec_has "agent-vm pi -p hi --rm" \
  && pass "pi: a TTY, and the arguments are pi's" || fail "pi: $(grep 'zsh' "$REC")"
rec claude >/dev/null
rec_has "shell --workdir $PROJ $PV -- zsh" && pass "claude: no TTY forced" || fail "claude: $(grep 'zsh' "$REC")"

# One reader for every command, before or right after its name.
take() { ( vm_opts=(); rm=""; taken=""; _agent_vm_take_opt "$@" || exit 1; echo "$taken:${vm_opts[*]-}:$rm" ); }
check "take: --disk 7"          "$(take --disk 7 x)"      "2:--disk 7:"
check "take: --disk=7"          "$(take --disk=7 x)"      "1:--disk 7:"
check "take: --ram is --memory" "$(take --ram 4)"         "2:--memory 4:"
check "take: --rm"              "$(take --rm x)"          "1::1"
check "take: not an option"     "$(take -p hi)"           "0::"
check "take: a missing value"   "$(take --disk 2>&1; echo $?)" "Error: --disk needs a value.
1"
AGENT_VM_TEST_STOPPED=1 rec claude --disk=50 -p hi >/dev/null
rec_has "edit $PV --disk 50" && rec_has "claude --dangerously-skip-permissions -p hi" \
  && pass "claude --disk=50: agent-vm's, not claude's" || fail "claude --disk=50: $(grep -E '^edit|zsh' "$REC")"
out="$(rec claude --disk abc)"
case "$?:$out" in
  1:*"--disk must be a positive integer (got: 'abc')"*) pass "claude --disk abc: refused, and said" ;;
  *) fail "claude --disk abc: $out" ;;
esac
rec_has "shell --workdir" && fail "claude ran anyway" || pass "and claude does not run"

# With no env left on the host, the guest copy must go too, not keep old secrets.
rm -f "$HOME/.agent-vm/env" "$PROJ/.agent-vm.env"
rec run true >/dev/null
rec_has '> "$HOME/.agent-vm.env")' && pass "an empty env still replaces the guest file" \
  || fail "an empty env left the guest file as it was"

# Each `limactl shell` is a round trip: the env push and the write probe share one.
out="$(rec run true)"
# The script is multi-line, so one call spans lines of the record: from the
# push's line to the probe's, no new `shell …` call starts.
check "one round trip for the env push and the probe" \
  "$(grep -c 'rm -f "$HOME/.agent-vm.env"' "$REC") $(grep -c 'agent-vm-write-probe' "$REC") $(sed -n '/rm -f "$HOME\/.agent-vm.env"/,/agent-vm-write-probe/p' "$REC" | grep -c '^shell ')" "1 1 0"
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

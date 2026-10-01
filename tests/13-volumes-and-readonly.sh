section "~/.agent-vm/volumes: entries limited to some projects"
mkdir -p "$SB/vol-f"
vols() { printf '%s\n' "$@" > "$HOME/.agent-vm/volumes"; _agent_vm_build_mounts_json "$PV" "$PROJ" true 2>"$SB/vols-err"; }
has_vol() { case "$1" in *"\"location\": \"$(_agent_vm_host_path "$SB/vol-f")\""*) echo yes ;; *) echo no ;; esac; }
check "filter: the project's own path" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$PROJ")")" yes
check "filter: a trailing slash is the same path" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$PROJ/")")" yes
check "filter: another project's path" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$SB/other")")" no
check "filter: a parent is not a match" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$SB")")" no
check "filter: * matches below a directory" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:$SB/*")")" yes
check "filter: * does not match elsewhere" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro:/nowhere/*")")" no
check "filter: ~ is expanded" \
  "$( HOME="$SB"; _agent_vm_volume_matches '~/proj' "$PROJ" && echo yes || echo no )" yes
check "filter: mode rw is kept" \
  "$(vols "$SB/vol-f:/mnt/f:rw:$PROJ" | grep -oF "$(mnt "$SB/vol-f" /mnt/f), \"writable\": true")" \
  "$(mnt "$SB/vol-f" /mnt/f), \"writable\": true"
check "filter: no destination mounts at the same path" \
  "$(vols "$SB/vol-f::ro:$PROJ" | grep -cF "{$(mnt "$SB/vol-f"), \"writable\": false}")" 1
check "filter: no destination, short form" \
  "$(vols "$SB/vol-f:ro:$PROJ" | grep -cF "{$(mnt "$SB/vol-f"), \"writable\": false}")" 1
# Entries that do not read as source:destination:mode:project are refused, not
# guessed: read as a destination, the project filter is lost and the entry
# mounted in every project (cases from #30).
for e in "$SB/vol-f:/mnt/f:rw:" \
         "$SB/vol-f:/mnt/f:$SB/other" \
         "$SB/vol-f:/mnt/f:$SB/other:rw" \
         "$SB/vol-f:/mnt/f:rw:$SB/other:ro" \
         "$SB/vol-f:/mnt/f:ro:$SB/other:x"; do
  out="$(vols "$e")"
  if [ "$(has_vol "$out")" = no ] && grep -q "Warning: Mount entry '$e'" "$SB/vols-err"; then
    pass "refused, with a warning: ${e#"$SB"/}"
  else
    fail "not refused: ${e#"$SB"/} -> $out $(cat "$SB/vols-err")"
  fi
done
out="$(vols "$SB/vol-f:/mnt/f:rw:")"
grep -q "empty project filter" "$SB/vols-err" && pass "an empty filter is named as such" || fail "empty filter: $(cat "$SB/vols-err")"
out="$(vols "$(printf '%s:/mnt/a\tb:ro' "$SB/vol-f")")"
check "a control character in an entry: refused" "$(has_vol "$out") $(grep -c 'control character' "$SB/vols-err")" "no 1"
out="$(vols "$SB/vol-f:/mnt/f:ro:~nobody/proj")"
check "a ~user filter is not an absolute path: refused" "$(has_vol "$out") $(grep -c 'not an absolute path' "$SB/vols-err")" "no 1"
check "the filter's ~/ still expands" \
  "$( HOME="$SB"; _agent_vm_volume_matches '~/proj' "$PROJ" && echo yes || echo no )" yes

out="$(vols "$SB/vol-f:/mnt/f:ro:relative/path")"
check "filter: a relative one matches nothing" "$(has_vol "$out")" no
grep -q "Project filter 'relative/path'.*not an absolute path" "$SB/vols-err" \
  && pass "filter: and says why" || fail "filter: relative filter not reported: $(cat "$SB/vols-err")"
# A relative destination is inside the project, and made on the host, which
# needs perl (_agent_vm_nofollow). Without it the entry is skipped, and said.
if [[ -n "$AGENT_VM_HAS_PERL" ]]; then
out="$(vols "$SB/vol-f:.claude:ro:$PROJ")"
check "relative: inside the project" \
  "$(printf '%s' "$out" | grep -cF "$(mnt "$SB/vol-f" "$PROJ/.claude")")" 1
[ -d "$PROJ/.claude" ] && pass "relative: the mount point is made on the host" || fail "relative: no $PROJ/.claude"
vols "$SB/vol-f:./a/b:ro" >/dev/null
[ -d "$PROJ/a/b" ] && pass "relative: ./ and subdirectories" || fail "relative: no $PROJ/a/b"
else
  out="$(vols "$SB/vol-f:.claude:ro:$PROJ")"
  check "relative, no perl: skipped, and said" \
    "$(has_vol "$out") $(grep -c 'perl is needed' "$SB/vols-err") $([ -e "$PROJ/.claude" ] && echo made || echo none)" "no 1 none"
fi
mkdir -p "$SB/outside"
out="$(vols "$SB/vol-f:../outside/x:ro")"
check "relative: .. is refused" "$(has_vol "$out")" no
grep -q "goes out of the project with '..'" "$SB/vols-err" && [ ! -e "$SB/outside/x" ] \
  && pass "relative: and nothing is made outside" || fail "relative ..: $(cat "$SB/vols-err")"
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
ln -s "$SB/outside" "$PROJ/planted"
out="$(vols "$SB/vol-f:planted/x:ro")"
check "relative: a symlink in the project is refused" "$(has_vol "$out")" no
grep -q "goes through a symlink in the project" "$SB/vols-err" && [ ! -e "$SB/outside/x" ] \
  && pass "relative: and mkdir does not follow it" || fail "relative symlink: $(cat "$SB/vols-err"); $(ls "$SB/outside")"
rm -f "$PROJ/planted"
if [[ -n "$AGENT_VM_HAS_PERL" ]]; then
# The VM can plant the link after the check above: here, right before the
# mount point is made, for a directory and for a file source.
race_real="$(typeset -f _agent_vm_nofollow)"
mkdir -p "$SB/race-out"
for kind in dir file; do
  src="$SB/vol-f"; [ "$kind" = file ] && { src="$SB/race-src.toml"; echo x > "$src"; }
  out="$( eval "${race_real/_agent_vm_nofollow/_race_nofollow}"
          _agent_vm_nofollow() { ln -s "$SB/race-out" "$PROJ/raced"; _race_nofollow "$@"; }
          _agent_vm_project_mountpoint "$PROJ" raced/x "$src" 2>"$SB/race-err" )"
  check "relative, a link planted after the check ($kind): refused, nothing made outside" \
    "$out|$(ls -A "$SB/race-out")|$(grep -c 'goes through a symlink' "$SB/race-err")" "||1"
  rm -f "$PROJ/raced" "$SB/race-src.toml"
done
rm -rf "$SB/race-out"
else
  printf '  skip relative: a link planted after the check (perl is not installed)\n'
fi
else
  printf '  skip relative: symlink in the project (ln -s plants copies on this machine)\n'
fi
out="$(vols "$SB/vol-f:.:ro")"
check "relative: the project itself is refused" "$(has_vol "$out")" no
echo x > "$SB/vol-file.toml"
if [[ -n "$AGENT_VM_HAS_PERL" ]]; then
vols "$SB/vol-file.toml:conf/app.toml" >/dev/null
[ -f "$PROJ/conf/app.toml" ] && pass "relative, a file: an empty file is its mount point" || fail "relative file: no placeholder"
grep -q "|$PROJ/conf/app.toml\$" "$HOME/.agent-vm/.agent-vm-file-mounts-$PV" \
  && pass "relative, a file: bound at that path" || fail "relative file: $(cat "$HOME/.agent-vm/.agent-vm-file-mounts-$PV")"
fi
# Two file entries: the JSON is only JSON.
echo y > "$SB/vol-file2.toml"
out="$(vols "$SB/vol-file.toml:/etc/a.toml" "$SB/vol-file2.toml:/etc/b.toml")"
case "$out" in \[*\]) pass "two file entries: the mounts JSON alone" ;; *) fail "two file entries: $out" ;; esac
rm -rf "$PROJ/.claude" "$PROJ/a" "$PROJ/planted" "$PROJ/conf" "$SB/outside" "$SB/vol-file.toml" "$SB/vol-file2.toml"
check "no filter: every project, as before" "$(has_vol "$(vols "$SB/vol-f:/mnt/f:ro")")" yes
check "no filter, no mode: as before" \
  "$(vols "$SB/vol-f:/mnt/f" | grep -c "\"mountPoint\": \"/mnt/f\", \"writable\": false")" 1
rm -f "$HOME/.agent-vm/volumes"

section "--readonly makes every share read-only"
# The hypervisor enforces read-only per share, not per host file. A writable
# volume containing the project (~/work:/mnt/work:rw) was a way to write the
# project under --readonly without root.
mkdir -p "$SB/vol-rw" "$SB/vol-ro"
printf '%s:/mnt/rw:rw\n%s:/mnt/ro\n' "$SB/vol-rw" "$SB/vol-ro" > "$HOME/.agent-vm/volumes"
ro_json="$(_agent_vm_build_mounts_json "$PV" "$PROJ" false 2>"$SB/ro-notice")"
rw_json="$(_agent_vm_build_mounts_json "$PV" "$PROJ" true 2>/dev/null)"
case "$ro_json" in
  *'"writable": true'*) fail "a share stays writable under --readonly: $ro_json" ;;
  *) pass "no share is writable under --readonly" ;;
esac
case "$rw_json" in
  *"$(mnt "$SB/vol-rw" /mnt/rw), \"writable\": true"*)
    pass "without it, an rw volume is writable again" ;;
  *) fail "rw volume not restored: $rw_json" ;;
esac
case "$(cat "$SB/ro-notice")" in
  *"'$SB/vol-rw' (rw in ~/.agent-vm/volumes) is mounted read-only too"*) pass "the downgrade is announced" ;;
  *) fail "no notice for the downgraded volume" ;;
esac

# An existing VM whose project is already read-only: the probe agrees with
# --readonly, so only the record of applied mounts can say a volume is still
# writable. Stopped, so no prompt is needed.
REC_MOUNTS="$HOME/.agent-vm/.agent-vm-mounts-$PV"
ro_run() { AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 rec --readonly run true >/dev/null; }
printf '%s\n' "[{\"location\": \"$PROJ\", \"writable\": false}, {\"location\": \"$SB/vol-rw\", \"writable\": true}]" > "$REC_MOUNTS"
ro_run
rec_has "edit $PV --set del(.mountType) | .mounts" && pass "a recorded writable volume forces a remount" \
  || fail "a writable volume survived --readonly"
_agent_vm_mounts_all_readonly "$PV" && pass "the new record has no writable share" \
  || fail "the record still has a writable share: $(cat "$REC_MOUNTS")"
ro_run
rec_has "edit $PV" && fail "an all read-only VM was remounted again" \
  || pass "an all read-only VM is left alone"
# Back to writable while it runs: another terminal may be using it under
# --readonly, so it is asked (no by default), not taken for a broken mount.
out="$(AGENT_VM_TEST_RO=1 rec run true; echo "rc=$?")"
case "$out" in *"runs read-only (--readonly)"*"not restarted"*"rc=1") pass "after --readonly, running, no terminal: not restarted" ;; *) fail "after --readonly, running: $out" ;; esac
rec_has "stop $PV" && fail "after --readonly, running: stopped unasked" || pass "and it was not stopped"
out="$( _agent_vm_can_ask() { return 0; }; _agent_vm_ask_yn() { echo 1; }; AGENT_VM_TEST_RO=1 rec run true )"
rec_has "stop $PV" && rec_has "edit $PV" && pass "after --readonly, running, restart accepted: made writable" || fail "after --readonly, accepted: $out"
_agent_vm_mounts_all_readonly "$PV" && fail "after --readonly, accepted: still recorded read-only" || pass "and recorded writable"
# Stopped: the end of a --readonly session is said as such, not as a broken
# mount being repaired.
printf '%s\n' "[{\"location\": \"$PROJ\", \"writable\": false}]" > "$REC_MOUNTS"
out="$(AGENT_VM_TEST_STOPPED=1 rec run true)"
case "$out" in *"left read-only by --readonly; making it writable again"*) pass "after --readonly, stopped: says it is making the VM writable again" ;; *) fail "after --readonly, stopped: $out" ;; esac
printf '[{"location": "%s", "writable": true}]\n' "$PROJ" > "$REC_MOUNTS"
out="$(AGENT_VM_TEST_RO=1 rec run true)"
case "$out" in *"Project mount is not writable; repairing"*) pass "a writable VM that cannot write: a repair" ;; *) fail "broken mount: $out" ;; esac
# The first push ran on the broken mount, where the VM could not see the
# project's env file or runtime: the repaired VM gets them pushed again.
check "after a repair, the env is pushed again, with the project's files" \
  "$(grep -c 'rm -f "$HOME/.agent-vm.env"' "$REC") $(grep -c "^shell $PV sh -c" "$REC")" "2 2"
rm -f "$REC_MOUNTS"
ro_run
rec_has "edit $PV --set del(.mountType) | .mounts" && pass "no record (an older VM): remounted to be sure" \
  || fail "an unrecorded VM was trusted"
_agent_vm_cleanup_state "$PV"
[ -e "$REC_MOUNTS" ] && fail "rm/--reset left the mounts record" || pass "rm/--reset drops the mounts record"

# Declining a resize of a running VM (or having no terminal to accept it on)
# used to return before anything else: --readonly was then never applied, and
# the command ran on a writable VM.
# --disk: unlike CPUs and memory, it is not clamped to this host's share.
out="$(rec --readonly --disk 20 run true)"
rc=$?
case "$rc:$out" in
  1:*"Not applied: the VM keeps its current settings"*"--readonly was requested but not applied"*)
    pass "a declined resize does not skip --readonly" ;;
  *) fail "a declined resize skipped --readonly ($rc): $out" ;;
esac
rec_has "agent-vm true" && fail "the command ran on a writable VM" || pass "and the command does not run"
rec_has "edit $PV --disk" && fail "the declined resize was applied" || pass "and the resize is not applied"
_agent_vm_cleanup_state "$PV"
rm -f "$HOME/.agent-vm/volumes"

section "--readonly on a stopped VM: read-only from its first boot"
# A VM that last ran writable used to be started writable, then stopped and
# made read-only: whatever starts with the VM had a writable window.
printf '[{"location": "%s", "writable": true}]\n' "$PROJ" > "$REC_MOUNTS"
AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 rec --readonly run true >/dev/null
e="$(grep -n "^edit $PV --set" "$REC" | head -1 | cut -d: -f1)"
s="$(grep -n "^start $PV" "$REC" | head -1 | cut -d: -f1)"
if [ -n "$e" ] && [ -n "$s" ] && [ "$e" -lt "$s" ]; then
  pass "the shares are made read-only before the VM starts"
else
  fail "read-only applied at '${e:-none}', start at '${s:-none}'"
fi
check "and it starts once" "$(grep -c "^start $PV" "$REC")" "1"
rec_has "stop $PV" && fail "the VM was stopped to apply --readonly" || pass "and is not stopped again"
# Back to writable: also before the start.
AGENT_VM_TEST_STOPPED=1 rec run true >/dev/null
check "the end of a --readonly session: changed first, then one start" \
  "$(grep -c "^start $PV" "$REC") $(grep -E "^(edit $PV --set|start $PV)" "$REC" | head -1 | cut -d' ' -f1)" "1 edit"
# Whether --readonly holds is decided on the host: the guest is not asked.
rec_has "findmnt" && fail "the guest was asked for its mount type" || pass "the guest is not asked for its mount type"

section "a stop that did not happen changes nothing"
# The shares were edited and recorded read-only while the VM still ran with
# its writable ones.
printf '[{"location": "%s", "writable": true}]\n' "$PROJ" > "$REC_MOUNTS"
out="$(AGENT_VM_TEST_STOP_FAIL=1 AGENT_VM_TEST_RO=1 rec run true)"
case "$?:$out" in
  1:*"could not stop VM '$PV'"*) pass "the repair stops only once the VM is down" ;;
  *) fail "a failed stop went on: $out" ;;
esac
rec_has "edit $PV" && fail "the shares were edited on a running VM" || pass "and nothing is edited"
check "and the record is unchanged" "$(cat "$REC_MOUNTS")" "[{\"location\": \"$PROJ\", \"writable\": true}]"
_agent_vm_cleanup_state "$PV"
# `agent-vm stop` said "VM stopped." whatever happened.
out="$(rec stop)"
case "$?:$out" in 0:*"VM stopped."*) pass "stop: a VM that stops is said stopped" ;; *) fail "stop: $out" ;; esac
out="$(AGENT_VM_TEST_STOP_FAIL=1 rec stop)"
case "$?:$out" in
  1:*"is still running"*) pass "stop: a VM that keeps running is an error" ;;
  *) fail "stop that did not take: $out" ;;
esac
case "$out" in *"VM stopped."*) fail "stop: reported stopped while running" ;; *) pass "stop: and not reported stopped" ;; esac

section "directories that are never shared"
# `cd ~ && agent-vm shell` handed the VM every dotfile and SSH key, read-write.
refused() {  # <dir>
  local out
  out="$( cd "$1" && export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$PV"; : > "$REC"; agent-vm run true </dev/null 2>&1 )"
  case "$?:$out" in
    1:*"refusing to share"*) grep -q '^clone\|^start\|^shell' "$REC" && echo "refused, but limactl ran" || echo refused ;;
    *) echo "accepted: $out" ;;
  esac
}
check "the home directory"          "$(refused "$HOME")" "refused"
check "a parent of it"              "$(refused "$SB")" "refused"
check "/"                           "$(refused /)" "refused"
check "agent-vm's own directory"    "$(refused "$AGENT_VM_SCRIPT_DIR")" "refused"
check "a parent of agent-vm's"      "$(refused "$(dirname "$AGENT_VM_SCRIPT_DIR")")" "refused"
check "agent-vm's state"            "$(refused "$HOME/.agent-vm")" "refused"
# Inside them: the VM would write what the host runs (lib/), or every VM's
# config (Lima's _config/override.yaml).
mkdir -p "$HOME/.agent-vm/inside" "$(_agent_vm_lima_home)/_config"
check "a folder inside agent-vm"    "$(refused "$AGENT_VM_SCRIPT_DIR/lib")" "refused"
check "a folder inside its state"   "$(refused "$HOME/.agent-vm/inside")" "refused"
check "a folder inside Lima's"      "$(refused "$(_agent_vm_lima_home)/_config")" "refused"
check "and says which"              "$(_agent_vm_unsafe_project "$AGENT_VM_SCRIPT_DIR/lib")" "is inside agent-vm itself"
case "$(refused "$PROJ")" in accepted*) pass "a project directory is shared" ;; *) fail "a project directory was refused" ;; esac
case "$(_agent_vm_unsafe_project "$HOME/proj-under-home" 2>/dev/null || echo none)" in
  none) pass "a project inside the home directory is fine" ;;
  *) fail "a project inside the home directory was refused" ;;
esac

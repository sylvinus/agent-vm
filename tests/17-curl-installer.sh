# =============================================================================
section "www/public/install.sh (curl | sh)"
# =============================================================================
# Stub curl and git serve releases from $WF, one directory per tag, and log
# what was asked for. A release is agent-vm.sh and lib/, plus a MARK file
# naming it.
INSTALLER="$SELF_DIR/www/public/install.sh"
WF="$SB/wfix"; WBIN="$SB/wbin"; WH="$SB/whome"
mkdir -p "$WBIN" "$WH"
cat > "$WBIN/curl" <<'STUB'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; https://*) url="$1" ;; esac
  shift
done
echo "$url" >> "$WF/log"
case "$url" in
  */releases/latest/download/*) f="$WF/$(cat "$WF/latest")/${url##*/}" ;;
  */releases/download/*) t="${url%/*}"; f="$WF/${t##*/}/${url##*/}" ;;
  *) exit 22 ;;
esac
[ -f "$f" ] || exit 22
cp "$f" "$out"
STUB
cat > "$WBIN/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$WF/log"
case "$1" in
  clone) mkdir -p "$3/.git" && cp -R "$WF/src/." "$3/" ;;
  -C) [ -d "$2/.git" ] ;;
esac
STUB
chmod +x "$WBIN/curl" "$WBIN/git"
make_release() {  # <version> [corrupt]
  local d="$WF/v$1" s="$WF/stage/agent-vm-$1"
  mkdir -p "$d" "$s"
  cp -R "$WF/src/." "$s/"; echo "$1" > "$s/MARK"
  tar -czf "$d/agent-vm-$1.tar.gz" -C "$WF/stage" "agent-vm-$1"
  local sum; sum="$(_agent_vm_sha256 < "$d/agent-vm-$1.tar.gz" | cut -d' ' -f1)"
  [ -z "${2:-}" ] || sum="0000$sum"
  printf '%s  agent-vm-%s.tar.gz\n' "$sum" "$1" > "$d/SHA256SUMS"
  echo "v$1" > "$WF/latest"
}
mkdir -p "$WF/src"; cp -R "$AGENT_VM_SH" "$(dirname "$AGENT_VM_SH")/lib" "$WF/src/"
# The base is built (the stub limactl lists it), so `install` has nothing to
# ask on a terminal.
mkdir -p "$WH/state"; echo 1 > "$WH/state/.agent-vm-base-version"
winst() {
  ( export HOME="$WH" WF XDG_DATA_HOME= AGENT_VM_BIN_DIR="$WH/bin" SHELL=/bin/zsh PATH="$WBIN:$PATH" \
      AGENT_VM_STATE_DIR="$WH/state"
    sh "${WINSTALLER:-$INSTALLER}" "$@" ) 2>&1
}
# Without symlinks each install plants a copy, so a later install would trip
# over it instead of running: clear it where a check needs a fresh install.
fresh_link() { [[ -n "$AGENT_VM_HAS_SYMLINKS" ]] || rm -f "$WH/bin/agent-vm"; }
WDIR="$WH/.local/share/agent-vm"

make_release 1.0.0
: > "$WF/log"
out="$(winst)"; rc=$?
check "release: installs" "$rc" "0"
case "$out" in *"agent-vm claude"*) pass "release: base built, nothing asked" ;; *) fail "release: $out" ;; esac
check "release: the latest tarball is in place" "$(cat "$WDIR/MARK" 2>/dev/null)" "1.0.0"
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
check "release: linked onto the PATH" "$(readlink "$WH/bin/agent-vm")" "$WDIR/agent-vm.sh"
else
  printf '  skip release: readlink (ln -s plants copies on this machine)\n'
fi
check "release: sums from latest/, the tarball from its tag" "$(tr '\n' ' ' < "$WF/log")" \
  "https://github.com/sylvinus/agent-vm/releases/latest/download/SHA256SUMS https://github.com/sylvinus/agent-vm/releases/download/v1.0.0/agent-vm-1.0.0.tar.gz "

make_release 1.1.0
fresh_link
out="$(winst)"; rc=$?
check "rerun: replaced by the new release" "$rc:$(cat "$WDIR/MARK")" "0:1.1.0"
check "rerun: no staging or old copy left" "$(ls -A "$WH/.local/share")" "agent-vm"
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
case "$out" in *"already linked"*) pass "rerun: the link is kept" ;; *) fail "rerun: $out" ;; esac
else
  printf '  skip rerun: the link is kept (ln -s plants copies on this machine)\n'
fi

# The swap stopped between its two renames (a failed mv, a Ctrl-C): the
# previous version goes back where it was, nothing else left.
make_release 1.1.5
fresh_link
mkdir -p "$SB/wmvfail"
printf '#!/bin/sh\ncase "$1" in *.new.*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v mv)" > "$SB/wmvfail/mv"
chmod +x "$SB/wmvfail/mv"
out="$(PATH="$SB/wmvfail:$PATH" winst)"; rc=$?
check "swap cut short: the previous version is back" "$rc:$(cat "$WDIR/MARK" 2>/dev/null)" "1:1.1.0"
check "swap cut short: no staging or old copy left" "$(ls -A "$WH/.local/share")" "agent-vm"

make_release 1.2.0 corrupt
fresh_link
out="$(winst)"; rc=$?
check "bad checksum: refused, the install is untouched" "$rc:$(cat "$WDIR/MARK")" "1:1.1.0"
case "$out" in *"checksum mismatch"*) pass "bad checksum: said" ;; *) fail "bad checksum: $out" ;; esac

: > "$WF/log"
fresh_link
out="$(winst --version v1.0.0)"; rc=$?
check "--version: that release" "$rc:$(cat "$WDIR/MARK")" "0:1.0.0"
check "--version: its sums, from its tag" "$(head -n 1 "$WF/log")" \
  "https://github.com/sylvinus/agent-vm/releases/download/v1.0.0/SHA256SUMS"
check "--version: not a version (exit 1)" "$(winst --version 1.0 >/dev/null; echo $?)" "1"
check "--version with --git (exit 1)" "$(winst --version 1.0.0 --git >/dev/null; echo $?)" "1"
check "unknown option (exit 2)" "$(winst --nope >/dev/null; echo $?)" "2"

make_release 1.3.0
mkdir -p "$SB/wother"; echo mine > "$SB/wother/notes"
out="$(winst --dir "$SB/wother")"; rc=$?
check "a directory of the user's: refused, left as it was" "$rc:$(ls "$SB/wother")" "1:notes"

rm -rf "$WDIR" "$WH/bin"
: > "$WF/log"
out="$(winst --git)"; rc=$?
check "--git: clones" "$rc:$(head -n 1 "$WF/log")" "0:git clone https://github.com/sylvinus/agent-vm.git $WDIR"
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
check "--git: linked onto the PATH" "$(readlink "$WH/bin/agent-vm")" "$WDIR/agent-vm.sh"
else
  printf '  skip --git: readlink (ln -s plants copies on this machine)\n'
fi
fresh_link
out="$(winst --git)"; rc=$?
check "--git again: pulls" "$rc:$(tail -n 1 "$WF/log")" "0:git -C $WDIR pull --ff-only"
out="$(winst)"; rc=$?
check "release over a clone: refused" "$rc" "1"
case "$out" in *"is a git clone"*"git -C"*) pass "release over a clone: says how to update it" ;; *) fail "release over a clone: $out" ;; esac

# A download cut short must run nothing: only the last line calls main.
rm -rf "$WDIR"
sed '$d' "$INSTALLER" > "$SB/install-cut.sh"
out="$(WINSTALLER="$SB/install-cut.sh" winst)"; rc=$?
check "cut short: runs nothing" "$rc:$([ -e "$WDIR" ] && echo there)" "0:"

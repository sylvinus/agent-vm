#!/usr/bin/env bash
#
# Checks of www/public/install.sh, the curl installer, and of agent-vm.sh,
# which it runs. Stub curl and git serve releases laid out as release.sh
# makes them (a tarball per platform: agent-vm and agent-vm.sh), one laid out
# as 0.2's, and a clone whose make builds a stub binary: nothing is
# downloaded or built. Then what 0.2 left behind: its link to agent-vm.sh,
# and a shell rc sourcing it. Run by TestInstaller (setup_script_test.go), or
# alone:
#
#   tests/installer.sh

set -uo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")/.." >/dev/null && pwd)"
INSTALLER="$SELF_DIR/www/public/install.sh"

FAIL=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1"; printf '         expected: %s\n         actual:   %s\n' "$3" "$2"; fi
}

# The installer's name for this machine, and another platform's.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM=darwin-arm64 ;;
  Darwin-x86_64) PLATFORM=darwin-amd64 ;;
  Linux-aarch64 | Linux-arm64) PLATFORM=linux-arm64 ;;
  Linux-x86_64) PLATFORM=linux-amd64 ;;
  *) echo "  skip: no release build for $(uname -s) $(uname -m)"; exit 0 ;;
esac
case "$PLATFORM" in *-arm64) OTHER="${PLATFORM%-*}-amd64" ;; *) OTHER="${PLATFORM%-*}-arm64" ;; esac

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

SB="$(mktemp -d)"
SB="$(CDPATH= cd -P -- "$SB" >/dev/null && pwd)"
trap 'rm -rf "$SB"' EXIT

WF="$SB/wfix"; WBIN="$SB/wbin"; WH="$SB/whome"
mkdir -p "$WBIN" "$WH" "$WF"
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
case "$1" in
  clone) echo "git $*" >> "$WF/log"; mkdir -p "$3/.git" && cp -R "$WF/src/." "$3/" ;;
  -C)
    [ -d "$2/.git" ] || exit 128
    case "$3" in
      rev-parse) cat "$WF/head" ;;
      *) echo "git $*" >> "$WF/log" ;;
    esac ;;
esac
STUB
chmod +x "$WBIN/curl" "$WBIN/git"

# The agent-vm binary, as far as these tests see it: it logs its calls, and
# `install` links it onto the PATH and says what to run next.
stub_binary() {  # <file> <mark>
  cat > "$1" <<EOF
#!/bin/sh
echo "$2 \$*" >> "\$WF/ran"
[ "\$1" = install ] || exit 0
mkdir -p "\$AGENT_VM_BIN_DIR"
ln -sfn "\$0" "\$AGENT_VM_BIN_DIR/agent-vm"
echo "agent-vm $2 installed. Next:  cd your-project && agent-vm claude"
EOF
  chmod +x "$1"
}

# A release as release.sh makes it: a tarball for this platform and one for
# another, their sums in SHA256SUMS. corrupt: this platform's sum is wrong.
make_release() {  # <version> [corrupt]
  local d="$WF/v$1" p
  mkdir -p "$d"
  : > "$d/SHA256SUMS"
  for p in "$OTHER" "$PLATFORM"; do
    local s="$WF/stage-$1-$p/agent-vm-$1"
    mkdir -p "$s"
    cp "$SELF_DIR/agent-vm.sh" "$s/"
    stub_binary "$s/agent-vm" "$1-$p"
    tar -czf "$d/agent-vm-$1-$p.tar.gz" -C "$WF/stage-$1-$p" "agent-vm-$1"
    local sum; sum="$(sha256 "$d/agent-vm-$1-$p.tar.gz")"
    [ -z "${2:-}" ] || [ "$p" != "$PLATFORM" ] || sum="0000$sum"
    printf '%s  agent-vm-%s-%s.tar.gz\n' "$sum" "$1" "$p" >> "$d/SHA256SUMS"
  done
  echo "v$1" > "$WF/latest"
}

# A release as 0.2's: one tarball, agent-vm.sh the command itself.
make_old_release() {  # <version>
  local d="$WF/v$1" s="$WF/stage-$1/agent-vm-$1"
  mkdir -p "$d" "$s"
  printf '#!/usr/bin/env bash\necho "0.2 $*" >> "$WF/ran"\n' > "$s/agent-vm.sh"
  tar -czf "$d/agent-vm-$1.tar.gz" -C "$WF/stage-$1" "agent-vm-$1"
  printf '%s  agent-vm-%s.tar.gz\n' "$(sha256 "$d/agent-vm-$1.tar.gz")" "$1" > "$d/SHA256SUMS"
  echo "v$1" > "$WF/latest"
}

# The clone: agent-vm.sh, and a make that builds a stub binary, counted.
mkdir -p "$WF/src"
cp "$SELF_DIR/agent-vm.sh" "$WF/src/"
cat > "$WF/src/Makefile" <<'EOF'
agent-vm:
	echo built >> "$$WF/builds"
	mkdir -p _output/bin
	cp stub _output/bin/agent-vm
EOF
stub_binary "$WF/src/stub" clone
echo head1 > "$WF/head"

winst() {
  ( export HOME="$WH" WF XDG_DATA_HOME= AGENT_VM_BIN_DIR="$WH/bin" PATH="$WBIN:$PATH"
    sh "${WINSTALLER:-$INSTALLER}" "$@" ) 2>&1
}
WDIR="$WH/.local/share/agent-vm"

echo "www/public/install.sh (curl | sh)"

# 0.2, installed by this installer: its link leads to agent-vm.sh.
make_old_release 0.2.1
out="$(winst)"; rc=$?
check "0.2 release: installs, and runs its agent-vm.sh" "$rc:$(cat "$WF/ran")" "0:0.2 install"
mkdir -p "$WH/bin" && ln -sfn "$WDIR/agent-vm.sh" "$WH/bin/agent-vm"

make_release 1.0.0
: > "$WF/log"; : > "$WF/ran"
out="$(winst)"; rc=$?
check "release over 0.2: installs" "$rc" "0"
case "$out" in *"agent-vm claude"*) pass "release: the binary's install ran" ;; *) fail "release: $out" ;; esac
check "release: this machine's tarball, through agent-vm.sh" "$(cat "$WF/ran")" "1.0.0-$PLATFORM install"
check "release: the binary linked onto the PATH, over 0.2's link" "$(readlink "$WH/bin/agent-vm")" "$WDIR/agent-vm"
check "release: sums from latest/, only this machine's tarball, from its tag" "$(tr '\n' ' ' < "$WF/log")" \
  "https://github.com/sylvinus/agent-vm/releases/latest/download/SHA256SUMS https://github.com/sylvinus/agent-vm/releases/download/v1.0.0/agent-vm-1.0.0-$PLATFORM.tar.gz "

# What 0.2 left that install did not replace: a link to agent-vm.sh, and a
# shell rc sourcing it. Both still run agent-vm.
ln -sfn "$WDIR/agent-vm.sh" "$SB/old-link"
: > "$WF/ran"
( export WF; "$SB/old-link" version )
check "0.2's link to agent-vm.sh runs the binary" "$(cat "$WF/ran")" "1.0.0-$PLATFORM version"
: > "$WF/ran"
out="$(export WF; bash -c 'set +e; source "$1"; agent-vm list; echo "shell still here: $?"' _ "$WDIR/agent-vm.sh" 2>&1)"
check "bash rc sourcing agent-vm.sh: an agent-vm function, the shell kept" "$out:$(cat "$WF/ran")" "shell still here: 0:1.0.0-$PLATFORM list"
if command -v zsh >/dev/null 2>&1; then
  : > "$WF/ran"
  out="$(export WF; zsh -fc 'source "$1"; agent-vm list; echo "shell still here: $?"' _ "$WDIR/agent-vm.sh" 2>&1)"
  check "zsh rc sourcing agent-vm.sh: the same" "$out:$(cat "$WF/ran")" "shell still here: 0:1.0.0-$PLATFORM list"
else
  printf '  skip zsh rc (no zsh)\n'
fi

make_release 1.1.0
: > "$WF/ran"
out="$(winst)"; rc=$?
check "rerun: replaced by the new release" "$rc:$(cat "$WF/ran")" "0:1.1.0-$PLATFORM install"
check "rerun: no staging or old copy left" "$(ls -A "$WH/.local/share")" "agent-vm"
check "rerun: the link still leads to the binary" "$(readlink "$WH/bin/agent-vm")" "$WDIR/agent-vm"

# The swap stopped between its two renames (a failed mv, a Ctrl-C): the
# previous version goes back where it was, nothing else left.
make_release 1.1.5
mkdir -p "$SB/wmvfail"
printf '#!/bin/sh\ncase "$1" in *.new.*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v mv)" > "$SB/wmvfail/mv"
chmod +x "$SB/wmvfail/mv"
out="$(PATH="$SB/wmvfail:$PATH" winst)"; rc=$?
: > "$WF/ran"; ( export WF; "$WDIR/agent-vm.sh" version )
check "swap cut short: the previous version is back" "$rc:$(cat "$WF/ran")" "1:1.1.0-$PLATFORM version"
check "swap cut short: no staging or old copy left" "$(ls -A "$WH/.local/share")" "agent-vm"

make_release 1.2.0 corrupt
out="$(winst)"; rc=$?
: > "$WF/ran"; ( export WF; "$WDIR/agent-vm.sh" version )
check "bad checksum: refused, the install is untouched" "$rc:$(cat "$WF/ran")" "1:1.1.0-$PLATFORM version"
case "$out" in *"checksum mismatch"*) pass "bad checksum: said" ;; *) fail "bad checksum: $out" ;; esac

# Windows, in Git Bash: its tarball, agent-vm.exe run by agent-vm.sh.
mkdir -p "$SB/winbin" "$WF/v1.1.8" "$WF/stage-win/agent-vm-1.1.8"
printf '#!/bin/sh\ncase "$1" in -s) echo MINGW64_NT-10.0 ;; -m) echo x86_64 ;; esac\n' > "$SB/winbin/uname"
chmod +x "$SB/winbin/uname"
cp "$SELF_DIR/agent-vm.sh" "$WF/stage-win/agent-vm-1.1.8/"
stub_binary "$WF/stage-win/agent-vm-1.1.8/agent-vm.exe" 1.1.8-windows-amd64
tar -czf "$WF/v1.1.8/agent-vm-1.1.8-windows-amd64.tar.gz" -C "$WF/stage-win" agent-vm-1.1.8
printf '%s  agent-vm-1.1.8-windows-amd64.tar.gz\n' "$(sha256 "$WF/v1.1.8/agent-vm-1.1.8-windows-amd64.tar.gz")" > "$WF/v1.1.8/SHA256SUMS"
: > "$WF/ran"
out="$(PATH="$SB/winbin:$PATH" winst --version 1.1.8 --dir "$SB/win")"; rc=$?
check "Windows (Git Bash): its tarball, agent-vm.exe run" "$rc:$(cat "$WF/ran")" "0:1.1.8-windows-amd64 install"

# A release with no build for this machine: said, nothing changed.
mkdir -p "$WF/v1.2.5"
printf '0000  agent-vm-1.2.5-%s.tar.gz\n' "$OTHER" > "$WF/v1.2.5/SHA256SUMS"
echo v1.2.5 > "$WF/latest"
out="$(winst)"; rc=$?
case "$rc:$out" in 1:*"no build for $PLATFORM"*) pass "no build for this machine: said" ;; *) fail "no build: $out" ;; esac

: > "$WF/log"
out="$(winst --version v1.0.0)"; rc=$?
: > "$WF/ran"; ( export WF; "$WDIR/agent-vm.sh" version )
check "--version: that release" "$rc:$(cat "$WF/ran")" "0:1.0.0-$PLATFORM version"
check "--version: its sums, from its tag" "$(head -n 1 "$WF/log")" \
  "https://github.com/sylvinus/agent-vm/releases/download/v1.0.0/SHA256SUMS"
check "--version: not a version (exit 1)" "$(winst --version 1.0 >/dev/null; echo $?)" "1"
check "--version with --git (exit 1)" "$(winst --version 1.0.0 --git >/dev/null; echo $?)" "1"
check "unknown option (exit 2)" "$(winst --nope >/dev/null; echo $?)" "2"

make_release 1.3.0
mkdir -p "$SB/wother"; echo mine > "$SB/wother/notes"
out="$(winst --dir "$SB/wother")"; rc=$?
check "a directory of the user's: refused, left as it was" "$rc:$(ls "$SB/wother")" "1:notes"

# A clone: agent-vm.sh builds it, then runs its install.
rm -rf "$WDIR" "$WH/bin"
: > "$WF/log"; : > "$WF/builds"
out="$(winst --git)"; rc=$?
check "--git: clones" "$rc:$(head -n 1 "$WF/log")" "0:git clone https://github.com/sylvinus/agent-vm.git $WDIR"
check "--git: built once" "$(wc -l < "$WF/builds" | tr -d ' ')" "1"
check "--git: the built binary linked onto the PATH" "$(readlink "$WH/bin/agent-vm")" "$WDIR/_output/bin/agent-vm"
out="$(winst --git)"; rc=$?
check "--git again: pulls" "$rc:$(tail -n 1 "$WF/log")" "0:git -C $WDIR pull --ff-only"
check "--git again, nothing pulled: not rebuilt" "$(wc -l < "$WF/builds" | tr -d ' ')" "1"
# 0.2's link into a clone, after a git pull to 0.3: rebuilt, then run.
echo head2 > "$WF/head"
ln -sfn "$WDIR/agent-vm.sh" "$SB/clone-link"
: > "$WF/ran"
( export WF PATH="$WBIN:$PATH"; "$SB/clone-link" version ) 2>/dev/null
check "a 0.2 link into a clone, after a pull: rebuilt, then run" "$(wc -l < "$WF/builds" | tr -d ' '):$(cat "$WF/ran")" "2:clone version"
out="$(winst)"; rc=$?
check "release over a clone: refused" "$rc" "1"
case "$out" in *"is a git clone"*"git -C"*) pass "release over a clone: says how to update it" ;; *) fail "release over a clone: $out" ;; esac

# A download cut short must run nothing: only the last line calls main.
rm -rf "$WDIR"
sed '$d' "$INSTALLER" > "$SB/install-cut.sh"
out="$(WINSTALLER="$SB/install-cut.sh" winst)"; rc=$?
check "cut short: runs nothing" "$rc:$([ -e "$WDIR" ] && echo there)" "0:"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

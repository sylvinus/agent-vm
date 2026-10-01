# =============================================================================
section "windows host support (Git Bash)"
# =============================================================================
# A fake uname reporting MINGW64, used through PATH in subshells only, so
# nothing leaks into the rest of the suite. Plain sh: the restricted-PATH
# cases below could not even resolve a bash shebang.
mkdir -p "$SB/fakewin" "$SB/fakeqemu" "$SB/emptybin"
cat > "$SB/fakewin/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) echo "MINGW64_NT-10.0-26100" ;;
  *) echo "x86_64" ;;
esac
STUB
chmod +x "$SB/fakewin/uname"
# And one reporting Linux, for the "not on Windows" cases on a Windows runner.
mkdir -p "$SB/fakelinux"
printf '#!/bin/sh\necho Linux\n' > "$SB/fakelinux/uname"
chmod +x "$SB/fakelinux/uname"
printf '#!/bin/sh\nexit 0\n' > "$SB/fakeqemu/qemu-system-x86_64"
chmod +x "$SB/fakeqemu/qemu-system-x86_64"

# 11-recorded-commands.sh stubs the host prereq checks (05 re-sources the
# engine, wiping helpers' stubs); restore the real ones: they are what is
# under test here. Same restore as in 19-wsl.sh.
. "$SELF_DIR/lib/host.sh"
if ( PATH="$SB/fakewin:$PATH"; _agent_vm_on_windows ); then
  pass "MINGW64 uname is detected as Windows"
else
  fail "MINGW64 uname is not detected as Windows"
fi
# Without the fake, detection must agree with the real kernel: true on an
# actual Windows runner, false everywhere else.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) expect_win=1 ;;
  *) expect_win="" ;;
esac
if _agent_vm_on_windows; then got_win=1; else got_win=""; fi
check "native detection agrees with uname" "$got_win" "$expect_win"

if ( PATH="$SB/fakewin:$SB/fakeqemu:$PATH"; _agent_vm_check_windows_prereqs ); then
  pass "QEMU present -> Windows prereqs pass"
else
  fail "QEMU present but Windows prereqs fail"
fi
win_out="$(AGENT_VM_QEMU_DIR="$SB/no-qemu" PATH="$SB/fakewin:$SB/emptybin" _agent_vm_check_windows_prereqs 2>&1)"
check "QEMU absent -> Windows prereqs fail (exit 1)" "$?" "1"
case "$win_out" in
  *winget*"Windows Hypervisor Platform"*) pass "the failure names the winget install and the hypervisor feature" ;;
  *) fail "the failure does not say how to install QEMU: $win_out" ;;
esac
# winget's QEMU does not put itself on PATH: found in its directory, it goes
# on PATH for this shell, with the line to keep it.
mkdir -p "$SB/qemu-dir"
printf '#!/bin/sh\nexit 0\n' > "$SB/qemu-dir/qemu-system-x86_64.exe"
chmod +x "$SB/qemu-dir/qemu-system-x86_64.exe"
win_out="$( AGENT_VM_QEMU_DIR="$SB/qemu-dir"; PATH="$SB/fakewin:$SB/emptybin"
            _agent_vm_check_windows_prereqs && printf 'PATH=%s' "$PATH" )"
case "$win_out" in
  *"export PATH=\"$SB/qemu-dir:\$PATH\""*"PATH=$SB/qemu-dir:"*) pass "QEMU in its install directory: put on PATH, and the line to keep it printed" ;;
  *) fail "QEMU in its install directory: $win_out" ;;
esac

# A start that failed on WHPX says what it needs, and who can turn it on.
printf 'qemu-system-x86_64.exe: WHPX: No accelerator found, hr=00000000\n' > "$SB/whpx.log"
printf 'something else\n' > "$SB/other.log"
case "$(PATH="$SB/fakewin:$PATH" _agent_vm_windows_start_hint "$SB/other.log" "$SB/whpx.log" 2>&1)" in
  *"Windows Hypervisor"*"FeatureName:HypervisorPlatform"*"IT department"*) pass "WHPX failure: the hint names the feature and the administrator" ;;
  *) fail "WHPX failure: no hint" ;;
esac
check "another failure: no hint" "$(PATH="$SB/fakewin:$PATH" _agent_vm_windows_start_hint "$SB/other.log" 2>&1)" ""
check "not on Windows: no hint" "$(PATH="$SB/fakelinux:$PATH" _agent_vm_windows_start_hint "$SB/whpx.log" 2>&1)" ""

# =============================================================================
section "Windows: paths, as Lima reads them and as the guest sees them"
# =============================================================================
# Git Bash spells C:\Users as /c/Users. Lima on Windows requires an absolute
# Windows path as a mount location, and Git Bash rewrites /c/... arguments to
# C:/... when it starts limactl.exe, guest paths included. A fake cygpath
# stands for Git Bash's.
cat > "$SB/fakewin/cygpath" <<'STUB'
#!/bin/sh
[ "$1" = -m ] && shift
[ "$1" = -- ] && shift
case "$1" in
  /[a-z]/*) d="$(printf '%s' "$1" | cut -c2 | tr a-z A-Z)"; printf '%s:%s\n' "$d" "$(printf '%s' "$1" | cut -c3-)" ;;
  *) printf 'C:/msys64%s\n' "$1" ;;
esac
STUB
chmod +x "$SB/fakewin/cygpath"
check "a host path in Lima's spelling" "$(PATH="$SB/fakewin:$PATH" _agent_vm_host_path /c/Users/me/proj)" "C:/Users/me/proj"
check "elsewhere, unchanged" "$(PATH="$SB/fakelinux:$PATH" _agent_vm_host_path /c/Users/me/proj)" "/c/Users/me/proj"
win_json="$( PATH="$SB/fakewin:$PATH"; AGENT_VM_STATE_DIR="$SB/winstate"
             _agent_vm_build_mounts_json agent-vm-w /c/Users/me/proj true )"
check "the project share: a Windows location, mounted at the shell's path" \
  "$win_json" '[{"location": "C:/Users/me/proj", "mountPoint": "/c/Users/me/proj", "writable": true}]'

# limactl gets every argument as written: Git Bash's rewriting is off for it.
mkdir -p "$SB/convlima"
printf '#!/bin/sh\necho "${MSYS_NO_PATHCONV:-}|${MSYS2_ARG_CONV_EXCL:-}|$*"\n' > "$SB/convlima/limactl"
chmod +x "$SB/convlima/limactl"
conv="$( PATH="$SB/fakewin:$SB/convlima:$PATH"; . "$SELF_DIR/lib/host.sh"
         limactl shell --workdir /c/proj vm true
         printf '%s\n' "$(_agent_vm_limactl_path)" )"
check "on Windows, limactl runs without path rewriting" "$conv" "1|*|shell --workdir /c/proj vm true
$SB/convlima/limactl"
check "and a missing limactl is still missing" \
  "$( PATH="$SB/fakewin:$SB/emptybin"; . "$SELF_DIR/lib/host.sh"; _agent_vm_limactl_path; echo "rc=$?" )" "rc=1"
# unset -f: on a Windows runner the suite's own sourcing defined the wrapper.
check "elsewhere, limactl is not wrapped" \
  "$( PATH="$SB/fakelinux:$SB/convlima:$PATH"; unset -f limactl; . "$SELF_DIR/lib/host.sh"
      limactl x )" "||x"

# The .git probe hands limactl a file and a location Lima can read.
mkdir -p "$SB/validlima"
cat > "$SB/validlima/limactl" <<STUB
#!/bin/sh
echo "\$*" > "$SB/validate.args"
STUB
chmod +x "$SB/validlima/limactl"
( PATH="$SB/fakewin:$SB/validlima:$PATH"; export TMPDIR="$SB/probe-tmp"; _agent_vm_lima_protects_git ) >/dev/null 2>&1
case "$(cat "$SB/validate.args" 2>/dev/null)" in
  "validate $(PATH="$SB/fakewin:$PATH" _agent_vm_host_path "$SB/probe-tmp")/"*"/probe.yaml") pass "the .git probe passes limactl a Windows path" ;;
  *) fail "the .git probe: $(cat "$SB/validate.args" 2>/dev/null)" ;;
esac

# =============================================================================
section "Windows: setup without Lima offers the download"
# =============================================================================
nolima_win() {
  ( PATH="$SB/fakewin:$(nolima_path)"
    _agent_vm_have_tty() { [ -n "${TTY:-}" ]; }
    _agent_vm_ask_yn() { echo 1; }
    _agent_vm_install_fork_windows() { echo "FORK DOWNLOAD"; return 1; }
    _agent_vm_setup --preinstall=none ) 2>&1
}
case "$(TTY=1 nolima_win)" in
  *"FORK DOWNLOAD"*) pass "with a terminal: the Lima build for Windows is offered" ;;
  *) fail "with a terminal: no download offered" ;;
esac
case "$(nolima_win)" in
  *"FORK DOWNLOAD"*) fail "no terminal: downloaded without asking" ;;
  *"Run 'agent-vm setup' in a terminal"*) pass "no terminal: says where the offer is" ;;
  *) fail "no terminal: $(nolima_win)" ;;
esac

# =============================================================================
section "Windows: the Lima build is replaced when its tag changes"
# =============================================================================
# A stub curl serves the release from $FORKSRV/<tag>/, a stub unzip unpacks a
# "zip" that names its limactl.exe, so which build is installed can be read.
FORKSRV="$SB/forksrv"; mkdir -p "$SB/forkbin"
make_fork_release() {  # <tag>
  local d="$FORKSRV/$1" t="${1#v}" f
  mkdir -p "$d"
  for f in "lima-$t-Windows-AMD64.zip" "lima-additional-guestagents-$t-Windows-AMD64.zip"; do
    echo "$1" > "$d/$f"
  done
  ( cd "$d" && if command -v sha256sum >/dev/null 2>&1; then sha256sum lima-*.zip; else shasum -a 256 lima-*.zip; fi > SHA256SUMS )
}
cat > "$SB/forkbin/curl" <<STUB
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; https://*) url="\$1" ;; esac; shift; done
echo "\$url" >> "$SB/fork.log"
t="\${url%/*}"; cp "$FORKSRV/\${t##*/}/\${url##*/}" "\$out"
STUB
cat > "$SB/forkbin/unzip" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -d) d="$2"; shift ;; -q|-o) ;; *) z="$1" ;; esac; shift; done
case "$z" in */lima-additional*) exit 0 ;; esac
mkdir -p "$d/bin" && cp "$z" "$d/bin/limactl.exe" && chmod +x "$d/bin/limactl.exe"
STUB
chmod +x "$SB/forkbin/curl" "$SB/forkbin/unzip"
# Under set -u, as a script sourcing agent-vm may run.
# The checksums are pinned in the engine: those of the stub release stand for
# them, unless PINNED gives others.
fork() {  # <tag> [function]
  ( set -u; PATH="$SB/fakewin:$SB/forkbin:$PATH"; AGENT_VM_LIMA_DIR="$SB/lima-fork"; AGENT_VM_LIMA_FORK_TAG="$1"
    AGENT_VM_LIMA_FORK_SHA256="${PINNED:-$(cat "$FORKSRV/$1/SHA256SUMS")}"
    _agent_vm_have_tty() { return 0; }; _agent_vm_ask_yn() { echo 1; }
    "${2:-_agent_vm_install_fork_windows}" ) 2>&1
}
make_fork_release v9.0.0-sylvinus.1
make_fork_release v9.0.0-sylvinus.2
# A zip that does not match the pinned checksum is refused, even when the
# release's own SHA256SUMS agrees with it: whoever replaces one can replace both.
: > "$SB/fork.log"
out="$(PINNED="$(sed 's/^[0-9a-f]\{8\}/deadbeef/' "$FORKSRV/v9.0.0-sylvinus.1/SHA256SUMS")" fork v9.0.0-sylvinus.1)"
case "$?:$out" in
  1:*"checksum mismatch"*) pass "install: a zip that differs from the pinned checksum is refused" ;;
  *) fail "install: pinned checksum not enforced: $out" ;;
esac
check "and nothing is installed" "$([ -e "$SB/lima-fork" ] && echo yes || echo no)" "no"
check "the release's SHA256SUMS is not downloaded" "$(grep -c 'SHA256SUMS' "$SB/fork.log")" "0"
: > "$SB/fork.log"
out="$(fork v9.0.0-sylvinus.1)"
check "install: the build of the tag, and a clean exit" \
  "$? $(cat "$SB/lima-fork/bin/limactl.exe" 2>/dev/null)" "0 v9.0.0-sylvinus.1"
: > "$SB/fork.log"
case "$(fork v9.0.0-sylvinus.1)" in *"already installed"*) pass "same tag: reused" ;; *) fail "same tag: not reused" ;; esac
check "same tag: nothing downloaded" "$(cat "$SB/fork.log")" ""
fork v9.0.0-sylvinus.2 _agent_vm_offer_fork_windows_update >/dev/null
check "another tag: setup's update replaces it" "$(cat "$SB/lima-fork/bin/limactl.exe" 2>/dev/null)" "v9.0.0-sylvinus.2"
check "and leaves no staging or old copy" "$(ls -A "$SB" | grep -c '^lima-fork\.')" "0"
: > "$SB/fork.log"
check "up to date: no update offered" "$(fork v9.0.0-sylvinus.2 _agent_vm_offer_fork_windows_update)$(cat "$SB/fork.log")" ""
mkdir -p "$SB/not-lima"; echo mine > "$SB/not-lima/notes"
out="$( ( PATH="$SB/fakewin:$SB/forkbin:$PATH"; AGENT_VM_LIMA_DIR="$SB/not-lima"; _agent_vm_install_fork_windows ) 2>&1 )"
case "$?:$out" in
  1:*"is not a Lima install"*) pass "a directory of the user's: refused" ;;
  *) fail "a directory of the user's: $out" ;;
esac
check "and left as it was" "$(ls "$SB/not-lima")" "notes"

# =============================================================================
section "Windows: install makes a launcher where there are no symlinks"
# =============================================================================
# Git Bash's ln -s copies the file unless Windows grants symlinks, and a copy
# of agent-vm.sh cannot find lib/. `ln` stands for that here.
WIB="$SB/winbin"
winst_ln() {
  ( export HOME="$SB/winhome" AGENT_VM_BIN_DIR="$WIB" PATH="$WIB:$PATH"
    ln() { [ "$1" = -s ] && shift; cp "$1" "$2"; }
    _agent_vm_have_tty() { return 1; }
    _agent_vm_base_exists() { return 0; }
    agent-vm "$@" ) 2>&1
}
mkdir -p "$SB/winhome"
out="$(winst_ln install)"
case "$out" in *"a launcher for"*) pass "install: says it wrote a launcher" ;; *) fail "install: $out" ;; esac
check "the launcher runs this agent-vm" "$(bash "$WIB/agent-vm" version 2>&1)" "$AGENT_VM_VERSION"
case "$(winst_ln install)" in *"already linked"*) pass "install again: the launcher is recognised" ;; *) fail "install again: $(winst_ln install)" ;; esac
winst_ln uninstall >/dev/null
[ ! -e "$WIB/agent-vm" ] && pass "uninstall removes the launcher" || fail "uninstall left the launcher"
echo "mine" > "$WIB/agent-vm"
winst_ln uninstall >/dev/null
check "uninstall leaves a file of the user's" "$(cat "$WIB/agent-vm")" "mine"
rm -f "$WIB/agent-vm"

# =============================================================================
section "Windows: doctor and CRLF files"
# =============================================================================
mkdir -p "$SB/winstate2"
printf "K='v'\n" > "$SB/winstate2/env"; chmod 644 "$SB/winstate2/env"
out="$( cd "$PROJ" && PATH="$SB/fakewin:$SB/fakeqemu:$PATH" AGENT_VM_STATE_DIR="$SB/winstate2" _agent_vm_doctor 2>&1 )"
case "$out" in
  *"readable by other users"*) fail "doctor on Windows: warns about emulated permission bits" ;;
  *"-     env: 1 key(s)"*) pass "doctor on Windows: the env file without a permission verdict" ;;
  *) fail "doctor on Windows, env: $out" ;;
esac
case "$out" in
  *"'Windows Hypervisor Platform' feature"*"FeatureName:HypervisorPlatform"*) pass "doctor on Windows: names the hypervisor feature" ;;
  *) fail "doctor on Windows, hypervisor: $out" ;;
esac

# Git for Windows checks files out with CRLF by default: the CRs must not
# reach the shells in the VM.
printf '#!/bin/bash -e\r\necho hi\r\n' > "$SB/crlf-runtime.sh"
check "a CRLF shebang with an option: bash" "$(_agent_vm_runtime_interpreter "$SB/crlf-runtime.sh")" "bash"
mkdir -p "$SB/catlima"
printf '#!/bin/sh\ncat > "%s"\n' "$SB/crlf-captured" > "$SB/catlima/limactl"
chmod +x "$SB/catlima/limactl"
( PATH="$SB/catlima:$PATH"; _agent_vm_run_runtime vm "$PROJ" "$SB/crlf-runtime.sh" )
check "a CRLF runtime reaches the VM without CRs" \
  "$(grep -c 'echo hi' "$SB/crlf-captured") $(od -c < "$SB/crlf-captured" | grep -c '\\r')" "1 0"
( AGENT_VM_STATE_DIR="$SB/crlf-state"; mkdir -p "$AGENT_VM_STATE_DIR"
  printf 'A=1\r\n' > "$AGENT_VM_STATE_DIR/env"
  printf 'B=2\r\n' > "$SB/crlf-proj.env"
  AGENT_VM_PROJECT_ENV="$SB/crlf-proj.env" _agent_vm_env_payload "$PROJ" ) > "$SB/crlf-payload"
check "CRLF env files reach the VM without CRs" \
  "$(grep -c '^[AB]=' "$SB/crlf-payload") $(od -c < "$SB/crlf-payload" | grep -c '\\r')" "2 0"

# QEMU on Windows has no 9p: a mount type left unset is reverse-sshfs there,
# which only the builtin SFTP server with readonlyNames enforces. On any other
# host the same VM gets 9p. A limactl of its own, reporting QEMU and no type.
mkdir -p "$SB/qemulima" "$SB/qemulima-home/agent-vm-w"
printf '#!/bin/sh\n[ "$1" = list ] && echo "qemu <nil>"\nexit 0\n' > "$SB/qemulima/limactl"
chmod +x "$SB/qemulima/limactl"
echo 2.1.0 > "$SB/qemulima-home/agent-vm-w/lima-version"
enforced_on() {  # <fake uname dir>
  ( PATH="$1:$SB/qemulima:$PATH"; LIMA_HOME="$SB/qemulima-home"; _agent_vm_mount_is_host_enforced agent-vm-w; printf '%s' "$?" )
}
check "unset on QEMU, Windows host: reverse-sshfs, not enforced" "$(enforced_on "$SB/fakewin")" "1"
check "unset on QEMU, Linux host: 9p, enforced" "$(enforced_on "$SB/fakelinux")" "0"

# =============================================================================
section "the fork release: asset names and checksums"
# =============================================================================
# The download offer has no Windows machine to try it on here, so the parts
# that do not touch the network are pinned: which files, for which arch, and
# the checksum gate that refuses a bad download.
mkdir -p "$SB/fakewinarm" "$SB/fakewinodd"
cat > "$SB/fakewinarm/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) echo "MINGW64_NT-10.0-26100" ;;
  -m) echo "aarch64" ;;
  *) echo "aarch64" ;;
esac
STUB
cat > "$SB/fakewinodd/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) echo "MINGW64_NT-10.0-26100" ;;
  *) echo "riscv64" ;;
esac
STUB
chmod +x "$SB/fakewinarm/uname" "$SB/fakewinodd/uname"
check "x86_64 is AMD64" \
  "$(PATH="$SB/fakewin:$PATH" _agent_vm_lima_fork_arch)" "AMD64"
check "aarch64 is ARM64" \
  "$(PATH="$SB/fakewinarm:$PATH" _agent_vm_lima_fork_arch)" "ARM64"
if PATH="$SB/fakewinodd:$PATH" _agent_vm_lima_fork_arch >/dev/null 2>&1; then
  fail "an architecture with no build should be refused"
else
  pass "an architecture with no build is refused"
fi
# Both zips, spelled exactly as the release publishes them: the installer
# downloads these names, so a rename breaks it loudly.
check "the asset names for AMD64" \
  "$(PATH="$SB/fakewin:$PATH" _agent_vm_lima_fork_files | tr '\n' ' ')" \
  "lima-2.3.0-sylvinus.2-Windows-AMD64.zip lima-additional-guestagents-2.3.0-sylvinus.2-Windows-AMD64.zip "
check "the asset names for ARM64" \
  "$(PATH="$SB/fakewinarm:$PATH" _agent_vm_lima_fork_files | tr '\n' ' ')" \
  "lima-2.3.0-sylvinus.2-Windows-ARM64.zip lima-additional-guestagents-2.3.0-sylvinus.2-Windows-ARM64.zip "
# Every file downloaded, for either architecture, has a pinned checksum, of
# the pinned tag.
pinned_ok=yes
for a in "$SB/fakewin" "$SB/fakewinarm"; do
  for f in $(PATH="$a:$PATH" _agent_vm_lima_fork_files); do
    # A here-string, not a pipe: grep -q exits on the match, printf can then
    # die of SIGPIPE, and pipefail fails the line.
    grep -Eq "^[0-9a-f]{64}  $f\$" <<< "$AGENT_VM_LIMA_FORK_SHA256" || pinned_ok="no: $f"
  done
done
check "each zip has a pinned checksum" "$pinned_ok" "yes"
case "$(PATH="$SB/fakewin:$PATH" _agent_vm_lima_fork_release)" in
  *"/releases/download/v2.3.0-sylvinus.2") pass "the release URL carries the fork tag" ;;
  *) fail "the release URL does not carry the fork tag: $(PATH="$SB/fakewin:$PATH" _agent_vm_lima_fork_release)" ;;
esac

mkdir -p "$SB/sums"
printf 'hello\n' > "$SB/sums/a.zip"
printf 'world\n' > "$SB/sums/b.zip"
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$SB/sums" && sha256sum a.zip b.zip > SHA256SUMS )
else
  ( cd "$SB/sums" && shasum -a 256 a.zip b.zip > SHA256SUMS )
fi
sums() { cat "$SB/sums/SHA256SUMS"; }
_agent_vm_sha256_sums_check "$(sums)" "$SB/sums" a.zip b.zip \
  && pass "matching checksums verify" \
  || fail "matching checksums do not verify"
printf 'tampered\n' > "$SB/sums/b.zip"
if _agent_vm_sha256_sums_check "$(sums)" "$SB/sums" a.zip b.zip >/dev/null 2>&1; then
  fail "a tampered download verified"
else
  pass "a tampered download is refused"
fi
# Binary mode marks the name with a *: `sha256sum -b`, and Git Bash's default.
printf 'hello\n' > "$SB/sums/c.zip"
printf '%s *c.zip\n' "$(_agent_vm_sha256 < "$SB/sums/c.zip" | cut -d' ' -f1)" >> "$SB/sums/SHA256SUMS"
_agent_vm_sha256_sums_check "$(sums)" "$SB/sums" c.zip \
  && pass "a binary-mode (*) checksum line verifies" \
  || fail "a binary-mode (*) checksum line does not verify"
if _agent_vm_sha256_sums_check "$(sums)" "$SB/sums" missing.zip >/dev/null 2>&1; then
  fail "an unlisted file verified"
else
  pass "an unlisted file is refused"
fi

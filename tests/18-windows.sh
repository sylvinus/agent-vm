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
win_out="$(PATH="$SB/fakewin:$SB/emptybin" _agent_vm_check_windows_prereqs 2>&1)"
check "QEMU absent -> Windows prereqs fail (exit 1)" "$?" "1"
case "$win_out" in
  *winget*) pass "the failure names the winget install" ;;
  *) fail "the failure does not say how to install QEMU: $win_out" ;;
esac
# The mapping stays SHELL-first: bash on Windows reads .bash_profile (Git
# Bash login shells, like Terminal.app), anything else is unchanged.
check "Git Bash login shells read .bash_profile" \
  "$(SHELL=/bin/bash PATH="$SB/fakewin:$PATH" _agent_vm_rc_file)" "$HOME/.bash_profile"
check "the SHELL contract holds on Windows too" \
  "$(SHELL=/bin/zsh PATH="$SB/fakewin:$PATH" _agent_vm_rc_file)" "$HOME/.zshrc"

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
# Both zips plus the checksums, spelled exactly as the release publishes
# them: the installer downloads these names, so a rename breaks it loudly.
check "the asset names for AMD64" \
  "$(PATH="$SB/fakewin:$PATH" _agent_vm_lima_fork_files | tr '\n' ' ')" \
  "lima-2.3.0-sylvinus.2-Windows-AMD64.zip lima-additional-guestagents-2.3.0-sylvinus.2-Windows-AMD64.zip SHA256SUMS "
check "the asset names for ARM64" \
  "$(PATH="$SB/fakewinarm:$PATH" _agent_vm_lima_fork_files | tr '\n' ' ')" \
  "lima-2.3.0-sylvinus.2-Windows-ARM64.zip lima-additional-guestagents-2.3.0-sylvinus.2-Windows-ARM64.zip SHA256SUMS "
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
_agent_vm_sha256_sums_check "$SB/sums" a.zip b.zip \
  && pass "matching checksums verify" \
  || fail "matching checksums do not verify"
printf 'tampered\n' > "$SB/sums/b.zip"
if _agent_vm_sha256_sums_check "$SB/sums" a.zip b.zip >/dev/null 2>&1; then
  fail "a tampered download verified"
else
  pass "a tampered download is refused"
fi
if _agent_vm_sha256_sums_check "$SB/sums" missing.zip >/dev/null 2>&1; then
  fail "an unlisted file verified"
else
  pass "an unlisted file is refused"
fi

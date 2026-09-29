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

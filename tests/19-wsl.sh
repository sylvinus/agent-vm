# =============================================================================
section "WSL detection (nested virtualization is the user's job)"
# =============================================================================
# Fake uname binaries reporting WSL2 and WSL1 kernel releases. Used through
# PATH in subshells only, like the MINGW64 fake in 18-windows.sh.
mkdir -p "$SB/fakewsl2" "$SB/fakewsl1"
cat > "$SB/fakewsl2/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) echo "Linux" ;;
  -r) echo "6.6.87.1-microsoft-standard-WSL2" ;;
  *) echo "x86_64" ;;
esac
STUB
cat > "$SB/fakewsl1/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) echo "Linux" ;;
  -r) echo "4.4.0-19041-Microsoft" ;;
  *) echo "x86_64" ;;
esac
STUB
chmod +x "$SB/fakewsl2/uname" "$SB/fakewsl1/uname"

check "WSL2 kernel release detected" \
  "$(PATH="$SB/fakewsl2:$PATH" _agent_vm_wsl_version)" "2"
check "WSL1 kernel release detected" \
  "$(PATH="$SB/fakewsl1:$PATH" _agent_vm_wsl_version)" "1"
check "plain Linux is not WSL" "$(_agent_vm_wsl_version)" ""

# helpers.sh stubs _agent_vm_check_linux_prereqs (the machine running the
# tests has no /dev/kvm); restore the real one to exercise the hint below.
. "$SELF_DIR/lib/host.sh"
if [[ ! -e /dev/kvm ]]; then
  wsl_hint="$(PATH="$SB/fakewsl2:$PATH" _agent_vm_check_linux_prereqs 2>&1)"
  check "WSL2 without KVM fails (exit 1)" "$?" "1"
  case "$wsl_hint" in
    *nested*virtualization*) pass "the failure points at nested virtualization" ;;
    *) fail "the failure does not mention nested virtualization: $wsl_hint" ;;
  esac
  wsl_hint="$(PATH="$SB/fakewsl1:$PATH" _agent_vm_check_linux_prereqs 2>&1)"
  case "$wsl_hint" in
    *WSL1*) pass "the failure names WSL1 and the upgrade" ;;
    *) fail "the failure does not name WSL1: $wsl_hint" ;;
  esac
else
  pass "/dev/kvm exists on this machine: missing-KVM hints not exercised"
fi

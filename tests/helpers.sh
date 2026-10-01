AGENT_VM_SH="${AGENT_VM_SH:-$SELF_DIR/agent-vm.sh}"
SETUP_SH="${SETUP_SH:-$SELF_DIR/agent-vm.setup.sh}"

FAIL=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1"; printf '         expected: %s\n         actual:   %s\n' "$3" "$2"; fi
}
section() { printf '\n%s\n' "$1"; }

SB="$(mktemp -d)"
# Physical path: the temp dir itself is reached through a link on some
# machines (macOS /private, msys mounts), and tests compare $SB against paths
# the tools resolve themselves (git top-level, script dirs, readlink). Two
# spellings of one directory never match, so settle on one here.
SB="$(CDPATH= cd -P -- "$SB" >/dev/null && pwd)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB/home"
# git's config from this sandbox only: with XDG_CONFIG_HOME or
# GIT_CONFIG_GLOBAL set, `git config --global` would read and write the real
# one. safe.bareRepository is set, as on a machine agent-vm set up, so a start
# does not stop on it; the tests of that question use a stub git.
unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
printf '[safe]\n\tbareRepository = explicit\n' > "$HOME/.gitconfig"
# The stub Lima has no readonlyNames unless a test says so, and a VM started
# on it asks before going on (see _agent_vm_confirm_unsafe). Answered yes here;
# the tests of those questions unset it.
export AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1
# A real directory: `name` and `info` resolve their argument and reject a
# path that does not exist, so the tests cannot use a made-up one.
PROJ="$SB/proj"
mkdir -p "$HOME" "$SB/bin" "$PROJ"

# --- stubs --------------------------------------------------------------------
# One base VM plus one project VM, running, 4 CPUs / 8 GiB / 32 GiB.
# `shell` dumps stdin so we can assert on what setup pipes into the VM.
# AGENT_VM_TEST_EXTRA_VM adds one more name to the inventory, so a test can
# make the VM of an arbitrary directory exist. AGENT_VM_TEST_CALLS records the
# destructive calls, to assert which VM they hit.
cat > "$SB/bin/limactl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    case "$*" in
      *"{{.Name}}|{{.CPUs}}|{{.Memory}}|{{.Disk}}"*)
        echo "agent-vm-base|4|8589934592|34359738368"
        echo "agent-vm-proj-deadbeef|4|8589934592|34359738368" ;;
      *"{{.Name}} {{.Status}}"*)
        echo "agent-vm-base Stopped"
        echo "agent-vm-proj-deadbeef Running" ;;
      *-q*)
        { echo "agent-vm-base"
          echo "agent-vm-proj-deadbeef"
          [ -n "${AGENT_VM_TEST_EXTRA_VM:-}" ] && echo "$AGENT_VM_TEST_EXTRA_VM"
        } | if [ -s "${AGENT_VM_TEST_DELETED:-}" ]; then grep -vxF -f "$AGENT_VM_TEST_DELETED"; else cat; fi ;;
    esac ;;
  shell)
    cat > "${AGENT_VM_TEST_CAPTURE:-/dev/null}"
    if [ -n "${AGENT_VM_TEST_SHELL_FAIL:-}" ]; then echo "E: boom" >&2; exit 1; fi ;;
  start)
    echo 'time="2026-01-01T00:00:00Z" level=info msg="Attempting to download the image" arch=aarch64' >&2
    if [ -n "${AGENT_VM_TEST_START_FAIL:-}" ]; then echo 'level=fatal msg="no start"' >&2; exit 1; fi ;;
  stop) echo "$*" >> "${AGENT_VM_TEST_CALLS:-/dev/null}" ;;
  # With AGENT_VM_TEST_DELETED (a file), a deleted VM leaves the listing.
  delete)
    echo "$*" >> "${AGENT_VM_TEST_CALLS:-/dev/null}"
    [ -z "${AGENT_VM_TEST_DELETED:-}" ] || echo "$2" >> "$AGENT_VM_TEST_DELETED" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$SB/bin/limactl"

# Minimal images (and some Linux hosts) have no shasum; _agent_vm_name needs one.
if ! command -v shasum >/dev/null 2>&1; then
  cat > "$SB/bin/shasum" <<'STUB'
#!/usr/bin/env bash
if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
else echo "0000000000000000"; fi
STUB
  chmod +x "$SB/bin/shasum"
fi
export PATH="$SB/bin:$PATH"

# shellcheck source=./agent-vm.sh
source "$AGENT_VM_SH"

# The start of a mounts JSON entry for host path <path> mounted at <mount point>
# (default: the same path), as _agent_vm_build_mounts_json writes it: the
# location in the host's own spelling, C:/... on Windows.
mnt() { printf '"location": "%s", "mountPoint": "%s"' "$(_agent_vm_host_path "$1")" "${2:-$1}"; }

# The machine running the tests has no /dev/kvm and no QEMU; those checks are
# not under test (lib/host.sh covers them, tests/18-windows.sh the branches).
_agent_vm_check_linux_prereqs() { return 0; }
_agent_vm_check_windows_prereqs() { return 0; }

# 0 when this machine makes real symlinks. Windows runners lack the privilege,
# so ln -s silently plants a copy instead, and every test asserting on links
# (readlink, resolve-through, link-not-file) would test the copy. Those tests
# skip on the verdict below, with the reason printed.
if ln -s "$SELF_DIR/test.sh" "$SB/ln-probe" 2>/dev/null && [ -L "$SB/ln-probe" ]; then
  AGENT_VM_HAS_SYMLINKS=1
else
  AGENT_VM_HAS_SYMLINKS=""
fi
rm -f "$SB/ln-probe"

# project-env needs perl for a file inside the project (_agent_vm_nofollow).
# macOS and most Linux hosts have it; minimal images (bash:3.2) do not, and
# the tests that need it skip there, with the reason printed.
if command -v perl >/dev/null 2>&1; then AGENT_VM_HAS_PERL=1; else AGENT_VM_HAS_PERL=""; fi

printf 'agent-vm test suite (sandbox: %s)\n' "$SB"

# =============================================================================
section "script dir resolves through symlinks"
# =============================================================================
# `agent-vm install` puts a symlink on PATH. Without following it, AGENT_VM_SCRIPT_DIR
# points at the link's directory and `agent-vm setup` cannot find
# agent-vm.setup.sh, which lives next to the real file.
REALDIR="$(CDPATH= cd -P -- "$(dirname "$AGENT_VM_SH")" >/dev/null && pwd)"
mkdir -p "$SB/link1" "$SB/link2"
ln -sf "$AGENT_VM_SH" "$SB/link1/agent-vm"
ln -sf "$SB/link1/agent-vm" "$SB/link2/agent-vm"
# Paths go in as positional parameters: interpolating them into single-quoted
# shell text would break on a path containing a single quote.
script_dir_of() {
  bash -c 'source "$1" 2>/dev/null; printf "%s" "$AGENT_VM_SCRIPT_DIR"' _ "$1"
}
check "direct symlink"                     "$(script_dir_of "$SB/link1/agent-vm")" "$REALDIR"
check "chain of two symlinks"              "$(script_dir_of "$SB/link2/agent-vm")" "$REALDIR"
check "no symlink (the historical sourcing)" "$(script_dir_of "$AGENT_VM_SH")"     "$REALDIR"

# lib/ is found next to the real file; a copy without it says so and stops.
check "through a symlink, lib/ loads too" \
  "$(bash "$SB/link2/agent-vm" version 2>&1)" "$AGENT_VM_VERSION"
mkdir -p "$SB/lone"; cp "$AGENT_VM_SH" "$SB/lone/"
out="$(bash "$SB/lone/agent-vm.sh" version 2>&1)"
case "$?:$out" in
  1:"agent-vm: cannot load $SB/lone/lib/ui.sh") pass "run without lib/: says which file, exits 1" ;;
  *) fail "run without lib/: $out" ;;
esac
out="$(bash -c 'source "$1" 2>/dev/null; echo "returned $?"; type agent-vm >/dev/null 2>&1 || echo "no agent-vm"' _ "$SB/lone/agent-vm.sh")"
check "sourced without lib/: returns 1, defines no half-loaded agent-vm" "$out" "returned 1
no agent-vm"

# =============================================================================
section "install / uninstall"
# =============================================================================
# A throwaway HOME and bin directory. TTY=1 stands for a terminal to ask on,
# ANSWER for the reply (1 yes, 0 no), BASE=1 for a base VM already built.
IH="$SB/ihome"; IBIN="$SB/ibin"
mkdir -p "$IH"
inst() {
  ( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN" SHELL=/bin/zsh PATH="$IBIN:$PATH"
    _agent_vm_have_tty() { [ -n "${TTY:-}" ]; }
    _agent_vm_ask_yn() { echo "${ANSWER:-1}"; }
    _agent_vm_base_exists() { [ -n "${BASE:-}" ]; }
    _agent_vm_setup() { echo "SETUP RAN $#"; return "${SETUP_RC:-0}"; }
    agent-vm "$@" ) 2>&1
}
out="$(inst install)"
check "install: the link points at this agent-vm.sh" "$(readlink "$IBIN/agent-vm" 2>/dev/null)" "$REALDIR/agent-vm.sh"
case "$out" in *"not on your PATH"*) fail "install: PATH hint while the directory is on PATH" ;; *) pass "install: no PATH hint when the directory is on PATH" ;; esac
[ -e "$IH/.zshrc" ] && fail "install: rc written without a terminal to ask on" || pass "install: no terminal, the rc is left alone"
out="$( ( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; _agent_vm_have_tty() { return 1; }; agent-vm install ) 2>&1)"
case "$out" in *"already linked"*"$IBIN is not on your PATH"*'export PATH="'"$IBIN"':$PATH"'*) pass "install again: already linked, and the PATH line to add" ;; *) fail "install again: $out" ;; esac
out="$(TTY=1 inst install)"
check "yes: the rc sources agent-vm.sh" "$(grep -c "source \"$REALDIR/agent-vm.sh\"" "$IH/.zshrc" 2>/dev/null)" "1"
TTY=1 inst install >/dev/null
check "yes, twice: one source line" "$(grep -c 'agent-vm.sh' "$IH/.zshrc")" "1"
rm -f "$IH/.zshrc"
TTY=1 ANSWER=0 inst install >/dev/null
[ -e "$IH/.zshrc" ] && fail "no: the rc was written" || pass "no: the rc is left alone"
check "install takes no argument (exit 2)" "$(inst install --force >/dev/null; echo $?)" "2"

# Then setup, when there is no base yet and a terminal to ask on.
case "$(TTY=1 inst install)" in *"SETUP RAN 0"*) pass "no base, yes: setup runs" ;; *) fail "no base, yes: setup did not run" ;; esac
check "no base, setup fails: install says so" "$(TTY=1 SETUP_RC=3 inst install >/dev/null; echo $?)" "3"
out="$(TTY=1 ANSWER=0 inst install)"
case "$out" in *"SETUP RAN"*) fail "no base, no: setup ran" ;; *"agent-vm setup "*) pass "no base, no: setup is named, not run" ;; *) fail "no base, no: $out" ;; esac
out="$(inst install)"
case "$out" in *"SETUP RAN"*) fail "no terminal: setup ran" ;; *"agent-vm setup "*) pass "no terminal: setup is named, not run" ;; *) fail "no terminal: $out" ;; esac
out="$(TTY=1 BASE=1 inst install)"
case "$out" in *"SETUP RAN"*|*"agent-vm setup "*) fail "base built: setup offered again" ;; *"agent-vm claude"*) pass "base built: points at an agent instead" ;; *) fail "base built: $out" ;; esac

# Someone else's file or link at that path is never replaced.
rm -f "$IBIN/agent-vm"; echo mine > "$IBIN/agent-vm"
check "a file of the user's: refused" "$(inst install >/dev/null; echo $?)" "1"
check "and left as it was" "$(cat "$IBIN/agent-vm")" "mine"
out="$(inst uninstall)"
check "uninstall: a file of the user's is left" "$(cat "$IBIN/agent-vm")" "mine"
rm -f "$IBIN/agent-vm"; ln -s "$SB/nowhere" "$IBIN/agent-vm"
out="$(inst install)"
check "a dangling link: refused, not overwritten" "$(inst install >/dev/null; echo $?):$(readlink "$IBIN/agent-vm")" "1:$SB/nowhere"
case "$out" in *"already exists and is not a link to"*"AGENT_VM_BIN_DIR"*) pass "and says why, with the way out" ;; *) fail "dangling link: $out" ;; esac
rm -f "$IBIN/agent-vm"

# uninstall removes our link and names the rc line it leaves.
inst install >/dev/null
printf 'source "%s"\n' "$REALDIR/agent-vm.sh" > "$IH/.zshrc"
out="$(inst uninstall)"
[ ! -e "$IBIN/agent-vm" ] && [ ! -L "$IBIN/agent-vm" ] && pass "uninstall: our link is removed" || fail "uninstall: the link is still there"
case "$out" in *"still sources agent-vm.sh"*) pass "uninstall: names the rc line it leaves" ;; *) fail "uninstall: $out" ;; esac
check "uninstall: the rc is not edited" "$(cat "$IH/.zshrc")" "source \"$REALDIR/agent-vm.sh\""
case "$(inst uninstall)" in *"No link to remove"*) pass "uninstall again: nothing to remove, said" ;; *) fail "uninstall twice" ;; esac

# The wrapper kept for the previous way: install.sh, and --uninstall. The rc
# already sources agent-vm.sh here, so nothing asks on a terminal.
( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; bash "$REALDIR/install.sh" >/dev/null 2>&1 )
check "install.sh: installs" "$(readlink "$IBIN/agent-vm" 2>/dev/null)" "$REALDIR/agent-vm.sh"
( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; bash "$REALDIR/install.sh" --uninstall >/dev/null 2>&1 )
[ ! -L "$IBIN/agent-vm" ] && pass "install.sh --uninstall: uninstalls" || fail "install.sh --uninstall left the link"

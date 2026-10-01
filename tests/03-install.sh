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
# Link resolution has nothing to resolve where ln -s plants copies (Windows
# runners lack the privilege): those checks skip, with the reason printed.
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
check "direct symlink"                     "$(script_dir_of "$SB/link1/agent-vm")" "$REALDIR"
check "chain of two symlinks"              "$(script_dir_of "$SB/link2/agent-vm")" "$REALDIR"
else
  printf '  skip symlink resolution (ln -s plants copies on this machine)\n'
fi
check "no symlink (the historical sourcing)" "$(script_dir_of "$AGENT_VM_SH")"     "$REALDIR"

# Sourced from a shell rc, the current directory is anyone's: a project where
# the agent may have written a lib/ui.sh.
ELSEWHERE="$SB/elsewhere"; mkdir -p "$ELSEWHERE/lib"
printf 'touch "%s/planted-lib-ran"\n' "$SB" > "$ELSEWHERE/lib/ui.sh"
source_from_elsewhere() {  # <file>
  ( cd "$ELSEWHERE" && bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$AGENT_VM_SCRIPT_DIR"' _ "$1" )
}
check "sourced by bash from another directory: lib/ next to agent-vm.sh" \
  "$(source_from_elsewhere "$AGENT_VM_SH")" "$REALDIR"
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
  check "sourced by bash through a symlink, from another directory" \
    "$(source_from_elsewhere "$SB/link2/agent-vm")" "$REALDIR"
fi
check "sourced by bash: a lib/ in the current directory never runs" \
  "$([ -e "$SB/planted-lib-ran" ] && echo ran || echo no)" "no"
rm -f "$SB/planted-lib-ran"

# zsh (the ~/.zshrc line of 0.1.0's installer): a function running the file
# with bash, and nothing else, whatever the user's options. From another
# directory, through links, and from a path with a space and a quote.
if command -v zsh >/dev/null 2>&1; then
  zsh_source() {  # <file>: sourced, then `agent-vm version`
    ( cd "$ELSEWHERE" && zsh -fc 'setopt noclobber ksh_arrays sh_word_split nounset
      . "$1"; print -r -- "${AGENT_VM_SCRIPT_DIR-unset} $(whence -w agent-vm)"; agent-vm version' _ "$1" 2>&1 )
  }
  check "sourced by zsh: only an agent-vm function, which runs the command" \
    "$(zsh_source "$AGENT_VM_SH")" "unset agent-vm: function
$AGENT_VM_VERSION"
  if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
    check "sourced by zsh through a symlink, from another directory" \
      "$(zsh_source "$SB/link2/agent-vm")" "unset agent-vm: function
$AGENT_VM_VERSION"
  fi
  ODD="$SB/it's odd"; mkdir -p "$ODD"; cp -R "$REALDIR/agent-vm.sh" "$REALDIR/lib" "$ODD/"
  check "sourced by zsh from a path with a space and a quote" \
    "$(zsh_source "$ODD/agent-vm.sh")" "unset agent-vm: function
$AGENT_VM_VERSION"
  rm -rf "$ODD"
  check "sourced by zsh by a relative path: still found from another directory" \
    "$(cd "$REALDIR" && zsh -fc '. ./agent-vm.sh; cd "$1" && agent-vm version' _ "$ELSEWHERE" 2>&1)" "$AGENT_VM_VERSION"
  out="$(cd "$ELSEWHERE" && zsh -fc '. "$1"; agent-vm nosuchcmd' _ "$AGENT_VM_SH" 2>&1; echo "st=$?")"
  case "$out" in *"st=0") fail "sourced by zsh: a failing command returns 0: $out" ;;
    *) pass "sourced by zsh: a failing command's status comes back" ;; esac
  check "sourced by zsh: a lib/ in the current directory never runs" \
    "$([ -e "$SB/planted-lib-ran" ] && echo ran || echo no)" "no"
  rm -f "$SB/planted-lib-ran"
  check "run by zsh: runs under bash" "$(zsh "$AGENT_VM_SH" version 2>&1)" "$AGENT_VM_VERSION"
else
  printf '  skip sourced by zsh (zsh is not installed)\n'
fi

# lib/ is found next to the real file; a copy without it says so and stops.
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
check "through a symlink, lib/ loads too" \
  "$(bash "$SB/link2/agent-vm" version 2>&1)" "$AGENT_VM_VERSION"
else
  printf '  skip through a symlink (ln -s plants copies on this machine)\n'
fi
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
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
check "install: the link points at this agent-vm.sh" "$(readlink "$IBIN/agent-vm" 2>/dev/null)" "$REALDIR/agent-vm.sh"
else
  printf '  skip install: readlink (ln -s plants copies on this machine)\n'
  # A copy stands where the link would: clear it so the installs below start
  # clean instead of tripping over it.
  rm -f "$IBIN/agent-vm"
fi
case "$out" in *"not on your PATH"*) fail "install: PATH hint while the directory is on PATH" ;; *) pass "install: no PATH hint when the directory is on PATH" ;; esac
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
out="$( ( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; _agent_vm_have_tty() { return 1; }; agent-vm install ) 2>&1)"
case "$out" in *"already linked"*"$IBIN is not on your PATH"*'export PATH="'"$IBIN"':$PATH"'*) pass "install again: already linked, and the PATH line to add" ;; *) fail "install again: $out" ;; esac
else
  printf '  skip install again (ln -s plants copies on this machine)\n'
fi
# The link is all install puts in place: no shell rc is written, whatever the
# shell. A `source agent-vm.sh` line in ~/.profile broke every sh login (dash
# has no `source`, and the file is bash).
for sh in /bin/zsh /bin/bash /usr/bin/fish; do
  rm -f "$IBIN/agent-vm"
  ( export SHELL="$sh"; TTY=1 BASE=1 inst install ) >/dev/null
done
check "install writes no shell rc, for zsh, bash or fish" "$(ls -A "$IH")" ""
rm -f "$IBIN/agent-vm"
# An rc line from before 0.2.0 is named, not edited.
printf 'source "%s"\n' "$REALDIR/agent-vm.sh" > "$IH/.zshrc"
out="$(BASE=1 inst install)"
case "$out" in *"still sources agent-vm.sh"*"can remove"*) pass "an old rc line is named as no longer needed" ;; *) fail "old rc line: $out" ;; esac
check "and left as it was" "$(cat "$IH/.zshrc")" "source \"$REALDIR/agent-vm.sh\""
rm -f "$IH/.zshrc" "$IBIN/agent-vm"
check "install takes no argument (exit 2)" "$(inst install --force >/dev/null; echo $?)" "2"

# Then setup, when there is no base yet and a terminal to ask on.
# Each install below starts from a clean bin dir: without symlink privilege
# an install leaves a copy behind, which the next one would read as a foreign
# file. Recreating the link each time is harmless where links are real.
clean_bin() { rm -f "$IBIN/agent-vm"; }
clean_bin
case "$(TTY=1 inst install)" in *"SETUP RAN 0"*) pass "no base, yes: setup runs" ;; *) fail "no base, yes: setup did not run" ;; esac
clean_bin
check "no base, setup fails: install says so" "$(TTY=1 SETUP_RC=3 inst install >/dev/null; echo $?)" "3"
clean_bin
out="$(TTY=1 ANSWER=0 inst install)"
case "$out" in *"SETUP RAN"*) fail "no base, no: setup ran" ;; *"agent-vm setup "*) pass "no base, no: setup is named, not run" ;; *) fail "no base, no: $out" ;; esac
clean_bin
out="$(inst install)"
case "$out" in *"SETUP RAN"*) fail "no terminal: setup ran" ;; *"agent-vm setup "*) pass "no terminal: setup is named, not run" ;; *) fail "no terminal: $out" ;; esac
clean_bin
out="$(TTY=1 BASE=1 inst install)"
case "$out" in *"SETUP RAN"*|*"agent-vm setup "*) fail "base built: setup offered again" ;; *"agent-vm claude"*) pass "base built: points at an agent instead" ;; *) fail "base built: $out" ;; esac

# Someone else's file or link at that path is never replaced.
rm -f "$IBIN/agent-vm"; echo mine > "$IBIN/agent-vm"
check "a file of the user's: refused" "$(inst install >/dev/null; echo $?)" "1"
check "and left as it was" "$(cat "$IBIN/agent-vm")" "mine"
out="$(inst uninstall)"
check "uninstall: a file of the user's is left" "$(cat "$IBIN/agent-vm")" "mine"
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
rm -f "$IBIN/agent-vm"; ln -s "$SB/nowhere" "$IBIN/agent-vm"
out="$(inst install)"
check "a dangling link: refused, not overwritten" "$(inst install >/dev/null; echo $?):$(readlink "$IBIN/agent-vm")" "1:$SB/nowhere"
case "$out" in *"already exists and is not a link to"*"AGENT_VM_BIN_DIR"*) pass "and says why, with the way out" ;; *) fail "dangling link: $out" ;; esac
else
  printf '  skip dangling link (ln -s plants copies on this machine)\n'
fi
rm -f "$IBIN/agent-vm"

# uninstall removes our link and names the rc line it leaves.
inst install >/dev/null
printf 'source "%s"\n' "$REALDIR/agent-vm.sh" > "$IH/.zshrc"
out="$(inst uninstall)"
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
[ ! -e "$IBIN/agent-vm" ] && [ ! -L "$IBIN/agent-vm" ] && pass "uninstall: our link is removed" || fail "uninstall: the link is still there"
else
  printf '  skip uninstall: link removal (ln -s plants copies on this machine)\n'
  rm -f "$IBIN/agent-vm"
fi
case "$out" in *"still sources agent-vm.sh"*) pass "uninstall: names the rc line it leaves" ;; *) fail "uninstall: $out" ;; esac
check "uninstall: the rc is not edited" "$(cat "$IH/.zshrc")" "source \"$REALDIR/agent-vm.sh\""
case "$(inst uninstall)" in *"No link to remove"*) pass "uninstall again: nothing to remove, said" ;; *) fail "uninstall twice" ;; esac

# The wrapper kept for the previous way: install.sh, and --uninstall. The rc
# already sources agent-vm.sh here, so nothing asks on a terminal.
( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; bash "$REALDIR/install.sh" >/dev/null 2>&1 )
if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
check "install.sh: installs" "$(readlink "$IBIN/agent-vm" 2>/dev/null)" "$REALDIR/agent-vm.sh"
else
  printf '  skip install.sh: readlink (ln -s plants copies on this machine)\n'
fi
( export HOME="$IH" AGENT_VM_BIN_DIR="$IBIN"; bash "$REALDIR/install.sh" --uninstall >/dev/null 2>&1 )
[ ! -L "$IBIN/agent-vm" ] && pass "install.sh --uninstall: uninstalls" || fail "install.sh --uninstall left the link"

# =============================================================================
section "--preinstall parsing"
# =============================================================================
preinstall_exports() {
  export AGENT_VM_TEST_CAPTURE="$SB/piped.sh"
  : > "$AGENT_VM_TEST_CAPTURE"
  _agent_vm_setup --preinstall="$1" >/dev/null 2>&1
  grep -E "^export AGENT_VM_INSTALL_$2=" "$AGENT_VM_TEST_CAPTURE" | cut -d= -f2
}
check "default: node on"            "$(preinstall_exports default NODE)"       "1"
check "default: ruby off"           "$(preinstall_exports default RUBY)"       "0"
check "all: ruby on"                "$(preinstall_exports all RUBY)"           "1"
check "none: node off"              "$(preinstall_exports none NODE)"          "0"
check "explicit subset: gh on"      "$(preinstall_exports node,gh GH)"         "1"
check "explicit subset: docker off" "$(preinstall_exports node,gh DOCKER)"     "0"
check "default leaves pi out"       "$(preinstall_exports default PI)"         "0"
check "all installs pi"             "$(preinstall_exports all PI)"             "1"
check "naming pi installs it"       "$(preinstall_exports default,pi PI)"      "1"
check "pi pulls node in"            "$(preinstall_exports pi NODE)"            "1"
check "default leaves code-server out" "$(preinstall_exports default CODE_SERVER)" "0"
check "all installs code-server"    "$(preinstall_exports all CODE_SERVER)"    "1"
check "naming code-server installs it" "$(preinstall_exports default,code-server CODE_SERVER)" "1"
check "code-server alone has no extension" "$(preinstall_exports code-server CODE_CLAUDE)" "0"
check "code-claude pulls code-server in" "$(preinstall_exports code-claude CODE_SERVER)" "1"
check "code-claude alone: no Claude CLI" "$(preinstall_exports code-claude CLAUDE)" "0"
check "default leaves the extensions out" "$(preinstall_exports default CODE_CODEX)" "0"
check "all installs the extensions" "$(preinstall_exports all CODE_VIBE)" "1"
check "code-codex needs no npm" "$(preinstall_exports code-codex NODE)" "0"
check "but the chrome MCP wired into it does" "$(preinstall_exports code-codex,chromium,mcp-chrome NODE)" "1"

section "setup wizard: agents in the editor"
# The question after code-server, with the answer given.
code_ext() {
  ( install_code_server="$1" install_claude="$2" install_codex="$3" install_vibe="$4"
    install_code_claude=0 install_code_codex=0 install_code_vibe=0 answer="$5"
    _agent_vm_ask_choice() { echo asked >> "$SB/asked.log"; echo "$answer"; }
    _agent_vm_ask_code_extensions 2>/dev/null
    echo "$install_claude$install_codex$install_vibe:$install_code_claude$install_code_codex$install_code_vibe" )
}
check "both: CLIs kept, extensions added" "$(code_ext 1 1 0 1 1)" "101:101"
check "extension only: CLIs dropped"      "$(code_ext 1 1 1 0 2)" "000:110"
check "command line only: no extension"   "$(code_ext 1 1 1 1 3)" "111:000"
: > "$SB/asked.log"
check "no code-server: not asked"         "$(code_ext 0 1 1 1 2)" "111:000"
check "no agent with an extension: not asked" "$(code_ext 1 0 0 0 2)" "000:000"
check "and nothing was asked" "$(wc -l < "$SB/asked.log" | tr -d ' ')" "0"

section "--preinstall: MCP names"
check "default wires the chrome MCP"      "$(preinstall_exports default MCP_CHROME)"     "1"
check "default leaves playwright out"     "$(preinstall_exports default MCP_PLAYWRIGHT)" "0"
check "all wires both"                    "$(preinstall_exports all MCP_CHROME)"         "1"
check "all wires playwright too"          "$(preinstall_exports all MCP_PLAYWRIGHT)"     "1"
# The point of the mcp-* names: a caller that manages MCP servers per project
# just omits them. Nothing new has to be passed, so older builds stay compatible.
check "omitting mcp-chrome disables it"   "$(preinstall_exports node,gh,chromium,opencode MCP_CHROME)" "0"
check "naming mcp-chrome enables it"      "$(preinstall_exports node,chromium,opencode,mcp-chrome MCP_CHROME)" "1"
check "naming mcp-playwright enables it"  "$(preinstall_exports node,chromium,opencode,mcp-playwright MCP_PLAYWRIGHT)" "1"

section "startup: when the VM's base was built"
( AGENT_VM_STATE_DIR="$SB/base-age"; mkdir -p "$AGENT_VM_STATE_DIR"
  _agent_vm_resources() { echo '1|3|10'; }
  echo 1790803800 > "$AGENT_VM_STATE_DIR/.agent-vm-version-vmx"
  out="$(_agent_vm_print_resources vmx)"
  case "$out" in *"Base VM: built $(_agent_vm_epoch_date 1790803800 +%F)") echo ok ;; *) echo "date: $out" ;; esac
  case "$(_agent_vm_print_resources agent-vm-base)" in *"Base VM"*) echo "base: said" ;; *) echo ok ;; esac
  echo junk > "$AGENT_VM_STATE_DIR/.agent-vm-version-vmx"
  case "$(_agent_vm_print_resources vmx)" in *"Base VM"*) echo "junk: said" ;; *) echo ok ;; esac
) > "$SB/base-age.out" 2>&1
check "the date of the VM's base, nothing without a record" \
  "$(cat "$SB/base-age.out")" "$(printf 'ok\nok\nok')"

section "terminal modes after a session"
check "nothing written when stdout is not a terminal" "$(_agent_vm_reset_term_modes | wc -c | tr -d ' ')" "0"
if command -v script >/dev/null 2>&1 && script -qc true /dev/null >/dev/null 2>&1; then
  check "mouse tracking and kitty keyboard turned off on a terminal" \
    "$(AGENT_VM_SH="$AGENT_VM_SH" script -qc 'bash -c ". \"\$AGENT_VM_SH\"; _agent_vm_reset_term_modes"' /dev/null | grep -c $'\033\\[?1003l.*\033\\[<u')" "1"
fi

section "boxed notices"
check "a paragraph wraps at the width" \
  "$(printf 'aaa bbb ccc ddd\n' | _agent_vm_wrap 8)" "$(printf 'aaa bbb\nccc ddd')"
check "an indented command is kept whole" \
  "$(printf '  git config --global x y\n' | _agent_vm_wrap 8)" "  git config --global x y"
box="$(printf 'one two\n\n  cmd --flag\n' | _agent_vm_box "Title" 2>&1)"
check "the box: title rule, body, bottom rule, on stderr" "$box" "$(printf '\n+- Title %s\n|\n| one two\n|\n|   cmd --flag\n|\n+%s' \
  "$(printf '%*s' 63 '' | tr ' ' -)" "$(printf '%*s' 71 '' | tr ' ' -)")"
check "nothing on stdout" "$(printf 'x\n' | _agent_vm_box "T" 2>/dev/null)" ""
if script -qec true /dev/null >/dev/null 2>&1; then
  narrow="$(script -qec "stty rows 40 cols 40; bash -c 'source \"$AGENT_VM_SH\"; _agent_vm_bare_repo_hint | _agent_vm_box \"Git: repositories not named .git\"'" /dev/null 2>&1 | tr -d '\r')"
  # Wider lines than the terminal are only the commands, kept whole.
  wide="$(printf '%s\n' "$narrow" | awk 'length($0) > 40 && $0 !~ /^\|   /')"
  check "a 40-column terminal gets a 40-column box" "$wide" ""
else
  printf '  skip narrow box test (no util-linux script)\n'
fi

section "setup: the install output"
# A pipe into the output window must not swallow the install's failure, and
# the log must keep what the window drops.
out="$(AGENT_VM_TEST_SHELL_FAIL=1 _agent_vm_setup --preinstall=none 2>&1)"
check "a failed install still fails setup" "$?" "1"
case "$out" in
  *"Setup script failed. Full log: $HOME/.agent-vm/setup.log"*) pass "the failure names the log" ;;
  *) fail "no log named: $out" ;;
esac
case "$(cat "$HOME/.agent-vm/setup.log")" in
  *"Attempting to download the image"*"E: boom") pass "one log, every step in order: the start, then the install" ;;
  *) fail "setup.log: $(cat "$HOME/.agent-vm/setup.log")" ;;
esac
out="$(AGENT_VM_TEST_START_FAIL=1 _agent_vm_setup --preinstall=none 2>&1)"
check "a failed start fails setup" "$?" "1"
case "$out" in
  *"Failed to start base VM. Full log: $HOME/.agent-vm/setup.log"*) pass "and names the log" ;;
  *) fail "start failure: $out" ;;
esac
case "$(cat "$HOME/.agent-vm/setup.log")" in
  *'msg="no start"'*) pass "which has Lima's error" ;;
  *) fail "setup.log after a failed start: $(cat "$HOME/.agent-vm/setup.log")" ;;
esac
_agent_vm_setup --preinstall=none >/dev/null 2>&1
check "a good install passes" "$?" "0"
check "no status file is left behind" "$([ -e "$HOME/.agent-vm/setup.log.status" ] && echo left || echo gone)" "gone"
check "without a terminal, every line passes through" \
  "$(printf 'a\nb' | _agent_vm_scroll_window "$SB/window.log")" "$(printf 'a\nb')"
check "and reaches the log" "$(cat "$SB/window.log")" "$(printf 'a\nb')"
# On a terminal: never more than 10 lines redrawn, and cleared at the end.
if script -qec true /dev/null >/dev/null 2>&1; then
  win="$(script -qec "stty rows 40 cols 80; bash -c 'source \"$AGENT_VM_SH\"; seq 1 30 | _agent_vm_scroll_window \"$SB/tty.log\"'" /dev/null 2>&1 | cat -v)"
  case "$win" in
    *'^[[11A'*) fail "the window grew past 10 lines" ;;
    *'^[[10A'*'^[[10A^M^[[J') pass "a 10-line window, cleared at the end" ;;
    *) fail "unexpected window output: $(printf '%s' "$win" | tail -c 200)" ;;
  esac
  check "the log keeps all 30 lines" "$(wc -l < "$SB/tty.log" | tr -d ' ')" "30"
  lima_line='time="2026-01-01T00:00:00Z" level=info msg="Attempting to download the image" arch=aarch64 digest=sha256:0123'
  win="$(script -qec "stty rows 40 cols 80; bash -c 'source \"$AGENT_VM_SH\"; printf \"%s\\n\" '\''$lima_line'\'' | _agent_vm_scroll_window \"$SB/lima.log\"'" /dev/null 2>&1 | cat -v)"
  case "$win" in
    *'[2mAttempting to download the image^M'*) pass "a Lima log line shows its message only" ;;
    *) fail "Lima line in the window: $win" ;;
  esac
  check "and the log keeps it whole" "$(cat "$SB/lima.log")" "$lima_line"
else
  printf '  skip terminal window test (no util-linux script)\n'
fi

if _agent_vm_setup --preinstall=node,not-a-real-name >/dev/null 2>&1; then
  fail "an unknown --preinstall name should be fatal"
else
  pass "an unknown --preinstall name is fatal"
fi

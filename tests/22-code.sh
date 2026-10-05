# =============================================================================
section "code: code-server in the VM"
# =============================================================================
# Against the recording limactl of tests/11-recorded-commands.sh.
ports="$(_agent_vm_code_ports "$PV")"
first="${ports%% *}"
check "ten ports per VM" "$(printf '%s\n' $ports | wc -l | tr -d ' ')" "10"
check "the same ones on every start" "$(_agent_vm_code_ports "$PV")" "$ports"
case "$first" in
  2[0-9][0-9][0-9][0-9]) pass "from 20000 to 29999" ;;
  *) fail "port out of range: $first" ;;
esac
check "host name: the VM's, lowercased" "$(_agent_vm_code_host agent-vm-My-Proj-0a1b2c3d)" "agent-vm-my-proj-0a1b2c3d.localhost"
long="agent-vm-$(printf 'x%.0s' $(seq 1 80))-0a1b2c3d"
check "host name: a DNS label, the hash kept" \
  "$(_agent_vm_code_host "$long" | sed 's/\.localhost$//' | awk '{ print length($0) <= 63, substr($0, length($0) - 8) }')" "1 -0a1b2c3d"
check "the ten start at the last digits of the name's hash" "$(_agent_vm_code_ports agent-vm-a-0000270f)" \
  "20008 20009 20010 20011 20012 20013 20014 20015 20016 20017 "
check "another VM, other ports" \
  "$([ "$(_agent_vm_code_ports agent-vm-a-00000001)" != "$(_agent_vm_code_ports agent-vm-b-00000002)" ] && echo differ)" "differ"

# Which candidates something in the VM listens on, run as the VM does: any
# protocol (ss), or, without ss, any answer but a refused connection, never
# through the VM's proxy.
if command -v zsh >/dev/null 2>&1; then
  mkdir -p "$SB/prep-bin" "$SB/prep-home"
  printf '#!/bin/sh\nexit 0\n' > "$SB/prep-bin/code-server"
  printf '#!/bin/sh\nexit 1\n' > "$SB/prep-bin/pgrep"
  printf '#!/bin/sh\nprintf "LISTEN 0 4096 0.0.0.0:20001 0.0.0.0:*\\nLISTEN 0 128 [::]:20002 [::]:*\\n"\n' > "$SB/prep-bin/ss"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --noproxy ] && np=1; done\ncase "$*" in *:20000/*) exit 7 ;; *:20001/*) [ -n "$np" ] && exit 56 ;; esac\nexit 7\n' > "$SB/prep-curl"
  chmod +x "$SB/prep-bin/"* "$SB/prep-curl"
  prep() { HOME="$SB/prep-home" PATH="$1:$PATH" zsh -c "$_AGENT_VM_CODE_PREP" agent-vm-code 20000 20001 20002 2>/dev/null | grep '^listening=' | tr '\n' ' '; }
  check "prep: what ss lists, whatever it speaks" "$(prep "$SB/prep-bin")" "listening=20001 listening=20002 "
  rm "$SB/prep-bin/ss"
  mkdir -p "$SB/prep-nossbin"
  for t in sh awk sed grep cat od tr id mkdir head hostname; do
    ln -sf "$(command -v "$t")" "$SB/prep-nossbin/$t" 2>/dev/null
  done
  cp "$SB/prep-bin/"* "$SB/prep-nossbin/"
  cp "$SB/prep-curl" "$SB/prep-nossbin/curl"
  prep_noss() { HOME="$SB/prep-home" http_proxy=http://127.0.0.1:9/ PATH="$SB/prep-nossbin" "$(command -v zsh)" -c "$_AGENT_VM_CODE_PREP" agent-vm-code 20000 20001 2>/dev/null | grep '^listening=' | tr '\n' ' '; }
  check "prep without ss: a port that answers, not through the proxy" "$(prep_noss)" "listening=20001 "
  rm -rf "$SB/prep-bin" "$SB/prep-nossbin" "$SB/prep-home" "$SB/prep-curl"
else
  printf '  skip the editor prep run (zsh is not installed)\n'
fi

if _agent_vm_host_port_open "$first"; then
  printf '  skip code launch tests (port %s is taken on this machine)\n' "$first"
else
  out="$(rec code)"
  rec_has "agent-vm VSCODE_PROXY_URI= code-server --config /home/u/.config/code-server/agent-vm-lima-x.yaml --bind-addr 127.0.0.1:$first --cookie-suffix $PV" \
    && pass "code-server on the VM's loopback, the VM's own config and cookie" \
    || fail "code: $(grep 'code-server --config' "$REC")"
  rec_has "--disable-getting-started-override --link-protection-trusted-domains https://claude.com/cai/oauth --link-protection-trusted-domains https://platform.claude.com/oauth --vscode-option" \
    && pass "Claude Code's login pages are trusted, by path" || fail "trusted domains: $(grep 'code-server' "$REC")"
  rec_has "--disable-telemetry --disable-update-check --disable-workspace-trust --disable-proxy" \
    && pass "no telemetry, update check or port proxy" || fail "code flags: $(grep 'code-server --config' "$REC")"
  rec_has "--vscode-option disable-experiments --vscode-option disable-extension=GitHub.copilot-chat $PROJ" \
    && pass "no experiments, Copilot never loaded, and the project opened" || fail "code flags: $(grep 'code-server --config' "$REC")"
  case "$out" in
    *"+- VS Code"*"|   Address:   http://$PV.localhost:$first/"*"|   Password:  0123456789abcdef0123456789abcdef"*"Ctrl-C stops the"*)
      pass "the VM's own host name, and the password, in a box" ;;
    *) fail "code output: $out" ;;
  esac
  check "the Safari fallback, on macOS only" \
    "$(uname() { echo Linux; }; _agent_vm_code_say u 20000 pw 2>&1 | grep -c 127.0.0.1; uname() { echo Darwin; }; _agent_vm_code_say u 20000 pw 2>&1 | grep -c 'http://127.0.0.1:20000/')" \
    "$(printf '0\n1')"
  # The user opens it: no opener is run on this machine.
  mkdir -p "$SB/openers"
  for o in open xdg-open start; do printf '#!/bin/sh\n: > "%s/opened"\n' "$SB" > "$SB/openers/$o"; chmod +x "$SB/openers/$o"; done
  rm -f "$SB/opened"
  PATH="$SB/openers:$PATH" rec code >/dev/null
  [ -e "$SB/opened" ] && fail "the browser is opened" || pass "the browser is not opened"
  rm -rf "$SB/openers" "$SB/opened"

  AGENT_VM_TEST_CODE_PREP="config=/c.yaml\npassword=pw\nlistening=$first\n" rec code >/dev/null
  rec_has "--bind-addr 127.0.0.1:$((first + 1))" \
    && pass "a port taken in the VM is skipped" || fail "taken port: $(grep 'code-server --config' "$REC")"

  out="$(AGENT_VM_TEST_CODE_PREP="config=/c.yaml\npassword=pw\nrunning=$first\n" rec code)"
  rec_has "code-server --config" && fail "a second editor was started" \
    || pass "an editor already running is not started again"
  case "$out" in
    *"Address:   http://$PV.localhost:$first/"*"Password:  pw"*"already runs"*) pass "and its address is given" ;;
    *) fail "running: $out" ;;
  esac
fi

out="$(AGENT_VM_TEST_CODE_PREP='missing\n' rec code; echo "rc=$?")"
case "$out" in
  *"code-server is not installed"*"--preinstall=default,code-claude"*"rc=1") pass "without code-server: says how to add it" ;;
  *) fail "missing: $out" ;;
esac
rec_has "code-server --config" && fail "missing: started anyway" || pass "and starts nothing"

out="$(AGENT_VM_TEST_CODE_PREP='config=/c.yaml\npassword=a\033]0;x\a\n' rec code; echo "rc=$?")"
case "$out" in
  *"could not read the editor's password"*"rc=1") pass "a password with control characters is not printed" ;;
  *) fail "control chars: $(printf '%s' "$out" | cat -v)" ;;
esac

out="$(rec code foo; echo "rc=$?")"
case "$out" in
  *"unknown argument for code: foo"*"rc=1") pass "code takes no argument" ;;
  *) fail "code foo: $out" ;;
esac
rec_has "shell" && fail "code foo: the VM was entered" || pass "and enters no VM"

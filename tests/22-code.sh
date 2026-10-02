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
check "another VM, other ports" \
  "$([ "$(_agent_vm_code_ports agent-vm-other-00000000)" != "$ports" ] && echo differ)" "differ"

if _agent_vm_host_port_open "$first"; then
  printf '  skip code launch tests (port %s is taken on this machine)\n' "$first"
else
  out="$(rec code)"
  rec_has "agent-vm code-server --config /home/u/.config/code-server/agent-vm-lima-x.yaml --bind-addr 127.0.0.1:$first --cookie-suffix $PV" \
    && pass "code-server on the VM's loopback, the VM's own config and cookie" \
    || fail "code: $(grep 'code-server --config' "$REC")"
  rec_has "--disable-telemetry --disable-update-check --disable-workspace-trust --disable-proxy" \
    && pass "no telemetry, update check or port proxy" || fail "code flags: $(grep 'code-server --config' "$REC")"
  rec_has "--vscode-option disable-experiments --vscode-option disable-extension=GitHub.copilot-chat $PROJ" \
    && pass "no experiments, Copilot never loaded, and the project opened" || fail "code flags: $(grep 'code-server --config' "$REC")"
  case "$out" in
    *"Editor: http://$PV.localhost:$first/"*"Password: 0123456789abcdef0123456789abcdef"*)
      pass "the VM's own host name, and the password" ;;
    *) fail "code output: $out" ;;
  esac
  check "the Safari fallback, on macOS only" \
    "$(uname() { echo Linux; }; _agent_vm_code_say u 20000 pw | grep -c 127.0.0.1; uname() { echo Darwin; }; _agent_vm_code_say u 20000 pw | grep -c 'http://127.0.0.1:20000/')" \
    "$(printf '0\n1')"

  AGENT_VM_TEST_CODE_PREP="config=/c.yaml\npassword=pw\nlistening=$first\n" rec code >/dev/null
  rec_has "--bind-addr 127.0.0.1:$((first + 1))" \
    && pass "a port taken in the VM is skipped" || fail "taken port: $(grep 'code-server --config' "$REC")"

  out="$(AGENT_VM_TEST_CODE_PREP="config=/c.yaml\npassword=pw\nrunning=$first\n" rec code)"
  rec_has "code-server --config" && fail "a second editor was started" \
    || pass "an editor already running is not started again"
  case "$out" in
    *"already runs"*"http://$PV.localhost:$first/"*"Password: pw"*) pass "and its address is given" ;;
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

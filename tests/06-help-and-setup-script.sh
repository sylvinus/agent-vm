# =============================================================================
section "release hygiene"
# =============================================================================
# Every dispatched command must appear in `help`: a command nobody can discover
# is a command nobody uses. (`sh`/`destroy`/`status` are aliases documented inline.)
help_text="$(agent-vm help)"
missing=""
for verb in setup claude opencode codex vibe pi shell run stop rm destroy-all \
            list name info env version help; do
  case "$help_text" in
    *"  $verb"*) ;;
    *) missing="$missing $verb" ;;
  esac
done
# One verdict, not a pass that fires whatever the loop found.
if [ -n "$missing" ]; then
  fail "dispatched but missing from help:$missing"
else
  pass "every dispatched command appears in help"
fi
check "help lists each customisation file once" \
  "$(printf '%s\n' "$help_text" | grep -c '^  ~/.agent-vm/env ')" "1"
# Every key info prints, named in help.
missing=""
for key in $(agent-vm info "$PROJ" | cut -d= -f1); do
  case "$help_text" in *"$key"*) ;; *) missing="$missing $key" ;; esac
done
check "help names every info key" "$missing" ""
check "the version in help output matches the constant" \
  "$(agent-vm version)" "$AGENT_VM_VERSION"

# A bad resource value must produce an actionable message, not a raw bash
# arithmetic diagnostic leaking from the comparison helper.
bad="$( (agent-vm --disk 10G version) 2>&1 )" || true
case "$bad" in
  *"must be a positive integer"*) pass "a non-numeric --disk is rejected clearly" ;;
  *"value too great for base"*)   fail "raw bash arithmetic error leaked: $bad" ;;
  *) fail "unexpected output for --disk 10G: $bad" ;;
esac
# A command that starts no VM refuses them instead of dropping them: `agent-vm
# --readonly stop` must not read as if something had been made read-only.
for c in version stop status help env; do
  out="$( (agent-vm --readonly "$c") 2>&1 )"
  case "$?:$out" in
    1:*"--readonly is an option for the commands that start a VM"*"not for '$c'"*) pass "--readonly before '$c' is refused" ;;
    *) fail "--readonly before '$c': $out" ;;
  esac
done
out="$( (agent-vm --disk 32 --cpus 4 version) 2>&1 )"
case "$out" in
  *"--disk is an option for the commands that start a VM"*) pass "valid values too: the option is named" ;;
  *) fail "--disk 32 --cpus 4 version: $out" ;;
esac

# A failed write of the secrets file must not be reported as success: a caller
# told the secret was stored when it was not is the worst outcome for this file.
# Root ignores permission bits, so the condition cannot be staged as root —
# which is exactly what the bash 3.2 container runs as.
if [ "$(id -u)" -eq 0 ] || _agent_vm_on_windows; then
  printf '  skip env-set-failure test (running as root, or on Windows where chmod bits are emulated)\n'
else
  RO="$SB/readonly-home"
  mkdir -p "$RO/.agent-vm"
  printf "K='v'\n" > "$RO/.agent-vm/env"
  chmod 500 "$RO/.agent-vm"
  if HOME="$RO" bash "$AGENT_VM_SH" env set OTHER x >/dev/null 2>&1; then
    fail "env set reported success on an unwritable directory"
  else
    pass "env set fails loudly when the write cannot happen"
  fi
  chmod 700 "$RO/.agent-vm"
fi

# =============================================================================
section "setup script: apt runs with a working debconf frontend"
# =============================================================================
# `export DEBIAN_FRONTEND=noninteractive` does not survive sudo's env_reset,
# so an apt call that does not carry the variable itself prints debconf's
# "unable to initialize frontend: Dialog" block on every install step.
if grep -qE '^[^#]*sudo apt-get' "$SETUP_SH"; then
  fail "an apt call bypasses apt_get: $(grep -nE '^[^#]*sudo apt-get' "$SETUP_SH" | head -1)"
else
  pass "every apt call goes through apt_get"
fi
# The script reaches bash on its stdin: a command that reads stdin swallows the
# lines after it. Here sudo stands for a dpkg prompt, reading all it can.
apt_fn="$(sed -n '/^apt_get() {/,/^}/p' "$SETUP_SH")"
check "apt_get does not read the script's stdin" \
  "$({ printf 'sudo() { cat >/dev/null; }\n%s\napt_get update\necho after\n' "$apt_fn"; } | bash 2>/dev/null)" "after"
check "npm installs do not read it either" \
  "$(grep -E '^[^#]*npm i ' "$SETUP_SH" | grep -vc '</dev/null$')" "0"
if grep -q 'sudo env DEBIAN_FRONTEND=noninteractive apt-get' "$SETUP_SH"; then
  pass "apt_get hands the frontend to sudo"
else
  fail "apt_get no longer passes DEBIAN_FRONTEND through sudo"
fi
# Recommends pull in Samba, avahi-daemon, printer config... via Chromium.
if grep -qv -- '--no-install-recommends' <<< "$(grep -E '^[^#]*apt_get install' "$SETUP_SH")"; then
  fail "an install pulls in Recommends: $(grep -nE '^[^#]*apt_get install' "$SETUP_SH" | grep -v -- '--no-install-recommends' | head -1)"
else
  pass "every apt install skips Recommends"
fi
if grep -qE '^[^#]*\| *sudo( -E)? bash' "$SETUP_SH"; then
  fail "a remote script is piped to a root shell: $(grep -nE '^[^#]*\| *sudo( -E)? bash' "$SETUP_SH" | head -1)"
else
  pass "no remote script runs as root"
fi

# Behind a proxy, sudo must keep the proxy settings Lima puts in the guest's
# environment (#25): installed before the first apt call, and checked by
# visudo first, since a broken sudoers file breaks sudo.
proxy_line="$(grep -n '/etc/sudoers.d/10-agent-vm-proxy' "$SETUP_SH" | head -1 | cut -d: -f1)"
visudo_line="$(grep -n 'sudo visudo -cqf /tmp/agent-vm-proxy.sudoers' "$SETUP_SH" | head -1 | cut -d: -f1)"
apt_line="$(grep -nE '^[^#]*apt_get (update|install)' "$SETUP_SH" | head -1 | cut -d: -f1)"
if [ -n "$proxy_line" ] && [ -n "$visudo_line" ] && [ "$visudo_line" -lt "$proxy_line" ] && [ "$proxy_line" -lt "$apt_line" ]; then
  pass "sudo keeps the proxy settings from before the first apt call, checked by visudo"
else
  fail "proxy sudoers drop-in: visudo at ${visudo_line:-none}, install at ${proxy_line:-none}, first apt at ${apt_line:-none}"
fi
kept=" $(grep -o 'env_keep += "[^"]*"' "$SETUP_SH" | cut -d'"' -f2) "
dropped=""
for v in http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
  case "$kept" in *" $v "*) ;; *) dropped="$dropped $v" ;; esac
done
check "sudo keeps every proxy variable, both cases" "$dropped" ""

# Shell history in the VM (#20): the block setup appends to ~/.zshrc, run by
# zsh itself.
sed -n "/^cat >> ~\/.zshrc <<'ZSHRC'/,/^ZSHRC\$/p" "$SETUP_SH" | sed '1d;$d' > "$SB/zshrc-history"
if command -v zsh >/dev/null 2>&1; then
  check "zsh history: saved to a file, space-prefixed commands left out" \
    "$(HOME="$SB" zsh -fc '. "$1"; print -r -- "$HISTFILE $SAVEHIST"; [[ -o histignorespace && -o incappendhistory ]] && print opts' _ "$SB/zshrc-history")" \
    "$SB/.zsh_history 10000
opts"
else
  printf '  skip zsh history (zsh not installed)\n'
fi

# The sshfs wrapper, run against a stub that stands for /usr/bin/sshfs:
# no_contain_symlinks is added only when that sshfs knows it (#22).
sed -n '/^sudo tee \/usr\/local\/bin\/sshfs/,/^EOF$/p' "$SETUP_SH" | sed '1d;$d' \
  | sed "s|/usr/bin/sshfs|$SB/sshfs-real|g" > "$SB/sshfs-wrapper"
sshfs_stub() {  # <help text>
  printf '#!/bin/sh\n[ "$1" = -h ] && { echo "%s"; exit 1; }\necho "$*"\n' "$1" > "$SB/sshfs-real"
  chmod +x "$SB/sshfs-real"
}
sshfs_stub '    -o no_contain_symlinks allow all symlink targets'
check "sshfs wrapper: turns contain_symlinks off where it exists" \
  "$(sh "$SB/sshfs-wrapper" ':/p' /p -o slave -o allow_other)" ":/p /p -o slave -o allow_other -o no_contain_symlinks"
sshfs_stub '    -o follow_symlinks'
check "sshfs wrapper: an older sshfs gets the arguments unchanged" \
  "$(sh "$SB/sshfs-wrapper" ':/p' /p -o slave)" ":/p /p -o slave"

# =============================================================================
section "MCP config writer"
# =============================================================================
# configure_mcp lives in the in-VM setup script, whose top level performs the
# actual installs — so lift just that function out rather than sourcing it.
if ! command -v jq >/dev/null 2>&1; then
  printf '  skip configure_mcp tests (jq not installed)\n'
else
  MCPHOME="$SB/mcp"; mkdir -p "$MCPHOME"
  (
    HOME="$MCPHOME"
    eval "$(awk '/^configure_mcp\(\) \{/,/^\}/' "$SETUP_SH")"
    INSTALL_CLAUDE=1 INSTALL_OPENCODE=1 INSTALL_VIBE=1 INSTALL_CODEX=1
    for _ in 1 2; do   # twice: the writer must be idempotent
      configure_mcp chrome-devtools npx -y chrome-devtools-mcp@latest --headless=true
      configure_mcp playwright env PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npx -y @playwright/mcp@latest
    done
  ) >/dev/null 2>&1

  oc="$MCPHOME/.config/opencode/opencode.json"
  check "opencode: two servers"  "$(jq '.mcp | length' "$oc")" "2"
  check "opencode: \$schema kept" "$(jq -r '."$schema"' "$oc")" "https://opencode.ai/config.json"
  check "opencode: command starts with the launcher" \
    "$(jq -r '.mcp.playwright.command[0]' "$oc")" "env"
  check "opencode: env assignment survives as its own argv entry" \
    "$(jq -r '.mcp.playwright.command[1]' "$oc")" "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1"
  check "claude: two servers" \
    "$(jq '.mcpServers | length' "$MCPHOME/.claude.json")" "2"
  check "codex: no duplicate table after two runs" \
    "$(grep -cF '[mcp_servers.playwright]' "$MCPHOME/.codex/config.toml")" "1"
  check "vibe: no duplicate entry after two runs" \
    "$(grep -c '^\[\[mcp_servers\]\]' "$MCPHOME/.vibe/config.toml")" "2"
fi

# =============================================================================
section "Pi install block"
# =============================================================================
# Lifted out like configure_mcp, with sudo recorded instead of run.
if ! command -v jq >/dev/null 2>&1; then
  printf '  skip Pi install tests (jq not installed)\n'
else
  pi_block="$(awk '/^if \[\[ "\$INSTALL_PI" == "1" \]\]; then/,/^fi$/' "$SETUP_SH")"
  run_pi_block() {
    ( HOME="$1"; INSTALL_PI=1 INSTALL_NODE="$2"
      sudo() { echo "sudo $*" >> "$HOME/sudo.log"; }
      eval "$pi_block" ) >/dev/null 2>&1
  }
  PIH="$SB/pi-home"; mkdir -p "$PIH"
  run_pi_block "$PIH" 1
  check "pi: the maintained package, without install scripts" "$(cat "$PIH/sudo.log" 2>/dev/null)" \
    "sudo npm i -g --ignore-scripts @earendil-works/pi-coding-agent"
  # (The </dev/null is a redirection, which the recording sudo does not see.)
  check "pi: project files trusted" \
    "$(jq -r .defaultProjectTrust "$PIH/.pi/agent/settings.json" 2>/dev/null)" "always"
  check "pi: telemetry off" \
    "$(jq -r .enableInstallTelemetry "$PIH/.pi/agent/settings.json" 2>/dev/null)" "false"
  PIH0="$SB/pi-home-nonode"; mkdir -p "$PIH0"
  run_pi_block "$PIH0" 0
  check "pi: skipped without node" "$( [ -e "$PIH0/sudo.log" ] || [ -e "$PIH0/.pi" ]; echo $?)" "1"
fi

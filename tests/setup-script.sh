#!/usr/bin/env bash
#
# Checks of agent-vm.setup.sh, the script `agent-vm setup` runs in the base
# VM: its blocks lifted out and run against stubs, nothing installed. Run by
# TestSetupScript (setup_script_test.go), or alone:
#
#   tests/setup-script.sh

set -uo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")/.." >/dev/null && pwd)"
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
# Physical path: macOS reaches its temp dir through /private.
SB="$(CDPATH= cd -P -- "$SB" >/dev/null && pwd)"
trap 'rm -rf "$SB"' EXIT

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

# An agent is there as a command, as an extension, or both: either way its
# config (managed settings, MCP servers) is written. The lines setup derives
# it with, run as setup does.
has_block="$(awk '/^HAS_CLAUDE=0 HAS_CODEX=0 HAS_VIBE=0$/,/HAS_VIBE=1$/' "$SETUP_SH")"
has() { ( INSTALL_CLAUDE="$1" INSTALL_CODE_CLAUDE="$2" INSTALL_CODEX="$3" INSTALL_CODE_CODEX="$4" INSTALL_VIBE="$5" INSTALL_CODE_VIBE="$6"
          eval "$has_block"; echo "$HAS_CLAUDE$HAS_CODEX$HAS_VIBE" ); }
check "setup: the agents' config, for a command or an extension" \
  "$(has 1 0 0 0 0 0) $(has 0 1 0 0 0 0) $(has 0 0 0 1 0 0) $(has 0 0 0 0 1 1) $(has 0 0 0 0 0 0)" "100 100 010 001 000"

# =============================================================================
section "MCP config writer"
# =============================================================================
# configure_mcp lives in the in-VM setup script, whose top level performs the
# actual installs, so lift just that function out rather than sourcing it.
if ! command -v jq >/dev/null 2>&1; then
  printf '  skip configure_mcp tests (jq not installed)\n'
else
  MCPHOME="$SB/mcp"; mkdir -p "$MCPHOME"
  (
    HOME="$MCPHOME"
    eval "$(awk '/^configure_mcp\(\) \{/,/^\}/' "$SETUP_SH")"
    HAS_CLAUDE=1 INSTALL_OPENCODE=1 HAS_VIBE=1 HAS_CODEX=1
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

# =============================================================================
section "code-server JSON schemas"
# =============================================================================
# code_server_schemas against a fake code-server and a curl serving files of
# $SCH/web, named after the URL, recording what it was asked for. It runs in
# the VM, under bash 4 or later.
if ! command -v jq >/dev/null 2>&1 || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '  skip code-server schema tests (needs jq and bash 4)\n'
else
  SCH="$SB/schemas"; mkdir -p "$SCH/ext/a" "$SCH/ext/b" "$SCH/web"
  web() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' _; }
  echo '{"contributes":{"jsonValidation":[{"fileMatch":"a.json","url":"https://h.test/s/a"},{"fileMatch":"x","url":"vscode://schemas/x"}]}}' > "$SCH/ext/a/package.json"
  echo '{"contributes":{"jsonValidation":[{"fileMatch":"b.json","url":"https://json.schemastore.org/b"},{"fileMatch":"g","url":"https://h.test/gone"}]}}' > "$SCH/ext/b/package.json"
  # a: an absolute ref, a relative one with ./ and a fragment, a local one,
  # and one to the editor's own schemas.
  echo '{"$ref":"#/definitions/x","definitions":{"x":{"$ref":"https://h.test/abs.json"},"y":{"$ref":"./rel.json#/z"},"z":{"$ref":"vscode://schemas/settings"},"w":{"properties":{"$ref":{"type":"string"}}}}}' > "$SCH/web/$(web https://h.test/s/a)"
  # abs refers to a schema that is no object: true is a valid schema.
  echo '{"type":"object","properties":{"t":{"$ref":"https://h.test/true.json"}}}' > "$SCH/web/$(web https://h.test/abs.json)"
  echo 'true' > "$SCH/web/$(web https://h.test/true.json)"
  echo '{"$ref":"../top.json"}' > "$SCH/web/$(web https://h.test/s/rel.json)"
  echo '{"type":"string"}' > "$SCH/web/$(web https://h.test/top.json)"
  echo '{"type":"number"}' > "$SCH/web/$(web https://www.schemastore.org/b)"
  # c: listed at one URL, its $id another, which its relative references
  # follow, as the editor's do. d: references up two folders.
  mkdir -p "$SCH/ext/c"
  echo '{"contributes":{"jsonValidation":[{"fileMatch":"c.json","url":"https://www.schemastore.org/package"},{"fileMatch":"d.json","url":"https://h.test/s/a/b/d.json"}]}}' > "$SCH/ext/c/package.json"
  echo '{"$id":"https://json.schemastore.org/package.json","properties":{"e":{"$ref":"eslintrc.json#"}}}' > "$SCH/web/$(web https://www.schemastore.org/package)"
  echo '{"type":"boolean"}' > "$SCH/web/$(web https://www.schemastore.org/eslintrc.json)"
  echo '{"$ref":"../../c.json"}' > "$SCH/web/$(web https://h.test/s/a/b/d.json)"
  echo '{"type":"null"}' > "$SCH/web/$(web https://h.test/s/c.json)"
  out="$( ( curl() {
              local o="" st=0
              echo call >> "$SCH/calls"
              while [ $# -gt 0 ]; do
                case "$1" in
                  -o) o="$2"; shift 2 ;;
                  --parallel-max|--max-time) shift 2 ;;
                  -*) shift ;;
                  *)
                    echo "$1" >> "$SCH/fetched"
                    if [ -f "$SCH/web/$(web "$1")" ]; then cp "$SCH/web/$(web "$1")" "$o"; else st=22; fi
                    shift ;;
                esac
              done
              return "$st"
            }
            set -euo pipefail
            eval "$(awk '/^(code_server_schemas|schema_url_resolve)\(\) \{/,/^\}/' "$SETUP_SH")"
            code_server_schemas "$SCH/ext" "$SCH/machine/settings.json"; echo "rc=$?" ) 2>&1)"
  check "every schema named, and every one they refer to, by the URL the editor asks" \
    "$(jq -r '."json.schemas"[].url' "$SCH/machine/settings.json" 2>/dev/null | sort | tr '\n' ' ')" \
    "https://h.test/abs.json https://h.test/s/a https://h.test/s/a/b/d.json https://h.test/s/c.json https://h.test/s/rel.json https://h.test/top.json https://h.test/true.json https://json.schemastore.org/b https://json.schemastore.org/eslintrc.json https://www.schemastore.org/package "
  check "a level of references fetched in one call" "$(wc -l < "$SCH/calls" | tr -d ' ')" "3"
  check "each with its content" \
    "$(jq -r '."json.schemas"[] | select(.url == "https://h.test/top.json") | .schema.type' "$SCH/machine/settings.json" 2>/dev/null)" "string"
  check "json.schemastore.org fetched from www.schemastore.org, where it redirects" \
    "$(grep -c 'json.schemastore.org' "$SCH/fetched"; grep -c '^https://www.schemastore.org/b$' "$SCH/fetched")" "$(printf '0\n1')"
  check "the editor's own schemas are left alone" "$(grep -c vscode "$SCH/fetched")" "0"
  case "$out" in
    *"could not download the JSON schema https://h.test/gone"*"rc=0") pass "a failed download is a warning, not a failure" ;;
    *) fail "failed download: $out" ;;
  esac
fi

# =============================================================================
section "code-server install block"
# =============================================================================
# Lifted out like the Pi block, with curl and code-server recorded instead of
# run, then the MCP writer after it, as in the script.
if ! command -v jq >/dev/null 2>&1; then
  printf '  skip code-server install tests (jq not installed)\n'
else
  cs_block="$(awk '/^toml_prepend\(\) \{/,/^\}/' "$SETUP_SH")
$(awk '/^if \[\[ "\$INSTALL_CODE_SERVER" == "1" \]\]; then/,/^fi$/' "$SETUP_SH")
$(awk '/^configure_mcp\(\) \{/,/^\}/' "$SETUP_SH")"
  # <home> <claude> <codex> <vibe>: the extensions asked for.
  # Under set -e, as the script runs: a failing step must show here. Twice:
  # what it writes must not pile up when it runs again in the same VM. The
  # first run's state is kept in <home>/first.
  run_cs_block() {
    mkdir -p "$1/.config/code-server"; echo "password: from-the-base" > "$1/.config/code-server/config.yaml"
    ( set -e
      HOME="$1"; INSTALL_CODE_SERVER=1 INSTALL_CODE_CLAUDE="$2" INSTALL_CODE_CODEX="$3" INSTALL_CODE_VIBE="$4"
      HAS_CLAUDE="$2" HAS_CODEX="$3" HAS_VIBE="$4" INSTALL_OPENCODE=0
      curl() { echo "curl $*" >> "$HOME/calls.log"; }
      code-server() { echo "code-server $*" >> "$HOME/calls.log"; }
      code_server_schemas() { echo "schemas $*" >> "$HOME/calls.log"; mkdir -p "$(dirname "$2")"; echo '{"json.schemas":[]}' > "$2"; }
      eval "$cs_block"
      mkdir -p "$HOME/first"
      for f in .codex/config.toml .vibe/config.toml; do [ ! -f "$HOME/$f" ] || cp "$HOME/$f" "$HOME/first/${f%%/*}"; done
      configure_mcp chrome-devtools npx -y chrome-devtools-mcp@latest
      eval "$cs_block"
      configure_mcp chrome-devtools npx -y chrome-devtools-mcp@latest
      echo done > "$HOME/finished" ) >/dev/null 2>&1
  }
  CSB="$SB/cs-bare"; mkdir -p "$CSB"
  run_cs_block "$CSB" 0 0 0
  check "code-server alone: no extension installed" "$(grep -c '^code-server' "$CSB/calls.log")" "0"
  check "code-server alone: Copilot off" \
    "$(jq -r '."chat.disableAIFeatures"' "$CSB/.local/share/code-server/User/settings.json")" "true"
  check "code-server alone: dark theme" \
    "$(jq -r '."workbench.colorTheme"' "$CSB/.local/share/code-server/User/settings.json")" "Dark 2026"
  check "code-server alone: no telemetry, no experiments" \
    "$(jq -r '[."telemetry.telemetryLevel", ."workbench.enableExperiments"] | map(tostring) | join(" ")' \
       "$CSB/.local/share/code-server/User/settings.json")" "off false"
  check "code-server alone: the editor downloads no schema" \
    "$(jq -r '."json.schemaDownload.enable"' "$CSB/.local/share/code-server/User/settings.json")" "false"
  check "code-server alone: setup puts them in the machine settings" \
    "$(grep '^schemas' "$CSB/calls.log" | head -n 1 | sed 's|^schemas [^ ]*/lib/vscode/extensions |schemas <ext> |')" \
    "schemas <ext> $CSB/.local/share/code-server/Machine/settings.json"
  check "code-server alone: no Claude settings" \
    "$(jq -r 'keys | map(select(startswith("claudeCode"))) | length' "$CSB/.local/share/code-server/User/settings.json")" "0"
  check "the password code-server wrote is not left in the base" \
    "$([ -e "$CSB/.config/code-server" ] && echo left || echo gone)" "gone"

  check "code-server alone: runs to the end under set -e" "$(cat "$CSB/finished" 2>/dev/null)" "done"

  CSA="$SB/cs-all"; mkdir -p "$CSA"
  run_cs_block "$CSA" 1 1 1
  check "with the extensions: runs to the end under set -e" "$(cat "$CSA/finished" 2>/dev/null)" "done"
  check "codex: written on a fresh home" "$(head -n 2 "$CSA/first/.codex" 2>/dev/null | sort | tr '\n' ' ')" \
    'approval_policy = "never" sandbox_mode = "danger-full-access" '
  check "vibe: written on a fresh home" "$(cat "$CSA/first/.vibe" 2>/dev/null)" 'default_agent = "auto-approve"'
  check "the three extensions, in one call" \
    "$(grep '^code-server' "$CSA/calls.log" | head -n 1)" \
    "code-server --install-extension anthropic.claude-code --install-extension openai.chatgpt --install-extension mistralai.mistral-vibe-code"
  # The permission keys are machine-scoped: code-server reads them from the
  # machine settings only.
  check "claude: bypass mode allowed and picked, in the machine settings" \
    "$(jq -r '[."claudeCode.allowDangerouslySkipPermissions", ."claudeCode.initialPermissionMode"] | map(tostring) | join(" ")' \
       "$CSA/.local/share/code-server/Machine/settings.json")" "true bypassPermissions"
  check "claude: and not in the user settings, where they do nothing" \
    "$(jq -r 'keys | map(select(startswith("claudeCode.") and . != "claudeCode.hideOnboarding")) | length' \
       "$CSA/.local/share/code-server/User/settings.json")" "0"
  check "claude: no onboarding checklist" \
    "$(jq -r '."claudeCode.hideOnboarding"' "$CSA/.local/share/code-server/User/settings.json")" "true"
  check "codex: full access, once, before any table" \
    "$(head -n 2 "$CSA/.codex/config.toml" | sort | tr '\n' ' '; grep -c '^approval_policy' "$CSA/.codex/config.toml")" \
    'approval_policy = "never" sandbox_mode = "danger-full-access" 1'
  check "vibe: auto-approve, once, before any table" \
    "$(head -n 1 "$CSA/.vibe/config.toml"; grep -c '^default_agent' "$CSA/.vibe/config.toml")" \
    "$(printf 'default_agent = "auto-approve"\n1')"
  if python3 -c 'import tomllib' 2>/dev/null; then
    check "codex: the file parses, keys at the top level" \
      "$(python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print(d["approval_policy"], "chrome-devtools" in d["mcp_servers"])' "$CSA/.codex/config.toml")" \
      "never True"
    check "vibe: the file parses, key at the top level" \
      "$(python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print(d["default_agent"], len(d["mcp_servers"]))' "$CSA/.vibe/config.toml")" \
      "auto-approve 1"
  else
    printf '  skip TOML parse checks (no python3 with tomllib)\n'
  fi
fi

printf '\n%s passed, %s failed\n' "$PASSED" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

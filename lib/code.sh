# --- code: code-server in the VM, opened in the host's browser ----------------

# Run in the VM before the editor starts, with the candidate ports as
# arguments. Prints `missing` without code-server, else its config file and
# password, the port of an editor of this VM already running, and which
# candidates something in the VM listens on.
#
# The password is made here, in the VM, on first use, never in the base:
# every VM is a copy of the base disk, and one VM knowing another's password
# could log into it through the host's loopback, which every VM reaches. The
# file is named after the hostname, which Lima sets per VM, so a file that
# came with the base is never used.
_AGENT_VM_CODE_PREP='
command -v code-server >/dev/null 2>&1 || { echo missing; exit 0; }
cfg="$HOME/.config/code-server/agent-vm-$(hostname).yaml"
if [ ! -s "$cfg" ]; then
  pw="$(od -An -N16 -tx1 /dev/urandom | tr -d " \n")"
  [ "${#pw}" = 32 ] || exit 1
  mkdir -p "${cfg%/*}" || exit 1
  (umask 077 && printf "auth: password\npassword: %s\ncert: false\n" "$pw" > "$cfg") || exit 1
fi
echo "config=$cfg"
echo "password=$(sed -n "s/^password: //p" "$cfg")"
pgrep -u "$(id -u)" -af -- "--config $cfg" \
  | sed -n "s/.*--bind-addr 127\.0\.0\.1:\([0-9]*\).*/running=\1/p" | head -n 1
for p in "$@"; do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$p/" && echo "listening=$p"
done
exit 0
'

# Ten host ports for <vm>'s editor, from its name: the same on every start,
# so the browser finds the saved password at the same address.
_agent_vm_code_ports() {
  local h base i
  h="$(printf '%s' "$1" | _agent_vm_sha256 | cut -c1-4)"
  [[ "$h" =~ ^[0-9a-f]{4}$ ]] || return 1
  base=$((20000 + (16#$h % 1000) * 10))
  for i in 0 1 2 3 4 5 6 7 8 9; do printf '%s ' $((base + i)); done
}

# The host name the browser reaches <vm>'s editor at: <vm>.localhost, which
# Chrome and Firefox send to 127.0.0.1 on their own. Browsers keep cookies
# per host name, not per port: on 127.0.0.1, a page served by any VM would
# receive the session cookie of every editor, which logs into it. Lowercase,
# and at most 63 characters (a DNS label), the hash at the end kept.
_agent_vm_code_host() {
  local label
  label="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [[ ${#label} -gt 63 ]]; then
    label="${label:0:54}-${label:$((${#label} - 8))}"
  fi
  printf '%s.localhost\n' "$label"
}

# 0 when something on this machine accepts connections on 127.0.0.1:<port>.
_agent_vm_host_port_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# The editor's <url> on <port>, and its <password>. Safari leaves *.localhost
# to macOS, which may not resolve it: 127.0.0.1 then, in a window of its own.
_agent_vm_code_say() {
  echo "Editor: $1"
  echo "Password: $3"
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "(Safari may not resolve it: then http://127.0.0.1:$2/, in a private window kept for this editor, so pages from other VMs never get its cookie.)"
  fi
}

# Open <url> in the host's browser once Lima forwards <port>.
_agent_vm_code_open() {
  local url="$1" port="$2" i=0
  until _agent_vm_host_port_open "$port"; do
    i=$((i + 1))
    if [[ $i -ge 60 ]]; then
      echo "Warning: nothing on 127.0.0.1:$port after 60s: Lima did not forward the editor's port." >&2
      return 1
    fi
    sleep 1
  done
  if _agent_vm_on_windows; then
    start "$url"
  elif [[ "$(uname -s)" == Darwin ]]; then
    open "$url"
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
  fi >/dev/null 2>&1
  return 0
}

# `agent-vm code`: code-server for the project, in the foreground until
# Ctrl-C. Takes no argument of its own.
_agent_vm_code() {
  local vm_opts=() rm="" tty="" args=()
  _agent_vm_split_args "$@" || return 1
  if [[ ${#args[@]} -gt 0 || -n "$tty" ]]; then
    echo "Error: unknown argument for code: ${args[0]:---tty}" >&2
    echo "Usage: agent-vm [vm options] code" >&2
    return 1
  fi
  _agent_vm_in_vm _agent_vm_code_session
}

_agent_vm_code_session() {
  local vm_name="$1" host_dir="$2" ports out line cfg="" pw="" running="" listening=" " port="" p
  local url opener="" want_tty="" st=0
  ports="$(_agent_vm_code_ports "$vm_name")" || {
    echo "Error: cannot hash the VM name: install shasum or sha256sum." >&2
    return 1
  }
  # shellcheck disable=SC2086
  if ! out="$(limactl shell "$vm_name" -- zsh -lc "$_AGENT_VM_CODE_PREP" agent-vm-code $ports </dev/null)"; then
    echo "Error: could not set up the editor's password in VM '$vm_name'." >&2
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      missing)
        echo "Error: code-server is not installed in VM '$vm_name'." >&2
        echo "  'agent-vm setup --preinstall=default,code-claude' (or code-server alone) adds it to the base, then 'agent-vm --reset code'" >&2
        echo "  re-clones this VM (its disk is lost)." >&2
        return 1 ;;
      config=*)    cfg="${line#config=}" ;;
      password=*)  pw="${line#password=}" ;;
      running=*)   running="${line#running=}" ;;
      listening=*) listening="$listening${line#listening=} " ;;
    esac
  done <<< "$out"
  # Printed to the terminal: nothing the VM wrote may carry escape sequences.
  if [[ -z "$pw" || "$pw$cfg" == *[[:cntrl:]]* || ( -n "$running" && ! "$running" =~ ^[0-9]+$ ) ]]; then
    echo "Error: could not read the editor's password in VM '$vm_name'." >&2
    return 1
  fi

  if [[ -n "$running" ]]; then
    url="http://$(_agent_vm_code_host "$vm_name"):$running/"
    echo "The editor of VM '$vm_name' already runs, from another terminal."
    _agent_vm_code_say "$url" "$running" "$pw"
    [[ -t 1 ]] && _agent_vm_code_open "$url" "$running"
    return 0
  fi

  # The first port free both here and in the VM: Lima forwards the VM's port
  # to the same one here, and only when nothing holds it.
  for p in $ports; do
    [[ "$listening" == *" $p "* ]] && continue
    _agent_vm_host_port_open "$p" && continue
    port="$p"
    break
  done
  if [[ -z "$port" ]]; then
    echo "Error: no free port for the editor among: $ports" >&2
    return 1
  fi

  url="http://$(_agent_vm_code_host "$vm_name"):$port/"
  _agent_vm_code_say "$url" "$port" "$pw"
  echo "The password is kept in the VM, in $cfg. Ctrl-C stops the editor."
  if [[ -t 1 ]]; then
    _agent_vm_code_open "$url" "$port" &
    opener=$!
  fi
  # A terminal for Ctrl-C to reach code-server: without one, it would keep
  # running in the VM once this command ends.
  [[ -t 0 && -t 1 ]] && want_tty=1
  # Bound to the VM's loopback, which Lima forwards to this machine's only.
  # The cookie suffix keeps sessions apart at 127.0.0.1, where two editors
  # would overwrite each other's cookie. --disable-proxy: no route from the
  # browser to the VM's other ports, and the proxy is where CVE-2025-47269 was.
  # The --vscode-option ones reach the VS Code server inside: no experiments,
  # and the built-in Copilot Chat never loads (it updates itself otherwise).
  # The settings written at setup do the rest (agent-vm.setup.sh).
  _agent_vm_lima_run "$vm_name" "$host_dir" "$want_tty" code-server \
    --config "$cfg" \
    --bind-addr "127.0.0.1:$port" \
    --cookie-suffix "$vm_name" \
    --app-name "$vm_name" \
    --disable-telemetry \
    --disable-update-check \
    --disable-workspace-trust \
    --disable-proxy \
    --disable-getting-started-override \
    --vscode-option disable-experiments \
    --vscode-option disable-extension=GitHub.copilot-chat \
    "$host_dir" || st=$?
  [[ -z "$opener" ]] || kill "$opener" 2>/dev/null
  return "$st"
}

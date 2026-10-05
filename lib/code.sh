# --- code: code-server in the VM, for the host's browser ----------------------

# Run in the VM before the editor starts, with the candidate ports as
# arguments. Prints `missing` without code-server, else its config file and
# password, the port of an editor of this VM already running, and which
# candidates something in the VM listens on, whatever it speaks (ss; without
# it, curl, any answer but a refused connection, the VM's proxy bypassed).
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
if command -v ss >/dev/null 2>&1; then
  open=" $(ss -Hltn 2>/dev/null | awk "{ n = split(\$4, a, \":\"); printf \"%s \", a[n] }")"
  for p in "$@"; do
    case "$open" in *" $p "*) echo "listening=$p" ;; esac
  done
else
  for p in "$@"; do
    curl -s -o /dev/null --noproxy "*" --max-time 1 "http://127.0.0.1:$p/"
    [ $? -eq 7 ] || echo "listening=$p"
  done
fi
exit 0
'

# Ten host ports for <vm>'s editor, from 20000 to 29999, from its name: the
# same on every start, so the browser finds the saved password at the same
# address while the first is free. VM names end with a hash (see
# _agent_vm_name): its last four digits start the ten, anywhere in the range,
# so two VMs rarely start at the same port.
_agent_vm_code_ports() {
  local h="${1: -4}" base i
  [[ "$h" =~ ^[0-9a-f]{4}$ ]] || h="$(printf '%s' "$1" | _agent_vm_sha256 | cut -c1-4)"
  [[ "$h" =~ ^[0-9a-f]{4}$ ]] || return 1
  base=$((20000 + 16#$h % 9991))
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

# The address of <vm>'s editor on <port>, its <password>, and a last line
# <note>, in a box. Safari leaves *.localhost to macOS, which may not resolve
# it: 127.0.0.1 then, in a window of its own.
_agent_vm_code_say() {
  {
    echo "  Address:   http://$(_agent_vm_code_host "$1"):$2/"
    echo "  Password:  $3"
    if [[ "$(uname -s)" == Darwin ]]; then
      echo ""
      echo "If Safari does not open it: http://127.0.0.1:$2/ in a private window kept for this editor, so pages from other VMs never get its cookie."
    fi
    [[ -z "${4:-}" ]] || printf '\n%s\n' "$4"
  } | _agent_vm_box "VS Code"
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
  local vm_name="$1" host_dir="$2" ports out line cfg="" pw="" running="" port="" p want_tty=""
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
    esac
  done <<< "$out"
  # Printed to the terminal: nothing the VM wrote may carry escape sequences.
  if [[ -z "$pw" || "$pw$cfg" == *[[:cntrl:]]* || ( -n "$running" && ! "$running" =~ ^[0-9]+$ ) ]]; then
    echo "Error: could not read the editor's password in VM '$vm_name'." >&2
    return 1
  fi

  if [[ -n "$running" ]]; then
    _agent_vm_code_say "$vm_name" "$running" "$pw" "The editor of VM '$vm_name' already runs, from another terminal."
    return 0
  fi

  # The first port free both here and in the VM: Lima forwards the VM's port
  # to the same one here, and only when nothing holds it.
  for p in $ports; do
    _agent_vm_has_line "$out" "listening=$p" && continue
    _agent_vm_host_port_open "$p" && continue
    port="$p"
    break
  done
  if [[ -z "$port" ]]; then
    echo "Error: no free port for the editor among: $ports" >&2
    return 1
  fi

  _agent_vm_code_say "$vm_name" "$port" "$pw" "The password is kept in the VM, in $cfg. Ctrl-C stops the editor."
  # A terminal for Ctrl-C to reach code-server: without one, it would keep
  # running in the VM once this command ends.
  [[ -t 0 && -t 1 ]] && want_tty=1
  # Bound to the VM's loopback, which Lima forwards to this machine's only.
  # The cookie suffix keeps sessions apart at 127.0.0.1. --disable-proxy: no
  # route from the browser to the VM's other ports; empty VSCODE_PROXY_URI
  # leaves a link to localhost:<port> at that port here instead of rewriting
  # it through the editor's /proxy/. An absolute template such as
  # http://localhost:{{port}}/ breaks the workbench: code-server runs
  # new URL() on it before substituting {{port}}, which throws Invalid URL
  # (coder/code-server#6504). The --vscode-option
  # ones: no experiments, and the built-in Copilot Chat never loads. Claude
  # Code's login pages open without the link prompt, those paths only.
  #
  # Not a boundary between VMs: any VM can listen on a port Lima forwards to
  # this machine, and a page it serves can send the browser, with this
  # editor's cookie, to a host name it chose. Every VM can reach every
  # other's editor; keeping them apart needs network isolation, which
  # agent-vm does not have yet.
  _agent_vm_lima_run "$vm_name" "$host_dir" "$want_tty" \
    'VSCODE_PROXY_URI=' code-server \
    --config "$cfg" \
    --bind-addr "127.0.0.1:$port" \
    --cookie-suffix "$vm_name" \
    --app-name "$vm_name" \
    --disable-telemetry \
    --disable-update-check \
    --disable-workspace-trust \
    --disable-proxy \
    --disable-getting-started-override \
    --link-protection-trusted-domains https://claude.com/cai/oauth \
    --link-protection-trusted-domains https://platform.claude.com/oauth \
    --vscode-option disable-experiments \
    --vscode-option disable-extension=GitHub.copilot-chat \
    "$host_dir"
}

# --- setup: build the base template -------------------------------------------

# Report a setup failure and leave nothing running. The half-provisioned
# template stays on disk on purpose (the next `setup` deletes and recreates
# it, and keeping it lets the user look inside), but it has no reason to keep
# burning CPU and RAM meanwhile.
_agent_vm_setup_aborted() {
  echo "Error: $1" >&2
  limactl stop "$AGENT_VM_TEMPLATE" &>/dev/null
}

# _agent_vm_scroll_window <log>: copy stdin to <log>. On a terminal, show only
# the last 10 lines, redrawn in place and cleared at the end; otherwise pass
# every line through. Lines are cut to the terminal width, since a wrapped line
# would break the redraw, and colour codes are dropped, since a cut one would
# leave the terminal coloured. No fork per line: apt prints thousands of lines.
_agent_vm_scroll_window() {
  local log="$1"
  if [[ ! -t 1 ]]; then
    tee -a "$log"
    return 0
  fi
  local height=10 size width rows line rest buf="" n=0 drawn=0
  # "rows cols". Not tput: with stdout captured and stderr silenced it has no
  # terminal left to ask, and answers 80. Probed first, as in _agent_vm_box:
  # without a terminal the open itself errors on stderr.
  if _agent_vm_have_tty; then
    size="$(stty size 2>/dev/null </dev/tty)"
  else
    size=""
  fi
  rows="${size% *}"; width="${size#* }"
  [[ "$width" =~ ^[0-9]+$ && "$width" -gt 1 ]] || width=80
  [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -lt $((height + 2)) ]] && height=$((rows > 3 ? rows - 2 : 1))
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >&3
    # A progress bar redraws with \r: keep what the last redraw left.
    line="${line%$'\r'}"; line="${line##*$'\r'}"
    # Lima logs `time="…" level=info msg="…" key=value`: the message is what
    # fits and what says something.
    if [[ "$line" == time=*' msg="'* ]]; then
      line="${line#* msg=\"}"; line="${line%%\"*}"
    fi
    while [[ "$line" == *$'\e'* ]]; do
      rest="${line#*$'\e'}"
      line="${line%%$'\e'*}${rest#\[*[A-Za-z]}"
    done
    line="${line//$'\t'/ }"
    line="${line:0:$((width - 1))}"
    if [[ "$n" -lt "$height" ]]; then
      n=$((n + 1))
    else
      buf="${buf#*$'\n'}"
    fi
    buf="$buf$line"$'\n'
    [[ "$drawn" -gt 0 ]] && printf '\e[%dA' "$drawn"
    printf '\r\e[J\e[2m%s\e[0m' "$buf"
    drawn="$n"
  done 3>>"$log"
  [[ "$drawn" -gt 0 ]] && printf '\e[%dA\r\e[J' "$drawn"
  return 0
}

# _agent_vm_windowed <log> <command> [args...]: run the command, stdin
# included, with its output in _agent_vm_scroll_window and appended to <log>.
# Returns the command's status, which goes through a file: a pipeline returns
# its last command's. On failure,
# the end of the log is shown again, since the window is gone.
_agent_vm_windowed() {
  local log="$1" status_file="$1.status" rc
  shift
  echo 1 >| "$status_file"
  { "$@" 2>&1; echo $? >| "$status_file"; } | _agent_vm_scroll_window "$log"
  rc="$(cat "$status_file" 2>/dev/null)"
  rm -f "$status_file"
  if [[ "$rc" != "0" ]]; then
    [[ -t 1 ]] && tail -n 20 "$log" >&2
    return 1
  fi
  return 0
}

# Why the caller's install_* choices need Node.js, if they do: Codex and Pi
# install with npm, Chrome DevTools MCP runs with npx for the agents it is
# wired into.
_agent_vm_node_needed_by() {
  if [[ "$install_codex" == 1 ]]; then
    echo "Codex CLI requires npm"
  elif [[ "$install_pi" == 1 ]]; then
    echo "Pi requires npm"
  elif [[ "$install_chromium" == 1 && "$install_mcp_chrome" == 1 \
          && ( "$install_claude" == 1 || "$install_opencode" == 1 || "$install_vibe" == 1 ) ]]; then
    echo "Chrome DevTools MCP uses npx"
  fi
  return 0
}

_agent_vm_setup() {
  local disk=10
  local memory=3
  local cpus=1
  local preinstall=""
  local preinstall_seen=""
  # The default set, used without --preinstall when the wizard's first
  # question is accepted or there is no terminal. Opt-in: Ruby, Rust, Go, Pi
  # (0.x, released several times a week) and Playwright MCP (a second
  # browser-driving server, whose tools cost context in every agent). Only MCP
  # servers with something to bake into the image belong here; a remote one
  # is per-project config.
  local install_python=1 install_node=1
  local install_ruby=0 install_rust=0 install_golang=0
  local install_docker=1 install_chromium=1 install_gh=1
  local install_claude=1 install_opencode=1 install_codex=1 install_vibe=1
  local install_pi=0
  local install_mcp_chrome=1 install_mcp_playwright=0

  local vm_opts=() rm="" taken
  while [[ $# -gt 0 ]]; do
    # The resources are read as for the other commands (see
    # _agent_vm_take_opt); its other options are not setup's.
    vm_opts=(); rm=""
    _agent_vm_take_opt "$@" || return 1
    if [[ $taken -gt 0 ]]; then
      local opt="${vm_opts[*]-}"
      case "$opt" in
        "--disk "*)   disk="${opt#--disk }" ;;
        "--memory "*) memory="${opt#--memory }" ;;
        "--cpus "*)   cpus="${opt#--cpus }" ;;
        *)
          echo "Unknown option: ${1%%=*}" >&2
          echo "Usage: agent-vm setup [--disk GB] [--memory GB] [--cpus N] [--preinstall=LIST]" >&2
          return 1 ;;
      esac
      shift "$taken"
      continue
    fi
    case "$1" in
      --help|-h)
        cat << 'EOF'
Usage: agent-vm setup [options]

Create a base VM template with dev tools and agents pre-installed. Runs an
interactive wizard by default; the first prompt offers a "default install"
(everything except the opt-in Ruby, Rust, Go, Pi, Playwright MCP). Answer 'n' for
per-component prompts. Pass --preinstall=... to skip the wizard and pick a
specific subset non-interactively. When no terminal is available (e.g. CI),
the wizard is skipped automatically and the default set is installed.

Options:
  --disk GB           VM disk size (default: 10)
  --memory GB         VM memory (default: 3)
  --cpus N            Number of CPUs (default: 1)
  --preinstall=LIST   Comma-separated list of tools to preinstall in the base
                      VM image (skips the wizard). Anything not listed is
                      skipped. Use:
                        'default' for the default set
                                  (everything except Ruby, Rust, Go, Pi,
                                  mcp-playwright),
                        'all' for everything,
                        'none' for nothing.
                      Available names:
                        python, node, ruby, rust, golang, docker, chromium,
                        gh, claude, opencode, codex, vibe, pi, mcp-chrome,
                        mcp-playwright
                      Selecting codex or pi also installs node (npm). So does
                      mcp-chrome when chromium and an agent are selected
                      (npx). mcp-playwright does not: list node yourself.
                      The mcp-* names wire an MCP server into each installed
                      agent's config. Both 'mcp-chrome' (Chrome DevTools) and
                      'mcp-playwright' drive the preinstalled Chromium, so
                      both need node and chromium and are skipped, with a
                      notice, without them. Pi has no MCP support, so they
                      are not wired into it. 'mcp-playwright' is opt-in and not
                      part of 'default': a second browser-driving server is
                      redundant for most users. Omit them to leave the agents'
                      MCP config untouched, for when MCP servers are
                      managed per project rather than baked into the image.
                      Examples:
                        --preinstall=default,rust       # default set plus Rust
                        --preinstall=python,docker,claude
                        --preinstall=node,chromium,opencode   # no chrome MCP
  --help              Show this help
EOF
        return 0
        ;;
      --preinstall)
        preinstall_seen=1
        # Only consume the next argument as the value when it is an actual
        # value, not another option. Bare `--preinstall` falls back to the
        # default set (handled below) without swallowing e.g. a following
        # `--disk`.
        if [[ -n "${2:-}" && "$2" != -* ]]; then
          preinstall="$2"
          shift 2
        else
          shift
        fi
        ;;
      --preinstall=*)
        preinstall="${1#*=}"
        preinstall_seen=1
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Usage: agent-vm setup [--disk GB] [--memory GB] [--cpus N] [--preinstall=LIST]" >&2
        return 1
        ;;
    esac
  done

  # Apply --preinstall=LIST: start with everything OFF and turn on what's
  # listed. 'default' / 'all' / 'none' are shortcuts. Setting this also
  # bypasses the interactive wizard below. `--preinstall=` with no value
  # (or `--preinstall` swallowed by a following flag) falls back to the
  # default set, explicitly opting into the wizard's recommended install.
  # Pass `--preinstall=none` if you really want nothing.
  if [[ -n "$preinstall_seen" ]]; then
    install_python=0 install_node=0 install_ruby=0 install_rust=0 install_golang=0
    install_docker=0 install_chromium=0 install_gh=0
    install_claude=0 install_opencode=0 install_codex=0 install_vibe=0
    install_pi=0
    install_mcp_chrome=0 install_mcp_playwright=0
    [[ -z "$preinstall" ]] && preinstall="default"
    # Iterate the comma-list by appending a trailing comma and peeling off
    # one token per iteration.
    local rest="${preinstall}," f
    while [[ -n "$rest" ]]; do
      f="${rest%%,*}"
      rest="${rest#*,}"
      # Trim whitespace.
      f="${f# }"; f="${f% }"
      [[ -z "$f" ]] && continue
      case "$f" in
        all)
          install_python=1 install_node=1 install_ruby=1
          install_rust=1 install_golang=1
          install_docker=1 install_chromium=1 install_gh=1
          install_claude=1 install_opencode=1 install_codex=1 install_vibe=1
          install_pi=1
          install_mcp_chrome=1 install_mcp_playwright=1
          ;;
        default)
          install_python=1 install_node=1
          install_docker=1 install_chromium=1 install_gh=1
          install_claude=1 install_opencode=1 install_codex=1 install_vibe=1
          install_mcp_chrome=1
          ;;
        none) ;;  # explicit no-op token; with the all-off reset above,
                  # `--preinstall=none` ships nothing.
        python)   install_python=1 ;;
        node)     install_node=1 ;;
        ruby)     install_ruby=1 ;;
        rust)     install_rust=1 ;;
        golang)   install_golang=1 ;;
        docker)   install_docker=1 ;;
        chromium) install_chromium=1 ;;
        gh)       install_gh=1 ;;
        claude)   install_claude=1 ;;
        opencode) install_opencode=1 ;;
        codex)    install_codex=1 ;;
        vibe)     install_vibe=1 ;;
        pi)       install_pi=1 ;;
        mcp-chrome)     install_mcp_chrome=1 ;;
        mcp-playwright) install_mcp_playwright=1 ;;
        *)
          echo "Unknown preinstall name: $f (names are lowercase)" >&2
          echo "Valid: python, node, ruby, rust, golang, docker, chromium, gh, claude, opencode, codex, vibe, pi, mcp-chrome, mcp-playwright, default, all, none" >&2
          return 1
          ;;
      esac
    done
  fi

  # Fail-fast checks before the (potentially long) wizard so the user doesn't
  # answer 15 prompts only to be told their host is missing Lima or KVM.
  # Installing software on the host is asked, never assumed. Without a
  # terminal to ask on, say what to run instead.
  # The Lima that keeps .git read-only is offered first, so that it is not
  # brew's lima installed now and replaced a minute later.
  echo "Starting agent-vm setup..."
  local declined_protection=""
  if [[ -z "$(_agent_vm_limactl_path)" ]]; then
    if _agent_vm_on_windows && _agent_vm_have_tty; then
      if [[ "$(_agent_vm_ask_yn "Lima is not installed. Download the Lima build for Windows that keeps .git read-only (both zips, about 60 MB)?" Y)" == "1" ]]; then
        _agent_vm_install_fork_windows || return 1
        hash -r 2>/dev/null
      fi
    elif command -v brew &>/dev/null && _agent_vm_have_tty; then
      if [[ "$(_agent_vm_ask_yn "Lima is not installed. Install it now with 'brew install $AGENT_VM_LIMA_FORMULA' (keeps .git read-only for the VMs, built from source)?" Y)" == "1" ]]; then
        brew install "$AGENT_VM_LIMA_FORMULA" || return 1
      else
        declined_protection=1
        if [[ "$(_agent_vm_ask_yn "Install brew's lima instead, which lets the VMs write .git?" Y)" == "1" ]]; then
          brew install lima || return 1
          echo "With this Lima, every start with writable shares will ask first ('agent-vm doctor' says why)." >&2
        fi
      fi
    fi
    if [[ -z "$(_agent_vm_limactl_path)" ]]; then
      echo "Error: Lima is required." >&2
      if _agent_vm_on_windows; then
        echo "  Run 'agent-vm setup' in a terminal: it offers the Lima build for Windows." >&2
        echo "  Or get it by hand at $(_agent_vm_lima_fork_release)" >&2
        echo "  (both Windows zips, verified, unpacked on PATH)." >&2
      elif command -v brew &>/dev/null; then
        echo "  Install it with: brew install $AGENT_VM_LIMA_FORMULA" >&2
        echo "  (or brew install lima, which lets the VMs write .git)" >&2
      else
        echo "  Install it from https://lima-vm.io/docs/installation/" >&2
      fi
      return 1
    fi
  fi

  _agent_vm_check_linux_prereqs || return 1
  _agent_vm_check_windows_prereqs || return 1

  # Interactive wizard, unless --preinstall was passed or no terminal is
  # attached (e.g. running under CI). Defaults shown in [] are prefilled from
  # any --disk/--memory/--cpus flags the user already passed, so they can
  # confirm or override. Components default to the "default install" set
  # (everything except Ruby/Rust/Go). The first prompt offers that whole set
  # as a one-tap shortcut; 'n' gives per-component prompts.
  if [[ -z "$preinstall_seen" ]] && _agent_vm_have_tty; then
    printf '\nagent-vm setup wizard\n' >&2
    printf '─────────────────────\n\n' >&2
    printf 'These settings apply to the base VM image. Every per-project VM is\n' >&2
    printf 'cloned from it, so anything preinstalled here is available in all\n' >&2
    printf 'future agent VMs. You can still install extra tools inside any\n' >&2
    printf 'individual VM later (e.g. via `agent-vm shell`).\n\n' >&2
    printf 'For more: https://www.agent-vm.org/\n\n' >&2

    # Software first: the more interesting choice for most users.
    printf 'Software\n' >&2
    printf '────────\n' >&2
    printf '  Agents:   Claude Code, OpenCode, Codex CLI, Mistral Vibe\n' >&2
    printf '  Tools:    Python, Node.js, Docker, Chromium, gh,\n' >&2
    printf '            Chrome DevTools MCP\n' >&2
    printf '  Skip:     Pi, Ruby, Rust, Go, Playwright MCP\n\n' >&2
    local use_default_software
    use_default_software=$(_agent_vm_ask_yn "Use this default" Y)
    if [[ "$use_default_software" != "1" ]]; then
      printf '\nAI coding agents\n' >&2
      printf '────────────────\n' >&2
      install_claude=$(_agent_vm_ask_yn "Claude Code" Y)
      install_opencode=$(_agent_vm_ask_yn "OpenCode" Y)
      install_codex=$(_agent_vm_ask_yn "Codex CLI" Y)
      install_vibe=$(_agent_vm_ask_yn "Mistral Vibe" Y)
      install_pi=$(_agent_vm_ask_yn "Pi" N)

      printf '\nSystem tools\n' >&2
      printf '────────────\n' >&2
      install_docker=$(_agent_vm_ask_yn "Docker" Y)
      install_chromium=$(_agent_vm_ask_yn "Chromium (headless browser)" Y)
      install_gh=$(_agent_vm_ask_yn "GitHub CLI (gh)" Y)

      # MCP servers, wired into each installed agent's config. Chrome DevTools
      # drives the Chromium above, so it is only worth asking when that is on.
      # Playwright brings its own browser download, hence the N default.
      install_mcp_chrome=0 install_mcp_playwright=0
      if [[ "$install_chromium" == "1" ]]; then
        install_mcp_chrome=$(_agent_vm_ask_yn "Chrome DevTools MCP (wired into each agent's config)" Y)
        install_mcp_playwright=$(_agent_vm_ask_yn "Playwright MCP (also drives that Chromium)" N)
      fi

      local node_forced_reason
      node_forced_reason="$(_agent_vm_node_needed_by)"

      printf '\nLanguages\n' >&2
      printf '─────────\n' >&2
      install_python=$(_agent_vm_ask_yn "Python 3" Y)
      if [[ -n "$node_forced_reason" ]]; then
        install_node=1
        printf 'Node.js 24: yes (%s)\n' "$node_forced_reason" >&2
      else
        install_node=$(_agent_vm_ask_yn "Node.js 24" Y)
      fi
      # Opt-in, like Pi and Playwright MCP: N unless asked for.
      install_ruby=$(_agent_vm_ask_yn "Ruby" N)
      install_rust=$(_agent_vm_ask_yn "Rust" N)
      install_golang=$(_agent_vm_ask_yn "Go" N)
    fi

    # Resources second, the same way, accepted in one go or not. Current
    # values reflect any --disk/--memory/--cpus already passed on the CLI.
    # These are starting values: any later `agent-vm` command can resize the
    # per-project VM with --disk/--memory/--cpus.
    printf '\nDefault resources\n' >&2
    printf '─────────────────\n' >&2
    printf '(per-VM override with --disk / --memory / --cpus on any agent-vm command)\n\n' >&2
    printf '  Disk     %s GB\n' "$disk" >&2
    printf '  Memory   %s GB\n' "$memory" >&2
    printf '  CPUs     %s\n\n'  "$cpus" >&2
    local use_default_resources
    use_default_resources=$(_agent_vm_ask_yn "Use these defaults" Y)
    if [[ "$use_default_resources" != "1" ]]; then
      disk=$(_agent_vm_ask_int "Disk size in GB" "$disk")
      memory=$(_agent_vm_ask_int "Memory in GB" "$memory")
      cpus=$(_agent_vm_ask_int "Number of CPUs" "$cpus")
    fi
    printf '\n' >&2
  fi

  # After the wizard: its questions are the familiar ones (which agents, how
  # much RAM), this one is not, and a first run should not open on it. Still
  # before the VM is created, since it can replace Lima. Announced, so a
  # warning reads as the result of a check and not out of the blue.
  # safe.bareRepository is checked on every start instead (see
  # _agent_vm_check_bare_repo_setting).
  echo "Running security checks..."
  [[ -n "$declined_protection" ]] || _agent_vm_offer_git_protection

  # --preinstall can name what needs node without node.
  local node_reason
  node_reason="$(_agent_vm_node_needed_by)"
  if [[ -n "$node_reason" && "$install_node" != "1" ]]; then
    echo "Enabling Node.js because $node_reason." >&2
    install_node=1
  fi

  _agent_vm_clean_partial_state "$AGENT_VM_TEMPLATE"

  # Retire the marker with the base it describes, before anything can fail.
  # It is only rewritten at the end of a successful setup, so leaving the old
  # one in place would make an interrupted re-setup look like a ready base.
  rm -f "$AGENT_VM_STATE_DIR/.agent-vm-base-version" "$AGENT_VM_STATE_DIR/.agent-vm-base-built-by"

  limactl stop "$AGENT_VM_TEMPLATE" &>/dev/null
  limactl delete "$AGENT_VM_TEMPLATE" --force &>/dev/null

  # Same clamp as the per-project path. Done here rather than at parse time so
  # the wizard above still shows what was asked for.
  cpus="$(_agent_vm_cap_resource cpus "$cpus")"
  memory="$(_agent_vm_cap_resource memory "$memory")"
  _agent_vm_warn_disk_space "$disk"

  echo "Creating base VM..."
  local create_args=(
    --set '.mounts=[]'
    --disk="$disk"
    --memory="$memory"
    --cpus="$cpus"
    --tty=false
    # No Lima containerd: Docker (optional) ships its own, and Lima's unit in
    # /usr/local shadows Docker's. Also skips unpacking nerdctl on every boot.
    --containerd=none
  )
  # Every step from here shows its output in a 10-line window, all of it kept
  # in one log for when something fails.
  mkdir -p "$AGENT_VM_STATE_DIR"
  local setup_log="$AGENT_VM_STATE_DIR/setup.log"
  : >| "$setup_log"
  if ! _agent_vm_windowed "$setup_log" \
       limactl create --name="$AGENT_VM_TEMPLATE" template:debian-13 "${create_args[@]}" </dev/null; then
    echo "Error: Failed to create base VM. Full log: $setup_log" >&2
    return 1
  fi

  _agent_vm_print_resources "$AGENT_VM_TEMPLATE"

  echo "Starting base VM (the first run downloads a Debian image)..."
  if ! _agent_vm_windowed "$setup_log" limactl start "$AGENT_VM_TEMPLATE" </dev/null; then
    echo "Error: Failed to start base VM. Full log: $setup_log" >&2
    echo "Lima's own log: $(_agent_vm_lima_home)/$AGENT_VM_TEMPLATE/ha.stderr.log" >&2
    _agent_vm_windows_start_hint "$setup_log" "$(_agent_vm_lima_home)/$AGENT_VM_TEMPLATE/ha.stderr.log"
    return 1
  fi

  # The setup script runs in the VM, the choices as `export` lines put before
  # it on stdin. Without them, it installs the default set.
  echo "Installing packages inside VM..."
  if [[ ! -r "${AGENT_VM_SCRIPT_DIR}/agent-vm.setup.sh" ]]; then
    echo "Error: Setup script not found at ${AGENT_VM_SCRIPT_DIR}/agent-vm.setup.sh" >&2
    return 1
  fi
  {
    printf 'export AGENT_VM_INSTALL_PYTHON=%s\n'    "$install_python"
    printf 'export AGENT_VM_INSTALL_NODE=%s\n'      "$install_node"
    printf 'export AGENT_VM_INSTALL_RUBY=%s\n'      "$install_ruby"
    printf 'export AGENT_VM_INSTALL_RUST=%s\n'      "$install_rust"
    printf 'export AGENT_VM_INSTALL_GOLANG=%s\n'    "$install_golang"
    printf 'export AGENT_VM_INSTALL_DOCKER=%s\n'    "$install_docker"
    printf 'export AGENT_VM_INSTALL_CHROMIUM=%s\n'  "$install_chromium"
    printf 'export AGENT_VM_INSTALL_GH=%s\n'        "$install_gh"
    printf 'export AGENT_VM_INSTALL_CLAUDE=%s\n'    "$install_claude"
    printf 'export AGENT_VM_INSTALL_OPENCODE=%s\n'  "$install_opencode"
    printf 'export AGENT_VM_INSTALL_CODEX=%s\n'     "$install_codex"
    printf 'export AGENT_VM_INSTALL_VIBE=%s\n'      "$install_vibe"
    printf 'export AGENT_VM_INSTALL_PI=%s\n'        "$install_pi"
    printf 'export AGENT_VM_INSTALL_MCP_CHROME=%s\n'     "$install_mcp_chrome"
    printf 'export AGENT_VM_INSTALL_MCP_PLAYWRIGHT=%s\n' "$install_mcp_playwright"
    cat "${AGENT_VM_SCRIPT_DIR}/agent-vm.setup.sh"
  } | _agent_vm_windowed "$setup_log" limactl shell "$AGENT_VM_TEMPLATE" bash -l \
    || { _agent_vm_setup_aborted "Setup script failed. Full log: $setup_log"; return 1; }

  # Run user's custom setup script if it exists
  local user_setup="$AGENT_VM_STATE_DIR/setup.sh"
  if [ -f "$user_setup" ]; then
    echo "Running custom setup from $user_setup..."
    _agent_vm_strip_cr < "$user_setup" | limactl shell "$AGENT_VM_TEMPLATE" zsh -l \
      || { _agent_vm_setup_aborted "Custom setup script failed."; return 1; }
  fi

  # The ready marker only for a stopped template: Lima clones only a stopped
  # instance, so every new project VM would fail on a base still running.
  if ! _agent_vm_stop_vm "$AGENT_VM_TEMPLATE"; then
    echo "Error: the base VM is set up but did not stop: 'limactl stop $AGENT_VM_TEMPLATE', then 'agent-vm setup' again." >&2
    return 1
  fi

  # Record base VM version so we can warn about stale clones
  mkdir -p "$AGENT_VM_STATE_DIR"
  # And which agent-vm built it, for `list` and the bases of 0.1.0, which
  # wrote none (see _agent_vm_migrate_0_1).
  printf '%s\n' "$AGENT_VM_VERSION" >| "$AGENT_VM_STATE_DIR/.agent-vm-base-built-by"
  date +%s >| "$AGENT_VM_STATE_DIR/.agent-vm-base-version"

  echo ""
  echo "Base VM ready. Try one of these in any project directory:"
  echo "  agent-vm shell"
  [[ "$install_claude"   == "1" ]] && echo "  agent-vm claude"
  [[ "$install_opencode" == "1" ]] && echo "  agent-vm opencode"
  [[ "$install_codex"    == "1" ]] && echo "  agent-vm codex"
  [[ "$install_vibe"     == "1" ]] && echo "  agent-vm vibe"
  [[ "$install_pi"       == "1" ]] && echo "  agent-vm pi"
  # Only worth saying to someone who has a VM to re-clone: on a first install
  # there is nothing to reset, and the advice reads like a missed step.
  if [[ -n "$(_agent_vm_project_vms)" ]]; then
    echo ""
    echo "Note: Existing VMs were not updated. Use --reset to re-clone them from the new base."
  fi
}

# --- ui: prompts, boxes, terminal detection -----------------------------------

# Can a terminal actually be opened? `-r /dev/tty` does not answer that: the
# device node is world-readable even with no controlling terminal (CI, cron),
# and only opening it fails.
_agent_vm_have_tty() {
  ( exec </dev/tty ) 2>/dev/null
}

# Prompt for a value with a default. Reads from /dev/tty so this still works
# when called inside command substitution. Writes the prompt to stderr and the
# answer (or the default if the user just pressed Enter) to stdout.
#
# `2>/dev/null` comes before `</dev/tty` in every read below: redirections
# apply left to right, so the other order prints the open error first.
_agent_vm_ask() {
  local prompt="$1" default="$2" reply=""
  printf '  %s [%s]: ' "$prompt" "$default" >&2
  IFS= read -r reply 2>/dev/null </dev/tty || reply=""
  printf '%s\n' "${reply:-$default}"
}

# Yes/no prompt. Second arg is the default: Y or N (case-insensitive). Prints
# 1 (yes) or 0 (no) to stdout. Empty input picks the default.
_agent_vm_ask_yn() {
  local prompt="$1" default="${2:-Y}" reply="" indicator
  case "$default" in
    [Yy]*) indicator="[Y/n]"; default=Y ;;
    *)     indicator="[y/N]"; default=N ;;
  esac
  printf '  %s %s: ' "$prompt" "$indicator" >&2
  IFS= read -r reply 2>/dev/null </dev/tty || reply=""
  reply="${reply:-$default}"
  case "$reply" in
    [Yy]*) printf '1\n' ;;
    *)     printf '0\n' ;;
  esac
}

# Can a question be asked, and seen? A terminal to read the answer from, and
# stderr, where the question goes, on a terminal too: a caller capturing
# stderr would otherwise wait on a question nobody sees.
_agent_vm_can_ask() {
  _agent_vm_have_tty && [[ -t 2 ]]
}

# Turn off the input modes a full-screen program in the VM may have left on
# the terminal, when it was killed or the SSH session dropped before it
# restored them: mouse tracking (1000, 1002, 1003, with the 1006 and 1015
# encodings), focus reports (1004), bracketed paste (2004), the kitty keyboard
# protocol (a pop, which resets the flags when it empties the stack) and
# xterm's modifyOtherKeys. Each one types escape sequences into the host
# shell otherwise. Also shows the cursor. No clear, no leaving the alternate
# screen: 1049l restores a saved cursor position, which moves the prompt.
_agent_vm_reset_term_modes() {
  [[ -t 1 ]] || return 0
  printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[?1004l\033[?2004l\033[<u\033[>4;0m\033[?25h'
}

# What turned the security questions off, when something did:
# --unsafe-disable-security-prompts (_agent_vm_ensure_running sets
# _agent_vm_unsafe_no_prompts, as a local, for the flag), or
# AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1 in the shell. Never a file of
# the project, which the VM can write. Fails when they are on.
_agent_vm_prompts_disabled_by() {
  if [[ -n "${_agent_vm_unsafe_no_prompts:-}" ]]; then
    printf '%s\n' "--unsafe-disable-security-prompts"
  elif [[ "${AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS:-}" == 1 ]]; then
    printf '%s\n' "AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1"
  else
    return 1
  fi
}

# The question after a security warning: 0 to go on. No by default, and when
# it cannot be asked (_agent_vm_can_ask); yes when the questions are off.
_agent_vm_confirm_unsafe() {
  local by
  if by="$(_agent_vm_prompts_disabled_by)"; then
    echo "Continuing: $by." >&2
    return 0
  fi
  _agent_vm_can_ask && [[ "$(_agent_vm_ask_yn "Continue anyway?" N)" == "1" ]]
}

# _agent_vm_wrap <width>: word-wrap stdin to <width> columns. Lines indented
# by two spaces are commands, kept whole so they can be copied.
_agent_vm_wrap() {
  awk -v w="$1" '
    /^  / || length($0) <= w { print; next }
    {
      line = ""; n = split($0, word, " ")
      for (i = 1; i <= n; i++) {
        if (line == "") line = word[i]
        else if (length(line) + 1 + length(word[i]) <= w) line = line " " word[i]
        else { print line; line = word[i] }
      }
      print line
    }'
}

# _agent_vm_box <title>: print stdin on stderr as a boxed notice, for the
# warnings and offers of setup and of a start: one paragraph per line,
# wrapped to the terminal (72 columns at most). A question asked right after reads as being about the box.
# No right border: it would need every line padded to its display width, which
# the shell does not know for non-ASCII text.
_agent_vm_box() {
  local title="$1" size width rule n
  # Probed first: asking stty outright prints the shell's own open error on
  # stderr when there is no terminal, which a bare 2>/dev/null
  # does not silence, since it is the redirection itself that fails.
  if _agent_vm_have_tty; then
    size="$(stty size 2>/dev/null </dev/tty)"
  else
    size=""
  fi
  width="${size#* }"
  [[ "$width" =~ ^[0-9]+$ ]] || width=72
  [[ "$width" -gt 72 ]] && width=72
  [[ "$width" -lt 30 ]] && width=30
  rule="$(printf '%*s' "$width" '' | tr ' ' '-')"
  n=$((width - ${#title} - 4))
  [[ "$n" -lt 1 ]] && n=1
  {
    printf '\n+- %s %s\n|\n' "$title" "${rule:0:$n}"
    _agent_vm_wrap $((width - 2)) | sed 's/^/| /; s/ *$//'
    printf '|\n+%s\n' "${rule:0:$((width - 1))}"
  } >&2
}

# Prompt for a positive integer with default. Re-prompts on invalid input.
# Used for disk/memory/cpus where a typo (e.g. "10G") would otherwise produce
# a cryptic limactl error several seconds later.
_agent_vm_ask_int() {
  local prompt="$1" default="$2" reply
  while true; do
    reply=$(_agent_vm_ask "$prompt" "$default")
    if [[ "$reply" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s\n' "$reply"
      return 0
    fi
    printf '  (must be a positive integer, e.g. 10; got: %s)\n' "$reply" >&2
  done
}

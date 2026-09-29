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

# _agent_vm_wrap <width> — word-wrap stdin to <width> columns. Lines indented
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

# _agent_vm_box <title> — print stdin on stderr as a boxed notice, for setup's
# warnings and offers: one paragraph per line, wrapped to the terminal (72
# columns at most). A question asked right after reads as being about the box.
# No right border: it would need every line padded to its display width, which
# bash and zsh count differently for non-ASCII text.
_agent_vm_box() {
  local title="$1" size width rule n
  size="$(stty size 2>/dev/null </dev/tty)"
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
    printf '  (must be a positive integer, e.g. 10 — got: %s)\n' "$reply" >&2
  done
}

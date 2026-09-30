# --- env: ~/.agent-vm/env and .agent-vm.env -----------------------------------

# Escape a value for a single-quoted shell literal: ' becomes '"'"'.
#
# Via sed, NOT `${v//\'/\'\"\'\"\'}`: bash 3.2 — what macOS ships — keeps the
# backslashes in the replacement half of that substitution and emits
# `O\'"\'"\'Brien`. The resulting line is a syntax error, and a shell sourcing
# ~/.agent-vm.env then abandons the WHOLE file, losing every secret in it, not
# just the one with the quote.
_agent_vm_sq_escape() {
  printf '%s' "$1" | sed "s/'/'\"'\"'/g"
}

# _agent_vm_env_read <file> <key> — print the value the file assigns to <key>,
# as a shell would, without running the shell.
# 0 = found (value on stdout) · 1 = not assigned · 3 = assigned with syntax
# this reader refuses to interpret.
#
# Accepted: optional leading `export `, then a value made of single-quoted
# parts (possibly spanning lines, as `set` writes a value with a newline),
# double-quoted parts with nothing to expand, and bare characters other than
# $ ` \ ; & | < > ( ) ~. A trailing `# comment` is allowed. The last
# assignment wins, like in the shell.
_agent_vm_env_read() {
  awk -v k="$2" -v q="'" '
    function parse(s,    v, c, e, more) {
      v = ""
      while (s != "") {
        c = substr(s, 1, 1)
        if (c == q) {
          s = substr(s, 2)
          while (!(e = index(s, q))) {
            if ((getline more) <= 0) { VAL = v; return 3 }
            v = v s "\n"; s = more
          }
          v = v substr(s, 1, e - 1); s = substr(s, e + 1)
        } else if (c == "\"") {
          s = substr(s, 2); e = index(s, "\"")
          if (!e || substr(s, 1, e - 1) ~ /[$`\\]/) { VAL = v; return 3 }
          v = v substr(s, 1, e - 1); s = substr(s, e + 1)
        } else if (c == " " || c == "\t") {
          VAL = v
          return (s ~ /^[ \t]+(#.*)?$/) ? 0 : 3
        } else if (index("$`\\;&|<>()~\r", c)) {
          VAL = v
          return (c == "\r" && s == "\r") ? 0 : 3
        } else {
          v = v c; s = substr(s, 2)
        }
      }
      VAL = v
      return 0
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/^export[ \t]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
      eq = index(line, "=")
      rc = parse(substr(line, eq + 1))
      if (substr(line, 1, eq - 1) == k) { found = 1; bad = rc; val = VAL }
    }
    END {
      if (!found) exit 1
      if (bad) exit 3
      printf "%s", val
    }
  ' "$1"
}

# _agent_vm_env_lines <list|drop> <file> [key]: walk the file's assignments,
# following a quoted value onto the lines it spans.
#   list  prints each assigned name, once per assignment
#   drop  prints the file without <key>'s assignments, whole
# A line inside a quoted value is never read as an assignment: `set` writes a
# value with a newline across lines, and a line of it that looks like
# `NAME=...` is data. Dropping only the first line of such a value would leave
# its tail behind, an unterminated quote that breaks the file for the shell
# that sources it.
_agent_vm_env_lines() {
  awk -v mode="$1" -v k="${3:-}" '
    function scan(s,    i, c, n) {
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (q == "\"") {
          if (c == "\\") i++
          else if (c == "\"") q = ""
          continue
        }
        if (c == "\\") i++
        else if (c == "\047" || c == "\"") q = c
        else if (c == "#" && i > 1 && substr(s, i - 1, 1) ~ /[ \t]/) return
      }
    }
    {
      if (q != "") {
        scan($0)
        if (mode == "drop" && !skip) print
        next
      }
      skip = 0
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/^export[ \t]+/, "", line)
      if (match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        name = substr(line, 1, RLENGTH - 1)
        if (mode == "list") print name
        if (name == k) skip = 1
        scan(substr(line, RLENGTH + 1))
      }
      if (mode == "drop" && !skip) print
    }
  ' "$2"
}

# Where this project's env file lives. Same shape as the runtime script
# (_agent_vm_project_runtime_path), same override rule: AGENT_VM_PROJECT_ENV holds it somewhere else (typically
# an integrator's own directory, ".mytool/env"), relative paths resolve against
# the project, absolute ones are used as-is.
#
# In the project, not in the state dir: a per-project value belongs with the
# project. It follows a clone, a move and a delete without the engine having to
# track which directory was which — and nothing outlives a project that is
# gone.
#
# The flip side, and it is on the integrator: this file is inside a git
# repository. Put a secret in it and it is one `git add` away from being
# published. Secrets shared by every VM belong in `agent-vm env`, which lives
# outside any repository.
_agent_vm_project_env_file() {
  local host_dir="${1:-$(pwd)}" rel="${AGENT_VM_PROJECT_ENV:-.agent-vm.env}"
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s\n' "${host_dir}/${rel}" ;;
  esac
}

# A project env file is a file in someone's repository, so the failure that
# matters is committing it. Say so when it is WRITTEN — the only moment the
# user is thinking about this file — and give the exact line that prevents it:
# a warning without the fix is just noise someone learns to scroll past.
#
# `git check-ignore` is the authority here: it accounts for .gitignore at every
# level, .git/info/exclude and the user's global excludes, none of which a grep
# over .gitignore would see. Exit 1 means "not ignored"; anything else (no
# repository, git missing, an error) is not something to lecture about.
#
# Already tracked is the worse case and a different fix: ignoring a tracked
# file changes nothing, git keeps staging its edits. Saying "add this line"
# there would be wrong advice.
_agent_vm_warn_unignored() {
  local file="$1" top rel rc=0 drive rest alt
  command -v git >/dev/null 2>&1 || return 0
  top="$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  rel="${file#"$top"/}"
  if [[ "$rel" == "$file" ]]; then
    # Git Bash spells the drive C:/... while the shell spells it /c/.... git
    # itself takes either form, but the string comparison above needs one.
    drive="${top%%:*}"; rest="${top#*:}"
    if [[ "$drive" =~ ^[A-Za-z]$ && "$rest" == /* ]]; then
      alt="/$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')$rest"
      rel="${file#"$alt"/}"
    fi
  fi
  # Still no common root (a worktree elsewhere, an odd spelling): not
  # something to lecture about.
  [[ "$rel" == "$file" ]] && return 0

  if git -C "$top" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    echo "Warning: $rel is tracked by git — its contents are in the repository." >&2
    echo "         git rm --cached '$rel' && echo '/$rel' >> .gitignore" >&2
    return 0
  fi

  git -C "$top" check-ignore -q "$file" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || return 0
  echo "Warning: $rel is not ignored by git — it can be committed by accident." >&2
  echo "         echo '/$rel' >> $top/.gitignore" >&2
}

# What gets pushed into a VM: the shared file first, this project's next.
# The guest sources it, so the last assignment wins and the project's value
# overrides the shared one. A function of its own so that order is testable
# without starting a VM — it is the whole meaning of "per project".
_agent_vm_env_payload() {
  local host_dir="${1:-$(pwd)}" project_env
  project_env="$(_agent_vm_project_env_file "$host_dir")"
  # The echo keeps a shared file with no trailing newline from gluing its last
  # line to the project's first one. CRs go: a CRLF file (Windows) would put
  # one at the end of every value in the guest.
  [ -f "$AGENT_VM_STATE_DIR/env" ] && { _agent_vm_strip_cr < "$AGENT_VM_STATE_DIR/env"; echo; }
  [ -f "$project_env" ] && _agent_vm_strip_cr < "$project_env"
  return 0
}

# Read, write and delete entries in ~/.agent-vm/env, the dotenv file pushed
# into the VM on every agent-vm command and auto-sourced there.
#
# Exists so integrators don't hand-roll the quoting: the file is *sourced* by a
# shell, so one bad escape costs every secret in it (see _agent_vm_sq_escape).
#
#   agent-vm env set KEY VALUE   replace or add KEY (value never echoed)
#   agent-vm env get KEY         print KEY's value
#   agent-vm env has KEY         exit 0 if KEY is set, 1 otherwise (no output)
#   agent-vm env unset KEY       remove KEY
#   agent-vm env list            print the key NAMES only, never the values
#
# Writes are atomic (temp file then mv) and the file is kept mode 600. Lines
# that do not assign KEY are preserved untouched.
#
# The same verbs serve `env` (one file for every VM) and `project-env`
# (one file per project). Same code for both on purpose: this file is SOURCED
# by the VM's shell, so the quoting and the atomic replace below are the whole
# point of the engine owning it. A second copy would be a second set of bugs.
_agent_vm_env() {
  local verb="$1" file="$2"; shift 2
  local action="${1:-list}"
  local key="${2:-}"

  case "$action" in
    set|get|has|unset)
      if [[ -z "$key" ]]; then
        echo "Error: 'agent-vm $verb $action' needs a KEY." >&2
        return 1
      fi
      # A key must be a shell-assignable name: anything else would produce a
      # line that breaks the file for every reader.
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Error: '$key' is not a valid environment variable name." >&2
        return 1
      fi ;;
  esac

  case "$action" in
    set)
      if [[ $# -lt 3 ]]; then
        echo "Error: 'agent-vm $verb set' needs a VALUE." >&2
        return 1
      fi
      local value="$3" tmp
      mkdir -p "$(dirname "$file")"
      tmp="$(mktemp "${file}.XXXXXX")"
      chmod 600 "$tmp"
      if [[ -f "$file" ]] && ! _agent_vm_env_lines drop "$file" "$key" > "$tmp"; then
        rm -f "$tmp"
        echo "Error: could not read $file" >&2
        return 1
      fi
      printf "%s='%s'\n" "$key" "$(_agent_vm_sq_escape "$value")" >> "$tmp"
      # A silently-dropped write here means the caller is told the secret was
      # stored when it was not — the worst possible failure for this file.
      if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        echo "Error: could not write $file" >&2
        return 1
      fi
      chmod 600 "$file"
      ;;
    unset)
      [[ -f "$file" ]] || return 0
      local tmp
      tmp="$(mktemp "${file}.XXXXXX")"
      chmod 600 "$tmp"
      if ! _agent_vm_env_lines drop "$file" "$key" > "$tmp"; then
        rm -f "$tmp"
        echo "Error: could not read $file" >&2
        return 1
      fi
      if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        echo "Error: could not write $file" >&2
        return 1
      fi
      chmod 600 "$file"
      ;;
    get|has)
      [[ -f "$file" ]] || return 1
      # Read, never source. The project file sits in a directory the VM can
      # write to, and sourcing it here would run whatever the agent put in it
      # on the host. Only the forms `set` writes and plain dotenv lines are
      # accepted; anything the shell would expand is refused, not evaluated.
      local value rc=0
      value="$(_agent_vm_env_read "$file" "$key")" || rc=$?
      case "$rc" in
        0) ;;
        1) return 1 ;;
        *)
          echo "Error: $key in $file uses shell syntax agent-vm does not evaluate" >&2
          echo "  (\$, backquotes, backslashes, ~, ;, | ...). Rewrite it with 'agent-vm $verb set'." >&2
          return 2 ;;
      esac
      [[ "$action" == "has" ]] && return 0
      printf '%s\n' "$value"
      ;;
    list)
      [[ -f "$file" ]] || return 0
      # Names only — never values, so this stays safe to paste into an issue.
      _agent_vm_env_lines list "$file" | awk '!seen[$0]++'
      ;;
    *)
      echo "Usage: agent-vm $verb {set KEY VALUE|get KEY|has KEY|unset KEY|list}" >&2
      return 1 ;;
  esac
}

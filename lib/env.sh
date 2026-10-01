# --- env: ~/.agent-vm/env and .agent-vm.env -----------------------------------

# Escape a value for a single-quoted shell literal: ' becomes '"'"'.
#
# Via sed, NOT `${v//\'/\'\"\'\"\'}`: bash 3.2, what macOS ships, keeps the
# backslashes in the replacement half of that substitution and emits
# `O\'"\'"\'Brien`. The resulting line is a syntax error, and a shell sourcing
# ~/.agent-vm.env then abandons the WHOLE file, losing every secret in it, not
# just the one with the quote.
_agent_vm_sq_escape() {
  printf '%s' "$1" | sed "s/'/'\"'\"'/g"
}

# _agent_vm_env_read <file> <key>: print the value the file assigns to <key>,
# as a shell would, without running the shell.
# 0 = found (value on stdout) · 1 = not assigned · 3 = assigned with syntax
# this reader refuses to interpret.
#
# Accepted: optional leading `export `, then a value made of single-quoted
# parts (possibly spanning lines, as `set` writes a value with a newline),
# double-quoted parts with nothing to expand, and bare characters other than
# $ ` \ ; & | < > ( ) ~. A trailing `# comment` is allowed. The last
# assignment wins, like in the shell.
#
# One line refused, and no key can be answered: a quote left open or a
# trailing backslash makes the shell read the next lines as part of that
# value, and other syntax can run anything, an assignment to any key before
# or after it included (eval, typeset, a sourced file). A line that is not an
# assignment, a comment or blank counts as refused.
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
      if (broken) next
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line ~ /^(#.*)?\r?$/) next
      sub(/^export[ \t]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { broken = 1; next }
      eq = index(line, "=")
      if (parse(substr(line, eq + 1))) { broken = 1; next }
      if (substr(line, 1, eq - 1) == k) { found = 1; val = VAL }
    }
    END {
      if (broken) exit 3
      if (!found) exit 1
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
        # $'"'"'...'"'"': backslash escapes, a quote among them included.
        if (q == "$") {
          if (c == "\\") i++
          else if (c == "\047") q = ""
          continue
        }
        if (q == "\"") {
          if (c == "\\") i++
          else if (c == "\"") q = ""
          continue
        }
        if (c == "\\") i++
        else if (c == "$" && substr(s, i + 1, 1) == "\047") { q = "$"; i++ }
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

# _agent_vm_project_path <dir> <path>: a project file's path, <path> taken
# relative to the project <dir> unless absolute. An integrator moves the env
# file and the runtime script into its own directory (".mytool/env") with
# AGENT_VM_PROJECT_ENV and AGENT_VM_PROJECT_RUNTIME.
_agent_vm_project_path() {
  case "$2" in
    /*) _agent_vm_path_join / "$2" ;;
    *)  _agent_vm_path_join "$1" "$2" ;;
  esac
}

# This project's env file: in the project, so it follows a clone, a move and
# a delete, and one `git add` away from being published (secrets shared by
# every VM belong in `agent-vm env`).
_agent_vm_project_env_file() {
  _agent_vm_project_path "${1:-$(pwd)}" "${AGENT_VM_PROJECT_ENV:-.agent-vm.env}"
}

# _agent_vm_path_join <dir> <path>: <dir>/<path>, with `.` and `..` resolved in
# the text, as `cd` does. Whether a project file is read by the host or by the
# VM depends on whether it is inside the project (_agent_vm_in_project): a
# path that only goes through the project on its way out of it (`../x`) names
# a file outside, which the VM cannot see.
_agent_vm_path_join() {
  local out="${1%/}" rest="$2/" comp
  while [[ -n "$rest" ]]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    case "$comp" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *)  out="$out/$comp" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}

# After `project-env set`: warns, with the line that fixes it, when the file
# is tracked by git (rm --cached, then ignore) or not ignored (ignore), as
# `git check-ignore` sees it. Silent without a repository or git. git runs in
# a directory the VM can write: see _agent_vm_git_untrusted.
_agent_vm_warn_unignored() {
  local file="$1" top rel rc=0 drive rest alt
  command -v git >/dev/null 2>&1 || return 0
  top="$(_agent_vm_git_untrusted -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)" || return 0
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

  # The printed lines work from any directory, the project one being possibly
  # below the top of the repository: paths are relative to the top, and quoted.
  local q_top q_rel
  q_top="$(_agent_vm_sq_escape "$top")"
  q_rel="$(_agent_vm_sq_escape "$rel")"
  if _agent_vm_git_untrusted -C "$top" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    echo "Warning: $rel is tracked by git: its contents are in the repository." >&2
    echo "         git -C '$q_top' rm --cached '$q_rel' && echo '/$q_rel' >> '$q_top/.gitignore'" >&2
    return 0
  fi

  _agent_vm_git_untrusted -C "$top" check-ignore -q "$file" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || return 0
  echo "Warning: $rel is not ignored by git: it can be committed by accident." >&2
  echo "         echo '/$q_rel' >> '$q_top/.gitignore'" >&2
}

# _agent_vm_project_rel <dir> <path>: when <path> is inside the project
# directory <dir>, where the VM can write, print it relative to <dir> and
# return 0. The host must not read such a file by its path: the VM can make it
# a symlink, and the host would follow it to any file of the user's and hand
# the content over. It is read in the VM instead, by <dir>/<rel>, where a link
# resolves among the VM's own files (see _agent_vm_push_env_and_probe), or
# with _agent_vm_nofollow.
#
# Inside by its spelling, or by where it leads: the project reached through a
# link of the user's, the other spelling of a linked directory (/tmp and
# /private/tmp on macOS), another case where the file system ignores it. So
# <path> is resolved one component at a time, links followed one hop at a
# time, and the first step that reaches the project decides, before anything
# in it is followed: the rest is in the project, and goes through
# _agent_vm_nofollow or the VM, which follow none of the VM's links on the
# host. Before that point, every link is outside the project, where the VM
# cannot change it.
_agent_vm_project_rel() {
  local dir="${1%/}" target="$2" pdir cur="" next cmp rest comp t hops=0 r
  if [[ "$target" == "$dir/"* ]]; then
    printf '%s\n' "${target#"$dir"/}"
    return 0
  fi
  pdir="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd)" || return 1
  [[ -n "$pdir" ]] || return 1
  pdir="$(_agent_vm_fold "$pdir")"
  rest="${target#/}/"
  while [[ -n "$rest" ]]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    case "$comp" in
      ""|.) continue ;;
      ..) cur="${cur%/*}"; continue ;;
    esac
    next="$cur/$comp"
    cmp="$(_agent_vm_fold "$next")"
    if [[ "$cmp" == "$pdir" || "$cmp" == "$pdir/"* ]]; then
      r="${next:$((${#pdir} + 1))}/${rest%/}"
      r="${r#/}"
      printf '%s\n' "${r%/}"
      return 0
    fi
    if [[ -L "$next" ]]; then
      hops=$((hops + 1))
      [[ $hops -gt 40 ]] && return 1
      t="$(readlink "$next")" || return 1
      [[ "$t" == /* ]] && cur=""
      rest="${t#/}/$rest"
      continue
    fi
    cur="$next"
  done
  return 1
}

# 0 when <path> is inside the project directory <dir> (see
# _agent_vm_project_rel).
_agent_vm_in_project() {
  _agent_vm_project_rel "$1" "$2" >/dev/null
}

# What gets pushed into a VM: the shared file first, this project's next.
# The guest sources it, so the last assignment wins and the project's value
# overrides the shared one. A function of its own so that order is testable
# without starting a VM: it is the whole meaning of "per project".
#
# The project's file is only in here when AGENT_VM_PROJECT_ENV puts it outside
# the project. Inside, the VM reads it and appends it (see
# _agent_vm_in_project).
_agent_vm_env_payload() {
  local host_dir="${1:-$(pwd)}" project_env
  project_env="$(_agent_vm_project_env_file "$host_dir")"
  # The echo keeps a shared file with no trailing newline from gluing its last
  # line to the project's first one. CRs go: a CRLF file (Windows) would put
  # one at the end of every value in the guest.
  [ -f "$AGENT_VM_STATE_DIR/env" ] && { _agent_vm_strip_cr < "$AGENT_VM_STATE_DIR/env"; echo; }
  if ! _agent_vm_in_project "$host_dir" "$project_env" && [ -f "$project_env" ]; then
    _agent_vm_strip_cr < "$project_env"
  fi
  return 0
}

# _agent_vm_nofollow <read|write|mkdir|touch> <dir> <rel>: print the file
# <dir>/<rel>, replace it with stdin, make it a directory (mkdir -p), or make
# it an empty file unless it is one already, following no symlink below <dir>:
# the one way the host touches the project, which the VM can write. Through a link
# planted there, a plain read would copy any file of the user's into the
# project, and a write could land anywhere. Checking for links first is not
# enough: the VM can swap one in between the check and the use.
#
# So each directory is entered and checked to be the one lstat saw, the file
# is opened with O_NOFOLLOW (and O_NONBLOCK, so a FIFO cannot hang it), and a
# write goes to a new file renamed over the old one, which replaces a link
# rather than following it. Perl, because the shell can do none of this.
# Missing directories are created except on a read. A file written is mode
# 600; one made by touch has the umask's mode, like `: > file`.
#
# Status: 0 done, 1 no such file (read), 3 a symlink or something other than a
# directory or a regular file on the way, 2 any other failure.
_agent_vm_nofollow() {
  if ! command -v perl >/dev/null 2>&1; then
    echo "Error: perl is needed to use a file in the project without following symlinks." >&2
    return 2
  fi
  perl -e '
    use strict;
    use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK);
    my ($op, $top, $rel) = @ARGV;
    chdir $top or exit 2;
    my @dirs = grep { $_ ne "" && $_ ne "." } split m{/}, $rel;
    my $name = pop @dirs;
    exit 3 if !defined $name || grep { $_ eq ".." } @dirs, $name;
    push @dirs, $name if $op eq "mkdir";
    for my $d (@dirs) {
      my @l = lstat $d;
      if (!@l) {
        exit 1 if $op eq "read";
        mkdir $d or exit 2;
        @l = lstat $d or exit 2;
      }
      exit 3 unless -d _;
      chdir $d or exit 2;
      my @s = stat ".";
      exit 3 unless @s && $s[0] == $l[0] && $s[1] == $l[1];
    }
    exit 0 if $op eq "mkdir";
    if ($op eq "touch") {
      if (lstat $name) {
        exit(-f _ ? 0 : 3);
      }
      sysopen(my $new, $name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0666) or exit 2;
      close $new;
      exit 0;
    }
    local $/;
    if ($op eq "read") {
      sysopen(my $in, $name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit($!{ENOENT} ? 1 : 3);
      exit 3 unless -f $in;
      binmode $in; binmode STDOUT;
      my $data = <$in>;
      print $data if defined $data;
      exit 0;
    }
    binmode STDIN;
    my $data = <STDIN>;
    $data = "" unless defined $data;
    my ($tmp, $out);
    for (1 .. 20) {
      $tmp = sprintf ".%s.agent-vm.%d.%d", $name, $$, int rand 1e9;
      last if sysopen $out, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600;
      undef $out;
    }
    exit 2 unless $out;
    binmode $out;
    unless ((print {$out} $data) && close $out && rename $tmp, $name) {
      unlink $tmp;
      exit 2;
    }
    exit 0;
  ' "$@"
}

# _agent_vm_env_file <read|write> <file> <top>: an env file, read to stdout or
# replaced with stdin. With <top> set, <file> is inside that project directory
# and goes through _agent_vm_nofollow. Without, it is one of the user's own
# (~/.agent-vm/env, or a project file kept outside the project), used as is.
# Status as _agent_vm_nofollow's.
_agent_vm_env_file() {
  local op="$1" file="$2" top="$3" tmp
  if [[ -n "$top" ]]; then
    _agent_vm_nofollow "$op" "$top" "${file#"${top%/}"/}"
    return
  fi
  if [[ "$op" == read ]]; then
    [[ -f "$file" ]] || return 1
    cat "$file" || return 2
    return 0
  fi
  mkdir -p "$(dirname "$file")" || return 2
  tmp="$(mktemp "${file}.XXXXXX")" || return 2
  chmod 600 "$tmp"
  if cat >| "$tmp" && mv "$tmp" "$file"; then
    chmod 600 "$file"
    return 0
  fi
  rm -f "$tmp"
  return 2
}

# `env` (~/.agent-vm/env) and `project-env`: set, get, has, unset, list, on a
# file the VM's shell sources, so the quoting is done here, once (see
# _agent_vm_sq_escape). Writes are atomic and mode 600, other lines kept as
# they are; list prints names, never values.
# Usage: _agent_vm_env <verb> <file> <top> [action [KEY [VALUE]]], <top> being
# the project directory when <file> is inside it (see _agent_vm_env_file).
# The file is read into a variable, never a temporary file: it holds secrets.
_agent_vm_env() {
  local verb="$1" file="$2" top="$3"; shift 3
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
    list) ;;
    *)
      echo "Usage: agent-vm $verb {set KEY [VALUE]|get KEY|has KEY|unset KEY|list}" >&2
      return 1 ;;
  esac
  # A word too many is refused: `set TOKEN my secret` would store "my".
  local max=2
  case "$action" in
    set) max=3 ;;
    list) max=1 ;;
  esac
  if [[ $# -gt $max ]]; then
    echo "Error: too many arguments for 'agent-vm $verb $action'. Quote a value with spaces." >&2
    echo "Usage: agent-vm $verb {set KEY [VALUE]|get KEY|has KEY|unset KEY|list}" >&2
    return 1
  fi
  # Without VALUE, `set` reads it from stdin, typed without echo on a
  # terminal: a value on the command line lands in the shell history and in
  # `ps`. From a pipe, one trailing newline goes, as `echo` adds it.
  local set_value=""
  if [[ "$action" == set ]]; then
    if [[ $# -ge 3 ]]; then
      set_value="$3"
    elif [[ -t 0 ]]; then
      printf 'Value for %s (not shown): ' "$key" >&2
      IFS= read -rs set_value || set_value=""
      printf '\n' >&2
    else
      set_value="$(cat; printf x)"
      set_value="${set_value%x}"
      set_value="${set_value%$'\n'}"
    fi
    if [[ $# -lt 3 && -z "$set_value" ]]; then
      echo "Error: 'agent-vm $verb set $key' needs a VALUE, as an argument or on stdin." >&2
      return 1
    fi
  fi

  # The x keeps the file's trailing newlines, which $(...) would strip.
  local content have=1 st=0
  content="$(_agent_vm_env_file read "$file" "$top" && printf x)" || st=$?
  content="${content%x}"
  case "$st" in
    0) ;;
    1) have="" ;;
    3)
      echo "Error: $file is a symlink, is reached through one, or is not a regular file." >&2
      echo "  agent-vm follows no link in the project, which the VM can write. Replace it with a plain file." >&2
      return 2 ;;
    *)
      echo "Error: could not read $file" >&2
      return 2 ;;
  esac

  case "$action" in
    set|unset)
      [[ "$action" == unset && -z "$have" ]] && return 0
      local new
      new="$(printf '%s' "$content" | _agent_vm_env_lines drop - "$key" && printf x)" || {
        echo "Error: could not read $file" >&2
        return 1
      }
      new="${new%x}"
      if [[ "$action" == set ]]; then
        new="$new$(printf "%s='%s'" "$key" "$(_agent_vm_sq_escape "$set_value")")"$'\n'
      fi
      # A silently-dropped write here means the caller is told the secret was
      # stored when it was not, the worst possible failure for this file.
      if ! printf '%s' "$new" | _agent_vm_env_file write "$file" "$top"; then
        echo "Error: could not write $file" >&2
        return 1
      fi
      ;;
    get|has)
      [[ -n "$have" ]] || return 1
      # Read, never source. The project file sits in a directory the VM can
      # write to, and sourcing it here would run whatever the agent put in it
      # on the host. Only the forms `set` writes and plain dotenv lines are
      # accepted; anything the shell would expand is refused, not evaluated.
      local value rc=0
      value="$(printf '%s' "$content" | _agent_vm_env_read - "$key")" || rc=$?
      case "$rc" in
        0) ;;
        1) return 1 ;;
        *)
          echo "Error: $key in $file uses, or comes after, shell syntax agent-vm does not evaluate" >&2
          echo "  (\$, backquotes, backslashes, ~, ;, | ...). Rewrite it with 'agent-vm $verb set'." >&2
          return 2 ;;
      esac
      [[ "$action" == "has" ]] && return 0
      printf '%s\n' "$value"
      ;;
    list)
      [[ -n "$have" ]] || return 0
      # Names only, never values: safe to paste into an issue.
      printf '%s' "$content" | _agent_vm_env_lines list - | awk '!seen[$0]++'
      ;;
  esac
}

# =============================================================================
section "env: the shared secrets file"
# =============================================================================
# This file is SOURCED by the VM's shell, so one bad escape costs every secret
# in it — not just the one that was mis-quoted. That is why the quoting lives
# here rather than in each integrator.
ENVHOME="$SB/envhome"; mkdir -p "$ENVHOME"
avenv() { HOME="$ENVHOME" bash "$AGENT_VM_SH" env "$@"; }

avenv set ALBERT_API_KEY "k1" >/dev/null
avenv set AC_GIT_USER_NAME "O'Brien" >/dev/null
check "get returns the value"        "$(avenv get ALBERT_API_KEY)" "k1"
check "a single quote survives"      "$(avenv get AC_GIT_USER_NAME)" "O'Brien"
avenv set ALBERT_API_KEY "k2" >/dev/null
check "rotation replaces, not appends" "$(grep -c '^ALBERT_API_KEY=' "$ENVHOME/.agent-vm/env")" "1"
check "rotation keeps the fresh value" "$(avenv get ALBERT_API_KEY)" "k2"
check "the quoted entry still reads back" "$(avenv get AC_GIT_USER_NAME)" "O'Brien"

printf 'SOMEONE_ELSE=keep-me\n' >> "$ENVHOME/.agent-vm/env"
avenv set ALBERT_API_KEY "k3" >/dev/null
check "unmanaged lines are preserved" "$(grep -c '^SOMEONE_ELSE=keep-me$' "$ENVHOME/.agent-vm/env")" "1"

avenv has ALBERT_API_KEY && pass "has: present key" || fail "has: present key"
avenv has NOPE_NOT_HERE && fail "has: absent key" || pass "has: absent key"

# `has`/`get` must answer about the FILE. The subshell inherits this shell's
# environment, so without unsetting first, a merely-exported variable reads as
# stored — and agent-vm's own callers often run inside a VM that exports these.
if HOME="$ENVHOME" AMBIENT_ONLY=x bash "$AGENT_VM_SH" env has AMBIENT_ONLY; then
  fail "has must ignore the ambient environment"
else
  pass "has ignores the ambient environment"
fi

check "list prints names only" "$(avenv list | sort | tr '\n' ' ')" "AC_GIT_USER_NAME ALBERT_API_KEY SOMEONE_ELSE "
if avenv list | grep -q "O'Brien\|k3"; then fail "list must never print values"; else pass "list never prints values"; fi

avenv unset ALBERT_API_KEY >/dev/null
avenv has ALBERT_API_KEY && fail "unset removed the key" || pass "unset removes the key"
check "unset keeps the others" "$(grep -c '^SOMEONE_ELSE=' "$ENVHOME/.agent-vm/env")" "1"
# Permission bits are emulated on Windows: the engine still chmods, but
# ls cannot show a mode the filesystem does not have.
if _agent_vm_on_windows; then
  printf '  skip file is mode 600 (permission bits are emulated on Windows)\n'
else
check "file is mode 600" "$(ls -l "$ENVHOME/.agent-vm/env" | cut -c2-10)" "rw-------"
fi

if avenv set "not-a-name" x >/dev/null 2>&1; then
  fail "an invalid variable name must be rejected"
else
  pass "an invalid variable name is rejected"
fi

# The file has to survive being sourced the way the VM sources it.
val="$(set -a; . "$ENVHOME/.agent-vm/env"; set +a; printf '%s' "${AC_GIT_USER_NAME:-BROKEN}")"
check "the file sources cleanly in a shell" "$val" "O'Brien"

# =============================================================================
section "state dir: overridable, and published"
# =============================================================================
# Integrators must not rebuild this path from $HOME. They can only stop doing
# that if the engine both publishes it and honours an override.
STATE_ALT="$SB/state-alt"
check "AGENT_VM_STATE_DIR is honoured" \
  "$(AGENT_VM_STATE_DIR="$STATE_ALT" bash "$AGENT_VM_SH" info "$SB" | sed -n 's/^state_dir=//p')" \
  "$STATE_ALT"
AGENT_VM_STATE_DIR="$STATE_ALT" bash "$AGENT_VM_SH" env set SOME_KEY v >/dev/null
if [ -f "$STATE_ALT/env" ]; then
  pass "writes land in the overridden state dir"
else
  fail "the override is published but not used for writes"
fi

# =============================================================================
section "project-env: one env per project"
# =============================================================================
# Same file format and same quoting as the shared env — deliberately the same
# code — but it lives WITH the project, like the project runtime script, and
# moves, clones and disappears with it.
PENV="$SB/penv"; mkdir -p "$PENV/pa/.mytool" "$PENV/pb" "$PENV/state"
pe() { ( cd "$1" && AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" project-env "${@:2}" ); }

pe "$PENV/pa" set OPENCODE_CONFIG "/a/.albert-code/opencode.json" >/dev/null
pe "$PENV/pb" set OPENCODE_CONFIG "/b/.albert-code/opencode.json" >/dev/null
check "each project keeps its own value (a)" "$(pe "$PENV/pa" get OPENCODE_CONFIG)" "/a/.albert-code/opencode.json"
check "each project keeps its own value (b)" "$(pe "$PENV/pb" get OPENCODE_CONFIG)" "/b/.albert-code/opencode.json"
check "the file sits in the project, at the documented default" \
  "$(ls -A "$PENV/pa" | grep '^\.agent-vm\.env$')" ".agent-vm.env"
if [ -z "$(ls -A "$PENV/state" 2>/dev/null)" ]; then
  pass "nothing about a project is written into the state dir"
else
  fail "project state leaked outside the project: $(ls -A "$PENV/state" | tr '\n' ' ')"
fi
pe "$PENV/pa" set NAME "O'Brien" >/dev/null
check "the shared quoting applies here too" "$(pe "$PENV/pa" get NAME)" "O'Brien"
if _agent_vm_on_windows; then
  printf '  skip file is mode 600 (permission bits are emulated on Windows)\n'
else
check "the file is mode 600" "$(ls -l "$PENV/pa/.agent-vm.env" | cut -c2-10)" "rw-------"
fi
if pe "$PENV/pa" list | grep -q "O'Brien"; then fail "list must never print values"; else pass "list never prints values"; fi

# AGENT_VM_PROJECT_ENV, like AGENT_VM_PROJECT_RUNTIME: an integrator keeps its
# files in its own directory instead of cluttering the project root.
_pe_alt() { ( cd "$PENV/pa" && AGENT_VM_PROJECT_ENV=.mytool/env AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" project-env "$@" ); }
_pe_alt set OPENCODE_CONFIG "/elsewhere" >/dev/null
check "AGENT_VM_PROJECT_ENV relocates the file" "$(cat "$PENV/pa/.mytool/env")" "OPENCODE_CONFIG='/elsewhere'"
check "and the default file is untouched by it" "$(pe "$PENV/pa" get OPENCODE_CONFIG)" "/a/.albert-code/opencode.json"
check "info publishes the path, so nobody rebuilds it" \
  "$( ( cd "$PENV/pa" && AGENT_VM_PROJECT_ENV=.mytool/env AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" info | sed -n 's/^project_env=//p' ) )" \
  "$PENV/pa/.mytool/env"

# Precedence: the payload pushed into the VM is shared-then-project, because it
# is sourced — so a key set in both ends up with the project's value. Without
# this order, "per project" would mean nothing.
( AGENT_VM_STATE_DIR="$PENV/state"
  mkdir -p "$AGENT_VM_STATE_DIR"
  printf "SHARED_ONLY='s'\nBOTH='shared'\n" > "$AGENT_VM_STATE_DIR/env"
  printf "BOTH='project'\n" > "$PENV/pa/.agent-vm.env"
  payload="$(_agent_vm_env_payload "$PENV/pa")"
  val="$(set -a; eval "$payload"; set +a; printf '%s' "${BOTH:-MISSING}")"
  shared="$(set -a; eval "$payload"; set +a; printf '%s' "${SHARED_ONLY:-MISSING}")"
  [ "$val" = "project" ] || { echo "      BOTH=$val" >&2; exit 1; }
  [ "$shared" = "s" ] || { echo "      SHARED_ONLY=$shared" >&2; exit 1; } )
if [ $? -eq 0 ]; then
  pass "the project's value wins, and shared keys still come through"
else
  fail "wrong precedence between the shared env and the project env"
fi
# A shared file without a trailing newline must not glue onto the project's.
( AGENT_VM_STATE_DIR="$PENV/state"
  printf "SHARED_LAST='s'" > "$AGENT_VM_STATE_DIR/env"
  printf "BOTH='project'\n" > "$PENV/pa/.agent-vm.env"
  payload="$(_agent_vm_env_payload "$PENV/pa")"
  printf '%s\n' "$payload" | grep -qx "BOTH='project'" )
check "a shared file with no final newline stays separate" "$?" "0"

# =============================================================================
section "project-env: the file is in a repository, so say so"
# =============================================================================
# The failure that matters for this file is committing it. The warning has to
# name the fix, and the fix has to work — a printed line nobody can apply is
# worse than no warning.
if command -v git >/dev/null 2>&1; then
  GI="$SB/gitrepo"; mkdir -p "$GI"
  ( cd "$GI" && git init -q && git config user.email t@t && git config user.name t )
  gpe() { ( cd "$GI" && AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" project-env "$@" ); }

  err_out="$(gpe set K v 2>&1 >/dev/null)"
  case "$err_out" in
    *"not ignored by git"*) pass "warns when the file is not ignored" ;;
    *) fail "no warning on an unignored file: $err_out" ;;
  esac
  check "the warning stays on stderr" "$(gpe set K v 2>/dev/null)" ""

  # The printed line, applied verbatim, must silence the warning.
  line="$(printf '%s\n' "$err_out" | sed -n 's/^ *echo //p' | sed "s/ >>.*//; s/^'//; s/'$//")"
  printf '%s\n' "$line" >> "$GI/.gitignore"
  if [ -n "$(gpe set K v2 2>&1 >/dev/null)" ]; then
    fail "the suggested line does not silence the warning: $(gpe set K v2 2>&1 >/dev/null)"
  else
    pass "the suggested line is the one that fixes it"
  fi

  # .git/info/exclude counts too — a grep over .gitignore would miss it.
  rm -f "$GI/.gitignore"
  printf '.agent-vm.env\n' >> "$GI/.git/info/exclude"
  if [ -n "$(gpe set K v3 2>&1 >/dev/null)" ]; then
    fail "warns although .git/info/exclude covers the file"
  else
    pass "an exclude outside .gitignore is honoured"
  fi

  # Already tracked: ignoring changes nothing, so the advice must differ.
  : > "$GI/.git/info/exclude"
  ( cd "$GI" && git add -f .agent-vm.env >/dev/null 2>&1 )
  case "$(gpe set K v4 2>&1 >/dev/null)" in
    *"tracked by git"*) pass "a tracked file gets the fix that actually applies" ;;
    *) fail "a tracked file must not be told to add a gitignore line" ;;
  esac

  # Outside a repository there is nothing to warn about.
  OUTSIDE="$SB/outside"; mkdir -p "$OUTSIDE"
  if [ -n "$( ( cd "$OUTSIDE" && AGENT_VM_STATE_DIR="$PENV/state" bash "$AGENT_VM_SH" project-env set K v ) 2>&1 >/dev/null )" ]; then
    fail "warns outside a git repository"
  else
    pass "silent outside a git repository"
  fi
else
  echo "  (git absent: gitignore warning not exercised)"
fi

# =============================================================================
section "project-env: Git Bash drive-letter spellings"
# =============================================================================
# git spells the top C:/... while the shell spells the file /c/.... A fake git
# answers all three invocations with canned replies, so this runs everywhere:
# untracked, then unignored, so the warning must fire with the repo-relative
# name and a suggestion line that names it too.
mkdir -p "$SB/fakedrive"
cat > "$SB/fakedrive/git" <<'STUB'
#!/bin/sh
case "$*" in
  *rev-parse*) echo "C:/proj" ;;
  *ls-files*) exit 1 ;;
  *check-ignore*) exit 1 ;;
esac
STUB
chmod +x "$SB/fakedrive/git"
drive_err="$(PATH="$SB/fakedrive:$PATH" _agent_vm_warn_unignored "/c/proj/.agent-vm.env" 2>&1 >/dev/null)"
case "$drive_err" in
  *"Warning: .agent-vm.env is not ignored"*) pass "C:/ top over a /c/ file still warns, with the relative name" ;;
  *) fail "drive-letter mismatch silenced the warning: $drive_err" ;;
esac
case "$drive_err" in
  *"echo '/.agent-vm.env' >> C:/proj/.gitignore"*) pass "the suggested line names the relative file" ;;
  *) fail "the suggested line is not applicable: $drive_err" ;;
esac

section "setup options"
case "$(agent-vm setup --reset 2>&1 </dev/null)" in
  *"Unknown option: --reset"*) pass "setup rejects --reset instead of ignoring it" ;;
  *) fail "setup accepted --reset" ;;
esac
for opt in --rm --scratch "--ssh-port=2300"; do
  case "$(agent-vm setup "$opt" 2>&1 </dev/null)" in
    *"Unknown option: ${opt%%=*}"*) pass "setup rejects $opt" ;;
    *) fail "setup accepted $opt" ;;
  esac
done
case "$(agent-vm setup --disk 10G 2>&1 </dev/null)" in *"--disk must be a positive integer"*) pass "setup: a bad value is said" ;; *) fail "setup --disk 10G accepted" ;; esac

# A value option at the end is one clear error, also under a caller's set -u.
for opt in --disk --memory --cpus; do
  out="$( (set -u; agent-vm setup "$opt") 2>&1 </dev/null)"
  case "$?:$out" in
    1:"Error: $opt needs a value.") pass "setup $opt without a value: said" ;;
    *) fail "setup $opt without a value: $out" ;;
  esac
done

section "setup wizard: the opt-in components default to no"
# Pressing Enter at every per-component prompt must give the default set's
# languages: Ruby, Rust and Go stay out, like Pi and Playwright MCP.
mkdir -p "$SB/wizlima"
cat > "$SB/wizlima/limactl" <<STUB
#!/bin/sh
case "\$1" in
  shell) cat > "$SB/wizard.stdin" ;;
  list) [ "\$2" = -q ] && echo agent-vm-base ;;
esac
exit 0
STUB
chmod +x "$SB/wizlima/limactl"
( PATH="$SB/wizlima:$PATH"; AGENT_VM_STATE_DIR="$SB/wizstate"
  _agent_vm_have_tty() { return 0; }
  _agent_vm_ask_yn() {
    case "$1" in
      "Use this default") echo 0 ;;
      "Use these defaults") echo 1 ;;
      *) case "$2" in [Yy]) echo 1 ;; *) echo 0 ;; esac ;;
    esac
  }
  _agent_vm_offer_git_protection() { :; }
  _agent_vm_setup ) >/dev/null 2>&1
check "wizard defaults: Ruby, Rust, Go, Pi and Playwright MCP off; Claude on" \
  "$(grep -E '^export AGENT_VM_INSTALL_(RUBY|RUST|GOLANG|PI|MCP_PLAYWRIGHT|CLAUDE)=' "$SB/wizard.stdin" 2>/dev/null | cut -d_ -f4- | tr '\n' ' ')" \
  "RUBY=0 RUST=0 GOLANG=0 CLAUDE=1 PI=0 MCP_PLAYWRIGHT=0 "

section "release.sh"
REL="$SELF_DIR/release.sh"
notes="$("$REL" notes "$AGENT_VM_VERSION" 2>&1)"
case "$notes" in
  ""|*"has no '## "*) fail "CHANGELOG.md has no section for $AGENT_VM_VERSION, the version agent-vm.sh reports" ;;
  *) pass "CHANGELOG.md has a section for $AGENT_VM_VERSION" ;;
esac
# On a changelog of our own: the section stops at the next heading and loses
# its surrounding blank lines.
mkdir -p "$SB/rel"
cp "$REL" "$SB/rel/release.sh"
printf '# Changelog\n\n## 2.0.0\n\n- two\n\n## 1.0.0\n\n- one\n' > "$SB/rel/CHANGELOG.md"
check "notes: only that version's section" "$("$SB/rel/release.sh" notes 2.0.0)" "- two"
check "notes: the last section too"        "$("$SB/rel/release.sh" notes 1.0.0)" "- one"
"$SB/rel/release.sh" notes 3.0.0 >/dev/null 2>&1
check "notes: an absent version fails" "$?" "1"
"$REL" 1.2 >/dev/null 2>&1
check "a malformed version is refused before anything else" "$?" "1"
"$REL" >/dev/null 2>&1
check "no argument prints the usage (exit 2)" "$?" "2"

# The tarball is what an install runs: not the site, not the tests. Worktree
# attributes, so this checks the .gitattributes being committed.
if git -C "$SELF_DIR" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  listing="$(git -C "$SELF_DIR" archive --worktree-attributes --format=tar --prefix=x/ HEAD | tar -tf - 2>/dev/null)"
  check "release tarball: no www/, tests/, test.sh or test-e2e.sh" \
    "$(printf '%s\n' "$listing" | grep -cE '^x/(www/|tests/|test\.sh$|test-e2e\.sh$)')" "0"
  check "release tarball: agent-vm.sh, lib/ and the setup script" \
    "$(printf '%s\n' "$listing" | grep -cxE 'x/(agent-vm\.sh|lib/env\.sh|agent-vm\.setup\.sh)')" "3"
else
  printf '  skip release tarball contents (not a git checkout)\n'
fi

# A run that pushed the tag and then failed to publish is picked up again,
# rather than stuck on "tag already exists". Against a throwaway repository,
# its origin a bare one, and a stub gh.
if command -v git >/dev/null 2>&1; then
  RR="$SB/relrepo"; RO="$SB/relorigin.git"; RB="$SB/relbin"
  mkdir -p "$RR/www/public" "$RR/tests" "$RB"
  cp -R "$SELF_DIR/agent-vm.sh" "$SELF_DIR/lib" "$SELF_DIR/agent-vm.setup.sh" "$SELF_DIR/install.sh" \
    "$SELF_DIR/runtime.example.sh" "$SELF_DIR/test-e2e.sh" "$SELF_DIR/release.sh" "$SELF_DIR/CHANGELOG.md" "$RR/"
  cp "$SELF_DIR/www/public/install.sh" "$RR/www/public/"
  printf '#!/bin/sh\nexit 0\n' > "$RR/test.sh"; chmod +x "$RR/test.sh"
  : > "$RR/tests/helpers.sh"
  cat > "$RB/gh" <<STUB
#!/bin/sh
case "\$1 \$2" in
  "run list") echo "completed success" ;;
  "release view") [ -e "$SB/rel-released" ] ;;
  "repo view") echo "o/r" ;;
esac
STUB
  chmod +x "$RB/gh"
  ( cd "$RR" && git init -q && git checkout -q -b main && git add -A \
      && git -c user.name=t -c user.email=t@t commit -qm r \
      && git init -q --bare "$RO" && git remote add origin "$RO" && git push -q origin main \
      && git -c user.name=t -c user.email=t@t tag -a "v$AGENT_VM_VERSION" -m t && git push -q origin "v$AGENT_VM_VERSION" ) >/dev/null 2>&1
  relrun() { ( cd "$RR" && PATH="$RB:$PATH" bash ./release.sh "$AGENT_VM_VERSION" --dry-run ) 2>&1; }
  rm -f "$SB/rel-released"
  out="$(relrun)"
  case "$out" in
    *"with no release: resuming"*"dry run complete"*) pass "release.sh: a tag with no release is resumed" ;;
    *) fail "release.sh resume: $out" ;;
  esac
  case "$out" in *'$ git tag'*|*'$ git push'*) fail "release.sh resume: tags or pushes again" ;; *) pass "release.sh resume: neither tags nor pushes again" ;; esac
  # A missing formula stops the run before it tags or publishes anything.
  case "$(AGENT_VM_TAP="$SB/no-tap" relrun; echo "rc=$?")" in
    *"no formula at $SB/no-tap/Formula/agent-vm.rb"*"rc=1")
      case "$(AGENT_VM_TAP="$SB/no-tap" relrun)" in *"Checking the repository"*) fail "release.sh: the formula is checked after the repository" ;; *) pass "release.sh: a missing formula stops it first" ;; esac ;;
    *) fail "release.sh: missing formula: $(AGENT_VM_TAP="$SB/no-tap" relrun)" ;;
  esac
  touch "$SB/rel-released"
  case "$(relrun)" in *"tag v$AGENT_VM_VERSION already exists"*) pass "release.sh: a released tag is still refused" ;; *) fail "release.sh: a released tag was not refused" ;; esac
  # The tag made here but never pushed: resumed too, and pushed before the
  # release, which `gh release create --verify-tag` needs on origin.
  rm -f "$SB/rel-released"
  git -C "$RR" push -q origin ":refs/tags/v$AGENT_VM_VERSION" >/dev/null 2>&1
  out="$(relrun)"
  case "$out" in
    *"resuming"*"\$ git push origin refs/tags/v$AGENT_VM_VERSION"*"\$ gh release create"*) pass "release.sh resume: a tag only made here is pushed first" ;;
    *) fail "release.sh resume, local tag: $out" ;;
  esac
  case "$out" in *'$ git tag'*) fail "release.sh resume: tags again" ;; *) pass "release.sh resume: and not tagged again" ;; esac
else
  printf '  skip release.sh resume (no git)\n'
fi

section "no terminal: detected by opening it"
# `-r /dev/tty` is true with no controlling terminal; only opening it fails.
# setsid gives a process no controlling terminal, which is the CI case.
if command -v setsid >/dev/null 2>&1; then
  SETSID="$(command -v setsid)"
  # Runs $1 in bash with no controlling terminal. The exit status comes back as
  # a last `rc=N` line: busybox setsid has no -w to wait and pass it through.
  notty() {
    "$SETSID" "$BASH_BIN" -c "source '$AGENT_VM_SH'; $1"'; echo "rc=$?"' </dev/null 2>&1
  }

  out="$(notty '_agent_vm_have_tty')"
  check "no controlling terminal: _agent_vm_have_tty says no" "${out##*rc=}" "1"

  # Lima missing, brew present, nobody to ask: say what to run, install nothing.
  mkdir -p "$SB/fakebrew"
  printf '#!/bin/sh\necho "brew $*" >> "%s/brew.log"\n' "$SB" > "$SB/fakebrew/brew"
  chmod +x "$SB/fakebrew/brew"
  rm -f "$SB/brew.log"
  out="$(PATH="$SB/fakebrew:$(nolima_path)" notty 'agent-vm setup --preinstall=none')"
  [ ! -e "$SB/brew.log" ] && pass "no terminal: brew is not run without asking" \
    || fail "brew ran without a prompt: $(cat "$SB/brew.log")"
  case "${out##*rc=}:$out" in
    1:*"Install it with: brew install sylvinus/tap/lima-sylvinus"*"brew install lima"*) pass "no terminal: says how to install Lima, the one keeping .git read-only first" ;;
    *) fail "no terminal: '$out'" ;;
  esac
  case "$out" in
    */dev/tty*) fail "a /dev/tty error leaked: $out" ;;
    *) pass "no /dev/tty error is printed" ;;
  esac

  # The wizard is skipped too, rather than run and answered with its defaults
  # because every read fails.
  rm -f "$SB/brew.log" "$PROTECTS"
  out="$(AGENT_VM_STATE_DIR="$SB/wizard-state" AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_PROTECTS="$PROTECTS" \
         PATH="$SB/fakebrew:$PATH" notty '_agent_vm_check_linux_prereqs() { return 0; }; agent-vm setup')"
  case "${out##*rc=}:$out" in
    *"setup wizard"*) fail "the wizard ran with no terminal" ;;
    0:*) pass "no terminal: the wizard is skipped and setup completes" ;;
    *) fail "setup with no terminal: '$out'" ;;
  esac
  check "the base records the agent-vm that built it" \
    "$(cat "$SB/wizard-state/.agent-vm-base-built-by" 2>/dev/null)" "$AGENT_VM_VERSION"
  # A base that did not stop is not marked ready: Lima cannot clone it.
  out="$(AGENT_VM_STATE_DIR="$SB/wizard-state2" AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_PROTECTS="$PROTECTS" \
         AGENT_VM_TEST_BASE_RUNNING=1 PATH="$SB/fakebrew:$PATH" notty '_agent_vm_check_linux_prereqs() { return 0; }; agent-vm setup')"
  case "${out##*rc=}:$out" in
    1:*"the base VM is set up but did not stop"*) pass "a base that does not stop: setup fails, and says so" ;;
    *) fail "a base that does not stop: '$out'" ;;
  esac
  [ ! -e "$SB/wizard-state2/.agent-vm-base-version" ] && pass "and it is not marked ready" \
    || fail "a running base was marked ready"
  # Lima's containerd is never installed: Docker brings its own when chosen.
  grep -q "^create .*--containerd=none" "$REC" && pass "Lima's containerd is off" \
    || fail "Lima's containerd stays on: $(grep '^create' "$REC")"
  # The resources are read as for the other commands, both spellings.
  : > "$REC"
  AGENT_VM_STATE_DIR="$SB/wizard-state3" AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_PROTECTS="$PROTECTS" PATH="$SB/fakebrew:$PATH" \
    notty '_agent_vm_check_linux_prereqs() { return 0; }; agent-vm setup --disk=20 --memory 2 --cpus=1' >/dev/null
  grep -q "^create .*--disk=20 --memory=2 --cpus=1" "$REC" && pass "setup: --disk=20 --memory 2 --cpus=1 reach the base" \
    || fail "setup resources: $(grep '^create' "$REC")"
  # A Lima that cannot keep .git read-only: said, with the command, and setup
  # goes on without installing anything.
  case "$out" in
    *"cannot keep .git read-only"*"brew install sylvinus/tap/lima-sylvinus"*"Continuing without .git protection"*)
      pass "no terminal: setup says .git is not protected, and how to fix it" ;;
    *) fail "no terminal: no .git protection warning: '$out'" ;;
  esac
  [ ! -e "$SB/brew.log" ] && pass "no terminal: nothing is installed" \
    || fail "brew ran without a prompt: $(cat "$SB/brew.log")"
else
  printf '  skip terminal detection (no setsid here)\n'
fi

# =============================================================================
section "setup offers a Lima that keeps .git read-only"
# =============================================================================
# With a terminal and Homebrew. A stub brew records its calls; installing the
# formula makes the limactl stub answer like a Lima with readonlyNames.
# FAKE_BREW_HAS_LIMA: brew's own lima is installed. FAKE_BREW_FAIL: the
# install fails.
mkdir -p "$SB/fakebrew"
cat > "$SB/fakebrew/brew" <<STUB
#!/bin/sh
echo "brew \$*" >> "$SB/brew.log"
case "\$1 \$2" in
  "list --formula") [ -n "\${FAKE_BREW_HAS_LIMA:-}" ] ;;
  "install sylvinus/tap/lima-sylvinus") [ -z "\${FAKE_BREW_FAIL:-}" ] && touch "$PROTECTS" ;;
esac
STUB
chmod +x "$SB/fakebrew/brew"
# ANSWER is the reply to the prompt (1 yes, 0 no).
offer() {
  rm -f "$SB/brew.log"
  # The Homebrew path, on any host: on Windows the offer is the download,
  # which 18-windows.sh covers with a stub.
  ( export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_PROTECTS="$PROTECTS" PATH="$SB/fakebrew:$PATH"
    _agent_vm_on_windows() { return 1; }
    _agent_vm_have_tty() { return 0; }
    _agent_vm_ask_yn() { echo "${ANSWER:-1}"; }
    _agent_vm_offer_git_protection ) 2>&1
}
brew_calls() { tr '\n' ';' < "$SB/brew.log" 2>/dev/null; }

rm -f "$PROTECTS"
out="$(FAKE_BREW_HAS_LIMA=1 offer)"
check "yes, over brew's lima: unlink it, then install the formula" \
  "$(brew_calls)" "brew list --formula lima;brew unlink lima;brew install sylvinus/tap/lima-sylvinus;"
case "$out" in *"Lima now keeps every .git read-only"*) pass "yes: says it worked, checked afresh" ;; *) fail "yes: $out" ;; esac

rm -f "$PROTECTS"
offer >/dev/null
check "yes, no brew lima: nothing to unlink" \
  "$(brew_calls)" "brew list --formula lima;brew install sylvinus/tap/lima-sylvinus;"

rm -f "$PROTECTS"
out="$(FAKE_BREW_HAS_LIMA=1 FAKE_BREW_FAIL=1 offer)"
case "$(brew_calls)" in
  *"brew install sylvinus/tap/lima-sylvinus;brew link lima;") pass "a failed install links brew's lima back" ;;
  *) fail "failed install: $(brew_calls)" ;;
esac
case "$out" in *"the install failed. Continuing without .git protection"*) pass "and says so" ;; *) fail "failed install: $out" ;; esac

rm -f "$PROTECTS"
out="$(ANSWER=0 offer)"
[ ! -e "$SB/brew.log" ] && pass "no: brew is not run" || fail "no: brew ran: $(brew_calls)"
case "$out" in *"cannot keep .git read-only"*"Continuing without .git protection"*) pass "no: the risk is said" ;; *) fail "no: $out" ;; esac

touch "$PROTECTS"
out="$(offer)"
check "already protected: nothing said" "$out" ""
[ ! -e "$SB/brew.log" ] && pass "already protected: brew is not run" || fail "already protected: brew ran: $(brew_calls)"

section "start: git on this machine ignores bare repositories"
# A folder holding HEAD, objects/ and refs/ is a repository to git, whatever
# its name, so .git protection does not cover it. A start with writable shares
# offers to set safe.bareRepository=explicit; left unset, it asks whether to go
# on, and stops by default. The stub git is the doctor section's.
# ANSWER is the reply to the offer (1 yes, 0 no), GO_ON the one to the
# security question; NOTTY=1 means no terminal to ask on. Prints the output,
# then rc=N.
bare_check() {
  rm -f "$SB/git.log"
  ( export PATH="$SB/fakegit:$PATH"
    unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS
    _agent_vm_can_ask() { [ -z "${NOTTY:-}" ]; }
    _agent_vm_ask_yn() { case "$1" in "Continue anyway?") echo "${GO_ON:-0}" ;; *) echo "${ANSWER:-1}" ;; esac; }
    _agent_vm_check_bare_repo_setting; echo "rc=$?" ) 2>&1
}
git_set_called() { grep -q 'config --global safe.bareRepository explicit' "$SB/git.log" 2>/dev/null; }

rm -f "$SB/git-bare"
out="$(bare_check)"
[ "$(cat "$SB/git-bare" 2>/dev/null)" = "explicit" ] && pass "yes: the setting is made" || fail "yes: not set: $out"
case "$out" in
  *"HEAD, objects/ and refs/"*"git config --global safe.bareRepository explicit"*"now ignores"*"rc=0") pass "yes: the risk, the command, the result, and on" ;;
  *) fail "yes: $out" ;;
esac
rm -f "$SB/git-bare"
out="$(ANSWER=0 bare_check)"
git_set_called && fail "no: the setting was made anyway" || pass "no: git config is not run"
case "$out" in *"Warning: not set"*"Aborted."*"rc=1") pass "no: says what is left open, and stops by default" ;; *) fail "no: $out" ;; esac
out="$(ANSWER=0 GO_ON=1 bare_check)"
case "$out" in *"rc=0") pass "no, then go on: on" ;; *) fail "no, then go on: $out" ;; esac
out="$(NOTTY=1 bare_check)"
git_set_called && fail "no terminal: the setting was made without asking" || pass "no terminal: nothing is changed"
case "$out" in *"git config --global safe.bareRepository explicit"*"Aborted."*"rc=1") pass "no terminal: the command is printed, and it stops" ;; *) fail "no terminal: $out" ;; esac
out="$(FAKE_GIT_SET_FAILS=1 bare_check)"
case "$out" in *"did not take"*"Aborted."*"rc=1") pass "a failed git config is said, and it stops" ;; *) fail "failed git config: $out" ;; esac
# Disabled questions: no offer either, the global config is not changed unasked.
rm -f "$SB/git.log"
out="$( export AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1; PATH="$SB/fakegit:$PATH"; _agent_vm_check_bare_repo_setting 2>&1; echo "rc=$?" )"
git_set_called && fail "prompts disabled: the setting was made" || pass "prompts disabled: git config is not run"
case "$out" in *"Warning: not set"*"Continuing: AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1."*"rc=0") pass "prompts disabled: warned, then on" ;; *) fail "prompts disabled: $out" ;; esac
out="$(FAKE_GIT_VERSION=2.30.1 bare_check)"
git_set_called && fail "old git: set on a git that ignores it" || pass "old git: nothing is set"
case "$out" in *"older than 2.38"*"Aborted. Upgrade git"*"rc=1") pass "old git: stops, and says to upgrade" ;; *) fail "old git: $out" ;; esac
echo explicit > "$SB/git-bare"
check "already set: nothing said" "$(bare_check)" "rc=0"
git_set_called && fail "already set: git config was run" || pass "already set: git config is not run"
check "no git on this machine: nothing to protect" "$( hash -r; PATH="$SB/nolimactl" _agent_vm_bare_repo_state)" "nogit"
check "setup no longer asks" "$(declare -f _agent_vm_setup | grep -c 'bare_repo')" "0"

# In a start: before anything changes, and not under --readonly, where the VM
# cannot write a repository anywhere.
rm -f "$SB/git-bare"
out="$( export PATH="$SB/fakegit:$PATH"; unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }
        touch "$PROTECTS"; AGENT_VM_TEST_STOPPED=1 rec run true; echo "rc=$?" )"
case "$out" in *"Aborted. Run the command above"*"rc=1") pass "start: unset, no terminal: stopped" ;; *) fail "start: not stopped: $out" ;; esac
grep -Eq '^(edit|start|clone) ' "$REC" && fail "start: the VM was touched before the abort" || pass "start: nothing touched"
printf '[{"location": "%s", "writable": true, %s}]\n' "$PROJ" "$SSHFS_RO" > "$HOME/.agent-vm/.agent-vm-mounts-$PV"
out="$( export PATH="$SB/fakegit:$PATH"; unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }
        rec run true; echo "rc=$?" )"
case "$out" in *"Aborted."*) fail "start of a running VM: stopped on the setting: $out" ;; *"Warning: git on this machine uses repositories a VM creates"*"rc=0") pass "start of a running VM: warned, not asked" ;; *) fail "start of a running VM: $out" ;; esac
case "$( PATH="$SB/fakegit:$PATH"; rec info | grep '^security_questions=')" in *bare-repo*) pass "info: security_questions names the setting" ;; *) fail "info: bare-repo not named" ;; esac
printf '[{"location": "%s", "writable": false, %s}]\n' "$PROJ" "$SSHFS_RO" > "$HOME/.agent-vm/.agent-vm-mounts-$PV"
out="$( export PATH="$SB/fakegit:$PATH"; unset AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS; _agent_vm_can_ask() { return 1; }
        AGENT_VM_TEST_STOPPED=1 AGENT_VM_TEST_RO=1 AGENT_VM_TEST_MOUNTTYPE=reverse-sshfs rec --readonly run true; echo "rc=$?" )"
case "$out" in *"repositories not named .git"*|*"Aborted."*) fail "start --readonly: asked anyway: $out" ;; *"rc=0") pass "start --readonly: no question" ;; *) fail "start --readonly: $out" ;; esac
rm -f "$PROTECTS" "$HOME/.agent-vm/.agent-vm-mounts-$PV"
# A first run opens on the familiar questions: the security ones come after the
# wizard, and before the VM exists.
check "security checks: after the wizard, before the VM" \
  "$(declare -f _agent_vm_setup | grep -o -e 'Use these defaults' -e 'Running security checks' -e 'Creating base VM' | tr '\n' '|')" \
  "Use these defaults|Running security checks|Creating base VM|"

# Against the real git, when it is recent enough: only the system and global
# config count, as for git itself. A repository's own setting must not answer.
real_git_ver="$(git --version 2>/dev/null)"; real_git_ver="${real_git_ver#git version }"; real_git_ver="${real_git_ver%% *}"
if [ -n "$real_git_ver" ] && _agent_vm_ver_ge "$real_git_ver" 2.38.0; then
  mkdir -p "$SB/realgit/home" "$SB/realgit/repo"
  ( export HOME="$SB/realgit/home" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$SB/realgit/xdg"
    cd "$SB/realgit/repo" && git init -q . && git config safe.bareRepository explicit
    printf '%s ' "$(_agent_vm_bare_repo_state)"
    git config --global safe.bareRepository explicit
    printf '%s' "$(_agent_vm_bare_repo_state)" ) > "$SB/realgit/out"
  check "real git: a repository's own setting does not count, the global one does" "$(cat "$SB/realgit/out")" "unset ok"
else
  printf '  skip real git (absent or older than 2.38)\n'
fi
rm -f "$PROTECTS"

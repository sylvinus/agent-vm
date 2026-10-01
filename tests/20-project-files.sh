# =============================================================================
section "project files: never read on the host through a symlink"
# =============================================================================
# The VM can write the project, and make .agent-vm.env or
# .agent-vm.runtime.sh a symlink to any file of the user's. The host used to
# read both with a plain `<` on every start and hand the content to the VM:
# `ln -s ~/.ssh/id_ed25519 .agent-vm.env` got the key on the next command.
# Uses the recording limactl of 11-recorded-commands.sh.
SECRET="$SB/host-secret"
printf 'TOPSECRET=leaked\n' > "$SECRET"
PF="$SB/pf"; mkdir -p "$PF"
PFV="$(_agent_vm_name "$PF")"
pf_rec() {
  : > "$REC"; : > "$SB/pf-stdin"
  ( cd "$PF" || exit 1
    export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$PFV" AGENT_VM_TEST_STDIN="$SB/pf-stdin"
    agent-vm "$@" </dev/null 2>&1 )
}
# Regular files only: the planted links themselves point at the secret, and
# some greps (busybox) follow links when recursing.
leaked() {
  grep -q TOPSECRET <<< "$({ cat "$SB/pf-stdin"; find "$PF" -type f -exec cat {} +; } 2>/dev/null)" \
    && echo leaked || echo no
}

if [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
  ln -s "$SECRET" "$PF/.agent-vm.env"
  ln -s "$SECRET" "$PF/.agent-vm.runtime.sh"
  AGENT_VM_TEST_RUNTIME_FOUND=1 pf_rec run true >/dev/null
  check "a symlinked env or runtime: nothing of the target reaches the VM" "$(leaked)" "no"
  grep -qF "$PF/.agent-vm.env" "$REC" && pass "the env file is handed to the VM by its path" \
    || fail "the env file path is not passed to the VM: $(grep -A3 'agent-vm.env' "$REC")"
  grep -q "^shell --workdir $PF $PFV zsh -lc" "$REC" && grep -qF "$PF/.agent-vm.runtime.sh" "$REC" \
    && pass "the runtime script is run by its path in the VM" || fail "runtime: $(grep '^shell' "$REC")"
  # The same through a relocated path whose directory is a link.
  mkdir -p "$SB/pf-outside"; cp "$SECRET" "$SB/pf-outside/env"
  ln -s "$SB/pf-outside" "$PF/.mytool"
  AGENT_VM_PROJECT_ENV=.mytool/env AGENT_VM_PROJECT_RUNTIME=.mytool/env pf_rec run true >/dev/null
  check "a symlinked directory on the way: nothing reaches the VM" "$(leaked)" "no"
  rm -rf "$PF/.mytool"
  # The project named another way: by its real path while it is used through
  # a link (/tmp and /private/tmp on macOS). Still the project, by where the
  # path leads, not how it is spelled.
  ln -s "$PF" "$SB/pf-link"
  pf_link() {
    ( cd "$SB/pf-link" || exit 1
      export AGENT_VM_TEST_REC="$REC" AGENT_VM_TEST_VM="$(_agent_vm_name "$SB/pf-link")" AGENT_VM_TEST_STDIN="$SB/pf-stdin"
      : > "$REC"; : > "$SB/pf-stdin"
      AGENT_VM_PROJECT_ENV="$PF/.agent-vm.env" AGENT_VM_PROJECT_RUNTIME="$PF/.agent-vm.runtime.sh" agent-vm "$@" </dev/null 2>&1 )
  }
  if [[ -n "$AGENT_VM_HAS_PERL" ]]; then
    check "the real path of a linked project: project-env get refuses the link" \
      "$(pf_link project-env get TOPSECRET; echo "rc=$?")" "$(printf '%s\n%s\n%s' "Error: $SB/pf-link/.agent-vm.env is a symlink, is reached through one, or is not a regular file." "  agent-vm follows no link in the project, which the VM can write. Replace it with a plain file." "rc=2")"
    pf_link project-env set X 1 >/dev/null
    check "and project-env set leaves the link alone" "$([ -L "$PF/.agent-vm.env" ] && echo link || echo replaced)" "link"
  else
    printf '  skip project-env through a linked project (perl is not installed)\n'
  fi
  AGENT_VM_TEST_RUNTIME_FOUND=1 pf_link run true >/dev/null
  check "and nothing of the target reaches the VM" "$(leaked)" "no"
  grep -qF "$SB/pf-link/.agent-vm.env" "$REC" && pass "the env file is handed to the VM by its path there" \
    || fail "linked project: env path not passed to the VM"
  check "a relative path is found by where it leads" \
    "$(_agent_vm_project_rel "$SB/pf-link" "$PF/sub/f"):$(_agent_vm_project_rel "$PF" "$SB/pf-link/f"):$(_agent_vm_project_rel "$PF" "$SB/other/f" || echo out)" \
    "sub/f:f:out"
  # A link of the user's to a folder IN the project, which the VM then makes
  # a link out of it: still the project, not where the VM's link leads.
  mkdir -p "$PF/sub" "$SB/pf-elsewhere"; ln -s "$PF/sub" "$SB/pf-sublink"
  check "a user's link into the project: in it" "$(_agent_vm_project_rel "$PF" "$SB/pf-sublink/.env")" "sub/.env"
  rmdir "$PF/sub"; ln -s "$SB/pf-elsewhere" "$PF/sub"
  check "and once the VM swaps a link in below it: still in it" "$(_agent_vm_project_rel "$PF" "$SB/pf-sublink/.env")" "sub/.env"
  check "a relative link outside, through .., is followed" \
    "$(ln -s "../pf-link" "$SB/pf-elsewhere/up"; _agent_vm_project_rel "$PF" "$SB/pf-elsewhere/up/y")" "y"
  rm -rf "$SB/pf-sublink" "$PF/sub" "$SB/pf-elsewhere"
  rm -f "$SB/pf-link" "$PF/.agent-vm.env" "$PF/.agent-vm.runtime.sh"
else
  printf '  skip symlinked project files (ln -s plants copies on this machine)\n'
fi

# Kept outside the project by an absolute AGENT_VM_PROJECT_ENV, the file is
# the user's own, and the host still pushes it.
printf 'OUTSIDE=1\n' > "$SB/pf-own.env"
AGENT_VM_PROJECT_ENV="$SB/pf-own.env" pf_rec run true >/dev/null
check "an env file outside the project is pushed by the host" "$(grep -c '^OUTSIDE=1$' "$SB/pf-stdin")" "1"
# So is one a relative path takes out of the project: the VM cannot see it.
AGENT_VM_PROJECT_ENV=../pf-own.env pf_rec run true >/dev/null
check "a relative path out of the project (../) is pushed by the host" "$(grep -c '^OUTSIDE=1$' "$SB/pf-stdin")" "1"
check "and named without the detour" \
  "$(cd "$PF" && AGENT_VM_PROJECT_ENV=sub/../../pf-own.env _agent_vm_project_env_file) $(AGENT_VM_PROJECT_RUNTIME=/a/./b/../rt.sh _agent_vm_project_runtime_path "$PF")" \
  "$SB/pf-own.env /a/rt.sh"
check "project-env reads it there" \
  "$( cd "$PF" && AGENT_VM_PROJECT_ENV=../pf-own.env AGENT_VM_STATE_DIR="$SB/pf-state" bash "$AGENT_VM_SH" project-env get OUTSIDE )" "1"
rm -f "$SB/pf-own.env"
# A runtime the VM does not find is not run.
pf_rec run true >/dev/null
grep -q "zsh -lc.*\.agent-vm\.runtime\.sh" "$REC" && fail "a runtime the VM did not find was run" \
  || pass "no runtime in the project: nothing run"

section "project files: what the VM does with them"
# A limactl that runs the guest's command here, with its own HOME: the
# scripts that read the project's files in the VM, run for real.
GH="$SB/guest-home"; mkdir -p "$GH" "$SB/localvm"
cat > "$SB/localvm/limactl" <<STUB
#!/usr/bin/env bash
[ "\$1" = shell ] || exit 0
shift
wd=""
[ "\$1" = --workdir ] && { wd="\$2"; shift 2; }
shift
[ -z "\$wd" ] || cd "\$wd"
HOME="$GH" exec "\$@"
STUB
chmod +x "$SB/localvm/limactl"
printf 'B=2\r\nA=project\r\n' > "$PF/.agent-vm.env"
: > "$PF/.agent-vm.runtime.sh"
out="$(PATH="$SB/localvm:$PATH" _agent_vm_push_env_and_probe vm "$PF" "A=shared" "$PF/.agent-vm.env" "$PF/.agent-vm.runtime.sh")"
check "the VM writes the shared payload, then the project's file, without CRs" \
  "$(od -c < "$GH/.agent-vm.env" | grep -c '\\r') $(tr '\n' ' ' < "$GH/.agent-vm.env")" "0 A=shared B=2 A=project "
check "and says it did, and that the runtime is there" "$(printf '%s' "$out" | tr '\n' ' ')" "env-ok runtime-found"
if _agent_vm_on_windows; then
  printf '  skip the guest env file is private (permission bits are emulated on Windows)\n'
else
  check "the guest env file is private" "$(ls -l "$GH/.agent-vm.env" | cut -c2-10)" "rw-------"
fi
rm -f "$PF/.agent-vm.runtime.sh"
out="$(PATH="$SB/localvm:$PATH" _agent_vm_push_env_and_probe vm "$PF" "" "$PF/.agent-vm.env" "$PF/.agent-vm.runtime.sh")"
check "no runtime there: not found" "$out" "env-ok"
if command -v zsh >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\r\necho "ran:${BASH_VERSION:+bash}" > "$HOME/rt-out"\r\n' > "$PF/.agent-vm.runtime.sh"
  PATH="$SB/localvm:$PATH" _agent_vm_run_project_runtime vm "$PF" "$PF/.agent-vm.runtime.sh" >/dev/null 2>&1
  check "the VM runs the runtime by its path, with its shebang, without CRs" "$(cat "$GH/rt-out" 2>/dev/null)" "ran:bash"
else
  printf '  skip the runtime run in the VM (zsh is not installed)\n'
fi
rm -f "$PF/.agent-vm.env" "$PF/.agent-vm.runtime.sh"

section "project-env: no symlink followed on the host"
# `project-env set` read the file through a link and wrote the target's
# content back into the project, where the VM reads it.
pfe() { ( cd "$PF" && AGENT_VM_STATE_DIR="$SB/pf-state" bash "$AGENT_VM_SH" project-env "$@" ); }
if ! command -v perl >/dev/null 2>&1; then
  printf '  skip project-env through symlinks (perl is not installed)\n'
elif [[ -n "$AGENT_VM_HAS_SYMLINKS" ]]; then
  ln -s "$SECRET" "$PF/.agent-vm.env"
  for verb in "set K v" "unset TOPSECRET" "get TOPSECRET" "has TOPSECRET" "list"; do
    # eval: zsh does not split an unquoted $verb into words.
    out="$(eval "pfe $verb" 2>&1)"
    case "$?:$out" in
      2:*"is a symlink, is reached through one"*) pass "project-env $verb on a symlink: refused" ;;
      *) fail "project-env $verb on a symlink: $out" ;;
    esac
  done
  check "the link is left, its target untouched, nothing copied" \
    "$([ -L "$PF/.agent-vm.env" ] && echo link) $(cat "$SECRET") $(leaked)" "link TOPSECRET=leaked no"
  rm -f "$PF/.agent-vm.env"
  # A directory on the way that is a link: nothing read, nothing written there.
  mkdir -p "$SB/pf-outside"; printf 'TOPSECRET=leaked\n' > "$SB/pf-outside/env"
  ln -s "$SB/pf-outside" "$PF/.mytool"
  out="$(AGENT_VM_PROJECT_ENV=.mytool/env pfe set K v 2>&1)"
  check "set through a symlinked directory: refused" "$?" "2"
  check "and nothing is written there" "$(ls -A "$SB/pf-outside" | tr '\n' ' ')" "env "
  rm -rf "$PF/.mytool" "$SB/pf-outside"
fi
if command -v perl >/dev/null 2>&1; then
  # A FIFO would hang a plain read.
  if mkfifo "$PF/.agent-vm.env" 2>/dev/null; then
    out="$(pfe get K 2>&1)"
    check "a FIFO: refused, not waited on" "$?" "2"
    rm -f "$PF/.agent-vm.env"
  fi
  # The ordinary way still works, in a directory created on the way.
  AGENT_VM_PROJECT_ENV=.mytool/sub/env pfe set K "it's" >/dev/null 2>&1
  check "a relocated file in new directories: written and read back" \
    "$(AGENT_VM_PROJECT_ENV=.mytool/sub/env pfe get K)" "it's"
  if ! _agent_vm_on_windows; then
    check "and it is mode 600" "$(ls -l "$PF/.mytool/sub/env" | cut -c2-10)" "rw-------"
  fi
  check "no temporary file is left" "$(ls -A "$PF/.mytool/sub")" "env"
  rm -rf "$PF/.mytool"
fi
rm -rf "$PF"

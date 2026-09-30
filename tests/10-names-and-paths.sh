# =============================================================================
section "project paths that would rewrite the mount config are refused"
# =============================================================================
# The path is spliced into the yq expression given to `limactl edit --set`. A
# quote in a directory name used to end the string and let the name add mounts
# of its own: `a","writable":true},{"location":"~",...` mounted the home
# directory read-write, --readonly or not.
for d in "$SB/"'q"uote' "$SB/"'back\slash'; do
  mkdir -p "$d"
  out="$(_agent_vm_ensure_running agent-vm-x "$d" 2>&1)"
  rc=$?
  case "$rc:$out" in
    1:*"a quote, a backslash or a control character"*) pass "refused: $(basename "$d")" ;;
    *) fail "not refused: $(basename "$d") ($rc: $out)" ;;
  esac
done

# =============================================================================
section "VM names need a hash, and get one without shasum"
# =============================================================================
# Without a hash, every directory named `proj` shared the VM `agent-vm-proj-`.
HB="$SB/hashbin"; mkdir -p "$HB/none" "$HB/sha256sum-only"
# Wrapper scripts, not symlinks: where the machine makes no real links
# (Windows runners plant copies), a copied binary cannot find its libraries
# under the restricted PATH below, while a wrapper execs the real tool by
# absolute path. /bin/sh exists everywhere these tests run.
for t in cut basename tr sed; do
  tool="$(command -v "$t")"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$tool" > "$HB/none/$t"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$tool" > "$HB/sha256sum-only/$t"
  chmod +x "$HB/none/$t" "$HB/sha256sum-only/$t"
done
out="$(PATH="$HB/none"; _agent_vm_name /x/proj 2>&1)"
rc=$?
case "$rc:$out" in
  1:*"install shasum or sha256sum"*) pass "no hash tool: naming fails instead of dropping the hash" ;;
  *) fail "no hash tool: got $rc '$out'" ;;
esac
if command -v sha256sum >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v sha256sum)" > "$HB/sha256sum-only/sha256sum"
  chmod +x "$HB/sha256sum-only/sha256sum"
  check "sha256sum gives the same name as shasum" \
    "$(PATH="$HB/sha256sum-only"; _agent_vm_name /x/proj)" "$(_agent_vm_name /x/proj)"
else
  printf '  skip sha256sum fallback (not installed here)\n'
fi

# =============================================================================
section "Lima's state directory follows LIMA_HOME"
# =============================================================================
# A leftover without lima.yaml is cleaned where Lima keeps its VMs, and only
# there: with LIMA_HOME set, ~/.lima is someone else's.
mkdir -p "$SB/limahome/agent-vm-partial" "$HOME/.lima/agent-vm-partial"
( LIMA_HOME="$SB/limahome"; _agent_vm_clean_partial_state agent-vm-partial ) 2>/dev/null
check "LIMA_HOME: the leftover there goes, ~/.lima is not touched" \
  "$([ -d "$SB/limahome/agent-vm-partial" ] && echo kept || echo cleaned) $([ -d "$HOME/.lima/agent-vm-partial" ] && echo kept || echo cleaned)" \
  "cleaned kept"
_agent_vm_clean_partial_state agent-vm-partial 2>/dev/null
check "without LIMA_HOME: ~/.lima" "$([ -d "$HOME/.lima/agent-vm-partial" ] && echo kept || echo cleaned)" "cleaned"

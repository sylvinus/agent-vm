# =============================================================================
section "host capacity: clamping"
# =============================================================================
# The policy is "a VM must not starve the host it runs on". These assertions
# pin the arithmetic, the floors, and the two cases where the value must be
# left alone: nothing asked, and an unreadable host.
check "half of 8 CPUs"                 "$(_agent_vm_host_share 8 1)" "4"
check "floor of 1 CPU on a 1-CPU host" "$(_agent_vm_host_share 1 1)" "1"
check "floor of 2 GiB on a 3 GiB host" "$(_agent_vm_host_share 3 2)" "2"

# A known host: 8 CPUs / 16 GiB.
_agent_vm_host_cpus()    { echo 8; }
_agent_vm_host_mem_gib() { echo 16; }

check "nothing asked stays nothing"    "$(_agent_vm_cap_resource cpus '')"  ""
check "a value under the share passes" "$(_agent_vm_cap_resource cpus 2)"   "2"
check "a value at the share passes"    "$(_agent_vm_cap_resource cpus 4)"   "4"
check "a value above the share is clamped" \
  "$(_agent_vm_cap_resource cpus 16 2>/dev/null)" "4"
check "memory is clamped too" \
  "$(_agent_vm_cap_resource memory 64 2>/dev/null)" "8"
# Clamping must be said, not done behind the user's back.
clamp_msg="$(_agent_vm_cap_resource cpus 16 2>&1 >/dev/null)"
case "$clamp_msg" in
  *"exceeds this host's share"*) pass "clamping is announced on stderr" ;;
  *) fail "clamping was silent (got: '$clamp_msg')" ;;
esac
# The share is a policy, so it is overridable.
check "AGENT_VM_HOST_SHARE=1 gives the whole host" \
  "$(AGENT_VM_HOST_SHARE=1 _agent_vm_cap_resource cpus 8)" "8"
check "AGENT_VM_HOST_SHARE=4 clamps to a quarter" \
  "$(AGENT_VM_HOST_SHARE=4 _agent_vm_cap_resource cpus 8 2>/dev/null)" "2"
# It goes into arithmetic: anything but a positive integer falls back to 2,
# never to a division error, an empty value or an evaluated name.
# HOME and not an unset name: under set -u that aborts before the subscript runs.
for bad in 0 08 abc -1 '' 'HOME[$(touch '"$SB"'/pwned-share)]'; do
  check "AGENT_VM_HOST_SHARE='$bad' falls back to half" \
    "$(AGENT_VM_HOST_SHARE="$bad" _agent_vm_cap_resource cpus 8 2>/dev/null)" "4"
done
check "and nothing in it was evaluated" "$([ -e "$SB/pwned-share" ] && echo yes || echo no)" "no"
case "$(AGENT_VM_HOST_SHARE=0 _agent_vm_host_share 8 1 2>&1 >/dev/null)" in
  *"not a positive integer"*) pass "an invalid AGENT_VM_HOST_SHARE is reported" ;;
  *) fail "an invalid AGENT_VM_HOST_SHARE was silent" ;;
esac

# An unreadable host must never shrink anything.
_agent_vm_host_cpus()    { echo ""; }
_agent_vm_host_mem_gib() { echo ""; }
check "unknown host: the value is honoured as asked" \
  "$(_agent_vm_cap_resource cpus 16)" "16"

# Free space: measured where Lima keeps the disks, through a link to another
# disk; in HOME before Lima has made its directory. A stub df names the path.
free_at() {  # <LIMA_HOME or empty>: the path df was given, then the GiB
  ( df() { printf '%s ' "$2" > "$SB/df-arg"; printf 'h\nfs 1 1 2097152 0%% /\n'; }
    if [[ -n "$1" ]]; then export LIMA_HOME="$1"; else unset LIMA_HOME; fi
    gib="$(_agent_vm_free_gib)"
    printf '%s%s' "$(cat "$SB/df-arg")" "$gib" )
}
mkdir -p "$SB/lima-disk"
ln -s "$SB/lima-disk" "$SB/lima-link" 2>/dev/null
check "free space: in Lima's directory, a link followed" "$(free_at "$SB/lima-link")" "$SB/lima-link/. 2"
check "free space: in HOME before Lima's directory exists" "$(free_at "$SB/no-lima")" "$HOME/. 2"
check "free space: ~/.lima without LIMA_HOME" "$(mkdir -p "$HOME/.lima"; free_at "")" "$HOME/.lima/. 2"
rmdir "$HOME/.lima"; rm -rf "$SB/lima-link" "$SB/lima-disk" "$SB/df-arg"

# Restore the real probes for anything running after this section.
unset -f _agent_vm_host_cpus _agent_vm_host_mem_gib
# shellcheck source=./agent-vm.sh
source "$AGENT_VM_SH"

# The flags stay plain integers — no new value to learn, no new way to be wrong.
check "a resource value is taken as a plain integer" \
  "$( vm_opts=(); rm=""; taken=""; _agent_vm_take_opt --cpus 4 && echo "${vm_opts[*]}" )" "--cpus 4"

# =============================================================================
section "version --min: a floor an integrator can oppose"
# =============================================================================
# Without this, every integrator reimplements the comparison — and some get
# "1.10.0 > 1.9.0" wrong, which a string comparison does.
vge() { if _agent_vm_ver_ge "$1" "$2" 2>/dev/null; then echo yes; else echo no; fi; }
check "1.10.0 outranks 1.9.0"          "$(vge 1.10.0 1.9.0)"     "yes"
check "1.9.0 does not reach 1.10.0"    "$(vge 1.9.0 1.10.0)"     "no"
check "equal versions pass"            "$(vge 1.2.3 1.2.3)"      "yes"
check "a short version is padded"      "$(vge 1 1.0.0)"          "yes"
check "and compared once padded"       "$(vge 1 1.0.1)"          "no"
check "a -rc suffix is ignored"        "$(vge 2.0.0-rc1 2.0.0)"  "yes"
check "0.08.0 is decimal, not octal"   "$(vge 0.8.0 0.08.0)"     "yes"
check "0.09.0 outranks 0.8.0"          "$(vge 0.09.0 0.8.0)"     "yes"
check "a component past 999 still orders" "$(vge 1.1000.0 2.0.0)" "no"
check "and does not spill into the next"  "$(vge 1.0.1000 1.1.0)" "no"
# Past what shell arithmetic holds.
check "a 20-digit floor is not met"    "$(vge 0.2.0 18446744073709551616)" "no"
check "a 20-digit version meets a 19-digit one" "$(vge 18446744073709551616 9223372036854775807)" "yes"
check "leading zeros are dropped"      "$(vge 0010 9)"           "yes"

check "plain version still prints" "$(agent-vm version)" "$AGENT_VM_VERSION"

if agent-vm version --min 0.0.1 >/dev/null 2>&1; then
  pass "a floor below the installed version passes"
else
  fail "a satisfied floor was rejected"
fi
check "a satisfied floor prints nothing" "$(agent-vm version --min 0.0.1 2>/dev/null)" ""
check "--min= spelling works too" \
  "$( (agent-vm version --min=0.0.1 >/dev/null 2>&1) && echo yes )" "yes"

agent-vm version --min 99.0.0 >/dev/null 2>&1
check "an unmet floor exits 1" "$?" "1"
# The case that separates a numeric comparison from a lexical one: against
# 0.2.0, "0.10.0" is higher as a number and lower as a string. A lexical
# implementation passes every other assertion in this section.
agent-vm version --min 0.10.0 >/dev/null 2>&1
check "0.10.0 is a higher floor than 0.2.0" "$?" "1"
too_old="$(agent-vm version --min 99.0.0 2>&1 >/dev/null)"
case "$too_old" in
  *"older than the required 99.0.0"*"Update it:  "*) pass "an unmet floor says what to do" ;;
  *) fail "unhelpful message for an unmet floor: $too_old" ;;
esac
mkdir -p "$SB/upd/clone/.git" "$SB/upd/Cellar/agent-vm/1.0.0/libexec" "$SB/upd/release"
update_of() { ( AGENT_VM_SCRIPT_DIR="$1"; _agent_vm_update_command ); }
check "update: a clone pulls"        "$(update_of "$SB/upd/clone")" "git -C '$SB/upd/clone' pull"
mkdir -p "$SB/upd/it's/.git"
check "update: a clone path is quoted for the shell" "$(update_of "$SB/upd/it's")" "git -C '$SB/upd/it'\"'\"'s' pull"
check "update: a keg upgrades"       "$(update_of "$SB/upd/Cellar/agent-vm/1.0.0/libexec")" "brew upgrade agent-vm"
mkdir -p "$HOME/.local/share/agent-vm" "$SB/upd/agent-vm"
check "update: a release reinstalls" "$(update_of "$HOME/.local/share/agent-vm")" "curl -fsSL https://www.agent-vm.org/install.sh | sh"
check "update: a release installed elsewhere reinstalls there" \
  "$(update_of "$SB/upd/release")" "curl -fsSL https://www.agent-vm.org/install.sh | sh -s -- --dir '$SB/upd/release'"
check "update: XDG_DATA_HOME moves the default" \
  "$(XDG_DATA_HOME="$SB/upd"; update_of "$SB/upd/agent-vm")" "curl -fsSL https://www.agent-vm.org/install.sh | sh"
rm -rf "$HOME/.local/share/agent-vm"

# A malformed call must be distinguishable from "too old": a typo in the
# caller's own code should not send a user chasing an upgrade.
agent-vm version --min oups >/dev/null 2>&1
check "a malformed version exits 2" "$?" "2"
agent-vm version --min >/dev/null 2>&1
check "a missing value exits 2" "$?" "2"
agent-vm version --max 1 >/dev/null 2>&1
check "an unknown option exits 2" "$?" "2"

# =============================================================================
section "runtime scripts: location and interpreter"
# =============================================================================
# Before this, every runtime ran under zsh whatever its shebang said — a bash
# script silently got zsh's arrays and globbing.
RT="$SB/rt"; mkdir -p "$RT"
printf '#!/usr/bin/env bash\ntrue\n' > "$RT/env-bash.sh"
printf '#!/bin/bash\ntrue\n'         > "$RT/bin-bash.sh"
printf '#!/bin/sh\ntrue\n'           > "$RT/sh.sh"
printf '#!/usr/bin/env python3\n'    > "$RT/py.sh"
printf 'echo no shebang\n'           > "$RT/none.sh"
: > "$RT/empty.sh"
check "#!/usr/bin/env bash → bash" "$(_agent_vm_runtime_interpreter "$RT/env-bash.sh")" "bash"
check "#!/bin/bash → bash"         "$(_agent_vm_runtime_interpreter "$RT/bin-bash.sh")" "bash"
check "#!/bin/sh → sh"             "$(_agent_vm_runtime_interpreter "$RT/sh.sh")"       "sh"
check "another language → zsh (unchanged behaviour)" \
  "$(_agent_vm_runtime_interpreter "$RT/py.sh")" "zsh"
check "no shebang → zsh"           "$(_agent_vm_runtime_interpreter "$RT/none.sh")"     "zsh"
check "empty file → zsh"           "$(_agent_vm_runtime_interpreter "$RT/empty.sh")"    "zsh"

# Where the project runtime is looked up.
check "default location is the project root" \
  "$(_agent_vm_project_runtime_path "$PROJ")" "$PROJ/.agent-vm.runtime.sh"
check "a relative override resolves against the project" \
  "$(AGENT_VM_PROJECT_RUNTIME=.mytool/runtime.sh _agent_vm_project_runtime_path "$PROJ")" \
  "$PROJ/.mytool/runtime.sh"
check "an absolute override is used as-is" \
  "$(AGENT_VM_PROJECT_RUNTIME=/tmp/elsewhere.sh _agent_vm_project_runtime_path "$PROJ")" \
  "/tmp/elsewhere.sh"

# The script still reaches the VM whole: it is piped, because the per-user
# runtime lives outside the mount and its path means nothing inside the VM.
export AGENT_VM_TEST_CAPTURE="$SB/runtime-stdin"
_agent_vm_run_runtime agent-vm-proj-deadbeef "$PROJ" "$RT/env-bash.sh"
unset AGENT_VM_TEST_CAPTURE
check "the runtime is piped into the VM intact" \
  "$(cat "$SB/runtime-stdin")" "$(cat "$RT/env-bash.sh")"

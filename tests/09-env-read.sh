# =============================================================================
section "env get/has read the file, they never run it"
# =============================================================================
# The project env file sits in a directory the VM can write to, and can arrive
# with a cloned repository. Sourcing it on the host to answer `get` ran
# whatever it contained, as the user, outside the sandbox.
RD="$SB/envread"; mkdir -p "$RD" "$SB/envread-cwd"
# Without perl, the same file is named from outside its directory, where the
# host reads it as is: the reader under test is the same.
if [[ -n "$AGENT_VM_HAS_PERL" ]]; then
  rd() { ( cd "$RD" && AGENT_VM_STATE_DIR="$SB/envread-state" bash "$AGENT_VM_SH" project-env "$@" ); }
else
  printf '  note: no perl, the project env file is read from outside the project\n'
  rd() { ( cd "$SB/envread-cwd" && AGENT_VM_PROJECT_ENV="$RD/.agent-vm.env" AGENT_VM_STATE_DIR="$SB/envread-state" bash "$AGENT_VM_SH" project-env "$@" ); }
fi

printf 'X=$(touch %s/pwned-dollar)\nY=`touch %s/pwned-tick`\n' "$SB" "$SB" > "$RD/.agent-vm.env"
rd get X >/dev/null 2>&1
check "get refuses a \$(...) value (exit 2)" "$?" "2"
rd has Y >/dev/null 2>&1
check "has refuses a backquoted value (exit 2)" "$?" "2"
if [ -e "$SB/pwned-dollar" ] || [ -e "$SB/pwned-tick" ]; then
  fail "a value in the project env file was executed on the host"
else
  pass "nothing in the project env file was executed on the host"
fi
case "$(rd get X 2>&1)" in
  *"Rewrite it with 'agent-vm project-env set'"*) pass "the refusal says how to fix the entry" ;;
  *) fail "the refusal does not say what to do" ;;
esac

# Everything `set` can write must read back unchanged, including the values
# that would be code if the reader evaluated them.
: > "$RD/.agent-vm.env"
for v in "O'Brien" '$(echo hi)' '`id`' 'a\b' 'two words' '"dq"' '~/x' "line1
line2"; do
  rd set K "$v" >/dev/null 2>&1
  check "set/get round trip: $(printf '%s' "$v" | tr '\n' '|')" "$(rd get K)" "$v"
done
rd set EMPTY "" >/dev/null 2>&1
rd has EMPTY && pass "an empty value is present" || fail "an empty value reads as absent"
check "an empty value reads back empty" "$(rd get EMPTY)" ""

# A value spanning lines must not create keys out of its own content.
rd set MULTI "first
PHANTOM=injected" >/dev/null 2>&1
rd has PHANTOM && fail "a line inside a quoted value was read as a key" \
  || pass "a line inside a quoted value is not a key"

# Plain dotenv lines written by hand.
cat > "$RD/.agent-vm.env" <<'EOF'
# a comment
A=plain

export B=exported
  C="double quoted"
D=value # trailing comment
E='a'"b"c
F=first
F=second
EOF
printf 'G=crlf\r\n\r\n' >> "$RD/.agent-vm.env"
cat >> "$RD/.agent-vm.env" <<'EOF'
H=~/somewhere
I="$HOME"
EOF
check "plain value"                  "$(rd get A)" "plain"
check "export prefix"                "$(rd get B)" "exported"
check "leading blanks, double quotes" "$(rd get C)" "double quoted"
check "trailing comment"             "$(rd get D)" "value"
check "concatenated quoting"         "$(rd get E)" "abc"
check "the last assignment wins"     "$(rd get F)" "second"
check "a CRLF line ending is dropped" "$(rd get G)" "crlf"
rd get H >/dev/null 2>&1
check "an unquoted ~ (host-dependent) is refused" "$?" "2"
rd get I >/dev/null 2>&1
check "an expansion inside double quotes is refused" "$?" "2"
rd get NOT_THERE >/dev/null 2>&1
check "an absent key exits 1" "$?" "1"

# From a refused line on, the rest of the file is unreadable: the shell may
# read the next lines as part of that value, or run them as code. A key named
# after it is refused, not answered from lines the shell does not read as such.
printf 'A=before\nX="line1\nY=evil\n"\nZ=a\\\nW=b\n' > "$RD/.agent-vm.env"
check "the shell reads Y as part of X's value" \
  "$(set -a; . "$RD/.agent-vm.env" 2>/dev/null; printf '%s' "${Y:-unset}")" "unset"
rd get Y >/dev/null 2>&1
check "a key inside an open double quote is refused" "$?" "2"
rd get W >/dev/null 2>&1
check "a key after a backslash continuation is refused" "$?" "2"
check "a key before the refused line still reads" "$(rd get A)" "before"
rd get NOT_THERE >/dev/null 2>&1
check "a key named nowhere is still absent" "$?" "1"
printf 'A=1\nsource ./other\nunset A\n' > "$RD/.agent-vm.env"
rd get A >/dev/null 2>&1
check "a line of code counts as refused: a key named after it is refused" "$?" "2"
printf 'A=1\nB=2;A=3\n' > "$RD/.agent-vm.env"
rd get A >/dev/null 2>&1
check "a key assigned later on a refused line is refused" "$?" "2"

# =============================================================================
section "env set/unset replace a multi-line value whole"
# =============================================================================
# Dropping only the first line of a value spanning lines left its tail, an
# unterminated quote: the file then failed to source in the VM, losing every
# key after it, while `get` still answered.
: > "$RD/.agent-vm.env"
rd set A 'a' >/dev/null 2>&1
rd set K "line1
PHANTOM=x" >/dev/null 2>&1
rd set B 'b' >/dev/null 2>&1
rd set K new >/dev/null 2>&1
sourced="$(set -a; . "$RD/.agent-vm.env" 2>&1; set +a; printf '%s|%s|%s' "${A:-}" "${B:-}" "${K:-}")"
check "set over a multi-line value: the file still sources, every key intact" "$sourced" "a|b|new"
check "list: a line inside a value is not a key" "$(rd list | tr '\n' ' ')" "A B K "
rd set K "line1
line2" >/dev/null 2>&1
rd unset K >/dev/null 2>&1
check "unset of a multi-line value leaves nothing behind" "$(cat "$RD/.agent-vm.env")" "A='a'
B='b'"
printf 'export E=1\nE2="two\nlines"\n' >> "$RD/.agent-vm.env"
rd unset E >/dev/null 2>&1
rd has E && fail "unset left an 'export E=' line" || pass "unset removes an 'export KEY=' line too"
rd unset E2 >/dev/null 2>&1
check "a double-quoted value over two lines goes whole" "$(cat "$RD/.agent-vm.env")" "A='a'
B='b'"
check "list names each key once" \
  "$(printf "X=1\nX=2\nexport Y=3\n" > "$SB/envlist"; _agent_vm_env env "$SB/envlist" "" list | tr '\n' ' ')" "X Y "

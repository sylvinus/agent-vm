#!/usr/bin/env bash
#
# agent-vm test suite.
#
#   ./test.sh
#
# Runs against a stub limactl in a throwaway HOME, so it never creates, starts
# or deletes a VM and never touches your real ~/.agent-vm. No network needed.
# What needs a real VM is in test-e2e.sh.
#
# tests/helpers.sh sets up the sandbox and the stubs, then every tests/NN-*.sh
# runs in order, in this one shell: later files use what earlier ones set up
# (the recording limactl of 11-recorded-commands.sh, for one).
#
# Also worth running under bash 3.2 (what macOS ships), which is stricter about
# empty array expansion under `set -u`:
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 ./test.sh

set -uo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"

. "$SELF_DIR/tests/helpers.sh"
for _test_file in "$SELF_DIR"/tests/[0-9]*.sh; do
  . "$_test_file"
done

printf '\n%s passed, %s failed\n' "$PASSED" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

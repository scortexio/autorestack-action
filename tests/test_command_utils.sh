#!/bin/bash
#
# Tests for the run/try/die wrappers. The property that matters: run aborts
# the whole script even where `set -e` is suppressed, i.e. inside an `if`
# condition, including the body of a function invoked as the condition. That
# is exactly where update-pr-stack.sh does most of its work, so `set -e`
# alone cannot be relied on there.

set -ueo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
fail() { echo "❌ $1"; exit 1; }
ok() { echo "✅ $1"; PASS=$((PASS+1)); }

# Baseline first, to document the trap that motivates run: with plain set -e,
# a failure inside a function called as an if-condition does NOT stop it.
OUT=$(bash -c '
    set -ueo pipefail
    f() { false; echo "after-false"; }
    if f; then :; fi
' 2>&1)
grep -q "after-false" <<<"$OUT" || fail "baseline: expected set -e to be suppressed in condition context"
ok "baseline: set -e is suppressed inside an if-condition function"

# run must abort both the function and the script from that same context.
STATUS=0
OUT=$(ROOT_DIR="$ROOT_DIR" bash -c '
    set -ueo pipefail
    source "$ROOT_DIR/command_utils.sh"
    f() { run false; echo "after-run"; }
    if f; then :; fi
    echo "survived"
' 2>&1) || STATUS=$?
[[ "$STATUS" -ne 0 ]] || fail "run: script should exit nonzero"
grep -q "after-run" <<<"$OUT" && fail "run: function continued after the failure"
grep -q "survived" <<<"$OUT" && fail "run: script continued after the failure"
grep -q "command failed" <<<"$OUT" || fail "run: no failure message printed"
ok "run aborts the script from a condition context"

# try hands the status back without aborting.
OUT=$(ROOT_DIR="$ROOT_DIR" bash -c '
    set -ueo pipefail
    source "$ROOT_DIR/command_utils.sh"
    if ! try false; then echo "handled"; fi
    try true || exit 9
    echo "done"
' 2>&1)
grep -q "handled" <<<"$OUT" || fail "try: failure status not handed to caller"
grep -q "done" <<<"$OUT" || fail "try: success path broken"
ok "try returns the status to the caller"

echo
echo "All command_utils tests passed 🎉 ($PASS)"

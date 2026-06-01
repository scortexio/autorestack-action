#!/bin/bash
#
# Tests for the conflict-resolved continuation path (continue_after_resolution).
#
# Focus: the run that resumes after a user pushes a conflict resolution must
# recover its state from the marker left in the conflict comment, and must NOT
# mutate the PR when the recorded state no longer applies (no marker, or the user
# manually retargeted the base). A previous version re-derived the state from
# `gh pr list` and, on a long-lived base, pushed a merge built against a
# non-existent branch before crashing.

set -ueo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
fail() { echo "❌ $1"; exit 1; }
ok() { echo "✅ $1"; PASS=$((PASS+1)); }

# Build a configurable gh mock in a temp dir. It records every invocation to
# $CALLS and is driven by env vars set per scenario:
#   MOCK_LABELS         newline-separated labels returned by `pr view --json labels`
#   MOCK_BASE           base branch returned by `pr view --json baseRefName`
#   MOCK_COMMENTS_FILE  file whose contents are returned by `pr view --json comments`
make_mock_gh() {
    local dir="$1"
    cat > "$dir/mock_gh.sh" <<'EOF'
#!/bin/bash
set -ueo pipefail
echo "gh $*" >> "$CALLS"
if [[ "$1 $2" == "pr view" ]]; then
    case "$*" in
        *--json\ labels*)   printf '%s\n' "${MOCK_LABELS:-}";;
        *--json\ baseRefName*) printf '%s\n' "${MOCK_BASE:-}";;
        *--json\ comments*) cat "${MOCK_COMMENTS_FILE:-/dev/null}";;
        *) echo "unhandled pr view: $*" >&2; exit 1;;
    esac
elif [[ "$1 $2" == "pr comment" ]]; then
    cat >/dev/null  # consume the -F - body
elif [[ "$1 $2" == "pr edit" ]]; then
    :
elif [[ "$1 $2" == "pr list" ]]; then
    :  # no sibling conflicts
elif [[ "$1 $2" == "label create" ]]; then
    :
else
    echo "unhandled gh: $*" >&2; exit 1
fi
EOF
    chmod +x "$dir/mock_gh.sh"
}

# Set up a fresh repo with a bare origin so real pushes are observable.
setup_repo() {
    WORK=$(mktemp -d)
    ORIGIN=$(mktemp -d)
    git init -q --bare "$ORIGIN"
    git init -q -b main "$WORK"
    cd "$WORK"
    git config user.email t@e.com && git config user.name t
    git remote add origin "$ORIGIN"

    echo base > f.txt && git add f.txt && git commit -qm initial
    SQUASH=$(git rev-parse HEAD)            # the squash commit lives on main/target
    git push -q origin main

    git checkout -q -b parent && git push -q origin parent   # merged parent branch
    git checkout -q -b child                                  # the PR under resolution
    echo child >> f.txt && git add f.txt && git commit -qm child
    git push -q origin child
    CHILD_BEFORE=$(git rev-parse child)
    CALLS="$WORK/calls.log"; : > "$CALLS"
    MOCK_DIR=$(mktemp -d); make_mock_gh "$MOCK_DIR"
}

run_resume() {
    env ACTION_MODE=conflict-resolved PR_BRANCH=child \
        GH="$MOCK_DIR/mock_gh.sh" \
        MOCK_LABELS="$MOCK_LABELS" MOCK_BASE="$MOCK_BASE" \
        MOCK_COMMENTS_FILE="$MOCK_COMMENTS_FILE" CALLS="$CALLS" \
        bash "$ROOT_DIR/update-pr-stack.sh" >"$WORK/out.log" 2>&1 || echo "EXIT=$?" >>"$WORK/out.log"
}

marker() { # base target squash
    printf '<!-- autorestack-state: base=%s target=%s squash=%s -->' "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
echo "### Scenario A: user manually retargeted the base -> no mutation"
setup_repo
MOCK_LABELS="autorestack-needs-conflict-resolution"
MOCK_BASE="spark"   # human changed it; marker says parent
MOCK_COMMENTS_FILE="$WORK/comments.txt"
{ echo "### conflict"; echo; marker parent main "$SQUASH"; } > "$MOCK_COMMENTS_FILE"
run_resume

grep -q "remove-label autorestack-needs-conflict-resolution" "$CALLS" || fail "A: label not removed"
grep -q "gh pr comment" "$CALLS" || fail "A: no explanatory comment posted"
grep -q -- "--base" "$CALLS" && fail "A: base must NOT be edited"
[[ "$(git -C "$WORK" rev-parse child)" == "$CHILD_BEFORE" ]] || fail "A: child branch was mutated"
[[ "$(git -C "$ORIGIN" rev-parse child)" == "$CHILD_BEFORE" ]] || fail "A: child was pushed"
ok "A: manual retarget detected, no branch mutation, label removed"

# ---------------------------------------------------------------------------
echo "### Scenario B: no state marker -> no mutation"
setup_repo
MOCK_LABELS="autorestack-needs-conflict-resolution"
MOCK_BASE="parent"
MOCK_COMMENTS_FILE="$WORK/comments.txt"
{ echo "### some old conflict comment with no marker"; } > "$MOCK_COMMENTS_FILE"
run_resume

grep -q "remove-label autorestack-needs-conflict-resolution" "$CALLS" || fail "B: label not removed"
grep -q -- "--base" "$CALLS" && fail "B: base must NOT be edited"
[[ "$(git -C "$ORIGIN" rev-parse child)" == "$CHILD_BEFORE" ]] || fail "B: child was pushed"
ok "B: missing marker handled, no branch mutation, label removed"

# ---------------------------------------------------------------------------
echo "### Scenario C: base matches and target exists -> resume, base before label"
setup_repo
# Make child already contain target(main) + squash so update_direct_target is a
# no-op and we exercise the push/retarget/label ordering directly.
git -C "$WORK" merge -q --no-edit main
git -C "$WORK" push -q origin child
MOCK_LABELS="autorestack-needs-conflict-resolution"
MOCK_BASE="parent"   # matches marker -> not a manual retarget
MOCK_COMMENTS_FILE="$WORK/comments.txt"
{ echo "### conflict"; echo; marker parent main "$SQUASH"; } > "$MOCK_COMMENTS_FILE"
run_resume

grep -q -- "pr edit child --base main" "$CALLS" || fail "C: base not retargeted to main"
grep -q "remove-label autorestack-needs-conflict-resolution" "$CALLS" || fail "C: label not removed"
base_line=$(grep -n -- "--base main" "$CALLS" | head -1 | cut -d: -f1)
label_line=$(grep -n "remove-label" "$CALLS" | head -1 | cut -d: -f1)
[[ "$base_line" -lt "$label_line" ]] || fail "C: base edit must come before label removal"
ok "C: resume retargets base then removes label"

echo
echo "All conflict-resume tests passed 🎉 ($PASS scenarios)"

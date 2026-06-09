#!/bin/bash
#
# Tests for the conflict-resolved continuation path (continue_after_resolution).
#
# Focus: the run that resumes after a user pushes a conflict resolution must
# recover its state from the marker left in the conflict comment, and must NOT
# mutate the PR when the recorded state no longer applies (no marker, or the user
# manually retargeted the base). A previous version re-derived the base pull
# request from the target branch, which made it sensitive to humans doing
# unexpected things such as changing the base branch manually.

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
#   MOCK_LABELS_FAIL    set to 1 to make `pr view --json labels` fail
#   MOCK_PR_LIST_FAIL   set to 1 to make `pr list` fail
make_mock_gh() {
    local dir="$1"
    cat > "$dir/mock_gh.sh" <<'EOF'
#!/bin/bash
set -ueo pipefail
echo "gh $*" >> "$CALLS"
if [[ "$1 $2" == "pr view" ]]; then
    case "$*" in
        *--json\ labels*)
            [[ "${MOCK_LABELS_FAIL:-}" == 1 ]] && { echo "mock gh: labels API down" >&2; exit 1; }
            printf '%s\n' "${MOCK_LABELS:-}";;
        *--json\ baseRefName*) printf '%s\n' "${MOCK_BASE:-}";;
        *--json\ comments*) cat "${MOCK_COMMENTS_FILE:-/dev/null}";;
        *) echo "unhandled pr view: $*" >&2; exit 1;;
    esac
elif [[ "$1 $2" == "pr comment" ]]; then
    cat >/dev/null  # consume the -F - body
elif [[ "$1 $2" == "pr edit" ]]; then
    :
elif [[ "$1 $2" == "pr list" ]]; then
    [[ "${MOCK_PR_LIST_FAIL:-}" == 1 ]] && { echo "mock gh: pr list API down" >&2; exit 1; }
    :  # no sibling conflicts
elif [[ "$1 $2" == "label create" ]]; then
    :
else
    echo "unhandled gh: $*" >&2; exit 1
fi
EOF
    chmod +x "$dir/mock_gh.sh"
}

make_mock_git() {
    local dir="$1"
    cat > "$dir/mock_git.sh" <<'EOF'
#!/bin/bash
set -ueo pipefail
echo "git $*" >> "$CALLS"
exec git "$@"
EOF
    chmod +x "$dir/mock_git.sh"
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
    MOCK_DIR=$(mktemp -d)
    make_mock_gh "$MOCK_DIR"
    make_mock_git "$MOCK_DIR"
}

run_resume() {
    env ACTION_MODE=conflict-resolved PR_BRANCH=child \
        GH="$MOCK_DIR/mock_gh.sh" GIT="$MOCK_DIR/mock_git.sh" \
        MOCK_LABELS="$MOCK_LABELS" MOCK_BASE="$MOCK_BASE" \
        MOCK_COMMENTS_FILE="$MOCK_COMMENTS_FILE" CALLS="$CALLS" \
        MOCK_LABELS_FAIL="${MOCK_LABELS_FAIL:-}" MOCK_PR_LIST_FAIL="${MOCK_PR_LIST_FAIL:-}" \
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
echo "### Scenario C: base matches and target exists -> resume, push before base before label"
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

grep -q -- "git push origin child" "$CALLS" || fail "C: child not pushed"
grep -q -- "pr edit child --base main" "$CALLS" || fail "C: base not retargeted to main"
grep -q "remove-label autorestack-needs-conflict-resolution" "$CALLS" || fail "C: label not removed"
push_line=$(grep -n -- "git push origin child" "$CALLS" | head -1 | cut -d: -f1)
base_line=$(grep -n -- "--base main" "$CALLS" | head -1 | cut -d: -f1)
label_line=$(grep -n "remove-label" "$CALLS" | head -1 | cut -d: -f1)
[[ "$push_line" -lt "$base_line" ]] || fail "C: push must come before base edit"
[[ "$base_line" -lt "$label_line" ]] || fail "C: base edit must come before label removal"
ok "C: resume pushes, retargets base, then removes label"

# ---------------------------------------------------------------------------
echo "### Scenario D: recorded target branch is gone -> give up cleanly"
setup_repo
MOCK_LABELS="autorestack-needs-conflict-resolution"
MOCK_BASE="parent"   # matches marker -> not a manual retarget
MOCK_COMMENTS_FILE="$WORK/comments.txt"
{ echo "### conflict"; echo; marker parent ghost-target "$SQUASH"; } > "$MOCK_COMMENTS_FILE"
run_resume

grep -q "remove-label autorestack-needs-conflict-resolution" "$CALLS" || fail "D: label not removed"
grep -q "gh pr comment" "$CALLS" || fail "D: no explanatory comment posted"
grep -q -- "--base" "$CALLS" && fail "D: base must NOT be edited"
[[ "$(git -C "$ORIGIN" rev-parse child)" == "$CHILD_BEFORE" ]] || fail "D: child was pushed"
ok "D: missing target detected, no branch mutation, label removed"

# ---------------------------------------------------------------------------
echo "### Scenario E: recorded base branch is gone -> give up cleanly, no crash"
setup_repo
# Advance main with the squash commit so the child is not already up to date and
# the resume would actually reach the merge step.
git checkout -q main
echo squash > s.txt && git add s.txt && git commit -qm squash
SQUASH2=$(git rev-parse main)
git push -q origin main
git checkout -q child
# The kept parent branch was deleted (auto-delete head branches left enabled, or
# manual deletion). Before the up-front check, the resume tried to merge the
# missing ref, failed `git merge --abort` because no merge was in progress, and
# exited nonzero after re-posting a misleading conflict comment and the label,
# repeating on every push.
git push -q origin ":parent"
MOCK_LABELS="autorestack-needs-conflict-resolution"
MOCK_BASE="parent"   # matches marker -> not a manual retarget
MOCK_COMMENTS_FILE="$WORK/comments.txt"
{ echo "### conflict"; echo; marker parent main "$SQUASH2"; } > "$MOCK_COMMENTS_FILE"
run_resume

grep -q "EXIT=" "$WORK/out.log" && fail "E: script exited nonzero: $(cat "$WORK/out.log")"
grep -q "remove-label autorestack-needs-conflict-resolution" "$CALLS" || fail "E: label not removed"
grep -q -- "add-label" "$CALLS" && fail "E: conflict label must NOT be re-added"
grep -q "gh pr comment" "$CALLS" || fail "E: no explanatory comment posted"
grep -q -- "--base" "$CALLS" && fail "E: base must NOT be edited"
[[ "$(git -C "$ORIGIN" rev-parse child)" == "$CHILD_BEFORE" ]] || fail "E: child was pushed"
ok "E: missing base branch detected, no crash, label removed"

# ---------------------------------------------------------------------------
echo "### Scenario F: reading the PR comments fails -> fail the run, keep the label"
setup_repo
# A transient API failure while reading the comments must not pass for "no
# state marker": that path removes the conflict label and permanently cancels
# the auto-resume. The run must fail loudly instead, so the next push retries.
MOCK_LABELS="autorestack-needs-conflict-resolution"
MOCK_BASE="parent"
MOCK_COMMENTS_FILE="$WORK/does-not-exist"   # makes the mock gh fail on pr view --json comments
run_resume

grep -q "EXIT=" "$WORK/out.log" || fail "F: run should have failed"
grep -q "remove-label" "$CALLS" && fail "F: label must NOT be removed on an API failure"
grep -q "gh pr comment" "$CALLS" && fail "F: no comment must be posted on an API failure"
[[ "$(git -C "$ORIGIN" rev-parse child)" == "$CHILD_BEFORE" ]] || fail "F: child was pushed"
ok "F: API failure fails the run and keeps the resume armed"

# ---------------------------------------------------------------------------
echo "### Scenario G: reading the labels fails -> fail the run, do nothing"
setup_repo
# An API failure must not pass for "no conflict label": that ends the run
# green without resuming anything.
MOCK_LABELS=""
MOCK_LABELS_FAIL=1
MOCK_BASE="parent"
MOCK_COMMENTS_FILE="$WORK/comments.txt"
{ echo "### conflict"; echo; marker parent main "$SQUASH"; } > "$MOCK_COMMENTS_FILE"
run_resume

grep -q "EXIT=" "$WORK/out.log" || fail "G: run should have failed, not ended green"
grep -q "remove-label" "$CALLS" && fail "G: label must NOT be touched on an API failure"
[[ "$(git -C "$ORIGIN" rev-parse child)" == "$CHILD_BEFORE" ]] || fail "G: child was pushed"
ok "G: labels API failure fails the run instead of skipping the resume"

# ---------------------------------------------------------------------------
echo "### Scenario H: listing sibling conflicts fails -> keep the old base branch"
setup_repo
# Same successful-resume setup as scenario C, but the sibling listing that
# decides whether the old base branch can be deleted fails. Answering "no
# siblings" there would delete a branch another conflicted PR still needs.
git -C "$WORK" merge -q --no-edit main
git -C "$WORK" push -q origin child
MOCK_LABELS="autorestack-needs-conflict-resolution"
MOCK_LABELS_FAIL=""
MOCK_BASE="parent"
MOCK_PR_LIST_FAIL=1
MOCK_COMMENTS_FILE="$WORK/comments.txt"
{ echo "### conflict"; echo; marker parent main "$SQUASH"; } > "$MOCK_COMMENTS_FILE"
run_resume

grep -q "EXIT=" "$WORK/out.log" || fail "H: run should have failed"
git -C "$ORIGIN" rev-parse --verify -q parent >/dev/null || fail "H: old base branch was deleted on an API failure"
grep -q -- "push origin :parent" "$CALLS" && fail "H: deletion must not be attempted"
ok "H: sibling-listing API failure keeps the old base branch"

echo
echo "All conflict-resume tests passed 🎉 ($PASS scenarios)"

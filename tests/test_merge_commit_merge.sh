#!/bin/bash
#
# A PR merged with a merge commit (not squashed) keeps its history, so stacked
# children already contain the parent's commits and their heads must not be
# rewritten. The action only retargets the children and deletes the merged
# branch.

set -ueo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../command_utils.sh"

simulate_push() {
    log_cmd git update-ref "refs/remotes/origin/$1" "$1"
}

TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
echo "Created test repo at $TEST_REPO"

log_cmd git init -b main
log_cmd git config user.email "test@example.com"
log_cmd git config user.name "Test User"

echo "line" > file.txt
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
simulate_push main

log_cmd git checkout -b feature1
echo "f1" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 1"
simulate_push feature1

log_cmd git checkout -b feature2
echo "f2" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 2"
simulate_push feature2

# Merge feature1 into main with a real merge commit
log_cmd git checkout main
log_cmd git merge --no-ff --no-edit feature1
MERGE_COMMIT=$(git rev-parse HEAD)
simulate_push main

FEATURE2_BEFORE=$(git rev-parse feature2)

OUT=$(env \
    SQUASH_COMMIT="$MERGE_COMMIT" \
    MERGED_BRANCH=feature1 \
    PR_NUMBER=1 \
    TARGET_BRANCH=main \
    GH="$SCRIPT_DIR/mock_gh.sh" \
    GIT="$SCRIPT_DIR/mock_git.sh" \
    "$SCRIPT_DIR/../update-pr-stack.sh" 2>&1)
echo "$OUT"

if ! grep -q "merged with a merge commit" <<<"$OUT"; then
    echo "❌ Expected the merge-commit message"
    exit 1
fi
if [[ "$(git rev-parse feature2)" != "$FEATURE2_BEFORE" ]]; then
    echo "❌ feature2's head must not be rewritten"
    exit 1
fi

# Children must be retargeted before the merged branch is deleted (deleting a
# PR's base branch closes the PR).
EDIT_LINE=$(grep -n "pr edit 2 --base main" <<<"$OUT" | cut -d: -f1 | head -1 || true)
DELETE_LINE=$(grep -n "push origin :feature1" <<<"$OUT" | cut -d: -f1 | head -1 || true)
if [[ -z "$EDIT_LINE" ]]; then
    echo "❌ Child PR must be retargeted onto main"
    exit 1
fi
if [[ -z "$DELETE_LINE" ]]; then
    echo "❌ Merged branch must be deleted"
    exit 1
fi
if [[ "$EDIT_LINE" -gt "$DELETE_LINE" ]]; then
    echo "❌ Retarget must happen before the branch deletion (edit=$EDIT_LINE delete=$DELETE_LINE)"
    exit 1
fi

# The served-diff verification is advisory, so it must come after the
# deletion, the last mutation the run owes the stack.
VERIFY_LINE=$(grep -n "✓ GitHub serves the expected diff for PR #2" <<<"$OUT" | cut -d: -f1 | head -1 || true)
if [[ -z "$VERIFY_LINE" ]]; then
    echo "❌ Served diff must be verified after the retarget"
    exit 1
fi
if [[ "$VERIFY_LINE" -lt "$DELETE_LINE" ]]; then
    echo "❌ Verification must come after the branch deletion (verify=$VERIFY_LINE delete=$DELETE_LINE)"
    exit 1
fi

# The untouched head keeps a clean diff against the new base
ACTUAL_DIFF=$(git diff main...feature2 | grep '^[+-]' | grep -v '^[+-][+-][+-]')
if [[ "$ACTUAL_DIFF" != "+f2" ]]; then
    echo "❌ Diff main...feature2 should show only feature2's change, got:"
    echo "$ACTUAL_DIFF"
    exit 1
fi

echo "✅ Merge-commit merge: children retargeted, heads untouched, branch deleted"

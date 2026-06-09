#!/bin/bash
#
# A PR merged with a merge commit (not squashed) must be left alone: history is
# not rewritten, so stacked children stay valid and need no synthetic merge.

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
    TARGET_BRANCH=main \
    GH="$SCRIPT_DIR/mock_gh.sh" \
    GIT="$SCRIPT_DIR/mock_git.sh" \
    "$SCRIPT_DIR/../update-pr-stack.sh" 2>&1)
echo "$OUT"

if ! grep -q "merged with a merge commit" <<<"$OUT"; then
    echo "❌ Expected the merge-commit skip message"
    exit 1
fi
if grep -q "pr edit" <<<"$OUT"; then
    echo "❌ No PR must be retargeted"
    exit 1
fi
if [[ "$(git rev-parse feature2)" != "$FEATURE2_BEFORE" ]]; then
    echo "❌ feature2 must not be modified"
    exit 1
fi
echo "✅ Merge-commit merge skipped, stack untouched"

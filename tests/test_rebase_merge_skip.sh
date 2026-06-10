#!/bin/bash
#
# A PR merged with "Rebase and merge" is not supported: the commits on the
# target are new copies, so neither retargeting children as-is nor the squash
# sequence gives a correct result. The action must detect the rebase (the
# commit below the merge sha was also introduced by this PR, per GitHub's
# commit-PR association), comment on the children, and leave the stack alone.

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

for i in $(seq 1 15); do echo "line $i" >> file.txt; done
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
simulate_push main

# feature1: two commits, so the rebase leaves a copy below the merge sha
log_cmd git checkout -b feature1
sed -i '2s/.*/Feature 1 change A/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature1: commit A"
sed -i '6s/.*/Feature 1 change B/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature1: commit B"
simulate_push feature1

log_cmd git checkout -b feature2
sed -i '14s/.*/Feature 2 content/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature2: change"
simulate_push feature2

# main advances independently, then feature1 is rebase-merged: GitHub copies
# each PR commit onto the target, which cherry-pick reproduces
log_cmd git checkout main
sed -i '10s/.*/Main hotfix/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "main: hotfix"
log_cmd git cherry-pick feature1~1 feature1
MERGE_COMMIT=$(git rev-parse HEAD)
simulate_push main

FEATURE2_BEFORE=$(git rev-parse feature2)

OUT=$(env \
    SQUASH_COMMIT="$MERGE_COMMIT" \
    MERGED_BRANCH=feature1 \
    PR_NUMBER=1 \
    TARGET_BRANCH=main \
    MOCK_REBASE_COPIES="$(git rev-parse "$MERGE_COMMIT~")" \
    GH="$SCRIPT_DIR/mock_gh.sh" \
    GIT="$SCRIPT_DIR/mock_git.sh" \
    "$SCRIPT_DIR/../update-pr-stack.sh" 2>&1)
echo "$OUT"

if ! grep -q "rebase merges are not supported" <<<"$OUT"; then
    echo "❌ Expected the rebase-merge skip message"
    exit 1
fi
if ! grep -q "Mock: gh pr comment 2" <<<"$OUT"; then
    echo "❌ The child PR must be told the stack was not updated"
    exit 1
fi
if grep -q "pr edit" <<<"$OUT"; then
    echo "❌ No PR must be retargeted"
    exit 1
fi
if grep -q "push origin :feature1" <<<"$OUT"; then
    echo "❌ The merged branch must be kept"
    exit 1
fi
if [[ "$(git rev-parse feature2)" != "$FEATURE2_BEFORE" ]]; then
    echo "❌ feature2's head must not be rewritten"
    exit 1
fi

echo "✅ Rebase merge detected: children warned, stack left alone"

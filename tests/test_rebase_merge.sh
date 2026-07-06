#!/bin/bash
#
# A PR merged with "Rebase and merge" lands its commits as new copies on the
# target, exactly like a squash spread over several commits: content without
# history. The action treats it like a squash: SQUASH_COMMIT (the PR's
# merge_commit_sha) is the last copy, and the child is re-parented onto it in
# one merge. The intermediate copies never enter the 3-way merge, so they can
# raise no spurious conflicts.

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

# feature1: two commits, so the rebase leaves an intermediate copy below the
# merge sha
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

OUT=$(env \
    SQUASH_COMMIT="$MERGE_COMMIT" \
    MERGED_BRANCH=feature1 \
    PR_NUMBER=1 \
    TARGET_BRANCH=main \
    GH="$SCRIPT_DIR/mock_gh.sh" \
    GIT="$SCRIPT_DIR/mock_git.sh" \
    "$SCRIPT_DIR/../update-pr-stack.sh" 2>&1)
echo "$OUT"

if ! git merge-base --is-ancestor "$MERGE_COMMIT" feature2; then
    echo "❌ feature2 must be re-parented onto the rebased tip"
    log_cmd git log --graph --oneline --all
    exit 1
fi
if ! grep -q "Mock: gh pr edit 2 --base main" <<<"$OUT"; then
    echo "❌ The child PR must be retargeted to main"
    exit 1
fi
if ! grep -q "push origin :feature1" <<<"$OUT"; then
    echo "❌ The merged branch must be deleted"
    exit 1
fi

# The child's PR diff against its new base shows only its own change: the
# parent's changes arrive through the rebased copies on main, not the diff.
EXPECTED_DIFF=$(cat <<'EOF'
-line 14
+Feature 2 content
EOF
)
ACTUAL_DIFF=$(log_cmd git diff main...feature2 | grep '^[+-]' | grep -v '^[+-][+-][+-]')
if [[ "$ACTUAL_DIFF" == "$EXPECTED_DIFF" ]]; then
    echo "✅ Triple-dot diff main...feature2 shows only feature2's unique change"
else
    echo "❌ Triple-dot diff is wrong"
    echo "Expected:"
    echo "$EXPECTED_DIFF"
    echo "Actual:"
    echo "$ACTUAL_DIFF"
    exit 1
fi

echo "✅ Rebase merge handled like a squash: child re-parented, retargeted, branch deleted"

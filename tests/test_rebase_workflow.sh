#!/bin/bash
#
# Test that the update-pr-stack mechanism works when PRs are rebased during
# development (as opposed to using merge commits to sync with the parent).
#
# Scenario:
#   1. main ← feature1 ← feature2 (linear stack)
#   2. feature1 gets an additional commit AFTER feature2 was branched
#   3. Developer rebases feature2 onto the updated feature1
#   4. feature1 is squash-merged into main
#   5. Action runs → feature2 should get a correct PR diff against main

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../command_utils.sh"

simulate_push() {
    local branch_name="$1"
    log_cmd git update-ref "refs/remotes/origin/$branch_name" "$branch_name"
}

TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
echo "Created test repo at $TEST_REPO"

log_cmd git init -b main
log_cmd git config user.email "test@example.com"
log_cmd git config user.name "Test User"

# Initial commit on main — use enough lines to avoid adjacent-change conflicts
for i in $(seq 1 10); do echo "line $i" >> file.txt; done
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
simulate_push main

# feature1: modify line 2 (top region)
log_cmd git checkout -b feature1
sed -i '2s/.*/Feature 1 first change/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature1: first commit"
simulate_push feature1

# feature2: branched from feature1, modify line 9 (bottom region, far away)
log_cmd git checkout -b feature2
sed -i '9s/.*/Feature 2 content/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature2: change line 9"
simulate_push feature2

# Now feature1 gets an additional commit modifying line 3 (still top region)
log_cmd git checkout feature1
sed -i '3s/.*/Feature 1 second change/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature1: second commit"
simulate_push feature1

FEATURE1_TIP=$(git rev-parse HEAD)

# Developer rebases feature2 onto the updated feature1
log_cmd git checkout feature2
log_cmd git rebase feature1
simulate_push feature2

echo ""
echo "=== State before squash-merge ==="
log_cmd git log --graph --oneline --all
echo ""

# Squash-merge feature1 into main (simulated via cherry-pick --no-commit + commit)
log_cmd git checkout main
# Use merge --squash to properly squash all of feature1's commits
log_cmd git merge --squash feature1
log_cmd git commit -m "Squash merge feature1"
SQUASH_COMMIT=$(git rev-parse HEAD)
simulate_push main

echo ""
echo "Squash commit: $SQUASH_COMMIT"
echo ""

# Run the action
run_update_pr_stack() {
  log_cmd \
    env \
    SQUASH_COMMIT=$SQUASH_COMMIT \
    MERGED_BRANCH=feature1 \
    TARGET_BRANCH=main \
    GH="$SCRIPT_DIR/mock_gh.sh" \
    GIT="$SCRIPT_DIR/mock_git.sh" \
    $SCRIPT_DIR/../update-pr-stack.sh
}
run_update_pr_stack

cd "$TEST_REPO"

# Verify: squash commit is an ancestor of feature2
if log_cmd git merge-base --is-ancestor "$SQUASH_COMMIT" feature2; then
    echo "✅ feature2 includes the squash commit"
else
    echo "❌ feature2 does not include the squash commit"
    log_cmd git log --graph --oneline --all
    exit 1
fi

# Verify: triple-dot diff main...feature2 shows ONLY feature2's unique change
# We expect the diff to show only feature2's unique change (line 9).
# Strip index lines and hunk header function-name context for stable comparison.
EXPECTED_DIFF=$(cat <<'EOF'
-line 9
+Feature 2 content
EOF
)
ACTUAL_DIFF=$(log_cmd git diff main...feature2 | grep '^[+-]' | grep -v '^[+-][+-][+-]')
if [[ "$ACTUAL_DIFF" == "$EXPECTED_DIFF" ]]; then
    echo "✅ Triple-dot diff main...feature2 shows only feature2's unique changes"
else
    echo "❌ Triple-dot diff is wrong"
    echo "Expected:"
    echo "$EXPECTED_DIFF"
    echo "Actual:"
    echo "$ACTUAL_DIFF"
    diff <(echo "$EXPECTED_DIFF") <(echo "$ACTUAL_DIFF") || true
    exit 1
fi

# Verify idempotence
FEATURE2_BEFORE=$(git rev-parse feature2)
run_update_pr_stack
cd "$TEST_REPO"
FEATURE2_AFTER=$(git rev-parse feature2)

if [[ "$FEATURE2_BEFORE" == "$FEATURE2_AFTER" ]]; then
    echo "✅ Idempotence: re-running produces no new commits"
else
    echo "❌ Idempotence failed"
    exit 1
fi

echo ""
echo "All rebase-workflow tests passed! 🎉"
echo "Test repository remains at: $TEST_REPO for inspection"

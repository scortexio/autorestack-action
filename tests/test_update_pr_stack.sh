#!/bin/bash

set -eo pipefail

# Get script directory (needed for static mock files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source command utils from the project root to get log_cmd early
# Assuming command_utils.sh is one level up from the tests directory
source "$SCRIPT_DIR/../command_utils.sh"

# Helper function to simulate 'git push origin <branch>'
simulate_push() {
    local branch_name="$1"
    # Use the helper log_cmd for consistency
    log_cmd git update-ref "refs/remotes/origin/$branch_name" "$branch_name"
}

# Create a temporary directory for the test repository
TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
echo "Created test repo at $TEST_REPO"

# Initialize a repo, set the initial branch name to main, and set up basic config
log_cmd git init -b main
log_cmd git config user.email "test@example.com"
log_cmd git config user.name "Test User"

# Create initial commit on main branch
echo "Initial line 1" > file.txt
echo "Initial line 2" >> file.txt
echo "Initial line 3" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
simulate_push main

# Create feature1 branch - Modify line 2
log_cmd git checkout -b feature1
sed -i '2s/.*/Feature 1 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 1"
simulate_push feature1

# Make a note of the commit we'll squash/cherry-pick
FEATURE1_COMMIT=$(log_cmd git rev-parse HEAD)

# Create feature2 branch based on feature1 - Modify line 2
log_cmd git checkout -b feature2
sed -i '2s/.*/Feature 2 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 2"
simulate_push feature2

# Create feature3 branch based on feature2 - Modify line 2
log_cmd git checkout -b feature3
sed -i '2s/.*/Feature 3 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 3"
simulate_push feature3

# Simulate a squash merge of feature1 into main by cherry-picking. -x changes
# the commit message: a plain cherry-pick landing in the same second as the
# original commit reproduces feature1's sha exactly, and the script then skips
# the whole re-parenting as already done, silently testing nothing.
log_cmd git checkout main
log_cmd git cherry-pick -x "$FEATURE1_COMMIT"
# The cherry-pick creates a *new* commit on main, simulating the squash merge result
SQUASH_COMMIT=$(log_cmd git rev-parse HEAD) # Get the hash of the new commit on main
simulate_push main # Update origin/main to include the squash commit

echo "Simulated Squash commit (via cherry-pick): $SQUASH_COMMIT"

# Run the update-pr-stack.sh script with our mocked gh command

echo "Running update-pr-stack.sh..."
# The update script sources command_utils.sh itself
# Capture stdout+stderr interleaved so command ordering can be asserted.
# Outside the test repo: an untracked file makes git-merge-onto refuse to run.
RUN_LOG=$(mktemp)
run_update_pr_stack() {
  log_cmd \
    env \
    SQUASH_COMMIT=$SQUASH_COMMIT \
    MERGED_BRANCH=feature1 \
    PR_NUMBER=1 \
    TARGET_BRANCH=main \
    GH="$SCRIPT_DIR/mock_gh.sh" \
    GIT="$SCRIPT_DIR/mock_git.sh" \
    $SCRIPT_DIR/../update-pr-stack.sh 2>&1 | tee "$RUN_LOG"
}
run_update_pr_stack

# The head must be pushed before the PR is retargeted (a failed push must leave
# the PR untouched on its old base), and the merged branch deleted only after
# the retarget (deleting a PR's base branch closes the PR).
push_line=$(grep -n "git push origin feature2" "$RUN_LOG" | head -1 | cut -d: -f1 || true)
edit_line=$(grep -n "pr edit 2 --base main" "$RUN_LOG" | head -1 | cut -d: -f1 || true)
delete_line=$(grep -n "git push origin :feature1" "$RUN_LOG" | head -1 | cut -d: -f1 || true)
if [[ -n "$push_line" && -n "$edit_line" && -n "$delete_line" \
      && "$push_line" -lt "$edit_line" && "$edit_line" -lt "$delete_line" ]]; then
    echo "✅ Ordering: push head, then retarget base, then delete merged branch"
else
    echo "❌ Wrong ordering (push=$push_line edit=$edit_line delete=$delete_line)"
    exit 1
fi

# Verify the results
cd "$TEST_REPO"

# Test if the squash commit is incorporated into feature2
if log_cmd git merge-base --is-ancestor "$SQUASH_COMMIT" feature2; then
    echo "✅ feature2 includes the squash commit"
else
    echo "❌ feature2 does not include the squash commit"
    log_cmd git log --graph --oneline --all
    exit 1
fi

# Verify feature3 is NOT modified (indirect children are not updated)
# We stored the original SHA before running the script, now verify it hasn't changed
FEATURE3_AFTER=$(log_cmd git rev-parse feature3)
FEATURE3_BEFORE=$(log_cmd git rev-parse origin/feature3)
if [[ "$FEATURE3_AFTER" == "$FEATURE3_BEFORE" ]]; then
    echo "✅ feature3 remains unchanged (indirect children not updated)"
else
    echo "❌ feature3 was modified unexpectedly"
    exit 1
fi

# Show the contents of feature2 to verify it contains the expected changes
echo -e "\nContent of feature2 branch:"
log_cmd git show feature2:file.txt

# Test triple dot diff on feature2
# After rebase, the diff should only contain the changes unique to feature2
# In this conflict scenario, feature2's change should overwrite feature1's change
EXPECTED_DIFF2=$(cat <<EOF
diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,3 @@
 Initial line 1
-Feature 1 content line 2
+Feature 2 content line 2
 Initial line 3
EOF
)
ACTUAL_DIFF2=$(log_cmd git diff main...feature2 | grep -v '^index')
if [[ "$ACTUAL_DIFF2" == "$EXPECTED_DIFF2" ]]; then
    echo "✅ Triple dot diff for feature2 shows expected changes"
else
    echo "❌ Triple dot diff for feature2 doesn't show expected changes"
    echo "Expected:"
    echo "$EXPECTED_DIFF2"
    echo "Actual:"
    echo "$ACTUAL_DIFF2"
    echo "Diff:"
    diff <(
    echo "$EXPECTED_DIFF2"
    ) <(
    echo "$ACTUAL_DIFF2"
    )
    exit 1
fi


# Test triple dot diff on feature3 relative to feature2 (simulates PR diff)
# Even though feature3 was NOT updated, its diff vs feature2 should remain correct
# because the merge-base calculation still works (feature2's synthetic merge has
# the original feature2 commit as a parent via BEFORE_MERGE)
EXPECTED_DIFF3=$(cat <<EOF
diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,3 @@
 Initial line 1
-Feature 2 content line 2
+Feature 3 content line 2
 Initial line 3
EOF
)
ACTUAL_DIFF3=$(log_cmd git diff feature2...feature3 | grep -v '^index')
if [[ "$ACTUAL_DIFF3" == "$EXPECTED_DIFF3" ]]; then
    echo "✅ Triple dot diff for feature3 (vs feature2) shows expected changes"
else
    echo "❌ Triple dot diff for feature3 doesn't show expected changes"
    echo "Expected:"
    echo "$EXPECTED_DIFF3"
    echo "Actual:"
    echo "$ACTUAL_DIFF3"
    exit 1
fi


# Test idempotence by running the update again
echo -e "\nRunning update script again to test idempotence..."

# Store current commit hash for feature2 (the only branch modified by the action)
FEATURE2_COMMIT_BEFORE=$(log_cmd git rev-parse feature2)

# Run update script again with mocked push
run_update_pr_stack

# Check that no new commits were created
FEATURE2_COMMIT_AFTER=$(log_cmd git rev-parse feature2)

if [[ "$FEATURE2_COMMIT_BEFORE" == "$FEATURE2_COMMIT_AFTER" ]]; then
    echo "✅ Idempotence test passed for feature2"
else
    echo "❌ Idempotence test failed for feature2"
    log_cmd git log --graph --oneline --all
    exit 1
fi

echo -e "\nAll tests passed! 🎉"

# Clean up
# cd /tmp
# rm -rf "$TEST_REPO"
echo "Test repository remains at: $TEST_REPO for inspection"


#!/bin/bash
# =============================================================================
# End-to-End Test for the update-pr-stack Action
# =============================================================================
#
# PURPOSE:
# This test validates the full functionality of the update-pr-stack GitHub
# Action, which automatically updates stacked PRs after a base PR is merged.
#
# WARNING: This test creates and deletes a REAL GitHub repository.
# It requires a GITHUB_TOKEN environment variable with appropriate permissions:
# repo (full control), workflow, pull_request (write).
#
# =============================================================================
# TEST SCENARIOS
# =============================================================================
#
# SCENARIO 0: Diff Pollution Test (without action)
# -------------------------------------------------
# Proves that without the action, PR diffs become polluted when the base
# branch is deleted and GitHub auto-retargets to main.
#
# Setup:
#   - Enable "auto-delete head branches" repo setting
#   - Create 2-PR stack: main <- noact_feature1 <- noact_feature2
#   - Each PR modifies a different line (3 and 4)
#
# Test:
#   - Capture noact_feature2's initial diff (shows only its own 1-line change)
#   - Merge noact_feature1 (GitHub auto-deletes branch and retargets PR2 to main)
#   - Verify noact_feature2's diff is NOW POLLUTED (shows accumulated changes)
#
# Then disables auto-delete and installs the action for subsequent scenarios.
#
# SCENARIO 1: Nominal Linear Stack with Clean Merges (Steps 4-7)
# --------------------------------------------------------------
# Tests the happy path where PRs are merged without conflicts.
#
# Setup:
#   - Create a stack of 4 PRs: main <- feature1 <- feature2 <- feature3 <- feature4
#   - Each PR modifies line 2 (shared, accumulates) plus a unique line (3, 4, 5)
#
# Action Trigger:
#   - Squash merge PR1 (feature1) into main
#
# Expected Behavior:
#   - The action should detect that PR2 (feature2) was based on feature1
#   - Update PR2's base branch from feature1 to main
#   - Merge main into feature2 to incorporate the squash commit
#   - Delete the merged branch (feature1)
#   - NOTE: Indirect children (feature3, feature4) are NOT updated - their diffs
#     remain correct because the merge-base calculation works correctly
#
# Verifications:
#   - feature1 branch is deleted from remote
#   - PR2 base branch is updated from feature1 to main
#   - PR3 base branch remains feature2 (only direct children's base is updated)
#   - feature2 contains the squash merge commit (feature3/feature4 do NOT)
#   - PR diffs are IDENTICAL before and after (action preserves incremental diffs)
#
# SCENARIO 2: Conflict Handling (Steps 8-13)
# ------------------------------------------
# Tests the action's behavior when a merge conflict occurs.
#
# Setup:
#   - After Scenario 1, modify line 7 on feature3 and push
#   - Also modify line 7 on main with different content (creating a conflict)
#   - feature4 (grandchild) exists based on feature3
#
# Action Trigger:
#   - Squash merge PR2 (feature2) into main
#
# Expected Behavior:
#   - The action attempts to merge main into feature3
#   - Detects a merge conflict (both modified line 7 differently)
#   - Does NOT push any conflicted state to the remote
#   - Posts a comment on PR3 explaining the conflict
#   - Adds a label "autorestack-needs-conflict-resolution" to PR3
#   - Does NOT update PR3's base branch (keeps it as feature2 for readable diff)
#   - Does NOT delete feature2 branch (still referenced by conflicted PR)
#   - Exits with success (conflict is handled gracefully, not a failure)
#
# Verifications:
#   - feature2 branch is NOT deleted from remote (still referenced by conflicted PR3)
#   - PR3 base branch stays as feature2 (not updated to main)
#   - Conflict comment exists on PR3
#   - Conflict label "autorestack-needs-conflict-resolution" exists on PR3
#   - feature3 branch was NOT updated (still at pre-conflict SHA)
#
# Manual Conflict Resolution (Steps 12-15):
#   - Test simulates user resolving the conflict manually
#   - Merge main into feature3, resolve conflict (keep feature3's changes)
#   - Push the resolved branch
#   - The push triggers the 'synchronize' event on PR3
#   - The action detects the conflict label and removes it
#   - Updates PR3's base branch to main
#   - Deletes feature2 branch (no other conflicted PRs depend on it)
#   - NOTE: feature4 is NOT updated (indirect children are not modified)
#
# SCENARIO 4: Multi-child with 0 conflicts (Steps 23-25)
# -------------------------------------------------------
# Tests that when a PR with 2 children is merged and neither conflicts,
# both children are cleanly updated, diffs preserved, and old base deleted.
#
# SCENARIO 5: Multi-child with mixed outcome (Steps 26-28)
# ---------------------------------------------------------
# Tests that when one child conflicts and the other merges cleanly, the
# clean child is fully updated while the conflicted child keeps the old base.
# The old base branch is kept for the conflicted child.
#
# SCENARIO 6: No direct children / 0-child run (Steps 29-31)
# -----------------------------------------------------------
# Tests that merging a PR with no children simply deletes the branch
# and the action completes successfully.
#
# =============================================================================
set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Debugging: print commands as they are executed
# --- Configuration ---
# Temporary repository name prefix
REPO_PREFIX="temp-e2e-test-stack-"

# Generate a unique repository name
REPO_NAME=$(echo "$REPO_PREFIX$(date +%s)-$RANDOM" | tr '[:upper:]' '[:lower:]')

# Get GitHub username
# Default to 'autorestack-test' if GH_USER is not set or empty
: ${GH_USER:=autorestack-test}
REPO_FULL_NAME="$GH_USER/$REPO_NAME"

# Get the directory of the currently executing script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Source command utils for logging
source "$PROJECT_ROOT/command_utils.sh"

# Workflow file name
WORKFLOW_FILE="update-pr-stack.yml"

# --- Helper Functions ---
cleanup() {
  local exit_code=$?
  # If PRESERVE_ON_FAILURE is set and there was an error, skip cleanup
  if [[ "${PRESERVE_ON_FAILURE:-}" == "1" ]] && [[ $exit_code -ne 0 ]]; then
    echo >&2 "--- Preserving repo for debugging (PRESERVE_ON_FAILURE=1) ---"
    echo >&2 "Repo: $REPO_FULL_NAME"
    echo >&2 "Local dir: $TEST_DIR"
    return 0
  fi

  echo >&2 "--- Cleaning up ---"
  if [[ -d "$TEST_DIR" ]]; then
    echo >&2 "Removing local test directory: $TEST_DIR"
    rm -rf "$TEST_DIR"
  fi
  # Check if repo exists before attempting deletion
  if gh repo view "$REPO_FULL_NAME" &> /dev/null; then
      echo >&2 "Deleting remote GitHub repository: $REPO_FULL_NAME"
      if ! gh repo delete "$REPO_FULL_NAME" --yes; then
          echo >&2 "Failed to delete repository $REPO_FULL_NAME. Please delete it manually."
          else
          echo >&2 "Successfully deleted remote repository $REPO_FULL_NAME."
      fi
  else
      echo >&2 "Remote repository $REPO_FULL_NAME does not exist or was already deleted."
  fi

}

# Trap EXIT signal to ensure cleanup runs even if the script fails
trap cleanup EXIT


# Get the full PR diff from GitHub.
# This captures GitHub's view of what the PR changes (head vs base).
# Used to verify the action preserves correct diff semantics.
get_pr_diff() {
    local pr_url=$1
    gh pr diff "$pr_url" --repo "$REPO_FULL_NAME" 2>/dev/null
}

# Compare two diffs and return 0 if identical, 1 if different.
# Strips "index" lines (blob SHA pairs) since those change legitimately
# when the base branch changes.
compare_diffs() {
    local diff1="$1"
    local diff2="$2"
    local context="$3"

    local stripped1 stripped2
    stripped1=$(echo "$diff1" | grep -v '^index ')
    stripped2=$(echo "$diff2" | grep -v '^index ')

    if [[ "$stripped1" == "$stripped2" ]]; then
        echo >&2 "✅ Diffs match: $context"
        return 0
    else
        echo >&2 "❌ Diffs differ: $context"
        echo >&2 "--- Expected diff ---"
        echo "$diff1" >&2
        echo >&2 "--- Actual diff ---"
        echo "$diff2" >&2
        echo >&2 "--------------------"
        return 1
    fi
}

# Wait for a PR's base branch to change to the expected value.
# Uses retry loop instead of arbitrary sleep.
wait_for_pr_base_change() {
    local pr_number=$1
    local expected_base=$2
    local max_attempts=${3:-10}
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        local current_base
        current_base=$(gh pr view "$pr_number" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)

        if [[ "$current_base" == "$expected_base" ]]; then
            echo >&2 "✅ PR #$pr_number base is now '$expected_base'"
            return 0
        fi

        echo >&2 "Attempt $attempt/$max_attempts: PR #$pr_number base is '$current_base', waiting for '$expected_base'..."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo >&2 "❌ Timeout: PR #$pr_number base did not change to '$expected_base'"
    return 1
}

# Merge a PR with retry logic to handle transient "not mergeable" errors.
# After pushing to a PR's base branch, GitHub's mergeability computation is async
# and can take several seconds. During this time, merge attempts fail with
# "Pull Request is not mergeable" even when there's no actual conflict.
# See: https://github.com/cli/cli/issues/8092
#      https://github.com/orgs/community/discussions/24462
merge_pr_with_retry() {
    local pr_url=$1
    local max_attempts=5
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        echo >&2 "Merge attempt $attempt/$max_attempts for $pr_url..."

        if log_cmd gh pr merge "$pr_url" --squash --repo "$REPO_FULL_NAME" 2>&1; then
            echo >&2 "PR merged successfully on attempt $attempt."
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            local sleep_time=$((attempt * 2))
            echo >&2 "Merge failed, retrying in ${sleep_time}s..."
            sleep $sleep_time
        fi
    done

    echo >&2 "Failed to merge PR after $max_attempts attempts."
    return 1
}

wait_for_synchronize_workflow() {
    local pr_number=$1 # PR number that was updated
    local branch_name=$2 # The branch name that was pushed
    local expected_conclusion=${3:-success} # Expected conclusion (success, failure, etc.)
    local max_attempts=20 # ~7 mins max wait
    local attempt=0
    local target_run_id=""
    local start_time=$(date +%s)

    echo >&2 "Waiting for workflow '$WORKFLOW_FILE' triggered by synchronize event on PR #$pr_number (branch $branch_name)..."

    while [[ $attempt -lt $max_attempts ]]; do
        sleep_time=$(( (attempt + 1) * 2 ))
        echo >&2 "Attempt $((attempt + 1))/$max_attempts: Checking for workflow run..."

        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Searching for the specific workflow run..."
            # List recent runs for the workflow triggered by pull_request event
            candidate_run_ids=$(log_cmd gh run list \
                --repo "$REPO_FULL_NAME" \
                --workflow "$WORKFLOW_FILE" \
                --event pull_request \
                --limit 15 \
                --json databaseId,createdAt --jq '.[] | select(.createdAt >= "'$(date -u -d "@$start_time" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r $start_time +%Y-%m-%dT%H:%M:%SZ)'") | .databaseId' || echo "")

            if [[ -z "$candidate_run_ids" ]]; then
                echo >&2 "No recent '$WORKFLOW_FILE' runs found since start. Sleeping $sleep_time seconds."
                sleep $sleep_time
                attempt=$((attempt + 1))
                continue
            fi

            echo >&2 "Found candidate run IDs: $candidate_run_ids. Checking runs..."
            for run_id in $candidate_run_ids; do
                echo >&2 "Checking candidate run ID: $run_id"
                run_info=$(log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --json headBranch || echo "{}")

                run_head_branch=$(echo "$run_info" | jq -r '.headBranch // ""')

                echo >&2 "  Run head branch: $run_head_branch"

                if [[ "$run_head_branch" == "$branch_name" ]]; then
                    echo >&2 "Found matching workflow run ID: $run_id (branch matches)"
                    target_run_id="$run_id"
                    break
                fi
            done
        fi

        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Target workflow run not found among recent runs. Sleeping $sleep_time seconds."
            sleep $sleep_time
            attempt=$((attempt + 1))
            continue
        fi

        # Monitor the identified target run
        echo >&2 "Monitoring workflow run ID: $target_run_id"
        run_info=$(log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --json status,conclusion)
        run_status=$(echo "$run_info" | jq -r '.status')
        run_conclusion=$(echo "$run_info" | jq -r '.conclusion')

        echo >&2 "Workflow run $target_run_id status: $run_status, conclusion: $run_conclusion"

        if [[ "$run_status" == "completed" ]]; then
            if [[ "$run_conclusion" == "$expected_conclusion" ]]; then
                echo >&2 "Workflow $target_run_id completed with expected conclusion: $run_conclusion."
                return 0
            else
                echo >&2 "Workflow $target_run_id completed with unexpected conclusion: $run_conclusion (expected: $expected_conclusion)"
                log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $target_run_id"
                return 1
            fi
        elif [[ "$run_status" == "queued" || "$run_status" == "in_progress" || "$run_status" == "waiting" ]]; then
            echo >&2 "Workflow $target_run_id is $run_status. Sleeping $sleep_time seconds."
        else
            echo >&2 "Workflow $target_run_id has unexpected status: $run_status. Conclusion: $run_conclusion"
            log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $target_run_id"
            return 1
        fi

        sleep $sleep_time
        attempt=$((attempt + 1))
    done

    echo >&2 "Timeout waiting for synchronize workflow run to complete."
    gh run list --repo "$REPO_FULL_NAME" --workflow "$WORKFLOW_FILE" --limit 10 || echo >&2 "Could not list recent runs."
    return 1
}

wait_for_workflow() {
    local pr_number=$1 # PR number that was merged
    local merged_branch_name=$2 # The head branch name of the merged PR (unused now, but kept for context)
    local merge_commit_sha=$3 # The SHA of the merge commit
    local expected_conclusion=${4:-success} # Expected conclusion (success, failure, etc.)
    local max_attempts=20 # Increased attempts (~7 mins max wait)
    local attempt=0
    local target_run_id=""

    echo >&2 "Waiting for workflow '$WORKFLOW_FILE' triggered by merge of PR #$pr_number (merge commit $merge_commit_sha)..."

    while [[ $attempt -lt $max_attempts ]]; do
        # Calculate sleep time: increases with attempts
        sleep_time=$(( (attempt + 1) * 2 ))
        echo >&2 "Attempt $((attempt + 1))/$max_attempts: Checking for workflow run..."

        # If we haven't found the target run ID yet, search for it
        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Searching for the specific workflow run..."
            # List recent runs for the specific workflow triggered by pull_request event
            candidate_run_ids=$(log_cmd gh run list \
                --repo "$REPO_FULL_NAME" \
                --workflow "$WORKFLOW_FILE" \
                --event pull_request \
                --limit 10 \
                --json databaseId --jq '.[].databaseId' || echo "") # Get IDs, handle potential errors

            if [[ -z "$candidate_run_ids" ]]; then
                echo >&2 "No recent '$WORKFLOW_FILE' runs found for 'pull_request' event. Sleeping $sleep_time seconds."
                sleep $sleep_time
                attempt=$((attempt + 1))
                continue # Go to next attempt
            fi

            echo >&2 "Found candidate run IDs: $candidate_run_ids. Checking runs..."
            for run_id in $candidate_run_ids; do
                echo >&2 "Checking candidate run ID: $run_id"
                run_info=$(log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --json headBranch,headSha || echo "{}") # Fetch run info, default to empty JSON on error

                # Check if the run matches our merged branch
                run_head_branch=$(echo "$run_info" | jq -r '.headBranch // ""')
                run_head_sha=$(echo "$run_info" | jq -r '.headSha // ""')

                echo >&2 "  Run head branch: $run_head_branch, head SHA: $run_head_sha"
                echo >&2 "  Expected merged branch: $merged_branch_name, merge commit SHA: $merge_commit_sha"

                # For pull_request events, the workflow runs on the PR's head branch
                # Match by the head branch being the merged branch name
                if [[ "$run_head_branch" == "$merged_branch_name" ]]; then
                    echo >&2 "Found matching workflow run ID: $run_id (headBranch matches merged branch)"
                    target_run_id="$run_id"
                    break # Found the run, exit the inner loop
                else
                     echo >&2 "Run $run_id does not match the merge event criteria."
                fi
            done
        fi

        # If we still haven't found the run ID after checking candidates, wait and retry listing
        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Target workflow run not found among recent runs. Sleeping $sleep_time seconds."
            sleep $sleep_time
            attempt=$((attempt + 1))
            continue # Go to next attempt
        fi

        # --- Monitor the identified target run ---
        echo >&2 "Monitoring workflow run ID: $target_run_id"
        run_info=$(log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --json status,conclusion)
        run_status=$(echo "$run_info" | jq -r '.status')
        run_conclusion=$(echo "$run_info" | jq -r '.conclusion') # Might be null if not completed

        echo >&2 "Workflow run $target_run_id status: $run_status, conclusion: $run_conclusion"

        if [[ "$run_status" == "completed" ]]; then
            if [[ "$run_conclusion" == "$expected_conclusion" ]]; then
                echo >&2 "Workflow $target_run_id completed with expected conclusion: $run_conclusion."
                return 0
            else
                echo >&2 "Workflow $target_run_id completed with unexpected conclusion: $run_conclusion (expected: $expected_conclusion)"
                log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $target_run_id"
                return 1
            fi
        elif [[ "$run_status" == "queued" || "$run_status" == "in_progress" || "$run_status" == "waiting" ]]; then
            echo >&2 "Workflow $target_run_id is $run_status. Sleeping $sleep_time seconds."
        else
            echo >&2 "Workflow $target_run_id has unexpected status: $run_status. Conclusion: $run_conclusion"
            log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $target_run_id"
            return 1
        fi

        sleep $sleep_time
        attempt=$((attempt + 1))
    done

    echo >&2 "Timeout waiting for workflow run triggered by merge of PR #$pr_number (merge commit $merge_commit_sha) to complete with conclusion $expected_conclusion."
    # List recent runs for debugging
    echo >&2 "Recent runs for workflow '$WORKFLOW_FILE':"
    gh run list --repo "$REPO_FULL_NAME" --workflow "$WORKFLOW_FILE" --limit 10 || echo >&2 "Could not list recent runs."
    return 1
}

# --- Test Execution ---
echo >&2 "--- Starting E2E Test ---"

# 0. Sanity checks - ensure we're testing committed code
echo >&2 "0. Running sanity checks..."

# Check that the working directory is clean
if ! git -C "$PROJECT_ROOT" diff --quiet HEAD 2>/dev/null; then
    echo >&2 "ERROR: Repository has uncommitted changes."
    echo >&2 "Please commit your changes before running e2e tests."
    echo >&2 "This ensures we test exactly what will be deployed."
    git -C "$PROJECT_ROOT" status --short >&2
    exit 1
fi

# Get the current commit SHA from the action repo
ACTION_REPO_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
echo >&2 "Testing commit: $ACTION_REPO_COMMIT"

# Check that the current commit exists on origin
if ! git -C "$PROJECT_ROOT" fetch origin --quiet 2>/dev/null; then
    echo >&2 "WARNING: Could not fetch from origin, skipping remote check"
elif ! git -C "$PROJECT_ROOT" branch -r --contains "$ACTION_REPO_COMMIT" 2>/dev/null | grep -q .; then
    echo >&2 "ERROR: Current commit $ACTION_REPO_COMMIT does not exist on origin."
    echo >&2 "Please push your changes before running e2e tests."
    echo >&2 "This ensures the workflow can reference the action at this commit."
    exit 1
fi

echo >&2 "✅ Sanity checks passed"

# 1. Setup local repository
echo >&2 "1. Setting up local test repository..."
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
echo >&2 "Created test directory: $TEST_DIR"
log_cmd git init -b main
log_cmd git config user.email "test-e2e@example.com"
log_cmd git config user.name "E2E Test Bot"

# Create initial content with enough lines for context separation
# (Git needs ~3 lines of context between changes to avoid treating them as overlapping hunks)
echo "Base file content line 1" > file.txt
echo "Base file content line 2" >> file.txt
echo "Base file content line 3" >> file.txt
echo "Base file content line 4" >> file.txt
echo "Base file content line 5" >> file.txt
echo "Base file content line 6" >> file.txt
echo "Base file content line 7" >> file.txt
echo "Base file content line 8" >> file.txt
echo "Base file content line 9" >> file.txt
echo "Base file content line 10" >> file.txt
echo "Base file content line 11" >> file.txt
echo "Base file content line 12" >> file.txt
echo "Base file content line 13" >> file.txt
echo "Base file content line 14" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
INITIAL_COMMIT_SHA=$(git rev-parse HEAD)

# 2. Create remote GitHub repository
echo >&2 "2. Creating remote GitHub repository: $REPO_FULL_NAME"

log_cmd gh repo create "$REPO_FULL_NAME" --description "Temporary E2E test repo for update-pr-stack action" --public
echo >&2 "Successfully created $REPO_FULL_NAME"

# Enable GitHub Actions on the new repository (may be disabled by default in CI environments)
echo >&2 "Enabling GitHub Actions on the repository..."
log_cmd gh api -X PUT "/repos/$REPO_FULL_NAME/actions/permissions" --input - <<< '{"enabled":true,"allowed_actions":"all"}'

# 3. Push initial state
echo >&2 "3. Pushing initial state to remote..."
REMOTE_URL="https://github.com/$REPO_FULL_NAME.git"
log_cmd git remote add origin "$REMOTE_URL"

log_cmd git push -u origin main

# =============================================================================
# SCENARIO 0: Diff Pollution Test (without action)
# =============================================================================
# This scenario proves that without the action, PR diffs become polluted
# when the base branch is deleted and GitHub auto-retargets to main.
#
# We enable the "auto-delete head branches" repo setting, which causes GitHub
# to atomically handle both branch deletion and PR retargeting when a PR is
# merged. (Note: using `gh pr merge --delete-branch` doesn't trigger auto-retarget
# reliably - it must be the repo setting.)
#
# This causes the child PR's diff to show accumulated changes instead of
# just its own incremental changes - the "broken" state we want to demonstrate.
# =============================================================================

echo >&2 "--- SCENARIO 0: Diff Pollution Test (without action) ---"

# Enable auto-delete head branches - this triggers GitHub's auto-retarget behavior
# Note: This setting works differently than gh pr merge --delete-branch.
# The repo setting causes GitHub to atomically handle branch deletion and PR retargeting
# as part of the merge, whereas --delete-branch is a post-merge action that doesn't
# trigger auto-retarget reliably.
echo >&2 "0a. Enabling auto-delete head branches..."
log_cmd gh api -X PATCH "/repos/$REPO_FULL_NAME" --input - <<< '{"delete_branch_on_merge":true}'

# Create 2 PRs for the no-action test (using prefix 'noact_')
# Each feature changes a DIFFERENT line so pollution is clearly visible
echo >&2 "0b. Creating 'no action' stack..."
log_cmd git checkout main
log_cmd git checkout -b noact_feature1 main
sed -i '3s/.*/NoAct Feature 1 line 3/' file.txt  # Feature 1 changes LINE 3
log_cmd git add file.txt
log_cmd git commit -m "NoAct: Add feature 1"
log_cmd git push origin noact_feature1
NOACT_PR1_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head noact_feature1 --title "NoAct Feature 1" --body "NoAct PR 1")
NOACT_PR1_NUM=$(echo "$NOACT_PR1_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created NoAct PR #$NOACT_PR1_NUM: $NOACT_PR1_URL"

log_cmd git checkout -b noact_feature2 noact_feature1
sed -i '4s/.*/NoAct Feature 2 line 4/' file.txt  # Feature 2 changes LINE 4 (different!)
log_cmd git add file.txt
log_cmd git commit -m "NoAct: Add feature 2"
log_cmd git push origin noact_feature2
NOACT_PR2_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base noact_feature1 --head noact_feature2 --title "NoAct Feature 2" --body "NoAct PR 2, based on NoAct PR 1")
NOACT_PR2_NUM=$(echo "$NOACT_PR2_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created NoAct PR #$NOACT_PR2_NUM: $NOACT_PR2_URL"

# Capture initial diff (should show only 1 line change)
echo >&2 "0c. Capturing initial diff for PR2..."
NOACT_PR2_DIFF_INITIAL=$(get_pr_diff "$NOACT_PR2_URL")
echo >&2 "--- Initial PR2 diff (vs noact_feature1) ---"
echo "$NOACT_PR2_DIFF_INITIAL" >&2
echo >&2 "----------------------------------------------"

# Merge bottom PR WITHOUT the action installed
# The repo setting will auto-delete the branch and trigger GitHub's auto-retarget
echo >&2 "0d. Merging NoAct PR1 (without action installed)..."
merge_pr_with_retry "$NOACT_PR1_URL"
echo >&2 "NoAct PR1 merged. Waiting for GitHub to auto-retarget PR2..."

# Wait for GitHub to auto-retarget PR2 to main
if ! wait_for_pr_base_change "$NOACT_PR2_NUM" "main"; then
    echo >&2 "❌ GitHub did not auto-retarget PR2 to main"
    echo >&2 "Debug info:"
    gh pr view "$NOACT_PR2_NUM" --repo "$REPO_FULL_NAME" --json baseRefName,state,headRefName >&2
    exit 1
fi

# Capture diff after retarget
NOACT_PR2_DIFF_AFTER=$(get_pr_diff "$NOACT_PR2_URL")
echo >&2 "--- After retarget PR2 diff (vs main) ---"
echo "$NOACT_PR2_DIFF_AFTER" >&2
echo >&2 "------------------------------------------"

# The diff should now be different (polluted with Feature1's changes)
if [[ "$NOACT_PR2_DIFF_AFTER" != "$NOACT_PR2_DIFF_INITIAL" ]]; then
    echo >&2 "✅ Confirmed: PR2 diff changed after retarget (broken state demonstrated)"
else
    echo >&2 "❌ Unexpected: PR2 diff did NOT change after retarget"
    exit 1
fi

echo >&2 "--- SCENARIO 0 PASSED: Diff pollution demonstrated ---"

# Disable auto-delete for remaining scenarios (the action handles branch deletion)
echo >&2 "Disabling auto-delete head branches..."
log_cmd gh api -X PATCH "/repos/$REPO_FULL_NAME" --input - <<< '{"delete_branch_on_merge":false}'

# Install the action workflow for subsequent scenarios
echo >&2 "0e. Installing action and workflow..."
log_cmd git checkout main
log_cmd git pull origin main

mkdir -p .github/workflows
cp "$PROJECT_ROOT/.github/workflows/$WORKFLOW_FILE" .github/workflows/
sed -i "s|uses: Phlogistique/autorestack-action@main|uses: Phlogistique/autorestack-action@$ACTION_REPO_COMMIT|g" .github/workflows/"$WORKFLOW_FILE"
echo >&2 "Modified workflow to use action at commit $ACTION_REPO_COMMIT"

log_cmd git add .github/workflows/"$WORKFLOW_FILE"
log_cmd git commit -m "Add action and workflow files"
log_cmd git push origin main


# =============================================================================
# SCENARIO 1: Nominal Linear Stack with Clean Merges
# =============================================================================
# Tests the happy path where PRs are merged without conflicts.
# Also validates that diffs are preserved after the action runs.
# =============================================================================

# 4. Create stacked PRs
echo >&2 "4. Creating stacked branches and PRs..."
# Each PR modifies:
# - Line 2 (shared line, accumulates through the stack - tests merge handling)
# - A unique line (for diff pollution visibility)
# Branch feature1 (base: main)
log_cmd git checkout -b feature1 main
sed -i '2s/.*/Feature 1 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 1"
log_cmd git push origin feature1
PR1_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head feature1 --title "Feature 1" --body "This is PR 1")
PR1_NUM=$(echo "$PR1_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR1_NUM: $PR1_URL"
# Branch feature2 (base: feature1)
log_cmd git checkout -b feature2 feature1
sed -i '2s/.*/Feature 2 content line 2/' file.txt # Edit line 2 (shared)
sed -i '3s/.*/Feature 2 content line 3/' file.txt # Edit line 3 (unique)
log_cmd git add file.txt
log_cmd git commit -m "Add feature 2"
log_cmd git push origin feature2
PR2_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature1 --head feature2 --title "Feature 2" --body "This is PR 2, based on PR 1")
PR2_NUM=$(echo "$PR2_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR2_NUM: $PR2_URL"
# Branch feature3 (base: feature2)
log_cmd git checkout -b feature3 feature2
sed -i '2s/.*/Feature 3 content line 2/' file.txt # Edit line 2 (shared)
sed -i '4s/.*/Feature 3 content line 4/' file.txt # Edit line 4 (unique)
log_cmd git add file.txt
log_cmd git commit -m "Add feature 3"
log_cmd git push origin feature3
PR3_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature2 --head feature3 --title "Feature 3" --body "This is PR 3, based on PR 2")
PR3_NUM=$(echo "$PR3_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR3_NUM: $PR3_URL"

# Branch feature4 (base: feature3) - tests that indirect children's diffs remain correct
log_cmd git checkout -b feature4 feature3
sed -i '2s/.*/Feature 4 content line 2/' file.txt # Edit line 2 (shared)
sed -i '5s/.*/Feature 4 content line 5/' file.txt # Edit line 5 (unique)
log_cmd git add file.txt
log_cmd git commit -m "Add feature 4"
log_cmd git push origin feature4
PR4_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature3 --head feature4 --title "Feature 4" --body "This is PR 4, based on PR 3 (indirect child, tests diff preservation)")
PR4_NUM=$(echo "$PR4_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR4_NUM: $PR4_URL"

# Capture initial diffs for diff validation
echo >&2 "Capturing initial diffs for diff validation..."
PR2_DIFF_INITIAL=$(get_pr_diff "$PR2_URL")
PR3_DIFF_INITIAL=$(get_pr_diff "$PR3_URL")
PR4_DIFF_INITIAL=$(get_pr_diff "$PR4_URL")

# --- Initial Merge Scenario ---
echo >&2 "--- Testing Initial Merge (PR1) ---"

# 5. Trigger Action by Squash Merging PR1
echo >&2 "5. Squash merging PR #$PR1_NUM to trigger the action..."
merge_pr_with_retry "$PR1_URL"
MERGE_COMMIT_SHA1=$(gh pr view "$PR1_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
if [[ -z "$MERGE_COMMIT_SHA1" ]]; then
    echo >&2 "Failed to get merge commit SHA for PR #$PR1_NUM."
    exit 1
fi
echo >&2 "PR #$PR1_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA1"
# 6. Wait for the workflow to complete
echo >&2 "6. Waiting for the 'Update Stacked PRs' workflow (triggered by PR1 merge) to complete..."
if ! wait_for_workflow "$PR1_NUM" "feature1" "$MERGE_COMMIT_SHA1" "success"; then
    echo >&2 "Workflow for PR1 merge did not complete successfully."
    exit 1
fi
# 7. Verification for Initial Merge
echo >&2 "7. Verifying the results of the initial merge..."
echo >&2 "Fetching latest state from remote..."
log_cmd git fetch origin --prune # Prune deleted branches like feature1
# Verify feature1 branch was deleted remotely
if git show-ref --verify --quiet refs/remotes/origin/feature1; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature1' still exists."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature1' was deleted."
fi
# Verify PR2 base branch was updated
echo >&2 "Checking PR #$PR2_NUM base branch..."
PR2_BASE=$(log_cmd gh pr view "$PR2_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR2_BASE" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR2_NUM base branch updated to 'main'."
else
    echo >&2 "❌ Verification Failed: PR #$PR2_NUM base branch is '$PR2_BASE', expected 'main'."
    exit 1
fi
# Verify PR3 base branch is still feature2 (action should only update direct children's base)
echo >&2 "Checking PR #$PR3_NUM base branch..."
PR3_BASE=$(log_cmd gh pr view "$PR3_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR3_BASE" == "feature2" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR3_NUM base branch remains 'feature2'."
else
    echo >&2 "❌ Verification Failed: PR #$PR3_NUM base branch is '$PR3_BASE', expected 'feature2'."
    exit 1
fi
# Verify feature2 (direct child) is updated to include the squash commit
echo >&2 "Checking if feature2 incorporates the squash commit..."
log_cmd git checkout feature2
log_cmd git pull origin feature2
if log_cmd git merge-base --is-ancestor "$MERGE_COMMIT_SHA1" feature2; then
    echo >&2 "✅ Verification Passed: feature2 correctly incorporates the squash commit $MERGE_COMMIT_SHA1."
else
    echo >&2 "❌ Verification Failed: feature2 does not include the squash commit $MERGE_COMMIT_SHA1."
    log_cmd git log --graph --oneline feature2 main
    exit 1
fi
# Note: feature3 and feature4 are NOT updated (indirect children are not modified).
# Their diffs remain correct because the merge-base calculation still works.
echo >&2 "✅ feature3 and feature4 intentionally not updated (indirect children)"
# Verify diffs are preserved (identical to initial)
echo >&2 "Verifying diffs are preserved after action..."
PR2_DIFF_AFTER=$(get_pr_diff "$PR2_URL")
PR3_DIFF_AFTER=$(get_pr_diff "$PR3_URL")
PR4_DIFF_AFTER=$(get_pr_diff "$PR4_URL")

if ! compare_diffs "$PR2_DIFF_INITIAL" "$PR2_DIFF_AFTER" "PR2 diff preserved"; then
    exit 1
fi
if ! compare_diffs "$PR3_DIFF_INITIAL" "$PR3_DIFF_AFTER" "PR3 diff preserved"; then
    exit 1
fi
if ! compare_diffs "$PR4_DIFF_INITIAL" "$PR4_DIFF_AFTER" "PR4 diff preserved"; then
    exit 1
fi

echo >&2 "--- Initial Merge Test Completed Successfully ---"


# --- Conflict Scenario ---
echo >&2 "--- Testing Conflict Scenario (Merging PR2) ---"

# 8. Introduce conflicting changes
echo >&2 "8. Introducing conflicting changes..."
# Change line 7 on feature3 (far from line 2 to avoid adjacent-line conflicts)
log_cmd git checkout feature3
sed -i '7s/.*/Feature 3 conflicting change line 7/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Conflict: Modify line 7 on feature3"
FEATURE3_CONFLICT_COMMIT_SHA=$(git rev-parse HEAD) # Store this SHA
log_cmd git push origin feature3
# Change line 7 on main differently - this will conflict when rebasing feature3 after PR2 merge
log_cmd git checkout main
log_cmd git pull origin main  # Pull latest changes from PR1 merge
sed -i '7s/.*/Main conflicting change line 7/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Conflict: Modify line 7 on main"
log_cmd git push origin main

# 9. Trigger Action by Squash Merging PR2 (which is now based on the updated main from step 7)
echo >&2 "9. Squash merging PR #$PR2_NUM (feature2) to trigger conflict..."
merge_pr_with_retry "$PR2_URL"
MERGE_COMMIT_SHA2=$(gh pr view "$PR2_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
if [[ -z "$MERGE_COMMIT_SHA2" ]]; then
    echo >&2 "Failed to get merge commit SHA for PR #$PR2_NUM."
    exit 1
fi
echo >&2 "PR #$PR2_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA2"

# 10. Wait for the workflow to complete (it should succeed despite internal conflict)
echo >&2 "10. Waiting for the 'Update Stacked PRs' workflow (triggered by PR2 merge)..."
# The action itself should succeed because it posts a comment on conflict, not fail the run.
if ! wait_for_workflow "$PR2_NUM" "feature2" "$MERGE_COMMIT_SHA2" "success"; then
    echo >&2 "Workflow for PR2 merge did not complete successfully as expected."
    exit 1
fi

# 11. Verification for Conflict Scenario
echo >&2 "11. Verifying the results of the conflict scenario..."
echo >&2 "Fetching latest state from remote..."
log_cmd git fetch origin --prune

# Verify feature2 branch was NOT deleted (still referenced by conflicted PR3)
if git show-ref --verify --quiet refs/remotes/origin/feature2; then
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature2' still exists (kept for conflicted PR)."
else
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature2' was deleted prematurely."
    exit 1
fi

# Verify PR3 base branch was NOT updated (stays as feature2 for readable diff)
echo >&2 "Checking PR #$PR3_NUM base branch..."
PR3_BASE_AFTER_CONFLICT=$(log_cmd gh pr view "$PR3_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR3_BASE_AFTER_CONFLICT" == "feature2" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR3_NUM base branch stays as 'feature2' (not updated during conflict)."
else
    echo >&2 "❌ Verification Failed: PR #$PR3_NUM base branch is '$PR3_BASE_AFTER_CONFLICT', expected 'feature2'."
    exit 1
fi


# Verify conflict comment exists on PR3
echo >&2 "Checking for conflict comment on PR #$PR3_NUM..."
# Give GitHub some time to process the comment
sleep 5
CONFLICT_COMMENT=$(log_cmd gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json comments --jq '.comments[] | select(.body | contains("Automatic update blocked by merge conflicts")) | .body')
if [[ -n "$CONFLICT_COMMENT" ]]; then
    echo >&2 "✅ Verification Passed: Conflict comment found on PR #$PR3_NUM."
    echo "$CONFLICT_COMMENT" # Log the comment
else
    echo >&2 "❌ Verification Failed: Conflict comment not found on PR #$PR3_NUM."
    echo >&2 "--- Comments on PR #$PR3_NUM ---"
    gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json comments --jq '.comments[].body' || echo "Failed to get comments"
    echo >&2 "-----------------------------"
    exit 1
fi

# Verify conflict label exists on PR3
echo >&2 "Checking for conflict label on PR #$PR3_NUM..."
CONFLICT_LABEL=$(log_cmd gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ "$CONFLICT_LABEL" == "autorestack-needs-conflict-resolution" ]]; then
    echo >&2 "✅ Verification Passed: Conflict label 'autorestack-needs-conflict-resolution' found on PR #$PR3_NUM."
else
    echo >&2 "❌ Verification Failed: Conflict label not found on PR #$PR3_NUM."
    echo >&2 "--- Labels on PR #$PR3_NUM ---"
    gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[].name' || echo "Failed to get labels"
    echo >&2 "-----------------------------"
    exit 1
fi

# Verify feature3 branch was NOT pushed with conflicts (check its head SHA)
REMOTE_FEATURE3_SHA_BEFORE_RESOLVE=$(log_cmd git rev-parse "refs/remotes/origin/feature3")
# The action failed the merge locally, so it shouldn't have pushed feature3.
# The remote SHA should still be the one from step 8 ("Conflict: Modify line 3 on feature3").
EXPECTED_FEATURE3_SHA_BEFORE_RESOLVE=$FEATURE3_CONFLICT_COMMIT_SHA
if [[ "$REMOTE_FEATURE3_SHA_BEFORE_RESOLVE" == "$EXPECTED_FEATURE3_SHA_BEFORE_RESOLVE" ]]; then
     echo >&2 "✅ Verification Passed: Remote feature3 branch was not updated by the action due to conflict."
else
     echo >&2 "❌ Verification Failed: Remote feature3 branch SHA ($REMOTE_FEATURE3_SHA_BEFORE_RESOLVE) differs from expected SHA before conflict resolution ($EXPECTED_FEATURE3_SHA_BEFORE_RESOLVE)."
     exit 1
fi


# 12. Resolve conflict manually
echo >&2 "12. Resolving conflict manually on feature3..."
log_cmd git checkout feature3
# Ensure we have the latest main which includes the PR2 merge commit AND the conflicting change on main
log_cmd git fetch origin
# Now, perform the merge that the action tried and failed
echo >&2 "Attempting merge of origin/main into feature3..."
if git merge origin/main; then
    echo >&2 "❌ Conflict Resolution Failed: Merge of main into feature3 succeeded unexpectedly (no conflict?)"
    log_cmd git status
    log_cmd git log --graph --oneline --all
    exit 1
else
    echo >&2 "Merge conflict occurred as expected. Resolving..."
    # Check status to confirm conflict
    log_cmd git status
    # Resolve conflict - keep feature3's version (ours) of the conflicting file
    # This preserves both line 2 (Feature 3 content) and line 7 (Feature 3 conflicting change)
    log_cmd git checkout --ours file.txt
    echo "Resolved file.txt content:"
    cat file.txt
    log_cmd git add file.txt
    # Use 'git commit' without '-m' to use the default merge commit message
    log_cmd git commit --no-edit
    echo >&2 "Conflict resolved and committed."
fi
log_cmd git push origin feature3
echo >&2 "Pushed resolved feature3."

# 13. Wait for continuation workflow triggered by push
echo >&2 "13. Waiting for continuation workflow after conflict resolution push..."
if ! wait_for_synchronize_workflow "$PR3_NUM" "feature3" "success"; then
    echo >&2 "Continuation workflow for feature3 conflict resolution did not complete successfully."
    exit 1
fi

# 14. Verify continuation workflow effects
echo >&2 "14. Verifying continuation workflow effects..."

# Verify conflict label was removed from PR3
echo >&2 "Checking that conflict label was removed from PR #$PR3_NUM..."
sleep 5 # Give GitHub time to process
CONFLICT_LABEL_AFTER=$(log_cmd gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ -z "$CONFLICT_LABEL_AFTER" ]]; then
    echo >&2 "✅ Verification Passed: Conflict label was removed from PR #$PR3_NUM."
else
    echo >&2 "❌ Verification Failed: Conflict label still exists on PR #$PR3_NUM."
    exit 1
fi

# Verify PR3 base branch was updated to main after resolution
echo >&2 "Checking PR #$PR3_NUM base branch after resolution..."
PR3_BASE_AFTER_RESOLUTION=$(log_cmd gh pr view "$PR3_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR3_BASE_AFTER_RESOLUTION" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR3_NUM base branch updated to 'main' after resolution."
else
    echo >&2 "❌ Verification Failed: PR #$PR3_NUM base branch is '$PR3_BASE_AFTER_RESOLUTION', expected 'main'."
    exit 1
fi

# Verify feature2 was deleted after resolution (no other conflicted PRs depend on it)
echo >&2 "Checking that feature2 branch was deleted after resolution..."
log_cmd git fetch origin --prune
if git show-ref --verify --quiet refs/remotes/origin/feature2; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature2' still exists after resolution."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature2' was deleted after resolution."
fi

echo >&2 "--- Continuation Workflow Test Completed Successfully ---"

# 15. Verify conflict resolution (content checks)
echo >&2 "15. Verifying conflict resolution content..."
# Fetch the latest state again
log_cmd git fetch origin
log_cmd git checkout feature3
log_cmd git pull origin feature3

# Verify feature3 now incorporates main (including PR2 merge commit and main's conflict commit)
if log_cmd git merge-base --is-ancestor origin/main feature3; then
    echo >&2 "✅ Verification Passed: Resolved feature3 correctly incorporates main."
else
    echo >&2 "❌ Verification Failed: Resolved feature3 does not include main."
    log_cmd git log --graph --oneline feature3 origin/main
    exit 1
fi

# Note: feature4 is NOT updated (indirect children are not modified).
# It will be updated when feature3 is merged (becoming a direct child at that point).
echo >&2 "✅ feature4 intentionally not updated (indirect child of resolved PR)"

# Verify the final content of file.txt on feature3
# Line 1: Original base
# Line 2: From feature 3 commit ("Feature 3 content line 2")
# Line 7: From feature 3 conflict commit, kept during resolution ("Feature 3 conflicting change line 7")
log_cmd git checkout feature3
EXPECTED_CONTENT_LINE1="Base file content line 1"
EXPECTED_CONTENT_LINE2="Feature 3 content line 2"
EXPECTED_CONTENT_LINE7="Feature 3 conflicting change line 7"

ACTUAL_CONTENT_LINE1=$(sed -n '1p' file.txt)
ACTUAL_CONTENT_LINE2=$(sed -n '2p' file.txt)
ACTUAL_CONTENT_LINE7=$(sed -n '7p' file.txt)

if [[ "$ACTUAL_CONTENT_LINE1" == "$EXPECTED_CONTENT_LINE1" && \
      "$ACTUAL_CONTENT_LINE2" == "$EXPECTED_CONTENT_LINE2" && \
      "$ACTUAL_CONTENT_LINE7" == "$EXPECTED_CONTENT_LINE7" ]]; then
    echo >&2 "✅ Verification Passed: file.txt content on resolved feature3 is correct."
else
    echo >&2 "❌ Verification Failed: file.txt content on resolved feature3 is incorrect."
    echo "Expected:"
    echo "$EXPECTED_CONTENT_LINE1"
    echo "$EXPECTED_CONTENT_LINE2"
    echo "$EXPECTED_CONTENT_LINE7"
    echo "Actual:"
    cat file.txt
    exit 1
fi

echo >&2 "--- Conflict Scenario Test Completed Successfully ---"


# --- SCENARIO 3: Sibling Conflicts (Multiple PRs from same base, both conflict) ---
# ===================================================================================
# Tests that the old base branch is kept until ALL sibling PRs resolve their conflicts.
#
# Setup:
#   - Create a new stack: main <- feature5 <- (feature6, feature7) parallel children
#   - feature6 and feature7 both modify line 5 of file.txt
#   - main modifies line 5 differently (creating conflict with both siblings)
#
# Expected Behavior:
#   - After merging feature5, both feature6 and feature7 have conflicts
#   - feature5 branch is kept (referenced by both conflicted PRs)
#   - After resolving feature6, feature5 is still kept (feature7 still conflicted)
#   - After resolving feature7, feature5 is deleted (no more conflicted siblings)
# ===================================================================================

echo >&2 "--- Testing Sibling Conflicts Scenario ---"

# 16. Create new stack for sibling conflict test
echo >&2 "16. Creating new stack for sibling conflict test..."
log_cmd git checkout main
log_cmd git pull origin main

# Create feature5 based on main (modifies line 2, no conflict with line 5)
log_cmd git checkout -b feature5 main
sed -i '2s/.*/Feature 5 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 5"
log_cmd git push origin feature5
PR5_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head feature5 --title "Feature 5" --body "This is PR 5")
PR5_NUM=$(echo "$PR5_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR5_NUM: $PR5_URL"

# Create feature6 based on feature5 (modifies line 5, will conflict with main)
log_cmd git checkout -b feature6 feature5
sed -i '5s/.*/Feature 6 conflicting content line 5/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 6 (modifies line 5)"
log_cmd git push origin feature6
PR6_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature5 --head feature6 --title "Feature 6" --body "This is PR 6, sibling of PR 7")
PR6_NUM=$(echo "$PR6_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR6_NUM: $PR6_URL"

# Create feature7 based on feature5 (also modifies line 5, will conflict with main)
log_cmd git checkout feature5
log_cmd git checkout -b feature7
sed -i '5s/.*/Feature 7 conflicting content line 5/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 7 (also modifies line 5)"
log_cmd git push origin feature7
PR7_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature5 --head feature7 --title "Feature 7" --body "This is PR 7, sibling of PR 6")
PR7_NUM=$(echo "$PR7_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR7_NUM: $PR7_URL"

# Introduce conflicting change on main (line 5) - this will conflict with feature6/7
# when the action tries to merge SQUASH_COMMIT~ into them
log_cmd git checkout main
sed -i '5s/.*/Main conflicting content line 5/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add conflicting change on main line 5"
log_cmd git push origin main

# 17. Merge feature5 to trigger conflicts on both siblings
echo >&2 "17. Squash merging PR #$PR5_NUM (feature5) to trigger sibling conflicts..."
merge_pr_with_retry "$PR5_URL"
MERGE_COMMIT_SHA5=$(gh pr view "$PR5_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
echo >&2 "PR #$PR5_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA5"

# Wait for workflow
echo >&2 "Waiting for workflow..."
if ! wait_for_workflow "$PR5_NUM" "feature5" "$MERGE_COMMIT_SHA5" "success"; then
    echo >&2 "Workflow for PR5 merge did not complete successfully."
    exit 1
fi

# 18. Verify both siblings have conflicts and feature5 is kept
echo >&2 "18. Verifying sibling conflict state..."
log_cmd git fetch origin

# Verify feature5 branch was NOT deleted (both siblings conflicted)
if git show-ref --verify --quiet refs/remotes/origin/feature5; then
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature5' still exists (kept for conflicted siblings)."
else
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature5' was deleted prematurely."
    exit 1
fi

# Verify both PRs have conflict labels
PR6_HAS_LABEL=$(gh pr view "$PR6_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
PR7_HAS_LABEL=$(gh pr view "$PR7_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')

if [[ "$PR6_HAS_LABEL" == "autorestack-needs-conflict-resolution" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR6_NUM has conflict label."
else
    echo >&2 "❌ Verification Failed: PR #$PR6_NUM does not have conflict label."
    exit 1
fi

if [[ "$PR7_HAS_LABEL" == "autorestack-needs-conflict-resolution" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR7_NUM has conflict label."
else
    echo >&2 "❌ Verification Failed: PR #$PR7_NUM does not have conflict label."
    exit 1
fi

# Verify both PRs still have feature5 as base
PR6_BASE=$(gh pr view "$PR6_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
PR7_BASE=$(gh pr view "$PR7_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)

if [[ "$PR6_BASE" == "feature5" && "$PR7_BASE" == "feature5" ]]; then
    echo >&2 "✅ Verification Passed: Both sibling PRs still have 'feature5' as base."
else
    echo >&2 "❌ Verification Failed: PR6 base is '$PR6_BASE', PR7 base is '$PR7_BASE', expected both to be 'feature5'."
    exit 1
fi

# 19. Resolve first sibling (feature6) - feature5 should still be kept
echo >&2 "19. Resolving first sibling (feature6)..."
log_cmd git checkout feature6
log_cmd git fetch origin
if git merge origin/main; then
    echo >&2 "Merge succeeded unexpectedly (no conflict?)"
else
    echo >&2 "Resolving conflict on feature6..."
    log_cmd git checkout --ours file.txt
    log_cmd git add file.txt
    log_cmd git commit --no-edit
fi
log_cmd git push origin feature6

# Wait for continuation workflow
echo >&2 "Waiting for continuation workflow for feature6..."
if ! wait_for_synchronize_workflow "$PR6_NUM" "feature6" "success"; then
    echo >&2 "Continuation workflow for feature6 did not complete successfully."
    exit 1
fi

# 20. Verify feature5 is still kept (feature7 still conflicted)
echo >&2 "20. Verifying feature5 is still kept after first sibling resolution..."
log_cmd git fetch origin

# feature5 should still exist
if git show-ref --verify --quiet refs/remotes/origin/feature5; then
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature5' still exists (feature7 still conflicted)."
else
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature5' was deleted prematurely (feature7 still needs it)."
    exit 1
fi

# PR6 base should now be main
PR6_BASE_AFTER=$(gh pr view "$PR6_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR6_BASE_AFTER" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR6_NUM base updated to 'main' after resolution."
else
    echo >&2 "❌ Verification Failed: PR #$PR6_NUM base is '$PR6_BASE_AFTER', expected 'main'."
    exit 1
fi

# PR6 should no longer have conflict label
PR6_LABEL_AFTER=$(gh pr view "$PR6_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ -z "$PR6_LABEL_AFTER" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR6_NUM conflict label removed."
else
    echo >&2 "❌ Verification Failed: PR #$PR6_NUM still has conflict label."
    exit 1
fi

# PR7 should still have conflict label and feature5 as base
PR7_LABEL_STILL=$(gh pr view "$PR7_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
PR7_BASE_STILL=$(gh pr view "$PR7_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR7_LABEL_STILL" == "autorestack-needs-conflict-resolution" && "$PR7_BASE_STILL" == "feature5" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR7_NUM still has conflict label and 'feature5' base."
else
    echo >&2 "❌ Verification Failed: PR7 label='$PR7_LABEL_STILL', base='$PR7_BASE_STILL'."
    exit 1
fi

# 21. Resolve second sibling (feature7) - now feature5 should be deleted
echo >&2 "21. Resolving second sibling (feature7)..."
log_cmd git checkout feature7
log_cmd git fetch origin
if git merge origin/main; then
    echo >&2 "Merge succeeded unexpectedly (no conflict?)"
else
    echo >&2 "Resolving conflict on feature7..."
    log_cmd git checkout --ours file.txt
    log_cmd git add file.txt
    log_cmd git commit --no-edit
fi
log_cmd git push origin feature7

# Wait for continuation workflow
echo >&2 "Waiting for continuation workflow for feature7..."
if ! wait_for_synchronize_workflow "$PR7_NUM" "feature7" "success"; then
    echo >&2 "Continuation workflow for feature7 did not complete successfully."
    exit 1
fi

# 22. Verify feature5 is now deleted (all siblings resolved)
echo >&2 "22. Verifying feature5 is deleted after all siblings resolved..."
log_cmd git fetch origin --prune

if git show-ref --verify --quiet refs/remotes/origin/feature5; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature5' still exists after all siblings resolved."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature5' was deleted after all siblings resolved."
fi

# PR7 base should now be main
PR7_BASE_FINAL=$(gh pr view "$PR7_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR7_BASE_FINAL" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR7_NUM base updated to 'main' after resolution."
else
    echo >&2 "❌ Verification Failed: PR #$PR7_NUM base is '$PR7_BASE_FINAL', expected 'main'."
    exit 1
fi

echo >&2 "--- Sibling Conflicts Scenario Test Completed Successfully ---"


# --- SCENARIO 4: Multi-child with 0 conflicts ---
# ===================================================================================
# Tests that when a PR with multiple children is merged and none conflict,
# all children are cleanly updated and the old base branch is deleted.
#
# Setup:
#   - Create main <- feature8 <- (feature9, feature10) parallel children
#   - feature9 and feature10 modify different lines (no conflict with each other or main)
#
# Expected Behavior:
#   - After merging feature8, both feature9 and feature10 are cleanly rebased
#   - Both PRs' base branches updated to main
#   - feature8 branch is deleted (no conflicts)
# ===================================================================================

echo >&2 "--- Testing Multi-child No Conflicts Scenario ---"

echo >&2 "23. Creating stack for multi-child no-conflict test..."
log_cmd git checkout main
log_cmd git pull origin main

# Create feature8 based on main
log_cmd git checkout -b feature8 main
sed -i '2s/.*/Feature 8 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 8"
log_cmd git push origin feature8
PR8_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head feature8 --title "Feature 8" --body "This is PR 8")
PR8_NUM=$(echo "$PR8_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR8_NUM: $PR8_URL"

# Create feature9 based on feature8 (modifies line 3 — no conflict)
log_cmd git checkout -b feature9 feature8
sed -i '3s/.*/Feature 9 content line 3/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 9 (modifies line 3)"
log_cmd git push origin feature9
PR9_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature8 --head feature9 --title "Feature 9" --body "This is PR 9, child of PR 8")
PR9_NUM=$(echo "$PR9_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR9_NUM: $PR9_URL"

# Capture PR9 diff before merge
PR9_DIFF_BEFORE=$(get_pr_diff "$PR9_URL")

# Create feature10 based on feature8 (modifies line 4 — no conflict)
log_cmd git checkout feature8
log_cmd git checkout -b feature10
sed -i '4s/.*/Feature 10 content line 4/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 10 (modifies line 4)"
log_cmd git push origin feature10
PR10_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature8 --head feature10 --title "Feature 10" --body "This is PR 10, child of PR 8")
PR10_NUM=$(echo "$PR10_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR10_NUM: $PR10_URL"

# Capture PR10 diff before merge
PR10_DIFF_BEFORE=$(get_pr_diff "$PR10_URL")

# 24. Merge feature8 to trigger clean updates on both children
echo >&2 "24. Squash merging PR #$PR8_NUM (feature8)..."
merge_pr_with_retry "$PR8_URL"
MERGE_COMMIT_SHA8=$(gh pr view "$PR8_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
echo >&2 "PR #$PR8_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA8"

echo >&2 "Waiting for workflow..."
if ! wait_for_workflow "$PR8_NUM" "feature8" "$MERGE_COMMIT_SHA8" "success"; then
    echo >&2 "Workflow for PR8 merge did not complete successfully."
    exit 1
fi

# 25. Verify both children updated cleanly
echo >&2 "25. Verifying multi-child clean update..."
log_cmd git fetch origin --prune

# feature8 branch should be deleted (no conflicts)
if git show-ref --verify --quiet refs/remotes/origin/feature8; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature8' still exists."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature8' was deleted."
fi

# Both PRs should have main as base
PR9_BASE=$(gh pr view "$PR9_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
PR10_BASE=$(gh pr view "$PR10_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)

if [[ "$PR9_BASE" == "main" && "$PR10_BASE" == "main" ]]; then
    echo >&2 "✅ Verification Passed: Both PRs updated to base 'main'."
else
    echo >&2 "❌ Verification Failed: PR9 base='$PR9_BASE', PR10 base='$PR10_BASE', expected both 'main'."
    exit 1
fi

# Neither PR should have conflict labels
PR9_LABEL=$(gh pr view "$PR9_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
PR10_LABEL=$(gh pr view "$PR10_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')

if [[ -z "$PR9_LABEL" && -z "$PR10_LABEL" ]]; then
    echo >&2 "✅ Verification Passed: Neither PR has conflict labels."
else
    echo >&2 "❌ Verification Failed: PR9 label='$PR9_LABEL', PR10 label='$PR10_LABEL'."
    exit 1
fi

# Diffs should be preserved
PR9_DIFF_AFTER=$(get_pr_diff "$PR9_URL")
PR10_DIFF_AFTER=$(get_pr_diff "$PR10_URL")
compare_diffs "$PR9_DIFF_BEFORE" "$PR9_DIFF_AFTER" "PR9 diff preserved after multi-child clean update"
compare_diffs "$PR10_DIFF_BEFORE" "$PR10_DIFF_AFTER" "PR10 diff preserved after multi-child clean update"

echo >&2 "--- Multi-child No Conflicts Scenario Test Completed Successfully ---"


# --- SCENARIO 5: Multi-child with mixed outcome (one conflicts, one succeeds) ---
# ===================================================================================
# Tests that when one child conflicts and the other merges cleanly, the old base
# branch is kept (for the conflicted child) and the clean child is fully updated.
#
# Setup:
#   - Create main <- feature11 <- (feature12, feature13) parallel children
#   - feature12 modifies line 5 (will conflict with a main change)
#   - feature13 modifies line 14 (no conflict — far enough from line 5 to avoid overlapping hunks)
#   - Push a conflicting change to line 5 on main
#
# Expected Behavior:
#   - feature13 is cleanly updated, base changed to main
#   - feature12 gets conflict label, base stays feature11
#   - feature11 branch is kept (still referenced by conflicted PR12)
# ===================================================================================

echo >&2 "--- Testing Multi-child Mixed Outcome Scenario ---"

echo >&2 "26. Creating stack for mixed outcome test..."
log_cmd git checkout main
log_cmd git pull origin main

# Create feature11 based on main
log_cmd git checkout -b feature11 main
sed -i '2s/.*/Feature 11 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 11"
log_cmd git push origin feature11
PR11_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head feature11 --title "Feature 11" --body "This is PR 11")
PR11_NUM=$(echo "$PR11_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR11_NUM: $PR11_URL"

# Create feature12 based on feature11 (modifies line 5 — will conflict)
log_cmd git checkout -b feature12 feature11
sed -i '5s/.*/Feature 12 conflicting content line 5/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 12 (modifies line 5)"
log_cmd git push origin feature12
PR12_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature11 --head feature12 --title "Feature 12" --body "This is PR 12, child of PR 11")
PR12_NUM=$(echo "$PR12_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR12_NUM: $PR12_URL"

# Create feature13 based on feature11 (modifies line 6 — no conflict)
log_cmd git checkout feature11
log_cmd git checkout -b feature13
sed -i '14s/.*/Feature 13 content line 14/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 13 (modifies line 14)"
log_cmd git push origin feature13
PR13_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature11 --head feature13 --title "Feature 13" --body "This is PR 13, child of PR 11")
PR13_NUM=$(echo "$PR13_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR13_NUM: $PR13_URL"

# Capture PR13 diff before merge
PR13_DIFF_BEFORE=$(get_pr_diff "$PR13_URL")

# Push conflicting change to main (line 5)
log_cmd git checkout main
sed -i '5s/.*/Main conflicting content line 5 for scenario 5/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add conflicting change on main line 5 (scenario 5)"
log_cmd git push origin main

# 27. Merge feature11 to trigger mixed outcome
echo >&2 "27. Squash merging PR #$PR11_NUM (feature11)..."
merge_pr_with_retry "$PR11_URL"
MERGE_COMMIT_SHA11=$(gh pr view "$PR11_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
echo >&2 "PR #$PR11_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA11"

echo >&2 "Waiting for workflow..."
if ! wait_for_workflow "$PR11_NUM" "feature11" "$MERGE_COMMIT_SHA11" "success"; then
    echo >&2 "Workflow for PR11 merge did not complete successfully."
    exit 1
fi

# 28. Verify mixed outcome
echo >&2 "28. Verifying mixed outcome..."
log_cmd git fetch origin

# feature11 branch should still exist (feature12 is conflicted)
if git show-ref --verify --quiet refs/remotes/origin/feature11; then
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature11' still exists (kept for conflicted PR12)."
else
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature11' was deleted prematurely."
    exit 1
fi

# PR13 (clean child) should have main as base
PR13_BASE=$(gh pr view "$PR13_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR13_BASE" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR13_NUM (clean child) base updated to 'main'."
else
    echo >&2 "❌ Verification Failed: PR #$PR13_NUM base is '$PR13_BASE', expected 'main'."
    exit 1
fi

# PR13 should not have conflict label
PR13_LABEL=$(gh pr view "$PR13_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ -z "$PR13_LABEL" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR13_NUM has no conflict label."
else
    echo >&2 "❌ Verification Failed: PR #$PR13_NUM has conflict label."
    exit 1
fi

# PR13 diff should be preserved (compare_diffs strips blob SHAs which change with the base)
PR13_DIFF_AFTER=$(get_pr_diff "$PR13_URL")
compare_diffs "$PR13_DIFF_BEFORE" "$PR13_DIFF_AFTER" "PR13 diff preserved after mixed outcome"

# PR12 (conflicting child) should still have feature11 as base
PR12_BASE=$(gh pr view "$PR12_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR12_BASE" == "feature11" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR12_NUM (conflicted child) base stays 'feature11'."
else
    echo >&2 "❌ Verification Failed: PR #$PR12_NUM base is '$PR12_BASE', expected 'feature11'."
    exit 1
fi

# PR12 should have conflict label
PR12_LABEL=$(gh pr view "$PR12_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ "$PR12_LABEL" == "autorestack-needs-conflict-resolution" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR12_NUM has conflict label."
else
    echo >&2 "❌ Verification Failed: PR #$PR12_NUM does not have conflict label."
    exit 1
fi

echo >&2 "--- Multi-child Mixed Outcome Scenario Test Completed Successfully ---"


# --- SCENARIO 6: No direct children (0-child run) ---
# ===================================================================================
# Tests that merging a PR with no children completes successfully and simply
# deletes the merged branch.
#
# Setup:
#   - Create main <- feature14 with no children
#
# Expected Behavior:
#   - Action runs and completes with success
#   - feature14 branch is deleted
# ===================================================================================

echo >&2 "--- Testing No Children Scenario ---"

echo >&2 "29. Creating standalone PR with no children..."
log_cmd git checkout main
log_cmd git pull origin main

log_cmd git checkout -b feature14 main
sed -i '2s/.*/Feature 14 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 14"
log_cmd git push origin feature14
PR14_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head feature14 --title "Feature 14" --body "This is PR 14, no children")
PR14_NUM=$(echo "$PR14_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR14_NUM: $PR14_URL"

# 30. Merge feature14
echo >&2 "30. Squash merging PR #$PR14_NUM (feature14, no children)..."
merge_pr_with_retry "$PR14_URL"
MERGE_COMMIT_SHA14=$(gh pr view "$PR14_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
echo >&2 "PR #$PR14_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA14"

echo >&2 "Waiting for workflow..."
if ! wait_for_workflow "$PR14_NUM" "feature14" "$MERGE_COMMIT_SHA14" "success"; then
    echo >&2 "Workflow for PR14 merge did not complete successfully."
    exit 1
fi

# 31. Verify branch was deleted and nothing broke
echo >&2 "31. Verifying no-children outcome..."
log_cmd git fetch origin --prune

if git show-ref --verify --quiet refs/remotes/origin/feature14; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature14' still exists."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature14' was deleted."
fi

echo >&2 "--- No Children Scenario Test Completed Successfully ---"


# --- Test Succeeded ---
echo >&2 "--- E2E Test Completed Successfully! ---"

# Cleanup is handled by the trap

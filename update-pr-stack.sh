#!/bin/bash
#
# Updates PR stack after merging a PR
#
# Required environment variables:
# SQUASH_COMMIT - The hash of the squash commit that was merged
# MERGED_BRANCH - The name of the branch that was merged and will be deleted
# TARGET_BRANCH - The name of the branch that the PR was merged into
#
# Design note:
# This script aims to output a transcript of "plain" git/gh commands that a
# human could follow through manually. For this reason:
# - We use git refs (e.g., SQUASH_COMMIT) instead of shell variables where
#   possible, so the logged commands are self-contained and reproducible
# - We strive to keep commands as simple as possible

set -ueo pipefail  # Exit on error, undefined var, or pipeline failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/command_utils.sh"

CONFLICT_LABEL="autorestack-needs-conflict-resolution"

# Allow replacing git and gh
[ -v GIT ] && git() { "$GIT" "$@"; }
[ -v GH ] && gh() { "$GH" "$@"; }

# Function to check if a required environment variable is set
check_env_var() {
    if [[ -z "${!1-}" ]]; then
        echo "Error: $1 is not set" >&2
        exit 1
    fi
}

# Check if a branch already has the squash commit merged (squash-merge mode only)
# Requires SQUASH_COMMIT ref to be set via git update-ref
#
# Note: This uses local branch refs. The caller must ensure both branches
# exist locally before calling (e.g., via git checkout).
has_squash_commit() {
    local BRANCH="$1"
    local BASE="$2"
    git merge-base --is-ancestor "$BASE" "$BRANCH" \
        && git merge-base --is-ancestor SQUASH_COMMIT "$BRANCH"
}

format_branch_list_for_text() {
    for ((i=1; i<=$#; i++)); do
        case $i in
            1) format='`%s`';;
            $#) format=', and `%s`';;
            *) format=', `%s`';;
        esac
        printf "$format" "${!i}"
    done
}

update_direct_target() {
    local BRANCH="$1"
    local BASE_BRANCH="$2"

    # Checkout first to ensure the local branch exists (created from origin if
    # needed). This allows has_squash_commit to compare local refs, which matters
    # for testing where the script may run multiple times in the same repo.
    log_cmd git checkout "$BRANCH"

    if has_squash_commit "$BRANCH" "$TARGET_BRANCH"; then
        echo "✓ $BRANCH already up-to-date; skipping"
        return 0
    fi

    echo "Updating direct target $BRANCH (from $MERGED_BRANCH to $BASE_BRANCH)"

    CONFLICTS=()
    log_cmd git update-ref BEFORE_MERGE HEAD
    if ! log_cmd git merge --no-edit "origin/$MERGED_BRANCH"; then
        CONFLICTS+=("origin/$MERGED_BRANCH")
        log_cmd git merge --abort
    fi
    # Only try merging the pre-squash target state if it's not already
    # included in the merged branch — otherwise the first merge covers it.
    if ! git merge-base --is-ancestor SQUASH_COMMIT~ "origin/$MERGED_BRANCH"; then
        if ! log_cmd git merge --no-edit SQUASH_COMMIT~; then
            CONFLICTS+=( "$(git rev-parse SQUASH_COMMIT~)" )
            log_cmd git merge --abort
        fi
    fi

    if [[ "${#CONFLICTS[@]}" -gt 0 ]]; then
        {
            echo "### ⚠️ Automatic update blocked by merge conflicts"
            echo
            echo -n "I tried to merge "
            format_branch_list_for_text "${CONFLICTS[@]}"
            echo " into this branch while updating the pull request stack and hit conflicts."
            echo
            echo "#### How to resolve"
            echo '```bash'
            echo "git fetch origin"
            echo "git switch $BRANCH"
            for conflict in "${CONFLICTS[@]}"; do
                echo "git merge $conflict"
                echo "# ..."
                echo '# fix conflicts, for instance with `git mergetool`'
                echo "# ..."
                echo "git commit"
            done
            echo "git push"
            echo '```'
            echo
            echo "Once you push, this action will resume and finish updating this pull request."
        } | log_cmd gh pr comment "$BRANCH" -F -
        # Create the label if it doesn't exist, then add it to the PR
        gh label create "$CONFLICT_LABEL" --description "PR needs manual conflict resolution" --color "d73a4a" 2>/dev/null || true
        log_cmd gh pr edit "$BRANCH" --add-label "$CONFLICT_LABEL"
        return 1
    else
        log_cmd git merge --no-edit -s ours SQUASH_COMMIT
        log_cmd git update-ref MERGE_RESULT "HEAD^{tree}"
        COMMIT_MSG="Merge updates from $BASE_BRANCH and squash commit"
        if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            COMMIT_MSG="$COMMIT_MSG

See $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
        fi
        CUSTOM_COMMIT=$(log_cmd git commit-tree MERGE_RESULT -p BEFORE_MERGE -p "origin/$MERGED_BRANCH" -p SQUASH_COMMIT -m "$COMMIT_MSG")
        log_cmd git reset --hard "$CUSTOM_COMMIT"
    fi

    return 0
}

# Check if a PR has the conflict resolution label
pr_has_conflict_label() {
    local BRANCH="$1"
    local LABELS
    LABELS=$(gh pr view "$BRANCH" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
    echo "$LABELS" | grep -q "^${CONFLICT_LABEL}$"
}

# Check if any other PRs with conflict label still depend on a given base branch
# Returns 0 (true) if siblings exist, 1 (false) if no siblings
has_sibling_conflicts() {
    local BASE_BRANCH="$1"
    local EXCLUDE_BRANCH="$2"

    # Find all open PRs with the conflict label that are based on BASE_BRANCH
    local CONFLICTED_SIBLINGS
    CONFLICTED_SIBLINGS=$(gh pr list --base "$BASE_BRANCH" --label "$CONFLICT_LABEL" --json headRefName --jq '.[].headRefName' 2>/dev/null || echo "")

    for SIBLING in $CONFLICTED_SIBLINGS; do
        if [[ "$SIBLING" != "$EXCLUDE_BRANCH" ]]; then
            return 0  # Found a sibling still in conflict
        fi
    done

    return 1  # No siblings with same base
}

# Continue processing after user manually resolved conflicts
continue_after_resolution() {
    check_env_var "PR_BRANCH"

    echo "Checking if $PR_BRANCH needs continuation after conflict resolution..."

    # Check if the PR has the conflict label
    if ! pr_has_conflict_label "$PR_BRANCH"; then
        echo "✓ $PR_BRANCH does not have conflict label; nothing to do"
        return
    fi

    echo "Found conflict label on $PR_BRANCH, continuing stack update..."

    # Get the current base branch (the old base that was kept during conflict)
    local OLD_BASE
    OLD_BASE=$(gh pr view "$PR_BRANCH" --json baseRefName --jq '.baseRefName')
    echo "Current base branch: $OLD_BASE"

    # Find where the old base was merged to (the new target)
    local NEW_TARGET
    NEW_TARGET=$(gh pr list --head "$OLD_BASE" --state merged --json baseRefName --jq '.[0].baseRefName')

    if [[ -z "$NEW_TARGET" ]]; then
        echo "⚠️ Could not find where '$OLD_BASE' was merged to; skipping base branch and deletion updates"
        # Don't update base or delete old branch - leave things as they are
    else
        echo "Old base '$OLD_BASE' was merged to '$NEW_TARGET'"

        # Remove the conflict label
        log_cmd gh pr edit "$PR_BRANCH" --remove-label "$CONFLICT_LABEL"

        # Update the PR's base branch to the new target
        log_cmd gh pr edit "$PR_BRANCH" --base "$NEW_TARGET"

        # Check if old base branch should be deleted
        if has_sibling_conflicts "$OLD_BASE" "$PR_BRANCH"; then
            echo "⚠️ Keeping branch '$OLD_BASE' - still referenced by other conflicted PRs"
        else
            echo "Deleting old base branch '$OLD_BASE' (no other PRs depend on it)"
            log_cmd git push origin ":$OLD_BASE" || echo "⚠️ Could not delete '$OLD_BASE' (may already be deleted)"
        fi
    fi
}

main() {
    # Check required environment variables
    check_env_var "SQUASH_COMMIT"
    check_env_var "MERGED_BRANCH"
    check_env_var "TARGET_BRANCH"

    log_cmd git update-ref SQUASH_COMMIT "$SQUASH_COMMIT"

    # Find all PRs directly targeting the merged PR's head
    INITIAL_TARGETS=($(log_cmd gh pr list --base "$MERGED_BRANCH" --json headRefName --jq '.[].headRefName'))

    # Track successfully updated vs conflicted branches separately
    UPDATED_TARGETS=()
    CONFLICTED_TARGETS=()

    for BRANCH in "${INITIAL_TARGETS[@]}"; do
        if update_direct_target "$BRANCH" "$TARGET_BRANCH"; then
            UPDATED_TARGETS+=("$BRANCH")
        else
            CONFLICTED_TARGETS+=("$BRANCH")
        fi
    done

    # Only update base branches for successfully updated PRs
    for BRANCH in "${UPDATED_TARGETS[@]}"; do
        log_cmd gh pr edit "$BRANCH" --base "$TARGET_BRANCH"
    done

    # Push updated branches; only delete merged branch if no conflicts
    if [[ "${#CONFLICTED_TARGETS[@]}" -eq 0 ]]; then
        # No conflicts - safe to delete merged branch
        log_cmd git push origin ":$MERGED_BRANCH" "${UPDATED_TARGETS[@]}"
    else
        # Some conflicts - keep merged branch for reference during manual resolution
        if [[ "${#UPDATED_TARGETS[@]}" -gt 0 ]]; then
            log_cmd git push origin "${UPDATED_TARGETS[@]}"
        fi
        echo "⚠️ Keeping branch '$MERGED_BRANCH' - still referenced by conflicted PRs: ${CONFLICTED_TARGETS[*]}"
    fi
}

# Only run if the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${ACTION_MODE:-squash-merge}" in
        squash-merge)
            main
            ;;
        conflict-resolved)
            continue_after_resolution
            ;;
        *)
            echo "Error: Unknown ACTION_MODE: $ACTION_MODE" >&2
            exit 1
            ;;
    esac
fi

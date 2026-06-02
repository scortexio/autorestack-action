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

# Machine-readable marker embedded (invisibly) in the conflict comment so the
# conflict-resolved run can recover the exact stack state it recorded, instead of
# re-deriving the parent PR from the PR's current base branch (which breaks when
# anything about that base changes, e.g. a human retargeting the PR manually).
STATE_MARKER_PREFIX="<!-- autorestack-state:"

# Args: base-branch target-branch squash-hash. Branch names and hashes contain no
# spaces, so a space-separated key=value list parses back unambiguously.
format_state_marker() {
    printf '%s base=%s target=%s squash=%s -->' \
        "$STATE_MARKER_PREFIX" "$1" "$2" "$3"
}

# Echoes the most recent state-marker line found in our PR comments, or nothing.
read_state_marker() {
    local PR_BRANCH="$1"
    gh pr view "$PR_BRANCH" --json comments --jq '.comments[].body' 2>/dev/null \
        | { grep -F "$STATE_MARKER_PREFIX" || true; } | tail -n1
}

# Args: a marker line. Echoes "base target squash".
parse_state_marker() {
    local LINE="$1"
    printf '%s %s %s\n' \
        "$(sed -n 's/.* base=\([^ ]*\).*/\1/p' <<<"$LINE")" \
        "$(sed -n 's/.* target=\([^ ]*\).*/\1/p' <<<"$LINE")" \
        "$(sed -n 's/.* squash=\([^ ]*\).*/\1/p' <<<"$LINE")"
}

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
    local BASE_MERGE_CLEAN=true
    log_cmd git update-ref BEFORE_MERGE HEAD
    if ! log_cmd git merge --no-edit "origin/$MERGED_BRANCH"; then
        CONFLICTS+=("origin/$MERGED_BRANCH")
        BASE_MERGE_CLEAN=false
        log_cmd git merge --abort
    fi
    # Only try merging the pre-squash target state if it's not already
    # included in the merged branch — otherwise the first merge covers it.
    if ! git merge-base --is-ancestor SQUASH_COMMIT~ "origin/$MERGED_BRANCH"; then
        if ! log_cmd git merge --no-edit SQUASH_COMMIT~; then
            CONFLICTS+=( "$(git rev-parse SQUASH_COMMIT~)  # $TARGET_BRANCH just before $MERGED_BRANCH was merged" )
            log_cmd git merge --abort
        fi
    fi

    if [[ "${#CONFLICTS[@]}" -gt 0 ]]; then
        # When the base-branch merge was clean, HEAD now holds it (the
        # conflicting pre-squash merge was aborted back to it). Push it before
        # asking for help: the user resolves on top of it, and the head stays a
        # descendant of its base so the PR stays mergeable and the synchronize
        # event that resumes this action still fires. GitHub does not run
        # pull_request workflows on a PR conflicting with its base, which would
        # otherwise strand the branch for good. If the base merge itself
        # conflicted we have nothing safe to pre-push, so we just ask for help.
        # Note: ordering is important here: if we label before pushing, we
        # re-trigger ourselves immediately.
        if [[ "$BASE_MERGE_CLEAN" == true ]]; then
            log_cmd git push origin "$BRANCH"
        fi
        {
            echo "### ⚠️ Automatic update blocked by merge conflicts"
            echo
            echo "#### How to resolve"
            echo '```bash'
            echo "git fetch origin"
            echo "git switch $BRANCH"
            echo "git pull origin $BRANCH"

            for i in "${!CONFLICTS[@]}"; do
                echo "git merge ${CONFLICTS[$i]}"
                echo '```'
                echo
                echo 'Fix the conflicts (for instance with `git mergetool`), then run `git commit` before continuing.'
                echo
                echo '```bash'
            done
            echo "git push origin $BRANCH"
            echo '```'
            echo
            echo "Once you push, this action will resume and finish updating this pull request."
            echo
            format_state_marker "$MERGED_BRANCH" "$TARGET_BRANCH" "$(git rev-parse SQUASH_COMMIT)"
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

# Give up on resuming the stack update: tell the user why on the PR, then drop
# the conflict label so this action stops re-triggering. Used for the dead-end
# cases where we cannot or must not finish automatically.
abandon_resume() {
    local PR_BRANCH="$1"
    local MESSAGE="$2"
    echo "$MESSAGE" | log_cmd gh pr comment "$PR_BRANCH" -F -
    log_cmd gh pr edit "$PR_BRANCH" --remove-label "$CONFLICT_LABEL"
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

    # The synchronize payload is the child PR, so SQUASH_COMMIT / MERGED_BRANCH /
    # TARGET_BRANCH from the original squash-merge run are not in the environment.
    # Recover them from the marker the squash-merge run left in the conflict
    # comment.
    local MARKER
    MARKER=$(read_state_marker "$PR_BRANCH")
    if [[ -z "$MARKER" ]]; then
        echo "⚠️ No autorestack state marker on $PR_BRANCH; cannot resume safely. Removing the label."
        abandon_resume "$PR_BRANCH" "ℹ️ autorestack could not find its state marker on this PR, so it will not update the stack automatically. If this PR still needs its base updated, update its base manually."
        return
    fi

    local OLD_BASE NEW_TARGET SQUASH_HASH
    read -r OLD_BASE NEW_TARGET SQUASH_HASH < <(parse_state_marker "$MARKER")
    echo "Recorded state: base=$OLD_BASE target=$NEW_TARGET squash=$SQUASH_HASH"

    # The base we left the PR on while waiting for conflict resolution was the
    # merged parent branch. If it no longer matches, a human retargeted the PR
    # (e.g. straight onto the integration branch); we are no longer the authority
    # on its base, so we step back without touching the branch. This runs before
    # any mutation: once the base diverges, the recorded target is stale and a
    # merge built against it would be wrong.
    local CURRENT_BASE
    CURRENT_BASE=$(gh pr view "$PR_BRANCH" --json baseRefName --jq '.baseRefName')
    if [[ "$CURRENT_BASE" != "$OLD_BASE" ]]; then
        echo "⚠️ Base of $PR_BRANCH changed manually ($OLD_BASE -> $CURRENT_BASE); not updating the stack."
        abandon_resume "$PR_BRANCH" "ℹ️ The base branch of this PR was changed manually, so autorestack stepped back and will not update it automatically."
        return
    fi

    # Defense in depth: never act on a target branch that no longer exists. The
    # action checks out with full history (fetch-depth: 0), so a missing origin
    # ref means the branch is really gone, not just unfetched; no future resume
    # can succeed, so give up cleanly rather than stranding the PR under the label.
    if ! git rev-parse --verify --quiet "origin/$NEW_TARGET" >/dev/null; then
        echo "⚠️ Recorded target branch '$NEW_TARGET' no longer exists; abandoning resume of $PR_BRANCH."
        abandon_resume "$PR_BRANCH" "ℹ️ The branch this PR was being retargeted onto (\`$NEW_TARGET\`) no longer exists, so autorestack stepped back. If this PR still needs its base updated, update its base manually."
        return
    fi

    # The squash-merge run pushed the base merge and asked the user to resolve the
    # pre-squash merge, but it never recorded the squash itself. Finish that now:
    # re-run the same merge sequence as the squash-merge path. With the user's
    # resolution in place the base merge and pre-squash merge are no-ops; only the
    # "-s ours" squash record gets applied, keeping the diff against the new base
    # clean. has_squash_commit makes this idempotent.
    log_cmd git update-ref SQUASH_COMMIT "$SQUASH_HASH"
    MERGED_BRANCH="$OLD_BASE"
    TARGET_BRANCH="$NEW_TARGET"
    if ! update_direct_target "$PR_BRANCH" "$NEW_TARGET"; then
        echo "⚠️ '$PR_BRANCH' still conflicts; re-posted the conflict comment, will retry on next push"
        return 1
    fi

    # Drop the label last: it is what re-triggers this action, so while any
    # earlier step can still fail it must stay on to let the next push resume.
    # Push the cleaned-up head before retargeting so the head already contains
    # NEW_TARGET when the base flips to it, keeping the PR mergeable (GitHub
    # suppresses CI on a PR that conflicts with its base).
    log_cmd git push origin "$PR_BRANCH"
    log_cmd gh pr edit "$PR_BRANCH" --base "$NEW_TARGET"
    log_cmd gh pr edit "$PR_BRANCH" --remove-label "$CONFLICT_LABEL"

    # Check if old base branch should be deleted
    if has_sibling_conflicts "$OLD_BASE" "$PR_BRANCH"; then
        echo "⚠️ Keeping branch '$OLD_BASE' - still referenced by other conflicted PRs"
    else
        echo "Deleting old base branch '$OLD_BASE' (no other PRs depend on it)"
        log_cmd git push origin ":$OLD_BASE" || echo "⚠️ Could not delete '$OLD_BASE' (may already be deleted)"
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

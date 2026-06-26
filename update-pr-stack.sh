#!/bin/bash
#
# Updates PR stack after merging a PR
#
# Required environment variables (squash-merge mode):
# SQUASH_COMMIT - The hash of the squash commit that was merged
# MERGED_BRANCH - The name of the branch that was merged and will be deleted
# TARGET_BRANCH - The name of the branch that the PR was merged into
# PR_NUMBER - The number of the PR that was merged
#
# Required environment variables (conflict-resolved mode):
# PR_BRANCH - The head branch of the PR being resumed
# PR_NUMBER - Its PR number, from the event payload
# PR_BASE   - Its base branch, from the event payload
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
    local PR_NUMBER="$1"
    local BODIES
    if ! BODIES=$(gh pr view "$PR_NUMBER" --json comments \
            --jq '.comments[] | select(.viewerDidAuthor) | .body'); then
        echo "Error: could not read comments of PR #$PR_NUMBER" >&2
        exit 1
    fi
    { grep -F "$STATE_MARKER_PREFIX" <<<"$BODIES" || true; } | tail -n1
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

# Args: a commit sha. Echoes the numbers of the pull requests that introduced
# the commit to the repository, one per line.
commit_pull_numbers() {
    gh api "repos/{owner}/{repo}/commits/$1/pulls" --jq '.[].number' \
        || { echo "❌ Could not list the pull requests that introduced commit $1" >&2; return 1; }
}

# Args: the merge commit sha, the merged PR's number. The association is
# computed asynchronously, some time after the merge. The merge commit always
# belongs to the merged PR, so once it shows up the index has caught up with
# this merge; until then, an empty answer for any commit of the merge means
# nothing. Exits if the association never appears.
wait_for_pull_association() {
    local MERGE_SHA="$1" PR_NUMBER="$2"
    local NUMBERS
    for _ in $(seq 1 24); do
        NUMBERS=$(commit_pull_numbers "$MERGE_SHA") || exit 1
        if grep -qx "$PR_NUMBER" <<<"$NUMBERS"; then
            return 0
        fi
        sleep "${ASSOCIATION_POLL_SECONDS:-5}"
    done
    echo "❌ GitHub never associated $MERGE_SHA with PR #$PR_NUMBER; cannot tell a squash from a rebase" >&2
    exit 1
}

# Args: the merged PR's number. The event payload does not say which merge
# method was used (GitHub records it nowhere), but GitHub associates every
# trunk commit with the PR that introduced it. A squash introduces a single
# commit, so the commit below SQUASH_COMMIT belongs to an older PR or to
# none; a rebase introduces a copy of each PR commit, so with two or more
# commits the one below SQUASH_COMMIT still belongs to this PR. A
# single-commit PR merges identically under rebase and squash and correctly
# reads as a squash here.
is_rebase_merge() {
    local PR_NUMBER="$1"
    local MERGE_SHA PARENT_SHA NUMBERS
    MERGE_SHA=$(git rev-parse SQUASH_COMMIT)
    PARENT_SHA=$(git rev-parse SQUASH_COMMIT~)

    NUMBERS=$(commit_pull_numbers "$PARENT_SHA") || exit 1
    if [[ -z "$NUMBERS" ]]; then
        # Ambiguous: "no PR introduced this commit" (a squash on top of a
        # direct push) and "not indexed yet" (a rebase copy) both come back
        # empty. Wait until the index has caught up with this merge, then ask
        # again; this time empty really means no PR.
        wait_for_pull_association "$MERGE_SHA" "$PR_NUMBER"
        NUMBERS=$(commit_pull_numbers "$PARENT_SHA") || exit 1
    fi
    grep -qx "$PR_NUMBER" <<<"$NUMBERS"
}

# Echoes "<number> <head branch>" for each open PR based on the merged branch.
list_child_prs() {
    log_cmd gh pr list --base "$MERGED_BRANCH" --json number,headRefName --jq '.[] | "\(.number) \(.headRefName)"'
}

# A failed git merge does not always leave a merge in progress: when the ref to
# merge does not exist ("not something we can merge"), there is no MERGE_HEAD,
# and `git merge --abort` itself fails ("There is no merge to abort"). Only
# abort when a merge is actually in progress.
abort_merge_if_in_progress() {
    if git rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
        log_cmd git merge --abort
    fi
}

# Args: head branch, base branch, PR number. git commands use the branch; gh
# commands use the number, since a head branch can carry several PRs.
update_direct_target() {
    local BRANCH="$1"
    local BASE_BRANCH="$2"
    local PR_NUMBER="$3"

    # Checkout first to ensure the local branch exists (created from origin if
    # needed). This allows has_squash_commit to compare local refs, which matters
    # for testing where the script may run multiple times in the same repo.
    log_cmd git checkout "$BRANCH"

    if has_squash_commit "$BRANCH" "$TARGET_BRANCH"; then
        echo "✓ $BRANCH already up-to-date; skipping"
        return 0
    fi

    echo "Updating direct target $BRANCH (from $MERGED_BRANCH to $BASE_BRANCH)"

    local MERGE_MSG="Merge updates from $BASE_BRANCH and $MERGED_BRANCH"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        MERGE_MSG="$MERGE_MSG

See $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    fi

    # Re-parent the child onto the target in a single merge: merge the squash
    # commit with the base forced to merge-base(HEAD, origin/$MERGED_BRANCH). That
    # drops the merged branch's content (now carried by the target via the squash)
    # while keeping the child's own changes -- the merge equivalent of
    # `git rebase --onto`, done by the vendored git-merge-onto.
    local RC=0
    log_cmd python3 "$SCRIPT_DIR/git-merge-onto" -m "$MERGE_MSG" SQUASH_COMMIT "origin/$MERGED_BRANCH" || RC=$?
    if [[ "$RC" -eq 0 ]]; then
        return 0
    fi
    if [[ "$RC" -ne 1 ]]; then
        echo "❌ git-merge-onto failed (exit $RC) while re-parenting $BRANCH" >&2
        exit 1
    fi

    # Conflict (exit 1): git-merge-onto committed nothing and left the merge in
    # progress, so the head is unchanged and still a descendant of its base -- the
    # PR stays mergeable and the synchronize event that resumes this action keeps
    # firing. Clean the runner's tree, ask the user to resolve, and record the state
    # so the next push can resume. The label comes last: it is what re-triggers us.
    abort_merge_if_in_progress
    {
        echo "### ⚠️ Automatic update blocked by a merge conflict"
        echo
        echo "Resolve it like this:"
        echo '```bash'
        echo "git fetch origin"
        echo "git switch $BRANCH"
        echo "git merge --ff-only origin/$BRANCH"
        echo "uvx git-merge-onto origin/$BASE_BRANCH origin/$MERGED_BRANCH"
        echo '```'
        echo
        echo 'Fix the conflicts (for instance with `git mergetool`), then run `git add -A && git commit` to finish the merge.'
        echo
        echo '```bash'
        echo "git push origin $BRANCH"
        echo '```'
        echo
        echo "Once you push, this action will resume and finish updating this pull request."
        echo
        format_state_marker "$MERGED_BRANCH" "$TARGET_BRANCH" "$(git rev-parse SQUASH_COMMIT)"
    } | log_cmd gh pr comment "$PR_NUMBER" -F -
    gh label create "$CONFLICT_LABEL" --description "PR needs manual conflict resolution" --color "d73a4a" 2>/dev/null || true
    log_cmd gh pr edit "$PR_NUMBER" --add-label "$CONFLICT_LABEL"
    return 1
}

# Check if a PR has the conflict resolution label.
pr_has_conflict_label() {
    local PR_NUMBER="$1"
    local LABELS
    if ! LABELS=$(gh pr view "$PR_NUMBER" --json labels --jq '.labels[].name'); then
        echo "Error: could not read labels of PR #$PR_NUMBER" >&2
        exit 1
    fi
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
    local PR_NUMBER="$1"
    local MESSAGE="$2"
    echo "$MESSAGE" | log_cmd gh pr comment "$PR_NUMBER" -F -
    log_cmd gh pr edit "$PR_NUMBER" --remove-label "$CONFLICT_LABEL"
}

# Continue processing after user manually resolved conflicts
continue_after_resolution() {
    check_env_var "PR_BRANCH"
    check_env_var "PR_NUMBER"
    check_env_var "PR_BASE"

    echo "Checking if PR #$PR_NUMBER ($PR_BRANCH) needs continuation after conflict resolution..."

    # Check if the PR has the conflict label
    if ! pr_has_conflict_label "$PR_NUMBER"; then
        echo "✓ $PR_BRANCH does not have conflict label; nothing to do"
        return
    fi

    echo "Found conflict label on $PR_BRANCH, continuing stack update..."

    # The synchronize payload is the child PR, so SQUASH_COMMIT / MERGED_BRANCH /
    # TARGET_BRANCH from the original squash-merge run are not in the environment.
    # Recover them from the marker the squash-merge run left in the conflict
    # comment.
    local MARKER
    MARKER=$(read_state_marker "$PR_NUMBER")
    if [[ -z "$MARKER" ]]; then
        echo "⚠️ No autorestack state marker on $PR_BRANCH; cannot resume safely. Removing the label."
        abandon_resume "$PR_NUMBER" "ℹ️ autorestack could not find its state marker on this PR, so it will not update the stack automatically. If this PR still needs its base updated, update its base manually."
        return
    fi

    local OLD_BASE NEW_TARGET SQUASH_HASH
    read -r OLD_BASE NEW_TARGET SQUASH_HASH < <(parse_state_marker "$MARKER")
    echo "Recorded state: base=$OLD_BASE target=$NEW_TARGET squash=$SQUASH_HASH"

    if [[ -z "$OLD_BASE" || -z "$NEW_TARGET" || -z "$SQUASH_HASH" ]]; then
        echo "Error: malformed state marker on $PR_BRANCH: $MARKER" >&2
        exit 1
    fi

    # The PR was left based on the merged parent branch. If the payload shows a
    # different base, a human retargeted the PR; the recorded target is stale,
    # so step back before any mutation.
    if [[ "$PR_BASE" != "$OLD_BASE" ]]; then
        echo "⚠️ Base of $PR_BRANCH changed manually ($OLD_BASE -> $PR_BASE); not updating the stack."
        abandon_resume "$PR_NUMBER" "ℹ️ The base branch of this PR was changed manually, so autorestack stepped back and will not update it automatically."
        return
    fi

    # Defense in depth: never act on a target branch that no longer exists. The
    # action checks out with full history (fetch-depth: 0), so a missing origin
    # ref means the branch is really gone, not just unfetched; no future resume
    # can succeed, so give up cleanly rather than stranding the PR under the label.
    if ! git rev-parse --verify --quiet "origin/$NEW_TARGET" >/dev/null; then
        echo "⚠️ Recorded target branch '$NEW_TARGET' no longer exists; abandoning resume of $PR_BRANCH."
        abandon_resume "$PR_NUMBER" "ℹ️ The branch this PR was being retargeted onto (\`$NEW_TARGET\`) no longer exists, so autorestack stepped back. If this PR still needs its base updated, update its base manually."
        return
    fi

    # Same check for the old base: the resolution command we posted re-parents
    # against origin/$OLD_BASE, so if that branch is gone (auto-delete head branches
    # left enabled, or deleted manually) the user cannot resolve and the label would
    # re-trigger a failing run on every push. Give up cleanly instead.
    if ! git rev-parse --verify --quiet "origin/$OLD_BASE" >/dev/null; then
        echo "⚠️ Recorded base branch '$OLD_BASE' no longer exists; abandoning resume of $PR_BRANCH."
        abandon_resume "$PR_NUMBER" "ℹ️ The branch this PR was based on (\`$OLD_BASE\`) no longer exists, so autorestack stepped back. If this PR still needs its base updated, update its base manually."
        return
    fi

    # The user resolved by re-parenting (the comment's `git-merge-onto`), so the
    # head now contains the squash commit. Verify that and finalize -- do NOT re-run
    # the merge. Its forced base is the old parent, where the lines the user just
    # resolved still differ from the trunk, so a re-merge would re-raise the very
    # conflict they fixed. A plain ancestry check is all the resume needs.
    log_cmd git update-ref SQUASH_COMMIT "$SQUASH_HASH"
    log_cmd git checkout "$PR_BRANCH"
    if ! git merge-base --is-ancestor SQUASH_COMMIT "$PR_BRANCH"; then
        # Fail loudly rather than silently: the user pushed without finishing the
        # re-parent, so a red run is the signal they need to look again.
        echo "❌ '$PR_BRANCH' does not contain the squash commit; the conflict is not resolved." >&2
        echo "   Follow the conflict comment on this PR (run its git-merge-onto command), then push again." >&2
        return 1
    fi

    # Drop the label last: it is what re-triggers this action, so while any
    # earlier step can still fail it must stay on to let the next push resume.
    # Push the cleaned-up head before retargeting so the head already contains
    # NEW_TARGET when the base flips to it, keeping the PR mergeable (GitHub
    # suppresses CI on a PR that conflicts with its base).
    log_cmd git push origin "$PR_BRANCH"
    log_cmd gh pr edit "$PR_NUMBER" --base "$NEW_TARGET"
    log_cmd gh pr edit "$PR_NUMBER" --remove-label "$CONFLICT_LABEL"

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
    check_env_var "PR_NUMBER"

    log_cmd git update-ref SQUASH_COMMIT "$SQUASH_COMMIT"

    # A merge-commit merge does not rewrite history: each child's head already
    # contains the merged branch's commits, and the merge commit carries them
    # into TARGET_BRANCH. The heads need no synthetic merge; just retarget the
    # children and delete the merged branch.
    if git rev-parse --verify --quiet SQUASH_COMMIT^2 >/dev/null; then
        echo "✓ '$MERGED_BRANCH' was merged with a merge commit, not squashed; retargeting children without touching their heads"
        while read -r NUMBER BRANCH; do
            [[ -n "$BRANCH" ]] || continue
            log_cmd gh pr edit "$NUMBER" --base "$TARGET_BRANCH"
        done < <(list_child_prs)
        # Deleting a PR's base branch closes the PR, so the retargets come first.
        log_cmd git push origin ":$MERGED_BRANCH"
        return 0
    fi

    # Rebase merges are not supported: the copies on the target are new
    # commits, so a child retargeted as-is would show its parent's changes in
    # its diff, and the squash sequence can raise spurious conflicts against
    # the intermediate copies. Tell the children and leave everything alone.
    if is_rebase_merge "$PR_NUMBER"; then
        echo "⚠️ '$MERGED_BRANCH' looks rebase-merged; rebase merges are not supported, leaving the stack alone"
        while read -r NUMBER BRANCH; do
            [[ -n "$BRANCH" ]] || continue
            log_cmd gh pr comment "$NUMBER" --body "ℹ️ The base branch \`$MERGED_BRANCH\` of this PR was merged with \"Rebase and merge\", which autorestack does not support. Update this PR manually. \`$MERGED_BRANCH\` was kept so this PR stays open."
        done < <(list_child_prs)
        return 0
    fi

    # Find all PRs directly targeting the merged PR's head
    INITIAL_NUMBERS=()
    INITIAL_TARGETS=()
    while read -r NUMBER BRANCH; do
        [[ -n "$BRANCH" ]] || continue
        INITIAL_NUMBERS+=("$NUMBER")
        INITIAL_TARGETS+=("$BRANCH")
    done < <(list_child_prs)

    # Track successfully updated vs conflicted branches separately
    UPDATED_TARGETS=()
    UPDATED_NUMBERS=()
    CONFLICTED_TARGETS=()

    for i in "${!INITIAL_TARGETS[@]}"; do
        if update_direct_target "${INITIAL_TARGETS[$i]}" "$TARGET_BRANCH" "${INITIAL_NUMBERS[$i]}"; then
            UPDATED_TARGETS+=("${INITIAL_TARGETS[$i]}")
            UPDATED_NUMBERS+=("${INITIAL_NUMBERS[$i]}")
        else
            CONFLICTED_TARGETS+=("${INITIAL_TARGETS[$i]}")
        fi
    done

    # Push the heads before retargeting: a failed push then leaves each PR
    # intact on its old base, and the head already contains TARGET_BRANCH when
    # the base flips to it.
    if [[ "${#UPDATED_TARGETS[@]}" -gt 0 ]]; then
        log_cmd git push origin "${UPDATED_TARGETS[@]}"
    fi

    for NUMBER in "${UPDATED_NUMBERS[@]}"; do
        log_cmd gh pr edit "$NUMBER" --base "$TARGET_BRANCH"
    done

    # Deleting a PR's base branch closes the PR, so this must come after the
    # retargets. Keep the branch for reference while conflicted PRs remain.
    if [[ "${#CONFLICTED_TARGETS[@]}" -eq 0 ]]; then
        log_cmd git push origin ":$MERGED_BRANCH"
    else
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

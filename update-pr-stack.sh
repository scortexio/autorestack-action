#!/bin/bash
#
# Updates PR stack after merging a PR
#
# Required environment variables (squash-merge mode):
# SQUASH_COMMIT - The merged PR's merge_commit_sha: the squash commit, or the
#                 last copied commit of a rebase merge
# MERGED_BRANCH - The name of the branch that was merged and will be deleted
# TARGET_BRANCH - The name of the branch that the PR was merged into
# PR_NUMBER - The number of the PR that was merged
#
# Required environment variables (conflict-resolved mode):
# PR_BRANCH - The head branch of the PR being resumed
# PR_NUMBER - Its PR number, from the event payload
# PR_BASE   - Its base branch, from the event payload
# GITHUB_REPOSITORY - "owner/repo", provided by Actions
#
# Design note:
# This script aims to output a transcript of "plain" git/gh commands that a
# human could follow through manually. For this reason:
# - We use git refs (e.g., SQUASH_COMMIT) instead of shell variables where
#   possible, so the logged commands are self-contained and reproducible
# - We strive to keep commands as simple as possible

# set -u and pipefail do the real work here; set -e is only a backstop. It is
# suppressed inside if/&&/|| conditions and everything they call, including
# the whole body of update_direct_target (always invoked as a condition), so
# failure handling is explicit instead: run/try/die from command_utils.sh.
set -ueo pipefail

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
# Dies when the comments cannot be read at all: an API failure must not pass
# for "no marker", which the caller treats as a reason to give up the resume
# and remove the conflict label for good.
read_state_marker() {
    local PR_NUMBER="$1"
    local BODIES
    BODIES=$(gh api graphql --paginate \
            -F owner="${GITHUB_REPOSITORY%/*}" -F repo="${GITHUB_REPOSITORY#*/}" \
            -F number="$PR_NUMBER" -f query='
        query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
            repository(owner: $owner, name: $repo) {
                pullRequest(number: $number) {
                    comments(first: 100, after: $endCursor) {
                        pageInfo { hasNextPage endCursor }
                        nodes { viewerDidAuthor body }
                    }
                }
            }
        }' --jq '.data.repository.pullRequest.comments.nodes[] | select(.viewerDidAuthor) | .body') \
        || die "could not read comments of PR #$PR_NUMBER"
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
has_squash_commit() {
    local BRANCH="$1"
    local BASE="$2"
    git merge-base --is-ancestor "$BASE" "$BRANCH" \
        && git merge-base --is-ancestor SQUASH_COMMIT "$BRANCH"
}

# Echoes "<number> <head branch>" for each open PR based on the merged branch.
# try, not run: callers run this in a command substitution, where a die would
# only leave the subshell, so they capture the output and die themselves. An
# unhandled failure here must not pass for "no children": the caller would
# then delete the merged branch under the children it never saw.
list_child_prs() {
    try gh api "repos/{owner}/{repo}/pulls?base=$MERGED_BRANCH&state=open&per_page=100" \
        --paginate --jq '.[] | "\(.number) \(.head.ref)"'
}

# A failed git merge does not always leave a merge in progress: when the ref to
# merge does not exist ("not something we can merge"), there is no MERGE_HEAD,
# and `git merge --abort` itself fails ("There is no merge to abort"). Only
# abort when a merge is actually in progress.
abort_merge_if_in_progress() {
    if git rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
        run git merge --abort
    fi
}

# Post the conflict-resolution comment and add the conflict label.
# Args: head branch, merged parent branch, final target branch, squash hash, PR number.
# The user re-parents the head from MERGED onto TARGET with git-merge-onto; the
# state marker records both plus the squash so the resume can finalize.
post_conflict_comment() {
    local BRANCH="$1" MERGED="$2" TARGET="$3" SQUASH_HASH="$4" PR_NUMBER="$5"
    {
        echo "### ⚠️ Automatic update blocked by a merge conflict"
        echo
        echo "Resolve it like this:"
        echo '```bash'
        echo "git fetch origin"
        echo "git switch $BRANCH"
        echo "git merge --ff-only origin/$BRANCH"
        echo "uvx git-merge-onto origin/$TARGET origin/$MERGED --absorbed"
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
        format_state_marker "$MERGED" "$TARGET" "$SQUASH_HASH"
    } | try gh pr comment "$PR_NUMBER" -F - \
        || die "could not post the conflict-resolution comment on PR #$PR_NUMBER"
    gh label create "$CONFLICT_LABEL" --description "PR needs manual conflict resolution" --color "d73a4a" 2>/dev/null || true
    run gh pr edit "$PR_NUMBER" --add-label "$CONFLICT_LABEL"
}

# Args: head branch, base branch, PR number. git commands use the branch; gh
# commands use the number, since a head branch can carry several PRs.
update_direct_target() {
    local BRANCH="$1"
    local BASE_BRANCH="$2"
    local PR_NUMBER="$3"

    run git checkout "$BRANCH"

    # The target branch is never checked out, so it has no local ref, only the
    # remote-tracking one; a bare $TARGET_BRANCH would not resolve.
    if has_squash_commit "$BRANCH" "origin/$TARGET_BRANCH"; then
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
    # `git rebase --onto`, done by the vendored git-merge-onto. --absorbed records
    # the merged branch's tip as an extra parent: the head then still descends
    # from its current base (the merged branch) even when that base moved after
    # the head forked, so the PR reads as mergeable until it is retargeted.
    local RC=0
    try python3 "$SCRIPT_DIR/git-merge-onto" --absorbed -m "$MERGE_MSG" SQUASH_COMMIT "origin/$MERGED_BRANCH" || RC=$?
    if [[ "$RC" -eq 0 ]]; then
        return 0
    fi
    if [[ "$RC" -ne 1 ]]; then
        die "git-merge-onto failed (exit $RC) while re-parenting $BRANCH"
    fi

    # Conflict (exit 1): git-merge-onto committed nothing and left the merge in
    # progress. Clean the runner's tree, ask the user to resolve, and record the
    # state so the next push can resume. The label comes last: it is what
    # re-triggers us.
    #
    # The resume rides on a synchronize event, and GitHub creates no pull_request
    # runs for a PR that conflicts with its base. This PR's base is the merged
    # branch (kept until the resume retargets it), and the head does not always
    # descend from its tip: when an earlier run updated that branch after this
    # head forked (an ancestor PR merged first), GitHub falls back to a textual
    # merge to decide mergeability, which fails exactly when the resolution
    # rewrote the same lines. That would strand the PR: no run, label stuck.
    # --absorbed in the posted command is what prevents this: it records the
    # merged branch's tip as a parent of the resolution, so the pushed head
    # descends from its base again and the resume event is guaranteed to fire.
    abort_merge_if_in_progress
    local SQUASH_HASH_FOR_MARKER
    SQUASH_HASH_FOR_MARKER=$(git rev-parse SQUASH_COMMIT) || die "cannot resolve SQUASH_COMMIT"
    post_conflict_comment "$BRANCH" "$MERGED_BRANCH" "$TARGET_BRANCH" "$SQUASH_HASH_FOR_MARKER" "$PR_NUMBER"
    return 1
}

# Check if a PR has the conflict resolution label.
pr_has_conflict_label() {
    local PR_NUMBER="$1"
    local LABELS
    LABELS=$(gh pr view "$PR_NUMBER" --json labels --jq '.labels[].name') \
        || die "could not read labels of PR #$PR_NUMBER"
    echo "$LABELS" | grep -q "^${CONFLICT_LABEL}$"
}

# Check if any other PRs with conflict label still depend on a given base branch
# Returns 0 (true) if siblings exist, 1 (false) if no siblings
# Dies when the PRs cannot be listed: answering "no siblings" on an API failure
# makes the caller delete a branch a sibling may still need for its resolution.
has_sibling_conflicts() {
    local BASE_BRANCH="$1"
    local EXCLUDE_BRANCH="$2"

    # Find all open PRs with the conflict label that are based on BASE_BRANCH
    local CONFLICTED_SIBLINGS
    CONFLICTED_SIBLINGS=$(gh api "repos/{owner}/{repo}/pulls?base=$BASE_BRANCH&state=open&per_page=100" \
        --paginate --jq ".[] | select(any(.labels[]; .name == \"$CONFLICT_LABEL\")) | .head.ref") \
        || die "could not list conflicted PRs based on $BASE_BRANCH"

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
    echo "$MESSAGE" | try gh pr comment "$PR_NUMBER" -F - \
        || die "could not comment on PR #$PR_NUMBER"
    run gh pr edit "$PR_NUMBER" --remove-label "$CONFLICT_LABEL"
}

# Continue processing after user manually resolved conflicts
continue_after_resolution() {
    check_env_var "PR_BRANCH"
    check_env_var "PR_NUMBER"
    check_env_var "PR_BASE"
    check_env_var "GITHUB_REPOSITORY"

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
    MARKER=$(read_state_marker "$PR_NUMBER") || die "could not read the state marker of PR #$PR_NUMBER"
    if [[ -z "$MARKER" ]]; then
        echo "⚠️ No autorestack state marker on $PR_BRANCH; cannot resume safely. Removing the label."
        abandon_resume "$PR_NUMBER" "ℹ️ autorestack could not find its state marker on this PR, so it will not update the stack automatically. If this PR still needs its base updated, update its base manually."
        return
    fi

    local OLD_BASE NEW_TARGET SQUASH_HASH
    read -r OLD_BASE NEW_TARGET SQUASH_HASH < <(parse_state_marker "$MARKER")
    echo "Recorded state: base=$OLD_BASE target=$NEW_TARGET squash=$SQUASH_HASH"

    if [[ -z "$OLD_BASE" || -z "$NEW_TARGET" || -z "$SQUASH_HASH" ]]; then
        die "malformed state marker on $PR_BRANCH: $MARKER"
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
    run git update-ref SQUASH_COMMIT "$SQUASH_HASH"
    run git checkout "$PR_BRANCH"
    if ! git merge-base --is-ancestor SQUASH_COMMIT "$PR_BRANCH"; then
        # The head does not contain the squash commit: the user pushed without
        # finishing the re-parent, or followed an old-format conflict comment (a
        # prior action version) whose resolution never folds the squash in. Re-post
        # the current instructions and keep the label on so the next push resumes.
        # Still return 1: a red run flags that the PR is not resolved yet.
        echo "⚠️ '$PR_BRANCH' does not contain the squash commit yet; re-posting the conflict comment." >&2
        post_conflict_comment "$PR_BRANCH" "$OLD_BASE" "$NEW_TARGET" "$SQUASH_HASH" "$PR_NUMBER"
        return 1
    fi

    # Drop the label last: it is what re-triggers this action, so while any
    # earlier step can still fail it must stay on to let the next push resume.
    # Push the cleaned-up head before retargeting so the head already contains
    # NEW_TARGET when the base flips to it, keeping the PR mergeable (GitHub
    # suppresses CI on a PR that conflicts with its base).
    run git push origin "$PR_BRANCH"
    run gh pr edit "$PR_NUMBER" --base "$NEW_TARGET"
    run gh pr edit "$PR_NUMBER" --remove-label "$CONFLICT_LABEL"

    # Check if old base branch should be deleted
    if has_sibling_conflicts "$OLD_BASE" "$PR_BRANCH"; then
        echo "⚠️ Keeping branch '$OLD_BASE' - still referenced by other conflicted PRs"
    else
        echo "Deleting old base branch '$OLD_BASE' (no other PRs depend on it)"
        try git push origin ":$OLD_BASE" || echo "⚠️ Could not delete '$OLD_BASE' (may already be deleted)"
    fi
}

main() {
    # Check required environment variables
    check_env_var "SQUASH_COMMIT"
    check_env_var "MERGED_BRANCH"
    check_env_var "TARGET_BRANCH"
    check_env_var "PR_NUMBER"

    run git update-ref SQUASH_COMMIT "$SQUASH_COMMIT"

    # A merge-commit merge does not rewrite history: each child's head already
    # contains the merged branch's commits, and the merge commit carries them
    # into TARGET_BRANCH. The heads need no synthetic merge; just retarget the
    # children and delete the merged branch.
    if git rev-parse --verify --quiet SQUASH_COMMIT^2 >/dev/null; then
        echo "✓ '$MERGED_BRANCH' was merged with a merge commit, not squashed; retargeting children without touching their heads"
        CHILDREN=$(list_child_prs) || die "could not list the PRs based on $MERGED_BRANCH"
        while read -r NUMBER BRANCH; do
            [[ -n "$BRANCH" ]] || continue
            run gh pr edit "$NUMBER" --base "$TARGET_BRANCH"
        done <<<"$CHILDREN"
        # Deleting a PR's base branch closes the PR, so the retargets come first.
        run git push origin ":$MERGED_BRANCH"
        return 0
    fi

    # A squash merge and a rebase merge both land the branch's content as new
    # commits without merging its history, and both take the path below.
    # SQUASH_COMMIT (the PR's merge_commit_sha) is the squash commit or the
    # last rebased copy; either way its tree carries the merged branch's full
    # content, which is all the single-merge re-parent reads from it.

    # Find all PRs directly targeting the merged PR's head
    CHILDREN=$(list_child_prs) || die "could not list the PRs based on $MERGED_BRANCH"
    INITIAL_NUMBERS=()
    INITIAL_TARGETS=()
    while read -r NUMBER BRANCH; do
        [[ -n "$BRANCH" ]] || continue
        INITIAL_NUMBERS+=("$NUMBER")
        INITIAL_TARGETS+=("$BRANCH")
    done <<<"$CHILDREN"

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
        run git push origin "${UPDATED_TARGETS[@]}"
    fi

    for NUMBER in "${UPDATED_NUMBERS[@]}"; do
        run gh pr edit "$NUMBER" --base "$TARGET_BRANCH"
    done

    # Deleting a PR's base branch closes the PR, so this must come after the
    # retargets. Keep the branch for reference while conflicted PRs remain.
    if [[ "${#CONFLICTED_TARGETS[@]}" -eq 0 ]]; then
        run git push origin ":$MERGED_BRANCH"
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

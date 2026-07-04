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

# GitHub's served diff and a local `git diff` of the same trees agree on
# content but not on header noise: blob hashes (the index lines) differ
# between generators, and so can the "diff --git" line's formatting. Drop
# both, keep everything else verbatim.
normalize_diff() {
    sed -e '/^index /d' -e '/^diff --git /d'
}

# Args: PR number, head branch, base branch. Returns 0 when the diff GitHub
# serves for the PR matches one computed locally from the remote-tracking
# refs, 1 when it does not, 2 when a command failed. The local diff pins
# every config knob that shapes the text, so it reproduces GitHub's generator
# no matter what the runner's gitconfig says: diff.algorithm (hunk
# splitting), noprefix/mnemonicPrefix and the explicit --src/dst-prefix (the
# a/ b/ headers), diff.context (hunk sizes), --no-ext-diff and --no-textconv
# (content rewriting), --no-color.
served_diff_matches() {
    local NUMBER="$1" BRANCH="$2" BASE="$3"
    local SERVED EXPECTED
    SERVED=$(try gh pr diff "$NUMBER" | normalize_diff) || return 2
    EXPECTED=$(try git -c diff.algorithm=myers -c diff.noprefix=false \
        -c diff.mnemonicPrefix=false -c diff.context=3 \
        diff --no-color --no-ext-diff --no-textconv \
        --src-prefix=a/ --dst-prefix=b/ \
        "origin/$BASE...origin/$BRANCH" | normalize_diff) || return 2
    [[ "$SERVED" == "$EXPECTED" ]]
}

# Args: PR number, head branch. A verification step failed; the check is
# advisory, so tell the log and move on.
warn_unverified() {
    echo "⚠️ Could not verify the diff GitHub serves for PR #$1 ($2)" >&2
}

# Args: PR number, head branch. Advisory check that GitHub actually *serves*
# the PR's diff consistently with the refs, nudging its recompute when it
# does not. Always returns 0: the stack update itself is already complete, so
# a failure here only warns (and comments on the PR when the diff stays
# stale).
#
# Observed repeatedly on real GitHub (scortexio/gh-stack-mv#37 works around
# the same bug): after `gh pr edit --base`, GitHub sometimes keeps serving
# the diff computed against the OLD base. The PR record (baseRefName) is
# correct, only the diff endpoint is stale, and it stays stale until a fresh
# event on the PR triggers another recompute. The retarget is the last event
# this action feeds a PR, so left alone the PR's "Files changed" tab durably
# shows the parent's changes -- the very thing this action exists to prevent.
verify_pr_diff() {
    local NUMBER="$1" BRANCH="$2"
    local BASE RC

    # The base is read LIVE from the PR, never remembered from this run's own
    # retarget: a human retargeting the PR while this check runs must not
    # have their edit reverted by the nudge below.
    BASE=$(try gh pr view "$NUMBER" --json baseRefName --jq .baseRefName) \
        || { warn_unverified "$NUMBER" "$BRANCH"; return 0; }
    # The expected diff is computed from refs fetched at verification time:
    # the invariant checked is "the served diff is consistent with the refs
    # as they are NOW", which holds under any concurrent push history.
    try git fetch origin "refs/heads/$BASE" "refs/heads/$BRANCH" \
        || { warn_unverified "$NUMBER" "$BRANCH"; return 0; }

    RC=0; served_diff_matches "$NUMBER" "$BRANCH" "$BASE" || RC=$?
    if [[ "$RC" -eq 1 ]]; then
        # A push can land between the fetch above and gh's read, so a single
        # mismatch may be a torn read, not staleness. Re-fetch and re-compare
        # once before concluding anything.
        try git fetch origin "refs/heads/$BASE" "refs/heads/$BRANCH" \
            || { warn_unverified "$NUMBER" "$BRANCH"; return 0; }
        RC=0; served_diff_matches "$NUMBER" "$BRANCH" "$BASE" || RC=$?
    fi

    if [[ "$RC" -eq 1 ]]; then
        # Genuinely stale. Nudge: re-assert the base the PR has RIGHT NOW (a
        # same-value edit); its only purpose is to feed the diff recompute a
        # fresh event. Re-read rather than reuse: never write a value that
        # was not on the PR moments before.
        BASE=$(try gh pr view "$NUMBER" --json baseRefName --jq .baseRefName) \
            || { warn_unverified "$NUMBER" "$BRANCH"; return 0; }
        try gh pr edit "$NUMBER" --base "$BASE" \
            || { warn_unverified "$NUMBER" "$BRANCH"; return 0; }
        for _ in $(seq 1 5); do
            sleep "${VERIFY_POLL_SECONDS:-3}"
            # A concurrent push during this window would otherwise keep
            # reading as "still stale": keep the expected diff in step with
            # the refs.
            try git fetch origin "refs/heads/$BASE" "refs/heads/$BRANCH" \
                || { warn_unverified "$NUMBER" "$BRANCH"; return 0; }
            RC=0; served_diff_matches "$NUMBER" "$BRANCH" "$BASE" || RC=$?
            [[ "$RC" -eq 1 ]] || break
        done
    fi

    case "$RC" in
        0)
            echo "✓ GitHub serves the expected diff for PR #$NUMBER"
            ;;
        1)
            echo "⚠️ GitHub still serves a stale diff for PR #$NUMBER ($BRANCH) after a nudge" >&2
            {
                echo "### ⚠️ GitHub may be showing an outdated diff"
                echo
                echo "After the base branch of this pull request was updated, the diff GitHub serves for it still does not match \`$BASE...$BRANCH\`, and re-asserting the base branch did not refresh it. If the *Files changed* tab looks wrong, nudge the recompute again:"
                echo '```bash'
                echo "gh pr edit $NUMBER --base $BASE"
                echo '```'
            } | try gh pr comment "$NUMBER" -F - \
                || echo "⚠️ Could not comment on PR #$NUMBER" >&2
            ;;
        *)
            warn_unverified "$NUMBER" "$BRANCH"
            ;;
    esac
    return 0
}

# Args: PR number and head branch, repeated (N1 BRANCH1 N2 BRANCH2 ...).
verify_pr_diffs() {
    while (( $# >= 2 )); do
        verify_pr_diff "$1" "$2"
        shift 2
    done
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
    # `git rebase --onto`, done by the vendored git-merge-onto.
    local RC=0
    try python3 "$SCRIPT_DIR/git-merge-onto" -m "$MERGE_MSG" SQUASH_COMMIT "origin/$MERGED_BRANCH" || RC=$?
    if [[ "$RC" -eq 0 ]]; then
        return 0
    fi
    if [[ "$RC" -ne 1 ]]; then
        die "git-merge-onto failed (exit $RC) while re-parenting $BRANCH"
    fi

    # Conflict (exit 1): git-merge-onto committed nothing and left the merge in
    # progress, so the head is unchanged and still a descendant of its base -- the
    # PR stays mergeable and the synchronize event that resumes this action keeps
    # firing. Clean the runner's tree, ask the user to resolve, and record the state
    # so the next push can resume. The label comes last: it is what re-triggers us.
    abort_merge_if_in_progress
    local SQUASH_HASH_FOR_MARKER
    SQUASH_HASH_FOR_MARKER=$(git rev-parse SQUASH_COMMIT) || die "cannot resolve SQUASH_COMMIT"
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
        format_state_marker "$MERGED_BRANCH" "$TARGET_BRANCH" "$SQUASH_HASH_FOR_MARKER"
    } | try gh pr comment "$PR_NUMBER" -F - \
        || die "could not post the conflict-resolution comment on PR #$PR_NUMBER"
    gh label create "$CONFLICT_LABEL" --description "PR needs manual conflict resolution" --color "d73a4a" 2>/dev/null || true
    run gh pr edit "$PR_NUMBER" --add-label "$CONFLICT_LABEL"
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

    # Advisory, so strictly after every mutation the stack is owed.
    verify_pr_diffs "$PR_NUMBER" "$PR_BRANCH"
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
        VERIFY_ARGS=()
        while read -r NUMBER BRANCH; do
            [[ -n "$BRANCH" ]] || continue
            run gh pr edit "$NUMBER" --base "$TARGET_BRANCH"
            VERIFY_ARGS+=("$NUMBER" "$BRANCH")
        done <<<"$CHILDREN"
        # Deleting a PR's base branch closes the PR, so the retargets come first.
        run git push origin ":$MERGED_BRANCH"
        # Advisory, so strictly after every mutation the stack is owed.
        if [[ "${#VERIFY_ARGS[@]}" -gt 0 ]]; then
            verify_pr_diffs "${VERIFY_ARGS[@]}"
        fi
        return 0
    fi

    # Rebase merges are not supported: the copies on the target are new
    # commits, so a child retargeted as-is would show its parent's changes in
    # its diff, and the squash sequence can raise spurious conflicts against
    # the intermediate copies. Tell the children and leave everything alone.
    if is_rebase_merge "$PR_NUMBER"; then
        echo "⚠️ '$MERGED_BRANCH' looks rebase-merged; rebase merges are not supported, leaving the stack alone"
        CHILDREN=$(list_child_prs) || die "could not list the PRs based on $MERGED_BRANCH"
        while read -r NUMBER BRANCH; do
            [[ -n "$BRANCH" ]] || continue
            run gh pr comment "$NUMBER" --body "ℹ️ The base branch \`$MERGED_BRANCH\` of this PR was merged with \"Rebase and merge\", which autorestack does not support. Update this PR manually. \`$MERGED_BRANCH\` was kept so this PR stays open."
        done <<<"$CHILDREN"
        return 0
    fi

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

    # Advisory, so strictly after every mutation the stack is owed.
    VERIFY_ARGS=()
    for i in "${!UPDATED_NUMBERS[@]}"; do
        VERIFY_ARGS+=("${UPDATED_NUMBERS[$i]}" "${UPDATED_TARGETS[$i]}")
    done
    if [[ "${#VERIFY_ARGS[@]}" -gt 0 ]]; then
        verify_pr_diffs "${VERIFY_ARGS[@]}"
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

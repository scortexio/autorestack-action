#!/bin/bash

# Mock gh CLI for unit tests.
# Only direct children are queried now (no recursive updates of indirect children).

if [[ "$1" == "api" && "$2" == repos/*"/pulls?base="* ]]; then
    if [[ "${MOCK_PR_LIST_FAIL:-}" == 1 ]]; then
        echo "mock gh: pr list API down" >&2
        exit 1
    fi
    # Open PRs based on a branch (already --jq filtered to "<number> <head>").
    base="${2#*pulls\?base=}"
    base="${base%%&*}"
    if [[ "$base" == "feature1" ]]; then
        # feature2 is a direct child of feature1 (PR #2)
        echo '2 feature2'
    else
        # No other bases have direct children in our test scenario
        :
    fi
elif [[ "$1" == "pr" && "$2" == "view" && "$*" == *"--json baseRefName"* ]]; then
    # Only the served-diff verification asks; by then the PR has been
    # retargeted onto the target branch.
    echo "${TARGET_BRANCH:-main}"
elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
    # The diff GitHub serves for the PR. While the MOCK_STALE_DIFFS file
    # exists, serve garbage instead, simulating the staleness bug the
    # verification pass works around; see `pr edit` below for how it heals.
    if [[ -n "${MOCK_STALE_DIFFS:-}" && -e "$MOCK_STALE_DIFFS" ]]; then
        echo "stale diff from before the base update"
    elif [[ "$3" == 2 ]]; then
        # PR #2 is feature2 (see the pulls query above). Neutral config so
        # the output has the shape GitHub serves, whatever the test machine's
        # gitconfig says.
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
            git diff "origin/${TARGET_BRANCH:-main}...origin/feature2"
    else
        echo "Unknown PR number for pr diff: $3" >&2
        exit 1
    fi
elif [[ "$1" == "pr" && "$2" == "edit" ]]; then
    # A PR event feeds GitHub's diff recompute a fresh chance to run: count
    # down the edits the staleness survives, then heal the served diff.
    if [[ -n "${MOCK_STALE_DIFFS:-}" && -e "$MOCK_STALE_DIFFS" ]]; then
        N=$(cat "$MOCK_STALE_DIFFS")
        if [[ "$N" -gt 0 ]]; then
            echo "$((N - 1))" > "$MOCK_STALE_DIFFS"
        else
            rm "$MOCK_STALE_DIFFS"
        fi
    fi
    echo "Mock: gh pr edit $3 --base $5"
elif [[ "$1" == "pr" && "$2" == "comment" ]]; then
    # A `-F -` body arrives on stdin; consume it so the writer does not die
    # on a broken pipe.
    if [[ "$*" == *"-F"* ]]; then
        cat > /dev/null
    fi
    # Just log the comment command
    echo "Mock: gh pr comment $3"
elif [[ "$1" == "api" && "$2" == repos/*/commits/*/pulls ]]; then
    # Which PRs introduced this trunk commit (already --jq filtered to bare
    # numbers). The merge commit belongs to the merged PR, and so does any sha
    # listed in MOCK_REBASE_COPIES (space-separated); anything else was not
    # introduced by a PR. SQUASH_COMMIT and PR_NUMBER come from the test's env.
    sha="${2#*/commits/}"
    sha="${sha%/pulls}"
    if [[ "$sha" == "$SQUASH_COMMIT" || " ${MOCK_REBASE_COPIES:-} " == *" $sha "* ]]; then
        echo "$PR_NUMBER"
    fi
else
    echo "Unknown gh command: $@" >&2
    exit 1
fi

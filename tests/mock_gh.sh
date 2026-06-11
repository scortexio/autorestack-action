#!/bin/bash

# Mock gh CLI for unit tests.
# Only direct children are queried now (no recursive updates of indirect children).

if [[ "$1" == "pr" && "$2" == "list" ]]; then
    if [[ "${MOCK_PR_LIST_FAIL:-}" == 1 ]]; then
        echo "mock gh: pr list API down" >&2
        exit 1
    fi
    # Parse the --base argument to determine which PRs to return
    base=""
    for ((i=1; i<=$#; i++)); do
        if [[ "${!i}" == "--base" ]]; then
            next=$((i+1))
            base="${!next}"
        fi
    done

    if [[ "$base" == "feature1" ]]; then
        # feature2 is a direct child of feature1 (PR #2)
        echo '2 feature2'
    else
        # No other bases have direct children in our test scenario
        :
    fi
elif [[ "$1" == "pr" && "$2" == "edit" ]]; then
    # Just log the edit command
    echo "Mock: gh pr edit $3 --base $5"
elif [[ "$1" == "pr" && "$2" == "comment" ]]; then
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

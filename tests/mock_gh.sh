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
elif [[ "$1" == "pr" && "$2" == "edit" ]]; then
    # Just log the edit command
    echo "Mock: gh pr edit $3 --base $5"
elif [[ "$1" == "pr" && "$2" == "comment" ]]; then
    # Consume the body when it comes on stdin (-F -); keep a copy for tests
    # that assert on the comment's content.
    if [[ " $* " == *" -F "* ]]; then
        cat > "${MOCK_COMMENT_FILE:-/dev/null}"
    fi
    # Just log the comment command
    echo "Mock: gh pr comment $3"
else
    echo "Unknown gh command: $@" >&2
    exit 1
fi

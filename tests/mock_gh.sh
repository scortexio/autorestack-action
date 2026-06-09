#!/bin/bash

# Mock gh CLI for unit tests.
# Only direct children are queried now (no recursive updates of indirect children).

if [[ "$1" == "pr" && "$2" == "list" ]]; then
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
else
    echo "Unknown gh command: $@" >&2
    exit 1
fi

#!/bin/bash


if [[ "$1" == "push" || "$1" == "fetch" ]]; then
    # Log the attempt but don't execute: the test repos have no real remote.
    # push would fail outright; refs/remotes/origin/* stand for the remote's
    # state and are maintained by the tests' simulate_push instead.
    printf "Executing (mocked):" >&2
    printf " %q" "git" "$@" >&2
    printf "\n" >&2
else
    # Pass through any other git command to the real git
    exec git "$@"
fi

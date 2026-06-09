#!/bin/bash

# Function to log and execute commands
log_cmd() {
    printf "Executing:" >&2
    printf " %q" "$@" >&2
    printf "\n" >&2
    "$@"
}

die() {
    echo "❌ $*" >&2
    exit 1
}

# Log and execute a command, aborting the run if it fails. The explicit exit
# in die aborts from any context; `set -e` does not, because it is suppressed
# inside if/&&/|| conditions and everything they call, including the whole
# body of a function invoked as a condition.
#
# Note: inside a command substitution, exit only leaves the subshell, so
# `VAR=$(run ...)` does not abort the script. Use `VAR=$(try ...) || die ...`
# instead.
run() {
    log_cmd "$@" || die "command failed (exit $?): $*"
}

# Log and execute a command whose failure is an expected outcome (e.g. a
# merge that may conflict), handing the exit status to the caller.
try() {
    log_cmd "$@"
}

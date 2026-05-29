#!/bin/bash
#
# Test for the "bot does the clean work, user resolves only the genuine
# conflict" behaviour, in two parts.
#
# When updating a descendant branch after a parent squash-merge, the parent
# branch is merged first (step 1), then the target's pre-squash state (step 2),
# then the squash is recorded with -s ours (step 0).
#
# Part A (squash-merge mode): step 1 is clean but step 2 conflicts. The action
# pushes the step-1 result to the branch BEFORE posting the comment and label,
# so the head stays a descendant of its base. That keeps the PR mergeable and
# lets the synchronize event that resumes the action still fire (GitHub does not
# run pull_request workflows on a PR conflicting with its base). The posted
# comment is unchanged: it lists only the genuine conflict (the pre-squash
# merge), because step 1 was clean and never entered the conflict list.
#
# Part B (conflict-resolved mode): after the user resolves step 2 and pushes,
# continue_after_resolution records the squash with -s ours and pushes BEFORE
# retargeting, so the branch ends up mergeable into the new target. The squash
# commit is reconstructed from the merged parent PR (mergeCommit), since the
# synchronize payload is the child PR and SQUASH_COMMIT is not in the env.
#
# Runs fully offline. Unlike the other unit tests, its mock git APPLIES pushes
# to local origin refs, so the simulated user picks up what the action pushed.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../command_utils.sh"

simulate_push() {
    log_cmd git update-ref "refs/remotes/origin/$1" "$1"
}

TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
echo "Created test repo at $TEST_REPO"

# Mock git that applies pushes to local origin refs and passes everything else
# through. This lets the action's internal push actually move origin/feature2.
cat > "$TEST_REPO/mock_git.sh" <<'MOCK_GIT'
#!/bin/bash
if [[ "$1" == "push" ]]; then
    shift
    remote=""
    specs=()
    for a in "$@"; do
        case "$a" in
            -*) ;;  # ignore flags like --force-with-lease
            *) if [[ -z "$remote" ]]; then remote="$a"; else specs+=("$a"); fi ;;
        esac
    done
    for s in "${specs[@]}"; do
        if [[ "$s" == :* ]]; then
            git update-ref -d "refs/remotes/origin/${s#:}" 2>/dev/null || true
        else
            git update-ref "refs/remotes/origin/$s" "$s"
        fi
    done
    printf "Executing (mock push applied):" >&2
    printf " %q" git push "$@" >&2
    printf "\n" >&2
    exit 0
fi
exec git "$@"
MOCK_GIT
chmod +x "$TEST_REPO/mock_git.sh"

# Mock gh. Records the conflict comment and answers the queries the action makes.
# Reads MOCK_SQUASH from the environment so it can report the parent PR's merge
# commit during conflict-resolved mode.
COMMENT_FILE="$TEST_REPO/conflict_comment.md"
CONFLICT_LABEL="autorestack-needs-conflict-resolution"
cat > "$TEST_REPO/mock_gh.sh" <<MOCK_GH
#!/bin/bash
CONFLICT_LABEL="$CONFLICT_LABEL"
COMMENT_FILE="$COMMENT_FILE"
MOCK_GH
cat >> "$TEST_REPO/mock_gh.sh" <<'MOCK_GH'
# Extract the value following a flag (e.g. --json) from the arg list.
flag_value() {
    local want="$1"; shift
    for ((i=1; i<=$#; i++)); do
        if [[ "${!i}" == "$want" ]]; then local n=$((i+1)); echo "${!n}"; return; fi
    done
}
has_flag() {
    local want="$1"; shift
    for a in "$@"; do [[ "$a" == "$want" ]] && return 0; done
    return 1
}

if [[ "$1" == "pr" && "$2" == "list" ]]; then
    base=$(flag_value --base "$@")
    head=$(flag_value --head "$@")
    json=$(flag_value --json "$@")
    if [[ -n "$head" ]]; then
        # Query about the merged parent PR (head=$OLD_BASE).
        case "$json" in
            baseRefName) echo "main" ;;
            mergeCommit) echo "$MOCK_SQUASH" ;;
        esac
    elif [[ "$base" == "feature1" ]]; then
        # INITIAL_TARGETS and has_sibling_conflicts both query --base feature1.
        echo "feature2"
    fi
elif [[ "$1" == "pr" && "$2" == "view" ]]; then
    json=$(flag_value --json "$@")
    case "$json" in
        labels) echo "$CONFLICT_LABEL" ;;
        baseRefName) echo "feature1" ;;
    esac
elif [[ "$1" == "pr" && "$2" == "comment" ]]; then
    cat > "$COMMENT_FILE"
elif [[ "$1" == "label" || ( "$1" == "pr" && "$2" == "edit" ) ]]; then
    : # ignore label creation / edits
else
    echo "Unknown gh command: $@" >&2
    exit 1
fi
MOCK_GH
chmod +x "$TEST_REPO/mock_gh.sh"

# Replaying merges may create non-ff merge commits; never open an editor.
export GIT_EDITOR=true

log_cmd git init -b main
log_cmd git config user.email "test@example.com"
log_cmd git config user.name "Test User"

for i in $(seq 1 12); do echo "line $i" >> file.txt; done
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
simulate_push main

# feature1 (parent PR): first commit on line 2.
log_cmd git checkout -b feature1
sed -i '2s/.*/f1 commit 1/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 1"
simulate_push feature1

# feature2 (child PR): branched off feature1, changes line 9.
log_cmd git checkout -b feature2
sed -i '9s/.*/f2 content line 9/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f2: change line 9"
simulate_push feature2
ORIG_FEATURE2=$(git rev-parse feature2)

# feature1 advances AFTER feature2 branched (line 4): merging origin/feature1
# into feature2 is clean and substantive.
log_cmd git checkout feature1
sed -i '4s/.*/f1 commit 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 2"
simulate_push feature1

# main advances on line 9 so the pre-squash target conflicts with feature2.
log_cmd git checkout main
sed -i '9s/.*/main conflicting line 9/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "main: conflicting change on line 9"
simulate_push main

# Squash-merge feature1 into main.
log_cmd git checkout main
log_cmd git merge --squash feature1
log_cmd git commit -m "Squash merge feature1"
SQUASH_COMMIT=$(git rev-parse HEAD)
simulate_push main
echo "Squash commit: $SQUASH_COMMIT"

############################################################################
# Part A: squash-merge mode — clean step-1 merge, conflicting step-2 merge.
############################################################################

log_cmd \
  env \
  SQUASH_COMMIT="$SQUASH_COMMIT" \
  MERGED_BRANCH=feature1 \
  TARGET_BRANCH=main \
  GH="$TEST_REPO/mock_gh.sh" \
  GIT="$TEST_REPO/mock_git.sh" \
  "$SCRIPT_DIR/../update-pr-stack.sh"

if [[ ! -f "$COMMENT_FILE" ]]; then
    echo "❌ No conflict comment was posted; scenario did not trigger a conflict"
    exit 1
fi

echo ""
echo "=== Conflict comment posted to the PR ==="
cat "$COMMENT_FILE"
echo ""

FAILED=0

# The action should have pushed the base-branch merge to origin/feature2.
if log_cmd git merge-base --is-ancestor origin/feature1 origin/feature2; then
    echo "✅ origin/feature2 now contains origin/feature1 (action pushed the base merge)"
else
    echo "❌ origin/feature2 does not contain origin/feature1; the base merge was not pushed"
    FAILED=1
fi

# ...and that push must be a fast-forward on top of the original branch (so the
# PR stays mergeable into its base and the synchronize event still fires).
if log_cmd git merge-base --is-ancestor "$ORIG_FEATURE2" origin/feature2; then
    echo "✅ origin/feature2 is a descendant of the original branch (mergeable into its base)"
else
    echo "❌ origin/feature2 is not a descendant of the original branch"
    FAILED=1
fi

# The comment must not ask the user to redo the base merge the action did, and
# must list the genuine conflict: the pre-squash target state (SQUASH_COMMIT~).
if grep -q '^git merge origin/feature1' "$COMMENT_FILE"; then
    echo "❌ Comment asks the user to merge origin/feature1, which the action already did"
    FAILED=1
else
    echo "✅ Comment omits the base merge the action already pushed"
fi

if grep -q "^git merge $(git rev-parse "$SQUASH_COMMIT"~)" "$COMMENT_FILE"; then
    echo "✅ Comment asks the user to resolve the genuine conflict (pre-squash merge)"
else
    echo "❌ Comment does not list the pre-squash merge as the conflict to resolve"
    FAILED=1
fi

[[ "$FAILED" -ne 0 ]] && exit 1

############################################################################
# Simulate the user resolving the conflict by following the comment, starting
# from the branch as it is on the remote (which now includes the action's base
# merge), resolving by keeping our (feature2) side.
############################################################################

log_cmd git checkout feature2
log_cmd git reset --hard origin/feature2

MERGE_CMDS=$(grep -E '^git merge' "$COMMENT_FILE" || true)
if [[ -z "$MERGE_CMDS" ]]; then
    echo "❌ Comment lists no 'git merge' commands to follow"
    exit 1
fi

while IFS= read -r cmd; do
    echo "Human runs: $cmd"
    if ! log_cmd bash -c "$cmd"; then
        echo "Resolving conflict by keeping our (feature2) side..."
        log_cmd git checkout --ours -- file.txt
        log_cmd git add file.txt
        log_cmd git commit --no-edit
    fi
done <<< "$MERGE_CMDS"

simulate_push feature2

# The old base branch gets deleted during continuation, so capture its tip now.
FEATURE1_TIP=$(git rev-parse feature1)

############################################################################
# Part B: conflict-resolved mode — record the squash and push, then retarget.
############################################################################

log_cmd \
  env \
  ACTION_MODE=conflict-resolved \
  PR_BRANCH=feature2 \
  MOCK_SQUASH="$SQUASH_COMMIT" \
  GH="$TEST_REPO/mock_gh.sh" \
  GIT="$TEST_REPO/mock_git.sh" \
  "$SCRIPT_DIR/../update-pr-stack.sh"

echo ""
echo "=== feature2 after the action recorded the squash ==="
log_cmd git log --graph --oneline --all
echo ""

# The squash must now be recorded on origin/feature2 (-s ours), so the branch is
# mergeable into the new target (main == SQUASH_COMMIT after the squash-merge).
if log_cmd git merge-base --is-ancestor "$SQUASH_COMMIT" origin/feature2; then
    echo "✅ origin/feature2 records the squash commit (mergeable into main)"
else
    echo "❌ origin/feature2 is missing the squash commit after continuation"
    FAILED=1
fi

if log_cmd git merge-base --is-ancestor "$FEATURE1_TIP" origin/feature2; then
    echo "✅ origin/feature2 still includes the parent branch's advanced content"
else
    echo "❌ origin/feature2 is missing the parent branch's content"
    FAILED=1
fi

# main is now an ancestor of feature2, so merging feature2 into main is a clean
# fast-forward: the diff against the new base is exactly feature2's own change.
if log_cmd git merge-base --is-ancestor origin/main origin/feature2; then
    echo "✅ origin/main is an ancestor of origin/feature2 (clean diff against new base)"
else
    echo "❌ origin/main is not an ancestor of origin/feature2"
    FAILED=1
fi

[[ "$FAILED" -ne 0 ]] && exit 1

echo ""
echo "All push-base-merge-on-conflict tests passed! 🎉"
echo "Test repository remains at: $TEST_REPO for inspection"

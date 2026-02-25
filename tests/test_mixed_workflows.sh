#!/bin/bash
#
# Test mixed merge/rebase workflows where feature2 is NOT fully up to date
# with feature1 at the time of squash-merge.
#
# Scenarios:
#   A) feature2 rebased onto an intermediate state of feature1, then feature1
#      got more commits that feature2 never picked up.
#   B) feature2 merged feature1 once, then rebased onto a later feature1 state,
#      but feature1 got yet more commits after that.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../command_utils.sh"

simulate_push() {
    log_cmd git update-ref "refs/remotes/origin/$1" "$1"
}

# Extract just the +/- lines from a diff (ignoring headers and context)
diff_changes() {
    grep '^[+-]' | grep -v '^[+-][+-][+-]'
}

run_scenario() {
    local SCENARIO_NAME="$1"
    echo ""
    echo "============================================"
    echo "  Scenario $SCENARIO_NAME"
    echo "============================================"
    echo ""

    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"

    log_cmd git init -b main
    log_cmd git config user.email "test@example.com"
    log_cmd git config user.name "Test User"

    # 10-line file to keep changes well-separated
    for i in $(seq 1 10); do echo "line $i" >> file.txt; done
    log_cmd git add file.txt
    log_cmd git commit -m "Initial commit"
    simulate_push main
}

assert_diff_is() {
    local LABEL="$1"
    local EXPECTED="$2"
    local ACTUAL
    ACTUAL=$(log_cmd git diff main...feature2 | diff_changes)
    if [[ "$ACTUAL" == "$EXPECTED" ]]; then
        echo "✅ $LABEL"
    else
        echo "❌ $LABEL"
        echo "Expected changed lines:"
        echo "$EXPECTED"
        echo "Actual changed lines:"
        echo "$ACTUAL"
        exit 1
    fi
}

assert_idempotent() {
    local BEFORE AFTER
    BEFORE=$(git rev-parse feature2)
    run_update_pr_stack
    cd "$TEST_REPO"
    AFTER=$(git rev-parse feature2)
    if [[ "$BEFORE" == "$AFTER" ]]; then
        echo "✅ Idempotent"
    else
        echo "❌ Idempotence failed"
        exit 1
    fi
}

squash_merge_feature1() {
    log_cmd git checkout main
    log_cmd git merge --squash feature1
    log_cmd git commit -m "Squash merge feature1"
    SQUASH_COMMIT=$(git rev-parse HEAD)
    simulate_push main
    echo "Squash commit: $SQUASH_COMMIT"
}

run_update_pr_stack() {
    log_cmd \
      env \
      SQUASH_COMMIT=$SQUASH_COMMIT \
      MERGED_BRANCH=feature1 \
      TARGET_BRANCH=main \
      GH="$SCRIPT_DIR/mock_gh.sh" \
      GIT="$SCRIPT_DIR/mock_git.sh" \
      $SCRIPT_DIR/../update-pr-stack.sh
}

########################################################################
# Scenario A: rebase onto intermediate feature1, then feature1 advances
########################################################################
run_scenario "A: rebased onto intermediate feature1, then feature1 advances"

# feature1: two commits (lines 2 and 3)
log_cmd git checkout -b feature1
sed -i '2s/.*/f1 commit 1/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 1"
simulate_push feature1

# feature2: branched from feature1 after commit 1, changes line 9
log_cmd git checkout -b feature2
sed -i '9s/.*/f2 content/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f2: change line 9"
simulate_push feature2

# feature1 gets commit 2
log_cmd git checkout feature1
sed -i '3s/.*/f1 commit 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 2"
simulate_push feature1

# Developer rebases feature2 onto feature1 (picks up commit 2)
log_cmd git checkout feature2
log_cmd git rebase feature1
simulate_push feature2

# feature1 gets commit 3 — feature2 does NOT pick this up
log_cmd git checkout feature1
sed -i '4s/.*/f1 commit 3/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 3"
simulate_push feature1

echo ""
echo "=== Graph before squash-merge ==="
log_cmd git log --graph --oneline --all
echo ""

squash_merge_feature1
run_update_pr_stack
cd "$TEST_REPO"

# The diff should show only feature2's unique change
assert_diff_is "Scenario A: diff shows only f2's change" "$(cat <<'EOF'
-line 9
+f2 content
EOF
)"
assert_idempotent

########################################################################
# Scenario B: merge then rebase, then feature1 advances again
########################################################################
run_scenario "B: merge then rebase, then feature1 advances again"

# feature1: commit 1 (line 2)
log_cmd git checkout -b feature1
sed -i '2s/.*/f1 commit 1/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 1"
simulate_push feature1

# feature2 from feature1, changes line 9
log_cmd git checkout -b feature2
sed -i '9s/.*/f2 content/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f2: change line 9"
simulate_push feature2

# feature1 gets commit 2
log_cmd git checkout feature1
sed -i '3s/.*/f1 commit 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 2"
simulate_push feature1

# Developer merges feature1 into feature2
log_cmd git checkout feature2
log_cmd git merge --no-edit feature1
simulate_push feature2

# feature1 gets commit 3
log_cmd git checkout feature1
sed -i '4s/.*/f1 commit 3/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 3"
simulate_push feature1

# Developer rebases feature2 onto latest feature1 (rewrite away the merge)
log_cmd git checkout feature2
log_cmd git rebase feature1
simulate_push feature2

# feature1 gets commit 4 — feature2 does NOT pick this up
log_cmd git checkout feature1
sed -i '5s/.*/f1 commit 4/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "f1: commit 4"
simulate_push feature1

echo ""
echo "=== Graph before squash-merge ==="
log_cmd git log --graph --oneline --all
echo ""

squash_merge_feature1
run_update_pr_stack
cd "$TEST_REPO"

assert_diff_is "Scenario B: diff shows only f2's change" "$(cat <<'EOF'
-line 9
+f2 content
EOF
)"
assert_idempotent

########################################################################
echo ""
echo "All mixed-workflow tests passed! 🎉"

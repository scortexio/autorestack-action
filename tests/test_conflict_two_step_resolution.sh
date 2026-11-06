#!/bin/bash
#
# Replays the incident that stranded a conflicted PR (scortexio/gh-stack-mv#36):
#
#   1. main <- feature1 <- feature2, where feature1 advanced AFTER feature2
#      forked (in the incident, autorestack itself advanced it when a
#      grandparent PR merged). feature1's tip is therefore NOT an ancestor of
#      feature2.
#   2. feature1 is squash-merged; the action's re-parent of feature2 conflicts,
#      so the action posts the resolution comment and stops.
#   3. The user resolves with the two posted merges: origin/feature1, then
#      origin/main.
#
# The resolution must descend from origin/feature1's tip: feature2's PR is
# still based on feature1 at that point, and GitHub creates no pull_request
# runs for a PR that conflicts with its base, so without that ancestry the
# resume event may never fire and the conflict label stays stuck forever.

set -ueo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../command_utils.sh"

simulate_push() {
    log_cmd git update-ref "refs/remotes/origin/$1" "$1"
}

TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
echo "Created test repo at $TEST_REPO"

log_cmd git init -b main
log_cmd git config user.email "test@example.com"
log_cmd git config user.name "Test User"

for i in $(seq 1 10); do echo "line $i" >> file.txt; done
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
simulate_push main

# feature1: modify line 2
log_cmd git checkout -b feature1
sed -i '2s/.*/Feature 1 version A/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature1: commit A"
simulate_push feature1

# feature2 forks here and modifies the same line 2: its resolution will rewrite
# the very lines the squash reshapes, which is what made the incident's PR read
# as conflicting with its base.
log_cmd git checkout -b feature2
sed -i '2s/.*/Feature 2 version/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature2: change line 2"
simulate_push feature2

# feature1 advances after the fork: its tip is no longer an ancestor of feature2.
log_cmd git checkout feature1
sed -i '2s/.*/Feature 1 version B/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "feature1: commit B"
simulate_push feature1
FEATURE1_TIP=$(git rev-parse feature1)

if git merge-base --is-ancestor "$FEATURE1_TIP" feature2; then
    echo "❌ Setup broken: feature1's tip must not be an ancestor of feature2"
    exit 1
fi

# Squash-merge feature1 into main
log_cmd git checkout main
log_cmd git merge --squash feature1
log_cmd git commit -m "Squash merge feature1"
SQUASH_COMMIT=$(git rev-parse HEAD)
simulate_push main

FEATURE2_BEFORE=$(git rev-parse feature2)
# Outside the test repo: an untracked file makes git-merge-onto refuse to run.
COMMENT_FILE=$(mktemp)

# The action must hit the conflict path: comment, label, no push, branch kept.
OUT=$(env \
    SQUASH_COMMIT="$SQUASH_COMMIT" \
    MERGED_BRANCH=feature1 \
    MERGED_TIP=$(git rev-parse feature1) \
    PR_NUMBER=1 \
    TARGET_BRANCH=main \
    GH="$SCRIPT_DIR/mock_gh.sh" \
    GIT="$SCRIPT_DIR/mock_git.sh" \
    MOCK_COMMENT_FILE="$COMMENT_FILE" \
    "$SCRIPT_DIR/../update-pr-stack.sh" 2>&1)
echo "$OUT"

if ! grep -q "Mock: gh pr comment 2" <<<"$OUT"; then
    echo "❌ Expected a conflict comment on the child PR"
    exit 1
fi
if grep -q "origin :feature1" <<<"$OUT"; then
    echo "❌ The merged branch must be kept while the child is conflicted"
    exit 1
fi
if [[ "$(git rev-parse feature2)" != "$FEATURE2_BEFORE" ]]; then
    echo "❌ feature2 must not move on a conflict"
    exit 1
fi
for REF in origin/feature1 origin/main; do
    if ! grep -qxF "git merge $REF" "$COMMENT_FILE"; then
        echo "❌ The posted resolution must run 'git merge $REF'"
        cat "$COMMENT_FILE"
        exit 1
    fi
done
echo "✅ Conflict detected: two-step resolution posted, stack left alone"

# Resolve as the comment instructs. Both merges conflict: feature2 rewrote line 2,
# which feature1 rewrote too, and a plain merge of main uses the true merge base,
# from before feature1 existed.
log_cmd git checkout feature2
for REF in origin/feature1 origin/main; do
    if log_cmd git merge --no-edit "$REF"; then
        echo "❌ Merging $REF should conflict (both sides rewrote line 2)"
        exit 1
    fi
    sed -i '/^<<<<<<</,/^>>>>>>>/c\Feature 2 version' file.txt
    log_cmd git add file.txt
    log_cmd git commit --no-edit
done
simulate_push feature2

# The regression assertion: the resolution descends from the old base's tip.
if log_cmd git merge-base --is-ancestor "$FEATURE1_TIP" feature2; then
    echo "✅ Resolution descends from origin/feature1's tip (first merge recorded it)"
else
    echo "❌ Resolution does not descend from origin/feature1's tip"
    log_cmd git log --graph --oneline feature2 feature1
    exit 1
fi
if ! log_cmd git merge-base --is-ancestor "$SQUASH_COMMIT" feature2; then
    echo "❌ Resolution must contain the squash commit (resume checks this)"
    exit 1
fi

# And the content is the user's resolution on top of main.
if [[ "$(sed -n '2p' file.txt)" == "Feature 2 version" ]]; then
    echo "✅ Resolved content kept"
else
    echo "❌ Resolved content lost: $(sed -n '2p' file.txt)"
    exit 1
fi

echo ""
echo "All two-step resolution tests passed! 🎉"
echo "Test repository remains at: $TEST_REPO for inspection"

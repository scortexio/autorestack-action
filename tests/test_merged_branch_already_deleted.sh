#!/bin/bash
#
# Someone can click "Delete branch" on the merged PR while the action is still
# running. The deletion is the action's last step, so the run must still end
# green.

set -ueo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() { echo "❌ $1"; exit 1; }

WORK=$(mktemp -d)
ORIGIN=$(mktemp -d)
MOCK_DIR=$(mktemp -d)
git init -q --bare "$ORIGIN"
git init -q -b main "$WORK"
cd "$WORK"
git config user.email t@e.com && git config user.name t
git remote add origin "$ORIGIN"

echo base > f.txt && git add f.txt && git commit -qm initial
git checkout -q -b parent
echo parent > p.txt && git add p.txt && git commit -qm parent
MERGED_TIP=$(git rev-parse parent)
git checkout -q -b child
echo child > c.txt && git add c.txt && git commit -qm child
git checkout -q main
git merge -q --squash parent && git commit -qm "Squash merge parent"
SQUASH_COMMIT=$(git rev-parse main)
git push -q origin main parent child
git fetch -q origin

# The branch disappears from the remote after the action's checkout.
git --git-dir="$ORIGIN" update-ref -d refs/heads/parent

cat > "$MOCK_DIR/gh" <<'MOCK'
#!/bin/bash
if [[ "$1" == "api" ]]; then echo "2 child"; fi
MOCK
chmod +x "$MOCK_DIR/gh"

RC=0
env SQUASH_COMMIT="$SQUASH_COMMIT" MERGED_BRANCH=parent MERGED_TIP="$MERGED_TIP" \
    TARGET_BRANCH=main PR_NUMBER=1 GH="$MOCK_DIR/gh" \
    bash "$ROOT_DIR/update-pr-stack.sh" >"$MOCK_DIR/out.log" 2>&1 || RC=$?

[[ "$RC" -eq 0 ]] || { cat "$MOCK_DIR/out.log"; fail "the run must succeed when the merged branch is already deleted"; }
grep -q "'parent' was already deleted" "$MOCK_DIR/out.log" || fail "expected a warning about the deleted branch"
git fetch -q origin
git merge-base --is-ancestor "$SQUASH_COMMIT" origin/child || fail "child must be re-parented onto main"

echo "✅ Already-deleted merged branch: warned, not failed"

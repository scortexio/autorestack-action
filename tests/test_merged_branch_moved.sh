#!/bin/bash
#
# A commit pushed to the merged branch after GitHub squash-merged it is in
# neither the squash commit nor the children: the child must not absorb it, and
# the merged branch must not be deleted.

set -ueo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() { echo "❌ $1"; exit 1; }
ok() { echo "✅ $1"; }

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

# Someone pushes to the parent branch after the merge, before the action runs.
git checkout -q parent
echo late > late.txt && git add late.txt && git commit -qm late
LATE=$(git rev-parse parent)
git push -q origin parent
git checkout -q main
git fetch -q origin

cat > "$MOCK_DIR/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "api" ]]; then echo "2 child"; fi
EOF
chmod +x "$MOCK_DIR/gh"

RC=0
env SQUASH_COMMIT="$SQUASH_COMMIT" MERGED_BRANCH=parent MERGED_TIP="$MERGED_TIP" \
    TARGET_BRANCH=main PR_NUMBER=1 GH="$MOCK_DIR/gh" \
    bash "$ROOT_DIR/update-pr-stack.sh" >"$MOCK_DIR/out.log" 2>&1 || RC=$?

git fetch -q origin
git merge-base --is-ancestor "$SQUASH_COMMIT" origin/child || fail "child must be re-parented onto main"
git merge-base --is-ancestor "$LATE" origin/child && fail "child must not absorb the late commit"
ok "child re-parented without absorbing the late commit"

[[ "$(git rev-parse origin/parent 2>/dev/null)" == "$LATE" ]] || fail "parent branch must be kept at the late commit"
[[ "$RC" -ne 0 ]] || fail "the run must fail when it cannot delete the merged branch"
ok "parent branch kept, run failed"

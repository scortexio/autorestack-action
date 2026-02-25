## Stacked PRs with squash & merge

### The problem

If you want stacked pull requests on GitHub, one way to do it that stays easy for people who aren't rebase wizards is to use a simple `git push` / `git merge` workflow while working on your PRs.

When you merge the lower PR in the stack, you just need to update the upper PR. This works fine if you use regular merge commits, but your trunk history becomes very hard to read with normal tooling like the GitHub commit history page (though you can still navigate it with `git log --first-parent`).

If you use squash & merge instead, your main branch history stays nice and clean, but now the upper PR in the stack gets a garbage diff and merge conflicts when you try to update it. This happens because the squash commit rewrites history, and GitHub can't figure out what the PR is actually trying to change.

### The solution

This action tries to fix that in a transparent way. Install it, and hopefully the workflow of stacking + merge during dev + squash merge when landing works. It also works if you rebase during development instead of merging.

---

### How it works

1. Triggers when a PR is squash merged
2. Finds PRs that were based on the merged branch (direct children only)
3. Creates a synthetic merge commit with three parents (child tip, deleted branch tip, squash commit) to preserve history without re-introducing code
4. Updates the direct child PRs to base on trunk now that the bottom change has landed
5. Force-pushes updated branches and deletes the merged branch

**Note:** Indirect descendants (grandchildren, etc.) are intentionally not modified. Their PR diffs remain correct because the merge-base calculation still works—the synthetic merge commit includes the original parent commit as an ancestor. When their direct parent is eventually merged, they become direct children and get updated at that point.

### Conflict handling

When a merge conflict occurs during the automatic update:

1. The action posts a comment on the affected PR with instructions for manual resolution
2. Adds a `autorestack-needs-conflict-resolution` label to the PR
3. Keeps the PR's base branch unchanged (so the diff stays readable)
4. Keeps the merged branch around (so you can reference it during resolution)

After you manually resolve the conflict and push:

1. The push triggers the `synchronize` event
2. The action detects the conflict label and removes it
3. Updates the PR's base branch to trunk
4. Deletes the old base branch (if no other conflicted PRs still depend on it)

---

### Setup

**1. Disable auto-delete head branches**

The action manages branch deletion itself. GitHub's auto-delete setting must be disabled:

**Via Settings:**
- Go to your repository Settings → General → Pull Requests
- Uncheck "Automatically delete head branches"

**Via GitHub CLI:**
```bash
gh api -X PATCH "/repos/OWNER/REPO" --input - <<< '{"delete_branch_on_merge":false}'
```

**2. Create a GitHub App**

When autorestack pushes the synthetic merge commit to upstack branches, you probably want CI to run on those PRs so they can become mergeable. Pushes made with the default `GITHUB_TOKEN` [do not trigger workflow runs](https://docs.github.com/en/actions/security-guides/automatic-token-authentication#using-the-github_token-in-a-workflow) — this is a deliberate GitHub limitation to prevent infinite loops. A GitHub App installation token does not have this limitation.

1. [Create a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app) with the following repository permissions:
   - **Contents:** Read and write (to push branches)
   - **Pull requests:** Read and write (to update PRs, add labels, post comments)
2. Install the app on your repository
3. Store the App ID in a repository variable (e.g. `AUTORESTACK_APP_ID`)
4. Generate a private key and store it in a repository secret (e.g. `AUTORESTACK_PRIVATE_KEY`)

**3. Add the workflow**

Create a `.github/workflows/update-pr-stack.yml` file:
```yaml
name: Update PR Stack

on:
  pull_request:
    types: [closed, synchronize]

jobs:
  update-pr-stack:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/create-github-app-token@v2
        id: app-token
        with:
          app-id: ${{ vars.AUTORESTACK_APP_ID }}
          private-key: ${{ secrets.AUTORESTACK_PRIVATE_KEY }}

      - uses: Phlogistique/autorestack-action@main
        with:
          github-token: ${{ steps.app-token.outputs.token }}
```

<details>
<summary>Using <code>GITHUB_TOKEN</code> instead (CI won't trigger on upstack PRs)</summary>

If you don't need CI checks on upstack PRs — for example, if your repository has no branch protection rules requiring status checks — you can use the default token:

```yaml
name: Update PR Stack

on:
  pull_request:
    types: [closed, synchronize]

permissions:
  contents: write
  pull-requests: write

jobs:
  update-pr-stack:
    runs-on: ubuntu-latest
    steps:
      - uses: Phlogistique/autorestack-action@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

</details>

### Notes

* Currently only supports squash merges
* If a merge hits a conflict, you'll need to resolve it manually; pushing the resolution automatically continues the stack update
* Very large stacks might hit GitHub rate limits

---

### Credits

Inspired by Graphite and Gerrit workflows but implemented with plain git + GitHub CLI.

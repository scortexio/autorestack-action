# Running the tests

You CAN run every test in this repo yourself. Do not claim a test is
"left to CI" or "can't be run locally" — that is false here.

## Offline unit tests (instant, no credentials)

```bash
bash tests/test_update_pr_stack.sh
bash tests/test_rebase_workflow.sh
bash tests/test_mixed_workflows.sh
```

## Full end-to-end test (real GitHub, several minutes)

```bash
bash .claude/run-e2e-tests.sh
```

This is self-contained: direnv supplies the GitHub App credentials, the script
installs `gh` if missing, mints a short-lived token, then runs `tests/test_e2e.sh`,
which creates and tears down a throwaway public repo under the `autorestack-test`
org and waits on real GitHub Actions runs. It tests the currently checked-out
HEAD commit, so commit (and usually push, so the workflow can reference the
action at that commit) before running. It is long, so run it in the background.

## You must validate e2e changes, one way or the other

A change that touches `tests/test_e2e.sh`, `update-pr-stack.sh`, or the action
workflow is not done until the e2e has actually passed against it. Either:

- run `.claude/run-e2e-tests.sh` locally, or
- if you pushed, the `Tests` CI workflow (`.github/workflows/tests.yml`) runs the
  same `tests/test_e2e.sh` on the PR. In that case set a watcher and confirm it
  succeeds before reporting the change as validated:

  ```bash
  gh run watch "$(gh run list --branch <branch> --workflow Tests --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
  ```

Don't run a local e2e *and* let CI run the identical pushed commit — that spends
two throwaway repos for one check. Pick one.

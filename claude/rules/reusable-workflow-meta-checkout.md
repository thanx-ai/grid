---
title: "Reusable workflows: checkout the meta-repo at github.job_workflow_sha"
tags: [github-actions, reusable-workflow, ci, workflow-design]
---

`thanx-ai/grid`'s reusable workflows (`ci.yml`, `deploy.yml`) execute shell scripts under `scripts/` that live in this repo, not in the caller. When the workflow runs, the caller's repo is checked out at the workspace root — the meta-repo's scripts aren't on disk unless we explicitly fetch them.

## The pattern

Every reusable workflow job that invokes a `scripts/` shell script must:

1. Checkout the caller (default `actions/checkout@v6`, which checks out the repo that triggered the workflow).
2. Checkout `thanx-ai/grid` at **`github.job_workflow_sha`** into `.grid-meta/`.
3. Invoke the script as `bash .grid-meta/scripts/<name>.sh` from the caller's root.

```yaml
- name: Checkout caller repo
  uses: actions/checkout@v6

- name: Checkout thanx-ai/grid (for shared scripts)
  uses: actions/checkout@v6
  with:
    repository: thanx-ai/grid
    ref: ${{ github.job_workflow_sha }}
    path: .grid-meta

- name: Run shared script
  run: bash .grid-meta/scripts/lint-raw-apps.sh
```

## Why `github.job_workflow_sha`, not `GITHUB_WORKFLOW_REF`

`github.job_workflow_sha` is documented as "for jobs using a reusable workflow, the commit SHA for the reusable workflow file." It resolves at job-start time to the SHA of THIS reusable workflow, regardless of how the caller pinned it (`@v0.1.0`, `@master`, `@<sha>`). It works for every external caller.

`GITHUB_WORKFLOW_REF` (and the equivalent `github.workflow_ref`) was the previous (broken) approach. It points at the **caller's trigger ref**, not the called reusable workflow's ref. For an external caller:

- PR trigger → `caller-repo/.github/workflows/grid.yml@refs/pull/N/merge`
- Master push → `caller-repo/.github/workflows/grid.yml@refs/heads/master`

`${GITHUB_WORKFLOW_REF##*@}` then yields `refs/pull/N/merge` or `refs/heads/master`, and `actions/checkout@v6 repository: thanx-ai/grid ref: <that>` fails with `fatal: couldn't find remote ref refs/pull/N/merge` — those refs don't exist in `thanx-ai/grid`. The bug appeared only against external callers because for `self-test.yml` (caller=callee=thanx-ai/grid), `refs/heads/master` does exist locally and the checkout coincidentally succeeds.

## Why ref-matching matters at all

If a caller pins `uses: thanx-ai/grid/.github/workflows/ci.yml@v0.1.0`, the workflow YAML is loaded at `v0.1.0`. If we then checked out `thanx-ai/grid@master` for the scripts, **the script behavior would drift from the workflow YAML**: a v0.1.0 caller would get whatever `master` looked like the moment the job ran. That defeats the point of pinning a version.

`github.job_workflow_sha` resolves to the exact SHA the workflow YAML was loaded from, so the scripts ship at the same revision as the workflow that referenced them.

## Why scripts live in `scripts/`, not in the workflow YAML

The lint, variable-reference, and deploy-test logic is non-trivial (parsing `wmill app lint` output for esbuild warnings, hitting the Windmill API to validate refs, etc.). Keeping it in bash means:

- It's testable locally without spinning up a GitHub Actions runner.
- The `self-test.yml` workflow can shellcheck it as a CI gate.
- Team members can run it against a local Windmill via `bash scripts/lint-raw-apps.sh`.

Inlining 100+ lines of bash into a workflow `run:` block loses all three properties.

## How the scripts find the caller's content

Each script does `repo_root="$(git rev-parse --show-toplevel)"` then `cd "$repo_root"`. `git rev-parse` walks up from the current directory, so as long as the script runs from inside the caller's checkout (which it does — the caller is the default workspace), it finds the caller's root, not the meta-repo's. **Do not** add explicit path arguments — the existing pattern works for any caller layout.

## How to verify a change to this pattern

Self-test (`self-test.yml`) catches YAML / bash syntax errors but **cannot detect external-caller regressions** — its caller is itself, so `GITHUB_WORKFLOW_REF` happens to yield the right ref by coincidence. To verify any change to the meta-checkout flow, run the change against the `thanx-ai/grid-shared` repo's workflow end-to-end (PR CI green, master deploy succeeds). The v0.1.0 `GITHUB_WORKFLOW_REF` bug shipped because this end-to-end check was skipped — self-test was the only gate.

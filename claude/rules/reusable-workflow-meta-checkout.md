---
title: "Reusable workflows: checkout the meta-repo at the caller's pinned ref"
tags: [github-actions, reusable-workflow, ci, workflow-design]
---

`thanx-ai/grid`'s reusable workflows (`ci.yml`, `deploy.yml`) execute shell scripts under `scripts/` that live in this repo, not in the caller. When the workflow runs, the caller's repo is checked out at the workspace root — the meta-repo's scripts aren't on disk unless we explicitly fetch them.

## The pattern

Every reusable workflow job that invokes a `scripts/` shell script must:

1. Checkout the caller (default `actions/checkout@v6`, which checks out the repo that triggered the workflow).
2. Compute the meta-repo ref from `GITHUB_WORKFLOW_REF`.
3. Checkout `thanx-ai/grid` at that ref into a subdirectory (`.grid-meta` by convention).
4. Invoke the script as `bash .grid-meta/scripts/<name>.sh` from the caller's root.

```yaml
- name: Checkout caller repo
  uses: actions/checkout@v6

- name: Resolve meta-repo ref
  id: meta
  # GITHUB_WORKFLOW_REF looks like
  # "thanx-ai/grid/.github/workflows/ci.yml@refs/tags/v0.1.0"
  # — we want the ref after the '@'.
  run: echo "ref=${GITHUB_WORKFLOW_REF##*@}" >> "$GITHUB_OUTPUT"

- name: Checkout thanx-ai/grid (for shared scripts)
  uses: actions/checkout@v6
  with:
    repository: thanx-ai/grid
    ref: ${{ steps.meta.outputs.ref }}
    path: .grid-meta

- name: Run shared script
  run: bash .grid-meta/scripts/lint-raw-apps.sh
```

## Why ref-matching matters

If a caller pins `uses: thanx-ai/grid/.github/workflows/ci.yml@v0.1.0`, the workflow YAML is loaded at `v0.1.0`. If we then checked out `thanx-ai/grid@master` for the scripts, **the script behavior would drift from the workflow YAML**: a v0.1.0 caller would get whatever `master` looked like the moment the job ran. That defeats the point of pinning a version.

Using `${GITHUB_WORKFLOW_REF##*@}` ensures the scripts ship at the exact same revision as the workflow that referenced them.

## Why scripts live in `scripts/`, not in the workflow YAML

The lint, variable-reference, and deploy-test logic is non-trivial (parsing `wmill app lint` output for esbuild warnings, hitting the Windmill API to validate refs, etc.). Keeping it in bash means:

- It's testable locally without spinning up a GitHub Actions runner.
- The `self-test.yml` workflow can shellcheck it as a CI gate.
- Team members can run it against a local Windmill via `bash scripts/lint-raw-apps.sh`.

Inlining 100+ lines of bash into a workflow `run:` block loses all three properties.

## How the scripts find the caller's content

Each script does `repo_root="$(git rev-parse --show-toplevel)"` then `cd "$repo_root"`. `git rev-parse` walks up from the current directory, so as long as the script runs from inside the caller's checkout (which it does — the caller is the default workspace), it finds the caller's root, not the meta-repo's. **Do not** add explicit path arguments — the existing pattern works for any caller layout.

## How to verify a change to this pattern

Bump the version tag (`v0.1.1`, `v0.2.0`) on this repo, then run the `grid-examples` repo's workflow against the new tag and confirm both CI and deploy succeed end-to-end. The `self-test.yml` here only catches YAML / bash syntax errors — semantic regressions in the checkout flow only surface against a live caller.

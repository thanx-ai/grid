---
title: "Reusable workflows: checkout the meta-repo at ref: master"
tags: [github-actions, reusable-workflow, ci, workflow-design]
---

`thanx-ai/grid-tooling`'s reusable workflows (`ci.yml`, `deploy.yml`) execute shell scripts under `scripts/` that live in this repo, not in the caller. When the workflow runs, the caller's repo is checked out at the workspace root — the meta-repo's scripts aren't on disk unless we explicitly fetch them.

## The pattern

Every reusable workflow job that invokes a `scripts/` shell script must:

1. Checkout the caller (default `actions/checkout@v6`, which checks out the repo that triggered the workflow).
2. Checkout `thanx-ai/grid-tooling` at **`master`** into `.grid-meta/`.
3. Invoke the script as `bash .grid-meta/scripts/<name>.sh` from the caller's root.

```yaml
- name: Checkout caller repo
  uses: actions/checkout@v6

- name: Checkout thanx-ai/grid-tooling (for shared scripts)
  uses: actions/checkout@v6
  with:
    repository: thanx-ai/grid-tooling
    ref: master
    path: .grid-meta

- name: Run shared script
  run: bash .grid-meta/scripts/lint-raw-apps.sh
```

## Why `master`, not `github.job_workflow_sha` or `GITHUB_WORKFLOW_REF`

The instinct is to checkout the meta-repo at the same SHA the reusable workflow YAML was loaded from, so the scripts can't drift from the workflow mid-run. Two earlier attempts failed against external callers:

1. **`${GITHUB_WORKFLOW_REF##*@}`** — this is the *caller's* trigger ref, not the called workflow's ref:
   - PR trigger → `refs/pull/N/merge`
   - Master push → `refs/heads/master`
   `actions/checkout` then fails with `fatal: couldn't find remote ref refs/pull/N/merge` because those refs don't exist in `thanx-ai/grid-tooling`. (Self-test passes by coincidence — caller=callee, so `refs/heads/master` happens to exist locally.)

2. **`${{ github.job_workflow_sha }}`** — documented to "for jobs using a reusable workflow, the commit SHA for the reusable workflow file," but empirically resolves to **empty string** when the reusable workflow is in a different repo than the caller. With `ref:` empty, `actions/checkout` falls back to a `GET /repos/{owner}/{repo}` REST call to determine the default branch — and the caller's `GITHUB_TOKEN` cannot read this private repo's metadata, even though the org-level reusable-workflow access setting (`actions/permissions/access: organization`) authorizes loading the YAML and the git-protocol fetch. The REST API has stricter scoping than git-over-HTTPS for cross-repo, same-org private access. Result: `Not Found - https://docs.github.com/rest/repos/repos#get-a-repository` and the job dies before any real work runs.

Hardcoding `ref: master` sidesteps both:

- It's a real, fetchable ref in `thanx-ai/grid-tooling` (no `refs/pull/N/merge` confusion).
- `actions/checkout` skips the REST default-branch lookup entirely when `ref:` is set, so it just does `git fetch origin refs/heads/master` over HTTPS — which the caller's GITHUB_TOKEN *can* perform under the org-level access setting.

## The trade-off

`ref: master` means the scripts can drift from the workflow YAML mid-run if someone merges to `thanx-ai/grid-tooling` master between the moment GitHub loads the reusable workflow and the moment the meta-checkout step actually runs. That window is small (seconds), and the trade-off is consistent with the broader "ship on master" policy in [`CLAUDE.md`](../../CLAUDE.md) — every caller is on `@master` anyway, so the same drift can already happen across runs. We've decided that operational simplicity beats sub-minute drift protection.

## Why scripts live in `scripts/`, not in the workflow YAML

The lint, variable-reference, and deploy-test logic is non-trivial (parsing `wmill app lint` output for esbuild warnings, hitting the Windmill API to validate refs, etc.). Keeping it in bash means:

- It's testable locally without spinning up a GitHub Actions runner.
- The `self-test.yml` workflow can shellcheck it as a CI gate.
- Team members can run it against a local Windmill via `bash scripts/lint-raw-apps.sh`.

Inlining 100+ lines of bash into a workflow `run:` block loses all three properties.

## How the scripts find the caller's content

Each script does `repo_root="$(git rev-parse --show-toplevel)"` then `cd "$repo_root"`. `git rev-parse` walks up from the current directory, so as long as the script runs from inside the caller's checkout (which it does — the caller is the default workspace), it finds the caller's root, not the meta-repo's. **Do not** add explicit path arguments — the existing pattern works for any caller layout.

## How to verify a change to this pattern

Self-test (`self-test.yml`) catches YAML / bash syntax errors but **cannot detect external-caller regressions** — its caller is itself, so any cross-repo failure mode is hidden. To verify any change to the meta-checkout flow, run the change against `thanx-ai/grid-shared`'s workflow end-to-end (PR CI green, master deploy succeeds). Both the `GITHUB_WORKFLOW_REF` bug and the `github.job_workflow_sha`-empty bug shipped because this end-to-end check was skipped — self-test was the only gate.

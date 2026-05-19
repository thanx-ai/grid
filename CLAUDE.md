# CLAUDE.md

Guidance for Claude Code working in this repo.

## This is a public repo

`thanx-ai/grid` is published as a public GitHub repo. **Never write anything sensitive into this tree** — no tokens, deploy keys, API secrets, internal-only URLs (besides the already-public `grid.thanx.com` / `grid-origin.thanx.com`), customer data, employee PII, or `.env` files. If you're about to commit anything that looks like a credential, stop and route it to the consuming repo's GitHub Actions secrets instead. The `.gitignore` covers obvious files (`.env`, `.env.*`, `.wmill/`) but it can't catch a token hardcoded into a workflow YAML — review every diff with that lens before pushing.

## Read first

At the start of every session, read every file under `claude/rules/`. Those capture specific gotchas that bit us in past sessions; the bar for adding one is "this surprised us once and would surprise us again." If a rule there contradicts something below, the rule wins (and fix this file in the same PR).

## What this repo is

`thanx-ai/grid` is a **meta-repo**, not a content repo. It ships two things:

1. **Reusable GitHub Actions workflows** (`.github/workflows/ci.yml`, `deploy.yml`) that project repos call via `uses: thanx-ai/grid/.github/workflows/deploy.yml@v0.1.0`. The deploy workflow does **per-item** `wmill <type> push` against the Grid (`https://grid.thanx.com`) — never `wmill sync push`, because that would let one project repo's deploy delete items owned by another. See [`claude/rules/per-item-push-not-sync.md`](./claude/rules/per-item-push-not-sync.md).
2. **`grid` — a Claude Code plugin** (under `.claude-plugin/` and `skills/`) that bootstraps individual project repos: scaffolds `wmill.yaml`, the repo's thin `.github/workflows/grid.yml`, and copies the conventions in `claude/rules/` into the project repo so future Claude sessions there pick them up.

**There is no `f/` content in this repo.** Grid code lives in each person's own project repo (e.g. `thanx-ai/grid-shared`, which is the canonical reference). If you're tempted to add an `f/<scope>/...` file here, you're solving the wrong problem — it belongs in a project repo.

## Architecture

### The scope model

Grid code is owned per-person, not per-team. Each person has their own GitHub project repo; inside it, **each item picks its own scope folder**:

| Folder       | Use when                                                                    |
| ------------ | --------------------------------------------------------------------------- |
| `f/company/` | The item is genuinely cross-functional and everyone at Thanx should use it. |
| `f/<dept>/`  | The item is owned by one department (`f/eng/`, `f/cs/`, `f/sales/`, …).     |

Both are workspace-readable; the distinction is ownership and write access (dept-group write via SCIM for `f/<dept>/`, broader for `f/company/`). The `u/<you>/` namespace exists in Windmill but the plugin's scaffolders don't target it — prototypes live as drafts in the same project repo, not as a separate maturity tier.

The plugin's `/grid:create` (and sibling scaffolders) asks scope per item. A single project repo routinely ships to both `f/company/` and `f/<dept>/`.

### Reusable workflows

Both reusable workflows follow the same pattern: checkout the caller, checkout `thanx-ai/grid` at the same ref into `.grid-meta/`, invoke shared scripts under `.grid-meta/scripts/`. See [`claude/rules/reusable-workflow-meta-checkout.md`](./claude/rules/reusable-workflow-meta-checkout.md) for why and how. **If you change `scripts/*.sh`, the change ships at the ref the caller pinned — `v0.1.0` callers get `v0.1.0` scripts, not whatever's on master.**

The workflows expect callers to follow the Grid conventions (folder-permissioned `f/` paths, raw_app layout, deploy-test annotation pattern). Those conventions are documented in `claude/rules/` and ride along into project repos via the plugin's `setup` skill (Step 4).

### Versioning

Every change that affects the public surface of `ci.yml`, `deploy.yml`, or the plugin's scaffolds requires a version bump:

- **Patch** (`v0.1.0` → `v0.1.1`) — bug fixes, internal script tweaks that don't change inputs/outputs.
- **Minor** (`v0.1.0` → `v0.2.0`) — new optional inputs, new optional skill steps. Backward-compatible.
- **Major** (`v0.x` → `v1.0`) — breaking changes to workflow inputs, secret names, or scaffolded files.

The moving major tag (`v0`, `v1`) tracks the latest minor/patch in that line so callers pinning `@v0` get rolling updates within `0.x`. After a release, run:

```bash
git tag v0.1.1
git tag -f v0
git push --tags --force-with-lease
```

While the plugin and workflows are unstable (pre-`v1`), bumps happen liberally. Once at `v1`, breaking changes are rare and well-announced.

## Layout

```
.claude-plugin/         # plugin manifest + marketplace.json
.github/workflows/      # reusable workflows + self-test
  ci.yml                # reusable: lint raw apps + check variable refs
  deploy.yml            # reusable: per-item `wmill <type> push` + deploy tests
  self-test.yml         # this repo's own CI (actionlint + shellcheck)
claude/rules/           # conventions Claude reads at session start
                        # (canonical source; plugin copies to project repos)
scripts/                # bash scripts invoked by reusable workflows
  lint-raw-apps.sh
  check-variable-references.sh
  changed-grid-items.sh   # classifies changed paths into wmill push args
  deploy-grid-items.sh    # loops `wmill <type> push` over the changed set
  run-deploy-tests.sh
skills/                 # plugin skills (/grid:setup, /grid:create, /grid:import)
  setup/                # one-time repo bootstrap (wmill.yaml, workflow caller, token, rules)
  create/               # scaffold a NEW raw_app, picking scope per app
  import/               # adopt an EXISTING project / HTML file as a raw_app
```

## Common commands

```bash
# Verify a reusable-workflow change locally
shellcheck scripts/*.sh
bash -n scripts/*.sh

# After editing a workflow YAML, run actionlint:
bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)
./actionlint -color

# Tag a release (post-merge to master)
git tag v0.1.1 && git tag -f v0 && git push --tags --force-with-lease

# Test a workflow change end-to-end against grid-shared
# 1. Push the change to a branch on this repo
# 2. In grid-shared, temporarily change @v0.1.0 → @<your-branch>
# 3. Trigger CI in grid-shared and watch it run against your branch
```

## What goes where

When making changes, route by purpose:

| Change                                    | File(s) to touch                                       |
| ----------------------------------------- | ------------------------------------------------------ |
| Bug in lint/check/test bash script        | `scripts/<name>.sh` — patch bump                       |
| New optional workflow input               | `.github/workflows/<name>.yml` — minor bump            |
| Breaking workflow change                  | `.github/workflows/<name>.yml` — major bump + announce |
| New plugin skill                          | `skills/<name>/SKILL.md` + update `.claude-plugin/`    |
| Convention every project repo should know | `claude/rules/<topic>.md` — picked up by `setup`       |
| Internal rule (meta-repo authoring only)  | `claude/rules/<topic>.md` + skip-list in `setup`       |

## Self-test CI

`self-test.yml` runs on every PR. It does **not** touch a live Windmill workspace — only actionlint + shellcheck. To catch semantic regressions in the reusable workflows, push a branch and run `grid-shared`'s workflow against it (see Common commands above).

## Conventions

- Plugin skills live at `skills/<name>/SKILL.md`. The filename is fixed; the directory name is the skill name.
- Scripts use `bash`, are `set -euo pipefail`, and pass shellcheck. No silent fallbacks — fail loud.
- Workflow YAML files use 2-space indent. Inputs and secrets are explicitly typed and described.
- "the Grid" in prose; `thanx-ai/grid` (repo slug) and `grid` (plugin name) are exact strings preserved as-is. The plugin used to be called `thanx-grid` — don't reintroduce that name.
- Help / access questions: `#ai-help-desk` Slack channel. The GitHub team reviewer is `@eng-platform` (it exists as a GitHub team; the Slack channel of that name does not).

## Capture friction as rules

If you hit a non-obvious gotcha while working here — a misleading doc, a CLI flag whose behaviour surprises you, an API shape you got wrong, a CI check that silently passed when it shouldn't — capture the corrected guidance **in the same PR that fixes the problem**:

- Short, self-contained rule → new file under `claude/rules/<topic>.md` (one sentence lede, then _why_ it bit us and _how to verify_).
- Contradicts something here or in `README.md` → fix that text inline too.

Rules that apply to project repos (e.g. raw-app authoring gotchas) ride along into every project repo via the `setup` skill. Rules that are meta-repo-internal (e.g. `reusable-workflow-meta-checkout.md`) stay here only — the skill's skip-list excludes them.

## Before requesting review

Wait for CI to come back **fully green**:

- `actionlint` — workflow YAML well-formed
- `shellcheck` — bash scripts clean
- `bash -n` — bash scripts parse

Yellow or red CI has shipped real production bugs in the predecessor of this repo — don't ask reviewers to look past warnings. Fix them, then request review.

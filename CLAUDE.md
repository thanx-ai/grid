# CLAUDE.md

Guidance for Claude Code working in this repo.

## Read first

At the start of every session, read every file under `claude/rules/`. Those capture specific gotchas that bit us in past sessions; the bar for adding one is "this surprised us once and would surprise us again." If a rule there contradicts something below, the rule wins (and fix this file in the same PR).

## What this repo is

`thanx-ai/grid` is a **meta-repo**, not a content repo. It ships two things:

1. **Reusable GitHub Actions workflows** (`.github/workflows/ci.yml`, `deploy.yml`) that team repos call via `uses: thanx-ai/grid/.github/workflows/deploy.yml@v0.1.0`. These workflows run `wmill sync push` against the Grid (`https://grid.thanx.com`).
2. **`thanx-grid` — a Claude Code plugin** (under `.claude-plugin/` and `skills/`) that bootstraps team repos: scaffolds `wmill.yaml`, the team's thin `.github/workflows/grid.yml`, and copies the conventions in `claude/rules/` into the team repo so future Claude sessions there pick them up.

**There is no `f/` content in this repo.** Team-shared Windmill code lives in each team's own GitHub repo (e.g. `thanx-ai/grid-examples`, which is the canonical reference). If you're tempted to add an `f/<dept>/...` file here, you're solving the wrong problem — it belongs in a team repo.

## Architecture

### The promotion model

Grid code lives at exactly one of two maturity tiers, both implemented in team repos (not here):

| Tier            | Namespace      | Where                                 |
| --------------- | -------------- | ------------------------------------- |
| 1. **Personal** | `u/<you>/`     | Your own GitHub repo                  |
| 2. **Team**     | `f/<dept>/`    | Your team's GitHub repo               |

The plugin's `/thanx-grid:grid-setup` skill asks which scope a new team repo targets and scaffolds accordingly. `/thanx-grid:promote` flips a repo from `u/<you>/` to `f/<dept>/` (renames items via the Windmill API, updates `wmill.yaml`, opens a PR against the team repo's default branch).

### Reusable workflows

Both reusable workflows follow the same pattern: checkout the caller, checkout `thanx-ai/grid` at the same ref into `.grid-meta/`, invoke shared scripts under `.grid-meta/scripts/`. See [`claude/rules/reusable-workflow-meta-checkout.md`](./claude/rules/reusable-workflow-meta-checkout.md) for why and how. **If you change `scripts/*.sh`, the change ships at the ref the caller pinned — `v0.1.0` callers get `v0.1.0` scripts, not whatever's on master.**

The workflows expect callers to follow the Grid conventions (folder-permissioned `f/` paths, raw_app layout, deploy-test annotation pattern). Those conventions are documented in `claude/rules/` and ride along into team repos via the plugin's `grid-setup` skill (Step 6).

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
  deploy.yml            # reusable: wmill sync push + deploy tests
  self-test.yml         # this repo's own CI (actionlint + shellcheck)
claude/rules/           # conventions Claude reads at session start
                        # (canonical source; plugin copies to team repos)
scripts/                # bash scripts invoked by reusable workflows
  lint-raw-apps.sh
  check-variable-references.sh
  run-deploy-tests.sh
skills/                 # plugin skills
  grid-setup/           # bootstrap a team repo
  new-app/              # scaffold a raw_app at the team repo's scope
  import-app/           # adopt an existing project as a raw_app
  promote/              # u/<you>/ → f/<dept>/ flip
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

# Test a workflow change end-to-end against grid-examples
# 1. Push the change to a branch on this repo
# 2. In grid-examples, temporarily change @v0.1.0 → @<your-branch>
# 3. Trigger CI in grid-examples and watch it run against your branch
```

## What goes where

When making changes, route by purpose:

| Change                                              | File(s) to touch                                       |
| --------------------------------------------------- | ------------------------------------------------------ |
| Bug in lint/check/test bash script                  | `scripts/<name>.sh` — patch bump                       |
| New optional workflow input                         | `.github/workflows/<name>.yml` — minor bump            |
| Breaking workflow change                            | `.github/workflows/<name>.yml` — major bump + announce |
| New plugin skill                                    | `skills/<name>/SKILL.md` + update `.claude-plugin/`    |
| Convention every team repo should know              | `claude/rules/<topic>.md` — picked up by `grid-setup`  |
| Internal rule (meta-repo authoring only)            | `claude/rules/<topic>.md` + skip-list in `grid-setup`  |

## Self-test CI

`self-test.yml` runs on every PR. It does **not** touch a live Windmill workspace — only actionlint + shellcheck. To catch semantic regressions in the reusable workflows, push a branch and run `grid-examples`'s workflow against it (see Common commands above).

## Conventions

- Plugin skills live at `skills/<name>/SKILL.md`. The filename is fixed; the directory name is the skill name.
- Scripts use `bash`, are `set -euo pipefail`, and pass shellcheck. No silent fallbacks — fail loud.
- Workflow YAML files use 2-space indent. Inputs and secrets are explicitly typed and described.
- "the Grid" in prose; `thanx-ai/grid` and `thanx-grid` are exact strings preserved as-is.
- Help / access questions: `#ai-help-desk` Slack channel. The GitHub team reviewer is `@eng-platform` (it exists as a GitHub team; the Slack channel of that name does not).

## Capture friction as rules

If you hit a non-obvious gotcha while working here — a misleading doc, a CLI flag whose behaviour surprises you, an API shape you got wrong, a CI check that silently passed when it shouldn't — capture the corrected guidance **in the same PR that fixes the problem**:

- Short, self-contained rule → new file under `claude/rules/<topic>.md` (one sentence lede, then _why_ it bit us and _how to verify_).
- Contradicts something here or in `README.md` → fix that text inline too.

Rules that apply to team repos (e.g. raw-app authoring gotchas) ride along into every team repo via the `grid-setup` skill. Rules that are meta-repo-internal (e.g. `reusable-workflow-meta-checkout.md`) stay here only — the skill's skip-list excludes them.

## Before requesting review

Wait for CI to come back **fully green**:
- `actionlint` — workflow YAML well-formed
- `shellcheck` — bash scripts clean
- `bash -n` — bash scripts parse

Yellow or red CI has shipped real production bugs in the predecessor of this repo — don't ask reviewers to look past warnings. Fix them, then request review.

# The Grid

Reusable GitHub Actions workflows + a Claude Code plugin (`thanx-grid`) for teams shipping to **Grid** — Thanx's self-hosted [Windmill](https://windmill.dev) workspace at `https://grid.thanx.com`.

This repo is **not** where Grid code lives. It's the shared infrastructure that every team repo pulls in to deploy to the Grid. Team-shared dashboards, scripts, and flows live in each team's own GitHub repo (see [`thanx-ai/grid-examples`](https://github.com/thanx-ai/grid-examples) for the canonical reference).

## What's here

### 1. Reusable GitHub Actions workflows

Two workflows under `.github/workflows/` that team repos call via `uses:` from their own `.github/workflows/grid.yml`:

- **`ci.yml`** — lints every `.raw_app/`, validates that every literal `wmill.getVariable("f/...")` reference resolves in the prod workspace.
- **`deploy.yml`** — runs `wmill sync push --yes` against the Grid, then executes deploy tests.

### 2. The `thanx-grid` Claude Code plugin

Under `.claude-plugin/` and `skills/`. Provides:

- **`/thanx-grid:grid-setup`** — bootstrap a team repo (scaffolds `wmill.yaml`, `.github/workflows/grid.yml`, copies Grid conventions into `claude/rules/`).
- **`/thanx-grid:new-app`** — scaffold a Windmill raw_app at the team repo's configured scope.
- **`/thanx-grid:import-app`** — adopt an existing GitHub project or HTML dashboard as a raw_app.
- **`/thanx-grid:promote`** — flip a repo from `u/<you>/` mode to `f/<dept>/` mode (rename items via the Windmill API, update YAML, open a PR).

## Quickstart for team repos

Create a new repo, then in a Claude Code session:

```bash
gh repo create thanx-ai/<your-team>-tools --private
cd <your-team>-tools
claude
# then:
/thanx-grid:grid-setup
```

`grid-setup` will:

1. Ask whether the repo deploys to `u/<your-username>/` (personal) or `f/<dept>/` (team-shared).
2. Scaffold `wmill.yaml`, `.github/workflows/grid.yml`, `folder.meta.yaml` (if team-shared), and copy the Grid conventions into `claude/rules/`.
3. Walk you through minting a Windmill deploy token (`grid.thanx.com` → User → Account Settings → Tokens → New Token) and storing it as the `WINDMILL_DEPLOY_TOKEN` repo secret.

The resulting `.github/workflows/grid.yml` looks like:

```yaml
name: Grid

on:
  push:
    branches: [master]
  pull_request:

jobs:
  ci:
    uses: thanx-ai/grid/.github/workflows/ci.yml@v0.1.0
    secrets:
      WMILL_READ_TOKEN: ${{ secrets.WMILL_READ_TOKEN }}

  deploy:
    if: github.ref == 'refs/heads/master'
    needs: ci
    uses: thanx-ai/grid/.github/workflows/deploy.yml@v0.1.0
    with:
      includes: "f/<your-dept>/**"
    secrets:
      WINDMILL_DEPLOY_TOKEN: ${{ secrets.WINDMILL_DEPLOY_TOKEN }}
```

That's it — merges to `master` deploy automatically.

## Adoption is opt-in and additive

Teams already deploying via their own pipelines (e.g. `thanx-ai/merchant-health-dashboard`, `thanx-ai/thanx-strategy-workbook`) keep their existing workflows. The plugin adds files; it doesn't replace existing CI. Adopt the reusable workflows when you want to retire your own deploy plumbing — never as a forced migration.

## Two namespaces

Every team repo deploys to exactly one of:

- **`u/<your-username>/`** — personal sandbox. Private to one user. Default for prototypes.
- **`f/<dept>/`** — team-shared. Workspace-wide read+run; dept-group write via SCIM. For shared dashboards and scripts.

When a prototype matures, `/thanx-grid:promote` flips the repo from `u/` to `f/<dept>/`.

## Versioning

Pre-`v1` while the API is stabilizing. Pin to `@v0.1.0` (or `@v0` for rolling minors/patches within `0.x`).

- **Patch** (`v0.1.0` → `v0.1.1`) — bug fixes, no input/output changes.
- **Minor** (`v0.1.0` → `v0.2.0`) — new optional inputs / skill steps; backward-compatible.
- **Major** (`v0.x` → `v1.0`) — breaking changes; announced via the `#ai-help-desk` Slack channel.

## Help

- Questions, bugs, access issues — `#ai-help-desk` on Slack.
- Convention questions — read `claude/rules/` first; they capture every gotcha that's bitten us in the past.
- PR review — request `@eng-platform`.

## Developing this repo

See [`DEVELOPING.md`](./DEVELOPING.md) for plugin and workflow development.

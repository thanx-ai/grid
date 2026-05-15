# The Grid

Reusable GitHub Actions workflows + a Claude Code plugin (`thanx-grid`) for shipping to **Grid** — Thanx's self-hosted [Windmill](https://windmill.dev) workspace at `https://grid.thanx.com`.

> **Public repository.** `thanx-ai/grid` ships as a public repo so individual project repos (which may themselves be private) can pull it in via `uses: thanx-ai/grid/...@<ref>` without needing GitHub App tokens for cross-repo workflow access. **Never** commit anything sensitive here: no tokens, no internal hostnames beyond `grid.thanx.com` / `grid-origin.thanx.com`, no real customer data, no `.env` files. The `.gitignore` and CI guards catch the obvious foot-guns; the rest is on us.

This repo is **not** where Grid code lives. It's the shared infrastructure that individual project repos pull in to deploy to the Grid. Apps, scripts, and flows live in each person's own GitHub repo (see [`thanx-ai/grid-examples`](https://github.com/thanx-ai/grid-examples) for the canonical reference).

## What's here

### 1. Reusable GitHub Actions workflows

Two workflows under `.github/workflows/` that project repos call via `uses:` from their own `.github/workflows/grid.yml`:

- **`ci.yml`** — lints every `.raw_app/`, validates that every literal `wmill.getVariable("f/...")` reference resolves in the prod workspace.
- **`deploy.yml`** — pushes each changed item individually with `wmill <type> push` (`app`, `script`, `flow`, `resource`, `variable`, `schedule`, `trigger`, `folder`). Each push is an upsert: it creates or updates the remote item but **never deletes** anything outside the changeset. Then executes deploy tests. See [`claude/rules/per-item-push-not-sync.md`](./claude/rules/per-item-push-not-sync.md) for why this isn't `wmill sync push`.

### 2. The `thanx-grid` Claude Code plugin

Under `.claude-plugin/` and `skills/`. Provides:

- **`/thanx-grid:grid-setup`** — bootstrap a project repo (scaffolds `wmill.yaml`, `.github/workflows/grid.yml`, copies Grid conventions into `claude/rules/`).
- **`/thanx-grid:new-app`** — scaffold a Windmill raw_app, picking per-app whether it lands in `f/company/` or `f/<dept>/`.
- **`/thanx-grid:import-app`** — adopt an existing GitHub project or HTML dashboard as a raw_app.

## Quickstart

Each person owns their own project repo. Create one, then in a Claude Code session:

```bash
gh repo create thanx-ai/<your-username>-grid --private
cd <your-username>-grid
claude
# then:
/thanx-grid:grid-setup
```

`grid-setup` will:

1. Scaffold `wmill.yaml`, `.github/workflows/grid.yml`, and copy the Grid conventions into `claude/rules/`.
2. Walk you through minting a Windmill deploy token (`grid.thanx.com` → User → Account Settings → Tokens → New Token) and storing it as the `WINDMILL_DEPLOY_TOKEN` repo secret.

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
    # No `with: includes:` input — deploy.yml infers the set from the commit
    # range and pushes each item with `wmill <type> push`. See
    # claude/rules/per-item-push-not-sync.md.
    uses: thanx-ai/grid/.github/workflows/deploy.yml@v0.1.0
    secrets:
      WINDMILL_DEPLOY_TOKEN: ${{ secrets.WINDMILL_DEPLOY_TOKEN }}
```

That's it — merges to `master` deploy automatically.

## Adoption is opt-in and additive

Projects already deploying via their own pipelines (e.g. `thanx-ai/merchant-health-dashboard`, `thanx-ai/thanx-strategy-workbook`) keep their existing workflows. The plugin adds files; it doesn't replace existing CI. Adopt the reusable workflows when you want to retire your own deploy plumbing — never as a forced migration.

## Where apps live

Every app you ship to the Grid lands in one of two folders, picked **per-app** based on use-case (not per-repo):

- **`f/company/`** — workspace-wide. Use when the app is genuinely cross-functional and everyone at Thanx should be able to find and run it.
- **`f/<dept>/`** — department-scoped (`f/eng/`, `f/cs/`, `f/sales/`, …). Workspace-wide read+run; dept-group write via SCIM. Use when the app is owned by one team, even if other teams might occasionally read it.

Both folders are readable workspace-wide; the distinction is ownership and write access. Default to `f/<dept>/`; reach for `f/company/` only when an app truly belongs to no single department.

A single project repo can ship apps to both folders — `/thanx-grid:new-app` asks each time.

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

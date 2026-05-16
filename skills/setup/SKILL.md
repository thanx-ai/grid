---
name: setup
description: ONE-TIME bootstrap for a new project repo that will deploy to Thanx Grid. Wires up `wmill.yaml`, a `.github/workflows/grid.yml` that calls the reusable workflows in `thanx-ai/grid`, mints the deploy token, and copies the Grid conventions into `claude/rules/`. **This is the repo-level setup — not for creating individual apps.** Use `/grid:create` to add a new raw_app, or `/grid:import` to bring in an existing project. Use this skill when a user says "set up grid", "bootstrap grid in this repo", "configure wmill for grid", or "add grid deploy to this repo".
---

# setup

Bootstraps an **individual project repo** for safe Windmill development against the Grid (`https://grid.thanx.com`). Runs once per repo. The output is **additive** — it adds files to the caller's repo, never replaces existing CI or build tooling.

## What this skill does vs. `/grid:create` and `/grid:import`

- **`/grid:setup` (this skill)** — one-time per repo. Wires up `wmill.yaml`, the GH Actions caller, the deploy token, and the bundled rule docs. Run once after `git init` (or when adopting Grid in an existing repo).
- **`/grid:create`** — many times per repo. Scaffolds one new raw_app, asking each time whether it lives under `f/company/` or `f/<dept>/`.
- **`/grid:import`** — adopts an existing GitHub project / local dir / standalone HTML file as a raw_app. Same per-app scope question as `/grid:create`.

## When NOT to use

- Already inside `thanx-ai/grid` or `thanx-ai/grid-examples` itself — those repos are the meta-repo and reference template respectively; they don't need bootstrapping.
- `wmill.yaml` already exists and `.github/workflows/grid.yml` is already calling `thanx-ai/grid` workflows — the repo is already set up. Use `/grid:create` or `/grid:import` for per-app work instead.

## Step 1: Confirm context

Run these in parallel:

```bash
test -f wmill.yaml && echo "wmill.yaml exists" || echo "no wmill.yaml"
test -f .github/workflows/grid.yml && echo "grid.yml exists" || echo "no grid.yml"
git remote get-url origin 2>/dev/null || echo "no remote"
git config user.email
which gh && gh auth status 2>&1 | head -3 || echo "gh missing or unauthed"
```

If `thanx-ai/grid` or `thanx-ai/grid-examples` is the origin, refuse: this skill is for downstream project repos.

If `wmill.yaml` already exists, read it. If its `includes:` already covers `f/**`, the repo is set up — tell the user to run `/grid:create` or `/grid:import` instead. If it has a narrower scope from a pre-rename state (e.g. `u/<username>/**` or `f/<dept>/**`), ask whether to widen it to `f/**` and re-scaffold the workflow caller.

## Step 2: Scaffold `wmill.yaml`

Write `wmill.yaml` with a broad `f/**` scope. The Grid deploy workflow doesn't rely on `includes:` to limit the deploy blast radius — it uses per-item `wmill <type> push` (see [`claude/rules/per-item-push-not-sync.md`](../../claude/rules/per-item-push-not-sync.md)). The `includes:` here is just for local `wmill sync pull` operations.

```yaml
defaultTs: bun
includes:
  - f/**
excludes:
  - "**/node_modules/**"
  - "**/dist/**"
codebases: []
skipVariables: false
skipResources: false
skipResourceTypes: true
skipSecrets: true
includeSchedules: true
includeTriggers: true
includeUsers: false
includeGroups: false
includeSettings: false
includeKey: false
```

`skipResourceTypes: true` — project repos don't own resource type definitions; those live in the workspace and are managed centrally.

## Step 3: Scaffold `.github/workflows/grid.yml`

This is the thin caller that wires the project repo into `thanx-ai/grid`'s reusable workflows.

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
    # No `with: includes:` input — the reusable deploy.yml infers the
    # changed set from the commit range and pushes each item via
    # `wmill <type> push`. See claude/rules/per-item-push-not-sync.md.
    uses: thanx-ai/grid/.github/workflows/deploy.yml@v0.1.0
    secrets:
      WINDMILL_DEPLOY_TOKEN: ${{ secrets.WINDMILL_DEPLOY_TOKEN }}
```

Note: the default branch may be `main` instead of `master`. Check `git symbolic-ref refs/remotes/origin/HEAD` and substitute accordingly.

**No `folder.meta.yaml` is scaffolded here.** Folder ACLs are written per-item by `/grid:create` and `/grid:import` the first time an app lands in a given folder — so a project repo only ever scaffolds the folders it actually uses.

## Step 4: Copy bundled rules into `claude/rules/`

The plugin ships with the Grid conventions as rule files (gotchas that bit us in past sessions). Copy them so the project repo's Claude sessions pick them up.

Locate the plugin's `claude/rules/` directory. Try in order:

1. `$HOME/.claude/plugins/grid/claude/rules/` — default Claude Code plugin install path
2. Search via `find $HOME/.claude/plugins -type d -name rules -path '*grid*' 2>/dev/null`
3. If the user has a local clone of `thanx-ai/grid` (look at common dev paths: `$HOME/code/grid`, `$HOME/src/thanx-ai/grid`, `$HOME/dev/grid`), use its `claude/rules/`

If none resolve, ask the user where their `grid` plugin is installed and use that. Store the resolved path as `$PLUGIN_RULES`.

Then copy each rule file (skip `README.md`, skip files whose name suggests they're meta-repo-internal — e.g. `reusable-workflow-meta-checkout.md`):

```bash
mkdir -p claude/rules
for rule in "$PLUGIN_RULES"/*.md; do
  base=$(basename "$rule")
  case "$base" in
    README.md|reusable-workflow-meta-checkout.md|per-item-push-not-sync.md) continue ;;
  esac
  # Prepend a managed-header. Idempotent: skip if already present.
  if ! grep -q "Managed by grid plugin" "$rule"; then
    printf '<!-- Managed by grid plugin. Re-run /grid:setup to refresh. -->\n\n' > "claude/rules/$base"
    cat "$rule" >> "claude/rules/$base"
  else
    cp "$rule" "claude/rules/$base"
  fi
done
```

`per-item-push-not-sync.md` stays meta-repo-internal — project repos consume the deploy behavior but don't need to author against the CLI surface table.

## Step 5: Append a CLAUDE.md note (or create one)

Append to `CLAUDE.md` (or create if missing):

```markdown
## Grid conventions

This repo deploys to Thanx Grid via the reusable workflows in [`thanx-ai/grid`](https://github.com/thanx-ai/grid). At the start of every session, read every file under `claude/rules/` — those capture gotchas that bit us in past sessions and are managed by the `grid` Claude Code plugin.

Each app, script, or flow picks its own scope folder (`f/company/` or `f/<dept>/`) at scaffold time via `/grid:create` or `/grid:import`. Edits in the repo are the source of truth; merges to the default branch auto-deploy via `.github/workflows/grid.yml`.
```

## Step 6: Walk through token minting + secret storage

The deploy workflow needs a Windmill API token stored as a repo secret. **Do not** mint or store it for the user — walk them through it.

> 1. Mint a deploy token:
>    - Go to https://grid.thanx.com
>    - Click your avatar (top-right) → **Account Settings** → **Tokens** → **New Token**
>    - Label it `<repo-name> deploy` (e.g. `grid-examples deploy`)
>    - Leave scopes empty (unscoped) for the simplest setup, or grant: `folders:write, scripts:write, flows:write, apps:write, raw_apps:write, resources:write, variables:write, schedules:write, triggers:write, users:read`
>    - Copy the token (you'll see it once)
> 2. Add it as a repo secret:
>    ```bash
>    gh secret set WINDMILL_DEPLOY_TOKEN
>    # paste the token at the prompt
>    ```
> 3. (Optional) Mint a read-only token for the variable-reference CI check:
>    - Same UI path. Label `<repo-name> read`. Scopes: `variables:read, resources:read`.
>    - `gh secret set WMILL_READ_TOKEN`

Without `WMILL_READ_TOKEN` the variable-reference check passes with a loud warning, so it's optional but recommended.

## Step 7: Verify the workspace auth works

Walk the user through confirming their token actually works against the Grid before they push:

> Quick sanity check — these don't deploy anything, they just confirm the token is good:
>
> ```bash
> wmill workspace add thanx thanx https://grid-origin.thanx.com
> # (interactive — paste the deploy token you just minted)
>
> wmill app list --workspace thanx | head
> # Should print a few existing apps. If it errors with 401/403, the
> # token doesn't have read access — re-mint with broader scopes.
> ```
>
> `wmill sync push` is deliberately not used here. The deploy workflow does per-item push specifically to avoid `sync push`'s diff-and-delete behavior — see `claude/rules/sync-push-deletes.md`. For a manual one-off push, use `wmill app push <path>`, `wmill script push <path>`, etc.

## Step 8: Tell the user what's next

> Done. From here:
>
> - Build a raw app: `/grid:create`
> - Import an existing project: `/grid:import`
>
> The first push to `master` (or `main`) triggers the deploy workflow. It only pushes items changed in the commit range, one at a time — see `claude/rules/per-item-push-not-sync.md`. Watch the run at `https://github.com/<owner>/<repo>/actions`.

## Idempotency

This skill should be safe to re-run on a repo that's already been bootstrapped — it refreshes the bundled rules, leaves user content untouched, and asks before overwriting `wmill.yaml` or `.github/workflows/grid.yml`. If `claude/rules/<name>.md` already exists, compare the content against the plugin's source and re-copy only if the managed-header is missing or the content has drifted from the canonical version.

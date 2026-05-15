---
name: grid-setup
description: First-time setup for a repo that deploys to Thanx Grid. Wires up `wmill.yaml`, a `.github/workflows/grid.yml` calling the reusable workflows from `thanx-ai/grid`, and copies the Grid conventions into `claude/rules/`. Use when a user says "set up grid", "bootstrap grid in this repo", "configure wmill for grid", or "add grid deploy to this repo".
---

# grid-setup

Bootstraps a team repo for safe Windmill development against the Grid (`https://grid.thanx.com`). The output is **additive** — it adds files to the caller's repo, never replaces existing CI or build tooling.

## Two scopes to choose between

A team repo deploys to exactly one of:

- **`u/<your-username>/`** — personal sandbox, private to one user. Pick this for prototypes, exploration, or one-off scripts. No team-shared access; you're the only writer and reader.
- **`f/<dept>/`** — team-shared. Everyone in the workspace can read and run; only your department's SCIM group can write. Pick this when other people need to view dashboards or run your scripts.

Ask the user which one, then follow the matching branch.

## When NOT to use

- Already inside `thanx-ai/grid` or `thanx-ai/grid-examples` itself — those repos are the meta-repo and reference template respectively; they don't need bootstrapping.
- An existing `wmill.yaml` is present and scoped differently. **Read it first.** Surface the existing scope to the user, ask whether to keep it or migrate (and offer `/thanx-grid:promote` for `u/` → `f/`).

## Step 1: Confirm context

Run these in parallel:

```bash
test -f wmill.yaml && echo "wmill.yaml exists" || echo "no wmill.yaml"
test -f .github/workflows/grid.yml && echo "grid.yml exists" || echo "no grid.yml"
git remote get-url origin 2>/dev/null || echo "no remote"
git config user.email
which gh && gh auth status 2>&1 | head -3 || echo "gh missing or unauthed"
```

If `thanx-ai/grid` or `thanx-ai/grid-examples` is the origin, refuse: this skill is for downstream repos.

If `wmill.yaml` exists, read it. Show the scope (`includes:` field) and ask whether to keep, override, or run `/thanx-grid:promote` instead.

## Step 2: Ask which scope

```text
Where should this repo deploy to?
  1. u/<your-username>/ — personal sandbox (default for prototypes)
  2. f/<dept>/ — team-shared (everyone in the workspace can read+run; your dept writes)
```

If `u/`, ask for the Windmill username (validate: lowercase, alnum + underscore). Store as `$WMILL_USER`.

If `f/<dept>/`, ask which department. The valid options match the Windmill folder names — common ones: `engineering`, `product`, `design`, `success`, `operations`, `onboarding`, `support`, `finance`, `exec`, `marketing`, `sales`, `agents`, `scheduled`. Store as `$WMILL_DEPT`.

**Reject `f/shared/`** — that folder is admin-only and not appropriate for a team repo to claim ownership of.

## Step 3: Scaffold `wmill.yaml`

For `u/` mode:

```yaml
defaultTs: bun
includes:
  - u/<WMILL_USER>/**
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

For `f/<dept>/` mode, replace the `includes:` block with:

```yaml
includes:
  - f/<WMILL_DEPT>/**
```

`skipResourceTypes: true` — downstream repos don't own resource type definitions.

## Step 4: Scaffold `.github/workflows/grid.yml`

This is the thin caller that wires the team repo into `thanx-ai/grid`'s reusable workflows.

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
      includes: "<INCLUDES_PATTERN>"
    secrets:
      WINDMILL_DEPLOY_TOKEN: ${{ secrets.WINDMILL_DEPLOY_TOKEN }}
```

Substitute `<INCLUDES_PATTERN>`:
- `u/` mode → `u/<WMILL_USER>/**`
- `f/<dept>/` mode → `f/<WMILL_DEPT>/**`

Note: the default branch may be `main` instead of `master`. Check `git symbolic-ref refs/remotes/origin/HEAD` and substitute accordingly.

## Step 5: Scaffold `folder.meta.yaml` (`f/<dept>/` mode only)

For `u/` mode, skip this step — personal namespaces don't have folder.meta.yaml.

For `f/<dept>/`, write `f/<WMILL_DEPT>/folder.meta.yaml`:

```yaml
summary: <Dept> team-shared scripts, flows, and apps
display_name: <WMILL_DEPT>
extra_perms:
  admin@windmill.dev: true
  g/all: false
  g/<WMILL_DEPT>: true
owners:
  - admin@windmill.dev
```

`g/all: false` is workspace-wide read+run (the value is the *write* bit). `g/<WMILL_DEPT>: true` grants write to the dept's SCIM group.

**Note about the SCIM group**: if `g/<WMILL_DEPT>` doesn't exist in Google Workspace, the dept's members won't have write access. The YAML grant is a no-op until the SCIM group is provisioned. Request new groups in `#ai-help-desk`.

**Special case — `f/success/`**: the Google Workspace SCIM group is `customer_success` (predates the folder rename). Use `g/customer_success: true` for the success folder until the SCIM rename ships.

## Step 6: Copy bundled rules into `claude/rules/`

The plugin ships with the Grid conventions as rule files (gotchas that bit us in past sessions). Copy them so the team repo's Claude sessions pick them up.

Locate the plugin's `claude/rules/` directory. Try in order:

1. `$HOME/.claude/plugins/thanx-grid/claude/rules/` — default Claude Code plugin install path
2. Search via `find $HOME/.claude/plugins -type d -name rules -path '*thanx-grid*' 2>/dev/null`
3. If the user has a local clone of `thanx-ai/grid` (look at common dev paths: `$HOME/code/grid`, `$HOME/src/thanx-ai/grid`, `$HOME/dev/grid`), use its `claude/rules/`

If none resolve, ask the user where their `thanx-grid` plugin is installed and use that. Store the resolved path as `$PLUGIN_RULES`.

Then copy each rule file (skip `README.md`, skip files whose name suggests they're meta-repo-internal — e.g. `reusable-workflow-meta-checkout.md`):

```bash
mkdir -p claude/rules
for rule in "$PLUGIN_RULES"/*.md; do
  base=$(basename "$rule")
  case "$base" in
    README.md|reusable-workflow-meta-checkout.md) continue ;;
  esac
  # Prepend a managed-header. Idempotent: skip if already present.
  if ! grep -q "Managed by thanx-grid plugin" "$rule"; then
    printf '<!-- Managed by thanx-grid plugin. Re-run /thanx-grid:grid-setup to refresh. -->\n\n' > "claude/rules/$base"
    cat "$rule" >> "claude/rules/$base"
  else
    cp "$rule" "claude/rules/$base"
  fi
done
```

## Step 7: Append a CLAUDE.md note (or create one)

Append to `CLAUDE.md` (or create if missing):

```markdown
## Grid conventions

This repo deploys to Thanx Grid via the reusable workflows in [`thanx-ai/grid`](https://github.com/thanx-ai/grid). At the start of every session, read every file under `claude/rules/` — those capture gotchas that bit us in past sessions and are managed by the `thanx-grid` Claude Code plugin.

Deploys target `<INCLUDES_PATTERN>` in the Windmill workspace. Edits in the repo are the source of truth; merges to the default branch auto-deploy via `.github/workflows/grid.yml`.
```

## Step 8: Walk through token minting + secret storage

The deploy workflow needs a Windmill API token stored as a repo secret. **Do not** mint or store it for the user — walk them through it.

> 1. Mint a deploy token:
>    - Go to https://grid.thanx.com
>    - Click your avatar (top-right) → **Account Settings** → **Tokens** → **New Token**
>    - Label it `<repo-name> deploy` (e.g. `grid-examples deploy`)
>    - Leave scopes empty (unscoped) for the simplest setup, or grant: `folders:write, scripts:write, flows:write, apps:write, raw_apps:write, resources:write, variables:write, schedules:write, users:read`
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

## Step 9: Verify locally before pushing

Walk the user through a dry-run:

> Before pushing, confirm the scope. **Mint a local wmill auth first if you haven't**:
>
> ```bash
> wmill workspace add thanx thanx https://grid-origin.thanx.com
> # (interactive — sign in with a token; use grid-origin, not grid.thanx.com,
> #  since grid.thanx.com is proxied through Cloudflare)
> ```
>
> Then dry-run the deploy:
>
> ```bash
> wmill sync push --workspace thanx --base-url https://grid-origin.thanx.com
> # (no --yes — this prompts. Inspect the diff and Ctrl-C if anything
> #  outside <INCLUDES_PATTERN> appears.)
> ```
>
> The diff should only show changes inside your scope. If anything outside appears, the `includes:` in `wmill.yaml` is misconfigured.

## Step 10: Tell the user what's next

> Done. From here:
>
> - Build a raw app: `/thanx-grid:new-app`
> - Import an existing project: `/thanx-grid:import-app`
> - Promote `u/` → `f/<dept>/` when ready to share: `/thanx-grid:promote`
>
> The first push to `master` (or `main`) triggers the deploy workflow. Watch it at `https://github.com/<owner>/<repo>/actions`.

## Idempotency

This skill should be safe to re-run on a repo that's already been bootstrapped — it refreshes the bundled rules, leaves user content untouched, and asks before overwriting `wmill.yaml` or `.github/workflows/grid.yml`. If `claude/rules/<name>.md` already exists, compare the content against the plugin's source and re-copy only if the managed-header is missing or the content has drifted from the canonical version.

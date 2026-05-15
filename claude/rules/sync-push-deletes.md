# `wmill sync push` is destructive within its scope

**Rule.** `wmill sync push` is a diff-and-apply against the remote workspace, scoped by the union of `wmill.yaml` `includes:` / `excludes:` AND any `--includes` patterns on the CLI invocation (comma-separated; see [`wmill-sync-includes-flag.md`](./wmill-sync-includes-flag.md)). Anything that exists on the **remote** but not in the **local** source within that scope is **deleted**. It is not additive-only.

The Windmill docs are explicit: *"sync... will override any item that is within the scope: remove those that are in the target and not in the source, and it will create new items that are in source but not in target."*

## Why this matters here

`wmill.yaml` declares the broad scope used by local commands:

```yaml
includes:
  - f/**
  - resources/**
```

The deploy workflow (`.github/workflows/deploy.yml`) **narrows** that scope further with an explicit comma-separated `--includes` pattern so any folder NOT in the list is invisible to deploy:

```text
--includes 'f/shared/**,f/agents/**,f/scheduled/**,f/engineering/**,f/product/**,f/design/**,f/success/**,f/operations/**,f/onboarding/**,f/support/**,f/finance/**,f/exec/**,f/marketing/**,f/sales/**,resources/**'
```

Three practical consequences:

1. **Any `f/<team>/<name>` in the workspace that isn't in this repo gets deleted on the next master deploy** — *if* that team folder is in the `--includes` pattern. If a teammate hand-builds a flow in the Windmill UI under `f/success/foo` and nobody runs `wmill sync pull` + commits before the next merge, the flow disappears.

2. **Adding a new top-level `f/<team>/` folder requires updating `deploy.yml`** — without an `f/<team>/**` entry in `--includes`, items in that folder on the workspace are never deleted by deploy, but new content the repo adds to that folder is also never deployed. Either condition is a foot-gun; keep `deploy.yml` and `ls f/` in lock-step.

3. **`u/<username>/**` is outside both scopes and never touched.** That's why `u/` is the safe namespace for prototyping (and why the `thanx-grid` plugin defaults its scaffolders there for non-`thanx-ai/grid` repos).

## How to verify before pushing

Always dry-run if you didn't author every change in the scope yourself:

```bash
# Drop --yes to see the diff before applying. Read it.
wmill sync push --workspace thanx --base-url https://grid-origin.thanx.com
```

If the diff lists **deletions** for paths you didn't intend to remove, stop. Run `wmill sync pull` on a branch, commit the missing files, then retry. Once `--yes` is on the command line, the diff is silently applied.

## Per-team repo ownership (future)

The explicit per-folder `--includes` scoping in `deploy.yml` is the prerequisite for letting another repo own its own `f/<team>/`. To wire that up safely:

1. Remove that `f/<team>/**` entry from the `--includes` argument in `deploy.yml` here so this repo's deploy stops touching that folder.
2. Set up the other repo with its own deploy workflow scoped to **just** that folder.
3. Until both halves are in place, **only this repo writes to `f/**` paths**; downstream/private repos prototype under `u/<username>/**` (safe) or a workspace fork (also safe).

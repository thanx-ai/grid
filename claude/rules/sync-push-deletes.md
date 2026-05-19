# `wmill sync push` is destructive within its scope

> **The reusable `deploy.yml` does not use `wmill sync push`** — it pushes each item individually with `wmill <type> push`, exactly to avoid the hazard described below. This rule remains here because (a) `sync push` is still useful for local dry-runs and (b) if anyone is ever tempted to add `sync push` back to a workflow, the gotchas need to be discoverable in the same place that documents the CLI surface.

**Rule.** `wmill sync push` is a diff-and-apply against the remote workspace, scoped by the union of `wmill.yaml` `includes:` / `excludes:` AND any `--includes` patterns on the CLI invocation (comma-separated). Anything that exists on the **remote** but not in the **local** source within that scope is **deleted**. It is not additive-only.

The Windmill docs are explicit: _"sync... will override any item that is within the scope: remove those that are in the target and not in the source, and it will create new items that are in source but not in target."_

## Historical context: why a predecessor repo used `sync push --includes`

A predecessor repo to `thanx-ai/grid` ran `wmill sync push --yes` from its `deploy.yml` with a hand-maintained comma-separated `--includes` list of `f/<team>/**` patterns. That worked because exactly one repo owned `f/**` — the deploy could safely "if it's not in the source, delete it from the remote" within those folders.

That model broke as soon as multiple project repos started writing into the same `f/<dept>/` folder. Any one repo's deploy would silently delete every item another repo owned in that folder. The fix is the **per-item push** model — which is why the current `deploy.yml` doesn't use `sync push` at all and doesn't take an `--includes` input.

Leaving this rule in place because (a) `sync push --dry-run` is still useful locally for diffing what the workspace currently has against what you've changed, and (b) if anyone is tempted to reintroduce `sync push` to a workflow, the trap needs to be documented somewhere obvious — here.

## How to verify before pushing

Always dry-run if you didn't author every change in the scope yourself:

```bash
# Drop --yes to see the diff before applying. Read it.
wmill sync push --workspace thanx --base-url https://grid-origin.thanx.com
```

If the diff lists **deletions** for paths you didn't intend to remove, stop. Run `wmill sync pull` on a branch, commit the missing files, then retry. Once `--yes` is on the command line, the diff is silently applied.

## Multiple project repos writing the same folder

Multiple individual project repos commonly write into the same `f/company/` or `f/<dept>/` folder on the Grid. With `wmill sync push` and folder-scoped `--includes`, any one of those repos' deploys would silently delete every item another repo owns in that folder. That's why the deploy workflow doesn't use `sync push` at all and pushes each changed item individually instead.

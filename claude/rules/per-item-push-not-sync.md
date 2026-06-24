# Deploy uses per-item `wmill <type> push`, never `wmill sync push`

**Rule.** The reusable `deploy.yml` pushes each changed item individually with `wmill <type> push <args>`. It does **not** run `wmill sync push`. The choice is structural, not stylistic — every item type's push is documented as "This overrides any remote versions" (an upsert), while `sync push` is documented as a diff-and-apply that **deletes anything in scope that exists on the remote but not in the local source** ([see `sync-push-deletes.md`](./sync-push-deletes.md)).

## Why this matters here

Every person has their own project repo. Multiple project repos write into the same `f/company/` and `f/<dept>/` folders on the Grid. If any one of them ran `wmill sync push --includes "f/<dept>/**"`, the deploy would delete every item under `f/<dept>/` that wasn't in _that one repo_ — silently wiping a teammate's work on the next merge.

Per-item push removes the entire class of bug: a deploy can only create-or-update items the repo explicitly knows about. The cost is that **deletions don't propagate** — removing `f/eng/foo.raw_app/` from a project repo leaves it live on the Grid until someone removes it via the UI or `wmill app delete`. That's the deliberate trade.

## The CLI surface (verified against `windmill-cli@1.700.1`)

Every item type has a `push` subcommand and every one says "This overrides any remote versions":

| Type     | Command                                         | Local-source shape                                                     |
| -------- | ----------------------------------------------- | ---------------------------------------------------------------------- |
| App      | `wmill app push [file_path] [remote_path]`      | `.raw_app/` directory (args optional — infers from cwd + `wmill.yaml`) |
| Script   | `wmill script push <path>`                      | `.script.ts` / `.script.py` / `.script.js` / `.script.sh`              |
| Flow     | `wmill flow push <file_path> <remote_path>`     | `.flow/` directory with `flow.yaml`                                    |
| Resource | `wmill resource push <file_path> <remote_path>` | `.resource.yaml`                                                       |
| Variable | `wmill variable push <file_path> <remote_path>` | `.variable.yaml`                                                       |
| Schedule | `wmill schedule push <file_path> <remote_path>` | `.schedule.yaml`                                                       |
| Trigger  | `wmill trigger push <file_path> <remote_path>`  | `.trigger.yaml`                                                        |
| Folder   | `wmill folder push <name>`                      | `folder.meta.yaml` under `f/<name>/`                                   |

Verify when bumping the CLI version: `wmill <type> --help | grep -A1 push` should still say "overrides any remote versions" for each.

## How `deploy.yml` decides what to push

The workflow pushes the **full `f/**` inventory** every deploy (see [`deploy-full-inventory.md`](./deploy-full-inventory.md)): `scripts/list-grid-items.sh` runs `git ls-files -- 'f/**'` through the shared classifier (`scripts/classify-grid-paths.sh`), which classifies each path by suffix into `<type> <local_path> [<remote_path>]` records, and `scripts/deploy-grid-items.sh` pipes those into `scripts/push-grid-items.sh`, which loops:

```bash
for entry in "${RECORDS[@]}"; do
  read -r type local remote <<<"$entry"
  wmill "$type" push "$local" "$remote" \
    --workspace thanx --base-url "$WMILL_BASE_URL" --token "$WINDMILL_DEPLOY_TOKEN"
done
```

`wmill push` content-hashes each item and no-ops the unchanged ones. If the repo has no `f/**` items the workflow logs and exits 0 — but **never** fall back to a workspace-wide sync as a "default deploy". That would defeat the whole rule.

### The push order is dependency-ranked, not lexical

`classify-grid-paths.sh` emits its records in `wmill push` **dependency order**, and `push-grid-items.sh` pushes them in that order without re-sorting. The order has three tiers:

1. `folder` — a folder must exist before any item created inside it.
2. `script`, `app`, `flow`, `resource`, `variable` — runnables and standalone data.
3. `schedule`, `trigger` — these reference a runnable by path, and `wmill schedule push` **validates the target exists** (`Not found: script not found at name <path>` otherwise), so they must come **after** tier 2.

This matters because a repo routinely holds a script and its schedule (or a folder and its contents) together — the tooling must push them in the right order. A plain `sort -u` orders records lexically by type (`app, flow, folder, resource, schedule, script, trigger, variable`), which pushes `schedule` *before* `script` (and *before* `variable`) and lands `folder` in the middle: the schedule push 404s on a runnable that doesn't exist yet and reds the whole deploy. The fix is a tier-ranked stable sort at the end of `classify-grid-paths.sh`; don't regress it back to a bare `sort -u`. It's covered by `scripts/test/list-grid-items-test.sh`.

## What about `wmill sync push` for local dev?

`wmill sync push --dry-run` (without `--yes`) is still useful for local diffing. The rule is specifically about the CI deploy step. If you need to bulk-sync from your laptop, you're doing it knowingly and the destructive scope is on you.

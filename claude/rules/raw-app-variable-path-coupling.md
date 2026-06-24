# Windmill workspace variables are folder-path-coupled — renaming an app's folder breaks every `getVariable("f/<old>/...")` silently

**Rule.** A workspace variable lives at a literal path like `f/eng/MY_API_TOKEN`. If you rename an app's scope folder (e.g. `f/engineering/` → `f/eng/`), every `wmill.getVariable("f/engineering/...")` / `getResource(...)` call keeps the **old** path string and breaks. Renaming the folder is three edits, not one:

1. Rewrite every path string in `wmill.ts` and every `backend/*.yaml` inline script (`f/<old>/...` → `f/<new>/...`).
2. Recreate the workspace variables at the new path in the **local** Windmill (so `wmill app dev` resolves them).
3. Recreate them at the new path in the **prod** workspace (grid.thanx.com) before the deploy.

The code rename alone leaves the runnables throwing `Variable not found at f/<old>/...` (or 401ing) — the variable still exists only at the old path, or doesn't exist yet at the new one.

## Why it's silent

There is no rename operation that moves a variable along with its folder. Variables are independent items keyed by their full path; moving an app directory in git doesn't touch them. `wmill app lint` doesn't resolve variable paths, and `scripts/check-variable-references.sh` only fails when a path exists in **neither** place — so if you create the new variable but miss a stray `f/<old>/...` string in one `backend/*.yaml`, that single runnable 404s alone while the rest work. See [`scaffold-getvariable-placeholders.md`](./scaffold-getvariable-placeholders.md) for the underlying "getVariable throws at runtime" failure mode.

It bit the Ergane control pane (Jun 2026) on the `f/engineering` → `f/ergane` folder rename.

## How to verify

- `grep -rn 'f/<old>/' <SCOPE>/<name>.raw_app/` after a rename — must return nothing.
- For each `getVariable`/`getResource` literal, confirm the path exists in both local and prod: `wmill variable list --workspace thanx | grep <SCOPE>/`. The CI check covers prod paths in `*.ts`/`*.py` source, but **not** paths buried in `inlineScript.content` YAML — verify those by hand (the same blind spot as [`raw-app-windmill-client-import.md`](./raw-app-windmill-client-import.md)).

# Inline backend runnables: prefer `type: script` in this repo; if you must go inline, use `inlineScript: { content, language }`

**Rule.** Prefer `type: script` + `path:` over inline runnables in `f/<team>/<name>.raw_app/backend/<id>.yaml`. Grid's workspace requires every item to carry an `on_behalf_of` user, and a newly-deployed raw app with inline runnables ships without one — the Windmill UI then blocks deploy with "You must set the 'on behalf of' user for all items before deploying." Inline runnables also can't be reused by other apps/flows. Promote the body to `f/<team>/<name>.ts` and reference it:

```yaml
# ✅ Preferred — runnable executes with the caller's permissions, no policy stamp needed
type: script
path: f/shared/load_irl_snapshot # adjust to match your deployed script's path
```

If you have a reason to keep the runnable inline (e.g. a tiny app-specific helper), the source goes inside a nested `inlineScript` block — not at the top level under `code:`:

```yaml
# ✅ Correct
type: inline
inlineScript:
  language: bun
  content: |
    export async function main() {
      return { ok: true };
    }
```

```yaml
# ❌ Wrong — lint passes but the dev/runtime client rejects it
type: inline
language: bun
code: |
  export async function main() {
    return { ok: true };
  }
```

The wrong shape bit us in `f/shared/example_irl.raw_app` (May 2026): `wmill app lint` printed `✅ All checks passed`, the bundle built, the dev server started, the frontend rendered… and then `wmill.backend.loadIrlSnapshot()` errored with:

```
Invalid runnable 'loadIrlSnapshot': type=inline, runType=undefined, path=undefined,
hasInlineScript=false. Must have either inlineScript (for inline type) or type="path"
with runType and path fields.
```

The error surfaces in the user-facing error banner as a "Failed to load" — looks like a frontend regression, isn't.

## Why lint doesn't catch it

`wmill app lint` only validates that the YAML parses and that the `backend/` folder is non-empty. The shape of each runnable isn't checked until execution. The `executeRunnable` path in the wmill CLI (`/opt/homebrew/lib/node_modules/windmill-cli/esm/main.js`, search `executeRunnable`) is what enforces the schema.

## Why we no longer ship inline as the default in this repo

`f/shared/example_irl.raw_app` originally shipped its trip snapshot as an inline runnable to demonstrate the inline pattern. The first deploy to grid.thanx.com failed with **"You must set the 'on behalf of' user for all items before deploying"** because inline runnables in a raw app execute under `app.policy.on_behalf_of_email`, which `wmill sync push` cannot populate from the repo — the policy is regenerated on every push and the workspace requires a real user. Promoting the body to `f/shared/load_irl_snapshot.ts` and referencing it via `type: script` resolved it (May 2026); deployed scripts run with the caller's identity, so no policy stamp is required.

If you do ship inline anyway, the operator has to run `wmill app set-permissioned-as <path> <email>` once after the first deploy. That's a manual step that gets forgotten when the app is recreated.

The accepted aliases for the inline form are `type: inline` or `type: runnableByName`; for the path form they are `type: path`, `type: runnableByPath`, or `type: script`. `wmill app pull` writes runnables in the `type: script` shape.

## How to verify

- Run `wmill app dev f/<team>/<name>.raw_app` (configure a local workspace first via `wmill workspace add` — see `claude/rules/local-windmill-dev.md`) and load `http://localhost:5173` in a browser. If a runnable is mis-shaped, the dev server logs `[backend] Job started: …` followed by the `Invalid runnable` error, and the frontend renders your `Failed to load` banner.
- For CI: there is no protection. Treat any new inline runnable as needing a manual `wmill app dev` smoke test before merge.

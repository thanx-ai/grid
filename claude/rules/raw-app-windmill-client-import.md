# Backend inline runnables that call `wmill.*` must start with `import * as wmill from "windmill-client"`

**Rule.** Any `inlineScript` under `<SCOPE>/<name>.raw_app/backend/<id>.yaml` (and any deployed `*.script.ts`) whose body calls `wmill.getVariable`, `wmill.getResource`, `wmill.runScript`, etc. MUST import the client on the first line of `content`:

```yaml
type: inline
inlineScript:
  language: bun
  content: |
    import * as wmill from "windmill-client";

    export async function main(lookbackDays: number = 30) {
      const token = await wmill.getVariable("f/eng/SOME_TOKEN");
      // ...
    }
```

There is no top-level `wmill` global in the worker runtime. Without the import the runnable throws `wmill is not defined` the first time it executes. Every deployed Windmill script that touches `wmill.*` imports it (see `f/shared/slack_notify.ts` line 1, in the `thanx-ai/grid-shared` reference repo).

If the body doesn't call `wmill.*` (a pure transform, static data) — omit the import. Don't add it speculatively.

## Why lint doesn't catch it

`wmill app lint` validates the frontend bundle + the wmill-virtual interception. It never executes the backend runnables, so a missing import inside `inlineScript.content` passes clean. The failure surfaces only at runtime, and because raw apps render backend errors as a "Failed to load" banner, it looks like a frontend regression — it isn't; the runnable never ran.

This is the same lint blind spot as [`scaffold-getvariable-placeholders.md`](./scaffold-getvariable-placeholders.md) (missing variable) and [`raw-app-inline-runnable-yaml.md`](./raw-app-inline-runnable-yaml.md) (wrong YAML shape): all three lint-clean and fail only on execution. (Note `raw-app-inline-runnable-yaml.md` also recommends preferring `type: script` over inline runnables in the first place — this import rule applies whenever you do go inline, but inline isn't the default.)

It bit the Ergane control pane (Jun 2026): 14 `backend/*.yaml` inline scripts called `wmill.getVariable(...)` without the import; lint printed `✅ All checks passed`, and every runnable threw `wmill is not defined` on first load.

## Distinct from the wmill-virtual rule

[`raw-app-wmill-virtual.md`](./raw-app-wmill-virtual.md) is about the **frontend** call shape — `wmill.backend.<id>(args)`, imported from the local `./wmill` stub. This rule is about the **backend** runnable body importing the real `windmill-client` npm package. Different file, different import, different failure: a raw_app can get one right and the other wrong.

## How to verify

- Run `wmill app dev <SCOPE>/<name>.raw_app`, load `http://localhost:5173`, and confirm each runnable returns data instead of a "Failed to load" banner. The dev server logs the `wmill is not defined` ReferenceError in the `[backend]` job output.
- There is no CI guard: `scripts/check-variable-references.sh` only scans `*.ts`/`*.py`/`*.go` source files (see its `--include` flags) — it does not read `inlineScript.content` YAML. Until that gap is closed, the `wmill app dev` smoke test is the only check.

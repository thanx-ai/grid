# Raw apps call backend runnables as `wmill.backend.<id>(args)` — not `wmill.<id>(...)`

**Rule.** In a `.raw_app/` frontend, invoke backend runnables through the `backend` Proxy:

```ts
// f/<team>/<name>.raw_app/App.tsx
import * as wmill from "./wmill";

const rows = await wmill.backend.loadCsMetrics({ lookbackDays: 30 });
```

Not `wmill.loadCsMetrics(30)`. The `wmill.ts` file in the app root is **hand-authored** and exists for typechecking / `wmill app dev`. At build time the wmill CLI replaces it with a fixed virtual module whose only top-level exports are `backend`, `backendAsync`, `waitJob`, `getJob`, `streamJob`. `backend` is a `Proxy` keyed by the YAML filename in `backend/`: `backend/loadCsMetrics.yaml` is addressed as `wmill.backend.loadCsMetrics(...)` and the args object is forwarded to the runnable.

If you wrote `wmill.<runnable>(...)` as a top-level call, esbuild emits:

```
▲ [WARNING] Import "loadCsMetrics" will always be undefined because there is
no matching export in "wmill-virtual:./wmill" [import-is-undefined]
```

The bundle still builds. The frontend then crashes at runtime the first time it touches that call. CI now treats this warning as an error (`scripts/lint-raw-apps.sh`), so it gates merges — but if you bypass CI or run lint manually, treat any `[WARNING]` from `wmill app lint` as a blocker.

## Stub shape

Mirror the runtime API in `wmill.ts`. Example:

```ts
// f/<team>/<name>.raw_app/wmill.ts
export type CsMerchantMetric = { merchantId: string /* ... */ };

export const backend = {
  async loadCsMetrics(_args: {
    lookbackDays?: number;
  }): Promise<CsMerchantMetric[]> {
    return [
      /* mock rows so `wmill app dev` renders before first sync */
    ];
  },
};
```

The stub's mock implementation only runs locally; at build/deploy time the virtual module replaces the whole export. Keep the **types** in the stub aligned with the script's `main()` return type so the frontend typechecks against the real surface.

## How to verify

- `wmill app lint f/<team>/<name>.raw_app` — should print no `[WARNING]` lines.
- `bash scripts/lint-raw-apps.sh` — runs lint across every `.raw_app/` and fails on warnings.
- CI workflow `lint-raw-apps` runs the same script on every PR.

## Why CLAUDE.md / README used to say otherwise

Earlier docs implied `wmill.ts` was auto-generated from `backend/*.yaml` and that the build-time warning was "expected and safe to ignore." Both wrong. The fix that introduced this rule (the `example_dashboard` raw app, deploy run 25721801946) shipped that misconception and broke the dashboard. Don't trust the historical wording if you see it in older commits — trust the CLI source (`/opt/homebrew/lib/node_modules/windmill-cli/esm/main.js`, search for `wmill-virtual`).

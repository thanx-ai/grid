# Raw-app tests are plain `bun test` files — never `// test:` deploy tests

Cover `.raw_app/` logic with `*_test.ts` files **inside the app directory**, run locally by `scripts/test-raw-apps.sh` (wired into `ci.yml` as the `Test raw apps` job). Do **not** put the `// test:` annotation on them.

## Why

The `// test:` annotation means "push me to Windmill and run me there" (`scripts/run-deploy-tests.sh`). App code can't survive that trip: it imports `./wmill`, a **virtual module that only exists while esbuild is bundling the app**. There is no such module in a Windmill script runtime, so an annotated app test fails on the import — a long way from its cause.

Worse, the two discovery mechanisms overlap. Deploy-test discovery is `find f -type f -name '*.ts'` with **no prune**, so a `// test:`-annotated file inside a `.raw_app/` gets picked up by *both* runners. `test-raw-apps.sh` therefore fails loudly on the annotation rather than letting deploy discover it later.

## Why it bit us

`wmill app lint` proves the bundle *builds*. Nothing proved it was *correct*, and two bugs shipped in `f/sales/franchise_intel.raw_app` because of it:

- The "My accounts" owner filter inherited an `&& m` exemption meant for the bucket presets, so selecting a rep rendered **458 rows of which 4 were theirs** — their book invisible inside a wall of blank CRM columns.
- One checkbox suppressed two unrelated things, so the `open opp` chip **could never render**: the loader computed the field, the table drew a chip, and the default filter removed every row that had one.

Both were found by hand-rendering the app against real data. Neither could have been caught by any check that existed.

Meanwhile `f/company/activation_dashboard.raw_app` already shipped **123 passing tests across 10 files** that protected nothing, because nothing ran them.

## How to write one

Pure logic (the cheap, durable case) — extract it into `lib/` and test it directly, as `activation_dashboard` does:

```ts
// f/company/activation_dashboard.raw_app/lib/merchants_test.ts
import { expect, test } from "bun:test";
import { merchantOptions } from "./merchants";

test("options sort by name, not the book's merchant-id order", () => { … });
```

Component behaviour, when the bug lives in a filter or render path, needs a DOM. Use happy-dom and mock the virtual module:

```ts
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { mock } from "bun:test";

mock.module("./wmill", () => ({ backend: { loadThing: async () => FIXTURE } }));
GlobalRegistrator.register();

const React = (await import("react")).default;
const App = (await import("./App")).default;
// render, drive the real <select>s, assert on host.querySelectorAll("tbody tr")
```

Add `happy-dom` and `@happy-dom/global-registrator` to the app's `devDependencies` and commit the refreshed `package-lock.json` — `node_modules/` is gitignored but the lock is committed, and CI installs with `npm ci`.

Keep these tests **offline**. They run in-process with no Windmill and no network; a test that reaches for a real backend belongs in a `// test:` deploy test beside the loader script instead.

## How to verify

```bash
bash scripts/test-raw-apps.sh          # from the caller repo root
cd f/<folder>/<name>.raw_app && bun test   # single app
```

Assert on *invariants*, not on absolute counts, when a test reads a generated feed — `franchise_intel_loader.ts` is regenerated on every publish, so `expect(rows.length).toBe(458)` rots within a day. "Every rendered row's owner equals the selected owner" does not.

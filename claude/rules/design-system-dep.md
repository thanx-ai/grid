# Design-system deps in raw_apps: registry or vendor, never `file:` / submodule

**Rule.** A raw_app that needs `@thanx/react`, `@thanx/tokens`, or any other shared design-system package has exactly two supported install paths:

1. **Publish the design system to an npm registry** (public npm, GitHub Packages, or — most likely — Windmill's workspace-scoped private npm proxy) and reference it as a normal version-pinned dependency in the raw_app's `package.json`: `"@thanx/react": "^1.4.0"`.
2. **Vendor it in-tree** under `<scope>/<name>.raw_app/lib/<package>/` and import via a relative path (`import { Button } from "./lib/thanx-react"`).

`file:` paths (`"@thanx/react": "file:../thanx-design-system/packages/react"`) and git submodules (`.gitmodules` referencing a sibling design-system repo) do **not** work and never will under the current raw_app build model.

## Why

`wmill app lint` runs `npm install` from inside the `.raw_app/` directory before esbuild bundles the output. `npm install` resolves `file:` paths relative to the package's own location — and the design-system sibling directory isn't inside the `.raw_app/`, so the install fails with `ENOENT` or silently pulls nothing. Git submodules pointed at design-system repos compound the problem: even if the submodule clones, its contents are outside the `.raw_app/` and `npm install` still can't reach them.

This is the same constraint that drives the `file:` / `link:` and `.gitmodules` refusals in `/grid:import` Step 2.

## Registry path (recommended)

Windmill exposes a workspace-scoped private npm proxy at `/w/<workspace>/npm_proxy/...`. To use it from a raw_app:

```jsonc
// <scope>/<name>.raw_app/package.json
{
  "dependencies": {
    "@thanx/react": "^1.4.0",
    "@thanx/tokens": "^1.4.0",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
  },
}
```

```text
# <scope>/<name>.raw_app/.npmrc
@thanx:registry=https://grid-origin.thanx.com/api/w/thanx/npm_proxy/
//grid-origin.thanx.com/api/w/thanx/npm_proxy/:_authToken=${WINDMILL_NPM_TOKEN}
```

**Token discipline.** The `${WINDMILL_NPM_TOKEN}` must remain an env-var reference and **never** be replaced with a literal token. A bare `.npmrc` entry in `.gitignore` (which this repo's gitignore has, and which `/grid:setup` recommends for project repos) matches at any directory depth — so a nested `<scope>/<name>.raw_app/.npmrc` is covered as long as the project repo has the bare `.npmrc` line. The risk that remains is an authored `.npmrc` that ends up committed in a repo whose gitignore does NOT have that line; verify before committing if the source repo was set up without `/grid:setup`.

The publishing side (how `@thanx/react@1.4.0` gets into the workspace proxy) lives in the design-system repo, not in project repos consuming it. Until that publish pipeline exists, fall back to the vendor path.

**Path forward** — the design-system repo is on the to-do list to wire `npm publish` into its own GH Action targeting the workspace proxy. Track the work and switch to the registry path once it's live.

## Vendor path (interim)

When the registry isn't ready, copy the built artifacts into the raw_app and import locally:

```bash
mkdir -p <scope>/<name>.raw_app/lib/thanx-react
cp -r path/to/thanx-design-system/packages/react/dist/* <scope>/<name>.raw_app/lib/thanx-react/
```

```tsx
import { Button } from "./lib/thanx-react";
```

Trade-offs:

- **Pro:** works today. No registry dependency. esbuild bundles the lib like any other local file.
- **Con:** every raw_app vendors its own copy. Breaking changes don't propagate; each project repo updates its `lib/` on its own cadence. Track the design-system version that was vendored in a `lib/thanx-react/VENDORED_VERSION` text file so the drift is visible.

Don't vendor source files (`.tsx`/`.ts` directly) — copy the pre-built `dist/` artifacts. Source vendoring drags in transitive dev dependencies that the raw_app's `package.json` doesn't declare; the bundle either fails to resolve or silently includes the wrong version.

## What to do when `/grid:import` flags a `file:` or submodule dependency

If a source repo's `package.json` has `"@thanx/react": "file:..."` or a `.gitmodules` referencing the design-system repo, `/grid:import` Step 2 raises a migration item naming this rule and offers a **proceed / bail** prompt. Two recovery paths to clear the migration item:

1. **Switch the source repo's `package.json` to the registry version** (`"@thanx/react": "^1.4.0"`) before re-running `/grid:import`. Requires the registry path to be live.
2. **Vendor first, import second.** In the source repo, manually replace the design-system imports with relative imports against a copied `lib/` dir, commit that, then re-run `/grid:import`. The import will see normal relative paths it can carry over.

If you instead pick **Proceed** at the migration prompt, the design-system imports will be carried over verbatim and marked as TODOs in the generated `.raw_app/` — the bundle won't lint until you complete one of the two paths above. Either way, the design-system surgery is the user's responsibility; `/grid:import` doesn't try to do it automatically because the publishing/vendoring decision is workspace-architectural, not per-app.

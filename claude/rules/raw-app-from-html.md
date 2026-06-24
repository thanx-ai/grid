# Importing a single self-contained HTML file as a raw_app

**Rule.** When `/grid:import` is given a `.html` source (or a `file://…html` URL), the conversion to `f/<team>/<name>.raw_app/` is not a literal copy. Three transforms are mandatory and easy to get wrong:

1. **Hardcoded data literals must move to a backend script.** Inline `<script>` blocks in HTML dashboards routinely declare a 100KB+ `const CUBE = {…}` / `const DATA = […]` literal. Keep it inline in `App.tsx` and the snapshot ships in the JS bundle — bundle balloons, PR diff becomes hostile, and the data is no longer queryable from anything else in the workspace. Always write a deployed Windmill script at `f/<team>/load_<name>.ts` that exports the data and returns it from `main()`, then point the raw_app's `backend/<runnable>.yaml` at that script with `type: script`. If the data is large (>100KB) and the UI has a natural tab/view boundary, split the loader so the frontend can lazy-load the heavy part — `f/shared/load_customer_cube_overview.ts` + `f/shared/load_customer_cube_customers.ts` are the canonical example: the Overview tab loads on mount, the Customers tab lazy-loads the 200KB+ customers array on first open.
2. **Client-side password gates are not access control.** A surprisingly common HTML-dashboard idiom is a `redacted/general/exec` mode toggle gated by SHA-256 hashes of the password against a hardcoded value. **Drop the gate during the port.** Anyone with the bundle can read the hashes and the data; the gate is obfuscation. In Windmill, group membership against the `f/<dept>/` folder is the real auth boundary (see [`folder-perms.md`](./folder-perms.md)). If data partitioning is genuinely required, split the loader: `f/shared/load_x_redacted.ts` (workspace-wide read+run) and a restricted-folder loader (e.g. `f/<restricted-team>/load_x_full.ts`, readable only to that group) — same UI calling two different runnables based on which one succeeds. No read-restricted folder exists in the workspace today; one would need to be stood up alongside a matching Google Workspace group.
3. **Remote fonts must be self-hosted — strip the `@import`, do NOT inject an external `<link>`.** Two independent failures, so dropping the `@import` alone is not enough:

   - `scripts/lint-raw-apps.sh` treats any `[WARNING]` from `wmill app lint` as a CI failure, and esbuild **does** warn on remote `@import url(...)` in CSS — so the `@import` line has to go.
   - The obvious fix — inject a runtime `<link>` to `fonts.googleapis.com`/`fonts.gstatic.com` from `index.tsx` — **fails in production.** It loads under `wmill app dev` (no CSP), so it looks fixed locally, but the **deployed app's Content-Security-Policy blocks the external request** and the font silently falls back to a system font. (Same CSP class as the no-external-CDN constraint; Next.js avoids it because `next/font` self-hosts.)

   Self-host: download the `.woff2` for each weight the design uses, base64-encode it, and inline it as `@font-face` in `index.css` (the stylesheet `App.tsx` imports) so it ships inside `dist/bundle.css`:

   ```css
   @font-face {
     font-family: "Inter";
     font-weight: 400;
     font-style: normal;
     font-display: swap;
     src: url("data:font/woff2;base64,<BASE64>") format("woff2");
   }
   ```

   One `@font-face` per weight/style; keep only the weights you use (~15–30 KB of base64 each). A wrong/missing `@font-face` is invisible to lint — confirm the font applied by looking at the rendered output (see the visual-verification section below).

## CDN scripts → npm dependencies

For each `<script src="https://cdn.example.com/lib.min.js">` in the source HTML, **try npm first**:

| CDN URL pattern                            | Preferred npm package                                           |
| ------------------------------------------ | --------------------------------------------------------------- |
| `cdn.plot.ly/plotly-X.min.js`              | `plotly.js-basic-dist-min` (or `plotly.js` if you need 3D/maps) |
| `cdn.jsdelivr.net/npm/chart.js`            | `chart.js`                                                      |
| `unpkg.com/d3@7`                           | `d3`                                                            |
| `cdnjs.cloudflare.com/ajax/libs/moment.js` | `moment` (or `dayjs` — smaller)                                 |
| `cdn.tailwindcss.com`                      | **REFUSE** — pre-process locally; see `/grid:import` Step 2     |

Adding the npm dep means esbuild bundles + tree-shakes + types come along. Fall back to runtime `<script>` injection in `index.tsx` only when there's no usable npm package or the API surface is too small to justify a multi-MB dep.

## Imperative DOM code → React refs + useEffect

The inline `<script>` of an HTML dashboard typically renders by mutating the DOM:

```js
document.getElementById("chart-revenue").innerHTML = "";
Plotly.newPlot(document.getElementById("chart-revenue"), data, layout);
```

In React, that pattern becomes a child component holding a `useRef<HTMLDivElement>(null)` and running the imperative call inside `useEffect`:

```tsx
function Chart({
  data,
  layout,
}: {
  data: Plotly.Data[];
  layout?: Partial<Plotly.Layout>;
}) {
  const ref = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (!ref.current) return;
    Plotly.newPlot(ref.current, data, layout);
    return () => {
      if (ref.current) Plotly.purge(ref.current);
    };
  }, [data, layout]);
  return <div ref={ref} style={{ height: 320 }} />;
}
```

The cleanup function in the `useEffect` return is mandatory — without it you leak DOM nodes on every re-render of the parent.

**Stabilize the `data` AND the `layout` props or the chart re-initializes on every parent render.** Both. Inline literals (`<Chart data={[{ x, y }]} layout={{ yaxis: { tickformat: "$,.0f" } }} />`) are new references each tick, which makes the `useEffect([data, layout])` purge and re-init even when the underlying data didn't change. People remember to memoize `data` and then casually inline `layout={{ ... }}` next to it; the chart re-inits on every keystroke in an unrelated filter input. The cleanest fix is a per-chart child component that `useMemo`s **both** the data array and the layout object against the actual dependencies — see `f/shared/customer_cube.raw_app/App.tsx`'s `RevenueChart` / `VerticalMixChart` / `RenewalPipelineChart` / `AcvDistributionChart`, and the `logosLayout` / `revenueLayout` / `stackLayout` / `scatterLayout` / `histoLayout` / `nrrChartLayout` constants on the later tabs. This bug shipped on the first version of the customer_cube port (data half) and again on the second version (layout half) — both caught in code review.

**Do not** translate `document.getElementById('x').innerHTML = '<table>…</table>'` literally with `dangerouslySetInnerHTML`. That's an XSS surface (the source HTML often interpolates user-controlled strings), and the rendered markup sits outside React's tree so state updates won't reach it. Rewrite that section as proper JSX.

## File-shape checklist

After conversion, the raw_app should look exactly like this — no `src/`, no `index.html`, no `tsconfig.json`:

```
f/<team>/<name>.raw_app/
├── raw_app.yaml         # framework: react18
├── package.json         # react + react-dom + any CDN-replacement npm deps
├── index.tsx            # ReactDOM mount + any CDN <script> runtime injections (no font <link> — see rule 3)
├── App.tsx              # The body markup as JSX + state + effects; imports ./index.css
├── index.css            # The <style> contents, minus remote @import lines, plus inlined base64 @font-face
├── wmill.ts             # Typed stub mirroring each backend/*.yaml return shape
└── backend/
    └── load<Name>.yaml  # type: script, path: f/<team>/load_<name>
```

The deployed loader (`f/<dept>/load_<name>.script.ts`) holds the data and **must ship with a colocated `f/<dept>/load_<name>_test.script.ts`**. The test's first line is `// test: script/f/<dept>/load_<name>` so `scripts/run-deploy-tests.sh` discovers and runs it on every deploy; without it, a regression in the loader's return shape only surfaces when the raw_app crashes in production. At minimum the test should assert non-empty primary arrays, expected top-level keys, and that numeric fields are numbers. The test must `import { main } from "./<sibling>.ts"` — see [`deploy-test-no-nested-job.md`](./deploy-test-no-nested-job.md) for why `wmill.runScript` is unsafe in a Windmill deploy test.

Refresh the snapshot by re-running whatever generated the source HTML and committing a new version of `load_<name>.ts` (the test usually doesn't need to change unless the shape did).

## Lint-green is not visually correct — look at the rendered output

For HTML imports, `wmill app lint` is necessary but not sufficient — lint catches `[WARNING]`-level esbuild issues (unresolved imports, wrong wmill virtual surface) but does not catch React runtime errors. Hand-translated JSX from imperative HTML routinely ships render-time bugs (missing `key` props on `.map()` output, accessing `undefined.length` when stub data is empty, `useEffect` cleanup leaks). Spinning up `wmill app dev` and loading the bundle in a browser proves the React tree renders against the local stub data — see `/grid:import` Step 9 item 3.

Worse, a whole class of bugs renders **without throwing** — they look fine to lint and to a quick glance, and only a side-by-side with the source reveals them:

- **Dropped `import "./index.css"` in `App.tsx`** → esbuild emits no `dist/bundle.css` and the app is fully unstyled. (Confirm `dist/bundle.css` is non-empty.)
- **CSP-blocked external font** (item 3 above) → silent system-font fallback in production only.
- **Mismatched asset key** between a `load_assets` runnable and the frontend `useAsset(...)` → blank image. Derive the key from one canonical function on both sides (strip leading `/`, drop extension, `[^a-z0-9]+`→`_`, lowercase: `/demo-assets/brand/cover.jpg` → `demo_assets_brand_cover`).
- **Lost icon size default** → an SVG ported to spread `{...props}` without a default `size`/`width`/`height` renders at full intrinsic size for callers passing only `className`. Keep the size default.

When you have the source (a running source app, the source `.html`, or a deployed reference), drive both with Playwright and **pixel-diff per route/view** (`pixelmatch`); otherwise eyeball each view in the `wmill app dev` tab against the source. Treat a visual mismatch as a blocker, same as a lint `[WARNING]`.

Make the `wmill.ts` mocks return small **representative** data (one or two rows of each shape, not empty arrays). Empty stubs pass too easily — they exercise the loading branch and skip the real render path.

## Watch the Unicode on bucket strings

Snapshot generators (Python, etc.) routinely emit en-dashes in human-facing bucket labels — `"1–10"`, `"$50K–150K"`, `"6–12mo"`. The frontend filter/sort code often needs to declare a parallel ordering constant locally (`const order = ["1–10", ...]`). It's easy to type the ASCII hyphen (`"1-10"`) by accident; TypeScript sees both as `string` and can't catch the mismatch, so the join silently produces empty groups in production and renders an empty table. The customer_cube `ProfitabilityTab` sizeSlices bucket-order constant shipped with ASCII hyphens once; the "By Size" break-even table rendered empty until review caught it.

Mitigations: (a) prefer reusing an already-correct constant from elsewhere in the file (e.g. `LOC_BUCKETS` in `customer_cube.raw_app/App.tsx`) over re-typing the literals; (b) when you must declare a new list, paste from the generator output, don't hand-type; (c) sanity-check a slice's `n` count when reviewing.

## How we got bit

May 2026: `/grid:import file:///Users/.../customer_cube.html` (a 700KB self-contained Plotly dashboard with 210 customer records inlined). The first instinct was "just paste the body into App.tsx and call it done" — that would have shipped a 1MB bundle, made the customer snapshot un-queryable from any other Windmill job, and copied the SHA-256 password gate into the React app as if it were real auth. The port instead extracted the data to a deployed Windmill script, dropped the gate (folder ACLs on `f/shared/` are the actual boundary), and replaced the imperative Plotly calls with `useEffect`-driven `Chart` children. Bundle came out at 1.9 MB (most of which is `plotly.js-basic-dist-min`, not data), lint passed clean. The first iteration shipped a single `f/shared/load_customer_cube.ts` of 24K lines; a follow-up split it into overview + customers along the tab boundary so the heavy customers array lazy-loads (now the canonical pattern in step 1 above).

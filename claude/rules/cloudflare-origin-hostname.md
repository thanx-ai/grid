# Use `grid-origin.thanx.com` for API calls, not `grid.thanx.com`

**Rule.** Scripted callers of the Windmill HTTP API — CI, `wmill sync push`, `wmill sync pull`, `wmill workspace add` (the stored URL becomes the default for every later CLI call), the deploy-test runner, the variable-reference checker, any local `curl` against `/api/...` — must target `https://grid-origin.thanx.com`. Reserve `https://grid.thanx.com` for browser traffic (the Windmill UI, app share links, the token-mint page).

`grid.thanx.com` is proxied through Cloudflare. Cloudflare Access challenges every request that arrives without an authenticated browser session or a service-token header pair, and replies with a 403 + HTML body + `cf-ray` header before the request ever reaches Windmill. The `wmill` CLI tries to parse that HTML as JSON and fails with an opaque error; bare `curl` calls return the Cloudflare login page. `grid-origin.thanx.com` resolves directly to the Windmill origin and skips the Cloudflare layer entirely.

The split is intentional and load-bearing: app users keep getting Cloudflare DDoS / WAF protection in front of the UI, while CI and deploy automation stop needing per-runner allowlists or service-token rotation.

## How to verify

- New workflow / script hitting `/api/...`? Default the base URL to `https://grid-origin.thanx.com`. In `.github/workflows/`, set it once at the job level as `env: WMILL_BASE_URL: https://grid-origin.thanx.com` so every step inherits the same value — both `deploy.yml` and `ci.yml` already do this.
- Setting up a fresh CLI workspace? `wmill workspace add thanx thanx https://grid-origin.thanx.com` — the stored base URL is what every subsequent `wmill sync pull/push --workspace thanx` sends API calls to.
- Adding a user-facing URL (a share link in a Slack message, a doc, a UI redirect)? Use `https://grid.thanx.com`.
- Suspicious of a 403 with `cf-ray:` in the headers? You're hitting `grid.thanx.com` from an unauthenticated context — switch the base URL to `grid-origin.thanx.com` and retry.
- Locally, override the default with `WMILL_BASE_URL=https://grid-origin.thanx.com` if you ever want to point a script at the origin explicitly. The two CI scripts (`scripts/run-deploy-tests.sh`, `scripts/check-variable-references.sh`) already default to it.

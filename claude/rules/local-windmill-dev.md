# Iterate against a local Windmill — never against `grid.thanx.com` for dev loops

**Rule.** The iteration pattern for raw_app / script / flow work is: run Windmill **locally**, point the `wmill` CLI at that local workspace, iterate there (`wmill app dev`, `wmill script run`, lint) until it works, then push to the project repo's default branch — the reusable `deploy.yml` workflow pushes it to `grid.thanx.com` for you. Don't mint a personal token against production just to close the edit/test loop; that couples your in-progress iteration to the shared workspace everyone else's items live in, and every failed attempt round-trips over the network instead of hitting `localhost`.

```
edit code  →  test against local Windmill  →  looks right?  →  git push to master  →  deploy.yml pushes it live
                     ↑___________________________|
                     no (fix and retry — all local, no network round trip)
```

## First-time setup

**1. Run Windmill locally.** `docker compose up -d` with Windmill's own compose file — see <https://www.windmill.dev/docs/advanced/self_host> for the current one. This gives you a Windmill instance at `http://localhost:8000` with a single `bun`-tagged worker (relevant if you write deploy tests — see [`deploy-test-no-nested-job.md`](./deploy-test-no-nested-job.md)).

**2. Mint a CLI token.** The `wmill` CLI has no `--email --password` bootstrap, so exchange the local instance's default superadmin login for a persistent API token via two curl calls — auth-login, then token-create:

```bash
SESSION_TOKEN=$(curl -s -X POST http://localhost:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@windmill.dev","password":"changeme"}')

TOKEN=$(curl -s -X POST http://localhost:8000/api/users/tokens/create \
  -H "Authorization: Bearer $SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"label":"local-dev-cli"}')
```

(`admin@windmill.dev` / `changeme` are Windmill's own documented OSS defaults for a fresh local instance, not a Thanx secret — change them on first login if you want, and re-run the login call with your new password.)

**3. Register the local workspace with the CLI:**

```bash
wmill workspace add --create local dev http://localhost:8000/ --token "$TOKEN"
```

This creates workspace id `dev` (named `local` in your CLI config) — the workspace `wmill app dev`, `wmill script run`, etc. target by default once it's the active workspace.

## The iteration loop

Once the `local` workspace exists, day-to-day work never has to touch `grid.thanx.com`:

- `wmill app lint <path>` / `wmill app dev <path>` (loads `http://localhost:5173`) — build and smoke-test a raw_app entirely against the local instance.
- `wmill script run <path>` — run a script's `main()` against local data/variables.
- Fix, re-run, repeat — every cycle is local, so a broken attempt costs a few seconds, not a CI round trip.
- When it works locally, commit and push to the repo's default branch. `.github/workflows/grid.yml` → the reusable `ci.yml` + `deploy.yml` in `thanx-ai/grid-tooling` take it from there and push it to `grid.thanx.com` per-item (see [`per-item-push-not-sync.md`](./per-item-push-not-sync.md), [`deploy-full-inventory.md`](./deploy-full-inventory.md)).

If a runnable calls a service on your own machine rather than an external API, see [`raw-app-dev-host-networking.md`](./raw-app-dev-host-networking.md) — `wmill app dev` runs runnables inside a container, so `127.0.0.1` won't reach your host.

## If the script needs Keystone data

The local workspace has no `f/shared/KEYSTONE_ACCESS_TOKEN` — that variable is a production-managed secret provisioned in the `grid.thanx.com` workspace only (see [`keystone-data-access.md`](./keystone-data-access.md)). Runtime code always reads it by that same path (`wmill.getVariable("f/shared/KEYSTONE_ACCESS_TOKEN")`), so to exercise that code path locally:

1. **Prompt the user** to provision their own **personal** Keystone API token (Keystone admin UI → API tokens), rather than trying to copy or guess the shared production token.
2. Add it as a variable at the **same path** in the local workspace so the code is unchanged between local and prod:

   ```bash
   wmill variable push f/shared/KEYSTONE_ACCESS_TOKEN --value "<personal token>" --workspace local
   ```

   (Or set it via the local instance's UI at `http://localhost:8000` → Variables.)

Never put a personal Keystone token in the *production* `f/shared/KEYSTONE_ACCESS_TOKEN` slot, and never commit it anywhere in the repo — it's a local-workspace-only variable.

## How to verify

- `wmill workspace list` shows `local` pointing at `http://localhost:8000/`.
- `wmill app dev <path>` / `wmill script run <path>` succeed against local data without ever hitting `grid-origin.thanx.com`.
- A script that calls Keystone at runtime resolves `f/shared/KEYSTONE_ACCESS_TOKEN` locally to a personal token, and the same code deploys unchanged (prod resolves the same path to the shared token).

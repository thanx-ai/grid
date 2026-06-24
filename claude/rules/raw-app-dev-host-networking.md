# `wmill app dev` runs backend runnables in a container — reach host services via `host.docker.internal`, not `127.0.0.1`

**Rule.** When a raw_app's runnables call a service running on the developer's own machine (a local API, a dev server), point the base-URL workspace variable at `http://host.docker.internal:<port>` AND bind the host service to `0.0.0.0`. `wmill app dev` executes backend runnables inside the Windmill worker **container**, so `127.0.0.1` / `localhost` resolves to the container itself, not your host — the call fails with `ConnectionRefused`.

```ts
// host service — bind to 0.0.0.0 so the Docker bridge can reach it
app.listen(8787, "0.0.0.0"); // not "127.0.0.1"
```

```
# the workspace variable the runnable reads (local dev value)
f/eng/MY_API_BASE_URL = http://host.docker.internal:8787
# (prod points the same variable at the real https:// origin)
```

## Why it bites

A runnable that works when you `curl http://127.0.0.1:8787` from your shell fails inside `wmill app dev` because the worker is containerized. The error is a bare `ConnectionRefused` / `fetch failed` in the `[backend]` job log — nothing announces "you're in a container," so it reads like the host service is down when it's actually just unreachable at that address from inside the container.

`host.docker.internal` is Docker's built-in DNS name for the host gateway; it resolves from inside the worker to your machine. But the host service also has to listen on a non-loopback interface — a server bound to `127.0.0.1` accepts only the host's own loopback, so the bridged request from the container is refused even with the right hostname.

**Platform note:** `host.docker.internal` resolves automatically on Docker Desktop (macOS / Windows). On native Docker Engine (Linux), the container needs `--add-host=host.docker.internal:host-gateway` or the hostname won't resolve at all — you'll get a DNS failure rather than `ConnectionRefused`. If the `wmill app dev` worker is Docker Desktop (the common Mac dev setup), this is automatic; on Linux, confirm the worker container is launched with that `--add-host` flag.

## If the host service fail-closes on non-loopback source IPs

A host API that trusts only loopback source IPs (a common "local dev is safe" shortcut) will reject the container's request — the source IP is the Docker bridge (RFC1918, e.g. `172.17.0.0/16`), not `127.0.0.1`. Add an explicit opt-in that trusts the Docker bridge / RFC1918 range, gated behind a flag, and **keep the credential check**: widening the trusted source range is not a substitute for auth.

## Production is unaffected

This is local-dev-only. In prod the runnable runs on a Grid worker and the base-URL variable points at the real `https://` origin — no `host.docker.internal`, no `0.0.0.0` binding. Keep the base URL in a workspace variable (never hardcoded) so local and prod differ only by the variable's value — and recreate that variable at the same path in both the local and prod workspaces (see [`raw-app-variable-path-coupling.md`](./raw-app-variable-path-coupling.md)).

## How to verify

- Start the host service bound to `0.0.0.0`, then `wmill app dev <SCOPE>/<name>.raw_app` — the runnable should return data, not `ConnectionRefused`.
- Confirm the host service's access log shows the request arriving from a `172.x` (Docker bridge) source IP rather than `127.0.0.1`.

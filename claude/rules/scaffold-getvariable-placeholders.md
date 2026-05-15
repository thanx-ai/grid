# Don't leave placeholder `wmill.getVariable(...)` calls in scaffold scripts

**Rule.** A script must not call `wmill.getVariable("f/...")` for a variable that does not yet exist in the workspace. Either create the variable first, or omit the call until the real implementation needs it.

`getVariable` throws on a missing path:

```
Variable not found at f/shared/KEYSTONE_BASE_URL or not visible to you:
Not found: Variable f/shared/KEYSTONE_BASE_URL not found
```

The throw happens **at runtime, on every invocation** — there is no lint or typecheck that flags it locally or in CI. Because raw apps surface backend errors as a "Failed to load" banner in the app body, the bug looks like a frontend regression. It isn't; the script never ran. The example dashboard shipped with `await wmill.getVariable("f/shared/KEYSTONE_BASE_URL")` as a TODO marker for future Keystone wiring, the variable was never created in the workspace, and the deployed app crashed on first load.

## How to verify

- CI runs `bash scripts/check-variable-references.sh` on every PR (`.github/workflows/ci.yml` → `check-variable-references` job). It greps every literal `wmill.getVariable("f/...")` / `wmill.getResource("f/...")` call under `f/` and hits the prod `variables/exists` / `resources/exists` endpoint. A missing path fails the PR before merge. **This is the load-bearing guardrail** — if the check is green, the bug class is caught.
- Local verification (same logic): `WMILL_READ_TOKEN=<token> bash scripts/check-variable-references.sh`.
- If a path is aspirational (no real consumer yet), delete the call. A TODO comment is enough.
- If a path _should_ exist, create it in the Windmill UI (or via `wmill variable add`) **before** merging the script that reads it.

The check only sees **literal string arguments**. Template strings like `getVariable(\`f/${env}/X\`)` are silently skipped — there's nothing to verify statically. Avoid computed paths in scaffolded code; if you need a computed path, write a deploy test (see [README → Deploy tests](../../README.md#deploy-tests)) that exercises the resolution at runtime.

## Why a typecheck doesn't help

`getVariable` is typed as `(path: string) => Promise<string>` — the path is a runtime string, not a literal type that could be cross-referenced against the workspace's variable inventory. The only signal is a thrown promise on execution — which is why the CI check above queries the workspace directly rather than relying on the type system.

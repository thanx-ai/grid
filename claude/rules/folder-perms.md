# folder.meta.yaml is the only ACL knob this repo has — items inherit from it

When you deploy a script/app/flow via `wmill sync push` and it's only reachable by `admin@windmill.dev` even though it lives under `f/<team>/`, the cause is almost always `folder.meta.yaml` missing a group grant. Items have no per-item ACL in the repo: `wmill sync` doesn't round-trip per-script/per-app/per-flow `extra_perms`, and `wmill.yaml` has no toggle to opt in. The folder ACL is what governs access, full stop.

## Why this bit us

The example dashboard at `f/shared/example_dashboard.raw_app/` deployed cleanly, lint passed, the URL resolved — but only `admin@windmill.dev` could open it. `f/shared/folder.meta.yaml` had `admin@windmill.dev: true` and **no group entries**, so the folder ACL collapsed to "admin-only" and every item inside inherited that. CLAUDE.md claimed `f/shared/` was "everyone read+run" but the YAML didn't reflect it. The CI lint had nothing to say about ACL shape, so the drift shipped silently.

## How to verify

For every `f/<team>/folder.meta.yaml`:

1. **`g/all: false` must be in `extra_perms`** if you want workspace-wide read+run.
2. The team group (`g/engineering`, `g/customer_success`, `g/product`, `g/design`, `g/operations`, `g/onboarding`, `g/support`, `g/finance`, `g/exec`, `g/marketing`, `g/sales`) must be present with `true` if that team should be able to write. If the SCIM group doesn't exist in Google Workspace yet, the grant is a no-op until the group is provisioned.
3. The `true`/`false` semantics are: `true` = read + **write**, `false` = read-only (still includes run).

Quick local check before pushing:

```bash
yq '.extra_perms' f/<team>/folder.meta.yaml
```

Expect `g/all: false` plus the owning team group. Missing `g/all` is the failure mode.

## Related

- Workspace-wide visibility expansion (this commit): everything in `f/*/` is now `g/all: false`.
- `g/all: false` includes **run**, not just read — anyone can manually trigger jobs. Side-effecting work (Slack, Salesforce, outbound webhooks) needs `suspend` approval gates; see CLAUDE.md "Approval / suspend".
- There's no CI check for folder.meta.yaml shape today. If a third folder.meta.yaml drift bites us, that's the trigger to write `scripts/check-folder-perms.sh` (same model as `check-variable-references.sh`).

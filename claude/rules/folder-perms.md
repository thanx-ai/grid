# folder.meta.yaml is the only ACL knob this repo has — items inherit from it

When you deploy a script/app/flow (via the master-merge per-item push, a manual `wmill <type> push`, or local `wmill sync push`) and it's only reachable by `admin@windmill.dev` even though it lives under `f/<scope>/`, the cause is almost always `folder.meta.yaml` missing a group grant. Items have no per-item ACL in the repo: the wmill CLI doesn't round-trip per-script/per-app/per-flow `extra_perms`, and `wmill.yaml` has no toggle to opt in. The folder ACL is what governs access, full stop.

## Why this bit us

The example dashboard at `f/shared/example_dashboard.raw_app/` deployed cleanly, lint passed, the URL resolved — but only `admin@windmill.dev` could open it. `f/shared/folder.meta.yaml` had `admin@windmill.dev: true` and **no group entries**, so the folder ACL collapsed to "admin-only" and every item inside inherited that. CLAUDE.md claimed `f/shared/` was "everyone read+run" but the YAML didn't reflect it. The CI lint had nothing to say about ACL shape, so the drift shipped silently.

## How to verify

For every `f/<team>/folder.meta.yaml`:

1. **`g/all: false` must be in `extra_perms`** if you want workspace-wide read+run.
2. The team group (`g/engineering`, `g/success`, `g/product`, `g/design`, `g/operations`, `g/onboarding`, `g/support`, `g/finance`, `g/exec`, `g/marketing`, `g/sales`) must be present with `true` if that team should be able to write. Most of these are SCIM-synced from Google Workspace; `g/operations` and `g/success` are Windmill-native groups (created directly in Windmill, not SCIM) — see the incident below for why that distinction mattered. Either way, if the group doesn't exist yet, the grant is a no-op until it's provisioned.
3. The `true`/`false` semantics are: `true` = read + **write**, `false` = read-only (still includes run).

Quick local check before pushing:

```bash
yq '.extra_perms' f/<team>/folder.meta.yaml
```

Expect `g/all: false` plus the owning team group. Missing `g/all` is the failure mode.

## Folder ACL drift: a group grant made in the Windmill UI gets silently reverted

`folder.meta.yaml`'s `extra_perms` is re-`PUT` in full on **every** master deploy, of **anything** — not just when this folder's file changes. See [`deploy-full-inventory.md`](./deploy-full-inventory.md): the repo is the source of truth on every deploy, by design, so a workspace-side (UI) edit to anything the full-inventory push re-asserts gets reverted on the next deploy. Folder ACLs are one of the "simpler types" that doc calls out as fully re-`PUT` each time (alongside `resource`, `variable`, `schedule`).

**Why this bit us.** An admin granted `g/Operations` and `g/Success` write access to `f/operations` and `f/success` directly in the Windmill UI, to unblock two teams. The repo's committed groups for those folders were (and remained) `g/operations` and `g/customer_success` — different names, and in the operations case, different *case* (Windmill/SCIM group names are case-sensitive, so `g/Operations` and `g/operations` are two unrelated groups, the same trap as confusing `g/exec` with an unrelated same-named "Exec workspace" group). The UI grant was never committed. The next master deploy of *anything* — unrelated to these folders — re-pushed both `folder.meta.yaml` files exactly as committed, silently dropping the UI-only groups. The admin had no way to know this would happen and re-added the same UI-only grant a month later, expecting it to stick. Compounding it: `g/customer_success` was never actually provisioned as a real group at all — the folder's write grant had been a no-op since the folder was scaffolded, and the two real, actively-used groups (`Operations` and `Success`, with real members and admins) only ever existed under the capitalized, uncommitted names.

**Resolution.** Rather than rename the live UI-managed groups (Windmill has no rename endpoint — `name` is the group's primary key; `POST /groups/update/:name` only rewrites `summary`), we created new lowercase groups (`g/operations`, `g/success`) with identical membership and admins to the capitalized originals, then pointed `folder.meta.yaml` at them. `f/operations` already declared `g/operations` — that grant had been silently inert the whole time and started working the moment the group existed. `f/success` moved from the dead `g/customer_success` to the new `g/success`. The old capitalized `Operations`/`Success` groups are kept temporarily (not deleted) until the new groups are confirmed working, then retired.

**How to avoid it going forward**: any folder ACL change — a new group, a case fix, extending write access — goes through a PR editing `folder.meta.yaml`, the same as any other Grid item. Never grant folder permissions directly in the Windmill UI; treat that as scratch/debugging only, and expect it to be wiped on the next deploy. If the intended group doesn't match the canonical list below, that's a sign the canonical group is wrong (fix `folder.meta.yaml` to use it) or a genuinely new group is needed (add it to the canonical list in this doc and to `scripts/check-folder-perms.sh` in the same PR).

## Related

- Workspace-wide visibility expansion (this commit): everything in `f/*/` is now `g/all: false`.
- `g/all: false` includes **run**, not just read — anyone can manually trigger jobs. Side-effecting work (Slack, Salesforce, outbound webhooks) needs `suspend` approval gates; see CLAUDE.md "Approval / suspend".
- CI now checks folder.meta.yaml shape: `scripts/check-folder-perms.sh` (same model as `check-variable-references.sh`) validates every `extra_perms` key against the canonical group list above and fails the build on an unknown or wrong-case group name. It cannot catch a grant that only ever existed in the UI and was never committed at all — that class of drift is prevented by process (previous section), not by CI.

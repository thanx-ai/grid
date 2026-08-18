# folder.meta.yaml is the only ACL knob this repo has — items inherit from it

When you deploy a script/app/flow (via the master-merge per-item push, a manual `wmill <type> push`, or local `wmill sync push`) and it's only reachable by `admin@windmill.dev` even though it lives under `f/<scope>/`, the cause is almost always `folder.meta.yaml` missing a group grant. Items have no per-item ACL in the repo: the wmill CLI doesn't round-trip per-script/per-app/per-flow `extra_perms`, and `wmill.yaml` has no toggle to opt in. The folder ACL is what governs access, full stop.

## Why this bit us

The example dashboard at `f/shared/example_dashboard.raw_app/` deployed cleanly, lint passed, the URL resolved — but only `admin@windmill.dev` could open it. `f/shared/folder.meta.yaml` had `admin@windmill.dev: true` and **no group entries**, so the folder ACL collapsed to "admin-only" and every item inside inherited that. CLAUDE.md claimed `f/shared/` was "everyone read+run" but the YAML didn't reflect it. The CI lint had nothing to say about ACL shape, so the drift shipped silently.

## Only one repo should ever declare a given folder's ACL

A `f/<name>/folder.meta.yaml` is not scoped to the repo that wrote it — any repo can deploy items into `f/success/`, `f/operations/`, etc., and any of them can also carry that folder's `folder.meta.yaml`. But every deploy re-pushes a repo's **entire** `f/**` inventory (see [`deploy-full-inventory.md`](./deploy-full-inventory.md)), and for folders that's a full `PUT` of `extra_perms`, not a merge. If two repos both declare `f/success/folder.meta.yaml`, whichever merges last silently overwrites the other's grants — permanently, with no error, no conflict, and no one even touching the "losing" repo.

**Why this bit us.** An org-wide audit (triggered by the incident below) found `f/operations`, `f/success`, `f/sales`, `f/engineering`, `f/marketing`, and `f/product` were each declared by **two** repos — `grid-shared` (a near-empty placeholder copy in every case) and a separate repo that actually owned the folder's real content (`ops-kpi-grid`, `merchant-operations-dashboard`, `thanx-sales-demo`, `thanx-eng-reports` ×2, `sara-grid`). Every deploy from *either* repo silently reverted the other's grants on that folder — including, ironically, the fix below the first time it landed only in `grid-shared`.

**Resolution.** Pick exactly one owning repo per folder — the one with real content, not the placeholder — and remove `folder.meta.yaml` from every other repo touching that folder. Items already deployed elsewhere under that path are unaffected; only the ACL file moves. See `thanx-ai/grid-shared`'s history for the cleanup this produced.

**How to avoid it going forward:** before scaffolding a new `folder.meta.yaml` (via `/grid:create` or `/grid:import`), check whether the folder already exists live with real grants — if so, don't declare it again in a new repo; just deploy the item and let the existing owner's file govern access.

## How to verify

For every `f/<team>/folder.meta.yaml`:

1. **`g/all: false`** grants workspace-wide read+run if you want it — but it's opt-in, not mandatory. Some folders (exec financials, HR/comp data) deliberately omit it so that *only* explicitly-listed owners have any access at all; forcing `g/all` onto those would widen exposure they're specifically designed to withhold. `scripts/check-folder-perms.sh` warns (doesn't fail) when `g/all` is absent, and fails outright if `g/all: true` is ever committed (that grants write to every workspace user).
2. The team group must be present with `true` if that team should be able to write. **Canonical group names are per-workspace** — most callers target the default `thanx` workspace, but `cube-grid` targets `exec` and `talent-review` targets `hr`, each with their own group namespace:

   | Workspace | Canonical groups |
   |---|---|
   | `thanx` (default) | `g/engineering`, `g/success`, `g/product`, `g/design`, `g/operations`, `g/onboarding`, `g/support`, `g/finance`, `g/exec`, `g/marketing`, `g/sales` |
   | `exec` | `g/exec` |
   | `hr` | `g/people_ops` |

   Most of the `thanx`-workspace groups are SCIM-synced from Google Workspace; `g/operations` and `g/success` are Windmill-native (created directly in Windmill, not SCIM) — see the incident below for why that distinction mattered. Keep this table in sync with `canonical_groups` in `scripts/check-folder-perms.sh` (which reads it per-workspace) — add a new workspace/group in the same PR that adds it to a `folder.meta.yaml`.
3. The `true`/`false` semantics are: `true` = read + **write**, `false` = read-only (still includes run).

Quick local check before pushing (defaults to the `thanx` workspace; pass another as `$1` if this caller targets one):

```bash
scripts/check-folder-perms.sh          # thanx
scripts/check-folder-perms.sh exec     # cube-grid
scripts/check-folder-perms.sh hr       # talent-review
```

## Folder ACL drift: a group grant made in the Windmill UI gets silently reverted

`folder.meta.yaml`'s `extra_perms` is re-`PUT` in full on **every** master deploy, of **anything** — not just when this folder's file changes. See [`deploy-full-inventory.md`](./deploy-full-inventory.md): the repo is the source of truth on every deploy, by design, so a workspace-side (UI) edit to anything the full-inventory push re-asserts gets reverted on the next deploy. Folder ACLs are one of the "simpler types" that doc calls out as fully re-`PUT` each time (alongside `resource`, `variable`, `schedule`).

**Why this bit us.** An admin granted `g/Operations` and `g/Success` write access to `f/operations` and `f/success` directly in the Windmill UI, to unblock two teams. The repo's committed groups for those folders were (and remained) `g/operations` and `g/customer_success` — different names, and in the operations case, different *case* (Windmill/SCIM group names are case-sensitive, so `g/Operations` and `g/operations` are two unrelated groups, the same trap as confusing `g/exec` with an unrelated same-named "Exec workspace" group). Compounding it: `g/customer_success` was never actually provisioned as a real group at all — the folder's write grant had been a no-op since the folder was scaffolded, and the two real, actively-used groups (`Operations` and `Success`, with real members and admins) only ever existed under the capitalized, uncommitted names.

The UI grant *had* actually been committed once before, in a different repo — `merchant-operations-dashboard` committed `g/Success: true` to its own `f/success/folder.meta.yaml` two months earlier ("align folder.meta.yaml with live Windmill state"). It didn't matter: that repo's grant was itself only one of two competing declarations of `f/success` (see the section above), and it never fixed the capitalization or the dead `g/customer_success` in the *other* declaring repo, `grid-shared`. Every deploy of either repo kept re-asserting its own (partially wrong) version. The admin had no way to know this would happen and re-added the same UI-only grant a month later, expecting it to stick.

**Resolution.** Rather than rename the live UI-managed groups (Windmill has no rename endpoint — `name` is the group's primary key; `POST /groups/update/:name` only rewrites `summary`), we created new lowercase groups (`g/operations`, `g/success`) with identical membership and admins to the capitalized originals, then pointed the real owning repo's `folder.meta.yaml` at them (see the section above for which repo that is per folder). The old capitalized `Operations`/`Success` groups are kept temporarily (not deleted) until the new groups are confirmed working, then retired.

**How to avoid it going forward**: any folder ACL change — a new group, a case fix, extending write access — goes through a PR editing `folder.meta.yaml`, the same as any other Grid item. Never grant folder permissions directly in the Windmill UI; treat that as scratch/debugging only, and expect it to be wiped on the next deploy. If the intended group doesn't match the canonical table above, that's a sign the canonical group is wrong (fix `folder.meta.yaml` to use it) or a genuinely new group is needed (add it to the table in this doc and to `scripts/check-folder-perms.sh` in the same PR).

## Related

- Workspace-wide visibility expansion (this commit): everything in `f/*/` is now `g/all: false`.
- `g/all: false` includes **run**, not just read — anyone can manually trigger jobs. Side-effecting work (Slack, Salesforce, outbound webhooks) needs `suspend` approval gates; see CLAUDE.md "Approval / suspend".
- CI checks folder.meta.yaml shape in two layers: `scripts/check-folder-perms.sh` is a fast, static, per-workspace check of key names/shape (catches a wrong-case or made-up group before merge, and rejects `g/all: true`). `scripts/check-folder-groups-live.sh` queries the actual live workspace (`groups/get`, `users/list`) to confirm every referenced group/user really exists — this is the check that would have caught the original incident, since `g/customer_success` was already on the canonical list the static check validates against and still didn't exist. The live check requires `WMILL_READ_TOKEN` with `groups:read`/`users:read` scopes; it passes with a warning if the secret isn't configured, same as `check-variable-references.sh`.

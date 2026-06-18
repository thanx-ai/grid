# Match the access control to the trust boundary: folder perms by default, workspace isolation only to exclude an admin

The Grid has four nested trust boundaries. Pick the cheapest one that excludes the audience you actually need to exclude — escalating "to be safe" buys operational overhead, not security, because the next rung up often doesn't block who you'd assume.

## The ladder (each rung defeats the one above it)

```
folder permissions  → blocks regular workspace members         ← default
workspace isolation → also blocks admins of OTHER workspaces
separate instance   → also blocks instance superadmins
off-platform        → also blocks Thanx eng / direct DB access
```

Verified against Windmill EE docs (grid.thanx.com is EE; checked 2026-06):

- **Workspace admins disregard ACLs.** Per the docs, "Admins of a workspace ... can read and write over everything within the workspace, disregarding ACLs." A folder ACL never hides anything from a workspace admin.
- **Superadmins admin every workspace.** "By default, superadmins have access to all workspaces as admins." A separate workspace on the *same instance* does **not** hide content from instance superadmins.
- **DB / infra access sits below all of it.** Folders and workspaces are just rows in the same Postgres. Job results, app state, and logs are stored **plaintext**; only secret *variables* are encrypted at rest (and the decryption key lives in instance config). Anyone with prod DB / backup / host access reads everything regardless of any Windmill ACL — so a dashboard can never hide its computed values from someone who can crawl the DB. If the source data already lives somewhere eng can query, the Grid is downstream of that exposure, not the cause of it.

## Decision rule

- **Folder permissions** (`f/<scope>/folder.meta.yaml`, omit `g/all` to restrict to a group) — use when the audience to exclude is regular, non-admin workspace members. This is the **default** and covers most dept-owned content and even most Exec/HR dashboards.
- **Workspace isolation** (a separate workspace on the same instance) — escalate **only** when a specific person who is or will be a workspace admin must not see the content, **and** won't be a superadmin or member of the isolated workspace. If you can't name that person, you don't need it. Cost: a separate deploy token in separate repo secrets, separate member management, and **no cross-workspace code reuse** (workspaces don't share folders or resources, so shared loaders/components must be duplicated).
- **Separate instance / off-platform** — required when the requirement is "Thanx eng, superadmins, or anyone with DB access must not see this." Neither folder perms nor same-instance workspace isolation achieves this.

## Two habits that make folder perms strong enough

1. **Keep the workspace-admin roster minimal.** This closes the folder mechanism's only real gap (admin bypass), and is good hygiene regardless. If the admin set is already broad and can't be trimmed, *that* is the trigger to isolate the workspace — not a vague desire for "more security."
2. **Set `g/all` deliberately.** Omit it to restrict to a group; `g/all: false` for workspace-wide read+run. Drift here is the silent failure mode — see [`folder-perms.md`](./folder-perms.md).

## Related

- [`folder-perms.md`](./folder-perms.md) — the `folder.meta.yaml` ACL shape and the `g/all` gotcha that this rule's "set `g/all` deliberately" habit points back to.

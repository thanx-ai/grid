---
name: promote
description: Flip a team repo from `u/<username>/` mode to `f/<dept>/` mode. Rewrites `wmill.yaml`, scaffolds `f/<dept>/folder.meta.yaml`, renames items in the Windmill workspace via the API, and opens a PR against the team repo's default branch. Use when the user says "promote", "graduate", "share with the team", or "move this from personal to team-scoped".
---

# promote

Promotion is the act of taking a team repo that's been deploying to `u/<username>/` and flipping it to deploy to `f/<dept>/` instead. The repo stays — its content moves namespaces.

**This is a destructive operation on the live Windmill workspace.** Renaming items via the API is not a snapshot — the old paths cease to exist. Get explicit user confirmation before executing Step 4.

## When NOT to use

- This repo already deploys to `f/<dept>/` — read `wmill.yaml`'s `includes:` to confirm. There's nothing to promote.
- This is `thanx-ai/grid` or `thanx-ai/grid-examples` — those are meta/reference repos and aren't user-namespace bootstrappable.
- The user wants to share with one specific person, not a department — Windmill doesn't have per-user ACLs beyond `u/<them>/`. They'd need to either add the person to a SCIM group or run a personal deploy.

## Step 1: Read current state

```bash
test -f wmill.yaml || { echo "no wmill.yaml — run /thanx-grid:grid-setup first"; exit 1; }
grep -A2 "^includes:" wmill.yaml
git remote get-url origin
git branch --show-current
```

Parse the `includes:` line. It should be `u/<username>/**`. Extract `<username>` and store as `$WMILL_USER`. If `includes:` is already `f/<dept>/**`, stop and tell the user the repo is already team-scoped.

## Step 2: Ask which department

```text
Which f/<dept>/ should this repo promote to?
```

Show the same list grid-setup uses: `engineering`, `product`, `design`, `success`, `operations`, `onboarding`, `support`, `finance`, `exec`, `marketing`, `sales`, `agents`, `scheduled`.

**Reject `f/shared/`** — admin-only.

Store as `$WMILL_DEPT`.

Confirm the user is in the write group for that dept. They can check at `grid.thanx.com` → bottom-left menu → Groups. If they're not in `g/<WMILL_DEPT>`, warn that they'll be able to push the YAML grant but won't have write access to the folder until they're added to the SCIM group.

## Step 3: Inventory the items to rename

List what's deployed under `u/<WMILL_USER>/` so the user can confirm scope:

```bash
WMILL_BASE_URL="https://grid-origin.thanx.com"
# User must have a wmill workspace configured locally; if not, walk them
# through `wmill workspace add` first.
wmill script list --workspace thanx --base-url "$WMILL_BASE_URL" | grep "^u/$WMILL_USER/" || true
wmill flow list --workspace thanx --base-url "$WMILL_BASE_URL" | grep "^u/$WMILL_USER/" || true
wmill app list --workspace thanx --base-url "$WMILL_BASE_URL" | grep "^u/$WMILL_USER/" || true
```

Show the user the full list. **Confirm** they want every item renamed before proceeding. Anything they don't want promoted should be deleted from `u/` first via the Windmill UI (or skipped — but partial promotion leaves dangling references; better to delete or rename uniformly).

## Step 4: Rename in the Windmill workspace (destructive)

For each item, call the Windmill API to move `u/<WMILL_USER>/<name>` → `f/<WMILL_DEPT>/<name>`. **Ask for explicit confirmation before this step.**

```bash
# $WMILL_TOKEN must have write scopes on f/<WMILL_DEPT>/. The user pastes
# it interactively — never read from `wmill workspace whoami` or any
# config file in a way that exposes the value to logs.
for item in $items; do
  # Scripts:
  curl -fsS -X POST "$WMILL_BASE_URL/api/w/thanx/scripts/p/u/$WMILL_USER/$item/move" \
    -H "Authorization: Bearer $WMILL_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"f/$WMILL_DEPT/$item\"}"
  # Flows: /flows/p/.../move with same body shape
  # Apps:  /apps/p/.../move with same body shape
done
```

If any rename fails (permissions, name collision in target folder, etc.), stop and surface the error. Do not continue with the repo-side updates if the workspace state is partially renamed — the next deploy from the team repo would attempt to recreate at the new path while the old path still exists.

## Step 5: Update `wmill.yaml`

```yaml
defaultTs: bun
includes:
  - f/<WMILL_DEPT>/**
excludes:
  - "**/node_modules/**"
  - "**/dist/**"
codebases: []
skipVariables: false
skipResources: false
skipResourceTypes: true
skipSecrets: true
includeSchedules: true
includeTriggers: true
includeUsers: false
includeGroups: false
includeSettings: false
includeKey: false
```

## Step 6: Move files in the repo

The repo's on-disk layout mirrors the Windmill namespace. Move every `u/<WMILL_USER>/*` to `f/<WMILL_DEPT>/*`:

```bash
mkdir -p f/$WMILL_DEPT
git mv u/$WMILL_USER/* f/$WMILL_DEPT/
rmdir u/$WMILL_USER 2>/dev/null
rmdir u 2>/dev/null
```

If any internal references between scripts use absolute paths like `wmill.runScript("u/<user>/foo", ...)`, **rewrite them** to `f/<dept>/foo`:

```bash
grep -rln "u/$WMILL_USER" f/ | while read -r file; do
  sed -i "" "s|u/$WMILL_USER/|f/$WMILL_DEPT/|g" "$file"
done
```

(`sed -i ""` is BSD/macOS; use `sed -i` on GNU.)

## Step 7: Scaffold `f/<dept>/folder.meta.yaml`

If `f/$WMILL_DEPT/folder.meta.yaml` doesn't already exist, write:

```yaml
summary: <Dept> team-shared scripts, flows, and apps
display_name: <WMILL_DEPT>
extra_perms:
  admin@windmill.dev: true
  g/all: false
  g/<WMILL_DEPT>: true
owners:
  - admin@windmill.dev
```

For `success`, use `g/customer_success: true` until the SCIM rename ships.

## Step 8: Update `.github/workflows/grid.yml`

Change the `includes:` input in the deploy job from `u/<WMILL_USER>/**` to `f/<WMILL_DEPT>/**`:

```yaml
deploy:
  if: github.ref == 'refs/heads/master'
  needs: ci
  uses: thanx-ai/grid/.github/workflows/deploy.yml@v0.1.0
  with:
    includes: "f/<WMILL_DEPT>/**"
  secrets:
    WINDMILL_DEPLOY_TOKEN: ${{ secrets.WINDMILL_DEPLOY_TOKEN }}
```

## Step 9: Commit and PR

```bash
git checkout -b promote/u-to-f-$WMILL_DEPT
git add -A
git commit -m "Promote: u/$WMILL_USER/ → f/$WMILL_DEPT/

Workspace items have been renamed via the Windmill API. Repo now deploys
to f/$WMILL_DEPT/ on merge.

Co-Authored-By: Claude <noreply@anthropic.com>"
git push -u origin promote/u-to-f-$WMILL_DEPT
gh pr create --title "Promote: u/$WMILL_USER/ → f/$WMILL_DEPT/" --body "$(cat <<'EOF'
## Summary

Flips this repo from personal (\`u/$WMILL_USER/\`) to team-shared (\`f/$WMILL_DEPT/\`). Workspace items have already been renamed via the Windmill API — this PR aligns the repo with the new namespace.

## What changed

- \`wmill.yaml\` \`includes:\` → \`f/$WMILL_DEPT/**\`
- \`.github/workflows/grid.yml\` deploy \`includes:\` updated
- All files moved from \`u/$WMILL_USER/\` to \`f/$WMILL_DEPT/\`
- \`f/$WMILL_DEPT/folder.meta.yaml\` scaffolded (if missing)
- Internal \`u/$WMILL_USER/\` references rewritten to \`f/$WMILL_DEPT/\`

## Test plan

- [ ] Local dry-run: \`wmill sync push --workspace thanx --base-url https://grid-origin.thanx.com\` shows zero changes (workspace already updated)
- [ ] After merge: deploy workflow runs cleanly
- [ ] Verify items are reachable at the new \`f/$WMILL_DEPT/\` paths

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Return the PR URL to the user.

## Step 10: Tell the user what's next

> Promotion complete (pending PR merge). Once merged:
>
> - The deploy workflow will run as a no-op (workspace already reflects the new namespace).
> - Shareable URLs change: an app previously at `https://grid.thanx.com/apps/get/u/$WMILL_USER/<name>` is now at `https://grid.thanx.com/apps/get/f/$WMILL_DEPT/<name>`. Update any bookmarks or links.
> - Anyone with `wmill` configured can run your scripts now (workspace-wide read+run). Write access is restricted to `g/$WMILL_DEPT`.

## Edge case: rename fails partway through Step 4

If 3 of 5 items rename successfully and the 4th fails (e.g. permission denied), **do not proceed**. The workspace is in a mixed state. Options:

1. **Roll back the renames** — call the same `/move` endpoint with the old path as the destination to undo each successful rename. Then surface the original error to the user.
2. **Resolve the permission issue first** (e.g. wait for SCIM group membership to propagate, then retry).

Never leave the workspace partially promoted while you commit repo changes — the next CI deploy will try to delete the still-`u/`-scoped items because they're no longer in the `includes:` pattern.

## Edge case: name collision in target folder

If `f/<WMILL_DEPT>/<name>` already exists in the workspace, the `/move` call fails. Ask the user whether to overwrite (manually delete the conflict first), rename their item before promoting (call `/move` with a new name), or skip that item.

## Edge case: items reference variables/resources at `f/shared/`

These keep working post-promotion — variables at `f/shared/` are workspace-wide-readable. **No path rewrite needed for `f/shared/` references**, only for `u/<WMILL_USER>/` references.

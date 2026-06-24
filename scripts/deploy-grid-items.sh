#!/usr/bin/env bash
# Deploy the Grid: push every deployable f/** item in the repo, one at a
# time, on every master deploy.
#
# Usage:
#   scripts/deploy-grid-items.sh
#
# Required env vars:
#   WMILL_BASE_URL         e.g. https://grid-origin.thanx.com
#   WMILL_WORKSPACE        the target workspace name (e.g. thanx)
#   WINDMILL_DEPLOY_TOKEN  API token with push scopes
#
# We push the FULL inventory every deploy rather than a commit-range diff.
# `wmill <type> push` content-hashes each item and no-ops the unchanged
# ones, so a full push is cheap, and it makes a missed deploy self-heal: an
# item that never reached the workspace (CI was broken when it landed, or an
# earlier deploy skipped it) is pushed on the next deploy with no
# special-casing. See claude/rules/deploy-full-inventory.md.
#
# Thin wrapper: list-grid-items.sh enumerates the inventory in `wmill push`
# dependency order, push-grid-items.sh runs the actual per-item push loop.
#
# This deploy path intentionally does NOT use `wmill sync push`. See
# claude/rules/per-item-push-not-sync.md for why and for the verified
# CLI surface push-grid-items.sh loops over.

set -euo pipefail

: "${WMILL_BASE_URL:?WMILL_BASE_URL must be set}"
: "${WMILL_WORKSPACE:?WMILL_WORKSPACE must be set}"
: "${WINDMILL_DEPLOY_TOKEN:?WINDMILL_DEPLOY_TOKEN must be set}"

# Resolve script dir so we can invoke our siblings regardless of cwd.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Enumerate the full inventory, then push it. pipefail (set above) makes a
# failure in either stage fail the deploy.
bash "$here/list-grid-items.sh" | bash "$here/push-grid-items.sh"

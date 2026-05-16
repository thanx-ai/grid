#!/usr/bin/env bash
# Push every Grid item changed between two git refs, one at a time.
#
# Usage:
#   scripts/deploy-grid-items.sh <before-ref> <after-ref>
#
# Required env vars:
#   WMILL_BASE_URL         e.g. https://grid-origin.thanx.com
#   WMILL_WORKSPACE        the target workspace name (e.g. thanx)
#   WINDMILL_DEPLOY_TOKEN  API token with push scopes
#
# This script intentionally does NOT use `wmill sync push`. See
# claude/rules/per-item-push-not-sync.md for why and for the verified
# CLI surface this loops over.

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <before-ref> <after-ref>" >&2
  exit 64
fi

: "${WMILL_BASE_URL:?WMILL_BASE_URL must be set}"
: "${WMILL_WORKSPACE:?WMILL_WORKSPACE must be set}"
: "${WINDMILL_DEPLOY_TOKEN:?WINDMILL_DEPLOY_TOKEN must be set}"

before="$1"
after="$2"

# Resolve script dir so we can invoke our sibling regardless of cwd.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t entries < <(bash "$here/changed-grid-items.sh" "$before" "$after")

if [ "${#entries[@]}" -eq 0 ]; then
  echo "No Grid items changed in ${before}..${after} — nothing to deploy."
  exit 0
fi

echo "Will push ${#entries[@]} item(s):"
for entry in "${entries[@]}"; do
  printf '  %s\n' "$entry"
done
echo

wmill_common=(
  --workspace "$WMILL_WORKSPACE"
  --base-url  "$WMILL_BASE_URL"
  --token     "$WINDMILL_DEPLOY_TOKEN"
)

failed=()
for entry in "${entries[@]}"; do
  # Split the TAB-separated record. Empty arg2 is fine for app/script/folder.
  IFS=$'\t' read -r type arg1 arg2 <<<"$entry"

  echo "▶ wmill $type push $arg1${arg2:+ $arg2}"
  case "$type" in
    app)
      # `wmill app push` with a single arg walks the .raw_app/ dir and
      # infers the remote path from its location relative to wmill.yaml.
      wmill app push "$arg1" "${wmill_common[@]}" || failed+=("$entry")
      ;;
    folder)
      wmill folder push "$arg1" "${wmill_common[@]}" || failed+=("$entry")
      ;;
    script)
      wmill script push "$arg1" "${wmill_common[@]}" || failed+=("$entry")
      ;;
    flow|resource|variable|schedule|trigger)
      wmill "$type" push "$arg1" "$arg2" "${wmill_common[@]}" || failed+=("$entry")
      ;;
    *)
      echo "  ERROR: unknown item type '$type' from changed-grid-items.sh" >&2
      failed+=("$entry")
      ;;
  esac
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo
  echo "${#failed[@]} item(s) failed to push:" >&2
  for entry in "${failed[@]}"; do
    printf '  %s\n' "$entry" >&2
  done
  exit 1
fi

echo
echo "All ${#entries[@]} item(s) pushed."

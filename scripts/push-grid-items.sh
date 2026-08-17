#!/usr/bin/env bash
# Push pre-classified Grid item records (TAB-separated, read from stdin),
# one at a time, with `wmill <type> push`.
#
# Usage:
#   <producer> | scripts/push-grid-items.sh
# where <producer> emits the record shape from classify-grid-paths.sh:
#   <type>\t<arg1>[\t<arg2>]
#
# deploy-grid-items.sh feeds it the full f/** inventory. Kept as a separate
# stdin filter so the `wmill <type> push` call surface lives in exactly one
# place and the dependency-ordered records can be produced by any enumerator.
#
# Required env vars:
#   WMILL_BASE_URL         e.g. https://grid-origin.thanx.com
#   WMILL_WORKSPACE        the target workspace name (e.g. thanx)
#   WINDMILL_DEPLOY_TOKEN  API token with push scopes
#
# This script intentionally does NOT use `wmill sync push`. Each
# `wmill <type> push` is an upsert (overrides the remote item) and never
# deletes anything outside the pushed set. See
# claude/rules/per-item-push-not-sync.md for why and for the verified
# CLI surface this loops over.
#
# Records must already be in `wmill push` dependency order (folders, then
# runnables/data, then schedule/trigger) — this script pushes them in the
# order received and does not re-sort. The producer owns ordering.
#
# The CLI's exit code alone is not trustworthy: windmill-cli (version
# pinned by the wmill_version input in deploy.yml) has been observed to
# exit 0 even when the API rejected the push with a row-level-security
# violation (HTTP 400,
# `SqlErr: new row violates row-level security policy for table "..."`) —
# e.g. a folder write attempted by a user/group without ACL access to it.
# Left unchecked, that means a deploy can report all-green while an item
# silently never landed. Every push below is run through run_push, which
# greps the CLI's own output for that signature and fails the item
# regardless of exit code.

set -euo pipefail

: "${WMILL_BASE_URL:?WMILL_BASE_URL must be set}"
: "${WMILL_WORKSPACE:?WMILL_WORKSPACE must be set}"
: "${WINDMILL_DEPLOY_TOKEN:?WINDMILL_DEPLOY_TOKEN must be set}"

# Requires bash 4+ (ubuntu-latest runs bash 5). macOS system bash is 3.2 and
# lacks `mapfile` — run this under a modern bash (e.g. `brew install bash`)
# if invoking locally.
mapfile -t entries

if [ "${#entries[@]}" -eq 0 ]; then
  echo "No Grid items to push."
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

# Matches the API's row-level-security rejection message. Case-insensitive
# since we're grepping CLI-formatted output, not the raw JSON body.
rls_rejection_pattern='row-level security|SqlErr'

# Run a `wmill ... push` invocation, streaming its output live (so CI logs
# look exactly like they did before) while also capturing it to grep for
# an RLS rejection the CLI itself reported as success. Returns failure if
# either the exit code is non-zero OR the output matches the rejection
# pattern.
run_push() {
  local out status
  out="$(mktemp)"
  if "$@" 2>&1 | tee "$out"; then
    status=0
  else
    status=1
  fi
  if grep -Eiq "$rls_rejection_pattern" "$out"; then
    echo "  ERROR: CLI reported success (exit $status) but output matched an RLS rejection — treating as failed." >&2
    status=1
  fi
  rm -f "$out"
  return "$status"
}

failed=()
for entry in "${entries[@]}"; do
  # Skip blank lines defensively (a trailing newline from the producer
  # would otherwise become an empty record and trip the unknown-type arm).
  [ -z "$entry" ] && continue
  # Split the TAB-separated record. Empty arg2 is fine for app/script/folder.
  IFS=$'\t' read -r type arg1 arg2 <<<"$entry"

  echo "▶ wmill $type push $arg1${arg2:+ $arg2}"
  case "$type" in
    app)
      # `wmill app push` with a single arg walks the .raw_app/ dir and
      # infers the remote path from its location relative to wmill.yaml.
      run_push wmill app push "$arg1" "${wmill_common[@]}" || failed+=("$entry")
      ;;
    folder)
      run_push wmill folder push "$arg1" "${wmill_common[@]}" || failed+=("$entry")
      ;;
    script)
      run_push wmill script push "$arg1" "${wmill_common[@]}" || failed+=("$entry")
      ;;
    flow|resource|variable|schedule|trigger)
      run_push wmill "$type" push "$arg1" "$arg2" "${wmill_common[@]}" || failed+=("$entry")
      ;;
    *)
      echo "  ERROR: unknown item type '$type' from classify-grid-paths.sh" >&2
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

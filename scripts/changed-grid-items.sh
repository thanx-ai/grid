#!/usr/bin/env bash
# Classify the set of paths changed between two git refs into the
# arguments needed for `wmill <type> push` calls.
#
# Usage:
#   scripts/changed-grid-items.sh <before-ref> <after-ref>
#
# Output: one TAB-separated record per line, deduped and emitted in
# `wmill push` dependency order (folders first; then runnables and
# standalone data — script/app/flow/resource/variable; then the items
# that reference them — schedule/trigger):
#   <type>\t<arg1>[\t<arg2>]
# where the args match what `wmill <type> push` expects:
#   app       <local-path-to-.raw_app-dir>
#   script    <local-path-to-script-file>
#   flow      <local-path-to-flow.yaml>  <remote-path>
#   resource  <local-path>               <remote-path>
#   variable  <local-path>               <remote-path>
#   schedule  <local-path>               <remote-path>
#   trigger   <local-path>               <remote-path>
#   folder    <folder-name>
#
# Deletions are *not* emitted — by design. The deploy workflow only
# upserts items; removing an item from a project repo does not
# propagate to the Grid. See claude/rules/per-item-push-not-sync.md.
#
# Paths outside f/** are ignored — only items under the Grid namespace
# are deployable.

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <before-ref> <after-ref>" >&2
  exit 64
fi

before="$1"
after="$2"

# Zero SHA (initial push) — fall back to comparing against the after
# ref's parent. If after has no parent (root commit), there's nothing
# to diff against; emit empty and let the caller no-op.
zero_sha="0000000000000000000000000000000000000000"
if [ "$before" = "$zero_sha" ]; then
  if parent="$(git rev-parse --verify --quiet "$after^")"; then
    before="$parent"
  else
    exit 0
  fi
fi

# Both refs must be reachable from local history. If either isn't (e.g. a
# force-push rewrote `before` out of the tree), fail loud rather than
# silently producing an empty changeset — a silent no-op deploy on a
# force-push would skip every item the user actually intended to push.
for ref in "$before" "$after"; do
  if ! git cat-file -e "$ref" 2>/dev/null; then
    echo "ERROR: ref '$ref' is not reachable from local history." >&2
    echo "  This usually means a force-push rewrote it. Re-run the deploy" >&2
    echo "  workflow via workflow_dispatch, or push a no-op commit on master" >&2
    echo "  to reset the before-ref baseline." >&2
    exit 2
  fi
done

# --diff-filter=ACMRT: Added, Copied, Modified, Renamed, Type-changed.
# Deletions (D) and unmerged (U) are excluded — see per-item-push-not-sync.md.
# No `|| true` here: with both refs verified above, a non-zero exit from
# `git diff` is a real bug we want to surface, not swallow.
mapfile -t changed < <(git diff --name-only --diff-filter=ACMRT "$before" "$after" -- 'f/**')

# Process each path. We may emit multiple times for the same logical
# item (e.g. several files inside one .raw_app/); final sort -u dedupes.
emit() {
  # Use a real TAB (not the literal string) as field separator.
  local IFS=$'\t'
  printf '%s\n' "$*"
}

# Strip a known suffix from the basename to derive the remote_path. The
# remote_path lives at the same directory as the local file, with the
# suffix removed:
#   f/eng/foo.resource.yaml -> f/eng/foo
#   f/eng/widget.flow/flow.yaml -> f/eng/widget
remote_from_yaml_suffix() {
  local path="$1" suffix="$2"
  printf '%s\n' "${path%."$suffix"}"
}

for path in "${changed[@]}"; do
  case "$path" in
    # Apps: any file inside an *.raw_app/ directory — collapse to the
    # directory itself. `wmill app push <dir>` is the canonical form.
    f/*/*.raw_app/*)
      app_dir="${path%%.raw_app/*}.raw_app"
      emit app "$app_dir"
      ;;

    # Flows: any file inside an *.flow/ directory — push the flow.yaml.
    # `wmill flow push <flow.yaml> <remote-path>` is the canonical form.
    f/*/*.flow/*)
      flow_dir="${path%%.flow/*}.flow"
      flow_yaml="$flow_dir/flow.yaml"
      remote="${flow_dir%.flow}"
      emit flow "$flow_yaml" "$remote"
      ;;

    # Scripts: explicit .script.<lang> suffix. Highest-specificity match
    # for files that want to be unambiguously labelled as a script.
    f/*/*.script.ts | f/*/*.script.js | f/*/*.script.py | f/*/*.script.sh)
      emit script "$path"
      ;;

    # Bare scripts: .ts / .js / .py / .sh files at folder-root level
    # outside any .raw_app/ or .flow/ directory (those arms above match
    # first, so files inside them never reach this arm). This is the
    # canonical pattern for raw_app backends + their tests:
    #   f/<scope>/<name>.raw_app/...    (UI)
    #   f/<scope>/<name>_loader.ts      (backend the app calls)
    #   f/<scope>/<name>_loader_test.ts (deploy test, `// test: script/...`)
    # See thanx-ai/grid-shared CLAUDE.md "Apps + backends" for the docs
    # this enforces. Pre-2026-05-21 these were silently skipped, which
    # left loaders + tests undeployed and made `run-deploy-tests.sh` 404
    # on the first master push after CI was restored.
    f/*/*.ts | f/*/*.js | f/*/*.py | f/*/*.sh)
      emit script "$path"
      ;;

    # Resources, variables, schedules, triggers — file-based with a
    # known suffix. Remote path = local path minus the suffix.
    f/*/*.resource.yaml)
      remote="$(remote_from_yaml_suffix "$path" resource.yaml)"
      emit resource "$path" "$remote"
      ;;
    f/*/*.variable.yaml)
      remote="$(remote_from_yaml_suffix "$path" variable.yaml)"
      emit variable "$path" "$remote"
      ;;
    f/*/*.schedule.yaml)
      remote="$(remote_from_yaml_suffix "$path" schedule.yaml)"
      emit schedule "$path" "$remote"
      ;;
    f/*/*.trigger.yaml)
      remote="$(remote_from_yaml_suffix "$path" trigger.yaml)"
      emit trigger "$path" "$remote"
      ;;

    # Folder metadata — folder.meta.yaml controls perms / display.
    # `wmill folder push <name>` takes the folder name (the f/ segment).
    f/*/folder.meta.yaml)
      # Folder name is everything between "f/" and "/folder.meta.yaml",
      # possibly multi-segment (e.g. f/company/sub/folder.meta.yaml).
      rel="${path#f/}"
      name="${rel%/folder.meta.yaml}"
      emit folder "$name"
      ;;

    # Anything else under f/ — silently skip. wmill.yaml ignores files
    # it doesn't recognise (see claude/rules/flow-yaml-shape.md for the
    # silent-skip gotcha), and the lint job in ci.yml catches misnamed
    # raw_apps. Adding warnings here would compete with that.
    *)
      ;;
  esac
done | sort -u | awk -F'\t' '
  # `wmill <type> push` has a real dependency order; lexical-by-type
  # ordering (the old `sort -u` output) violates it and reds deploys:
  #   - a folder must exist before any item inside it is pushed;
  #   - schedule/trigger reference a runnable and `wmill schedule push`
  #     validates the target script_path exists, so they must come AFTER
  #     the script/app/flow they point at.
  # Assign a dependency tier per type, then stable-sort by (tier, record).
  # Within a tier there are no cross-deps the push validates, so lexical
  # order is purely for determinism. Unknown types default to tier 1 (the
  # middle), matching deploy-grid-items.sh, which errors on them anyway.
  BEGIN {
    rank["folder"]   = 0
    rank["script"]   = 1; rank["app"]     = 1; rank["flow"] = 1
    rank["resource"] = 1; rank["variable"] = 1
    rank["schedule"] = 2; rank["trigger"]  = 2
  }
  { r = ($1 in rank) ? rank[$1] : 1; printf "%d\t%s\n", r, $0 }
' | LC_ALL=C sort -t$'\t' -k1,1n -k2 -s | cut -f2-
# -k1,1n: primary key = the prepended numeric tier. -k2 (open-ended, NOT
# -k2,2): secondary key = the whole original record from field 2 onward,
# so within a tier records are ordered lexically by their full
# type+args — deterministic, not type-only. LC_ALL=C pins that to byte
# order so it's identical on macOS and Ubuntu. cut -f2- then drops the
# tier column, leaving the original <type>\t<arg1>[\t<arg2>] record.

#!/usr/bin/env bash
# Classify the set of paths changed between two git refs into the
# arguments needed for `wmill <type> push` calls.
#
# Usage:
#   scripts/changed-grid-items.sh <before-ref> <after-ref>
#
# Output: one TAB-separated record per line, sorted+deduped:
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

# --diff-filter=ACMRT: Added, Copied, Modified, Renamed, Type-changed.
# Deletions (D) and unmerged (U) are excluded — see per-item-push-not-sync.md.
mapfile -t changed < <(git diff --name-only --diff-filter=ACMRT "$before" "$after" -- 'f/**' || true)

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

    # Scripts: explicit .script.<lang> suffix. Anything else under f/
    # (raw .ts / .py without the marker) is treated as part of the
    # nearest .raw_app/ — caught by the *.raw_app/* arm above.
    f/*/*.script.ts | f/*/*.script.js | f/*/*.script.py | f/*/*.script.sh)
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
done | sort -u

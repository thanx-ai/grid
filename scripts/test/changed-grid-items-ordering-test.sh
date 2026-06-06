#!/usr/bin/env bash
# Test the dependency ordering of scripts/changed-grid-items.sh.
#
# `wmill <type> push` has a real dependency order: a folder must exist
# before items inside it, and schedule/trigger reference a runnable that
# must already exist. A plain `sort -u` orders records lexically by type
# (app, flow, folder, resource, schedule, script, trigger), which pushes
# schedule/trigger BEFORE the script/app/flow they reference and lands
# folder in the middle. That reds deploys and orphans schedules — see
# claude/rules/per-item-push-not-sync.md.
#
# This test builds a throwaway git repo, commits — in a single commit, the
# exact same-commit pattern that broke a production deploy — one item of
# every deployable type (folder, the full tier-2 runnable/data set, and
# the schedule + trigger that reference them), then asserts the emitted
# order respects the dependency tiers. Covering every tier-2 type means a
# typo in the awk rank table (e.g. bumping `resource` out of the middle
# tier) is caught here, not in a live deploy.
#
# Runs offline: it never touches a Windmill workspace, only git + the
# classifier script.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../changed-grid-items.sh"

if [ ! -f "$script" ]; then
  echo "FAIL: cannot find changed-grid-items.sh at $script" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
git init -q
git config user.email test@example.com
git config user.name test

# Baseline = git's empty tree, a constant every repo recognises. Diffing
# against it makes every committed path show up as Added, with no need for
# an empty root commit (which prints a cosmetic "ambiguous argument 'HEAD'"
# to stderr on the first commit). changed-grid-items.sh `git cat-file -e`s
# this ref and it always resolves.
before="$(git hash-object -t tree /dev/null)"

# A single commit adding, together, one item of every deployable type:
#   - folder metadata               (tier 0 — must push FIRST)
#   - script + its test, app, flow,
#     resource, variable            (tier 1 — runnables + standalone data)
#   - the script's schedule, a
#     trigger                       (tier 2 — reference runnables; push LAST)
mkdir -p f/eng/widget.raw_app f/eng/pipeline.flow
cat >f/eng/folder.meta.yaml <<'YAML'
summary: eng folder
YAML
echo 'export function main() {}' >f/eng/summary_email.ts
echo 'export function main() {}' >f/eng/summary_email_test.ts
echo '{}' >f/eng/widget.raw_app/app.yaml
echo 'summary: a flow' >f/eng/pipeline.flow/flow.yaml
cat >f/eng/conn.resource.yaml <<'YAML'
value:
  host: example.invalid
YAML
cat >f/eng/token.variable.yaml <<'YAML'
value: placeholder
YAML
cat >f/eng/summary_email_daily.schedule.yaml <<'YAML'
script_path: f/eng/summary_email
schedule: "0 0 * * *"
YAML
cat >f/eng/on_event.trigger.yaml <<'YAML'
script_path: f/eng/summary_email
YAML
git add -A
git commit -q -m "add script + schedule + folder together"
after="$(git rev-parse HEAD)"

out="$(bash "$script" "$before" "$after")"

echo "--- changed-grid-items.sh output ---"
printf '%s\n' "$out"
echo "------------------------------------"

# Helper: 1-based line number of the first record whose type field matches,
# or -1 if the type was never emitted.
type_pos() {
  local want="$1" n=0
  while IFS=$'\t' read -r type _; do
    n=$((n + 1))
    if [ "$type" = "$want" ]; then
      printf '%s\n' "$n"
      return 0
    fi
  done <<<"$out"
  printf '%s\n' "-1"
}

fail=0
check() { # check <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc" >&2
    fail=1
  fi
}

# Resolve the positions referenced by more than one assertion up front.
folder_pos="$(type_pos folder)"
script_pos="$(type_pos script)"
app_pos="$(type_pos app)"
schedule_pos="$(type_pos schedule)"
trigger_pos="$(type_pos trigger)"

# Sanity: every expected type was emitted at all. This must pass before the
# ordering assertions below are meaningful — type_pos returns -1 for a
# missing type, and -1 < N is trivially true, so an absent type would
# silently satisfy a "before" check. These guards rule that out.
for t in folder script app flow resource variable schedule trigger; do
  check "emitted a $t record" test "$(type_pos "$t")" -ne -1
done

# Bail out now if any type is missing: the ordering assertions below
# compare positions with -lt, and a missing type's -1 sentinel makes
# "-1 < N" trivially true — they would print a misleading PASS. The
# sanity failures above are the real story, so stop here.
if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "ordering test FAILED — expected record type(s) missing from output" >&2
  exit 1
fi

# Folder must be first.
check "folder is pushed first (before everything else)" \
  test "$folder_pos" -eq 1

# The core regression: every tier-1 runnable/data item before every
# tier-2 reference-holder. A rank-table typo on any of these is caught.
for runnable in script app flow resource variable; do
  rp="$(type_pos "$runnable")"
  check "$runnable is pushed BEFORE schedule" test "$rp" -lt "$schedule_pos"
  check "$runnable is pushed BEFORE trigger"  test "$rp" -lt "$trigger_pos"
done

# Folder strictly precedes its contents.
check "folder is pushed BEFORE the script inside it" \
  test "$folder_pos" -lt "$script_pos"
check "folder is pushed BEFORE the app inside it" \
  test "$folder_pos" -lt "$app_pos"

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "ordering test FAILED" >&2
  exit 1
fi

echo
echo "all ordering assertions passed"

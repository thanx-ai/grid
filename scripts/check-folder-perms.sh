#!/usr/bin/env bash
# Validate every f/**/folder.meta.yaml's extra_perms against the canonical
# group list for the target Windmill workspace — catch a typo'd or
# wrong-case group name (e.g. g/Operations instead of g/operations) before
# it merges.
#
# Why: folder ACLs are re-PUT from the repo on every master deploy (see
# claude/rules/deploy-full-inventory.md) — the repo always wins. That's by
# design for drift the repo caused. But it means a group grant made
# directly in the Windmill UI, under a name that doesn't match what's
# committed here, silently vanishes on the next deploy of anything, and
# nothing before this check told the deploying PR author that the name
# they typed doesn't match a real, known group. See
# claude/rules/folder-perms.md for the incident that motivated this.
#
# This check is static — it validates the *committed* file's key names
# against a hardcoded per-workspace list. It does not (and cannot) inspect
# what groups actually exist in Windmill; a canonical-but-nonexistent group
# (exactly what caused the original incident: g/customer_success was
# already on this list and still didn't exist) can only be caught by
# check-folder-groups-live.sh, which queries the real workspace. Run both —
# this one is the fast offline pre-check, that one is the real guardrail.
#
# Workspace-aware: callers can target workspaces other than the default
# "thanx" (e.g. cube-grid -> exec, talent-review -> hr). Pass the target
# workspace as $1, or set WMILL_WORKSPACE. Defaults to "thanx".
#
# Usage:
#   scripts/check-folder-perms.sh [workspace]
# (run from the repo root, or anywhere inside it — cds to the repo root)

set -euo pipefail

workspace="${1:-${WMILL_WORKSPACE:-thanx}}"

# Keep in sync with the per-workspace group lists in claude/rules/folder-perms.md.
# Every workspace also implicitly allows g/all (checked separately, see below).
case "$workspace" in
  thanx)
    canonical_groups=(
      g/engineering
      g/success
      g/product
      g/design
      g/operations
      g/onboarding
      g/support
      g/finance
      g/exec
      g/marketing
      g/sales
    )
    ;;
  exec)
    # cube-grid is the only known caller targeting this workspace today.
    canonical_groups=(
      g/exec
    )
    ;;
  hr)
    # talent-review is the only known caller targeting this workspace today.
    canonical_groups=(
      g/people_ops
    )
    ;;
  *)
    echo "::warning::check-folder-perms.sh has no canonical group list for workspace '$workspace' — skipping group-name validation (g/all-value and structural checks still run). Add this workspace's real group list to scripts/check-folder-perms.sh and claude/rules/folder-perms.md." >&2
    canonical_groups=()
    ;;
esac

is_canonical() {
  local candidate="$1" g
  for g in "${canonical_groups[@]}"; do
    [[ "$candidate" == "$g" ]] && return 0
  done
  return 1
}

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(git ls-files -- 'f/*/folder.meta.yaml' 2>/dev/null | sort)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No tracked folder.meta.yaml files found under f/. Nothing to check."
  exit 0
fi

problems=()
warnings=()

# Strip one layer of matching surrounding quotes (single or double) from a
# string, if present. Used so a quoted key ("g/all", 'g/Operations') is
# recognized the same as its unquoted form.
strip_quotes() {
  local s="$1"
  if [[ "$s" == \"*\" && "$s" == *\" ]]; then
    s="${s#\"}"; s="${s%\"}"
  elif [[ "$s" == \'*\' && "$s" == *\' ]]; then
    s="${s#\'}"; s="${s%\'}"
  fi
  printf '%s' "$s"
}

for file in "${files[@]}"; do
  # extra_perms is a flat map: grab every indented "key: value" line between
  # the "extra_perms:" header and the next top-level (unindented) *key*
  # line, e.g. "owners:". A flush-left *comment* does NOT end the block —
  # only a flush-left non-comment line does. (The original version of this
  # script treated any flush-left line, comments included, as the end of
  # the block, which let a flush-left "# ---- team groups ----" comment
  # silently hide every key after it from validation.)
  perms_block="$(awk '
    /^extra_perms:/ { in_block=1; next }
    in_block && /^[^[:space:]]/ && $0 !~ /^#/ { in_block=0 }
    in_block { print }
  ' "$file")"

  if [[ -z "$perms_block" ]]; then
    problems+=("$file: no extra_perms block found (every folder.meta.yaml needs one — see claude/rules/folder-perms.md)")
    continue
  fi

  saw_g_all=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Skip comment-only lines (leading whitespace then #).
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    raw_key="$(sed -E 's/^[[:space:]]*([^:]+):.*/\1/' <<<"$line" | sed -E 's/[[:space:]]+$//')"
    [[ -z "$raw_key" ]] && continue
    key="$(strip_quotes "$raw_key")"
    [[ -z "$key" ]] && continue

    value="$(sed -E 's/^[^:]+:[[:space:]]*//' <<<"$line" | sed -E 's/[[:space:]]*(#.*)?$//')"

    if [[ "$key" == "g/all" ]]; then
      saw_g_all=1
      if [[ "$value" == "true" ]]; then
        problems+=("$file: 'g/all: true' grants write access to every workspace user — if that's really intended, get explicit sign-off and consider whether a narrower grant would do instead")
      fi
      continue
    fi

    if [[ "$key" == g/* ]]; then
      if [[ ${#canonical_groups[@]} -gt 0 ]] && ! is_canonical "$key"; then
        problems+=("$file: '$key' is not a known group in the '$workspace' workspace (checked against the canonical list in claude/rules/folder-perms.md) — a wrong-case or made-up group name here gets silently wiped on the next deploy, see claude/rules/folder-perms.md")
      fi
      continue
    fi

    if [[ "$key" == u/* ]]; then
      # Individual-user grants (u/<username>) aren't validated here — this
      # check has no way to confirm a username exists without hitting the
      # live workspace. See check-folder-groups-live.sh, which does.
      continue
    fi

    # Anything else is expected to be a user email (e.g. admin@windmill.dev)
    # — not validated here, `wmill folder push` will reject a malformed one.
  done <<< "$perms_block"

  if [[ "$saw_g_all" -eq 0 ]]; then
    # Deliberately a warning, not a failure: claude/rules/folder-perms.md's
    # own rule #1 says g/all is required only "if you want workspace-wide
    # read+run" — some folders (e.g. exec financials, HR/comp data)
    # deliberately omit it so that only explicitly-listed owners have any
    # access at all. Making this a hard failure would force those folders
    # toward the exact grant they're designed to withhold.
    warnings+=("$file: no explicit g/all entry — fine if that's deliberate (a folder that should NOT be workspace-readable), otherwise add 'g/all: false' for workspace-wide read+run. See claude/rules/folder-perms.md.")
  fi
done

if (( ${#warnings[@]} > 0 )); then
  for w in "${warnings[@]}"; do
    echo "::warning::$w" >&2
  done
fi

if (( ${#problems[@]} > 0 )); then
  echo "::error::folder.meta.yaml ACL problems found (workspace: $workspace):" >&2
  for p in "${problems[@]}"; do
    echo "  - $p" >&2
  done
  exit 1
fi

echo "✅ All folder.meta.yaml extra_perms use known groups (workspace: $workspace)."

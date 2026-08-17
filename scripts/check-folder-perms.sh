#!/usr/bin/env bash
# Validate every f/**/folder.meta.yaml's extra_perms against the canonical
# group list — catch a typo'd or wrong-case group name (e.g. g/Operations
# instead of g/operations) before it merges.
#
# Why: folder ACLs are re-PUT from the repo on every master deploy (see
# claude/rules/deploy-full-inventory.md) — the repo always wins. That's by
# design for drift the repo caused. But it means a group grant made
# directly in the Windmill UI, under a name that doesn't match what's
# committed here, silently vanishes on the next deploy of anything, and
# nothing before this check told the deploying PR author that the name
# they typed doesn't match a real, known group. See
# claude/rules/folder-perms.md for the incident that motivated this
# (g/Operations / g/Success added via the UI, wiped by the next deploy).
#
# This check is static — it validates the *committed* file's key names
# against the known-good list, the same list documented in
# claude/rules/folder-perms.md. It does not (and cannot) inspect what
# groups actually exist in Windmill/SCIM; keeping this list in sync with
# folder-perms.md's list is a manual step. It also does not (and cannot)
# detect a UI-only grant that was never committed at all — that class of
# drift is prevented by process (grants go through this repo), not by CI.
#
# Usage:
#   scripts/check-folder-perms.sh
# (run from the repo root, or anywhere inside it — cds to the repo root)

set -euo pipefail

# Keep in sync with the "team group" list in claude/rules/folder-perms.md.
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
done < <(find f -type f -name 'folder.meta.yaml' 2>/dev/null | sort)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No folder.meta.yaml files found under f/. Nothing to check."
  exit 0
fi

problems=()

for file in "${files[@]}"; do
  # extra_perms is a flat map: grab every indented "key: true|false" line
  # between the "extra_perms:" header and the next top-level (unindented)
  # key, e.g. "owners:".
  perms_block="$(awk '
    /^extra_perms:/ { in_block=1; next }
    in_block && /^[^[:space:]]/ { in_block=0 }
    in_block { print }
  ' "$file")"

  if [[ -z "$perms_block" ]]; then
    problems+=("$file: no extra_perms block found (every folder.meta.yaml needs one — see claude/rules/folder-perms.md)")
    continue
  fi

  saw_g_all=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="$(sed -E 's/^[[:space:]]*([^:]+):.*/\1/' <<<"$line" | sed -E 's/[[:space:]]+$//')"
    [[ -z "$key" ]] && continue

    if [[ "$key" == "g/all" ]]; then
      saw_g_all=1
      continue
    fi

    if [[ "$key" == g/* ]]; then
      if ! is_canonical "$key"; then
        problems+=("$file: '$key' is not a known group (checked against the canonical list in claude/rules/folder-perms.md) — a wrong-case or made-up group name here gets silently wiped on the next deploy, see claude/rules/folder-perms.md")
      fi
      continue
    fi

    # Anything else is expected to be a user email (e.g. admin@windmill.dev)
    # — not validated here, `wmill folder push` will reject a malformed one.
  done <<< "$perms_block"

  if [[ "$saw_g_all" -eq 0 ]]; then
    problems+=("$file: extra_perms has no explicit g/all entry — see claude/rules/folder-perms.md ('g/all: false must be in extra_perms if you want workspace-wide read+run')")
  fi
done

if (( ${#problems[@]} > 0 )); then
  echo "::error::folder.meta.yaml ACL problems found:" >&2
  for p in "${problems[@]}"; do
    echo "  - $p" >&2
  done
  exit 1
fi

echo "✅ All folder.meta.yaml extra_perms use known groups."

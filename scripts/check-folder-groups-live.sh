#!/usr/bin/env bash
# Verify every g/<name> and u/<name> grant in every f/**/folder.meta.yaml
# actually exists in the live target Windmill workspace.
#
# Why this exists (and why check-folder-perms.sh alone isn't enough): that
# script validates a group name against a hardcoded "canonical" list — but
# the incident that motivated all of this was a group that was ALREADY on
# the documented canonical list and still didn't exist in the workspace
# (g/customer_success). A static string-match against a human-maintained
# list can never catch that class of bug; only asking the workspace itself
# can. This script is the real guardrail; check-folder-perms.sh is the fast
# offline pre-check that catches typos before you even push.
#
# Modeled on check-variable-references.sh: warn-and-pass if no token is
# configured (the guardrail becomes a real gate once WMILL_READ_TOKEN is
# added as a repo secret with groups:read + users:read scopes), hard-fail
# on 401/403 (wrong scopes, not "no token").

set -euo pipefail

WORKSPACE="${WMILL_WORKSPACE:-thanx}"
# Use the direct origin (bypasses Cloudflare). grid.thanx.com is proxied through
# Cloudflare for browser traffic; API callers (CI, deploy scripts) need the
# origin hostname or they hit Cloudflare Access challenges.
BASE_URL="${WMILL_BASE_URL:-https://grid-origin.thanx.com}"
TOKEN="${WMILL_READ_TOKEN:-${WINDMILL_DEPLOY_TOKEN:-}}"

if [[ -z "$TOKEN" ]]; then
  echo "::warning::WMILL_READ_TOKEN not set — skipping live group/user existence check."
  echo "::warning::To enable this guardrail: mint a token at grid.thanx.com (scopes: groups:read, users:read — variables:read/resources:read too if shared with check-variable-references.sh) and add it as the WMILL_READ_TOKEN repo secret."
  echo "::warning::See claude/rules/folder-perms.md."
  exit 0
fi

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

# Extract the extra_perms block the same way check-folder-perms.sh does
# (kept independent/duplicated rather than shared, matching this repo's
# existing convention of small self-contained scripts).
extract_perms_block() {
  awk '
    /^extra_perms:/ { in_block=1; next }
    in_block && /^[^[:space:]]/ && $0 !~ /^#/ { in_block=0 }
    in_block { print }
  ' "$1"
}

strip_quotes() {
  local s="$1"
  if [[ "$s" == \"*\" && "$s" == *\" ]]; then
    s="${s#\"}"; s="${s%\"}"
  elif [[ "$s" == \'*\' && "$s" == *\' ]]; then
    s="${s#\'}"; s="${s%\'}"
  fi
  printf '%s' "$s"
}

declare -A group_files   # group name -> space-separated list of files referencing it
declare -A user_files    # username -> space-separated list of files referencing it
# Tracked alongside the maps above rather than via ${#group_files[@]} —
# bash's nounset (-u) treats a never-populated associative array as unbound
# on some expansions, so we count distinct keys ourselves as we insert them.
group_count=0
user_count=0

for file in "${files[@]}"; do
  perms_block="$(extract_perms_block "$file")"
  [[ -z "$perms_block" ]] && continue

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    raw_key="$(sed -E 's/^[[:space:]]*([^:]+):.*/\1/' <<<"$line" | sed -E 's/[[:space:]]+$//')"
    [[ -z "$raw_key" ]] && continue
    key="$(strip_quotes "$raw_key")"

    if [[ "$key" == "g/all" ]]; then
      continue
    elif [[ "$key" == g/* ]]; then
      name="${key#g/}"
      [[ -z "${group_files[$name]+x}" ]] && group_count=$((group_count + 1))
      group_files["$name"]="${group_files[$name]:-} $file"
    elif [[ "$key" == u/* ]]; then
      name="${key#u/}"
      [[ -z "${user_files[$name]+x}" ]] && user_count=$((user_count + 1))
      user_files["$name"]="${user_files[$name]:-} $file"
    fi
  done <<< "$perms_block"
done

if [[ "$group_count" -eq 0 && "$user_count" -eq 0 ]]; then
  echo "No group/user grants found to verify."
  exit 0
fi

missing=()

# --- Groups: one GET per distinct group (list is typically small). ---------
for name in "${!group_files[@]}"; do
  result=$(curl -sS -w 'HTTP_STATUS:%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/w/$WORKSPACE/groups/get/$name")
  body="${result%HTTP_STATUS:*}"
  status="${result##*HTTP_STATUS:}"

  case "$status" in
    200)
      # Exists. Soft-warn (don't fail) if it has no members — a real group
      # with zero members is a currently-inert grant, same failure mode as
      # a nonexistent one but less certain to be a mistake (e.g. a group
      # provisioned ahead of headcount).
      if echo "$body" | grep -Eq '"members":[[:space:]]*\[\]' 2>/dev/null; then
        echo "::warning::g/$name (referenced in: ${group_files[$name]# }) exists in workspace '$WORKSPACE' but currently has 0 members — the grant is real but inert until someone's added."
      fi
      ;;
    404)
      missing+=("g/$name  (referenced in: ${group_files[$name]# })  — no such group in workspace '$WORKSPACE'")
      ;;
    401|403)
      echo "::error::Auth failed (HTTP $status) checking group '$name' — verify token scopes (groups:read)" >&2
      exit 1
      ;;
    *)
      missing+=("g/$name  (referenced in: ${group_files[$name]# })  (HTTP $status: ${body:-empty})")
      ;;
  esac
done

# --- Users: fetch the workspace user list once, check membership locally. --
if [[ "$user_count" -gt 0 ]]; then
  result=$(curl -sS -w 'HTTP_STATUS:%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/w/$WORKSPACE/users/list")
  body="${result%HTTP_STATUS:*}"
  status="${result##*HTTP_STATUS:}"

  case "$status" in
    200)
      for name in "${!user_files[@]}"; do
        if ! echo "$body" | grep -q "\"username\":\"$name\"" 2>/dev/null; then
          missing+=("u/$name  (referenced in: ${user_files[$name]# })  — no such user in workspace '$WORKSPACE'")
        fi
      done
      ;;
    401|403)
      echo "::error::Auth failed (HTTP $status) listing users — verify token scopes (users:read)" >&2
      exit 1
      ;;
    *)
      echo "::warning::Could not fetch user list (HTTP $status) — skipping u/* validation this run."
      ;;
  esac
fi

echo "Checked $group_count group(s) and $user_count user(s) against workspace '$WORKSPACE'."

if (( ${#missing[@]} > 0 )); then
  echo >&2
  echo "::error::Unresolved group/user grants in workspace '$WORKSPACE':" >&2
  for m in "${missing[@]}"; do
    echo "  - $m" >&2
  done
  echo >&2
  echo "Fix options:" >&2
  echo "  - Create the group/add the user in the Windmill workspace before merging." >&2
  echo "  - Or fix the typo/case in folder.meta.yaml if that's what happened." >&2
  echo "  - See claude/rules/folder-perms.md for the incident this check exists to prevent." >&2
  exit 1
fi

echo "✅ All referenced groups/users exist in workspace '$WORKSPACE'."

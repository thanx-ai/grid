#!/usr/bin/env bash
# Verify every literal wmill.getVariable("f/...") and wmill.getResource("f/...")
# path referenced under f/ resolves in the target workspace.
#
# Why: scripts crash at runtime — not at deploy — when they reference a
# variable/resource that doesn't exist. Raw apps surface that crash as a
# "Failed to load" banner, which looks like a frontend bug but isn't.
# See claude/rules/scaffold-getvariable-placeholders.md.
#
# Limitation: only matches *literal* path arguments. Template strings and
# variables computed at runtime (e.g. getVariable(`f/${env}/X`)) are
# silently skipped — there's nothing to verify statically.

set -euo pipefail

WORKSPACE="${WMILL_WORKSPACE:-thanx}"
# Use the direct origin (bypasses Cloudflare). grid.thanx.com is proxied through
# Cloudflare for browser traffic; API callers (CI, deploy scripts) need the
# origin hostname or they hit Cloudflare Access challenges.
BASE_URL="${WMILL_BASE_URL:-https://grid-origin.thanx.com}"
TOKEN="${WMILL_READ_TOKEN:-${WINDMILL_DEPLOY_TOKEN:-}}"

if [[ -z "$TOKEN" ]]; then
  # In CI: warn loudly and pass. The point of the guardrail is to prevent
  # the bug; we don't want to *block* every PR until someone provisions the
  # secret. Once WMILL_READ_TOKEN is added to the repo secrets, this
  # branch stops firing and the check becomes a real gate.
  #
  # Locally: same behaviour — warn and exit 0. If you want a hard failure
  # locally, set WMILL_READ_TOKEN explicitly.
  echo "::warning::WMILL_READ_TOKEN not set — skipping getVariable / getResource reference check."
  echo "::warning::To enable this guardrail: mint a token at grid.thanx.com (scopes: variables:read, resources:read) and add it as the WMILL_READ_TOKEN repo secret."
  echo "::warning::See claude/rules/scaffold-getvariable-placeholders.md and the CI/CD section of README.md."
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Extract: <kind> <path> per line, where kind is "Variable" or "Resource".
# Handles single- or double-quoted literal string args. Skips template strings.
# Split per-kind to keep the regex extraction straightforward across BSD/GNU.
extract_kind() {
  local fn="$1" label="$2"
  grep -rhoE \
    --include='*.ts' --include='*.py' --include='*.go' \
    "${fn}\(\s*[\"']f/[^\"']+[\"']" \
    f/ 2>/dev/null |
    grep -oE "[\"']f/[^\"']+[\"']" |
    tr -d "\"'" |
    awk -v label="$label" '{print label, $0}'
}

extract_refs() {
  { extract_kind getVariable Variable
    extract_kind getResource Resource
  } | sort -u
}

refs="$(extract_refs || true)"
if [[ -z "$refs" ]]; then
  echo "No literal getVariable / getResource references found under f/."
  exit 0
fi

missing=()
checked=0

while IFS=' ' read -r kind path; do
  [[ -z "$path" ]] && continue
  checked=$((checked + 1))
  if [[ "$kind" == "Variable" ]]; then
    endpoint="variables/exists"
  else
    endpoint="resources/exists"
  fi

  result=$(curl -sS -w 'HTTP_STATUS:%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/w/$WORKSPACE/$endpoint/$path")
  body="${result%HTTP_STATUS:*}"
  status="${result##*HTTP_STATUS:}"

  case "$status" in
    200)
      # The exists endpoint returns the JSON literal `true` or `false`.
      if [[ "$body" != "true" ]]; then
        missing+=("$kind  $path")
      fi
      ;;
    401|403)
      echo "::error::Auth failed (HTTP $status) checking $kind $path — verify token scopes (variables:read, resources:read)" >&2
      exit 1
      ;;
    *)
      missing+=("$kind  $path  (HTTP $status: ${body:-empty})")
      ;;
  esac
done <<< "$refs"

echo "Checked $checked literal getVariable / getResource references against $WORKSPACE."

if (( ${#missing[@]} > 0 )); then
  echo >&2
  echo "::error::Unresolved references in $WORKSPACE:" >&2
  for m in "${missing[@]}"; do
    echo "  - $m" >&2
  done
  echo >&2
  echo "Fix options:" >&2
  echo "  - Create the variable/resource in the Windmill workspace before merging." >&2
  echo "  - Or remove the call from the script if it was a scaffold placeholder." >&2
  echo "  - See claude/rules/scaffold-getvariable-placeholders.md." >&2
  exit 1
fi

echo "✅ All literal references resolve."

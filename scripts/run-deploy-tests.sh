#!/usr/bin/env bash
# Invoke every Windmill test script annotated with `// test:` / `# test:`
# against the target workspace and fail if any throw.
#
# Runs after `wmill sync push` in deploy.yml — by then the test scripts are
# deployed alongside the runnables they cover, so calling them via
# run_wait_result exercises the live workspace state. A test that throws
# returns non-2xx and fails this script (and therefore the deploy workflow).
#
# Convention:
#   - Test files live next to the runnable they cover, named <name>_test.ts.
#   - First line is the annotation, e.g. `// test: script/f/shared/load_cs_metrics`.
#   - The test exports `main()` and `throw`s on assertion failure.
#
# Test scripts must be idempotent and side-effect-free — they execute
# against the production workspace.

set -euo pipefail

WORKSPACE="${WMILL_WORKSPACE:-thanx}"
# Use the direct origin (bypasses Cloudflare). grid.thanx.com is proxied through
# Cloudflare for browser traffic; API callers (CI, deploy scripts) need the
# origin hostname or they hit Cloudflare Access challenges.
BASE_URL="${WMILL_BASE_URL:-https://grid-origin.thanx.com}"
TOKEN="${WINDMILL_DEPLOY_TOKEN:?need WINDMILL_DEPLOY_TOKEN env}"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Test discovery: any TS/Py file under f/ whose first non-blank line is a
# `test:` annotation comment.
tests=()
while IFS= read -r file; do
  first_line=$(grep -m1 -E '^\s*\S' "$file" || true)
  if [[ "$first_line" =~ ^[[:space:]]*(//|#)[[:space:]]*test: ]]; then
    tests+=("$file")
  fi
done < <(find f -type f \( -name '*.ts' -o -name '*.py' \) | sort)

if (( ${#tests[@]} == 0 )); then
  echo "No test scripts found. (Annotate a script with '// test: script/<path>' to add one.)"
  exit 0
fi

echo "Found ${#tests[@]} test script(s). Running against $WORKSPACE..."
echo

failed=()
for file in "${tests[@]}"; do
  # Map file path → Windmill script path. f/shared/foo_test.ts → f/shared/foo_test
  script_path="${file%.ts}"
  script_path="${script_path%.py}"
  echo "▶ $script_path"

  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT

  http_code=$(curl -sS -o "$tmp" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$BASE_URL/api/w/$WORKSPACE/jobs/run_wait_result/p/$script_path" \
    -d '{}')

  if [[ "$http_code" =~ ^2 ]]; then
    echo "  ✅ ok"
  else
    body=$(cat "$tmp")
    echo "  ❌ HTTP $http_code"
    echo "  $body" | sed 's/^/  /'
    failed+=("$script_path")
  fi
done

echo

if (( ${#failed[@]} > 0 )); then
  echo "::error::Deploy tests failed:" >&2
  for f in "${failed[@]}"; do
    echo "  - $f" >&2
  done
  exit 1
fi

echo "✅ All deploy tests passed."

#!/usr/bin/env bash
# Test scripts/push-grid-items.sh — specifically the run_push wrapper that
# catches a `wmill` CLI reporting success (exit 0) despite the API
# rejecting the write with a row-level-security violation.
#
# Asserts:
#   - a stubbed `wmill` that exits 0 but prints the RLS rejection text is
#     still treated as a failure (the exact bug this wrapper exists for);
#   - a stubbed `wmill` that exits 0 and prints ordinary success output
#     is treated as a success;
#   - a stubbed `wmill` that exits non-zero with no RLS text is still a
#     failure (the exit-code path still works, unchanged);
#   - benign strings containing "SqlErr"/"SQLError" as a substring (e.g. a
#     completely unrelated MySQL connection error, or an app path like
#     sqlerrors_dashboard.raw_app) do NOT get misclassified as an RLS
#     rejection.
#
# Runs offline: fakes the `wmill` binary via a PATH-prepended stub, never
# touches a real Windmill workspace.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../push-grid-items.sh"

if [ ! -f "$script" ]; then
  echo "FAIL: cannot find push-grid-items.sh at $script" >&2
  exit 1
fi

fail=0
check() { # check <description> <expected 0|1> <stdin-record> <wmill-stub-body>
  local desc="$1" expect="$2" record="$3" stub_body="$4"
  local bindir status=0
  bindir="$(mktemp -d)"
  cat >"$bindir/wmill" <<EOF
#!/usr/bin/env bash
$stub_body
EOF
  chmod +x "$bindir/wmill"

  printf '%s\n' "$record" | \
    PATH="$bindir:$PATH" \
    WMILL_BASE_URL=https://example.invalid \
    WMILL_WORKSPACE=thanx \
    WINDMILL_DEPLOY_TOKEN=fake \
    bash "$script" >/tmp/push-grid-items-test.out 2>&1 || status=$?

  if [ "$status" -eq "$expect" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (expected exit $expect, got $status)" >&2
    sed 's/^/    /' /tmp/push-grid-items-test.out >&2
    fail=1
  fi
  rm -rf "$bindir"
}

# --- Case 1: exit 0 but RLS text in output — still a failure ---------------
check "exit-0-with-RLS-text is treated as a failure" 1 \
  "$(printf 'script\tf/success/foo.ts')" \
  'echo "Pushing script..."
echo '"'"'Error: 400 SqlErr: new row violates row-level security policy for table "script"'"'"'
exit 0'

# --- Case 2: exit 0, ordinary success output — passes ----------------------
check "exit-0-clean-output is a success" 0 \
  "$(printf 'script\tf/eng/foo.ts')" \
  'echo "Pushed script f/eng/foo successfully."
exit 0'

# --- Case 3: non-zero exit, no RLS text — still a failure (exit-code path) -
check "non-zero-exit-clean is still a failure" 1 \
  "$(printf 'script\tf/eng/bar.ts')" \
  'echo "some unrelated error" >&2
exit 3'

# --- Case 4: benign "SqlErr"-like substrings are NOT misclassified --------
check "benign MySqlError/sqlerrors substrings are not misclassified" 0 \
  "$(printf 'script\tf/eng/baz.ts')" \
  'echo "npm install: MySqlError: connection timeout (unrelated, benign)"
echo "loading sqlerrors_dashboard.raw_app"
echo "Pushed script f/eng/baz successfully."
exit 0'

rm -f /tmp/push-grid-items-test.out

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "push-grid-items test FAILED" >&2
  exit 1
fi

echo
echo "all push-grid-items assertions passed"

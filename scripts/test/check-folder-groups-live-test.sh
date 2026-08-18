#!/usr/bin/env bash
# Test scripts/check-folder-groups-live.sh — the live-workspace guardrail
# that check-folder-perms.sh structurally cannot provide (a canonical group
# name that doesn't actually exist in the workspace, exactly what caused
# the incident this whole check-folder-* pair exists to prevent).
#
# Asserts:
#   - no WMILL_READ_TOKEN => warns and passes (doesn't block PRs before the
#     secret is provisioned);
#   - a group that 404s (doesn't exist) is a failure — the exact
#     g/customer_success incident;
#   - a typo'd user (u/zack vs the real u/zach) is a failure;
#   - a group that exists but has zero members is a warning, not a failure;
#   - a repo with no group/user grants at all is a no-op pass.
#
# Runs offline: fakes `curl` via a PATH-prepended stub returning canned
# HTTP-status-suffixed bodies (matching the real script's `curl -w
# 'HTTP_STATUS:%{http_code}'` — body first, then the status suffix, no
# separator — same shape actual curl produces). Never touches a real
# Windmill workspace.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../check-folder-groups-live.sh"

if [ ! -f "$script" ]; then
  echo "FAIL: cannot find check-folder-groups-live.sh at $script" >&2
  exit 1
fi

fail=0
check() { # check <description> <expected 0|1> <test-expr...>
  local desc="$1" expect="$2"; shift 2
  local status=0
  "$@" >/tmp/check-folder-groups-live-test.out 2>&1 || status=$?
  if [ "$status" -eq "$expect" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (expected exit $expect, got $status)" >&2
    sed 's/^/    /' /tmp/check-folder-groups-live-test.out >&2
    fail=1
  fi
}

seed_repo() { # seed_repo <dir>
  local dir="$1"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && git config user.email test@example.com && git config user.name test )
}

# Each `echo`/`printf` line below writes literal shell source (single
# quotes deliberate — no expansion wanted here, this is generating the
# *text* of the stub script, not evaluating it).
# shellcheck disable=SC2016
make_curl_stub() { # make_curl_stub <bindir> <case-body-lines...>
  local bindir="$1"; shift
  mkdir -p "$bindir"
  {
    echo '#!/usr/bin/env bash'
    echo 'url="${*: -1}"'
    echo 'case "$url" in'
    printf '%s\n' "$@"
    echo '*) printf "{}HTTP_STATUS:500" ;;'
    echo 'esac'
  } >"$bindir/curl"
  chmod +x "$bindir/curl"
}

# Runs the script in <dir>, with <bindir> prepended to PATH (for the curl
# stub) and WMILL_READ_TOKEN set, all inside a subshell so nothing leaks
# into the rest of this test run. Avoids fragile nested `bash -c "..."`
# string quoting for $PATH expansion.
run_with_stub() { # run_with_stub <dir> <bindir>
  (
    cd "$1" || exit 1
    PATH="$2:$PATH"
    export PATH
    export WMILL_READ_TOKEN=fake
    bash "$script"
  )
}

# --- Case 1: no token — warns and passes ------------------------------------
noToken="$(mktemp -d)"
seed_repo "$noToken"
mkdir -p "$noToken/f/success"
cat >"$noToken/f/success/folder.meta.yaml" <<'YAML'
extra_perms:
  g/all: false
  g/success: true
owners:
  - admin@windmill.dev
YAML
( cd "$noToken" && git add -A && git commit -q -m seed )
check "no token: warns and passes" 0 bash -c "cd '$noToken' && unset WMILL_READ_TOKEN WINDMILL_DEPLOY_TOKEN; bash '$script'"

# --- Case 2: dead group (the actual g/customer_success incident) — fails --
deadGroup="$(mktemp -d)"
seed_repo "$deadGroup"
mkdir -p "$deadGroup/f/success"
cat >"$deadGroup/f/success/folder.meta.yaml" <<'YAML'
extra_perms:
  g/all: false
  g/customer_success: true
owners:
  - admin@windmill.dev
YAML
( cd "$deadGroup" && git add -A && git commit -q -m seed )
bin1="$(mktemp -d)"
make_curl_stub "$bin1" '*/groups/get/customer_success) printf "{\"error\":\"not found\"}HTTP_STATUS:404" ;;'
check "dead canonical-but-nonexistent group is a failure" 1 run_with_stub "$deadGroup" "$bin1"

# --- Case 3: typo'd user (u/zack vs real u/zach) — fails --------------------
typoUser="$(mktemp -d)"
seed_repo "$typoUser"
mkdir -p "$typoUser/f/success"
cat >"$typoUser/f/success/folder.meta.yaml" <<'YAML'
extra_perms:
  g/all: false
  u/zack: true
owners:
  - admin@windmill.dev
YAML
( cd "$typoUser" && git add -A && git commit -q -m seed )
bin2="$(mktemp -d)"
make_curl_stub "$bin2" '*/users/list) printf "[{\"username\":\"zach\"},{\"username\":\"alexa\"}]HTTP_STATUS:200" ;;'
check "typo'd user (u/zack, real user is u/zach) is a failure" 1 run_with_stub "$typoUser" "$bin2"

# --- Case 4: real group, zero members — warning, not a failure -------------
zeroMembers="$(mktemp -d)"
seed_repo "$zeroMembers"
mkdir -p "$zeroMembers/f/success"
cat >"$zeroMembers/f/success/folder.meta.yaml" <<'YAML'
extra_perms:
  g/all: false
  g/success: true
owners:
  - admin@windmill.dev
YAML
( cd "$zeroMembers" && git add -A && git commit -q -m seed )
bin3="$(mktemp -d)"
make_curl_stub "$bin3" '*/groups/get/success) printf "{\"name\":\"success\",\"members\":[]}HTTP_STATUS:200" ;;'
check "real group with 0 members warns but passes" 0 run_with_stub "$zeroMembers" "$bin3"

# --- Case 5: no group/user grants at all — no-op pass -----------------------
noGrants="$(mktemp -d)"
seed_repo "$noGrants"
mkdir -p "$noGrants/f/company"
cat >"$noGrants/f/company/folder.meta.yaml" <<'YAML'
extra_perms:
  admin@windmill.dev: true
  g/all: false
owners:
  - admin@windmill.dev
YAML
( cd "$noGrants" && git add -A && git commit -q -m seed )
check "no group/user grants at all is a no-op pass" 0 bash -c "cd '$noGrants' && WMILL_READ_TOKEN=fake bash '$script'"

rm -rf "$noToken" "$deadGroup" "$typoUser" "$zeroMembers" "$noGrants" "$bin1" "$bin2" "$bin3" /tmp/check-folder-groups-live-test.out

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "check-folder-groups-live test FAILED" >&2
  exit 1
fi

echo
echo "all check-folder-groups-live assertions passed"

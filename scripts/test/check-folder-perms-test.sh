#!/usr/bin/env bash
# Test scripts/check-folder-perms.sh — the static validator for
# folder.meta.yaml's extra_perms.
#
# Asserts:
#   - a folder.meta.yaml using only canonical group names (+ g/all + an
#     admin email) passes;
#   - a wrong-case group name (g/Operations instead of g/operations, or
#     g/Success instead of g/success) is rejected — this is the exact
#     incident that motivated the script: see claude/rules/folder-perms.md;
#   - a folder.meta.yaml missing an explicit g/all entry is rejected;
#   - a repo with no folder.meta.yaml files at all is a no-op pass.
#
# Runs offline: builds a throwaway git repo, never touches a workspace.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../check-folder-perms.sh"

if [ ! -f "$script" ]; then
  echo "FAIL: cannot find check-folder-perms.sh at $script" >&2
  exit 1
fi

fail=0
check() { # check <description> <expected 0|1> <test-expr...>
  local desc="$1" expect="$2"; shift 2
  local status=0
  "$@" >/tmp/check-folder-perms-test.out 2>&1 || status=$?
  if [ "$status" -eq "$expect" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (expected exit $expect, got $status)" >&2
    sed 's/^/    /' /tmp/check-folder-perms-test.out >&2
    fail=1
  fi
}

seed_repo() { # seed_repo <dir>
  local dir="$1"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && git config user.email test@example.com && git config user.name test )
}

# --- Case 1: canonical groups only — passes -------------------------------
good="$(mktemp -d)"
seed_repo "$good"
mkdir -p "$good/f/operations" "$good/f/success"
cat >"$good/f/operations/folder.meta.yaml" <<'YAML'
summary: Operations tools
extra_perms:
  admin@windmill.dev: true
  g/all: false
  g/operations: true
owners:
  - admin@windmill.dev
YAML
cat >"$good/f/success/folder.meta.yaml" <<'YAML'
summary: Customer Success tools
extra_perms:
  admin@windmill.dev: true
  g/all: false
  g/success: true
owners:
  - admin@windmill.dev
YAML
( cd "$good" && git add -A && git commit -q -m seed )
check "canonical groups pass" 0 bash -c "cd '$good' && bash '$script'"

# --- Case 2: wrong-case group name (the actual incident) — rejected ------
badcase="$(mktemp -d)"
seed_repo "$badcase"
mkdir -p "$badcase/f/operations"
cat >"$badcase/f/operations/folder.meta.yaml" <<'YAML'
summary: Operations tools
extra_perms:
  admin@windmill.dev: true
  g/all: false
  g/Operations: true
owners:
  - admin@windmill.dev
YAML
( cd "$badcase" && git add -A && git commit -q -m seed )
check "wrong-case group name (g/Operations) is rejected" 1 bash -c "cd '$badcase' && bash '$script'"

# --- Case 3: wrong-case group name on the other folder — rejected -------
madeup="$(mktemp -d)"
seed_repo "$madeup"
mkdir -p "$madeup/f/success"
cat >"$madeup/f/success/folder.meta.yaml" <<'YAML'
summary: Customer Success tools
extra_perms:
  admin@windmill.dev: true
  g/all: false
  g/Success: true
owners:
  - admin@windmill.dev
YAML
( cd "$madeup" && git add -A && git commit -q -m seed )
check "wrong-case group name (g/Success) is rejected" 1 bash -c "cd '$madeup' && bash '$script'"

# --- Case 4: missing g/all — rejected --------------------------------------
noall="$(mktemp -d)"
seed_repo "$noall"
mkdir -p "$noall/f/sales"
cat >"$noall/f/sales/folder.meta.yaml" <<'YAML'
summary: Sales tools
extra_perms:
  admin@windmill.dev: true
  g/sales: true
owners:
  - admin@windmill.dev
YAML
( cd "$noall" && git add -A && git commit -q -m seed )
check "missing g/all is rejected" 1 bash -c "cd '$noall' && bash '$script'"

# --- Case 5: no folder.meta.yaml files at all — no-op pass -----------------
empty="$(mktemp -d)"
seed_repo "$empty"
mkdir -p "$empty/f"
( cd "$empty" && git add -A 2>/dev/null; git commit -q -m seed --allow-empty )
check "no folder.meta.yaml files is a no-op pass" 0 bash -c "cd '$empty' && bash '$script'"

rm -rf "$good" "$badcase" "$madeup" "$noall" "$empty" /tmp/check-folder-perms-test.out

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "check-folder-perms test FAILED" >&2
  exit 1
fi

echo
echo "all check-folder-perms assertions passed"

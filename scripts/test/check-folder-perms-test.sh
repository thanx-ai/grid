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
#   - a flush-left comment mid-block does NOT truncate parsing and hide a
#     wrong-case group from validation (this exact bug let g/Operations
#     pass silently in an earlier version of this script);
#   - a quoted key (e.g. "g/Operations") is recognized the same as its
#     unquoted form, in both directions (rejecting a bad quoted group,
#     and NOT falsely rejecting a validly-quoted "g/all");
#   - g/all: true (write access for the entire workspace) is flagged;
#   - a folder.meta.yaml missing g/all is a WARNING, not a failure — some
#     folders (exec financials, HR data) deliberately omit it;
#   - the canonical list is workspace-aware: a group valid in one
#     workspace but not the default is accepted when the right workspace
#     is passed, and rejected against the wrong one;
#   - a repo with no folder.meta.yaml files at all is a no-op pass.
#
# Runs offline: builds throwaway git repos, never touches a workspace.

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

# --- Case 4: missing g/all is a WARNING, not a rejection --------------------
noall="$(mktemp -d)"
seed_repo "$noall"
mkdir -p "$noall/f/exec"
cat >"$noall/f/exec/folder.meta.yaml" <<'YAML'
summary: Exec financials — deliberately no g/all
extra_perms:
  admin@windmill.dev: true
  g/exec: true
owners:
  - admin@windmill.dev
YAML
( cd "$noall" && git add -A && git commit -q -m seed )
check "missing g/all is a warning (passes)" 0 bash -c "cd '$noall' && bash '$script'"

# --- Case 5: g/all: true is flagged -----------------------------------------
allTrue="$(mktemp -d)"
seed_repo "$allTrue"
mkdir -p "$allTrue/f/success"
cat >"$allTrue/f/success/folder.meta.yaml" <<'YAML'
summary: Customer Success tools
extra_perms:
  admin@windmill.dev: true
  g/all: true
  g/success: true
owners:
  - admin@windmill.dev
YAML
( cd "$allTrue" && git add -A && git commit -q -m seed )
check "g/all: true is rejected" 1 bash -c "cd '$allTrue' && bash '$script'"

# --- Case 6: flush-left comment must not truncate the parsed block --------
flushcomment="$(mktemp -d)"
seed_repo "$flushcomment"
mkdir -p "$flushcomment/f/operations"
cat >"$flushcomment/f/operations/folder.meta.yaml" <<'YAML'
summary: Operations tools
extra_perms:
  g/all: false
# ---- team groups ----
  g/Operations: true
owners:
  - admin@windmill.dev
YAML
( cd "$flushcomment" && git add -A && git commit -q -m seed )
check "flush-left comment does not hide a bad key after it" 1 bash -c "cd '$flushcomment' && bash '$script'"

# --- Case 7: quoted keys are recognized in both directions -----------------
quotedBad="$(mktemp -d)"
seed_repo "$quotedBad"
mkdir -p "$quotedBad/f/operations"
cat >"$quotedBad/f/operations/folder.meta.yaml" <<'YAML'
summary: Operations tools
extra_perms:
  g/all: false
  "g/Operations": true
owners:
  - admin@windmill.dev
YAML
( cd "$quotedBad" && git add -A && git commit -q -m seed )
check "quoted bad-case group (\"g/Operations\") is rejected" 1 bash -c "cd '$quotedBad' && bash '$script'"

quotedGood="$(mktemp -d)"
seed_repo "$quotedGood"
mkdir -p "$quotedGood/f/success"
cat >"$quotedGood/f/success/folder.meta.yaml" <<'YAML'
summary: Customer Success tools
extra_perms:
  "g/all": false
  g/success: true
owners:
  - admin@windmill.dev
YAML
( cd "$quotedGood" && git add -A && git commit -q -m seed )
check "quoted \"g/all\" is recognized, not falsely flagged missing" 0 bash -c "cd '$quotedGood' && bash '$script'"

# --- Case 8: workspace-aware canonical list ---------------------------------
hrworkspace="$(mktemp -d)"
seed_repo "$hrworkspace"
mkdir -p "$hrworkspace/f/talent_review"
cat >"$hrworkspace/f/talent_review/folder.meta.yaml" <<'YAML'
extra_perms:
  u/karina: true
  g/people_ops: true
owners:
  - admin@windmill.dev
YAML
( cd "$hrworkspace" && git add -A && git commit -q -m seed )
check "g/people_ops rejected against default (thanx) workspace" 1 bash -c "cd '$hrworkspace' && bash '$script'"
check "g/people_ops accepted when hr workspace is passed" 0 bash -c "cd '$hrworkspace' && bash '$script' hr"

# --- Case 9: no folder.meta.yaml files at all — no-op pass -----------------
empty="$(mktemp -d)"
seed_repo "$empty"
mkdir -p "$empty/f"
( cd "$empty" && git add -A 2>/dev/null; git commit -q -m seed --allow-empty )
check "no folder.meta.yaml files is a no-op pass" 0 bash -c "cd '$empty' && bash '$script'"

rm -rf "$good" "$badcase" "$madeup" "$noall" "$allTrue" "$flushcomment" "$quotedBad" "$quotedGood" "$hrworkspace" "$empty" /tmp/check-folder-perms-test.out

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "check-folder-perms test FAILED" >&2
  exit 1
fi

echo
echo "all check-folder-perms assertions passed"

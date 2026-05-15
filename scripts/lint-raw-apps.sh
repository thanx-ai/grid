#!/usr/bin/env bash
# Lint every f/**/<name>.raw_app/ in the repo and fail if the esbuild
# bundle step emits any warnings.
#
# Why warnings-as-errors: `wmill app lint` exits 0 on esbuild warnings,
# but those warnings are how you discover that a frontend imports an
# export the runtime wmill virtual module doesn't expose — e.g.
# `wmill.loadCsMetrics(...)` when the real surface is
# `wmill.backend.loadCsMetrics({ lookbackDays: 30 })`. Those silently
# ship as runtime crashes. See claude/rules/raw-app-wmill-virtual.md.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

apps=()
while IFS= read -r line; do
  apps+=("$line")
done < <(find f -type d -name '*.raw_app' 2>/dev/null | sort)

if [[ ${#apps[@]} -eq 0 ]]; then
  echo "No raw apps found under f/. Nothing to lint."
  exit 0
fi

fail=0
for app in "${apps[@]}"; do
  echo
  echo "▶ Linting $app"
  log="$(mktemp)"
  trap 'rm -f "$log"' EXIT
  if ! wmill app lint "$app" 2>&1 | tee "$log"; then
    echo "::error file=$app::wmill app lint failed for $app"
    fail=1
    continue
  fi
  # Strip ANSI escapes, then look for esbuild warning markers.
  if sed -E $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E '\[WARNING\]' >/dev/null; then
    echo
    echo "::error file=$app::wmill app lint emitted esbuild warnings — treating as errors"
    echo "  Warnings often signal runtime breakage (e.g. an import the wmill"
    echo "  virtual module doesn't expose). Fix before merging."
    echo "  See claude/rules/raw-app-wmill-virtual.md for the common case."
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  echo
  echo "❌ Raw app lint failed. See per-app output above."
  exit 1
fi

echo
echo "✅ All raw apps lint clean."

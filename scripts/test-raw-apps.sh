#!/usr/bin/env bash
# Run `bun test` inside every f/**/<name>.raw_app/ that ships test files.
#
# Why this exists as its own runner: raw-app code CANNOT be covered by the
# `// test:` deploy tests. Those are pushed to Windmill and executed there
# (scripts/run-deploy-tests.sh), and app code imports the `./wmill` virtual
# module, which only exists while esbuild is bundling the app — there is no
# such module in a Windmill script runtime. So app logic had no automated
# check at all: `wmill app lint` proves the bundle builds, not that it is
# correct. Two filter bugs shipped in f/sales/franchise_intel.raw_app that way
# (an owner filter that rendered 458 rows for a rep who owned 4, and a default
# checkbox that made a chip unreachable), and 123 already-written tests in
# f/company/activation_dashboard.raw_app were protecting nothing because
# nothing ran them.
#
# Tests run LOCALLY here, in-process, with no Windmill and no network.
#
# See claude/rules/raw-app-tests.md.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

apps=()
while IFS= read -r line; do
  apps+=("$line")
done < <(find f -type d -name '*.raw_app' 2>/dev/null | sort)

if [[ ${#apps[@]} -eq 0 ]]; then
  echo "No raw apps found under f/. Nothing to test."
  exit 0
fi

# Test files inside an app dir, ignoring the installed tree.
find_tests() {
  find "$1" -path '*/node_modules' -prune -o -type f \
    \( -name '*_test.ts' -o -name '*_test.tsx' -o -name '*.test.ts' -o -name '*.test.tsx' \) \
    -print 2>/dev/null | sort
}

fail=0
tested=0
skipped=()

for app in "${apps[@]}"; do
  tests=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && tests+=("$line")
  done < <(find_tests "$app")

  if [[ ${#tests[@]} -eq 0 ]]; then
    skipped+=("$app")
    continue
  fi

  # A raw-app test must NOT carry the `// test:` annotation. Deploy-test
  # discovery is `find f -type f -name '*.ts'` with no prune, so an annotated
  # file in here would ALSO be picked up by run-deploy-tests.sh, pushed to
  # Windmill as a script, and fail there on the ./wmill import — a confusing
  # failure a long way from its cause. Catch it at the source instead.
  for t in "${tests[@]}"; do
    first_line=$(grep -m1 -E '^\s*\S' "$t" || true)
    if [[ "$first_line" =~ ^[[:space:]]*//[[:space:]]*test: ]]; then
      echo "::error file=$t::raw-app tests must not use the '// test:' annotation"
      echo "  That annotation means 'push me to Windmill and run me there', which"
      echo "  cannot work for app code importing ./wmill. Delete the annotation —"
      echo "  this runner finds the file by its *_test.ts name."
      fail=1
    fi
  done

  echo
  echo "▶ Testing $app"

  # Deps come from the app's own package.json. package-lock.json is committed
  # (see .gitignore in the caller repo) so `npm ci` is reproducible; fall back
  # to `npm install` for an app that has not generated a lock yet.
  if [[ -f "$app/package-lock.json" ]]; then
    if ! (cd "$app" && npm ci --silent); then
      echo "::error file=$app/package-lock.json::npm ci failed for $app"
      fail=1
      continue
    fi
  elif ! (cd "$app" && npm install --silent); then
    echo "::error file=$app/package.json::npm install failed for $app"
    fail=1
    continue
  fi

  if (cd "$app" && bun test); then
    tested=$((tested + 1))
  else
    echo "::error file=$app::bun test failed for $app"
    fail=1
  fi
done

echo
for app in "${skipped[@]}"; do
  echo "– $app has no *_test.ts — not covered"
done

if [[ $fail -ne 0 ]]; then
  echo
  echo "❌ Raw app tests failed. See per-app output above."
  exit 1
fi

if [[ $tested -eq 0 ]]; then
  echo
  echo "No raw app ships tests yet. Nothing run."
  exit 0
fi

echo
echo "✅ Raw app tests passed in $tested app(s)."

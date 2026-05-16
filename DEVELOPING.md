# Developing `thanx-ai/grid`

This doc covers developing the reusable workflows and the `grid` Claude Code plugin **in this repo**. For working in a project repo against the Grid (the consumer side), see the rules under `claude/rules/` — they're copied into each project repo by the `setup` skill.

## Layout reminder

```
.claude-plugin/         # plugin manifest + marketplace.json
.github/workflows/
  ci.yml                # reusable: lint raw apps + check variable refs
  deploy.yml            # reusable: per-item `wmill <type> push` + deploy tests
  self-test.yml         # this repo's own CI (actionlint + shellcheck)
claude/rules/           # conventions (canonical; plugin copies to project repos)
scripts/                # bash scripts invoked by reusable workflows
skills/                 # plugin skills (setup, create, import)
```

## Local development

You need:

- `bash` (Linux/macOS — Windows via WSL).
- `shellcheck` — `brew install shellcheck` / `apt install shellcheck`.
- `actionlint` (optional but recommended) — `bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)`.
- `gh` — for testing workflow changes against `thanx-ai/grid-examples`.

You do **not** need:

- A local Windmill instance (the meta-repo doesn't run scripts itself).
- A `wmill` CLI install (it's installed inside the reusable workflows at runtime).

## Iterating on a reusable workflow

The self-test workflow (`self-test.yml`) only catches YAML and shell syntax errors. Semantic regressions (checkout pattern, ref resolution, lint behavior) only show up against a real caller. The dev loop:

1. Make the change on a feature branch in this repo.
2. Push the branch.
3. In `thanx-ai/grid-examples`, temporarily change the workflow ref from `@v0.1.0` (or `@v0`) to `@<your-branch>` in `.github/workflows/grid.yml`.
4. Open a PR in `grid-examples` against its master to trigger CI. Or push to a branch and `workflow_dispatch`.
5. Watch the run in the GitHub Actions tab.
6. When green, revert the workflow ref in `grid-examples` and merge your meta-repo PR.

```bash
# In thanx-ai/grid-examples:
sed -i '' 's|@v0\(.[0-9.]*\)\{0,1\}|@<your-branch>|g' .github/workflows/grid.yml
git checkout -b test-thanx-ai-grid-<your-branch>
git commit -am "test: pin to <your-branch>"
gh pr create --draft
```

After CI passes, **don't merge the grid-examples test PR** — close it and revert the ref locally.

## Iterating on the plugin

Plugin skills are markdown files under `skills/<name>/SKILL.md`. They're read by Claude Code at invocation time; no compilation step. To test locally:

1. Install the plugin from a local path (if your Claude Code supports it) or push to a branch and install from GitHub:
   ```text
   /plugin install thanx-ai/grid@<your-branch>
   ```
2. Open a fresh test repo (`mkdir /tmp/grid-test && cd /tmp/grid-test && git init`).
3. Run the skill: `/grid:setup`.
4. Inspect the scaffolded files and the bundled-rules copy.

If the skill produces wrong output, edit `skills/<name>/SKILL.md`, reinstall the plugin (`/plugin install ...` again), and re-test.

## Adding a new rule

Rules under `claude/rules/` are picked up by Claude at the start of every session in this repo, and copied into project repos by `setup` (Step 6).

To add one:

1. Write `claude/rules/<topic>.md` with YAML frontmatter (`title`, `tags`).
2. Lead with one sentence summarizing the rule.
3. Explain _why_ it bit us (what was confusing, what the buggy assumption was).
4. Explain _how to verify_ (a check, a command, a regex).
5. Decide whether it applies to project repos. If meta-repo-internal only (e.g. about workflow authoring), add the filename to the skip-list in `skills/setup/SKILL.md` Step 6.

## Bumping versions

After merging changes to `master`:

```bash
git checkout master && git pull
# Pick the right bump:
git tag v0.1.1                      # patch
# or:  git tag v0.2.0                # minor
# or:  git tag v1.0.0                # major (announce in #ai-help-desk first)

# Update the moving major tag (callers pinning @v0 follow this):
git tag -f v0
git push --tags --force-with-lease
```

After tagging, update the default `@v0.x.y` reference in `skills/setup/SKILL.md` Step 4 if the bump is minor or major (patches don't change the default).

## Style conventions

- Prose: "the Grid" lowercase-determiner. Exact strings preserved: `thanx-ai/grid` (repo), `thanx-grid` (plugin), `# The Grid` (README title).
- Slack: `#ai-help-desk` for all access/help/bug questions. There is no `#eng-platform` channel.
- GitHub: `@eng-platform` is the review team.
- Skill `description:` frontmatter must include trigger phrases the user is likely to type (e.g. "set up grid", "bootstrap grid in this repo").
- Workflow `description:` fields are required on every input and secret. Generated docs render them.

## Release checklist

Before tagging a new minor or major:

- [ ] CI green on master (`actionlint` + `shellcheck`)
- [ ] `grid-examples` workflow passes against the new ref
- [ ] Changelog entry (if applicable — TBD when we add one)
- [ ] Tag pushed
- [ ] `v0`/`v1` moving tag updated
- [ ] If breaking: announce in `#ai-help-desk` with the upgrade path

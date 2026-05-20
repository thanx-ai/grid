# `wmill sync` takes `--includes` (plural), not repeated `--include`

**Rule.** When narrowing the scope of `wmill sync push` or `wmill sync pull` on the command line, pass a single `--includes` flag whose value is a **comma-separated** list of glob patterns. The CLI does not accept a repeated `--include` (singular) flag — it errors out with `Unknown option "--include". Did you mean option "--includes"?` and exits non-zero before contacting the server.

This bit us when `.github/workflows/deploy.yml` shipped fourteen repeated `--include 'f/<team>/**'` lines (one per grid-owned folder). The previous wmill CLI silently accepted the unknown flag; **windmill-cli 1.700.1** treats it as a hard error, so every `master` push failed in the `Deploy to Grid` job before any `wmill sync` work happened. See run [25787264701](https://github.com/thanx-ai/grid-tooling/actions/runs/25787264701/job/75743601252).

The companion flag is `--extra-includes` (also plural, also comma-separated) — useful when you want to union additional patterns on top of the `includes:` list in `wmill.yaml` without rewriting it.

## How to verify

- `wmill sync push --help` lists `-i, --includes <patterns>` and `--extra-includes <patterns>`. There is no `--include` (singular) entry.
- Adding a new `f/<team>/` folder that should deploy? Append `,f/<team>/**` to the existing `--includes 'f/shared/**,…'` argument in `.github/workflows/deploy.yml`. Do **not** add a new `--include` line — that reintroduces the v1.700.1 failure mode.
- Multiple patterns in a single `--includes`: separate with a literal comma, **no surrounding spaces** (`'a/**,b/**'`, not `'a/**, b/**'`). Spaces are treated as part of the pattern and silently never match.
- Local one-off: `wmill sync push --yes --workspace thanx --includes 'f/agents/**'` — single pattern is just the degenerate case of the same flag.

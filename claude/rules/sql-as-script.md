# SQL-shaped content lands as a `*.script.ts` wrapper (not raw `.sql`)

**Rule.** When you have a SQL file (a query, a migration, a stored procedure) in a project repo that should run on the Grid, **wrap it in a `*.script.ts` that calls a Windmill DB resource**. Don't try to ship the bare `.sql` file as a Grid item via the deploy workflow.

> **First ask whether you need a DB resource at all.** For read-only Snowflake (`ANALYTICS.*`) or read-replica analytics, query **through Keystone** instead — no service account, no `c_snowflake` resource, PII masking + audit for free. See [`keystone-data-access.md`](./keystone-data-access.md). The `Resource<"...">` pattern below is for cases Keystone can't serve (a warehouse it doesn't proxy, or writes).

This is interim guidance — Windmill natively supports SQL script languages (PostgreSQL, MySQL, MS SQL, BigQuery, Snowflake, Redshift, Oracle, DuckDB; see [Windmill docs](https://www.windmill.dev/docs/getting_started/scripts_quickstart/sql)), but our `scripts/classify-grid-paths.sh` classifier doesn't yet emit a `<type>` entry for SQL files, so deploys would silently skip them. Wrapping in TypeScript sidesteps that entirely and gives the same workspace surface.

## Why this matters

Two common shapes of "SQL we'd want on the Grid" show up in project repos:

- A `queries/*.sql` directory of Snowflake / Postgres / BigQuery SELECTs that power a dashboard or report.
- Python or TypeScript wrappers under `src/routes/` (or similar) that hold the SQL strings inline and run them against a workspace DB.

The TypeScript-wrapper pattern handles both uniformly: define a Windmill resource for the database (one per warehouse, workspace-wide), write a `*.script.ts` that imports the SQL string and runs it via the resource's client, return typed rows.

## The pattern

```ts
// f/strategy/cohort_retention.script.ts
import { Resource } from "windmill-client";

type Snowflake = {
  account: string;
  username: string;
  password: string;
  database: string;
  warehouse: string;
  role: string;
  schema: string;
};

export async function main(
  conn: Resource<"snowflake">,
  lookbackDays: number = 90,
): Promise<{ cohort: string; retained: number; total: number }[]> {
  const sql = `
    WITH cohorts AS (
      SELECT cohort_month, customer_id
      FROM analytics.customer_cohorts
      WHERE first_order_at >= DATEADD(day, -?, CURRENT_DATE())
    )
    SELECT cohort_month::TEXT AS cohort,
           COUNT(DISTINCT CASE WHEN retained THEN customer_id END) AS retained,
           COUNT(DISTINCT customer_id) AS total
    FROM cohorts
    LEFT JOIN analytics.retention_signals USING (customer_id)
    GROUP BY 1
    ORDER BY 1
  `;
  // ... call into the Snowflake client using conn.username/password/etc.
}
```

The `Resource<"snowflake">` parameter is the canonical Windmill way to receive a typed DB connection — its concrete value lives in the workspace as a Resource, not in the repo. The script author must confirm that a resource of the relevant type exists in the workspace UI before deploy; CI's `check-variable-references.sh` does **not** catch this — it greps for literal `wmill.getResource("f/...")` call sites in source files, and a `Resource<"T">` type parameter is just a TypeScript annotation, not a callable that the grep matches.

Long queries live alongside the script as a sibling `*.sql` file imported via the bundler:

```ts
// f/strategy/cohort_retention.script.ts
import sql from "./cohort_retention.sql" with { type: "text" };

export async function main(conn: Resource<"snowflake">) {
  // run sql against conn
}
```

The `*.sql` companion file is checked in but **not** picked up by `classify-grid-paths.sh` as a deployable item — it's just a static asset the script bundles. The script wrapper is the deployable.

## Why not native Windmill SQL scripts (yet)

Windmill's native SQL script types (`*.flow` / `*.script` with `language: postgresql` etc.) would be ergonomic, but:

1. The `wmill <type> push` CLI uses suffix-based detection. `wmill script push <path>` accepts `.ts`/`.js`/`.py`/`.sh` per its `--help`. SQL files don't fit the canonical suffix set, so the per-item push path needs a SQL-aware extension (likely `.script.pgsql` / `.script.snowflake.sql` / similar — needs verification against a live `wmill script push some.sql`).
2. `scripts/classify-grid-paths.sh` doesn't classify `*.sql` paths today. Adding the classification + the matching push invocation is a small follow-up but blocked on (1).

Once both are settled, this rule becomes "use native SQL scripts for new code; wrappers are for migrations". For now, wrappers everywhere.

## What `/grid:import` does

`/grid:import` source mode `script` (the new fourth mode) accepts a `.js`/`.ts`/`.mjs`/`.cjs` file and wraps it as a `*.script.ts`. **It does not accept `.sql` files directly** — the SQL-to-TS-wrapper transform is interactive (the user picks the resource type and the parameters) and doesn't compress into a one-shot import. Write the wrapper by hand following the pattern above, then run `/grid:create` if you want an app fronting the data.

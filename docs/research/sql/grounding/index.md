# SQL & ORM survey — grounding ledger

Claim-by-claim source verification of every page under `docs/research/sql/`. Each survey
page has a `<page>.md` ledger; every material assertion is checked against a **local**
primary artifact — a repository pinned in [`_sources.md`](./_sources.md). Web is
fallback-only (release dates, download counts, adoption). This tree is internal QA
evidence — excluded from the VitePress build (`srcExclude`) and from lychee.

> Not published research. Do not link to it from the survey pages.

## Status legend

| Mark | Meaning                                                                                |
| ---- | -------------------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact (locator recorded)                           |
| `⚠`  | Discrepancy — wrong/misattributed/fabricated; correction recorded + applied to the doc |
| `◯`  | Not locally groundable — editorial/opinion, or source unobtainable (fallback named)    |

**Types:** `quote` · `fact` (date/author/license/attribution) · `figure` (number/version) ·
`behavior` (library does X) · `exposition` (standard knowledge) · `opinion`.

## Per-page ledgers

Populated as each wave lands. Waves: **W1** effects core · **W2** Haskell typed cluster ·
**W3** typed builders / thin · **W4** full ORMs · **W5** raw / baseline · **W6** synthesis.

| Page                 | Ledger                                               | Claims | ✓   | ⚠   | Wave |
| -------------------- | ---------------------------------------------------- | ------ | --- | --- | ---- |
| effect-ts            | [effect-ts.md](./effect-ts.md)                       | 59     | 57  | 0   | W1   |
| quill                | [quill.md](./quill.md)                               | 52     | 47  | 0   | W1   |
| doobie               | [doobie.md](./doobie.md)                             | 64     | 58  | 0   | W1   |
| skunk                | [skunk.md](./skunk.md)                               | 56     | 53  | 0   | W1   |
| slick                | [slick.md](./slick.md)                               | 56     | 53  | 1   | W1   |
| ecto                 | [ecto.md](./ecto.md)                                 | 72     | 69  | 1   | W1   |
| hasql                | [hasql.md](./hasql.md)                               | 64     | 61  | 0   | W2   |
| squeal               | [squeal.md](./squeal.md)                             | 65     | 64  | 0   | W2   |
| opaleye              | [opaleye.md](./opaleye.md)                           | 54     | 51  | 0   | W2   |
| beam                 | [beam.md](./beam.md)                                 | 54     | 50  | 0   | W2   |
| persistent-esqueleto | [persistent-esqueleto.md](./persistent-esqueleto.md) | 54     | 52  | 0   | W2   |
| diesel               | [diesel.md](./diesel.md)                             | 57     | 53  | 0   | W3   |
| sqlx                 | [sqlx.md](./sqlx.md)                                 | 68     | 65  | 0   | W3   |
| sea-orm              | [sea-orm.md](./sea-orm.md)                           | 55     | 51  | 0   | W3   |
| kysely               | [kysely.md](./kysely.md)                             | 52     | 49  | 0   | W3   |
| drizzle              | [drizzle.md](./drizzle.md)                           | 57     | 53  | 0   | W3   |
| jooq                 | [jooq.md](./jooq.md)                                 | 68     | 63  | 0   | W3   |
| sqlc                 | [sqlc.md](./sqlc.md)                                 | 54     | 51  | 0   | W3   |
| linq2db              | [linq2db.md](./linq2db.md)                           | 50     | 47  | 0   | W3   |
| dapper               | [dapper.md](./dapper.md)                             | 61     | 56  | 1   | W3   |
| exposed              | [exposed.md](./exposed.md)                           | 37     | 36  | 0   | W3   |

## Master discrepancy register

Union of all `⚠` rows, populated as each batch lands. The non-`✓` remainder is `◯`
(web-attested release dates / versions on a `--depth 1` clone, or editorial) — recorded
per page.

| #   | Page       | Claim                                                                   | Correction                                                                                                                                   | Source                               | Fixed? |
| --- | ---------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ | ------ |
| R1  | (concepts) | Landscape table grouped `Ecto` under "Effect-system SQL / effect value" | `Ecto` is eager, blocking tagged-tuple `Repo` calls over BEAM processes — not an effect value; regrouped as "Functional data mapper (eager)" | `elixir/ecto` `lib/ecto.ex`          | ✓ W1   |
| R2  | (index)    | Slick framed as "`DBIO` run to a `Future`" (Slick 3)                    | pinned checkout is in-development **Slick 4** with an effect-polymorphic runner (`IO`/`Future`/ZIO facades); catalog + taxonomy updated      | `scala/slick` `slick/Database.scala` | ✓ W1   |

### Batch 1 (wave 1 — effects-first core, 2026-07-12)

Six pages grounded at authoring time against the pinned local checkouts
([`_sources.md`](./_sources.md)): [effect-ts](./effect-ts.md), [quill](./quill.md),
[doobie](./doobie.md), [skunk](./skunk.md), [slick](./slick.md), [ecto](./ecto.md).
**Zero substantive page discrepancies** — every material blockquote copy-paste-matches the
source tree. Two _survey-level_ corrections were caught during authoring and applied to the
shared pages (R1, R2 above) rather than left in a deep-dive. The `◯` remainder per page is
the web-attested set only: first-release years, latest version numbers, docs-site URLs.
Licenses confirmed from each `LICENSE`: Effect TS **MIT**, Quill **Apache-2.0**, doobie
**MIT**, skunk **MIT**, Slick **BSD-2-Clause**, Ecto **Apache-2.0**.

### Batch 2 (wave 2 — Haskell typed cluster, 2026-07-12)

Five pages grounded at authoring time against the pinned checkouts: [hasql](./hasql.md),
[squeal](./squeal.md), [opaleye](./opaleye.md), [beam](./beam.md),
[persistent-esqueleto](./persistent-esqueleto.md). **Zero substantive page discrepancies.**
Several brief-vs-tree facts were caught during authoring and stated correctly in the pages
(none reached a published claim):

- **hasql** — the pinned tree is the **1.10** major revision: the runner is
  `Connection.use :: … IO (Either SessionError a)` (not `Session.run`), prepared/unprepared
  is a constructor choice (not a boolean flag), and `Exception` instances were removed in
  1.10 (errors are fully value-typed). Pooling / transactions / TH-checking live in the
  satellite packages `hasql-pool` / `hasql-transaction` / `hasql-th` (a core absence).
- **squeal** — builds directly on `postgresql-libpq` + `postgresql-binary`, **not** on
  `hasql` (`hasql` is named only as design inspiration in the release notes). Errors are
  thrown `SquealException`s, not a typed channel.
- **opaleye** — injection safety is **escaped-literal rendering** (postgresql-simple's
  parameterless `queryWith_`/`execute_` + `quote`/`escape`), not out-of-band bind
  parameters — stated precisely rather than assimilated to the generic binding story.
- **beam** — MIT; higher-kinded-data schema; "does not do connection or transaction
  management" (verbatim); plain-`IO` backend interpreters; no Template Haskell.
- **persistent + esqueleto** — **license correction**: persistent is **MIT** but esqueleto
  is **BSD-3-Clause** (the brief said "MIT for both"); pages state both correctly. persistent
  owns entities + migrations + `Key` identity but has **no** change tracking / unit of work /
  lazy loading, and no savepoints in core (`transactionSave` = commit+begin).

The `◯` remainder per page is the web-attested set only (first-release years, latest
version numbers on a `--depth 1` clone).

### Batch 3 (wave 3 — typed builders / thin safe-SQL, 2026-07-12)

Ten pages grounded at authoring time: [diesel](./diesel.md), [sqlx](./sqlx.md),
[sea-orm](./sea-orm.md), [kysely](./kysely.md), [drizzle](./drizzle.md), [jooq](./jooq.md),
[sqlc](./sqlc.md), [linq2db](./linq2db.md), [dapper](./dapper.md), [exposed](./exposed.md).
**Zero substantive page discrepancies.** Three authoring-time catches where the brief's
suggested wording was **not present in the pinned tree** — corrected by grounding on real
in-tree text rather than quoting a remembered tagline:

- **dapper** (⚠ #D1) — "King of Micro ORM" / "Dapper does not do the following: generate
  SQL, track changes" are **not** in this checkout's `Readme.md` (older/wiki text); every
  "does not do X" claim was regrounded on `Readme.md:464` ("the 95% scenario") or
  grep-confirmed code absence.
- **jooq** — the "SQL was never meant to be abstracted" tagline is not in the tree; grounded
  the philosophy on `README.md` instead. License verified Apache-2.0-for-OSS-DBs /
  commercial-for-others via the blanked `SQLDialect.commercial()` enum section.
- **linq2db** — grounded on the tree's own text (including faithfully quoted source typos
  "databse"/"nester"); one flat transaction per connection (a second `BeginTransaction`
  throws, no savepoints).

Other grounded facts worth recording: **sqlx** removed MSSQL pre-`0.7` and ships pure-Rust
wire drivers (`#![forbid(unsafe_code)]` core; SQLite the C exception); **sqlc** is a genuine
compiler embedding the real `libpg_query` grammar and does **not** run migrations; **Exposed**
`1.x` **deprecated** `createMissingTablesAndColumns` auto-migration in favour of
`MigrationUtils` + a third-party runner; **SeaORM**'s "async & dynamic ORM" / "built upon
SQLx" taglines are in-tree (`README`), not just web. The `◯` remainder is the web-attested
set only.

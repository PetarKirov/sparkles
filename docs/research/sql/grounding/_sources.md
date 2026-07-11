# Grounding sources — local-artifact map

Lookup table for the per-page verification pass of the **SQL & ORM abstraction** survey.
Every surveyed library maps here to a **local** repository checkout, pinned to the HEAD
reviewed. Web (official docs, blog posts, release registries) is a fallback **only** for
facts a source tree cannot carry (release dates, download counts, adoption). `$REPOS` =
`/home/petar/code/repos`.

**Acquisition:** the two effects-first flagships were already present
(`typescript/effect-smol`, `scala/zio-protoquill` + `scala/zio-quill`); the remaining 34
repos were shallow-cloned (`git clone --depth 1`) on 2026-07-12. A `--depth 1` checkout has
no history — the pin is the HEAD SHA only, and line numbers are as-of that HEAD.

> Not published research. Do not link to it from the survey pages. Excluded from the
> VitePress build (`srcExclude`) and from lychee.

## Source repos (pinned to reviewed HEAD)

### Effect systems & functional access (already local)

| Repo             | Path                            | Pinned SHA   | As of      |
| ---------------- | ------------------------------- | ------------ | ---------- |
| effect-smol      | `$REPOS/typescript/effect-smol` | `2711e39a`   | 2026-07-12 |
| effect (classic) | `$REPOS/typescript/effect`      | `e5998a4`    | 2026-07-12 |
| zio-protoquill   | `$REPOS/scala/zio-protoquill`   | `dc8505cb`   | 2026-07-12 |
| zio-quill        | `$REPOS/scala/zio-quill`        | `5a5b8ae5`   | 2026-07-12 |
| zio (runtime)    | `$REPOS/scala/zio`              | `45b68c1197` | 2026-07-12 |

### Effect systems & functional access (cloned)

| Repo            | Path                             | Pinned SHA | As of      |
| --------------- | -------------------------------- | ---------- | ---------- |
| doobie          | `$REPOS/scala/doobie`            | `0fd7b4b`  | 2026-07-12 |
| slick           | `$REPOS/scala/slick`             | `f16973a`  | 2026-07-12 |
| skunk           | `$REPOS/scala/skunk`             | `706dc37`  | 2026-07-12 |
| ecto            | `$REPOS/elixir/ecto`             | `e0aa6e1`  | 2026-07-12 |
| hasql           | `$REPOS/haskell/hasql`           | `c8e78a9`  | 2026-07-12 |
| squeal          | `$REPOS/haskell/squeal`          | `533cab7`  | 2026-07-12 |
| haskell-opaleye | `$REPOS/haskell/haskell-opaleye` | `eaf0942`  | 2026-07-12 |
| beam            | `$REPOS/haskell/beam`            | `98e04b0`  | 2026-07-12 |
| persistent      | `$REPOS/haskell/persistent`      | `52651fd`  | 2026-07-12 |
| esqueleto       | `$REPOS/haskell/esqueleto`       | `7821cbe`  | 2026-07-12 |

### Typed query builders & thin safe-SQL (cloned)

| Repo        | Path                            | Pinned SHA | As of      |
| ----------- | ------------------------------- | ---------- | ---------- |
| diesel      | `$REPOS/rust/diesel`            | `d4378b5`  | 2026-07-12 |
| sqlx (Rust) | `$REPOS/rust/sqlx`              | `1d674f5`  | 2026-07-12 |
| sea-orm     | `$REPOS/rust/sea-orm`           | `f0121e0`  | 2026-07-12 |
| cornucopia  | `$REPOS/rust/cornucopia`        | `c824a93`  | 2026-07-12 |
| kysely      | `$REPOS/typescript/kysely`      | `c431677`  | 2026-07-12 |
| drizzle-orm | `$REPOS/typescript/drizzle-orm` | `9d64532`  | 2026-07-12 |
| jooq        | `$REPOS/java/jooq`              | `c8d3d75`  | 2026-07-12 |
| sqlc        | `$REPOS/go/sqlc`                | `22d878a`  | 2026-07-12 |
| linq2db     | `$REPOS/dotnet/linq2db`         | `6b62648`  | 2026-07-12 |
| dapper      | `$REPOS/dotnet/dapper`          | `72a54c4`  | 2026-07-12 |
| exposed     | `$REPOS/kotlin/exposed`         | `b801a8a`  | 2026-07-12 |

### Full ORMs / data-mappers (cloned)

| Repo          | Path                        | Pinned SHA | As of      |
| ------------- | --------------------------- | ---------- | ---------- |
| efcore        | `$REPOS/dotnet/efcore`      | `937552f`  | 2026-07-12 |
| hibernate-orm | `$REPOS/java/hibernate-orm` | `4d5d0b3c` | 2026-07-12 |
| sqlalchemy    | `$REPOS/python/sqlalchemy`  | `5bf558a`  | 2026-07-12 |
| sqlmodel      | `$REPOS/python/sqlmodel`    | `097f4e8`  | 2026-07-12 |
| django        | `$REPOS/python/django`      | `65a9f14`  | 2026-07-12 |
| prisma        | `$REPOS/typescript/prisma`  | `cda80a4`  | 2026-07-12 |
| typeorm       | `$REPOS/typescript/typeorm` | `44d8052`  | 2026-07-12 |
| gorm          | `$REPOS/go/gorm`            | `1d6ce99`  | 2026-07-12 |
| ent           | `$REPOS/go/ent`             | `69d5d4d`  | 2026-07-12 |
| rails         | `$REPOS/ruby/rails`         | `35ee781`  | 2026-07-12 |

### Raw drivers & tagged-template baseline (cloned)

| Repo        | Path                         | Pinned SHA | As of      |
| ----------- | ---------------------------- | ---------- | ---------- |
| sqlx (Go)   | `$REPOS/go/sqlx`             | `41dac16`  | 2026-07-12 |
| postgres.js | `$REPOS/typescript/postgres` | `e7dfa14`  | 2026-07-12 |
| jdbi        | `$REPOS/java/jdbi`           | `78c2fa4`  | 2026-07-12 |

> [!NOTE]
> Go's `database/sql` (the stdlib driver interface the `go-database-sql.md` page surveys)
> lives in the local Go source tree at `$REPOS/go/go` (pinned at `01534385`, 2026-06-01, the
> Go 1.27 development tip; `src/database/sql/` + `src/database/sql/driver/`); `jmoiron/sqlx`
> (`$REPOS/go/sqlx` @ `41dac16`) is the ergonomic layer above it.

## Per-page → repo mapping

Format: page → local repo (+ the sub-tree used for quote grounding). Per-claim locators
live in each `grounding/<page>.md` ledger.

### A. Effect systems & functional access

- **effect-ts.md** — `$REPOS/typescript/effect-smol`, core at
  `packages/effect/src/unstable/sql/` (`Statement.ts`, `SqlClient.ts`, `SqlConnection.ts`,
  `SqlError.ts`, `SqlResolver.ts`, `SqlSchema.ts`, `SqlModel.ts`, `SqlStream.ts`,
  `Migrator.ts`); driver at `packages/sql/pg/src/PgClient.ts`. Classic monorepo
  (`$REPOS/typescript/effect`) for the `@effect/sql` lineage + `sql-drizzle`/`sql-kysely`.
- **quill.md** — `$REPOS/scala/zio-protoquill` (`quill-sql/`, `quill-jdbc-zio/`);
  shared engine `$REPOS/scala/zio-quill/quill-engine` (`Model.scala`, `NamingStrategy.scala`,
  `idiom/Idiom.scala`); ZIO runtime `$REPOS/scala/zio`.
- **doobie.md** — `$REPOS/scala/doobie` (`modules/free/`, `modules/core/src/main/scala/doobie/`).
- **skunk.md** — `$REPOS/scala/skunk` (`modules/core/`).
- **slick.md** — `$REPOS/scala/slick` (`slick/src/main/scala/slick/`).
- **ecto.md** — `$REPOS/elixir/ecto` (`lib/ecto/`).
- **hasql.md** — `$REPOS/haskell/hasql` (`library/`).
- **squeal.md** — `$REPOS/haskell/squeal` (`squeal-postgresql/src/`).
- **opaleye.md** — `$REPOS/haskell/haskell-opaleye` (`src/Opaleye/`).
- **beam.md** — `$REPOS/haskell/beam` (`beam-core/`, `beam-postgres/`).
- **persistent-esqueleto.md** — `$REPOS/haskell/persistent` (`persistent/`) +
  `$REPOS/haskell/esqueleto` (`src/Database/Esqueleto/`).

### B. Typed query builders & thin safe-SQL

- **diesel.md** — `$REPOS/rust/diesel` (`diesel/src/`, `diesel_derives/`).
- **sqlx.md** — `$REPOS/rust/sqlx` (`sqlx-core/`, `sqlx-macros-core/`).
- **sea-orm.md** — `$REPOS/rust/sea-orm` (`src/`).
- **kysely.md** — `$REPOS/typescript/kysely` (`src/`). cornucopia (`$REPOS/rust/cornucopia`)
  is a see-also on sqlc.md/diesel.md.
- **drizzle.md** — `$REPOS/typescript/drizzle-orm` (`drizzle-orm/src/`).
- **jooq.md** — `$REPOS/java/jooq` (`jOOQ/src/main/java/org/jooq/`).
- **sqlc.md** — `$REPOS/go/sqlc` (`internal/`).
- **linq2db.md** — `$REPOS/dotnet/linq2db` (`Source/LinqToDB/`).
- **dapper.md** — `$REPOS/dotnet/dapper` (`Dapper/`).
- **exposed.md** — `$REPOS/kotlin/exposed` (`exposed-core/src/main/kotlin/`).

### C. Full ORMs / data-mappers

- **ef-core.md** — `$REPOS/dotnet/efcore` (`src/EFCore/`, `src/EFCore.Relational/`).
- **hibernate.md** — `$REPOS/java/hibernate-orm` (`hibernate-core/src/main/java/org/hibernate/`).
- **sqlalchemy.md** — `$REPOS/python/sqlalchemy` (`lib/sqlalchemy/`); SQLModel
  (`$REPOS/python/sqlmodel`) folded in as a see-also.
- **django-orm.md** — `$REPOS/python/django` (`django/db/`).
- **prisma.md** — `$REPOS/typescript/prisma` (`packages/client/`, `packages/generator/`).
- **typeorm.md** — `$REPOS/typescript/typeorm` (`src/`).
- **gorm.md** — `$REPOS/go/gorm` (top-level `.go` files, `clause/`).
- **ent.md** — `$REPOS/go/ent` (`entc/`, `dialect/`).
- **activerecord.md** — `$REPOS/ruby/rails` (`activerecord/lib/active_record/`).

### D. Raw drivers & tagged-template baseline

- **go-database-sql.md** — `$REPOS/go/go/src/database/sql/` + `$REPOS/go/sqlx`.
- **postgres-js.md** — `$REPOS/typescript/postgres` (`src/`, `cjs/`).
- **jdbi.md** — `$REPOS/java/jdbi` (`core/src/main/java/org/jdbi/v3/core/`).

## Web-attested only (cite-by-name; never asserted as tree facts)

Per-library **first-release dates**, **latest version numbers**, **download/adoption
counts**, and any **historical milestone** in the umbrella's timeline are web-attested
against the primary registry (crates.io, npm, Maven Central, Hackage, Hex.pm, NuGet,
RubyGems, pkg.go.dev) or the project's changelog/release page, and flagged `🌐` in the
per-page ledger — they are not present in a `--depth 1` tree.

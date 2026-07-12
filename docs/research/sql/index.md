# SQL & ORM Abstraction

A breadth-first survey of **database access across languages** — from the thinnest layer
that keeps SQL injection-proof (safe string templates, raw drivers), through typed query
builders and functional data mappers, up to full object-relational mappers with change
tracking and unit-of-work. The goal is a grounded map of how ~30 production systems in a
dozen ecosystems structure the four hard problems — safe query construction, connection &
transaction lifetime, schema & migration, and result mapping — to inform the design of an
**algebraic effects-first** D data-access library (working name `sparkles:sql`). Because
the design centre is effects-first, the survey weights the effect-system and functional
data-mapper families most heavily: [Effect TS][effect-ts] (TypeScript), [Quill][quill],
[doobie][doobie], [skunk][skunk], [Slick][slick] (Scala), and [Ecto][ecto] (Elixir).

This survey answers seven questions:

1. **What are the levels of abstraction, and what does each rung trade?** The
   driver → safe-SQL → typed-builder → functional-data-mapper → full-ORM ladder. See
   [concepts: the abstraction ladder][ladder] and the [master catalog](#master-catalog).
2. **How is SQL made injection-safe, and how do the mechanisms differ?** Runtime
   tagged-templates vs typed builders vs compile-time quotation vs macro-checked raw SQL.
   See [concepts: statements, parameters & injection][safety], the
   [by-query-model taxonomy](#by-query-construction-model), and the
   [safe-interpolation case study][safe-interp] (which features D's IES).
3. **Compile-time or runtime query construction — who checks the query, and when?**
   Type-level schemas and macros ([Quill][quill], `sqlx`, `Squeal`, `jOOQ`) vs runtime AST
   builders. See the [comparison][comparison].
4. **How is database access modelled as an effect, and how do transactions compose?**
   Blocking vs async vs effect-value (`IO`/`ZIO`/`Effect`/`ConnectionIO`); `withTransaction`
   combinators, nesting, and savepoints. See the [by-effect-model taxonomy](#by-effect-async-model).
5. **How is error handling typed?** A single typed error channel with a reason union
   ([Effect TS][effect-ts]) vs a narrowed exception channel ([Quill][quill]) vs thrown
   `SQLException`/`DbException`. See [concepts: effects, transactions & errors][effects].
6. **What are the schema & migration strategies?** Code-first, schema-first, and db-first
   (introspection + codegen). See the [by-schema-stance taxonomy](#by-schema-stance).
7. **What should an effects-first `sparkles:sql` borrow, across the thin→ORM spectrum?**
   The synthesis and delta. See the [comparison][comparison].

> [!NOTE]
> **Scope: complete — all five waves + synthesis published.** This survey was built in waves.
> **Wave 1** establishes the shared vocabulary ([concepts][concepts]) and the effect-system
> / functional-data-mapper core: [Effect TS][effect-ts], [Quill][quill], [doobie][doobie],
> [skunk][skunk], [Slick][slick], [Ecto][ecto]. **Wave 2** adds the **Haskell typed cluster**
> ([hasql][hasql], [Squeal][squeal], [Opaleye][opaleye], [Beam][beam],
> [persistent + esqueleto][pe]). **Wave 3** adds the **typed query builders & thin safe-SQL**
> ([Diesel][diesel], [sqlx][sqlx], [SeaORM][sea-orm], [Kysely][kysely], [Drizzle][drizzle],
> [jOOQ][jooq], [sqlc][sqlc], [linq2db][linq2db], [Dapper][dapper], [Exposed][exposed]).
> **Wave 4** adds the **full ORMs** ([EF Core][ef-core], [Hibernate][hibernate],
> [SQLAlchemy][sqlalchemy], [Django ORM][django-orm], [Prisma][prisma], [TypeORM][typeorm],
> [GORM][gorm], [ent][ent], [ActiveRecord][activerecord]). **Wave 5** adds the **raw /
> tagged-template baseline** ([Go `database/sql`][gds], [postgres.js][pgjs], [JDBI][jdbi]), and
> the capstone [comparison & synthesis][comparison] reads the whole corpus against itself and
> distils the design brief for an effects-first `sparkles:sql`.

**Last reviewed:** July 12, 2026

---

## Master catalog

One row per surveyed system. **Category** places it on the [abstraction ladder][ladder].
**Query model** is how a query is expressed ([concepts][models]). **Effect/async model** is
how a result is returned. **Schema stance** is the library's relationship to the schema
([concepts][schema]). The **Link** column points at the deep-dive (or the wave that
publishes it).

| System                     | Language   | Category                      | Query model                          | Effect / async model                     | Schema stance            | Link                         |
| -------------------------- | ---------- | ----------------------------- | ------------------------------------ | ---------------------------------------- | ------------------------ | ---------------------------- |
| **Effect TS `sql`**        | TypeScript | Functional data mapper        | Tagged template                      | Effect value (typed `SqlError`)          | Code-agnostic            | [effect-ts][effect-ts]       |
| **Quill**                  | Scala      | Functional data mapper        | Quoted DSL → AST (compile-time)      | Pluggable; ZIO in JDBC-ZIO               | Code-agnostic            | [quill][quill]               |
| **doobie**                 | Scala      | Functional data mapper        | Tagged template + `Fragment`         | `ConnectionIO` (cats-effect)             | None (SQL only)          | [doobie][doobie]             |
| **skunk**                  | Scala      | Functional data mapper        | Typed statement + `Codec`            | cats-effect + fs2                        | None (SQL only)          | [skunk][skunk]               |
| **Slick**                  | Scala      | Functional-relational         | Typed relational algebra             | `DBIO` → effect-poly `F` (IO/Future/ZIO) | Schema + codegen         | [slick][slick]               |
| **Ecto**                   | Elixir     | Functional data mapper        | Composable query macros              | Immutable / blocking                     | Code-first + migrations  | [ecto][ecto]                 |
| **hasql**                  | Haskell    | Safe-SQL / micro-mapper       | Raw SQL + `Encoders`/`Decoders`      | `Session` over `IO` (blocking)           | None (SQL only)          | [hasql][hasql]               |
| **Squeal**                 | Haskell    | Typed query builder           | Typed relational algebra             | Indexed monad `PQ` over `IO`             | Code-first (type-level)  | [squeal][squeal]             |
| **Opaleye**                | Haskell    | Typed query builder           | Typed relational algebra (arrows)    | `IO` (postgresql-simple)                 | Db-first                 | [opaleye][opaleye]           |
| **Beam**                   | Haskell    | Functional data mapper        | Typed relational algebra (`Q` monad) | `MonadBeam` over `IO`                    | Code-first / db-first    | [beam][beam]                 |
| **persistent + esqueleto** | Haskell    | Full ORM + typed joins        | TH entities + type-safe EDSL         | `SqlPersistT` over `IO` (blocking)       | Code-first               | [persistent-esqueleto][pe]   |
| **Diesel**                 | Rust       | Typed query builder           | Fluent typed builder                 | Blocking (+ async fork)                  | Db-first (`schema.rs`)   | [diesel][diesel]             |
| **sqlx**                   | Rust       | Safe-SQL / micro-mapper       | Macro-checked raw SQL                | Async                                    | Db-first (compile check) | [sqlx][sqlx]                 |
| **SeaORM**                 | Rust       | Full ORM (data mapper)        | Fluent builder over `sqlx`           | Async                                    | Code/db-first (entities) | [sea-orm][sea-orm]           |
| **Kysely**                 | TypeScript | Typed query builder           | Fluent typed builder                 | Async                                    | Db-first (types)         | [kysely][kysely]             |
| **Drizzle**                | TypeScript | Typed query builder           | Fluent SQL-like builder              | Async                                    | Code-first (schema)      | [drizzle][drizzle]           |
| **jOOQ**                   | Java       | Typed query builder           | Fluent typed builder                 | Blocking (+ R2DBC)                       | Db-first codegen         | [jooq][jooq]                 |
| **sqlc**                   | Go         | Safe-SQL / micro-mapper       | Raw SQL → generated code             | Blocking (`database/sql`)                | Db-first (codegen)       | [sqlc][sqlc]                 |
| **linq2db**                | .NET       | Typed query builder           | LINQ → SQL                           | Async                                    | Db-first / POCO          | [linq2db][linq2db]           |
| **Dapper**                 | .NET       | Safe-SQL / micro-mapper       | Raw SQL + auto-map                   | Blocking / async                         | None                     | [dapper][dapper]             |
| **Exposed**                | Kotlin     | Typed query builder + DAO     | Fluent DSL / DAO                     | Blocking (+ suspend)                     | Code-first               | [exposed][exposed]           |
| **EF Core**                | .NET       | Full ORM (data mapper)        | LINQ                                 | Async                                    | Code-first + migrations  | [ef-core][ef-core]           |
| **Hibernate / JPA**        | Java       | Full ORM (data mapper)        | JPQL / Criteria                      | Blocking (+ reactive)                    | Code-first / db-first    | [hibernate][hibernate]       |
| **SQLAlchemy**             | Python     | Full ORM (data mapper) + Core | Core expression + ORM                | Blocking (+ asyncio)                     | Code-first               | [sqlalchemy][sqlalchemy]     |
| **Django ORM**             | Python     | Full ORM (active-record-ish)  | `QuerySet` method chains             | Blocking (+ async)                       | Code-first + migrations  | [django-orm][django-orm]     |
| **Prisma**                 | TypeScript | Full ORM (data mapper)        | Schema-first + generated client      | Async                                    | Schema-first (`.prisma`) | [prisma][prisma]             |
| **TypeORM**                | TypeScript | Full ORM (AR + data mapper)   | Decorators + query builder           | Async                                    | Code-first               | [typeorm][typeorm]           |
| **GORM**                   | Go         | Full ORM (active-record-ish)  | Chainable methods + struct tags      | Blocking                                 | Code-first (automigrate) | [gorm][gorm]                 |
| **ent**                    | Go         | Full ORM (data mapper)        | Schema-as-code + generated builders  | Blocking                                 | Code-first (codegen)     | [ent][ent]                   |
| **ActiveRecord**           | Ruby       | Full ORM (active record)      | Model + query methods                | Blocking                                 | Db-first + migrations    | [activerecord][activerecord] |
| **Go `database/sql`**      | Go         | Driver (+ `sqlx`)             | Raw string                           | Blocking                                 | None                     | [go-database-sql][gds]       |
| **postgres.js**            | JS / TS    | Driver + safe-SQL             | Tagged template                      | Async                                    | None                     | [postgres-js][pgjs]          |
| **JDBI**                   | Java       | Safe-SQL / micro-mapper       | Raw SQL (fluent + SQL objects)       | Blocking                                 | None                     | [jdbi][jdbi]                 |

---

## Taxonomy

Each table re-cuts the same set by one axis. Forward-dated systems are named but not yet
linked; their deep-dives arrive in the marked wave.

### By abstraction level

The primary axis (see [concepts: the abstraction ladder][ladder]).

| Rung                         | Systems                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------ |
| **Driver**                   | Go `database/sql`, `postgres.js`, JDBC, ADO.NET                                                  |
| **Safe-SQL / micro-mapper**  | [doobie][doobie]-adjacent, `hasql`, `Dapper`, `JDBI`, `sqlc`, `sqlx`, `postgres.js`              |
| **Typed query builder**      | [Slick][slick], `Squeal`, `Opaleye`, `Diesel`, `Kysely`, `Drizzle`, `jOOQ`, `linq2db`, `Exposed` |
| **Functional data mapper**   | [Effect TS][effect-ts], [Quill][quill], [doobie][doobie], [skunk][skunk], [Ecto][ecto], `Beam`   |
| **Full ORM (data mapper)**   | `EF Core`, `Hibernate`, `SQLAlchemy`, `Prisma`, `ent`, `SeaORM`, `persistent`                    |
| **Full ORM (active record)** | `ActiveRecord`, `Django ORM`, `GORM`, `TypeORM`                                                  |

### By query construction model

_How the query is expressed_ ([concepts: query construction models][models]).

| Model                        | Checked         | Systems                                                                        |
| ---------------------------- | --------------- | ------------------------------------------------------------------------------ |
| **Raw string**               | never           | Go `database/sql`, `Dapper`, `JDBI` (SQL objects)                              |
| **Tagged template**          | runtime         | [Effect TS][effect-ts], [doobie][doobie] (`sql"..."`), `postgres.js`           |
| **Fluent typed builder**     | compile         | `jOOQ`, `Kysely`, `Diesel`, `Drizzle`, `Exposed`, `SeaORM`                     |
| **Quoted DSL → AST**         | compile         | [Quill][quill], EF Core / `linq2db` ([LINQ][models])                           |
| **Typed relational algebra** | compile (types) | [Slick][slick], `Squeal`, `Opaleye`, `Beam`, `esqueleto`                       |
| **Macro-checked raw SQL**    | compile         | `sqlx`, `sqlc`, `cornucopia`                                                   |
| **Criteria / method chains** | runtime/partial | `Hibernate`, `SQLAlchemy`, `Django ORM`, `GORM`, `ActiveRecord`, `Ecto` macros |

### By effect / async model

_How a result is returned_ ([concepts: effects, transactions & errors][effects]).

| Model                                  | Systems                                                                                                                                                                                        |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Blocking**                           | `Diesel`, `jOOQ`, `Hibernate`, `JDBI`, Go `database/sql`, `sqlc`, `GORM`, `ent`, `ActiveRecord`, `Django ORM`                                                                                  |
| **Async (future / promise / `Task`)**  | `sqlx`, `EF Core`, `Prisma`, `Kysely`, `Drizzle`, `TypeORM`, `postgres.js`, `SeaORM`, `linq2db`, `SQLAlchemy` (asyncio)                                                                        |
| **Effect value (`IO`/`ZIO`/`Effect`)** | [Effect TS][effect-ts], [Quill][quill] (ZIO), [doobie][doobie], [skunk][skunk] (cats-effect), [Slick][slick] (`DBIO` run to an effect-poly `F`), [Squeal][squeal] (indexed `PQ`), [Beam][beam] |
| **Blocking `IO` (Haskell)**            | [hasql][hasql] (`Session`), [Opaleye][opaleye] (postgresql-simple), [persistent + esqueleto][pe] (`SqlPersistT`)                                                                               |
| **Functional/immutable, blocking**     | [Ecto][ecto] (eager tagged-tuple `Repo` calls)                                                                                                                                                 |

### By schema stance

_The library's relationship to the schema_ ([concepts: schema, migrations & codegen][schema]).

| Stance                           | Systems                                                                                                 |
| -------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **Code-first (models → schema)** | `EF Core`, `Django ORM`, `TypeORM`, `Beam`, `Drizzle`, `Exposed`, [Ecto][ecto], `GORM`, `ent`, `SeaORM` |
| **Schema-first (declaration)**   | `Prisma` (`.prisma`), [Slick][slick] (codegen input), `Squeal` (type-level)                             |
| **Db-first (introspect + gen)**  | `jOOQ`, `sqlc`, `sqlx`, `Diesel`, `Kysely`, `Opaleye`, `ActiveRecord` (`schema.rb`), `linq2db`          |
| **None (raw SQL, no schema)**    | [doobie][doobie], [skunk][skunk], `hasql`, `Dapper`, `JDBI`, Go `database/sql`, `postgres.js`           |

---

## Milestones

A high-confidence timeline of when the field's ideas and tools landed. Per-library
provenance (and exact release dates) live in each deep-dive's `Ecosystem & maturity` and
`Sources`; forward-dated entries are marked.

| Year        | Milestone                                                                                                                              |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **1970**    | Codd — the relational model (CACM)                                                                                                     |
| 1986–1992   | SQL standardized (SQL-86 … SQL-92); JDBC-style call-level interfaces emerge                                                            |
| **2001**    | **Hibernate** (Gavin King) — the archetypal JVM ORM; **JDBI**'s ancestor era                                                           |
| 2003–2004   | **SQLAlchemy** begins (Bayer); **Ruby on Rails / ActiveRecord** (DHH) popularizes active record                                        |
| **2005**    | **Django ORM** ships with Django; **Hibernate** informs the **JPA** standard (JSR 220, 2006)                                           |
| 2007–2008   | **LINQ** + **LINQ to SQL** / **Entity Framework** (Microsoft) — language-integrated query on .NET                                      |
| **2009**    | **jOOQ** (Lukas Eder) — typed SQL DSL generated from the schema                                                                        |
| 2012–2013   | **Slick** (Typesafe) — functional-relational mapping for Scala; **Ecto** work begins for Elixir                                        |
| **2015**    | **Ecto** 1.0 (Elixir); **doobie** matures (Rob Norris); **HugSQL**/**Yesod persistent** era                                            |
| 2016        | **Quill** (Li Haoyi/Flavio Brasil) — compile-time QDSL; **Diesel** 1.0 (Rust); **Opaleye**/**Beam** (Haskell typed SQL)                |
| 2017–2019   | **skunk** (Norris) — pure-FP Postgres, no JDBC; **hasql** matures; **ent** (Facebook, Go); **sqlc** (Go)                               |
| **2019**    | **Prisma 2** rewrite (schema-first + Rust query engine); **EF Core** matures as the .NET default                                       |
| 2020        | **sqlx** (Rust) — compile-time-checked raw SQL; **SeaORM** begins; **GORM** v2                                                         |
| 2022        | **Kysely** + **Drizzle** (TypeScript) — type-safe query builders challenge the ORM default                                             |
| 2023–2026\* | **Effect TS `sql`** — DB-access-as-effect (typed `SqlError`, scoped acquirer); **ProtoQuill** (Scala 3); Drizzle/Kysely adoption surge |

<sub>\* 2023–2026 entries are current-as-of-review; exact dates are in the per-library
deep-dives (some forward-dated pending their wave).</sub>

---

## Quick navigation

### Suggested reading paths

- **"I'm designing `sparkles:sql` (effects-first)."** [concepts][concepts] (the ladder +
  the effect/transaction vocabulary) → [Effect TS][effect-ts] (DB-as-effect, typed error
  union, scoped acquirer, transaction-as-combinator) → [Quill][quill] (compile-time safe
  query DSL, `Idiom`/`NamingStrategy`) → [doobie][doobie] + [skunk][skunk] (the cats-effect
  free-monad and pure-FP-Postgres alternatives) → the [comparison][comparison].
- **"I want the safe-SQL-without-an-ORM story."** [concepts: injection safety][safety] →
  the [safe-interpolation case study][safe-interp] (the technique + D's IES) →
  [Effect TS][effect-ts] / [doobie][doobie] (tagged templates) → [sqlx][sqlx] / [sqlc][sqlc]
  (macro-checked / codegen'd raw SQL) → [hasql][hasql] / [Dapper][dapper] (micro-mappers).
- **"I want the typed-query-builder lineage."** [Slick][slick] → [Squeal][squeal] /
  [Opaleye][opaleye] / [Beam][beam] (Haskell type-level schemas) → [jOOQ][jooq] /
  [Kysely][kysely] / [Diesel][diesel] / [Drizzle][drizzle] (fluent typed builders).
- **"I want to understand full ORMs."** [concepts: ORM patterns][orm] → [Hibernate][hibernate]
  / [EF Core][ef-core] / [SQLAlchemy][sqlalchemy] (data mapper + unit of work) →
  [ActiveRecord][activerecord] / [Django ORM][django-orm] / [GORM][gorm] (active record) →
  [Prisma][prisma] / [ent][ent] (schema-first / codegen).

### Library deep-dives

Grouped by category; see the [master catalog](#master-catalog) for the one-line summary.

- **Effect systems & functional access:** [Effect TS][effect-ts] · [Quill][quill] ·
  [doobie][doobie] · [skunk][skunk] · [Slick][slick] · [Ecto][ecto].
- **Typed functional SQL (Haskell):** [hasql][hasql] · [Squeal][squeal] · [Opaleye][opaleye] ·
  [Beam][beam] · [persistent + esqueleto][pe].
- **Typed builders & thin safe-SQL:** [Diesel][diesel] · [sqlx][sqlx] · [SeaORM][sea-orm] ·
  [Kysely][kysely] · [Drizzle][drizzle] · [jOOQ][jooq] · [sqlc][sqlc] · [linq2db][linq2db] ·
  [Dapper][dapper] · [Exposed][exposed].
- **Full ORMs:** [EF Core][ef-core] · [Hibernate][hibernate] · [SQLAlchemy][sqlalchemy] ·
  [Django ORM][django-orm] · [Prisma][prisma] · [TypeORM][typeorm] · [GORM][gorm] ·
  [ent][ent] · [ActiveRecord][activerecord].
- **Raw / tagged-template baseline:** [Go `database/sql`][gds] · [postgres.js][pgjs] ·
  [JDBI][jdbi].
- **Synthesis:** [Comparison & Synthesis][comparison] — the cross-cutting analysis + the
  effects-first `sparkles:sql` design brief.
- **Case study:** [Safe SQL Interpolation][safe-interp] — how each ecosystem makes the
  `${value}` syntax injection-safe, featuring D's interpolated expression sequences (IES).

---

## Sources

- Each deep-dive's `Sources` section carries its primary sources (repository files +
  official docs), pinned in the survey's grounding ledger.
- Shared vocabulary and the canonical pattern references (Codd; Fowler, _Patterns of
  Enterprise Application Architecture_; OWASP on SQL injection) are cited in
  [concepts][concepts].

<!-- References -->

[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[safety]: ./concepts.md#statements-parameters-and-sql-injection
[models]: ./concepts.md#query-construction-models
[schema]: ./concepts.md#schema-migrations-code-generation
[effects]: ./concepts.md#effects-transactions-and-error-handling
[orm]: ./concepts.md#orm-patterns
[effect-ts]: ./effect-ts.md
[quill]: ./quill.md
[doobie]: ./doobie.md
[skunk]: ./skunk.md
[slick]: ./slick.md
[ecto]: ./ecto.md
[hasql]: ./hasql.md
[squeal]: ./squeal.md
[opaleye]: ./opaleye.md
[beam]: ./beam.md
[pe]: ./persistent-esqueleto.md
[diesel]: ./diesel.md
[sqlx]: ./sqlx.md
[sea-orm]: ./sea-orm.md
[kysely]: ./kysely.md
[drizzle]: ./drizzle.md
[jooq]: ./jooq.md
[sqlc]: ./sqlc.md
[linq2db]: ./linq2db.md
[dapper]: ./dapper.md
[exposed]: ./exposed.md
[ef-core]: ./ef-core.md
[hibernate]: ./hibernate.md
[sqlalchemy]: ./sqlalchemy.md
[django-orm]: ./django-orm.md
[prisma]: ./prisma.md
[typeorm]: ./typeorm.md
[gorm]: ./gorm.md
[ent]: ./ent.md
[activerecord]: ./activerecord.md
[gds]: ./go-database-sql.md
[pgjs]: ./postgres-js.md
[jdbi]: ./jdbi.md
[comparison]: ./comparison.md
[safe-interp]: ./safe-interpolation.md

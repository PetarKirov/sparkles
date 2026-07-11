# SQL & ORM Access: Concepts & Vocabulary

The shared vocabulary every deep-dive in this survey leans on. Database-access libraries
span a wide **abstraction ladder** — from a thin wrapper over a network protocol that
hands you rows of `unknown`, up to a full **object-relational mapper** that materializes a
graph of typed entities and writes their mutations back automatically. The terms below cut
across that whole ladder; each is defined once here and linked from the deep-dives.

> [!NOTE]
> This page is descriptive, not prescriptive: it fixes terminology so the deep-dives and
> the [comparison][comparison] can be read side by side. Where a term has a canonical
> external definition (Codd's model, Fowler's _Patterns of Enterprise Application
> Architecture_), that source is cited; where a library coined or sharpened a term, the
> owning deep-dive carries the verbatim quote.

---

## The abstraction ladder

The single most load-bearing axis in this survey is **how much the library does between
your code and the wire**. Every surveyed system sits at one of five rungs (many span two):

| Rung                         | What you write                                                       | What the library owns                                                     | Representative systems                                                                  |
| ---------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| **Driver**                   | Raw SQL strings + positional params; you read rows by index          | The wire protocol, connection, type transfer                              | Go `database/sql`, `postgres.js`, JDBC, ADO.NET                                         |
| **Safe-SQL / micro-mapper**  | Raw SQL, but parameters bind automatically and rows map to types     | Injection-safe parameter binding, row→object hydration                    | `Dapper`, `postgres.js`, `hasql`, `JDBI`                                                |
| **Typed query builder**      | A fluent/DSL expression that _is_ SQL, checked by the type system    | SQL generation, dialect, compile- or type-checked column/table references | `Kysely`, `jOOQ`, `Diesel`, `Slick`, `Squeal`, `Opaleye`                                |
| **Data mapper (functional)** | Queries as first-class values in a query monad; explicit persistence | AST→SQL, codecs, transaction plumbing — but _not_ change tracking         | [doobie][doobie], [Quill][quill], [Ecto][ecto], [skunk][skunk], `Beam`, `sqlc`          |
| **Full ORM**                 | Objects/entities with declared relations; you mutate them            | Change tracking, identity map, unit of work, lazy loading, migration      | EF Core, Hibernate/JPA, SQLAlchemy ORM, Django ORM, Prisma, ActiveRecord, GORM, TypeORM |

The higher the rung, the more the library hides — and the more it must _guess_ (when to
load a relation, when to flush a change, which SQL a method call becomes). The two
"functional data mapper" families this survey weights most heavily —
[Quill][quill]/[doobie][doobie]/[skunk][skunk] (Scala), [Ecto][ecto] (Elixir), and the
[Effect TS `sql`][effect-ts] layer (TypeScript) — deliberately stop below the full-ORM
rung: they give you typed, composable queries and explicit effects **without** an identity
map or implicit flush. That boundary is the survey's central design question for
`sparkles:sql`.

---

## Relational foundations

- **Relation / table / row / tuple.** The relational model (Codd 1970) models data as
  _relations_ — sets of tuples over named, typed attributes. In SQL a relation is a
  **table** (or a query result), a tuple is a **row**, an attribute is a **column**.
- **Schema.** The set of tables, columns, types, keys, and constraints. A library's
  relationship to the schema — does it own it (**code-first**), read it
  (**db-first** / introspection), or track a separate declaration (**schema-first**) — is
  a primary classifier (see [Schema, migrations & code generation](#schema-migrations-code-generation)).
- **DDL vs DML.** _Data Definition Language_ (`CREATE TABLE`, `ALTER`) shapes the schema;
  _Data Manipulation Language_ (`SELECT`/`INSERT`/`UPDATE`/`DELETE`) moves rows. Most of
  this survey is about generating DML; migrations (below) are about DDL.

---

## Connections, pools, and sessions

- **Connection.** A single, stateful session with the database server — a socket plus
  server-side state (the current transaction, prepared statements, session variables). A
  connection is **not** thread-safe and processes one statement at a time.
- **Connection pool.** Because opening a connection is expensive (TCP + TLS + auth
  handshake), production systems keep a **pool** of open connections and lease one per
  unit of work. Pool acquisition, sizing, and release are a core resource-lifetime concern
  — the surveyed effect systems model it with a **scoped** acquire/release
  ([Effect TS][effect-ts]'s `Acquirer`, [ZIO][quill]'s `Scope`/`ZLayer`) so a leaked
  connection is a type error, not a runtime leak.
- **Prepared statement.** SQL sent to the server once for parse+plan, then executed many
  times with different parameter values. Prepared statements are both a **performance**
  mechanism (plan reuse) and the **safety** mechanism behind parameter binding (below):
  the query text and the data travel on separate channels, so data can never be parsed as
  SQL.
- **Cursor.** A server-side handle that streams a large result set in chunks instead of
  buffering it whole — the substrate under a library's `stream`/`Stream` API.

---

## Statements, parameters, and SQL injection

- **String interpolation vs parameter binding.** The defining safety fork. _Interpolating_
  a value into SQL text (`"... WHERE id = " + userId`) lets a hostile value change the
  query's structure — **SQL injection**, the archetypal web vulnerability. _Binding_ a
  value as a **parameter** (a placeholder `?` / `$1` / `:id` whose value is transferred
  out-of-band) makes injection structurally impossible: the value is never SQL text.
- **Bind parameter / placeholder.** The out-of-band value slot. Dialects differ on syntax
  (`?` for MySQL/SQLite, `$1…$n` for PostgreSQL, `:name`/`@name` named forms), which is one
  reason a library carries a **dialect** (below).
- **The safety spectrum.** Libraries make binding the _default_ in three broad ways:
  1. **Tagged templates** — an interpolation that looks like string-building but compiles
     to a parameterized statement, capturing every `${expr}` as a bind parameter. See
     [Effect TS][effect-ts] (`` sql`... WHERE id = ${id}` ``) and `postgres.js`.
  2. **Query builders / DSLs** — you never write SQL text at all; you compose typed
     fragments, and values enter only through binding APIs. See `jOOQ`, `Kysely`,
     `Diesel`, [Slick][slick].
  3. **Quoted / compiled DSLs** — a macro turns a host-language expression into an AST,
     and only that AST is rendered to SQL; user values become **lifts** (bound params).
     See [Quill][quill].

  Each mechanism has an **escape hatch** for raw SQL (`sql.unsafe`, `sql"..."`, `queryRaw`)
  that re-exposes injection risk — a library's ergonomics are partly about how rarely you
  reach for it.

---

## Query construction models

_How a query is expressed_ — the axis the [taxonomy][index] cuts on. Six recurring models:

| Model                        | The query is…                                                     | Checked…        | Systems                                                                     |
| ---------------------------- | ----------------------------------------------------------------- | --------------- | --------------------------------------------------------------------------- |
| **Raw string**               | a `String` you assemble                                           | never           | Go `database/sql`, `Dapper`, `JDBI` (SQL objects)                           |
| **Tagged template**          | an interpolated literal that captures params                      | runtime         | [Effect TS][effect-ts], `postgres.js`                                       |
| **Fluent typed builder**     | a chain of method calls mirroring SQL clauses                     | compile         | `jOOQ`, `Kysely`, `Diesel`, `Drizzle`, `Exposed`                            |
| **Quoted DSL → AST**         | a host-language expression a macro reifies to an AST, then to SQL | compile         | [Quill][quill], `linq2db`/EF Core ([LINQ](#linq-language-integrated-query)) |
| **Typed relational algebra** | a value in an embedded algebra of `select`/`restrict`/`aggregate` | compile (types) | `Opaleye`, `Squeal`, `Beam`, [Slick][slick]                                 |
| **Macro-checked raw SQL**    | raw SQL a build step verifies against a live/described schema     | compile         | `sqlx` (Rust), `sqlc` (Go), `cornucopia`                                    |

Two cross-cutting notions:

- **AST (abstract syntax tree).** An in-memory tree representing the query independent of
  its SQL text — the intermediate form a builder or quoted DSL manipulates before a
  **dialect** renders it. Reifying the query as data is what lets a library retarget
  dialects, optimize, and inspect the generated SQL.
- **LINQ (Language-Integrated Query).** Microsoft's model where ordinary language
  expressions (`where`/`select` lambdas) are captured as **expression trees** and
  translated to SQL — the .NET analogue of Quill's quotation. EF Core and `linq2db` are
  LINQ providers.
- **Phantom types / type-level schema.** A type parameter carrying schema information (a
  table's column set, a query's result shape) that has no runtime representation — the
  compiler uses it to reject a query referencing a non-existent column or a type-mismatched
  comparison. The mechanism behind `Squeal`/`Opaleye`/`Beam` (Haskell), [Slick][slick],
  and `Kysely`'s type-only builder.
- **Compile-time vs runtime construction.** _When_ the SQL string is produced. A
  [Quill][quill] `quote{}` is normalized and, where possible, rendered to SQL **at compile
  time**; a builder like `jOOQ` renders **at runtime** from an AST. Compile-time
  construction can be faster and enables build-time SQL logging, but restricts
  expressiveness to what the macro can see.

---

## Dialects, idioms, and naming strategies

- **SQL dialect (idiom).** SQL is standardized but every engine diverges — placeholder
  syntax, `LIMIT`/`OFFSET` vs `TOP`, `RETURNING`, upsert grammar, quoting. A library that
  generates SQL carries a **dialect** (Quill calls it an **`Idiom`**; Effect calls it a
  **`Compiler`** parameterized by `Dialect`) that turns the AST into engine-specific text.
- **Naming strategy.** The rule mapping host-language identifiers (`firstName`, `BlogPost`)
  to database names (`first_name`, `blog_post`) — snake-case conversion, pluralization,
  quoting. Quill makes this an explicit `NamingStrategy` type; ORMs bury it in conventions.

---

## Schema, migrations & code generation

- **Migration.** A versioned, ordered change to the schema (a numbered `CREATE`/`ALTER`
  script or a code object). A **migration runner** records which have been applied (in a
  bookkeeping table) and applies the pending ones, ideally each inside a transaction.
- **The schema-ownership question.** Three stances:
  - **Code-first** — the entities/models _are_ the schema; the tool emits migrations from
    them (EF Core, Django, Prisma, TypeORM, `Beam`).
  - **Schema-first** — a separate schema declaration (a `.prisma` file, a `.sql` file, a
    Slick/jOOQ codegen input) is the source of truth.
  - **Database-first** — the live database is the source of truth; the tool **introspects**
    it and **generates** typed code (`jOOQ`, `sqlc`, `sqlx`'s macros, EF Core scaffolding).
- **Introspection.** Reading the live schema (catalog tables) to discover columns/types.
- **Code generation.** Emitting typed host-language code (structs, column constants,
  decoders) from a schema or from the SQL queries themselves — the defining move of `sqlc`,
  `cornucopia`, `jOOQ`, and `ent`.

---

## Type mapping and result decoding

- **Codec / encoder / decoder.** The pair of functions moving a host value into a bind
  parameter (**encoder**) and a result cell back into a host value (**decoder**). Typed
  libraries make these first-class and composable (skunk's `Codec`, Quill's
  `GenericEncoder`/`GenericDecoder`, Diesel's `FromSql`/`ToSql`).
- **Row mapping / hydration.** Assembling a result row into a host object — positionally,
  by column name, or by compile-time-derived mapping. Hydrating a whole object graph
  (entity + its relations) is the ORM's job.
- **Nullability.** Whether a column/expression can be `NULL`, and how the library reflects
  it in the host type (`Option`/`Maybe`/nullable `T?`). Getting nullability into the type
  system is a headline feature of `sqlx`, `Kysely`, `Squeal`, and [Slick][slick].

---

## ORM patterns

The classic enterprise patterns (Fowler, _Patterns of Enterprise Application
Architecture_, 2002) that separate a **full ORM** from the lower rungs:

- **Active Record.** An object that carries both data _and_ its own persistence methods
  (`user.save()`, `User.find(1)`); the class maps 1:1 to a table. The pattern behind Rails
  ActiveRecord, Django ORM, GORM, and TypeORM's active-record mode.
- **Data Mapper.** A separate layer moves data between objects and the database, keeping
  the objects **persistence-ignorant**. Hibernate/JPA, EF Core, SQLAlchemy ORM, and
  Doctrine follow this pattern; the _functional_ data mappers ([doobie][doobie],
  [Quill][quill], [Ecto][ecto]) share its separation but drop the mutable-object part.
- **Identity Map.** A per-session cache ensuring one row ↦ one in-memory object, so two
  loads of the same entity return the _same_ instance (and edits don't diverge).
- **Unit of Work.** A session that accumulates the objects you create/modify/delete and
  works out the minimal set of SQL statements to persist them **on flush/commit**, in the
  right order. EF Core's `SaveChanges`, Hibernate's `Session`, and SQLAlchemy's `Session`
  are units of work.
- **Change tracking.** The mechanism (snapshotting or proxies) by which a unit of work
  detects which loaded entities were mutated, so it can emit `UPDATE`s for exactly those.
- **Repository.** A collection-like abstraction over persisted aggregates
  (`repo.insert`, `repo.findById`) — Ecto's `Repo`, Effect's `SqlModel.makeRepository`.

---

## Loading strategies and the N+1 problem

- **Lazy vs eager loading.** A **lazy** relation is fetched only when first accessed (a
  proxy triggers a query on `user.posts`); an **eager** one is fetched up front (via a
  join or a second query). Lazy loading is convenient and the classic ORM foot-gun.
- **The N+1 problem.** Loading N parent rows and then triggering one query per parent to
  fetch a relation — N+1 round-trips where a single join would do. Every ORM has mitigation
  (eager `include`/`join fetch`, batch loaders). The functional mappers avoid it by making
  the join explicit; Effect's `SqlResolver` attacks it with **DataLoader-style batching**
  (coalescing many keyed lookups into one `WHERE id IN (…)`).

---

## Effects, transactions, and error handling

- **Blocking vs async vs effect-typed.** _How_ the library returns a result. **Blocking**
  APIs occupy the calling thread until the row arrives (JDBC, Go `database/sql`, ADO.NET).
  **Async** APIs return a future/promise/`Task` (EF Core, `sqlx`, `postgres.js`).
  **Effect-typed** APIs return a _description_ of the work as a first-class value in an
  **effect system** — `IO`/`ZIO`/`Effect`/`ConnectionIO` — that the runtime interprets,
  carrying the required environment and the possible errors in its type.
- **Effect system / monadic IO.** A value of type `Effect<A, E, R>` (Effect TS),
  `ZIO[R, E, A]` (Quill's ZIO contexts), `IO[A]`/`ConnectionIO[A]` (doobie/skunk) is a
  **description** of a computation that may fail with `E` and needs environment `R`,
  composed with `map`/`flatMap` and run at the edge of the program. Making database access
  an effect value (rather than an eagerly-run call) is the premise of an **algebraic
  effects-first** design and the reason this survey weights these libraries heavily.
- **Typed error channel.** The set of failures a query can produce, reflected in the
  **type** rather than thrown. Effect TS models it as a single `SqlError` over an 11-case
  reason union; Quill's ZIO contexts narrow to a `SQLException` channel; doobie/skunk keep
  errors in the effect's error type. Contrast with the exception-based mainstream (JDBC's
  `SQLException`, ADO.NET's `DbException`).
- **Transaction.** A group of statements that commit or roll back atomically. Libraries
  expose it as a combinator wrapping a block of work (`withTransaction(effect)`,
  `transaction { … }`), committing on success and rolling back on failure/exception.
- **Savepoint.** A nested checkpoint within a transaction, letting an inner block roll back
  without aborting the outer transaction — how the effect systems implement **nested**
  `withTransaction` (a top-level `BEGIN`, inner `SAVEPOINT`s).
- **Isolation level.** How concurrent transactions are shielded from each other
  (`READ COMMITTED` … `SERIALIZABLE`); a serialization failure is a retryable error, which
  is why Effect's `SqlError` reasons carry an `isRetryable` flag.

---

## The landscape at a glance

| Family                             | Query model                                    | Effect/async model               | Schema stance    | Survey pages                                                             |
| ---------------------------------- | ---------------------------------------------- | -------------------------------- | ---------------- | ------------------------------------------------------------------------ |
| **Effect-system SQL**              | tagged template / quoted DSL                   | effect value (typed errors)      | code-agnostic    | [Effect TS][effect-ts], [Quill][quill], [doobie][doobie], [skunk][skunk] |
| **Functional data mapper (eager)** | composable query macros                        | eager, immutable (tagged tuples) | code-first       | [Ecto][ecto]                                                             |
| **Functional-relational (typed)**  | typed relational algebra / builder             | effect value or future           | code / db-first  | [Slick][slick], `Squeal`, `Opaleye`, `Beam`                              |
| **Typed query builder**            | fluent typed builder                           | async or blocking                | db-first codegen | `jOOQ`, `Kysely`, `Diesel`, `Drizzle`, `Exposed`                         |
| **Macro-checked raw SQL**          | raw SQL verified at build                      | async or blocking                | db-first         | `sqlx`, `sqlc`, `cornucopia`                                             |
| **Full ORM (data mapper)**         | LINQ / criteria / method chains + unit of work | async or blocking                | code-first       | EF Core, Hibernate, SQLAlchemy, Prisma                                   |
| **Full ORM (active record)**       | model methods + query methods                  | blocking or async                | code-first       | ActiveRecord, Django ORM, GORM, TypeORM                                  |
| **Micro-mapper / driver**          | raw SQL + auto-bind + hydrate                  | blocking or async                | none             | `Dapper`, `hasql`, `JDBI`, Go `database/sql`, `postgres.js`              |

---

## Sources

- E. F. Codd, _A Relational Model of Data for Large Shared Data Banks_ (CACM, 1970) — the
  relational model.
- M. Fowler, _Patterns of Enterprise Application Architecture_ (2002) — [Active
  Record][ar], [Data Mapper][dm], [Identity Map][im], [Unit of Work][uow], [Lazy
  Load][ll], and the [catalog][eaa].
- OWASP, [SQL Injection][owasp] — the vulnerability parameter binding prevents.
- Per-library primary sources are cited in each deep-dive; the effect/transaction model
  claims here are grounded in [Effect TS][effect-ts] and [Quill][quill].

<!-- References -->

[index]: ./index.md
[comparison]: ./comparison.md
[effect-ts]: ./effect-ts.md
[quill]: ./quill.md
[doobie]: ./doobie.md
[skunk]: ./skunk.md
[slick]: ./slick.md
[ecto]: ./ecto.md
[ar]: https://martinfowler.com/eaaCatalog/activeRecord.html
[dm]: https://martinfowler.com/eaaCatalog/dataMapper.html
[im]: https://martinfowler.com/eaaCatalog/identityMap.html
[uow]: https://martinfowler.com/eaaCatalog/unitOfWork.html
[ll]: https://martinfowler.com/eaaCatalog/lazyLoad.html
[eaa]: https://martinfowler.com/eaaCatalog/
[owasp]: https://owasp.org/www-community/attacks/SQL_Injection

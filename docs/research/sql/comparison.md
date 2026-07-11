# Comparison & Synthesis

The capstone of the [SQL & ORM abstraction survey][index]. It reads the ~30 deep-dives
against one another along the survey's [fixed five-dimension spine](#the-five-dimension-spine),
names the [points the whole field agrees on](#the-consensus-standard), isolates the
[trade-offs that are still genuinely open](#architectural-trade-offs-still-genuinely-open),
and closes with [where an effects-first `sparkles:sql` fits](#where-an-effects-first-sparkles-sql-fits).

**Last reviewed:** July 12, 2026

> [!NOTE]
> The [master catalog][index] already gives the one-line-per-system summary; this page is
> the cross-cutting analysis. Every claim about a specific library is grounded in its
> deep-dive; follow the link for the verbatim source citation.

---

## At-a-glance matrix

Each surveyed system by the two axes that most determine its character: **how a query is
made injection-safe**, and **what the library does with the effect of running it**. The
"Compile-time query check?" column is the sharpest differentiator — it separates libraries
that catch a bad column or type _before the program runs_ from those that discover it at
runtime.

| System                       | Rung                     | Injection-safety mechanism                   | Compile-time query check?         | Effect model                    |
| ---------------------------- | ------------------------ | -------------------------------------------- | --------------------------------- | ------------------------------- |
| Go [`database/sql`][gds]     | Driver                   | Positional placeholders (driver)             | No                                | Blocking (pool)                 |
| [`postgres.js`][pgjs]        | Driver + safe-SQL        | Tagged template → `$n` params                | No                                | Async (thenable)                |
| [Dapper][dapper]             | Micro-mapper             | Anonymous-object params → `DbParameter`      | No                                | Blocking / async                |
| [JDBI][jdbi]                 | Micro-mapper             | Named/positional bind (`:id`)                | No                                | Blocking                        |
| [hasql][hasql]               | Micro-mapper             | Positional `Encoders` (out-of-band)          | No (opt-in via `hasql-th`)        | Blocking `IO`                   |
| [Effect TS][effect-ts]       | Functional data mapper   | Tagged template → auto `Parameter`           | No (runtime compile)              | Effect value (typed `SqlError`) |
| [doobie][doobie]             | Functional data mapper   | `sql"..."` → `Put`-bound `?`                 | No (opt-in `.check` vs live DB)   | `ConnectionIO` (cats-effect)    |
| [skunk][skunk]               | Functional data mapper   | Typed `Codec` fragments (never interpolates) | No (runtime `Describe`)           | cats-effect + fs2               |
| [Ecto][ecto]                 | Functional data mapper   | Query macros + `^` pin operator              | Partial (macro-checked)           | Eager, blocking (BEAM)          |
| [Quill][quill]               | Functional data mapper   | Compile-time quotation → lifts               | **Yes** (static translation)      | Pluggable; ZIO                  |
| [Slick][slick]               | Functional-relational    | Lifted embedding (`Rep[T]`)                  | **Yes** (types)                   | `DBIO` → effect-poly `F`        |
| [Diesel][diesel]             | Typed query builder      | Fluent builder → bound params                | **Yes** (types)                   | Blocking                        |
| [sqlx][sqlx]                 | Macro-checked raw SQL    | Real bind params                             | **Yes** (`query!` vs live DB)     | Async                           |
| [sqlc][sqlc]                 | SQL-to-code generator    | Real bind params                             | **Yes** (static SQL parse)        | Blocking (generated)            |
| [jOOQ][jooq]                 | Typed query builder      | Fluent builder → `?` bind                    | **Yes** (types, from codegen)     | Blocking (+ R2DBC)              |
| [Kysely][kysely]             | Typed query builder      | Fluent builder → placeholders                | **Yes** (types, from a `DB` type) | Async                           |
| [Drizzle][drizzle]           | Typed query builder      | SQL-like builder → `Param`                   | **Yes** (types, from schema)      | Async                           |
| [Exposed][exposed]           | Typed builder + DAO      | DSL `Op`/`QueryBuilder` params               | **Yes** (types)                   | Blocking (+ coroutine)          |
| [Squeal][squeal]             | Typed query builder      | Type-level schema + `EncodeParams`           | **Yes** (type-level)              | Indexed `PQ` monad              |
| [Opaleye][opaleye]           | Typed query builder      | Escaped literals (postgresql-simple)         | **Yes** (types)                   | Blocking `IO`                   |
| [Beam][beam]                 | Typed data mapper        | HKD query DSL → `val_` params                | **Yes** (types)                   | Blocking `IO`                   |
| [linq2db][linq2db]           | LINQ provider            | LINQ closure values → params                 | Partial (C#-typed, runtime SQL)   | Async / sync                    |
| [EF Core][ef-core]           | Full ORM (data mapper)   | LINQ → params                                | Partial (C#-typed, runtime SQL)   | Async                           |
| [Hibernate][hibernate]       | Full ORM (data mapper)   | JPQL/Criteria named params                   | Partial (Criteria typed; HQL not) | Blocking (+ reactive)           |
| [SQLAlchemy][sqlalchemy]     | Full ORM + Core          | Core expression → bind params                | Partial (Core-typed; runtime)     | Blocking (+ asyncio)            |
| [Django ORM][django-orm]     | Full ORM (active-record) | `QuerySet` values → params                   | No                                | Blocking (+ async)              |
| [Prisma][prisma]             | Full ORM (schema-first)  | Generated client → params                    | **Yes** (from `.prisma` schema)   | Async                           |
| [TypeORM][typeorm]           | Full ORM (AR + DM)       | Repository/QueryBuilder `:param`             | Partial (entity-typed; runtime)   | Async                           |
| [SeaORM][sea-orm]            | Full ORM (dynamic)       | `sea-query` `Value` bind                     | Partial (entity-typed; runtime)   | Async                           |
| [GORM][gorm]                 | Full ORM (active-record) | `clause.Expr` `?` bind                       | No (reflection)                   | Blocking                        |
| [ent][ent]                   | Full ORM (codegen)       | Generated typed predicates → params          | **Yes** (from schema codegen)     | Blocking                        |
| [persistent + esqueleto][pe] | Full ORM + typed joins   | TH entities + `val` params                   | **Yes** (types)                   | Blocking `SqlPersistT`          |
| [ActiveRecord][activerecord] | Full ORM (active record) | `sanitize_sql` bound params                  | No                                | Blocking                        |

Two structural observations fall straight out of the matrix:

1. **Injection safety is a solved problem, mechanically.** Every surveyed library — from the
   thinnest driver to the heaviest ORM — makes bound parameters the default and reserves a
   loudly-named escape hatch (`sql.unsafe`, `$queryRawUnsafe`, `Arel.sql`, `sql.raw`,
   `FromSqlRaw`, `Fragment.const`) for raw text. The interesting variation is _how the safe
   default is expressed_ (a tagged template, a builder, a macro, a quotation), not _whether_
   it exists.
2. **Compile-time query checking is the real fault line.** It cleaves the field into three
   camps: **statically-checked** (Quill, Diesel, sqlx, sqlc, jOOQ, Kysely, Drizzle, Squeal,
   Opaleye, Beam, ent, Prisma, esqueleto — a _wrong column or type won't compile_),
   **runtime-constructed but host-typed** (the LINQ/Criteria ORMs — EF Core, Hibernate,
   SQLAlchemy Core, linq2db — where the host language types the expression but the SQL and
   its DB-validity are resolved at runtime), and **stringly-dynamic** (the driver/micro-mapper
   tier + the reflection ORMs — GORM, Django, ActiveRecord — where nothing checks the SQL
   against the schema until it executes).

---

## The five-dimension spine

The same analytical cuts every deep-dive uses, read across the whole corpus.

### 1. Connection, pooling & resource lifetime

The universal substrate. Every non-trivial library ships or wraps a **connection pool**,
because the connect handshake dominates per-query latency. The design variation is in _how
acquisition and release are scoped_:

- **Manual / ambient** — Go [`database/sql`][gds]'s `*sql.DB` is a pool you pass around;
  [ActiveRecord][activerecord] and [Django ORM][django-orm] bind a connection to the current
  thread/task implicitly; [Exposed][exposed] and [Hibernate][hibernate] use a thread-local
  or context-bound session. Convenient, but a leaked or mis-scoped connection is a runtime
  bug.
- **Scoped as a value** — the effect systems make lifetime a _type_. [Effect TS][effect-ts]'s
  `Acquirer` is an `Effect<Connection, SqlError, Scope>`; [skunk][skunk] and [doobie][doobie]
  hand you a `Resource[F, …]`; [Quill][quill]'s ZIO contexts use `ZLayer`/`Scope`;
  [Squeal][squeal] wraps `bracket`. Here a leaked connection is a _compile-time_ impossibility
  — the `Scope`/`Resource` guarantees release on every exit path, success or failure. This is
  the single most transferable idea for an effects-first design.

### 2. Query construction & injection safety

The survey's richest axis, with six recurring models ([concepts][models]). Ranked roughly
by how much the compiler knows:

- **Raw string** (Go `database/sql`, [Dapper][dapper], [JDBI][jdbi] SQL objects) — maximum
  control, zero static knowledge.
- **Tagged template** ([Effect TS][effect-ts], [postgres.js][pgjs], [doobie][doobie]) — reads
  like string interpolation, compiles to a parameterized statement. `postgres.js` is the most
  elegant point in this space: the _same_ `sql` function is the query tag _and_ the fragment
  builder (`sql(obj)` for inserts, `sql(arr)` for `IN`, `sql('col')` for identifiers).
- **Macro-checked raw SQL** ([sqlx][sqlx], [sqlc][sqlc]) — you still write SQL, but a build
  step validates it and infers result types. sqlx checks against a _live_ DB (or a committed
  `.sqlx` cache); sqlc _parses_ the SQL statically with an embedded real grammar
  (`libpg_query`), needing no DB connection.
- **Fluent typed builder** ([jOOQ][jooq], [Kysely][kysely], [Diesel][diesel],
  [Drizzle][drizzle], [Exposed][exposed], [SeaORM][sea-orm]) — you never write SQL text; a
  method chain typed by a schema (generated, or a supplied type) produces it. Kysely is the
  purest "type-only" form (the schema is _just_ a TypeScript type, erased at runtime).
- **Typed relational algebra** ([Slick][slick], [Squeal][squeal], [Opaleye][opaleye],
  [Beam][beam], esqueleto) — the query is a value in an embedded algebra whose _types_ encode
  the schema; the Haskell trio pushes this furthest (Squeal reifies the entire schema as a
  type; Beam's higher-kinded data reuses one record for values and query expressions).
- **Quoted DSL / LINQ → AST** ([Quill][quill], [EF Core][ef-core], [linq2db][linq2db]) — a
  macro or expression-tree capture turns ordinary host-language code into an AST, then SQL.
  Quill is the compile-time extreme (SQL is generated _during compilation_ where possible).

The **escape hatch** is universal and universally dangerous; the mark of a good design is how
rarely you need it and how loudly it announces itself.

### 3. Schema, migrations & code generation

Three stances ([concepts][schema]), and a clean split on _who owns the truth_:

- **Code-first** (models → schema): [EF Core][ef-core], [Django ORM][django-orm],
  [Prisma][prisma] (schema-file-first, really), [TypeORM][typeorm], [Beam][beam],
  [Drizzle][drizzle], [Ecto][ecto], [GORM][gorm], [ent][ent], [Exposed][exposed]. The ORM
  emits migrations from the model.
- **Db-first** (introspect → generate): [jOOQ][jooq], [sqlc][sqlc], [sqlx][sqlx],
  [Diesel][diesel], [Kysely][kysely] (via codegen), [Opaleye][opaleye], [ActiveRecord][activerecord]
  (`schema.rb`). The database is the truth; typed code is generated from it.
- **Schema-agnostic** (no schema at all): the driver/micro-mapper tier ([doobie][doobie],
  [skunk][skunk], [hasql][hasql], [Dapper][dapper], [JDBI][jdbi], Go `database/sql`,
  [postgres.js][pgjs]) — you bring your own schema and migration tool.

A recurring, important finding: **migrations are frequently _not_ the query library's job.**
[SQLAlchemy][sqlalchemy] delegates to Alembic; [Hibernate][hibernate] to Flyway/Liquibase;
[ent][ent] to Atlas; [sqlc][sqlc] reads a schema but runs no migrations; the whole
functional-mapper tier omits them by design. A migration runner is a separable concern.

### 4. Type mapping & result decoding

How a row becomes a typed value, and how much of that mapping is checked. The elegant designs
make the codec **composable and first-class**: [skunk][skunk]'s `Codec` and
[hasql][hasql]'s `Encoders`/`Decoders` compose bidirectionally like parser combinators;
[Quill][quill] derives `GenericEncoder`/`GenericDecoder` at compile time; the Haskell
profunctor libraries ([Opaleye][opaleye]) drive both binding and decoding from one `Default`
instance. The ORMs hydrate whole object graphs (and pay for it with lazy-loading and N+1
hazards — see below). The micro-mappers ([Dapper][dapper] IL-emits a per-shape materializer;
[JDBI][jdbi]'s `RowMapper`s; sqlx/sqlc generate the struct) sit in between: typed row→object
mapping without graph management.

### 5. Effect model, transactions & error handling

The dimension that most divides the field, and the one this survey weights most heavily.

- **Effect model.** Three tiers: **blocking** (the JVM/Go/Ruby/Python mainstream + the
  Haskell `IO` libraries), **async** (the .NET/TS/Rust mainstream — futures/`Task`/Promises),
  and **effect value** (the description-as-a-value tier: [Effect TS][effect-ts]'s `Effect`,
  [Quill][quill]'s ZIO, [doobie][doobie]/[skunk][skunk]'s cats-effect `F`, [Slick][slick]'s
  effect-polymorphic `DBIO`, [Squeal][squeal]'s indexed `PQ`). Only the last makes the
  _required environment_ and the _possible errors_ part of the query's type.
- **Transactions.** Near-universal shape: a **combinator wrapping a block**
  (`withTransaction(effect)`, `transaction { … }`, `sql.begin(fn)`, `inTransaction`), committing
  on success and rolling back on failure. **Nesting via savepoints** is common but _not_
  universal — [Effect TS][effect-ts], [Quill][quill], [EF Core][ef-core], [Hibernate][hibernate],
  [jOOQ][jooq], [SQLAlchemy][sqlalchemy], [Prisma][prisma], [postgres.js][pgjs], [Django ORM][django-orm]
  emit real `SAVEPOINT`s for nested transactions, while [ent][ent] (returns `ErrTxStarted`),
  [Slick][slick], and [linq2db][linq2db] (one flat transaction per connection) do not.
- **Errors.** Three approaches, in ascending order of type-safety: **thrown exceptions** (the
  mainstream — `SQLException`, `DbException`, `HibernateException`, `PersistException`, Prisma's
  `P####` codes), a **narrowed exception channel** ([Quill][quill]'s `ZIO[…, SQLException, …]`,
  doobie's `MonadError[F, Throwable]`), and a **structured typed error union** — the design
  frontier, held essentially alone by [Effect TS][effect-ts]'s `SqlError` over an 11-case
  `SqlErrorReason` discriminated union, each case carrying an `isRetryable` flag. No other
  surveyed library models "unique violation vs deadlock vs serialization failure" as distinct,
  matchable, retryable-aware _types_.

---

## The consensus standard

Points on which the entire field — thin to heavy, across a dozen languages — has converged.
A `sparkles:sql` that violated any of these would be objectively behind the state of the art:

1. **Parameter binding is the default; raw text is an opt-in escape hatch.** Non-negotiable.
2. **Connections are pooled**, and the pool is safe for concurrent use.
3. **Transactions are a block-scoped combinator** that commits on success and rolls back on
   failure/exception.
4. **Result rows map to typed values** — even the thinnest mappers (Dapper, sqlx, JDBI) refuse
   to leave you with untyped column bags.
5. **Dialect differences are abstracted** behind a compiler/`Idiom`/`Dialect`, so one query
   targets many engines.
6. **Migrations are a separable concern** — increasingly delegated to a dedicated tool (Alembic,
   Flyway, Atlas) rather than baked into the query layer.

---

## Architectural trade-offs (still genuinely open)

Where the field has _not_ converged — the real design decisions:

| Trade-off                                  | The two poles                                                                                                                                                  | Where the survey lands                                                                                                                                                         |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Compile-time vs runtime query checking** | Static ([Quill][quill], [sqlx][sqlx], [Diesel][diesel], the Haskell trio) vs runtime ([EF Core][ef-core], [GORM][gorm])                                        | Static catches more bugs but constrains expressiveness and lengthens builds; the strongest static designs pay in type complexity.                                              |
| **Write-SQL vs build-SQL**                 | Raw SQL, checked ([sqlx][sqlx], [sqlc][sqlc], [doobie][doobie]) vs a typed builder/DSL ([jOOQ][jooq], [Diesel][diesel], [Slick][slick])                        | No winner. Raw-SQL-checked keeps SQL legible and skips a DSL; builders compose and retarget dialects. Both beat stringly-dynamic.                                              |
| **Explicit persistence vs unit of work**   | Explicit writes ([Ecto][ecto], [doobie][doobie], the functional tier) vs implicit flush ([Hibernate][hibernate], [EF Core][ef-core], [SQLAlchemy][sqlalchemy]) | The unit of work is powerful but the source of ORMs' hardest bugs (flush timing, lazy-load N+1, `LazyInitializationException`). The functional mappers reject it deliberately. |
| **Effect value vs async vs blocking**      | Effect value ([Effect TS][effect-ts], [Quill][quill], cats-effect) vs `Promise`/`Task` vs blocking                                                             | Effect values make environment + errors typed and composition lawful, at the cost of a runtime and a learning curve.                                                           |
| **Typed errors vs exceptions**             | A reason union ([Effect TS][effect-ts]) vs thrown `SQLException`                                                                                               | The typed-union frontier is essentially unoccupied; it is where the most design headroom remains.                                                                              |
| **Schema ownership**                       | Code-first vs db-first vs none                                                                                                                                 | Follows the product: greenfield favours code-first migrations; integrating-an-existing-DB favours db-first codegen.                                                            |

---

## Where an effects-first `sparkles:sql` fits

The survey exists to inform an **algebraic effects-first** D library. Read as a design brief,
the corpus points to a clear position: **a functional data mapper that stops below the
full-ORM rung** — typed, composable queries and explicit, effect-typed persistence, _without_
an identity map or an implicit unit of work. That is exactly where [Effect TS][effect-ts],
[Quill][quill], [doobie][doobie], [skunk][skunk], and [Ecto][ecto] sit, and it is the design
centre the effects-first premise most naturally serves.

The most transferable ideas, by dimension:

- **The service seam = the query constructor.** [Effect TS][effect-ts]'s sharpest move is that
  the injected `SqlClient` service _is_ the `sql` tagged-template function. A D analogue: the
  capability handed in by the effect layer is itself the query builder, so obtaining "the
  database" and "the way to write a query" are one act. Pairs naturally with D's
  [Design-by-Introspection](../../guidelines/design-by-introspection-01-guidelines.md)
  capability-detection style.
- **Scoped acquisition as the resource discipline.** Model the connection/pool as a
  scoped acquire/release ([Effect TS][effect-ts]'s `Acquirer`, [skunk][skunk]'s `Resource`),
  so a leaked connection is unrepresentable. D's `scope`/`@safe`/`-preview=dip1000` lifetime
  checking and the repo's `during`/`event-horizon` effect substrate are the natural fit.
- **A typed error _reason union_, not a bag of exceptions.** [Effect TS][effect-ts]'s
  `SqlErrorReason` (unique-violation / deadlock / serialization-failure / … each with
  `isRetryable`) is the single most under-adopted idea in the field and the best match for D's
  [`Expected!(T, E)`](../../guidelines/idioms/expected/index.md) error handling — a `sum`-typed
  error channel where a caller can _match_ on "was this a retryable serialization failure?".
- **Transaction-as-combinator with a fiber/context-local connection.** The universal
  `withTransaction(effect)` shape, with nesting lowered to real `SAVEPOINT`s and the active
  connection carried in the effect context (as [Effect TS][effect-ts]'s `TransactionConnection`
  and [Quill][quill]'s `FiberRef[Connection]` do) — so nested calls and batched resolvers
  transparently join the same transaction.
- **Safe query construction: a compile-time-checked template, not a builder.** Between Quill's
  compile-time quotation and Effect's runtime tagged-template, D can aim higher than either:
  D's `mixin` + CTFE + template machinery can make a **compile-time-parameterized SQL template**
  (values captured as binds, dialect rendered at compile time) that is injection-safe _by
  construction_ without an ORM DSL — closer to [Quill][quill]'s static translation but using D
  string-interpolation/IES rather than a macro. Keep [Quill][quill]'s clean `Idiom` (dialect)
  / `NamingStrategy` separation.
- **Composable codecs.** Adopt [skunk][skunk]/[hasql][hasql]'s bidirectional, combinator-composed
  `Codec` for row↔type mapping, `@nogc`-friendly and derivable via D introspection — not a
  reflection-driven ORM materializer.
- **Batching without an ORM.** [Effect TS][effect-ts]'s `SqlResolver` (DataLoader-style,
  transaction-keyed) shows how to kill N+1 _without_ lazy proxies — the functional answer to the
  ORM's hardest problem.

What to **not** borrow: the implicit unit of work, the identity map, lazy-loading proxies, and
ambient/thread-local session state — the machinery that makes [Hibernate][hibernate]/[EF
Core][ef-core]/[ActiveRecord][activerecord] powerful but is also the source of their subtlest
bugs, and which an effects-first, explicit-by-design library is precisely positioned to avoid.

> [!NOTE]
> This synthesis is prior-art analysis, not a committed design. A concrete `sparkles:sql`
> proposal — milestones, D API sketches, the `during`/`event-horizon` integration — is
> deferred to a later spec effort, for which this survey is the evidence base.

---

## Sources

- Every claim about a specific library is grounded in its deep-dive (linked above), each of
  which carries its own primary-source `Sources` section and a claim-by-claim grounding ledger.
- The shared vocabulary and the canonical pattern references (Codd; Fowler's _Patterns of
  Enterprise Application Architecture_; OWASP on SQL injection) are cited in [concepts][concepts].

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[models]: ./concepts.md#query-construction-models
[schema]: ./concepts.md#schema-migrations-code-generation
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

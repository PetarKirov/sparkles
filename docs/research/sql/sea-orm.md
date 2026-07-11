# SeaORM (Rust)

An async, **dynamic** relational mapper for Rust — entities are `derive`-generated structs (`Model` / `ActiveModel` / `Column` / `Relation`), queries are a runtime fluent builder over `sea-query`'s AST, and every call is a `Future` executed over a `sqlx` connection pool.

| Field              | Value                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Rust (`edition = "2024"`, `rust-version = "1.94.0"`)                                                                                   |
| License            | MIT OR Apache-2.0 (`Cargo.toml` `license`; `LICENSE-MIT` + `LICENSE-APACHE`)                                                           |
| Repository         | [SeaQL/sea-orm][repo]                                                                                                                  |
| Documentation      | [sea-ql.org/SeaORM][docs] · [docs.rs/sea-orm][docsrs]                                                                                  |
| Category           | [Full ORM][ladder] (data-mapper-leaning, with an active-record surface) — async & **dynamic**; no identity map / implicit unit of work |
| Abstraction level  | [Full ORM rung][ladder], but stops short of change-tracking-on-flush — the `ActiveModel` change-set is per-call and explicit           |
| Query model        | [Fluent builder][qcm] wrapping `sea-query`'s `SelectStatement` AST — a **runtime** value rendered to SQL at execution time             |
| Effect/async model | [Async][effects] (`Future` / `async fn`) over a `sqlx` pool; errors returned as `Result<T, DbErr>`, never thrown                       |
| Backends           | PostgreSQL, MySQL/MariaDB, SQLite — via `sqlx` `0.9` (plus a `rusqlite` driver, and `mock` / `proxy` connections for testing)          |
| First release      | `0.1.1`, 2021-08-08 (`CHANGELOG.md`; `0.1.0` ≈ 2021-08, web-attested)                                                                  |
| Latest version     | `2.0.0-rc.42` (the pinned tree; `2.0` is in release-candidate phase — `CHANGELOG.md`)                                                  |

> [!NOTE]
> SeaORM is this survey's data point for a **full ORM that keeps the query dynamic**.
> Where `Diesel` encodes a query's shape in the type system and renders SQL at compile
> time, SeaORM builds the query as an ordinary [runtime value][qcm] — a `sea-query` AST
> you mutate with `.filter(...)`, `.join(...)`, `.order_by(...)` and only lower to SQL
> when it runs. It is a relational mapper (entities, relations, [eager loading][nplusone],
> an `ActiveModel` change-set) that deliberately omits the ORM's heaviest machinery — no
> [identity map][orm], no session that snapshots and auto-flushes a diff. It layers that
> mapper on two lower libraries this survey also tracks: it is **built on `sqlx`** (drivers,
> pooling, async) and **`sea-query`** (the query AST). Terms below link to [concepts][concepts].

---

## Overview

### What it solves

SeaORM turns SQL tables into typed Rust entities and lets you query and mutate them with
a fluent, async API that feels like the mainstream ORMs — while keeping the generated
query a runtime, inspectable value rather than compile-time magic. Its one-line
positioning is the `Cargo.toml` `description` ([`Cargo.toml`][cargo]):

> _"🐚 An async & dynamic ORM for Rust"_

The `README` frames it for the web-service builder ([`README.md`][readme]): _"SeaORM is a
powerful ORM for building web services in Rust"_, and leans hard on familiarity for
developers arriving from other ecosystems ([`README.md`][readme]):

> _"Inspired by popular ORMs in the Ruby, Python, and Node.js ecosystem, SeaORM offers a
> developer experience that feels instantly recognizable."_

So it sits at the [full-ORM rung][ladder] alongside `ActiveRecord`, `GORM`, and `ent` — a
relational mapper with entities, declared relations, and eager loading — but it is a
data-mapper at heart: persistence is an explicit call (`model.insert(db)`,
`Entity::insert(active_model).exec(db)`), not a mutable self-persisting object with a
background session. It is the Rust counterpart to Go's `GORM` / `ent` more than to
`Diesel` (a typed query builder) or `sqlx` (a macro-checked driver), both of which this
survey also covers.

### Design philosophy

SeaORM's crate docs enumerate four pillars, each a verbatim claim from its own module
documentation ([`src/docs.rs`][srcdocs]). Two are load-bearing for this survey.

**Async, on top of `sqlx`.** SeaORM does not implement its own driver or pool; it wraps
`sqlx` ([`src/docs.rs`][srcdocs]):

> _"Relying on [SQLx](https://github.com/launchbadge/sqlx), SeaORM is a new library with
> async support from day 1."_

Every `.one(db)` / `.all(db)` / `.exec(db)` is an `async fn` returning a `Future`; a
`DatabaseConnection` is a `sqlx` pool.

**Dynamic, on top of `sea-query`.** The queries are not phantom-typed relational algebra;
they are a runtime AST you assemble ([`src/docs.rs`][srcdocs]):

> _"Built upon [SeaQuery](https://github.com/SeaQL/sea-query), SeaORM allows you to build
> complex queries without 'fighting the ORM'."_

This is the axis the metadata table calls _dynamic_: a `Select<E>` wraps a mutable
`sea_query::SelectStatement`, so a query can be branched, extended, and composed at
runtime from user input — the opposite trade-off from `Diesel`'s compile-time-checked
builder (more runtime flexibility, less compile-time query verification). The other two
pillars are **Testable** (_"Use mock connections to write unit tests for your logic"_) via
the `mock` feature, and **Service Oriented** (_"Quickly build services that join, filter,
sort and paginate data in APIs"_) ([`src/docs.rs`][srcdocs]).

The entity model is generated, not hand-written. A `Model` struct annotated with
`#[derive(DeriveEntityModel)]` and `#[sea_orm(table_name = "...")]` expands into the whole
entity — the `Entity` marker, the `Column` enum, the `PrimaryKey` enum, and the paired
`ActiveModel` ([`sea-orm-macros/src/lib.rs`][macros]). SeaORM `2.0` adds a denser
`#[sea_orm::model]` format that also emits the `ModelEx` / `ActiveModelEx` graph types
used by the nested loader and saver.

## Connection, pooling & resource lifetime

You open a database with `Database::connect`, passing a URL or a `ConnectOptions`
([`src/database/mod.rs`][dbmod]); it dispatches on the URL scheme to a `sqlx` connector
(`postgres://`, `mysql://`, `sqlite://`) and hands back a `DatabaseConnection`. That handle
_is_ the pool ([`src/database/db_connection.rs`][dbconn]):

> _"Behind the scenes this is a connection pool (for SQLx-backed drivers) or a shared
> connection (for `rusqlite` / mocks / proxies), so it is cheap to clone — pass `&DbConn`
> around or `db.clone()` into spawned tasks."_

`DatabaseConnection` wraps a `DatabaseConnectionType` enum whose variants are the `sqlx`
pool types (`SqlxMySqlPoolConnection`, `SqlxPostgresPoolConnection`,
`SqlxSqlitePoolConnection`), plus `rusqlite`, `mock`, and `proxy` connections
([`src/database/db_connection.rs`][dbconn]) — the same code runs against any of them
because query methods are generic over the connection ([`src/database/connection.rs`][conn]):

> _"Most query and mutation methods in SeaORM (`.one(db)`, `.all(db)`, `.exec(db)`, ...)
> take any `&impl ConnectionTrait`, so the same code works on a pool, a transaction, or a
> mock."_

`ConnectOptions` exposes pool sizing and timeouts — `max_connections`, `min_connections`,
`connect_timeout`, `idle_timeout`, `acquire_timeout`, `max_lifetime`, plus `sqlx_logging`
([`src/database/mod.rs`][dbmod]). Resource lifetime is **async RAII**, not a [scoped][pool]
effect: a leased connection is returned to the pool when the transaction or statement
future completes, and the pool is torn down when the last clone of the
`DatabaseConnection` is dropped. Pool exhaustion is a typed error, not a hang —
`DbErr::ConnectionAcquire(ConnAcquireErr::Timeout)` ([`src/error.rs`][error]). For result
sets too large to buffer, the `stream` feature adds `StreamTrait`, yielding rows one at a
time over a server-side [cursor][pool] ([`src/database/connection.rs`][conn]); `Cursor` and
`Paginator` build keyset- and offset-pagination on top ([`src/executor/cursor.rs`][cursor]).

## Query construction & injection safety

This is SeaORM's centre of gravity and the source of the "dynamic" label.

**A query is a runtime AST value.** `EntityTrait::find` returns a `Select<E>`, which wraps
a `sea_query::SelectStatement` ([`src/query/select.rs`][select]):

> _"A `SELECT` query against entity `E`. Returned by `EntityTrait::find`; chain filters,
> joins, ordering, and projections onto it, then run it on a `ConnectionTrait` with
> `.one(db)` / `.all(db)` / `.stream(db)` / `.paginate(db, n)`."_

Nothing touches the database while the query is built; the `Select` is inert data. You
refine it with the `QueryFilter`, `QuerySelect`, and `QueryOrder` traits — `filter`,
`select_only`, `column`, `join`, `group_by`, `having`, `order_by`, `limit`, `offset`
([`src/query/helper.rs`][helper]). Because the builder is a value, conditions can be
assembled **at runtime** from optional inputs — the canonical dynamic-query pattern, taken
verbatim from the `filter` docs ([`src/query/helper.rs`][helper]):

```rust
let mut conditions = Condition::all();
if let Some(name) = input.name {
    conditions = conditions.add(cake::Column::Name.contains(&name));
}
let cakes = cake::Entity::find().filter(conditions).all(db).await?;
```

`filter` accepts anything `IntoCondition` — a single column predicate or a whole
`Condition::all()` / `Condition::any()` tree (`AND` / `OR`), which nest arbitrarily and
compose with `add_option` for the "add this clause only if present" idiom
([`src/query/helper.rs`][helper]). The idiomatic surface reads like SQL clauses:

```rust
let chocolate: Vec<cake::Model> = Cake::find()
    .filter(Cake::COLUMN.name.contains("chocolate"))
    .all(db)
    .await?;

let cheese: Option<cake::Model> = Cake::find_by_id(1).one(db).await?;
```

**Values enter only as bound parameters.** A column predicate is produced by `ColumnTrait`
methods (`eq`, `ne`, `gt`, `lt`, `like`, `is_in`, `between`, …), each of which captures the
value as a `sea_query::Value` inside an `Expr` — never as SQL text
([`src/entity/column.rs`][column]). The comparison is a `BinOper` node in the AST, so
`Column::eq(v)` can never let `v` change the query's structure; `eq(None)` even lowers to
`IS NULL` ([`src/entity/column.rs`][column]). When the query runs, `QueryTrait::build`
renders the AST for the target backend into a `Statement` that keeps SQL and data on
**separate channels** ([`src/database/statement.rs`][stmt]):

```rust
pub struct Statement {
    pub sql: String,           // "backend-specific placeholders for the values"
    pub values: Option<Values>, // "bound parameter values, in the order they appear in `sql`"
    pub db_backend: DbBackend,
}
```

The `sql` carries placeholders (`$1`, `?`) and the `values` travel out-of-band, so a
prepared statement makes [SQL injection][inject] structurally impossible — the data is
never parsed as SQL. The `DbBackend` on the statement fixes the dialect (placeholder style,
quoting, `RETURNING` support), so the same `Select` renders to Postgres, MySQL, or SQLite
text.

**The escape hatch stays parameterized.** For the ~5% of queries too complex for the
builder, the `raw_sql!` macro splices SQL — but its interpolation compiles to bind
parameters, not string holes ([`src/lib.rs`][lib]):

> _"The `raw_sql!` macro is like the `format!` macro but without the risk of SQL
> injection."_

```rust
let cake_ids = [2, 3, 4]; // expanded by the `..` operator
let cake: Option<CakeWithBakery> = CakeWithBakery::find_by_statement(raw_sql!(
    Sqlite,
    r#"SELECT "cake"."name", "bakery"."name" AS "bakery_name"
       FROM "cake" LEFT JOIN "bakery" ON "cake"."bakery_id" = "bakery"."id"
       WHERE "cake"."id" IN ({..cake_ids})"#
))
.one(db)
.await?;
```

Each `{expr}` becomes a bind parameter and `{..ids}` expands to a parameter list, so the
raw path does not re-open injection for values. The genuinely unsafe door is the low-level
`Statement::from_string` (SQL text with no parameters), used only for statements you
construct entirely yourself.

## Schema, migrations & code generation

SeaORM supports **all three** [schema-ownership stances][schema] — a notable breadth.

- **Database-first (introspection codegen).** `sea-orm-cli generate entity` reads a live
  database and emits entity files, in `compact`, `expanded`, `dense` (new in `2.0`), or
  `frontend` formats ([`sea-orm-cli/src/cli.rs`][cli]). This is the recommended bootstrap:
  the `README` shows the dense format and notes _"You don't have to write this by hand!
  Entity files can be generated from an existing database using `sea-orm-cli`"_
  ([`README.md`][readme]).
- **Migration-first (programmatic DDL).** `sea-orm-migration` is a separate crate. A
  migration implements `MigrationTrait` with `up` / `down`, each handed a `SchemaManager`
  whose `create_table`, `alter_table`, `drop_table`, `create_index`, and
  `create_foreign_key` methods take `sea-query` DDL statements
  ([`sea-orm-migration/src/manager.rs`][manager]). A `MigratorTrait` records applied
  migrations in a `seaql_migrations` table and applies the pending ones; per-migration
  transaction wrapping is controlled by `use_transaction`
  ([`sea-orm-migration/src/lib.rs`][migration]).
- **Code-first (entities as the schema).** `Schema::create_table_from_entity` derives a
  `TableCreateStatement` from an `Entity` ([`src/schema/entity.rs`][schemaent]), and
  `2.0`'s **Entity First Workflow** (behind the `entity-registry` + `schema-sync` features)
  detects new entities/columns and syncs the database in dependency order
  ([`README.md`][readme]): `db.get_schema_registry("my_crate::entity::*").sync(db).await`.

So unlike `Ecto` (whose core ships no migration runner) or `Diesel` (migration-first with
SQL files), SeaORM covers introspection, programmatic migrations, and code-first sync from
one toolchain.

## Type mapping & result decoding

**Row hydration is by trait.** A `Model` is decoded from a `QueryResult` by
`FromQueryResult` (auto-derived); `ModelTrait` exposes `get` / `set` / `try_set` moving
values through `sea_query::Value` ([`src/entity/model.rs`][model]). `try_set` returns a
`DbErr` on a type mismatch, while `set` panics — _"prefer `try_set` when the value comes
from untrusted input"_ ([`src/entity/model.rs`][model]). Codecs ultimately bottom out in
`sqlx`'s per-backend `Encode` / `Decode`, so SeaORM inherits `sqlx`'s type coverage
(chrono, `uuid`, `rust_decimal`, JSON, Postgres arrays and `pgvector`, …) through feature
flags ([`Cargo.toml`][cargo]).

**Nullability is `Option<T>`.** A nullable column is a `Option<T>` field; the crucial
distinction is between `Set(None)` (write SQL `NULL`) and `NotSet` (omit the column
entirely), which the `ActiveValue` docs call out explicitly ([`src/entity/active_value.rs`][av]).

**Partial models curb overfetching.** `#[derive(DerivePartialModel)]` defines a struct that
selects only the columns it declares, and `#[sea_orm(nested)]` lets a partial model embed
another (partial or full) model for deep relational shapes without loading whole rows
([`README.md`][readme]); `into_partial_model` projects a `Select` down to it. Raw queries
decode the same way through `FromQueryResult` + `find_by_statement`.

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and where SeaORM's choices are
sharpest.

**Async `Future`, not an effect value.** Every terminal method is `async`: `find().one(db)`
returns a `Future<Output = Result<Option<Model>, DbErr>>`, awaited on whatever runtime
(`tokio`, `async-std`) the feature flags select. There is no `IO` / `ZIO` / `Effect` /
`ConnectionIO` wrapper ([effect-typed APIs][effects] in the survey's sense): the "effect"
is a plain Rust future, run by the caller's executor, and errors come back in the `Result`
rather than in a type-level error channel. The pillar `README` calls this out — `sqlx`'s
`Future`-based concurrency lets you `try_join` independent queries in parallel
([`src/docs.rs`][srcdocs]). (A `sea-orm-sync` crate re-exposes the same API without a
runtime, for CLI-with-SQLite use.)

**`ActiveModel` is the change-set.** SeaORM's answer to change tracking is per-field state,
not a background session diff. Each field of an `ActiveModel` is an `ActiveValue<T>` with
three states ([`src/entity/active_value.rs`][av]):

> _"- `Set` - a value that's explicitly set by the application and sent to the database. -
> `Unchanged` - an existing, unchanged value from the database. - `NotSet` - an undefined
> value (nothing is sent to the database)."_
>
> _"The difference between these states is useful when constructing `INSERT` and `UPDATE`
> SQL statements ... It's also useful for knowing which fields have changed in a record."_

An `INSERT` emits only the `Set` fields (so `NotSet` lets the database fill a default /
autoincrement `id`); an `UPDATE` writes only the `Set` fields and keys off the `Unchanged`
primary key — _"only changed columns will be updated, never overwriting untouched columns"_
([`README.md`][readme]), which avoids clobbering concurrent writes. `save` chooses
`insert` vs `update` by whether the primary key is set ([`src/entity/active_model.rs`][am]):

```rust
let res = if !self.is_update() { self.insert(db).await } else { self.update(db).await }?;
```

This is a change-set you build and hand over explicitly — closer to `Ecto`'s `Changeset`
or `Diesel`'s `AsChangeset` than to `Hibernate`'s automatic dirty-checking on flush. There
is **no [identity map][orm]** and **no implicit [unit of work][orm]**; a `save`/`insert`/
`update`/`delete` is one statement you call. `is_changed()` and `set_ne` (preserve the
`Unchanged` state when a new value equals the old) round out the tracking helpers
([`src/entity/active_value.rs`][av]). SeaORM offers both an **active-record** surface
(`model.insert(db)`, `model.delete(db)`) and a **repository/data-mapper** surface
(`Entity::insert(am).exec(db)`, `Entity::delete_many().filter(...).exec(db)`)
([`README.md`][readme]).

**Transactions: closure or manual, nested via `SAVEPOINT`.** `TransactionTrait` gives two
styles ([`src/database/connection.rs`][conn]):

> _"Use `begin` for a manually managed transaction, or `transaction` for a closure that
> auto-commits on `Ok` and rolls back on `Err`."_

```rust
db.transaction::<_, (), DbErr>(|txn| Box::pin(async move {
    bakery.insert(txn).await?;
    Cake::insert(cake).exec(txn).await?;
    Ok(())
})).await?;
```

The closure receives a `&DatabaseTransaction` — which itself implements `ConnectionTrait`,
so the same query methods run against it — and returns `Result<T, E>`; the callback error
`E` is wrapped into `TransactionError<E>` distinguishing a user error from a connection
error ([`src/database/connection.rs`][conn]). `begin_with_config` sets the [isolation
level][effects] (`ReadCommitted` … `Serializable`) and access mode (`ReadOnly` /
`ReadWrite`) ([`src/database/connection.rs`][conn]). **Nesting** is real: calling `begin`
on a transaction opens a [savepoint][effects] ([`src/database/transaction.rs`][tx]):

> _"Calling `begin` on a transaction starts a nested transaction via `SAVEPOINT`."_

so an inner rollback discards only the inner work; the outer `BEGIN` is emitted once.

**Errors are a typed `Result`, but one wide enum.** Rust has no exceptions, so every
fallible call returns `Result<T, DbErr>`. `DbErr` is _"An error from unsuccessful database
operations"_ ([`src/error.rs`][error]) — a `#[non_exhaustive]`, `thiserror`-derived enum
with a couple of dozen variants (`Conn`, `Exec`, `Query`, `RecordNotFound`,
`RecordNotInserted`, `ConnectionAcquire`, `Type`, `Json`, `Migration`, …). This is the
survey-relevant contrast: SeaORM has the _typed-`Result`_ posture of the functional mappers
(`doobie`, `Effect TS`), but a **coarse** one — a single library-wide error type rather than
a per-query error set, and no `isRetryable`-style modeling. For the two most common
constraint violations there is a portable classifier, `DbErr::sql_err`, returning a
`SqlErr` ([`src/error.rs`][error]):

> _"A portable, backend-agnostic classification of the most common SQL constraint
> violations ... Only unique-key and foreign-key violations are recognized. For any other
> failure ... inspect the underlying driver error instead."_

Anything finer — SQLSTATE codes, check constraints, deadlock detection — requires matching
`RuntimeErr::SqlxError` and reaching into the `sqlx` driver error yourself
([`src/error.rs`][error]).

**Relations and eager loading.** Unlike the functional mappers, SeaORM _does_ load
relations. `Related<R>` and `Linked` declare the joins ([`src/entity/relation.rs`][rel],
[`src/entity/model.rs`][model]); from there:

- `find_related` — **lazy**, a second `Select` you run explicitly.
- `find_also_related` / `find_with_related` — **eager via join**, returning
  `(Model, Option<Model>)` for 1-1 and `(Model, Vec<Model>)` consolidated per left row for
  1-N / M-N ([`README.md`][readme], [`src/query/select.rs`][select]).
- `LoaderTrait::load_one` / `load_many` / `load_many_to_many` — **DataLoader-style batch
  loading** that _"issue[s] a single `WHERE … IN (…)` query for each relation hop"_,
  explicitly _"avoiding the N+1 query problem"_ ([`src/query/loader.rs`][loader]).

`2.0`'s "Smart Entity Loader" picks between them automatically — _"intelligently uses join
for 1-1 and data loader for 1-N relations, eliminating the [N+1][nplusone] problem even
when performing nested queries"_ ([`README.md`][readme]) — and the nested `ActiveModel`
builder persists a whole object graph (user + profile + posts + tags) in topological order
in one `save`.

## Ecosystem & maturity

SeaORM is a flagship of the **SeaQL** organization (author Chris Tsang), sitting atop its
siblings `sea-query` (the query AST, `~1.0`) and `sea-schema` (introspection), and backed
by `sqlx` `0.9` ([`Cargo.toml`][cargo]). It is dual-licensed **MIT OR Apache-2.0**
(`LICENSE-MIT`, `LICENSE-APACHE`). Backends are PostgreSQL, MySQL/MariaDB, and SQLite via
`sqlx`, with an additional `rusqlite` driver and `mock` / `proxy` connections for tests;
commercial **SQL Server** support ships out-of-tree as SeaORM-X ([`README.md`][readme]).

The `README` reports _"With 250k+ weekly downloads, SeaORM is production-ready, trusted by
startups and enterprises worldwide"_ ([`README.md`][readme]), and lists open-source
dependents including **Zed**, **Servo**, **RisingWave**, **OpenObserve**, **Warpgate**,
**LLDAP**, **Svix**, and **Ryot** ([`README.md`][readme], web-verifiable). The surrounding
ecosystem is substantial: `sea-orm-cli` (codegen + migration scaffolding), `sea-orm-migration`,
`sea-orm-sync` (runtime-free API), `sea-orm-arrow` (Arrow/Parquet), **Seaography** (an
instant GraphQL layer over entities), and **SeaORM Pro** (an admin panel). First released
`0.1.1` in August 2021 ([`CHANGELOG.md`][changelog]); the pinned tree is `2.0.0-rc.42`, a
release candidate for the `2.0` line whose headline features are the dense entity format,
strongly-typed columns, nested `ActiveModel`, RBAC, and synchronous support
([`CHANGELOG.md`][changelog]).

## Strengths

- **Async over a real pool for free.** Built on `sqlx`, so mature drivers, connection
  pooling, prepared statements, and `Future`-based parallelism come for nothing
  ([`src/docs.rs`][srcdocs]).
- **Dynamic queries.** The `sea-query`-backed builder is a runtime value, so conditions,
  joins, and projections can be assembled from user input — with `Condition::all/any` trees
  and `add_option` for optional clauses ([`src/query/helper.rs`][helper]).
- **Injection-safe by construction.** Column predicates capture values as bound params;
  `Statement` keeps SQL and data on separate channels; even `raw_sql!` parameterizes
  ([`src/database/statement.rs`][stmt], [`src/lib.rs`][lib]).
- **All three schema stances.** Db-first introspection codegen, programmatic migrations,
  and code-first sync from one toolchain ([`sea-orm-cli/src/cli.rs`][cli],
  [`sea-orm-migration/src/manager.rs`][manager], [`src/schema/entity.rs`][schemaent]).
- **Relations with N+1 avoidance.** `find_with_related` joins, `LoaderTrait` batches, and
  the `2.0` smart loader picks per relation cardinality ([`src/query/loader.rs`][loader]).
- **Explicit `ActiveModel` change-set.** Per-field `Set` / `Unchanged` / `NotSet` updates
  only changed columns and never clobbers untouched ones ([`src/entity/active_value.rs`][av]).
- **Testable without a database.** `mock` connections assert against a transaction log
  ([`src/docs.rs`][srcdocs]).

## Weaknesses

- **Runtime, not compile-time, query checking.** A column typo or a shape mismatch is a
  runtime `DbErr`, not a compile error — the price of "dynamic" versus `Diesel`'s
  type-checked builder.
- **Coarse error type.** One wide `DbErr` enum, not a per-query error set; anything beyond
  unique/FK classification means reaching into the raw `sqlx` error ([`src/error.rs`][error]).
- **No effect value / typed error channel.** Async futures with `Result`, not an
  `IO`/`Effect` describing the work and its failure set — so the [effect-first][effects]
  guarantees this survey chases (scoped resources, encoded error unions) are not present.
- **No identity map or implicit unit of work.** Batching multi-entity writes is manual
  (explicit `save`s in a transaction / the nested builder); there is no automatic
  minimal-diff flush.
- **`2.0` churn.** The pinned tree is a release candidate; the dense entity format and
  `ActiveModelEx` API are still evolving between minor releases ([`src/entity/base_entity.rs`][baseentity]).
- **Macro-heavy.** The entity is `derive`-generated; understanding a failure often means
  understanding what `DeriveEntityModel` / `#[sea_orm::model]` expanded to.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                 | Trade-off                                                                                                    |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Build on `sqlx` (drivers, pool, async)                            | Don't reinvent connection management; async "from day 1"; parallel queries via `Future`   | Inherits `sqlx`'s type surface and error shapes; SeaORM errors sometimes bottom out in a raw `sqlx::Error`   |
| Build on `sea-query` — query is a **runtime AST**                 | Dynamic queries: branch/compose from user input "without fighting the ORM"; multi-dialect | No compile-time verification that a query is well-typed (unlike `Diesel`); mistakes surface at runtime       |
| Column predicates capture `sea_query::Value` bind params          | Injection impossible for values; `Statement` splits SQL from data; `raw_sql!` stays safe  | Raw text via `Statement::from_string` is the one unsafe door; you must reach for parameters deliberately     |
| `ActiveModel` per-field `Set` / `Unchanged` / `NotSet`            | Explicit change-set; `UPDATE` touches only changed columns; `INSERT` omits defaults       | More ceremony than a mutable self-saving object; you manage the states, no automatic dirty-tracking on flush |
| Async `Future` + `Result<T, DbErr>`, not an effect value          | Idiomatic Rust; runtime-agnostic; typed errors without exceptions                         | No `IO`/`Effect` description, no encoded error set, no scoped-resource guarantees ([effect-first][effects])  |
| One wide `DbErr` enum + portable `SqlErr` for unique/FK           | Simple, ergonomic error handling for the common cases                                     | Coarse; deadlocks, SQLSTATE, check constraints need manual `sqlx`-error inspection                           |
| Full ORM surface **without** identity map / implicit unit-of-work | Predictable, explicit persistence; both active-record and repository styles               | No automatic minimal-diff flush; multi-entity batching is manual or via the nested builder                   |
| Support all three schema stances (db-first / migration / code)    | Bootstrap from a live DB, evolve with migrations, or sync from entities                   | Three overlapping mechanisms to learn; the "right" one depends on the project's stage                        |

---

## Sources

- [SeaQL/sea-orm — GitHub repository][repo] · [sea-ql.org/SeaORM][docs] · [docs.rs/sea-orm][docsrs]
- [`Cargo.toml` — `"An async & dynamic ORM for Rust"`, MIT/Apache dual license, `sqlx 0.9` + `sea-query ~1.0` deps, backends][cargo]
- [`src/docs.rs` — the four pillars: Async (on SQLx), Dynamic (on SeaQuery), Testable, Service Oriented][srcdocs]
- [`README.md` — positioning, familiar-ORMs quote, entity/loader/ActiveModel examples, `raw_sql!`, dependents, 250k weekly downloads][readme]
- [`src/lib.rs` — crate docs; `raw_sql!` "without the risk of SQL injection"][lib]
- [`src/query/select.rs` — `Select<E>` wrapping `sea_query::SelectStatement`; `find_with_related` / `find_also_related`][select]
- [`src/query/helper.rs` — `QueryFilter` / `QuerySelect`; `filter(IntoCondition)`, `Condition::all/any`, runtime condition trees][helper]
- [`src/entity/column.rs` — `ColumnTrait`; `eq`/`ne`/`like`/`is_in` capturing `sea_query::Value` bind params; `eq(None)` → `IS NULL`][column]
- [`src/database/statement.rs` — `Statement { sql, values, db_backend }`: SQL and parameters on separate channels][stmt]
- [`src/database/connection.rs` — `ConnectionTrait`, `StreamTrait`, `TransactionTrait` (begin / closure / config), `IsolationLevel`, `AccessMode`][conn]
- [`src/database/db_connection.rs` — `DatabaseConnection` as a `sqlx` pool; `DatabaseConnectionType` variants; `DbBackend`][dbconn]
- [`src/database/transaction.rs` — `DatabaseTransaction`; nested transaction via `SAVEPOINT`][tx]
- [`src/database/mod.rs` — `Database::connect`, `ConnectOptions` pool sizing/timeouts][dbmod]
- [`src/entity/active_value.rs` — `ActiveValue` `Set` / `Unchanged` / `NotSet`; `Set(None)` vs `NotSet`; `set_ne` / `is_changed`][av]
- [`src/entity/active_model.rs` — `ActiveModelTrait` `insert`/`update`/`save`; `save` = insert if PK not set][am]
- [`src/entity/model.rs` — `ModelTrait` get/set/try_set; `find_related` / `find_linked`][model]
- [`src/entity/base_entity.rs` — `EntityTrait`: `Model`/`ActiveModel`/`Column`/`PrimaryKey`/`Relation`; CRUD entry points][baseentity]
- [`src/entity/relation.rs` — `Related<R>` / `RelationTrait`; `find_related`, junction `via`][rel]
- [`src/query/loader.rs` — `LoaderTrait` batch `load_one`/`load_many`/`load_many_to_many` (N+1 avoidance)][loader]
- [`src/error.rs` — `DbErr` enum, `RuntimeErr`, `ConnAcquireErr`; portable `SqlErr` via `DbErr::sql_err`][error]
- [`sea-orm-macros/src/lib.rs` — `DeriveEntityModel` / `DeriveActiveModel` derives][macros]
- [`sea-orm-migration/` — `MigrationTrait` (`up`/`down`), `MigratorTrait`, `SchemaManager` (`create_table`/`alter_table`)][migration] · [`manager.rs`][manager]
- [`sea-orm-cli/src/cli.rs` — `generate entity` (db-first codegen, compact/expanded/dense/frontend)][cli]
- [`src/schema/entity.rs` — `Schema::create_table_from_entity` (code-first DDL)][schemaent] · [`src/executor/cursor.rs` — `Cursor` / `Paginator`][cursor]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [injection][inject] · [schema/migrations][schema] · [ORM patterns][orm] · [N+1][nplusone] · [effects & transactions][effects] · [pools][pool])
- Related deep-dives in this survey: `sqlx` · `sea-query` · `Diesel` · `Ecto` · `doobie` · Go `GORM` / `ent`

<!-- References -->

[repo]: https://github.com/SeaQL/sea-orm
[docs]: https://www.sea-ql.org/SeaORM
[docsrs]: https://docs.rs/sea-orm
[cargo]: https://github.com/SeaQL/sea-orm/blob/master/Cargo.toml
[srcdocs]: https://github.com/SeaQL/sea-orm/blob/master/src/docs.rs
[readme]: https://github.com/SeaQL/sea-orm/blob/master/README.md
[lib]: https://github.com/SeaQL/sea-orm/blob/master/src/lib.rs
[select]: https://github.com/SeaQL/sea-orm/blob/master/src/query/select.rs
[helper]: https://github.com/SeaQL/sea-orm/blob/master/src/query/helper.rs
[column]: https://github.com/SeaQL/sea-orm/blob/master/src/entity/column.rs
[stmt]: https://github.com/SeaQL/sea-orm/blob/master/src/database/statement.rs
[conn]: https://github.com/SeaQL/sea-orm/blob/master/src/database/connection.rs
[dbconn]: https://github.com/SeaQL/sea-orm/blob/master/src/database/db_connection.rs
[tx]: https://github.com/SeaQL/sea-orm/blob/master/src/database/transaction.rs
[dbmod]: https://github.com/SeaQL/sea-orm/blob/master/src/database/mod.rs
[av]: https://github.com/SeaQL/sea-orm/blob/master/src/entity/active_value.rs
[am]: https://github.com/SeaQL/sea-orm/blob/master/src/entity/active_model.rs
[model]: https://github.com/SeaQL/sea-orm/blob/master/src/entity/model.rs
[baseentity]: https://github.com/SeaQL/sea-orm/blob/master/src/entity/base_entity.rs
[rel]: https://github.com/SeaQL/sea-orm/blob/master/src/entity/relation.rs
[loader]: https://github.com/SeaQL/sea-orm/blob/master/src/query/loader.rs
[error]: https://github.com/SeaQL/sea-orm/blob/master/src/error.rs
[macros]: https://github.com/SeaQL/sea-orm/blob/master/sea-orm-macros/src/lib.rs
[migration]: https://github.com/SeaQL/sea-orm/blob/master/sea-orm-migration/src/lib.rs
[manager]: https://github.com/SeaQL/sea-orm/blob/master/sea-orm-migration/src/manager.rs
[cli]: https://github.com/SeaQL/sea-orm/blob/master/sea-orm-cli/src/cli.rs
[schemaent]: https://github.com/SeaQL/sea-orm/blob/master/src/schema/entity.rs
[cursor]: https://github.com/SeaQL/sea-orm/blob/master/src/executor/cursor.rs
[changelog]: https://github.com/SeaQL/sea-orm/blob/master/CHANGELOG.md
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[schema]: ./concepts.md#schema-migrations-code-generation
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions

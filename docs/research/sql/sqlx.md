# SQLx (Rust)

An async, pure-Rust SQL toolkit whose signature feature is a family of `query!` macros that
send your **raw SQL** to a real development database **at compile time** — having the server
itself verify the syntax, confirm every column exists, and infer the Rust types of the
parameters and result — then generate a typed anonymous record; no ORM, no DSL, no query
builder.

| Field              | Value                                                                                                                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Rust (edition 2021; MSRV `rust-version = "1.94.0"`)                                                                                                   |
| License            | `MIT OR Apache-2.0` (dual, at your option)                                                                                                            |
| Repository         | [launchbadge/sqlx][repo]                                                                                                                              |
| Documentation      | [docs.rs/sqlx][docs] · [crates.io][crate] · [`README.md`][readme] · [`sqlx-cli`][cli]                                                                 |
| Category           | [Safe-SQL / micro-mapper][concepts-ladder] — [macro-checked raw SQL][concepts-models]; **not** an ORM, **not** a query builder                        |
| Abstraction level  | [Safe-SQL / micro-mapper rung][concepts-ladder], reaching into [db-first codegen][concepts-schema] via the compile-time macros                        |
| Query model        | [Macro-checked raw SQL][concepts-models] (`query!` verified against a live DB) plus a runtime [raw-string][concepts-models] `query()` + `.bind()` API |
| Effect/async model | [Async][concepts-effects] — `BoxFuture`/`BoxStream` over `tokio`/`async-std`; errors returned as `Result<T, sqlx::Error>` (a monolithic enum)         |
| Backends           | PostgreSQL, MySQL/MariaDB, SQLite (`Any` runtime-dispatch driver); MSSQL removed before `0.7`, pending a rewrite                                      |
| First release      | ≈2020 (`0.1.0`, web-attested via crates.io)                                                                                                           |
| Latest version     | `0.9.0` (the pinned tree; the published line is `0.8.x`, web-attested)                                                                                |

> [!NOTE]
> SQLx sits on the [safe-SQL / micro-mapper rung][concepts-ladder]: you write raw SQL, but
> parameters bind out-of-band and rows hydrate into typed values. Its distinguishing move is
> to push a slice of [db-first code generation][concepts-schema] into the compiler — the
> `query!` macro is a build-time PREPARE against a real database — without ever generating a
> query DSL. It is this survey's data point for **[macro-checked raw SQL][concepts-models]**
> (the family with `sqlc` and `cornucopia`), contrasted with `Diesel`'s typed-relational-AST
> builder and with the effect-value encodings of `doobie`/`skunk`/`Quill`. See
> [concepts][concepts] for shared vocabulary.

---

## Overview

### What it solves

SQLx removes the classic dilemma between "write raw SQL and lose all static checking" and
"adopt an ORM/DSL and lose SQL." You write ordinary SQL strings; a procedural macro connects
to your development database while `rustc` runs and asks the server to validate them. The
crate's own one-line pitch, from the workspace manifest ([`Cargo.toml`][cargo]):

> _"The Rust SQL Toolkit. An async, pure Rust SQL crate featuring compile-time checked
> queries without a DSL. Supports PostgreSQL, MySQL, and SQLite."_

The `README` header lists the five pillars ([`README.md`][readme]):

> _"SQLx is an async, pure Rust SQL crate featuring compile-time checked queries without a
> DSL."_

with the supporting bullets: _"Truly Asynchronous. Built from the ground-up using
async/await for maximum concurrency"_, _"Compile-time checked queries (if you want)"_,
_"Database Agnostic. Support for PostgreSQL, MySQL, MariaDB, SQLite"_, _"Pure Rust. The
Postgres and MySQL/MariaDB drivers are written in pure Rust using zero unsafe code"_, and
_"Runtime Agnostic. Works on different runtimes (`async-std` / `tokio` / `actix`)"_
([`README.md`][readme]).

Two design negatives are as load-bearing as the positives. SQLx is **not** a driver you feed
positional `?`s by hand and read rows by index (that is the [driver rung][concepts-ladder]),
and it is **not** an ORM or query builder that hides SQL behind method chains. The
`README`'s "SQLx is not an ORM!" section draws the line precisely ([`README.md`][readme]):

> _"SQLx supports **compile-time checked queries**. It does not, however, do this by
> providing a Rust API or DSL (domain-specific language) for building queries. Instead, it
> provides macros that take regular SQL as input and ensure that it is valid for your
> database. The way this works is that SQLx connects to your development DB at compile time
> to have the database itself verify (and return some info on) your SQL queries."_

The consequence, spelled out in the same section, is the toolkit's defining trade for
expressiveness: because SQLx never parses the SQL itself, _"any syntax that the development
DB accepts can be used (including things added by database extensions)"_ — but the depth of
verification _"depends on the database"_ ([`README.md`][readme]).

### Design philosophy

**Raw SQL is the interface; the compiler is the checker.** Where a typed query builder
(`Diesel`, `jOOQ`, `Kysely`) makes the Rust type system model the schema, and a codegen tool
(`sqlc`, `cornucopia`) reads `.sql` files and emits Rust ahead of the build, SQLx inverts
both: the SQL lives inline in your Rust source, and the _database server_ is enlisted as the
type checker during compilation. The checked and unchecked worlds coexist deliberately —
compile-time checking is opt-in per call site (`query!` vs. `query`), captured in the
`README`'s _"Compile-time checked queries **(if you want)**"_ ([`README.md`][readme]).

**Pure-Rust wire protocols, not C client libraries.** The Postgres and MySQL drivers speak
the databases' binary wire protocols directly in Rust — `sqlx-postgres/src/message/` carries
native `startup`, `sasl`, `authentication`, `parse`, `bind`, `execute`, and `data_row`
frame codecs ([`sqlx-postgres/src/message/`][pgmsg]), depending on `hmac`, `md-5`, `rand`,
`byteorder`, and `whoami` rather than `libpq`. This is what lets the crate assert
memory-safety: `sqlx-core` is `#![forbid(unsafe_code)]` ([`sqlx-core/src/lib.rs`][corelib]),
and the facade restates it ([`README.md`][readme]):

> _"This crate uses `#![forbid(unsafe_code)]` to ensure everything is implemented in 100%
> Safe Rust."_

The one exception is SQLite, an embedded C database reached through `libsqlite3-sys`; there
the guarantee is _"downgraded to `#![deny(unsafe_code)]` with `#![allow(unsafe_code)]` on the
`sqlx::sqlite` module"_ ([`README.md`][readme]). The `README` footnote is explicit that
SQLite _"uses the libsqlite3 C library"_ and that `#![forbid(unsafe_code)]` holds _"unless
the `sqlite` feature is enabled"_ ([`README.md`][readme]).

**Async from the ground up, runtime-agnostic.** Every I/O entry point returns a future or a
stream; the runtime (`tokio` or `async-std`) and TLS backend (`native-tls` or `rustls`) are
chosen by Cargo features rather than baked in ([`src/lib.md`][libmd]): _"If more than one
runtime feature is enabled, the Tokio runtime is used if a Tokio context exists on the
current thread … `async-std` is used otherwise."_ This makes SQLx the async, monolithic-error
counterpoint to `hasql`'s blocking `Session` and to the interpretable effect values of the
functional-mapper family.

---

## Connection, pooling & resource lifetime

A single session is any of the driver connection types — `PgConnection`, `MySqlConnection`,
`SqliteConnection` — opened with `connect()` ([`README.md`][readme]):

```rust
use sqlx::Connection;
let conn = SqliteConnection::connect("sqlite::memory:").await?;
```

In production you reach instead for `sqlx::Pool`, _"a standard technique that can manage
opening and re-using connections … [and] enforces a maximum number of connections"_
([`sqlx-core/src/pool/mod.rs`][pool]). A pool is created once and shared for the process
lifetime; the module documents its resource story crisply ([`sqlx-core/src/pool/mod.rs`][pool]):

- **Cheap to clone, reference-counted.** _"`Pool` is `Send`, `Sync` and `Clone` … Cloning
  `Pool` is cheap as it is simply a reference-counted handle to the inner pool state. When
  the last remaining handle to the pool is dropped, the connections owned by the pool are
  immediately closed."_
- **Bounded and fair.** _"The pool has a maximum connection limit that it will not exceed; if
  `acquire()` is called when at this limit and all connections are checked out, the task will
  be made to wait."_ — and _"Calls to `acquire()` are fair, i.e. fulfilled on a first-come,
  first-serve basis."_ A wait that never resolves surfaces as `Error::PoolTimedOut`
  ([`sqlx-core/src/error.rs`][error]).
- **Scoped return by `Drop`.** A `PoolConnection` returned by `Pool::acquire` _"return[s] to
  the pool"_ when dropped; the lease is an ordinary RAII lifetime rather than an explicit
  release call.

`PoolOptions` tunes `max_connections`, timeouts, and lifecycle hooks; the `README`'s
quickstart shows `PgPoolOptions::new().max_connections(5).connect(url)`
([`README.md`][readme]). Type aliases (`PgPool`, `MySqlPool`, `SqlitePool`) exist per driver
([`sqlx-core/src/pool/mod.rs`][pool]).

Crucially, **`&Pool` itself is an `Executor`**, so most code never touches a connection
handle at all ([`sqlx-core/src/pool/mod.rs`][pool]): _"You can also pass `&Pool` directly
anywhere an `Executor` is required; this will automatically checkout a connection for you."_
The `Executor` trait is implemented for exactly two things — `&Pool` and `&mut Connection`
([`sqlx-core/src/executor.rs`][executor]); a `Transaction` is used by dereferencing it to its
inner connection (`&mut *tx`).

---

## Query construction & injection safety

This is SQLx's centre of gravity, and it has two layers: the **compile-time-checked macro**
(`query!`) and the **runtime query API** (`query().bind()`). Both make bind parameters the
only channel for dynamic data, so [SQL injection is structurally impossible][concepts-injection]
for a bound value.

### The `query!` macro: raw SQL verified against a live database

`query!` is described in its own docstring as a _"Statically checked SQL query with
`println!()` style syntax"_ that ([`src/macros/mod.rs`][macros]):

> _"expands to an instance of [`query::Map`] that outputs an ad-hoc anonymous struct type, if
> the query has at least one output column that is not `Void`, or `()` (unit) otherwise."_

Bind parameters are typechecked like format arguments — _"Like `println!()` and the other
formatting macros, you can add bind parameters to your SQL and this macro will typecheck
passed arguments and error on missing ones"_ ([`src/macros/mod.rs`][macros]):

```rust
let countries = sqlx::query!(
        "SELECT country, COUNT(*) as count
         FROM users GROUP BY country WHERE organization = ?",
        organization
    )
    .fetch_all(&pool) // -> Vec<{ country: String, count: i64 }>
    .await?;

// countries[0].country  (typed String)
// countries[0].count    (typed i64)
```

The `README` names the three guarantees the macro adds over the runtime `query()`
([`README.md`][readme]): the bind parameters _"are compile-time validated to be the right
number and the right type"_; _"The output type is an anonymous record"_ whose fields carry
the SQL-inferred Rust types; and _"The `DATABASE_URL` environment variable must be set at
build time to a database … [with] the same schema as the database you will be connecting to
at runtime."_ The mechanism is a real prepare: the macro expander connects and calls
`DB::describe_blocking(&input.sql, database_url, …)` ([`sqlx-macros-core/src/query/mod.rs`][qexpand]),
returning a `Describe` whose docstring states its job ([`sqlx-core/src/describe.rs`][describe]):

> _"The query macros (e.g., `query!`, `query_as!`, etc.) use the information here to validate
> output and parameter types; and, generate an anonymous record."_

The generated record is literally emitted as `#[derive(Debug)] #[allow(non_snake_case)]
struct Record { … }` with one field per output column, filled from the `Describe`
([`sqlx-macros-core/src/query/mod.rs`][qexpand]). Because the column count and types come from
the server, adding a column to a `SELECT *` or renaming one is caught at compile time, not in
production.

`query!` has a family of variants ([`src/macros/mod.rs`][macros]): `query_as!` maps into a
**named** struct (working around Rust's lack of nameable anonymous records — its docstring is
explicit that _"this macro does not use [`FromRow`]"_ but matches columns to fields by name);
`query_scalar!` extracts a single column; `query_file!` reads the SQL from an out-of-line
`.sql` file; and each has a `_unchecked` twin that still parses/validates the query but skips
input/output typechecking.

### Nullability and type overrides

The macros lift SQL nullability into the Rust type. _"In most cases, the database engine can
tell us whether or not a column may be `NULL`, and the `query!()` macro adjusts the field
types of the returned struct accordingly"_ — a non-nullable column becomes `T`, a nullable or
expression column becomes `Option<T>` ([`src/macros/mod.rs`][macros]). Where inference is
fragile (Postgres expressions, outer joins), column-name annotations override it, exploiting
SQL's arbitrary-text column aliases ([`src/macros/mod.rs`][macros]):

| Syntax    | Nullability     | Type       |
| --------- | --------------- | ---------- |
| `foo!`    | Forced not-null | Inferred   |
| `foo?`    | Forced nullable | Inferred   |
| `foo: T`  | Inferred        | Overridden |
| `foo!: T` | Forced not-null | Overridden |
| `foo?: T` | Forced nullable | Overridden |

### Offline mode: the `.sqlx` query cache

The obvious objection — that compiling now needs a reachable database — is answered by
offline mode ([`src/macros/mod.rs`][macros]): _"Run `cargo sqlx prepare`. Check the generated
`.sqlx` directory into version control. Don't have `DATABASE_URL` set during compilation."_
The macro expander picks its data source accordingly — a `QueryDataSource::Live { database_url }`
if `DATABASE_URL` is set, otherwise a `QueryDataSource::Cached` read from a
`query-<hash>.json` file located in `SQLX_OFFLINE_DIR`, the crate's `.sqlx`, or the workspace
`.sqlx` ([`sqlx-macros-core/src/query/mod.rs`][qexpand]). Each cache file is the serialized
`Describe` metadata keyed by a hash of the SQL text ([`sqlx-macros-core/src/query/data.rs`][qdata]),
so CI needs no database. The prepared cache can be verified in CI with `cargo sqlx prepare
--check`, keeping it in sync with both the source queries and the live schema
([`src/macros/mod.rs`][macros]).

### The runtime API: `query()` + `.bind()`, and `SqlSafeStr`

When the SQL is dynamic (its _shape_ varies), the macros do not apply and you use the runtime
`query()` function, which returns a `Query` — _"A single SQL query as a prepared statement"_
marked `#[must_use = "query must be executed to affect database"]`
([`sqlx-core/src/query.rs`][query]). Values enter only through `.bind()`, and the docstring is
emphatic about why ([`sqlx-core/src/query.rs`][query]):

```rust
let results = sqlx::query(
    "SELECT * FROM articles
     WHERE title LIKE '%' || $1 || '%'
     OR content LIKE '%' || $1 || '%'"   // Postgres/SQLite: $1 reused
)
    .bind(user_input)
    .fetch_all(&mut conn)
    .await?;
```

> _"The value bound to a query parameter is entirely separate from the query and does not
> affect its syntax. Thus, SQL injection is impossible (barring shenanigans like calling a
> SQL function that lets you execute a string as a statement) and all strings are valid."_

and, critically, the binding is server-side ([`sqlx-core/src/query.rs`][query]): _"**SQLx does
not substitute placeholders on the client side.** It is done by the database server itself."_
Placeholder syntax is dialect-specific — `$1…$N` for Postgres/SQLite, positional `?` for
MySQL/MariaDB ([`sqlx-core/src/query.rs`][query]). The same section warns that parameters
_"cannot be used to add conditional SQL fragments"_ — you cannot bind a table name or an
operator.

SQLx hardens the string channel itself with a type-level speed bump. The `query()` and
`raw_sql()` functions accept `impl SqlSafeStr`, _"A SQL string that is safe to execute on a
database connection"_ implemented natively **only for `&'static str`**
([`sqlx-core/src/sql_str.rs`][sqlstr]). A dynamically built `String` must be wrapped in
`AssertSqlSafe(...)`, and the compiler diagnostic makes the intent unmistakable
([`sqlx-core/src/sql_str.rs`][sqlstr]): _"dynamic SQL strings should be audited for possible
injections"_, _"prefer literal SQL strings with bind parameters or `QueryBuilder` to add
dynamic data to a query."_ The type is _"designed to act as a speed bump against naively
using `format!()` to add dynamic data or user input to a query"_ and is _"intentionally
analogous to `std::panic::UnwindSafe` and `AssertUnwindSafe`"_ ([`sqlx-core/src/sql_str.rs`][sqlstr]).

### The escape hatch: `QueryBuilder`

For genuinely dynamic query _structure_ — a variable `WHERE`, a bulk `INSERT` — SQLx offers
`QueryBuilder`, _"A builder type for constructing queries at runtime"_
([`sqlx-core/src/query_builder.rs`][qbuilder]). It is a string builder, not a typed AST like
`Diesel`'s: `.push()` appends raw SQL (its docstring loudly warns it _"does not perform
sanitization"_), while `.push_bind()` _"inserts a placeholder into the query and then sends
the possibly untrustworthy value separately"_ ([`sqlx-core/src/query_builder.rs`][qbuilder]).
Reaching for `QueryBuilder` is the point where the macro's compile-time guarantee is
surrendered — the fundamental cost of the raw-SQL-is-the-interface stance.

---

## Schema, migrations & code generation

SQLx is **database-first** and owns no schema declaration: there is no entity model that _is_
the schema, and the macros discover types by _introspecting the live database_, not by reading
a code-first model. Custom types are the one place this shows through — the `Type` trait
docstring warns that _"Type definitions are not verified against the database at compile-time.
The `query!()` macros have no implicit knowledge of user-defined types"_, so a user-defined SQL
type must be surfaced with a `foo as "foo: MyType"` override ([`sqlx-core/src/types/mod.rs`][typesmod]).

Unlike `hasql` (which delegates migrations to a satellite package), SQLx ships a **first-party
migration runner**. The `migrate!` macro _"embeds migrations into the binary by expanding to a
static instance of [`Migrator`]"_ ([`src/macros/mod.rs`][macros]):

```rust
sqlx::migrate!("db/migrations").run(&pool).await?;
// or, statically:
static MIGRATOR: Migrator = sqlx::migrate!(); // defaults to "./migrations"
```

Migrations are numbered `.sql` files under `migrations/`; the runner records applied ones in a
bookkeeping table named `_sqlx_migrations` by default ([`sqlx-core/src/migrate/migrator.rs`][migrator]),
computes a `checksum` per migration ([`sqlx-core/src/migrate/migration.rs`][migration]), and
refuses to proceed if a previously-applied migration's text has changed — a checksum mismatch
returns `MigrateError::VersionMismatch` ([`sqlx-core/src/migrate/migrator.rs`][migrator]).
`Migrator` exposes `run`, `run_to(target)`, and `undo(target)` for reversible migrations, and a
`no_tx` flag for migrations that cannot run inside a transaction
([`sqlx-core/src/migrate/migrator.rs`][migrator]). The `sqlx-cli` binary (`cargo sqlx migrate
add/run`, `cargo sqlx prepare`, `cargo sqlx database create`) is the developer-facing front end.

There is **no first-party introspection→codegen path** that emits Rust structs from the schema
(the `sqlc`/`jOOQ` move); SQLx's "codegen" is the _inline, per-query_ record synthesis of the
macros, not a generated schema module. Third-party crates (`ormx`, `SeaORM`) build ORMs atop
SQLx, catalogued in its Ecosystem wiki ([`README.md`][readme]).

---

## Type mapping & result decoding

Type mapping rests on three traits, parameterized over the database `DB`
([`sqlx-core/src/encode.rs`][encode], [`sqlx-core/src/decode.rs`][decode],
[`sqlx-core/src/types/mod.rs`][typesmod]):

| Trait            | Role                                                                                     |
| ---------------- | ---------------------------------------------------------------------------------------- |
| `Type<DB>`       | Declares that a Rust type maps to a SQL type (`type_info()`); the compatibility check    |
| `Encode<'q, DB>` | Writes a value into the driver's `ArgumentBuffer` for a bind parameter; returns `IsNull` |
| `Decode<'r, DB>` | Reconstructs a value from a `ValueRef` borrowed from the row                             |

Nullability is uniform: _"To represent nullable SQL types, `Option<T>` is supported where `T`
implements `Type`. An `Option<T>` represents a potentially `NULL` value from SQL"_
([`sqlx-core/src/types/mod.rs`][typesmod]); decoding a SQL `NULL` into a non-`Option` field
raises `UnexpectedNullError` — _"unexpected null; try decoding as an `Option`"_
([`sqlx-core/src/error.rs`][error]). `#[derive(sqlx::Type)]` generates codecs for wrapper
newtypes (`#[sqlx(transparent)]`), enums, and (Postgres) composite records
([`sqlx-core/src/types/mod.rs`][typesmod]).

**Row hydration** has two independent routes, easy to conflate:

- **`FromRow`** — _"A record that can be built from a row returned by the database"_, used by
  the _runtime_ `query_as()`; the derive generates _"a sequence of calls to `Row::try_get`
  using the name from each struct field"_ and supports `rename`, `rename_all`, `default`,
  `flatten`, and `skip` field attributes ([`sqlx-core/src/from_row.rs`][fromrow]).
- **The macro's own struct-literal mapping** — `query!`/`query_as!` do **not** use `FromRow`;
  they build the record from the compile-time `Describe`, matching column names to fields with
  the SQL-inferred (not the struct-declared) types ([`src/macros/mod.rs`][macros]).

Both hydrate positionally-or-by-name into a fixed-shape record; neither materializes an object
graph across tables — joins are written explicitly in SQL, keeping SQLx below the
change-tracking ORM rung. Prepared queries move data in a compact binary encoding rather than
text, which the docstring flags as a bandwidth win ([`sqlx-core/src/query.rs`][query]).

---

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and SQLx lands squarely at the
**[async-future][concepts-effects]** point — not the blocking `IO` of `hasql`, and not the
interpretable effect _value_ of `doobie`/`skunk`/`Quill`.

### Async futures, not effect values

The `Executor` trait — the low-level engine behind the free functions — returns boxed futures
and streams ([`sqlx-core/src/executor.rs`][executor]):

```rust
fn fetch_optional<'e, 'q, E>(self, query: E)
    -> BoxFuture<'e, Result<Option<DB::Row>, Error>>;
fn fetch_many<'e, 'q, E>(self, query: E)
    -> BoxStream<'e, Result<Either<DB::QueryResult, DB::Row>, Error>>;
```

The user-facing finalizers layer onto these: `.execute()` (rows affected), `.fetch_one()`,
`.fetch_optional()`, `.fetch_all()`, and `.fetch()` (a `Stream` decoded on demand). The trait
steers callers to the free functions ([`sqlx-core/src/executor.rs`][executor]): _"Instead of
calling the methods of this trait, use the free functions in the `sqlx` crate root:
`sqlx::query()` … `sqlx::query_as()`, `sqlx::query_scalar()` … `sqlx::raw_sql()`"_ — the last
being the DDL/batch path that _"never uses prepared statements"_ and _"accepts multiple queries
separated by semicolons."_

A `Query` is inert until awaited (`#[must_use = "query must be executed to affect database"]`,
[`sqlx-core/src/query.rs`][query]), which resembles the effect systems' laziness. The
difference the survey cares about: a SQLx future is a _poll-driven Rust future_, opaque and
runtime-executed, whereas a `doobie` `ConnectionIO` is a _reifiable description_ you can inspect
and interpret. SQLx has no environment-carrying `R` and no per-query error type in its value —
it is `async`, not algebraic-effects.

### Transactions and savepoints

A `Transaction` starts with `Pool::begin` or `Connection::begin`, is used as an `Executor` by
dereference, and ends with `.commit()` or `.rollback()`
([`sqlx-core/src/transaction.rs`][tx]):

```rust
let mut tx = conn.begin().await?;
sqlx::query("DELETE FROM \"testcases\" WHERE id = $1").bind(id).execute(&mut *tx).await?;
tx.commit().await?;
```

Safety comes from RAII ([`sqlx-core/src/transaction.rs`][tx]): _"If neither are called before
the transaction goes out-of-scope, [`rollback`] is called. In other words, [`rollback`] is
called on `drop` if the transaction is still in-progress."_ **Nesting is via savepoints**,
selected by transaction depth: `begin` emits `BEGIN` at depth 0 and `SAVEPOINT
_sqlx_savepoint_{depth}` deeper; `commit` emits `COMMIT` or `RELEASE SAVEPOINT`; `rollback`
emits `ROLLBACK` or `ROLLBACK TO SAVEPOINT` ([`sqlx-core/src/transaction.rs`][tx]). The
`TransactionManager` trait exposes `begin`/`commit`/`rollback` plus `get_transaction_depth`,
where _"Level 2 or higher: A transaction is active and one or more SAVEPOINTs have been
created"_ ([`sqlx-core/src/transaction.rs`][tx]) — the same top-level-`BEGIN` + inner-`SAVEPOINT`
model the effect systems implement for nested `withTransaction`.

### Errors: a single monolithic `Result`, not a typed channel

Every fallible call returns `sqlx::Result<T>` = `Result<T, sqlx::Error>`
([`sqlx-core/src/error.rs`][error]). Unlike `hasql`'s per-layer `Either` hierarchy or an
effect system's type-parameterized error slot, `sqlx::Error` is **one big `#[non_exhaustive]`
enum** covering the whole crate: `Configuration`, `Database(Box<dyn DatabaseError>)`, `Io`,
`Tls`, `Protocol`, `RowNotFound`, `TypeNotFound`, `ColumnDecode`, `Encode`, `Decode`,
`PoolTimedOut`, `PoolClosed`, `Migrate`, and more ([`sqlx-core/src/error.rs`][error]). The
error _channel_ is value-typed (Rust `Result`, no exceptions), but it is not _narrowed per
query_ the way the effect-first designs narrow it.

Structured database faults hide behind the `Database` variant's `DatabaseError` trait, which
exposes the retryable, actionable detail ([`sqlx-core/src/error.rs`][error]): `message()`, the
SQLSTATE `code()`, a `constraint()` and `table()` name (Postgres), and a `kind()` returning an
`ErrorKind` — `UniqueViolation`, `ForeignKeyViolation`, `NotNullViolation`, `CheckViolation`,
`ExclusionViolation`, or `Other` — with convenience predicates `is_unique_violation()` and
friends. Catching a unique-constraint conflict is therefore
`err.as_database_error().and_then(|e| e.is_unique_violation())`, or a downcast to the concrete
`PgDatabaseError` for driver-specific fields — the same practical outcome as `doobie`'s
`attemptSomeSqlState`, reached through Rust's `Result` rather than an effect's typed error.

---

## Ecosystem & maturity

SQLx is a mature, widely-deployed toolkit under the permissive **`MIT OR Apache-2.0`** dual
license ([`Cargo.toml`][cargo]; both [`LICENSE-MIT`][licensemit] and `LICENSE-APACHE`
present), authored by _"The LaunchBadge team"_ and a large contributor base ([`README.md`][readme]).
It is one of the most-depended-upon database crates on crates.io (web-attested), and the base
layer under third-party ORMs such as `SeaORM` and `ormx`.

**Backends.** PostgreSQL, MySQL/MariaDB, and SQLite are first-class; an `Any` driver _"can
proxy to a database driver at runtime"_ selected by URL scheme ([`README.md`][readme]).
Postgres and MySQL are pure-Rust wire implementations; SQLite links `libsqlite3-sys` (bundled
or system). **MSSQL** was supported before `0.7` _"but has been removed pending a full rewrite
of the driver as part of our SQLx Pro initiative"_ ([`README.md`][readme]) — a notable gap for
the survey's backend matrix.

**Feature-gated everything.** Runtime (`runtime-tokio`/`runtime-async-std`), TLS
(`tls-native-tls`/`tls-rustls-*`), each database, the `macros`/`migrate`/`derive` capabilities,
and per-type support (`uuid`, `chrono`/`time`, `json`, `bigdecimal`/`rust_decimal`, `ipnet`,
`bstr`) are all Cargo features ([`README.md`][readme]) — one must pick a runtime + TLS + driver
combination to build.

The pinned tree declares `version = "0.9.0"` ([`Cargo.toml`][cargo]; `CHANGELOG` `0.9.0`
dated `2026-05-06`), while the broadly-deployed line is `0.8.x` (web-attested). The `README`
notes a meaningful build-time cost of the macros — _"Compile-time verified queries do quite a
bit of work at compile time"_ — recommending `opt-level = 3` for `sqlx-macros`
([`README.md`][readme]).

---

## Strengths

- **Compile-time SQL verification with zero DSL.** `query!` validates syntax, columns, and
  types against a real database while `rustc` runs — if it compiles, the SQL is valid against
  the schema — while you still write plain SQL that any database extension can extend.
- **Injection-safe by construction.** Bind parameters are server-side and out-of-band; the
  `SqlSafeStr`/`AssertSqlSafe` type wall makes `format!`-ing user input into SQL a conscious,
  audited act rather than an accident.
- **Async-first, runtime- and TLS-agnostic.** Futures/streams over `tokio` or `async-std`;
  rows decoded on demand; a fair, bounded, cheaply-cloned `Pool` that is itself an `Executor`.
- **Pure-Rust drivers.** Postgres/MySQL speak the wire protocol natively with
  `#![forbid(unsafe_code)]` in core — no `libpq`/`libmysqlclient` C dependency.
- **Offline mode.** The committed `.sqlx` cache lets CI and teammates build without a database
  while preserving the check via `cargo sqlx prepare --check`.
- **Batteries included.** First-party connection pooling, nested transactions with savepoints,
  a checksum-verified migration runner, `FromRow`/`Type` derives, and multi-database support.

## Weaknesses

- **The macro needs a reachable DB or a committed cache.** Compile-time checking requires
  `DATABASE_URL` (or an up-to-date `.sqlx/`); a stale cache or drifted schema silently
  under-checks, and CI must run `prepare --check` to stay honest.
- **Dynamic queries lose the guarantee.** Anything variable in _shape_ falls back to
  `QueryBuilder` / `AssertSqlSafe` raw-string composition — no compile-time checking, and the
  author re-owns injection safety for `.push()`.
- **Stringly-typed, not a typed builder.** There is no reifiable query AST, no dialect
  retargeting, no type-checked column references à la `Diesel`; a query is text plus binds.
- **Monolithic error enum.** `sqlx::Error` is one crate-wide `#[non_exhaustive]` enum, not a
  per-query typed error channel — coarser than the effect-first designs' narrowed error slots.
- **Async future, not an effect value.** Queries are opaque poll-driven futures with no
  environment/error type in the value, so they cannot be inspected or interpreted like a
  `ConnectionIO`.
- **Build-time cost and feature sprawl.** The macros do real work each compile; runtime, TLS,
  driver, and type support are a matrix of Cargo features to assemble. SQLite requires C
  `unsafe`; MSSQL is unsupported since `0.7`.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                  | Trade-off                                                                                                     |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| **Raw SQL + compile-time check** (`query!` PREPAREs against a live DB) | Full SQL power (extensions included); "if it compiles, the SQL matches the schema"; no DSL | Compilation needs a reachable DB or a committed `.sqlx` cache; verification depth varies per database         |
| **Anonymous record generated from `Describe`**                         | Result fields carry SQL-inferred types + nullability; column drift caught at compile time  | Output type is unnameable (need `query_as!` + a struct); does not use `FromRow`; two hydration paths to learn |
| **Offline `.sqlx` cache** (`cargo sqlx prepare`)                       | CI/teammates build without a database; check preserved via `prepare --check`               | Cache can go stale vs. schema/queries; another artifact to commit and validate                                |
| **Bind parameters only for dynamic data** (server-side substitution)   | Injection structurally impossible for values; compact binary transfer                      | Cannot parameterize query _structure_ (table names, conditional clauses) — needs `QueryBuilder`               |
| **`SqlSafeStr` / `AssertSqlSafe` type wall**                           | Makes dynamic-string SQL an audited, explicit choice; a `format!` speed bump               | Ergonomic friction for legitimate dynamic SQL; the assertion can still be misused                             |
| **Pure-Rust wire drivers** (`#![forbid(unsafe_code)]` in core)         | Memory safety, no C client dependency, cross-compiles anywhere Rust does                   | SQLite still needs C `unsafe` via `libsqlite3-sys`; each protocol is a large in-house maintenance surface     |
| **Async futures, not effect values**                                   | Native `async`/`await`, runtime-agnostic, streaming rows; low conceptual overhead          | No inspectable/interpretable program value; no environment or per-query error type in the value               |
| **Monolithic `sqlx::Error` enum**                                      | One `Result` type across the whole crate; simple to propagate with `?`                     | Coarser than a narrowed typed-error channel; DB specifics need `as_database_error()` + downcast               |
| **First-party pool, transactions, migrations**                         | Batteries included; nested savepoints and checksum-verified migrations built in            | More surface in one crate than `hasql`'s satellite ecosystem; opinionated policy baked in                     |
| **Database-first, no schema ownership**                                | Types discovered by introspection; no code-first model to keep in sync                     | Custom types need explicit `as "col: T"` overrides; no generated schema module (unlike `sqlc`/`jOOQ`)         |

---

## Sources

- [launchbadge/sqlx — GitHub repository][repo] · [docs.rs][docs] · [crates.io][crate] · [`sqlx-cli`][cli]
- [`README.md` — "not an ORM", async/pure-Rust/compile-time-checked pillars, quickstart, compile-time verification, offline mode, safety, dual license][readme]
- [`Cargo.toml` — workspace `version`/`license`/`edition`/`rust-version`, crate description][cargo]
- [`CHANGELOG.md` — release history (`0.9.0` dated 2026-05-06)][changelog] · [`LICENSE-MIT`][licensemit]
- [`src/macros/mod.rs` — `query!`/`query_as!`/`query_scalar!`/`query_file!`/`migrate!` docs: anonymous record, `println!`-style args, nullability, overrides cheatsheet, offline mode][macros]
- [`sqlx-macros-core/src/query/mod.rs` — `QueryDataSource` Live/Cached, `.sqlx` lookup, `describe_blocking`, generated `struct Record`][qexpand]
- [`sqlx-macros-core/src/query/data.rs` — `QueryData`/`DynQueryData`, `query-<hash>.json` offline cache][qdata]
- [`sqlx-core/src/describe.rs` — `Describe` (columns/parameters/nullable) powering macro type inference][describe]
- [`sqlx-core/src/executor.rs` — `Executor`/`Execute` traits, `BoxFuture`/`BoxStream`, free-function guidance][executor]
- [`sqlx-core/src/query.rs` — `Query`, `.bind()`, injection docstring ("SQL injection is impossible", server-side substitution)][query]
- [`sqlx-core/src/sql_str.rs` — `SqlSafeStr`/`AssertSqlSafe` (only `&'static str` is native), the `format!` speed-bump diagnostic][sqlstr]
- [`sqlx-core/src/query_builder.rs` — runtime `QueryBuilder`, `.push()`/`.push_bind()`][qbuilder]
- [`sqlx-core/src/transaction.rs` — `Transaction`, rollback-on-drop, savepoint SQL, `TransactionManager`][tx]
- [`sqlx-core/src/error.rs` — `Error` enum, `DatabaseError` trait, `ErrorKind`, `UnexpectedNullError`][error]
- [`sqlx-core/src/pool/mod.rs` — `Pool` (bounded, fair, ref-counted, `Executor`)][pool]
- [`sqlx-core/src/from_row.rs` — `FromRow` derive (runtime `query_as`)][fromrow] · [`encode.rs`][encode] · [`decode.rs`][decode] · [`types/mod.rs` — `Type`, `Option<T>` nullability][typesmod]
- [`sqlx-core/src/migrate/migrator.rs` — `Migrator`, `_sqlx_migrations`, checksum `VersionMismatch`, `run`/`undo`][migrator] · [`migration.rs`][migration]
- [`sqlx-postgres/src/message/` — pure-Rust Postgres wire protocol frames][pgmsg] · [`sqlx-core/src/lib.rs` — `#![forbid(unsafe_code)]`][corelib] · [`src/lib.md`][libmd]
- Shared vocabulary: [concepts & vocabulary][concepts] · [the abstraction ladder][concepts-ladder] · [query construction models][concepts-models] · [statements, parameters & injection][concepts-injection] · [schema, migrations & codegen][concepts-schema] · [effects, transactions & error handling][concepts-effects]

<!-- References -->

[concepts]: ./concepts.md
[concepts-ladder]: ./concepts.md#the-abstraction-ladder
[concepts-models]: ./concepts.md#query-construction-models
[concepts-injection]: ./concepts.md#statements-parameters-and-sql-injection
[concepts-pools]: ./concepts.md#connections-pools-and-sessions
[concepts-schema]: ./concepts.md#schema-migrations-code-generation
[concepts-types]: ./concepts.md#type-mapping-and-result-decoding
[concepts-effects]: ./concepts.md#effects-transactions-and-error-handling
[concepts-orm]: ./concepts.md#orm-patterns
[index]: ./index.md
[repo]: https://github.com/launchbadge/sqlx
[docs]: https://docs.rs/sqlx
[crate]: https://crates.io/crates/sqlx
[cli]: https://crates.io/crates/sqlx-cli
[readme]: https://github.com/launchbadge/sqlx/blob/main/README.md
[libmd]: https://github.com/launchbadge/sqlx/blob/main/src/lib.md
[cargo]: https://github.com/launchbadge/sqlx/blob/main/Cargo.toml
[changelog]: https://github.com/launchbadge/sqlx/blob/main/CHANGELOG.md
[licensemit]: https://github.com/launchbadge/sqlx/blob/main/LICENSE-MIT
[macros]: https://github.com/launchbadge/sqlx/blob/main/src/macros/mod.rs
[qexpand]: https://github.com/launchbadge/sqlx/blob/main/sqlx-macros-core/src/query/mod.rs
[qdata]: https://github.com/launchbadge/sqlx/blob/main/sqlx-macros-core/src/query/data.rs
[describe]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/describe.rs
[executor]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/executor.rs
[query]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/query.rs
[sqlstr]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/sql_str.rs
[qbuilder]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/query_builder.rs
[tx]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/transaction.rs
[error]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/error.rs
[pool]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/pool/mod.rs
[fromrow]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/from_row.rs
[encode]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/encode.rs
[decode]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/decode.rs
[typesmod]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/types/mod.rs
[migrator]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/migrate/migrator.rs
[migration]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/migrate/migration.rs
[pgmsg]: https://github.com/launchbadge/sqlx/tree/main/sqlx-postgres/src/message
[corelib]: https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/lib.rs

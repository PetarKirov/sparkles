# Diesel (Rust)

Rust's compile-time-checked ORM and query builder: you declare each table with the `table!` macro (usually generated from a live database by `diesel print-schema`), then compose queries as a fluent DSL over the generated column structs — `users.filter(name.eq("Sean")).load::<User>(conn)` — where a wrong column name or a type-mismatched comparison is a _compile_ error and every value binds as an out-of-band parameter rather than being interpolated into SQL text.

| Field              | Value                                                                                                                                                    |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Rust (edition 2024, MSRV `1.88.0`; `#![no_std]`-capable via the `sqlite-no-std` feature)                                                                 |
| License            | Dual **MIT OR Apache-2.0** — [`LICENSE-MIT`][licensemit] (© "2015-2021 Sean Griffin, 2018-2021 Diesel Core Team"), [`LICENSE-APACHE`][licenseapache]     |
| Repository         | [diesel-rs/diesel][repo]                                                                                                                                 |
| Documentation      | [docs.rs/diesel][docs] · [diesel.rs guides][guides] · in-repo [`guide_drafts/`][guidedrafts]                                                             |
| Category           | [Typed query builder][ladder] shading into a light [ORM][ormpatterns] (the derives, associations, `save_changes`)                                        |
| Abstraction level  | Typed query builder / light ORM — above a driver, below a full identity-map ORM ([ladder][ladder])                                                       |
| Query model        | [Fluent typed builder][qmodels] over macro-declared schema structs; the query is a monomorphized AST of `QueryFragment` nodes rendered to SQL at runtime |
| Effect/async model | **Blocking** — `Connection` is synchronous; async is an out-of-tree companion crate (`diesel-async`, not in this checkout)                               |
| Backends           | PostgreSQL, MySQL, SQLite ([`diesel/Cargo.toml`][dieselcargo], [`README.md`][readme])                                                                    |
| First release      | ≈2016 (Sean Griffin; 1.0 in 2018, 2.0 in 2022) — web-attested                                                                                            |
| Latest version     | `2.3.11` (2026-07-10) — the pinned checkout's [`diesel/Cargo.toml`][dieselcargo] + [`CHANGELOG.md`][changelog]                                           |

> [!NOTE]
> Diesel is this survey's data point for the **schema-macro + fluent typed builder** flavour of a
> [typed query builder][qmodels]: a query is a chain of method calls mirroring SQL clauses, built
> over column structs the `table!` macro generates, whose SQL types live in Rust's type system — so
> an ill-typed comparison or a non-existent column is a compile error. It is the Rust analogue of
> `jOOQ` (JVM) and the sibling of `Kysely`/`Drizzle` (TypeScript) on the construction axis. It
> contrasts sharply with `sqlx`, the other flagship Rust library, which checks _raw SQL_ against a
> live database at build time rather than building a typed AST. Its effect model — a plain,
> synchronous `Connection` returning `Result` — is the deliberate opposite of the
> [effect-value][effects] mappers this [survey][index] weights most heavily. Terms below are defined
> once in the shared [concepts][concepts] vocabulary and linked, not re-defined here.

---

## Overview

### What it solves

Diesel removes the row-mapping boilerplate of a raw driver while pushing query validity into the
compiler. Its self-description ([`README.md`][readme]):

> _"Diesel gets rid of the boilerplate for database interaction and eliminates runtime errors
> without sacrificing performance. It takes full advantage of Rust's type system to create a low
> overhead query builder that \"feels like Rust.\""_

The crate root fixes the category ([`diesel/src/lib.rs`][lib]):

> _"Diesel is an ORM and query builder designed to reduce the boilerplate for database
> interactions."_

The headline is that the query builder is checked against your schema at compile time. That
requires you to declare the schema in Rust, and Diesel generates that declaration for you from the
live database ([`diesel/src/lib.rs`][lib]):

> _"For Diesel to validate your queries at compile time it requires you to specify your schema in
> your code, which you can do with [the `table!` macro][`table!`]. `diesel print-schema` can be
> used to automatically generate these macro calls (by connecting to your database and querying its
> schema)."_

The `README.md` shows the payoff two ways. A whole result-mapping `impl` collapses into a derive —
`#[derive(Queryable, Selectable)]` on a `Download` struct replaces a hand-written `from_row`
function ([`README.md`][readme]) — and a query composes as ordinary Rust that renders to exactly the
SQL you expect:

```rust
// diesel: README.md
let versions = Version::belonging_to(krate)
  .select(id)
  .order(num.desc())
  .limit(5);
let downloads = version_downloads
  .filter(date.gt(now - 90.days()))
  .filter(version_id.eq_any(versions))
  .order(date)
  .load::<Download>(&mut conn)?;
```

### Design philosophy

Diesel calls itself an ORM but its centre of gravity is the _query builder_; the in-repo guide draws
the line ([`guide_drafts/trait_derives.md`][traitderives]):

> _"In general, it may be more helpful to think of Diesel as a SQL query builder. While Diesel does
> offer some standard ORM (Object Relation Mapper) features, Diesel's code generation derives are for
> safely building SQL queries."_

The safety is achieved by encoding SQL structure in traits and letting the compiler reject anything
that does not typecheck ([`guide_drafts/trait_derives.md`][traitderives]):

> _"Part of what makes Diesel's query builder so powerful is its ability to assist writing safe SQL
> queries in Rust. It enables this level of safety through implementing a series of traits on your
> structs."_

Two consequences run through the library. First, **the schema is the single source of truth and it
lives in the type system**: the `table!` macro turns a column list into a module of zero-sized
marker structs, and every DSL method is generic over those markers, so "does column `X` exist on
table `Y`, and is `X op value` well-typed?" is answered by trait resolution, not at runtime. Second,
Diesel is explicit that _almost_, not _all_, runtime failure is removed
([`diesel/src/result.rs`][result], on the `DatabaseError` variant):

> _"While Diesel prevents almost all sources of runtime errors at compile time, it does not attempt
> to prevent 100% of them. Typically this error will occur from insert or update statements due to a
> constraint violation."_

The residue — constraint violations, deserialization mismatches, connection loss — surfaces through
an ordinary `Result`, not a typed per-query error channel (see [the effect model below](#effect-model-transactions-error-handling)).

---

## Connection, pooling & resource lifetime

A connection is a concrete per-backend type implementing the `Connection` trait:
`PgConnection` ([`diesel/src/pg/connection/mod.rs`][pgconn]),
`SqliteConnection` ([`diesel/src/sqlite/connection/mod.rs`][sqliteconn]), and
`MysqlConnection` ([`diesel/src/mysql/connection/mod.rs`][mysqlconn]). All are established the same
way — `Connection::establish(database_url)` returns a `ConnectionResult<Self>`
([`diesel/src/connection/mod.rs`][connection]) — and, per the [concepts][pools] note, a `Connection`
is single-session and takes `&mut self` on every query, so Rust's borrow checker enforces that one
connection runs one statement at a time (no aliasing, no accidental concurrent use).

The trait documents its own contract ([`diesel/src/connection/mod.rs`][connection]):

> _"This trait represents a database connection. It can be used to query the database through the
> query dsl provided by diesel, custom extensions or raw sql queries."_

Diesel leans on **prepared statements** both for performance and as the safety substrate for
parameter binding; the trait tells third-party implementers so directly: _"It's important to use
prepared statements to implement the following methods"_ (`LoadConnection::load`,
`Connection::execute_returning_count`) and to cache them via a `StatementCache`
([`diesel/src/connection/mod.rs`][connection]). Cache behaviour is tunable through a `CacheSize`
(`Unbounded` / `Disabled`).

**Pooling is opt-in and delegated to `r2d2`.** With the `r2d2` feature, Diesel provides a
`ConnectionManager` and `Pool` ([`diesel/src/r2d2.rs`][r2d2]): _"Connection pooling via r2d2."_ The
idiom is to build the pool once at start-up and lease a connection per unit of work; a leased
connection is returned to the pool on drop. There is no scoped acquire/release resource combinator
of the kind the [effect systems][pools] use — resource return rides on Rust's `Drop`, which is
deterministic but not reflected in a query's type.

---

## Query construction & injection safety

This is the heart of Diesel. The mechanism has three layers: a **schema macro** that manufactures
typed table/column structs, a **fluent DSL** whose methods map to SQL clauses over those structs,
and a **bind-parameter AST** so values never touch SQL text.

### The `table!` macro

The schema is declared with `table!`, which the macro doc describes precisely
([`diesel_derives/src/lib.rs`][derives], `table_proc`):

> _"Specifies that a table exists, and what columns it has. This will create a new public module,
> with the same name, as the name of the table. In this module, you will find a unit struct named
> `table`, and a unit struct with the name of each column."_

```rust
// diesel: diesel_derives/src/lib.rs (table! doc example)
diesel::table! {
    users {
        id -> Integer,
        name -> VarChar,
        favorite_color -> Nullable<VarChar>,
    }
}
```

That expands to a `users` module containing a unit struct `table`, a unit struct per column
(`id`, `name`, `favorite_color`), a `dsl` submodule re-exporting them, an `all_columns` constant,
a `star` expression, and a `SqlType` alias ([`diesel_derives/src/lib.rs`][derives]). Each column
struct carries its SQL type — `id: Integer`, `favorite_color: Nullable<VarChar>` — as an associated
type, which is the fact the compiler consults later. The `dsl` re-export is what lets you write
`users.filter(name.eq("Sean"))` instead of `users::table.filter(users::name.eq("Sean"))`. In
practice you do **not** hand-write these blocks: `diesel print-schema` introspects the database and
emits them into a `schema.rs`, making Diesel **database-first** by default.

### The fluent DSL

Query-building methods live on `QueryDsl` and map to SQL clauses, "unless it conflicts with a Rust
keyword (such as `WHERE`/`where`)" — hence `filter` rather than `where`
([`diesel/src/query_dsl/mod.rs`][querydsl], [`diesel/src/lib.rs`][lib]). Operators on columns live
on `ExpressionMethods` and are named after their Rust equivalents: _"`==` is called `.eq`, and `!=`
is called `.ne`"_ ([`diesel/src/lib.rs`][lib]). A representative query and its structure:

```rust
// users.filter(name.eq("Sean")).select(id) — from the .eq doctest
let data = users.select(id).filter(name.eq("Sean"));
assert_eq!(Ok(1), data.first(connection));
```

Nothing here is a string. `users` is the table struct, `name`/`id` are column structs, and each
method returns a new statement type wrapping the previous one — the query is a nested generic type,
an AST built at the type level.

### Compile-time column and type checking

The type check falls out of the signature of the expression methods. `.eq` is
([`diesel/src/expression_methods/global_expression_methods.rs`][exprmethods]):

```rust
// diesel: expression_methods/global_expression_methods.rs
fn eq<T>(self, other: T) -> dsl::Eq<Self, T>
where
    Self::SqlType: SqlType,
    T: AsExpression<Self::SqlType>,
{
    Grouped(Eq::new(self, other.as_expression()))
}
```

`Self::SqlType` is the column's SQL type (from the `table!` macro), and the bound
`T: AsExpression<Self::SqlType>` requires the right-hand value to be convertible into an expression
_of that SQL type_. So `name.eq("Sean")` compiles (a `&str` is `AsExpression<Text>`) while
`name.eq(1)` does **not** (`i32` is not `AsExpression<Text>`) — a type mismatch is a compile error,
never a runtime one. Referencing a column that is not on the table's `from` clause fails the same
way, via the `SelectableExpression`/`AppearsOnTable` bounds; the crate root even catalogues the
resulting error messages, e.g. _"`posts::title: SelectableExpression<users::table> is not satisfied`
… you're trying to select a field from a table that does not appear in your from clause"_
([`diesel/src/lib.rs`][lib]).

### Values become bind parameters, never text

`AsExpression` is also where injection safety is made structural. Converting a plain Rust value
produces a `Bound` node ([`diesel/src/expression/mod.rs`][expr], on `AsExpression`):

> _"Indicate that the type has data which will be sent separately from the query. This is generally
> referred as a \"bind parameter\". Types which implement [`ToSql`] will generally implement
> `AsExpression` this way."_

`Bound<T, U>` renders itself not as SQL text but as a placeholder plus an out-of-band value
([`diesel/src/expression/bound.rs`][bound]):

```rust
// diesel: expression/bound.rs
impl<T, U, DB> QueryFragment<DB> for Bound<T, U>
where
    DB: Backend + HasSqlType<T>,
    U: ToSql<T, DB>,
{
    fn walk_ast<'b>(&'b self, mut pass: AstPass<'_, 'b, DB>) -> QueryResult<()> {
        pass.push_bind_param(&self.item)?;
        Ok(())
    }
}
```

The query builder that the AST walks emits a placeholder for each bound value and collects the
values separately ([`diesel/src/query_builder/mod.rs`][querybuilder]):

> _"A bind parameter is a value which is sent separately from the query itself. It is represented in
> SQL with a placeholder such as `?` or `$1`."_

The `QueryBuilder` trait's surface is exactly `push_sql`, `push_identifier` (quoted), `push_bind_param`
(the placeholder), and `finish` ([`diesel/src/query_builder/mod.rs`][querybuilder]). Because a value
enters only through `push_bind_param` while the query structure enters through `push_sql`/
`push_identifier`, a hostile value can never change the query's shape — injection is impossible by
construction, the same guarantee (via a different mechanism) that a tagged-template library gives.

### Escape hatches

For SQL the builder cannot express, Diesel offers two raw paths, both marked `unsafe`-in-spirit.
`sql_query` runs a full raw statement whose results decode by column name into a
`#[derive(QueryableByName)]` struct, with `.bind::<Type, _>(value)` binding parameters
([`README.md`][readme], [`diesel/src/query_builder/sql_query.rs`][sqlquery]) — the bind API carries
an explicit warning: _"Diesel cannot validate that the value is of the right type nor can it validate
that you have passed the correct number of parameters."_ For a raw _fragment_ inside an otherwise
typed query, `dsl::sql::<SqlType>("…")` with `.bind::<Type, _>(…)` splices checked-only-by-you SQL
([`diesel/src/expression/sql_literal.rs`][sqlliteral]) — the one place a user reintroduces the
injection risk the typed path removes.

---

## Schema, migrations & code generation

Diesel is **database-first** in practice. The `table!` declarations are the schema the query builder
checks against, and the canonical way to obtain them is to introspect a live database with
`diesel print-schema` — a subcommand of the `diesel_cli` crate ([`diesel_cli/src/print_schema.rs`][printschema])
— which writes them into `schema.rs`. You _can_ hand-write `table!` blocks, but the tool exists so
you do not have to keep them in sync manually.

Schema _evolution_ is a first-class, in-repo concern (unlike `Slick`, which delegates it). The
`diesel_migrations` crate + the `diesel migrations` CLI own it
([`diesel_migrations/src/lib.rs`][migrations]):

> _"A database migration always provides procedures to update the schema, as well as to revert
> itself. Diesel's migrations are versioned, and run in order. Diesel also takes care of tracking
> which migrations have already been run automatically. Your migrations don't need to be idempotent,
> as Diesel will ensure no migration is run twice unless it has been reverted."_

A migration is a folder `{version}_{name}/` containing two hand-written SQL files —
_"`up.sql` will be used to run the migration, while `down.sql` will be used for reverting it"_
([`diesel_migrations/src/lib.rs`][migrations]). This is the opposite stance from the code-first ORMs
(`EF Core`, `Prisma`) that _emit_ migrations from the model: Diesel's migrations are raw SQL you
write, and the runner only versions, orders, and tracks them. Migrations can run via the CLI or be
compiled into the binary with the `embed_migrations!` macro. Each migration runs inside its own
transaction by default ([`diesel_migrations/src/lib.rs`][migrations]): _"a failing migration is
automatically rolled back, leaving the database in the state it was in before the migration
started"_ — with an opt-out (`run_in_transaction = false`) for statements a DB cannot run
transactionally.

The direction of dependence is worth stating plainly: **the SQL migrations are authoritative; the
`schema.rs` is derived from the database they produce.** There is no code-first path where Rust
structs generate the DDL.

---

## Type mapping & result decoding

Diesel keeps a strict wall between **SQL types** and **Rust types**. SQL types
(`diesel::sql_types::Integer`, `Text`, `Nullable<Text>`, …) are markers used only in the query
builder; the crate root warns _"You should never put them on your `Queryable` structs"_
([`diesel/src/lib.rs`][lib]). The mapping in each direction is a trait — `ToSql<ST, DB>` (encode a
Rust value into a bind parameter) and `FromSql<ST, DB>` (decode a result cell) — parameterized by
both the SQL type and the backend, so the same Rust `i32` can encode differently per database.

Row hydration is where the two result-mapping derives differ, and the difference is a genuine
sharp edge:

- **`#[derive(Queryable)]`** maps a query's result **positionally**. The derive doc is emphatic
  ([`diesel_derives/src/lib.rs`][derives]): _"it will assume that **all fields on your struct**
  matches **all fields in the query**, including the order and count. This means that field order is
  significant if you're using `#[derive(Queryable)]`. **Field name has no effect**."_ Swap two
  same-typed fields and you get silently wrong data, not an error.

- **`#[derive(Selectable)]`** maps **by column name** and, with `check_for_backend`, validates the
  mapping at compile time. It generates an `as_select()` select clause built from the named columns
  ([`diesel_derives/src/lib.rs`][derives]); `#[diesel(check_for_backend(diesel::pg::Pg))]`
  _"instructs the derive to generate additional code to identify potential type mismatches … result
  in much better error messages"_ ([`diesel_derives/src/lib.rs`][derives]). The crate's own guidance
  is to reach for `Selectable` + `check_for_backend` whenever `Queryable`'s positional matching
  produces confusing errors ([`diesel/src/lib.rs`][lib], [`diesel/src/query_dsl/mod.rs`][querydsl]).

Writing goes through the parallel derives: **`#[derive(Insertable)]`** maps struct fields to columns
for `INSERT` (by field name, overridable with `#[diesel(column_name = …)]`)
([`README.md`][readme], [`diesel_derives/src/lib.rs`][derives]), and `#[derive(AsChangeset)]` does
the same for `UPDATE`. Both accept `#[diesel(serialize_as = …)]` / `#[diesel(deserialize_as = …)]`
for custom per-field conversion.

**Nullability is in the type system.** A `Nullable<ST>` column materializes as a Rust `Option<T>`:
`Option<T>` implements `FromSql<Nullable<ST>, DB>` and `ToSql<Nullable<ST>, DB>`
([`diesel/src/type_impls/option.rs`][option]), so a nullable column that you try to read into a
non-`Option` field is a compile error, and `column.eq(None)` typechecks only against a nullable
column. This is the same [nullability-in-types][typemap] property `sqlx`/`Kysely`/`Slick` advertise.

---

## Effect model, transactions & error handling

**Diesel is blocking.** `Connection` is a synchronous trait — every method takes `&mut self` and
returns a `Result` inline; there is no future, no `Task`, no effect value
([`diesel/src/connection/mod.rs`][connection]). Nothing in the crate is `async`: async support is an
**out-of-tree companion crate, `diesel-async`** (not present in this checkout), which mirrors the
API over async connection pools. On the survey's [effect axis][effects], Diesel sits at the blocking
end, the opposite of the `ConnectionIO`/`ZIO`/`Effect` mappers — a query is _run_ where it is
written, not returned as a description to be interpreted later.

Queries are still lazy in a weaker sense: a statement type is `#[must_use]` and does nothing until
you call a `RunQueryDsl` execution method — `load` (returns `Vec<U>`), `first` / `get_result`
(one row), `get_results` (rows from a `RETURNING`), or `execute` (affected-row count)
([`diesel/src/query_dsl/mod.rs`][querydsl]). Each takes `&mut Conn` and returns a
`QueryResult<T>`, i.e. `Result<T, diesel::result::Error>` ([`diesel/src/result.rs`][result]):

```rust
// diesel: query_dsl/mod.rs (RunQueryDsl doctests)
let data = users.select(name).load::<String>(connection)?;      // Vec<String>
let data = users.load::<(i32, String)>(connection)?;            // tuple rows
let data = users.load::<User>(connection)?;                     // #[derive(Queryable)] struct
```

### Transactions and savepoints

Transactions are a closure combinator on `Connection`. `conn.transaction(|conn| { … })` runs the
body atomically ([`diesel/src/connection/mod.rs`][connection]):

> _"This function executes the provided closure `f` inside a database transaction. If there is
> already an open transaction for the current connection savepoints will be used instead. The
> connection is committed if the closure returns `Ok(_)`, it will be rolled back if it returns
`Err(_)`."_

So **nesting is real, via savepoints** — a nested `transaction` opens a `SAVEPOINT` rather than a
second `BEGIN`. The `AnsiTransactionManager` makes the SQL explicit
([`diesel/src/connection/transaction_manager.rs`][txman]):

```rust
// diesel: connection/transaction_manager.rs
let start_transaction_sql = match transaction_depth {
    None => Cow::from("BEGIN"),
    Some(transaction_depth) => Cow::from(alloc::format!(
        "SAVEPOINT diesel_savepoint_{transaction_depth}"
    )),
};
```

Rollback mirrors it: `ROLLBACK` at depth 1, `ROLLBACK TO SAVEPOINT diesel_savepoint_{n-1}` deeper in
([`diesel/src/connection/transaction_manager.rs`][txman]). Returning `Err(Error::RollbackTransaction)`
from the closure rolls back with no "real" error — Diesel _"will never return this variant unless you
gave it to us"_ ([`diesel/src/result.rs`][result]). The manager also handles the awkward case where a
commit fails and the follow-up rollback fails too, surfacing both in `Error::RollbackErrorOnCommit`
and marking the connection broken.

### Errors are one exception-style enum, not a typed channel

Every fallible operation returns `QueryResult<T> = Result<T, Error>`, where `Error` is a single
non-exhaustive enum of _"all the ways that a query can fail"_ ([`diesel/src/result.rs`][result]):
`DatabaseError(DatabaseErrorKind, …)`, `NotFound`, `QueryBuilderError`, `DeserializationError`,
`SerializationError`, `RollbackTransaction`, `AlreadyInTransaction`, `NotInTransaction`,
`BrokenTransactionManager`, and more. Recoverable database failures are further tagged by
`DatabaseErrorKind` (`UniqueViolation`, `ForeignKeyViolation`, …). This is a **flat, per-connection
error type shared by all queries**, not a per-query typed error set: unlike `doobie`/`skunk` (errors
in the effect's error type) or the Effect TS `SqlError` union, a Diesel query's type says nothing
about _which_ errors it can raise. Two ergonomic helpers soften it: `NotFound` is distinct so
`get_result`/`first` distinguish "no rows" from other failures, and `OptionalExtension::optional`
turns `Err(NotFound)` into `Ok(None)` ([`diesel/src/result.rs`][result]).

---

## Ecosystem & maturity

Diesel is a mature, widely-deployed Rust project — the pinned checkout is `diesel 2.3.11`, released
2026-07-10 ([`diesel/Cargo.toml`][dieselcargo], [`CHANGELOG.md`][changelog]) — dual-licensed
**MIT OR Apache-2.0** ([`diesel/Cargo.toml`][dieselcargo], [`LICENSE-MIT`][licensemit]), created by
Sean Griffin (© from 2015) and now stewarded by the Diesel Core Team, with maintenance work funded
by the NLnet/NGI Zero, Prototype Fund, and GitHub Secure Open Source programs
([`README.md`][readme]). It targets three backends — **PostgreSQL, MySQL, SQLite** — behind Cargo
features ([`diesel/src/lib.rs`][lib], [`README.md`][readme]), with the C client libraries
(`libpq`/`libmysqlclient`/`libsqlite3`) either linked or bundled via the `-sys` crates.

The workspace is large ([`Cargo.toml`][rootcargo]): the `diesel` crate itself, the `diesel_derives`
proc-macro crate (`table!`, `Queryable`, `Selectable`, `Insertable`, `AsChangeset`, `Associations`,
`QueryableByName`, `AsExpression`), `diesel_cli` (`print-schema`, `migration`), `diesel_migrations`,
`diesel_dynamic_schema` (runtime-known tables), and `dsl_auto_type` (the `#[auto_type]` inference
helper). Feature flags gate optional type integrations (`serde_json`, `chrono`, `uuid`,
`network-address`), pooling (`r2d2`), and — notably — the **maximum table width**: `32-column-tables`
(default), `64-`, `128-`, each _"substantially"_/_"significantly"_ increasing compile time
([`diesel/src/lib.rs`][lib]), a concrete signal of the trait-machinery cost. Diesel is the reference
compile-time-checked ORM in Rust; its principal peer is `sqlx` (macro-checked raw SQL against a live
DB), with `SeaORM` layered on top of the `sea-query` builder as the active-record-flavoured
alternative, and `cornucopia` in the query-file-codegen niche.

---

## Strengths

- **Compile-time-checked queries.** A wrong column, a table not in the `from` clause, or a
  type-mismatched comparison is a compile error, not a runtime one — the `.eq` bound
  `T: AsExpression<Self::SqlType>` is enforced by trait resolution.
- **Injection-proof by construction.** Values enter only via `push_bind_param` as `?`/`$1`
  placeholders; the query builder never interpolates data into SQL text. There is no "safe by
  default" caveat to remember.
- **Low overhead.** The query is a monomorphized AST of `QueryFragment` nodes with no boxing on the
  hot path; the README's pitch is compile-time safety _"without sacrificing performance."_
- **Codegen removes boilerplate.** `diesel print-schema` generates the `table!` blocks; the derives
  generate row mapping (`Queryable`/`Selectable`), inserts (`Insertable`), and updates
  (`AsChangeset`).
- **Real nested transactions.** `transaction` uses `SAVEPOINT`s for nesting, so an inner block can
  roll back independently of the outer transaction.
- **In-tree migrations.** Versioned `up.sql`/`down.sql` migrations, auto-tracked, each in its own
  transaction, runnable via CLI or embedded with `embed_migrations!`.
- **Nullability in types.** `Nullable<ST>` ⟷ `Option<T>` is compiler-enforced.
- **Three production backends** (PostgreSQL/MySQL/SQLite) behind one DSL, plus `r2d2` pooling.

## Weaknesses

- **Long compile times and heavy trait machinery.** Wider tables (`64-`/`128-column-tables`) inflate
  compile time _"significantly"_ by the crate's own admission; the whole design trades build time for
  compile-time safety.
- **Notoriously complex error messages.** The crate root dedicates a section to _"How to read
  diesels compile time error messages"_ ([`diesel/src/lib.rs`][lib]) — an implicit acknowledgement
  that the trait-bound failures are hard to read without `Selectable` + `check_for_backend`.
- **`Queryable` is positionally matched.** _"Field order is significant … field name has no
  effect"_, so a reordered struct silently mis-maps unless you use `Selectable`.
- **Blocking only.** Async requires the separate `diesel-async` crate; there is no effect value or
  built-in async in this tree.
- **No typed per-query error channel.** All failures collapse into one `diesel::result::Error` enum;
  the query type carries no information about which errors it can raise.
- **Not a full ORM.** No identity map, no unit of work, no automatic change tracking beyond
  `save_changes`; associations are child-to-parent only — _"Unlike other ORMs, Diesel has no concept
  of `has many`"_ ([`diesel/src/associations/mod.rs`][assoc]).
- **Database-first only.** The schema flows database → `schema.rs`; there is no code-first path that
  emits DDL from Rust structs.

## Key design decisions and trade-offs

| Decision                                                                     | Rationale                                                                               | Trade-off                                                                                                       |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| **`table!` macro → typed column/table structs**, schema in the type system   | Column existence and SQL types become trait facts, so queries typecheck at compile time | You must declare (or `print-schema`-generate) the schema; wide tables cost real compile time; opaque errors     |
| **Fluent DSL of monomorphized AST nodes** (`QueryFragment`)                  | Zero-cost, low-overhead SQL generation that "feels like Rust"; retargets three backends | The query is a deeply nested generic type; type signatures and boxed queries get unwieldy                       |
| **Values bind via `AsExpression` → `Bound` → `push_bind_param`**             | Injection is structurally impossible; data always travels out-of-band as `?`/`$1`       | A raw fragment (`sql_query`, `dsl::sql`) is the only escape and reintroduces the risk it removes                |
| **Blocking `Connection` (`&mut self`, returns `Result`)**                    | Simple, predictable, borrow-checked single-session use; no runtime coupling             | No async in-tree (needs `diesel-async`); not an effect value the way this survey's mappers are                  |
| **`transaction(closure)` with `SAVEPOINT` nesting**                          | Atomic block that composes; nested blocks get independent rollback                      | Rollback-on-commit-failure edge cases mark the connection broken; isolation levels need the lower-level manager |
| **One non-exhaustive `Error` enum for all failures**                         | Small, uniform surface; `NotFound`/`optional` cover the common recoveries               | No typed per-query error channel; you match a shared enum, not a query-specific error set                       |
| **Database-first schema + raw-SQL `up.sql`/`down.sql` migrations**           | Migrations are exactly the SQL that runs; `schema.rs` stays a faithful mirror of the DB | No code-first DDL generation; hand-written SQL and generated `schema.rs` can drift if not regenerated           |
| **`Queryable` (positional) vs `Selectable` (by-name + `check_for_backend`)** | A fast default derive plus a safer, name-matched, compile-checked one                   | The default silently mis-maps on field reorder; users must know to prefer `Selectable`                          |

---

## Sources

- [diesel-rs/diesel — GitHub repository][repo] · [docs.rs/diesel][docs] · [diesel.rs guides][guides]
- [`README.md` — positioning ("eliminates runtime errors without sacrificing performance"), query-builder + derive examples, raw SQL][readme]
- [`diesel/src/lib.rs` — crate root: ORM+builder definition, `table!`/`print-schema` compile-time validation, `filter`/`.eq` naming, SQL↔Rust type wall, error-message guide, feature flags][lib]
- [`guide_drafts/trait_derives.md` — "think of Diesel as a SQL query builder"; safety via traits][traitderives]
- [`diesel_derives/src/lib.rs` — `table_proc` (`table!`) doc; `Queryable`/`Selectable`/`Insertable` derive semantics; `check_for_backend`][derives]
- [`diesel/src/expression_methods/global_expression_methods.rs` — `.eq` signature, the `AsExpression<Self::SqlType>` compile-time check][exprmethods]
- [`diesel/src/expression/mod.rs` — `Expression`/`AsExpression` traits; bind-parameter conversion][expr] · [`diesel/src/expression/bound.rs` — `Bound` → `push_bind_param`][bound]
- [`diesel/src/query_builder/mod.rs` — `QueryBuilder`/`QueryFragment`; "placeholder such as `?` or `$1`"][querybuilder]
- [`diesel/src/query_builder/sql_query.rs`][sqlquery] · [`diesel/src/expression/sql_literal.rs`][sqlliteral] — the raw-SQL escape hatches + Safety notes
- [`diesel/src/query_dsl/mod.rs` — `QueryDsl` (clause methods), `RunQueryDsl` (`load`/`execute`/`first`/`get_result`)][querydsl]
- [`diesel/src/connection/mod.rs` — `Connection` trait, `establish`, `transaction` savepoint contract, prepared-statement requirement][connection]
- [`diesel/src/connection/transaction_manager.rs` — `BEGIN`/`SAVEPOINT diesel_savepoint_n` SQL][txman]
- [`diesel/src/result.rs` — `Error` enum, `DatabaseErrorKind`, `QueryResult`, `OptionalExtension`, "prevents almost all … not 100%"][result]
- [`diesel/src/type_impls/option.rs` — `Nullable<ST>` ⟷ `Option<T>`][option]
- [`diesel_migrations/src/lib.rs` — versioned `up.sql`/`down.sql` migrations, auto-tracking, per-migration transaction][migrations] · [`diesel_cli/src/print_schema.rs` — `print-schema` introspection][printschema]
- [`diesel/src/r2d2.rs` — r2d2 connection pooling][r2d2] · [`diesel/src/associations/mod.rs` — child-to-parent associations][assoc]
- [`diesel/Cargo.toml`][dieselcargo] · [`Cargo.toml` (workspace)][rootcargo] · [`CHANGELOG.md`][changelog] · [`LICENSE-MIT`][licensemit] · [`LICENSE-APACHE`][licenseapache]
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [effects, transactions & errors][effects] · [connections & pools][pools] · [type mapping & decoding][typemap] · [schema/migrations/codegen][schemamig] · [ORM patterns][ormpatterns] · [N+1][nplusone]

<!-- References -->

[repo]: https://github.com/diesel-rs/diesel
[docs]: https://docs.rs/diesel/latest/diesel/
[guides]: https://diesel.rs/guides/
[readme]: https://github.com/diesel-rs/diesel/blob/d4378b5/README.md
[lib]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/lib.rs
[traitderives]: https://github.com/diesel-rs/diesel/blob/d4378b5/guide_drafts/trait_derives.md
[guidedrafts]: https://github.com/diesel-rs/diesel/tree/d4378b5/guide_drafts
[derives]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel_derives/src/lib.rs
[exprmethods]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/expression_methods/global_expression_methods.rs
[expr]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/expression/mod.rs
[bound]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/expression/bound.rs
[querybuilder]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/query_builder/mod.rs
[sqlquery]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/query_builder/sql_query.rs
[sqlliteral]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/expression/sql_literal.rs
[querydsl]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/query_dsl/mod.rs
[connection]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/connection/mod.rs
[txman]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/connection/transaction_manager.rs
[result]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/result.rs
[option]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/type_impls/option.rs
[migrations]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel_migrations/src/lib.rs
[printschema]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel_cli/src/print_schema.rs
[r2d2]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/r2d2.rs
[assoc]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/associations/mod.rs
[pgconn]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/pg/connection/mod.rs
[sqliteconn]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/sqlite/connection/mod.rs
[mysqlconn]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/src/mysql/connection/mod.rs
[dieselcargo]: https://github.com/diesel-rs/diesel/blob/d4378b5/diesel/Cargo.toml
[rootcargo]: https://github.com/diesel-rs/diesel/blob/d4378b5/Cargo.toml
[changelog]: https://github.com/diesel-rs/diesel/blob/d4378b5/CHANGELOG.md
[licensemit]: https://github.com/diesel-rs/diesel/blob/d4378b5/LICENSE-MIT
[licenseapache]: https://github.com/diesel-rs/diesel/blob/d4378b5/LICENSE-APACHE
[concepts]: ./concepts.md
[index]: ./index.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[schemamig]: ./concepts.md#schema-migrations-code-generation
[ormpatterns]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem

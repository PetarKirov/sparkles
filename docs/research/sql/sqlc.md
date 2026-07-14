# sqlc (Go)

A command-line **SQL compiler**: you write a schema and a set of raw SQL queries each tagged
with a `-- name: GetAuthor :one` comment, and `sqlc generate` parses and type-checks that SQL
against its own embedded engine grammars, then emits fully-typed Go — a struct per table, a
`Queries` type, and one method per query running on `database/sql` or `pgx` — with no runtime
library, no ORM, and no query DSL.

| Field              | Value                                                                                                                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Go (the generator); emits Go, and — via plugins — Kotlin, Python, TypeScript, and more                                                                |
| License            | MIT (`Copyright (c) 2024 Riza, Inc.`)                                                                                                                 |
| Repository         | [sqlc-dev/sqlc][repo]                                                                                                                                 |
| Documentation      | [docs.sqlc.dev][docs] · [playground][play] · [`README.md`][readme]                                                                                    |
| Category           | [Safe-SQL / micro-mapper][concepts-ladder] — a **SQL-to-code generator** (db-first codegen); **not** an ORM, **not** a query builder                  |
| Abstraction level  | Between the [safe-SQL / micro-mapper][concepts-ladder] and [functional data-mapper][concepts-ladder] rungs; the generated code is a micro-mapper      |
| Query model        | [Macro-checked raw SQL][concepts-models] — but **statically parsed** by sqlc's own grammar, needing no database connection at build time              |
| Effect/async model | [Blocking][concepts-effects] — generated methods are synchronous `database/sql`/`pgx` calls taking a `context.Context`; errors are Go `error` returns |
| Backends           | PostgreSQL, MySQL, SQLite (primary); ClickHouse and GoogleSQL engines also present                                                                    |
| First release      | ≈2019 (`kyleconroy/sqlc`, web-attested via the [introductory blog post][blog])                                                                        |
| Latest version     | `v1.31.1` (the pinned tree's `internal/info` constant)                                                                                                |

> [!NOTE]
> sqlc is this survey's data point for **build-time code generation from raw SQL**. Like
> `sqlx` (Rust) and `cornucopia` it belongs to the [macro-checked raw SQL][concepts-models]
> family — but where `sqlx`'s `query!` macro PREPAREs against a _live_ development database,
> sqlc parses the SQL _statically_ with its own embedded grammar and infers every type from a
> schema it reads from `.sql` files, needing **no database connection**. It sits on the
> [db-first codegen][concepts-schema] axis: the schema `.sql` is the source of truth, and the
> output is ordinary Go you check into your repo. See [concepts][concepts] for shared vocabulary.

---

## Overview

### What it solves

sqlc removes the trade every Go developer using `database/sql` faces: hand-write the SQL and
then hand-write, and keep in sync, the `rows.Scan(&a, &b, …)` boilerplate and the parameter
structs — or adopt an ORM and lose SQL. sqlc keeps the SQL and _generates_ the boilerplate.
The `README` states the loop in three steps ([`README.md`][readme]):

> _"sqlc generates **type-safe code** from SQL. Here's how it works:_
> _1. You write queries in SQL._
> _1. You run sqlc to generate code with type-safe interfaces to those queries._
> _1. You write application code that calls the generated code."_

The documentation index makes the output language concrete and the promise blunt
([`docs/index.rst`][index]):

> _"sqlc generates **fully type-safe idiomatic Go code** from SQL. … Seriously, it's that
> easy. You don't have to write any boilerplate SQL querying code ever again."_

The framing is a _compiler_, not a library — the repository's own title is _"sqlc: A SQL
Compiler"_ ([`README.md`][readme]), and the CLI exposes a `compile` subcommand whose entire job
is to _"Statically check SQL for syntax and type errors"_ ([`internal/cmd/cmd.go`][cmd]) without
emitting anything. That is the load-bearing distinction from every other tool in this survey:
sqlc has a genuine front end. It parses your DDL into a **catalog**, parses each query against
that catalog, resolves the type of every parameter and every result column, and _only then_
hands a fully-typed intermediate representation to a language back end. A misspelled column, a
type mismatch, or a query against a non-existent table fails `sqlc generate` — the SQL bug is
caught at code-generation time, before the Go even compiles.

Two design negatives define the shape. sqlc is **not** a driver (it generates no wire code — it
targets `database/sql`/`pgx`), and it is **not** an ORM or builder: there is no runtime query
object, no method chain, no change tracking. The generated code is a thin, readable mapper you
own.

### Design philosophy

**SQL is the source language; Go is the object language.** sqlc treats a directory of `.sql`
files the way a C compiler treats `.c` files — as input to be parsed, checked, and lowered. The
project's tongue-in-cheek epigraph captures the stance ([`docs/index.rst`][index]): _"And lo,
the Great One looked down upon the people and proclaimed: 'SQL is actually pretty great'."_ The
consequence is that everything expressible in your database's SQL dialect is available to you,
because sqlc embeds a real parser for that dialect (see [Schema, migrations & code
generation](#schema-migrations-code-generation)) — you are not restricted to what a builder DSL
can model.

**Pure build-time, zero runtime.** There is no `import "sqlc"` in the generated code. The
tutorial is explicit that the tool itself is self-contained ([`docs/tutorials/getting-started-postgresql.md`][tut]):
_"sqlc itself has no dependencies."_ The emitted package imports only `context`,
`database/sql` (or `pgx`), and whatever type packages your columns need. No reflection, no
metadata is consulted at runtime; the "mapping" is fixed Go source produced once at generation
time.

**The query annotation drives the method shape.** sqlc's central convention is a one-line
comment above each query ([`docs/reference/query-annotations.md`][annot]):

> _"sqlc requires each query to have a small comment indicating the name and command. The
> format of this comment is as follows: `-- name: <name> <command>`"_

The `<name>` becomes the Go method name (and must be a valid Go identifier — validated in
[`internal/metadata/meta.go`][meta]); the `<command>` (`:one`, `:many`, `:exec`, …) selects the
method's return shape. This is the whole user-facing surface: annotated SQL in, typed Go out.

---

## Connection, pooling & resource lifetime

sqlc generates **no** connection, pool, or lifetime management code — a deliberate absence, and
a finding for this survey. The generated `Queries` type wraps a single narrow interface, `DBTX`,
that any driver handle satisfies ([`internal/codegen/golang/templates/stdlib/dbCode.tmpl`][dbtmpl]):

```go
type DBTX interface {
    ExecContext(context.Context, string, ...interface{}) (sql.Result, error)
    PrepareContext(context.Context, string) (*sql.Stmt, error)
    QueryContext(context.Context, string, ...interface{}) (*sql.Rows, error)
    QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}

func New(db DBTX) *Queries {
    return &Queries{db: db}
}
```

Because `*sql.DB`, `*sql.Tx`, and `*sql.Conn` all implement these four methods, `New(db)` accepts
any of them — and connection pooling is entirely `database/sql`'s job (or `pgxpool`'s for the
`pgx` back end, whose generated `DBTX` uses `Exec`/`Query`/`QueryRow` instead). sqlc owns none of
the resource story from [concepts][concepts-pools]: no pool sizing, no acquire/release, no scoped
lifetime. It hands you a stateless method set over whatever handle you pass. That is the same
minimalism as Go's stdlib `database/sql` — sqlc adds _typing_, not _plumbing_ — and it is the
sharp contrast with `hasql`'s `Pool`, `sqlx`'s (Rust) bounded fair `Pool`, or the effect
systems' scoped `Acquirer`. Prepared statements are optional and opt-in: with
`emit_prepared_queries`, `Prepare(ctx, db)` calls `PrepareContext` for every query up front and
routes calls through the cached `*sql.Stmt` ([`dbCode.tmpl`][dbtmpl]); otherwise each call is an
unprepared `…Context` call.

---

## Query construction & injection safety

This is one of sqlc's two centres of gravity. The mechanism has three parts: you write raw SQL,
you annotate it, and sqlc statically parses it to synthesize an injection-safe, typed method.

### You write SQL; sqlc parses and types it

A query file is ordinary SQL with a leading annotation. From the PostgreSQL tutorial
([`docs/tutorials/getting-started-postgresql.md`][tut]):

```sql
-- name: GetAuthor :one
SELECT * FROM authors
WHERE id = $1 LIMIT 1;

-- name: CreateAuthor :one
INSERT INTO authors (name, bio) VALUES ($1, $2)
RETURNING *;
```

The compiler reads each query file, parses every statement with the per-engine parser, and for
each statement extracts the name/command from the comment, then resolves parameters and columns
against the catalog ([`internal/compiler/parse.go`][cparse], [`internal/compiler/compile.go`][ccompile]).
`SELECT *` is **expanded** at compile time into the concrete column list (so a `*` that cannot
be resolved is an error), and `$1`/`$2` are matched to catalog column types to infer the Go
parameter types. The result is a typed `Query` (`SQL`, `Metadata`, `[]*Column`, `[]Parameter`)
in [`internal/compiler/query.go`][cquery].

### The generated method: a const string plus bind parameters

The emitter turns that typed `Query` into a package-level SQL _constant_ and a method that
passes the parameters as **bind arguments** to the driver
([`internal/codegen/golang/templates/stdlib/queryCode.tmpl`][qtmpl]):

```go
const getAuthor = `-- name: GetAuthor :one
SELECT id, name, bio FROM authors
WHERE id = $1 LIMIT 1
`

func (q *Queries) GetAuthor(ctx context.Context, id int64) (Author, error) {
    row := q.db.QueryRowContext(ctx, getAuthor, id)
    var i Author
    err := row.Scan(&i.ID, &i.Name, &i.Bio)
    return i, err
}
```

Two properties matter. First, **the SQL text is fixed at generation time** — a `const`, never
assembled at runtime. sqlc does not build SQL from strings the way a query builder does; _you_
wrote the query, sqlc merely embedded it. Second, **dynamic data travels only as bind
parameters**: `id` is passed as the trailing variadic argument to `QueryRowContext`, so the
value is transferred out-of-band and [SQL injection is structurally impossible][concepts-injection]
for a bound value — exactly the parameter-binding safety model `concepts` describes, inherited
directly from `database/sql`. There is no interpolation channel to misuse.

### Naming, nullability, and embedding macros

For anything positional binding cannot express, sqlc adds a small set of `sqlc.*` macros that it
rewrites away before generating ([`docs/reference/macros.md`][macros]):

- **`sqlc.arg(name)`** attaches a name to a parameter: _"This macro expands to an engine-specific
  parameter placeholder. The name of the parameter is noted and used during code generation."_
  So `WHERE lower(name) = sqlc.arg(name)` gives a named Go argument instead of a positional one.
- **`sqlc.narg(name)`** is _"The same as `sqlc.arg`, but always marks the parameter as
  nullable"_ — forcing an `Option`-shaped (`sql.NullString`, `*string`) Go type where inference
  would otherwise pick a non-null one.
- **`sqlc.embed(table)`** lets you _"reuse existing model structs in more queries"_: a join
  selecting `sqlc.embed(students), sqlc.embed(test_scores)` produces a row struct with nested
  `Student` and `TestScore` fields instead of a flat column list.
- **`sqlc.slice("ages")`** handles `IN (…)` for drivers that cannot bind a slice: it _"generates
  a dynamic query at runtime with the correct number of parameters."_

`sqlc.slice` is the single place sqlc's generated code touches the query text at runtime — it
`strings.Replace`s a `/*SLICE:ages*/?` marker with the right number of `?` placeholders
([`queryCode.tmpl`][qtmpl]) — but note the safety invariant holds: only the _count_ of
placeholders changes, and every actual value still travels as a bind parameter, never as
interpolated text. The macro's own doc flags the one cost: _"this macro can't be used with
prepared statements"_ ([`macros.md`][macros]).

### The escape hatch, and its absence

There is no `queryRaw` in sqlc, because _every_ query is already raw SQL — the "escape hatch" of
other tools is sqlc's normal mode. The corresponding limitation is the mirror image: sqlc cannot
express a query whose _structure_ varies at runtime (a conditional `WHERE`, a dynamic column
list, a runtime-chosen `ORDER BY`). Every query must be a fixed, named SQL statement known at
generation time. Where a builder like `Kysely` or `jOOQ` shines — assembling query shape from
data — sqlc simply does not play; you drop to `database/sql` by hand for that one query.

---

## Schema, migrations & code generation

The other centre of gravity, and where the "compiler" claim is earned: sqlc ships **its own SQL
parser per engine** and its own Go emitter.

### The engines: real, embedded grammars

`sqlc generate` dispatches on the configured `engine` to a per-dialect parser and catalog
([`internal/compiler/engine.go`][engine]):

| Engine       | Parser                                                                   | How it parses SQL                                                                           |
| ------------ | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `postgresql` | [`pganalyze/pg_query_go/v6`][pgquery] ([`postgresql/parse.go`][pgparse]) | Wraps `libpg_query` — the **actual PostgreSQL server grammar** extracted from PG's C source |
| `mysql`      | `sqlc-dev/marino/parser` ([`dolphin/parse.go`][dolphin])                 | sqlc's fork of the TiDB/PingCAP MySQL parser (the struct field is literally `pingcap`)      |
| `sqlite`     | ANTLR-generated ([`sqlite/parse.go`][sqliteparse], `antlr4-go/antlr/v4`) | A grammar compiled to an ANTLR recursive-descent parser                                     |

The PostgreSQL choice is the notable one: rather than reimplement PG's grammar, sqlc embeds
`libpg_query`, the exact parser Postgres itself uses, so any syntax the server accepts, sqlc
accepts. (When cgo is unavailable — Windows, or a pure-Go build — it falls back to
`wasilibs/go-pgquery`, a WASM build of the same library; [`parser/parser_wasi.go`][pgwasi].) Each
parser translates the dialect AST into sqlc's shared `internal/sql/ast` node types, so the rest
of the compiler is engine-agnostic.

### The catalog: schema is the source of truth

sqlc reads your schema DDL and folds it into an in-memory **catalog** — the type environment for
every subsequent query ([`internal/compiler/compile.go`][ccompile]). It parses `CREATE`/`ALTER`
statements ([`docs/howto/ddl.md`][ddl]): _"sqlc parses `CREATE TABLE` and `ALTER TABLE`
statements in order to generate the necessary code."_ Column nullability, primary keys, array
dimensions, and enum values are all captured here (e.g. a column is `NotNull` if it carries
`NOT NULL` or is part of the primary key — [`postgresql/parse.go`][pgparse]). By **default there
is no database connection**: the catalog is built entirely from the `.sql` files, and type
inference runs against it statically. An optional `analyzer.database` mode can connect to a real
database and use `EXPLAIN`/describe output to refine inference, but it is off unless configured
([`internal/compiler/engine.go`][engine]) — the static path is the norm.

### sqlc does not run migrations

A pointed absence: **sqlc is not a migration runner.** It _reads_ schema, but never _applies_ it
([`docs/howto/ddl.md`][ddl]):

> _"sqlc does not perform database migrations for you. However, sqlc is able to differentiate
> between up and down migrations. sqlc ignores down migrations when parsing SQL files."_

You point sqlc's `schema` at either a single DDL file or a directory of migration files produced
by an _external_ tool — `atlas`, `dbmate`, `golang-migrate`, `goose`, `sql-migrate`, `tern` are
all supported ([`ddl.md`][ddl]) — and sqlc strips the down/rollback halves
(`RemoveRollbackStatements` in [`internal/migrations/migrations.go`][migrations]) to reconstruct
the current schema. Applying migrations, versioning them, and recording what ran is left to that
external tool. This is the opposite of `sqlx` (Rust) and the effect systems, which ship a
first-party checksum-verified migration runner.

### The emitter, and the plugin architecture

The built-in Go back end is a `text/template` emitter ([`internal/codegen/golang/gen.go`][gen]):
it builds `[]Enum`, `[]Struct`, and `[]Query` from the compiler's typed result, then renders
`db.go` (the `DBTX`/`Queries` scaffolding), `models.go` (a struct per table/enum), and
`<queries>.sql.go` (a const + method per query). The generated code is run through `go/format`,
so it is gofmt-clean — the tutorial notes sqlc _"generates readable, **idiomatic** Go code that
you otherwise would've had to write yourself"_ ([`tut`][tut]).

Crucially, **the Go generator is itself a codegen plugin.** Every back end — built-in or
external — is invoked over the same `CodegenService` gRPC interface with a `GenerateRequest`
protobuf; the built-in Go and JSON emitters are wired in-process via
`ext.HandleFunc(golang.Generate)`, exactly parallel to how a WASM or subprocess plugin is called
([`internal/cmd/generate.go`][codegen]). External languages plug in two ways
([`docs/guides/plugins.md`][plugins]):

- **WASM plugins** — a `.wasm` module fetched by URL and pinned by `sha256`, run in the
  `wazero` sandbox: _"WASM plugins are fully sandboxed; they do not have access to the network,
  filesystem, or environment variables."_
- **Process plugins** — an external binary reading the request on stdin: _"Process-based plugins
  offer minimal security. Only use plugins that you trust."_

This is how sqlc targets Kotlin, Python, and TypeScript ([`sqlc-gen-kotlin`][repo] et al.) — and
how the community adds C#, F#, Ruby, Zig, and more, all consuming the same
schema-and-query-analysis front end.

---

## Type mapping & result decoding

Type mapping is a compile-time table lookup, not a runtime codec. Each engine has a
`<engine>_type.go` mapping catalog types to Go types; `goType` in
[`internal/codegen/golang/go_type.go`][gotype] resolves a column to its Go type, honoring
user `overrides` first. The doc states the default posture ([`docs/reference/datatypes.md`][datatypes]):
_"`sqlc` attempts to make reasonable default choices when mapping internal database types to Go
types."_

**Nullability is driven by the schema**, and it flows into the Go type. A `NOT NULL timestamp`
becomes `time.Time`; a nullable one becomes `sql.NullTime` ([`datatypes.md`][datatypes]) — or,
under the `pgx/v5` package, the corresponding `pgtype`. PostgreSQL arrays materialize as Go
slices (`text[]` → `[]string`). Enums become a defined Go type with typed constants. Because
inference reads the catalog's `NotNull` bit, adding `NOT NULL` in the schema _changes the
generated Go type_ — nullability is a first-class, statically-derived property, the same headline
that `sqlx` and `Kysely` sell, reached here through DDL parsing rather than a live-DB describe.

**Row hydration is generated `Scan` code**, not reflection. For `:one` the method does
`row.Scan(&i.ID, &i.Name, …)`; for `:many` it loops `rows.Next()`/`rows.Scan(…)` into a slice
([`queryCode.tmpl`][qtmpl]). The field order and pointers are fixed at generation time from the
resolved column list, so decoding costs nothing beyond the driver's own `Scan`. Custom Go types
plug in via `overrides` (map a column or a DB type to your own type, provided it implements the
driver's `Scanner`/`Valuer`), and `sqlc.embed` (above) composes existing model structs into a
nested row type — a limited, explicit form of object composition, never an automatic object
graph.

---

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and sqlc lands at the **[blocking][concepts-effects]**
point — the generated code is ordinary synchronous Go.

### Blocking calls, no effect value

Every generated method is a direct, synchronous driver call taking a `context.Context` as its
first argument and returning `(value, error)` ([`queryCode.tmpl`][qtmpl]). There is no future,
no `Task`, no `IO`/effect value: `authors, err := queries.ListAuthors(ctx)` runs the query and
blocks until the rows arrive ([`tut`][tut]). This is the Go idiom — concurrency is the _caller's_
job (a goroutine per unit of work), not a property of the query value. It is the antithesis of
`doobie`/`skunk`/`Quill`'s interpretable `ConnectionIO`/`ZIO` descriptions, and of `sqlx`'s
(Rust) `async` futures: a sqlc method is neither reifiable nor deferred; it _is_ the effect,
executed on call. For this survey's algebraic-effects lens, sqlc is the reference point for
"typed _shape_, untyped _effect_" — the result is exhaustively typed, but the effect is a bare,
eager, side-effecting function.

### Transactions: the driver's, wrapped by `WithTx`

sqlc generates no transaction combinator. Instead the `Queries` type carries a `WithTx` method
([`docs/howto/transactions.md`][txn]): _"the `WithTx` method allows a `Queries` instance to be
associated with a transaction."_ You manage the transaction lifecycle with the _driver's_ API and
re-bind the query set onto it:

```go
tx, err := db.Begin()
if err != nil {
    return err
}
defer tx.Rollback()
qtx := queries.WithTx(tx)
r, err := qtx.GetRecord(ctx, id)
// … more qtx calls …
return tx.Commit()
```

`WithTx(tx)` simply returns a new `Queries{db: tx}` — because `*sql.Tx` satisfies `DBTX`, the same
generated methods now run inside the transaction ([`dbCode.tmpl`][dbtmpl]). Begin/commit/rollback,
savepoints, isolation levels, and nesting are all whatever the underlying driver offers; sqlc
neither models nor constrains them. There is no `withTransaction(effect)` block, no automatic
rollback-on-error beyond the idiomatic `defer tx.Rollback()`, and no savepoint machinery like the
effect systems' nested `withTransaction`.

### Errors: plain Go `error`, no typed channel

Every method returns a bare `error`. A `:one` query that finds no row surfaces the driver's
`sql.ErrNoRows` (or `pgx.ErrNoRows`); a constraint violation surfaces the driver's error type,
which the caller inspects with `errors.Is`/`errors.As` and driver-specific predicates (e.g.
`*pq.Error`/`*pgconn.PgError` for a unique-violation SQLSTATE). sqlc adds no error taxonomy of
its own — there is no `SqlError` reason union like `Effect TS`, no per-query typed error slot,
no `Either` hierarchy like `hasql`. An optional `wrap_errors` codegen flag wraps returns in
`fmt.Errorf("query X: %w", err)` for context ([`gen.go`][gen]), but the channel remains Go's
single untyped `error`. This is the same coarseness as `sqlx`'s (Rust) monolithic `Error`, taken
further: sqlc delegates the error _type_ to the driver entirely.

### Build-time verification: `vet`, `verify`, `diff`

sqlc pushes some checks that other tools do at runtime into the toolchain. `sqlc vet` runs
queries through CEL lint rules ([`docs/howto/vet.md`][vet]) — with an optional database
connection it exposes `EXPLAIN (… FORMAT JSON)` output to the rules, catching, e.g., a query that
would do a sequential scan. `sqlc verify` (_"Verify schema, queries, and configuration"_,
[`internal/cmd/verify.go`][verify]) checks queries against an updated schema via sqlc Cloud, and
`sqlc diff` compares freshly-generated output to the committed files so CI fails if someone edited
SQL without regenerating. These are the compiler's answer to the effect systems' runtime typed
errors: shift the failure left, to `generate`/CI time.

---

## Ecosystem & maturity

sqlc is a mature, widely-adopted tool under the permissive **MIT** license, copyright _"Riza,
Inc."_ ([`LICENSE`][license]), created by Kyle Conroy (the sponsor link points at
`github.com/sponsors/kyleconroy`, and the first release was ≈2019 — web-attested via the
[introductory blog post][blog]). The pinned tree reports `v1.31.1`
([`internal/info/facts.go`][info]).

**Backends.** PostgreSQL and MySQL are the most complete; SQLite is Beta for the built-in Go
generator ([`docs/reference/language-support.rst`][langsupport]). ClickHouse and GoogleSQL
engines also exist in `internal/engine/` (the pinned commit — `22d878a` — is _"feat: add GoogleSQL
support to `sqlc parse`"_), though narrower than the big three.

**Languages.** Beyond built-in Go, first-party plugins cover Kotlin, Python, and TypeScript
([`README.md`][readme]); the community language table lists C#, F#, Java, PHP, Ruby, Zig, Rust,
and Gleam plugins ([`langsupport`][langsupport]) — all riding the same WASM/process plugin
protocol. This plugin split is what lets a single SQL-analysis front end fan out across
ecosystems, and is the strongest architectural bet in the project.

**sqlc Cloud** adds hosted query verification, managed test databases, and `push`/`verify`
against published schema versions ([`tut`][tut]) — an optional commercial layer over the
open-source generator.

---

## Strengths

- **Real SQL front end.** sqlc genuinely parses your SQL (Postgres via `libpg_query` — the
  server's own grammar) and type-checks it against a catalog, so column/type/table bugs fail
  `generate`, before any Go compiles — and without a database connection.
- **Injection-safe by construction, zero runtime.** Queries are `const` strings; data binds
  out-of-band through `database/sql`. No ORM, no reflection, no runtime dependency — the emitted
  code is plain, gofmt-clean Go you own.
- **Nullability and types in the generated signatures.** `NOT NULL` in the schema changes the Go
  type; arrays, enums, and composite/embedded rows all map through statically.
- **Idiomatic, driver-agnostic output.** One method per query on a four-method `DBTX` interface;
  works with `database/sql`, `lib/pq`, or `pgx`, and drops straight into transactions via
  `WithTx`.
- **Language-agnostic via plugins.** A WASM/process codegen protocol (the built-in Go generator
  uses it too) targets Kotlin, Python, TypeScript, and a long community tail from one front end.
- **Shift-left tooling.** `vet` (CEL + `EXPLAIN`), `verify`, and `diff` push checks into CI that
  other stacks meet only at runtime.

## Weaknesses

- **No dynamic queries.** Every query is a fixed, named statement decided at generation time;
  runtime-variable structure (conditional `WHERE`, dynamic columns/`ORDER BY`) has no expression
  — you fall back to hand-written `database/sql` there.
- **Not a migration tool.** sqlc reads schema but never applies it; you need a separate migration
  runner, and sqlc's view of the schema can drift from what's actually deployed.
- **Static inference has blind spots.** Without the optional live-DB analyzer, complex
  expressions, some function return types, and tricky nullability need `sqlc.narg`/overrides or
  column annotations to steer; the analyzer that fixes this needs a database and is off by default.
- **Blocking, untyped-effect model.** Generated methods are eager synchronous calls returning a
  bare `error` — no effect value to inspect/interpret, no typed error channel, transactions and
  savepoints entirely delegated to the driver.
- **A regeneration step in the loop.** The generated code is an artifact to re-run and re-commit
  on every SQL change; `diff` in CI is needed to keep it honest.
- **Backend/language maturity is uneven.** PostgreSQL/MySQL lead; SQLite is Beta; ClickHouse and
  GoogleSQL are narrower; non-Go languages are Beta plugins.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                          | Trade-off                                                                                            |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **Embed a real per-engine parser** (Postgres = `libpg_query`)        | Accept anything the dialect does; type-check statically without a DB connection    | Three parser back ends to maintain; static inference has gaps a live DB would resolve                |
| **Static catalog from schema `.sql`, DB analyzer optional**          | No database needed at build time; deterministic, CI-friendly `generate`            | Schema files can drift from the deployed DB; hard cases need macros/overrides or the opt-in analyzer |
| **`-- name: … :cmd` annotation drives codegen**                      | Minimal surface — annotated SQL is the whole input; command picks the method shape | Every query must be a fixed, named statement; no runtime-dynamic query structure                     |
| **Emit `const` SQL + bind params on `database/sql`/`pgx`**           | Injection-safe by construction; zero runtime dependency; idiomatic, readable Go    | Cannot vary query shape at runtime; `sqlc.slice` is the one (still param-safe) exception             |
| **Generate no connection/pool/transaction code** (`DBTX` + `WithTx`) | Delegate resource lifetime to the driver; work with any handle                     | No pooling/lifetime/savepoint model of its own; caller owns all of it                                |
| **Blocking methods, bare `error` returns**                           | Match Go idiom; concurrency and error taxonomy are the caller's                    | No effect value, no typed error channel; transactions are driver-managed                             |
| **Everything is a codegen plugin** (WASM/process, built-ins too)     | One SQL front end targets many languages; sandboxed, pinned WASM plugins           | Non-Go targets are separate plugins at varying maturity; a plugin protocol to keep stable            |
| **Read migrations, never run them**                                  | Stay a compiler; interoperate with `atlas`/`goose`/`dbmate`/…                      | No first-party migration runner or checksum verification (unlike `sqlx`, the effect systems)         |

---

## Sources

- [sqlc-dev/sqlc — GitHub repository][repo] · [docs.sqlc.dev][docs] · [playground][play] · [introductory blog post][blog]
- [`README.md` — "sqlc generates type-safe code from SQL", the three-step loop, "A SQL Compiler", supported languages][readme]
- [`docs/index.rst` — "fully type-safe idiomatic Go code", "SQL is actually pretty great", "no boilerplate … ever again"][index]
- [`docs/reference/query-annotations.md` — the `-- name: <name> <command>` convention; `:one`/`:many`/`:exec`/`:batch*`/`:copyfrom`][annot]
- [`docs/reference/macros.md` — `sqlc.arg`/`sqlc.narg`/`sqlc.embed`/`sqlc.slice`][macros]
- [`docs/reference/datatypes.md` — default type mapping, nullability → `sql.NullX`, arrays → slices][datatypes]
- [`docs/howto/ddl.md` — "sqlc does not perform database migrations for you"; external migration-tool support][ddl]
- [`docs/howto/transactions.md` — `WithTx` binds a `Queries` set onto a driver transaction][txn]
- [`docs/howto/vet.md` — CEL lint rules + `EXPLAIN` output][vet] · [`docs/guides/plugins.md` — WASM (sandboxed) / process plugins][plugins]
- [`docs/tutorials/getting-started-postgresql.md` — end-to-end example, "sqlc itself has no dependencies", generated `db.go`/`models.go`/`query.sql.go`][tut]
- [`internal/compiler/engine.go` — engine dispatch (postgresql/dolphin/sqlite), optional DB analyzer][engine] · [`internal/compiler/compile.go` — catalog + query parsing][ccompile] · [`internal/compiler/parse.go`][cparse] · [`internal/compiler/query.go` — typed `Query`/`Column`/`Parameter`][cquery]
- [`internal/engine/postgresql/parse.go` — `pganalyze/pg_query_go/v6` (libpg_query)][pgparse] · [`internal/engine/postgresql/parser/parser_wasi.go` — WASM fallback][pgwasi] · [`internal/engine/dolphin/parse.go` — `sqlc-dev/marino` (TiDB) MySQL parser][dolphin] · [`internal/engine/sqlite/parse.go` — ANTLR][sqliteparse]
- [`internal/metadata/meta.go` — annotation parsing, command constants, query-name validation][meta]
- [`internal/codegen/golang/gen.go` — `text/template` emitter, `wrap_errors`][gen] · [`internal/codegen/golang/templates/stdlib/dbCode.tmpl` — `DBTX`/`Queries`/`New`/`WithTx`][dbtmpl] · [`.../queryCode.tmpl` — `const` SQL + bind-param methods][qtmpl] · [`internal/codegen/golang/go_type.go`][gotype]
- [`internal/cmd/cmd.go` — `generate`/`compile` ("Statically check SQL")/`diff`][cmd] · [`internal/cmd/generate.go` — codegen dispatch (built-in via `ext.HandleFunc`, WASM/process plugins)][codegen] · [`internal/cmd/verify.go`][verify]
- [`internal/config/config.go` — engine, schema/queries, `Plugin` (Process/WASM), `analyzer.database`][config] · [`internal/migrations/migrations.go` — down-migration stripping][migrations] · [`internal/info/facts.go` — `v1.31.1`][info] · [`LICENSE` — MIT / Riza, Inc.][license] · [`docs/reference/language-support.rst`][langsupport]
- Shared vocabulary: [concepts & vocabulary][concepts] · [the abstraction ladder][concepts-ladder] · [query construction models][concepts-models] · [statements, parameters & injection][concepts-injection] · [schema, migrations & codegen][concepts-schema] · [effects, transactions & error handling][concepts-effects] · [connections & pools][concepts-pools]

<!-- References -->

[concepts]: ./concepts.md
[concepts-ladder]: ./concepts.md#the-abstraction-ladder
[concepts-models]: ./concepts.md#query-construction-models
[concepts-injection]: ./concepts.md#statements-parameters-and-sql-injection
[concepts-pools]: ./concepts.md#connections-pools-and-sessions
[concepts-schema]: ./concepts.md#schema-migrations-code-generation
[concepts-types]: ./concepts.md#type-mapping-and-result-decoding
[concepts-effects]: ./concepts.md#effects-transactions-and-error-handling
[index]: ./index.md
[repo]: https://github.com/sqlc-dev/sqlc
[docs]: https://docs.sqlc.dev
[play]: https://play.sqlc.dev
[blog]: https://conroy.org/introducing-sqlc
[readme]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/README.md
[cmd]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/cmd/cmd.go
[codegen]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/cmd/generate.go
[verify]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/cmd/verify.go
[engine]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/compiler/engine.go
[ccompile]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/compiler/compile.go
[cparse]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/compiler/parse.go
[cquery]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/compiler/query.go
[pgparse]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/engine/postgresql/parse.go
[pgwasi]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/engine/postgresql/parser/parser_wasi.go
[pgquery]: https://github.com/pganalyze/pg_query_go
[dolphin]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/engine/dolphin/parse.go
[sqliteparse]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/engine/sqlite/parse.go
[meta]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/metadata/meta.go
[gen]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/codegen/golang/gen.go
[dbtmpl]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/codegen/golang/templates/stdlib/dbCode.tmpl
[qtmpl]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/codegen/golang/templates/stdlib/queryCode.tmpl
[gotype]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/codegen/golang/go_type.go
[config]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/config/config.go
[migrations]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/migrations/migrations.go
[info]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/internal/info/facts.go
[license]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/LICENSE
[annot]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/reference/query-annotations.md
[macros]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/reference/macros.md
[datatypes]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/reference/datatypes.md
[ddl]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/howto/ddl.md
[txn]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/howto/transactions.md
[vet]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/howto/vet.md
[plugins]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/guides/plugins.md
[tut]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/tutorials/getting-started-postgresql.md
[langsupport]: https://github.com/sqlc-dev/sqlc/blob/22d878abc860cb01a53eefb1be3140d3504f79d1/docs/reference/language-support.rst

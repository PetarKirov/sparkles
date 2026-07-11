# Go `database/sql` + `jmoiron/sqlx` (Go)

Go's standard-library database access: a driver-agnostic **connection pool** (`database/sql`) sitting on a small pluggable-driver contract (`database/sql/driver`) that third-party drivers implement — you write raw SQL, bind parameters as out-of-band placeholders, and scan result columns into variables **by position** (`rows.Scan(&a, &b)`); `jmoiron/sqlx` is the community superset that adds struct scanning, `:name` parameters, and slice expansion **without** becoming an ORM.

| Field              | Value                                                                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language           | Go                                                                                                                                                     |
| License            | BSD-3-Clause (the Go project license) for the stdlib; [MIT][sqlxlicense] for `sqlx` (© 2013 Jason Moiron)                                              |
| Repository         | [`golang/go` · `src/database/sql`][repo] (stdlib) · [`jmoiron/sqlx`][sqlxrepo]                                                                         |
| Documentation      | [pkg.go.dev/database/sql][docs] · [pkg.go.dev/database/sql/driver][driverpkg] · [pkg.go.dev/.../sqlx][sqlxdocs] · [jmoiron.github.io/sqlx][sqlxguide]  |
| Category           | [Driver][concepts-ladder] + connection pool (stdlib) · [safe-SQL / micro-mapper][concepts-ladder] (`sqlx`)                                             |
| Abstraction level  | [Driver rung][concepts-ladder] (`database/sql`) → [safe-SQL / micro-mapper rung][concepts-ladder] (`sqlx`) — the two lowest rungs of the ladder        |
| Query model        | [Raw SQL string][concepts-models] + positional placeholders (`?` / `$1` / `@p1`, driver-dependent); `sqlx` adds client-side `:name` named params       |
| Effect/async model | [Blocking][concepts-effects], `context`-aware (goroutine-per-call; the pool handles concurrency); no future/effect value                               |
| Backends           | Any engine with a registered `driver.Driver` — Postgres (`lib/pq`, `pgx`), MySQL (`go-sql-driver/mysql`), SQLite (`go-sqlite3`), SQL Server, Oracle, … |
| First release      | ≈2012 (Go 1.0; the `sql`/`sql/driver` split predates it as `exp/sql`) — web-attested; `sqlx` ≈2013 (LICENSE © 2013)                                    |
| Latest version     | stdlib tracks the Go release (reviewed at the Go 1.27 development tip, commit `01534385`); `sqlx` `v1.4.0` (2024, web) — reviewed at `41dac16`         |

> [!NOTE]
> `database/sql` occupies the **[driver rung][concepts-ladder]** of the abstraction ladder —
> the thinnest rung, one step below even a [micro-mapper][concepts-ladder]: it talks to no
> database itself, generates no SQL, and maps no rows to objects. Its two jobs are the
> `driver` **interface** (the contract `lib/pq`/`pgx`/`go-sqlite3` implement) and the
> `*sql.DB` **connection pool**. `sqlx` climbs exactly one rung to the
> [safe-SQL / micro-mapper][concepts-ladder] — adding `Get`/`Select` struct hydration and
> `:name` binding — and stops there. Together they are this survey's **baseline**: the
> raw-SQL floor against which every higher library (`GORM`, `ent`, `sqlc`, and the effect
> systems) is measured, and the Go analogue of `Dapper` (.NET), `JDBI` (Java), and `hasql`
> (Haskell). See [concepts][concepts] for shared vocabulary.

---

## Overview

### What it solves

`database/sql` is a **generic interface plus a connection pool**, deliberately not a
database client. The package doc states the split in its first two sentences
([`src/database/sql/sql.go`][sqlgo]):

> _"Package sql provides a generic interface around SQL (or SQL-like) databases._
> _The sql package must be used in conjunction with a database driver."_

The companion `driver` package holds the interfaces that make the "in conjunction with"
work ([`driver/driver.go`][drivergo]):

> _"Package driver defines interfaces to be implemented by database drivers as used by_
> _package sql. Most code should use the [database/sql] package."_

Two packages, two audiences. The design memo bundled with the source draws the boundary
as a picture ([`doc.txt`][doctxt]):

> _"User Code ---> sql package (concrete types) ---> sql/driver (interfaces)_
> _Database Driver -> sql (to register) + sql/driver (implement interfaces)"_

Application code depends only on the concrete `*sql.DB`/`*sql.Rows`/`*sql.Tx` types; a
driver (`github.com/lib/pq`, `github.com/jackc/pgx`, `github.com/mattn/go-sqlite3`,
`github.com/go-sql-driver/mysql`, …) depends only on the `driver` interfaces and calls
`sql.Register` at `init` time. **No driver ships in the standard library** — the `Open`
doc is explicit ([`src/database/sql/sql.go`][sqlgo]): _"No database drivers are included
in the Go standard library. See https://golang.org/s/sqldrivers for a list of third-party
drivers."_ Selecting a backend is a blank import (`import _ "github.com/lib/pq"`) whose
`init` registers the driver name, and `Register` panics on a duplicate or nil driver
([`src/database/sql/sql.go`][sqlgo]).

The user-facing shape is small: obtain a `*sql.DB`, hand it a SQL string and arguments,
and either `Exec` (no rows), `Query` (many rows), or `QueryRow` (at most one). The
canonical read loop is verbose by design ([`example_test.go`][example]):

```go
// database/sql — the idiomatic Query → Next → Scan → Err → Close loop
rows, err := db.QueryContext(ctx, "SELECT name FROM users WHERE age=?", age)
if err != nil {
    log.Fatal(err)
}
defer rows.Close()
names := make([]string, 0)
for rows.Next() {
    var name string
    if err := rows.Scan(&name); err != nil { // scan columns into vars by position
        log.Fatal(err)
    }
    names = append(names, name)
}
if err := rows.Err(); err != nil { // distinguishes "done" from "iteration failed"
    log.Fatal(err)
}
```

Every one of those steps — check the `Query` error, `defer rows.Close()`, `Scan` into
correctly-typed variables in column order, and separately consult `rows.Err()` because
`Next` returning `false` conflates end-of-rows with an iteration error — is a place to get
it wrong. That verbosity is precisely the gap `sqlx` fills.

`sqlx` is a strict **superset wrapper**, not a replacement. Its package doc
([`doc.go`][sqlxdoc]):

> _"Package sqlx provides general purpose extensions to database/sql._
> _It is intended to seamlessly wrap database/sql and provide convenience methods which_
> _are useful in the development of database driven applications. None of the underlying_
> _database/sql methods are changed. Instead all extended behavior is implemented through_
> _new methods defined on wrapper types."_

The `README.md` states the compatibility contract that makes adoption incremental
([`README.md`][sqlxreadme]):

> _"The sqlx versions of `sql.DB`, `sql.TX`, `sql.Stmt`, et al. all leave the underlying_
> _interfaces untouched, so that their interfaces are a superset on the standard ones."_

Structurally, `sqlx.DB` **embeds** `*sql.DB` (`type DB struct { *sql.DB; … }`,
[`sqlx.go`][sqlxgo]), so an `*sqlx.DB` _is_ an `*sql.DB` with extra methods — you can drop
`sqlx` into an existing `database/sql` codebase and reach for `Get`/`Select`/`NamedExec`
only where they help.

### Design philosophy

Three properties define `database/sql`, each traceable to its own goals memo.

**The pool is the point — hide per-connection concurrency.** The single largest value-add
is that `*sql.DB` is not a connection but a **pool** of them, safe to share across
goroutines. From `doc.txt` ([`doc.txt`][doctxt]):

> _"Handle concurrency well. Users shouldn't need to care about the database's_
> _per-connection thread safety issues (or lack thereof), and shouldn't have to maintain_
> _their own free pools of connections. The 'sql' package should deal with that_
> _bookkeeping as needed. Given an \*sql.DB, it should be possible to share that instance_
> _between multiple goroutines, without any extra synchronization."_

A raw `driver.Conn` is single-threaded — _"The returned connection is only used by one
goroutine at a time"_ ([`driver/driver.go`][drivergo]) — but the pool leases one connection
per statement and returns it after, so application code never sees that constraint.

**Feel like Go, care about the common case.** The memo lists _"Feel like Go"_ and _"Care
mostly about the common cases. Common SQL should be portable. SQL edge cases or db-specific
extensions can be detected and conditionally used… It is a non-goal to care about every
particular db's extension or quirk"_ ([`doc.txt`][doctxt]). The result is a small,
stringly-typed API: no query builder, no schema types, no code generation.

**Push complexity down, keep the interface stable.** _"Push complexity, where necessary,_
_down into the sql+driver packages, rather than exposing it to users"_ and _"Provide_
_optional interfaces in sql/driver for drivers to implement for special cases or_
_fastpaths. But the only party that knows about those is the sql package"_
([`doc.txt`][doctxt]). This is the [design-by-introspection][concepts] move: a driver can
implement `QueryerContext`, `SessionResetter`, `Validator`, `NamedValueChecker`, or the
`RowsColumnType*` family, and `database/sql` probes for them at run time via type
assertions, transparently upgrading behaviour — _"some stuff just might start working or
start working slightly faster."_

`sqlx`'s philosophy is the mirror image: **add ergonomics, subtract nothing.** It never
changes the wire behaviour; it only saves you the `Scan` boilerplate and the manual
placeholder bookkeeping.

---

## Connection, pooling & resource lifetime

This is where `database/sql` earns its keep. `*sql.DB` is a pool, and its type doc says so
first ([`src/database/sql/sql.go`][sqlgo]):

> _"DB is a database handle representing a pool of zero or more underlying connections._
> _It's safe for concurrent use by multiple goroutines._
> _The sql package creates and frees connections automatically; it also maintains a free_
> _pool of idle connections."_

**`Open` is lazy.** `sql.Open` (and the driver-native `sql.OpenDB(connector)`) merely
validate arguments and start a background opener goroutine; no connection is dialed until
the first query. _"Open may just validate its arguments without creating a connection to
the database. To verify that the data source name is valid, call [DB.Ping]"_
([`src/database/sql/sql.go`][sqlgo]). The doc adds the operational rule: _"the Open
function should be called just once. It is rarely necessary to close a [DB]"_ — a `*sql.DB`
is a long-lived, process-scoped object, not a per-request handle.

**The pool is configured with four knobs**, all methods on `*DB`
([`src/database/sql/sql.go`][sqlgo]):

```go
db.SetMaxOpenConns(n)          // hard cap on total open conns; <= 0 = unlimited (default 0)
db.SetMaxIdleConns(n)          // idle conns retained for reuse (defaultMaxIdleConns = 2)
db.SetConnMaxLifetime(d)       // close & reopen a conn older than d
db.SetConnMaxIdleTime(d)       // close a conn idle longer than d
```

The defaults are load-bearing footguns: `maxOpen` is **unlimited** by default
(`maxOpen <= 0 means unlimited`) and `maxIdleCount` defaults to **2**
(`const defaultMaxIdleConns = 2`), so a burst of concurrency can open a flood of
connections while only two survive as idle — the classic reason to set both explicitly. The
methods keep the two consistent: _"If MaxOpenConns is greater than 0 but less than the new
MaxIdleConns, then the new MaxIdleConns will be reduced to match the MaxOpenConns limit"_
([`src/database/sql/sql.go`][sqlgo]).

**Checkout is a leasing protocol.** `(*DB).conn(ctx, strategy)` prefers a free connection
(`cachedOrNewConn`), and if the pool is at `maxOpen` it registers a `connRequest` on a
channel and **blocks until a connection is returned or `ctx` is canceled**
([`src/database/sql/sql.go`][sqlgo]):

```go
// (*DB).conn — abridged: at the cap, wait for a returned conn or ctx cancellation
if db.maxOpen > 0 && db.numOpen >= db.maxOpen {
    req := make(chan connRequest, 1)
    delHandle := db.connRequests.Add(req)
    db.waitCount++
    db.mu.Unlock()
    select {
    case <-ctx.Done():
        // remove the request; return ctx.Err()
    case ret, ok := <-req:
        // got a connection handed back by putConn
    }
}
```

Release is symmetric: `(*DB).putConn` returns the leased connection to `freeConn` (or hands
it directly to a waiting request), calling the driver's `ResetSession`/`IsValid` hooks first
if implemented. A background `connectionCleaner` closes connections that exceed
`maxLifetime`/`maxIdleTime`. The `context` threaded into every call is the **cancellation
and timeout** mechanism for the whole wait-plus-query — a canceled context aborts a pool
wait, a query, and (for a `Tx`) triggers rollback.

**Three lifetime scopes, three types.** A statement off `*sql.DB` leases a connection for
the duration of that one call. A `*sql.Tx` (from `Begin`/`BeginTx`) **binds one connection**
exclusively until `Commit`/`Rollback` returns it. A `*sql.Conn` (from `db.Conn(ctx)`)
reserves a single pooled connection for a sequence of calls — _"A \*DB is a pool of
connections. Call Conn to reserve a connection for exclusive use"_ — and `conn.Close()`
returns it to the pool ([`example_test.go`][example]). This is the substrate a
[scoped acquire/release][concepts-pools] effect design would formalize; in Go it is
`defer`-and-discipline, and a leaked `*Rows` (never `Close`d) leaks its connection.

`sqlx` adds **nothing** here — it embeds `*sql.DB`, so `SetMaxOpenConns`, `Conn`, and the
whole pool are inherited verbatim. `sqlx.Connect` is the one nicety: `Open` + an immediate
`Ping` so a bad DSN fails at construction rather than at first query ([`sqlx.go`][sqlxgo]).

## Query construction & injection safety

The model is the same at both rungs: **you write raw SQL text; parameter values travel a
separate channel and never become SQL.** `database/sql` does not parse, validate, or
generate your query — it is an opaque string forwarded to the driver, with the argument
list handed over as `[]driver.NamedValue`.

**Placeholders are driver-defined, bound out-of-band.** The `?` in the loop above is a
_placeholder_; the value of `age` is transferred to the server as a bound parameter, not
spliced into the text — so [SQL injection is structurally impossible][concepts-injection]
for a bound value. The stdlib's only static check is the **count**: before dispatch,
`driverArgs` compares the argument count to the statement's `NumInput()` and rejects a
mismatch ([`convert.go`][convert]): `"sql: expected %d arguments, got %d"`. Placeholder
_syntax_ is the driver's, not the stdlib's — MySQL/SQLite use `?`, PostgreSQL uses
`$1…$n`, SQL Server uses `@p1`, Oracle uses `:name`. `sqlx`'s `defaultBinds` map is a
compact census of the split ([`bind.go`][bindgo]):

```go
var defaultBinds = map[int][]string{
    DOLLAR:   {"postgres", "pgx", "pq-timeouts", "cloudsqlpostgres", "ql", "nrpostgres", "cockroach"},
    QUESTION: {"mysql", "sqlite3", "nrmysql", "nrsqlite3"},
    NAMED:    {"oci8", "ora", "goracle", "godror"},
    AT:       {"sqlserver", "azuresql"},
}
```

**String concatenation is the (unguarded) footgun.** Because the query is just a `string`,
nothing stops you writing `"... WHERE id = " + userId` — the language does not distinguish a
SQL string from any other, and there is no tagged-template or builder guard-rail as in
[Effect TS][concepts-injection] or `Kysely`. Injection safety is _convention plus
placeholders_, not a type-system property. This is the same trade-off `Dapper` and `JDBI`
make.

**The stdlib has minimal named-parameter support**, driver-permitting: `sql.Named("k", v)`
produces a `NamedArg`, and the driver's `NamedValue.Name`, _"if the Name is not empty…
should be used for the parameter identifier and not the ordinal position"_
([`driver/driver.go`][drivergo]). Most drivers only support positional binding, so named
args are rare in practice — which is the itch `sqlx` scratches on the client side.

**`sqlx` adds two convenience rewrites, both of which stay parameterized.**

`:name` **named parameters** are compiled _client-side_ into the driver's positional
placeholders. `compileNamedQuery` scans the SQL byte-by-byte, extracts each `:name` into an
ordered `names` list, and emits the driver-appropriate bindvar (`?`, `$1`, `@p1`, or a
passthrough `:name` for Oracle) ([`named.go`][namedgo]); `bindStruct`/`bindMap` then pull
the matching values off a struct (respecting the `db:"…"` tag) or a `map[string]interface{}`
in that order. `NamedExec`/`NamedQuery` tie it together ([`named.go`][namedgo]):

```go
// sqlx — a struct's fields fill :first_name/:last_name/:email as bound params
_, err = db.NamedExec(
    `INSERT INTO person (first_name, last_name, email)
     VALUES (:first_name, :last_name, :email)`,
    &Person{FirstName: "Jane", LastName: "Citizen", Email: "jane@example.com"})
```

The values still become bound parameters — the `:name` is a _rewrite of the placeholder
form_, not an interpolation of the value.

`sqlx.In` **expands a slice for an `IN (…)` clause** — the single most-loved convenience,
identical in spirit to `Dapper`'s list expansion ([`bind.go`][bindgo]):

> _"In expands slice values in args, returning the modified query string and a new arg_
> _list that can be executed by a database. The `query` should use the `?` bindVar. The_
> _return value uses the `?` bindVar."_

```go
// sqlx.In — one ? per slice element; each element is a bound parameter
query, args, err := sqlx.In("SELECT * FROM users WHERE level IN (?) AND active = ?",
    []int{4, 6, 7}, true)
// query: "... WHERE level IN (?, ?, ?) AND active = ?"; args: 4, 6, 7, true
query = db.Rebind(query) // ? → $1,$2,… for the target driver
```

`In` rewrites the text (one `?` per element) but each element is appended to the arg list
as a bound value; an **empty slice is a deliberate error** (`"empty slice passed to 'in'
query"`), not a silent `IN ()`. `Rebind` then translates the `?` placeholders to the
driver's dialect ([`bind.go`][bindgo]). Neither rewrite is a query builder — there is no
AST, no typed column references, no compile-time checking. `database/sql` + `sqlx` sit
firmly at the [raw-string end][concepts-models] of the query-construction axis, the opposite
pole from `jOOQ`/`Diesel` (typed builders) or the build-time-verified SQL of
`sqlc`/`sqlx` (Rust).

## Schema, migrations & code generation

**Neither package owns any schema — a defining, deliberate absence.** There is no
entity/model type that _is_ the schema ([code-first][concepts-schema]), no schema file
treated as truth ([schema-first][concepts-schema]), no [introspection→codegen][concepts-schema]
step, and no migration runner anywhere in `database/sql` or `sqlx`. You write `CREATE
TABLE`/`ALTER` as ordinary SQL and run it through `Exec` like any other statement; ordering
and version bookkeeping are entirely external (community tools such as `golang-migrate`,
`goose`, or `atlas`, none of them in scope here). `sqlx.LoadFile` is the closest gesture —
it `Exec`s the whole contents of a file in one call, with a candid `FIXME` that
multi-statement files _"[do] not really work"_ across all drivers ([`sqlx.go`][sqlxgo]).

This absence is exactly the ecosystem boundary the survey cares about. The Go tools that
_do_ own a schema build **on top of** `database/sql`: `sqlc` generates typed Go from your
`.sql` files and hand-written queries, `ent` and `GORM` add models/migrations/relations,
and each ultimately dials the same `driver.Driver` and leases from the same `*sql.DB` pool.
`database/sql` is the substrate; schema ownership is someone else's rung.

## Type mapping & result decoding

Decoding is where the two rungs visibly diverge: **positional `Scan` in the stdlib,
reflective struct hydration in `sqlx`.**

**The driver value universe is six types.** Everything crossing the driver boundary is a
`driver.Value`, defined as _"either nil… or an instance of one of these types"_
([`driver/driver.go`][drivergo]):

```go
//  int64
//  float64
//  bool
//  []byte
//  string
//  time.Time
```

The stdlib centralizes conversion so drivers stay small (a `doc.txt` goal: _"Make type
casting/conversions consistent between all drivers… most of the conversions are done in the
sql package"_). `Rows.Scan` converts each of those six into the Go types you point it at —
_"Scan also converts between string and numeric types, as long as no information would be
lost"_, and the design is _"paranoid about silent truncation"_: a `float64` of 300 scans
into a `uint16` but not a `uint8` ([`src/database/sql/sql.go`][sqlgo], [`doc.txt`][doctxt]).

**`Scan` is by position, into pointers.** `rows.Scan(&a, &b)` assigns column 0 to `a`,
column 1 to `b`; there is no column-name matching. The destination count must equal the
column count (`"sql: expected %d destination arguments in Scan, not %d"`), and `Scan`
without a preceding `Next` is an error ([`src/database/sql/sql.go`][sqlgo]). Custom decoding
plugs in through the `Scanner` interface — a `Scan(src any) error` method — the seam behind
the stdlib's own nullable types.

**Nullability is an explicit wrapper type, not a type-system fact.** A `NULL` column cannot
scan into a plain `string`/`int`; you scan into `sql.NullString`, `sql.NullInt64`,
`sql.NullTime`, … each a `{ Value; Valid bool }` pair implementing `Scanner`
([`src/database/sql/sql.go`][sqlgo]):

```go
type NullString struct {
    String string
    Valid  bool // Valid is true if String is not NULL
}
```

Nullability is thus a _runtime_ concern checked by `Valid`, never lifted into the static
type the way `sqlx` (Rust) or `Kysely` do — the same limitation as `Dapper`. The README
demonstrates the consequence: a nullable `city` column needs `City sql.NullString`, and
selecting `NULL` into a bare `string` field is a decode error at scan time
([`README.md`][sqlxreadme]).

**`sqlx` adds name-based struct hydration via reflection.** `Get` (one row) and `Select`
(many rows) scan into a struct or `[]struct` by matching column names to fields
([`sqlx.go`][sqlxgo]):

```go
// sqlx — struct/slice hydration; column names → struct fields via the `db` tag
type Person struct {
    FirstName string `db:"first_name"`
    LastName  string `db:"last_name"`
    Email     string
}
var people []Person
err := db.Select(&people, "SELECT * FROM person ORDER BY first_name ASC")
var jason Person
err = db.Get(&jason, "SELECT * FROM person WHERE first_name=$1", "Jason")
```

`Select`'s contract: _"executes a query using the provided Queryer, and StructScans each
row into dest, which must be a slice… The \*sql.Rows are closed automatically"_
([`sqlx.go`][sqlxgo]) — collapsing the entire `Next`/`Scan`/`Err`/`Close` loop into one
line. The mapping is done by the `reflectx` sub-package, _"extensions to the standard
reflect lib… [whose] main Mapper type allows for Go-compatible named attribute access,
including accessing embedded struct attributes"_ ([`reflectx/reflect.go`][reflectgo]). At
scan time `TraversalsByName` resolves each column to a field-index path, `fieldsByTraversal`
builds a slice of field pointers, and `rows.Scan` fills them ([`sqlx.go`][sqlxgo]) — so the
underlying decode is still the stdlib's positional `Scan`, driven by a name→field map.

Two sharp edges follow from reflection. A column with **no matching field** is an error
(`"missing destination name %s in %T"`) unless you opt into `db.Unsafe()`, which _"will
silently succeed to scan when columns in the SQL result have no fields in the destination
struct"_ ([`sqlx.go`][sqlxgo]). And `*sqlx.Rows.StructScan` **caches** the column↔field
traversal across rows, so _"it is not safe to run StructScan on the same Rows instance with
different struct types"_ ([`sqlx.go`][sqlxgo]). For ad-hoc shapes `sqlx` also offers
`MapScan` (row → `map[string]interface{}`) and `SliceScan` (row → `[]interface{}`). There
is no composable [codec][concepts-types] algebra of the kind `skunk`/`hasql` expose; a
custom mapping is a `Scanner`/`driver.Valuer` method pair, imperative and per-type.

## Effect model, transactions & error handling

This is the dimension the survey weights most, and `database/sql` sits at the
**blocking, `context`-aware, error-value** end — no future, no effect value, no typed error
channel.

**Blocking, with `context` as the async/cancellation seam.** Every operation has a
`…Context` form (`QueryContext`, `ExecContext`, `BeginTx`, `PrepareContext`) and a
convenience form that calls it with `context.Background()`. A call _blocks the calling
goroutine_ until the row arrives or the context is canceled; concurrency is achieved by
running many goroutines against the shared pool, not by returning a `Task`/`Future`. The
package doc warns of the one leak in the abstraction ([`src/database/sql/sql.go`][sqlgo]):
_"Drivers that do not support context cancellation will not return until after the query is
completed."_ There is no `IO`/`ConnectionIO`/`Effect` value to compose and interpret at the
edge — the contrast with `doobie`/`skunk`/`Quill`, and even with `Dapper`'s eager `Task`.

**Transactions: `Begin`/`Commit`/`Rollback`, one connection, no savepoints in the API.** A
`*sql.Tx` is _"owned exclusively until Commit or Rollback, at which point it's returned with
putConn"_ ([`src/database/sql/sql.go`][sqlgo]) — a single connection pinned for the
transaction's life. The idiom is `defer tx.Rollback()` after `Begin`, with a `Commit` on the
happy path (the rollback is a no-op once committed) ([`example_test.go`][example]):

```go
tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
if err != nil { log.Fatal(err) }
_, execErr := tx.ExecContext(ctx, "UPDATE users SET status = ? WHERE id = ?", "paid", id)
if execErr != nil {
    _ = tx.Rollback()
    log.Fatal(execErr)
}
if err := tx.Commit(); err != nil { log.Fatal(err) }
```

> [!IMPORTANT]
> **There is no savepoint API and no nested-transaction combinator in the stdlib — a
> deliberate finding.** The `driver.Tx` interface is exactly two methods, `Commit() error`
> and `Rollback() error` ([`driver/driver.go`][drivergo]); `database/sql` exposes nothing
> more. Nesting a `Begin` inside a `Tx` is not modeled — you thread the `*Tx` through and
> issue `SAVEPOINT` as raw SQL yourself if the engine supports it. This is the same shape as
> `Dapper`/`JDBI`: the transaction is an object you carry, not a scope the library manages,
> and there is no `withTransaction(effect)` combinator, retry-on-serialization-failure, or
> savepoint helper of the kind the [effect systems][concepts-effects] provide.

**Isolation levels are an enum on `TxOptions`.** `BeginTx` takes
`&sql.TxOptions{Isolation, ReadOnly}`; `IsolationLevel` ranges over `LevelDefault …
LevelSerializable … LevelLinearizable`, and _"If a driver does not support a given isolation
level an error may be returned"_ ([`src/database/sql/sql.go`][sqlgo]). Context binds the
transaction's lifetime: _"If the context is canceled, the sql package will roll back the
transaction"_, and a background `awaitDone` goroutine performs that rollback on cancellation.

**Errors are ordinary `error` values, checked by sentinel or `errors.Is`.** Go has no
exceptions; a failure is a returned `error`. The load-bearing sentinels are
`sql.ErrNoRows` (from `Row.Scan` when a `QueryRow` matched nothing — _"QueryRow returns a
placeholder [*Row] value that defers this error until a Scan"_), `sql.ErrTxDone` (any op on
a finished `Tx`), and the driver-facing `driver.ErrBadConn`, which signals the pool to
**transparently retry the operation on a fresh connection** — _"the [database/sql] package
should retry on a new connection"_ — but a driver must _"NOT"_ return it _"if there's a
possibility that the database server might have performed the operation"_, to avoid
double-executing ([`driver/driver.go`][drivergo]). A
constraint-violation or SQL error surfaces as the _driver's_ concrete error type (e.g.
`*pq.Error`, `*mysql.MySQLError`), inspected with `errors.As` — there is **no typed error
channel, no `Result`/`Either`, and no `isRetryable` flag**, the exception-free analogue of
the value-typed errors the [effect systems][concepts-effects] carry in their types.

`sqlx` changes none of this: its wrappers return the same `error` values (adding
`MustExec`/`MustBegin` panic-on-error twins for terse setup code, [`sqlx.go`][sqlxgo]), and
`Get` returns `sql.ErrNoRows` _"like row.Scan would"_ ([`sqlx.go`][sqlxgo]).

## Ecosystem & maturity

`database/sql` is one of the most-depended-upon packages in the entire Go ecosystem —
every Go program that touches a SQL database goes through it, and it has been API-stable
since Go 1.0 (2012) under the Go 1 compatibility promise. It ships in the standard library
under the **BSD-3-Clause** Go project license, with the driver contract published
separately so the third-party driver ecosystem can evolve independently: `github.com/lib/pq`
and `github.com/jackc/pgx` (Postgres), `github.com/go-sql-driver/mysql` (MySQL/MariaDB),
`github.com/mattn/go-sqlite3` and `modernc.org/sqlite` (SQLite),
`github.com/microsoft/go-mssqldb` (SQL Server), and dozens more, all discoverable via the
maintained [SQLDrivers wiki][sqldrivers]. Because the package generates no SQL, there is no
dialect layer — engine differences (placeholder syntax, `RETURNING`, `LIMIT` vs `TOP`) live
in the SQL _you_ write and in the driver.

`sqlx` (Jason Moiron, MIT, ≈2013) is the de-facto ergonomic layer above the stdlib —
widely deployed, and the model that the whole "raw SQL + struct scan" style in Go follows.
Its own dependency footprint is just the three reference drivers used in tests
(`go-sql-driver/mysql`, `lib/pq`, `mattn/go-sqlite3`, [`go.mod`][gomod]), and its
compatibility policy is conservative: _"Compatibility with the most recent two versions of
Go is a requirement"_ ([`README.md`][sqlxreadme]). The pinned review point is `41dac16`
(2024-05-30); the tagged release line is `v1.4.0` (web-attested). Everything higher in the
Go data-access stack — `sqlc`, `ent`, `GORM`, `bun`, `squirrel` — either targets
`database/sql` directly or interoperates with it, which is what makes this page the survey's
baseline.

---

## Strengths

- **The connection pool.** A share-anywhere, goroutine-safe `*sql.DB` with lazy opening,
  idle reuse, lifetime/idle eviction, and context-aware wait-at-cap — the single biggest
  reason to use `database/sql` over a bare driver, and something you'd otherwise hand-roll.
- **A stable, minimal driver contract.** `driver.Driver`/`Conn`/`Stmt`/`Rows` are tiny and
  frozen; the optional-interface probing (`QueryerContext`, `SessionResetter`, `Validator`,
  `NamedValueChecker`) lets drivers add fast paths without breaking the interface.
- **Injection-safe by default.** Bound parameters travel a separate channel from the query
  text; a value never becomes SQL. String concatenation is the only way to lose that, and
  it is an explicit choice.
- **Backend-agnostic.** Any engine with a registered driver, no dialect layer, no
  generated SQL — full control over the query, including CTEs, window functions, and vendor
  extensions.
- **`context` everywhere.** Uniform cancellation and timeout across pool waits, queries,
  and transactions.
- **`sqlx` removes the boilerplate cheaply.** `Get`/`Select` collapse the scan loop;
  `:name` and `In` remove manual placeholder bookkeeping — all as a strict superset, so
  adoption is incremental and reversible.

## Weaknesses

- **Verbose, error-prone at the stdlib level.** The `Query`→`Next`→`Scan`→`Err`→`Close`
  ritual (positional `Scan`, separate `rows.Err()`, `defer Close`) is exactly the ceremony
  higher rungs exist to remove.
- **No compile-time SQL or column checking.** SQL is opaque text; a typo'd column, wrong
  placeholder count, or type mismatch is a run-time error — the price of the
  [raw-string model][concepts-models].
- **Nullability is a wrapper type, not a static fact.** `sql.NullString` et al. push
  `NULL`-handling to run time (`Valid`); the type system never knows a column is nullable.
- **No schema, migrations, codegen, or change tracking.** Absent by design; the ecosystem's
  job.
- **No savepoints, nested transactions, retry, or effect value.** Transactions are a
  threaded object with two methods; there is no composable transaction combinator and no
  typed error channel — errors are `error` values you compare or `errors.As`.
- **Default pool settings are a trap.** Unlimited `maxOpen` and `maxIdle = 2` out of the box
  invite connection floods; both should be set explicitly.
- **`sqlx` mapping is reflective and stringly-typed.** Column↔field matching is by name/tag;
  a mismatch errors (or silently drops under `Unsafe()`), and cached `StructScan`
  traversals are unsafe to reuse across struct types.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                                   | Trade-off                                                                                                        |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Split `sql` (concrete types) from `sql/driver` (interfaces)**       | Stable user API; independent, competing third-party drivers; conversions centralized once   | The stdlib talks to no database; you must import a driver and know its placeholder dialect                       |
| **`*sql.DB` is a pool, not a connection**                             | Hides per-connection single-threadedness; share one handle across all goroutines            | Hidden lifecycle — a leaked `*Rows`/`*Tx` leaks a connection; default `maxOpen`/`maxIdle` invite floods          |
| **Raw SQL string + out-of-band placeholders**                         | Full SQL power, backend-agnostic, injection-safe by binding; no dialect/codegen to maintain | No compile-time column/type checking; string concatenation is an unguarded injection footgun                     |
| **Positional `Scan(&a, &b)` into pointers; six driver `Value` types** | Small, allocation-light, driver-simple; consistent conversions "paranoid about truncation"  | Verbose and order-fragile; column-name mapping and struct hydration are left to a layer above (`sqlx`)           |
| **Nullability via `sql.NullT` wrapper types**                         | Explicit, driver-agnostic `NULL` handling through the `Scanner` interface                   | `NULL`-ness is a run-time `Valid` bool, never a static type; `SELECT *` into bare fields breaks on `NULL`        |
| **No schema / migrations / codegen / change tracking**                | Stay a driver + pool; leave ORM concerns to the ecosystem (`sqlc`, `ent`, `GORM`)           | You hand-write all DDL/DML and updates; versioning is an external tool's job                                     |
| **`Tx` = one pinned connection, two methods; no savepoints**          | Minimal, matches the `driver.Tx` contract; predictable, no hidden machinery                 | No nested-transaction/savepoint/retry combinator; `SAVEPOINT` is raw SQL you thread through                      |
| **Blocking + `context`; errors are `error` values**                   | Feels like Go; goroutine-per-call scales on the pool; sentinels + `errors.Is`/`As`          | Not a future/effect value; no typed error channel or `isRetryable`; driver errors are concrete types             |
| **Optional driver interfaces probed by type assertion**               | Add fast paths (`QueryerContext`, `Validator`, `RowsColumnType*`) without breaking the API  | Capability is implicit and run-time — behaviour "just might start working" depending on the driver               |
| **`sqlx` as a strict superset (embed `*sql.DB`, add methods)**        | Incremental, reversible adoption; `Get`/`Select`/`:name`/`In` remove boilerplate cheaply    | Reflective, stringly-typed mapping; caches make `StructScan` type-unsafe to reuse; still no query builder or ORM |

---

## Sources

- [`golang/go` · `src/database/sql`][repo] · [`jmoiron/sqlx`][sqlxrepo] — the pinned trees
  (stdlib at the Go 1.27 dev tip, commit `01534385`; `sqlx` at `41dac16`)
- [`src/database/sql/sql.go`][sqlgo] — package doc ("generic interface… must be used in
  conjunction with a database driver"), `Register`, `Open`/`OpenDB` (lazy), `DB` pool doc,
  `SetMaxOpenConns`/`SetMaxIdleConns`/`SetConnMaxLifetime`/`SetConnMaxIdleTime`,
  `(*DB).conn`/`putConn` leasing, `Query`/`Exec`/`QueryRow`, `Rows.Scan`/`Next`/`Err`/`Close`,
  `Row.Scan`, `Tx` (Begin/Commit/Rollback), `IsolationLevel`/`TxOptions`, `Null*` types,
  `ErrNoRows`/`ErrTxDone`, `Scanner`
- [`database/sql/driver/driver.go`][drivergo] — the driver contract:
  `Driver`/`Connector`/`Conn`/`Stmt`/`Rows`/`Tx`/`Result`, the six-type `Value`,
  `NamedValue`, optional interfaces (`QueryerContext`, `SessionResetter`, `Validator`,
  `NamedValueChecker`, `RowsColumnType*`), `ErrBadConn`/`ErrSkip`
- [`database/sql/driver/types.go`][typesgo] — `Valuer` (`Value() (Value, error)`)
- [`doc.txt`][doctxt] — the goals memo (the "User Code → sql → sql/driver" picture,
  concurrency goal, "push complexity down", optional-interface fast paths)
- [`example_test.go`][example] — the canonical Query/Scan loop, `BeginTx`, `Conn` reservation
- [`sqlx` · `doc.go`][sqlxdoc] / [`README.md`][sqlxreadme] — "seamlessly wrap
  database/sql… none of the underlying methods are changed"; superset compatibility
- [`sqlx` · `sqlx.go`][sqlxgo] — `DB` embedding `*sql.DB`, `Get`/`Select`/`scanAll`,
  `StructScan`/`isScannable`/`fieldsByTraversal`, `Unsafe`, `Connect`, `MapScan`/`SliceScan`
- [`sqlx` · `named.go`][namedgo] — `compileNamedQuery` (`:name` → positional), `NamedExec`/`NamedQuery`
- [`sqlx` · `bind.go`][bindgo] — `defaultBinds`, `BindType`/`Rebind`, `In` slice expansion
- [`sqlx` · `reflectx/reflect.go`][reflectgo] — the reflection `Mapper` (named attribute
  access, embedded structs, `db` tag)
- [SQLDrivers wiki — the third-party driver list][sqldrivers]
- Shared vocabulary: [concepts & vocabulary][concepts] · [the abstraction ladder][concepts-ladder] ·
  [query construction models][concepts-models] · [statements, parameters & injection][concepts-injection] ·
  [connections, pools & sessions][concepts-pools] · [schema, migrations & codegen][concepts-schema] ·
  [type mapping & result decoding][concepts-types] · [effects, transactions & error handling][concepts-effects]

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
[repo]: https://github.com/golang/go/tree/master/src/database/sql
[docs]: https://pkg.go.dev/database/sql
[driverpkg]: https://pkg.go.dev/database/sql/driver
[sqlgo]: https://github.com/golang/go/blob/master/src/database/sql/sql.go
[drivergo]: https://github.com/golang/go/blob/master/src/database/sql/driver/driver.go
[typesgo]: https://github.com/golang/go/blob/master/src/database/sql/driver/types.go
[doctxt]: https://github.com/golang/go/blob/master/src/database/sql/doc.txt
[example]: https://github.com/golang/go/blob/master/src/database/sql/example_test.go
[convert]: https://github.com/golang/go/blob/master/src/database/sql/convert.go
[sqldrivers]: https://go.dev/wiki/SQLDrivers
[sqlxrepo]: https://github.com/jmoiron/sqlx
[sqlxdocs]: https://pkg.go.dev/github.com/jmoiron/sqlx
[sqlxguide]: http://jmoiron.github.io/sqlx/
[sqlxlicense]: https://github.com/jmoiron/sqlx/blob/master/LICENSE
[sqlxdoc]: https://github.com/jmoiron/sqlx/blob/master/doc.go
[sqlxreadme]: https://github.com/jmoiron/sqlx/blob/master/README.md
[sqlxgo]: https://github.com/jmoiron/sqlx/blob/master/sqlx.go
[namedgo]: https://github.com/jmoiron/sqlx/blob/master/named.go
[bindgo]: https://github.com/jmoiron/sqlx/blob/master/bind.go
[reflectgo]: https://github.com/jmoiron/sqlx/blob/master/reflectx/reflect.go
[gomod]: https://github.com/jmoiron/sqlx/blob/master/go.mod

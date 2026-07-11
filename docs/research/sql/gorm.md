# GORM (Go)

A reflection-based, struct-tag-driven **active-record ORM** for Go: models are plain structs annotated with `gorm:"..."` tags, queries are a chainable `*gorm.DB` builder that a runtime `Statement` + `clause` AST assembles, and a **callbacks** pipeline lowers each terminal call to SQL run synchronously over `database/sql`.

| Field              | Value                                                                                                                       |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Language           | Go (`module gorm.io/gorm`, `go 1.18`)                                                                                       |
| License            | MIT (`LICENSE`; "Copyright (c) 2013-present Jinzhu")                                                                        |
| Repository         | [go-gorm/gorm][repo]                                                                                                        |
| Documentation      | [gorm.io][docs] · [pkg.go.dev/gorm.io/gorm][pkgdev]                                                                         |
| Category           | [Full ORM][ladder] (active-record) — reflection-based, code-first; **no** identity map / implicit unit of work              |
| Abstraction level  | [Full-ORM rung][ladder], but stops short of change-tracking-on-flush — each finisher runs its own SQL                       |
| Query model        | [Chainable fluent builder][qcm] + struct tags + raw string with `?` params → a **runtime** `Statement`/`clause` AST         |
| Effect/async model | [Blocking][effects] (synchronous `database/sql`); errors accumulate on the `db.Error` field, never thrown, never a `Future` |
| Backends           | PostgreSQL, MySQL/MariaDB, SQLite, SQL Server (+ GaussDB) via `gorm.io/driver/*`                                            |
| First release      | ≈2013 (the original GORM; `LICENSE` copyright "2013-present"), `gorm.io/gorm` v2 rewrite 2020 (web-attested)                |
| Latest version     | `v1.31.x` — the pinned tree `1d6ce99` (2026-06-22) carries the `v1.31.2` tag                                                |

> [!NOTE]
> GORM is this survey's data point for the **mainstream reflection-driven active-record
> ORM** — the Go counterpart to `ActiveRecord` (Ruby) and Django ORM. It occupies the
> [full-ORM rung][ladder]: you declare structs, mutate them, and call
> `db.Create(&user)` / `db.Save(&user)`. But it is the _low-ceremony_ end of that rung —
> queries are runtime strings and reflected structs, not compile-time-checked
> ([contrast `sqlc`, `ent`, and Rust's `Diesel`][qcm]); effects are **blocking**, not an
> `IO`/`Effect` value; and there is no [identity map or unit of work][orm]. Terms below
> link to [concepts][concepts].

---

## Overview

### What it solves

GORM maps Go structs to relational tables and back, so an application manipulates typed
Go values instead of hand-writing SQL and scanning rows by index. The package docstring
states the ambition plainly ([`gorm.go`][gorm]):

> _"Package gorm is a full-featured, developer-friendly ORM for Golang."_

and the `README` opens with the tagline the project is known by ([`README.md`][readme]):

> _"The fantastic ORM library for Golang, aims to be developer friendly."_

It sits at the [full-ORM active-record rung][ladder]: a model both carries data and is
the thing you persist. `db.Create(&user)` inserts a row and writes the generated primary
key back into `user`; `db.First(&user, 10)` loads it; `db.Save(&user)` /
`db.Model(&user).Update("name", "jinzhu")` write mutations. The `README`'s feature list
is a fair census of the surface ([`README.md`][readme]):

> _"Full-Featured ORM / Associations (Has One, Has Many, Belongs To, Many To Many,
> Polymorphism, Single-table inheritance) / Hooks (Before/After
> Create/Save/Update/Delete/Find) / Eager loading with `Preload`, `Joins` / Transactions,
> Nested Transactions, Save Point, RollbackTo to Saved Point / ... / Auto Migrations /
> ... / Developer Friendly"_

### Design philosophy

GORM is **code-first and reflection-driven**. A model is an ordinary Go struct; its
schema (table name, columns, keys, indexes, relations) is _reflected_ at runtime from the
struct's fields and `gorm:"..."` struct tags — there is no schema file and no code
generation step in the core. The base model GORM ships to embed is itself just a struct
([`model.go`][model]):

```go
// gorm: model.go
type Model struct {
    ID        uint `gorm:"primarykey"`
    CreatedAt time.Time
    UpdatedAt time.Time
    DeletedAt DeletedAt `gorm:"index"`
}
```

Field parsing reads the tag straight off the reflected struct field
([`schema/field.go`][field]):

```go
// gorm: schema/field.go — ParseField
tagSetting = ParseTagSetting(fieldStruct.Tag.Get("gorm"), ";")
// …
PrimaryKey:    utils.CheckTruth(tagSetting["PRIMARYKEY"], tagSetting["PRIMARY_KEY"]),
AutoIncrement: utils.CheckTruth(tagSetting["AUTOINCREMENT"]),
```

Everything downstream — the SQL builder, the migrator, row hydration — works off the
resulting `schema.Schema` / `schema.Field` reflection metadata, cached per model type. The
consequence, developed throughout this page, is that GORM's power and its weaknesses share
one root: **the query and the schema are runtime values built by reflection and string
assembly, not types the Go compiler checks.**

## Connection, pooling & resource lifetime

You obtain a `*gorm.DB` by handing `gorm.Open` a `Dialector` (a driver adapter) and
options ([`gorm.go`][gorm]):

```go
db, err := gorm.Open(sqlite.Open("test.db"), &gorm.Config{})
```

The returned `*DB` embeds a `*Config`, an `Error`, a `RowsAffected`, and a `*Statement`
([`gorm.go`][gorm]). Underneath, GORM does **not** implement its own driver or pool — it
drives Go's standard `database/sql`. The connection abstraction is `ConnPool`, whose
method set is exactly the `database/sql` context API ([`interfaces.go`][interfaces]):

```go
// gorm: interfaces.go
type ConnPool interface {
    PrepareContext(ctx context.Context, query string) (*sql.Stmt, error)
    ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
    QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row
}
```

`db.DB()` returns the underlying `*sql.DB` ([`gorm.go`][gorm]) — and a `*sql.DB` _is_ a
[connection pool][pool] with its own sizing (`SetMaxOpenConns`, `SetMaxIdleConns`,
`SetConnMaxLifetime`), managed by the standard library, not GORM. Resource lifetime is
therefore the `database/sql` model: the pool leases a connection per statement and returns
it when the call completes; there is no [scoped acquire/release effect][pool]. `Open`
pings the pool on connect unless `DisableAutomaticPing` is set ([`gorm.go`][gorm]).

Two lifetime knobs sit above the pool. `db.Session(&Session{...})` forks a configured,
cheap clone of the `*DB` for a scope (context, logger, batch size, prepared-statement
mode) ([`gorm.go`][gorm]); `db.Connection(func(tx *gorm.DB) error {...})` leases a single
`*sql.Conn` for a block and returns it to the pool afterward ([`finisher_api.go`][fin]).
`PrepareStmt` mode wraps the pool in a `PreparedStmtDB` that caches prepared statements
with an LRU (`PrepareStmtMaxSize` / `PrepareStmtTTL`) ([`gorm.go`][gorm]) — plan reuse plus
the safety of out-of-band parameters (below).

## Query construction & injection safety

This is GORM's centre of gravity, and the section the survey weighs most for safety.

**The query is a chainable `*gorm.DB`.** Chain methods (`Where`, `Select`, `Joins`,
`Order`, `Group`, `Having`, `Limit`, `Offset`, `Preload`, `Distinct`, …) live in
[`chainable_api.go`][chain]; terminal "finisher" methods (`Create`, `First`, `Find`,
`Save`, `Update`, `Delete`, `Count`, `Scan`, …) live in [`finisher_api.go`][fin]. Each
chain method clones the statement (`getInstance`), mutates `tx.Statement`, and returns the
`*DB`, so calls thread left to right — the canonical example from the `Where` docstring
([`chainable_api.go`][chain]):

```go
// gorm: chainable_api.go — Where docstring
db.Where("name = ?", "jinzhu").First(&user)
db.Where(&User{Name: "jinzhu", Age: 20}).First(&user)
db.Where("name = ?", "jinzhu").Where("age <> ?", "20").First(&user)
```

`Where` funnels its argument through `Statement.BuildCondition`, which returns
`[]clause.Expression` and adds a `clause.Where` clause ([`chainable_api.go`][chain]):

```go
// gorm: chainable_api.go
func (db *DB) Where(query interface{}, args ...interface{}) (tx *DB) {
    tx = db.getInstance()
    if conds := tx.Statement.BuildCondition(query, args...); len(conds) > 0 {
        tx.Statement.AddClause(clause.Where{Exprs: conds})
    }
    return
}
```

**A `Statement` accumulates clauses and bind vars; a `clause` AST renders them.** The
`Statement` holds `Clauses map[string]clause.Clause`, an `SQL strings.Builder`, and
`Vars []interface{}` ([`statement.go`][stmt]); the `clause` package is the query AST —
`clause.Where`, `clause.Expr`, and the typed predicate nodes `clause.Eq` / `Neq` / `Gt` /
`IN` / `Like` ([`clause/expression.go`][expr]). Nothing touches the database while the
chain is built; the finisher hands the assembled statement to the callback pipeline
(below) which calls `Statement.Build(clauses...)` to emit SQL in a fixed clause order.

**Values enter only as bound parameters — the `?` placeholder is the safety seam.** A
`clause.Expr{SQL, Vars}` wraps a raw SQL fragment and its arguments; its `Build` walks the
fragment byte-by-byte, and every `?` consumes one argument, routed through
`builder.AddVar` rather than spliced into the text ([`clause/expression.go`][expr]):

```go
// gorm: clause/expression.go — Expr.Build (abridged)
for _, v := range []byte(expr.SQL) {
    if v == '?' && len(expr.Vars) > idx {
        if afterParenthesis || expr.WithoutParentheses {
            processValue(builder, expr.Vars[idx])
        } else {
            builder.AddVar(builder, expr.Vars[idx])
        }
        idx++
    } else {
        // … copy the byte verbatim …
        builder.WriteByte(v)
    }
}
```

`AddVar` is where a value becomes a parameter: it appends the value to `stmt.Vars` and
writes the driver's placeholder via the dialector's `BindVarTo` (e.g. `?` for
MySQL/SQLite, `$1…$n` for Postgres) — the SQL text and the data leave on **separate
channels** ([`statement.go`][stmt]):

```go
// gorm: statement.go — AddVar, default arm
default:
    stmt.Vars = append(stmt.Vars, v)
    stmt.DB.Dialector.BindVarTo(writer, stmt, v)
```

Because the argument is never rendered into the SQL string, it reaches the server as a
[prepared-statement parameter][inject] and cannot change the query's structure —
[SQL injection][inject] for _values_ is structurally impossible, the same guarantee the
lower-level libraries in this survey provide. The typed predicate nodes preserve it:
`clause.Eq{Column, Value}.Build` writes the quoted column then `builder.AddVar(builder, eq.Value)`,
and even lowers `eq.Value == nil` to `IS NULL` ([`clause/expression.go`][expr]).

**`BuildCondition` is polymorphic**, which is GORM's ergonomic hook and a footgun
([`statement.go`][stmt]): a string with `?` args becomes a `clause.Expr`; a string with
`@name` args becomes a `clause.NamedExpr`; a struct becomes one `clause.Eq` per **non-zero**
field (so `Where(&User{Age: 0})` silently drops `Age` — the classic zero-value trap); a
`map[string]interface{}` becomes an `Eq`/`IN` per key (maps include zero values). A bare
string or number is treated as a primary-key lookup.

**The escape hatches stay parameterized — but identifiers do not.** `db.Raw(sql, values...)`
and `db.Exec(sql, values...)` route through the same `clause.Expr`/`NamedExpr` machinery,
so their `?`/`@name` arguments are bound, not spliced ([`finisher_api.go`][fin],
[`chainable_api.go`][chain]); `gorm.Expr(sql, args...)` injects a raw SQL fragment as a
value ([`gorm.go`][gorm]). The genuine danger is **identifiers and raw fragments**, which
_cannot_ be bind parameters: `Order`, `Group`, and raw `Select` column strings are marked
`Raw: true` and substituted textually ([`chainable_api.go`][chain]), so passing
user-controlled text as a column/order expression re-opens injection. GORM's own logger
underlines that materializing SQL with values inlined is unsafe ([`logger/sql.go`][loggersql]):

> _"ExplainSQL generate SQL string with given parameters, the generated SQL is expected to
> be used in logger, execute it might introduce a SQL injection vulnerability"_

The upstream guidance (the gorm.io security page, web) is the standard one: keep user data
in `?`/`@name` parameters and never string-concatenate it into a condition, table, or
column name.

## Schema, migrations & code generation

GORM is **code-first**: the annotated structs _are_ the schema, reflected at runtime (see
[Design philosophy](#design-philosophy)). A representative model shows the tag language
carrying columns, keys, and relations at once ([`utils/tests/models.go`][models]):

```go
// gorm: utils/tests/models.go
type User struct {
    gorm.Model
    Name      string
    Age       uint
    Toys      []Toy      `gorm:"polymorphic:Owner"`
    CompanyID *int
    Company   Company
    Languages []Language `gorm:"many2many:UserSpeak;"`
    Team      []User     `gorm:"foreignkey:ManagerID"`
}
```

Tag settings drive column type, size, nullability, defaults, uniqueness, indexes, and the
relationship graph (`foreignKey`, `references`, `many2many`, `polymorphic`) — all parsed
into `schema.Field.TagSettings` ([`schema/field.go`][field]).

**`AutoMigrate` reflects structs into `CREATE`/`ALTER`** ([`migrator/migrator.go`][mig]).
For each model it creates the table if absent, else reconciles columns:

```go
// gorm: migrator/migrator.go — AutoMigrate (abridged)
if foundColumn == nil {
    // not found, add column
    if err = execTx.Migrator().AddColumn(value, dbName); err != nil {
        return err
    }
} else {
    // found, smartly migrate
    field := stmt.Schema.FieldsByDBName[dbName]
    if err = execTx.Migrator().MigrateColumn(value, field, foundColumn); err != nil {
        return err
    }
}
```

It then adds any missing constraints and indexes. The critical property — and a finding —
is that **`AutoMigrate` is additive only**: it adds and widens columns/indexes/constraints
but has no branch that _drops_ a column, index, or table that has disappeared from the
struct. GORM's docs state this directly ("AutoMigrate will … but WON'T delete unused
columns to protect your data"). So it is a convenience for keeping a dev/prod schema
roughly in step, not a full migration system: there is **no versioned migration runner, no
bookkeeping table, and no down/rollback path** in the core (contrast `SeaORM`'s
`sea-orm-migration`, `Ecto`'s migrations, `Diesel`'s SQL migration files). Production
projects are steered to a dedicated migration tool for destructive or ordered changes.

**Code generation is out of core.** The core reflects at runtime and generates nothing;
the sibling project `gorm.io/gen` (Gen) does DAO / type-safe query codegen from models or a
live database — GORM's answer to the codegen'd, type-checked Go alternatives `sqlc` and
`ent`. A newer, in-core **generics** surface, `gorm.G[T]`, wraps the same reflection engine
in Go 1.18 type parameters ([`generics.go`][gen]) so `gorm.G[User](db).Where(...).Find(ctx)`
returns a typed `[]User` and takes an explicit `context.Context` — but it type-checks the
_result shape_, not the SQL: a wrong column name or a malformed condition string is still a
runtime error.

## Type mapping & result decoding

**Row hydration is reflection.** After a query runs, `gorm.Scan` / `ScanRows` reflects the
destination (`*struct`, `*[]struct`, `*map`, or a primitive slice for `Pluck`) and sets
fields by matching result columns to `schema.Field`s ([`finisher_api.go`][fin],
[`scan.go`][scan]). Each `schema.Field` carries closures — `ValueOf`, `ReflectValueOf`,
`Set` — that read and write the field through reflection ([`schema/field.go`][field]),
plus an optional `Serializer` for custom on-the-wire encodings (JSON, gob, unixtime).

**Codecs bottom out in `database/sql`.** A Go value binds through the standard
`driver.Valuer` and scans back through `sql.Scanner`; GORM adds its own `Valuer`
(`GormValue(ctx, db) clause.Expr`) for values that must render as a SQL expression
([`interfaces.go`][interfaces]). Column SQL types come from the dialector's `DataTypeOf`
plus `GormDBDataType` overrides on a type ([`migrator/migrator.go`][mig]).

**Nullability** is expressed the Go way: a pointer field (`*int`, `*time.Time`) or a
`sql.Null*` wrapper is nullable; a plain value is not. GORM's soft-delete column is exactly
such a wrapper — `type DeletedAt sql.NullTime` with `Scan`/`Value`/JSON methods
([`soft_delete.go`][soft]) — and a `DeletedAt` field silently adds
`WHERE deleted_at IS NULL` to every query and turns `Delete` into an `UPDATE … SET deleted_at`
(a global scope you opt out of with `db.Unscoped()`). `MapColumns` remaps result column
names onto struct fields for ad-hoc projections ([`chainable_api.go`][chain]).

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and where GORM's choices are the
most classical.

**Blocking, synchronous, on `database/sql`.** Every finisher runs to completion on the
calling goroutine and returns a `*DB`; there is no `Future`, `Task`, or `IO`/`Effect`
value ([blocking][effects] in the survey's taxonomy). Concurrency is Go's own — you run
queries in goroutines — not a composed effect.

**Errors are a mutable field, not a return value or an exception.** Go has no exceptions,
and GORM does not follow the idiomatic `(T, error)` return either: it accumulates errors on
`db.Error`, chaining multiple with `%w` ([`gorm.go`][gorm]):

```go
// gorm: gorm.go — AddError
if db.Error == nil {
    db.Error = err
} else {
    db.Error = fmt.Errorf("%v; %w", db.Error, err)
}
```

so the idiom is `if err := db.Where(...).First(&u).Error; err != nil { … }` — you inspect
the field after the chain, and `RowsAffected` beside it. The failure vocabulary is a set of
package-level sentinels ([`errors.go`][errors]): `ErrRecordNotFound`, `ErrDuplicatedKey`,
`ErrForeignKeyViolated`, `ErrCheckConstraintViolated`, `ErrInvalidTransaction`,
`ErrMissingWhereClause`, `ErrPrimaryKeyRequired`, … Mapping a raw driver error onto the
portable `ErrDuplicatedKey`/`ErrForeignKeyViolated` sentinels is **opt-in**, gated on the
`TranslateError` config and a dialector that implements `ErrorTranslator`
([`gorm.go`][gorm], [`interfaces.go`][interfaces]). This is the survey-relevant contrast:
GORM has a _coarse, mutable, exception-free_ error posture — neither the thrown
`SQLException` of the JDBC world nor the encoded per-query error channel of the functional
mappers, and no `isRetryable` modelling.

**The callback pipeline is the executor and the plugin seam.** A finisher does not build
SQL itself; it invokes a named, ordered chain of callbacks. The six processors are set up
at `Open` ([`callbacks.go`][cb]), and the defaults register the pipeline stages
([`callbacks/callbacks.go`][cbreg]):

```go
// gorm: callbacks/callbacks.go — the create pipeline
createCallback.Match(enableTransaction).Register("gorm:begin_transaction", BeginTransaction)
createCallback.Register("gorm:before_create", BeforeCreate)
createCallback.Register("gorm:save_before_associations", SaveBeforeAssociations(true))
createCallback.Register("gorm:create", Create(config))
createCallback.Register("gorm:save_after_associations", SaveAfterAssociations(true))
createCallback.Register("gorm:after_create", AfterCreate)
createCallback.Match(enableTransaction).Register("gorm:commit_or_rollback_transaction", CommitOrRollbackTransaction)
```

`db.Create(&user)` is literally `tx.callbacks.Create().Execute(tx)` ([`finisher_api.go`][fin]);
`Query`/`Update`/`Delete`/`Row`/`Raw` each have their own ordered processor. Plugins and
hooks hang off this seam — `db.Callback().Create().Before("gorm:create").Register("my:audit", fn)`
inserts a stage, with `Before`/`After`/`Remove`/`Replace` and a topological sort resolving
order ([`callbacks.go`][cb]). This is how the `README`'s "flexible plugin API" (DB
resolver, Prometheus, tracing) is built.

**Active-record persistence — mutation, but no unit of work.** GORM mutates the struct you
hand it. After an `INSERT`, the create callback reads `result.LastInsertId()` and writes
the auto-increment PK back into the struct's primary-key field ([`callbacks/create.go`][cbcreate]);
`Save` inserts when the PK is blank and updates otherwise ([`finisher_api.go`][fin]):

```go
// gorm: finisher_api.go — Save (struct arm, abridged)
for _, pf := range tx.Statement.Schema.PrimaryFields {
    if _, isZero := pf.ValueOf(tx.Statement.Context, reflectValue); isZero {
        return tx.callbacks.Create().Execute(tx)   // blank PK → INSERT
    }
}
// … otherwise fall through to UPDATE
```

Per-record lifecycle **hooks** fire from inside the callbacks if the model implements the
interface — `BeforeCreate`, `AfterCreate`, `BeforeSave`, `BeforeUpdate`, `AfterUpdate`,
`BeforeDelete`, `AfterDelete`, `AfterFind` ([`callbacks/interfaces.go`][cbif]) — each
`func(*gorm.DB) error`. But this is active-record persistence _without_ Fowler's heavier
machinery, and that absence is a finding: there is **no [identity map][orm]** (two
`db.First(&a)` / `db.First(&b)` of the same row yield two independent structs), **no
session-level [change tracking][orm]**, and **no [unit of work][orm]** that batches a diff
and flushes it. `Statement.Changed` computes changed columns _per update call_ against the
passed value ([`statement.go`][stmt]), not against a tracked snapshot; every finisher
issues its own SQL immediately. Batching multiple entities is manual — you write them in a
loop inside a transaction, or use `FullSaveAssociations` / association mode.

**Transactions: closure or manual, nested via `SAVEPOINT`.** The block form commits on a
nil return and rolls back on error or panic ([`finisher_api.go`][fin]):

```go
// gorm: finisher_api.go — Transaction (block form)
db.Transaction(func(tx *gorm.DB) error {
    if err := tx.Create(&user).Error; err != nil {
        return err   // rolls back
    }
    return nil       // commits
})
```

Manual control is `db.Begin(opts...)` / `Commit()` / `Rollback()`, and **nesting is real**:
calling `Transaction` (or `Begin`) inside an open transaction opens a savepoint rather than
a new connection ([`finisher_api.go`][fin]):

```go
// gorm: finisher_api.go — Transaction, nested arm
spID := new(maphash.Hash).Sum64()
err = db.SavePoint(fmt.Sprintf("sp%d", spID)).Error
// … defer RollbackTo(sp…) on panic or error …
```

`SavePoint(name)` / `RollbackTo(name)` are exposed directly and dispatch to the dialector's
`SavePointerDialectorInterface` ([`finisher_api.go`][fin], [`interfaces.go`][interfaces]);
`DisableNestedTransaction` turns nesting off. Isolation level and read-only mode ride on the
standard `*sql.TxOptions` passed to `Begin`. Notably, GORM **wraps every single write in a
transaction by default** for integrity, an overhead you opt out of ([`gorm.go`][gorm]):

> _"GORM perform single create, update, delete operations in transactions by default to
> ensure database data integrity. You can disable it by setting `SkipDefaultTransaction`
> to true"_

**Associations and eager loading — the N+1 story.** GORM loads relations two ways.
`Joins("Account")` folds a belongs-to/has-one into the parent query as a SQL `JOIN`
([`chainable_api.go`][chain]). `Preload("Orders", conds...)` is **explicit eager loading by
separate query** ([`chainable_api.go`][chain]): after the parent rows land, the preload
callback collects the parents' keys and issues **one** `WHERE … IN (…)` query per relation,
then stitches the children back by an in-memory identity map ([`callbacks/preload.go`][pre]).
So `Preload` mitigates the [N+1 problem][nplusone] — N parents cost one extra round-trip
per relation hop, not N — but it is a second query, not a join, and it is **opt-in**:
forget the `Preload`/`Joins` and accessing a relation simply yields the zero value, since
GORM has no lazy-loading proxy. Explicit loading is the price and the safeguard.

## Ecosystem & maturity

GORM is the most widely used Go ORM. It is MIT-licensed and authored by **Jinzhu (Jinzhu
Zhang)** ([`LICENSE`][repo]); the current module `gorm.io/gorm` is the **v2** rewrite
(2020) of the original 2013 library, targeting `go 1.18`. Database support is a family of
out-of-tree dialector drivers — the test module pins
`gorm.io/driver/{mysql,postgres,sqlite,sqlserver,gaussdb}` ([`tests/go.mod`][testsmod]) —
plus community drivers (ClickHouse, TiDB, …). The surrounding ecosystem is substantial:
`gorm.io/gen` (query/DAO codegen), and first-party plugins under `gorm.io/plugin/*` —
`dbresolver` (read/write splitting, multiple databases), `prometheus`, and OpenTelemetry
tracing — all built on the callback seam. The `README` positions it as
"Full-Featured ORM … Every feature comes with tests" ([`README.md`][readme]), and its
GitHub adoption (tens of thousands of stars, a very large dependent graph) is
web-verifiable. The pinned tree `1d6ce99` (2026-06-22) carries the `v1.31.2` tag.

## Strengths

- **Low-friction developer experience.** Plain structs + `gorm:"..."` tags, a chainable
  API that reads like the query, and active-record finishers (`Create`/`First`/`Save`)
  that mutate your struct — minimal boilerplate to first query ([`README.md`][readme]).
- **Injection-safe for values by default.** `?`/`@name` arguments always become bound
  parameters via `AddVar` + the dialector's `BindVarTo`; SQL and data travel on separate
  channels ([`clause/expression.go`][expr], [`statement.go`][stmt]).
- **One reflection engine, many databases.** The same models and queries render to
  Postgres, MySQL, SQLite, or SQL Server through pluggable dialectors ([`interfaces.go`][interfaces]).
- **Rich relational features.** Associations (has-one/many, belongs-to, many-to-many,
  polymorphic), `Preload`/`Joins` eager loading with N+1 avoidance, and per-record hooks
  ([`callbacks/preload.go`][pre], [`callbacks/interfaces.go`][cbif]).
- **Extensible callback pipeline.** Create/query/update/delete are ordered, named
  callbacks you can insert into, replace, or remove — the basis for the plugin ecosystem
  ([`callbacks.go`][cb]).
- **Real nested transactions and savepoints**, plus a default transaction wrapper for
  single writes ([`finisher_api.go`][fin]).
- **`AutoMigrate`** keeps a schema roughly in step with structs without writing DDL for the
  additive common case ([`migrator/migrator.go`][mig]).

## Weaknesses

- **No compile-time query checking.** Conditions, column names, and raw SQL are runtime
  strings and reflected structs; a typo or shape mismatch is a runtime `db.Error`, not a
  build error — the opposite of `sqlc`/`ent`/`Diesel` ([`statement.go`][stmt]).
- **`interface{}`-heavy, polymorphic API.** `Where`/`BuildCondition` accept string, struct,
  map, or `*DB`; the struct arm silently drops zero-value fields (the zero-value trap), and
  identifiers passed to `Order`/`Group`/raw `Select` are substituted textually — an
  injection surface if fed user input ([`statement.go`][stmt], [`chainable_api.go`][chain]).
- **No identity map / unit of work / change tracking on a session.** Persistence is
  per-finisher SQL; multi-entity batching and minimal-diff flush are manual (a finding vs.
  `Hibernate`/EF Core) ([`finisher_api.go`][fin]).
- **Errors on a mutable field, coarse sentinels.** `db.Error` accumulates; driver-error
  classification is opt-in (`TranslateError`), and there is no per-query typed error
  channel or retryability model ([`gorm.go`][gorm], [`errors.go`][errors]).
- **`AutoMigrate` is additive-only.** It never drops columns/indexes/tables, so it cannot
  express a destructive or ordered migration; there is no versioned runner or down path in
  core ([`migrator/migrator.go`][mig]).
- **Reflection cost and "magic".** Behaviour flows through cached reflection + a callback
  graph; understanding a surprising query or a soft-delete scope means tracing the pipeline,
  not reading a call.
- **Blocking only.** No effect value, no async surface, no typed error/effect the compiler
  tracks — the [effect-first][effects] guarantees this survey chases are absent.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                   | Trade-off                                                                                                                      |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Reflect structs + `gorm:"..."` tags into schema at runtime       | Code-first, zero boilerplate, no build step; one model drives queries, migration, hydration | No compile-time schema/query checking; reflection cost; behaviour is runtime "magic" ([`schema/field.go`][field])              |
| Chainable `*gorm.DB` over a `Statement` + `clause` AST           | Reads like SQL; conditions compose and branch from runtime input                            | The chain is untyped `interface{}`; mistakes surface at runtime, not compile time ([`chainable_api.go`][chain])                |
| `?`/`@name` args always bound via `AddVar` / `BindVarTo`         | [Injection][inject]-safe for values by construction; multi-dialect placeholders             | Identifiers/raw fragments (`Order`, `Group`, raw `Select`) are textual — a residual injection surface ([`statement.go`][stmt]) |
| Active-record finishers mutate the struct (fill PK, `Save`)      | Familiar, low-ceremony persistence; the object is the unit of work                          | No [identity map][orm]/[unit of work][orm]; each call runs its own SQL; batching is manual ([`finisher_api.go`][fin])          |
| Errors accumulate on `db.Error`, exception-free                  | Fits Go's no-exceptions model; chain then check once                                        | Coarse, mutable; opt-in translation; no per-query typed error or retryability ([`gorm.go`][gorm], [`errors.go`][errors])       |
| Blocking on `database/sql`, no effect/async value                | Simple, idiomatic Go; standard pool, prepared statements, drivers for free                  | No composed effect, no typed error/effect channel; concurrency is manual goroutines ([`interfaces.go`][interfaces])            |
| Ordered, named **callback** pipeline as executor + plugin seam   | Uniform create/query/update/delete; hooks and plugins insert cleanly                        | Indirection: the SQL for an operation is spread across callback stages, harder to trace ([`callbacks.go`][cb])                 |
| `Preload` = explicit eager loading via separate `WHERE IN` query | Avoids [N+1][nplusone]; predictable, no lazy-proxy surprises                                | Opt-in — a forgotten `Preload` yields zero relations; a second round-trip, not a join ([`callbacks/preload.go`][pre])          |
| `AutoMigrate` additive-only                                      | Safe by default: never destroys data                                                        | Cannot drop/rename or order changes; no versioned migration runner in core ([`migrator/migrator.go`][mig])                     |

---

## Sources

- [go-gorm/gorm — GitHub repository][repo] · [gorm.io docs][docs] · [pkg.go.dev/gorm.io/gorm][pkgdev]
- [`README.md` — "The fantastic ORM library for Golang", feature list, Developer Friendly][readme]
- [`gorm.go` — `DB` / `Config` / `Session` / `Open`; `AddError`; `Expr`; `ToSQL`; default-transaction comment; package docstring][gorm]
- [`model.go` — `gorm.Model` base struct (ID/CreatedAt/UpdatedAt/DeletedAt with tags)][model]
- [`chainable_api.go` — `Where`/`Select`/`Joins`/`Order`/`Preload`/`Raw`: the chainable builder][chain]
- [`finisher_api.go` — `Create`/`First`/`Find`/`Save`/`Update`/`Delete`; `Transaction`; `Begin`/`Commit`/`SavePoint`][fin]
- [`statement.go` — `Statement` (Clauses/Vars/SQL); `BuildCondition` polymorphism; `AddVar` bind-param seam; `Changed`][stmt]
- [`callbacks.go` — the callback manager: processors, `Register`/`Before`/`After`/`Replace`, topological sort][cb]
- [`callbacks/callbacks.go` — `RegisterDefaultCallbacks`: the create/query/update/delete pipelines and clause order][cbreg]
- [`callbacks/create.go` — the `gorm:create` callback; `LastInsertId` → writes PK back into the struct][cbcreate]
- [`callbacks/preload.go` — `Preload` issues a separate `WHERE … IN (…)` query per relation (N+1 mitigation)][pre]
- [`callbacks/interfaces.go` — `BeforeCreate`/`AfterCreate`/`BeforeSave`/… lifecycle hook interfaces][cbif]
- [`clause/clause.go` + `clause/where.go` + `clause/expression.go` — the SQL clause AST: `Where`, `Expr`, `Eq`/`IN`/`Like`, `?` handling][expr]
- [`interfaces.go` — `Dialector`, `ConnPool` (= `database/sql` API), `Plugin`, `TxCommitter`, `ErrorTranslator`, `SavePointerDialectorInterface`][interfaces]
- [`errors.go` — sentinel errors (`ErrRecordNotFound`, `ErrDuplicatedKey`, `ErrForeignKeyViolated`, …)][errors]
- [`schema/field.go` + `schema/schema.go` — struct-tag reflection: `ParseField`, `TagSettings`, `Field`/`Schema` metadata][field]
- [`migrator/migrator.go` — `AutoMigrate`: create/add-column/smart-migrate; additive-only (no drop path)][mig]
- [`soft_delete.go` — `DeletedAt` = `sql.NullTime`; the soft-delete global scope][soft]
- [`generics.go` — `gorm.G[T]` type-parameterized surface over the reflection core][gen]
- [`logger/sql.go` — `ExplainSQL` injection-risk warning for value-inlined SQL][loggersql]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [injection][inject] · [schema/migrations][schema] · [ORM patterns][orm] · [N+1][nplusone] · [effects & transactions][effects] · [pools][pool])
- Related deep-dives in this survey: `SeaORM` · `ent` · `sqlc` · `Diesel` · `ActiveRecord` · `Ecto`

<!-- References -->

[repo]: https://github.com/go-gorm/gorm
[docs]: https://gorm.io
[pkgdev]: https://pkg.go.dev/gorm.io/gorm
[readme]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/README.md
[gorm]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/gorm.go
[model]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/model.go
[chain]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/chainable_api.go
[fin]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/finisher_api.go
[stmt]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/statement.go
[scan]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/scan.go
[cb]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/callbacks.go
[cbreg]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/callbacks/callbacks.go
[cbcreate]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/callbacks/create.go
[pre]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/callbacks/preload.go
[cbif]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/callbacks/interfaces.go
[expr]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/clause/expression.go
[interfaces]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/interfaces.go
[errors]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/errors.go
[field]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/schema/field.go
[mig]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/migrator/migrator.go
[soft]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/soft_delete.go
[gen]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/generics.go
[loggersql]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/logger/sql.go
[models]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/utils/tests/models.go
[testsmod]: https://github.com/go-gorm/gorm/blob/1d6ce99528060be18a42be09aca8d39efcb47f28/tests/go.mod
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[schema]: ./concepts.md#schema-migrations-code-generation
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions

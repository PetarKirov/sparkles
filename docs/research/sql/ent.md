# ent (Go)

An "entity framework for Go" whose signature move is **schema-as-code plus code
generation**: you declare your graph schema as ordinary Go types (`type User struct { ent.Schema }`
with `Fields()`/`Edges()`/`Indexes()` methods), and `ent generate` emits a fully-typed, fluent
client where every query, predicate, mutation, and edge traversal is statically typed and explicit
— no `interface{}`, no reflection at query time.

| Field              | Value                                                                                                                                                            |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Go (you write the schema in Go; `entc` generates Go)                                                                                                             |
| License            | Apache-2.0 (`Copyright 2019-present Facebook Inc.`)                                                                                                              |
| Repository         | [ent/ent][repo]                                                                                                                                                  |
| Documentation      | [entgo.io][docs] · [`doc/md/`][docdir]                                                                                                                           |
| Category           | [Full ORM (data-mapper)][concepts-ladder] — **schema-as-code + codegen, graph-oriented**; but explicit (no identity map / unit of work / lazy load)              |
| Abstraction level  | Top of the [ladder][concepts-ladder] (entities + relations + migrations), reached by generating a [typed fluent builder][concepts-models] rather than reflection |
| Query model        | [Fluent typed builder][concepts-models] — a generated method chain with one typed predicate per field (`user.AgeGT(30)`) and typed edge traversals               |
| Effect/async model | [Blocking][concepts-effects] — generated methods take a `context.Context` and run synchronously over `database/sql`; errors are Go `error` returns               |
| Backends           | MySQL, MariaDB, TiDB, PostgreSQL, CockroachDB, SQLite, and Gremlin (graph)                                                                                       |
| First release      | ≈2019, open-sourced by Facebook Connectivity (web-attested)                                                                                                      |
| Latest version     | pre-`v1.0`; the `v0.14.x` series (web-attested; the [`v1` roadmap][repo] is issue #46)                                                                           |

> [!NOTE]
> ent is this survey's data point for **schema-as-code driving whole-client code generation** —
> the mirror image of `sqlc`, which is _query_-first (raw SQL in, typed Go out). ent is _schema_-first
> and _graph_-shaped: the schema Go objects are the source of truth, and `entc` emits an entire typed
> ORM around them. It sits at the [full-ORM rung][concepts-ladder] by feature surface (entities,
> relations, migrations) yet deliberately drops the classic-ORM machinery from
> [concepts][concepts-orm] — there is **no identity map, no unit of work, no automatic change
> tracking, and no lazy loading** (eager loading is explicit via `WithX`). Its typed client is closer
> to the compile-checked builders (`Diesel`, `Beam`, `jOOQ`) than to a reflective active-record ORM
> like `GORM`. See [concepts][concepts] for the shared vocabulary.

---

## Overview

### What it solves

ent removes the trade a Go developer faces between a hand-written `database/sql` mapper (typed but
verbose, and you re-write `rows.Scan` for every query) and a reflection-based ORM like `GORM`
(terse but stringly-typed, with runtime-string column references and `interface{}` everywhere). ent
keeps full static typing _and_ terseness by generating the mapper. The four headline properties are
stated on the first screen of the `README.md` ([`README.md`][readme]):

> _"Simple, yet powerful entity framework for Go, that makes it easy to build and maintain
> applications with large data-models."_
>
> - _"**Schema As Code** - model any database schema as Go objects."_
> - _"**Easily Traverse Any Graph** - run queries, aggregations and traverse any graph structure easily."_
> - _"**Statically Typed And Explicit API** - 100% statically typed and explicit API using code generation."_
> - _"**Multi Storage Driver** - supports MySQL, MariaDB, TiDB, PostgreSQL, CockroachDB, SQLite and Gremlin."_

The "Schema As Code" and "Statically Typed … using code generation" clauses are the two pillars, and
the `getting-started` guide restates them as design _principles_ ([`doc/md/getting-started.mdx`][getstarted]):

> _"- Easily model database schema as a graph structure._
> _- Define schema as a programmatic Go code._
> _- Static typing based on code generation._
> _- Database queries and graph traversals are easy to write._
> _- Simple to extend and customize using Go templates."_

The lineage is explicit: the project was cloned from an internal Facebook/Meta framework
([`README.md`][readme]):

> _"The `ent` project was inspired by Ent, an entity framework used internally at Meta (Facebook).
> It was created by [a8m](https://github.com/a8m) and [alexsn](https://github.com/alexsn) from the
> [Facebook Connectivity][fbc] team. These days, it is developed and maintained by the
> [Atlas](https://github.com/ariga/atlas) team."_

The Atlas hand-off matters downstream: ent's migration engine _is_ Atlas (see
[Schema, migrations & code generation](#schema-migrations-code-generation)).

### Design philosophy

**The schema is Go, and it is the single source of truth.** An ent schema is a Go type that embeds
`ent.Schema` and answers a fixed set of methods — the codegen contract is the `ent.Interface`
([`ent.go`][entgo]):

> _"The Interface type describes the requirements for an exported type defined in the schema
> package. It functions as the interface between the user's schema types and codegen loader. Users
> should use the Schema type for embedding."_

That interface exposes `Fields()`, `Edges()`, `Indexes()`, plus the extension hooks `Mixin()`,
`Hooks()`, `Interceptors()`, `Policy()`, and `Annotations()` ([`ent.go`][entgo]). Because the schema
is _code_, it is type-checked by the Go compiler before codegen even runs, refactored with ordinary
tooling, and composed with `Mixin` (reusable field/edge/hook bundles). This is the defining contrast
with the schema-first families: a `.prisma` file (`Prisma`) or a `.sql` DDL file (`sqlc`) is a
separate artifact in a separate language; ent's schema is Go you import.

**Codegen produces an explicit, static API — reflection is a non-goal.** ent's promise is
"100% statically typed and explicit," and the emitted client honours it: every column becomes a
typed predicate function, every edge a typed traversal method, every entity a Go struct. A misspelled
field or a type-mismatched comparison is a _compile_ error, not a runtime one — the same guarantee
`Diesel` and `jOOQ` sell, reached here by generating code rather than by type-level metaprogramming.
The trade is the generated-code volume and the `go generate` step in the loop (see
[Weaknesses](#weaknesses)).

**The data model is a graph.** ent speaks of _vertices_ (entities) and _edges_ (relations) as
first-class, not as an afterthought bolted onto tables. Edges are declared symmetrically
(`edge.To`/`edge.From` with `Ref`), traversed with generated `QueryX` methods, and filtered with
generated `HasX`/`HasXWith` predicates. The graph vocabulary runs all the way down to the SQL layer,
whose translation package is literally named for it ([`dialect/sql/sqlgraph/graph.go`][sqlgraph]):
_"Package sqlgraph provides graph abstraction capabilities on top of sql-based databases for ent
codegen."_

---

## Connection, pooling & resource lifetime

ent opens a database through `ent.Open(driverName, dataSourceName)`, which for the SQL dialects wraps
the stdlib `database/sql` and returns a `*ent.Client` ([`examples/start/ent/client.go`][client]):

```go
// Open opens a database/sql.DB specified by the driver name and
// the data source name, and returns a new client attached to it.
func Open(driverName, dataSourceName string, options ...Option) (*Client, error) {
    switch driverName {
    case dialect.MySQL, dialect.Postgres, dialect.SQLite:
        drv, err := sql.Open(driverName, dataSourceName)
        if err != nil {
            return nil, err
        }
        return NewClient(append(options, Driver(drv))...), nil
    default:
        return nil, fmt.Errorf("unsupported driver: %q", driverName)
    }
}
```

The `*ent.Client` is the long-lived object; sub-clients (`client.User`, `client.Car`, …) hang off it,
one per schema type. **Pooling is `database/sql`'s job**, not ent's: ent holds a `dialect.Driver`
over the stdlib `*sql.DB`, whose pool sizing (`SetMaxOpenConns`, `SetMaxIdleConns`) you configure on
the underlying handle via the [`sql` integration][docs] driver. ent adds no pool of its own, no
scoped acquire/release, and no lifetime type — the same minimalism as `sqlc` and Go `database/sql`
generally, and the sharp contrast with the effect systems' scoped `Acquirer` from
[concepts][concepts-pools]. Resource cleanup is the idiomatic `defer client.Close()`.

---

## Query construction & injection safety

This is one of ent's two centres of gravity. The user never writes SQL text; they compose a chain of
_generated, typed_ methods, and the framework lowers that chain to a parameterized statement.

### The generated typed client

From the canonical getting-started program, creating and querying a `User` ([`examples/start/start.go`][start]):

```go
u, err := client.User.
    Create().
    SetAge(30).
    SetName("a8m").
    Save(ctx)

u, err := client.User.
    Query().
    Where(user.NameEQ("a8m")).
    // `Only` fails if no user found, or more than 1 user returned.
    Only(ctx)
```

`SetAge(int)` and `SetName(string)` are generated setters with the field's concrete Go type — passing
a `string` to `SetAge` does not compile. `user.NameEQ("a8m")` is a generated **typed predicate**: the
`user` package (one per schema type) exports a function per field-per-operator, each returning a
`predicate.User` ([`examples/start/ent/user/where.go`][where]):

```go
// AgeGT applies the GT predicate on the "age" field.
func AgeGT(v int) predicate.User {
    return predicate.User(sql.FieldGT(FieldAge, v))
}

// Name applies equality check predicate on the "name" field. It's identical to NameEQ.
func Name(v string) predicate.User {
    return predicate.User(sql.FieldEQ(FieldName, v))
}
```

The signature is the guarantee. `user.AgeGT` takes an `int` because `age` is `field.Int`; a wrong
field name is an undefined symbol, a wrong value type is a type error — both caught by `go build`
before the query ever runs. The available operators are enumerated per Go type in the docs
([`doc/md/predicates.md`][predicates]): numeric fields get `=, !=, >, <, >=, <=, IN, NOT IN`, string
fields add `Contains`/`HasPrefix`/`HasSuffix`/`ContainsFold`, optional fields add `IsNil`/`NotNil`,
and so on. Composite predicates use generated `user.And`/`user.Or`/`car.Not`.

### Graph traversal as typed method chains

Edges are traversed, not joined by hand. From the same example, walking `Group → Users → Cars`
([`examples/start/start.go`][start]):

```go
cars, err := client.Group.
    Query().
    Where(group.Name("GitHub")). // (Group(Name=GitHub),)
    QueryUsers().                // (User(Name=Ariel, Age=30),)
    QueryCars().                 // (Car(Model=Tesla, ...), Car(Model=Mazda, ...),)
    All(ctx)
```

Each `QueryX` is generated from an edge in the schema and is itself typed (`QueryUsers()` returns a
`*UserQuery`, `QueryCars()` a `*CarQuery`), so the chain is checked end to end. Edge _existence_ is a
predicate too — `user.HasCars()` and `user.HasCarsWith(car.ModelEQ("Ford"))` compile to a subquery
over the edge's foreign key or join table ([`examples/start/ent/user/where.go`][where]):

```go
// HasCars applies the HasEdge predicate on the "cars" edge.
func HasCars() predicate.User {
    return predicate.User(func(s *sql.Selector) {
        step := sqlgraph.NewStep(
            sqlgraph.From(Table, FieldID),
            sqlgraph.Edge(sqlgraph.O2M, false, CarsTable, CarsColumn),
        )
        sqlgraph.HasNeighbors(s, step)
    })
}
```

### Injection safety: the SQL builder binds every value

The whole typed chain lowers to `dialect/sql`, a thin, statically-typed wrapper over `database/sql`.
Its package doc is candid about the division of labour ([`dialect/sql/builder.go`][builder]):

> _"Package sql provides wrappers around the standard database/sql package to allow the generated
> code to interact with a statically-typed API. Users that are interacting with this package should
> be aware that the following builders don't check the given SQL syntax nor validate or escape
> user-inputs. ~All validations are expected to be happened in the generated ent package."_

Values never enter the SQL text. The builder's `Arg` emits a dialect placeholder and stashes the
value in a separate argument list ([`dialect/sql/builder.go`][builder]):

```go
// Arg appends an input argument to the builder.
func (b *Builder) Arg(a any) *Builder {
    // ...
    // Default placeholder param (MySQL and SQLite).
    format := "?"
    if b.postgres() {
        // Postgres' arguments are referenced using the syntax $n.
        format = "$" + strconv.Itoa(b.total+1)
    }
    // ...
    return b.Argf(format, a)
}
```

When the query executes, the rendered text and the collected arguments travel on separate channels —
`selector.Query()` returns `(query string, args []any)`, and the driver receives them apart
([`dialect/sql/sqlgraph/graph.go`][sqlgraph]):

```go
query, args := selector.Query()
if err := drv.Query(ctx, query, args, rows); err != nil {
    return err
}
```

Because every user value is a bind parameter, [SQL injection is structurally impossible][concepts-injection]
for values — the same parameter-binding model `concepts` describes, inherited from `database/sql` and
identical in spirit to `sqlc`'s `const`-string-plus-bind-args. The escape hatch is the raw `dialect/sql`
builder and query modifiers (`.Modify(...)`, `sql.Expr`), where — as the package doc warns — you own
escaping; but the generated predicate/traversal surface never exposes a string-concatenation channel.

---

## Schema, migrations & code generation

The other centre of gravity, and where the "framework" claim is earned: ent is a code generator
(`entc`) plus an Atlas-backed migration engine wrapped around your Go schema.

### Declaring entities, fields, edges, and indexes in Go

A schema is a Go struct embedding `ent.Schema`, with `Fields()` and `Edges()` methods returning
builder values ([`examples/start/ent/schema/user.go`][userschema]):

```go
type User struct {
    ent.Schema
}

func (User) Fields() []ent.Field {
    return []ent.Field{
        field.Int("age").
            Positive(),
        field.String("name").
            Default("unknown"),
    }
}

func (User) Edges() []ent.Edge {
    return []ent.Edge{
        edge.To("cars", Car.Type),
        edge.From("groups", Group.Type).
            Ref("users"),
    }
}
```

Each builder is a fluent descriptor. `field.String(...)`, `field.Int(...)`, `field.Time(...)`,
`field.JSON(...)`, `field.Bool(...)` create typed field builders ([`schema/field/field.go`][fieldpkg]);
`.Optional()` marks a field nullable (_"Unlike edges, fields are required by default"_),
`.Nillable()` makes it a pointer in the struct (_"'Nillable' fields are pointers in the generated
struct"_), `.Immutable()`, `.Default(...)`, and validators like `.Positive()` or `.Match(regexp)`
([`examples/start/ent/schema/group.go`][groupschema]) attach at declaration time. Edges are
symmetric: `edge.To` defines an association, `edge.From(...).Ref(...)` its back-reference — one being
`Unique()` makes it one-to-many, both makes it one-to-one ([`schema/edge/edge.go`][edgepkg]).
`index.Fields("first", "last").Unique()` declares composite/unique indexes ([`schema/index/index.go`][indexpkg]).
Each builder returns a `*Descriptor` that the loader reads.

### `entc`: the code generator

`go generate` runs the ent CLI over the schema package ([`examples/start/ent/generate.go`][generate]):

```go
//go:generate go run -mod=mod entgo.io/ent/cmd/ent generate ./schema
```

`entc` loads the schema types, builds a `*gen.Graph`, and renders the client with Go `text/template`s
([`entc/entc.go`][entc]). The `code-gen` guide lists what one run produces ([`doc/md/code-gen.md`][codegen]):

> _"The `generate` command generates the following assets for the schemas:_
> _- `Client` and `Tx` objects used for interacting with the graph._
> _- CRUD builders for each schema type._
> _- Entity object (Go struct) for each of the schema types._
> _- Package containing constants and predicates used for interacting with the builders._
> _- A `migrate` package for SQL dialects._
> _- A `hook` package for adding mutation middlewares."_

The output is committed to the repo (every generated file carries `Code generated by ent, DO NOT
EDIT.`) and is customizable through Go template extensions and schema `Annotations`
([`schema/schema.go`][schemapkg]). This is a **code-first** stance from [concepts][concepts-schema]:
the Go schema _is_ the schema, and codegen flows outward from it — the opposite direction to `sqlc`
(SQL query in) and to the db-first introspecting builders (`jOOQ`).

### Migrations: powered by Atlas

ent does run migrations — via [Atlas][docs], the tool its maintainers also build. The generated
client exposes an auto-migration entry point ([`doc/md/migrate.md`][migrate]):

```go
if err := client.Schema.Create(ctx); err != nil {
    log.Fatalf("failed creating schema resources: %v", err)
}
```

> _"`Create` creates all database resources needed for your `ent` project. By default, `Create` works
> in an "append-only" mode; which means, it only creates new tables and indexes, appends columns to
> tables or extends column types."_

Under the hood, the migration engine is Atlas — `dialect/sql/schema/atlas.go` imports
`ariga.io/atlas/sql/migrate` / `.../schema` / `.../sqlclient` and defines an `Atlas` type: _"Atlas
atlas migration engine"_ ([`dialect/sql/schema/atlas.go`][atlas]). ent offers **both** stances Atlas
supports: the _declarative_ `Schema.Create` above (drive the DB toward the schema's desired state,
optionally with `migrate.WithDropColumn(true)` / `WithDropIndex(true)`), and _versioned_ migrations,
where Atlas diffs the schema against a migration directory and writes numbered, reviewable SQL files
([`doc/md/versioned-migrations.mdx`][versioned]):

> _"Atlas loads the **current state** by executing the SQL files stored in the migration directory
> onto the provided dev database. It then compares this state against the **desired state** defined
> by the `ent/schema` package and writes a migration plan for moving from the current state to the
> desired state."_

That two-mode migration story (declarative auto-migrate for dev, checksum-verified versioned files
for prod) is richer than `sqlc`'s (which _reads_ schema but never applies it) and is a direct benefit
of the Atlas dependency.

---

## Type mapping & result decoding

Type mapping is fixed at generation time from the field's declared Go type, not discovered by
reflection at query time. `field.Int` becomes `int`, `field.String` becomes `string`, `field.Time`
becomes `time.Time` (with `PkgPath: "time"`), `field.JSON(name, typ)` becomes the given Go type
serialized as JSON ([`schema/field/field.go`][fieldpkg]). Nullability flows from the field modifiers:
a required field is a plain value; `.Optional()` allows it to be unset, and `.Nillable()` makes the
generated struct field a pointer (`*string`) so a database `NULL` is representable
([`schema/field/field.go`][fieldpkg]). Overriding the storage type per dialect is
`.SchemaType(map[string]string{...})`, and a custom Go type is `.GoType(...)`.

Row hydration is generated `Scan` code. A query lowers through `sqlgraph.QueryNodes`, which builds the
`SELECT`, runs it, and scans each row's columns into the entity struct in the fixed field order
resolved at codegen — so decoding costs nothing beyond the driver's own `Scan`
([`dialect/sql/sqlgraph/graph.go`][sqlgraph]). Related entities are **not** loaded automatically:
eager loading is opt-in per query. `client.User.Query().WithCars()` populates each user's `Edges.Cars`
by issuing a batched second query keyed on the parent IDs ([`examples/start/ent/user_query.go`][userquery],
[`doc/md/eager-load.mdx`][eagerload]) — ent's answer to the [N+1 problem][concepts-n1] is that a join
or batch is _explicit_ (`WithX`), never triggered by touching an unloaded field. Reading an edge that
was not eager-loaded returns a `NotLoadedError` rather than silently firing a query
([`examples/start/ent/ent.go`][enterrors]).

---

## Effect model, transactions & error handling

The dimension this survey weights most, and where ent lands squarely at the **[blocking][concepts-effects]**
point — the generated client is ordinary synchronous Go.

### Blocking calls, no effect value

Every terminal method takes a `context.Context` and returns `(value, error)` synchronously:
`Save(ctx)`, `All(ctx)`, `Only(ctx)`, `Exec(ctx)`, `Count(ctx)` all run the statement and block until
it returns ([`examples/start/start.go`][start]). There is no future, `Task`, `IO`, or `ConnectionIO`:
a query builder is a mutable value you _execute_, not a description you _interpret_. Concurrency is the
caller's job (a goroutine per unit of work), exactly as in `sqlc` and idiomatic Go. For the
algebraic-effects lens of this survey, ent is — like `GORM` and `sqlc` — a "typed _shape_, untyped
_effect_" data point: the result is exhaustively typed, but the effect is a bare, eager,
side-effecting call, in contrast with `doobie`/`skunk`/`Quill`'s reifiable effect values.

### Transactions: `client.Tx`, commit/rollback, no savepoints

A transaction is a transactional client. `client.Tx(ctx)` returns a `*ent.Tx` whose sub-clients run
inside the transaction; you drive it with `Commit`/`Rollback` ([`doc/md/transactions.md`][txn]):

```go
tx, err := client.Tx(ctx)
if err != nil {
    return fmt.Errorf("starting a transaction: %w", err)
}
hub, err := tx.Group.Create().SetName("Github").Save(ctx)
if err != nil {
    return rollback(tx, err) // rollback wraps tx.Rollback() + the error
}
// ...
return tx.Commit()
```

Isolation levels are exposed through `client.BeginTx(ctx, &sql.TxOptions{Isolation: ...})`
([`doc/md/transactions.md`][txn], [`examples/start/ent/client.go`][client]). Two limits are findings
for this survey. First, ent guards against re-entrancy — starting a transaction from a transactional
client returns `ErrTxStarted` (_"ent: cannot start a transaction within a transaction"_,
[`examples/start/ent/client.go`][client]) — so there is **no nested-transaction / savepoint model**;
a `SAVEPOINT`-based nested `withTransaction` like the effect systems' does not exist. Second, rollback
on error is manual (the idiomatic `defer`/`rollback` helper), not an automatic property of a
transaction combinator. There is a subtle lifetime wrinkle: entities created inside a `Tx` carry the
transactional driver, so `Unwrap()` must be called to traverse their edges after commit
([`doc/md/transactions.md`][txn]).

### Errors: typed sentinels, but a plain Go `error` channel

Every method returns a bare `error`; ent does not reflect the failure set in the _type_. But unlike
`sqlc` (which delegates entirely to the driver), ent generates a small taxonomy of **typed error
structs** with `Is*` predicates ([`examples/start/ent/ent.go`][enterrors]):

- `NotFoundError` — `Only`/`First` found no row; test with `ent.IsNotFound(err)`.
- `NotSingularError` — `Only` found more than one row; `ent.IsNotSingular(err)`.
- `ConstraintError` — _"trying to create/update one or more entities and one or more of their
  constraints failed. For example, violation of edge or field uniqueness"_; `ent.IsConstraintError(err)`.
- `ValidationError` — a schema validator (e.g. `Positive()`, `Match(regexp)`) rejected a value at
  mutation time; `ent.IsValidationError(err)`.
- `NotLoadedError` — an edge accessed on the struct was never eager-loaded; `ent.IsNotLoaded(err)`.

These are recovered with `errors.As`/`errors.Is` and the generated helpers — richer than a raw driver
error, but still a single untyped `error` return, not a type-level error channel like `Effect TS`'s
`SqlError` union or `doobie`'s effect error type.

### Middleware: hooks, interceptors, and the privacy layer

ent has an explicit policy layer that most lower-rung tools lack, wired through the schema. Three
seams, all typed function-middleware ([`ent.go`][entgo]):

- **Hooks** — _"the 'mutation middleware'. A function that gets a Mutator and returns a Mutator,"_ run
  around every create/update/delete (the generated `hook` package).
- **Interceptors** — _"an execution middleware for various types of Ent queries … invoked before the
  query executions,"_ a natural fit for logging, caching, or soft-delete filters.
- **Privacy `Policy`** — `EvalMutation`/`EvalQuery` rules attached in the schema. Its selling point
  ([`doc/md/privacy.mdx`][privacy]): _"you write the privacy policy **once** (in the schema), and it
  is **always** evaluated. No matter where queries and mutations are performed in your codebase, it
  will always go through the privacy layer."_

These are runtime middleware over the blocking calls — not an effect system — but they give ent a
first-class authorization/observability story that `sqlc` and `GORM` push onto the caller.

---

## Ecosystem & maturity

ent is a mature, widely-adopted framework under the permissive **Apache-2.0** license (headers read
`Copyright 2019-present Facebook Inc.`, [`LICENSE`][license]). It was open-sourced in ≈2019 by the
Facebook Connectivity team and is now developed and maintained by the **Atlas** team at Ariga
([`README.md`][readme]); it remains pre-`v1.0` (the `v1` roadmap is tracked in issue #46), with the
`v0.14.x` series current (web-attested).

**Backends.** The SQL dialects — PostgreSQL, MySQL, MariaDB, TiDB, CockroachDB, SQLite — share the
`dialect/sql` builder and the Atlas-backed migrator; a **Gremlin** graph backend (AWS Neptune) exists
in `dialect/gremlin/` for the graph-database case ([`README.md`][readme], [`dialect/dialect.go`][dialect]).
Indexes and some features are SQL-only (_"indexes are implemented only for SQL dialects, and does not
support gremlin,"_ [`schema/index/index.go`][indexpkg]).

**Extensibility and companions.** ent's codegen is template-driven and extension-friendly; the most
prominent extension is `entgql` (generate a GraphQL server + Relay-style pagination from the same
schema), alongside the Atlas migration tooling and the `elk`/gRPC generators. The whole ecosystem
rides the one schema-as-code definition. ent is a CNCF-adjacent, production-grade project with broad
industrial use (web-attested).

---

## Strengths

- **Schema-as-code, in Go.** The schema is type-checked Go you refactor with normal tooling and
  compose with `Mixin`; no separate schema DSL to learn or keep in sync.
- **Fully static, explicit client.** Generated typed predicates (`user.AgeGT(30)`), typed setters, and
  typed edge traversals mean wrong field/type/edge references are compile errors — no `interface{}`,
  no runtime-string columns as in `GORM`.
- **Graph model is first-class.** Edges, traversals (`QueryX`), edge predicates (`HasXWith`), and
  explicit eager loading (`WithX`) make relations ergonomic without the ORM lazy-load foot-gun.
- **Injection-safe by construction.** Every value binds as a `?`/`$n` parameter through `dialect/sql`;
  the typed surface exposes no string-concatenation channel.
- **Real migrations via Atlas.** Both declarative auto-migrate and versioned, checksum-verified
  migration files — a capability `sqlc` deliberately lacks.
- **Policy/hook/interceptor layer.** Authorization, logging, and caching are first-class schema-level
  middleware, evaluated everywhere by construction.
- **Broad backend support.** Six SQL engines plus a Gremlin graph backend behind one API.

## Weaknesses

- **A `go generate` step in the loop.** The client is a large committed artifact you regenerate on
  every schema change; the generated tree is verbose (a package and several files per entity).
- **Schema-as-Go learning curve.** The `edge.To`/`edge.From`/`Ref` symmetry, `Mixin`, and the
  builder-descriptor model are more to learn than a flat DDL file or a reflective struct-tag ORM.
- **Blocking, untyped-effect model.** Methods are eager synchronous calls returning a bare `error`;
  no effect value to inspect or interpret, and the error _channel_ (though populated with typed
  sentinels) is Go's single `error`.
- **No savepoints or nested transactions.** Re-entering `Tx` errors out; there is no `SAVEPOINT`-based
  nesting like the effect systems, and rollback-on-error is manual.
- **No dynamic-structure escape within the typed API.** Predicates compose, but a truly runtime-shaped
  query (dynamic column list, dynamic `ORDER BY`) drops to the raw `dialect/sql` builder where you own
  correctness and escaping.
- **Pre-`v1.0`.** The API is stable in practice and heavily used, but has not cut a `1.0`.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                              | Trade-off                                                                                    |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **Schema as Go code** (`ent.Schema` + `Fields`/`Edges` methods) | Compiler-checked, refactorable, composable (`Mixin`); no separate schema language      | A Go-API learning curve; the schema lives in code, not a declarative file reviewers can diff |
| **Generate the whole typed client** (`entc` templates)          | 100% static, explicit API — wrong field/type/edge is a compile error; no reflection    | A `go generate` step and a large committed, verbose generated tree                           |
| **Graph model** (vertices + typed edges/traversals)             | Relations are first-class and ergonomic (`QueryX`, `HasXWith`, `WithX`)                | More schema vocabulary; the graph abstraction adds `sqlgraph` machinery between you and SQL  |
| **Explicit, no identity map / unit of work / lazy load**        | Predictable SQL; no hidden flush or surprise N+1; `NotLoadedError` over silent queries | You lose classic-ORM conveniences (dirty tracking, transparent lazy loading)                 |
| **Bind every value via `dialect/sql`** (`?` / `$n`)             | Injection-safe by construction; dialect-portable                                       | The raw builder escape hatch is unchecked — you own escaping there                           |
| **Migrations via Atlas** (declarative + versioned)              | Real, reviewable migrations; reuse the maintainers' dedicated migration engine         | A heavyweight `ariga.io/atlas` dependency; two migration modes to understand                 |
| **Blocking methods, bare `error` + typed sentinels**            | Match Go idiom; typed `Is*` predicates beat a raw driver error                         | No effect value, no type-level error channel; transactions/savepoints are the caller's       |
| **Hooks / interceptors / privacy policy in the schema**         | Cross-cutting concerns declared once, always applied                                   | Runtime middleware, not an effect system; another layer of concepts to master                |

---

## Sources

- [ent/ent — GitHub repository][repo] · [entgo.io documentation][docs] · [`doc/md/`][docdir]
- [`README.md` — "Schema As Code", "Statically Typed And Explicit API … using code generation", Meta/Facebook origin, backend list][readme]
- [`doc/md/getting-started.mdx` — the five design principles (schema as Go code, static typing via codegen, graph traversals)][getstarted]
- [`ent.go` — the `ent.Interface` codegen contract (`Fields`/`Edges`/`Indexes`/`Hooks`/`Interceptors`/`Policy`), `Hook`/`Interceptor` middleware, `Op` mutation ops][entgo]
- [`schema/field/field.go` — `field.String`/`Int`/`Time`/`JSON` builders, `Optional`/`Nillable`/`Immutable`/`Default`][fieldpkg] · [`schema/edge/edge.go` — `edge.To`/`edge.From`/`Ref`/`Through`][edgepkg] · [`schema/index/index.go` — `index.Fields`/`Edges`/`Unique`][indexpkg] · [`schema/schema.go` — `Annotation`][schemapkg]
- [`examples/start/ent/schema/{user,car,group}.go` — a real schema (fields, edges, validators)][userschema] · [`examples/start/start.go` — the generated-client usage (create, query, traverse)][start] · [`examples/start/ent/generate.go` — the `go:generate` directive][generate]
- [`examples/start/ent/user/where.go` — generated typed predicates (`AgeGT`, `NameEQ`, `HasCars`/`HasCarsWith`)][where] · [`examples/start/ent/user_query.go` — `WithCars`/`WithGroups` eager loading][userquery]
- [`dialect/sql/builder.go` — the statically-typed `database/sql` wrapper; `Arg` placeholder binding (`?` / `$n`)][builder] · [`dialect/sql/sqlgraph/graph.go` — graph→SQL translation; `query, args := selector.Query()` + `drv.Query`][sqlgraph] · [`dialect/dialect.go` — MySQL/Postgres/SQLite/Gremlin drivers][dialect]
- [`dialect/sql/schema/atlas.go` — "Atlas atlas migration engine"; `ariga.io/atlas` imports][atlas] · [`doc/md/migrate.md` — `Schema.Create` auto-migration][migrate] · [`doc/md/versioned-migrations.mdx` — Atlas diff current→desired state][versioned]
- [`examples/start/ent/client.go` — `Open`, `Tx`, `BeginTx` (isolation), `ErrTxStarted`][client] · [`doc/md/transactions.md` — `Tx`/`Commit`/`Rollback`/`Unwrap`, isolation levels][txn] · [`examples/start/ent/ent.go` — `NotFoundError`/`NotSingularError`/`ConstraintError`/`ValidationError`/`NotLoadedError` + `Is*`][enterrors]
- [`doc/md/code-gen.md` — the generated-assets list][codegen] · [`entc/entc.go` — `entc` codegen entry (`LoadGraph`/`Generate`)][entc] · [`doc/md/predicates.md` — field/edge predicate catalog][predicates] · [`doc/md/eager-load.mdx` — `WithX` eager loading][eagerload] · [`doc/md/privacy.mdx` — the privacy policy layer][privacy]
- Shared vocabulary: [concepts & vocabulary][concepts] · [the abstraction ladder][concepts-ladder] · [query construction models][concepts-models] · [statements, parameters & injection][concepts-injection] · [schema, migrations & codegen][concepts-schema] · [effects, transactions & error handling][concepts-effects] · [connections & pools][concepts-pools] · [ORM patterns][concepts-orm] · [the N+1 problem][concepts-n1]

<!-- References -->

[concepts]: ./concepts.md
[concepts-ladder]: ./concepts.md#the-abstraction-ladder
[concepts-models]: ./concepts.md#query-construction-models
[concepts-injection]: ./concepts.md#statements-parameters-and-sql-injection
[concepts-pools]: ./concepts.md#connections-pools-and-sessions
[concepts-schema]: ./concepts.md#schema-migrations-code-generation
[concepts-effects]: ./concepts.md#effects-transactions-and-error-handling
[concepts-orm]: ./concepts.md#orm-patterns
[concepts-n1]: ./concepts.md#loading-strategies-and-the-n1-problem
[index]: ./index.md
[repo]: https://github.com/ent/ent
[docs]: https://entgo.io
[docdir]: https://github.com/ent/ent/tree/master/doc/md
[readme]: https://github.com/ent/ent/blob/master/README.md
[getstarted]: https://github.com/ent/ent/blob/master/doc/md/getting-started.mdx
[entgo]: https://github.com/ent/ent/blob/master/ent.go
[fieldpkg]: https://github.com/ent/ent/blob/master/schema/field/field.go
[edgepkg]: https://github.com/ent/ent/blob/master/schema/edge/edge.go
[indexpkg]: https://github.com/ent/ent/blob/master/schema/index/index.go
[schemapkg]: https://github.com/ent/ent/blob/master/schema/schema.go
[userschema]: https://github.com/ent/ent/blob/master/examples/start/ent/schema/user.go
[groupschema]: https://github.com/ent/ent/blob/master/examples/start/ent/schema/group.go
[start]: https://github.com/ent/ent/blob/master/examples/start/start.go
[generate]: https://github.com/ent/ent/blob/master/examples/start/ent/generate.go
[where]: https://github.com/ent/ent/blob/master/examples/start/ent/user/where.go
[userquery]: https://github.com/ent/ent/blob/master/examples/start/ent/user_query.go
[builder]: https://github.com/ent/ent/blob/master/dialect/sql/builder.go
[sqlgraph]: https://github.com/ent/ent/blob/master/dialect/sql/sqlgraph/graph.go
[dialect]: https://github.com/ent/ent/blob/master/dialect/dialect.go
[atlas]: https://github.com/ent/ent/blob/master/dialect/sql/schema/atlas.go
[migrate]: https://github.com/ent/ent/blob/master/doc/md/migrate.md
[versioned]: https://github.com/ent/ent/blob/master/doc/md/versioned-migrations.mdx
[client]: https://github.com/ent/ent/blob/master/examples/start/ent/client.go
[txn]: https://github.com/ent/ent/blob/master/doc/md/transactions.md
[enterrors]: https://github.com/ent/ent/blob/master/examples/start/ent/ent.go
[codegen]: https://github.com/ent/ent/blob/master/doc/md/code-gen.md
[entc]: https://github.com/ent/ent/blob/master/entc/entc.go
[predicates]: https://github.com/ent/ent/blob/master/doc/md/predicates.md
[eagerload]: https://github.com/ent/ent/blob/master/doc/md/eager-load.mdx
[privacy]: https://github.com/ent/ent/blob/master/doc/md/privacy.mdx
[license]: https://github.com/ent/ent/blob/master/LICENSE
[fbc]: https://connectivity.fb.com

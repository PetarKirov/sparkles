# Ecto (Elixir)

A functional [data mapper][ladder] for Elixir built from four decoupled pieces — a `Repo` boundary, code-first `Schema` structs, a composable **macro** query DSL, and the `Changeset` — that deliberately stops short of a full ORM: no lazy loading, no identity map, no implicit unit of work.

| Field              | Value                                                                                                                                                         |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Elixir (runs on the Erlang/BEAM VM; `elixir: "~> 1.14"`)                                                                                                      |
| License            | Apache-2.0 (`LICENSE.md`; `mix.exs` `licenses: ["Apache-2.0"]`)                                                                                               |
| Repository         | [elixir-ecto/ecto][repo]                                                                                                                                      |
| Documentation      | [hexdocs.pm/ecto][docs] · [`ecto_sql`][ectosqldocs] (SQL adapters + migrations)                                                                               |
| Category           | [Functional data mapper][ladder] (repo + changeset; **no** ORM identity-map / lazy-load / unit-of-work)                                                       |
| Abstraction level  | [Data mapper (functional)][ladder] — the rung below a full ORM                                                                                                |
| Query model        | Composable [query macros][qcm] → an `Ecto.Query` struct (a quoted DSL reified to an AST, compile-time where possible)                                         |
| Effect/async model | Synchronous / **blocking** through `Repo`; eager tagged-tuple (`{:ok, _}` / `{:error, _}`) returns — **not** an effect value (BEAM process-based concurrency) |
| Backends           | Postgres, MySQL, MSSQL, SQLite3, ClickHouse, ETS — via **adapters** (`ecto_sql` + a driver); core `ecto` is adapter-agnostic                                  |
| First release      | ≈2013 (web-attested; repo copyright dates from 2013 Plataformatec)                                                                                            |
| Latest version     | `3.14.1` (2026-07-09, `CHANGELOG.md`)                                                                                                                         |

> [!NOTE]
> Ecto is this survey's data point for a **functional data mapper in a
> dynamically-typed, process-concurrency ecosystem**. It reaches the same
> destination as [doobie][doobie] / [Quill][quill] — typed-ish composable queries and
> _explicit_ persistence, with no [identity map][orm] and no [lazy load][nplusone] —
> but by different means: eager, **blocking** tagged-tuple calls over cheap BEAM
> processes (not an `IO`/effect monad), and **runtime** `Changeset` validation
> instead of a compile-time type-checker. Its signature contribution — the
> `Ecto.Changeset` as a first-class, composable value for casting/validation/change
> tracking, kept _separate_ from persistence — is the idea to weigh against the
> effect-system libraries. Terms below link to [concepts][concepts].

---

## Overview

### What it solves

Ecto is, in its own `mix.exs` one-liner, _"A toolkit for data mapping and language
integrated query for Elixir"_ ([`mix.exs`][mix]). It is **not** an ORM in the
Rails/Hibernate sense; it is a set of four small, decoupled tools you assemble. The
`Ecto` module moduledoc states the decomposition directly ([`lib/ecto.ex`][ectomod]):

> _"Ecto is split into 4 main components:_
>
> - _`Ecto.Repo` - repositories are wrappers around the data store. …_
> - _`Ecto.Schema` - schemas are used to map external data into Elixir structs. …_
> - _`Ecto.Query` - written in Elixir syntax, queries are used to retrieve information from a given repository. Ecto queries are secure and composable_
> - _`Ecto.Changeset` - changesets provide a way to track and validate changes before they are applied to the data"_

The moduledoc's mnemonic captures the split of responsibilities ([`lib/ecto.ex`][ectomod]):
`Ecto.Repo` is _"**where** the data is"_, `Ecto.Schema` is _"**what** the data is"_,
`Ecto.Query` is _"**how to read** the data"_, and `Ecto.Changeset` is _"**how to
change** the data"_. Crucially, the data (a plain `struct`) and the storage (the
`Repo`) are decoupled, and a schema is **optional** — you can query a bare table name
and get maps back.

### Design philosophy

Ecto's guiding principle is **explicit over implicit**, expressed most sharply in its
refusal to lazy-load. Where a classic ORM makes `user.posts` transparently fire a
query, Ecto makes you ask ([`lib/ecto.ex`][ectomod]):

> _"NOTE: Ecto does not lazy load associations. While lazily loading associations may
> sound convenient at first, in the long run it becomes a source of confusion and
> performance issues."_

Associations are `#Ecto.Association.NotLoaded` until an explicit `preload` fills them
([`lib/ecto.ex`][ectomod]), which converts the classic [N+1][nplusone] surprise into a
visible, up-front decision. The same explicitness governs mutation: rather than a
mutable, self-persisting entity (the [Active Record][orm] pattern), Ecto keeps the data
as a _"light-weight, serializable"_ struct and routes every change through a
`Changeset` you build and hand to the `Repo` ([`lib/ecto.ex`][ectomod]):

> _"By having structs as data, we guarantee they are light-weight, serializable
> structures. In many languages, the data is often represented by large, complex
> objects, with entwined state transactions, which makes serialization, maintenance
> and understanding hard"_

There is **no [unit of work][orm]**: no session that snapshots loaded objects and
flushes a minimal diff on commit. Persistence is a value you construct (`Changeset` /
`Ecto.Multi`) and a call you make (`Repo.insert` / `Repo.transact`) — the exact
implicit machinery that `ActiveRecord` and `Hibernate` provide, and that Ecto
deliberately drops.

## Connection, pooling & resource lifetime

A `Repo` is _"a wrapper around the database"_ backed by a pluggable **adapter**
([`lib/ecto/repo.ex`][repomod]):

> _"A repository maps to an underlying data store, controlled by the adapter. For
> example, Ecto ships with a Postgres adapter that stores data into a PostgreSQL
> database."_

You define one with `use Ecto.Repo, otp_app: …, adapter: …`, and — unlike a
JDBC-style `DataSource` you open and close — it is an **OTP process** started into your
application's supervision tree ([`lib/ecto.ex`][ectomod]): each repo _"defines a
`start_link/0` function … used as part of your application supervision tree"_. Resource
lifetime is thus owned by the BEAM's supervisor, not by a `try/finally` or a
[scoped][pool] acquire/release combinator. The adapter runs the [connection pool][pool];
the repo config exposes `:pool_size` (default `10`) and `:pool_count`, so the total
connection budget is `pool_size * pool_count` ([`lib/ecto/repo.ex`][repomod]). For a
run of related statements that must share one physical connection, the adapter's
`checkout/3` callback pins a connection for the duration of a function
([`lib/ecto/adapter.ex`][adaptermod]) — the substrate under `Repo.checkout/2` and under
transactions.

## Query construction & injection safety

This is Ecto's centre of gravity, and where "language integrated query" is earned.

**Queries are built by macros into an `Ecto.Query` struct.** `Ecto.Query` _"Provides
the Query DSL"_ and comes in two equivalent surface syntaxes ([`lib/ecto/query.ex`][querymod]):

> _"Ecto queries come in two flavors: keyword-based and macro-based."_

The keyword form (`from … where: … select: …`) and the pipe form
(`|> where(...) |> select(...)`) both expand, at **compile time**, into the same
`%Ecto.Query{}` struct — an AST with `wheres`, `joins`, `select`, `order_bys`, and so on
as fields ([`lib/ecto/query.ex`][querymod]). The `from/2` macro even _requires_ a
compile-time keyword list (_"second argument to `from` must be a compile time keyword
list"_, [`lib/ecto/query.ex`][querymod]) and, when the bindings are static, expands
directly to the `%Query{}` value with no runtime builder. The two README examples show
both flavors ([`README.md`][readme]):

```elixir
# keyword-based
def keyword_query do
  query =
    from w in Weather,
         where: w.prcp > 0 or is_nil(w.prcp),
         select: w

  Repo.all(query)
end

# pipe-based — equivalent, and composable clause-by-clause
def pipe_query do
  Weather
  |> where(city: "Kraków")
  |> order_by(:temp_lo)
  |> limit(10)
  |> Repo.all
end
```

Nothing hits the database while a query is being built; a query is inert data _"until
they are passed as arguments to a function from `Ecto.Repo`"_
([`lib/ecto/query.ex`][querymod]). Queries are also **composable**: any value
implementing the `Ecto.Queryable` protocol (a schema atom, a table string, or another
`Ecto.Query`) may sit on the right of `in`, so refinements chain freely
([`lib/ecto/queryable.ex`][queryable]).

**The `^` pin operator is the injection-safety mechanism.** Query macros treat literals
as query structure; every _runtime_ value must be pinned with `^`, which marks it as a
**bound parameter** rather than SQL text ([`lib/ecto/query.ex`][querymod]):

> _"External values and Elixir expressions can be injected into a query expression with
> `^`"_

```elixir
def with_minimum(age, height_ft) do
  from u in "users",
    where: u.age > ^age and u.height > ^(height_ft * 3.28),
    select: u.name
end
```

The pinned expressions become positional parameters carried in the query struct's
`params`, transferred to the server [out-of-band][inject] — so a hostile `age` can
never change the query's shape. Ecto layers a second guard on top: comparing a column
to a pinned value that turns out to be `nil` is _forbidden_, precisely as an
injection-adjacent defense ([`lib/ecto/query.ex`][querymod]):

> _"This is done as a security measure to avoid attacks that attempt to traverse
> entries with nil columns."_

You write `is_nil(u.age)` instead. When a schema is present, Ecto additionally **casts**
the pinned value to the column's declared type, so `^age` compared to an `:integer`
field is coerced (raising `Ecto.Query.CastError` if it cannot be)
([`lib/ecto/query.ex`][querymod]).

**`fragment/1` is the raw-SQL escape hatch — and it stays parameterized.** When the DSL
cannot express something, `fragment` splices raw SQL, but interpolation still goes
through bind parameters ([`lib/ecto/query/api.ex`][queryapi]):

> _"Send fragments directly to the database. … Every occurrence of the `?` character
> will be interpreted as a place for parameters, which must be given as additional
> arguments to `fragment`."_

```elixir
from p in Post,
  where: is_nil(p.published_at) and
         fragment("lower(?)", p.title) == ^title
```

The `?` placeholders in a `fragment` are parameters, not string holes, so the escape
hatch does **not** re-open injection for _values_. The genuinely unsafe door is narrow
and loudly labelled: `unsafe_fragment/1` (used for dynamic query hints) is the one
construct that concatenates text verbatim, and its docs carry an explicit warning
([`lib/ecto/query.ex`][querymod]):

> _"The output of `unsafe_fragment/1` will be injected directly into the resulting SQL
> statement without being escaped. For this reason, input from uncontrolled sources,
> such as user input, should **never** be used. Otherwise, it could lead to harmful SQL
> injection attacks."_

By construction, then, Ecto's safety story is "parameters by default, and the raw hatch
is loud and rare" — the same posture as the [tagged-template][qcm] and [quoted-DSL][qcm]
families, achieved through macro expansion rather than templates.

## Schema, migrations & code generation

Ecto is **code-first**, but with an unusually loose grip on the schema. `Ecto.Schema`
_"maps external data into Elixir structs"_ via the `schema/2` macro, whose first
argument is the source table name ([`lib/ecto/schema.ex`][schemamod]):

```elixir
defmodule User do
  use Ecto.Schema

  schema "users" do
    field :name, :string
    field :age, :integer, default: 0
    field :password, :string, redact: true
    has_many :posts, Post
  end
end
```

`schema/2` generates a plain struct with the declared fields plus a `__meta__` field
tracking whether the row is `:built`, `:loaded`, or `:deleted`
([`lib/ecto/schema.ex`][schemamod]). Associations are declared with `has_many` /
`belongs_to` / `has_one` and are the anchors for explicit `preload`. `embedded_schema/1`
defines the same shape for in-memory / embedded data with no table and no `__meta__` —
useful for validating a form payload you never persist.

The schema is **optional**: a query against a bare `"users"` string returns maps, and
`Repo.insert_all` / `Repo.all` work schemalessly ([`lib/ecto.ex`][ectomod]). This is
unlike the [typed relational algebra][qcm] libraries where a schema type is load-bearing
for compile-time checking; in Ecto the schema mainly buys automatic casting and default
`select` of all fields.

**Migrations are not in this repo.** Core `ecto` is adapter-agnostic and ships no DDL /
[migration runner][schema]; that lives in the companion `ecto_sql` project, where
`Ecto.Adapters.SQL` provides _"the ability to version how your database changes through
time via database migrations"_ ([`lib/ecto.ex`][ectomod]). This split — a pure
data-mapping core, a SQL-specific migration/DDL layer bolted on — is itself a finding:
the abstraction boundary lands _below_ schema versioning. There is **no
[introspection / db-first code generation][schema]**: Ecto does not scaffold schemas from
a live database (contrast `jOOQ`/`sqlc`); the Elixir schema is the source of truth for
mapping, and the migrations (in `ecto_sql`) are hand-written, not derived from the
schema modules.

## Type mapping & result decoding

Type mapping runs on two levels: a per-type codec protocol, and — the distinctive part
— the `Changeset` as an explicit casting/validation value.

**Codecs: `Ecto.Type`.** A custom type maps between three representations —
_external_, _internal_, and _database_ — through the `cast/1`, `dump/1`, and `load/1`
callbacks ([`lib/ecto/type.ex`][typemod]): `cast` moves external → internal,
`dump` internal → database, `load` database → internal. The adapter contributes the
final leg via `loaders/2` and `dumpers/2`, translating adapter-native cells into Ecto
values (e.g. decoding `0`/`1` into booleans) ([`lib/ecto/adapter.ex`][adaptermod]).
Row **hydration** is by schema: a `Repo.all(User)` loads each row into a `%User{}`
struct with fields decoded to their declared types; a schemaless query hydrates into a
map. **Nullability** is Elixir `nil` — there is no `Option`/`Maybe` wrapper type — which
is why the `nil`-comparison guard above exists at the query layer.

**Changesets: casting + validation + change tracking as an explicit value.** This is
Ecto's signature idea. An `Ecto.Changeset` is a standalone data structure, built and
piped through validators, and only _then_ handed to a `Repo` write
([`lib/ecto/changeset.ex`][changesetmod]):

> _"Changesets allow filtering, type casting, validation, and constraints when
> manipulating structs, usually in preparation for inserting and updating entries into a
> database."_

Its "filtering" role is a security boundary in itself — you must _explicitly_ allowlist
the fields you accept ([`lib/ecto/changeset.ex`][changesetmod]): _"you must explicitly
list which data you accept. For example, you most likely don't want to allow a user to
set its own `is_admin` field to true"_. A canonical changeset pipeline
([`lib/ecto.ex`][ectomod]):

```elixir
def changeset(user, params \\ %{}) do
  user
  |> cast(params, [:name, :email, :age])          # filter + type-cast external params
  |> validate_required([:name, :email])           # validate only the changed fields
  |> validate_format(:email, ~r/@/)
  |> validate_inclusion(:age, 18..100)
  |> unique_constraint(:email)                     # DB-enforced, turned into an error
end
```

The `%Ecto.Changeset{}` struct makes the tracking explicit: `changes` holds _"the
`changes` from parameters that were approved in casting"_, `errors` holds validation
failures, `valid?` a boolean, and `data` the source struct
([`lib/ecto/changeset.ex`][changesetmod]). Two entry points separate the concerns —
`cast/4` for **external** (string-keyed) data from a form/API/CLI, and `change/2` for
**internal**, already-typed data ([`lib/ecto/changeset.ex`][changesetmod]). Validators
run in-process on the changeset's current changes; **constraints** (unique index,
foreign key) are deferred to the database and _"transformed"_ into changeset errors on a
failed write ([`lib/ecto.ex`][ectomod]), giving _"a safe, correct and data-race free
means of checking the user input"_ ([`lib/ecto/changeset.ex`][changesetmod]). Because a
changeset is a plain value, different use cases get different changesets
(`registration_changeset`, `update_changeset`) over the same schema — the composability
a monolithic ORM validation hook cannot offer.

Note the survey angle: Elixir has no static types, so "typed persistence" here is
**runtime** schema-cast + changeset validation, not the compile-time type-checking of
`Diesel` / `Slick`. The `Changeset` is where the "type discipline" actually lives, and
it is a value you can test in isolation without a database.

## Effect model, transactions & error handling

Ecto's effect model is the axis on which it most differs from the effect-system SQL
libraries this survey weights heavily.

**Blocking, eager, tagged-tuple — not an effect value.** A `Repo` call runs
_now_ and blocks the calling process until the row arrives; it returns an ordinary
value, not a description of work. There is no `IO`/`ZIO`/`Effect`/`ConnectionIO`
wrapper ([effect-typed APIs][effects] in the survey's sense). What substitutes for both
"async" and "typed errors" is (a) the BEAM's cheap processes — a blocking DB call parks
one lightweight process, so concurrency is structural rather than monadic — and (b) the
**tagged-tuple** convention: fallible operations return `{:ok, value}` or
`{:error, reason}`. `Repo.insert/2` _"returns `{:ok, struct}` … or `{:error, changeset}`
if there was a validation or a known constraint error"_ ([`lib/ecto/repo.ex`][repomod]),
so the failure carries the annotated changeset back for re-rendering:

```elixir
case Repo.update(changeset) do
  {:ok, user}         -> # user updated
  {:error, changeset} -> # changeset.errors explains what failed
end
```

This is a _convention_, not a type-level [error channel][effects]: unknown/adapter
failures (a dropped connection, a `Postgrex.Error`) are raised as exceptions, not
returned in the tuple ([`lib/ecto/repo.ex`][repomod]).

**Transactions: a function or an `Ecto.Multi`.** `Repo.transact/2` (the successor to the
now-deprecated `Repo.transaction/2`) wraps a block; the block's own `{:ok, _}` /
`{:error, _}` decides commit vs rollback ([`lib/ecto/repo.ex`][repomod]):

> _"The return value is the same as of the given `fun` which must be `{:ok, result}` or
> `{:error, reason}`. … If this function returns `{:ok, result}`, it means the
> transaction was successfully committed. On the other hand, if it returns
> `{:error, reason}`, it means the transaction was rolled back."_

It pairs idiomatically with Elixir's `with/1` for short-circuiting a sequence of
`{:ok, _}` steps, and an explicit `Repo.rollback/1` aborts and returns `{:error, value}`
([`lib/ecto/repo.ex`][repomod]). **Nesting** is flattened: a `transact` inside a
`transact` _"is simply executed, without wrapping the new transaction call in any way"_,
and an inner rollback aborts the whole outer transaction ([`lib/ecto/repo.ex`][repomod])
— so there is a single `BEGIN`, not nested `BEGIN`s. [Savepoints][effects] are opt-in
per operation: `Repo.insert(changeset, mode: :savepoint)` wraps that statement in a
savepoint so a constraint failure rolls back to it instead of poisoning the whole
transaction ([`lib/ecto/repo.ex`][repomod]).

**`Ecto.Multi`: composable multi-operation transactions.** For a _dynamic_ set of
operations, `Multi` is a value you build and then run
([`lib/ecto/multi.ex`][multimod]):

> _"`Ecto.Multi` is a data structure for grouping multiple Repo operations. `Ecto.Multi`
> makes it possible to pack operations that should be performed in a single database
> transaction and provides a way to introspect the queued operations without actually
> performing them."_

```elixir
Multi.new()
|> Multi.update(:account, Account.password_reset_changeset(account, params))
|> Multi.insert(:log, Log.password_reset_changeset(account, params))
|> Multi.delete_all(:sessions, Ecto.assoc(account, :sessions))
|> Repo.transact()
```

Each step is named; changesets are validated _before_ the transaction starts, so an
invalid changeset short-circuits without a `BEGIN` ([`lib/ecto/multi.ex`][multimod]). On
success you get `{:ok, %{account: …, log: …, sessions: …}}`; on failure
`{:error, failed_operation, failed_value, changes_so_far}` — the named step that failed,
its value, and the results accrued so far (all rolled back)
([`lib/ecto/multi.ex`][multimod]). Because a `Multi` is inert data, you can unit-test the
plan via `Ecto.Multi.to_list/1` without touching a database
([`lib/ecto/multi.ex`][multimod]). This is Ecto's answer to the [unit of work][orm]: an
_explicit, inspectable_ transaction script instead of an implicit flush.

The adapter boundary underneath is small — `Ecto.Adapter` _"Specifies the minimal API
required from adapters"_ ([`lib/ecto/adapter.ex`][adaptermod]), split into focused
behaviours `Ecto.Adapter.Queryable`, `.Schema`, `.Transaction`, and `.Storage`. The
`Transaction` behaviour's own contract mirrors the tuple convention: `transaction/3`
returns _"`{:ok, value}` if the transaction was successful … or `{:error, value}` if the
transaction was rolled back"_ ([`lib/ecto/adapter/transaction.ex`][txadapter]).

## Ecosystem & maturity

Ecto is the de-facto database layer of the Elixir world and the default persistence
choice for the Phoenix web framework (web-attested). It is licensed **Apache-2.0**
([`LICENSE.md`][repo]) and maintained by Dashbit (José Valim et al.; `mix.exs`
maintainers list Eric Meadows-Jönsson, José Valim, Felipe Stival, Greg Rychlewski). The
API has been **stable since 3.0** — the README states _"With version 3.0, Ecto API has
become stable. Our main focus is on providing bug fixes and incremental changes"_
([`README.md`][readme]); the pinned tree is `3.14.1` (2026-07-09,
[`CHANGELOG.md`][changelog]). First release dates to ≈2013 (repo copyright 2013
Plataformatec; web-attested).

Backends are reached through **adapters**, most via the `ecto_sql` project plus a
driver: `Ecto.Adapters.Postgres` (postgrex), `Ecto.Adapters.MyXQL` (MySQL),
`Ecto.Adapters.Tds` (MSSQL), `Ecto.Adapters.SQLite3`, `Ecto.Adapters.ClickHouse`, and
even non-SQL stores like ETS (`Etso`) ([`README.md`][readme]). The core `ecto` package
depends only on `telemetry`, `decimal`, and optional `jason` ([`mix.exs`][mix]) — it is
deliberately free of any database driver, underscoring that Ecto is a data-mapping
toolkit first and a SQL client only through `ecto_sql`.

## Strengths

- **Explicit persistence, no surprises.** No lazy loading, no identity map, no implicit
  flush; associations are `NotLoaded` until `preload`, so [N+1][nplusone] is a visible
  decision, not a hidden foot-gun ([`lib/ecto.ex`][ectomod]).
- **Changesets are the killer feature.** Casting + validation + change tracking as a
  composable, testable value _decoupled from the database_ — different changesets per use
  case over one schema; DB constraints fold back into changeset errors.
- **Injection-safe by construction.** The `^` pin marks every runtime value as a bound
  parameter; even `fragment` interpolation is parameterized; the one unsafe door is
  loudly labelled ([`lib/ecto/query.ex`][querymod]).
- **Composable, inspectable queries and transactions.** Queries are inert `%Query{}`
  data extended clause-by-clause; `Ecto.Multi` is an inspectable transaction script you
  can unit-test without a DB.
- **Schema-optional.** Query bare tables and get maps; a schema buys casting and default
  selects but is never required.
- **BEAM-native lifetime.** The repo is a supervised process; pooling and fault-recovery
  ride on OTP, not on manual resource management.

## Weaknesses

- **No effect value / no type-level error channel.** Repo calls are eager and blocking;
  the `{:ok, _}` / `{:error, _}` convention is not enforced by types, and adapter
  failures still throw ([`lib/ecto/repo.ex`][repomod]). Contrast the effect-system
  libraries ([doobie][doobie], [Effect TS][effectts]) that carry the error set in the type.
- **No compile-time query typing.** Elixir has no static types, so a column typo or a
  shape mismatch surfaces at runtime, not at compile time — unlike `Diesel` /
  [Slick][slick] / `Squeal`.
- **Migrations / DDL live outside core.** Schema versioning is in `ecto_sql`, and there
  is no db-first [introspection codegen][schema]; the split is a boundary you must know.
- **Macro learning curve.** The keyword vs pipe duality, positional/named bindings, and
  the `^`-everywhere rule are unusual; pinning is easy to forget (though the compiler
  usually catches it).
- **Changeset ceremony for simple cases.** Every write ideally goes through a changeset;
  small scripts feel heavier than an Active-Record `save`.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                           | Trade-off                                                                                                       |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Four decoupled components (Repo / Schema / Query / Changeset) | Small, single-purpose, composable pieces; data (struct) separate from storage (repo)                | More moving parts than a monolithic ORM object; the developer wires them together                               |
| Query DSL as **compile-time macros** → `%Ecto.Query{}` AST    | "Language integrated query" with Elixir syntax; injection-safe; queries are inert composable data   | Restricted to what the macros can see; `^` pin required for every runtime value; macro learning curve           |
| `^` pin = bound parameter; `fragment` `?` also parameterized  | Injection impossible for values; escape hatch stays safe; one loud `unsafe_fragment` door           | Verbose (`^` everywhere); forgetting a pin is a (usually compile-caught) error                                  |
| **No lazy loading**; associations via explicit `preload`      | Makes [N+1][nplusone] a visible decision; no hidden queries                                         | The developer must remember to `preload`; a missing preload is an obvious `NotLoaded`, not a silent extra query |
| **Changeset**, not mutable self-persisting entity             | Casting/validation/tracking as a testable value, separate from persistence; per-use-case changesets | Ceremony for trivial writes; two APIs (`cast` vs `change`) to keep straight                                     |
| No identity map, no implicit unit of work                     | Predictable, race-free persistence; explicit `Repo.insert`/`transact`/`Multi`                       | No automatic minimal-diff flush; batching multi-entity writes is manual (`Ecto.Multi`)                          |
| Blocking, eager, tagged-tuple returns (not an effect monad)   | Simple mental model; leans on cheap BEAM processes for concurrency; `with/1` for happy-path chains  | No type-level error channel; adapter failures throw; harder to reason about than a typed effect value           |
| Adapter-agnostic core; SQL/migrations in `ecto_sql`           | Ecto maps _any_ data source, not only SQL; small dependency-free core                               | Migration/DDL story is a separate package; no db-first codegen                                                  |

---

## Sources

- [elixir-ecto/ecto — GitHub repository][repo] · [hexdocs.pm/ecto][docs]
- [`lib/ecto.ex` — the four components, "does not lazy load", struct/storage decoupling, associations & `preload`][ectomod]
- [`lib/ecto/query.ex` — Query DSL moduledoc: keyword vs macro flavors, `^` interpolation, `nil`-comparison guard, `from/2` compile-time macro, `unsafe_fragment` warning][querymod]
- [`lib/ecto/query/api.ex` — `fragment/1`: `?` placeholders as parameters][queryapi]
- [`lib/ecto/queryable.ex` — the `Ecto.Queryable` protocol (schema atom / table string / query)][queryable]
- [`lib/ecto/changeset.ex` — Changeset moduledoc: filter/cast/validate/constraints; the `%Changeset{}` struct fields][changesetmod]
- [`lib/ecto/schema.ex` — `schema/2` / `embedded_schema/1`; code-first mapping][schemamod]
- [`lib/ecto/type.ex` — `cast`/`dump`/`load` external↔internal↔database mapping][typemod]
- [`lib/ecto/repo.ex` — Repo behaviour: `all`/`get`/`insert`/`update`/`preload`/`transact`; tagged tuples, nested transactions, `mode: :savepoint`][repomod]
- [`lib/ecto/multi.ex` — `Ecto.Multi` composable transactions][multimod]
- [`lib/ecto/adapter.ex` + `lib/ecto/adapter/transaction.ex` — the minimal adapter API and transaction contract][adaptermod]
- [`README.md` — keyword/pipe examples, adapters table, "stable since 3.0"][readme] · [`mix.exs` — description, license, deps][mix] · [`CHANGELOG.md` — v3.14.1][changelog]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [injection][inject] · [ORM patterns][orm] · [N+1][nplusone] · [effects & transactions][effects])
- Related deep-dives in this survey: [doobie][doobie] · [Quill][quill] · [skunk][skunk] · [Slick][slick] · [Effect TS][effectts]

<!-- References -->

[repo]: https://github.com/elixir-ecto/ecto
[docs]: https://hexdocs.pm/ecto/
[ectosqldocs]: https://hexdocs.pm/ecto_sql/
[ectomod]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto.ex
[querymod]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/query.ex
[queryapi]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/query/api.ex
[queryable]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/queryable.ex
[changesetmod]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/changeset.ex
[schemamod]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/schema.ex
[typemod]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/type.ex
[repomod]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/repo.ex
[multimod]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/multi.ex
[adaptermod]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/adapter.ex
[txadapter]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/lib/ecto/adapter/transaction.ex
[readme]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/README.md
[mix]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/mix.exs
[changelog]: https://github.com/elixir-ecto/ecto/blob/e0aa6e1b453f1c454f2810965eb34c5926fc8472/CHANGELOG.md
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[schema]: ./concepts.md#schema-migrations-code-generation
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions
[doobie]: ./doobie.md
[quill]: ./quill.md
[skunk]: ./skunk.md
[slick]: ./slick.md
[effectts]: ./effect-ts.md

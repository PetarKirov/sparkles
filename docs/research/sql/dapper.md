# Dapper (C# / .NET)

A set of extension methods on ADO.NET's `IDbConnection` that run the raw SQL _you_ write and materialize result rows into objects fast, with automatic parameter binding — the archetypal **micro-ORM**: raw SQL + injection-safe parameters + an IL-emitted, cached row-to-object mapper, and deliberately nothing above that rung (no query generation, no schema, no change tracking).

| Field              | Value                                                                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language           | C# / .NET (targets `net461`, `netstandard2.0`, `net8.0`, `net10.0`)                                                                                    |
| License            | Apache-2.0                                                                                                                                             |
| Repository         | [DapperLib/Dapper][repo]                                                                                                                               |
| Documentation      | [dapperlib.github.io/Dapper][docs] · [`Readme.md`][readme]                                                                                             |
| Category           | [Safe-SQL / micro-mapper][concepts-ladder] — raw SQL + fast object materialization; no query DSL, no ORM                                               |
| Abstraction level  | [Safe-SQL / micro-mapper rung][concepts-ladder] — extension methods on `IDbConnection`; parameters bind automatically, rows hydrate into typed objects |
| Query model        | [Raw SQL string][concepts-models] you write, with `@name` placeholders + anonymous-object / `DynamicParameters` binding                                |
| Effect/async model | Blocking **and** `async` (`Task` / `Task<T>`); no effect value, [exception-based][concepts-effects] errors                                             |
| Backends           | Any ADO.NET provider — SQL Server, PostgreSQL, MySQL/MariaDB, SQLite, Oracle, Firebird, SQL CE                                                         |
| First release      | ≈2011 (web-attested; open-sourced out of Stack Overflow)                                                                                               |
| Latest version     | `2.1` line (the pinned tree's [`version.json`][versionjson]); NuGet `2.1.x` (web-attested)                                                             |

> [!NOTE]
> Dapper sits on the [safe-SQL / micro-mapper rung][concepts-ladder] of the abstraction
> ladder — one step above a bare [driver][concepts-ladder] (ADO.NET itself), and far below
> a full ORM. You write every SQL string; Dapper's job is only to (1) turn a plain object's
> properties into real ADO.NET parameters and (2) turn the returned columns into typed
> objects, both as fast as hand-written code. It is this survey's data point for the
> **imperative, exception-based, provider-agnostic micro-mapper** in a mainstream OO
> ecosystem — the .NET analogue of `hasql` (Haskell) and `JDBI` (Java), and the deliberate
> antithesis of the heavier .NET options `EF Core` (full ORM) and `linq2db` (LINQ query
> builder). See [concepts][concepts] for shared vocabulary.

---

## Overview

### What it solves

Dapper removes the ceremony of ADO.NET without moving up to an ORM. Raw ADO.NET makes you
create a `DbCommand`, add each `DbParameter` by hand, call `ExecuteReader`, loop the
`DbDataReader`, and pull each column out by ordinal into a hand-written object — boilerplate
that is verbose, error-prone, and easy to get subtly wrong. Dapper collapses all of that into
one extension-method call while keeping the SQL entirely in your hands. The project's own
one-line pitch ([`docs/readme.md`][docsreadme]):

> _"Dapper is a simple micro-ORM used to simplify working with ADO.NET; if you like SQL but
> dislike the boilerplate of ADO.NET: Dapper is for you!"_

The `Readme.md` states the shape of the library precisely — it is a bag of extension methods,
not a framework you inherit from ([`Readme.md`][readme]):

> _"Dapper is a NuGet library that you can add in to your project that will enhance your
> ADO.NET connections via extension methods on your `DbConnection` instance. This provides a
> simple and efficient API for invoking SQL, with support for both synchronous and
> asynchronous data access, and allows both buffered and non-buffered queries."_

The whole public surface is a `static partial class SqlMapper` whose methods extend
`IDbConnection` ([`SqlMapper.cs`][sqlmapper]); the three load-bearing ones, from the
`Readme.md` ([`Readme.md`][readme]):

```csharp
// insert/update/delete etc
var count  = connection.Execute(sql [, args]);

// multi-row query
IEnumerable<T> rows = connection.Query<T>(sql [, args]);

// single-row query ({Single|First}[OrDefault])
T row = connection.QuerySingle<T>(sql [, args]);
```

`ExecuteScalar<T>` (first cell), `QueryMultiple` (several result grids), and their `…Async`
twins round the set out. Everything hangs off an existing, caller-owned `IDbConnection`; the
connection object is `this`, never something Dapper constructs.

### Design philosophy

Three properties define Dapper, each visible in its own metadata and docs.

**It is a _mapper_, not an ORM — "simple" and "light weight" are load-bearing words.** The
`Readme.md` title is _"Dapper - a simple object mapper for .Net"_ ([`Readme.md`][readme]); the
crate-level docstring calls it _"Dapper, a light weight object mapper for ADO.NET"_
([`SqlMapper.cs`][sqlmapper]); and the NuGet description positions it as _"A high performance
Micro-ORM supporting SQL Server, MySQL, Sqlite, SqlCE, Firebird etc."_
([`Dapper.csproj`][csproj]). The absence of ORM machinery is a stated feature, not a gap
([`Readme.md`][readme]):

> _"Dapper's simplicity means that many features that ORMs ship with are stripped out. It
> worries about the 95% scenario, and gives you the tools you need most of the time. It
> doesn't attempt to solve every problem."_

**Performance is the reason it exists.** Dapper came out of Stack Overflow, where it still
runs in production ([`Readme.md`][readme]): _"Dapper was originally developed for and by Stack
Overflow, but is F/OSS"_ and _"Dapper is in production use at Stack Overflow"_. The `Readme.md`
opens its benchmark section with _"A key feature of Dapper is performance"_ and shows its
`Query<T>`/`QueryFirstOrDefault<T>` mapping landing within a few microseconds of hand-coded
`SqlCommand` and well ahead of `EF Core`, `NHibernate`, and `EF 6` on the same `SELECT`. The
speed comes from compiling a per-shape materializer once and caching it (below), not from any
clever protocol work — Dapper speaks whatever ADO.NET speaks.

**Provider-agnostic by construction.** Dapper has no database-specific code; it works over any
ADO.NET provider ([`Readme.md`][readme]):

> _"Dapper has no DB specific implementation details, it works across all .NET ADO providers
> including SQLite, SQL CE, Firebird, Oracle, MariaDB, MySQL, PostgreSQL and SQL Server."_

That is the flip side of "you write the SQL": Dapper never generates or rewrites your query
for a dialect (with two small mechanical exceptions — list expansion and literal replacement,
below), so portability and correctness of the SQL itself are your responsibility.

---

## Connection, pooling & resource lifetime

Dapper owns **no** connection lifecycle. Every entry point is
`this IDbConnection cnn` — you pass a connection you already have, from whatever pool your
ADO.NET provider manages (`SqlConnection`, `NpgsqlConnection`, …). Connection pooling in .NET
lives in the provider's `DbConnection`, keyed off the connection string, and Dapper leaves it
entirely alone.

The one lifetime nicety Dapper adds is **open/close bracketing**: if it is handed a closed
connection it opens it, runs, and closes it again; if it is handed an open one it leaves it
open. In the buffered `Query<T>` path this is visible as a `wasClosed` check followed by
`if (wasClosed) cnn.Open();`, with the reader created under `CommandBehavior.CloseConnection`
so an unbuffered enumerator closes the connection when the caller finishes iterating
([`SqlMapper.cs`][sqlmapper]). There is no lease/return
abstraction, no `Scope`/`Resource`, and no [scoped acquire/release][concepts-pools] of the
kind the effect systems model — resource safety is the ADO.NET `using`-block discipline of the
caller.

`CommandDefinition` is the value that bundles _"the key aspects of a sql operation"_
([`CommandDefinition.cs`][cmddef]) — SQL text, parameters, an optional `IDbTransaction`, a
timeout, a `CommandType`, buffering flags, and a `CancellationToken`. Its `SetupCommand`
creates the `DbCommand`, applies the parameter reader, and — crucially for transactions — just
assigns `cmd.Transaction = Transaction` if one was supplied ([`CommandDefinition.cs`][cmddef]).

## Query construction & injection safety

This is Dapper's centre of gravity, and the model is: **you write raw SQL; Dapper turns your
parameter object into real ADO.NET `DbParameter`s and never interpolates a value into the SQL
text.**

**Parameters come from a plain object's properties.** You pass an anonymous type (or POCO, or
`Dictionary<string,object>`, or `DynamicParameters`) as `param`; Dapper matches each `@name`
placeholder in your SQL to a property of that object and adds a `DbParameter` for it. From the
`Readme.md` ([`Readme.md`][readme]):

> _"Parameters are usually passed in as anonymous classes. This allows you to name your
> parameters easily and gives you the ability to simply cut-and-paste SQL snippets and run them
> in your db platform's Query analyzer."_

```csharp
// Readme.md — @Age and @Id are added as DbParameters, never spliced into the text
var guid = Guid.NewGuid();
var dog = connection.Query<Dog>("select Age = @Age, Id = @Id",
                                new { Age = (int?)null, Id = guid });
```

Under the hood, Dapper IL-emits a parameter generator (`CreateParamInfoGenerator`) that, for
each property, calls `command.CreateParameter()`, sets `ParameterName`/`Value`/`DbType`, and
`command.Parameters.Add(...)` ([`SqlMapper.cs`][sqlmapper]). The value therefore travels the
ADO.NET parameter channel — a real `DbParameter` bound to a placeholder — so
[SQL injection is structurally impossible][concepts-injection] for it: the value is never SQL
text. Dapper offers **no string-interpolation API** for parameter values; there is nothing
analogous to a `sql.unsafe` splice for a value. The generator also _trims_ parameters not
mentioned in the SQL (for `CommandType.Text`), so an over-broad parameter object is harmless.

**`DynamicParameters` is the escape hatch for dynamically-assembled SQL — still parameterized.**
When you build the SQL string at runtime (variable `WHERE` predicates, stored-proc `out`
parameters), you accumulate parameters in a `DynamicParameters` bag —
_"A bag of parameters that can be passed to the Dapper Query and Execute methods"_
([`DynamicParameters.cs`][dynparams]). The `Readme.md` is explicit that this keeps you on the
safe path ([`Readme.md`][readme]):

> _"Parameters can also be built up dynamically using the DynamicParameters class. This allows
> for building a dynamic SQL statement while still using parameters for safety and
> performance."_

```csharp
// Readme.md — dynamic predicate, static safety: each branch adds a *parameter*, not text
var sqlPredicates = new List<string>();
var queryParams = new DynamicParameters();
if (boolExpression)
{
    sqlPredicates.Add("column1 = @param1");
    queryParams.Add("param1", dynamicValue1, System.Data.DbType.Guid);
}
```

`Add(string name, object? value, DbType?, ParameterDirection?, int? size, …)` also carries
direction (`Input`/`Output`/`ReturnValue`) and size, so stored procedures with output
parameters work by binding, then reading back with `p.Get<int>("@b")`
([`DynamicParameters.cs`][dynparams], [`Readme.md`][readme]).

**List expansion: `IN @ids` becomes `IN (@ids1, @ids2, @ids3)`.** A single most-loved
convenience — passing any `IEnumerable` for an `IN` clause — is a genuine SQL rewrite, but one
that _adds_ parameters rather than text ([`Readme.md`][readme]):

> _"Dapper allows you to pass in `IEnumerable<int>` and will automatically parameterize your
> query."_

```csharp
// Readme.md
connection.Query<int>("... where Id in @Ids", new { Ids = new int[] { 1, 2, 3 } });
// becomes: "... where Id in (@Ids1, @Ids2, @Ids3)"  with @Ids1=1, @Ids2=2, @Ids3=3
```

`PackListParameters` implements this: it enumerates the list, creates one `DbParameter` per
element (`@Ids1`, `@Ids2`, …), and `Regex.Replace`s the `@Ids` token in the command text with
the parenthesized parameter list; an empty list rewrites to `(SELECT @Ids WHERE 1 = 0)` so the
`IN` still parses ([`SqlMapper.cs`][sqlmapper]). Each element is a bound parameter, so the
injection guarantee holds. (The code comment records the design choice: _"initially we tried
TVP, however it performs quite poorly … SQL support up to 2000 params easily in sp_executesql"_
— [`SqlMapper.cs`][sqlmapper].)

**Literal replacement (`{=name}`) is the one value-into-text path — and it is bool/numeric
only.** For query-plan reasons you can inject a bool/numeric member _as a literal_ rather than
a parameter ([`Readme.md`][readme]): _"The literal replacement is not sent as a parameter; this
allows better plans and filtered index usage but should usually be used sparingly and after
testing."_ The mechanism (`{=member}` recognized by a regex, substituted via `Format`) refuses
anything that is not a number or boolean — `Format` throws
`NotSupportedException("The type '…' is not supported for SQL literals.")` for other types
([`SqlMapper.cs`][sqlmapper]) — so a `{=…}` token cannot carry an injection payload even though
it does reach the SQL text.

**There is no query builder and no compile-time SQL check in core.** Dapper never inspects,
validates, or generates your SQL. The optional `Dapper.SqlBuilder` package composes SQL
_fragments_ by replacing named placeholders (`/**where**/`, `/**orderby**/`) with joined
clause text ([`Dapper.SqlBuilder/SqlBuilder.cs`][sqlbuilder]) — string templating over raw
fragments, still no type checking of columns or expressions. That places Dapper firmly in the
[raw-string query model][concepts-models] — checked _never_ at compile time — the opposite end
of the axis from `jOOQ`/`Diesel` (fluent typed builder), the LINQ-to-SQL of `EF Core`/`linq2db`
(quoted DSL), or the build-time-verified raw SQL of `sqlx`/`sqlc`.

## Schema, migrations & code generation

**Dapper owns no schema, and this is a defining absence.** There is no entity/model
declaration that _is_ the schema (no [code-first][concepts-schema]), no schema file it treats
as truth (no [schema-first][concepts-schema]), no [introspection→codegen][concepts-schema] step
(the `jOOQ`/`sqlc` move), and no migration runner or DDL versioning anywhere in the tree. You
write your `CREATE TABLE`/`ALTER` as ordinary SQL and run it through `Execute` like any other
statement; ordering and bookkeeping are entirely external (a separate tool such as `FluentMigrator`
or `DbUp`, none of them Dapper's concern).

The mapping from a result column to a CLR member is **by convention, by name, at runtime** —
there is no declared schema to check it against, so a typo in a column alias or a renamed
property surfaces only when the query runs. The convention itself is configurable at exactly one
point: `DefaultTypeMap.MatchNamesWithUnderscores` — _"Should column names like User_Id be allowed
to match properties/fields like UserId ?"_ ([`DefaultTypeMap.cs`][typemap]) — an opt-in
snake-case bridge, off by default.

The satellite `Dapper.Rainbow` package layers thin CRUD helpers on top (_"Micro-ORM implemented
on Dapper, provides CRUD helpers"_, [`Readme.md`][readme]), and the community `Dapper.Contrib`
adds attribute-driven `Insert`/`Update`/`Get<T>`, but the core library stops at "run this SQL,
map these rows."

## Type mapping & result decoding

**The row-to-object materializer is IL-emitted once per shape and cached.** When you call
`Query<T>`, Dapper builds (via `System.Reflection.Emit`) a `DynamicMethod` named
`"Deserialize" + Guid` of type `Func<DbDataReader, object>` that reads each column and assigns
it to the matching property/constructor argument of `T`, then caches the delegate
([`SqlMapper.cs`][sqlmapper]). The `Query<T>` contract states the mapping rule
([`SqlMapper.cs`][sqlmapper]):

> _"if a basic type (int, string, etc) is queried then the data from the first column is
> assumed, otherwise an instance is created per row, and a direct column-name===member-name
> mapping is assumed (case insensitive)."_

Member resolution (`DefaultTypeMap.GetMember`) prefers, in order, an exact-case property, then
a case-insensitive property, then backing fields, then — if `MatchNamesWithUnderscores` — the
underscore-stripped name ([`DefaultTypeMap.cs`][typemap]). Constructor binding is supported (an
`[ExplicitConstructor]` attribute picks one), so immutable records materialize too.

**Caching is two-tier and keyed on the actual columns returned.** A top-level `_queryCache`
(`ConcurrentDictionary<Identity, CacheInfo>`) is keyed by an `Identity` = (SQL text,
`CommandType`, connection string, target `Type`, parameters `Type`, grid index, and — for
multi-map — the extra types' hash) ([`SqlMapper.Identity.cs`][identity]). The compiled
deserializer inside a `CacheInfo` is _additionally_ guarded by a **column hash** of the reader's
returned column names + types; if the columns differ from what the cached delegate was compiled
against, Dapper re-emits it ([`SqlMapper.cs`][sqlmapper]). A second `TypeDeserializerCache`
keyed per `Type` by a `DeserializerKey` (the column names + types + bounds) memoizes the emitted
`Func` across queries ([`SqlMapper.TypeDeserializerCache.cs`][desercache]). Net effect: the
expensive IL emission happens once per distinct (type, column-layout), and subsequent rows —
and subsequent queries of the same shape — reuse a straight-line delegate. The `Readme.md`
summarizes the trade-off ([`Readme.md`][readme]): _"Dapper caches information about every query
it runs, this allows it to materialize objects quickly and process parameters quickly. The
current implementation caches this information in a `ConcurrentDictionary` object."_ (With the
caveat, same page, that unparameterized SQL generated on the fly can bloat that cache.)

**Custom type mapping** plugs in through `ITypeHandler` — _"Implement this interface to perform
custom type-based parameter handling and value parsing"_, a `SetValue(IDbDataParameter, object)`
/ `Parse(Type, object)` pair ([`SqlMapper.ITypeHandler.cs`][typehandler]) — the seam that maps,
say, a `JSON` column or a value object. There is no composable [codec][concepts-types] algebra
of the kind `hasql`/`skunk` expose; a handler is an imperative pair of methods registered
globally.

**Multi-mapping (`splitOn`) hydrates a joined row into several objects.** For a `Post`-plus-its-
`User` join you name each type and supply a combining function ([`Readme.md`][readme]):

> _"Dapper allows you to map a single row to multiple objects. This is a key feature if you want
> to avoid extraneous querying and eager load associations."_

```csharp
// Readme.md
var data = connection.Query<Post, User, Post>(sql,
    (post, user) => { post.Owner = user; return post; });
```

The wide row is sliced into per-type column ranges at the `splitOn` boundary — which defaults
to the column named `Id` ([`Readme.md`][readme]): _"Dapper is able to split the returned row by
making an assumption that your Id columns are named `Id` or `id`. If your primary key is
different or you would like to split the row at a point other than `Id`, use the optional
`splitOn` parameter."_ `GenerateDeserializers` builds one materializer per slice and the map
function stitches them ([`SqlMapper.cs`][sqlmapper]). Overloads run up to seven types (plus a
`Type[]` form).

**`QueryMultiple` reads several result grids from one command.** A `GridReader` —
_"provides interfaces for reading multiple result sets from a Dapper query"_
([`SqlMapper.GridReader.cs`][gridreader]) — yields each grid in turn ([`Readme.md`][readme]):

```csharp
// Readme.md
using (var multi = connection.QueryMultiple(sql, new { id = selectedId }))
{
   var customer = multi.Read<Customer>().Single();
   var orders   = multi.Read<Order>().ToList();
}
```

**Nullability** is CLR nullability: a `NULL` cell maps to a `null` reference or a `Nullable<T>`
(`int?`), and the reader path guards `DBNull`. Because there is no described schema, nullability
is not lifted into the type system the way `sqlx`/`Kysely` do — a non-nullable `int` property
fed a `NULL` column throws at materialization time.

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and Dapper sits at the **imperative,
exception-based** end — no effect value, no typed error channel.

**Sync and async, both eager.** Every operation exists in a blocking form (`Query<T>`,
`Execute`, `ExecuteScalar<T>`) and a `Task`-returning form in the `SqlMapper.Async` partial —
`QueryAsync<T>` returns `Task<IEnumerable<T>>`, `ExecuteAsync` returns `Task<int>`, and (on
`net5.0`+) `QueryUnbufferedAsync<T>` returns `IAsyncEnumerable<T>` for streaming
([`SqlMapper.Async.cs`][async]). Both are [async in the future/`Task` sense][concepts-effects],
not an inspectable description: calling `Query<T>` _runs_ the query and returns rows (buffered
to a `List<T>` by default), and calling `QueryAsync<T>` starts it and returns a `Task`. There is
no `IO`/`ConnectionIO`/`Effect` value to compose and interpret at the edge — the contrast with
`doobie`/`skunk`/`Quill`, and even with `hasql`'s eager-but-monadic `Session`. Buffering is a
flag: _"Dapper's default behavior is to execute your SQL and buffer the entire reader on
return"_, with `buffered: false` for a lazy `IEnumerable<T>` ([`Readme.md`][readme]).

**Transactions are pure ADO.NET pass-through — Dapper adds no transaction abstraction.**

> [!IMPORTANT]
> **There is no `withTransaction`/`transaction { … }` combinator, no savepoint API, and no
> isolation-level helper in Dapper — a deliberate finding.** You obtain an `IDbTransaction` the
> ADO.NET way (`conn.BeginTransaction()`), pass it as the `transaction:` argument to each
> Dapper call, and `commit`/`rollback`/`Dispose` it yourself. The entire integration is one
> line in `CommandDefinition.SetupCommand`: `if (Transaction is not null) cmd.Transaction = Transaction;`
> ([`CommandDefinition.cs`][cmddef]). Nesting, savepoints, retry-on-serialization-
> failure, and isolation levels are the provider's `IDbTransaction`'s job, not Dapper's.
> Contrast the [nested-`withTransaction`/savepoint][concepts-effects] combinators of the effect
> systems and even `doobie`'s pluggable `Strategy`; Dapper is closer to `JDBI`/`database/sql` in
> kind — the transaction is an object you thread through, not a scope the library manages.

**Errors are exceptions.** Dapper does not model failure as a value. A SQL error, a
constraint violation, a decode mismatch, a `NULL` in a non-nullable slot — all surface as the
provider's `DbException` (SQL Server's `SqlException`, Npgsql's `PostgresException`, …) or a
Dapper `ArgumentException`/`NotSupportedException`/`InvalidOperationException`, thrown from the
call. There is no [typed error channel][concepts-effects], no `Either`/`Result`, no
`isRetryable` flag — catching a unique-violation means a `try`/`catch` on the provider
exception and inspecting its SQLSTATE/error number, the mainstream .NET idiom. This is the
exception-based pole the concepts page contrasts with the effect systems' value-typed errors.

## Ecosystem & maturity

Dapper is one of the most-deployed data-access libraries in .NET — battle-tested since it was
open-sourced out of **Stack Overflow** (where it still runs, [`Readme.md`][readme]) and authored
by Sam Saffron, Marc Gravell, and Nick Craver ([`Dapper.csproj`][csproj]). It is released under
the permissive **Apache-2.0** license ([`License.txt`][license]) and multi-targets the .NET
Framework, .NET Standard 2.0, and current .NET (`net8.0`/`net10.0`, [`Dapper.csproj`][csproj]),
so it runs essentially everywhere .NET does. Development is now community/independently
maintained under the `DapperLib` org, with **Dapper Plus** (ZZZ Projects) and **AWS** as named
sponsors ([`Readme.md`][readme]).

**Backends: any ADO.NET provider.** Because Dapper has _"no DB specific implementation details"_
([`Readme.md`][readme]), it works with SQL Server (`Microsoft.Data.SqlClient`), PostgreSQL
(`Npgsql`), MySQL/MariaDB, SQLite, Oracle, Firebird, and SQL CE — anything exposing
`DbConnection`. There is no dialect layer, because there is no SQL generation: dialect
differences live in the SQL _you_ write.

**The Dapper family** is a set of separately-versioned NuGet packages around the core
([`Readme.md`][readme]): `Dapper` (core), `Dapper.EntityFramework` (EF type handlers),
`Dapper.Rainbow` (CRUD helpers), and `Dapper.SqlBuilder` (dynamic fragment composition), plus
`Dapper.StrongName` (signed build). The out-of-repo `Dapper.Contrib` and the commercial
`Dapper Plus` add active-record-style CRUD and bulk operations on top.

---

## Strengths

- **Minimal, near-zero abstraction cost.** Extension methods on a connection you already own;
  no context object, no session, no configuration graph — add the package and call `Query<T>`.
- **Fast.** An IL-emitted, per-shape, cached materializer and parameter generator put mapping
  within microseconds of hand-written `SqlCommand` on the project's own benchmarks — well ahead
  of `EF Core`/`NHibernate`.
- **Injection-safe by default.** Parameter values become real ADO.NET `DbParameter`s and are
  never spliced into SQL text; the only value-into-text path (`{=…}`) is bool/numeric-only.
- **Provider-agnostic.** Works over any ADO.NET backend with no dialect layer, because it
  generates no SQL.
- **You keep full SQL control.** Any query the database supports — CTEs, window functions,
  hints, vendor extensions — runs verbatim; nothing is hidden behind a query builder.
- **Rich mapping for a micro-ORM.** Multi-mapping (`splitOn`), multiple result grids
  (`QueryMultiple`), list expansion, stored procs with output params, custom `ITypeHandler`s,
  and per-row type switching (`GetRowParser`).
- **Sync and async** across the whole surface, with buffered/unbuffered and `IAsyncEnumerable`
  streaming.

## Weaknesses

- **No compile-time SQL checking.** SQL is opaque text; a bad column name, type mismatch, or
  renamed property is discovered at runtime, not by the compiler — the price of the
  [raw-string model][concepts-models] (no `sqlx`/`sqlc`-style build-time verification, no
  typed builder).
- **You own all the SQL and the schema.** No query generation, no dialect portability, no
  migrations, no code generation — Dapper does nothing above map+bind.
- **No change tracking, identity map, or unit of work.** Updates mean writing the `UPDATE`
  yourself; there is no dirty-state detection or `SaveChanges`. (A feature for control, a cost
  for CRUD-heavy apps — where `EF Core` earns its keep.)
- **No transaction abstraction.** Transactions, savepoints, isolation, and retry are the raw
  ADO.NET `IDbTransaction` threaded through calls; nothing composes them.
- **Exception-based errors.** No typed/value error channel and no retryability metadata; failure
  handling is `try`/`catch` on provider exceptions.
- **Reflection.Emit at the core.** The IL materializer needs a JIT — a friction point for
  fully AOT/trimmed or reflection-restricted targets — and the query cache can grow under
  on-the-fly unparameterized SQL.
- **Mapping is by-name convention.** Column↔member matching is stringly-typed and case-folded;
  the only knob is underscore matching. No declared, checkable mapping.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                  | Trade-off                                                                                                |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| **Extension methods on `IDbConnection`**, not a context/session type | Zero setup; drops into any existing ADO.NET code; the caller owns the connection & pool    | No place to hang lifecycle/config; pooling, open/close, and transactions stay the caller's problem       |
| **Raw SQL you write**, no query generation or builder in core        | Full SQL power; provider-agnostic (no dialect layer); trivially portable snippets          | No compile-time column/type checking; SQL portability and correctness are on you                         |
| **Parameters via plain-object properties → real `DbParameter`s**     | Injection-safe by default; ergonomic (anonymous types); no bind ceremony                   | Binding is by-name and reflective; ValueTuples can't be parameters (no member names)                     |
| **List expansion + `{=…}` literals** as the only SQL rewrites        | Ergonomic `IN` clauses and plan-friendly literals without leaving the safe path            | Regex rewriting of your text; `{=…}` reaches SQL (bool/numeric only, so still injection-safe)            |
| **IL-emitted, cached per-(type, columns) materializer**              | Mapping speed near hand-written ADO.NET; cost amortized across rows and repeat queries     | Needs `Reflection.Emit`/JIT (AOT/trimming friction); cache can bloat under generated unparameterized SQL |
| **No schema / migrations / change tracking / identity map**          | Stays a mapper, not an ORM — "the 95% scenario"; predictable, no hidden queries or flushes | You hand-write all DML/DDL and updates; no dirty tracking, no `SaveChanges`, no relation navigation      |
| **Transactions = ADO.NET `IDbTransaction` pass-through**             | Nothing to learn beyond ADO.NET; provider owns nesting/savepoints/isolation                | No composable transaction combinator, savepoints, retry, or isolation helper in the library              |
| **Blocking + `Task` async, eager (no effect value)**                 | Familiar imperative model; matches mainstream .NET; async everywhere                       | Not an inspectable/deferred effect; no environment/error tracked in the type                             |
| **Exception-based error handling**                                   | Idiomatic .NET; provider exceptions carry SQLSTATE/error codes                             | No typed/value error channel, no `isRetryable`; failure handling is `try`/`catch`                        |

---

## Sources

- [DapperLib/Dapper — GitHub repository][repo] · [official docs site][docs]
- [`Readme.md` — positioning, `Execute`/`Query<T>`/`QuerySingle<T>` API, anonymous-object & `DynamicParameters` binding, `IN`-list expansion, literal replacement, buffered/unbuffered, multi-mapping + `splitOn`, `QueryMultiple`, stored procs, provider list, Stack Overflow origin, "95% scenario"][readme]
- [`docs/readme.md` — "a simple micro-ORM used to simplify working with ADO.NET"][docsreadme]
- [`Dapper.csproj` — "A high performance Micro-ORM…", `orm;sql;micro-orm` tags, authors, target frameworks][csproj]
- [`License.txt` — Apache-2.0][license] · [`version.json` — `2.1` line][versionjson]
- [`Dapper/SqlMapper.cs` — `static partial class SqlMapper`, extension methods, `CreateParamInfoGenerator` (IL parameter emit), `PackListParameters` (list expansion), `Format`/`ReplaceLiterals` (bool/numeric literals), `GetTypeDeserializerImpl` (IL materializer), `_queryCache`/column-hash guard, multi-map `GenerateDeserializers`][sqlmapper]
- [`Dapper/SqlMapper.Async.cs` — `QueryAsync<T>` → `Task<IEnumerable<T>>`, `QueryUnbufferedAsync<T>` → `IAsyncEnumerable<T>`][async]
- [`Dapper/DynamicParameters.cs` — "A bag of parameters…", `Add`/`AddDynamicParams`, direction/size][dynparams]
- [`Dapper/CommandDefinition.cs` — "the key aspects of a sql operation", `SetupCommand` (`cmd.Transaction = Transaction`)][cmddef]
- [`Dapper/SqlMapper.Identity.cs` — cache key = (SQL, `CommandType`, connection string, `Type`, params `Type`, grid index, types-hash)][identity]
- [`Dapper/SqlMapper.TypeDeserializerCache.cs` — per-`Type` cache keyed by column names + types][desercache]
- [`Dapper/DefaultTypeMap.cs` — by-name member resolution, `MatchNamesWithUnderscores`][typemap]
- [`Dapper/SqlMapper.ITypeHandler.cs` — custom `SetValue`/`Parse` handlers][typehandler] · [`Dapper/SqlMapper.GridReader.cs` — multi-result-set reader][gridreader]
- [`Dapper.SqlBuilder/SqlBuilder.cs` — dynamic fragment composition (`/**where**/` templating)][sqlbuilder]
- Shared vocabulary: [concepts & vocabulary][concepts] · [the abstraction ladder][concepts-ladder] · [query construction models][concepts-models] · [statements, parameters & injection][concepts-injection] · [type mapping & result decoding][concepts-types] · [effects, transactions & error handling][concepts-effects]

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
[repo]: https://github.com/DapperLib/Dapper
[docs]: https://dapperlib.github.io/Dapper/
[readme]: https://github.com/DapperLib/Dapper/blob/main/Readme.md
[docsreadme]: https://github.com/DapperLib/Dapper/blob/main/docs/readme.md
[csproj]: https://github.com/DapperLib/Dapper/blob/main/Dapper/Dapper.csproj
[license]: https://github.com/DapperLib/Dapper/blob/main/License.txt
[versionjson]: https://github.com/DapperLib/Dapper/blob/main/version.json
[sqlmapper]: https://github.com/DapperLib/Dapper/blob/main/Dapper/SqlMapper.cs
[async]: https://github.com/DapperLib/Dapper/blob/main/Dapper/SqlMapper.Async.cs
[dynparams]: https://github.com/DapperLib/Dapper/blob/main/Dapper/DynamicParameters.cs
[cmddef]: https://github.com/DapperLib/Dapper/blob/main/Dapper/CommandDefinition.cs
[identity]: https://github.com/DapperLib/Dapper/blob/main/Dapper/SqlMapper.Identity.cs
[desercache]: https://github.com/DapperLib/Dapper/blob/main/Dapper/SqlMapper.TypeDeserializerCache.cs
[typemap]: https://github.com/DapperLib/Dapper/blob/main/Dapper/DefaultTypeMap.cs
[typehandler]: https://github.com/DapperLib/Dapper/blob/main/Dapper/SqlMapper.ITypeHandler.cs
[gridreader]: https://github.com/DapperLib/Dapper/blob/main/Dapper/SqlMapper.GridReader.cs
[sqlbuilder]: https://github.com/DapperLib/Dapper/blob/main/Dapper.SqlBuilder/SqlBuilder.cs

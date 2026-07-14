# linq2db (.NET)

A fast, thin **LINQ-to-database** provider for .NET: you write ordinary C# LINQ (`from p in db.Product where p.ProductID > 25 select p`), and linq2db reifies the C# **expression tree** into a SQL AST and renders it to dialect-specific SQL — staying one rung above a micro-mapper like `Dapper` and deliberately below a full ORM like `EF Core` (no change tracking, no identity map, no unit of work).

| Field              | Value                                                                                                                                                                                         |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | C# / .NET (also F#-friendly via the `LinqToDB.FSharp` project)                                                                                                                                |
| License            | MIT — [`MIT-LICENSE.txt`][license], © 2026 Igor Tkachev, Ilya Chudin, Svyatoslav Danyliv, Dmitry Lukashenko, and others                                                                       |
| Repository         | [linq2db/linq2db][repo]                                                                                                                                                                       |
| Documentation      | [linq2db.github.io][docs] · [NuGet `linq2db`][nuget]                                                                                                                                          |
| Category           | [Typed query builder][ladder] / thin LINQ provider — explicitly **not** a full ORM                                                                                                            |
| Abstraction level  | Typed query builder — one rung above the `Dapper`/`PetaPoco` micro-mapper, below `EF Core` ([ladder][ladder])                                                                                 |
| Query model        | [LINQ][qmodels] — C# expression trees translated at runtime to a SQL AST, then to dialect SQL                                                                                                 |
| Effect/async model | **Async** (`Task<T>` / `IAsyncEnumerable<T>`) **and** synchronous; errors are thrown exceptions, not a typed channel                                                                          |
| Backends           | SQL Server, PostgreSQL, MySQL/MariaDB, SQLite, Oracle, DB2 (LUW/z-OS), Firebird, Sybase ASE, Informix, SAP HANA, ClickHouse, DuckDB, Access, SQL CE, YDB ([`DataProvider/`][dataproviderdir]) |
| First release      | ≈2013 (descends from BLToolkit) — web-attested                                                                                                                                                |
| Latest version     | `6.4.0` (in-tree [`Directory.Build.props`][buildprops])                                                                                                                                       |

> [!NOTE]
> linq2db is this survey's data point for a **LINQ provider that is a typed query builder, not an
> ORM**. Where `EF Core` sits on the same [LINQ][qmodels] query model but adds a full
> [unit-of-work / change-tracking][ormpatterns] layer, linq2db keeps LINQ purely as a _SQL
> construction_ mechanism and leaves persistence explicit. On the query axis it is the .NET
> cousin of `Quill`'s compile-time quotation (both reify a host-language expression to an AST
> before SQL), but linq2db reifies and translates the expression tree **at runtime**. Compare with
> `EF Core` (heavier, change-tracked) and `Dapper` (raw SQL, no query generation).

---

## Overview

### What it solves

linq2db occupies the narrow band between a micro-mapper that only hydrates rows from raw SQL and a
full ORM that owns your object graph. You get LINQ — compiler-checked, refactorable — as the query
surface, but nothing above it: no session, no dirty-checking, no lazy proxies. The README fixes the
position in one line ([`README.md`][readme]):

> _"Architecturally it is one step above micro-ORMs like Dapper, Massive, or PetaPoco, in that you
> work with LINQ expressions, not with magic strings, while maintaining a thin abstraction layer
> between your code and the database. Your queries are checked by the C# compiler and allow for easy
> refactoring."_

The upper boundary is drawn just as explicitly ([`README.md`][readme]):

> _"However, it's not as heavy as LINQ to SQL or Entity Framework. There is no change-tracking, so
> you have to manage that yourself, but on the positive side you get more control and faster access
> to your data."_

The whole design compresses to the README's own slogan — _"In other words **LINQ to DB is type-safe
SQL**"_ ([`README.md`][readme]) — and the package description restates it as infrastructure
([`LinqToDB.csproj`][csproj]): _"LINQ to DB is a data access technology that provides a run-time
infrastructure for managing relational data as objects."_

### Design philosophy

Three commitments define linq2db, and each is a deliberate _absence_ relative to a full ORM.

**LINQ is a SQL-construction language, not an abstraction over objects.** A query reads like a
collection transformation, but every clause is captured as an expression tree and turned into SQL;
the library never pretends the database is an in-memory graph. The canonical query from the README
([`README.md`][readme]):

```csharp
// linq2db: README.md
public static List<Product> GetProducts()
{
  using var db = new DbNorthwind();

  var query = from p in db.Product
                where p.ProductID > 25
                orderby p.Name descending
                select p;

  return query.ToList();
}
```

**No change tracking, no identity map, no implicit unit of work.** Persistence is a set of _explicit_
verbs — `Insert`, `Update`, `Delete`, `InsertOrReplace`, `Merge`, `BulkCopy` — that you call yourself
(see [Effect model, transactions & error handling](#effect-model-transactions-error-handling)). There
is no `SaveChanges`-style flush that diff-computes SQL from a mutated graph; the headline benefit the
README names is _"more control and faster access to your data"_ ([`README.md`][readme]).

**Speed is the stated raison d'être.** The very first sentence of the README is a performance claim
([`README.md`][readme]): _"LINQ to DB is the fastest LINQ database access library offering a simple,
light, fast, and type-safe layer between your POCOs and your database."_ The thinness _is_ the
performance story: fewer layers between the expression tree and the ADO.NET command, plus a compiled,
cached materialization path (below).

---

## Connection, pooling & resource lifetime

The data context is a `DataConnection` (or its per-query sibling `DataContext`), an abstraction over
the underlying ADO.NET provider ([`Data/DataConnection.cs`][dataconn]):

> _"Implements persistent database connection abstraction over different database engines. Could be
> initialized using connection string name or connection string, or attached to existing connection
> or transaction."_

Connections are configured through a `DataOptions` value, typically once and reused
([`README.md`][readme]):

```csharp
// linq2db: README.md
var db = new DataConnection(
  new DataOptions()
    .UseSqlServer(@"Server=.\;Database=Northwind;Trusted_Connection=True;"));
```

**Pooling is delegated to ADO.NET.** linq2db does not implement its own connection pool — it opens
provider `DbConnection` objects, and the pool is whatever the underlying driver
(`Microsoft.Data.SqlClient`, `Npgsql`, …) provides. That is why the README insists every context be
disposed: _"Make sure you **always** wrap your `DataConnection` class … in a `using` statement. This
is required for proper resource management, like releasing the database connections back into the
pool"_ ([`README.md`][readme]). Both `DataConnection` and `DataContext` implement `IDisposable` and
`IAsyncDisposable`, so `using`/`await using` is the resource-lifetime primitive — closer to C#'s RAII
than to the [scoped acquire/release][pools] of the effect systems in this survey.

The two context classes differ precisely in **connection retention** ([`README.md`][readme]):

> _"`DataConnection` opens connection with first query and holds it open until dispose happens.
> `DataContext` behaves the way you might used to with Entity Framework: it opens connection per query
> and closes it right after query is done."_

Both implement the shared `IDataContext` — _"Database connection abstraction interface"_
([`IDataContext.cs`][idatacontext]) — which also exposes the per-context `MappingSchema`, the
`CreateSqlBuilder` factory, and the `InlineParameters` flag (below). The remote-context variants
(`LinqToDB.Remote.Grpc`, `…HttpClient`, `…SignalR`, `…Wcf`) implement the same interface over a wire
protocol, so the query surface is identical whether the SQL runs in-process or on a server.

---

## Query construction & injection safety

### From expression tree to SQL

A table is surfaced as an `ITable<T>` — _"Table-like queryable source, e.g. table, view or
table-valued function"_ ([`ITable{T}.cs`][itable]) — which is an `IExpressionQuery<T>`, i.e. an
`IQueryable<T>`/`IQueryProvider`. When you write LINQ against it, the C# compiler builds a
`System.Linq.Expressions.Expression` tree instead of executable code; linq2db's provider
(`ExpressionQuery<T>`) captures that tree and compiles it into an executable `Query<T>`
([`Internal/Linq/ExpressionQuery.cs`][exprquery]):

```csharp
// linq2db: Internal/Linq/ExpressionQuery.cs (abridged)
abstract class ExpressionQuery<T> : IExpressionQuery<T>, IAsyncEnumerable<T>
{
    public Expression   Expression  { get; set; }
    public IDataContext DataContext { get; set; }

    Query<T> GetQuery(ref IQueryExpressions expression, bool cache, out bool dependsOnParameters)
    {
        if (cache && Info != null)
            return Info;                                   // reuse the compiled plan

        var info = Query<T>.GetQuery(DataContext, ref expression, out dependsOnParameters);

        if (cache && info.CompareInfo?.IsFastComparable == true && !dependsOnParameters)
            Info = info;                                   // cache it, keyed by expression shape

        return info;
    }
}
```

Two properties matter for this survey. First, **construction happens at runtime**: unlike `Quill`,
whose quotation is normalized to SQL at _compile_ time, linq2db walks the expression tree the first
time a query executes. Second, **the compiled plan is cached** keyed by the expression's shape (the
`Info` field, gated on `IsFastComparable`), so a query in a loop parses to SQL once and thereafter
re-binds only its parameters — the mechanism behind the "fastest LINQ" claim, and formalized as an
explicit API in `CompiledQuery`, which _"provides API for compilation and caching of queries for
reuse"_ ([`CompiledQuery.cs`][compiledquery]).

The translation pipeline is a chain of reified forms. The expression tree becomes a **SQL AST** whose
root for a `SELECT` is `SelectQuery` — a `sealed class … : SqlExpressionBase, ISqlTableSource` holding
`Select`/`From`/`Where`/`GroupBy`/`Having`/`OrderBy` clause objects
([`Internal/SqlQuery/SelectQuery.cs`][selectquery]). That AST is normalized by an `ISqlOptimizer` and
finally rendered by an `ISqlBuilder` — the abstract `BasicSqlBuilder` base
([`Internal/SqlProvider/BasicSqlBuilder.cs`][sqlbuilder]) with one subclass per dialect. The context
hands out both services by factory ([`IDataContext.cs`][idatacontext]): `Func<ISqlBuilder>
CreateSqlBuilder` and `Func<DataOptions, ISqlOptimizer> GetSqlOptimizer`. Reifying the query as an
AST is exactly what lets one C# query [retarget many dialects][dialects] — the same seam `Slick`'s
query compiler and `jOOQ`'s renderer occupy.

### Injection safety

**Values from the LINQ closure become bound ADO.NET parameters, not SQL text** — injection is
structurally impossible in the LINQ surface because there is no string to inject into. The provider
distinguishes a `SqlParameter` AST node (carrying a `Value` and `IsQueryParameter` flag,
[`Internal/SqlQuery/SqlParameter.cs`][sqlparam]) from an inlined literal, and _parameterizes by
default_. The `Sql` readme states the default directly ([`Sql/Readme.md`][sqlreadme]):

> _"Normally, `DateTime` instances passed into queries are parameterized on the client side. This
> includes `DateTime.Now`."_

The escape hatch is the opposite of the usual one: rather than a "raw SQL" door that _re-adds_ risk,
linq2db's `InlineParameters` flag lets you _opt out_ of parameterization for cases where a literal is
wanted ([`IDataContext.cs`][idatacontext]):

> _"Gets or sets option to force inline parameter values as literals into command text. If parameter
> inlining not supported for specific value type, it will be used as parameter."_

`Sql.ToSql<T>` does the same per-expression — its documentation notes _"All values will be embedded as
literals instead of parameters when possible"_ ([`Sql/Sql.cs`][sqlcs]) — and even then, a type that
cannot be safely inlined falls back to a parameter. Raw SQL is available through
`DataExtensions.FromSql` with a `RawSqlString` / `FormattableString` overload
([`RawSqlString.cs`][rawsql]); an _interpolated_ `FromSql($"… {value}")` still lifts each `{value}`
into a parameter, so the raw door stays parameterized too.

### The `Sql` function surface and escape to server-side SQL

Where LINQ has no operator for a SQL construct, linq2db maps a static C# method to a SQL fragment via
`[Sql.Expression]` — an attribute that _"allows custom Expressions to be defined for a Method used
within a Linq Expression"_, creating _"an Expression that will be used in SQL, in place of the method
call decorated by this attribute"_ ([`Sql/Sql.ExpressionAttribute.cs`][exprattr]):

```csharp
// linq2db: Sql/Readme.md — mapping a C# method to server-side NULLIF
[Sql.Expression("NULLIF({0}, {1})", PreferServerSide = true)]
public static T NullIf<T>(T value, T compareTo) where T : class, IComparable<T>
    => value.HasValue && value.Value.CompareTo(compareTo) == 0 ? null : value;
```

The built-in `Sql` class ships hundreds of such mappings (`Sql.Between`, `Sql.CurrentTimestamp`,
window/analytic functions, string aggregates), and _"many of these are used automatically behind the
scenes … the provider will automatically translate something such as `table.SomeDateTimeField.Year`
into the appropriate `DatePart` call"_ ([`Sql/Readme.md`][sqlreadme]). This is the extensibility seam
the README advertises as _"Ability to Map Custom SQL to Static Functions"_ ([`README.md`][readme]) —
the same role Quill's `infix` and jOOQ's plain-SQL templates play, but bound to a real, typed C#
method the compiler checks at the call site.

### Composability

Because a query is an `IQueryable<T>` value, queries **compose without string concatenation**: you
conditionally chain `where`/`select` clauses and the final SQL differs by branch ([`README.md`][readme]):

```csharp
// linq2db: README.md — the SQL differs by branch, no string building
var products = from p in db.Product select p;

if (onlyActive)
  products = from p in products where !p.Discontinued select p;

if (searchFor != null)
  products = from p in products where p.Name.Contains(searchFor) select p;

return products.ToArray();
```

---

## Schema, migrations & code generation

linq2db is **mapping-first, not schema-owning**: the POCO-to-table map can be declared three ways, and
the library reads (or generates) a schema but never treats the model as the authoritative DDL source.

**Attribute mapping.** `[Table]` _"maps databse table or view to a class or interface"_
([`Mapping/TableAttribute.cs`][tableattr]) and `[Column]` _"configures mapping of mapping class member
to database column"_ ([`Mapping/ColumnAttribute.cs`][colattr]), with `[PrimaryKey]`, `[Identity]`,
`[NotNull]`, `[Association]`, and more ([`README.md`][readme]):

```csharp
// linq2db: README.md
[Table("Products")]
public class Product
{
  [PrimaryKey, Identity]              public int    ProductID { get; set; }
  [Column("ProductName"), NotNull]    public string Name      { get; set; }
  [Column]                            public int    VendorID  { get; set; }

  [Association(ThisKey = nameof(VendorID), OtherKey = nameof(Vendor.ID))]
  public Vendor Vendor { get; set; }
}
```

One sharp edge: attribute mapping is all-or-nothing per class — _"if you add at least one attribute
into POCO, all other properties should also have attributes, otherwise they will be ignored"_
([`README.md`][readme]).

**Fluent mapping.** The `FluentMappingBuilder` — _"Fluent mapping builder"_
([`Mapping/FluentMappingBuilder.cs`][fluent]) — configures a `MappingSchema` at runtime, so the same
POCO can carry several mappings and none of them live on the type. **Inferred mapping** uses the
POCO's names verbatim with no attributes at all (the README calls it "not generally recommended"
because it infers neither primary keys nor associations). All three feed a single `MappingSchema`
([`Mapping/MappingSchema.cs`][mappingschema]) passed to the context via `DataOptions.UseMappingSchema`.

**Code generation is database-first.** The `linq2db.cli` `dotnet` tool scaffolds the model from a live
database — _"LINQ to DB CLI is a dotnet tool for Linq To DB database model scaffolding"_
([`LinqToDB.CLI.csproj`][clicsproj]) — backed by the `LinqToDB.Scaffold` framework (_"database scaffold
services for `Linq To DB`"_, [`LinqToDB.Scaffold/readme.md`][scaffoldreadme]) and a set of legacy T4
templates ([`LinqToDB.Templates/`][templatesdir]). So the workflow is db-first (introspect →
generate) or code-first-by-hand (write the POCOs), never a schema declaration that owns migrations.

**There is no migration runner** — a finding, as with `Slick`. linq2db can emit DDL
(`db.CreateTable<T>()` / `DropTable`, [`DataExtensions.cs`][insertext]) from a mapping, but it ships
no versioned, bookkeeping-table [migration][schemamig] engine; schema _evolution_ is left to external
tools (FluentMigrator, Grate, …; web-attested). It owns the mapping, not the schema's history.

---

## Type mapping & result decoding

Value conversion is the `MappingSchema`'s job. It carries the type-to-`DbDataType` map and a chain of
`IValueConverter`/`ValueConverter` conversions; custom scalar types map through `MapValueAttribute`
(enum ↔ literal), `[ValueConverter]`, or `SetConverter` registrations, and the `DataType`/`DbDataType`
pair pins the ADO.NET provider type for a column. Because the conversions live on the schema (not the
type), the same POCO can decode differently under two schemas.

**Row hydration is a compiled delegate.** The LINQ builder does not reflect per-row; it compiles an
expression that reads the `DbDataReader` positionally into the result shape (POCO, anonymous type, or
tuple) as part of building the `Query<T>` — the same compiled path that is cached across executions.
Projections can materialize a subset of columns into a full POCO without object tracking, which the
README highlights as a win over identity-tracking providers ([`README.md`][readme]): _"getting all the
fields is too wasteful so we want only certain fields, but still use our POCOs; something that is
challenging for libraries that rely on object tracking, like LINQ to SQL."_

**Nullability** follows the CLR type: a `Nullable<T>` column or a nullable reference type maps to a
nullable column, and the inferred-mapping path explicitly _"will not infer nullability of reference
types if you don't use nullable reference types annotations"_ ([`README.md`][readme]). The `Sql`
surface adds `Sql.AsNullable`/`Sql.ToNullable` (widen) and `Sql.AsNotNull`/`Sql.ToNotNull` (narrow) to
steer the nullability the SQL generator infers for an expression ([`Sql/Sql.cs`][sqlcs]) — a manual
lever, not the compiler-enforced [nullability][typemap] of `sqlx` or `Squeal`.

**Association loading is explicit and eager.** There is no lazy-proxy navigation; you request related
data with `LoadWith`/`ThenLoad`, which _"specifies associations, that should be loaded for each loaded
record from current table"_ and warns that _"use of this method could require multiple queries to load
all requested associations"_ ([`LinqExtensions/LinqExtensions.LoadWith.cs`][loadwith]). Because the
join is written by hand (or requested explicitly), the [N+1 problem][nplusone] is the author's to
avoid, not the library's to guess at.

---

## Effect model, transactions & error handling

### Sync and async, both first-class

linq2db is **not** effect-valued: a query runs when you enumerate it (sync) or await it (async), and
returns data directly, not a description of work. Both execution modes are first-class.
`ExpressionQuery<T>` implements `IEnumerable<T>` **and** `IAsyncEnumerable<T>` plus the async provider
seam `IQueryProviderAsync.ExecuteAsync` ([`Internal/Linq/ExpressionQuery.cs`][exprquery]), and the
`AsyncExtensions` class — _"provides helper methods for asynchronous operations"_
([`Async/AsyncExtensions.cs`][asyncext]) — adds `ToListAsync`/`ToArrayAsync`/`FirstAsync`/`CountAsync`/…
that return `Task<T>` with a `CancellationToken`. So the effect model is **async `Task` + blocking**,
matching the master catalog's classification.

### Explicit DML: persistence is a verb, not a flush

Without change tracking, every write is an explicit call. Two surfaces exist:

**Object-level** extension methods on `IDataContext` — `db.Insert(obj)` _"inserts record into table,
identified by `T` mapping class, using values from `obj` parameter"_ and returns the affected-row
count ([`DataExtensions.cs`][insertext]); likewise `Update`, `Delete`, `InsertOrReplace`, and
`InsertWithInt32Identity` (insert and return the generated key). **Query-level** fluent DML builds the
statement from a filtered `ITable<T>` ([`README.md`][readme]):

```csharp
// linq2db: README.md — a set-based UPDATE, no entities loaded
using var db = new DbNorthwind();
db.Product
  .Where(p => p.UnitsInStock == 0)
  .Set(p => p.Discontinued, true)
  .Update();
```

This runs one `UPDATE … WHERE …` against the server — no rows are fetched, mutated, and written back.
The same shape covers `.Value(...).Insert()`, `.Where(...).Delete()`, the `Upsert`/`InsertOrUpdate`
family (_"performs an Upsert (insert-or-update) of a single entity into the target table"_,
[`LinqExtensions/LinqExtensions.Upsert.cs`][upsert]), a full SQL `MERGE` API
([`LinqExtensions/LinqExtensions.Merge.cs`][merge]), `InsertWithOutput`/`DeleteWithOutput` (the
`OUTPUT`/`RETURNING` clause), and `BulkCopy` for high-throughput loads. This is the survey's clearest
example of the [data-mapper][ladder] stance _without_ a [unit of work][ormpatterns]: you name the
statement, linq2db generates it, and nothing is inferred from a mutated graph.

### Transactions

Transactions are managed imperatively on the `DataConnection`. `BeginTransaction()` _"starts new
transaction for current connection with default isolation level"_ and returns a
`DataConnectionTransaction` controller ([`Data/DataConnection.cs`][dataconn]); you then call
`CommitTransaction()`/`RollbackTransaction()` (or `Commit`/`Rollback` on the returned controller,
which is itself `IDisposable`/`IAsyncDisposable`) ([`Data/DataConnectionTransaction.cs`][dctrans]):

```csharp
// linq2db: README.md
using var db = new DbNorthwind();
using var tr = db.BeginTransaction();

// ... select / insert / update / delete ...

if (somethingIsNotRight) tr.Rollback();
else                     tr.Commit();
```

An overload takes an `IsolationLevel`, and async mirrors exist throughout
(`BeginTransactionAsync`/`CommitTransactionAsync`/`RollbackTransactionAsync`,
[`Data/DataConnection.Async.cs`][dataconnasync]). Two properties are worth pinning down:

- **No nested transactions / savepoints in the core API.** A second `BeginTransaction()` on a
  connection that already has one throws — _"if connection already has transaction, it will throw
  `InvalidOperationException`"_, with the message `"Data connection already has transaction"`
  ([`Data/DataConnection.cs`][dataconn]). Unlike the [savepoint-based nesting][savepoint] some effect
  systems provide, linq2db exposes one flat transaction per connection.
- **Ambient `TransactionScope` is supported**, and interacts with connection-retention: because a
  `DataConnection` attaches to the ambient transaction only at the moment it opens, a
  `TransactionScope` created _after_ the connection is open has no effect on it — one reason the README
  documents the `DataConnection`-vs-`DataContext` retention difference so carefully ([`README.md`][readme]).

### Error handling: exceptions, not a typed channel

Errors surface as **thrown exceptions**, not a typed error value. linq2db's own failures throw
`LinqToDBException` — _"exception type for exceptions, thrown by Linq To DB"_
([`LinqToDBException.cs`][exception]) — and `LinqException` for query-shape errors; anything the driver
raises (a constraint violation, a deadlock, a timeout) bubbles up as the ADO.NET provider's
`DbException` subtype. There is no enumerated reason union à la Effect TS's `SqlError`, no `Either`/
`Result` channel à la `doobie`, and no retryability flag on the error — the caller handles failures
with `try`/`catch` in the host language. This is the mainstream .NET posture (the same as `Dapper` and
`EF Core`), and the sharpest contrast with the [typed-error][effects] effect mappers this survey
weights most heavily.

---

## Ecosystem & maturity

linq2db is a mature, actively-developed OSS project under the permissive **MIT** license
([`MIT-LICENSE.txt`][license]), authored by Igor Tkachev, Ilya Chudin, Svyatoslav Danyliv, Dmitry
Lukashenko, and others under the `linq2db.net` banner ([`Directory.Build.props`][buildprops]). The
pinned tree is version `6.4.0`. It descends from the older BLToolkit data-access library and has been
shipped on NuGet as `linq2db` since ≈2013 (web-attested).

**Breadth of backends is a headline strength.** The `DataProvider/` tree carries dedicated,
version-aware providers for SQL Server (2005 through 2025), PostgreSQL (9.2+), MySQL/MariaDB, Oracle,
DB2 (LUW and z/OS), SQLite, Firebird, Sybase ASE, Informix, SAP HANA, Microsoft Access, ClickHouse,
DuckDB, SQL CE, and YDB ([`ProviderName.cs`][providername], [`DataProvider/`][dataproviderdir]) — a
wider dialect matrix than most libraries in this survey.

The surrounding ecosystem includes `linq2db.EntityFrameworkCore` (use linq2db's SQL generation _inside_
an `EF Core` project — the two coexist), a LINQPad driver, `LinqToDB.Identity` (ASP.NET Core Identity
storage), F# support (`LinqToDB.FSharp`), and remote contexts over gRPC/HttpClient/SignalR/WCF that
expose the same query API across a wire. Notable open-source users named in the README include
nopCommerce (e-commerce), OdataToEntity, and SunEngine ([`README.md`][readme]).

---

## Strengths

- **LINQ that stays close to SQL.** Compiler-checked, refactorable C# queries with no magic strings,
  yet a thin, predictable path to the generated SQL — no ORM "magic" between you and the statement.
- **Explicit, set-based DML.** `Insert`/`Update`/`Delete`/`Upsert`/`Merge`/`BulkCopy` run one
  server-side statement; a mass update touches zero client rows. No change tracking to reason about.
- **Injection-safe by default.** Closure values become bound ADO.NET parameters; inlining literals is
  the opt-_out_ (`InlineParameters`/`Sql.ToSql`), and even that falls back to a parameter when unsafe.
- **Fast.** Thin layering plus a compiled, cached materialization/SQL plan (`Query<T>.Info`,
  `CompiledQuery`) back the "fastest LINQ database access library" claim.
- **Very wide dialect support.** ~15 database families with version-aware SQL generation from one
  query surface.
- **Both sync and async, first-class.** `IEnumerable<T>` and `IAsyncEnumerable<T>`/`Task<T>` with
  cancellation, not a bolted-on afterthought.
- **Flexible mapping.** Attribute, fluent, or inferred POCO mapping into one `MappingSchema`; db-first
  scaffolding via `linq2db.cli`.

## Weaknesses

- **You manage persistence yourself.** No change tracking, identity map, or unit of work — the price
  of the control the README advertises; graph-shaped updates are more code than `EF Core`'s
  `SaveChanges`.
- **No typed error channel.** Failures are thrown `LinqToDBException`/`DbException`; no reason union,
  no `Result`/`Either`, no retryability flag.
- **No nested transactions / savepoints** in the core API; one flat transaction per connection.
- **Runtime translation.** Expression trees are parsed to SQL at first execution, not compile time; an
  untranslatable LINQ construct fails at runtime (a `LinqException`), not at build — weaker than
  `Quill`'s compile-time quotation.
- **No migration runner.** linq2db owns the mapping and can emit DDL, but schema _evolution_ is an
  external concern.
- **ADO.NET-shaped resource model.** `using`/`await using` RAII rather than a scoped effect resource;
  a leaked context is a runtime leak, not a type error.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                               | Trade-off                                                                                     |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **LINQ as SQL construction, not object abstraction**                | Compiler-checked, refactorable queries; thin, predictable SQL; no ORM guessing          | LINQ constructs the SQL can't express fail at _runtime_ (`LinqException`), not compile time   |
| **No change tracking / identity map / unit of work**                | Control and speed; explicit, set-based DML; nothing inferred from a mutated graph       | You write every `Insert`/`Update`/`Delete`; graph persistence is more manual than a full ORM  |
| **Runtime expression-tree → AST → SQL, plan cached**                | One query retargets ~15 dialects; parse-once/rebind-params amortizes the "fastest" cost | First execution pays the translation cost; not compile-time-checked like `Quill`              |
| **Parameterize by default; `InlineParameters` is the opt-out**      | Injection-safe surface with no raw-string door in the LINQ path                         | Literal-inlining (for plan-cache/constant-folding wins) is a deliberate, careful choice       |
| **Async + sync direct execution, not an effect value**              | Idiomatic .NET; `Task`/`IAsyncEnumerable` with cancellation                             | No effect-value composition, typed errors, or scoped resources like the effect-system peers   |
| **Exceptions, not a typed error channel**                           | Mainstream .NET; interops with `try`/`catch` and existing handlers                      | No enumerated/retryable error set (unlike Effect TS `SqlError` / `doobie`)                    |
| **Mapping-first (attribute / fluent / inferred), db-first codegen** | Map existing schemas flexibly; several mappings per POCO; scaffold from a live DB       | The library owns the _mapping_, not the schema; no built-in migration/versioning              |
| **One flat transaction per connection (+ `TransactionScope`)**      | Simple, deterministic transaction boundary                                              | No nested transactions or savepoints; `TransactionScope` timing interacts with retention mode |

---

## Sources

- [linq2db/linq2db — GitHub repository][repo] · [linq2db.github.io documentation][docs] · [NuGet `linq2db`][nuget]
- [`README.md` — positioning ("type-safe SQL", "one step above micro-ORMs", "no change-tracking"), LINQ/insert/update/delete/transaction examples, mapping, connection retention][readme]
- [`Source/LinqToDB/LinqToDB.csproj` — package description][csproj] · [`Directory.Build.props` — version, authors, license metadata][buildprops]
- [`ITable{T}.cs` — table-like queryable source][itable] · [`IDataContext.cs` — context abstraction, `InlineParameters`, `CreateSqlBuilder`][idatacontext]
- [`Internal/Linq/ExpressionQuery.cs` — the `IQueryProvider`: expression tree → `Query<T>`, plan cache, sync + async execution][exprquery] · [`CompiledQuery.cs` — compile & cache queries][compiledquery]
- [`Internal/SqlQuery/SelectQuery.cs` — the SQL AST root][selectquery] · [`Internal/SqlQuery/SqlParameter.cs` — bound-parameter node][sqlparam] · [`Internal/SqlProvider/BasicSqlBuilder.cs` — per-dialect SQL generation][sqlbuilder]
- [`Sql/Sql.cs` + `Sql/Sql.ExpressionAttribute.cs` — the `Sql` function surface, `[Sql.Expression]` custom-SQL mapping][sqlcs] · [`Sql/Readme.md` — parameterize-by-default, `Sql` built-ins][sqlreadme]
- [`Mapping/TableAttribute.cs`][tableattr] · [`Mapping/ColumnAttribute.cs`][colattr] · [`Mapping/FluentMappingBuilder.cs`][fluent] · [`Mapping/MappingSchema.cs`][mappingschema]
- [`Data/DataConnection.cs` — context + transactions][dataconn] · [`Data/DataConnectionTransaction.cs`][dctrans] · [`Data/DataConnection.Async.cs`][dataconnasync] · [`LinqToDBException.cs` — thrown-exception error model][exception]
- [`DataExtensions.cs` — object-level `Insert`/`Update`/`Delete`, `CreateTable`][insertext] · [`LinqExtensions/LinqExtensions.Upsert.cs`][upsert] · [`LinqExtensions/LinqExtensions.Merge.cs`][merge] · [`LinqExtensions/LinqExtensions.LoadWith.cs`][loadwith]
- [`Async/AsyncExtensions.cs` — `ToListAsync`/`FirstAsync`/…][asyncext] · [`ProviderName.cs`][providername] · [`DataProvider/`][dataproviderdir] · [`LinqToDB.CLI.csproj` + `LinqToDB.Scaffold/readme.md` — db-first scaffolding][clicsproj]
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [effects, transactions & errors][effects] · [type mapping & decoding][typemap] · [schema, migrations & codegen][schemamig] · [ORM patterns][ormpatterns] · [N+1][nplusone]

<!-- References -->

[repo]: https://github.com/linq2db/linq2db
[docs]: https://linq2db.github.io
[nuget]: https://www.nuget.org/packages/linq2db
[license]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/MIT-LICENSE.txt
[buildprops]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Directory.Build.props
[readme]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/README.md
[csproj]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/LinqToDB.csproj
[itable]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/ITable%7BT%7D.cs
[idatacontext]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/IDataContext.cs
[exprquery]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Internal/Linq/ExpressionQuery.cs
[compiledquery]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/CompiledQuery.cs
[selectquery]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Internal/SqlQuery/SelectQuery.cs
[sqlparam]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Internal/SqlQuery/SqlParameter.cs
[sqlbuilder]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Internal/SqlProvider/BasicSqlBuilder.cs
[sqlcs]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Sql/Sql.cs
[exprattr]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Sql/Sql.ExpressionAttribute.cs
[sqlreadme]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Sql/Readme.md
[tableattr]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Mapping/TableAttribute.cs
[colattr]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Mapping/ColumnAttribute.cs
[fluent]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Mapping/FluentMappingBuilder.cs
[mappingschema]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Mapping/MappingSchema.cs
[dataconn]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Data/DataConnection.cs
[dctrans]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Data/DataConnectionTransaction.cs
[dataconnasync]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Data/DataConnection.Async.cs
[exception]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/LinqToDBException.cs
[insertext]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/DataExtensions.cs
[upsert]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/LinqExtensions/LinqExtensions.Upsert.cs
[merge]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/LinqExtensions/LinqExtensions.Merge.cs
[loadwith]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/LinqExtensions/LinqExtensions.LoadWith.cs
[asyncext]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/Async/AsyncExtensions.cs
[rawsql]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/RawSqlString.cs
[providername]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/ProviderName.cs
[dataproviderdir]: https://github.com/linq2db/linq2db/tree/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB/DataProvider
[clicsproj]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB.CLI/LinqToDB.CLI.csproj
[scaffoldreadme]: https://github.com/linq2db/linq2db/blob/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB.Scaffold/readme.md
[templatesdir]: https://github.com/linq2db/linq2db/tree/6b626480c88f7114b5da83244e6c6ddb993f3369/Source/LinqToDB.Templates
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[schemamig]: ./concepts.md#schema-migrations-code-generation
[ormpatterns]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[savepoint]: ./concepts.md#effects-transactions-and-error-handling
[dialects]: ./concepts.md#dialects-idioms-and-naming-strategies

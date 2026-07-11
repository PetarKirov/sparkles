# Entity Framework Core (C# / .NET)

Microsoft's flagship [data-mapper ORM][ladder] for .NET: [LINQ][linq] queries against `DbSet<TEntity>` compile to SQL, a snapshot-based `ChangeTracker` computes the minimal `INSERT`/`UPDATE`/`DELETE` batch on `SaveChanges()`, and the entity classes double as the schema source for code-first migrations.

| Field              | Value                                                                                                                                              |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | C# / .NET (the pinned tree targets the current .NET; `Directory.Build.props` `DefaultNetCoreTargetFramework`)                                      |
| License            | MIT (`LICENSE.txt` — "The MIT License (MIT)", "Copyright (c) .NET Foundation and Contributors")                                                    |
| Repository         | [dotnet/efcore][repo]                                                                                                                              |
| Documentation      | [Microsoft Learn: EF Core][docs] · [API reference][apidocs]                                                                                        |
| Category           | [Full ORM (data mapper)][ladder] — unit of work + identity map + change tracking; the archetypal full ORM for .NET                                 |
| Abstraction level  | [Full ORM rung][ladder] — the top of the ladder: it owns change tracking, the identity map, the unit of work, lazy loading, and migrations         |
| Query model        | [LINQ][linq] → SQL: `where`/`select` lambdas captured as **expression trees** and translated to SQL by the query pipeline                          |
| Effect/async model | [Async-first][effects] (`Task<T>` / `ValueTask<T>`) with a mirrored synchronous API; failures are **thrown exceptions**, not a typed error channel |
| Backends           | SQL Server, Azure SQL, SQLite, Azure Cosmos DB, MariaDB, MySQL, PostgreSQL (Npgsql), Oracle, … via a **provider plugin API** (`README.md`)         |
| First release      | EF Core `1.0`, 2016-06 (web-attested)                                                                                                              |
| Latest version     | `11.0.0-preview` (the pinned tree; `eng/Versions.props`); EF Core `9.0` GA ≈ 2024-11 (web-attested)                                                |

> [!NOTE]
> EF Core is this survey's data point for a **full ORM in the [Data Mapper][orm] tradition**
> — the .NET counterpart to `Hibernate`/JPA on the JVM and `SQLAlchemy` in Python. It sits at
> the very top of the [abstraction ladder][ladder]: you mutate ordinary CLR objects and a
> session ([`DbContext`][ctx]) works out the SQL. That is the opposite pole from the
> effects-first functional mappers this survey weights most heavily ([doobie][doobie],
> [Quill][quill], [Ecto][ecto], [Effect TS][effect-ts]), which deliberately stop below the
> full-ORM rung — no [identity map][orm], no implicit flush. Within .NET it is the heavy end:
> `linq2db` and `Dapper` are the thinner options that keep LINQ/raw-SQL but **drop** change
> tracking. Terms below link to [concepts][concepts].

---

## Overview

### What it solves

EF Core lets a .NET developer treat a relational database as a graph of typed objects: you
query with LINQ, mutate the returned instances, and call one method to persist every change.
The `README` states the scope in a sentence ([`README.md`][readme]):

> _"EF Core is a modern object-database mapper for .NET. It supports LINQ queries, change
> tracking, updates, and schema migrations. EF Core works with SQL Server, Azure SQL Database,
> SQLite, Azure Cosmos DB, MariaDB, MySQL, PostgreSQL, and other databases through a provider
> plugin API."_

The four verbs in that line — **query**, **track**, **update**, **migrate** — are the four
subsystems this page dissects. The canonical program from the `README` shows all of them in
twenty lines ([`README.md`][readme]):

```csharp
// efcore: README.md
using var db = new BloggingContext();

// Inserting data into the database
db.Add(new Blog { Url = "http://blogs.msdn.com/adonet" });
db.SaveChanges();

// Querying
var blog = db.Blogs
    .OrderBy(b => b.BlogId)
    .First();

// Updating
blog.Url = "https://devblogs.microsoft.com/dotnet";
db.SaveChanges();

// Deleting
db.Remove(blog);
db.SaveChanges();
```

Nothing here writes SQL. `db.Blogs.OrderBy(...)` is a LINQ query the provider turns into a
`SELECT`; `blog.Url = ...` is a plain field assignment that the tracker later notices; the
three `SaveChanges()` calls each emit exactly the statement the mutation implies. That
"mutate objects, then flush" loop — the [Unit of Work][orm] — is what separates a full ORM
from every lower rung of the [ladder][ladder].

### Design philosophy

EF Core's design centre is the [`DbContext`][ctx]: it **is** the session, the unit of work,
and the repository, rolled into one object. Its own class docstring names the patterns
([`src/EFCore/DbContext.cs`][ctx]):

> _"A DbContext instance represents a session with the database and can be used to query and
> save instances of your entities. DbContext is a combination of the Unit Of Work and
> Repository patterns."_

The second pillar is that **the model is code**. Entities are ordinary POCOs, the schema is
discovered from them by convention, and the query language is the host language's own LINQ —
no separate query DSL, no `.sql` files in the common path. `DbSet<TEntity>` fuses the query
surface and the persistence surface ([`src/EFCore/DbSet.cs`][dbset]):

> _"A `DbSet<TEntity>` can be used to query and save instances of `TEntity`. LINQ queries
> against a `DbSet<TEntity>` will be translated into queries against the database."_

The third pillar — the one that most colours the survey — is that EF Core **guesses**. It
guesses which SQL a `Where` becomes, when a relation must be loaded, and which rows changed.
Those guesses are what make the mainstream ergonomics possible; they are also the source of
every trade-off below (the leaky LINQ-translation boundary, change-tracking overhead, lazy
loading's N+1 trap). Where the functional mappers make persistence and effects **explicit and
typed**, EF Core makes them **implicit and convenient** — the defining axis on which this
survey reads it.

---

## Connection, pooling & resource lifetime

A [`DbContext`][ctx] is a short-lived, **single-threaded** [session][pool]. Its docstring is
emphatic ([`src/EFCore/DbContext.cs`][ctx]): _"Entity Framework Core does not support multiple
parallel operations being run on the same DbContext instance … always await async calls
immediately, or use separate DbContext instances for operations that execute in parallel."_
The idiomatic lifetime is one context per unit of work (per web request); `AddDbContext`
registers it with `ServiceLifetime.Scoped` by default
([`src/EFCore/Extensions/EntityFrameworkServiceCollectionExtensions.cs`][services]).

EF Core does **not** implement its own [connection pool][pool]. The relational layer wraps an
ADO.NET `DbConnection` ([`src/EFCore.Relational/Storage/RelationalConnection.cs`][relconn] —
_"Represents a connection with a relational database"_), and physical connection pooling is
delegated to the underlying ADO.NET provider (`Microsoft.Data.SqlClient`, `Npgsql`, …), which
pools by connection string. What EF Core pools instead is the **context object graph itself**:
`AddDbContextPool` keeps a pool of reset-and-reused `DbContext` instances to skip per-request
setup cost ([`services`][services]) — _"DbContext pooling can increase performance in
high-throughput scenarios by re-using context instances … Note that when using pooling, the
context configuration cannot change between uses."_

Resource release is `IDisposable`/`IAsyncDisposable`: `using var db = new BloggingContext()`
disposes the context (returning its ADO.NET connection to the provider pool) at scope exit.
For result sets too large to buffer, the async LINQ terminators stream — `AsAsyncEnumerable()`
yields rows over a forward-only reader ([`src/EFCore/DbSet.cs`][dbset]) — the [cursor][pool]
substrate under EF Core's streaming reads.

---

## Query construction & injection safety

This is one of the two sections that matter most, and EF Core's answer is **LINQ**. A query is
an ordinary C# expression — `db.Blogs.Where(b => b.Rating > minRating).OrderBy(b => b.Url)` —
that the compiler captures as an **expression tree** (`IQueryable<T>` is backed by
`Expression`), and the query pipeline translates that tree to SQL. See
[concepts § LINQ][linq]: EF Core is the archetypal LINQ provider, the .NET analogue of
[Quill][quill]'s compile-time quotation, except EF Core translates at **runtime**.

**The pipeline.** The provider-agnostic core discovers query roots and rewrites the tree
(`QueryableMethodTranslatingExpressionVisitor` — _"A class that translates queryable methods in
a query"_, [`src/EFCore/Query/QueryableMethodTranslatingExpressionVisitor.cs`][qmt]); the
relational layer post-processes it into a SQL AST and renders dialect-specific text
(`RelationalQueryTranslationPostprocessor`,
[`src/EFCore.Relational/Query/RelationalQueryTranslationPostprocessor.cs`][relpost]). The whole
LINQ-to-SQL compilation is cached and keyed, so repeated shapes reuse the plan.

**Parameters are automatic and injection-safe.** A closed-over value in a LINQ query
(`minRating` above) is captured as a **query parameter**, not baked into the SQL text, and
transferred out-of-band as a `DbParameter` — so [SQL injection][inject] is structurally
impossible for LINQ queries: user data never becomes SQL. EF Core even exposes explicit control
over the constant/parameter choice via the `EF` helper class
([`src/EFCore/EF.cs`][efcs]): `EF.Constant<T>` _"forces its argument to be inserted into the
query as a constant expression"_, while `EF.Parameter<T>` forces the opposite — _"make sure a
constant value is parameterized instead of integrated as a constant into the query, which can
be useful in dynamic query construction scenarios."_

**The leaky boundary: client evaluation.** The cost of "write any LINQ, get SQL" is that not
all LINQ **is** translatable — an expression calling a method the provider can't map has no SQL
equivalent. EF Core's stance (since EF Core 3.0) is to **fail loudly** rather than silently run
the predicate in memory. The exception text is the sharpest statement of the trade-off
([`src/EFCore/Properties/CoreStrings.resx`][corestrings], `TranslationFailed`):

> _"The LINQ expression '{expression}' could not be translated. Either rewrite the query in a
> form that can be translated, or switch to client evaluation explicitly by inserting a call to
> 'AsEnumerable', 'AsAsyncEnumerable', 'ToList', or 'ToListAsync'."_

So the query surface is expressive and safe, but its edges are discovered **at runtime**: a
query that compiles fine in C# can throw when executed because one node had no SQL
translation. This is the ORM analogue of the [dynamic][qcm] builders' "typo is a runtime
error" — except here the failure mode is _untranslatable expression_, not _wrong column name_.

**Raw SQL, three doors.** For the queries LINQ can't express, EF Core offers a raw path with a
deliberately safe default and an explicit escape hatch
([`src/EFCore.Relational/Extensions/RelationalQueryableExtensions.cs`][relqueryable]):

- `FromSql(FormattableString)` — the **safe** raw entrypoint. Interpolated values become bound
  parameters: _"You can include interpolated parameter place holders in the SQL query string.
  Any interpolated parameter values you supply will automatically be converted to a
  `DbParameter`."_
- `FromSqlRaw(string, params object?[])` — the **escape hatch**. Placeholders (`{0}`) are
  parameterized, but the string itself is trusted, and the docstring carries the loudest
  warning in the codebase: _"However, **never** pass a concatenated or interpolated string
  (`$""`) with non-validated user-provided values into this method. Doing so may expose your
  application to SQL injection attacks. To use the interpolated string syntax, consider using
  `FromSql<TEntity>` to create parameters."_
- `FromSqlInterpolated(FormattableString)` — the older name for the safe path, now
  `[Obsolete("Use FromSql() instead. …")]`.

```csharp
// efcore: RelationalQueryableExtensions.cs — the safe raw path (interpolation → parameters)
var blogs = db.Blogs
    .FromSql($"SELECT * FROM Blogs WHERE Url = {url}")   // url → a DbParameter, not SQL text
    .OrderBy(b => b.Url)                                 // still composable with LINQ
    .ToList();
```

The design point is that the injection-unsafe door (`FromSqlRaw` with a built string) exists
but is named and documented as the dangerous one; the interpolated `FromSql` overload makes
the _safe_ thing the _natural_ thing — the same "safe-by-default, escape-hatch-by-name" posture
this survey tracks across [Effect TS][effect-ts]'s `sql.unsafe` and `SeaORM`'s
`raw_sql!`.

---

## Schema, migrations & code generation

EF Core is **code-first** by default: the entity classes and the `OnModelCreating` fluent
configuration _are_ the schema, and the tooling diffs them to emit DDL — the [code-first
stance][schema] on the concepts ladder (the same rung as `Django`, `Prisma`, `Beam`).

**A migration is a class.** `Add-Migration` / `dotnet ef migrations add` generates a subclass
of `Migration` ([`src/EFCore.Relational/Migrations/Migration.cs`][migration] — _"A base class
inherited by each EF Core migration"_) whose `Up` and `Down` methods build a provider-agnostic
list of `MigrationOperation`s via a `MigrationBuilder`. The empty-database baseline is the
constant `InitialDatabase = "0"`.

**The model snapshot is how the diff works.** Alongside the migration classes, EF Core keeps a
single `ModelSnapshot` — _"Base class for the snapshot of the `IModel` state generated by
Migrations"_ ([`src/EFCore.Relational/Infrastructure/ModelSnapshot.cs`][modelsnapshot]). Adding
a migration compares the **current** model (built from your entities) against the **snapshot**
(the model as of the last migration); the difference is computed by `IMigrationsModelDiffer` —
_"A service for finding differences between two `IRelationalModel`s and transforming those
differences into `MigrationOperation`s that can be used to update the database"_
([`src/EFCore.Relational/Migrations/IMigrationsModelDiffer.cs`][differ]). The snapshot is then
rewritten to the new state. This model-snapshot machinery is powerful but is also a known
source of complexity: the snapshot is a generated file that must stay in sync, and a hand-edit
or a merge conflict in it produces confusing diffs.

**Applying and tracking.** A migration runner applies pending migrations and records applied
ones in a bookkeeping table (`__EFMigrationsHistory`), queryable through the `DatabaseFacade`:
`GetMigrations()`, `GetAppliedMigrations()`, `GetPendingMigrations()`
([`src/EFCore.Relational/Extensions/RelationalDatabaseFacadeExtensions.cs`][reldbfacade]) — the
[migration-runner][schema] pattern.

**Database-first is also supported** via scaffolding: `dotnet ef dbcontext scaffold`
[introspects][schema] a live database and generates the `DbContext` + entity classes (the
[code-generation][schema] move), the inverse of code-first for bringing an existing database
under EF Core. So EF Core spans code-first (the default) and db-first (scaffolding), but —
unlike the schema-first tools — has no external `.sql`/`.prisma` schema file as the source of
truth; the C# model always is.

---

## Type mapping & result decoding

**Row hydration.** A tracking query materializes each row into an entity instance and wires up
its relationships; the shaper is compiled per query shape (`ShapedQueryCompilingExpressionVisitor`
in `Query/`). Column-to-property mapping, nullability (`NULL` ↦ a nullable CLR type `T?`), and
custom conversions are configured on the model; value converters
(`ValueConverter`) bridge a CLR type to a store type when they differ. Projections to anonymous
types or DTOs (`select new { … }`) skip entity materialization entirely and are never tracked.

### Change tracking, the identity map & `EntityState`

This subsection is what makes EF Core a **full ORM** rather than a query builder, so it earns
the most detail. Every entity a tracking query returns, or that you `Add`/`Attach`, is recorded
by the `ChangeTracker` — _"Provides access to change tracking information and operations for
entity instances the context is tracking"_ ([`src/EFCore/ChangeTracking/ChangeTracker.cs`][tracker]).

**The identity map.** Within one context, one database row maps to one CLR instance. `Find` is
the visible face of it ([`src/EFCore/DbSet.cs`][dbset]):

> _"Finds an entity with the given primary key values. If an entity with the given primary key
> values is being tracked by the context, then it is returned immediately without making a
> request to the database."_

So two lookups of the same key inside one context return the **same** object, and edits to it
can never diverge — the [Identity Map][orm] pattern (opt out with the [no-tracking][qcm] modes
below, which explicitly skip identity resolution).

**Snapshot-based change detection.** When an entity is loaded, EF Core snapshots its property
values. `EntityEntry.OriginalValues` exposes that snapshot
([`src/EFCore/ChangeTracking/EntityEntry.cs`][entry]): _"The original values are the property
values as they were when the entity was retrieved from the database."_ Because entities are
plain objects, EF Core cannot observe `blog.Url = "…"` as it happens; instead, on demand it
**re-scans** the tracked instances and compares each against its snapshot. `DetectChanges` does
the scan ([`tracker`][tracker]):

> _"Scans the tracked entity instances to detect any changes made to the instance data.
> `DetectChanges()` is usually called automatically by the context when up-to-date information
> is required (before `DbContext.SaveChanges()` and when returning change tracking
> information)."_

(The `EFCore.Proxies` package offers an alternative: change-tracking proxies that intercept
setters, so detection is push-based instead of a snapshot diff — [`ProxiesExtensions`][proxies].)

**`EntityState` is the per-entity verdict.** Each tracked entity is in one of five states
([`src/EFCore/EntityState.cs`][entitystate]):

| State       | Meaning (verbatim docstring)                                                                                    |
| ----------- | --------------------------------------------------------------------------------------------------------------- |
| `Detached`  | _"The entity is not being tracked by the context."_                                                             |
| `Unchanged` | _"tracked … and exists in the database. Its property values have not changed from the values in the database."_ |
| `Deleted`   | _"tracked … and exists in the database. It has been marked for deletion from the database."_                    |
| `Modified`  | _"tracked … and exists in the database. Some or all of its property values have been modified."_                |
| `Added`     | _"tracked … but does not yet exist in the database."_                                                           |

`Add` sets `Added`, `Remove` sets `Deleted`, change detection promotes an edited `Unchanged` to
`Modified`, and `Attach` infers `Added` vs `Unchanged` from whether the primary key is set
([`src/EFCore/DbSet.cs`][dbset]). These states are exactly the information `SaveChanges` needs to
pick `INSERT` vs `UPDATE` vs `DELETE` per row (next section).

**Opting out for reads.** Tracking has real cost (the snapshot, the identity map, the scan), so
read-only queries should skip it. `AsNoTracking()` returns entities the tracker ignores
([`src/EFCore/Extensions/EntityFrameworkQueryableExtensions.cs`][queryext]) — _"Disabling change
tracking is useful for read-only scenarios because it avoids the overhead of setting up change
tracking for each entity instance."_ The default is set by `QueryTrackingBehavior`
([`src/EFCore/QueryTrackingBehavior.cs`][qtb]): `TrackAll` (the default),
`NoTracking` (_"Identity resolution is not performed"_), or `NoTrackingWithIdentityResolution`
(no persistence tracking, but one-instance-per-key still holds).

---

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily. EF Core's effect model is **async-first
imperative** — not an effect value — and its unit of work is `SaveChanges`.

**`SaveChanges` is the unit of work.** The whole point of change tracking is that persistence is
one call. `SaveChanges` first runs change detection, then asks the state manager to emit the
minimal statement set ([`src/EFCore/DbContext.cs`][ctx]):

> _"Saves all changes made in this context to the database. … This method will automatically
> call `ChangeTracker.DetectChanges` to discover any changes to entity instances before saving
> to the underlying database."_

It returns _"The number of state entries written to the database"_, and computes — from each
entity's `EntityState` — exactly one `INSERT` for every `Added` row, one `UPDATE` (touching only
changed columns) for every `Modified` row, and one `DELETE` for every `Deleted` row, ordered to
respect foreign keys. That is the [Unit of Work][orm] in one method: accumulate mutations,
derive the minimal SQL on flush.

**Statement batching.** Those statements are not sent one-per-round-trip. The relational update
layer packs many `ModificationCommand`s into a `ModificationCommandBatch` — _"A base class for a
collection of `ModificationCommand`s that can be executed as a batch"_
([`src/EFCore.Relational/Update/ModificationCommandBatch.cs`][batch]); `TryAddCommand` returns
_"`false` if there was no room in the current batch … and it must instead be added to a new
batch"_, so a `SaveChanges` over N dirty entities becomes a handful of round-trips, not N.

**Atomicity is implicit.** A single `SaveChanges` is atomic even without an explicit
transaction. `AutoTransactionBehavior.WhenNeeded` (the default) explains it
([`src/EFCore/AutoTransactionBehavior.cs`][autotx]): _"Transactions are automatically created as
needed. For example, most single SQL statements are implicitly executed within a transaction, and
so do not require an explicit one to be created, reducing database round trips."_ So a multi-row
`SaveChanges` either fully commits or fully rolls back.

**Async-first.** Every terminal is offered sync and async: `SaveChanges()` / `SaveChangesAsync()`,
`ToList()` / `ToListAsync()`, `First()` / `FirstAsync()`, `Find()` / `FindAsync()`. The async
variants return `Task<T>` (or `ValueTask<T>` for `AddAsync`/`FindAsync`) and thread a
`CancellationToken`. This is [async in the survey's sense][effects] — a `Task`, run on the
caller's `SynchronizationContext`/thread pool — **not** an [effect value][effects]: there is no
`IO`/`ZIO`/`Effect`/`ConnectionIO` describing the work as data. The call executes when awaited;
its failure set is not in the type.

**Explicit transactions and savepoints.** For multi-`SaveChanges` units of work, `BeginTransaction`
on the `DatabaseFacade` opens one ([`reldbfacade`][reldbfacade], _"Starts a new transaction with a
given `IsolationLevel`"_); everything until `Commit`/`Rollback` shares it. Nesting is via
[savepoints][effects]: `IDbContextTransaction.CreateSavepoint(name)` — _"Creates a savepoint in the
transaction. This allows all commands that are executed after the savepoint was established to be
rolled back, restoring the transaction state to what it was at the time of the savepoint"_
([`src/EFCore/Storage/IDbContextTransaction.cs`][ictx]) — with `RollbackToSavepoint`/`ReleaseSavepoint`.
Savepoint support is provider-optional: the interface's default methods `throw new
NotSupportedException(CoreStrings.SavepointsNotSupported)`, so a provider that lacks them declines
rather than silently degrading.

**Errors are thrown, not typed.** Rust/Scala/Haskell libraries in this survey return a
`Result`/`Either`/effect error channel; EF Core throws. `SaveChanges` surfaces `DbUpdateException`
_"An error is encountered while saving to the database"_ and, for the retryable optimistic-concurrency
case, `DbUpdateConcurrencyException` ([`src/EFCore/DbUpdateConcurrencyException.cs`][concurrency]):

> _"An exception that is thrown when a concurrency violation is encountered while saving to the
> database. A concurrency violation occurs when an unexpected number of rows are affected during
> save. This is usually because the data in the database has been modified since it was loaded into
> memory."_

This is the [exception-based mainstream][effects] — the opposite of the effects-first target: the
error set a query can produce is _not_ reflected in its type; you learn it from `catch` blocks and
documentation, and there is no `isRetryable` flag on the exception (you match the exception type).

**Set-based writes that bypass tracking.** For bulk updates where materializing and tracking every
row is wasteful, `ExecuteUpdate`/`ExecuteDelete` push a set-based `UPDATE … WHERE`/`DELETE … WHERE`
straight to the server from a LINQ query ([`queryext`][queryext]): _"This operation executes
immediately against the database, rather than being deferred until `SaveChanges()` is called. It
also does not interact with the EF change tracker in any way."_ These are the deliberate,
tracking-free door — closer to what `Dapper`/`linq2db` do all the time.

**Relations and the N+1 story.** EF Core loads related data three ways
([concepts § loading strategies][nplusone]): **eager** via `Include`/`ThenInclude` (_"Specifies
related entities to include in the query results"_, [`queryext`][queryext]) which JOINs or issues a
correlated second query; **explicit** via `entry.Reference(...).Load()`; and **lazy** via proxies —
`UseLazyLoadingProxies()` generates runtime subclasses whose virtual navigation getters fire a
query on first access ([`proxies`][proxies]). Lazy loading is the classic [N+1][nplusone] foot-gun:
iterate N parents, touch `parent.Children` in the loop, and you have issued N extra queries where one
`Include` would do. The functional mappers avoid this by making every join explicit; EF Core makes
it convenient and therefore easy to trip over.

---

## Ecosystem & maturity

EF Core is a first-party [.NET Foundation][repo] project maintained by Microsoft, released under
the **MIT** license (`LICENSE.txt` — "Copyright (c) .NET Foundation and Contributors"). It is the
default ORM of the .NET ecosystem, shipped on the same cadence as .NET itself; the pinned tree is
`11.0.0-preview` (`eng/Versions.props`), on the current .NET target
(`Directory.Build.props`). EF Core `1.0` shipped in June 2016 as the cross-platform successor to
the .NET-Framework-only Entity Framework 6 (web-attested); it was a ground-up rewrite, not a port.

The **provider plugin API** is the ecosystem's spine: first-party providers cover SQL Server, SQLite,
Azure Cosmos DB, and the in-memory test provider, while the flagship third-party providers are
**Npgsql** (PostgreSQL — the reference for how far a provider can push the model, with array/JSON/range
support), **Pomelo** (MySQL/MariaDB), and Oracle's official provider ([`README.md`][readme]). The
relational base project (`EFCore.Relational`) carries the shared SQL-generation, migrations, and
update-batching machinery every relational provider inherits; a provider supplies the dialect,
type mappings, and method translations.

Tooling is mature: the `dotnet ef` CLI and the Package Manager Console cmdlets
(`Add-Migration`, `Update-Database`, `Scaffold-DbContext`) drive migrations and reverse-engineering,
and `EF.IsDesignTime` ([`src/EFCore/EF.cs`][efcs]) lets application code detect a design-time tool
run. Within .NET, the deliberately-lighter alternatives this survey contrasts are `Dapper` (a
[micro-mapper][ladder]: raw SQL + auto-bind + hydrate, **no** tracking) and `linq2db` (a LINQ
[query builder][qcm] that translates LINQ to SQL but, again, keeps **no** change tracking) — both
trade EF Core's convenience for predictability and speed. The cross-ecosystem peers are `Hibernate`/
JPA (the JVM data-mapper EF Core most resembles, snapshot dirty-checking and all), `SQLAlchemy`'s ORM
(Python), and `Prisma`/`TypeORM` (TypeScript).

---

## Strengths

- **LINQ is the query language.** Queries are ordinary, type-checked C# expressions with full IDE
  support; no separate DSL or `.sql` files in the common path, and closure values are parameterized
  automatically ([injection][inject]-safe by construction).
- **The unit of work is one call.** Mutate objects, call `SaveChanges` once, and EF Core derives the
  minimal `INSERT`/`UPDATE`/`DELETE` set, batches it, and wraps it in an implicit transaction
  ([`ctx`][ctx], [`batch`][batch], [`autotx`][autotx]).
- **Identity map + snapshot tracking.** One row ↦ one instance within a context; edits are detected by
  comparing against the load-time snapshot, so persistence needs no explicit change-set
  ([`tracker`][tracker], [`entry`][entry]).
- **Code-first migrations with a model diff.** The entities are the schema; the tooling diffs the model
  against a snapshot to emit reversible migration classes ([`differ`][differ], [`modelsnapshot`][modelsnapshot]).
- **Loud translation failures.** Untranslatable LINQ throws rather than silently running in memory —
  a footgun the framework closed in EF Core 3.0 ([`corestrings`][corestrings]).
- **Async-first, everywhere.** Every terminal has a cancellable `…Async` twin; provider-optional
  savepoints give nested-transaction control ([`ictx`][ictx]).
- **First-party, broad provider surface.** Microsoft-maintained, MIT, with providers for SQL Server,
  PostgreSQL, SQLite, MySQL, Cosmos, and more ([`readme`][readme]).

## Weaknesses

- **The LINQ-translation boundary is leaky and runtime-checked.** A query that compiles can throw at
  execution because one expression had no SQL mapping ([`corestrings`][corestrings]) — the expressive
  surface has jagged, runtime-discovered edges.
- **Change-tracking overhead.** The snapshot, identity map, and `DetectChanges` scan cost time and
  memory on every tracking query; read-heavy paths must remember `AsNoTracking()` ([`queryext`][queryext]).
- **Exceptions, not typed errors.** The failure set is not in the type; `DbUpdateException` /
  `DbUpdateConcurrencyException` are thrown, with no `isRetryable`-style modelling — the antithesis of
  the [effects-first][effects] target.
- **No effect value.** `Task<T>` describes _when_ work runs, not _what_ it is or _how_ it fails; there
  is no `IO`/`Effect` to compose, no encoded error union, no scoped-resource guarantee.
- **Lazy loading's N+1 trap.** Convenient virtual navigations make one-query-per-parent easy to write by
  accident ([`proxies`][proxies], [N+1][nplusone]).
- **Migration-snapshot complexity.** The generated `ModelSnapshot` is a stateful file that must stay in
  sync; merge conflicts and hand-edits in it produce confusing diffs ([`modelsnapshot`][modelsnapshot]).
- **`DbContext` is not thread-safe.** One context per unit of work is mandatory, not advisory
  ([`ctx`][ctx]).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                              | Trade-off                                                                                                      |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Queries are [LINQ][linq] expression trees → SQL at runtime       | The host language _is_ the query language; full IDE/type support; params auto-bound    | Not all LINQ is translatable — the untranslatable edge is a **runtime** `TranslationFailed` throw              |
| Snapshot-based [change tracking][orm] over POCOs                 | Entities stay plain objects; no persistence code in the domain; minimal-diff `UPDATE`s | `DetectChanges` scan + snapshot memory on every tracking query; must opt out with `AsNoTracking` for reads     |
| [`DbContext`][ctx] = session + [unit of work][orm] + repository  | One object owns the identity map and the flush; `SaveChanges` is a single atomic call  | Short-lived, single-threaded; wrong lifetime (too long / shared) is the classic EF bug                         |
| [Identity map][orm]: one row ↦ one instance per context          | Consistent object graph; edits can't diverge; `Find` can skip the database             | Only within one context; stale across contexts; the map itself is per-query overhead                           |
| Async is a `Task`, errors are thrown exceptions                  | Idiomatic .NET; mirrors the sync API 1:1; cancellation via `CancellationToken`         | No [effect value][effects], no typed error channel, no `isRetryable` — the effects-first guarantees are absent |
| Code-first: entities are the schema; migrations diff a snapshot  | Single source of truth in C#; reversible, reviewable migration classes                 | The `ModelSnapshot` is stateful and merge-hostile; snapshot drift produces confusing migrations                |
| Loud translation failure (no implicit client eval, since 3.0)    | Prevents silent O(rows) in-memory filtering / accidental full-table pulls              | Some previously-"working" queries now throw; forces an explicit `AsEnumerable()` to opt into client evaluation |
| Raw SQL: safe `FromSql` interpolation + named `FromSqlRaw` hatch | The safe path is the natural one; the unsafe door is explicit and warned               | `FromSqlRaw` with a built string re-opens [injection][inject] — the one door you must reach for deliberately   |
| Lazy loading via runtime proxies (opt-in)                        | Ergonomic navigation access without up-front joins                                     | The [N+1][nplusone] foot-gun; per-access queries hidden behind a property getter                               |

---

## Sources

- [dotnet/efcore — GitHub repository][repo] · [Microsoft Learn: EF Core docs][docs] · [API reference][apidocs]
- [`README.md` — "a modern object-database mapper for .NET … LINQ queries, change tracking, updates, and schema migrations … through a provider plugin API"; the basic-usage program][readme]
- [`src/EFCore/DbContext.cs` — "session … combination of the Unit Of Work and Repository patterns"; `SaveChanges` + auto-`DetectChanges`; single-threaded; `Add`/`Remove`][ctx]
- [`src/EFCore/DbSet.cs` — "LINQ queries … will be translated into queries against the database"; `Find` identity-map behavior; `Attach` state inference][dbset]
- [`src/EFCore/EntityState.cs` — `Detached`/`Unchanged`/`Deleted`/`Modified`/`Added` docstrings][entitystate]
- [`src/EFCore/ChangeTracking/ChangeTracker.cs` — "change tracking information and operations"; `DetectChanges` "Scans the tracked entity instances …"][tracker]
- [`src/EFCore/ChangeTracking/EntityEntry.cs` — `OriginalValues`: "the property values as they were when the entity was retrieved from the database"][entry]
- [`src/EFCore/QueryTrackingBehavior.cs` — `TrackAll` / `NoTracking` / `NoTrackingWithIdentityResolution`][qtb]
- [`src/EFCore/Extensions/EntityFrameworkQueryableExtensions.cs` — `Include`, `AsNoTracking`, `ExecuteUpdate`/`ExecuteDelete` ("does not interact with the EF change tracker")][queryext]
- [`src/EFCore/EF.cs` — `EF.Constant` / `EF.Parameter` (const-vs-parameter control); `EF.IsDesignTime`][efcs]
- [`src/EFCore/Properties/CoreStrings.resx` — `TranslationFailed`: "could not be translated … or switch to client evaluation explicitly …"][corestrings]
- [`src/EFCore/AutoTransactionBehavior.cs` — `WhenNeeded`: implicit transaction per `SaveChanges`][autotx]
- [`src/EFCore/DbUpdateConcurrencyException.cs` — optimistic-concurrency exception docstring][concurrency]
- [`src/EFCore/Storage/IDbContextTransaction.cs` — `CreateSavepoint`/`RollbackToSavepoint`; default `NotSupportedException`][ictx]
- [`src/EFCore/Query/QueryableMethodTranslatingExpressionVisitor.cs` — LINQ-method translation stage][qmt]
- [`src/EFCore.Relational/Query/RelationalQueryTranslationPostprocessor.cs` — SQL-tree post-processing][relpost]
- [`src/EFCore.Relational/Extensions/RelationalQueryableExtensions.cs` — `FromSql` (safe interpolation) vs `FromSqlRaw` ("never pass a concatenated or interpolated string …")][relqueryable]
- [`src/EFCore.Relational/Extensions/RelationalDatabaseFacadeExtensions.cs` — `BeginTransaction`; `GetMigrations`/`GetAppliedMigrations`/`GetPendingMigrations`][reldbfacade]
- [`src/EFCore.Relational/Update/ModificationCommandBatch.cs` — batched `INSERT`/`UPDATE`/`DELETE`; `TryAddCommand`][batch]
- [`src/EFCore.Relational/Migrations/Migration.cs` — migration base class, `InitialDatabase = "0"`, `TargetModel`][migration]
- [`src/EFCore.Relational/Migrations/IMigrationsModelDiffer.cs` — model diff → `MigrationOperation`s][differ]
- [`src/EFCore.Relational/Infrastructure/ModelSnapshot.cs` — the model snapshot migrations diff against][modelsnapshot]
- [`src/EFCore.Relational/Storage/RelationalConnection.cs` — ADO.NET `DbConnection` wrapper][relconn]
- [`src/EFCore/Extensions/EntityFrameworkServiceCollectionExtensions.cs` — `AddDbContext` (scoped), `AddDbContextPool`][services]
- [`src/EFCore.Proxies/ProxiesExtensions.cs` — `UseLazyLoadingProxies` / change-tracking proxies][proxies]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [LINQ][linq] · [injection][inject] · [schema/migrations][schema] · [ORM patterns][orm] · [N+1][nplusone] · [effects & transactions][effects] · [pools/sessions][pool])
- Related deep-dives in this survey: `linq2db` · `Dapper` · `Hibernate` · `SQLAlchemy` · `Prisma` · `SeaORM` · [doobie][doobie] · [Quill][quill] · [Ecto][ecto] · [Effect TS][effect-ts]

<!-- References -->

[repo]: https://github.com/dotnet/efcore
[docs]: https://learn.microsoft.com/ef/core/
[apidocs]: https://learn.microsoft.com/dotnet/api/microsoft.entityframeworkcore
[readme]: https://github.com/dotnet/efcore/blob/main/README.md
[ctx]: https://github.com/dotnet/efcore/blob/main/src/EFCore/DbContext.cs
[dbset]: https://github.com/dotnet/efcore/blob/main/src/EFCore/DbSet.cs
[entitystate]: https://github.com/dotnet/efcore/blob/main/src/EFCore/EntityState.cs
[tracker]: https://github.com/dotnet/efcore/blob/main/src/EFCore/ChangeTracking/ChangeTracker.cs
[entry]: https://github.com/dotnet/efcore/blob/main/src/EFCore/ChangeTracking/EntityEntry.cs
[qtb]: https://github.com/dotnet/efcore/blob/main/src/EFCore/QueryTrackingBehavior.cs
[queryext]: https://github.com/dotnet/efcore/blob/main/src/EFCore/Extensions/EntityFrameworkQueryableExtensions.cs
[efcs]: https://github.com/dotnet/efcore/blob/main/src/EFCore/EF.cs
[corestrings]: https://github.com/dotnet/efcore/blob/main/src/EFCore/Properties/CoreStrings.resx
[autotx]: https://github.com/dotnet/efcore/blob/main/src/EFCore/AutoTransactionBehavior.cs
[concurrency]: https://github.com/dotnet/efcore/blob/main/src/EFCore/DbUpdateConcurrencyException.cs
[ictx]: https://github.com/dotnet/efcore/blob/main/src/EFCore/Storage/IDbContextTransaction.cs
[qmt]: https://github.com/dotnet/efcore/blob/main/src/EFCore/Query/QueryableMethodTranslatingExpressionVisitor.cs
[relpost]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Query/RelationalQueryTranslationPostprocessor.cs
[relqueryable]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Extensions/RelationalQueryableExtensions.cs
[reldbfacade]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Extensions/RelationalDatabaseFacadeExtensions.cs
[batch]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Update/ModificationCommandBatch.cs
[migration]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Migrations/Migration.cs
[differ]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Migrations/IMigrationsModelDiffer.cs
[modelsnapshot]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Infrastructure/ModelSnapshot.cs
[relconn]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Storage/RelationalConnection.cs
[services]: https://github.com/dotnet/efcore/blob/main/src/EFCore/Extensions/EntityFrameworkServiceCollectionExtensions.cs
[proxies]: https://github.com/dotnet/efcore/blob/main/src/EFCore.Proxies/ProxiesExtensions.cs
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[linq]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[schema]: ./concepts.md#schema-migrations-code-generation
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions
[doobie]: ./doobie.md
[quill]: ./quill.md
[ecto]: ./ecto.md
[effect-ts]: ./effect-ts.md

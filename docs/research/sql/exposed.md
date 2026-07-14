# Exposed (Kotlin)

JetBrains's Kotlin SQL framework, offering **two layers over one code-first schema**: a typed, SQL-wrapping **DSL** (`Users.selectAll().where { Users.age greater 30 }` over `Table` objects whose columns are typed `Column<T>`) and an active-record **DAO** (`User.new { }` / `User.findById(id)` entities with lazy-loaded references) — both compiled to parameterized SQL and run inside a thread-local `transaction { }` block.

| Field              | Value                                                                                                                                               |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Kotlin (JVM; requires Kotlin `2.2.+`, JDK 8+ for core modules — [`README.md`][readme])                                                              |
| License            | Apache License 2.0 — [`LICENSE.txt`][license]; JetBrains official project ([`README.md`][readme])                                                   |
| Repository         | [JetBrains/Exposed][repo]                                                                                                                           |
| Documentation      | [jetbrains.com/help/exposed][docs] · [jetbrains.com/exposed][site]                                                                                  |
| Category           | [Typed query builder][ladder] (the DSL) shading up into a [full ORM — active record][ladder] (the DAO)                                              |
| Abstraction level  | Two rungs at once: a typed query builder, plus an active-record entity layer built on top of it ([ladder][ladder])                                  |
| Query model        | [Fluent typed builder][qmodels] over `Table` objects with typed `Column<T>` (DSL); active-record entity methods (DAO)                               |
| Effect/async model | **Blocking JDBC** inside a thread-local `transaction { }` (+ a coroutine `suspendTransaction` bridge and, since `1.0.0`, a reactive **R2DBC** path) |
| Backends           | H2, MariaDB, MySQL, Oracle, PostgreSQL (incl. pgjdbc-ng), SQL Server, SQLite — [`README.md`][readme]                                                |
| First release      | ≈2016 (web-attested, soft)                                                                                                                          |
| Latest version     | pinned checkout is **`1.3.1`** (`org.jetbrains.exposed`, [`gradle.properties`][gradleprops], [`CHANGELOG.md`][changelog]); date web/soft            |

> [!NOTE]
> Exposed is this survey's data point for a library that deliberately ships **both** a
> [typed query builder][qmodels] and a [full active-record ORM][ormpatterns] over the same
> code-first schema, and lets you mix them row by row. Its DSL is the Kotlin analogue of
> `jOOQ`/`Slick` on the construction axis (typed columns, compile-checked references, SQL
> you can read off the call chain); its DAO is the Kotlin analogue of `ActiveRecord`/`GORM`
> (mutable entities, lazy references, an identity-map cache). Unlike the effect-first
> mappers this survey weights most heavily (`doobie`, `Quill`, `Ecto`), Exposed's unit of
> execution is an eagerly-run, **thread-local**
> `transaction { }` block over blocking JDBC — the implicit-context model, and its `1.0`-era
> coroutine/R2DBC bridges, are the interesting tension for an [effects-first][effects] design.

---

## Overview

### What it solves

Exposed sits one rung above a raw JDBC driver and lets a Kotlin program talk to a
relational database without hand-writing SQL strings — while giving you a choice of _how
much_ abstraction you want. The same `object Users : Table()` schema declaration backs two
independent APIs: a **DSL** that reads like SQL (`select`/`where`/`innerJoin`/`groupBy`
over typed columns) and a **DAO** that reads like objects (`User.new { }`, `user.city`,
`User.find { … }`). The self-description ([`README.md`][readme]):

> _"Exposed is a lightweight SQL library on top of a database connectivity driver for the
> Kotlin programming language, with support for both JDBC and R2DBC (since version
> 1.0.0-\*) drivers. It offers two approaches for database access: a typesafe SQL-wrapping
> Domain-Specific Language (DSL) and a lightweight Data Access Object (DAO) API."_

The two modules split the responsibility cleanly. `exposed-core` "includes the
Domain-Specific Language (DSL) API"; `exposed-dao` is "(Optional)" and "only compatible
with `exposed-jdbc` and does not work with `exposed-r2dbc`" ([`README.md`][readme] module
table) — the first structural hint that the DAO is a JDBC-only convenience on top of the
DSL, not a peer of it.

### Design philosophy

The README frames the project's ambition immediately — "Welcome to Exposed, an ORM
framework for Kotlin" ([`README.md`][readme]) — but the body copy above is careful to
call the core a "lightweight SQL library", not an ORM. That tension is deliberate: the DSL
is not object-relational mapping at all (it maps _queries_, not object graphs), while the
DAO layer bolts a genuine active-record ORM on top. A reader must keep the two straight,
because they sit on different [rungs of the abstraction ladder][ladder].

The second design pillar is **dialect portability**. Exposed's mascot is a cuttlefish, and
the metaphor is load-bearing ([`README.md`][readme]):

> _"Exposed can be used to mimic a variety of database engines, which helps you to build
> applications without dependencies on any specific database engine and to switch between
> them with very little or no changes."_

Both APIs render to SQL through a single, dialect-aware builder pipeline (see [Query
construction](#query-construction--injection-safety)), so the same Kotlin query targets
H2, PostgreSQL, MySQL/MariaDB, Oracle, SQL Server, or SQLite. The schema is **code-first**:
the Kotlin `Table`/`IdTable` object _is_ the source of truth, and `SchemaUtils` emits the
DDL from it.

---

## Connection, pooling & resource lifetime

A database is registered with `Database.connect(...)`, which does **not** open a
connection — it stores a connection factory that a `transaction { }` block later draws on
([`README.md`][readme]):

```kotlin
// README.md
Database.connect("jdbc:h2:mem:test", driver = "org.h2.Driver", user = "root", password = "")

transaction {
    SchemaUtils.create(Cities, Users)
    // … DSL / DAO calls, all bound to this transaction's connection …
}
```

`Database.connect` accepts a raw JDBC URL, a `javax.sql.DataSource`, or a connection
lambda; for pooling you hand it a `DataSource` from HikariCP or similar — Exposed does not
implement its own pool. Each `transaction { }` **leases one connection** for the duration
of the block from the resolved `Database` and returns it on commit/rollback/close, so the
connection lifetime is the block's lexical scope. Resolution of _which_ database and
connection a call uses is implicit: if `db` is not passed, the value "will be either the
last `Database` instance created or the value associated with the parent transaction"
([`Transactions.kt`][jdbctx] `transaction` KDoc; `resolveDatabaseOrThrow` falls back to the
thread-local transaction, then to `TransactionManager.primaryDatabase`). Resource cleanup
is a `finally` block (`closeStatementsAndConnection`), not a scoped effect value — the
contrast with the [scoped acquire/release][pools] discipline of the effect systems.

---

## Query construction & injection safety

### The DSL over `Table` and `Column<T>`

Schema and query share one vocabulary. A table is a Kotlin `object` extending `Table`
(base class in [`Table.kt`][table]: `open class Table(name: String = "")`), and each
column-builder method returns a **typed** `Column<T>`:

```kotlin
// README.md — code-first schema, compile-checked columns
object Users : Table() {
    val id = varchar("id", 10)
    val name = varchar("name", length = 50)
    val cityId = integer("city_id").references(Cities.id).nullable()

    override val primaryKey = PrimaryKey(id, name = "PK_User_ID")
}
```

`integer(name)` yields `Column<Int>`, `varchar(name, length)` yields `Column<String>`,
`.nullable()` turns a `Column<T>` into a `Column<T?>`, and `.references(other)` records a
foreign key ([`Table.kt`][table]: `fun integer`, `fun varchar`, `fun <T> Column<T>.nullable`,
`infix fun … references`). Because a column is a first-class typed value, a query that
mentions a non-existent column, or compares a column to the wrong type, is a **compile
error** — the type-checking Exposed shares with `jOOQ`/`Slick`/`Diesel`.

Queries are built by chaining clause methods. `selectAll()` returns a `Query`;
`.where { … }` takes a lambda producing an `Op<Boolean>`; `.select(cols)` narrows the
projection; tables join with the `innerJoin` infix ([`Queries.kt`][queries]:
`fun FieldSet.selectAll(): Query`, `fun ColumnSet.select(...)`; [`Query.kt`][jdbcquery]:
`fun where(predicate: () -> Op<Boolean>)`):

```kotlin
// README.md — DSL query; note the typed predicate and typed row access
(Users innerJoin Cities)
    .select(Users.name, Cities.name)
    .where { Cities.name.eq("St. Petersburg") or Users.cityId.isNull() }
    .forEach { row -> println("${row[Users.name]} lives in ${row[Cities.name]}") }
```

### The expression AST: `Expression`, `Op`, and `SqlExpressionBuilder`

The predicate inside `where { }` is not a `Boolean` — it is a tree. Everything selectable
or comparable descends from `Expression<T>`, whose one job is to append its SQL to a
builder ([`Expression.kt`][expression]):

```kotlin
// exposed-core/.../Expression.kt
abstract class Expression<T> {
    abstract fun toQueryBuilder(queryBuilder: QueryBuilder)
}
```

An `Op<T> : Expression<T>()` is an SQL operator; the comparison operators are concrete
subclasses of `ComparisonOp`, each carrying its SQL sign ([`Op.kt`][op]):

```kotlin
// exposed-core/.../Op.kt
class EqOp(expr1: Expression<*>, expr2: Expression<*>) : ComparisonOp(expr1, expr2, "=")
class LessOp(expr1: Expression<*>, expr2: Expression<*>) : ComparisonOp(expr1, expr2, "<")
class GreaterOp(expr1: Expression<*>, expr2: Expression<*>) : ComparisonOp(expr1, expr2, ">")
class AndOp(expressions: List<Expression<Boolean>>) : CompoundBooleanOp(" AND ", expressions)
```

You never construct those directly — infix builder functions do. `eq`, `less`, `greater`,
`greaterEq`, `like`, `and`, `or`, `isNull`, `between`, `inList` are `infix fun`s that read
like operators ([`OpBuilder.kt`][opbuilder]):

```kotlin
// exposed-core/.../OpBuilder.kt
infix fun <T : Comparable<T>, S : T?> ExpressionWithColumnType<in S>.less(t: T): LessOp =
    LessOp(this, wrap(t))
infix fun Expression<Boolean>.and(op: Expression<Boolean>): Op<Boolean> = /* AndOp(...) */
infix fun <T : String?> Expression<T>.like(pattern: String): LikeEscapeOp = like(LikePattern(pattern))
```

> [!NOTE]
> These operators used to live on a `SqlExpressionBuilder` object (a scoped receiver you
> imported piecemeal). At this pin the `object SqlExpressionBuilder : ISqlExpressionBuilder`
> and every method on the interface are `@Deprecated` — most at `DeprecationLevel.ERROR` —
> in favour of the **top-level functions** above, so modern code just does
> `import org.jetbrains.exposed.v1.core.*` ([`SQLExpressionBuilder.kt`][sqlbuilder]). The
> `v1` package prefix throughout is itself new: the `1.0.0` release re-homed the whole API
> under `org.jetbrains.exposed.v1.*` while splitting JDBC and R2DBC into separate modules.

### Injection safety is structural

The line `Users.age greater 30` never puts `30` into SQL text. `greater(t)` calls
`GreaterOp(this, wrap(t))`, and `wrap` turns the literal into a `QueryParameter`
([`QueryParameter.kt`][queryparam]):

```kotlin
// exposed-core/.../QueryParameter.kt
class QueryParameter<T>(val value: T, override val columnType: IColumnType<T & Any>) :
    ExpressionWithColumnType<T>() {
    override fun toQueryBuilder(queryBuilder: QueryBuilder) {
        queryBuilder { registerArgument(columnType, value) }
    }
}
fun <T, S : T?> ExpressionWithColumnType<in S>.wrap(value: T): QueryParameter<T> =
    QueryParameter(value, columnType as IColumnType<T & Any>)
```

The `QueryBuilder` is "An object to which SQL expressions and values can be appended"
([`Expression.kt`][expression]) and carries a `prepared: Boolean` flag. Registering an
argument in `prepared` mode appends a **placeholder** and stashes the value out-of-band;
only in the non-prepared path is the value stringified into the SQL text
([`Expression.kt`][expression]):

```kotlin
// exposed-core/.../Expression.kt — QueryBuilder.registerArguments (abridged)
if (prepared) {
    _args.add(sqlType to it)
    append(sqlTypeT.parameterMarker(it))   // e.g. "?"  — bound out-of-band
} else {
    append(sqlTypeT.valueToString(it))     // literal text — used for logging/DDL
}
```

So an interpolated Kotlin value can only enter a DSL query as a **bind parameter**; there
is no string to inject into, and the query text and the data travel on separate JDBC
channels ([parameter binding][injection]). `like` is safe the same way — the pattern is
wrapped with `stringParam(...)` (a `QueryParameter`), not spliced
([`OpBuilder.kt`][opbuilder]). The **escape hatch** is explicit: `LiteralOp<T>` inlines
`columnType.valueToString(value)` as raw text ([`LiteralOp.kt`][literalop]), and raw SQL is
run through `Transaction.exec`, which still binds via a typed arg list rather than string
concatenation ([`JdbcTransaction.kt`][jdbctransaction]):

```kotlin
// exposed-jdbc/.../JdbcTransaction.kt — raw-SQL escape hatch, still parameterized
fun exec(
    @Language("sql") stmt: String,
    args: Iterable<Pair<IColumnType<*>, Any?>> = emptyList(),
    explicitStatementType: StatementType? = null
): Unit
```

### The DAO: the same predicates, wrapped in entities

The DAO does not invent a query language — it delegates to the DSL. An entity class pairs a
`Table` with an `Entity` type; queries use the very same `Op<Boolean>` predicates
([`README.md`][readme], [`EntityClass.kt`][entityclass]):

```kotlin
// README.md — DAO: entities over the same schema
class User(id: EntityID<Int>) : IntEntity(id) {
    companion object : IntEntityClass<User>(Users)
    var name by Users.name          // property delegate ↔ column
    var city by City referencedOn Users.city
    var age  by Users.age
}

User.find { Users.age greaterEq 18 }   // Users.age greaterEq 18 is a DSL Op<Boolean>
User.findById(1)                        // find { table.id eq id }.firstOrNull()
```

`EntityClass.findById` is literally `testCache(id) ?: find { table.id eq id }.firstOrNull()`
([`EntityClass.kt`][entityclass]), and `find(op)` wraps a `table.selectAll().where(op)`.
The DAO is therefore an active-record veneer whose _construction_ safety is inherited
wholesale from the DSL — it is `ActiveRecord`-shaped ergonomics with `jOOQ`-shaped
injection safety underneath.

---

## Schema, migrations & code generation

Exposed is **code-first**: the `Table` object is the schema, and `SchemaUtils` turns it
into DDL. `SchemaUtils.create(vararg tables)` issues `CREATE TABLE IF NOT EXISTS …`,
`SchemaUtils.drop(...)` the inverse ([`SchemaUtils.kt`][schemautils], and the README's
generated-SQL block shows the exact `CREATE`/`DROP` output). Keys, indexes, and foreign
keys are ordinary members: `override val primaryKey = PrimaryKey(id)`, `.index()`,
`.references(other)`.

Schema _evolution_, though, is where the pinned checkout is most instructive. The old
one-shot auto-migrator, `SchemaUtils.createMissingTablesAndColumns`, is now `@Deprecated`
([`SchemaUtils.kt`][schemautils]):

> _"To prevent this, please use `MigrationUtils.statementsRequiredForDatabaseMigration()`
> with a third-party migration tool (e.g., Flyway). `MigrationUtils` is accessible with a
> dependency on `exposed-migration-jdbc`."_

That is a genuine design retreat, and a finding: Exposed has moved _away_ from silently
`ALTER`-ing your database toward **generating** the migration statements
(`exposed-migration-core` / `-jdbc` / `-r2dbc` modules) and letting a real migration runner
(Flyway/Liquibase) version and apply them. There is a new `exposed-gradle-plugin` for
migration workflows ([`CHANGELOG.md`][changelog], `1.3.0`). So the schema stance is
code-first for _description_ but explicitly defers _versioned migration_ to the ecosystem —
the same boundary `Slick` draws, arrived at by deprecating the feature that used to cross it.
Database-first codegen (generating `Table` objects from a live schema) is likewise a
plugin-level concern, not a core feature.

---

## Type mapping & result decoding

Every column carries an `IColumnType<T>` (concrete `ColumnType<T>`) that owns the two-way
conversion: `valueToString` / `parameterMarker` on the way to SQL, and value readers on the
way back ([`ColumnType.kt`][columntype]). Because `Column<T>` is typed, a **result row is
read by column key with full types** — `row[Users.name]` is a `String`, `row[Users.cityId]`
an `Int?` ([`ResultRow.kt`][resultrow]); there is no positional indexing or casting in
application code.

**Nullability lives in the type system.** `.nullable()` returns `Column<T?>`, and the
`references(...).nullable()` chain in the README's `Users.cityId` produces a `Column<Int?>`,
so the compiler forces a null check when you read it (`if (row[Users.cityId] != null)`).
Optional references map to Kotlin `T?`; required ones do not.

For the DAO, decoding is **row hydration** into an entity: `EntityClass.wrapRow(row)`
builds an `Entity` and populates its cached `ResultRow`, and entity properties are read
through Kotlin property delegates (`var name by Users.name`) whose `getValue`/`setValue`
proxy the underlying `Column` ([`Entity.kt`][entity], [`EntityClass.kt`][entityclass]). Ids
are wrapped in an `EntityID<T>` (`IntIdTable` gives an auto-increment `Column<EntityID<Int>>`)
so an entity's identity is a typed value, not a bare `Int`.

---

## Effect model, transactions & error handling

This is where Exposed differs most sharply from the effect-first mappers, and it is the
dimension that matters most to this survey.

**Execution is eager and blocking.** `transaction { }` is a plain function whose body is a
receiver lambda, run immediately on the calling thread over blocking JDBC — there is no
description value, no `IO`, no deferred plan ([`Transactions.kt`][jdbctx]):

```kotlin
// exposed-jdbc/.../transactions/Transactions.kt
fun <T> transaction(
    db: Database? = null,
    transactionIsolation: Int? = db?.transactionManager?.defaultIsolationLevel,
    readOnly: Boolean? = db?.transactionManager?.defaultReadOnly,
    statement: JdbcTransaction.() -> T
): T
```

The block returns `T` directly. Its steps — every DSL `select`, every DAO `new`/`flush` —
happen as side effects the moment they are called. Where `doobie`/`Quill` build a
`ConnectionIO`/`ZIO` value you interpret at the edge, Exposed _is_ the edge.

**The transaction context is implicit and thread-local.** Neither the DSL nor the DAO takes
a transaction parameter; they read "the current transaction" from a per-thread stack
([`ThreadLocalTransactionsStack.kt`][tlstack]):

> _"Each thread keeps its own stack so transactions are isolated per thread. Coroutines
> that hop threads must pair every push with a pop to avoid leaks."_

`transaction { }` pushes its transaction onto that stack (`withThreadLocalTransaction`),
and `TransactionManager.current()` / `currentOrNull()` reads the top. This is the model's
central ergonomic bargain: query code is terse (no plumbing) but its correctness depends on
an **ambient** value the type system cannot see — the classic active-record trade-off, and
the reason the docstring above warns about coroutine thread-hops.

**Commit, rollback, and automatic retry.** The block commits on normal return and rolls
back on any throwable, rethrowing it ([`Transactions.kt`][jdbctx],
`executeTransactionWithErrorHandling`: `catch (cause: SQLException)` → `rollback…` → `throw`).
A top-level transaction is additionally wrapped in a **retry loop**: on `SQLException` it
retries up to `maxAttempts` with a randomized back-off delay (`Thread.sleep`) before giving
up — built-in handling for transient serialization failures, which the effect systems leave
to a `retry` combinator.

**Nested transactions use savepoints, opt-in.** A `transaction { }` inside another one does
_not_ start a second physical transaction by default. `newTransaction(outerTransaction)`
returns the outer transaction unless nesting is enabled ([`TransactionManager.kt`][jdbctm]):

> _"The returned value may be a new transaction, or it may return the [outerTransaction] if
> called from within an existing transaction with the database not configured to
> `useNestedTransactions`."_

When `DatabaseConfig.useNestedTransactions` **is** set, the inner transaction takes a JDBC
`SAVEPOINT` and rolls back to it independently ([`TransactionManager.kt`][jdbctm]:
`useSavePoints = outerTransaction != null && db.useNestedTransactions;
savepoint = connection.setSavepoint(...)`). So [savepoint-based nesting][savepoint] exists,
but is a config flag, and the default is "inner block joins the outer transaction".

**Errors are thrown exceptions, not a typed channel.** A database failure surfaces as
`ExposedSQLException : SQLException`, carrying the offending statement contexts
(`causedByQueries()`) for logging ([`Exceptions.kt`][exceptions]). There is no typed
`Either`/`Effect`-style error set — the failure model is JDBC's checked-exception
lineage, handled with `try`/`catch`, exactly the mainstream this survey's
[typed-error][effects] libraries react against.

**The async bridges.** Two escape routes from the blocking model exist:

1. **Coroutines over JDBC.** `suspend fun suspendTransaction(...)` runs the same JDBC work
   but carries the transaction in a **`CoroutineContext` element** rather than the
   thread-local stack, so it survives thread hops; it uses `delay` instead of `Thread.sleep`
   for retry back-off and cleans up under `withContext(NonCancellable)`
   ([`Transactions.kt`][jdbctx], [`JdbcTransactionManager.kt`][jdbctmgr]
   `createTransactionContext`). The older `newSuspendedTransaction` /
   `suspendedTransactionAsync` / `withSuspendTransaction` helpers still exist but are
   `@Deprecated` in favour of `suspendTransaction` ([`Suspended.kt`][suspended]).
2. **Native reactive via R2DBC.** Since `1.0.0`, the separate `exposed-r2dbc` module
   provides its own `suspend fun suspendTransaction(...)` over `R2dbcTransaction`, a
   genuinely non-blocking driver path ([`r2dbc/…/Transactions.kt`][r2dbctx]). It is the
   real answer to "async Exposed" — but the **DAO does not work with R2DBC**
   ([`README.md`][readme]), so the entity layer stays JDBC-and-blocking-only.

---

## Ecosystem & maturity

Exposed is a long-running JetBrains project, published under `org.jetbrains.exposed` and
licensed **Apache 2.0** ([`LICENSE.txt`][license], [`README.md`][readme] badge and
contribution clause). The pinned checkout is version **`1.3.1`** ([`gradle.properties`][gradleprops]),
part of the `1.x` line whose headline `1.0.0` change was a **modularization and namespace
split**: the API moved under `org.jetbrains.exposed.v1.*`, JDBC and R2DBC became distinct
transport modules, and DAO became strictly optional. The module set is broad
([`settings.gradle.kts`][settings], [`README.md`][readme]): `exposed-core`, `exposed-dao`,
`exposed-jdbc`, `exposed-r2dbc`, plus extensions `exposed-json`, `exposed-crypt`,
`exposed-money`, three date-time bindings (`exposed-java-time`, `exposed-kotlin-datetime`,
`exposed-jodatime`), the migration trio (`exposed-migration-core`/`-jdbc`/`-r2dbc`), an
`exposed-gradle-plugin`, and Spring Boot / Spring transaction starters.

The six-plus supported databases — H2, MariaDB, MySQL, Oracle, PostgreSQL (also via
pgjdbc-ng), SQL Server, SQLite — are the JDBC engines the cuttlefish "mimics"
([`README.md`][readme]). Exposed predates Kotlin's 1.0 stabilization era (first public
releases ≈2016, web-attested) and is widely used in the Kotlin/JVM server ecosystem; the
current requirement is Kotlin `2.2.+` ([`README.md`][readme]).

---

## Strengths

- **Two APIs, one schema.** The DSL (typed, SQL-shaped) and the DAO (active-record objects)
  share one `Table` declaration and can be mixed freely; you pick the abstraction per query.
- **Compile-checked, injection-proof queries.** Columns are typed `Column<T>`; a bad column
  or type mismatch is a compile error, and interpolated values become bind parameters via
  `QueryParameter`/`wrap` — there is no SQL string to inject into.
- **Dialect portability.** One builder pipeline renders to H2/PostgreSQL/MySQL/…, so an app
  can switch engines "with very little or no changes" ([`README.md`][readme]).
- **Code-first ergonomics.** `SchemaUtils.create`/`drop` derive DDL straight from the Kotlin
  `Table` objects; no separate schema file to keep in sync.
- **Idiomatic Kotlin surface.** Property delegates (`var name by Users.name`), infix
  operators (`age greater 30`), and lambda-with-receiver blocks make both APIs read naturally.
- **Built-in transaction niceties.** Automatic rollback-on-throw, transient-error retry with
  back-off, isolation-level and read-only knobs, and opt-in savepoint nesting.
- **Modern async on-ramps.** A coroutine `suspendTransaction` bridge and a first-class,
  non-blocking R2DBC path (since `1.0.0`).

## Weaknesses

- **Implicit thread-local context.** The active transaction/connection is ambient, not a
  value; correctness depends on an invisible thread-local, which is exactly what makes
  coroutine thread-hops and multi-database setups error-prone (the docstring warns of leaks).
- **Blocking-first; the DAO can't go reactive.** The default model occupies a thread per
  query; R2DBC is non-blocking but **DAO is JDBC-only** ([`README.md`][readme]), so the
  entity layer stays blocking.
- **Exception-based errors.** Failures are `ExposedSQLException`/`SQLException` thrown at
  runtime — no typed error channel, unlike `doobie`/`Quill`/Effect-TS.
- **DAO lazy-loading and N+1.** References load on access (`referrersOn`/`referencedOn`
  delegates run a query when touched — [`References.kt`][references]), so the classic
  [N+1 problem][nplusone] and identity-map surprises apply, as with any active-record ORM.
- **No built-in migration runner.** The one-shot `createMissingTablesAndColumns` is
  deprecated; real schema evolution needs `MigrationUtils` + Flyway/Liquibase
  ([`SchemaUtils.kt`][schemautils]).
- **API churn.** The `1.0.0` `v1.*` re-namespacing, the JDBC/R2DBC split, and the wholesale
  deprecation of the `SqlExpressionBuilder` receiver mean pre-`1.0` tutorials mislead.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                     | Trade-off                                                                                     |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **Two APIs (DSL + DAO) over one code-first `Table`**            | Let users choose SQL-shaped queries or object-shaped entities per use case    | Two mental models; the DAO's active-record semantics leak (lazy loading, identity map)        |
| **DSL = typed `Column<T>` + `Op` AST**                          | Compile-checked references and structurally injection-proof queries           | More ceremony than raw SQL; the operator/builder surface is large and (at `1.0`) in flux      |
| **Values become `QueryParameter` (bound), literals are opt-in** | Parameter binding by default; injection is structurally impossible in the DSL | Raw text needs an explicit `LiteralOp`/`exec` escape hatch                                    |
| **Eager, blocking `transaction { }`**                           | Simple, direct, JDBC-native; results are plain `T`                            | Not an effect value; occupies a thread; composes by imperative sequencing, not `flatMap`      |
| **Thread-local (ambient) transaction context**                  | Terse query code — no transaction/connection plumbing to pass                 | Correctness hinges on an invisible thread-local; coroutine thread-hops risk leaks             |
| **Exceptions for errors (`ExposedSQLException`)**               | Familiar JDBC lineage; interops with `try`/`catch` and Spring                 | No typed error set; failures are untyped runtime throwables                                   |
| **Nested `transaction {}` = savepoint, opt-in**                 | Deterministic default (inner joins outer); real nesting available on a flag   | Surprising default; independent inner rollback needs `useNestedTransactions = true`           |
| **Async via coroutine bridge + separate R2DBC module**          | A non-blocking path without rewriting the DSL                                 | DAO stays JDBC-only; two async stories (coroutines-over-JDBC vs native R2DBC) to understand   |
| **Code-first schema; migrations delegated**                     | `Table` object is the single source of truth; DDL generated by `SchemaUtils`  | No versioned migration runner in core — `createMissingTablesAndColumns` deprecated for Flyway |

---

## Sources

- [JetBrains/Exposed — GitHub repository][repo] · [official documentation][docs] · [product page][site]
- [`README.md` — positioning ("lightweight SQL library"/"ORM framework"), DSL & DAO examples, module table, supported databases, license][readme]
- [`LICENSE.txt` — Apache License 2.0][license] · [`gradle.properties` — group/version `1.3.1`][gradleprops] · [`CHANGELOG.md`][changelog] · [`settings.gradle.kts` — module list][settings]
- [`Expression.kt` — `QueryBuilder` (`prepared` flag, `registerArguments`), `Expression<T>`][expression]
- [`Op.kt` — `Op`, `ComparisonOp`, `EqOp`/`LessOp`/`GreaterOp`, `AndOp`/`OrOp`][op] · [`OpBuilder.kt` — top-level `eq`/`less`/`and`/`like` infix builders][opbuilder]
- [`QueryParameter.kt` — `QueryParameter<T>` + `wrap` (bind-parameter path)][queryparam] · [`LiteralOp.kt` — raw-text escape][literalop] · [`SQLExpressionBuilder.kt` — deprecated `SqlExpressionBuilder` receiver][sqlbuilder]
- [`Table.kt` — `Table`, `integer`/`varchar`/`references`/`nullable`, `PrimaryKey`][table] · [`ColumnType.kt`][columntype] · [`ResultRow.kt`][resultrow]
- [`jdbc/Query.kt` — DSL `Query`/`where`][jdbcquery] · [`jdbc/Queries.kt` — `selectAll`/`select`/`deleteWhere`][queries] · [`jdbc/SchemaUtils.kt` — `create`/`drop`, deprecated `createMissingTablesAndColumns`][schemautils]
- [`jdbc/JdbcTransaction.kt` — `exec` raw-SQL escape][jdbctransaction] · [`jdbc/transactions/Transactions.kt` — `transaction`/`suspendTransaction`, retry loop, rollback][jdbctx] · [`jdbc/transactions/TransactionManager.kt` — nested savepoints][jdbctm] · [`jdbc/transactions/JdbcTransactionManager.kt` — coroutine context][jdbctmgr] · [`jdbc/transactions/experimental/Suspended.kt` — deprecated coroutine helpers][suspended]
- [`core/transactions/ThreadLocalTransactionsStack.kt` — the thread-local model][tlstack] · [`Exceptions.kt` — `ExposedSQLException`][exceptions] · [`r2dbc/…/Transactions.kt` — reactive path][r2dbctx]
- [`dao/EntityClass.kt` — `new`/`find`/`findById`/`wrapRow`][entityclass] · [`dao/Entity.kt` — property delegates, `flush`][entity] · [`dao/References.kt` — lazy `referencedOn`/`referrersOn`][references] · [`dao/EntityCache.kt` — identity map][entitycache]
- [Concepts][concepts]: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [effects, transactions & errors][effects] · [ORM patterns][ormpatterns] · [N+1][nplusone] · [pools & sessions][pools] · [savepoints][savepoint]

<!-- References -->

[repo]: https://github.com/JetBrains/Exposed
[docs]: https://www.jetbrains.com/help/exposed/home.html
[site]: https://www.jetbrains.com/exposed/
[readme]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/README.md
[license]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/LICENSE.txt
[gradleprops]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/gradle.properties
[changelog]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/CHANGELOG.md
[settings]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/settings.gradle.kts
[expression]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/Expression.kt
[op]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/Op.kt
[opbuilder]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/OpBuilder.kt
[queryparam]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/QueryParameter.kt
[literalop]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/LiteralOp.kt
[sqlbuilder]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/SQLExpressionBuilder.kt
[table]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/Table.kt
[columntype]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/ColumnType.kt
[resultrow]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/ResultRow.kt
[jdbcquery]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-jdbc/src/main/kotlin/org/jetbrains/exposed/v1/jdbc/Query.kt
[queries]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-jdbc/src/main/kotlin/org/jetbrains/exposed/v1/jdbc/Queries.kt
[schemautils]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-jdbc/src/main/kotlin/org/jetbrains/exposed/v1/jdbc/SchemaUtils.kt
[jdbctransaction]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-jdbc/src/main/kotlin/org/jetbrains/exposed/v1/jdbc/JdbcTransaction.kt
[jdbctx]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-jdbc/src/main/kotlin/org/jetbrains/exposed/v1/jdbc/transactions/Transactions.kt
[jdbctm]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-jdbc/src/main/kotlin/org/jetbrains/exposed/v1/jdbc/transactions/TransactionManager.kt
[jdbctmgr]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-jdbc/src/main/kotlin/org/jetbrains/exposed/v1/jdbc/transactions/JdbcTransactionManager.kt
[suspended]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-jdbc/src/main/kotlin/org/jetbrains/exposed/v1/jdbc/transactions/experimental/Suspended.kt
[tlstack]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/transactions/ThreadLocalTransactionsStack.kt
[exceptions]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-core/src/main/kotlin/org/jetbrains/exposed/v1/core/Exceptions.kt
[r2dbctx]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-r2dbc/src/main/kotlin/org/jetbrains/exposed/v1/r2dbc/transactions/Transactions.kt
[entityclass]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-dao/src/main/kotlin/org/jetbrains/exposed/v1/dao/EntityClass.kt
[entity]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-dao/src/main/kotlin/org/jetbrains/exposed/v1/dao/Entity.kt
[references]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-dao/src/main/kotlin/org/jetbrains/exposed/v1/dao/References.kt
[entitycache]: https://github.com/JetBrains/Exposed/blob/b801a8acd3afe85b7c6ec6215d972ae525934065/exposed-dao/src/main/kotlin/org/jetbrains/exposed/v1/dao/EntityCache.kt
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[effects]: ./concepts.md#effects-transactions-and-error-handling
[ormpatterns]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[pools]: ./concepts.md#connections-pools-and-sessions
[savepoint]: ./concepts.md#effects-transactions-and-error-handling

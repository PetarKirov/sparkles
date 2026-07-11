# jOOQ (Java)

Java's typed SQL DSL: an _internal DSL_ that models the SQL language as a type-safe Java API, with the schema **reverse-engineered from your live database** into generated `Tables` and typed `Record`s, so that a `create.select(BOOK.TITLE).from(BOOK).where(BOOK.ID.eq(1)).fetch()` query is checked at compile time and a wrong column or value type is a _compile error_.

| Field              | Value                                                                                                                                                                                                                           |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Java (pinned `pom.xml` builds at `<release>25</release>`); first-class Kotlin & Scala DSL extension modules (`jOOQ-kotlin2`, `jOOQ-scala_3.5`)                                                                                  |
| License            | **Dual**: Apache-2.0 for open-source databases; **commercial** for the rest — [`LICENSE`][license]; `SQLDialect.commercial()` flags per-dialect ([`SQLDialect.java`][dialect])                                                  |
| Repository         | [jOOQ/jOOQ][repo]                                                                                                                                                                                                               |
| Documentation      | [jooq.org manual][docs] · [Javadoc][javadoc]                                                                                                                                                                                    |
| Category           | [Typed query builder][ladder] with **database-first code generation** ([schema-ownership][schemamig]); secondary micro-mapper (`UpdatableRecord` CRUD)                                                                          |
| Abstraction level  | Typed query builder — above a driver, below a full ORM ([ladder][ladder])                                                                                                                                                       |
| Query model        | [Fluent typed builder][qmodels] — method chains mirroring SQL clauses over a `QueryPart` model, rendered to dialect SQL at **runtime**                                                                                          |
| Effect/async model | **Blocking JDBC** by default (methods marked `@Blocking`); an opt-in **reactive R2DBC** path where every `ResultQuery` is a reactive-streams `Publisher`                                                                        |
| Backends           | 30+ RDBMS. Free (Apache-2.0): PostgreSQL, MySQL, MariaDB, SQLite, H2, HSQLDB, Derby, Firebird, CUBRID, DuckDB, ClickHouse, Trino, YugabyteDB, Ignite. Commercial: Oracle, SQL Server, DB2, Sybase, HANA, Redshift, Snowflake, … |
| First release      | jOOQ 1.0 ≈2009 (Lukas Eder) — web-attested                                                                                                                                                                                      |
| Latest version     | pinned checkout is `3.22.0-SNAPSHOT`; current stable line is 3.20.x — web/soft                                                                                                                                                  |

> [!NOTE]
> jOOQ is this survey's data point for the **db-first, code-generated** flavour of a [typed
> query builder][qmodels]. Where `Slick`/`Diesel` describe the schema in host-language code
> (`Table` subclasses, the `table!` macro), jOOQ's signature move is the opposite: a live
> database is the source of truth, and `jOOQ-meta`/`jOOQ-codegen` **introspect** it into
> typed `Tables`/`Record`s that mirror it exactly. On the construction axis it is the closest
> JVM analogue to `Diesel`; the TypeScript type-only analogue is `Kysely`. Unlike the
> effect-value mappers (`doobie`, `Quill`-ZIO, `Effect TS`), jOOQ executes on **blocking
> JDBC** and signals failure by throwing an unchecked `DataAccessException` — so it is the
> survey's clearest example of a compile-time-safe _construction_ layer bolted onto a
> classical _exception-based, blocking_ execution model (with a newer reactive R2DBC path).

---

## Overview

### What it solves

jOOQ's thesis is that SQL is already a good language and should be written _as_ SQL —
type-checked, auto-completed, and dialect-portable — rather than hidden behind an object
graph. The repository's own one-line description states the category directly
([`README.md`][readme]):

> _"jOOQ is an internal DSL and source code generator, modelling the SQL language as a type
> safe Java API to help you write better SQL."_

Two features carry the whole design, and the README names them as the primary pair
([`README.md`][readme]): _"The source code generator"_ and _"The DSL API for type safe query
construction … and dynamic SQL"_. The generator introspects your database and emits typed
column/table constants; the DSL then lets you assemble queries out of those constants with
IDE completion and compiler checking ([`README.md`][readme]):

> _"jOOQ's main feature is typesafe, embedded SQL, allowing for IDE auto completion of SQL
> syntax … as well as of schema meta data"_

The payoff is that the query and the schema are checked together. The README's `MULTISET`
example fetches films with nested actor and category collections in one type-safe query and
concludes ([`README.md`][readme]):

> _"The query is completely type safe. Change a column type, name, or the target DTO, and it
> will stop compiling! Trust only your own eyes"_

### Design philosophy

jOOQ deliberately sits _below_ an ORM. It does not persist an object graph, does not do
change tracking, and does not abstract SQL away — it makes SQL a first-class, typed API. The
`DSLContext` Javadoc frames the design around one idea: objects created from a context are
_attached_ and _fluently executable_, so the code you write reads like the SQL it becomes
([`DSLContext.java`][dslcontext]):

> _"objects created from a `DSLContext` will be \"attached\" to the `DSLContext`'s
> `configuration()`, such that they can be executed immediately in a fluent style."_

with the canonical shape given right there ([`DSLContext.java`][dslcontext]):

```java
// jOOQ: DSLContext.java (class Javadoc)
DSLContext create = DSL.using(connection, dialect);

// Immediately fetch results after constructing a query
create.selectFrom(MY_TABLE).where(MY_TABLE.ID.eq(1)).fetch();
```

The recommended ergonomics are static imports of the `DSL` factory so client code reads like
SQL keywords ([`DSL.java`][dsl]): _"For increased fluency and readability of your jOOQ client
code, it is recommended that you static import all methods from the `DSL`."_ The whole API is
organized so a `SELECT` clause reads top-to-bottom as `select … from … join … on … where …
group by … having … order by … limit`, which the `SelectFromStep` Javadoc demonstrates by
placing a raw SQL statement next to its verbatim jOOQ equivalent ([`SelectFromStep.java`][fromstep]).

---

## Connection, pooling & resource lifetime

jOOQ does **not** own a connection pool. A `DSLContext` is created over a `Configuration`
whose `ConnectionProvider` SPI abstracts the JDBC `Connection` lifecycle; jOOQ leases and
returns connections around each execution ([`ConnectionProvider.java`][connprovider]):

> _"jOOQ will try to acquire a new JDBC `Connection` from the connection provider as early as
> needed, and will release it as early as possible."_

Two built-ins cover the common cases ([`Configuration.java`][configuration]): a
`DefaultConnectionProvider` that _"wraps a single JDBC `Connection`. Ideal for batch
processing"_, and a `DataSourceConnectionProvider` that _"wraps a JDBC `DataSource`. Ideal for
use with connection pools, Java EE, or Spring."_ Pooling is thus delegated wholesale to an
external `DataSource` (HikariCP, Agroal, c3p0, …): the `DataSourceConnectionProvider` is _"A
default implementation for a pooled `DataSource`-oriented `ConnectionProvider`"_ that closes
each connection after execution _"in order to return the connection to the connection pool"_
([`DataSourceConnectionProvider.java`][dscp]). This is the JDBC/Spring resource model, not the
scoped acquire/release discipline the [effect systems][pools] use — a leaked connection is
prevented by jOOQ's release-early convention and try-with-resources, not by a type-level
`Scope`/`Resource`. For the reactive path, `DSL.using(ConnectionFactory)` swaps the JDBC
`ConnectionProvider` for an R2DBC `ConnectionFactory` ([`DSL.java`][dsl]).

---

## Query construction & injection safety

The construction surface is a **fluent typed builder** over an immutable `QueryPart` model.
`QueryPart` is _"The common base type for all objects that can be used for query
composition"_ ([`QueryPart.java`][querypart]); `Field<T>` is _"A column expression"_ carrying
its SQL type as the parameter `T` ([`Field.java`][field]); `Table<R>` is a table producing a
record type `R` ([`Table.java`][table]); and `Condition` is _"A condition or predicate"_ that,
tellingly, `extends Field<Boolean>` ([`Condition.java`][condition]). Queries are assembled
through a chain of **step interfaces** (`SelectSelectStep` → `SelectFromStep` →
`SelectJoinStep` → `SelectWhereStep` → `SelectConditionStep` → …), each returning the next
legal step, so the builder can only be driven in a SQL-shaped order.

**Type safety comes from two mechanisms.** First, `select(…)` is _generically typed on its
projection_: selecting one field yields a `SelectSelectStep<Record1<T1>>`, two fields a
`Record2<T1, T2>`, and so on up to `Record22` ([`DSLContext.java`][dslcontext]):

```java
// jOOQ: DSLContext.java
<T1> SelectSelectStep<Record1<T1>> select(SelectField<T1> field1);
<T1, T2> SelectSelectStep<Record2<T1, T2>> select(SelectField<T1> field1, SelectField<T2> field2);
```

So the projected column types flow into the result `Record` type at compile time — the same
degree-`N` phantom-typed record trick as `Kysely`/`Squeal`, realized here with 22 concrete
`RecordN` interfaces because Java has no variadic generics. Second, comparison operators are
_typed on the field's own `T`_. `Field<T>.eq` accepts only a value of type `T`, another
`Field<T>`, or a `Select` of `Record1<T>` ([`Field.java`][field]):

```java
// jOOQ: Field.java
Condition eq(T arg2);                          // a value of the column's own type
Condition eq(Field<T> arg2);                   // another column of the same type
Condition eq(Select<? extends Record1<T>> arg2); // a scalar subquery of the same type
```

Comparing `BOOK.ID` (a `Field<Integer>`) to a `String` therefore does not compile. A
mistyped column, a column from a table not in the `FROM` clause, or a type-mismatched
predicate are all rejected by `javac`, which is exactly the "change a column type … and it
will stop compiling" guarantee the README advertises.

**Injection safety is structural: user values never enter the SQL text.** Any value you pass
to an operator is wrapped as a **bind value** (`Param<T>`) that renders as a placeholder, not
as SQL ([`Param.java`][param]):

> _"Behind the scenes, jOOQ wraps the value in a bind value expression using
> `DSL#val(Object)`. … By default, a parameter marker `?` is generated."_

The rendering is visible in the engine: a `Val` renders itself to the JDBC placeholder
string, whose default is literally `"?"`, and separately registers its value on the
`BindContext` for out-of-band binding ([`Val.java`][val]):

```java
// jOOQ: impl/Val.java — getBindVariable(...)
if (ctx.paramType() == NAMED || ctx.paramType() == NAMED_OR_INLINED) {
    String prefix = defaultIfNull(ctx.settings().getRenderNamedParamPrefix(), ":");
    // ... ":name" or ":index"
}
else {
    return "?";
}
```

A `Configuration` drives this as a two-context render/bind pass — _"a `RenderContext` to
render `Query` objects and `QueryPart`s"_ and _"a `BindContext` to bind values to `Query`
objects and `QueryPart`s"_ ([`Configuration.java`][configuration]) — so the query text and the
data travel on separate channels, the [prepared-statement safety property][injection].

The **escape hatches** are Plain SQL templating and inlining, both explicit. `DSL.inline(…)`
forces a value into the SQL text but still escapes it — _"you can expect `value` to be
properly escaped for SQL syntax correctness and SQL injection prevention"_, e.g.
`inline("abc'def")` renders `'abc''def'` ([`DSL.java`][dsl]). By contrast the plain-SQL
`DSL.field(String)` splices text **verbatim** (`field("abc'def")` renders `abc'def`), which
is the one place a user reintroduces injection risk. jOOQ ships an optional compile-time guard
against exactly this: the `jOOQ-checker` module's `PlainSQLChecker` (a Checker Framework
plugin) flags plain-SQL API usage, and its `SQLDialectChecker` cross-checks a use-site
`@Require` dialect against each method's declaration-site `@Support` annotation
([`SQLDialectChecker.java`][dialectchecker]) — turning the `@Support` metadata, otherwise _"A
formal declaration of whether any API element is supported by a given `SQLDialect`"_
([`Support.java`][support]), into an enforced dialect-portability check.

### Dynamic SQL and the model API

Because a query is a tree of immutable `QueryPart`s, not a string, jOOQ supports **dynamic
SQL** (conditionally appending clauses/predicates) and a **model API** for traversing and
replacing parts of a query ([`README.md`][readme]). The same reified tree is what lets one
Java query render to 30+ dialects (below) and what powers jOOQ's SQL parser/translator and
pattern-based SQL transformations.

---

## Schema, migrations & code generation

This is jOOQ's defining move and the reason it anchors the **db-first** corner of the
[schema-ownership question][schemamig]. The `jOOQ-meta` module models a live database — a
`Database` is `AutoCloseable` and exposes `getConnection()`/`setConnection(Connection)` plus
`getSchemata()`, `getTables()`, and key/constraint accessors ([`Database.java`][metadb]), with
per-table columns hanging off each `TableDefinition.getColumns()` — and `jOOQ-codegen`'s
`JavaGenerator` walks that model and emits
typed Java. Its Javadoc states its role and its extensibility ([`JavaGenerator.java`][javagen]):

> _"A default implementation for code generation. … Replace this code with your own logic, if
> you need your database schema represented in a different way."_

The generator's run log enumerates exactly what it produces from the introspected schema
([`JavaGenerator.java`][javagen]): `tables`, `records`, `keys`, `pojos`, and `daos`. So from a
live PostgreSQL/MySQL/… database jOOQ generates, per table, a table reference (used as
`FILM`, `ACTOR` in queries), a typed `TableRecord`/`UpdatableRecord`, a `Keys` holder for
primary/foreign keys, and optionally POJOs and DAOs. **The database is the source of truth;
the generated code mirrors it.** Rename a column in the DB, regenerate, and every query that
referenced the old name stops compiling — the compile-time safety net is only as good as the
regeneration step, which is the trade-off of db-first codegen (a build phase that must be
re-run on schema change).

jOOQ does not force a live connection as the only input: `jOOQ-meta-extensions` can
introspect a **DDL script** (`.sql` files) or **JPA entities**
(`jOOQ-meta-extensions-hibernate`) or **Liquibase** changelogs
(`jOOQ-meta-extensions-liquibase`) instead of a running database — so "the schema" can be a
SQL file or ORM annotations, still consumed db-first-style by the same generator.

For schema _evolution_, jOOQ has grown its own **migrations** API (`Migration`, `Migrations`,
`Version`, and a `jOOQ-migrations` module with Git integration), but it is still marked
`@Experimental` — _"This is EXPERIMENTAL functionality and subject to change in future jOOQ
versions"_ ([`Migration.java`][migration]). In practice jOOQ pairs with Flyway/Liquibase for
migrations far more often than it runs them itself; DDL statement generation (`CREATE`/`ALTER`
as `QueryPart`s) has long been supported, but a mature, batteries-included migration runner is
not jOOQ's historical strength.

---

## Type mapping & result decoding

A `Record` _"combines a list of columns (`Field`) with a corresponding list of values, each
value being of the respective field's type"_ ([`Record.java`][record]), and a `Result<R>` is
_"A wrapper for database results"_ that literally `extends List<R>` — a result is an eager,
in-memory `List` of records ([`Result.java`][result]). When you project specific columns, the
record type is structural: _"Records with degree ≤ 22 are reflected by jOOQ through the
`Record1`, `Record2`, … `Record22` classes"_ ([`Record.java`][record]), so
`ctx.select(FILM.TITLE, FILM.LENGTH).from(FILM).fetch()` yields a `Result<Record2<String,
Integer>>` whose `value1()`/`value2()` accessors are typed.

Mapping records to your own types goes through a `RecordMapper` — _"a mapper that can receive
`Record` objects, when fetching data from the database, transforming them into a custom type
`<E>`"_ ([`RecordMapper.java`][recordmapper]) — invoked behind `fetchInto(Class)`,
`into(Class)`, and the `Records.mapping(…)` constructor-reference helpers shown in the README's
`fetch(mapping(Film::new))`. Column-level codecs are `Converter`/`Binding` pairs registered on
a `DataType`; `DSL.val(Object, DataType)` lets you pin the RDBMS type explicitly when
inference is insufficient ([`DSL.java`][dsl]).

**Nullability** is not lifted into the type system the way `sqlx`/`Kysely`/`Squeal` do it — a
`Field<T>` does not distinguish nullable from non-nullable at the type level, and a projected
value can be Java `null`; jOOQ's newer `MULTISET`/`ROW` nested records and ad-hoc conversion
(`convertFrom`) address structural mapping rather than null-tracking. This is a real gap versus
the type-only builders, and one jOOQ mitigates with runtime `NULL`-handling and `Optional`
convenience fetches rather than compile-time nullability.

---

## Effect model, transactions & error handling

**Execution is blocking JDBC by default.** There is no effect value and no query monad: the
terminal `fetch()`/`execute()` calls run the statement on the calling thread and return data
or a row count. jOOQ marks the blocking surface explicitly with JetBrains'
`@Blocking` annotation — every `fetch*` on `ResultQuery` and every `transaction*` overload on
`DSLContext` carries it ([`ResultQuery.java`][resultquery], [`DSLContext.java`][dslcontext]).
`Query.execute()` runs the statement and returns _"the number of … records"_ for DML or the
result count for a `Select` ([`Query.java`][query]). Most fetches are **eager** — they _"fetch
the entire JDBC `ResultSet` eagerly into memory, which allows for closing the underlying JDBC
resources as quickly as possible"_ — with lazy, resourceful alternatives via `fetchLazy()`
(a `Cursor`) and `fetchStream()` (a Java `Stream`), both of which the Javadoc insists be
closed with try-with-resources ([`ResultQuery.java`][resultquery]).

**The reactive path is R2DBC.** `ResultQuery<R>` `extends … Publisher<R>`
([`ResultQuery.java`][resultquery]) — a reactive-streams `Publisher` — so any query can be
`subscribe`d instead of `fetch`ed. Construct the context with an R2DBC `ConnectionFactory`
(`DSL.using(ConnectionFactory)`, [`DSL.java`][dsl]) and the same DSL renders and binds over
R2DBC connections (`impl/R2DBC.java`) rather than JDBC; `jOOQ-reactor-extensions` and
`jOOQ-kotlin2-coroutines` layer Project Reactor `Flux`/`Mono` and Kotlin coroutine adapters on
top. So jOOQ offers **both** blocking and reactive execution over one construction API — but
neither is an _effect value_: the blocking side runs eagerly, and the reactive side is a
reactive-streams `Publisher`, not an `IO`/`ZIO`/`ConnectionIO` description carrying its errors
in the type.

**Transactions** are a combinator over a lambda. `transaction(TransactionalRunnable)` and
`transactionResult(TransactionalCallable<T>)` run a block that receives a fresh
`Configuration`, committing on normal return and rolling back if the lambda throws
([`DSLContext.java`][dslcontext]) — a `RuntimeException` from the block _"indicat[es] that a
rollback has occurred."_ **Nesting uses real savepoints.** The `DefaultTransactionProvider`
implements nested `transaction` calls with JDBC `Savepoint`s ([`DefaultTransactionProvider.java`][txprovider]):

> _"By default, nested transactions are supported by modeling them implicitly with JDBC
> `Savepoint`s, if supported by the underlying JDBC driver, and if `nested()` is `true`."_

so an inner block can roll back to its savepoint without aborting the outer transaction — a
stronger nesting guarantee than `Slick`'s outermost-only model and equivalent to `Diesel`'s
`SAVEPOINT` scheme. The `TransactionProvider` SPI is pluggable, e.g. to defer to Spring's
transaction manager ([`TransactionProvider.java`][txprovider2]).

**Error handling is exception-based and unchecked.** jOOQ throws a `DataAccessException`, a
`RuntimeException`, rather than JDBC's checked `SQLException`, on the stated grounds that most
SQL exceptions are unrecoverable ([`DataAccessException.java`][dae]):

> _"Unlike JDBC, jOOQ throws `RuntimeException`, knowing that … most `SQLException` types are
> not recoverable."_

It provides a small hierarchy of typed subtypes — `DataException`,
`IntegrityConstraintViolationException`, `TooManyRowsException`, `NoDataFoundException`,
`DataTypeException`, `MappingException`, … — and translates driver exceptions into them by
inspecting the SQL state class, e.g. an `IntegrityConstraintViolationException` _"when jOOQ
detects `SQLStateClass.C23_INTEGRITY_CONSTRAINT_VIOLATION`"_ ([`DataAccessException.java`][dae]).
This is a richer, structured exception tree than raw JDBC, but it is still the **exception**
model, not a [typed error channel][effects]: the failure set is not in the query's type, and
the R2DBC path wraps `R2dbcException` the same way. That is the sharpest contrast with the
effect-value mappers this survey weights most heavily.

### Records as a micro-mapper (a secondary rung)

jOOQ is primarily a query builder, but generated `UpdatableRecord`s give it an active-record
CRUD facet: an `UpdatableRecord` is _"A common interface for records that can be stored back
to the database again"_, with `store()` executing _"either an `INSERT` or an `UPDATE`
statement"_, plus `delete()`, `refresh()`, and `merge()` — and opt-in optimistic locking
([`UpdatableRecord.java`][updatable]). This is a convenience layer, not change tracking or a
unit of work; there is no identity map and no implicit flush.

---

## Ecosystem & maturity

jOOQ is a mature, heavily-used JVM data-access library by Data Geekery GmbH (Lukas Eder), in
continuous development since ≈2009 and today at the 3.20.x stable line (the pinned checkout is
`3.22.0-SNAPSHOT`, [`pom.xml`][pom]; version numbers and first-release year are web-attested).
Its distribution and licensing are the notable structural fact. The repository is licensed
**Apache-2.0**, but with an explicit commercial alternative ([`LICENSE`][license]):

> _"Commercial licenses for this work are available. These replace the above Apache-2.0
> license and offer limited warranties, support, maintenance, and commercial database
> integrations."_

The split is enforced through the `SQLDialect` enum. Open-source databases are compiled into
the free build; the commercial dialects are literally stripped from the OSS source tree (the
enum's `// SQL dialects for commercial usage` section is blank in this checkout), and each
dialect carries a `commercial()` flag — _"Whether this dialect is supported with the jOOQ
commercial license only"_ ([`SQLDialect.java`][dialect]). The doc states the rule plainly
([`SQLDialect.java`][dialect]):

> _"The open source jOOQ distributions only support the dialect family, which corresponds to
> the latest supported dialect version of the commercial distribution."_

So the **free edition covers open-source databases** (PostgreSQL, MySQL, MariaDB, SQLite, H2,
HSQLDB, Derby, Firebird, CUBRID, DuckDB, ClickHouse, Trino, YugabyteDB, Ignite) at their
latest supported version only, while **Oracle, SQL Server, DB2, Sybase, HANA, Redshift,
Snowflake, and multi-version support require a paid license.** The ecosystem is broad:
first-class Kotlin and Scala DSL modules, Jackson/JPA/reactor extensions, a SQL
parser/translator, a `jOOQ-checker` compile-time plugin, and Gradle/Maven codegen plugins
(`jOOQ-codegen-gradle`, `jOOQ-codegen-maven`). Its dependents are pervasive across the JVM
server ecosystem; jOOQ is the reference implementation of "type-safe SQL in Java."

---

## Strengths

- **SQL you can see, typed by the compiler.** The fluent DSL mirrors SQL clause-for-clause, so
  the generated SQL is predictable; and the generated `Field<T>`/`RecordN` types make a wrong
  column, a wrong type, or an out-of-scope reference a compile error.
- **Db-first codegen keeps code and schema in lockstep.** `jOOQ-meta`/`jOOQ-codegen`
  reverse-engineer a live DB (or DDL/JPA/Liquibase) into typed `Tables`/`Record`s/`Keys`, so
  the schema is the single source of truth and drift surfaces at compile time after regen.
- **Injection-proof by construction.** Values become `?` bind parameters via `DSL.val`;
  inlining is explicit and still escaped; plain-SQL splicing is opt-in and can be blocked by
  the `PlainSQLChecker`.
- **One query, 30+ dialects.** The reified `QueryPart` model renders dialect-specific SQL,
  papering over placeholder syntax, `LIMIT`/`TOP`, upsert grammar, and more; `@Support`
  annotations document (and, with `jOOQ-checker`, enforce) per-dialect availability.
- **Rich SQL surface.** Window functions, CTEs, `MULTISET`/`ROW` nested collections, implicit
  joins, stored procedures, a SQL parser/translator, and DDL — jOOQ tracks the standard and
  vendor SQL closely rather than to a lowest common denominator.
- **Real savepoint nesting.** Nested `transaction` blocks use JDBC `Savepoint`s, so inner
  rollbacks don't abort the outer transaction.
- **Both blocking and reactive** execution over the same DSL (JDBC and R2DBC).

## Weaknesses

- **A code-generation build step.** The type safety depends on regenerating `Tables`/`Record`s
  whenever the schema changes; the codegen must be wired into the build and re-run, and
  generated code and DB can drift between runs.
- **Heavy, and Java-verbose.** Hundreds of API interfaces (22× `RecordN`, `BetweenAndStepN`,
  long step-interface chains) and generated classes; the DSL is powerful but large.
- **The free edition is open-source-DBs only.** Oracle, SQL Server, DB2, and friends — plus
  multi-version dialect support — require a commercial license; a real adoption gatekeeper for
  enterprise stacks.
- **No compile-time nullability.** `Field<T>` doesn't distinguish nullable columns at the type
  level, unlike `sqlx`/`Kysely`/`Squeal`; `NULL` handling is runtime.
- **Exception-based, blocking-first execution.** Failures are thrown `DataAccessException`s,
  not a typed error channel; the default model is eager and blocking. The reactive R2DBC path
  is a `Publisher`, not an effect value — no `IO`/`ZIO`-style description carrying errors and
  requirements in the type.
- **Migrations are still `@Experimental`.** Schema _evolution_ leans on Flyway/Liquibase.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                                      | Trade-off                                                                                              |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| **Db-first code generation** (`jOOQ-meta` → typed `Tables`/`Record`s)  | The live DB is the source of truth; generated types mirror it, so schema drift is a compile error              | Requires a codegen build step; generated code must be regenerated on schema change and can drift       |
| **Fluent typed builder over an immutable `QueryPart` model**           | SQL-shaped, IDE-completable, compiler-checked; the reified tree retargets 30+ dialects and enables dynamic SQL | Large API surface (22× `RecordN`, long step chains); Java verbosity                                    |
| **Values wrapped as `Param`/`?` bind values by default**               | Injection-proof; inlining/plain-SQL are explicit and (optionally) checker-enforced                             | Left-hand-side or field-mixed values need explicit `val(…)`; plain-SQL escape hatch re-exposes risk    |
| **Blocking JDBC as the default effect model**                          | Maps 1:1 to the JVM's dominant DB access model; simple, ubiquitous                                             | Eager and thread-bound; no effect value; reactive R2DBC is a separate opt-in path                      |
| **Unchecked `DataAccessException` (typed subtypes)**                   | Most SQL errors are unrecoverable; avoids checked-exception noise; SQL-state-classified tree                   | Not a typed error channel — failures aren't in the query's type (contrast `doobie`/Effect TS)          |
| **Savepoint-based nested transactions** (`DefaultTransactionProvider`) | Inner blocks can roll back independently; pluggable `TransactionProvider` (e.g. Spring)                        | Depends on driver savepoint support; opt-out via `nested(false)`                                       |
| **Dual license: Apache-2.0 (OSS DBs) / commercial (rest)**             | Sustains a large, actively-developed project; free tier covers open-source databases                           | Oracle/SQL Server/DB2/… and multi-version support are paid; commercial dialects absent from OSS source |
| **22 concrete `RecordN` interfaces for degree-typed projections**      | Compile-time-typed row shapes without variadic generics (which Java lacks)                                     | Hard ceiling at degree 22; API bloat; beyond 22, projections fall back to untyped `Record`             |

---

## Sources

- [jOOQ/jOOQ — GitHub repository][repo] · [jooq.org manual][docs] · [Javadoc][javadoc] · [licensing][licensing]
- [`README.md` — "internal DSL and source code generator", typesafe embedded SQL, `MULTISET` example][readme]
- [`LICENSE` — Apache-2.0 + commercial alternative][license]
- [`DSLContext.java` — attached fluent execution, `select`→`RecordN`, `transaction*`, `@Blocking`][dslcontext]
- [`DSL.java` — static factory, `val`/`inline`, `field(String)` plain SQL, `using(ConnectionFactory)` R2DBC][dsl]
- [`Field.java` — `Field<T>` column expression; typed `eq(T)`/`eq(Field<T>)`][field] · [`Table.java`][table] · [`Condition.java`][condition]
- [`Param.java` — bind-value wrapping, default `?` marker][param] · [`impl/Val.java` — `getBindVariable` renders `?`][val]
- [`QueryPart.java` — composition base type][querypart] · [`Query.java` — `execute()`][query] · [`Configuration.java` — render/bind contexts, connection providers][configuration]
- [`SelectFromStep.java` — SQL-next-to-jOOQ step example][fromstep] · [`Select.java`][select] · [`SelectWhereStep.java`][wherestep]
- [`Record.java` — `Record1`..`Record22`, degree-typed records][record] · [`Result.java` — `extends List<R>`][result] · [`RecordMapper.java`][recordmapper] · [`UpdatableRecord.java` — `store()` CRUD][updatable]
- [`ResultQuery.java` — eager/lazy fetch, `@Blocking`, `extends Publisher<R>` (R2DBC)][resultquery]
- [`ConnectionProvider.java`][connprovider] · [`impl/DataSourceConnectionProvider.java` — pool delegation][dscp]
- [`DefaultTransactionProvider.java` — JDBC `Savepoint` nesting][txprovider] · [`TransactionProvider.java` — SPI][txprovider2]
- [`exception/DataAccessException.java` — unchecked, SQL-state-classified tree][dae]
- [`SQLDialect.java` — free vs commercial dialects, `commercial()` flag][dialect] · [`Support.java` — `@Support` metadata][support] · [`SQLDialectChecker.java` — dialect compile check][dialectchecker]
- [`jOOQ-meta/…/Database.java` — DB introspection model][metadb] · [`jOOQ-codegen/…/JavaGenerator.java` — codegen of tables/records/keys][javagen] · [`Migration.java` — `@Experimental` migrations][migration] · [`pom.xml` — pinned version][pom]
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [schema, migrations & codegen][schemamig] · [effects, transactions & errors][effects] · [connections & pools][pools]

<!-- References -->

[repo]: https://github.com/jOOQ/jOOQ
[docs]: https://www.jooq.org/doc/latest/manual/
[javadoc]: https://www.jooq.org/javadoc/latest/
[licensing]: https://www.jooq.org/legal/licensing
[readme]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/README.md
[license]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/LICENSE
[pom]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/pom.xml
[dslcontext]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/DSLContext.java
[dsl]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/impl/DSL.java
[field]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Field.java
[table]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Table.java
[condition]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Condition.java
[param]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Param.java
[val]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/impl/Val.java
[querypart]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/QueryPart.java
[query]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Query.java
[configuration]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Configuration.java
[fromstep]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/SelectFromStep.java
[select]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Select.java
[wherestep]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/SelectWhereStep.java
[record]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Record.java
[result]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Result.java
[recordmapper]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/RecordMapper.java
[updatable]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/UpdatableRecord.java
[resultquery]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/ResultQuery.java
[connprovider]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/ConnectionProvider.java
[dscp]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/impl/DataSourceConnectionProvider.java
[txprovider]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/impl/DefaultTransactionProvider.java
[txprovider2]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/TransactionProvider.java
[dae]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/exception/DataAccessException.java
[dialect]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/SQLDialect.java
[support]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Support.java
[dialectchecker]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ-checker/src/main/java/org/jooq/checker/SQLDialectChecker.java
[metadb]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ-meta/src/main/java/org/jooq/meta/Database.java
[javagen]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ-codegen/src/main/java/org/jooq/codegen/JavaGenerator.java
[migration]: https://github.com/jOOQ/jOOQ/blob/c8d3d75/jOOQ/src/main/java/org/jooq/Migration.java
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
[schemamig]: ./concepts.md#schema-migrations-code-generation

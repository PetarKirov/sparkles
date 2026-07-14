# Jdbi (Java / JVM)

A convenience layer over JDBC that runs the raw SQL _you_ write and maps result rows to Java objects, offered through two APIs over one core — a fluent, imperative `Handle`/statement builder and a declarative **SQL Object** layer of annotated interfaces Jdbi implements at runtime — with injection-safe parameter binding and a pluggable `RowMapper`/`ColumnMapper`/`BeanMapper` system, and deliberately no ORM machinery above that rung.

| Field              | Value                                                                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Java (usable from Kotlin, Clojure, Scala, and other JVM languages; requires Java 17+)                                                           |
| License            | Apache-2.0 ([`LICENSE`][license])                                                                                                               |
| Repository         | [jdbi/jdbi][repo]                                                                                                                               |
| Documentation      | [jdbi.org Developer Guide][docs] · [Javadoc][apidocs] · [`docs/src/adoc/index.adoc`][guide-src]                                                 |
| Category           | [Safe-SQL / micro-mapper][concepts-ladder] — raw SQL + injection-safe binding + row→object mapping; two API styles, no query DSL, no ORM        |
| Abstraction level  | [Safe-SQL / micro-mapper rung][concepts-ladder] — a `Handle` wraps a JDBC `Connection`; parameters bind out-of-band, rows hydrate into types    |
| Query model        | [Raw SQL string][concepts-models] you write — fluent (`createQuery(...).bind(...)`) or annotated interfaces (`@SqlQuery("select ...")`)         |
| Effect/async model | Blocking JDBC; [exception-based][concepts-effects] errors (unchecked `JdbiException`); optional executor-backed `CompletionStage` async facade  |
| Backends           | Any database with a JDBC driver — Postgres, MySQL/MariaDB, SQLite, Oracle, H2, and others; vendor-type plugins for Postgres/MySQL/SQLite/Oracle |
| First release      | Jdbi 3 ≈2017 (web-attested; the Jdbi/DBI lineage dates to ≈2011)                                                                                |
| Latest version     | `3.54.0` @ 2026-07-01 ([`index.adoc`][guide-src]); pinned tree at `3.54.1-SNAPSHOT`                                                             |

> [!NOTE]
> Jdbi sits on the [safe-SQL / micro-mapper rung][concepts-ladder] of the abstraction
> ladder — one step above a bare [driver][concepts-ladder] (JDBC itself) and far below a
> full ORM. You write every SQL string; Jdbi binds your parameters out-of-band and maps the
> returned columns to Java types. It is this survey's **JVM thin-mapper baseline** — the
> Java analogue of `Dapper` (.NET), `hasql` (Haskell), and Go `database/sql`+`sqlx`, and the
> deliberate antithesis of the heavyweight `Hibernate`/JPA it refuses to become. Its
> distinguishing feature within that niche is a **two-API duality**: the same core is driven
> either fluently or through a declarative annotated-interface DAO layer. See
> [concepts][concepts] for shared vocabulary.

---

## Overview

### What it solves

Raw JDBC is verbose and error-prone: you acquire a `Connection`, build a `PreparedStatement`,
`setXxx` each parameter by index, `executeQuery`, loop a `ResultSet`, and pull each column out
by ordinal into a hand-written object — all while managing `close()` on every resource in the
right order. Jdbi collapses that ceremony without moving up to an ORM. It keeps the SQL in your
hands and takes over exactly two mechanical jobs — turning values into bound parameters and
turning result columns into typed objects — plus the resource and transaction plumbing around
them. The project's one-line pitch ([`README.md`][readme]):

> _"The Jdbi library provides convenient, idiomatic access to relational databases in Java and
> other JVM technologies such as Kotlin, Clojure or Scala."_

Jdbi does not replace JDBC; it refines it ([`README.md`][readme]):

> _"Jdbi is built on top of JDBC. If your database has a JDBC driver, you can use Jdbi with
> it."_

That is the whole portability story: Jdbi speaks whatever JDBC speaks, so any database with a
driver works, and the SQL dialect stays your responsibility because Jdbi generates none.

### Design philosophy

Four stated principles define Jdbi, each a verbatim claim from its own developer guide.

**It is emphatically _not_ an ORM — and the absence is the feature.** The guide states it
twice, first as a headline ([`index.adoc`][guide-src]):

> _"*Jdbi is not an ORM.* It is a convenience library to make Java database operations simpler
> and more pleasant to program than raw JDBC. While there is some ORM-like functionality, Jdbi
> goes to great length to ensure that there is no hidden magic that makes it hard to understand
> what is going on."_

and then concretely, enumerating exactly which ORM machinery is missing ([`index.adoc`][guide-src]):

> _"Jdbi is not an ORM. There is no session cache, "open session in view", change-tracking, or
> cajoling the library to understand your schema."_

**SQL is a first-class language, not something to hide.** ([`index.adoc`][guide-src]):

> _"*Jdbi does not hide SQL away.* One of the design principles of Jdbi is that SQL is the
> native language of the database, and it is unnecessary to wrap it into code, deconstruct it,
> or hide it away."_

The corollary is the division of labour ([`index.adoc`][guide-src]): _"Jdbi provides
straightforward mapping between SQL and data accessible through a JDBC driver. You bring your
own SQL, and Jdbi executes it."_ There is no query builder and no compile-time SQL check — the
raw-string [query model][concepts-models], checked _never_ at compile time, the opposite pole
from `jOOQ`/`Diesel` (typed builders) or `sqlx`/`sqlc` (build-time-verified SQL).

**It provides primitives, not a framework.** ([`index.adoc`][guide-src]): _"*Jdbi does not aim
to provide a complete database management framework.* It provides the building blocks that
allow constructing the mapping between data and objects as appropriate for your application and
the necessary primitives to execute SQL code against your database."_

**Two APIs, one core.** Jdbi's headline structural choice is that it exposes the same engine
through two surfaces ([`index.adoc`][guide-src]): _"Jdbi's API comes in two flavors"_ — the
**Fluent API** (a builder-style, imperative core) and the **declarative** **SQL Object**
extension. Crucially they are not rivals ([`index.adoc`][guide-src]): _"The declarative API
uses the [...] fluent API "under the hood" and the two styles can be mixed."_ This duality is
the through-line of the two sections below.

---

## Connection, pooling & resource lifetime

The `Jdbi` class is the entry point and the long-lived object. Its own Javadoc calls it the
_"Main entry point; configurable wrapper around a JDBC `DataSource`. Use it to obtain Handle
instances and provide configuration for all handles obtained from it."_ ([`Jdbi.java`][jdbijava]).
You construct one per data source, from a JDBC URL, a `DataSource`, a `ConnectionFactory`, or a
single `Connection`, and share it ([`index.adoc`][guide-src]): _"Jdbi instances are thread-safe
and do not own any database resources."_

Jdbi does **not** pool. This is an explicit non-goal ([`index.adoc`][guide-src]): _"Jdbi does
not provide connection pooling or other [...] features, but it can be combined with other
software that does."_ In practice you hand it a pooling `DataSource` (HikariCP, etc.), exactly
as `Dapper` leaves pooling to the ADO.NET provider.

The unit of work is a `Handle` — a wrapped, live connection. Its Javadoc ([`Handle.java`][handlejava]):

> _"This represents a connection to the database system. It is a wrapper around a JDBC
> Connection object. Handle provides essential methods for transaction management, statement
> creation, and other operations tied to the database session."_

Handles are short-lived and **must be closed** to release the connection ([`index.adoc`][guide-src]),
and they are **not thread-safe**. The idiomatic path never closes one by hand: the `withHandle`
/ `useHandle` callbacks on `Jdbi` fully manage the lifecycle. `withHandle` is _"A convenience
function which manages the lifecycle of a handle and yields it to a callback for use by
clients."_ ([`Jdbi.java`][jdbijava]) — `withHandle` returns a value, `useHandle` does not. The
naming convention is systematic: `with-` methods return and pair with `-Callback` objects,
`use-` methods are void and pair with `-Consumer` objects. A raw `Jdbi#open()` returns an
_unmanaged_ handle for the rare case (streaming a `ResultSet` past the callback boundary) that a
try-with-resources block must own it directly — with the guide's caution that _"Failing to
release the handle will leak connections."_ ([`index.adoc`][guide-src]).

SQL Object types add a third lifetime, `Jdbi#onDemand(...)`, whose instances _"obtain and
release connections for each method call [...] are thread-safe, and may be reused across an
application"_ ([`sqlobject/package-info.java`][sqlobjectpkg]) — a connection-per-call convenience
that trades a small acquisition cost for statelessness. There is no [scoped acquire/release
`Resource`][concepts-pools] value of the kind the effect systems model; resource safety is the
managed-callback discipline plus JDBC `close()`.

## Query construction & injection safety

This is Jdbi's centre of gravity, and its defining trait is that **the same raw-SQL,
out-of-band-binding model is offered through two API styles.**

### The safety mechanism: bound arguments, never interpolation

Arguments are Jdbi's wrapper over JDBC statement parameters ([`index.adoc`][guide-src]):
_"Arguments are Jdbi's representation of JDBC statement parameters (the `?` in `SELECT * FROM
Foo WHERE bar = ?`)."_ When you bind a value, Jdbi finds an `ArgumentFactory` that converts it
to an `Argument`, whose job is to call `setString`/`setInt`/… on the `PreparedStatement`
exactly as hand-written JDBC would. The value therefore travels the JDBC parameter channel — it
is never spliced into SQL text — so [SQL injection is structurally impossible][concepts-injection]
for a bound value. The guide is explicit that binding is the safe path ([`index.adoc`][guide-src]):
_"Binding ensures that the parameterized query string (`... where foo = ?`) is transmitted to
the database without allowing hostile parameter values to inject SQL."_

Two placeholder syntaxes are supported: **positional** `?` tokens bound by 0-based index, and
**named** `:name` tokens bound by name (parsed by the default `ColonPrefixSqlParser`; a
`HashPrefixSqlParser` swaps in `#name` when a colon is awkward in the dialect). Mixing the two
in one statement is disallowed. A key scoping note ([`index.adoc`][guide-src]): _"arguments
usually cannot be used to change the structure of a query (for example the table or column name,
`SELECT` or `INSERT`, etc.) nor may they be interpolated into string literals"_ — structural
changes are the templating engine's job (below), not binding's.

### API style 1: the Fluent API

You obtain a statement builder from the `Handle` — `createQuery` for result-bearing statements,
`createUpdate` for `INSERT`/`UPDATE`/`DELETE`/DDL, plus `createBatch`, `createCall` (stored
procedures), and `createScript`. `createQuery` returns _"a Query instance that executes a
statement with bound parameters and maps the result set into Java types."_ ([`Handle.java`][handlejava]).
Binding is a fluent chain; a `Query` is a [`ResultBearing`][concepts-types] whose `mapTo`/
`mapToBean` selects a mapper and whose terminal method (`one`/`findOne`/`first`/`findFirst`/
`list`/`stream`) collects. The guide's introductory example shows every binding form in one
block ([`IntroductionTest.java`][introtest]):

```java
List<User> users = jdbi.withHandle(handle -> {
    handle.execute("CREATE TABLE \"user\" (id INTEGER PRIMARY KEY, \"name\" VARCHAR)");

    // Inline positional parameters
    handle.execute("INSERT INTO \"user\" (id, \"name\") VALUES (?, ?)", 0, "Alice");

    // Positional parameters
    handle.createUpdate("INSERT INTO \"user\" (id, \"name\") VALUES (?, ?)")
            .bind(0, 1) // 0-based parameter indexes
            .bind(1, "Bob")
            .execute();

    // Named parameters
    handle.createUpdate("INSERT INTO \"user\" (id, \"name\") VALUES (:id, :name)")
            .bind("id", 2)
            .bind("name", "Clarice")
            .execute();

    // Named parameters from bean properties
    handle.createUpdate("INSERT INTO \"user\" (id, \"name\") VALUES (:id, :name)")
            .bindBean(new User(3, "David"))
            .execute();

    // Easy mapping to any type
    return handle.createQuery("SELECT * FROM \"user\" ORDER BY \"name\"")
            .mapToBean(User.class)
            .list();
});
```

Binding scales from single values up to whole objects: `bind(name, value)`, `bindMap(map)`,
`bindBean(bean)` (JavaBean getters), `bindFields(obj)` (public fields), `bindMethods(obj)`
(parameterless methods), each optionally prefixed (`bindBean("f", folder)` → `:f.id`), and each
resolving nested properties (`:user.address.street`). `bindList("kinds", …)` expands an
`Iterable` into a comma-separated placeholder list for `IN` clauses — but, notably, it requires
a **template attribute** (`<kinds>`), not a bind token, because the count of placeholders is a
structural change rendered before binding.

### API style 2: SQL Objects (the declarative DAO layer)

The SQL Object extension is _"a declarative-style extension to the fluent-style, programmatic
Core APIs"_ ([`index.adoc`][guide-src]). You declare a **public Java interface**, annotate each
method with the SQL to run, and Jdbi synthesizes the implementation at runtime. The package
Javadoc frames it ([`sqlobject/package-info.java`][sqlobjectpkg]):

> _"The SQLObject API allows for declarative definition of interfaces which will handle the
> generation of statements and queries on your behalf when needed."_

The method annotations are `@SqlQuery` (_"Used to indicate that a method should execute a
query."_ — [`SqlQuery.java`][sqlqueryjava]), `@SqlUpdate`, `@SqlBatch`, `@SqlCall`, and
`@SqlScript`. Method parameters become statement arguments; the return type drives the mapping.
The same introductory `UserDao` in declarative form ([`IntroductionTest.java`][introtest]):

```java
public interface UserDao {
    @SqlUpdate("CREATE TABLE \"user\" (id INTEGER PRIMARY KEY, \"name\" VARCHAR)")
    void createTable();

    @SqlUpdate("INSERT INTO \"user\" (id, \"name\") VALUES (?, ?)")
    void insertPositional(int id, String name);

    @SqlUpdate("INSERT INTO \"user\" (id, \"name\") VALUES (:id, :name)")
    void insertNamed(@Bind("id") int id, @Bind("name") String name);

    @SqlUpdate("INSERT INTO \"user\" (id, \"name\") VALUES (:id, :name)")
    void insertBean(@BindBean User user);

    @SqlQuery("SELECT * FROM \"user\" ORDER BY \"name\"")
    @RegisterBeanMapper(User.class)
    List<User> listUsers();
}
```

Binding is by annotation, mirroring the fluent binders one-for-one. `@Bind` _"Binds the
annotated argument as a named parameter, and as a positional parameter."_ ([`Bind.java`][bindjava]);
`@BindBean` _"Binds the properties of a JavaBean to a SQL statement."_ ([`BindBean.java`][bindbeanjava]);
and `@BindFields`, `@BindMethods`, `@BindMap`, `@BindList` complete the set. Compile with
`-parameters` and even `@Bind` is optional — unannotated parameters bind to their own names. To
use SQL Objects you install the plugin and attach the interface:

```java
Jdbi jdbi = Jdbi.create("jdbc:h2:mem:test");
jdbi.installPlugin(new SqlObjectPlugin());

List<User> users = jdbi.withExtension(UserDao.class, dao -> {
    dao.createTable();
    dao.insertPositional(0, "Alice");
    dao.insertBean(new User(3, "David"));
    return dao.listUsers();
});
```

Because SQL Objects run on the fluent core, any interface implicitly gets a `getHandle()`
(via the `SqlObject` mixin) to "drop down" to the fluent API for anything the annotations don't
cover ([`sqlobject/package-info.java`][sqlobjectpkg]) — the concrete realization of "the two
styles can be mixed."

### The one value-into-text path: template attributes

For the structural changes binding cannot express (table names, optional clauses, `IN`-list
expansion), Jdbi has a separate **template** layer with `<name>` **attributes** set by
`define(...)` (or `@Define` in SQL Objects). The default `DefinedAttributeTemplateEngine`
replaces angle-bracket placeholders; StringTemplate 4, Commons Text, and Freemarker engines
plug in for richer templating. This runs _before_ the SQL parser, and the guide is unambiguous
that it is the dangerous path ([`index.adoc`][guide-src]):

> _"Unlike \_argument binding_, the _rendering_ of _attributes_ performed by TemplateEngines is
> _not_ SQL-aware."\_

with a pointed caution ([`index.adoc`][guide-src]): _"Query templating is a common attack
vector! Always prefer binding parameters to static SQL over dynamic SQL when possible."_ The two
layers compose left to right — templating renders attributes, then the parser binds arguments:

```java
handle.createQuery("SELECT * FROM <TABLE> WHERE name = :n")
    .define("TABLE", "Person")   // structural: substituted into text
    .bind("n", "MyName");        // value: bound out-of-band
```

The design keeps _values_ on the safe channel even inside dynamic SQL: `@BindList`/`bindList`
render only the placeholder _count_ into text and still bind each element as a parameter, and
`defineNamedBindings()` exposes per-binding booleans so `<if(a)>a = :a,<endif>` conditional
clauses are driven by template logic while the value stays bound.

## Schema, migrations & code generation

**Jdbi owns no schema, and this is a deliberate absence.** There is no entity model that _is_
the schema (no [code-first][concepts-schema]), no schema file it treats as truth (no
[schema-first][concepts-schema]), and no [introspection→codegen][concepts-schema] step (the
`jOOQ`/`sqlc` move). You write `CREATE TABLE`/`ALTER` as ordinary SQL and run it through
`execute` or a `@SqlUpdate` method like any other statement. There is no migration runner: the
guide explicitly delegates it ([`index.adoc`][guide-src]): _"we recommend using a schema
migration tool such as Flyway or Liquibase to maintain your database schemas."_ The column↔member
mapping is by name, by convention, at runtime (below), so there is no declared schema to check a
query against — a renamed column surfaces only when the statement runs. This is the same
"you own the schema" stance as `Dapper` and Go `database/sql`.

## Type mapping & result decoding

Result decoding is Jdbi's second core job, and it is a **registry of composable mappers** split
along the same grain as JDBC's `ResultSet` access.

**Two mapper kinds.** A `RowMapper<T>` _"Maps result set rows to objects."_ ([`RowMapper.java`][rowmapperjava])
— invoked once per row, given the whole `ResultSet` positioned at the current row. A
`ColumnMapper<T>` _"Maps result set columns to objects."_ ([`ColumnMapper.java`][columnmapperjava])
— maps a single cell, and composes _inside_ row mappers (a reflection row mapper looks up a
column mapper per field). Both are `@FunctionalInterface`s, so simple cases are lambdas:

```java
List<User> users = handle
    .createQuery("SELECT id, name FROM user ORDER BY id ASC")
    .map((rs, ctx) -> new User(rs.getInt("id"), rs.getString("name")))
    .list();
```

**A registry keyed by type.** Register a mapper for a type and thereafter `mapTo(User.class)`
finds it: `jdbi.registerRowMapper(User.class, …)`, or `jdbi.registerColumnMapper(Money.class,
…)`. A mapper class with an explicit mapped type can be registered without repeating the type
(Jdbi reflects the generic signature). Column mappers ship out of the box for primitives and
their boxes, `String`, `Enum`, `BigDecimal`, `byte[]`, the `java.net`/`java.sql`/`java.time`
families, `UUID`, and arrays/collections; last-registered wins, so any built-in is overridable.
`ColumnMapperFactory`/`RowMapperFactory` produce mappers for generic or open-ended types
(e.g. an `Optional<T>` mapper composed from the `T` mapper).

**Reflection mappers for POJOs.** Three no-boilerplate mappers derive the column↔member mapping
from a class's shape:

- `ConstructorMapper` — _"assigns columns to constructor parameters by name"_
  ([`index.adoc`][guide-src]), using `-parameters` names, `@ColumnName`, or
  `@ConstructorProperties`; the idiomatic choice for immutable types and records.
- `BeanMapper` — maps to JavaBean setters. Its Javadoc notes the constraints
  ([`BeanMapper.java`][beanmapperjava]): _"This uses the JDK's built in bean mapping facilities,
  so it does not support nested properties. The mapped class must have a default constructor."_
- `FieldMapper` — maps directly to fields.

In SQL Objects the same mappers attach by annotation on the method or interface —
`@RegisterRowMapper` _"Register a row mapper in the context of a SQL Object type or method."_
([`RegisterRowMapper.java`][registerrowmapperjava]), plus `@RegisterColumnMapper`,
`@RegisterBeanMapper`, `@RegisterConstructorMapper`, `@RegisterFieldMapper` and their factory
variants.

**Nullability** is JDBC/Java nullability: a SQL `NULL` becomes a `null` reference or an empty
`Optional` (bound and mapped around any supported type). It is not lifted into the type system
the way `sqlx`/`Kysely` do — there is no described schema to derive it from — so a `NULL` in a
non-nullable primitive slot is a runtime concern (with a `coalesceNullPrimitivesToDefaults`
config that substitutes the JDBC default). Custom types plug in through `ArgumentFactory` (bind
side) and `ColumnMapper`/`RowMapper` (read side); a `Codec` abstraction pairs the two, but there
is no single composable [codec algebra][concepts-types] threading encode+decode the way
`skunk`/`hasql` expose.

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and Jdbi sits at the **blocking,
exception-based** end — the JVM mainstream, no effect value, no typed error channel.

**Blocking JDBC.** Every operation occupies the calling thread until the database answers: a
`Query` runs on the terminal `list()`/`one()`, an `Update` on `execute()`. There is no
[effect value][concepts-effects] to compose and interpret at the edge — the contrast with
`doobie`/`skunk`/`Quill`'s `ConnectionIO`/`IO`/`ZIO`, and even with `hasql`'s eager-but-monadic
`Session`. A `@Beta` async facade exists — `JdbiExecutor` _"wraps a `Jdbi` instance and an
`Executor` to run callbacks asynchronously, returning `CompletionStage` results"_
([`async/package-info.java`][asyncpkg]) — but it is thread-pool _offloading_ of the same
blocking calls (the Javadoc suggests sizing the pool to the connection pool), not
non-blocking I/O. Jdbi supports virtual threads, which is the ecosystem's actual answer to
blocking-at-scale.

**Transactions are a managed combinator over the `Handle`.** The `inTransaction`/`useTransaction`
methods (on `Jdbi` or `Handle`) open a transaction, pass the handle to a callback, and settle it
automatically ([`Jdbi.java`][jdbijava]):

> _"The handle will be in a transaction when the callback is invoked, and that transaction will
> be committed if the callback finishes normally, or rolled back if the callback raises an
> exception."_

Nesting is by **transaction reuse, not true nesting** ([`index.adoc`][guide-src]): _"if these
methods are called while the handle is already in an open transaction, the existing transaction
is reused (no nested transaction is created)"_ — an inner `inTransaction` joins the outer scope
and defers commit to it. **Savepoints** are available on the unmanaged path: `savepoint(name)`,
`releaseSavepoint(name)`, and `rollbackToSavepoint(name)`, "not supported by all
TransactionHandlers and requires support from the JDBC driver" ([`index.adoc`][guide-src]).
**Isolation levels** are a parameter to the transaction methods (an overload takes a
`TransactionIsolationLevel`), and a `SerializableTransactionRunner` retries transactions that
_"abort due to serialization failures"_ transparently ([`index.adoc`][guide-src]) — the closest
Jdbi comes to Effect's `isRetryable` reasons, but wired as a swappable `TransactionHandler`
rather than surfaced as typed error metadata. In SQL Objects, a default method annotated
`@Transaction` runs within a transaction, and a `Transactional` mixin exposes
`inTransaction`/`useTransaction` on the DAO itself.

**Errors are unchecked exceptions.** Jdbi does not model failure as a value. Every Jdbi
exception descends from `JdbiException`, which _extends_ `RuntimeException`
([`JdbiException.java`][jdbiexceptionjava]) — so nothing is a checked `SQLException` and there is
no [typed error channel][concepts-effects], no `Either`/`Result`, no reason union. A failed
statement surfaces as `UnableToExecuteStatementException` (a `StatementException`), wrapping the
driver's `SQLException` whose `SQLState` you inspect. To turn a specific `SQLState` into a
domain exception, Jdbi offers a `SqlExceptionHandler` extension point — imperatively via
`addExceptionHandler`, or declaratively via `@RegisterSqlExceptionHandler` — but the result is
still a _thrown_ exception, the mainstream JVM idiom, contrasted here with the effect systems'
value-typed errors.

## Ecosystem & maturity

Jdbi is a mature, widely-deployed JVM data-access library, founded by Brian McCallister and
maintained by a small team ([`README.md`][readme]); Jdbi 3 is the current line (the DBI/Jdbi
lineage predates it by years). It is released under the permissive **Apache-2.0** license
([`LICENSE`][license]) and keeps a deliberately small footprint — the core module _"uses only
slf4j and geantyref as hard dependencies"_ ([`index.adoc`][guide-src]) — while a large ring of
optional modules folds in library and vendor support. Distribution is via Maven Central, with a
BOM for version alignment; the pinned tree tests against Java 17/21/25.

**Backends: any JDBC database.** Because Jdbi builds on JDBC, it works with Postgres, MySQL/
MariaDB, SQLite, Oracle, H2, and anything exposing a driver; there is no dialect layer because
there is no SQL generation — dialect differences live in the SQL you write. Vendor plugins
(`jdbi3-postgres`, `jdbi3-mysql`, `jdbi3-sqlite`, `jdbi3-oracle12`, `jdbi3-postgis`) add
support for non-standard column types beyond the JDBC baseline.

**A plugin/extension architecture** carries the rest: `SqlObjectPlugin` (the declarative
layer), Kotlin (`jdbi3-kotlin`, `jdbi3-kotlin-sqlobject`) with data-class mapping, Guava,
JodaTime, Vavr, Guice, Spring, JPA-annotation, and JSON plugins (Jackson 2/3, Gson, Moshi),
pluggable SQL-template engines (StringTemplate 4, Commons Text, Freemarker) and caches
(Caffeine, Guava). Jdbi is a recipient of the Spotify FOSS 2023 Fund ([`README.md`][readme]).

---

## Strengths

- **Minimal, honest abstraction.** A `Handle` is a JDBC connection; a statement is your SQL;
  a mapper is a function. No hidden queries, no flush, no lazy proxies — _"no hidden magic."_
- **Injection-safe by default.** Values become real JDBC `PreparedStatement` parameters on the
  out-of-band channel; the only value-into-text path is the explicitly-flagged template layer.
- **Two ergonomic API styles over one core.** Fluent for ad-hoc/imperative code, declarative
  SQL Objects for a typed DAO layer — and they interoperate (`getHandle()`), so you can escalate
  or drop down without leaving Jdbi.
- **Rich, composable mapping.** Row/column mappers, a type registry, reflection mappers for
  constructors/beans/fields/records, factories for generics, and per-method annotation wiring.
- **You keep full SQL control.** CTEs, window functions, vendor extensions, `RETURNING` — any
  SQL the database supports runs verbatim; nothing is hidden behind a builder.
- **Provider-agnostic + broad plugin ecosystem.** Any JDBC backend; Kotlin/Guava/Jackson/Spring
  and vendor-type plugins extend it without bloating the core.
- **Managed transactions with savepoints and serializable-retry.** A real
  `inTransaction`/`useTransaction` combinator with commit/rollback semantics, plus savepoint and
  auto-retry handlers.

## Weaknesses

- **No compile-time SQL checking.** SQL is opaque text (doubly so in SQL Object annotation
  strings); a bad column, type mismatch, or renamed property is a runtime failure — the price of
  the [raw-string model][concepts-models].
- **You own the schema and migrations.** No code generation, no migration runner — delegated to
  Flyway/Liquibase.
- **No change tracking, identity map, or unit of work.** Updates mean writing the `UPDATE`
  yourself; there is no `SaveChanges`/dirty-state detection (by design — it is not an ORM).
- **Blocking-only core.** No effect value and no genuine non-blocking I/O; the async facade is
  `@Beta` executor offloading, and scale-out leans on virtual threads.
- **Exception-based, unchecked errors.** No typed/value error channel and no first-class
  retryability metadata; failure handling is `try`/`catch` on `SQLState` (or a
  `SqlExceptionHandler` that still throws).
- **Mapping is by-name convention + reflection.** Column↔member matching is stringly-typed and
  reflective; no declared, statically-checked mapping, and reflection has AOT/GraalVM friction.
- **SQL-in-annotation strings.** The declarative style embeds SQL in Java annotation literals —
  no IDE SQL support, awkward multi-line concatenation, and the SQL is checked only at runtime.

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                                    | Trade-off                                                                                               |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **Not an ORM** — no session cache, change-tracking, or schema modelling | No hidden magic; predictable, understandable SQL; "you bring your own SQL, Jdbi executes it" | You hand-write all DML/DDL and updates; no dirty tracking, `SaveChanges`, identity map, or lazy loading |
| **Raw SQL you write**, no query builder or generation                   | Full SQL power; provider-agnostic (no dialect layer); SQL is a first-class language          | No compile-time column/type checking; SQL portability and correctness are on you                        |
| **Two APIs over one core** (Fluent + SQL Objects), interoperable        | Imperative ergonomics _and_ a declarative DAO layer; drop-down via `getHandle()`, mixable    | Two surfaces to learn; SQL Objects hide SQL in annotation strings with only runtime checking            |
| **Out-of-band binding** (`:name`/`?` → JDBC parameters)                 | Injection-safe by default; ergonomic bean/field/method/map binders                           | By-name, reflective binding; structural changes need the separate (SQL-unaware) template layer          |
| **Template attributes** (`<name>`/`@Define`) for structural SQL         | Enables table names, `IN`-lists, conditional clauses that binding can't express              | Rendering is _not_ SQL-aware — "a common attack vector"; the escape hatch that re-exposes injection     |
| **Mapper registry** (`RowMapper`/`ColumnMapper` + reflection mappers)   | Composable, type-keyed, overridable; no-boilerplate mapping for POJOs/records                | Stringly-typed by-name matching + reflection (AOT friction); no statically-checked mapping              |
| **`Handle` = wrapped JDBC connection**, managed via callbacks           | Explicit, short-lived resource; `withHandle`/`inTransaction` manage lifecycle & commit       | Not thread-safe; leaks if opened unmanaged; no scoped-`Resource` value like the effect systems          |
| **No connection pooling** (delegated to the `DataSource`)               | Stays a thin layer; compose with HikariCP/etc.                                               | Pool sizing/lifecycle is the caller's problem                                                           |
| **Blocking JDBC**, exception-based unchecked errors                     | Familiar JVM model; virtual-thread friendly; managed transactions with savepoint & retry     | No effect value, no non-blocking I/O, no typed/value error channel or `isRetryable`                     |

---

## Sources

- [jdbi/jdbi — GitHub repository][repo] · [Developer Guide][docs] · [Javadoc][apidocs]
- [`README.md` — "convenient, idiomatic access to relational databases in Java"; "built on top of JDBC"; Apache-2.0; founders; Spotify FOSS fund][readme]
- [`docs/src/adoc/index.adoc` — "not an ORM" / "no session cache … change-tracking"; "does not hide SQL away"; two-API duality ("under the hood", "can be mixed"); binding vs templating & injection cautions; transactions (reuse, savepoints, serializable retry); Flyway/Liquibase delegation; slf4j+geantyref dependencies; module/plugin overview; 3.54.0 @ 2026-07-01][guide-src]
- [`docs/src/test/java/jdbi/doc/IntroductionTest.java` — the fluent-vs-SQL-Object `UserDao` example][introtest]
- [`core/.../Jdbi.java` — entry-point Javadoc; `withHandle`/`inTransaction` semantics][jdbijava]
- [`core/.../Handle.java` — "wrapper around a JDBC Connection object"; `createQuery`][handlejava]
- [`core/.../statement/SqlStatement.java` — `bind`/`bindBean` binding API][sqlstatementjava]
- [`core/.../mapper/RowMapper.java` — "Maps result set rows to objects"][rowmapperjava] · [`ColumnMapper.java` — "Maps result set columns to objects"][columnmapperjava] · [`mapper/reflect/BeanMapper.java` — bean-mapping constraints][beanmapperjava]
- [`core/.../JdbiException.java` — `extends RuntimeException` (unchecked errors)][jdbiexceptionjava] · [`core/.../async/package-info.java` — `JdbiExecutor` `CompletionStage` facade][asyncpkg]
- [`sqlobject/.../package-info.java` — "declarative definition of interfaces"; attach/onDemand lifecycles; `@Transaction` mixin][sqlobjectpkg] · [`sqlobject/.../statement/SqlQuery.java`][sqlqueryjava] · [`sqlobject/.../customizer/Bind.java`][bindjava] · [`BindBean.java`][bindbeanjava] · [`config/RegisterRowMapper.java`][registerrowmapperjava]
- Shared vocabulary: [concepts & vocabulary][concepts] · [the abstraction ladder][concepts-ladder] · [query construction models][concepts-models] · [statements, parameters & injection][concepts-injection] · [connections, pools & sessions][concepts-pools] · [schema, migrations & code generation][concepts-schema] · [type mapping & result decoding][concepts-types] · [effects, transactions & error handling][concepts-effects]

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
[repo]: https://github.com/jdbi/jdbi
[docs]: https://jdbi.org/
[apidocs]: https://jdbi.org/apidocs/
[readme]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/README.md
[license]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/LICENSE
[guide-src]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/docs/src/adoc/index.adoc
[introtest]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/docs/src/test/java/jdbi/doc/IntroductionTest.java
[jdbijava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/core/src/main/java/org/jdbi/v3/core/Jdbi.java
[handlejava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/core/src/main/java/org/jdbi/v3/core/Handle.java
[sqlstatementjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/core/src/main/java/org/jdbi/v3/core/statement/SqlStatement.java
[rowmapperjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/core/src/main/java/org/jdbi/v3/core/mapper/RowMapper.java
[columnmapperjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/core/src/main/java/org/jdbi/v3/core/mapper/ColumnMapper.java
[beanmapperjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/core/src/main/java/org/jdbi/v3/core/mapper/reflect/BeanMapper.java
[jdbiexceptionjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/core/src/main/java/org/jdbi/v3/core/JdbiException.java
[asyncpkg]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/core/src/main/java/org/jdbi/v3/core/async/package-info.java
[sqlobjectpkg]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/sqlobject/src/main/java/org/jdbi/v3/sqlobject/package-info.java
[sqlqueryjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/sqlobject/src/main/java/org/jdbi/v3/sqlobject/statement/SqlQuery.java
[bindjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/sqlobject/src/main/java/org/jdbi/v3/sqlobject/customizer/Bind.java
[bindbeanjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/sqlobject/src/main/java/org/jdbi/v3/sqlobject/customizer/BindBean.java
[registerrowmapperjava]: https://github.com/jdbi/jdbi/blob/78c2fa4012633b86190a9227a4f05cb7268f241a/sqlobject/src/main/java/org/jdbi/v3/sqlobject/config/RegisterRowMapper.java

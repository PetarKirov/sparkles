# Hibernate ORM (Java)

The archetypal JVM object/relational mapper and the design lineage behind the JPA standard: a stateful `Session` _is_ a [persistence context][orm] — a [first-level cache][orm] (identity map) plus a [unit of work][orm] that flushes in-memory entity mutations to SQL by **automatic dirty checking**, with lazy associations materialized on demand through runtime proxies.

| Field              | Value                                                                                                                                                                                         |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Java (the build "requires at least JDK 25, and produces Java 17 bytecode" — `README.adoc`)                                                                                                    |
| License            | Apache-2.0 (`SPDX-License-Identifier: Apache-2.0` in every source file; `LICENSE.txt`). Historically **LGPL-2.1** through Hibernate 5, relicensed to Apache-2.0 with 6.0 (2022, web-attested) |
| Repository         | [hibernate/hibernate-orm][repo]                                                                                                                                                               |
| Documentation      | [hibernate.org/orm][docs] · [Javadoc][javadoc] · [_A Short Guide to Hibernate 7_][intro]                                                                                                      |
| Category           | [Full ORM (data mapper)][ladder] — the reference implementation of the heavyweight, implicit-unit-of-work ORM                                                                                 |
| Abstraction level  | Top [rung of the ladder][ladder]: [identity map + unit of work + change tracking + lazy loading][orm]                                                                                         |
| Query model        | **HQL/JPQL** (object-oriented query language over entities) + the type-safe **Criteria API** + native SQL ([query models][qcm])                                                               |
| Effect/async model | [Blocking][effects] JDBC; failures are **thrown** as unchecked `HibernateException` / JPA `PersistenceException`. Async is a separate project, **Hibernate Reactive**                         |
| Backends           | Any JDBC database, via a per-database [`Dialect`][qcm] (PostgreSQL, MySQL, Oracle, SQL Server, DB2, H2, SQLite, …)                                                                            |
| First release      | ≈ 2001–2002 (the project "began in 2001, when Gavin King's frustration with Entity Beans in EJB 2 boiled over" — `Introduction.adoc`; web-attested for the exact `1.0`)                       |
| Latest version     | pinned tree is `8.1.0-SNAPSHOT` (`gradle/version.properties`); `7.x` is the current stable line (web-attested)                                                                                |

> [!NOTE]
> Hibernate is this survey's data point for the **full-ORM rung in its heaviest, most
> canonical form** — the design that every functional data mapper in this survey
> (`doobie`, `Ecto`, `Quill`, and friends) deliberately rejects. Its stateful
> `Session` owns an [identity map][orm], a [unit of work][orm], transactional write-behind,
> and [lazy loading][orm] with all their power and all their foot-guns. It is the JVM peer
> of `EF Core` (.NET) and `SQLAlchemy` (Python), and — because JPA "was modelled on
> Hibernate" — the reference against which `Django ORM`, `TypeORM`, and `SeaORM` are read.
> Terms below link to [concepts][concepts].

---

## Overview

### What it solves

Hibernate maps graphs of Java objects to relational tables and back, so that application
code manipulates ordinary entity instances while Hibernate generates the `SELECT` /
`INSERT` / `UPDATE` / `DELETE` traffic. The `README` states the positioning directly
([`README.adoc`][readme]):

> _"Hibernate ORM is a powerful object/relational mapping solution for Java, the de facto
> standard implementation of the Java Persistence API (now also known as Jakarta
> Persistence), Jakarta Query, and Jakarta Data."_

The point is not to hide SQL but to _renormalize_ result sets into object graphs. The
introduction is unusually candid that this is the actual problem ([`Introduction.adoc`][introadoc]):

> _"ORM takes the pain out of persistence by relieving the developer of the need to
> hand-write tedious, repetitive, and fragile code for flattening graphs of objects to
> database tables and rebuilding graphs of objects from flat SQL query result sets."_

So Hibernate sits at the [full-ORM rung][ladder] alongside `EF Core`, `SQLAlchemy`, and
`ActiveRecord`, but — like `EF Core` and `SQLAlchemy` and unlike `ActiveRecord` — it is a
**data mapper**: entities are persistence-ignorant POJOs, and a separate `Session`/
`EntityManager` moves their state. It is the reference implementation of the JPA
`EntityManager`: "Every `Session` is a JPA `EntityManager`" ([`Session.java`][session]).

### Design philosophy

Two convictions run through Hibernate's own documentation, and both matter for this survey.

**ORM works _with_ SQL, not instead of it.** Hibernate explicitly refuses to pretend the
relational model isn't there ([`Introduction.adoc`][introadoc]):

> _"the goal of ORM is not to hide SQL or the relational model. After all, Hibernate's
> query language is nothing more than an object-oriented dialect of ANSI SQL."_

The introduction embraces the "leaky abstraction" charge as a feature, on performance
grounds ([`Introduction.adoc`][introadoc]): _"Hibernate—and ORM in general—has been accused
of being a leaky abstraction … the short answer is: yes, and that's a good thing."_ And it
reframes the object-relational **impedance mismatch** as a mischaracterization: _"the
problem that object/relational mapping solves … has very little to do with any so-called
'mismatch' between classes and tables"_ — the real task is "to renormalize the data after
reading it from the database."

**The `Session` is a transactional cache of managed objects.** The single most important
idea in Hibernate is that the `Session` is a _persistence context_ ([`Session.java`][session]):

> _"The main runtime interface between a Java application and Hibernate. Represents the
> notion of a persistence context, a set of managed entity instances associated with a
> logical transaction."_

Everything below — the identity map, dirty checking, lazy loading, flush timing — is a
consequence of that one design decision.

Hibernate is the inspiration for JPA itself: it "was the inspiration behind the Java (now
Jakarta) Persistence API, or JPA, and includes a complete implementation of the latest
revision of this specification" ([`Introduction.adoc`][introadoc]). The project began in
2001 (Gavin King), was absorbed into JBoss/Red Hat in 2004, and its `Session` model was
lifted almost wholesale into JPA's `EntityManager`.

## Connection, pooling & resource lifetime

A `SessionFactory` is the heavyweight, thread-safe, application-scoped root object: it
"maintains the runtime metamodel representing persistent entities, their attributes, their
associations, and their mappings to relational database tables" and "is where a program
comes to obtain sessions" ([`SessionFactory.java`][factory]). It is effectively immutable
and threadsafe; each request obtains its own short-lived `Session` from it, and "an
instance of `Session` must never be shared between multiple threads" ([`SessionFactory.java`][factory]).

**Connection pooling is delegated.** Hibernate ships only a toy pool: the built-in
`DriverManagerConnectionProvider` is "a very rudimentary connection pool" explicitly marked
"Not intended for use in production systems!" ([`DriverManagerConnectionProvider.java`][dmcp]).
The configuration guide is blunt ([`Configuration.adoc`][configadoc]): _"By default,
Hibernate uses a simplistic built-in connection pool. This pool is not meant for use in
production."_ Real deployments plug in a [pool][pool] through a separate integration module —
`hibernate-agroal`, `hibernate-hikaricp`, `hibernate-c3p0`, or `hibernate-ucp` (the four
sibling modules in the tree). Pool size is set with `hibernate.connection.pool_size`, "also
respected when you use Agroal, HikariCP, or c3p0" ([`Configuration.adoc`][configadoc]).

**The `Session` is a memory-holding resource with a bounded lifetime.** Because "a
persistence context holds hard references to all its entities and prevents them from being
garbage collected … a `Session` is a short-lived object, and must be discarded as soon as a
logical transaction ends" ([`Session.java`][session]). The factory offers scoped helpers so
this cleanup is automatic ([`Session.java`][session]):

```java
sessionFactory.inTransaction(session -> {
    //do the work
    ...
});
```

For read-heavy or bulk work that should _not_ accumulate managed state, Hibernate offers the
[`StatelessSession`][stateless] — "A command-oriented API … A stateless session has no
persistence context, and always works directly with detached entity instances" — its own
answer to the heavyweight-session cost (see [Effect model][sec-effects]). Streaming large
result sets uses a JDBC [cursor][pool] via `ScrollableResults` / `Query.stream()`.

## Query construction & injection safety

Hibernate offers three query surfaces, all under `org.hibernate.query`, which is
"Everything related to HQL/JPQL, native SQL, and criteria queries" ([`query/package-info.java`][querypkg]).

**HQL/JPQL — an object-oriented query language over entities.** You write queries against
_entity classes and their attributes_, not tables and columns; Hibernate translates to
dialect SQL. A `SelectionQuery` is obtained from the session and executed
([`SelectionQuery.java`][selquery]):

```java
List<Book> books =
        session.createQuery(Book.class,
            "from Book left join fetch authors where title like :title")
                .setParameter("title", title)
                .setMaxResults(50)
                .getResultList();
```

Note `left join fetch` (the eager-fetch escape from N+1, below) and the **named parameter**
`:title`. Parameters may also be **ordinal** ([`SelectionQuery.java`][selquery]):

```java
Book book =
        session.createQuery(Book.class, "from Book where isbn = ?1")
                .setParameter(1, isbn)
                .getSingleResultOrNull();
```

**Injection safety is parameter binding, and the anti-pattern is called out explicitly.**
Arguments enter only through the `setParameter` overloads, which bind them as JDBC
parameters; the query text and the data travel on [separate channels][inject]. The
introduction issues an unambiguous warning ([`Querying.adoc`][queryingadoc]):

> _"Never concatenate user input with HQL and pass the concatenated string to
> `createQuery()` or `createStatement()`. This would open up the possibility for an attacker
> to execute arbitrary code on your database server."_

**The Criteria API — a type-safe query builder.** For queries assembled from code (rather
than string literals), Hibernate implements the JPA `CriteriaBuilder` and extends it: the
package "extends the JPA-defined API, allowing any query written in HQL to be expressed via
the criteria API," gated through `HibernateCriteriaBuilder` ([`query/criteria/package-info.java`][critpkg]).
Criteria queries built against the generated static metamodel (an entity `Book` yields a
`Book_` class with typed attribute references — `Book_.title` etc.) are checked at compile
time. Crucially, criteria queries are injection-safe _even for un-parameterized literals_
([`Querying.adoc`][queryingadoc]): _"by default, Hibernate automatically and transparently
treats strings passed to the `CriteriaBuilder` as JDBC parameters."_

**Native SQL — the escape hatch, still parameterized.** When HQL cannot express a query,
`createNativeQuery` runs raw dialect SQL, keeping the same bind-parameter discipline
([`Querying.adoc`][queryingadoc]):

```java
Book book =
        entityAgent.createNativeQuery("select * from Books where isbn = ?1", Book.class)
                   .setParameter(1, isbn)
                   .getSingleResult();
```

Native SQL is positioned as complementary, not a failure mode: Hibernate's "generated SQL is
meant to be used in conjunction with handwritten SQL" ([`Querying.adoc`][queryingadoc]).

**The `Dialect` renders the SQL.** Every query — HQL, criteria, or the write traffic emitted
at flush — is lowered to database-specific text by a `Dialect`: "Represents a dialect of SQL
implemented by a particular RDBMS. Every subclass … implements support for a certain
database platform. For example, `PostgreSQLDialect` implements support for PostgreSQL, and
`MySQLDialect` implements support for MySQL" ([`Dialect.java`][dialect]). A dialect owns
column-type mappings, function registrations, pagination (`LimitHandler`), identity/sequence
strategies, locking, and quoting; "Subclasses should be thread-safe and immutable"
([`Dialect.java`][dialect]). Since Hibernate 6 a single subclass covers all versions of a
product, with the runtime version supplied via `DialectResolutionInfo` — so the versioned
classes like `MySQL8Dialect` "are now deprecated and will be removed."

## Schema, migrations & code generation

Hibernate is **code-first**: the mapping metadata lives on the entity classes as
annotations, and the schema is derived from it. "Every entity class must be annotated
`@Entity`" ([`Entities.adoc`][entitiesadoc]):

```java
@Entity
class Book {
    @Id @GeneratedValue Long id;
    String title;
    @ManyToOne(fetch=LAZY) Publisher publisher;
    ...
}
```

The core annotations (`@Entity`, `@Table`, `@Id`, `@GeneratedValue`, `@Column`,
`@ManyToOne`, `@OneToMany`, `@ManyToMany`, `@JoinColumn`, `@JoinTable`) are the **JPA**
annotations from `jakarta.persistence`; Hibernate's own `org.hibernate.annotations` package
is "A set of mapping annotations which extend the O/R mapping annotations defined by JPA …
we address some areas where it falls short" ([`annotations/package-info.java`][annpkg]). XML
mappings are a supported alternative.

**Schema generation via `hbm2ddl` (dev-time only).** From the annotation metadata Hibernate
can emit or check DDL. The `hibernate.hbm2ddl.auto` setting drives the
`SchemaManagementTool`, which exposes a `SchemaCreator`, `SchemaDropper`, `SchemaMigrator`,
and `SchemaValidator` ([`SchemaManagementTool.java`][schematool]). The action set is the
`Action` enum — `NONE`, `CREATE`, `CREATE_DROP`, `CREATE_ONLY`, `DROP`, `VALIDATE`, `UPDATE`,
`TRUNCATE`, … ([`Action.java`][actionenum]) — so at startup Hibernate can create the schema,
drop-and-recreate it, `VALIDATE` that the live schema matches the mappings, or `UPDATE`
(alter) it.

**Real migrations are delegated — a finding.** `UPDATE` is explicitly _not_ a migration
tool. Hibernate's own best-practices guide says so ([`BestPractices.adoc`][bestpractices]):

> _"Although Hibernate provides the `update` option for the `hibernate.hbm2ddl.auto`
> configuration property, this feature is not suitable for a production environment. An
> automated schema migration tool (e.g. Flyway, Liquibase) allows you to use any
> database-specific DDL feature (e.g. Rules, Triggers, Partitioned Tables)."_

So unlike `EF Core` or `Django ORM` (which ship a versioned migration runner), Hibernate has
_no first-party migration story_: production schema evolution is handed to **Flyway** or
**Liquibase**, and `hbm2ddl` is used for tests, prototypes, and `VALIDATE`-at-boot. The
inverse workflow — db-first — is served by the `hibernate-tools` reverse-engineering
utilities that introspect a live database into entities (out of tree).

## Type mapping & result decoding

**Row hydration produces an object graph, not a tuple.** The `loader` package "defines
functionality for processing JDBC result sets and returning complex graphs of persistent
objects" ([`loader/package-info.java`][loaderpkg]). Each entity class has an
`EntityPersister` — "defines a mechanism for persisting instances of a certain entity class"
([`persister/package-info.java`][persisterpkg]) — that knows the entity's tables, columns,
and generated SQL, and drives both the read (hydrate a row into a managed instance) and the
write (emit `INSERT`/`UPDATE`/`DELETE`).

**Basic types and converters.** A "basic type handles the persistence of an attribute … that
is stored in exactly one database column" ([`annotations/package-info.java`][annpkg]).
Hibernate maps the standard Java types (primitives and wrappers, `String`, `BigDecimal`, the
`java.time` types, `UUID`, enums, byte/char arrays) out of the box; user types plug in via
JPA `AttributeConverter` or Hibernate's `UserType`/`@JavaType`/`@JdbcType`. Nullability is
expressed by the Java type: a nullable column is a reference field (possibly `null`), a
non-null column often a primitive.

**The identity map guarantees instance uniqueness.** Because the persistence context "holds a
unique mapping from the identifier of the entity instance to the instance itself"
([`Interacting.adoc`][interactingadoc]), two loads of the same row within one session return
the _same_ Java object — "There may be at most one persistent instance with a given
persistent identity associated with a given session" ([`Session.java`][session]). This is
the [identity map][orm] pattern in its textbook form, and it is also what makes dirty
checking possible: the context keeps a **snapshot** of each entity's loaded state to diff
against. The `PersistenceContext` SPI captures exactly this ([`PersistenceContext.java`][pctx]):

> _"Represents the state of 'stuff' Hibernate is tracking, including (not exhaustive):
> entities, collections, snapshots, proxies. … Often referred to as the 'first level cache'."_

## Effect model, transactions & error handling

This is where Hibernate is most opinionated, and most distant from the effects-first designs
this survey chases.

**The persistence context is the unit of work; dirty checking is automatic.** Managed
entities are watched, and their mutations are written back with no explicit save call
([`Session.java`][session]):

> _"Persistent instances are held in a managed state by the persistence context. Any change
> to the state of a persistent instance is automatically detected and eventually flushed to
> the database. This process of automatic change detection is called dirty checking …"_

The introduction spells out the ergonomic payoff and its mechanism
([`Interacting.adoc`][interactingadoc]): dirty checking means "after modifying an entity, we
don't need to perform any explicit operation to ask Hibernate to propagate that change back
to the database. Instead, the change will be automatically synchronized with the database
when the session is flushed." This is the exact inverse of the functional mappers: where
`Ecto`'s `Changeset`, `Diesel`'s `AsChangeset`, or `SeaORM`'s `ActiveModel` make the change
set an _explicit value you hand over_, Hibernate infers it by comparing each entity to its
load-time snapshot.

**Entity lifecycle states.** An instance is in one of four states with respect to a session
([`Session.java`][session]): _transient_ ("never persistent, and not associated with the
`Session`"), _persistent_ ("currently associated with the `Session`"), _detached_
("previously persistent, but not currently associated"), and _removed_ (marked for deletion
by `remove()`). Transitions are `persist()` (transient → persistent), `remove()` (persistent
→ removed), `detach()`/`clear()` (persistent → detached), and `merge()` (copy a detached
instance's state onto a managed one).

**Flush timing is implicit — and a documented foot-gun.** SQL is _not_ emitted when you call
`persist()`/`remove()`; it is emitted at **flush** ([`Session.java`][session]): "SQL
statements are often not executed synchronously by the methods of the `Session` interface."
By default a flush is triggered ([`Interacting.adoc`][interactingadoc]) "when the current
transaction commits," "before execution of a query whose result would be affected by the
synchronization of dirty state," or when the program calls `flush()`. Flushing "is a somewhat
expensive operation (the session must dirty-check every entity in the persistence context),"
and switching the `FlushMode` to `COMMIT` to skip pre-query flushes means "queries might
return stale data" — the classic surprise.

**The write-behind pipeline is event-driven.** The `Session` is modelled as a stream of
events dispatched to listeners: an event "represents a request by the session API for some
work to be performed, and an event listener must respond … usually by scheduling some sort of
action" ([`event/spi/package-info.java`][eventpkg]). The core listeners are
`FlushEventListener`, `AutoFlushEventListener`, `FlushEntityEventListener`,
`DirtyCheckEventListener`, `PersistEventListener`, `MergeEventListener`,
`DeleteEventListener`, and `LoadEventListener` (all in `event/spi/`). A `StatelessSession`
deliberately "does not produce events and does not make use of this framework"
([`event/spi/package-info.java`][eventpkg]).

**Lazy loading via runtime proxies and bytecode enhancement.** An unfetched association is
represented by a proxy; "The state of an unfetched entity is automatically fetched from the
database when a method of its proxy is invoked, if and only if the proxy is associated with
an open session" ([`Session.java`][session]). The `proxy` package "defines a framework for
lazy-initializing entity proxies" ([`proxy/package-info.java`][proxypkg]); proxies are built
by a bytecode library, whose duties include "Proxy generation — runtime building of proxies
used to defer loading of lazy entities" and "Field-level interception — build-time
instrumentation of entity classes … for both lazy loading and dirty tracking"
([`bytecode/package-info.java`][bytecodepkg]).

The famous failure mode is the flip side of "if and only if the proxy is associated with an
open session." Access a lazy association after the session closes and you get
([`LazyInitializationException.java`][lazyexc]):

> _"Indicates an attempt to access unfetched data outside the context of an open stateful
> `Session`. … this exception occurs when an uninitialized proxy or collection is accessed
> after the session was closed."_

**N+1 is the developer's problem, and mitigations are explicit.** The introduction is candid
([`Tuning.adoc`][tuningadoc]): _"Without question, the most common cause of poorly-performing
data access code in Java programs is the problem of N+1 selects,"_ adding that it "isn't a
bug or limitation of Hibernate … Only you, the developer, can solve this problem, because
only you know ahead of time what data you're going to need in a given unit of work." Hibernate provides _outer join
fetching_ (`left join fetch` in HQL, or `From.fetch()` in criteria), _batch fetching_, and
_subselect fetching_, plus `EntityGraph`s and named _fetch profiles_
([`SelectionQuery.java`][selquery], [`Tuning.adoc`][tuningadoc]). There is real tension in
its advice — "Most associations should be mapped for lazy fetching by default," yet "Avoid
the use of lazy fetching, which is often the source of N+1 selects" — which is precisely the
foot-gun this survey's functional mappers sidestep by making every join explicit.

**Transactions: resource-local or JTA, no nesting.** A `Transaction` "represents a
resource-local transaction, where resource-local is interpreted by Hibernate to mean any
transaction under the control of Hibernate. That is to say, the underlying transaction might
be a JTA transaction, or it might be a JDBC transaction" ([`Transaction.java`][transaction]).
The idiomatic form:

```java
try (var session = factory.openSession()) {
    Transaction tx = null;
    try {
        tx = session.beginTransaction();
        //do some work
        tx.commit();
    }
    catch (Exception e) {
        if (tx!=null) tx.rollback();
        throw e;
    }
}
```

Unlike `SeaORM` or `EF Core`, there is **no built-in savepoint nesting**: "there is at most
one uncommitted transaction associated with a given `Session` at any time"
([`Transaction.java`][transaction]). After a rollback the persistence context is poison —
"the current persistence context must be discarded, and the state of its entities must be
assumed inconsistent with the state held by the database" ([`Transaction.java`][transaction]).

**Errors are thrown, not returned.** Hibernate is exception-based to the core.
`HibernateException` is "The base type for exceptions thrown by Hibernate," and it extends
the JPA `PersistenceException` (an unchecked `RuntimeException`) — so query failures are not
in any type-level [error channel][effects]; they unwind the stack
([`HibernateException.java`][hibexc]). Every JDBC-layer failure "is wrapped in some form of
`JDBCException`" ([`HibernateException.java`][hibexc]), and Hibernate translates
vendor-specific `SQLException`s into a uniform hierarchy: `ConstraintViolationException`,
`DataException`, `LockAcquisitionException`, `LockTimeoutException`, `SQLGrammarException`,
`TransactionSerializationException`, `JDBCConnectionException`, and `SnapshotIsolationException`
([`exception/package-info.java`][exceptionpkg]). This is Hibernate's answer to a
typed-error taxonomy — richer than a single `SqlException`, but delivered by throwing, which
is the opposite of the `Result`/`IO`-valued errors of `doobie` / `Effect TS`.

## Ecosystem & maturity

Hibernate is the most widely deployed ORM on the JVM and, since JPA was "modelled after
Hibernate" ([`Introduction.adoc`][introadoc]), the de facto reference for the whole standard.
It is a Red Hat project ("Copyright Red Hat Inc. and Hibernate Authors" in every header),
led for many years by Steve Ebersole after founder Gavin King, and it is a core component of
Quarkus and the persistence default for Spring Boot. The pinned tree is a monorepo of many
modules beyond `hibernate-core` — dialect packs (`hibernate-community-dialects`), pool
integrations (`hibernate-agroal`/`-hikaricp`/`-c3p0`/`-ucp`), auditing (`hibernate-envers`),
spatial and vector types (`hibernate-spatial`, `hibernate-vector`), GraalVM native-image
support (`hibernate-graalvm`), and the annotation processor that generates the static
metamodel. Backends are "any JDBC database" for which a `Dialect` exists — the in-tree set
covers PostgreSQL, MySQL/MariaDB, Oracle, SQL Server, DB2, H2, HSQLDB, Derby, SQLite, and
more.

It is licensed **Apache-2.0** at this HEAD (the SPDX tag in every file; `LICENSE.txt`), a
relicensing from the **LGPL-2.1** it carried through Hibernate 5 (the change landed with 6.0
in 2022 — web-attested). The pinned development tree is `8.1.0-SNAPSHOT`; the current stable
line is `7.x` (the `changelog.md` HEAD is `7.4.0.CR1`, May 2026). The **async** story is
_not_ in this repository: blocking JDBC is inherent to the `Session` model, and non-blocking
reactive access is a **separate project, Hibernate Reactive** (built on Vert.x, sharing the
ORM's mapping engine but with a `Mutiny`/`CompletionStage` API) — a boundary worth stressing
for an effects-first design.

## Strengths

- **The full ORM feature set, battle-hardened.** Identity map, unit of work, automatic dirty
  checking, cascade, optimistic/pessimistic locking, a two-level cache, multi-tenancy,
  auditing, and more — two decades of production use ([`Session.java`][session],
  [`SessionFactory.java`][factory]).
- **Dirty checking removes save boilerplate.** Mutate a managed entity; the `UPDATE` is
  inferred and emitted at flush, with no explicit persist call ([`Interacting.adoc`][interactingadoc]).
- **Three query surfaces, all injection-safe.** HQL/JPQL over entities, a type-safe Criteria
  API (with a generated static metamodel), and native SQL — parameter binding is the default
  and string concatenation is explicitly warned against ([`Querying.adoc`][queryingadoc]).
- **Portable across databases via `Dialect`.** One mapping runs on any JDBC backend; the
  dialect owns all engine-specific SQL ([`Dialect.java`][dialect]).
- **The JPA standard, fully.** `Session extends EntityManager`; code can be written to the
  portable JPA API and drop to native Hibernate only where needed ([`Session.java`][session]).
- **An explicit low-ceremony alternative in-box.** `StatelessSession` drops the persistence
  context for bulk/read-heavy work ([`StatelessSession.java`][stateless]).
- **Uniform error taxonomy.** Vendor `SQLException`s are converted into a meaningful
  `JDBCException` hierarchy ([`exception/package-info.java`][exceptionpkg]).

## Weaknesses

- **Implicit flush timing.** SQL is emitted at flush, not at the mutating call, and AUTO
  flush-before-query vs `COMMIT` mode trades correctness for speed — a recurring source of
  "why did that run now?" / stale-read surprises ([`Interacting.adoc`][interactingadoc]).
- **`LazyInitializationException` and N+1.** Lazy loading requires an open session; touch a
  proxy after close and it throws, and naive traversal silently fans out into N+1 selects —
  by the docs' own admission "the most common cause of poorly-performing data access code"
  ([`LazyInitializationException.java`][lazyexc], [`Tuning.adoc`][tuningadoc]).
- **Heavyweight, memory-holding sessions.** The persistence context pins hard references to
  every managed entity, so a `Session` must be short-lived and never shared across threads
  ([`Session.java`][session]).
- **No first-party migrations.** `hbm2ddl` `update` is "not suitable for a production
  environment"; real schema evolution is delegated to Flyway/Liquibase
  ([`BestPractices.adoc`][bestpractices]).
- **No savepoint nesting; poison-on-rollback.** One uncommitted transaction per session, and
  a rollback forces the whole persistence context to be discarded ([`Transaction.java`][transaction]).
- **Blocking only.** The `Session` model is JDBC-blocking; async needs the separate Hibernate
  Reactive project — there is no effect value carrying the work and its error set.
- **Deep magic.** Bytecode-generated proxies, snapshot-based dirty checking, cascade, and the
  event pipeline make behaviour hard to predict from the call site
  ([`bytecode/package-info.java`][bytecodepkg], [`event/spi/package-info.java`][eventpkg]).

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                             | Trade-off                                                                                                            |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Stateful `Session` = persistence context (identity map + unit of work)     | One managed instance per row; navigate object graphs naturally; batch writes on flush | Sessions are memory-holding, thread-unsafe, short-lived; must be discarded after any exception                       |
| **Automatic dirty checking** (snapshot diff), not an explicit changeset    | No save boilerplate — mutate a managed entity and the `UPDATE` is inferred            | Flush must dirty-check every managed entity (cost); the "when did it write?" model is implicit                       |
| Implicit flush (on commit / before affected query / explicit)              | Read-your-writes within a transaction; fewer round-trips                              | Flush timing surprises; `COMMIT` mode returns stale query results ([`Interacting.adoc`][interactingadoc])            |
| Lazy loading via runtime proxies / bytecode enhancement                    | Object graphs load on demand; you don't pre-plan every fetch                          | `LazyInitializationException` after session close; N+1 selects; needs explicit `join fetch`/`EntityGraph`            |
| HQL/JPQL — an OO dialect of SQL over entities                              | Portable, injection-safe, expressive queries above the table layer                    | A whole query language to learn; still a string (typos caught at runtime, unlike the Criteria API)                   |
| Errors **thrown** as unchecked `HibernateException`/`PersistenceException` | Idiomatic Java; a uniform `JDBCException` taxonomy over vendor `SQLException`s        | No type-level error channel; failures aren't in the method signature ([`exception/package-info.java`][exceptionpkg]) |
| Code-first annotations; `hbm2ddl` for gen/validate, migrations delegated   | The entity classes are the single source of truth; `VALIDATE` catches drift at boot   | No first-party migration runner — Flyway/Liquibase required for production ([`BestPractices.adoc`][bestpractices])   |
| Blocking JDBC; reactive is a separate project                              | Matches the JDBC substrate and the JTA/container ecosystem                            | No async/effect value in-tree; non-blocking needs Hibernate Reactive                                                 |

---

## Sources

- [hibernate/hibernate-orm — GitHub repository][repo] · [hibernate.org/orm][docs] · [Javadoc][javadoc]
- [`README.adoc` — "object/relational mapping solution for Java", JPA reference implementation, JDK/bytecode versions][readme]
- [`Introduction.adoc` — ORM "relieves the developer", "not to hide SQL", impedance-mismatch reframing, leaky-abstraction defence, JPA lineage/history][introadoc]
- [`Session.java` — the persistence context; identity map; dirty checking; lifecycle states; proxies; flush; transaction idiom; "Every `Session` is a JPA `EntityManager`"][session]
- [`SessionFactory.java` — runtime metamodel, immutable/threadsafe root, `inTransaction`, session lifecycle][factory]
- [`StatelessSession.java` — no persistence context, no first-level cache, no write-behind/dirty checking, explicit fetch][stateless]
- [`SharedSessionContract.java` — operations common to `Session` and `StatelessSession`][shared]
- [`Transaction.java` — resource-local/JTA transaction; one uncommitted tx per session; discard-on-rollback][transaction]
- [`engine/spi/PersistenceContext.java` — "entities, collections, snapshots, proxies … the 'first level cache'"][pctx]
- [`event/spi/package-info.java` — event/listener framework for the flush/dirty pipeline; `StatelessSession` produces none][eventpkg]
- [`persister/package-info.java` — `EntityPersister`/`CollectionPersister` (entity → SQL)][persisterpkg] · [`loader/package-info.java` — result-set → object graph][loaderpkg]
- [`query/package-info.java` — HQL/JPQL, native SQL, criteria][querypkg] · [`query/SelectionQuery.java` — HQL + `setParameter` + `join fetch`][selquery] · [`query/Query.java`][queryjava] · [`query/criteria/package-info.java` — `HibernateCriteriaBuilder`][critpkg]
- [`dialect/Dialect.java` — per-RDBMS SQL generation; thread-safe/immutable; version via `DialectResolutionInfo`][dialect]
- [`bytecode/package-info.java` — proxy generation + field interception for lazy loading & dirty tracking][bytecodepkg] · [`proxy/package-info.java` — lazy-initializing entity proxies][proxypkg]
- [`LazyInitializationException.java` — access to unfetched data after session close][lazyexc]
- [`annotations/package-info.java` — Hibernate mapping annotations extending JPA; basic types][annpkg] · [`Entities.adoc` — `@Entity`/`@Id`/associations][entitiesadoc]
- [`cfg/SchemaToolingSettings.java` — `hibernate.hbm2ddl.auto`][schemasettings] · [`tool/schema/Action.java` — `CREATE`/`VALIDATE`/`UPDATE`/…][actionenum] · [`tool/schema/spi/SchemaManagementTool.java`][schematool]
- [`userguide/appendices/BestPractices.adoc` — `hbm2ddl` `update` "not suitable for a production environment"; use Flyway/Liquibase][bestpractices]
- [`Querying.adoc` — named/ordinal parameters; "Never concatenate user input with HQL"; criteria auto-parameterization; native SQL][queryingadoc]
- [`Interacting.adoc` — persistence context = first-level cache; identity map; automatic dirty checking; flush timing/modes][interactingadoc]
- [`Tuning.adoc` — N+1 selects; outer-join/batch/subselect fetching; lazy-by-default vs avoid-lazy tension][tuningadoc]
- [`Configuration.adoc` — built-in pool "not meant for use in production"; Agroal/HikariCP/c3p0][configadoc] · [`DriverManagerConnectionProvider.java` — "a very rudimentary connection pool … Not intended for use in production systems!"][dmcp]
- [`HibernateException.java` — base thrown type; JDBC wrapped in `JDBCException`][hibexc] · [`exception/package-info.java` — `ConstraintViolationException` & the `JDBCException` taxonomy][exceptionpkg]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [injection][inject] · [schema/migrations][schema] · [ORM patterns][orm] · [N+1][nplusone] · [effects & transactions][effects] · [pools][pool])
- Related deep-dives in this survey: `EF Core` · `SQLAlchemy` · `Django ORM` · `SeaORM` · `jOOQ` · `JDBI` · `doobie` · `Quill` · `Ecto` · `Effect TS`

<!-- References -->

[repo]: https://github.com/hibernate/hibernate-orm
[docs]: https://hibernate.org/orm/
[javadoc]: https://docs.jboss.org/hibernate/orm/current/javadocs/
[intro]: https://docs.jboss.org/hibernate/orm/current/introduction/html_single/Hibernate_Introduction.html
[readme]: https://github.com/hibernate/hibernate-orm/blob/main/README.adoc
[introadoc]: https://github.com/hibernate/hibernate-orm/blob/main/documentation/src/main/asciidoc/introduction/Introduction.adoc
[session]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/Session.java
[factory]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/SessionFactory.java
[stateless]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/StatelessSession.java
[shared]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/SharedSessionContract.java
[transaction]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/Transaction.java
[pctx]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/engine/spi/PersistenceContext.java
[eventpkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/event/spi/package-info.java
[persisterpkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/persister/package-info.java
[loaderpkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/loader/package-info.java
[querypkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/query/package-info.java
[selquery]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/query/SelectionQuery.java
[queryjava]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/query/Query.java
[critpkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/query/criteria/package-info.java
[dialect]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/dialect/Dialect.java
[bytecodepkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/bytecode/package-info.java
[proxypkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/proxy/package-info.java
[lazyexc]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/LazyInitializationException.java
[annpkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/annotations/package-info.java
[entitiesadoc]: https://github.com/hibernate/hibernate-orm/blob/main/documentation/src/main/asciidoc/introduction/Entities.adoc
[schemasettings]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/cfg/SchemaToolingSettings.java
[actionenum]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/tool/schema/Action.java
[schematool]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/tool/schema/spi/SchemaManagementTool.java
[bestpractices]: https://github.com/hibernate/hibernate-orm/blob/main/documentation/src/main/asciidoc/userguide/appendices/BestPractices.adoc
[queryingadoc]: https://github.com/hibernate/hibernate-orm/blob/main/documentation/src/main/asciidoc/introduction/Querying.adoc
[interactingadoc]: https://github.com/hibernate/hibernate-orm/blob/main/documentation/src/main/asciidoc/introduction/Interacting.adoc
[tuningadoc]: https://github.com/hibernate/hibernate-orm/blob/main/documentation/src/main/asciidoc/introduction/Tuning.adoc
[configadoc]: https://github.com/hibernate/hibernate-orm/blob/main/documentation/src/main/asciidoc/introduction/Configuration.adoc
[dmcp]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/engine/jdbc/connections/internal/DriverManagerConnectionProvider.java
[hibexc]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/HibernateException.java
[exceptionpkg]: https://github.com/hibernate/hibernate-orm/blob/main/hibernate-core/src/main/java/org/hibernate/exception/package-info.java
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[schema]: ./concepts.md#schema-migrations-code-generation
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions
[sec-effects]: #effect-model-transactions-error-handling

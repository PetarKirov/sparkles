# doobie (Scala)

A pure-functional JDBC layer for Scala that models every database operation as a value in a [free-monad][concepts] effect (`ConnectionIO`), assembles SQL through the injection-safe `sql"..."` / `fr"..."` interpolators, and interprets the whole program into a [`cats-effect`][catseffect] target `F` at the edge.

| Field              | Value                                                                                                                   |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Language           | Scala (cross-built for `2.12` / `2.13` / `3.3`), JVM only (wraps `java.sql`)                                            |
| License            | MIT                                                                                                                     |
| Repository         | [typelevel/doobie][repo]                                                                                                |
| Documentation      | [microsite / "Book of doobie"][site] · [Scaladoc][scaladoc]                                                             |
| Category           | [Functional data mapper][concepts-ladder] — safe raw SQL; explicitly _"not an ORM, nor … a relational algebra"_         |
| Abstraction level  | [Data mapper (functional)][concepts-ladder] rung — queries as first-class values, no identity map / change tracking     |
| Query model        | [Tagged-template][concepts-models] (`sql"..."` / `fr"..."`) building an opaque `Fragment`, composed by concatenation    |
| Effect/async model | [Effect value][concepts-effects] — the `ConnectionIO` free monad, interpreted into any `cats-effect` `F` (`IO`/`Async`) |
| Backends           | Any JDBC driver; first-party add-ons for PostgreSQL, MySQL, H2, plus a HikariCP pool transactor                         |
| First release      | ≈2013 (originally `tpolecat/doobie`; ≈ soft, web-attested)                                                              |
| Latest version     | `1.0` series (pinned tree targets `tlBaseVersion := "1.0"`, group `org.typelevel`)                                      |

> [!NOTE]
> doobie sits on the [functional data-mapper rung][concepts-ladder] of the abstraction ladder:
> below a full ORM (no identity map, no unit of work, no change tracking) and above a bare
> driver (parameters bind automatically and rows hydrate into typed values). It is this
> survey's data point for a **free-monad** effect encoding — the Scala-FP counterpart to the
> `Effect TS` `sql` layer and to `Quill`/`skunk`/`Ecto`, but built on `cats-effect`'s free
> monad and `MonadError` rather than a bespoke effect runtime. See [concepts][concepts] for
> the shared vocabulary.

---

## Overview

### What it solves

doobie turns JDBC — a large, stateful, exception-throwing Java API — into a set of _pure
values_ you compose and run at the edge of the program. Rather than call
`connection.prepareStatement(...)` and mutate a `PreparedStatement` in place, you build a
description of that work (`ConnectionIO[A]`) and hand it to a `Transactor` to interpret. The
microsite states the scope precisely ([`modules/docs/src/main/mdoc/docs/01-Introduction.md`][intro]):

> _"**doobie** provides low-level access to everything in `java.sql` (as of Java 8), allowing
> you to write any JDBC program in a pure functional style. However the focus of this book is
> the **high-level API**, which is where most users will spend their time."_

The high-level API is deliberately thin: a `sql"..."` interpolator produces a `Fragment`,
`.query[A]` / `.update` turn a `Fragment` into a `Query0[A]` / `Update0`, and `.transact(xa)`
runs it. Everything in between — parameter binding, result decoding, resource lifetime,
commit/rollback — is handled by typeclasses and the transactor, not by a mutable session
object.

### Design philosophy

doobie's own front page fixes exactly where it stands on the [abstraction ladder][concepts-ladder]
([`modules/docs/src/main/mdoc/index.md`][mdocindex]):

> _"**doobie** is a pure functional JDBC layer for Scala and Cats. It is not an ORM, nor is
> it a relational algebra; it simply provides a functional way to construct programs (and
> higher-level libraries) that use JDBC."_

Three commitments follow from that sentence, each visible in the code.

**Programs as values.** A doobie query is not an action; it is a value describing an action.
The `README` compresses the whole pitch to one line ([`README.md`][readme]): _"**doobie** is a
pure functional JDBC layer for Scala."_ The value is a `ConnectionIO[A]` — a free-monad
program over the JDBC `Connection` algebra (see
[Effect model, transactions & error handling](#effect-model-transactions--error-handling)) —
so it is referentially transparent, inspectable, and composable with `map`/`flatMap` before
anything touches a socket.

**Typed, but not an ORM.** doobie maps rows to types through the `Get`/`Put`/`Read`/`Write`
typeclasses, yet it owns no schema, tracks no entity mutations, and manages no relations. It
is a _mapper_, in Fowler's [Data Mapper][concepts-orm] sense (persistence-ignorant values),
minus the mutable objects — the same boundary drawn by `Quill`, `skunk`, and `Ecto`.

**Cats/Typelevel native.** doobie targets people _"interested in typed, pure functional
programming"_ ([`01-Introduction.md`][intro]); it is a [Typelevel][typelevel] project built on
`cats`, `cats-effect`, and `fs2`, and it borrows their idioms wholesale — `Monoid` for
fragment concatenation, `MonadError` for failures, `Resource` for pooled connections, `Stream`
for cursors.

---

## Connection, pooling & resource lifetime

doobie separates the _description_ of database work from the _means of running it_. Almost
every doobie program is a `ConnectionIO[A]` — a value that "requires a database connection" but
does not itself hold one ([`14-Managing-Connections.md`][conn]):

> _"Most **doobie** programs are values of type `ConnectionIO[A]` or `Stream[ConnectionIO, A]`
> that describe computations requiring a database connection. By providing a means of acquiring
> a JDBC connection we can transform these programs into computations that can actually be
> executed. The most common way of performing this transformation is via a `Transactor`."_

A [`Transactor[M]`][tx] bundles four things — a `kernel` (implementation-specific config), a
`connect: A => Resource[M, Connection]` source of connections, an `interpret: ConnectionOp ~> Kleisli[M, Connection, *]`
interpreter, and a transaction `Strategy` ([`util/transactor.scala`][tx]):

> _"A thin wrapper around a source of database connections, an interpreter, and a strategy for
> running programs, parameterized over a target monad `M` and an arbitrary wrapped value `A`.
> Given a stream or program in `ConnectionIO` … a `Transactor` can discharge the doobie
> machinery and yield an effectful … program in `M`."_

Constructors cover the usual sources ([`util/transactor.scala`][tx]):

```scala
// A DriverManager transactor — simplest, unpooled, fine for consoles/tests.
val xa = Transactor.fromDriverManager[IO](
  driver = "org.postgresql.Driver", url = "jdbc:postgresql:world",
  user = "postgres", password = "password", logHandler = None
)

// From an existing pooled javax.sql.DataSource (you supply the connect EC):
Transactor.fromDataSource[IO](ds, connectEC)

// From a single caller-owned Connection:
Transactor.fromConnection[IO](conn, logHandler = None)
```

**Resource-scoped pools.** The connection source is a `cats-effect` `Resource`, so a pool's
lifetime is type-tracked and leak-free. The `doobie-hikari` add-on wraps a HikariCP pool as a
`Resource[IO, HikariTransactor[IO]]` that is _"managed as a `Resource` … Everything will be
closed and shut down cleanly after use"_ ([`14-Managing-Connections.md`][conn]). This maps
onto the [scoped acquire/release][concepts-pools] idiom the effect systems in this survey share:
a leaked connection is a lifetime error at the `Resource` boundary, not a runtime leak.
`fromDriverManager` is explicitly the exception — its docstring warns it _"is unbounded and
will happily allocate new connections until server resources are exhausted … don't use it for
a web application"_ ([`util/transactor.scala`][tx]).

The `connectEC` execution context on which a thread blocks waiting for a pooled connection
_"should be **bounded** … The maximum thread limit for `connectEC` should be the same as your
underlying JDBC connection pool"_ ([`14-Managing-Connections.md`][conn]) — a direct consequence
of JDBC being a blocking API that `cats-effect` shifts onto a dedicated blocking pool.

---

## Query construction & injection safety

This is doobie's centre of gravity, and the mechanism is small enough to read end to end.

**The `sql` interpolator produces a `Fragment`.** `sql"..."` and `fr"..."` are ordinary Scala
`StringContext` interpolators. Each interpolated `$expr` is required to have a typeclass
instance; the interpolator's docstring is explicit ([`syntax/string.scala`][string]):

> _"String interpolator for SQL literals. An expression of the form `sql".. $a ... $b ..."`
> with interpolated values of type `A` and `B` (which must have instances of `Put`) yields a
> value of type `Fragment`."_

Under the hood each `$expr` is turned into a one-column `Fragment` whose SQL text is a single
`?` placeholder and whose captured value rides alongside as an `Elem`, while the literal SQL
parts become placeholder-free fragments; the pieces are then concatenated
([`syntax/string.scala`][string], [`util/write.scala`][write]):

```scala
// syntax/string.scala — an interpolated value becomes a "?" fragment carrying the arg:
implicit def fromWrite[A](a: A)(implicit write: Write[A]): SingleFragment[A] =
  SingleFragment(write.toFragment(a))

// util/write.scala — toFragment renders "?" placeholders and captures each value as an Elem:
def toFragment(a: A, sql: String = List.fill(length)("?").mkString(",")): Fragment = {
  val elems: List[Elem] = (puts zip toList(a)).map { case ((p, nullab), x) => … }
  Fragment(sql, elems, None)
}
```

**A `Fragment` is opaque and composable.** The `Fragment` type carries the SQL string, a
`Chain[Elem]` of captured arguments, and a source position ([`util/fragment.scala`][fragment]):

> _"A statement fragment, which may include interpolated values. Fragments can be composed by
> concatenation, which maintains the correct offset and mappings for interpolated values. Once
> constructed a `Fragment` is opaque; it has no externally observable properties. Fragments are
> eventually used to construct a `Query0` or `Update0`."_

Fragments form a `Monoid` ([`util/fragment.scala`][fragment]: `implicit val FragmentMonoid`), so
`++` (and `+~+`, which guarantees a separating space) build large statements from small ones,
keeping SQL text and bound parameters in lockstep. Each captured argument is an `Elem.Arg[A](a: A, p: Put[A])`
(or `Elem.Opt` for `Option`) — the value paired with the `Put[A]` that knows how to set it.

**Injection is structurally impossible for interpolated values.** When a fragment runs, its
SQL string (with `?` placeholders) becomes a `PreparedStatement` and the `Elem`s are bound as
out-of-band parameters ([`util/fragment.scala`][fragment]: `execWith` →
`prepareStatementPrimitive(sql)(write.set(1, elems)…)`). The microsite makes the guarantee
concrete ([`05-Parameterized.md`][param]):

> _"So what's going on? It looks like we're just dropping a string literal into our SQL string,
> but actually we're constructing a `PreparedStatement`, and the `minPop` value is ultimately
> set via a call to `setInt`."_

Because every `$expr` travels on the parameter channel — never the SQL-text channel — a hostile
value cannot change the query's structure. This is the [tagged-template safety
model][concepts-injection] realized through typeclasses.

```scala
// A parameterized query. `$n` binds as a ? parameter, not string-spliced.
def find(n: String): ConnectionIO[Option[Country]] =
  sql"select code, name, population from country where name = $n"
    .query[Country]   // Query0[Country]
    .option           // ConnectionIO[Option[Country]]

// Runtime fragment composition stays safe: literals + params interleave correctly.
def biggerThan(min: Int, codes: NonEmptyList[String]) =
  (fr"select code, name, population from country where population > $min and" ++
   Fragments.in(fr"code", codes))          // code IN (?, ?, …)
    .query[Country]
```

**The `Fragments` combinator module.** Common dynamic-SQL shapes are provided as fragment
builders ([`util/fragments.scala`][fragments]): `in` / `notIn` (`IN` clauses over a
`NonEmptyList`), `whereAnd` / `whereAndOpt` / `whereOr` / `whereOrOpt` (conjunction/disjunction
`WHERE` clauses that collapse to empty when no filter is present), `set` (for `UPDATE … SET`),
`values`, and `parentheses`. Optional filters compose cleanly:

```scala
val q =
  fr"SELECT name, code, population FROM country" ++
  Fragments.whereAndOpt(f1, f2, f3) ++          // WHERE appears only if a filter is defined
  fr"LIMIT $limit"
```

**The escape hatch (and its warning).** `Fragment.const(s)` / `const0(s)` splice a raw string
as literal SQL — the way to parameterize on identifiers (table/column names) that cannot be
bind parameters. doobie flags the risk in bold ([`08-Fragments.md`][frag]):

> _"Note that `Fragment.const` performs no escaping of passed strings. Passing user-supplied
> data is an **injection risk**."_

The compositional invariant is stated just as plainly ([`08-Fragments.md`][frag]): _"As long as
your individual fragments were constructed securely (i.e. Never call `Fragment.const` with user
supplied input), You can freely concatenate or interpolate fragments without worrying about SQL
injection."_ Note the naming quirk: the `sql` interpolator _"is simply an alias for `fr0`"_
(no trailing space), whereas `fr` appends one to ease concatenation ([`08-Fragments.md`][frag],
[`syntax/string.scala`][string]).

---

## Schema, migrations & code generation

**doobie owns no schema — this is a deliberate absence.** There is no model/entity declaration
that _is_ the schema (no code-first), no `.sql`/DSL schema file it treats as the source of truth
(no schema-first), and — searched across `modules/*/src/main/scala` — **no migration runner and
no DDL/versioning tooling** in the tree. doobie's own tagline draws the line: it is _"not an ORM,
nor … a relational algebra"_ ([`index.md`][mdocindex]). You write DDL as ordinary `sql"CREATE TABLE …".update.run`
statements if you wish, but versioning/ordering is left to external tools (Flyway, Liquibase),
exactly as with `Dapper` or `JDBI`.

**What doobie offers instead is _query typechecking_ against a live database.** Every `Query`/`Update`
can produce an `Analysis` — a `ConnectionIO[Analysis]` that prepares the statement and compares
its asserted parameter and column types against the JDBC metadata
([`util/query.scala`][query]: `def analysis: ConnectionIO[Analysis]`). The `.check` combinator
(and the specs2/ScalaTest add-ons) run this analysis in a test and report mismatches
([`06-Checking.md`][checking]). This is a **db-first verification** move — not code generation —
that catches a column renamed in the database or a wrong Scala type _at test time_ rather than
in production. It is the same family as `sqlx`'s macro checks, but performed at runtime against
a real connection rather than at compile time.

There is no first-party [introspection→codegen][concepts-schema] path (the `jOOQ`/`sqlc` move);
row shapes are asserted by the programmer through `.query[A]` and validated by `.check`.

---

## Type mapping & result decoding

doobie's [codec][concepts-types] story is a four-typeclass tower, split cleanly into
single-column and multi-column layers.

| Typeclass  | Direction      | Columns | Role                                                                               |
| ---------- | -------------- | ------- | ---------------------------------------------------------------------------------- |
| `Get[A]`   | read (decode)  | one     | Pull an `A` out of a `ResultSet` at index `n`, handling `NULL`                     |
| `Put[A]`   | write (encode) | one     | Set an `A` onto a `PreparedStatement` at index `n`, with allowed JDBC target types |
| `Meta[A]`  | both           | one     | A _symmetric_ `Get`/`Put` pair for a column type                                   |
| `Read[A]`  | read (decode)  | many    | Hydrate a whole row / case class / tuple, composed from `Get`s                     |
| `Write[A]` | write (encode) | many    | Bind a whole parameter list, composed from `Put`s                                  |

**Single column: `Get` / `Put` / `Meta`.** `Put[A]` carries the JDBC target types plus the
effectful setter ([`util/put.scala`][put]: `unsafeSetNonNullable(ps, n, a)`); `Get[A]` carries
the getter and enforces non-null reads ([`util/get.scala`][get]:
`unsafeGetNonNullable` throws `NonNullableColumnRead` when `rs.wasNull`). `Meta[A]` is only a
convenience bundling both, and its docstring warns against demanding it directly
([`util/meta/meta.scala`][meta]):

> _"It's important to understand that `Meta` should never be demanded by user methods; instead
> demand both `Get` and `Put`. The reason for this is that while `Meta` implies `Get` and
> `Put`, the presence of both `Get` and `Put` does *not* imply `Meta`."_

Custom column types derive by invariant-mapping an existing `Meta` ([`12-Custom-Mappings.md`][custom]):
`Meta[Int].imap(fromInt)(toInt)` (prefer `timap`, which records a type name for better
diagnostics; `tiemap` allows the read to fail). `Get`/`Put` are (co/contra)variant functors, so
`map`/`contramap`/`emap` refine them without touching JDBC.

**Multi-column: `Read` / `Write`.** A `Read[A]` decodes an entire row into an `A`
([`util/read.scala`][read]: `def unsafeGet(rs, startIdx): A`); a `Write[A]` binds an entire
parameter list ([`util/write.scala`][write]: `def unsafeSet(ps, startIdx, a): Unit`). Instances
are **derived automatically** for tuples, `Option`s, and case classes whose members each have a
`Get`/`Put`: on Scala 3 through `Mirror.ProductOf` compile-time derivation
([`scala-3/…/ReadPlatform.scala`][readplatform3]), on Scala 2 through shapeless `Generic`/`HList`
([`scala-2/…/ReadPlatform.scala`][readplatform2]) — imported via `doobie.generic.auto._` or
`doobie.implicits._`. `Query[A, B]` is thus parameterized by an input `A` with `Write[A]` and an
output `B` with `Read[B]` ([`util/query.scala`][query]).

**Nullability is `Option`.** A nullable column maps to `Option[A]`; `Read`/`Write` thread the
`NullabilityKnown` flag so a `NULL` read into a non-`Option` type raises rather than silently
producing a default ([`util/read.scala`][read], [`util/get.scala`][get]).

**Result cardinality** is chosen at the call site on `Query0[B]` ([`04-Selecting.md`][selecting]):
`.to[List]` (any collection), `.unique` (_"a single value, raising an exception if there is not
exactly one row"_), `.option` (_"an `Option`, raising … if there is more than one row"_), `.nel`
(`NonEmptyList`, raising if empty), and `.stream` (an `fs2` `Stream[ConnectionIO, B]` backed by a
server-side cursor).

---

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and doobie's answer is a **free monad**.

### `ConnectionIO` is a free monad over the JDBC algebra

For each JDBC interface doobie generates an _algebra_ of operations and takes the free monad over
it. For `java.sql.Connection` the definition is literally ([`modules/free/…/connection.scala`][free]):

```scala
// Algebra of operations for Connection. Each accepts a visitor …
sealed trait ConnectionOp[A] { def visit[F[_]](v: ConnectionOp.Visitor[F]): F[A] }

// Free monad over ConnectionOp.
type ConnectionIO[A] = FF[ConnectionOp, A]   // FF = cats.free.Free
```

Every JDBC call becomes a case object/class lifted into that free monad via `FF.liftF` —
`commit`, `rollback`, `setAutoCommit(false)`, `prepareStatement(sql)`, `createStatement`, and so
on ([`connection.scala`][free]). Because they are just data, a `ConnectionIO` program is a
_description_: `sql"…".query[C].option` allocates nothing on a connection until it is run. The
same treatment produces sibling algebras `PreparedStatementIO`, `ResultSetIO`,
`CallableStatementIO`, `DatabaseMetaDataIO`, and more — the whole of `java.sql` reified as free
monads.

Crucially, the `ConnectionOp` algebra is not _only_ JDBC methods: it also includes the
`cats-effect` primitives (`raiseError`, `handleErrorWith`, `delay`, `uncancelable`, `onCancel`,
`fromFuture`, …) as operations ([`connection.scala`][free]: `Visitor[F]`). This lets doobie
publish a `WeakAsync[ConnectionIO]` instance ([`connection.scala`][free]:
`implicit val WeakAsyncConnectionIO`), so `ConnectionIO` is itself a fully-featured effect monad
you can `flatMap`, `attempt`, and make cancelable — before any connection exists.

### The transactor interprets it into a `cats-effect` `F`

A program stays in `ConnectionIO` until a `Transactor` runs it. The interpreter is a natural
transformation `ConnectionOp ~> Kleisli[M, Connection, *]` ([`free/kleisliinterpreter.scala`][interp]:
`ConnectionInterpreter`), and running a program is a `foldMap` through it, feeding the leased
connection ([`util/transactor.scala`][tx]: `f.foldMap(interpret).run(conn)`). The user-facing
verb is `.transact(xa)`, defined as exactly `xa.trans.apply(ma)` ([`syntax/connectionio.scala`][cio]):

```scala
def find(n: String): ConnectionIO[Option[Country]] =
  sql"select code, name, population from country where name = $n".query[Country].option

// Interpret the description into IO, inside a transaction, and run at the edge:
val result: IO[Option[Country]] = find("France").transact(xa)
```

The microsite frames the interpretation as the moment doobie disappears
([`14-Managing-Connections.md`][conn]):

> _"once you have a `Transactor[M]` you have a way of discharging `ConnectionIO` and replacing
> it with some effectful `M` like `IO`. In effect this turns a **doobie** program into a "real"
> program value that you can integrate with the rest of your application; all doobieness is left
> behind."_

The target `M` is _any_ `cats-effect` `Async`/`MonadCancelThrow` — `IO`, `SyncIO`, a `Kleisli`,
a tagless-final `F[_]` — so doobie is effect-runtime-agnostic in the same way `Quill` offers
both `Future` and ZIO contexts.

### Transactions: a pluggable `Strategy`, savepoints for nesting

The transaction envelope is a first-class value, a `Strategy` of four `ConnectionIO[Unit]`
programs — `before`, `after`, `oops` (on failure), `always` (finally)
([`util/transactor.scala`][tx]). The default is the obvious one ([`util/transactor.scala`][tx]):

> _"A default `Strategy` with the following properties: Auto-commit will be set to `false`; the
> transaction will `commit` on success and `rollback` on failure."_

Its implementation is `Strategy(setAutoCommit(false), commit, rollback, unit)`, wired into a
`Resource[ConnectionIO, Unit]` so success runs `after` and any error/cancel runs `oops`
([`util/transactor.scala`][tx]). Because the strategy is data, it is replaceable through lenses:
`Transactor.after.set(xa, HC.rollback)` yields an always-rollback transactor for tests, and
`Strategy.void` disables transaction handling for drivers (e.g. Hive) that lack commit/rollback
([`14-Managing-Connections.md`][conn]). The `ConnectionOp` algebra exposes `setSavepoint` /
`rollback(savepoint)` / `releaseSavepoint` ([`connection.scala`][free]), the primitives for
[nested-transaction / savepoint][concepts-effects] combinators.

### Errors: the effect's `MonadError` channel, not a typed error

doobie makes a considered choice _against_ a typed error channel
([`09-Error-Handling.md`][errors]):

> _"we must decide whether to compute everything in a disjunction like
> `EitherT[ConnectionIO, Throwable, A]` or allow exceptions to propagate until they are caught
> explicitly. **doobie** adopts the second strategy: exceptions are allowed to propagate and
> escape unless handled explicitly (exactly as `IO` works)."_

Failures ride the `cats-effect` error channel: _"All **doobie** monads provide an `Async`
instance, which extends `MonadError[?[_], Throwable]`"_ ([`09-Error-Handling.md`][errors]), so
`.attempt`lifts any`ConnectionIO[A]`to`ConnectionIO[Either[Throwable, A]]`and`raiseError`injects a failure. This contrasts with`Effect TS`(a single`SqlError`over a reason union in
the _type_) and sits closer to`Quill`'s ZIO contexts, which narrow to a `SQLException`channel.
doobie recovers the ergonomics with SQL-aware combinators layered on`MonadError`
([`09-Error-Handling.md`][errors]): `attemptSql`/`attemptSomeSql`/`exceptSql`(trap`SQLException`) and `attemptSqlState`/`attemptSomeSqlState`/`exceptSomeSqlState`(match on`SQLState`), so a Postgres unique-violation `"23505"` can be caught as a value:

```scala
def safeInsert(s: String): ConnectionIO[Either[String, Person]] =
  insert(s).attemptSomeSqlState { case sqlstate.class23.UNIQUE_VIOLATION => "Oops!" }
```

Beyond `SQLException`, doobie raises an `InvariantViolation` for invalid type mappings, unknown
JDBC constants, and unexpected `NULL`s — _"programmer error or driver non-compliance …
generally unrecoverable"_ ([`09-Error-Handling.md`][errors]). There is **no** ORM-style change
tracking, dirty-checking, or flush: a `ConnectionIO` does precisely the statements you wrote,
in order.

---

## Ecosystem & maturity

doobie is a mature [Typelevel][typelevel] project under the permissive **MIT** license
([`LICENSE`][license]: _"The MIT License (MIT) … Copyright (c) 2013-2017 Rob Norris"_), authored
by Rob Norris (`tpolecat`) and maintained by the Typelevel org. The pinned tree is the `1.0`
development line: it cross-builds for Scala `2.12` / `2.13` / `3.3` on `cats-effect 3.7.0` and
`fs2 3.13.0` ([`build.sbt`][build]), and has renamed the root package from `doobie` to
`org.typelevel.doobie` and the Maven group to `org.typelevel` for the 1.0 release.

**Backends:** any JDBC-compliant database works through the core; first-party add-on modules
provide driver-specific type mappings and helpers for PostgreSQL (`doobie-postgres`), MySQL
(`doobie-mysql`), and H2 (`doobie-h2`), a HikariCP pooled transactor (`doobie-hikari`), circe
JSON integrations, `log4cats`/`otel4s` observability, and specs2/ScalaTest/munit/weaver testing
support ([`modules/`][repo]). Query typechecking (`.check`) is a headline maturity feature: the
test add-ons verify SQL against a live schema.

**Adoption** (web-attested): doobie's own front page lists production users including Avast,
eBay, ITV, The Guardian, SecurityScorecard, and Medidata ([`index.md`][mdocindex]). It is a de
facto standard for functional JDBC access in the Scala ecosystem and a common building block
under http4s-based services (the "functional web stack").

---

## Strengths

- **Programs as values.** A `ConnectionIO[A]` is a pure, inspectable description; composition,
  testing, and reasoning happen before any I/O, and the same value runs under `IO`, a tagless
  `F`, or a test interpreter.
- **Injection-safe by default.** Every interpolated `$expr` binds as a `?` parameter via `Put`;
  raw splicing requires the explicitly-labelled `Fragment.const` "injection risk" hatch.
- **Composable SQL.** `Fragment` is a `Monoid`; `++` / `+~+` and the `Fragments` combinators
  (`in`, `whereAndOpt`, `set`, …) build dynamic SQL while keeping text and parameters aligned.
- **Full JDBC surface.** Because the free algebras cover all of `java.sql`, anything JDBC can do
  (stored procedures, LOBs, metadata, batch updates, generated keys) is expressible purely.
- **Effect-agnostic.** Interprets into any `cats-effect` `Async`; integrates with `fs2` streaming
  and `Resource`-scoped pools.
- **Query typechecking.** `.check` / `analysis` validate a statement's parameter and result types
  against a real database at test time — a safety net no bare driver offers.
- **No hidden magic.** No identity map, lazy loading, N+1 surprises, or implicit flush; the SQL
  that runs is the SQL you wrote.

## Weaknesses

- **You write SQL.** doobie generates no SQL and provides no dialect layer or typed relational
  algebra; portability across engines is your problem, unlike `Slick`/`jOOQ`/`Quill`.
- **Untyped error channel.** Failures are `Throwable` in `MonadError`, not a typed error union;
  you opt back into typed handling with `.attemptSomeSqlState` or `EitherT`. Contrast `Effect TS`.
- **No schema/migrations/codegen.** No entity model, no migration runner, no introspection — pair
  it with Flyway/Liquibase and hand-written row types.
- **Runtime, not compile-time, checking.** `.check` needs a live database and runs in tests;
  there is no build-time schema verification like `sqlx`'s macros.
- **FP prerequisite.** The API assumes fluency with `cats`/`cats-effect` (free monads, `Resource`,
  tagless final); the docs themselves recommend prior functional-programming study.
- **JVM/JDBC only.** Blocking JDBC underneath (shifted onto a blocking pool); no Scala.js/Native,
  and no async wire protocol — that is `skunk`'s niche.

---

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                                      | Trade-off                                                                                                      |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Model JDBC as **free monads** (`ConnectionIO` = `Free[ConnectionOp, *]`) | Pure, inspectable, composable descriptions; one algebra interpreted many ways (real DB, tests) | An interpretation layer and `foldMap` overhead; a large generated codebase; a learning curve over direct calls |
| Run via a **`Transactor` → `cats-effect` `F`** interpreter               | Effect-runtime-agnostic; pooling as `Resource`, streaming as `fs2`                             | Nothing executes until interpreted; the whole `cats`/`cats-effect` stack is a hard dependency                  |
| **Raw SQL** through `sql"..."`, no query DSL/AST                         | Full SQL power, zero abstraction leak, exact control over the statement                        | No dialect portability, no compile-time column/table checking, no relational algebra                           |
| **Parameter binding by `Put`/`Write`** on every `$expr`                  | Injection-safe by construction; typed encoders compose                                         | Splicing identifiers needs the unsafe `Fragment.const` hatch (flagged "injection risk")                        |
| **`Fragment` `Monoid`** for composition                                  | Dynamic SQL built from reusable typed pieces; text + params stay in sync                       | The programmer owns whitespace/parenthesization correctness (`fr` vs `fr0`, `+~+`)                             |
| Errors as **`Throwable` in `MonadError`**, not typed                     | Matches `IO` semantics; simple; SQL-state combinators recover ergonomics                       | Failure modes are invisible in types; typed handling is opt-in (`attemptSomeSqlState`)                         |
| **No ORM machinery** (no identity map / unit of work / migrations)       | Predictable SQL, no N+1 or implicit-flush surprises; smaller, sharper library                  | You hand-write row types and manage schema/migrations with other tools                                         |
| Derive `Read`/`Write` via **`Mirror` (Scala 3) / shapeless (Scala 2)**   | Case classes and tuples map to rows with no boilerplate                                        | Derivation errors can be cryptic; cross-version derivation machinery differs                                   |

---

## Sources

- [typelevel/doobie — GitHub repository][repo] · [microsite "Book of doobie"][site] · [Scaladoc][scaladoc]
- [`README.md` — "pure functional JDBC layer for Scala"][readme]
- [`modules/docs/src/main/mdoc/index.md` — "not an ORM, nor … a relational algebra"; front-page example; adopters][mdocindex]
- [`modules/docs/src/main/mdoc/docs/01-Introduction.md` — scope, high-level API focus][intro]
- [`modules/docs/src/main/mdoc/docs/05-Parameterized.md` — `Put`/`Write`; `PreparedStatement`/`setInt` injection safety][param]
- [`modules/docs/src/main/mdoc/docs/08-Fragments.md` — `fr`/`fr0`/`++`; `Fragment.const` injection warning; `Fragments` module][frag]
- [`modules/docs/src/main/mdoc/docs/09-Error-Handling.md` — `MonadError`; `attemptSomeSqlState`; propagate-not-typed choice][errors]
- [`modules/docs/src/main/mdoc/docs/14-Managing-Connections.md` — `Transactor`, `trans`/`transact`, HikariCP `Resource`, `Strategy`][conn]
- [`modules/core/src/main/scala/doobie/util/transactor.scala` — `Transactor`, `Strategy.default`, `fromDriverManager`/`fromDataSource`/`fromConnection`][tx]
- [`modules/core/src/main/scala/doobie/util/fragment.scala` — `Fragment`, `Elem.Arg`/`Elem.Opt`, `FragmentMonoid`, `execWith`][fragment]
- [`modules/core/src/main/scala/doobie/syntax/string.scala` — the `sql`/`fr`/`fr0` `StringContext` interpolator][string]
- [`modules/core/src/main/scala/doobie/util/{put,get}.scala` + `util/meta/meta.scala` — `Put`/`Get`/`Meta` codecs][put]
- [`modules/core/src/main/scala/doobie/util/{read,write}.scala` — `Read`/`Write` multi-column derivation][read]
- [`modules/core/src/main/scala/doobie/util/query.scala` — `Query`/`Query0`, `.unique`/`.option`/`.nel`, `analysis`][query]
- [`modules/free/src/main/scala/doobie/free/connection.scala` — `ConnectionOp` algebra, `type ConnectionIO = Free[ConnectionOp, *]`, `WeakAsyncConnectionIO`][free]
- [`modules/free/src/main/scala/doobie/free/kleisliinterpreter.scala` — `ConnectionInterpreter: ConnectionOp ~> Kleisli[M, Connection, *]`][interp]
- Shared vocabulary: [concepts & vocabulary][concepts] · [the abstraction ladder][concepts-ladder] · [query construction models][concepts-models] · [effects, transactions & error handling][concepts-effects]

<!-- References -->

[concepts]: ./concepts.md
[concepts-ladder]: ./concepts.md#the-abstraction-ladder
[concepts-models]: ./concepts.md#query-construction-models
[concepts-injection]: ./concepts.md#statements-parameters-and-sql-injection
[concepts-pools]: ./concepts.md#connections-pools-and-sessions
[concepts-types]: ./concepts.md#type-mapping-and-result-decoding
[concepts-effects]: ./concepts.md#effects-transactions-and-error-handling
[concepts-orm]: ./concepts.md#orm-patterns
[concepts-schema]: ./concepts.md#schema-migrations-code-generation
[index]: ./index.md
[repo]: https://github.com/typelevel/doobie
[site]: https://typelevel.org/doobie/
[scaladoc]: https://www.javadoc.io/doc/org.typelevel/doobie-core_2.13
[catseffect]: https://typelevel.org/cats-effect/
[typelevel]: https://typelevel.org/
[readme]: https://github.com/typelevel/doobie/blob/main/README.md
[mdocindex]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/index.md
[intro]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/docs/01-Introduction.md
[param]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/docs/05-Parameterized.md
[frag]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/docs/08-Fragments.md
[checking]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/docs/06-Checking.md
[custom]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/docs/12-Custom-Mappings.md
[errors]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/docs/09-Error-Handling.md
[conn]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/docs/14-Managing-Connections.md
[selecting]: https://github.com/typelevel/doobie/blob/main/modules/docs/src/main/mdoc/docs/04-Selecting.md
[tx]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/transactor.scala
[fragment]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/fragment.scala
[fragments]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/fragments.scala
[string]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/syntax/string.scala
[put]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/put.scala
[get]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/get.scala
[meta]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/meta/meta.scala
[read]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/read.scala
[write]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/write.scala
[query]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/util/query.scala
[readplatform2]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala-2/doobie/util/ReadPlatform.scala
[readplatform3]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala-3/doobie/util/ReadPlatform.scala
[free]: https://github.com/typelevel/doobie/blob/main/modules/free/src/main/scala/doobie/free/connection.scala
[interp]: https://github.com/typelevel/doobie/blob/main/modules/free/src/main/scala/doobie/free/kleisliinterpreter.scala
[cio]: https://github.com/typelevel/doobie/blob/main/modules/core/src/main/scala/doobie/syntax/connectionio.scala
[license]: https://github.com/typelevel/doobie/blob/main/LICENSE
[build]: https://github.com/typelevel/doobie/blob/main/build.sbt

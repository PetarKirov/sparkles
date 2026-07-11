# Quill (Scala 3 ProtoQuill / Scala 2 zio-quill)

A compile-time [Language-Integrated Query][linq] library for Scala in which `quote { }` is a
**macro** that parses an ordinary Scala expression into a reified query [AST][ast], and `run`
translates that AST into SQL — statically when the whole quotation is known, with a runtime
fallback otherwise — leaving the effect type a **pluggable abstract member** that the ZIO
binding fixes to `ZIO[DataSource, SQLException, T]`.

| Field              | Value                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------------- |
| Language           | Scala 3 (ProtoQuill) · Scala 2.11–2.13 (zio-quill); shared `quill-engine`                                           |
| License            | Apache-2.0 (`LICENSE.txt`)                                                                                          |
| Repository         | [zio/zio-protoquill][repo] (Scala 3) · [zio/zio-quill][repoengine] (Scala 2 + engine)                               |
| Documentation      | [zio.dev/zio-quill][docs]                                                                                           |
| Category           | [Functional data mapper][ladder] — compile-time [LINQ][linq] / quoted DSL, no identity map, no unit-of-work         |
| Abstraction level  | [Data mapper (functional)][ladder] — typed composable queries + explicit effects, **below** the full-ORM rung       |
| Query model        | [Quoted DSL → AST][qcm], reified **at compile time** by a macro; SQL emitted statically when the AST is fully known |
| Effect/async model | Pluggable abstract `type Result[T]`; the JDBC-ZIO context sets it to `ZIO[DataSource, SQLException, T]`             |
| Backends           | Postgres, MySQL, H2, SQLite, SQL Server, Oracle (+ Cassandra, OrientDB, Spark in Scala 2)                           |
| First release      | ≈2015 (Quill) · ≈2021 (ProtoQuill / Scala 3) — web-attested                                                         |
| Latest version     | `4.8.6` (latest tag in the pinned checkout); dev HEAD `dc8505cb`, 2026-02-25                                        |

> [!NOTE]
> Quill is the survey's **compile-time quotation** data point on the [functional data
> mapper rung][ladder]. Where `Effect TS` builds a query at _runtime_ from a tagged
> template (a `Statement` that _is_ an `Effect`), Quill builds it at _compile time_ from a
> macro-reified AST and only enters an effect system at `run`, through an abstract
> `Result[T]`. It sits beside `doobie` and `skunk` on the same rung but reaches the AST by
> a completely different road: a [`quote`][qcm] macro rather than a query monad of hand-written
> SQL fragments. See [Query construction models][qcm] and [Effects, transactions & error
> handling][effects] in the concepts page.

---

## Overview

### What it solves

Quill lets you write queries as ordinary, type-checked Scala — `query[Person].filter(p => p.age > 18).map(_.name)` — and have that expression compiled to SQL, rather than assembled as a
string or built through a fluent method chain. Its README states the thesis in one line
([zio-quill `README.md`][readme-engine]):

> _"Quill provides a Quoted Domain Specific Language (QDSL) to express queries in Scala and
> execute them in a target language."_

The Scala 3 port frames itself the same way ([zio-protoquill `README.md`][readme-proto]):
_"ProtoQuill is the Scala 3 version of Quill: Free/Libre Compile-time Language Integrated
Queries for Scala."_ The library grew directly out of the language-integrated-query
research literature — its README credits Philip Wadler's _"A practical theory of
language-integrated query"_ and the QDSL paper _"Everything old is new again: Quoted Domain
Specific Languages"_ as its founding influences ([`README.md`][readme-engine]).

The four properties the README enumerates map one-to-one onto the machinery below
([zio-quill `README.md`][readme-engine]):

> 1. _**Boilerplate-free mapping**: The database schema is mapped using simple case classes._
> 2. _**Quoted DSL**: Queries are defined inside a `quote` block. Quill parses each quoted
>    block of code (quotation) at compile time and translates them to an internal Abstract
>    Syntax Tree (AST)._
> 3. _**Compile-time query generation**: The `ctx.run` call reads the quotation's AST and
>    translates it to the target language at compile time, emitting the query string as a
>    compilation message. As the query string is known at compile time, the runtime overhead
>    is very low and similar to using the database driver directly._
> 4. _**Compile-time query validation**: If configured, the query is verified against the
>    database at compile time and the compilation fails if it is not valid._

### Design philosophy

Quill is the **antithesis of a runtime string-building library**. Three structural
decisions define it.

**A quotation is data, not a string.** `quote { }` never produces SQL text; it produces a
`Quoted[T]` — a triple of a reified `Ast`, its bound values (`lifts`), and any nested runtime
quotations ([`DslModel.scala`][dslmodel]):

```scala
// zio-protoquill: quill-sql/src/main/scala/io/getquill/DslModel.scala
class Quoted[+T](
    val ast: io.getquill.ast.Ast,
    val lifts: List[Planter[_, _, _]],
    val runtimeQuotes: List[QuotationVase]
)
```

**The query "methods" are compile-time-only vocabulary.** `map`, `filter`, `flatMap`,
`join`, `sortBy`, `groupBy` on `Query[T]` exist **only so the parser recognizes them** — every
one of their bodies throws. Calling any of them outside a `quote { }` block is a hard error
([zio-quill `quotation/NonQuotedException.scala`][nonquoted]): _"The query definition must
happen within a `quote` block."_ The `Query[T]` LINQ interface is a _grammar_, not a runtime
collection API.

**The effect system is a hole punched in the context.** The base context declares
`type Result[T]` as an **abstract type member** and nothing more; the SQL string, the row
codecs, and the AST are all resolved without ever naming an effect monad. Only a concrete
backend fills `Result[T]` in — the JDBC-ZIO context sets it to `ZIO[DataSource, SQLException, T]`; a blocking JDBC context would set it to `T` — so the _same_ quotation and the _same_
`run` macro serve every effect model. This is the seam that makes Quill an
effects-first-_compatible_ mapper rather than an effects-first library per se: it commits to
no runtime and lets the binding choose.

---

## Connection, pooling & resource lifetime

Quill draws a firm line between _generating_ SQL (the macro layer, effect-agnostic) and
_running_ it (the context, effect-specific). Pooling itself is **not** Quill's job: the
JDBC-ZIO context wraps an ordinary `javax.sql.DataSource` (typically HikariCP), and Quill
provides `ZLayer` constructors that build one from Typesafe-Config
([`jdbczio/Quill.scala`][quill]):

```scala
// quill-jdbc-zio: .../io/getquill/jdbczio/Quill.scala
object DataSource {
  def fromDataSource(ds: => DataSource): ZLayer[Any, Throwable, DataSource] = ...
  def fromConfig(config: => Config): ZLayer[Any, Throwable, DataSource]     = ...
  def fromPrefix(prefix: String): ZLayer[Any, Throwable, DataSource]        = ...
}

object Connection {
  def acquireScoped: ZLayer[DataSource, SQLException, Connection] =
    ZLayer.scoped {
      for {
        blockingExecutor <- ZIO.blockingExecutor
        ds               <- ZIO.service[DataSource]
        r                <- ZioJdbc.scopedBestEffort(ZIO.attempt(ds.getConnection))
                              .refineToOrDie[SQLException].onExecutor(blockingExecutor)
      } yield r
    }
}
```

The resource lifetime is expressed with ZIO's `Scope`: `Connection.acquireScoped` is a
**scoped** `ZLayer` — the connection is acquired and, via the surrounding scope, guaranteed
released. Each `run` that is _not_ already inside a transaction leases a connection for
exactly the duration of that one statement ([`ZioJdbcContext.scala`][zioctx]):

```scala
private def onConnection[T](qlio: ZIO[Connection, SQLException, T]): ZIO[DataSource, SQLException, T] =
  currentConnection.get.flatMap {
    case Some(connection) => blocking(qlio.provideEnvironment(ZEnvironment(connection)))
    case None             => blocking(qlio.provideLayer(Quill.Connection.acquireScoped))
  }
```

Every JDBC call is wrapped in ZIO's `blocking`, keeping the (unavoidably blocking) JDBC
driver off the async compute pool. A ready-to-use backend is assembled by mixing dialect +
naming into a `Quill.Postgres` and wiring it with `fromNamingStrategy` /
`Quill.DataSource.fromConfig`; the environment a `run` demands is a plain
`ZIO[DataSource, SQLException, T]`, satisfied by that layer. See [Connections, pools &
sessions][conns] for the shared vocabulary.

## Query construction & injection safety

This is Quill's centre of gravity. A query is built in three compile-time moves — **parse**,
**reify**, **lower** — and injection safety falls out of the second automatically.

### The DSL surface

The user-facing entry points are all `inline def`s that immediately splice into a macro
([`Dsl.scala`][dsl], [`context/Context.scala`][context]):

```scala
// zio-protoquill: quill-sql/src/main/scala/io/getquill/Dsl.scala
inline def query[T]: EntityQuery[T] = ${ QueryMacro[T] }

inline def quote[T](inline bodyExpr: T): Quoted[T] = ${ QuoteMacro[T]('bodyExpr) }

inline implicit def unquote[T](inline quoted: Quoted[T]): T = ${ UnquoteMacro[T]('quoted) }

// quill-sql/src/main/scala/io/getquill/context/Context.scala
inline def lift[T](inline runtimeValue: T): T =
  ${ LiftMacro[T, PrepareRow, Session]('runtimeValue) } // Needs PrepareRow to summon encoders
```

`query[T]` names a table; `quote { }` reifies a query expression; `unquote` (an implicit
inline conversion) splices one `Quoted` into another so quotations compose; and `lift`
injects a **runtime value** into a compile-time quotation.

### The `Query[T]` LINQ monad is grammar, not code

The methods you call inside `quote { }` come from `Query[T]` in the shared engine — and their
bodies exist purely to be pattern-matched by the parser ([zio-quill `Model.scala`][model]):

```scala
// zio-quill: quill-engine/src/main/scala/io/getquill/Model.scala
sealed trait Query[+T] extends QAC[Nothing, T] {
  def map[R](f: T => R): Query[R]                              = NonQuotedException()
  def filter(f: T => Boolean): Query[T]                        = NonQuotedException()
  def flatMap[R](f: T => Query[R]): Query[R]                   = NonQuotedException()
  def sortBy[R](f: T => R)(implicit ord: Ord[R]): Query[T]     = NonQuotedException()
  def join[A >: T, B](q: Query[B]): JoinQuery[A, B, (A, B)]    = NonQuotedException()
  def leftJoin[A >: T, B](q: Query[B]): JoinQuery[A, B, (A, Option[B])] = NonQuotedException()
  def groupBy[R](f: T => R): Query[(R, Query[T])]              = NonQuotedException()
  // ...take, drop, union, distinct, nested, size, contains, ...
}
```

The whole family is unified under `QAC[ModificationEntity, OutputEntity]` — a
_Quill-Action-Concept_ whose docstring calls it a _"ZIO-inspired construct [that] makes it
easier to reason about Quoted actions (particularly in Dotty) in a type-full way"_
([`Model.scala`][model]). `Query[T]` is `QAC[Nothing, T]`; `Insert[E]` is
`QAC[E, Nothing]`; `ActionReturning[E, O]` is `QAC[E, O]`. `run` later dispatches on this
shape (below).

### The quotation macro: parse, reify, extract lifts

`QuoteMacro` is the heart. It takes the quoted Scala expression, parses it into a Quill
`Ast`, normalizes, reifies the AST back into an `Expr[Ast]` (so it survives into the compiled
program), and harvests the lifts ([`context/QuoteMacro.scala`][quotemacro]):

```scala
// quill-sql/src/main/scala/io/getquill/context/QuoteMacro.scala
def apply[T](bodyRaw: Expr[T])(using Quotes, Type[T], Type[Parser]): Expr[Quoted[T]] = {
  val body   = bodyRaw.asTerm.underlyingArgument.asExpr
  val parser = SummonParser().assemble
  val rawAst = parser(body)                                  // Scala AST -> Quill Ast
  val (noDynamicsAst, dynamicQuotes) = DynamicsExtractor(rawAst)
  val ast = SimplifyFilterTrue(BetaReduction(noDynamicsAst)) // normalize
  val reifiedAst = Lifter.WithBehavior(serializeQuats, serializeAst)(ast) // Ast -> Expr[Ast]
  val (lifts, pluckedUnquotes) = ExtractLifts(bodyRaw)
  '{ Quoted[T](${ reifiedAst }, ${ Expr.ofList(lifts) }, ${ Expr.ofList(pluckedUnquotes ++ dynamicQuotes) }) }
}
```

`SummonParser().assemble` builds the parser that maps a Scala `select`/`filter`/`map`
into `Entity`/`Filter`/`Map` AST nodes; `Lifter` is the reverse of `Unlifter` — it turns a
runtime `Ast` value into the `Expr[Ast]` tree that is spliced into the enclosing program.
`ExtractLifts` walks the body and pulls out every `Planter` and nested quotation
([`QuoteMacro.scala`][quotemacro]):

```scala
def extractLifts(body: Expr[Any])(using Quotes) =
  PlanterExpr.findUnquotes(body).distinctBy(_.uid).map(_.plant)
```

### Lifts are the injection-safety mechanism

A `lift(value)` does **not** interpolate `value` into SQL. It captures the value in a
`Planter` carrying a `GenericEncoder` and a UID; the AST holds only a `ScalarTag(uid)`
placeholder ([`DslModel.scala`][dslmodel]):

```scala
case class EagerPlanter[T, PrepareRow, Session](
    value: T,
    encoder: GenericEncoder[T, PrepareRow, Session],
    uid: String
) extends Planter[T, PrepareRow, Session]
```

At `run`, each `ScalarTag` in the tokenized query is replaced by the dialect's
**placeholder** (`?` or `$n`, from `Idiom.liftingPlaceholder`), and the planter's encoder
binds the value into the `PreparedStatement`. The value therefore travels out-of-band and can
never be parsed as SQL — [parameter binding][inject] is not opt-in, it is the _only_ way a
runtime value reaches a query. `EagerListPlanter` handles `liftQuery(list)` (an `IN`-list),
and `InjectableEagerPlanter` supports batch actions. There is no string-concatenation code
path in the DSL at all.

### Static vs dynamic translation

When you call `run`, `QueryExecution` first _tries_ to translate the whole thing at compile
time via `StaticTranslationMacro`; if any part is only known at runtime it silently falls
back to a runtime translator ([`context/QueryExecution.scala`][queryexec]):

```scala
Try(StaticTranslationMacro[D, N](quoted, queryElaborationBehavior, topLevelQuat)) match {
  case scala.util.Success(Some(staticState)) =>
    executeStatic[T](staticState, identityConverter, ExtractBehavior.Extract, topLevelQuat) // SQL is known now
  case scala.util.Success(None) =>
    executeDynamic(quoted, identityConverter, ExtractBehavior.Extract, queryElaborationBehavior, topLevelQuat) // defer to runtime
}
```

The decision hinges on whether the AST still contains any `QuotationTag` — i.e. a quotation
that was a plain `val` rather than an `inline def` and so could not be spliced at
compile time ([`context/StaticTranslationMacro.scala`][static]):

```scala
def noRuntimeQuotations(ast: Ast) =
  CollectAst.byType[QuotationTag](ast).isEmpty
// ...
if (noRuntimeQuotations(unliftedAst)) { /* translate now -> Some(StaticState) */ }
else { None } // -> dynamic fallback
```

In the **static** path the SQL string is a compile-time constant and (when compile-time
logging is enabled) is emitted as a diagnostic via `report.info` — this is the README's
_"emitting the query string as a compilation message"_ ([`StaticTranslationMacro.scala`][static]):

```scala
if (ProtoMessages.useStdOut) println(msg + pos)
else report.info(msg)
```

In the **dynamic** path (`RunDynamicExecution`) the same `Idiom.translate` runs at runtime.
Correctness is identical; only the timing and the runtime cost differ (a dynamic query
re-tokenizes on every call). The migration note in the ProtoQuill README is the practical
consequence: a Scala 2 query ported verbatim _"will become Dynamic. Change them to
`inline def` expressions and they should once-again be compile-time"_
([zio-protoquill `README.md`][readme-proto]).

### The escape hatch

Raw SQL enters through the `sql"..."` interpolator (formerly `infix"..."`), which the parser
turns into an `Infix` AST node ([`DslModel.scala`][dslmodel], [`parser/Parser.scala`][parser]):

```scala
// quill-sql/src/main/scala/io/getquill/DslModel.scala
implicit class SqlInfixInterpolator(val sc: StringContext) {
  def sql(args: Any*): InfixValue = NonQuotedException()
}
```

Inside `sql"..."`, a `${value}` argument is parsed as a **bound param** (safe), while a
`#${value}` argument is spliced **literally** into the SQL text (a deliberate injection
surface, used for e.g. dynamic table names) — the `#` case is routed to `PrepareDynamicInfix`
in the parser ([`Parser.scala`][parser]). As with every escape hatch in the survey, the
`sql"..."` node bypasses the type-checked path, so the ergonomics of the library are partly
about how rarely you need it.

## Schema, migrations & code generation

Quill is **schema-agnostic**: the schema _is_ your Scala case classes, and Quill ships **no
migration runner and no DDL generation** — a real finding for this survey. There is no
`CREATE TABLE`, no versioned-migration bookkeeping table, and no `up`/`down` scripts anywhere
in `quill-sql`. Owning the database's shape is left to an external tool (Flyway, Liquibase);
Quill only reads case classes and maps their names.

Mapping is by convention, tunable two ways. A `NamingStrategy` rewrites identifiers
globally — `Person` ↦ `person`, `firstName` ↦ `first_name` ([zio-quill
`NamingStrategy.scala`][naming]):

```scala
// zio-quill: quill-engine/src/main/scala/io/getquill/NamingStrategy.scala
trait NamingStrategy {
  def table(s: String): String  = default(s)
  def column(s: String): String = default(s)
  def default(s: String): String
}
object SnakeCase extends SnakeCase   // fooBar -> foo_bar
object Literal   extends Literal     // identity
object Escape    extends Escape      // "quoted"
```

Strategies compose (`CompositeNamingStrategy`, `NamingStrategy(SnakeCase, UpperCase)`), and
per-entity overrides come from `querySchema` / `schemaMeta` when convention is not enough
([`DslModel.scala`][dslmodel], [`Dsl.scala`][dsl]):

```scala
def querySchema[T](entity: String, columns: (T => (Any, String))*): EntityQuery[T] = NonQuotedException()

inline def schemaMeta[T](inline entity: String, inline columns: (T => (Any, String))*): SchemaMeta[T] =
  ${ SchemaMetaMacro[T]('entity, 'columns) }
```

The stance is closest to **schema-last / code-agnostic** in the [taxonomy][schema]: neither
code-first (no migrations emitted) nor db-first (the core does no introspection or codegen).
(Scala-2 Quill has a separate `quill-codegen` that scaffolds case classes from a live JDBC
schema, but that is a side tool, not part of the query engine.) See [Schema, migrations &
code generation][schema].

## Type mapping & result decoding

Encoders and decoders are typeclasses, abstract in the context and made concrete per backend.
The context declares the shapes and constrains them to the generic supertypes
([`generic/EncodingDsl.scala`][encdsl]):

```scala
// quill-sql/src/main/scala/io/getquill/generic/EncodingDsl.scala
type Encoder[T] <: GenericEncoder[T, PrepareRow, Session]
type Decoder[T] <: GenericDecoder[ResultRow, Session, T, DecodingType.Specific]
type NullChecker <: GenericNullChecker[ResultRow, Session]
```

Both are plain functions over the driver's row types ([`generic/GenericEncoder.scala`][encoder],
[`generic/GenericDecoder.scala`][decoder]):

```scala
trait GenericEncoder[T, PrepareRow, Session] extends ((Int, T, PrepareRow, Session) => PrepareRow)
trait GenericDecoder[ResultRow, Session, T, +DecType <: DecodingType] extends ((Int, ResultRow, Session) => T)
```

An encoder takes `(index, value, preparedStatement, session)` and returns the mutated
statement; a decoder takes `(index, resultSet, session)` and returns the value. The JDBC
context supplies the leaf instances for the SQL primitives ([`context/sql/SqlContext.scala`][sqlctx]):
`stringEncoder`/`stringDecoder`, `intEncoder`/`intDecoder`, `booleanEncoder`,
`bigDecimalEncoder`, `byteArrayEncoder`, `dateEncoder`/`localDateEncoder`, `uuidEncoder`, and
`optionEncoder`/`optionDecoder` for nullability. Case-class rows are handled by **generic
derivation** (Scala 3 `Mirror`-based): `GenericDecoder.summon[T, ResultRow, Session]` derives
a row decoder for any product type, driven by the `DecodingType.Generic` vs
`DecodingType.Specific` distinction that separates a derived decoder from a hand-written leaf
one. `AnyVal` value classes get automatic `MappedEncoding`-based codecs
([`EncodingDsl.scala`][encdsl]). Nullability is reflected as `Option[T]` and checked with a
`GenericNullChecker` before decoding. See [Type mapping & result decoding][typemap].

## Effect model, transactions & error handling

This is the dimension the survey weighs most, and Quill's answer is unusual: **the effect
type is an unfilled hole in the abstract context.** `ProtoContextSecundus` — the base every
backend extends — declares the associated types and the `execute*` operations _entirely
abstractly_ ([`context/ProtoContextSecundus.scala`][proto]):

```scala
// quill-sql/src/main/scala/io/getquill/context/ProtoContextSecundus.scala
trait ProtoContextSecundus[+Dialect <: io.getquill.idiom.Idiom, +Naming <: NamingStrategy] extends RowContext {
  type PrepareRow
  type ResultRow
  type Result[T]          // <- the effect wrapper, unspecified here
  type RunQueryResult[T]
  type RunActionResult
  type Session
  type Runner

  def executeQuery[T](sql: String, prepare: Prepare, extractor: Extractor[T])(executionInfo: ExecutionInfo, rn: Runner): Result[RunQueryResult[T]]
  def executeAction(sql: String, prepare: Prepare)(executionInfo: ExecutionInfo, rn: Runner): Result[RunActionResult]
  def executeActionReturning[T](sql: String, prepare: Prepare, extractor: Extractor[T], returningBehavior: ReturnAction)(executionInfo: ExecutionInfo, rn: Runner): Result[RunActionReturningResult[T]]
  // executeQuerySingle, executeBatchAction, executeBatchActionReturning, ...
}
```

`Result[T]` names no monad. `run` (a macro in `Context.InternalApi`) lowers a `Quoted` into a
call to one of these `execute*` methods and hands back `Result[RunQueryResult[T]]` — whatever
that turns out to be. The ZIO backend closes the loop by assigning every abstract member a
concrete type ([`context/qzio/ZioJdbcContext.scala`][zioctx]):

```scala
// quill-jdbc-zio: .../io/getquill/context/qzio/ZioJdbcContext.scala
override type Result[T]       = ZIO[Environment, Error, T]
override type Error           = SQLException
override type Environment     = DataSource
override type PrepareRow      = PreparedStatement
override type ResultRow       = ResultSet
override type Session         = Connection
override type RunQueryResult[T]  = List[T]
override type RunActionResult    = Long
```

So `ctx.run(query[Person])` has the fully-concrete type `ZIO[DataSource, SQLException, List[Person]]` — the required environment (`DataSource`) and the possible failure
(`SQLException`) are both in the type. The typed-error channel is therefore **narrow and
exception-derived**: unlike `Effect TS`'s structured `SqlError` reason-union, Quill's ZIO
context refines everything to a single `SQLException` in the ZIO error position (a driver
`SQLException` widened from JDBC; non-SQL faults are `refineToOrDie`d). The `run` overloads
are resolved by `@targetName` on the quoted shape ([`ZioJdbcContext.scala`][zioctx]):

```scala
@targetName("runQueryDefault")
inline def run[T](inline quoted: Quoted[Query[T]]): ZIO[DataSource, SQLException, List[T]] = InternalApi.runQueryDefault(quoted)
@targetName("runAction")
inline def run[E](inline quoted: Quoted[Action[E]]): ZIO[DataSource, SQLException, Long] = InternalApi.runAction(quoted)
@targetName("runActionReturning")
inline def run[E, T](inline quoted: Quoted[ActionReturning[E, T]]): ZIO[DataSource, SQLException, T] = InternalApi.runActionReturning[E, T](quoted)
```

### Transactions: a `FiberRef` and scoped acquire/release

`transaction` composes at the effect level: it takes a `ZIO[R, Throwable, A]` and returns
one, so anything runnable is transactional. The connection for the transaction is threaded
through a **`FiberRef[Option[Connection]]`**, and the begin/commit/rollback dance is expressed
with ZIO's structured resource operators ([`ZioJdbcContext.scala`][zioctx]):

```scala
def transaction[R <: DataSource, A](op: ZIO[R, Throwable, A]): ZIO[R, Throwable, A] = {
  blocking(currentConnection.get.flatMap {
    case Some(connection) => op   // already in a transaction on this fiber -> just run
    case None =>
      val connection = for {
        env            <- ZIO.service[DataSource]
        connection     <- scopedBestEffort(attemptBlocking(env.getConnection))
        prevAutoCommit <- attemptBlocking(connection.getAutoCommit)
        _ <- ZIO.acquireRelease(attemptBlocking(connection.setAutoCommit(false))) { _ =>
               attemptBlocking(connection.setAutoCommit(prevAutoCommit)).orDie }
        _ <- ZIO.acquireRelease(currentConnection.set(Some(connection))) { _ =>
               currentConnection.set(None) }
        _ <- ZIO.addFinalizerExit {
               case Success(_)     => blocking(ZIO.succeed(connection.commit()))
               case Failure(cause) => blocking(ZIO.succeed(connection.rollback())) }
      } yield ()
      ZIO.scoped(connection *> op)
  })
}
```

Two design points stand out. First, **commit-vs-rollback is decided by ZIO's `Exit`**: the
`addFinalizerExit` finalizer commits on `Success` and rolls back on `Failure` — an error _or_
an interruption/defect rolls the transaction back, because the finalizer sees the exit, not a
thrown exception. Second, **nesting is idempotent, not savepoint-based**: the `Some(connection)` branch means an inner `transaction` on the same fiber simply reuses the outer connection and
returns `op` unchanged — so `transaction(transaction(a *> b) *> c)` opens exactly one JDBC
transaction. (Unlike the effect libraries that emit inner `SAVEPOINT`s, a nested Quill
transaction is flattened into the outer one — a rollback rolls back everything.) The
`onConnection` reader (above) makes each `execute*` pick up the fiber's transaction connection
when one is set, and lease a fresh scoped one otherwise. The blocking JDBC contexts express
the identical logic synchronously with `Result[T] = T` and a `try/catch` around
`commit`/`rollback`.

### Dialect & naming are separate, pluggable axes

The SQL text itself is produced by an `Idiom` (the survey's [dialect][dialect]), orthogonal
to the naming strategy ([zio-quill `idiom/Idiom.scala`][idiom]):

```scala
// zio-quill: quill-engine/src/main/scala/io/getquill/idiom/Idiom.scala
trait Idiom extends IdiomReturningCapability {
  def liftingPlaceholder(index: Int): String
  def translate(ast: Ast, topLevelQuat: Quat, executionType: ExecutionType, transpileConfig: IdiomContext)(implicit
    naming: NamingStrategy
  ): (Ast, Statement, ExecutionType)
  def emptySetContainsToken(field: Token): Token
  // ...
}
```

`liftingPlaceholder` is why `PostgresDialect` emits `$1, $2` while `MySQLDialect` emits `?`;
`translate` is the AST→SQL renderer, taking the `NamingStrategy` as an implicit so the two
concerns stay independent. A context is parameterized on both — `Context[+Dialect <: Idiom, +Naming <: NamingStrategy]` — which is how `Quill.Postgres[SnakeCase]` selects dialect and
identifier-casing at the type level.

## Ecosystem & maturity

Quill is a mature, production-grade library under the **Apache-2.0** license
(`LICENSE.txt` in both repos). It is now a **ZIO organization** project (the `zio/zio-quill`
and `zio/zio-protoquill` GitHub orgs), and the Scala 2 README badges it _"Production Ready"_
([zio-quill `README.md`][readme-engine]). The codebase is two-layered: `quill-engine`
(Scala 2, cross-published) holds the AST, normalization, `Idiom`s, and `NamingStrategy`; the
Scala 3 `zio-protoquill` reimplements the front-end (parsing, quotation, execution) on Scala
3 macros while reusing that engine.

Backends span the JDBC SQL dialects — Postgres, MySQL, H2, SQLite, SQL Server, Oracle —
plus Cassandra (CQL, v4 drivers), with OrientDB and Spark historically in Scala 2. Each has
both a **blocking JDBC** context and effect-typed contexts: **ZIO** (`quill-jdbc-zio`),
**Cats-Effect / Monix** (`quill-jdbc-monix`), and a **doobie** integration. The pinned
checkout carries release tags through `v4.8.6`; the latest published line is `quill-*_3` on
Maven Central (per the ProtoQuill README). Notable is its lineage into the wider Scala data
ecosystem — the same quotation model underlies the `quill-doobie` bridge, letting a Quill
`Quoted` run inside a `doobie` `ConnectionIO`.

## Strengths

- **SQL is known at compile time.** The generated query is a compile-time constant in the
  common case; it can be logged as a compiler message and carries near-zero build overhead at
  runtime (_"similar to using the database driver directly"_).
- **Injection-proof by construction.** Every runtime value is a `lift` → `Planter` → bound
  parameter; there is no string-concatenation path in the DSL. The only injection surface is
  the explicit `#${...}` splice inside `sql"..."`.
- **Effect-agnostic core.** `Result[T]` is an abstract type member, so one quotation and one
  `run` macro serve ZIO, Cats-Effect, Monix, and blocking JDBC without change — an unusually
  clean separation of _query_ from _effect_.
- **Idiomatic Scala queries.** Queries are ordinary `map`/`filter`/`flatMap`/`join`
  expressions with full IDE and type support — no separate query DSL to learn, and joins are
  explicit (side-stepping the N+1 trap).
- **Dialect and naming are independent, first-class type parameters** (`Idiom` +
  `NamingStrategy`), making retargeting and identifier-casing declarative.
- **ZIO-native resource story.** Transactions and connections use `Scope`, `acquireRelease`,
  and `addFinalizerExit`, so a leaked connection or an un-rolled-back transaction is
  structurally prevented, and interruption is handled correctly.

## Weaknesses

- **Silent dynamic fallback.** A quotation that isn't an `inline def` (or that the macro
  can't fully resolve) degrades to a runtime translation with no error — you lose compile-time
  SQL and pay per-call tokenization, often without noticing. This is the single sharpest
  Scala-2→Scala-3 migration edge.
- **Heavy macro machinery.** The parse→reify→lower pipeline is intricate; when the parser
  can't handle an expression the errors are macro-level and hard to read, and compile times
  grow with quotation complexity.
- **Narrow, exception-shaped error channel.** The ZIO context refines everything to a single
  `SQLException`; there is no structured reason-union (e.g. retryable vs constraint-violation)
  like `Effect TS`'s `SqlError`. Distinguishing failure kinds means inspecting the
  `SQLException` yourself.
- **Nested transactions flatten, not savepoint.** An inner `transaction` reuses the outer
  connection; there is no per-block `SAVEPOINT`, so partial rollback of an inner block is not
  available out of the box.
- **No schema tooling.** No migrations, no DDL generation, no first-party db-first codegen in
  the query engine — you bring your own migration tool and keep case classes in sync by hand.
- **Expressiveness is bounded by the parser.** Only what the quotation parser recognizes can
  be static SQL; constructs outside its vocabulary must use `sql"..."` or go dynamic.

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                                       | Trade-off                                                                                                                  |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `quote { }` is a **macro** producing a reified `Quoted` (AST + lifts)    | SQL known at compile time; loggable; near-zero runtime cost; type-checked as normal Scala       | Intricate macro layer; opaque errors; compile-time cost; expressiveness bounded by what the parser recognizes              |
| `Query[T]` LINQ methods **throw** (`NonQuotedException`)                 | The interface is grammar for the parser, not a runtime collection API                           | Calling them outside `quote { }` is a runtime error, not a compile error; surprising to newcomers                          |
| Runtime values enter only via `lift` → `Planter` → bound parameter       | Injection is structurally impossible; encoders are typeclass-driven                             | Everything dynamic must be a `lift`; literal SQL needs the explicit `#${...}` escape in `sql"..."`                         |
| **Static translation with a silent dynamic fallback**                    | Best-effort compile-time SQL without forcing every query to be fully static                     | Falling to dynamic is invisible; you lose compile-time SQL and re-tokenize per call — the main migration foot-gun          |
| `type Result[T]` is an **abstract member** of the context                | One quotation + one `run` macro serve ZIO / Cats-Effect / Monix / blocking, effect-agnostically | The core commits to no effect semantics; typed-error richness is whatever the binding provides (ZIO → bare `SQLException`) |
| Transaction connection via a **`FiberRef`** + `Scope`/`addFinalizerExit` | Structured acquire/release; commit/rollback driven by ZIO `Exit`; interruption-safe             | Nested transactions flatten onto one connection (no `SAVEPOINT`); ties the model to a fiber-local                          |
| `Idiom` (dialect) and `NamingStrategy` are **separate type parameters**  | Retargeting dialects and identifier-casing are independent, declarative axes                    | A backend must supply both; more type parameters on every context signature                                                |
| **No schema/migration tooling** in the engine                            | Keeps Quill a query mapper; schema ownership is someone else's job                              | You need an external migrator (Flyway/Liquibase) and must keep case classes and DB in sync manually                        |

---

## Sources

- [zio/zio-protoquill — Scala 3 front-end (quotation, execution, JDBC-ZIO)][repo]
- [zio/zio-quill — Scala 2 + shared `quill-engine` (AST, idioms, naming)][repoengine]
- [zio.dev/zio-quill — official documentation][docs]
- [`quill-sql/.../io/getquill/Dsl.scala` — `quote`/`unquote`/`query` inline defs][dsl]
- [`quill-sql/.../io/getquill/DslModel.scala` — `Quoted[T]`, `Planter` variants, `sql"..."` interpolator][dslmodel]
- [`quill-sql/.../io/getquill/context/QuoteMacro.scala` — parse → reify → `ExtractLifts`][quotemacro]
- [`quill-sql/.../io/getquill/context/Context.scala` — `lift`, the `run` macros, `InternalApi`][context]
- [`quill-sql/.../io/getquill/context/ProtoContextSecundus.scala` — abstract `Result[T]` + `execute*`][proto]
- [`quill-sql/.../io/getquill/context/QueryExecution.scala` — static-vs-dynamic dispatch][queryexec]
- [`quill-sql/.../io/getquill/context/StaticTranslationMacro.scala` — compile-time translation + `report.info`][static]
- [`quill-sql/.../io/getquill/generic/{EncodingDsl,GenericEncoder,GenericDecoder}.scala` — codec typeclasses][encdsl]
- [`quill-jdbc-zio/.../io/getquill/context/qzio/ZioJdbcContext.scala` — `Result[T] = ZIO[DataSource, SQLException, T]`, `transaction`][zioctx]
- [`quill-jdbc-zio/.../io/getquill/jdbczio/Quill.scala` — `ZLayer` wiring (`Quill.Postgres`, `DataSource.fromConfig`)][quill]
- [zio-quill `quill-engine/.../io/getquill/Model.scala` — the `Query[T]` LINQ monad (`NonQuotedException`)][model]
- [zio-quill `quill-engine/.../io/getquill/idiom/Idiom.scala` — dialect `translate` + `liftingPlaceholder`][idiom]
- [zio-quill `quill-engine/.../io/getquill/NamingStrategy.scala` — `SnakeCase`/`Literal`/`Escape`, composites][naming]
- Concepts: [the abstraction ladder][ladder] · [query construction models][qcm] · [statements & injection][inject] · [effects & transactions][effects] · [type mapping][typemap] · [dialects & naming][dialect]

<!-- References -->

[repo]: https://github.com/zio/zio-protoquill
[repoengine]: https://github.com/zio/zio-quill
[docs]: https://zio.dev/zio-quill/
[readme-proto]: https://github.com/zio/zio-protoquill/blob/master/README.md
[readme-engine]: https://github.com/zio/zio-quill/blob/master/README.md
[dsl]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/Dsl.scala
[dslmodel]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/DslModel.scala
[quotemacro]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/context/QuoteMacro.scala
[context]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/context/Context.scala
[proto]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/context/ProtoContextSecundus.scala
[queryexec]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/context/QueryExecution.scala
[static]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/context/StaticTranslationMacro.scala
[parser]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/parser/Parser.scala
[encdsl]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/generic/EncodingDsl.scala
[encoder]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/generic/GenericEncoder.scala
[decoder]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/generic/GenericDecoder.scala
[sqlctx]: https://github.com/zio/zio-protoquill/blob/master/quill-sql/src/main/scala/io/getquill/context/sql/SqlContext.scala
[zioctx]: https://github.com/zio/zio-protoquill/blob/master/quill-jdbc-zio/src/main/scala/io/getquill/context/qzio/ZioJdbcContext.scala
[quill]: https://github.com/zio/zio-protoquill/blob/master/quill-jdbc-zio/src/main/scala/io/getquill/jdbczio/Quill.scala
[model]: https://github.com/zio/zio-quill/blob/master/quill-engine/src/main/scala/io/getquill/Model.scala
[idiom]: https://github.com/zio/zio-quill/blob/master/quill-engine/src/main/scala/io/getquill/idiom/Idiom.scala
[naming]: https://github.com/zio/zio-quill/blob/master/quill-engine/src/main/scala/io/getquill/NamingStrategy.scala
[nonquoted]: https://github.com/zio/zio-quill/blob/master/quill-engine/src/main/scala/io/getquill/quotation/NonQuotedException.scala
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[effects]: ./concepts.md#effects-transactions-and-error-handling
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[dialect]: ./concepts.md#dialects-idioms-and-naming-strategies
[schema]: ./concepts.md#schema-migrations-code-generation
[conns]: ./concepts.md#connections-pools-and-sessions
[linq]: ./concepts.md#query-construction-models
[ast]: ./concepts.md#query-construction-models

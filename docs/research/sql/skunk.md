# skunk (Scala)

A purely functional, non-blocking Postgres data mapper that **does not use JDBC** — it speaks the Postgres wire protocol directly on `cats-effect` + `fs2` + `scodec`, builds typed statements from an `sql"…"` interpolator whose holes are supplied by composable `Codec`s (not string values), and returns results as effect values and `fs2` streams.

| Field              | Value                                                                                                                               |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Scala (2.13 and 3; cross-built for JVM, Node.js/Scala.js, and Native)                                                               |
| License            | MIT (`Copyright (c) 2018-2024 by Rob Norris and Contributors`)                                                                      |
| Repository         | [tpolecat/skunk][repo]                                                                                                              |
| Documentation      | [typelevel.org/skunk microsite][docs] · module docstrings and Scaladoc under `modules/core/`                                        |
| Category           | [Functional data mapper][concepts-ladder] (typed, no ORM) — no identity map, no unit of work, no change tracking                    |
| Abstraction level  | [Data mapper (functional)][concepts-ladder] rung — typed, composable statements with explicit effects                               |
| Query model        | [Typed statement][concepts-qcm]: a compile-time `sql"…"` macro weaves an `Encoder`-driven `Fragment` into a `Query`/`Command`       |
| Effect/async model | [Effect value][concepts-eth] — tagless-final `F[_]` (`cats-effect`) + `fs2.Stream`; a statement's result is `F[…]`, run at the edge |
| Backends           | PostgreSQL **only**, by design (no JDBC, no other back end)                                                                         |
| First release      | ≈ 2019-2020 (Rob Norris / `tpolecat`; presented at Scala Days 2019) — web-attested                                                  |
| Latest version     | `1.x` line (`org.tpolecat` `skunk-core`, base version `1.1`) — web-attested                                                         |

> [!NOTE]
> skunk is this survey's **wire-native functional data mapper**. It sits on the
> [functional data-mapper rung][concepts-ladder] alongside `doobie`, `Quill`,
> `Ecto`, and the Effect TS `sql` layer: typed, composable queries with explicit
> effects, and deliberately **no** ORM machinery. Its distinguishing move against
> the whole JVM field is that it bypasses JDBC entirely and implements the Postgres
> Frontend/Backend protocol itself, which is what lets it stream with `fs2`, expose
> `LISTEN`/`NOTIFY` as a `Channel`, and produce positioned, source-annotated error
> reports. Terms such as [prepared statement][concepts-inj],
> [scoped `Resource`][concepts-cps], [savepoint][concepts-eth], and
> [codec][concepts-tmap] are defined in [`concepts.md`][concepts].

---

## Overview

### What it solves

skunk is the database layer for programs written in the Typelevel (`cats-effect` /
`fs2`) style. It answers _"how does a purely functional Scala program talk to Postgres
without inheriting JDBC's blocking, exception-throwing, `null`-returning API — and
without giving up type-checked parameters, streaming, or scoped resource lifetimes?"_
The library's own one-line summary ([`package.scala`][pkg]):

> _"**Skunk** is a functional data access layer for Postgres."_

The microsite overview enumerates the pillars ([`index.md`][docindex]):

> _"Skunk is powered by cats, cats-effect, scodec, and fs2."_ … _"Skunk is purely
> functional, non-blocking, and provides a tagless-final API."_ … _"Skunk gives very
> good error messages."_

Those four dependencies are load-bearing rather than incidental: `scodec` encodes and
decodes the binary wire messages, `fs2` provides the socket I/O and the streaming
result API, and `cats-effect` provides the abstract effect `F[_]`, the `Resource`
lifetime model, and the concurrency primitives. There is **no JDBC driver** underneath.

### Design philosophy

skunk's design principles are stated verbatim in the package object, and the first is
the one that defines the whole library ([`package.scala`][pkg]):

> _"Skunk doesn't use JDBC. It speaks the Postgres wire protocol. It will not work
> with any other database back end."_

That is a hard architectural commitment, not a configuration option — it is the reason
"PostgreSQL only" appears in the metadata table above. The remaining principles follow
from it ([`package.scala`][pkg]):

> _"Skunk is asynchronous all the way down, via cats-effect, fs2, and ultimately nio.
> The high-level network layers (`Protocol` and `Session`) are safe to use
> concurrently."_

**Codecs are explicit, not derived.** Where an ORM or a macro-mapper hides the
value↔column mapping behind implicit derivation, skunk makes it a first-class value you
name and compose ([`package.scala`][pkg]):

> _"Serialization to and from schema types is not typeclass-based, so there are no
> implicit derivations. Codecs are explicit, like parser combinators."_

The comparison to parser combinators is exact: a `Codec[A]` is a small value you build
up from primitives (`varchar`, `int4`) with combinators (`~`, `.opt`, `.imap`), the same
way a parser combinator library builds a parser — the connective tissue this survey's
`doobie` and Effect TS pages share, expressed here as plain composable values rather than
typeclass instances.

**Resource-scoped, at the cost of discipline.** The last principle is candid about the
trade-off skunk accepts ([`package.scala`][pkg]):

> _"Skunk uses `Resource` for lifetime-managed objects, which means it takes some
> discipline to avoid leaks, especially when working concurrently."_

---

## Connection, pooling & resource lifetime

A live connection is a `Session[F]`, and it is obtained as a `cats-effect` `Resource` —
never constructed and closed by hand. The `Session` trait states the lifetime contract
in its own docstring ([`Session.scala`][session]):

> _"Represents a live connection to a Postgres database. Operations provided here are
> safe to use concurrently. Note that this is a lifetime-managed resource and as such is
> invalid outside the scope of its owning `Resource`, as are any streams constructed
> here."_

Construction goes through a fluent `Session.Builder[F]`, terminating in one of two
resources ([`Session.scala`][session]):

```scala
// skunk: modules/core/shared/src/main/scala/Session.scala — Builder
def single(implicit T: Tracer[F]): Resource[F, Session[F]] =
  pooled(1).flatten

def pooled(max: Int)(implicit T: Tracer[F]): Resource[F, Resource[F, Session[F]]] =
  pooledExplicitTracer(max).map(_.apply(T))
```

`single` is _"logically unpooled"_ — _"In reality each session is managed by its own
single-session pool"_ — while `pooled(max)` yields a **nested** `Resource`: the outer
resource allocates the pool once at startup, and the inner `Resource[F, Session[F]]` is
leased per unit of work. A typical program `use`s the outer resource once and threads the
inner one through ([`Session.scala`][session]):

```scala
// skunk: Session.Builder usage
val pool: Resource[IO, Resource[IO, Session[IO]]] =
  Session.Builder[IO]
    .withUserAndPassword("jimmy", "banana")
    .withDatabase("world")
    .pooled(10)
```

The pool is more than a connection cache. It carries a pool-wide **describe cache** and a
**parse cache** so that a statement checked or parsed once need not be re-checked on
later leases ([`Session.scala`][session]): _"The pool maintains a cache of queries and
commands that have been checked against the schema, eliminating the need to check them
more than once."_ On release a `Recycler` resets the session — `Recyclers.full` runs
`closeEvictedPreparedStatements <+> ensureIdle <+> unlistenAll <+> resetAll` (`UNLISTEN *`

- `RESET ALL`) so a returned session carries no leftover transaction, listeners, or
  session variables. Because acquisition and release are tied to a [`Resource`][concepts-cps]
  scope, a leaked connection is a discipline error the effect system localizes, not a silent
  runtime leak — though, as the design note above concedes, the discipline is real.

## Query construction & injection safety

This is the heart of skunk, and its defining subtlety: the `sql"…"` interpolator **looks
like** string interpolation but is nothing of the sort — interpolated holes are `Encoder`s
and `Fragment`s, never runtime values, and the actual argument values travel out-of-band
on the extended-query protocol. The Fragments reference states the invariant in bold
([`Fragments.md`][fragdoc]):

> _"The resulting statement is prepared, and arguments (encoded) are passed separately as
> part of the extended query protocol. **Skunk never interpolates statement arguments.**"_

**The `Fragment`.** The precursor to every statement is a `Fragment[A]` — _"A composable,
embeddable hunk of SQL and typed parameters (common precursor to `Command` and `Query`)"_
([`Fragment.scala`][fragment]). It carries the SQL text as an alternating list of literal
chunks and placeholder-generating states, plus an `Encoder[A]` for the parameters:

```scala
// skunk: modules/core/shared/src/main/scala/Fragment.scala
final case class Fragment[A](
  parts:   List[Either[String, State[Int, String]]],
  encoder: Encoder[A],
  origin:  Origin
) extends (A => AppliedFragment) {
  def query[B](decoder: Decoder[B]): Query[A, B] = Query(sql, origin, encoder, decoder, isDynamic = false)
  def command: Command[A]                         = Command(sql, origin, encoder)
}
```

You turn a `Fragment[A]` into a `Query[A, B]` by supplying a `Decoder[B]` (`.query(dec)`),
or into a `Command[A]` (`.command`). A parameterless fragment has type `Fragment[Void]`.

**The interpolator is a typed macro.** In Scala 3 the `sql` interpolator is a
`transparent inline` macro whose body walks the interpolated arguments and classifies
each one at **compile time** ([`StringContextOps.scala`][sco]):

```scala
// skunk: modules/core/shared/src/main/scala-3/syntax/StringContextOps.scala — sqlImpl (abridged)
arg match {
  // The interpolated thing is an Encoder → emit a placeholder, accumulate the encoder.
  case '{ $e: Encoder[t] } =>
    val newParts    = '{Str(${Expr(str)})} :: '{Par($e.sql)} :: parts
    val newEncoders = '{ $e : Encoder[t] } :: es
  // A nested parameterless Fragment[Void] → splice its parts, no new encoder.
  case '{ $f: Fragment[Void] } =>
    '{Str(${Expr(str)})} :: '{Emb($f.parts)} :: parts
  // A nested parameterized Fragment[a] → splice its parts and accumulate its encoder.
  case '{ $f: Fragment[a] } =>
    '{ $f.encoder : Encoder[a] } :: es
  // Anything else is a compile error.
  case '{ $a: t } =>
    report.error(s"Found ${Type.show[t]}, expected String, Encoder, or Fragment.", a)
}
```

So `sql"… WHERE name LIKE $varchar"` does not interpolate a `String`; it interpolates
the `Codec[String]` named `varchar` (which is an `Encoder[String]`), emits a `$1`
placeholder in its place, and threads the accumulated encoder into the `Fragment`'s type.
Interpolate two encoders and the input type becomes a pair; the macro renumbers
placeholders and unions the encoders. A `${…}` hole that is neither an `Encoder` nor a
`Fragment` is a **compile-time type error**, not a runtime string splice. This is the
[parameter-binding safety model][concepts-inj] enforced by the type system: the value slot
and the SQL text are structurally different things.

**From fragment to statement.** The reference example shows the full arc — interpolator →
`Fragment` → `Query` with a decoder ([`Query.md`][querydoc]):

```scala
// skunk: modules/docs/.../tutorial/Query.md
val e: Query[String, Country] =
  sql"""
    SELECT name, population
    FROM   country
    WHERE  name LIKE $varchar
  """.query(country)
```

The `Query[A, B]` type carries **both** halves of the mapping: `A` is the input encoded by
`encoder`, `B` is the output decoded by `decoder`. Its docstring restates the discipline
skunk relies on ([`Query.scala`][query]):

> _"We assume that `sql` has the same number of placeholders of the form `$1`, `$2`, etc.,
> as the number of slots encoded by `encoder`, that `sql` selects the same number of
> columns are the number of slots decoded by `decoder`, and that the parameter and column
> types specified by `encoder` and `decoder` are consistent with the schema. The `check`
> methods on `Session` provide a means to verify this assumption."_

**Fragment composition.** Fragments form a contravariant semigroupal functor: `f1 *: f2`
(or `~`) appends the SQL and pairs the input types, and a fragment can be interpolated
inside another (`sql"… WHERE $f7 AND x = $int2"`), with placeholders renumbered
automatically ([`Fragments.md`][fragdoc]). For queries assembled at runtime, an
`AppliedFragment` binds a fragment to its argument as an existential pair and forms a
`Monoid`, so optional `WHERE` clauses can be folded together
(`conds.foldSmash(void" WHERE ", void" AND ", AppliedFragment.empty)`) — skunk's answer to
dynamic query building without abandoning binding.

**The escape hatch.** The one way to splice literal text is the `#$` interpolation, used
for positions where a parameter is illegal (a table name, say). The reference marks it as
exactly the risk the rest of the design removes ([`Fragments.md`][fragdoc]):

> _"Interpolating a literal string into a `Fragment` is a SQL injection risk. Never
> interpolate values that have been supplied by the user."_

`#$table` inserts `table` verbatim into the SQL; `$table` would be a compile error (a
`String` is not an `Encoder`). The asymmetry is deliberate: the safe path is the easy path,
and the unsafe path is visibly ugly and documented as dangerous — the same
"rawness-is-opt-in" stance as Effect TS's `sql.unsafe`.

## Schema, migrations & code generation

skunk has **no migration runner and no code generation** — an intentional absence that is
itself a finding. There is no `Beam`/`EF Core`-style code-first schema, no
`.prisma`/`Slick`-style schema declaration, and no `jOOQ`/`sqlc`-style catalog
introspection that emits column constants or row decoders. You write the DDL yourself
(as ordinary `Command`s) and you write the codecs yourself. The library is a **statement
mapper**, not a schema tool; where higher rungs own or generate the schema, skunk stops
below that line, exactly like `doobie`.

What it does offer instead is **runtime verification against the live schema**. When a
statement is prepared, skunk's `Describe` protocol asks Postgres for the parameter and
column types and checks them against the statement's `Encoder`/`Decoder`, caching the
result pool-wide (see the describe cache above). The `TypingStrategy` chooses how far this
goes — `BuiltinsOnly` (the default) knows the built-in OIDs statically, while `SearchPath`
resolves user-defined types from the connection's search path. A mismatch surfaces as a
positioned error report (below), not a generated file. This is verification, not codegen:
skunk trusts you to keep SQL, encoder, and decoder in sync, and tells you precisely where
you didn't.

## Type mapping & result decoding

The value↔column mapping is carried by three composable, explicit traits. A `Codec[A]` is
both an encoder and a decoder ([`Codec.scala`][codec]):

> _"Symmetric encoder and decoder of Postgres text-format data to and from Scala types."_

```scala
// skunk: modules/core/shared/src/main/scala/Codec.scala
trait Codec[A] extends Encoder[A] with Decoder[A] { outer =>
  def product[B](fb: Codec[B]): Codec[(A, B)] = /* pairs two codecs */
  def ~[B](fb: Codec[B]): Codec[A ~ B]        = product(fb)
  def imap[B](f: A => B)(g: B => A): Codec[B] = /* invariant map */
  override def opt: Codec[Option[A]]          = /* NULL ⇔ None */
}
```

The building blocks are `Encoder[A]` (_"Encoder of Postgres text-format data from Scala
types"_ — [`Encoder.scala`][encoder]) and `Decoder[A]` (_"Decoder of Postgres text-format
data into Scala types"_ — [`Decoder.scala`][decoder]). Because `varchar` and friends are
`Codec`s, the same value serves as both a parameter encoder and a row decoder — the
tutorial makes the point explicit ([`Query.md`][querydoc]): _"We have already seen
`varchar` used as a row decoder for `String` and now we're using it as an encoder for
`String`. We can do this because `varchar` actually has type `Codec[String]`."_

**Composition and the twiddle list.** Codecs (and encoders and decoders) compose with `~`,
building a left-associated nested pair — a "twiddle list" borrowed from `scodec`
([`package.scala`][pkg]): `type ~[+A, +B] = (A, B)`, so `varchar ~ int4` has type
`Codec[String ~ Int]` = `Codec[(String, Int)]`, and results destructure with the same
operator (`case n ~ p => …`). Newer code prefers the tuple operator `*:`; either way the
mapping to a case class is mechanical via `.to[CaseClass]` (an `Iso` derivation) or
`.map { case (n, p) => Country(n, p) }`:

```scala
// skunk: modules/docs/.../tutorial/Query.md
val country: Decoder[Country] =
  (varchar *: int4).to[Country]

val c: Query[Void, Country] =
  sql"SELECT name, population FROM country".query(country)
```

**Nullability.** `NULL` is modeled by `.opt`, which lifts a `Codec[A]` to a
`Codec[Option[A]]` where a column of all-`NULL` slots decodes to `None` and any value to
`Some` ([`Codec.scala`][codec]). Nullability is thus reflected in the Scala type
(`int4.opt` ⇒ `Codec[Option[Int]]`), the standard [type-mapping][concepts-tmap] treatment.
A decode failure is a typed `Decoder.Error(offset, length, message)` — an error value, not
a thrown exception at the decode site — which the runner turns into a `DecodeException`
with the full statement and arguments attached.

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and where skunk's wire-native,
`cats-effect` design pays off.

**A statement's result is an effect value.** `Session[F]` is parameterized over an abstract
effect `F[_]` (tagless final), constrained by `cats-effect`'s `MonadCancelThrow` /
`Temporal` and friends. Executing a statement yields an `F[…]` — a description of work,
run only at the edge of the program ([`Session.scala`][session]):

```scala
// skunk: modules/core/shared/src/main/scala/Session.scala (abridged)
sealed trait Session[F[_]] {
  def execute[A, B](query: Query[A, B])(args: A): F[List[B]]     // prepare-if-needed, all rows
  def unique[A, B](query: Query[A, B])(args: A): F[B]            // exactly one row, else error
  def option[A, B](query: Query[A, B])(args: A): F[Option[B]]    // zero or one
  def stream[A, B](query: Query[A, B])(args: A, chunkSize: Int): Stream[F, B]  // fs2 cursor stream
  def prepare[A, B](query: Query[A, B]): F[PreparedQuery[F, A, B]]
  def transaction[A]: Resource[F, Transaction[F]]
  def channel(name: Identifier): Channel[F, String, String]
}
```

The `execute`/`unique`/`option` trio (all `F[…]`) covers cardinality; `stream` returns an
`fs2.Stream[F, B]` backed by a **server-side cursor** so a large result set is paged in
`chunkSize`-row blocks in constant space rather than buffered whole (the
[cursor][concepts-cps] substrate). Because these are values, they compose with `flatMap` /
`traverse` and nothing touches the socket until the enclosing `IO` (or other `F`) is run.

**Transactions as a `Resource`, with automatic commit/rollback.** `Session.transaction`
yields a `Resource[F, Transaction[F]]` whose acquire runs `BEGIN` and whose release
consults both the exit case and the live transaction status to decide the finalizer
([`Session.scala`][session]):

> _"A transaction is begun before entering the `use` block, on success the block is
> executed, and on exit the following behavior holds… If the block exits due to
> cancellation or an error and the session transaction status is not `Idle` then the
> transaction will be rolled back and any error will be re-raised."_

The finalizer is a 3×3 matrix over `{Idle, Active, Failed}` status and
`{Succeeded, Canceled, Errored}` exit case ([`Transaction.scala`][transaction]): `Active` +
`Succeeded` commits; every failure or cancellation with a non-`Idle` status rolls back and
re-raises. An overload takes an explicit `TransactionIsolationLevel` and
`TransactionAccessMode`.

**Savepoints for nested rollback.** Postgres forbids true nested transactions, so skunk
uses [savepoints][concepts-eth]. A `Transaction[F]` exposes `savepoint` (an
existential `Savepoint` type) and `rollback(savepoint)`, implemented by emitting
`SAVEPOINT`/`ROLLBACK TO` with a generated name ([`Transaction.scala`][transaction]):

```scala
// skunk: modules/core/shared/src/main/scala/Transaction.scala
override def savepoint(implicit o: Origin): F[Savepoint] =
  for {
    _ <- assertActive(o.toCallSite("savepoint"))
    i <- n.nextName("savepoint")
    _ <- s.execute(internal"SAVEPOINT $i".command)
  } yield i
```

Trying to open a transaction while one is already `Active` raises a `SkunkException` with
the message _"Nested transactions are not allowed."_ and a hint to commit or roll back
first — so the "nesting" you get is savepoint-scoped rollback inside one transaction, not a
second `BEGIN`. The canonical pattern rolls back to a savepoint on a caught constraint
violation and continues ([`Transactions.md`][txdoc]):

```scala
// skunk: modules/docs/.../tutorial/Transactions.md
s.transaction.use { xa =>
  pets.traverse_ { p =>
    for {
      sp <- xa.savepoint
      _  <- pc.execute(p).recoverWith {
              case SqlState.UniqueViolation(ex) =>
                IO.println(s"Unique violation: ${ex.constraintName.getOrElse("<unknown>")}, rolling back...") *>
                  xa.rollback(sp)
            }
    } yield ()
  }
}
```

**Errors: skunk's own ADT in the `F` error channel, with rich reports.** Failures are
skunk exceptions raised into `F`'s error channel (recovered with `cats` /
`MonadError` combinators), not silent `null`s. The base type is `SkunkException`; a
Postgres-reported error becomes a `PostgresErrorException`, which lifts every field of the
wire `ErrorResponse` — SQLSTATE `code`, `severity`, `detail`, `hint`, `position`,
`constraintName`, `tableName`, `columnName`, `routine`, `fileName`, `line`
([`PostgresErrorException.scala`][pgerr]). Its rendered message is deliberately lavish:
`SkunkException.getMessage` frames each line with a `🔥` prefix and includes the
statement, the offending position pointed at within the SQL, the encoded arguments, and
the `Origin` (source file and line) where the statement was defined
([`SkunkException.scala`][skex]) — the concrete cash-out of the microsite's _"Skunk gives
very good error messages"_ claim. A `PostgresErrorException` even suggests the matching
`SqlState` extractor for trapping the error in application code.

**Typed error trapping via `SqlState`.** Postgres error codes are enumerated as `SqlState`,
which doubles as an extractor ([`SqlState.scala`][sqlstate]):

> _"Enumerated type of Postgres error codes. These can be used as extractors for error
> handling, for example: `doSomething.recoverWith { case SqlState.ForeignKeyViolation(ex) => ... }`"_

`SqlState.UniqueViolation.unapply` matches a `PostgresErrorException` whose `code` is
`23505`, giving structured, exhaustive-ish recovery keyed on the SQLSTATE — the equivalent
of Effect TS's `SqlErrorReason` union, but realized as pattern-matchable extractors over a
single exception hierarchy rather than a closed data type in the error channel. (A source
comment marks the intended direction: _"turn this into an ADT of structured error types"_
— [`PostgresErrorException.scala`][pgerr].)

**Wire-native extras: `LISTEN`/`NOTIFY`.** Because skunk owns the protocol, it exposes
Postgres asynchronous notifications as a first-class `Channel`, which _"can be used for
inter-process communication, implemented in terms of `LISTEN` and `NOTIFY`"_
([`Channel.scala`][channel]). A channel is an `fs2` `Pipe`/`Stream` pair: `listen(maxQueued)`
yields a `Stream[F, Notification[B]]` and `notify(msg)` sends one. This is not expressible
over a JDBC `PreparedStatement` API without vendor-specific polling — it falls out of
speaking the wire protocol directly.

## Ecosystem & maturity

skunk is **MIT**-licensed (`Copyright (c) 2018-2024 by Rob Norris and Contributors` —
[`LICENSE`][license]) and published under `org.tpolecat` (Rob Norris, "tpolecat"), the same
author as `doobie`. It is cross-built for **Scala 2.13 and 3** and for three platforms —
**JVM, Node.js (Scala.js), and Native** ([`index.md`][docindex]) — and depends on the
current Typelevel stack (`cats-effect` 3, `fs2` 3, `scodec`, and `otel4s` for
OpenTelemetry tracing/metrics, per [`build.sbt`][build]). It is featured in Gabriel Volpe's
book _Practical FP in Scala_ and was presented by its author at Scala Days 2019
([`index.md`][docindex]).

Backend support is, by the top design principle, **PostgreSQL only** — there is no
abstraction layer over other databases and there never will be, because the library is the
Postgres protocol. That is the sharp opposite of the multi-dialect stance of `jOOQ`,
`Slick`, or Effect TS; skunk trades breadth for depth (streaming, `LISTEN`/`NOTIFY`,
protocol-level error detail, SASL/SCRAM auth, SSL negotiation) that a lowest-common-
denominator dialect abstraction cannot reach.

## Strengths

- **No JDBC.** Speaking the wire protocol directly buys non-blocking I/O, real `fs2`
  streaming from server-side cursors, `LISTEN`/`NOTIFY` as a `Channel`, and
  protocol-level error detail — none of it reachable through JDBC.
- **Injection-safe by construction.** `sql"…"` holes are `Encoder`s/`Fragment`s checked at
  compile time; a non-encoder hole is a type error, and _"Skunk never interpolates
  statement arguments."_ The only unsafe path (`#$`) is visibly marked.
- **Explicit, composable codecs.** `Codec`/`Encoder`/`Decoder` are plain values built with
  `~`/`*:`/`.opt`/`.imap`/`.to` — no implicit derivation magic, easy to read and test.
- **Effect-value API.** Results are `F[…]` / `fs2.Stream[F, …]` over a tagless-final `F`;
  queries compose as descriptions and run at the edge, with scoped `Resource` pooling and
  interruption-safe transactions.
- **Real transaction nesting.** `Resource`-scoped `transaction` with automatic
  commit/rollback keyed on exit case _and_ live status, plus savepoint rollback for inner
  blocks.
- **Excellent error reports.** Positioned, source-annotated `SkunkException` /
  `PostgresErrorException` with SQLSTATE, arguments, and `SqlState` extractors for typed
  trapping.

## Weaknesses

- **Postgres only, forever.** By design it will _"not work with any other database back
  end"_ — no MySQL/SQLite/portability escape hatch.
- **All-in on the Typelevel stack.** You need `cats-effect`, `fs2`, and a working knowledge
  of `Resource`/tagless-final to use it at all; there is no plain-blocking façade.
- **No compile-time SQL verification against a schema.** Placeholder/column/type
  consistency is the author's responsibility, checked at runtime via `Describe` (or the
  `check` methods), not by a macro against a live schema — contrast `sqlx`/`sqlc`.
- **No migrations or codegen.** No schema ownership, no introspection, no generated column
  constants or decoders — you hand-write DDL and codecs.
- **Resource discipline required.** The docs themselves warn that `Resource`-managed
  sessions and streams _"take some discipline to avoid leaks, especially when working
  concurrently"_; a stream used outside its `Session`'s scope is invalid.
- **Twiddle-list ergonomics.** The `~`-nested-pair encoding of arity is idiosyncratic (the
  author's own note: _"I'm not sweating arity abstraction that much"_); the newer `*:` /
  `.to[CaseClass]` path softens but does not erase it.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                         | Trade-off                                                                                               |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Speak the Postgres wire protocol; **no JDBC**                       | Non-blocking I/O, `fs2` streaming, `LISTEN`/`NOTIFY`, protocol-level error detail                 | PostgreSQL only — zero portability; skunk must implement auth, SSL, and every message itself            |
| `sql"…"` interpolates `Encoder`s, not values (compile-time macro)   | Parameters are structurally out-of-band; injection is a type error, not a runtime hazard          | The interpolator is a macro (harder to reason about); non-encoder holes are compile errors, not splices |
| Explicit `Codec`/`Encoder`/`Decoder` values, no implicit derivation | Readable, testable, parser-combinator-style composition; no surprising typeclass resolution       | More boilerplate than derived mappers; the twiddle-list arity encoding is idiosyncratic                 |
| Result is an effect value `F[…]` over tagless-final `F`             | Lazy, composable descriptions; scoped `Resource` lifetimes; interruption-safe transactions        | Unusable outside `cats-effect`/`fs2`; steep on-ramp versus a blocking driver                            |
| Transaction as a `Resource` + savepoints for nesting                | Automatic commit/rollback on exit-case _and_ status; inner rollback without aborting the outer tx | Relies on Postgres savepoints (no true nesting); needs the `Resource`/exit-case model to be understood  |
| Errors as a `SkunkException` hierarchy with positioned reports      | Very good diagnostics; SQLSTATE `SqlState` extractors for typed trapping                          | Not (yet) a closed error ADT — recovery is exception-pattern-matching, not a sum type in `F`'s `E`      |
| No migrations, codegen, or introspection-to-code                    | Stays a statement mapper below the ORM line; keeps the surface small                              | You own the schema, DDL, and codecs; no compile-time schema checking                                    |

---

## Sources

- [`modules/core/shared/src/main/scala/package.scala`][pkg] — the design principles ("doesn't use JDBC", "asynchronous all the way down", "Codecs are explicit, like parser combinators"), the `~` twiddle-list alias, the minimal example.
- [`modules/core/shared/src/main/scala/Session.scala`][session] — the `Session[F]` trait (`execute`/`unique`/`option`/`stream`/`prepare`/`transaction`/`channel`), `Session.Builder` `single`/`pooled`, describe/parse caches, `Recyclers`.
- [`modules/core/shared/src/main/scala/Fragment.scala`][fragment] · [`Query.scala`][query] · [`Command.scala`][command] — the `Fragment[A]` → `Query[A, B]` / `Command[A]` pipeline and the placeholder/encoder/decoder consistency contract.
- [`modules/core/shared/src/main/scala-3/syntax/StringContextOps.scala`][sco] — the `sql` interpolator macro: compile-time classification of each hole as `Encoder` / `Fragment[Void]` / `Fragment[a]`, encoder accumulation, placeholder numbering.
- [`modules/core/shared/src/main/scala/Codec.scala`][codec] · [`Encoder.scala`][encoder] · [`Decoder.scala`][decoder] — the composable bidirectional codecs (`product`/`~`/`imap`/`opt`), `Decoder.Error`.
- [`modules/core/shared/src/main/scala/Transaction.scala`][transaction] — `transaction` acquire/release matrix, savepoint (`SAVEPOINT`/`ROLLBACK TO`), "Nested transactions are not allowed".
- [`modules/core/shared/src/main/scala/exception/SkunkException.scala`][skex] · [`PostgresErrorException.scala`][pgerr] · [`SqlState.scala`][sqlstate] — the error hierarchy, positioned `🔥` reports, SQLSTATE field extraction, `SqlState` extractors.
- [`modules/core/shared/src/main/scala/Channel.scala`][channel] — `LISTEN`/`NOTIFY` exposed as an `fs2` `Pipe`/`Stream` `Channel`.
- [`modules/docs/src/main/laika/`][docdir] — the microsite: [`index.md`][docindex] (pillars), [`tutorial/Query.md`][querydoc], [`tutorial/Transactions.md`][txdoc], [`reference/Fragments.md`][fragdoc] ("Skunk never interpolates statement arguments").
- [`LICENSE`][license] · [`build.sbt`][build] — MIT; `cats-effect`/`fs2`/`scodec`/`otel4s` dependencies, Scala 2.13 + 3 cross-build.
- Shared vocabulary: [`concepts.md`][concepts] — [abstraction ladder][concepts-ladder], [query-construction models][concepts-qcm], [parameter binding & injection][concepts-inj], [connections/pools][concepts-cps], [effects/transactions/errors][concepts-eth], [type mapping][concepts-tmap]. See also the survey [index][index].

<!-- References -->

[repo]: https://github.com/tpolecat/skunk
[docs]: https://typelevel.org/skunk/
[pkg]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/package.scala
[session]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Session.scala
[fragment]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Fragment.scala
[query]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Query.scala
[command]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Command.scala
[sco]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala-3/syntax/StringContextOps.scala
[codec]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Codec.scala
[encoder]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Encoder.scala
[decoder]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Decoder.scala
[transaction]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Transaction.scala
[skex]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/exception/SkunkException.scala
[pgerr]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/exception/PostgresErrorException.scala
[sqlstate]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala-3/SqlState.scala
[channel]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/core/shared/src/main/scala/Channel.scala
[docdir]: https://github.com/tpolecat/skunk/tree/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/docs/src/main/laika
[docindex]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/docs/src/main/laika/index.md
[querydoc]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/docs/src/main/laika/tutorial/Query.md
[txdoc]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/docs/src/main/laika/tutorial/Transactions.md
[fragdoc]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/modules/docs/src/main/laika/reference/Fragments.md
[license]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/LICENSE
[build]: https://github.com/tpolecat/skunk/blob/e4cde3f79d47dcaec94af5812d5cc7c51a8e87d1/build.sbt
[concepts]: ./concepts.md
[concepts-ladder]: ./concepts.md#the-abstraction-ladder
[concepts-qcm]: ./concepts.md#query-construction-models
[concepts-inj]: ./concepts.md#statements-parameters-and-sql-injection
[concepts-cps]: ./concepts.md#connections-pools-and-sessions
[concepts-eth]: ./concepts.md#effects-transactions-and-error-handling
[concepts-tmap]: ./concepts.md#type-mapping-and-result-decoding
[index]: ./index.md

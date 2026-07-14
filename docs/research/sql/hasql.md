# hasql (Haskell)

A fast, deliberately minimal PostgreSQL driver for Haskell built straight on `libpq`, in which a `Statement` is a first-class value pairing raw SQL with typed, composable `Encoders`/`Decoders`, executed inside an `IO`-based `Session` monad whose every failure is returned as an `Either SessionError` rather than thrown.

| Field              | Value                                                                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Haskell (`Haskell2010` plus a large default-extensions set)                                                                                       |
| License            | MIT                                                                                                                                               |
| Repository         | [nikita-volkov/hasql][repo]                                                                                                                       |
| Documentation      | [Hackage haddock][hackage] · [continuous haddock][haddock]                                                                                        |
| Category           | [Safe-SQL / micro-mapper][concepts-ladder] — raw SQL + typed mapping; no ORM, no query DSL, no relational algebra                                 |
| Abstraction level  | [Safe-SQL / micro-mapper rung][concepts-ladder] — parameters bind automatically, rows hydrate into typed values                                   |
| Query model        | [Raw SQL][concepts-models] with positional `$1`/`$2` placeholders + typed `Encoders`/`Decoders` ([macro-checked][concepts-models] via `hasql-th`) |
| Effect/async model | Blocking `IO` — the `Session` monad over `libpq`; errors returned as `Either SessionError` ([no exceptions][concepts-effects])                    |
| Backends           | PostgreSQL only (via `libpq`; needs `libpq` ≥ 14 to build, tested against servers from PostgreSQL 9)                                              |
| First release      | ≈2014 (web-attested; copyright dates from 2014)                                                                                                   |
| Latest version     | `1.10.3.5` (the pinned tree; the `1.10` major revision)                                                                                           |

> [!NOTE]
> hasql sits on the [safe-SQL / micro-mapper rung][concepts-ladder] of the abstraction
> ladder: above a bare [driver][concepts-ladder] (parameters bind automatically and rows
> hydrate into typed values) but far below a full ORM — no schema, no identity map, no
> change tracking, and — deliberately — no transactions or connection pooling in the core
> package. It is this survey's data point for a **granular companion-package ecosystem** and
> for a **blocking-`IO` `Session` monad** with a fully value-typed error channel, in contrast
> to the effect-value encodings of `doobie`/`skunk`/`Quill` and the typed relational-algebra
> DSLs of its Haskell siblings `Squeal` and `Opaleye`. See [concepts][concepts] for shared
> vocabulary.

---

## Overview

### What it solves

hasql is a thin, performance-led wrapper over `libpq` — PostgreSQL's C client library — that
turns raw SQL plus a pair of typed codecs into a runnable value. Its cabal synopsis states
the pitch in one line ([`hasql.cabal`][cabal]):

> _"Fast PostgreSQL driver with a flexible mapping API"_

The package description draws the scope boundary that defines the whole project — the core
owns connection management, execution, and mapping, and _everything else is someone else's
package_ ([`hasql.cabal`][cabal]):

> _"Root of the \"hasql\" ecosystem. This library provides connection management, execution of
> queries and mapping of parameters and results. Extended functionality such as pooling,
> transactions and compile-time checking of SQL is provided by extension libraries."_

That sentence is the single most load-bearing fact about hasql: **pooling, transactions, and
compile-time SQL checking are not in core** — they are separate packages (`hasql-pool`,
`hasql-transaction`, `hasql-th`). The core is the [Data Mapper][concepts-orm] separation
(persistence-ignorant typed values) with the mutable-object part dropped, the same boundary
`doobie` and `skunk` draw — but hasql is thinner, PostgreSQL-only, binary-wire-native, and
_blocking_ rather than an interpreted effect value.

### Design philosophy

hasql's `README` states three priorities, in order ([`README.md`][readme]):

> _"PostgreSQL driver for Haskell, that prioritizes:_
> _- Performance_
> _- Typesafety_
> _- Flexibility"_

**Flexibility means an ecosystem, not a framework.** hasql's defining architectural choice is
to be a small nucleus surrounded by focused satellites rather than one monolith
([`README.md`][readme]):

> _"Hasql is not just a single library, it is a granular ecosystem of composable libraries,
> each isolated to perform its own task and stay simple."_

The `README`'s "Why make it an ecosystem?" section lists the rationale — _"Focus"_ (each
library has a simple, narrow API), _"Flexibility"_ (the user picks the abstraction level),
_"Much more stable and descriptive semantic versioning"_, and _"Interchangeability and
competition of the ecosystem components"_ (transactions can be modelled several ways by
several packages instead of one imposed design) ([`README.md`][readme]). This is why the
survey reads hasql and (say) `hasql-transaction` as separate data points.

**Errors are values, never exceptions.** The second pillar is explicit error handling. The
cabal description is blunt ([`hasql.cabal`][cabal]):

> _"The API comes free from all kinds of exceptions. All error-reporting is explicit and is
> presented using the 'Either' type."_

and the `Hasql.Errors` module header restates it ([`Hasql/Errors.hs`][errorsmod]):

> _"The module follows Hasql's philosophy of explicit error handling, where all errors are
> represented as values rather than exceptions."_

Every entry point returns an `Either`: `acquire` yields `IO (Either ConnectionError Connection)`
and `use` yields `IO (Either SessionError a)`. This puts hasql's error story between the two
poles the survey tracks — richer than `doobie`'s untyped `Throwable` `MonadError` channel,
though realized as a concrete `Either` sum type rather than the type-parameterized error slot
of an `Effect`/`ZIO`.

---

## Connection, pooling & resource lifetime

The `Hasql.Connection` module is _"a low-level effectful API dealing with the connections to
the database"_ ([`Hasql/Connection.hs`][connmod]). A `Connection` is an `MVar` guarding a
mutable `ConnectionState` (the `libpq` handle plus a per-connection prepared-statement cache
and OID cache) ([`Hasql/Connection.hs`][connmod]):

```haskell
newtype Connection = Connection (MVar ConnectionState.ConnectionState)

acquire  :: Settings.Settings -> IO (Either ConnectionError Connection)
release  :: Connection -> IO ()
use      :: Connection -> Session.Session a -> IO (Either SessionError a)
```

**Settings are a monoid.** The `1.10` revision redesigned configuration into flat monoidal
composition ([`Hasql/Connection/Settings.hs`][settingsmod]): `hostAndPort "localhost" 5432 <> user "postgres" <> dbname "postgres"`,
with an `IsString` instance so `OverloadedStrings` lets a raw connection string _be_ a
`Settings` value. `noPreparedStatements True` disables server-side preparation for
`pgbouncer`-style proxies that cannot handle it.

**One session at a time, exclusive access.** `use` is the runner. It `takeMVar`s the
connection state, so a `Session` holds the connection for its entire duration
([`Hasql/Connection.hs`][connmod]):

> _"Execute a sequence of operations with exclusive access to the connection. Blocks until the
> connection is available when there is another session running upon the connection on a
> different thread."_

If user code inside a `Session` throws, `use` does not simply propagate: since `1.10` it runs
a `cleanUpAfterInterruption` handler that brings the connection back to idle _without
resetting_ — _"to preserve session state"_ — and only closes it if cleanup fails
([`Hasql/Connection.hs`][connmod]). This "no resets on errors" behaviour deliberately keeps
connection-local server state (temp tables, `SET` variables) across an interrupted session.

> [!NOTE]
> **Pooling is not in core — this is a finding, not an omission.** A `Connection` is a single
> `libpq` handle behind one `MVar`; there is no pool, no lease/return, no sizing. Production
> pooling is the separate `hasql-pool` package — _"a Hasql-specialized abstraction over the
> connection pool"_ ([`README.md`][readme]). Contrast `doobie`, whose HikariCP transactor is a
> `cats-effect` `Resource`, and the effect systems that model a leased connection as a
> [scoped acquire/release][concepts-pools]. hasql leaves that to a satellite so the core stays
> a bare driver over one socket.

Prepared statements are enabled by default and cached per connection (keyed by SQL text +
resolved parameter OIDs); the first execution of a preparable statement costs an extra
`PARSE` roundtrip, after which steady-state execution is a single roundtrip
([`Hasql/Engine/Contexts/Session.hs`][sessionctx]).

---

## Query construction & injection safety

This is hasql's centre of gravity, and the mechanism is a single value type read top to
bottom.

**A `Statement` is a first-class value combining SQL text with typed codecs.** The engine
docstring fixes exactly what it is ([`Hasql/Engine/Statement.hs`][stmtengine]):

> _"Specification of a strictly single-statement query, which can be parameterized and
> prepared. It encapsulates the mapping of parameters and results in association with an SQL
> template."_

There are two smart constructors — the prepared/unprepared distinction is chosen by _which
constructor you call_, recorded as an internal `isPrepared :: Bool` field, not passed as a
flag ([`Hasql/Engine/Statement.hs`][stmtengine]):

```haskell
preparable   :: Text -> Encoders.Params params -> Decoders.Result result -> Statement params result
unpreparable :: Text -> Encoders.Params params -> Decoders.Result result -> Statement params result
```

`preparable` is _"for statements that will be executed multiple times"_ (server-cached plan);
`unpreparable` is _"for statements that are dynamically generated or executed only once"_
([`Hasql/Engine/Statement.hs`][stmtengine]).

**The SQL text and the parameters are separate channels — hasql never interpolates.** The SQL
`Text` carries PostgreSQL positional placeholders (`$1`, `$2`, …); the values are supplied
_positionally_ through the `Encoders.Params` value, associated with placeholders **by order**
([`README.md`][readme]):

> _"Specification of how to encode the parameters of the statement where the association with
> placeholders is achieved by order."_

At execution the encoded values are handed to `libpq` as out-of-band binary parameters
(`queryParams` / `queryPrepared`), never spliced into the SQL string
([`Hasql/Engine/Contexts/Session.hs`][sessionctx]). Because a parameter value can only ever
travel on the parameter channel, [SQL injection is structurally impossible][concepts-injection]
for it — and, unlike `doobie`'s `Fragment.const` or a tagged-template library's `sql.unsafe`,
**core hasql exposes no raw-string splice at all**: there is no interpolator to misuse.
Dynamic SQL assembly is deferred to the separate `hasql-dynamic-statements` package.

A complete statement, straight from the `README` ([`README.md`][readme]):

```haskell
sumStatement :: Statement.Statement (Int64, Int64) Int64
sumStatement = Statement.preparable sql encoder decoder
  where
    -- The SQL of the statement, with $1, $2, ... placeholders for parameters.
    sql =
      "select $1 + $2"
    -- Association with placeholders is achieved by order.
    encoder =
      mconcat
        [ fst >$< Encoders.param (Encoders.nonNullable Encoders.int8),
          snd >$< Encoders.param (Encoders.nonNullable Encoders.int8)
        ]
    decoder =
      Decoders.singleRow
        (Decoders.column (Decoders.nonNullable Decoders.int8))
```

**Encoders compose contravariantly.** `Encoders.Params` is a `Contravariant`, `Divisible`, and
`Monoid` functor, which is how a params encoder for a whole record is built from
single-parameter pieces ([`Hasql/Codecs/Encoders/Params.hs`][paramsmod]):

> _"Has instances of 'Contravariant', 'Divisible' and 'Monoid', which you can use to compose
> multiple parameters together."_

The operators: `>$<` is `contramap` — it projects a field out of the input before encoding
(`fst >$<` feeds the first tuple element to an `int8` param); `<>` / `mconcat` concatenates
positional parameters left to right; and the `contrazipN` helpers from `contravariant-extras`
zip a tuple of encoders (the docstring shows `contrazip2 (param (nonNullable int8)) (param (nullable text))`)
([`Hasql/Codecs/Encoders/Params.hs`][paramsmod]). `param` lifts one value encoder, wrapped in
a `nonNullable`/`nullable` nullability marker; `noParams` (= `mempty`) is the empty product.

**Compile-time-checked SQL is an opt-in satellite.** For the general case the `README`
_"advise[s]"_ declaring statements with `hasql-th`, which _"validates the statements at
compile-time and generates codecs automatically"_ — the [macro-checked raw-SQL][concepts-models]
model (the family as `sqlx`/`sqlc`), via a `QuasiQuoter` ([`README.md`][readme]):

```haskell
import qualified Hasql.TH as TH -- from "hasql-th"

sumStatement :: Statement.Statement (Int64, Int64) Int64
sumStatement =
  [TH.singletonStatement|
    select ($1 :: int8 + $2 :: int8) :: int8
  |]
```

Here the SQL is parsed and type-annotated at compile time and the encoder/decoder are
generated from it — so the raw string, the codecs, and the result shape can no longer drift
apart. The core library, though, is codec-explicit by default.

---

## Schema, migrations & code generation

**hasql owns no schema, and this is deliberate.** There is no entity/model declaration that
_is_ the schema (no code-first), no schema file it treats as truth (no schema-first), and no
migration runner or DDL-versioning tooling anywhere in the core tree. The cabal description
draws the line explicitly — _"compile-time checking of SQL is provided by extension
libraries"_ ([`hasql.cabal`][cabal]) — and the same applies to migrations. You write DDL as
ordinary `script "create table …"` text if you wish; ordering and bookkeeping are external.

What the ecosystem offers instead, as separate packages ([`README.md`][readme]):

- **`hasql-th`** — _"Template Haskell utilities, providing compile-time syntax checking and
  easy statement declaration"_: parses the SQL and infers codecs at compile time (the
  [macro-checked raw-SQL][concepts-models] move), verifying against a parsed grammar rather
  than a live database.
- **`hasql-migration`** — a community _"port of postgresql-simple-migration for use with
  hasql"_ (a numbered-script migration runner).
- **`hasql-dynamic-statements`** — _"a toolkit for generating statements based on the
  parameters"_ for runtime-shaped SQL.

There is no first-party [introspection→codegen][concepts-schema] path (the `jOOQ`/`sqlc`
move). The one place core hasql touches the live schema is **OID resolution by name**: since
`1.10`, custom-type encoders/decoders (enums, composites, domains) resolve their PostgreSQL
type OIDs at runtime by querying `pg_type` and caching the result, rather than hardcoding OID
constants ([`CHANGELOG.md`][changelog]). A type referenced but absent from the database fails
the session with `MissingTypesSessionError` ([`Hasql/Engine/Contexts/Session.hs`][sessionctx]).

---

## Type mapping & result decoding

Decoders mirror encoders as a small tower, composed the _covariant_ way (encoders are
contravariant; decoders are `Functor`/`Applicative`).

| Layer        | Type                    | Role                                                                                                                               |
| ------------ | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Single value | `Decoders.Value a`      | Decode one column value from its binary wire form (`int8`, `text`, `uuid`, `json`, arrays, composites, `enum`, `custom`, `refine`) |
| Nullability  | `NullableOrNot Value a` | `nonNullable` / `nullable` — a `NULL` in a `nonNullable` slot is an error, `nullable` decodes to `Maybe a`                         |
| Row          | `Decoders.Row a`        | An `Applicative` product of `column` decoders                                                                                      |
| Result       | `Decoders.Result a`     | Row-cardinality: `noResult`, `rowsAffected`, `singleRow`, `rowMaybe`, `rowVector`, `rowList`, `foldlRows`/`foldrRows`              |

**A `Row` decoder is `Applicative`, and only `Applicative`.** Column decoders combine with
`<$>`/`<*>` ([`Hasql/Engine/Decoders/Row.hs`][rowdec]):

> _"Decoder of an individual row, which gets composed of column value decoders."_

The `1.10` revision **dropped the `Monad`/`MonadFail` instances** for `Row`, on the grounds
that _"`Applicative` is enough for all practical purposes"_ ([`CHANGELOG.md`][changelog]) —
so a row is a fixed-shape product of columns, decoded position by position, not a value whose
later columns can depend on earlier ones. `singleRow`, `rowVector`, etc. lift a `Row` into a
`Result`; a row-count mismatch (e.g. `singleRow` on zero or many rows) surfaces as
`UnexpectedRowCountStatementError` ([`Hasql/Engine/Decoders/Result.hs`][resultdec]).

**Strict type checking, since `1.10`.** Previously a decoder would accept any column whose
binary form happened to decode; now the decoder checks the actual column type OID against the
expected one ([`CHANGELOG.md`][changelog]):

> _"Previously decoders were silently accepting values of different types, if binary decoding
> did not fail. Now decoders check if the actual type of the column matches the expected type
> of the decoder and report `UnexpectedColumnTypeStatementError` error if they do not match.
> They also match the amount of columns in the result with the amount of columns expected by
> the decoder …"_

So an `int4` column read with an `int8` decoder now reports `UnexpectedColumnTypeStatementError`
instead of silently coercing, and a column-count mismatch reports
`UnexpectedColumnCountStatementError`. **Nullability** maps a `nullable` column to `Maybe a`;
a `NULL` in a `nonNullable` column is an `UnexpectedNullCellError` cell error. Everything
travels the **binary** wire format (via `postgresql-binary`), not text — a performance choice
that also makes decoding a typed parse rather than string conversion. `refine` attaches a
post-decode validation `(a -> Either Text b)`, whose failure becomes a `RefinementRowError`
([`Hasql/Engine/Decoders/Result.hs`][resultdec]).

---

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and hasql sits at the **blocking-`IO`**
end of the spectrum — not the effect-value end of `doobie`/`skunk`/`Quill`.

### The `Session` monad is a plain `IO` computation, not a description

A `Session` is a state-threading function over `IO`, given its monad instances by deriving
([`Hasql/Engine/Contexts/Session.hs`][sessionctx]):

```haskell
newtype Session a
  = Session (ConnectionState -> IO (Either SessionError a, ConnectionState))
  deriving
    (Functor, Applicative, Monad, MonadError SessionError, MonadIO)
    via (ExceptT SessionError (StateT ConnectionState IO))
```

This is the pivotal contrast for the survey. A `doobie` `ConnectionIO` or a `skunk`/`Effect`
program is a _description_ that allocates nothing until interpreted; a hasql `Session` is a
function you _run_ with `Connection.use`, and it drives `libpq` `IO` directly. It is
[blocking][concepts-effects] (each statement is _"a dedicated network roundtrip"_,
[`Hasql/Engine/Contexts/Session.hs`][sessionctx]), monadic, and eagerly effectful once run —
closer to `JDBI`/`Dapper`/`database/sql` in kind, but with typed codecs and value-typed errors
bolted on. Sessions compose with `do`-notation, sequencing statements whose parameters may
depend on earlier results ([`README.md`][readme]):

```haskell
sumAndDivModSession :: Int64 -> Int64 -> Int64 -> Session (Int64, Int64)
sumAndDivModSession a b c = do
  sumOfAAndB <- Session.statement (a, b) sumStatement
  Session.statement (sumOfAAndB, c) divModStatement
```

`Hasql.Session.statement`, `Hasql.Session.script` (a multi-statement text that _"cannot be
parameterized or prepared, nor can any results of it be collected"_,
[`Hasql/Session.hs`][sessionmod]), and `onLibpqConnection` (a raw-`libpq` escape hatch) are the
constructors.

### `Pipeline` is the `Applicative` for independent statements

To cut roundtrips, hasql exposes `Pipeline` — libpq's pipeline mode — as a **`Applicative`,
not a `Monad`**. Its docstring gives the reasoning, which is exactly the `Applicative`-vs-`Monad`
distinction ([`Hasql/Engine/Contexts/Pipeline.hs`][pipelinectx]):

> _"In situations where the parameters depend on the result of another query it is impossible
> to execute them in parallel, because the client needs to receive the results of one query
> before sending the request to execute the next. This reasoning is essentially the same as
> the one for the difference between 'Applicative' and 'Monad'. That's why 'Pipeline' does not
> have the 'Monad' instance."_

A batch of independent statements is expressed applicatively (or with `ApplicativeDo` /
`traverse`) and lifted into a `Session` with `Session.pipeline`, collapsing many round-trips
into (often) one ([`Hasql/Engine/Contexts/Pipeline.hs`][pipelinectx]). Dependent statements
stay in the `Session` monad. This is a clean, principled split: `Monad` where later work needs
earlier results, `Applicative` where it does not.

### Transactions are not in core

> [!IMPORTANT]
> **Core hasql has no transaction combinator, no savepoints, and no isolation-level API — a
> deliberate finding.** There is no `withTransaction`/`transaction { … }` in the tree. You
> either issue `script "begin"` / `"commit"` yourself, or reach for the separate
> `hasql-transaction` package — _"an STM-inspired composable abstraction over database
> transactions providing automated conflict resolution"_ ([`README.md`][readme]), i.e. it
> retries transactions that fail with a serialization/deadlock error. The `README`'s ecosystem
> rationale explicitly cites transactions as the case for satellites: _"not everyone will
> agree … with the restrictive design decisions made in the \"hasql-transaction\" library …
> another extension library can simply be released, which will provide a different
> interpretation."_ Contrast `doobie`'s built-in, pluggable `Strategy` and the effect systems'
> nested-`withTransaction`/[savepoint][concepts-effects] combinators.

### Errors: a value-typed sum, no exceptions

Every failure is an `Either` value in a structured hierarchy. There are two top-level error
types — `ConnectionError` from `acquire`, `SessionError` from `use` — and the `1.10` revision
even **removed the `Exception` instances**, since _"The error types here were never thrown as
exceptions"_ ([`CHANGELOG.md`][changelog]). The `SessionError` sum
([`Hasql/Engine/Errors.hs`][errorsengine]):

| Constructor                | Carries                                                                                    | Meaning                                              |
| -------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| `StatementSessionError`    | total-count, 0-based index, SQL `Text`, rendered params, `prepared` flag, `StatementError` | a statement failed (with full context for logging)   |
| `ScriptSessionError`       | SQL `Text`, `ServerError`                                                                  | a `script` failed server-side                        |
| `ConnectionSessionError`   | reason `Text`                                                                              | connection lost/unusable mid-session (transient)     |
| `MissingTypesSessionError` | set of `(schema, name)` pairs                                                              | a referenced custom type is absent from the database |
| `DriverSessionError`       | reason `Text`                                                                              | a hasql bug or server misbehaviour                   |

The nested `StatementError` distinguishes a `ServerStatementError` (wrapping a `ServerError`
with the SQLSTATE `code`, `message`, optional `detail`/`hint`, and `position`) from decoder
mismatches (`UnexpectedRowCountStatementError`, `UnexpectedColumnCountStatementError`,
`UnexpectedColumnTypeStatementError`), a per-row `RowStatementError` (→ `RowError` → `CellError`,
covering `UnexpectedNullCellError` and `DeserializationCellError`), and the catch-all
`UnexpectedResultStatementError` ([`Hasql/Engine/Errors.hs`][errorsengine]). A `refineResult`
on a `Statement` fails the session with `UnexpectedResultStatementError`
([`Hasql/Engine/Statement.hs`][stmtengine]).

Every error type is a member of an `IsError` class exposing `toMessage`, `toDetails`, and —
notably — `isTransient` ([`Hasql/Errors.hs`][errorsmod]), the retryability flag that maps to
the survey's [`isRetryable` notion][concepts-effects]: a `NetworkingConnectionError` and a
`ConnectionSessionError` are transient, a `ServerError` or an authentication failure is not.
Because the whole `ServerError` (SQLSTATE `code` included) is a value, catching a unique
violation (`"23505"`) is ordinary pattern-matching on the `Either`, not exception handling —
the same practical outcome as `doobie`'s `attemptSomeSqlState`, reached the other way.

---

## Ecosystem & maturity

hasql is a mature, actively-maintained project under the permissive **MIT** license, authored
by Nikita Volkov (`copyright: (c) 2014, Nikita Volkov`, [`hasql.cabal`][cabal];
[`LICENSE`][license]). The `README` calls it _"production-ready, actively maintained"_ and
names its most prominent user — the **PostgREST** project (a widely-deployed
REST-over-Postgres server) ([`README.md`][readme]).

**The ecosystem is the product.** Around the core sit focused satellites, each its own package
([`README.md`][readme]): `hasql-transaction` (STM-inspired transactions with retry),
`hasql-pool` (connection pool), `hasql-th` (compile-time SQL checking + codec generation),
`hasql-dynamic-statements` (runtime statement generation), `hasql-migration` (migrations),
`hasql-cursor-query` (cursor streaming), `hasql-interpolate` (a `QuasiQuoter` interpolating
Haskell expressions), `hasql-postgresql-types` (a lossless type model), and
`hasql-implicits` (default codecs). The stated payoffs are independent semantic versioning and
_"competition of the ecosystem components"_ ([`README.md`][readme]).

**Backends: PostgreSQL only.** hasql binds `libpq` and speaks the Postgres binary protocol;
there is no dialect layer and no other backend. Building requires `libpq` ≥ 14, though it is
_"thoroughly tested to be compatible with … PostgreSQL servers starting from version 9"_
([`hasql.cabal`][cabal]).

The pinned tree is the `1.10` major revision (`version: 1.10.3.5`), whose changes are the
headline maturity story ([`CHANGELOG.md`][changelog]): OID-resolution-by-name for custom
types, strict decoder type/column checking, "no resets on errors" (connections recover without
losing session state), a redesigned monoidal settings API, a low-level custom-codec API, a
move from `ByteString` to `Text` in the public surface, and a complete overhaul of the error
model into `Hasql.Errors`.

---

## Strengths

- **Fast and thin.** Direct `libpq` binding, binary wire format (`postgresql-binary`),
  per-connection prepared-statement caching, and a pipeline mode that batches independent
  statements into (often) one roundtrip.
- **Injection-safe by construction, with no unsafe splice in core.** SQL text and parameter
  values are separate `libpq` channels; core exposes no string interpolator to misuse (dynamic
  SQL is an opt-in satellite).
- **Typed, composable codecs.** `Encoders.Params` compose contravariantly (`>$<` / `<>` /
  `contrazipN`); `Decoders.Row`/`Result` compose applicatively — small, orthogonal pieces.
- **Errors as values.** A structured `Either SessionError` hierarchy with SQLSTATE codes and an
  `isTransient` retryability flag; no exceptions on the happy or the error path.
- **Principled `Applicative`/`Monad` split.** `Pipeline` (`Applicative`) for independent work,
  `Session` (`Monad`) for dependent work — the concurrency distinction made in the types.
- **Strict correctness checks.** Since `1.10`, column type and count mismatches are reported,
  not silently coerced.
- **Composable ecosystem.** Pick exactly the abstraction you need (transactions, pooling,
  compile-time checking, migrations) as independent, independently-versioned packages.

## Weaknesses

- **You write SQL, and codecs by hand (or reach for `hasql-th`).** No query DSL, no relational
  algebra, no dialect layer — portability and typed query construction are out of scope (that
  is `Squeal`/`Opaleye`'s niche).
- **PostgreSQL only.** No other backend; hard-bound to `libpq` (a C dependency, ≥ 14 to build).
- **Blocking `IO`, not an effect value.** A `Session` runs `libpq` directly; there is no
  interpretable/inspectable program value, no `cats-effect`/`ZIO`/`Effect` integration in core,
  and no async wire protocol (that is `skunk`'s niche).
- **Batteries are separate packages.** Transactions, pooling, migrations, and compile-time
  checking each require adding another dependency — the ecosystem model is a cost as well as a
  benefit.
- **No transactions/savepoints/isolation in core.** Multi-statement atomicity means manual
  `begin`/`commit` or `hasql-transaction`.
- **Fixed-shape rows.** `Row` is `Applicative`-only; a decode whose later columns depend on
  earlier values is not expressible (by design).

---

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                                  | Trade-off                                                                                                     |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| **Granular ecosystem**: tiny core + focused satellites                    | Focus, independent semver, competing designs for contested features (transactions)         | Common needs (pool, transactions, migrations, compile-time checks) are extra dependencies to assemble         |
| `Statement params result` = **SQL text + typed `Encoders`/`Decoders`**    | Injection-safe, first-class, reusable value; codecs compose separately from the SQL        | Codecs are hand-written (or generated by `hasql-th`); no dialect portability or typed query construction      |
| **Positional `$n` params, no interpolation, no raw splice in core**       | SQL text and data are structurally separate channels — injection is impossible for a param | Dynamic/identifier SQL needs `hasql-dynamic-statements`; parameters bind by order, so order errors are silent |
| **Encoders `Contravariant`/`Divisible`/`Monoid`; decoders `Applicative`** | Build whole-record codecs from single-column pieces with lawful, orthogonal combinators    | `Row` is `Applicative`-only (no result-dependent columns); `contrazipN` needed for wide tuples                |
| **`Session` = blocking `IO` monad**, run by `Connection.use`              | Simple, fast, direct `libpq` driving; monadic sequencing with dependent results            | Not an inspectable effect value; no effect-runtime integration; blocking, PostgreSQL-only                     |
| **`Pipeline` is `Applicative`, not `Monad`**                              | Independent statements batch into fewer roundtrips; the concurrency limit is in the type   | Result-dependent batching is impossible — must fall back to the per-statement `Session` monad                 |
| **Errors as `Either` values (no `Exception` instances)**                  | Explicit, structured, retryable-flagged (`isTransient`) failure handling; no hidden throws | A concrete `Either SessionError` sum, not a type-parameterized error slot; user code can still throw          |
| **No transactions / pooling / migrations / codegen in core**              | Keep the nucleus a sharp, minimal driver; delegate contested policy to satellites          | Multi-statement atomicity, pooling, and versioned schema all live in separate packages you must add           |
| **OID-by-name resolution + strict type checks (`1.10`)**                  | Custom types work without hardcoded OIDs; wrong-type reads fail loudly instead of coercing | A runtime `pg_type` lookup (cached) on first use; stricter decoders can reject previously-tolerated queries   |

---

## Sources

- [nikita-volkov/hasql — GitHub repository][repo] · [Hackage][hackage] · [continuous haddock][haddock]
- [`README.md` — priorities (Performance/Typesafety/Flexibility), "granular ecosystem", positional-params example, `hasql-th`, satellite packages, PostgREST][readme]
- [`hasql.cabal` — synopsis, description (pooling/transactions/compile-time checking in extension libraries), "free from all kinds of exceptions … Either", `libpq` ≥ 14, MIT, version `1.10.3.5`][cabal]
- [`LICENSE` — MIT, "Copyright (c) 2014, Nikita Volkov"][license]
- [`CHANGELOG.md` — `1.10` revision: OID-by-name, strict decoder checks, no-reset-on-error, monoid settings, custom codecs, `Text` migration, error overhaul, `Row` `Monad` drop, `Exception` removal][changelog]
- [`src/library/Hasql/Connection.hs` — `Connection` = `MVar`, `acquire`/`release`/`use`, exclusive access, cleanup-not-reset][connmod]
- [`src/library/Hasql/Connection/Settings.hs` — monoidal `Settings`, `hostAndPort`/`user`/`dbname`/`noPreparedStatements`][settingsmod]
- [`src/library/Hasql/Engine/Statement.hs` — `Statement` record, `preparable`/`unpreparable`, `isPrepared`, `refineResult`][stmtengine]
- [`src/library/Hasql/Session.hs` + `src/library/Hasql/Engine/Contexts/Session.hs` — `Session` newtype, `statement`/`script`/`onLibpqConnection`, per-statement roundtrip][sessionmod]
- [`src/library/Hasql/Codecs/Encoders/Params.hs` — `Params` `Contravariant`/`Divisible`/`Monoid`, `param`, `noParams`][paramsmod]
- [`src/library/Hasql/Engine/Decoders/{Row,Result}.hs` — `Row` `Applicative`, `column`, `singleRow`/`rowVector`/`foldlRows`][rowdec]
- [`src/library/Hasql/Engine/Contexts/Pipeline.hs` — `Pipeline` `Applicative`-not-`Monad`, libpq pipeline mode][pipelinectx]
- [`src/library/Hasql/Errors.hs` + `src/library/Hasql/Engine/Errors.hs` — `IsError`/`isTransient`, `ConnectionError`/`SessionError`/`StatementError`/`RowError`/`CellError`/`ServerError`][errorsmod]
- Shared vocabulary: [concepts & vocabulary][concepts] · [the abstraction ladder][concepts-ladder] · [query construction models][concepts-models] · [statements, parameters & injection][concepts-injection] · [effects, transactions & error handling][concepts-effects]

<!-- References -->

[concepts]: ./concepts.md
[concepts-ladder]: ./concepts.md#the-abstraction-ladder
[concepts-models]: ./concepts.md#query-construction-models
[concepts-injection]: ./concepts.md#statements-parameters-and-sql-injection
[concepts-pools]: ./concepts.md#connections-pools-and-sessions
[concepts-schema]: ./concepts.md#schema-migrations-code-generation
[concepts-types]: ./concepts.md#type-mapping-and-result-decoding
[concepts-effects]: ./concepts.md#effects-transactions-and-error-handling
[concepts-orm]: ./concepts.md#orm-patterns
[index]: ./index.md
[repo]: https://github.com/nikita-volkov/hasql
[hackage]: https://hackage.haskell.org/package/hasql
[haddock]: https://nikita-volkov.github.io/hasql/
[readme]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/README.md
[cabal]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/hasql.cabal
[license]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/LICENSE
[changelog]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/CHANGELOG.md
[connmod]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Connection.hs
[settingsmod]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Connection/Settings.hs
[stmtengine]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Engine/Statement.hs
[sessionmod]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Session.hs
[sessionctx]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Engine/Contexts/Session.hs
[paramsmod]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Codecs/Encoders/Params.hs
[rowdec]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Engine/Decoders/Row.hs
[resultdec]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Engine/Decoders/Result.hs
[pipelinectx]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Engine/Contexts/Pipeline.hs
[errorsmod]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Errors.hs
[errorsengine]: https://github.com/nikita-volkov/hasql/blob/c8e78a9f13e8e87065dfe5fe0e0a731281898dee/src/library/Hasql/Engine/Errors.hs

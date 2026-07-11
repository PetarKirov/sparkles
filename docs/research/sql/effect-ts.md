# Effect TS `sql` (TypeScript)

A dialect-agnostic SQL toolkit built on the [Effect][repo] runtime: a tagged-template `sql` constructor that captures every interpolated value as a bound parameter, compiles a fragment tree to `[sql, params]` for a chosen dialect, and returns each statement as a first-class `Effect` value carrying a typed [`SqlError`][concepts-eth] channel.

| Field              | Value                                                                                                                        |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| Language           | TypeScript                                                                                                                   |
| License            | MIT (`Copyright (c) 2023 Effectful Technologies Inc`)                                                                        |
| Repository         | [Effect-TS/effect-smol][repo] (SQL core under `packages/effect/src/unstable/sql`); lineage [Effect-TS/effect][repo-classic]  |
| Documentation      | [effect.website][docs] · module docstrings in `src/unstable/sql/*.ts`                                                        |
| Category           | [Functional data mapper][concepts-ladder] (effect-system SQL layer); **not** a full ORM — no identity map, no implicit flush |
| Abstraction level  | [Data mapper (functional)][concepts-ladder] rung — typed, composable queries with explicit effects                           |
| Query model        | [Tagged template][concepts-qcm] (`` sql`… ${x}` ``), plus fragment/helper combinators; escape hatch `sql.unsafe`             |
| Effect/async model | [Effect value][concepts-eth] — a `Statement` **is** an `Effect.Effect<ReadonlyArray<A>, SqlError>`                           |
| Backends           | Postgres (`pg`, PGlite), MySQL (`mysql2`), SQLite (node/bun/wasm/react-native/D1/Durable Objects), MSSQL, ClickHouse, libSQL |
| First release      | ≈ 2023 (classic `@effect/sql`; copyright year) — web-attested                                                                |
| Latest version     | `effect@4.0.0-beta.96` (SQL core in `effect/unstable/sql`); pinned checkout `2711e39a`, 2026-07-09                           |

> [!NOTE]
> Effect TS `sql` is this survey's **primary effects-first exemplar**. It sits on
> the [functional data-mapper rung][concepts-ladder] alongside `Quill`, `doobie`,
> `skunk`, and `Ecto`: it gives you typed, composable queries and explicit effects
> **without** a unit of work or change tracking. Its distinguishing move is that a
> query is not a string you run — it is an `Effect` you compose, whose failure
> type is a single structured [`SqlError`][concepts-eth]. Terms such as
> [tagged template][concepts-qcm], [scoped acquirer][concepts-cps],
> [savepoint][concepts-eth], and [DataLoader batching][concepts-n1] are defined in
> [`concepts.md`][concepts].

---

## Overview

### What it solves

Effect TS `sql` is the database-access layer of the [Effect][repo] ecosystem — a
large TypeScript library that models an entire program as a single
`Effect<A, E, R>` value (a description of work that yields `A`, may fail with `E`,
and needs environment `R`). The `sql` module answers the question _"how does a
program written in that style talk to a relational database without abandoning the
type-checked error channel, the scoped resource model, or the dependency-injection
context?"_ Its module docstring states the job directly
([`Statement.ts`][statement]):

> _"`SqlClient` uses this module to build executable, parameterized SQL from
> reusable fragments. A statement can be executed, streamed, run without row
> transformation, or compiled to SQL text and parameters for a specific dialect."_

The dialect-agnostic core lives in the main `effect` package under
`src/unstable/sql/`; a thin driver package (`@effect/sql-pg`, `@effect/sql-mysql2`,
…) supplies a `Connection` and a per-dialect `Compiler`. The service the rest of
the program depends on is `SqlClient`, and — the pivotal ergonomic decision — that
service **is** the `sql` tagged-template function
([`SqlClient.ts`][sqlclient]):

> _"`SqlClient` combines the tagged-template statement constructor with connection
> acquisition, dialect compilation, transactions, row transforms, tracing, and
> reactive query helpers. Driver integrations build this service from their
> connection and compiler pieces."_

Concretely, `interface SqlClient extends Constructor` — the injected service is
callable, so `const sql = yield* SqlClient` yields a value you invoke as
`` sql`SELECT …` ``.

### Design philosophy

Three commitments define the library, each grounded in its own source.

**A query is an `Effect`, not a call.** The central type, `Statement<A>`, is
declared to be simultaneously a SQL fragment and an effect
([`Statement.ts`][statement]):

> _"Executable SQL statement that is also a `Fragment` and `Effect`, with helpers
> for raw execution, streaming, value rows, unprepared execution, no-transform
> execution, and compilation."_

That dual nature (`interface Statement<A> extends Fragment, Effect.Effect<…>`) means
the same value can be **interpolated into a larger query** (as a fragment) or
**run** (as an effect) — and running it is lazy: nothing touches the database until
the surrounding `Effect` is executed by the runtime.

**Injection safety is the default, rawness is opt-in.** Interpolated values become
bound parameters automatically; the only way to splice unescaped text is to ask for
it explicitly. The `literal` constructor spells out the contract
([`Statement.ts`][statement]):

> _"Constructs a raw SQL literal segment. The literal text is not escaped, so use
> bound parameters for untrusted values."_

**Failures are structured data, not thrown exceptions.** Every SQL failure is one
`SqlError` wrapping a discriminated `SqlErrorReason`, and every reason knows whether
a retry can help ([`SqlError.ts`][sqlerror]):

> _"`SqlError` wraps the different reasons a SQL operation can fail, such as
> connection, authentication, authorization, syntax, constraint, or transaction
> problems. Each reason keeps the original cause, optional message and operation
> metadata, and whether retrying may succeed."_

---

## Connection, pooling & resource lifetime

The driver-facing contract is `Connection` — it executes **already-compiled** SQL
with positional parameters and never sees a template
([`SqlConnection.ts`][sqlconn]):

```ts
// effect/unstable/sql/SqlConnection.ts
export interface Connection {
  readonly execute: (
    sql: string,
    params: ReadonlyArray<unknown>,
    transformRows:
      | (<A extends object>(row: ReadonlyArray<A>) => ReadonlyArray<A>)
      | undefined,
  ) => Effect<ReadonlyArray<any>, SqlError>;
  readonly executeRaw: (
    sql: string,
    params: ReadonlyArray<unknown>,
  ) => Effect<unknown, SqlError>;
  readonly executeStream: (/* … */) => Stream<any, SqlError>;
  readonly executeValues: (/* … */) => Effect<
    ReadonlyArray<ReadonlyArray<unknown>>,
    SqlError
  >;
  readonly executeUnprepared: (/* … */) => Effect<ReadonlyArray<any>, SqlError>;
}
```

A connection is obtained through a **scoped** [`Acquirer`][concepts-cps] — the
Effect idiom that makes a leaked connection a type error rather than a runtime leak,
because release is tied to a `Scope`:

```ts
// effect/unstable/sql/SqlConnection.ts
export type Acquirer = Effect<Connection, SqlError, Scope>;
```

The `SqlClient` chooses **which** connection a statement runs on with a fiber-local
lookup. `make` builds a `getConnection` effect that prefers an active transaction's
pinned connection and otherwise leases a fresh one from the pool
([`SqlClient.ts`][sqlclient]):

```ts
// effect/unstable/sql/SqlClient.ts — make()
const getConnection = Effect.flatMap(
  Effect.serviceOption(transactionService),
  Option.match({
    onNone: () => options.acquirer, // no active tx: lease from the pool
    onSome: ([conn]) => Effect.succeed(conn), // inside a tx: reuse its pinned connection
  }),
);
```

The Postgres driver realizes the pool with the `pg` package: `PgClient.make` builds
a `Pg.Pool`, validates it with `pool.query("SELECT 1")` inside an
`Effect.acquireRelease` (so `pool.end()` runs on scope close), and derives two
acquirers — a pooled `acquirer` for ordinary statements and a dedicated
`transactionAcquirer` (`reserve`) that pins one `PoolClient` for the length of a
transaction ([`PgClient.ts`][pgclient]). `LISTEN`/`NOTIFY` uses a separate,
reference-counted client via `RcRef.make`. Query cancellation is best-effort:
`makeCancel` fires `SELECT pg_cancel_backend(<pid>)` on interruption.

## Query construction & injection safety

This is the library's core mechanism. The `sql` value is a `Constructor` — a
**callable object** whose call behaviour depends on how you invoke it, with a family
of helper methods hanging off it ([`Statement.ts`][statement]):

```ts
// effect/unstable/sql/Statement.ts (abridged)
export interface Constructor {
  <A extends object = Row>(
    strings: TemplateStringsArray,
    ...args: Array<any>
  ): Statement<A>;
  (value: string): Identifier;

  /** Create unsafe SQL query */
  readonly unsafe: <A extends object>(
    sql: string,
    params?: ReadonlyArray<unknown> | undefined,
  ) => Statement<A>;
  readonly literal: (sql: string) => Fragment;
  readonly in: {
    (value: ReadonlyArray<unknown>): ArrayHelper;
    (column: string, value: ReadonlyArray<unknown>): Fragment;
  };
  readonly insert: {
    (value: ReadonlyArray<Record<string, unknown>>): RecordInsertHelper;
    (value: Record<string, unknown>): RecordInsertHelper;
  };
  readonly update: <A extends Record<string, unknown>>(
    value: A,
    omit?: ReadonlyArray<keyof A>,
  ) => RecordUpdateHelperSingle;
  readonly and: (clauses: ReadonlyArray<string | Fragment>) => Fragment;
  readonly or: (clauses: ReadonlyArray<string | Fragment>) => Fragment;
  readonly csv: {
    (
      values: ReadonlyArray<string | Fragment>,
    ): Fragment; /* … prefixed overload */
  };
  readonly onDialect: <A, B, C, D, E>(options: {
    readonly sqlite: () => A;
    readonly pg: () => B;
    readonly mysql: () => C;
    readonly mssql: () => D;
    readonly clickhouse: () => E;
  }) => A | B | C | D | E;
}
```

The runtime `sql` closure dispatches on its first argument
([`Statement.ts`][statement]): a `TemplateStringsArray` (the ` ``` ` tagged-template
call, detected via `"raw" in strings`) builds a `Statement`; a plain `string`
returns an escaped `Identifier` (so `sql("user_table")` safely quotes a table or
column name); anything else throws `"absurd"`.

**The safety mechanism.** A tagged template is deconstructed by `statement`, which
walks the interpolated arguments and classifies each one. The docstring names the
invariant — _"converting ordinary interpolated values into bound parameters"_ — and
the body is the whole safety story ([`Statement.ts`][statement]):

```ts
// effect/unstable/sql/Statement.ts — statement()
const segments: Array<Segment> =
  strings[0].length > 0 ? [literal(strings[0])] : [];
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (isFragment(arg)) {
    segments.push(...arg.segments); // compose: splice a sub-query's segments
  } else if (isSegment(arg)) {
    segments.push(arg); // a helper (Identifier, ArrayHelper, …)
  } else {
    segments.push(parameter(arg)); // EVERYTHING ELSE becomes a bound Parameter
  }
  if (strings[i + 1].length > 0) {
    segments.push(literal(strings[i + 1]));
  }
}
```

The literal chunks of the template (the parts the author typed) become `Literal`
segments; every `${…}` hole that is not itself a `Fragment` or `Segment` becomes a
`Parameter`. A `Parameter` is _"a bound parameter segment whose value is emitted as
a dialect-specific placeholder and bind value"_ ([`Statement.ts`][statement]) — its
value can never re-enter the SQL text as syntax. So
`` sql`SELECT * FROM users WHERE id = ${userId}` `` produces the text
`SELECT * FROM users WHERE id = $1` and the bind array `[userId]`, regardless of
what `userId` contains. This is the [tagged-template safety model][concepts-qcm]
made mechanical.

**The fragment/segment model.** A `Fragment` is `{ segments: ReadonlyArray<Segment> }`,
and a `Segment` is a tagged union — `Literal` (raw text, optional appended params),
`Identifier` (escaped name), `Parameter` (bound value), the record/array helpers
(`ArrayHelper`, `RecordInsertHelper`, `RecordUpdateHelper`,
`RecordUpdateHelperSingle`), and `Custom` (dialect extensions). Because a
`Statement` **is** a `Fragment`, statements nest into other statements as
first-class values, and the helper combinators compose fragments: `sql.and([…])` /
`sql.or([…])` join clauses with `AND`/`OR` and parenthesize (returning `1=1` for an
empty list); `sql.in(col, values)` builds `col IN (…)` (or the never-matching `1=0`
for an empty array); `sql.insert(rows)` / `sql.update(row, omit)` compile
column/value clauses with a fluent `.returning("*")`.

**Compilation to `[sql, params]`.** A per-dialect `Compiler` renders the fragment
tree ([`Statement.ts`][statement]):

```ts
// effect/unstable/sql/Statement.ts
export interface Compiler {
  readonly dialect: Dialect;
  readonly compile: (
    statement: Fragment,
    withoutTransform: boolean,
  ) => readonly [sql: string, params: ReadonlyArray<unknown>];
  readonly withoutTransform: this;
}
```

`compile` folds over the segments, accumulating a `sql` string and a `binds` array.
The `Parameter` case is where a placeholder is emitted and the value diverted to the
bind list — text and data on separate channels
([`Statement.ts`][statement]):

```ts
// effect/unstable/sql/Statement.ts — CompilerProto.compile (Parameter case)
case "Parameter": {
  sql += placeholder(segment.value)   // e.g. "$1" for pg, "?" for sqlite/mysql
  binds.push(segment.value)
  break
}
case "Identifier": {
  sql += opts.onIdentifier(segment.value, withoutTransform)  // dialect-escaped
  break
}
case "Literal": {
  sql += segment.value                // author-provided text, inserted verbatim
  if (segment.params) binds.push.apply(binds, segment.params as any)
  break
}
```

Placeholders and escaping are the dialect's only real responsibility. Postgres uses
`$n` and double-quoted identifiers ([`PgClient.ts`][pgclient]):

```ts
// @effect/sql-pg — makeCompiler
Statement.makeCompiler<PgCustom>({
  dialect: "pg",
  placeholder(_) { return `$${_}` },   // $1, $2, …
  onIdentifier: /* Statement.defaultEscape('"') — doubles embedded quotes, escapes dots */,
  onRecordUpdate(/* … */) { /* (values …) AS alias(cols) [RETURNING …] */ },
  onCustom(type, placeholder, withoutTransform) { /* PgJson → jsonb param */ }
})
```

SQLite's `makeCompilerSqlite` uses `?` and double-quoted identifiers. A compiled
result is memoized on the statement object (`statementCacheSymbol`), so re-running a
statement does not re-render its SQL. The public escape hatch, exposed on the
compiler as `.compile(withoutTransform?)`, hands back the raw
`readonly [sql: string, params: ReadonlyArray<unknown>]` — useful for logging or
handing SQL to a driver directly.

**Escape hatches.** Two deliberate exits from the safe path: `sql.unsafe(text,
params)` builds a `Statement` from a raw `Literal` (comment: _"Create unsafe SQL
query"_ — [`Statement.ts`][statement]), and `sql.literal(text)` returns a raw,
unescaped `Fragment`. Both re-expose the injection risk the tagged template removes;
the ergonomics of the safe API are why they are rarely needed. `SqlClient` also
exposes `readonly safe: this` (comment: _"Copy of the client for safeql etc."_ —
[`SqlClient.ts`][sqlclient]), a self-alias that static analyzers such as SafeQL can
key on to type-check the SQL text.

**Dialect branches.** `sql.onDialect({ sqlite, pg, mysql, mssql, clickhouse })` and
`sql.onDialectOrElse({ orElse, … })` select a branch by
`compiler.dialect` — the [dialect/idiom][concepts-dialect] axis surfaced as an API
so a single query can carry engine-specific SQL (the migration DDL below leans on
it heavily).

## Schema, migrations & code generation

Effect TS `sql` is **code-agnostic**: it neither owns the database schema
([code-first][concepts-schema]) nor generates typed code from it
([db-first][concepts-schema]). There is **no introspection and no codegen** — no
`jOOQ`/`sqlc`-style step that reads the catalog and emits column constants or row
decoders. That absence is a finding: the type-safety story is carried entirely by
Effect Schema (below), applied to hand-written queries, not by a schema the tool
derives. Row shapes are asserted by the developer (`` sql<MyRow>`…` ``) or validated
at the edges by `SqlSchema`/`SqlModel`.

What it does ship is a **migration runner**, `Migrator` ([`Migrator.ts`][migrator]):

> _"A migrator loads numbered migration effects, records completed ids in a
> migrations table, and runs only pending migrations in a transaction."_

`Migrator.make` ensures a bookkeeping table (default `effect_sql_migrations`) exists
— its DDL branches per dialect through `sql.onDialectOrElse` — then runs the pending
migrations inside `sql.withTransaction(run)`. It takes an `ACCESS EXCLUSIVE` table
lock on Postgres, detects duplicate ids (`MigrationError` kind `"Duplicates"`), and
maps a unique/constraint conflict on the insert to a `"Locked"` error so concurrent
runners degrade gracefully. Migrations are loaded by `fromFileSystem`,
`fromGlob`/`fromBabelGlob`, or `fromRecord`, each parsing `<id>_<name>` filenames
and sorting by id; every migration is itself an `Effect.Effect<…, …, SqlClient>`.

`SqlModel.makeRepository` is the closest thing to schema-derived code: given an
Effect Schema `Model`, it returns `insert`/`update`/`findById`/`delete` operations
(with optional `softDeleteColumn`), each building the SQL from the model's field
names and decoding rows with the model schema. It is a [Repository][concepts-orm]
over a model, not a code generator — the SQL is assembled at runtime from the model,
not emitted to a file.

## Type mapping & result decoding

At the driver seam a row is untyped — `type Row = { readonly [column: string]:
unknown }` ([`SqlConnection.ts`][sqlconn]). Two layers add types back.

**Name transformation.** `Statement.defaultTransforms(fn, nested?)` builds
value/object/row transformers that rename keys — the standard
`snake_case ↔ camelCase` bridge between database and TypeScript
([naming strategy][concepts-dialect]). The compiler applies the query-side
transform to identifiers (`transformQueryNames`), and the client applies the
result-side transform to returned rows (`transformResultNames`); the Postgres driver
wires both from `PgClientConfig`. `Statement.primitiveKind` classifies a value into
one of `PrimitiveKind` (`"string" | "number" | "bigint" | "boolean" | "Date" |
"null" | "Int8Array" | "Uint8Array"`), treating `undefined` as `null`.

**Schema-validated codecs.** `SqlSchema` is _"a small adapter between Effect Schema
and SQL statements"_ ([`SqlSchema.ts`][sqlschema]): each helper _"accepts the
decoded request type used by application code, encodes it before calling `execute`,
and decodes unknown driver rows into the result schema."_ The family covers the
cardinalities — `findAll` (zero or more), `findNonEmpty` (fails
`NoSuchElementError` when empty), `findOne` (first row or `NoSuchElementError`),
`findOneOption` (first row as `Option.some`/`Option.none`), and `void` (discard the
result). Because these lean on Effect Schema codecs (`encodeEffect` /
`decodeUnknownEffect`), [nullability][concepts-tmap] and refinements live in the
schema, and a decode failure surfaces as a `Schema.SchemaError` in the effect's
error channel — parallel to `skunk`'s `Codec` and `Quill`'s
`GenericEncoder`/`GenericDecoder`, but expressed with Effect's general-purpose
schema library rather than a SQL-specific one.

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and where Effect TS `sql`
differs most sharply from the mainstream.

**A statement is a runnable effect.** `Statement<A>` extends both `Fragment` and
`Effect.Effect<ReadonlyArray<A>, SqlError>`, plus a set of alternate
interpretations ([`Statement.ts`][statement]):

```ts
// effect/unstable/sql/Statement.ts
export interface Statement<A>
  extends Fragment, Effect.Effect<ReadonlyArray<A>, SqlError> {
  readonly raw: Effect.Effect<unknown, SqlError>;
  readonly withoutTransform: Effect.Effect<ReadonlyArray<A>, SqlError>;
  readonly stream: Stream.Stream<A, SqlError>;
  readonly values: Effect.Effect<
    ReadonlyArray<ReadonlyArray<unknown>>,
    SqlError
  >;
  readonly unprepared: Effect.Effect<ReadonlyArray<A>, SqlError>;
  readonly compile: (
    withoutTransform?: boolean | undefined,
  ) => readonly [sql: string, params: ReadonlyArray<unknown>];
}
```

The effect behaviour comes from `Effectable.Prototype`, whose `evaluate(fiber)` runs
when the fiber executes the statement: it opens a `sql.execute` tracing span,
acquires a connection (through `getConnection`), compiles the fragment, and calls
`connection.execute(sql, params, transformRows)`. The variants reinterpret the same
fragment — `.stream` yields a `Stream` (server-side cursor, incremental rows),
`.values` returns positional row arrays, `.raw` returns the untouched driver result,
`.unprepared` skips prepared-statement caching, and `.withoutTransform` skips the
row-name transform. A statement is therefore a **description**: composing it (in
`Effect.gen`, `pipe`, `Effect.forEach`, …) is pure; the database is touched only
when the runtime interprets the enclosing effect.

**Transactions with fiber-local pinning and savepoints.** `sql.withTransaction`
wraps a block so every query inside runs on one connection, atomically. The builder
([`SqlClient.ts`][sqlclient]):

> _"Builds a transaction wrapper that begins top-level transactions, uses savepoints
> for nested transactions, commits on success, and rolls back on failure or
> interruption."_

The mechanism is a `TransactionConnection` service — _"phantom identifier for the
scoped transaction connection service"_ holding `readonly [conn: Connection, depth:
number]` — stored in the fiber context. `makeWithTransaction` reads it to decide
top-level versus nested ([`SqlClient.ts`][sqlclient]):

```ts
// effect/unstable/sql/SqlClient.ts — makeWithTransaction (abridged)
const connOption = Context.getOption(services, options.transactionService);
const conn =
  connOption._tag === 'Some'
    ? Effect.succeed([undefined, connOption.value[0]] as const) // nested: reuse the pinned conn
    : options.acquireConnection; // top-level: reserve a new conn
const id = connOption._tag === 'Some' ? connOption.value[1] + 1 : 0;
return Effect.flatMap(conn, ([scope, conn]) =>
  (id === 0 ? options.begin(conn) : options.savepoint(conn, id)).pipe(
    Effect.flatMap(() =>
      Effect.provideContext(
        restore(effect), // run the body with the conn in context
        Context.mutate(services, s =>
          s.pipe(
            Context.add(options.transactionService, [conn, id]), // depth-tracked, so inner tx nests
            Context.add(Tracer.ParentSpan, span),
          ),
        ),
      ),
    ),
    Effect.exit,
    Effect.flatMap(exit => {
      let effect: Effect.Effect<void>;
      if (Exit.isSuccess(exit)) {
        effect = id === 0 ? Effect.orDie(options.commit(conn)) : Effect.void; // outer COMMIT; inner: keep savepoint
      } else {
        effect = Effect.orDie(
          id > 0
            ? options.rollbackSavepoint(conn, id) // inner: ROLLBACK TO SAVEPOINT
            : options.rollback(conn),
        ); // outer: ROLLBACK
      }
      /* … close the reserved scope, then re-raise the exit … */
    }),
  ),
);
```

Depth `0` issues `BEGIN` … `COMMIT`/`ROLLBACK`; a nested `withTransaction` (depth
`> 0`) issues a [savepoint][concepts-eth] instead — the defaults are
`SAVEPOINT effect_sql_<id>` and `ROLLBACK TO SAVEPOINT effect_sql_<id>`
([`SqlClient.ts`][sqlclient]). Because the pinned connection is added to the fiber
context, the `getConnection` lookup shown earlier routes every statement in the body
onto it; the whole thing runs under `Effect.uninterruptibleMask`, so an interruption
still rolls back. The dialect DDL is overridable (`beginTransaction`, `commit`,
`savepoint`, …) via `SqlClient.MakeOptions`.

**Typed errors with a retryability flag.** Every failure is a `SqlError` over an
11-case `SqlErrorReason` union — `ConnectionError`, `AuthenticationError`,
`AuthorizationError`, `SqlSyntaxError`, `UniqueViolation`, `ConstraintError`,
`DeadlockError`, `SerializationError`, `LockTimeoutError`, `StatementTimeoutError`,
`UnknownError`. Each reason is a `Schema.TaggedErrorClass` with an `isRetryable`
getter, and `SqlError` delegates to it ([`SqlError.ts`][sqlerror]):

```ts
// effect/unstable/sql/SqlError.ts
export class SqlError extends Schema.TaggedErrorClass<SqlError>(
  'effect/sql/SqlError',
)('SqlError', {
  reason: SqlErrorReason,
}) {
  override readonly cause = this.reason;
  override get message(): string {
    return this.reason.message || this.reason._tag;
  }
  get isRetryable(): boolean {
    return this.reason.isRetryable;
  }
}
```

Retryable reasons are the transient ones — `ConnectionError`, `DeadlockError`,
`SerializationError`, `LockTimeoutError`, `StatementTimeoutError` return `true`; the
programming/authorization errors return `false`. That flag is exactly what a
[`SERIALIZABLE`][concepts-eth] retry loop keys on: a caller can `Effect.retry` while
`error.isRetryable`. Because `SqlError` is in the effect's `E` channel, it is
recovered structurally with `Effect.catchTag`/`catchTags`, never `try`/`catch`.

**SQLSTATE classification.** The driver turns native error codes into reasons. The
Postgres `classifyError` reads `cause.code` (SQLSTATE) and maps by prefix and exact
value ([`PgClient.ts`][pgclient]):

```ts
// @effect/sql-pg — classifyError (abridged)
if (code.startsWith('08')) return new ConnectionError(props); // connection exception
if (code.startsWith('28')) return new AuthenticationError(props); // invalid authorization
if (code === '42501') return new AuthorizationError(props); // insufficient privilege
if (code.startsWith('42')) return new SqlSyntaxError(props); // syntax / access rule
if (code === '23505')
  return new UniqueViolation({
    ...props,
    constraint: pgConstraintFromCause(cause),
  });
if (code.startsWith('23')) return new ConstraintError(props); // integrity constraint
if (code === '40P01') return new DeadlockError(props); // deadlock detected
if (code === '40001') return new SerializationError(props); // serialization failure
if (code === '55P03') return new LockTimeoutError(props); // lock not available
if (code === '57014') return new StatementTimeoutError(props); // query canceled
return new UnknownError(props);
```

`SqlError.ts` ships a parallel `classifySqliteError` (keyed on `SQLITE_*` codes and
`errno`), and the consolidation of every driver onto this reason shape was a
deliberate, recent change ([`.changeset/consolidate-sql-error.md`][changeset]):
_"Consolidate the SqlError changes to the new reason-based shape across effect and
the SQL drivers, classifying native failures into structured reasons with Unknown
fallback where native codes are unavailable."_

**Batching against the [N+1 problem][concepts-n1].** `SqlResolver` provides
DataLoader-style resolvers — `ordered`, `grouped`, `findById`, `void` — that
_"batch concurrent requests into SQL operations"_ and, crucially, _"keep batches
separated by the active SQL transaction connection"_ ([`SqlResolver.ts`][resolver]).
Each request's payload is encoded with a request schema, one `WHERE id IN (…)`-style
`execute` runs the batch, and returned rows are decoded and matched back to
requests; a length mismatch fails with `ResultLengthMismatch`. The
transaction-connection keying (`transactionKey` returns
`Equal.byReferenceUnsafe(conn)`) ensures a batch never coalesces requests from
different transactions onto the wrong connection.

**Streaming.** `Statement.stream` and `Connection.executeStream` turn a
[cursor][concepts-cps] into a `Stream`; `SqlStream.asyncPauseResume` adapts a
push-based driver source with backpressure (pausing the producer when the internal
queue fills). The Postgres driver implements it with `pg-cursor`, reading 128 rows
at a time.

## Ecosystem & maturity

Effect TS `sql` is **MIT**-licensed (`Copyright (c) 2023 Effectful Technologies
Inc` — [`LICENSE`][license]) and developed by Effectful Technologies alongside the
rest of Effect. In the `effect-smol` rewrite the SQL core was **moved into the main
`effect` package** under `src/unstable/sql`, so it ships with `effect` itself
(pinned here at `effect@4.0.0-beta.96`) rather than as a separate `@effect/sql`
package; the drivers remain separate (`@effect/sql-pg`, `@effect/sql-mysql2`, …).

The **classic lineage** is the `Effect-TS/effect` monorepo, where `@effect/sql` is
the standalone package and the driver set is larger — including the two adapter
packages `@effect/sql-drizzle` (_"An `@effect/sql` implementation for Drizzle"_) and
`@effect/sql-kysely` (_"An `@effect/sql` implementation for Kysely"_) that bridge the
Effect effect/error model onto those popular query builders
([`sql-drizzle/README.md`][drizzle], [`sql-kysely/README.md`][kysely]). Backend
coverage across the driver directory is broad: Postgres (`pg`, PGlite), MySQL
(`mysql2`), MSSQL, ClickHouse, libSQL, and SQLite in six host flavours (node, Bun,
WASM, React Native, Cloudflare D1, Durable Objects). The `-smol` status is
pre-release (`beta`), so APIs under `unstable/` are explicitly subject to change;
the classic `@effect/sql` is the production-stable line.

## Strengths

- **Injection-safe by default.** Every non-fragment interpolation becomes a bound
  `Parameter`; rawness (`sql.unsafe` / `sql.literal`) is an explicit, greppable
  opt-out.
- **Queries are values.** A `Statement` is both a composable `Fragment` and a lazy
  `Effect` — it nests into larger queries and defers all I/O to the runtime.
- **Typed, structured errors.** One `SqlError` over an 11-case reason union, each
  with `isRetryable`, recovered with `Effect.catchTag` instead of exceptions —
  ideal for [`SERIALIZABLE`][concepts-eth] retry loops.
- **Correct transaction nesting.** Fiber-local connection pinning plus automatic
  `SAVEPOINT`s give real nested transactions with commit/rollback-on-interruption,
  not a flat `BEGIN`/`COMMIT`.
- **Dialect-agnostic core.** The compiler abstracts placeholders/escaping across
  five dialects; `sql.onDialect` surfaces engine differences without forking the
  query.
- **First-class N+1 mitigation.** `SqlResolver` batches keyed by transaction
  connection; `SqlSchema`/`SqlModel` add schema-validated encode/decode and
  repositories.
- **Observability built in.** Every execution opens an OpenTelemetry span with
  `db.query.text`/`db.operation.name` attributes.

## Weaknesses

- **All-in on Effect.** The library is unusable outside the Effect runtime — you
  buy the entire fibers/context/schema stack to get the `sql` layer; there is no
  plain-`Promise` façade.
- **No compile-time SQL verification.** Row types are developer-asserted
  (`` sql<Row>`…` ``); nothing checks the SQL text against a real schema without an
  external tool (SafeQL, via the `safe` alias). Contrast `sqlx`/`sqlc`.
- **No codegen or introspection.** Unlike `jOOQ`/`sqlc`, it neither reads the
  catalog nor emits typed code; type safety rides entirely on hand-written Effect
  Schema.
- **Not a full ORM.** No identity map, unit of work, change tracking, or lazy
  relations — deliberate, but a gap if you want `Hibernate`/`Prisma` ergonomics.
- **Pre-release core.** The `effect-smol` SQL lives under `unstable/` at `beta`;
  the API can shift until it stabilizes.
- **Conceptual weight.** Understanding a query requires understanding effects,
  fibers, scopes, context services, and schema — a steep on-ramp versus a
  `postgres.js` tagged template.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                                      | Trade-off                                                                                              |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `Statement<A>` **is** a `Fragment` **and** an `Effect`                | Queries compose as data and run lazily as effects — one type, no separate "runner"             | Ties the whole library to the Effect runtime; unusable from plain `async`/`await` code                 |
| Tagged template auto-binds every non-fragment interpolation           | Injection safety is the path of least resistance; rawness must be spelled `unsafe`/`literal`   | The template author can't accidentally splice text, but must learn fragment vs parameter distinctions  |
| Failures as one `SqlError` over an 11-reason union with `isRetryable` | Structured, exhaustively-matchable errors in the typed `E` channel; retry logic is data-driven | Drivers must classify native codes (SQLSTATE/errno); unclassified failures fall back to `UnknownError` |
| Transactions via fiber-local `TransactionConnection` + savepoints     | Real nesting and interruption-safe rollback without threading a handle through every call      | Relies on Effect's context/fiber machinery; the pinned-connection routing is implicit, not visible     |
| Dialect-agnostic core + thin per-driver `Compiler`/`Connection`       | One query API across Postgres/MySQL/SQLite/MSSQL/ClickHouse; `sql.onDialect` for differences   | The core cannot know engine-specific types/features; drivers carry the real behaviour and edge cases   |
| No codegen/introspection; type safety via Effect Schema at the edges  | Stays a data mapper, not an ORM; reuses the general-purpose schema library                     | No compile-time column/nullability checks against a live schema; row types are asserted, not derived   |
| `SqlResolver` batching keyed by transaction connection                | DataLoader-style N+1 mitigation that never mixes transactions                                  | Extra request/resolver machinery and schema wiring compared to writing the join by hand                |

---

## Sources

- [`packages/effect/src/unstable/sql/Statement.ts`][statement] — the tagged-template DSL: `Constructor`, `Fragment`/`Segment` model, `statement` (arg → `Parameter`), `Compiler` producing `[sql, params]`, insert/update helpers, `Statement<A> extends Fragment, Effect`.
- [`packages/effect/src/unstable/sql/SqlClient.ts`][sqlclient] — the `SqlClient` service (`extends Constructor`), `getConnection` routing, `makeWithTransaction` (fiber-local `TransactionConnection` + savepoints), `TransactionConnection`.
- [`packages/effect/src/unstable/sql/SqlConnection.ts`][sqlconn] — the driver `Connection` interface, scoped `Acquirer`, `Row`.
- [`packages/effect/src/unstable/sql/SqlError.ts`][sqlerror] — `SqlError` (`Schema.TaggedErrorClass`), the 11-case `SqlErrorReason` union, `isRetryable`, `classifySqliteError`.
- [`packages/effect/src/unstable/sql/SqlResolver.ts`][resolver] — DataLoader-style batching keyed by the active transaction connection.
- [`packages/effect/src/unstable/sql/SqlSchema.ts`][sqlschema] · [`SqlModel.ts`][sqlmodel] — Effect Schema encode/decode; `makeRepository`.
- [`packages/effect/src/unstable/sql/Migrator.ts`][migrator] · [`SqlStream.ts`][sqlstream] — migration runner (each migration in `sql.withTransaction`); streaming interop.
- [`packages/sql/pg/src/PgClient.ts`][pgclient] — `PgClient extends SqlClient`; `layer`/`layerConfig`; `makeCompiler` with `$n`; `classifyError` (SQLSTATE → reason).
- [`LICENSE`][license] · [`.changeset/consolidate-sql-error.md`][changeset] — MIT; the reason-based `SqlError` consolidation.
- [Effect-TS/effect (classic monorepo)][repo-classic] — `@effect/sql` lineage plus the [`sql-drizzle`][drizzle] / [`sql-kysely`][kysely] adapters.
- Shared vocabulary: [`concepts.md`][concepts] — [abstraction ladder][concepts-ladder], [query-construction models][concepts-qcm], [effects/transactions/errors][concepts-eth], [the N+1 problem][concepts-n1].

<!-- References -->

[repo]: https://github.com/Effect-TS/effect-smol
[repo-classic]: https://github.com/Effect-TS/effect
[docs]: https://effect.website
[statement]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/Statement.ts
[sqlclient]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/SqlClient.ts
[sqlconn]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/SqlConnection.ts
[sqlerror]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/SqlError.ts
[resolver]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/SqlResolver.ts
[sqlschema]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/SqlSchema.ts
[sqlmodel]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/SqlModel.ts
[migrator]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/Migrator.ts
[sqlstream]: https://github.com/Effect-TS/effect-smol/blob/main/packages/effect/src/unstable/sql/SqlStream.ts
[pgclient]: https://github.com/Effect-TS/effect-smol/blob/main/packages/sql/pg/src/PgClient.ts
[license]: https://github.com/Effect-TS/effect-smol/blob/main/LICENSE
[changeset]: https://github.com/Effect-TS/effect-smol/blob/main/.changeset/consolidate-sql-error.md
[drizzle]: https://github.com/Effect-TS/effect/blob/main/packages/sql-drizzle/README.md
[kysely]: https://github.com/Effect-TS/effect/blob/main/packages/sql-kysely/README.md
[concepts]: ./concepts.md
[concepts-ladder]: ./concepts.md#the-abstraction-ladder
[concepts-qcm]: ./concepts.md#query-construction-models
[concepts-eth]: ./concepts.md#effects-transactions-and-error-handling
[concepts-cps]: ./concepts.md#connections-pools-and-sessions
[concepts-n1]: ./concepts.md#loading-strategies-and-the-n1-problem
[concepts-dialect]: ./concepts.md#dialects-idioms-and-naming-strategies
[concepts-schema]: ./concepts.md#schema-migrations-code-generation
[concepts-tmap]: ./concepts.md#type-mapping-and-result-decoding
[concepts-orm]: ./concepts.md#orm-patterns

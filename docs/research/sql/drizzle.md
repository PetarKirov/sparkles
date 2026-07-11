# Drizzle ORM (TypeScript)

A "headless" TypeScript query builder / light ORM whose core API is deliberately shaped like SQL — `db.select().from(users).where(eq(users.id, 1))` — with the schema declared in TypeScript (code-first) and full type inference from those schema objects; every query, however it is built, lowers to one injection-safe `` sql`…` `` tagged-template AST.

| Field              | Value                                                                                                                                                             |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | TypeScript (usable as a plain JS library; "shines with TypeScript")                                                                                               |
| License            | Apache-2.0 — [`LICENSE`][license]                                                                                                                                 |
| Repository         | [drizzle-team/drizzle-orm][repo]                                                                                                                                  |
| Documentation      | [orm.drizzle.team][docs] · in-repo per-dialect READMEs ([`sqlite-core/README.md`][sqlitereadme])                                                                  |
| Category           | [Typed query builder][ladder] / light ORM — code-first schema; a relational-query layer sits atop the SQL-like core, but there is no identity map or unit of work |
| Abstraction level  | Above a [driver][ladder], below a [full ORM][ladder] — a typed builder shading into a [functional data mapper][ladder] via the relational-query API               |
| Query model        | [Fluent SQL-like builder][qmodels] + a higher-level relational-query API — **both** lower to a `` sql`…` `` [tagged-template][qmodels] AST                        |
| Effect/async model | Async (Promises) — query objects are lazily-`await`ed `PromiseLike` values, not effect descriptions; the SQLite sync drivers are blocking                         |
| Backends           | PostgreSQL, MySQL, SQLite — "every" one of each, including serverless HTTP drivers (Neon, Turso, PlanetScale, D1, Vercel, Xata, AWS Data API)                     |
| First release      | ≈2022 (web-attested)                                                                                                                                              |
| Latest version     | `drizzle-orm` `0.45.3` + `drizzle-kit` `0.31.10` (pinned checkout; web-attested for "latest")                                                                     |

> [!NOTE]
> Drizzle is this survey's data point for the **code-first TypeScript query builder** that
> also _owns_ the schema. On the [construction axis][qmodels] it is a fluent SQL-like
> builder like `Kysely`, `jOOQ`, or `Diesel`; the distinguishing move is that the schema is
> declared **in TypeScript** and is the source of truth for both type inference and
> `drizzle-kit`-generated migrations. That places it between the type-only `Kysely` (which
> owns no schema) and the schema-file `Prisma` (a `.prisma` DSL + generated client). It
> stops **below** the full-ORM rung: there is no identity map, no change tracking, no unit
> of work. Compare with the effect-typed `Effect TS sql` layer and `Quill` on the
> effect/error axis this survey weights most; shared terms are defined once in
> [concepts][concepts] and the family map lives in the [survey index][index].

---

## Overview

### What it solves

Drizzle occupies the gap between a raw driver (you write SQL strings and read `unknown`
rows) and a full ORM (you mutate objects and a unit of work writes them back). Its thesis
is that the query language is already good — you should write something that _is_ SQL, but
typed. The tagline, verbatim in the repo ([`sqlite-core/README.md`][sqlitereadme]):

> _"If you know SQL, you know Drizzle ORM"_

The top-level README frames the whole library as a thin, dependency-free layer that you
reach through two typed query surfaces ([`README.md`][readme]):

> _"While Drizzle ORM remains a thin typed layer on top of SQL, we made a set of tools for
> people to have best possible developer experience."_

and, on what those surfaces are ([`README.md`][readme]):

> _"It lets you **declare SQL schemas** and build both **relational** and **SQL-like
> queries**, while keeping the balance between type-safety and extensibility for toolmakers
> to build on top."_

So there are two query APIs over one schema: the **SQL-like core builder**
(`db.select().from(...).where(...)`) and a higher-level **relational-queries** API
(`db.query.users.findMany({ with: { posts: true } })`). Both are covered below; the core
builder is the substrate the relational API compiles down to.

### Design philosophy

Three commitments define Drizzle, each stated in its own documentation.

**Headless and dependency-free.** Drizzle is a library, not a framework or a data proxy;
it ships no runtime it must own. The README's masthead is literally _"Headless ORM for
NodeJS, TypeScript and JavaScript"_ ([`README.md`][readme]), and the size claim is a
selling point ([`README.md`][readme]):

> _"It is lightweight at only ~7.4kb minified+gzipped, and it's tree shakeable with exactly
> 0 dependencies."_

The zero-dependency claim is verifiable in the package manifest: `drizzle-orm`'s
`dependencies` object is empty `{}`, and its 29 database drivers are all _optional_
`peerDependencies` ([`drizzle-orm/package.json`][pkg]). Nothing is pulled in unless you
import the dialect module for the driver you use.

**Driver-agnostic and serverless-ready.** The same query API rides over dozens of drivers,
including HTTP-based serverless ones, with no adapters ([`README.md`][readme]):

> _"**Drizzle supports every PostgreSQL, MySQL and SQLite database**, including serverless
> ones … No bells and whistles, no Rust binaries, no serverless adapters, everything just
> works out of the box."_

> _"**Drizzle is serverless-ready by design**. It works in every major JavaScript runtime
> like NodeJS, Bun, Deno, Cloudflare Workers, Supabase functions, any Edge runtime, and
> even in browsers."_

The consequence for this survey: Drizzle is a _portable client_ — its dialect object emits
SQL text + a bound-parameter array, and a per-driver `session` hands that to whatever
client library is on hand (see [Effect model](#effect-model-transactions-error-handling)).

**Code-first: the TypeScript schema is the source of truth.** You declare tables in
TypeScript, and that declaration is simultaneously the type source _and_ the migration
input ([`sqlite-core/README.md`][sqlitereadme]):

> _"With `drizzle-orm` you declare SQL schema in TypeScript."_

The migration toolchain is a separate CLI, and the README states its two modes precisely
([`README.md`][readme]):

> _"Drizzle comes with a powerful **Drizzle Kit** CLI companion for you to have hassle-free
> migrations. It can generate SQL migration files for you or apply schema changes directly
> to the database."_

---

## Connection, pooling & resource lifetime

Drizzle does **not** manage connections or a pool itself — it wraps a client you construct.
Each dialect exposes a `drizzle(client, options?)` constructor that adopts an existing
driver instance ([`sqlite-core/README.md`][sqlitereadme]):

```ts
import { drizzle } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';

const sqlite = new Database('sqlite.db');
const db = drizzle(sqlite); // db is a wrapper over your client
```

`PgDatabase` (and its siblings) hold only a `dialect` (the SQL compiler) and a `session`
(the per-driver execution seam); pooling, TLS, and reconnection belong to the underlying
client — `pg.Pool`, `postgres.js`, a Neon HTTP fetcher, etc.
([`pg-core/db.ts`][pgdb]). For a pool, the driver's own pool is used: in the node-postgres
transaction path Drizzle calls `this.client.connect()` to lease a `PoolClient` for the
transaction's duration and `release()`s it in a `finally`
([`node-postgres/session.ts`][npgsession]). This is a deliberate non-ownership stance —
contrast the effect-system libraries that model pool acquisition as a
[scoped acquire/release resource][pools] so a leaked connection is a type error. In Drizzle
the leased-connection lifetime is a plain `try/finally`, and outside a transaction the
client's own pool decides everything.

There is a **read-replica** helper: `withReplicas(primary, [replica, …])` returns a
db-shaped object that routes `select`/`selectDistinct`/`$count`/`with` to a replica and all
writes + `transaction`/`execute` to the primary ([`pg-core/db.ts`][pgdb]).

---

## Query construction & injection safety

This is the heart of Drizzle. **Every** query — the fluent builder, each operator, the
relational API — is ultimately a value of one class, `SQL`, assembled by one tagged-template
function, `` sql`…` ``. Understanding that class is understanding the whole safety story.

### The `sql` tagged template and the `Param` model

The `sql` function is a tagged template that interleaves the literal string fragments with
the interpolated values, wrapping the literals in `StringChunk` and pushing the values as
raw chunks ([`sql/sql.ts`][sqlfile]):

```ts
// drizzle-orm/src/sql/sql.ts
export function sql(strings: TemplateStringsArray, ...params: SQLChunk[]): SQL {
  const queryChunks: SQLChunk[] = [];
  if (params.length > 0 || (strings.length > 0 && strings[0] !== '')) {
    queryChunks.push(new StringChunk(strings[0]!));
  }
  for (const [paramIndex, param] of params.entries()) {
    queryChunks.push(param, new StringChunk(strings[paramIndex + 1]!));
  }
  return new SQL(queryChunks);
}
```

An `SQL` is just a list of chunks; a `Chunk` is a string, a `Table`, a `Column`, a `Name`
(escaped identifier), a `Param`, a `Placeholder`, or a nested `SQL`. Rendering happens in
`buildQueryFromSourceParams`, which walks the chunks and produces `{ sql, params }`. A
literal `StringChunk` contributes text with no params; an identifier `Name` is
double-quote-escaped; but **any interpolated data value** that is not one of the structural
chunk types falls through to the parameter path ([`sql/sql.ts`][sqlfile]):

```ts
// drizzle-orm/src/sql/sql.ts — the default arm of buildQueryFromSourceParams
return {
  sql: escapeParam(paramStartIndex.value++, chunk),
  params: [chunk],
  typings: ['none'],
};
```

`escapeParam` is the dialect's placeholder generator: PostgreSQL emits `$1`, `$2`, …
(``escapeParam(num) { return `$${num + 1}`; }``, [`pg-core/dialect.ts`][pgdialect]), while
MySQL and SQLite emit `?`. The value itself never enters the SQL string — it goes into the
`params` array that the driver binds out-of-band. That is [parameter binding][injection],
not interpolation, and it is the default for every interpolated value. The `Param` class
formalizes it — a value optionally paired with an encoder ([`sql/sql.ts`][sqlfile]):

```ts
// drizzle-orm/src/sql/sql.ts
/** Parameter value that is optionally bound to an encoder (for example, a column). */
export class Param<
  TDataType = unknown,
  TDriverParamType = TDataType,
> implements SQLWrapper {
  constructor(
    readonly value: TDataType,
    readonly encoder: DriverValueEncoder<
      TDataType,
      TDriverParamType
    > = noopEncoder,
  ) {}
}
```

When a `Param` is rendered, its `encoder.mapToDriverValue(value)` converts the host value to
the driver representation _before_ it is bound, and the placeholder is still emitted
([`sql/sql.ts`][sqlfile]). So the safety property is structural: a value can reach the
database only as a bound parameter, and the only way to inject text is to reach for an
explicit escape hatch (below).

### The fluent builder is `sql` in disguise

`db.select()/insert()/update()/delete()` return builders whose clause methods
(`.from`, `.where`, `.groupBy`, `.innerJoin`, `.orderBy`, `.limit`) accumulate a config
that the dialect renders ([`pg-core/db.ts`][pgdb], [`pg-core/query-builders/select.ts`][select]).
The _predicates_, though, are plain functions that build `SQL`. `eq`, `ne`, `gt`, `and`,
`or` are one-liners over `` sql`…` `` ([`sql/expressions/conditions.ts`][conditions]):

```ts
// drizzle-orm/src/sql/expressions/conditions.ts
export const eq: BinaryOperator = (left: SQLWrapper, right: unknown): SQL => {
  return sql`${left} = ${bindIfParam(right, left)}`;
};
export const gt: BinaryOperator = (left: SQLWrapper, right: unknown): SQL => {
  return sql`${left} > ${bindIfParam(right, left)}`;
};
```

`bindIfParam` is the bridge from a builder to the `Param` model: if the right-hand value is
a bare data value (not already an `SQLWrapper`/`Column`/`Param`/…), it is wrapped in a
`Param` carrying the _left column as its encoder_, so the value is bound and typed by the
column it is compared against ([`sql/expressions/conditions.ts`][conditions]):

```ts
// drizzle-orm/src/sql/expressions/conditions.ts
export function bindIfParam(value: unknown, column: SQLWrapper): SQLChunk {
  if (
    isDriverValueEncoder(column) &&
    !isSQLWrapper(value) &&
    !is(value, Param) /* …*/
  ) {
    return new Param(value, column);
  }
  return value as SQLChunk;
}
```

So `db.select().from(cars).where(eq(cars.id, 1))` produces `… where "cars"."id" = $1` with
`params: [1]` — the `1` never touches the string. The core builder therefore inherits the
`sql` template's injection-safety for free. A convenience: `and(...)`/`or(...)`
automatically drop `undefined` conditions, so optional filters compose without branching —
_"Conditions that are equal `undefined` are automatically ignored"_
([`sql/expressions/conditions.ts`][conditions]).

Everything Drizzle passes around implements one interface, `SQLWrapper`
([`sql/sql.ts`][sqlfile]):

```ts
// drizzle-orm/src/sql/sql.ts
export interface SQLWrapper {
  getSQL(): SQL;
  shouldOmitSQLParens?(): boolean;
}
```

`Table`, `Column`, `View`, `Subquery`, `SQL`, `Placeholder`, and `Param` all implement it,
which is why a column, a subquery, or a whole sub-`SQL` can be interpolated into a
`` sql`…` `` template and be rendered correctly (escaped identifier, parenthesized subquery,
etc.) rather than bound as data.

### Escape hatches (and their explicit danger)

Two functions deliberately re-open the injection surface, and Drizzle marks them as such.
`sql.raw(str)` splices a string verbatim with no parameterization
([`sql/sql.ts`][sqlfile]):

```ts
// drizzle-orm/src/sql/sql.ts
/** Convenience function to create an SQL query from a raw string. */
export function raw(str: string): SQL {
  return new SQL([new StringChunk(str)]);
}
```

`sql.identifier(value)` escapes the value as a DB name but offers no injection protection,
and the docstring says so in bold ([`sql/sql.ts`][sqlfile]):

> _"**WARNING: This function does not offer any protection against SQL injections, so you
> must validate any user input beforehand.**"_

`db.execute()` completes the picture: a string argument is routed through `sql.raw`
(unsafe), while an `SQLWrapper` is rendered safely ([`pg-core/db.ts`][pgdb]):

```ts
// drizzle-orm/src/pg-core/db.ts
const sequel = typeof query === 'string' ? sql.raw(query) : query.getSQL();
```

### Prepared statements & placeholders

For plan reuse across executions, `.prepare()` produces a prepared query, and
`sql.placeholder(name)` marks a slot filled at execution time. `fillPlaceholders` swaps the
named `Placeholder` chunks for the supplied values, running them through the bound
`Param`'s encoder — still never string-splicing ([`sql/sql.ts`][sqlfile],
[`sqlite-core/README.md`][sqlitereadme]):

```ts
// drizzle-orm/src/sqlite-core/README.md
const q = db
  .select()
  .from(customers)
  .where(eq(customers.id, placeholder('id')))
  .prepare();
q.get({ id: 10 }); // SELECT * FROM customers WHERE id = 10
q.get({ id: 12 }); // SELECT * FROM customers WHERE id = 12
```

---

## Schema, migrations & code generation

Drizzle is **code-first**: the TypeScript schema objects _are_ the schema, and they drive
both type inference and migration generation.

### Declaring the schema in TypeScript

A table is a call to `pgTable` / `mysqlTable` / `sqliteTable` naming the DB table and a
column map; each column is a builder function (`integer`, `text`, `serial`, `varchar`, …)
that optionally names its DB column and chains modifiers ([`sqlite-core/README.md`][sqlitereadme]):

```ts
// drizzle-orm/src/sqlite-core/README.md
import { sqliteTable, text, integer } from 'drizzle-orm/sqlite-core';

const users = sqliteTable('users', {
  id: integer('id').primaryKey(), // 'id' is the column name
  fullName: text('full_name'),
});
```

`pgTable` is a thin wrapper over `pgTableWithSchema` ([`pg-core/table.ts`][pgtable]):

```ts
// drizzle-orm/src/pg-core/table.ts
export const pgTable: PgTableFn = (name, columns, extraConfig) => {
  return pgTableWithSchema(name, columns, extraConfig, undefined);
};
```

Each column builder knows its SQL type — `PgInteger.getSQLType()` returns `'integer'`
([`pg-core/columns/integer.ts`][integer]) — and modifiers like `.primaryKey()`,
`.notNull()`, `.references(() => users.id)`, `.default(...)` attach column options. Keys,
foreign keys, indexes, checks, unique constraints, and RLS policies are declared in the
table's third argument. Crucially, the schema object is also what the types are inferred
from: `table.$inferSelect` / `table.$inferInsert` (and the `InferSelectModel` /
`InferInsertModel` type helpers) derive the row and insert shapes directly from the column
map ([`table.ts`][coretable]), so a query's result type is computed from the schema with no
codegen step at runtime.

### `drizzle-kit`: SQL migration generation & introspection

Schema _evolution_ lives in a separate CLI package, `drizzle-kit`
([`drizzle-kit/package.json`][kitpkg]), which the README calls the migrations companion. It
compares your TypeScript schema against a stored snapshot and emits SQL. The subcommands
([`drizzle-kit/src/cli/schema.ts`][kitschema]):

| Command               | What it does                                                                 |
| --------------------- | ---------------------------------------------------------------------------- |
| `generate`            | Diff schema → snapshot; write a numbered `.sql` migration file               |
| `migrate`             | Apply pending generated migrations to the database                           |
| `push`                | Apply schema changes **directly** to the DB without a migration file         |
| `introspect` / `pull` | Read a live database and **generate** the TypeScript schema (database-first) |
| `check` / `up`        | Validate / upgrade migration snapshots                                       |
| `studio`              | Launch Drizzle Studio (data browser)                                         |

`generate` describes its input as _"Path to a schema file or folder"_ and its `--custom`
flag prepares an empty migration for hand-written SQL ([`drizzle-kit/src/cli/schema.ts`][kitschema]).
The `introspect`/`pull` command (name `'introspect'`, alias `'pull'`) is the database-first
direction: point it at a live DB and it emits the schema. So Drizzle supports **both**
[schema stances][schemamig] — code-first `generate`, and database-first `introspect`.

The generated files are applied at runtime by an embedded `migrate()` runner per driver,
which reads the migrations folder's `meta/_journal.json` and splits each `.sql` on
`--> statement-breakpoint` markers, hashing each file to record what has been applied
([`migrator.ts`][migrator]). This is a code-first-with-generated-SQL model: unlike a pure
code-first ORM that runs an in-memory model diff, and unlike `Kysely` (which owns no schema
and leaves migrations to hand-written `up`/`down` functions), Drizzle _owns the schema
declaration_ and _materializes real SQL files_ you can review and edit — closer in spirit to
`Prisma`'s generate step, but with the schema written in ordinary TypeScript rather than a
`.prisma` DSL.

---

## Type mapping & result decoding

Column encode/decode is a pair of driver-value functions ([`sql/sql.ts`][sqlfile]):

```ts
// drizzle-orm/src/sql/sql.ts
export interface DriverValueDecoder<TData, TDriverParam> {
  mapFromDriverValue(value: TDriverParam): TData;
}
export interface DriverValueEncoder<TData, TDriverParam> {
  mapToDriverValue(value: TData): TDriverParam | SQL;
}
```

Each column type implements them. `PgInteger.mapFromDriverValue` coerces a driver string to
a number; a column's `mapToDriverValue` is the encoder `bindIfParam` attaches to a `Param`,
so a value is converted on its way into a bind slot ([`pg-core/columns/integer.ts`][integer]).
Raw `sql` expressions decode with `.mapWith(decoder)`, which installs a decoder on the `SQL`
value so a `` sql<number>`count(*)` `` yields a typed result ([`sql/sql.ts`][sqlfile]).

**Nullability is in the inferred type.** `.notNull()` on a column flips its config so that
`$inferSelect` produces `T` rather than `T | null`; the relational layer even threads
column-`notNull` into relation nullability — `createOne` computes `isNullable` by folding
`notNull` across the foreign-key columns ([`relations.ts`][relations]). So an optional
column materializes as `T | null` and a required one as `T`, derived from the schema, in
line with [nullability][typemap] in the concepts page. Result _hydration_ for the SQL-like
builder is positional/named row mapping keyed by the selection object; the relational API
does a richer nested hydration (below).

---

## Effect model, transactions & error handling

This is the axis that most sharply separates Drizzle from the effect-first libraries this
survey centres on.

### Async by Promise, executed on `await`

A Drizzle query is a **lazily-thenable object**, not an eagerly-run call and not an effect
description. Every runnable query extends `QueryPromise<T>`, which _implements_ `Promise<T>`
by running the query only when `.then` is invoked ([`query-promise.ts`][querypromise]):

```ts
// drizzle-orm/src/query-promise.ts
export abstract class QueryPromise<T> implements Promise<T> {
  then<TResult1 = T, TResult2 = never>(
    onFulfilled?,
    onRejected?,
  ): Promise<TResult1 | TResult2> {
    return this.execute().then(onFulfilled, onRejected);
  }
  abstract execute(): Promise<T>;
}
```

So `await db.select().from(users)` builds the query object, and the `await` triggers
`execute()`. This gives a small amount of laziness — an unresolved builder is inert, you can
keep chaining, and `.toSQL()` inspects the `{ sql, params }` without executing — but it is
_not_ the effect-value model of `Effect TS`/`ZIO`/`doobie`, where the query is a first-class
description carrying its error type and required environment. In Drizzle the description is a
`Promise`-shaped object and the error channel is exceptions (below). One wrinkle: the SQLite
sync drivers (`better-sqlite3`, `bun:sqlite`) are **blocking**, exposing `.all()`/`.get()`/
`.run()` methods rather than being awaited, and Drizzle carries a `SQLiteSyncDialect` vs
`SQLiteAsyncDialect` split to model both ([`sqlite-core/README.md`][sqlitereadme]).

### Transactions and savepoints

`db.transaction(callback)` runs a callback with a transaction-scoped `tx` and commits or
rolls back around it ([`pg-core/db.ts`][pgdb]):

```ts
// drizzle-orm/src/pg-core/db.ts
transaction<T>(
    transaction: (tx: PgTransaction<TQueryResult, TFullSchema, TSchema>) => Promise<T>,
    config?: PgTransactionConfig,
): Promise<T> {
    return this.session.transaction(transaction, config);
}
```

The `tx` is itself a full database handle — `PgTransaction` _extends_ `PgDatabase`
([`pg-core/session.ts`][pgsession]) — so inside the callback you use the same
`tx.select()/insert()/update()` API, plus `tx.rollback()`. In the node-postgres driver the
outermost transaction issues `begin` … `commit`, rolling back on any thrown error
([`node-postgres/session.ts`][npgsession]):

```ts
// drizzle-orm/src/node-postgres/session.ts
await tx.execute(
  sql`begin${config ? sql` ${tx.getTransactionConfigSQL(config)}` : undefined}`,
);
try {
  const result = await transaction(tx);
  await tx.execute(sql`commit`);
  return result;
} catch (error) {
  await tx.execute(sql`rollback`);
  throw error;
}
```

**Nested transactions become real [savepoints][savepoint]** — a `nestedIndex` on
`PgTransaction` tracks depth, and a nested `tx.transaction(...)` issues
`SAVEPOINT sp{n}` / `RELEASE SAVEPOINT` / `ROLLBACK TO SAVEPOINT`
([`node-postgres/session.ts`][npgsession]):

```ts
// drizzle-orm/src/node-postgres/session.ts
const savepointName = `sp${this.nestedIndex + 1}`;
await tx.execute(sql.raw(`savepoint ${savepointName}`));
try {
  const result = await transaction(tx);
  await tx.execute(sql.raw(`release savepoint ${savepointName}`));
  return result;
} catch (err) {
  await tx.execute(sql.raw(`rollback to savepoint ${savepointName}`));
  throw err;
}
```

This is a genuine capability the survey's `Slick` data point lacks (Slick's nested
`transactionally` adds no savepoints). Isolation level, access mode, and deferrable are
passed through `PgTransactionConfig` (SQLite uses `deferred`/`immediate`/`exclusive`
behaviors) ([`pg-core/session.ts`][pgsession]). An explicit `tx.rollback()` throws
`TransactionRollbackError`, which the surrounding machinery turns into a `ROLLBACK`
([`pg-core/session.ts`][pgsession], [`errors.ts`][errors]).

### Errors are thrown, not typed

Drizzle's error model is **exceptions**, not a [typed error channel][effects]. The whole
error surface is three `Error` subclasses ([`errors.ts`][errors]):

```ts
// drizzle-orm/src/errors.ts
export class DrizzleError extends Error {
  /* message + cause */
}
export class DrizzleQueryError extends Error {
  constructor(
    public query: string,
    public params: any[],
    public override cause?: Error,
  ) {
    super(`Failed query: ${query}\nparams: ${params}`);
  }
}
export class TransactionRollbackError extends DrizzleError {
  /* 'Rollback' */
}
```

A failed query rejects the `Promise` with a `DrizzleQueryError` carrying the SQL text,
params, and the underlying driver error on `.cause`. There is **no** enumerated failure
union (no retryable/serialization-conflict classification), no error type parameter on the
query, and no `Expected`/`Either`-style result — the failure story is `try/catch` around an
`await`. That is the crisp contrast with `Effect TS` (a single `SqlError` over an 11-case
reason union with an `isRetryable` flag), `Quill`'s ZIO `SQLException` channel, and
`doobie`/`skunk` keeping errors in the effect's error type. For the algebraic-effects-first
design this survey informs, Drizzle is the "great ergonomics, untyped effects" data point.

---

## The relational-queries API

Layered over the SQL-like core is a second, higher-level API for typed eager-loading of
relations in a **single** query. You declare relations with `relations()`, pairing a table
with `one`/`many` helpers ([`relations.ts`][relations]):

```ts
// drizzle-orm/src/relations.ts
export function relations<
  TTableName extends string,
  TRelations extends Record<string, Relation<any>>,
>(
  table: AnyTable<{ name: TTableName }>,
  relations: (helpers: TableRelationsHelpers<TTableName>) => TRelations,
): Relations<TTableName, TRelations> {
  /* … */
}
```

With relations registered on the `db` (via `drizzle(client, { schema })`), `db.query.<table>`
exposes `findMany` / `findFirst` taking a typed config ([`pg-core/query-builders/query.ts`][query]):

```ts
// illustrative — the API shape from RelationalQueryBuilder.findMany + DBQueryConfig
const usersWithPosts = await db.query.users.findMany({
  columns: { id: true, fullName: true }, // partial select
  with: { posts: true }, // eager-load the relation
  where: (users, { eq }) => eq(users.id, 1),
  orderBy: (users, { asc }) => asc(users.id),
  limit: 10,
});
```

The config type `DBQueryConfig` fixes exactly these keys — `columns`, `with`, `extras`,
`where`, `orderBy`, `limit`, `offset` — with `with` recursively taking `true` or a nested
`DBQueryConfig` per relation ([`relations.ts`][relations]). Critically, this compiles to
**one** SQL statement, not N+1: the PostgreSQL dialect's
`buildRelationalQueryWithoutPK` builds the related rows with `lateral` joins and aggregates
them with `json_agg` / `json_build_array` (`coalesce(json_agg(...), '[]')`), so a parent and
its children come back in a single round trip ([`pg-core/dialect.ts`][pgdialect]). This is
the survey's [N+1][nplusone] avoidance done by _compilation_ rather than a runtime batch
loader — the join is explicit in the generated SQL even though it is implicit in the API.

This layer is what pushes Drizzle from "pure query builder" toward "light ORM", but it is
still **stateless**: the results are plain typed objects, there is no identity map making two
loads share an instance, and there is no change tracking — you never mutate a loaded object
and expect a flush. Persistence stays explicit (`db.insert`/`update`/`delete`), which keeps
Drizzle below the full-ORM rung on the [abstraction ladder][ladder] and off the
[unit-of-work / identity-map][ormpatterns] machinery entirely.

---

## Ecosystem & maturity

Drizzle is a young but heavily-adopted library. `drizzle-orm` is at `0.45.3` and
`drizzle-kit` at `0.31.10` in the pinned checkout ([`drizzle-orm/package.json`][pkg],
[`drizzle-kit/package.json`][kitpkg]); both are pre-`1.0` and still evolving (the ORM tree
carries a `compatibilityVersion` counter noting a breaking PostgreSQL-indexes API change).
It is licensed under **Apache-2.0** ([`LICENSE`][license]) — a more permissive, patent-grant
license than most of the survey's query builders. The backend matrix is the three big
open-source engines and their serverless variants: PostgreSQL, MySQL, SQLite, reached
through 29 optional peer-dependency drivers ([`drizzle-orm/package.json`][pkg]) covering
node-postgres, `postgres.js`, Neon (HTTP + serverless), Vercel Postgres, Supabase, PGlite,
`mysql2`, PlanetScale, TiDB, `better-sqlite3`, Bun SQLite, Cloudflare D1, libSQL/Turso,
Expo SQLite, and generic HTTP proxies. The companion tools — `drizzle-kit` (migrations),
Drizzle Studio (browser), and schema-validator generators (`drizzle-zod`, `drizzle-valibot`,
`drizzle-typebox`, `drizzle-arktype`, `drizzle-seed`) — live in the same monorepo. Adoption
(the DB tool most developers "wanna use in their next project" per the README's own link)
and the ≈2022 first-release date are web-attested; they are not tree facts.

---

## Strengths

- **SQL-shaped and low-surprise.** The core builder mirrors SQL clause-for-clause; there is
  little "what SQL will this method emit?" guessing, and `.toSQL()` shows the exact
  `{ sql, params }`.
- **Injection-safe by construction.** Every interpolated value becomes a bound `Param`; the
  only way to splice text is the explicitly-`WARNING`-flagged `sql.raw` / `sql.identifier`.
- **Full type inference from the schema.** `$inferSelect`/`$inferInsert` and per-query
  result types derive from the TypeScript schema objects, with nullability in the type — no
  runtime codegen.
- **Owns the schema _and_ real migrations.** `drizzle-kit generate` emits reviewable SQL
  files; `push` applies directly; `introspect` goes database-first — more batteries than
  `Kysely`, without a separate schema DSL like `Prisma`.
- **Two APIs, one substrate.** The SQL-like builder for control and the relational-queries
  API for typed single-query eager-loading, both lowering to the same `SQL` AST.
- **Headless, zero-dependency, driver-agnostic.** ~7.4kb, `dependencies: {}`, runs over
  dozens of drivers including serverless HTTP ones and in the browser.
- **Real savepoints.** Nested transactions map to `SAVEPOINT`/`ROLLBACK TO SAVEPOINT`.

## Weaknesses

- **No typed error channel.** Failures are thrown `DrizzleQueryError`s; there is no
  enumerated/retryable error set as in `Effect TS`, `doobie`, or `Quill`.
- **Not an effect value.** A query is a lazily-`await`ed `Promise`, so it does not carry its
  error type or required environment; effect-first composition (typed `SqlError`, scoped
  acquirer) is out of scope by design.
- **Non-owning resource lifetime.** Pooling/connection lifetime belongs to the wrapped
  client; a leaked lease is a `try/finally` concern, not a type error.
- **Pre-1.0, moving API.** Version churn (a `compatibilityVersion` counter, a changed
  indexes API) means some tutorials and generated migrations rot across minor bumps.
- **Schema/DB drift is on you.** Code-first with generated SQL still requires running
  `generate` + `migrate` (or `push`); the TS schema and the live DB can diverge if you skip
  a step, and `introspect` output and hand-written schema can differ.
- **`sql.raw` is a foot-gun in reach.** The escape hatch is one call away and, unlike the
  default path, offers no protection — it depends on the author heeding the warning.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                    | Trade-off                                                                                              |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| **One `SQL` AST under everything** (builder, operators, relations) | Uniform injection safety and rendering; the whole API is `` sql`…` `` in disguise            | The builder is only as safe as its inputs; `sql.raw`/`sql.identifier` re-open the surface deliberately |
| **Interpolated values → bound `Param`** by default                 | Structural injection safety; per-column encoders type the value                              | Splicing raw SQL requires an explicit, `WARNING`-marked escape hatch                                   |
| **Code-first schema in TypeScript**                                | One source for both type inference and migrations; no separate DSL like `Prisma`'s `.prisma` | You must run `drizzle-kit generate`/`migrate`; schema and DB can drift                                 |
| **`drizzle-kit` emits reviewable SQL files**                       | Auditable, editable migrations; `push` for fast iteration; `introspect` for database-first   | Separate CLI + snapshot bookkeeping (`meta/_journal.json`, statement-breakpoints)                      |
| **Query = lazily-`await`ed `Promise`, not an effect value**        | Familiar async ergonomics; runs on `await`; works in every JS runtime                        | No typed error channel, no environment/error in the type — not effect-first                            |
| **Relational API compiles to one `json_agg` query**                | Typed eager-loading without N+1; join is explicit in the generated SQL                       | SQL is nontrivial (lateral joins + JSON aggregation); dialect-specific                                 |
| **Stateless results (no identity map / change tracking)**          | Stays a thin, predictable layer; persistence is explicit                                     | No object-graph mutation-and-flush; less "magic" than a full ORM (by design)                           |
| **Headless: wraps a driver, owns no pool**                         | Serverless-ready, zero-dependency, driver-agnostic                                           | Connection/pool lifetime is the client's; no scoped acquire/release resource discipline                |

---

## Sources

- [drizzle-team/drizzle-orm — GitHub repository][repo] · [orm.drizzle.team docs][docs] · [`LICENSE` (Apache-2.0)][license]
- [`README.md` — headless/0-deps/serverless positioning, two query APIs, Drizzle Kit][readme]
- [`drizzle-orm/src/sqlite-core/README.md` — "If you know SQL…", schema declaration, transactions, prepared statements, migrations][sqlitereadme]
- [`drizzle-orm/src/sql/sql.ts` — `sql` tag, `SQL`/`SQLWrapper`/`Param`, `buildQueryFromSourceParams`, `sql.raw`/`sql.identifier`][sqlfile]
- [`drizzle-orm/src/sql/expressions/conditions.ts` — `eq`/`gt`/`and`/`or`, `bindIfParam`][conditions]
- [`drizzle-orm/src/pg-core/db.ts` — `select`/`insert`/`update`/`delete`, `execute`, `transaction`, `withReplicas`][pgdb]
- [`drizzle-orm/src/pg-core/dialect.ts` — `escapeParam` (`$n`), relational `json_agg`/lateral compilation][pgdialect]
- [`drizzle-orm/src/pg-core/table.ts` — `pgTable`][pgtable] · [`…/columns/integer.ts` — `getSQLType`, `mapFromDriverValue`][integer]
- [`drizzle-orm/src/table.ts` — `$inferSelect`/`$inferInsert`, `InferSelectModel`][coretable]
- [`drizzle-orm/src/relations.ts` — `relations()`/`one`/`many`, `DBQueryConfig`][relations] · [`…/pg-core/query-builders/query.ts` — `findMany`/`findFirst`][query]
- [`drizzle-orm/src/query-promise.ts` — `QueryPromise implements Promise<T>`][querypromise] · [`errors.ts` — error classes][errors]
- [`drizzle-orm/src/pg-core/session.ts` — `PgTransaction extends PgDatabase`, `nestedIndex`, `rollback`][pgsession] · [`node-postgres/session.ts` — `begin`/`commit`, `savepoint`][npgsession]
- [`drizzle-orm/src/migrator.ts` — journal + statement-breakpoint runner][migrator] · [`drizzle-kit/src/cli/schema.ts` — `generate`/`migrate`/`push`/`introspect`][kitschema]
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [schema, migrations & codegen][schemamig] · [type mapping & decoding][typemap] · [effects, transactions & errors][effects] · [connections & pools][pools] · [N+1][nplusone] · [ORM patterns][ormpatterns]

<!-- References -->

[repo]: https://github.com/drizzle-team/drizzle-orm
[docs]: https://orm.drizzle.team
[license]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/LICENSE
[readme]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/README.md
[sqlitereadme]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/sqlite-core/README.md
[sqlfile]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/sql/sql.ts
[conditions]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/sql/expressions/conditions.ts
[pgdb]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/pg-core/db.ts
[pgdialect]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/pg-core/dialect.ts
[pgtable]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/pg-core/table.ts
[integer]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/pg-core/columns/integer.ts
[coretable]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/table.ts
[relations]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/relations.ts
[query]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/pg-core/query-builders/query.ts
[select]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/pg-core/query-builders/select.ts
[querypromise]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/query-promise.ts
[errors]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/errors.ts
[pgsession]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/pg-core/session.ts
[npgsession]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/node-postgres/session.ts
[migrator]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/src/migrator.ts
[kitschema]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-kit/src/cli/schema.ts
[kitpkg]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-kit/package.json
[pkg]: https://github.com/drizzle-team/drizzle-orm/blob/9d64532/drizzle-orm/package.json
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[schemamig]: ./concepts.md#schema-migrations-code-generation
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[ormpatterns]: ./concepts.md#orm-patterns
[savepoint]: ./concepts.md#effects-transactions-and-error-handling
[index]: ./index.md

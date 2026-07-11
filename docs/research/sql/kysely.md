# Kysely (TypeScript)

TypeScript's type-safe SQL query builder: you hand it one plain `Database` interface describing your tables and columns, and it gives you an immutable, lazy fluent builder whose autocomplete and type-checking are driven **entirely** by that type — a mistyped column or a type-mismatched comparison is a compile error — with the `sql` template tag as the parameter-safe escape hatch, no ORM, no runtime schema, and no code generation required.

| Field              | Value                                                                                                                           |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| Language           | TypeScript (runs on Node.js, Deno, Bun, Cloudflare Workers, browsers — [`README.md`][readme])                                   |
| License            | MIT, © 2022 Sami Koskimäki ([`LICENSE`][license])                                                                               |
| Repository         | [kysely-org/kysely][repo]                                                                                                       |
| Documentation      | [kysely.dev][docs] · [API docs (typedoc)][apidoc]                                                                               |
| Category           | [Typed query builder][concepts] — type-only, no full-ORM machinery                                                              |
| Abstraction level  | Typed query builder — above a driver, below a full ORM ([ladder][ladder])                                                       |
| Query model        | [Fluent typed builder][qmodels] over a **type-only** schema (a TS `Database` interface; no runtime schema)                      |
| Effect/async model | **Async** — every terminal method returns a `Promise`; not blocking, not an effect value                                        |
| Backends           | PostgreSQL, MySQL, MS SQL Server, SQLite, PGlite (built-in), Postgres.js (org), + a large [community dialect list][dialectsdoc] |
| First release      | ≈2021 (author's launch post archived 2021-12-03; `LICENSE` © 2022) — web-attested                                               |
| Latest version     | `0.29.3` (pinned checkout `package.json`; still pre-1.0) — web/soft                                                             |

> [!NOTE]
> Kysely is this survey's data point for the **type-only** [typed query builder][qmodels]: all
> safety flows from a TypeScript interface **you** supply, which is [erased at runtime][phantom]
> — there is no runtime schema object and no first-party code generation. It sits on the same
> construction rung as `jOOQ`, `Diesel`, and `Drizzle`, but contrast the axes: `Drizzle` is
> schema-object-first (you build a runtime schema value); `jOOQ`/`Diesel` are compiled-language
> builders that generate typed code from a live DB; Kysely asks only for a hand-written (or
> third-party-generated) type. It deliberately stops below the [full-ORM rung][ladder]: no
> identity map, no [change tracking][ormpatterns], no relations.

---

## Overview

### What it solves

Kysely turns SQL construction into a compile-time-checked, autocompleting expression without
adopting an ORM's object graph. Its self-description ([`README.md`][readme]):

> _"Kysely (pronounce "Key-Seh-Lee") is a type-safe and autocompletion-friendly TypeScript SQL
> query builder. Inspired by Knex.js."_

The pitch is that the builder tracks scope precisely and infers the result shape from the query
itself ([`README.md`][readme]):

> _"Kysely makes sure you only refer to tables and columns that are visible to the part of the
> query you're writing. The result type only has the selected columns with correct types and
> aliases. As an added bonus you get autocompletion for all that stuff."_

Everything rests on **one type parameter**. `Kysely<DB>` is parameterized by a `Database`
interface — a plain TypeScript type mapping table names to row interfaces — and the constructor
docstring states the contract exactly ([`src/kysely.ts`][kyselyts]):

> _"@typeParam DB - The database interface type. Keys of this type must be table names in the
> database and values must be interfaces that describe the rows in those tables."_

```ts
// src/kysely.ts — the Database interface is a plain TS type
interface Database {
  person: {
    id: Generated<number>;
    first_name: string;
    last_name: string | null;
  };
}

const db = new Kysely<Database>({
  dialect: new SqliteDialect({ database: new Sqlite(':memory:') }),
});
```

A wrong column name, a type-mismatched comparison, or a reference to a table not in the current
`from`/`join` scope is a **TypeScript compile error** — checked by the type system, never at
runtime against a live database (the trade-off `sqlx` and `sqlc` make differently; see
[Schema, migrations & code generation](#schema-migrations-code-generation)).

### Design philosophy

Kysely is emphatically **not an ORM**, and the docs draw the line with no ambiguity
([`site/docs/recipes/0001-relations.md`][relations]):

> _"Kysely IS NOT an ORM. Kysely DOES NOT have the concept of relations. Kysely IS a query
> builder. Kysely DOES build the SQL you tell it to, nothing more, nothing less."_

The second pillar is that the `Database` type is a **compile-time-only** artifact. The
`$extendTables`/`$omitTables`/`$pickTables` helpers exist purely to reshape the type, and each
carries the same disclaimer ([`src/kysely.ts`][kyselyts]):

> _"This method only modifies the types and doesn't affect any of the executed queries in any
> way."_

So the whole `Database` interface is [type-only schema][phantom]: it drives autocomplete and
type-checking, then vanishes — a JavaScript build strips it, leaving zero runtime schema cost.
The third pillar is pragmatism about the type system's limits ([`site/docs/intro.mdx`][intro]):
_"there are cases where things cannot be typed at compile time, and Kysely offers escape hatches
for these situations"_ — the `sql` template tag and the `DynamicModule` (below).

---

## Connection, pooling & resource lifetime

A `Kysely<DB>` instance is the connection-owning root ([`src/kysely.ts`][kyselyts]):

> _"You should create one instance of `Kysely` per database using the `Kysely` constructor. Each
> `Kysely` instance maintains its own connection pool."_

Pooling itself is **delegated to the underlying vendor driver**, not implemented by Kysely. A
`Dialect` produces a `Driver`, and the `Driver` wraps the third-party client's pool
([`src/dialect/dialect.ts`][dialect], [`site/docs/execution.mdx`][execution]):

> _"The `Driver`'s job is to abstract away vendor-specific details. It communicates with the
> actual third-party `DatabaseDriver` — for example, the `pg` or `mysql2` npm package — to get a
> connection from its pool."_

`PostgresDriver` holds a `pg` `Pool` and calls `pool.connect()` on `acquireConnection`, `pool.end()`
on `destroy` ([`src/dialect/postgres/postgres-driver.ts`][pgdriver]). Resource lifetime is
**imperative**: you call `await db.destroy()` when finished (it drives `driver.destroy()`), and
`Kysely` also implements `AsyncDisposable` (`Symbol.asyncDispose` → `destroy`) so an
`await using` block cleans up. `db.connection().execute(cb)` binds a callback to a single leased
connection ([`src/kysely.ts`][kyselyts]). This is the counterpoint to the effect systems in this
survey: where [Slick][slickpage]/[Effect TS][effect-ts] model the pool as a
[scoped acquire/release resource][pools] (a leak is a type error), Kysely leaves lifetime to a
`try`/`finally`, `destroy()`, or the disposable protocol.

---

## Query construction & injection safety

The builder mirrors SQL clause-for-clause — `selectFrom`, `select`, `where`, `innerJoin`,
`groupBy`, `having` — off the `QueryCreator<DB>` / `SelectQueryBuilder<DB, TB, O>` chain, all typed
against `DB` ([`src/query-creator.ts`][querycreator], [`src/query-builder/select-query-builder.ts`][sqb]):

```ts
// a fully type-checked query; every string is validated against `Database`
const persons = await db
  .selectFrom('person')
  .innerJoin('pet', 'pet.owner_id', 'person.id')
  .select(['person.id', 'first_name', 'pet.name as pet_name'])
  .where('age', '>', 40)
  .groupBy('person.id')
  .execute();
// result row type is inferred: { id: number; first_name: string; pet_name: string }
```

**The builder is immutable and lazy.** Each method returns a _new_ builder wrapping an updated,
frozen operation-node tree; nothing touches the database until a terminal method runs
([`site/docs/execution.mdx`][execution]):

> _"Each call returns a \_new_ `QueryBuilder` instance containing an updated, immutable `QueryAST`
> (Abstract Syntax Tree), which is the internal representation of your SQL query."\_

Concretely, `where` clones and returns `new SelectQueryBuilderImpl({...})`, and the props are
`freeze`-d in the constructor ([`src/query-builder/select-query-builder.ts`][sqb]). The docs warn
the caller about the consequence ([`src/query-builder/where-interface.ts`][whereiface]):

> _"The query builder is immutable. Remember to reassign the result back to the query variable."_

**The AST is an immutable operation-node tree.** Method arguments are turned into `OperationNode`s
by the `parser/` modules; a raw value becomes a `ValueNode`, an `Expression` contributes its own
node ([`src/parser/value-parser.ts`][valueparser]):

```ts
// src/parser/value-parser.ts
export function parseValueExpression(
  exp: ValueExpression<any, any, unknown>,
): OperationNode {
  if (isExpressionOrFactory(exp)) {
    return parseExpression(exp);
  }
  return ValueNode.create(exp); // a plain value → a bind-parameter node
}
```

Every node is `freeze`-d and tagged by a `kind` from a closed `OperationNodeKind` union
([`src/operation-node/operation-node.ts`][opnode], [`src/operation-node/value-node.ts`][valuenode]).

**Compilation separates SQL text from parameters — this is the injection-safety mechanism.** The
dialect's `QueryCompiler` walks the AST and produces a `CompiledQuery` of `{ sql, parameters }`
([`src/query-compiler/compiled-query.ts`][compiledquery]). A `ValueNode` never lands in the SQL
string; it is pushed onto the parameter array and replaced by a placeholder
([`src/query-compiler/default-query-compiler.ts`][compiler]):

```ts
// src/query-compiler/default-query-compiler.ts
protected override visitValue(node: ValueNode): void {
  if (node.immediate) {
    this.appendImmediateValue(node.value)
  } else {
    this.appendValue(node.value)
  }
}
protected appendValue(parameter: unknown): void {
  this.addParameter(parameter)                        // pushed onto #parameters[]
  this.append(this.getCurrentParameterPlaceholder())  // only a placeholder in the SQL
}
```

The placeholder is dialect-specific — `$1`, `$2`, … for PostgreSQL (`'$' + this.numParameters`),
`?` for MySQL and SQLite, `@1`, `@2`, … for MS SQL Server — each an override of
`getCurrentParameterPlaceholder` ([`src/query-compiler/default-query-compiler.ts`][compiler],
[`src/dialect/mysql/mysql-query-compiler.ts`][mysqlc], [`src/dialect/sqlite/sqlite-query-compiler.ts`][sqlitec],
[`src/dialect/mssql/mssql-query-compiler.ts`][mssqlc]). So the two `where` values above compile to
real placeholders, never string-concatenated text ([`src/query-builder/where-interface.ts`][whereiface]):

```sql
select * from "person" where "first_name" = $1 and "age" > $2
```

**The escape hatch is the `sql` template tag — and it is parameter-safe by default.** Interpolations
become bind parameters, not text ([`src/raw-builder/sql.ts`][sqltag]):

> _"Substitutions (the things inside `${}`) are automatically passed to the database as parameters
> and are never interpolated to the SQL string. There's no need to worry about SQL injection
> vulnerabilities."_

```ts
// src/raw-builder/sql.ts — ${date1}/${date2} become $1/$2, not literal text
const persons = await db
  .selectFrom('person')
  .select(sql<string>`concat(first_name, ' ', last_name)`.as('full_name'))
  .where(sql<boolean>`birthdate between ${date1} and ${date2}`)
  .execute();
```

Under the hood a `RawNode` interleaves the static `sqlFragments` with the interpolated
parameter nodes, and the compiler emits the fragments verbatim while `visitNode`-ing each
parameter (which, being a `ValueNode`, again becomes a placeholder)
([`src/query-compiler/default-query-compiler.ts`][compiler]):

```ts
// src/query-compiler/default-query-compiler.ts
protected override visitRaw(node: RawNode): void {
  const { sqlFragments, parameters: params } = node
  for (let i = 0; i < sqlFragments.length; ++i) {
    this.append(sqlFragments[i])
    if (params.length > i) {
      this.visitNode(params[i]) // an interpolation → a bound parameter
    }
  }
}
```

The _only_ way to reintroduce injection risk is to reach for the deliberate raw helpers —
`sql.raw`, `sql.lit`, `sql.ref`, `sql.table`, `sql.id` — which splice text/identifiers instead of
binding. Each is flagged loudly ([`src/raw-builder/sql.ts`][sqltag]):

> _"WARNING! Using this with unchecked inputs WILL lead to SQL injection vulnerabilities. The
> input is not checked or escaped by Kysely in any way."_

`sql.lit` produces a `ValueNode.createImmediate` that `appendImmediateValue` renders directly into
the SQL text ([`src/parser/value-parser.ts`][valueparser], [`src/query-compiler/default-query-compiler.ts`][compiler]).
For fully dynamic-but-typeless columns/tables, the `DynamicModule` (`db.dynamic.ref`) is the
type-erasing counterpart to the `sql` tag ([`src/kysely.ts`][kyselyts]).

---

## Schema, migrations & code generation

Kysely is **schema-agnostic**: it neither owns nor generates the `Database` type. You must supply
it ([`site/docs/generating-types.md`][gentypes]):

> _"To work with Kysely, you're required to provide a database schema type definition to the
> Kysely constructor. In many cases, defining your database schema definitions manually is good
> enough."_

There is **no first-party code generation**. Keeping the type aligned with a live database is
delegated to _separate_ community tools — `kysely-codegen` (introspection), `prisma-kysely`
(from a Prisma schema), `kanel-kysely`, and others ([`site/docs/generating-types.md`][gentypes]).
This is the deliberate contrast with the db-first builders in this survey (`jOOQ`, `Diesel`,
`sqlc`), whose code generation is a first-party, load-bearing step: Kysely's typed surface works
with _zero_ build tooling, at the cost that the hand-written type can silently drift from the real
schema.

Kysely _does_ ship a **DDL builder** and a **migration runner**, but they are separate from the
`Database` type. `db.schema.createTable(...)`, `.createIndex(...)`, `.alterTable(...)`,
`.createView(...)`, `.createType(...)` build DDL statements that execute like any query
([`src/schema/schema-module.ts`][schema]) — yet running them does _not_ update the `Database`
interface, which you must edit by hand (or regenerate). The `Migrator` runs versioned migrations
written as ordinary TypeScript `up`/`down` functions over the schema builder
([`src/migration/migrator.ts`][migrator]):

```ts
// src/migration/migrator.ts — a migration is imperative TS, not generated
export interface Migration {
  up(db: Kysely<any>): Promise<void>;
  down?(db: Kysely<any>): Promise<void>;
}
```

`migrateToLatest` records applied migrations in a bookkeeping table, runs the pending ones in
alphabetical order, guards concurrency with a migration lock (PostgreSQL advisory lock, MySQL
`get_lock`, or a lock table), and — where `supportsTransactionalDdl` — wraps each in a transaction.
Notably the runner _"never throws"_: it returns a `MigrationResultSet` whose `error`/`results`
report what happened ([`src/migration/migrator.ts`][migrator], [`src/dialect/dialect-adapter.ts`][adapter]).
So Kysely is neither strictly code-first nor db-first: it owns schema _evolution_ (the runner) but
leaves schema _description_ (the type) to you or third-party codegen.

---

## Type mapping & result decoding

Result decoding is **entirely type-level**. The result type of a query is _inferred_ from the
selected columns plus the `Database` type — `select(['id', 'first_name'])` yields
`{ id, first_name }`, `selectAll()` yields the whole row, and even the alias in `pet.name as pet_name`
is parsed into the result key ([`README.md`][readme], [`src/query-builder/select-query-builder.ts`][sqb]).
Nullability is preserved: a `last_name: string | null` column surfaces as a nullable field, exactly
as concepts calls out for [nullability][typemap].

Per-operation column types are expressed with the `ColumnType` family, which lets a column read
back as one type but insert/update as others ([`src/util/column-type.ts`][coltype]):

```ts
// src/util/column-type.ts
export type ColumnType<
  SelectType,
  InsertType = SelectType,
  UpdateType = SelectType,
> = {
  readonly __select__: SelectType;
  readonly __insert__: InsertType;
  readonly __update__: UpdateType;
};
export type Generated<S> = ColumnType<S, S | undefined, S>; // optional on insert/update
export type GeneratedAlways<S> = ColumnType<S, never, never>; // never insertable/updatable
```

The `Selectable<R>`, `Insertable<R>`, and `Updateable<R>` mapped types then project a table
interface into the three operation-specific row shapes — `Insertable` makes `Generated` columns
optional; `Updateable` makes every column optional ([`src/util/column-type.ts`][coltype],
[`site/docs/getting-started/_types.mdx`][typesdoc]). This is how one `PersonTable` interface serves
`select`, `insert`, and `update` with different required/optional fields.

Crucially, **Kysely does not decode cell values at runtime**. It hands back whatever the underlying
vendor driver returns (`pg`, `mysql2`, `better-sqlite3` do their own type parsing); the `Database`
type is a compile-time _contract_, not a runtime _codec_. This is the sharp contrast with
[skunk][skunkpage]'s `Codec` or `Diesel`'s `FromSql`/`ToSql`, where decoding is a first-class,
composable runtime value: in Kysely, runtime fidelity is the driver's responsibility, and a lie in
the `Database` type is not caught — you would get a runtime value that doesn't match its static
type. Runtime result transformation is opt-in via **plugins** (`CamelCasePlugin`,
`ParseJSONResultsPlugin`), which rewrite the query AST and/or post-process rows
([`src/plugin/`][pluginref]). Terminal methods shape the result count: `execute()` returns a row
array, `executeTakeFirst()` the first row or `undefined`, and `executeTakeFirstOrThrow()` throws a
`NoResultError` when empty ([`src/query-builder/select-query-builder.ts`][sqb],
[`src/query-builder/no-result-error.ts`][noresult]).

---

## Effect model, transactions & error handling

**Kysely is async, full stop.** Every terminal method returns a `Promise` — `execute()` resolves to
`SimplifyResult<O>[]` ([`src/query-builder/select-query-builder.ts`][sqb]). There is no blocking
mode and, deliberately, **no effect value**: a Kysely builder is lazy (it is "just" an immutable AST
until a terminal call), but it is not a reified `IO`/`ZIO`/`Effect`/`ConnectionIO` you compose in an
error-typed monad. This is the axis that separates Kysely from the survey's effect-first subjects
([Effect TS][effect-ts], [doobie][doobiepage], [Quill][quillpage], [skunk][skunkpage]): it splits
_build_ from _execute_ (you can `.compile()` to a `CompiledQuery` without running it), but the
terminal step is a promise, not a description carried in the type. The Effect ecosystem bridges this
gap with a separate `@effect/sql-kysely` adapter that wraps Kysely calls into Effect values.

**Transactions are callback-scoped.** `db.transaction().execute(cb)` runs `cb` inside a transaction,
committing on success and rolling back on a thrown exception ([`src/kysely.ts`][kyselyts]):

> _"If the function throws an exception, 1. the exception is caught, 2. the transaction is rolled
> back, and 3. the exception is thrown again. Otherwise the transaction is committed."_

```ts
// src/kysely.ts — the trx object is a Transaction<DB> that extends Kysely<DB>
const catto = await db.transaction().execute(async trx => {
  const jennifer = await trx
    .insertInto('person')
    .values({ first_name: 'Jennifer', last_name: 'Aniston', age: 40 })
    .returning('id')
    .executeTakeFirstOrThrow();

  return await trx
    .insertInto('pet')
    .values({
      owner_id: jennifer.id,
      name: 'Catto',
      species: 'cat',
      is_favorite: false,
    })
    .returningAll()
    .executeTakeFirst();
});
```

The implementation leases one connection, calls `driver.beginTransaction`, runs the callback, then
`commitTransaction` — or, on any throw, `rollbackTransaction` and rethrow
([`src/kysely.ts`][kyselyts], `TransactionBuilder.execute`). `setIsolationLevel` and `setAccessMode`
configure it, over the isolation levels `read uncommitted` … `serializable`, plus `snapshot`
([`src/driver/driver.ts`][driver]).

**Savepoints are real, and type-tracked.** Beyond the auto-managed callback form, `db.startTransaction()`
returns a `ControlledTransaction` with manual `commit()`/`rollback()` and _first-class savepoints_ —
`savepoint(name)`, `rollbackToSavepoint(name)`, `releaseSavepoint(name)` — where the live savepoint
set is carried in the type parameter `S extends string[]`, so rolling back to a released savepoint is
a compile error ([`src/kysely.ts`][kyselyts], `ControlledTransaction<DB, S>`). The driver exposes
these as optional `savepoint?`/`rollbackToSavepoint?`/`releaseSavepoint?` methods
([`src/driver/driver.ts`][driver]). This is a capability [Slick][slickpage] lacks (its nested
`transactionally` adds no savepoints). Note, however, that Kysely does **not** auto-nest a plain
`db.transaction()`: on a `Transaction`, the `transaction()`, `startTransaction()`, and `connection()`
methods are overridden to throw — nesting is an explicit, controlled-transaction-plus-savepoint
operation, not an implicit `SAVEPOINT` the way the effect systems layer nested `withTransaction`
([`src/kysely.ts`][kyselyts]).

**Errors are thrown exceptions, not a typed channel.** A failed query rejects its `Promise`;
`executeTakeFirstOrThrow` throws `NoResultError`; driver/database errors bubble up as thrown
exceptions ([`src/query-builder/no-result-error.ts`][noresult], [`src/kysely.ts`][kyselyts]). There
is no enumerated `SqlError` union, no `isRetryable` flag, and no error type in the query's static
type. So Kysely's safety guarantee is precisely scoped: **compile-time correctness of the SQL you
build**, with **runtime failures remaining untyped exceptions** in a promise rejection — the exact
inverse emphasis of the [typed-error effect mappers][effects] this survey weights most heavily.

---

## Ecosystem & maturity

Kysely is MIT-licensed (© 2022 Sami Koskimäki, [`LICENSE`][license]) and developed under the
`kysely-org` organization, led by author Sami Koskimäki and Igal Klebanov ([`README.md`][readme]).
Built-in dialects cover **PostgreSQL, MySQL, MS SQL Server, SQLite, and PGlite**; an organization
dialect covers Postgres.js; and a long community list adds Cloudflare D1, Turso/libSQL, Neon,
PlanetScale, SQLite WASM, Deno/Node SQLite, Capacitor, and more ([`site/docs/dialects.md`][dialectsdoc]).
It runs across Node.js, Deno, Bun, Cloudflare Workers, and browsers ([`README.md`][readme]), which
made it a favorite in the serverless/edge TypeScript wave (the README credits early promoters
including Theo Browne, Lee Robinson, and Dax Raad).

The pinned checkout is `0.29.3` — still **pre-1.0**, though widely adopted and stable in practice
(web-attested). The surrounding ecosystem is where the "no first-party codegen" gap is filled:
`kysely-codegen`, `prisma-kysely`, and `kanel-kysely` generate the `Database` type from a live DB or
a Prisma schema, and `@effect/sql-kysely` adapts it into the Effect runtime. First release is
web-attested to ≈2021 (the author's launch post is archived 2021-12-03; the `LICENSE` copyright is
2022).

---

## Strengths

- **Type-safety from a single plain type.** All autocomplete and checking flow from the `Database`
  interface; a wrong column, bad type, or out-of-scope reference is a compile error — with no
  runtime schema, no decorators, and no build step required.
- **Zero runtime schema cost.** The `Database` type is erased; the shipped JavaScript carries no
  schema object, only the builder and dialect ([`src/kysely.ts`][kyselyts]).
- **Injection-safe by construction.** Values compile to bind parameters, never concatenated text,
  across all dialect placeholder styles; the `sql` tag parameterizes interpolations too
  ([`src/query-compiler/default-query-compiler.ts`][compiler], [`src/raw-builder/sql.ts`][sqltag]).
- **Immutable, lazy, inspectable.** Each method returns a new frozen builder over an immutable AST;
  `.compile()` exposes the `{ sql, parameters }` without executing ([`site/docs/execution.mdx`][execution]).
- **Faithful SQL surface.** The builder mirrors SQL clauses and infers the exact result shape,
  including aliases and nullability — "nothing more, nothing less" ([`site/docs/recipes/0001-relations.md`][relations]).
- **First-class savepoints** with a type-tracked savepoint stack in controlled transactions
  ([`src/kysely.ts`][kyselyts]).
- **Portable.** Runs on every major JS runtime; built-in + community dialects span most SQL engines.

## Weaknesses

- **You must maintain the `Database` type by hand** (or via third-party codegen); it can drift from
  the real schema, and Kysely cannot validate against a live DB at build time the way `sqlx`/`sqlc`
  do ([`site/docs/generating-types.md`][gentypes]).
- **No runtime decoding / no codecs.** Cell values are whatever the driver returns; a type that
  lies about a column is not caught at runtime — decoding fidelity is outsourced to the vendor
  driver and opt-in plugins ([`src/util/column-type.ts`][coltype]).
- **Untyped errors.** Failures are thrown exceptions in a promise rejection; there is no typed error
  channel, `SqlError` union, or `isRetryable` signal ([`src/query-builder/no-result-error.ts`][noresult]).
- **Not an effect value.** Async-only; no `IO`/`ZIO`/`Effect` integration without the external
  `@effect/sql-kysely` adapter — a gap for effects-first designs.
- **No relations / no ORM conveniences.** Nested objects require hand-written JSON-function queries;
  there is no eager loading, identity map, or [change tracking][ormpatterns] ([`site/docs/recipes/0001-relations.md`][relations]).
- **No first-party migration codegen.** Migrations are imperative TS you write; the schema
  description and DDL are separate, hand-synced artifacts ([`src/migration/migrator.ts`][migrator]).
- **Pre-1.0.** The `0.x` version line signals ongoing API churn potential.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                       | Trade-off                                                                                                     |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Type-only `Database` interface drives all safety**           | No runtime schema, no decorators, no codegen required; erased at runtime → zero cost            | You must supply/maintain the type; it can't be validated against the live DB at build time (unlike `sqlx`)    |
| **Immutable, lazy builder over a frozen AST**                  | Composable, inspectable (`.compile()`), plugin-transformable; reassignable in conditionals      | Callers must reassign the returned builder; forgetting is a silent no-op                                      |
| **Values → bind parameters at compile-to-SQL**                 | Injection-safe by construction across all dialect placeholder styles                            | Raw splicing (`sql.raw`/`lit`/`id`) reopens injection risk; typed operators can't express every SQL construct |
| **`sql` template tag as the escape hatch**                     | Anything untypeable stays parameter-safe; interpolations bind, not concatenate                  | Raw fragments are unchecked against the schema; you annotate their result type by hand                        |
| **No first-party code generation**                             | The typed surface works with zero build tooling; codegen is optional and pluggable              | Hand-written type can drift; db-first users depend on third-party tools (`kysely-codegen`, `prisma-kysely`)   |
| **No runtime codecs — decoding is type-only**                  | Small, driver-agnostic core; leans on the vendor driver's own type parsing                      | A lying type isn't caught at runtime; no composable `Codec` like `skunk`/`Diesel`                             |
| **Async Promises, not an effect value**                        | Simplest possible model for the JS ecosystem; universal runtime support                         | No typed errors, no effect-system integration without `@effect/sql-kysely`                                    |
| **Exceptions, not a typed error channel**                      | Idiomatic TS; nothing extra to learn                                                            | Errors absent from the query type; no `isRetryable`/reason union like [Effect TS][effect-ts]                  |
| **Callback transactions + type-tracked controlled savepoints** | Auto commit/rollback for the common case; explicit, compile-checked savepoint stack when needed | Plain `db.transaction()` doesn't auto-nest (throws inside a `Transaction`); nesting is an explicit API        |

---

## Sources

- [kysely-org/kysely — GitHub repository][repo] · [kysely.dev documentation][docs] · [API docs][apidoc]
- [`README.md` — positioning ("type-safe and autocompletion-friendly … SQL query builder", "Inspired by Knex.js"), scope tracking, runtimes, core team][readme]
- [`LICENSE` — MIT, © 2022 Sami Koskimäki][license]
- [`src/kysely.ts` — `Kysely<DB>` root, `Database` type param, connection pool per instance, transactions, controlled transactions + savepoints, `$extendTables` type-only note][kyselyts]
- [`src/query-creator.ts` — `selectFrom`/`insertInto`/… entry points][querycreator] · [`src/query-builder/select-query-builder.ts` — fluent chain, immutable `where`, `execute`/`executeTakeFirst`/`compile`][sqb]
- [`src/query-builder/where-interface.ts` — "the query builder is immutable" + `$1`/`$2` placeholder example][whereiface]
- [`src/parser/value-parser.ts` — value → `ValueNode` (bind param) vs expression node][valueparser] · [`src/operation-node/operation-node.ts` — the `OperationNodeKind` AST union][opnode] · [`src/operation-node/value-node.ts`][valuenode]
- [`src/query-compiler/default-query-compiler.ts` — `visitValue`/`appendValue`/`addParameter`, placeholder generation, `visitRaw`][compiler] · [`src/query-compiler/compiled-query.ts` — `{ sql, parameters }`][compiledquery]
- [`src/dialect/mysql|sqlite|mssql-query-compiler.ts` — dialect placeholder overrides (`?`, `@n`)][mysqlc]
- [`src/raw-builder/sql.ts` — the `sql` tag, parameter safety, `ref`/`lit`/`raw`/`id`/`join` warnings][sqltag]
- [`src/dialect/dialect.ts` — `Dialect` (driver/compiler/adapter/introspector)][dialect] · [`src/dialect/postgres/postgres-driver.ts` — `pg` `Pool` delegation][pgdriver] · [`src/driver/driver.ts` — `beginTransaction`/`commit`/`rollback`/`savepoint`, isolation levels][driver]
- [`src/util/column-type.ts` — `ColumnType`/`Generated`/`Selectable`/`Insertable`/`Updateable`][coltype] · [`src/query-builder/no-result-error.ts`][noresult]
- [`src/schema/schema-module.ts` — DDL builder][schema] · [`src/migration/migrator.ts` — `Migration` `up`/`down`, `migrateToLatest`][migrator] · [`src/dialect/dialect-adapter.ts` — `supportsTransactionalDdl`, migration locks][adapter]
- [`site/docs/intro.mdx` — escape-hatch framing][intro] · [`site/docs/execution.mdx` — immutable build → compile → connection flow][execution] · [`site/docs/recipes/0001-relations.md` — "Kysely IS NOT an ORM"][relations] · [`site/docs/generating-types.md` — you provide the type; third-party codegen][gentypes] · [`site/docs/getting-started/_types.mdx` — the `Database` interface][typesdoc] · [`site/docs/dialects.md` — built-in + community dialects][dialectsdoc]
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [phantom / type-level schema][phantom] · [statements & injection][injection] · [type mapping & decoding][typemap] · [effects, transactions & errors][effects] · [connections & pools][pools] · [ORM patterns][ormpatterns]

<!-- References -->

[repo]: https://github.com/kysely-org/kysely
[docs]: https://kysely.dev
[apidoc]: https://kysely-org.github.io/kysely-apidoc/
[readme]: https://github.com/kysely-org/kysely/blob/c431677/README.md
[license]: https://github.com/kysely-org/kysely/blob/c431677/LICENSE
[kyselyts]: https://github.com/kysely-org/kysely/blob/c431677/src/kysely.ts
[querycreator]: https://github.com/kysely-org/kysely/blob/c431677/src/query-creator.ts
[sqb]: https://github.com/kysely-org/kysely/blob/c431677/src/query-builder/select-query-builder.ts
[whereiface]: https://github.com/kysely-org/kysely/blob/c431677/src/query-builder/where-interface.ts
[valueparser]: https://github.com/kysely-org/kysely/blob/c431677/src/parser/value-parser.ts
[opnode]: https://github.com/kysely-org/kysely/blob/c431677/src/operation-node/operation-node.ts
[valuenode]: https://github.com/kysely-org/kysely/blob/c431677/src/operation-node/value-node.ts
[compiler]: https://github.com/kysely-org/kysely/blob/c431677/src/query-compiler/default-query-compiler.ts
[compiledquery]: https://github.com/kysely-org/kysely/blob/c431677/src/query-compiler/compiled-query.ts
[mysqlc]: https://github.com/kysely-org/kysely/blob/c431677/src/dialect/mysql/mysql-query-compiler.ts
[sqlitec]: https://github.com/kysely-org/kysely/blob/c431677/src/dialect/sqlite/sqlite-query-compiler.ts
[mssqlc]: https://github.com/kysely-org/kysely/blob/c431677/src/dialect/mssql/mssql-query-compiler.ts
[sqltag]: https://github.com/kysely-org/kysely/blob/c431677/src/raw-builder/sql.ts
[dialect]: https://github.com/kysely-org/kysely/blob/c431677/src/dialect/dialect.ts
[pgdriver]: https://github.com/kysely-org/kysely/blob/c431677/src/dialect/postgres/postgres-driver.ts
[driver]: https://github.com/kysely-org/kysely/blob/c431677/src/driver/driver.ts
[coltype]: https://github.com/kysely-org/kysely/blob/c431677/src/util/column-type.ts
[noresult]: https://github.com/kysely-org/kysely/blob/c431677/src/query-builder/no-result-error.ts
[schema]: https://github.com/kysely-org/kysely/blob/c431677/src/schema/schema-module.ts
[migrator]: https://github.com/kysely-org/kysely/blob/c431677/src/migration/migrator.ts
[adapter]: https://github.com/kysely-org/kysely/blob/c431677/src/dialect/dialect-adapter.ts
[pluginref]: https://github.com/kysely-org/kysely/tree/c431677/src/plugin
[intro]: https://github.com/kysely-org/kysely/blob/c431677/site/docs/intro.mdx
[execution]: https://github.com/kysely-org/kysely/blob/c431677/site/docs/execution.mdx
[relations]: https://github.com/kysely-org/kysely/blob/c431677/site/docs/recipes/0001-relations.md
[gentypes]: https://github.com/kysely-org/kysely/blob/c431677/site/docs/generating-types.md
[typesdoc]: https://github.com/kysely-org/kysely/blob/c431677/site/docs/getting-started/_types.mdx
[dialectsdoc]: https://github.com/kysely-org/kysely/blob/c431677/site/docs/dialects.md
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[phantom]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
[ormpatterns]: ./concepts.md#orm-patterns
[effect-ts]: ./effect-ts.md
[doobiepage]: ./doobie.md
[quillpage]: ./quill.md
[skunkpage]: ./skunk.md
[slickpage]: ./slick.md

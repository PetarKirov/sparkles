# Prisma (TypeScript / Node.js)

A schema-first ORM whose single source of truth is a declarative `.prisma` schema file: `prisma generate` compiles that schema into a fully-typed `PrismaClient`, and queries — structured `where`/`include`/`select` criteria objects, not SQL text and not a fluent builder — are turned into a query plan by a Rust query engine (now shipped as WebAssembly) and executed over a JavaScript driver adapter.

| Field              | Value                                                                                                                                                     |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | TypeScript (client + CLI); Rust for the schema engine and query compiler, both shipped to the client as WebAssembly                                       |
| License            | Apache-2.0 — [`LICENSE`][license]                                                                                                                         |
| Repository         | [prisma/prisma][repo]                                                                                                                                     |
| Documentation      | [prisma.io/docs][docs] · in-repo [`README.md`][readme] · [`ARCHITECTURE.md`][arch]                                                                        |
| Category           | [Full ORM (data-mapper)][ladder] — schema-first, generated typed client; **stateless** (no identity map, no unit of work)                                 |
| Abstraction level  | The [full-ORM rung][ladder], reached from a schema file rather than from host-language classes; a generated client, not an active-record or session model |
| Query model        | Generated typed client — structured criteria objects (`where`/`include`/`select`) serialized to a JSON protocol and [compiled][qmodels] to a query plan   |
| Effect/async model | [Async (Promises)][effects] — every query is a lazily-executed `PrismaPromise`; errors are thrown, not typed                                              |
| Backends           | PostgreSQL, MySQL, SQLite, SQL Server, MongoDB, CockroachDB                                                                                               |
| First release      | ≈2021 (Prisma ORM 2 GA; the Prisma 1 GraphQL-era predecessor ≈2019) — web-attested                                                                        |
| Latest version     | pinned checkout tracks the `7.x` line (`@prisma/engines-version` `7.8.0-…`, [`packages/client/package.json`][clientpkg]); "latest" is web-attested        |

> [!NOTE]
> Prisma is this survey's data point for the **schema-first, code-generated full ORM**. It is
> the antithesis of the in-language builders `Drizzle` and `Kysely` (which own no schema DSL)
> and of the decorator ORM `TypeORM`: you write a declarative schema in its own DSL, run a
> build step, and get a typed client whose entire API surface — `findMany`, `create`,
> `where`, `include`, `select` — is _generated from that schema_. It sits on the
> [full-ORM rung][ladder] of the abstraction ladder but deliberately drops the
> [identity map and unit of work][ormpatterns]: results are plain objects and writes are
> explicit. On the effect axis this survey weights most it is a thrown-exception, Promise-based
> client — contrast the effect-typed `Effect TS sql` layer, `Quill`, and `doobie`. Shared
> terms are defined once in [concepts][concepts]; the family map lives in the
> [survey index][index].

---

## Overview

### What it solves

Prisma occupies the top rung of the [abstraction ladder][ladder] — a full ORM — but reaches
it from an unusual direction. Where `Hibernate` and `TypeORM` derive the schema from
annotated host-language classes and `EF Core` from C# entity classes, Prisma inverts the
dependency: a standalone declarative schema file is the source of truth, and the typed
host-language code is _generated from it_. The top-level `README.md` frames the whole toolkit
around three tools built on that schema ([`README.md`][readme]):

> _"Prisma ORM is a **next-generation ORM** that consists of these tools:"_
> _"- **Prisma Client**: Auto-generated and type-safe query builder for Node.js & TypeScript"_
> _"- **Prisma Migrate**: Declarative data modeling & migration system"_
> _"- **Prisma Studio**: GUI to view and edit data in your database"_

The client package's own masthead states the payoff and positions it against the mainstream
([`packages/client/README.md`][clientreadme]):

> _"Prisma Client JS is an **auto-generated query builder** that enables **type-safe**
> database access and **reduces boilerplate**. You can use it as an alternative to
> traditional ORMs such as Sequelize, TypeORM or SQL query builders like knex.js."_

The user never writes the types for `User`, the argument shape of `findMany`, or the result
shape of a `select` — the code generator emits all of them from the schema, so a query
referencing a non-existent column or a mistyped filter is a _compile error_
([`README.md`][readme]):

> _"the result of this query will be \_statically typed_ so that you can't accidentally access
> a property that doesn't exist (and any typos are caught at compile-time)."\_

Queries return not proxies or tracked entities but ordinary values ([`README.md`][readme]):
_"all Prisma Client queries return \_plain old JavaScript objects_."_ That single sentence is
the tell that this ORM is \_not_ a unit-of-work: you get data, not a live object graph, and
persistence is a separate explicit call.

### Design philosophy

Three commitments define Prisma, each grounded in the repository.

**The schema is the single source of truth.** Every workflow begins at the `.prisma` file
([`README.md`][readme]):

> _"Every project that uses a tool from the Prisma toolkit starts with a Prisma schema file.
> The Prisma schema allows developers to define their \_application models_ in an intuitive
> data modeling language and configure _generators_."\_

That schema is **schema-first**, not code-first: the model is neither inferred from classes
(as in `TypeORM`/`Hibernate`) nor read solely from the live database. It can, however, be
_seeded_ from an existing database — `prisma db pull` introspects a database into the schema,
after which the schema resumes its role as the authority (see
[Schema, migrations & code generation](#schema-migrations-code-generation)).

**Everything downstream is generated from an intermediate representation.** The schema is
parsed (by a Rust engine) into the **DMMF**, and the entire client is a projection of it
([`ARCHITECTURE.md`][arch]):

> _"What the … is DMMF? It's the Datamodel Meta Format. It is an AST (abstract syntax tree) of
> the datamodel in the form of JSON. The whole Prisma Client is just generated based on the
> DMMF, which comes from the Rust engines."_

The DMMF is explicitly an internal contract ([`ARCHITECTURE.md`][arch]): _"The DMMF is a
Prisma ORM internal API with no guarantees for stability to outside users."_ The consequence
for this survey: unlike a `Drizzle` schema (which _is_ TypeScript) or a `Kysely` type-only
interface, the Prisma type source is a **separate DSL compiled through a build step** — more
power to constrain and validate, at the cost of a generation step and a language of its own.

**The database is reached through a JavaScript driver adapter.** In the pinned checkout the
client no longer bundles a native Rust binary that opens its own database connection; it
requires a **driver adapter** wrapping an ordinary JS driver, and refuses to run without one
([`ClientEngine.ts`][clientengine]):

> _"PrismaClient requires a driver adapter to connect to your database, but none was provided.
> Pass one to the PrismaClient constructor, e.g. `new PrismaClient({ adapter })`."_

This is the visible edge of a large architectural shift (below): the Rust engine has been
narrowed to a **query compiler**, and connectivity/execution moved into TypeScript.

---

## Connection, pooling & resource lifetime

Prisma does **not** open sockets or own a pool itself — it delegates to a **driver adapter**
that wraps a JS database driver (`pg`, `@libsql/client`, `mysql2`, …). You construct the
adapter and hand it to the client ([`README.md`][readme]):

```ts
import { PrismaClient } from './generated/client';
import { PrismaPg } from '@prisma/adapter-pg';

const adapter = new PrismaPg({ connectionString: process.env.DATABASE_URL });
const prisma = new PrismaClient({ adapter });
```

The adapter interface `SqlDriverAdapter` is the resource seam — it exposes `queryRaw`,
`executeRaw`, `startTransaction`, an optional `getConnectionInfo`, and a `dispose` for
teardown ([`driver-adapter-utils/src/types.ts`][adapterutils]):

```ts
// @prisma/driver-adapter-utils — src/types.ts
export interface SqlDriverAdapter extends SqlQueryable {
  executeScript(script: string): Promise<void>;
  startTransaction(isolationLevel?: IsolationLevel): Promise<Transaction>;
  getConnectionInfo?(): ConnectionInfo;
  dispose(): Promise<void>;
}
```

Pool sizing, TLS, and reconnection belong to the wrapped driver: `@prisma/adapter-pg` holds a
`pg.Pool`, the libSQL adapter its own client, and so on. Inside the client, `LocalExecutor`
calls `driverAdapterFactory.connect()` once, builds a `TransactionManager` and a
`QueryInterpreter` over the resulting adapter, and `dispose()`s the adapter on disconnect
([`LocalExecutor.ts`][localexec]). The lifetime discipline is therefore a plain
`connect`/`dispose` pair, not the [scoped acquire/release resource][pools] the effect systems
model — a leaked connection is a runtime leak, not a type error.

Two lifecycle notes distinguish it. First, the client is **lazy**: the first query drives
`#ensureStarted`, which loads the WASM compiler and connects the adapter, with a small state
machine (`disconnected`/`connecting`/`connected`/`disconnecting`) guarding concurrent starts
([`ClientEngine.ts`][clientengine]). Second, there is a **remote** executor path
(`RemoteExecutor`): when constructed with an `accelerateUrl` instead of an adapter, the client
sends queries to **Prisma Accelerate**, a hosted connection-pooler/cache, over HTTP rather
than to a local adapter ([`ClientEngine.ts`][clientengine]). Connection pooling for
serverless is thus either the driver adapter's job or Accelerate's — never the client's.

---

## Query construction & injection safety

A Prisma query is neither SQL text nor a fluent builder: it is a **structured criteria
object** passed to a generated model method, and its journey to SQL is what makes it
injection-safe by construction.

### The generated model API

`prisma generate` emits a `PrismaClient` on which each model is a property (`prisma.user`,
`prisma.post`) carrying the CRUD verbs. The canonical reads and writes ([`README.md`][readme]):

```ts
// Retrieve all User records
const allUsers = await prisma.user.findMany();

// Eager-load the posts relation on each User (one query, not N+1)
const usersWithPosts = await prisma.user.findMany({
  include: { posts: true },
});

// Filter with a structured `where` (never string-built)
const filteredPosts = await prisma.post.findMany({
  where: {
    OR: [
      { title: { contains: 'prisma' } },
      { content: { contains: 'prisma' } },
    ],
  },
});

// Create a User and a related Post in one nested write
const user = await prisma.user.create({
  data: {
    name: 'Alice',
    email: 'alice@prisma.io',
    posts: { create: { title: 'Join us for Prisma Day 2021' } },
  },
});
```

`where`, `include`, `select`, `data`, `orderBy`, `take`, `skip`, and `cursor` are the argument
_keys_; the values are ordinary JS data. There is no place in this API where a user value is
concatenated into a SQL string — the criteria object is a tree of data, and every data value
lives at a leaf of that tree, structurally separate from the operators (`contains`, `OR`,
`equals`, …) that are schema-validated keys.

### From method call to bound parameter

Each model method is a proxy that builds a request and hands it to the engine
([`applyModel.ts`][applymodel]). The arguments are serialized by `serializeJsonQuery` into a
`JsonQuery` — Prisma's **JSON protocol** — a JSON document naming the model, the action
(`findMany` → `findMany`, `create` → `createOne`, …), and the selection/argument tree
([`serializeJsonQuery.ts`][serialize]). That JSON is then **parameterized** (`parameterizeQuery`
lifts data values out into a placeholder map via a schema-derived `ParamGraph`) and compiled
into a query plan; the plan's SQL nodes carry the values as a separate `args` array with typed
placeholders. When the interpreter renders a templated query, values become dialect
placeholders — `$1`, `$2` for PostgreSQL (`placeholderFormat.prefix` + numbering), `?` for
MySQL/SQLite — and the value goes into the bound-args array, never the SQL text
([`render-query.ts`][renderquery]):

```ts
// @prisma/client-engine-runtime — interpreter/render-query.ts
case 'parameter':
  return formatPlaceholder(placeholderFormat, ctx.placeholderNumber++)
// …
function formatPlaceholder(placeholderFormat: PlaceholderFormat, placeholderNumber: number): string {
  return placeholderFormat.hasNumbering ? `${placeholderFormat.prefix}${placeholderNumber}` : placeholderFormat.prefix
}
```

So the safety property is _structural_: a data value is [bound, not interpolated][injection],
end to end, whether it entered through `where`, `data`, or a nested write. Prisma also builds
`IN (…)` lists and value tuples as expanding placeholder fragments (`parameterTuple`,
`parameterTupleList`) and even chunks them when a value list would exceed the driver's
`maxBindValues` — again without ever string-splicing a value ([`render-query.ts`][renderquery]).

### Raw SQL: the safe tag and the unsafe escape hatch

For SQL the API cannot express, Prisma offers a **tagged-template** escape hatch that stays
parameterized, and an explicitly-unsafe sibling. `$queryRaw` / `$executeRaw` are tag functions:
interpolated `${…}` values are captured as bound parameters, exactly as the concepts page's
[tagged-template safety][injection] describes ([`getPrismaClient.ts`][client]):

```ts
const result =
  await prisma.$queryRaw`SELECT * FROM User WHERE id = ${1} OR email = ${'user@email.com'};`;
```

Passing a plain string instead of a template throws — the method insists on the tag form. The
raw args mapper turns the template's fragments into a prepared statement with the dialect's
placeholders (`$n` text for PostgreSQL, `?` for MySQL/SQLite, `@Pn` for SQL Server) and a
serialized parameter array ([`rawQueryArgsMapper.ts`][rawmapper]). The unsafe counterparts take
a bare string plus positional values and are documented as dangerous
([`getPrismaClient.ts`][client]):

> _"Unsafe counterpart of `$queryRaw` that is susceptible to SQL injections"_

Even the unsafe path has a guard rail: on PostgreSQL/CockroachDB, running an `ALTER` with
interpolated values through the _safe_ `$executeRaw` is rejected with an explanation that the
`$executeRawUnsafe` alternative _"is vulnerable to SQL injection attacks and requires you to
take care of input sanitization"_ ([`rawQueryArgsMapper.ts`][rawmapper]). A `$queryRawTyped`
variant (preview) goes the other way — raw `.sql` files are introspected at generate time so
the raw query is _statically typed_ (see [type mapping](#type-mapping-result-decoding)).

---

## The query engine: from JSON protocol to query plan

Prisma's most architecturally distinctive trait — and the one that has changed most — is that
a query is **compiled and interpreted**, not built directly. Understanding the pipeline is
understanding the library.

**Historically** (Prisma 2–5, comment- and web-attested) the client shipped a **Rust query
engine** as a native artifact: either a _library engine_ (`libquery_engine`, loaded in-process
through N-API) or a _binary engine_ (a sidecar process the client talked to over a
GraphQL-shaped protocol). That Rust engine connected _directly_ to the database with its own
connection pool (the `quaint` layer) and returned results. Traces of that era survive only in
comments — _"only relevant and implemented for the binary engine"_, _"When using library
engine …"_ ([`ClientEngine.ts`][clientengine]).

**In the pinned checkout the only engine is `ClientEngine`, written in TypeScript**, and the
Rust code is reduced to a **WebAssembly query compiler**. The pipeline for one
`prisma.user.findMany({ where, include })` is:

1. **Serialize** the criteria object to a `JsonQuery` (JSON protocol) — `serializeJsonQuery`.
2. **Parameterize** it: lift data values into a placeholder map keyed by a schema-derived
   `ParamGraph`, leaving a value-free query shape — `parameterizeQuery`.
3. **Compile** that shape, via the WASM compiler, into a **`QueryPlanNode`** — a small
   tree-shaped IR. The parameterized shape is the **cache key**: a `QueryPlanCache` memoizes
   the plan so repeated query shapes skip the compiler ([`ClientEngine.ts`][clientengine]).
4. **Interpret** the plan against the driver adapter — `QueryInterpreter.run`.

The plan is a program for a tiny VM. Its node union includes SQL nodes (`query`, `execute`),
binding and sequencing (`let`, `get`, `seq`), relation stitching (`join`), result shaping
(`dataMap`, `mapField`), control flow (`if`, `validate`), and transactions (`transaction`)
([`query-plan.ts`][queryplan]):

```ts
// @prisma/client-engine-runtime — query-plan.ts (abridged QueryPlanNode union)
export type QueryPlanNode =
  | { type: 'query'; args: QueryPlanDbQuery } // run SQL, return rows
  | { type: 'execute'; args: QueryPlanDbQuery } // run SQL, return affected count
  | { type: 'let'; args: { bindings: QueryPlanBinding[]; expr: QueryPlanNode } }
  | {
      type: 'join';
      args: { parent: QueryPlanNode; children: JoinExpression[] /* … */ };
    }
  | { type: 'transaction'; args: QueryPlanNode }
  | {
      type: 'dataMap';
      args: {
        expr: QueryPlanNode;
        structure: ResultNode;
        enums: Record<string, Record<string, string>>;
      };
    }
  | {
      type: 'validate';
      args: { expr: QueryPlanNode; rules: DataRule[] } & ValidationError;
    };
// … 'seq' | 'get' | 'sum' | 'unique' | 'required' | 'if' | 'diff' | 'process' | …
```

The `QueryInterpreter` is a straightforward recursive evaluator over this union: a `query` node
renders its SQL and runs `queryable.queryRaw`, a `let` node evaluates bindings into a scope, a
`join` node fetches parent and child result sets and stitches them **in memory** by matching
keys, and a `transaction` node wraps its child in a driver transaction
([`query-interpreter.ts`][interpreter]). Crucially, the interpreter runs against a `queryable`
that is _either_ the driver adapter _or_ an active transaction — the same plan executes inside
or outside a transaction unchanged.

The upshot for this survey: Prisma's "query builder" is really a **compiler + interpreter**,
with the query language (the JSON protocol) and its optimizer (the Rust compiler) firmly
outside the host language. This buys uniform behavior across six databases from one plan
format, at the cost of a WASM module in the bundle, an opaque compilation step, and query
mechanics that live in Rust rather than in readable TypeScript.

---

## Schema, migrations & code generation

This is Prisma's signature. The `.prisma` schema declares three block kinds — `datasource`,
`generator`, and `model` — and drives both code generation and migrations
([`README.md`][readme]):

```prisma
datasource db {
  provider = "postgresql"  // mysql, sqlite, sqlserver, mongodb or cockroachdb
}

generator client {
  provider = "prisma-client"
  output   = "../generated"
}

model Post {
  id        Int     @id @default(autoincrement())
  title     String
  content   String?
  published Boolean @default(false)
  author    User?   @relation(fields: [authorId], references: [id])
  authorId  Int?
}

model User {
  id    Int     @id @default(autoincrement())
  email String  @unique
  name  String?
  posts Post[]
}
```

`?` marks a nullable field, `[]` a to-many relation, and `@`/`@@` attributes carry keys,
defaults, uniqueness, and the `@relation` wiring. A model _"Represent[s] a table in the
underlying database"_ and _"Provide[s] the foundation for the queries in the Prisma Client
API"_ ([`README.md`][readme]).

### Code generation

The schema is parsed by the Rust schema engine — shipped as WebAssembly — into config and
DMMF: `@prisma/prisma-schema-wasm`'s `get_config` and `get_dmmf` are the entry points
([`internals/src/engine-commands/getConfig.ts`][getconfig],
[`internals/src/wasm.ts`][internalswasm]). `prisma generate` then runs a **generator** over
the DMMF to emit the typed client ([`README.md`][readme]):

> _"This command reads your Prisma schema and \_generates_ the Prisma Client code in the
> location specified by the `output` path in your generator configuration."\_

The repository ships **two** generators, both emitting a client from the same DMMF: the legacy
`prisma-client-js` (JavaScript, [`client-generator-js`][genjs]) and the newer TypeScript
`prisma-client` — an alias of `prisma-client-ts` ([`client-generator-registry/src/default.ts`][genregistry],
[`client-generator-ts/src/generator.ts`][gents]). The `prisma-client` (TS) generator is what
the README now recommends, and it requires an explicit `output` path. Because the client is
_generated_, changing the schema means re-running `prisma generate` — a real build step, unlike
`Drizzle`/`Kysely` where the TypeScript schema _is_ the type source with no codegen.

### Prisma Migrate

Migrations are the schema engine's second job — _"Declarative data modeling & schema
migrations"_ ([`migrate/README.md`][migratereadme]). The `SchemaEngine` interface (backed by
`@prisma/schema-engine-wasm` or a CLI binary) exposes the migration verbs
([`migrate/src/SchemaEngine.ts`][schemaengine]):

| Method / command                     | What it does                                                                               |
| ------------------------------------ | ------------------------------------------------------------------------------------------ |
| `createMigration` (`migrate dev`)    | Diff schema against migration history → write the next numbered SQL migration and apply it |
| `applyMigrations` (`migrate deploy`) | Apply pending migrations from the migrations directory to the database                     |
| `schemaPush` (`db push`)             | Push schema changes **directly** to the database, no migration file (prototyping)          |
| `introspect` (`db pull`)             | Read a live database and update the schema (database-first seeding)                        |
| `migrateDiff`                        | Compare two schema sources and emit a human-readable or executable diff                    |
| `reset` / `evaluateDataLoss`         | Reset the database; warn about destructive steps before applying                           |
| `introspectSql`                      | SQL introspection that powers the `TypedSQL` feature                                       |

`createMigration` _"will use the shadow database on the connectors where we need one"_ — a
throwaway database Prisma builds the schema in to compute an accurate diff — and `migrateDiff`
_"Compares two databases schemas from two arbitrary sources, and display[s] the difference as
either a human-readable summary, or an executable script"_ ([`migrate/src/SchemaEngine.ts`][schemaengine]).
So the schema is **code-first for migrations** (the tool emits SQL from schema diffs, EF-Core
style) while supporting **database-first introspection** to bootstrap the schema — the two
stances the [concepts page][schemamig] distinguishes, both present.

---

## Type mapping & result decoding

Type mapping is DMMF-driven and lives in the query plan's `dataMap` node. After the SQL nodes
return raw rows, `dataMap` reshapes them into the typed result the caller expects, guided by a
`ResultNode` structure and an enum-value map ([`query-plan.ts`][queryplan],
[`query-interpreter.ts`][interpreter]). The scalar type space the plan carries is explicit
([`query-plan.ts`][queryplan]):

```ts
// @prisma/client-engine-runtime — query-plan.ts
export type FieldType = { arity: Arity } & FieldScalarType;
export type FieldScalarType =
  | {
      type:
        | 'string'
        | 'int'
        | 'bigint'
        | 'float'
        | 'boolean'
        | 'json'
        | 'object'
        | 'datetime'
        | 'decimal'
        | 'unsupported';
    }
  | { type: 'enum'; name: string }
  | { type: 'bytes'; encoding: 'array' | 'base64' | 'hex' };
```

**Nullability and shape are in the generated types, not discovered at runtime.** Because the
result type of each query is generated from the DMMF _and narrowed by the `select`/`include`
you pass_, a partial selection produces a correspondingly partial static type — this is what
makes _"even when only retrieving the subsets of a model's fields"_ type-safe
([`README.md`][readme]). Decoding of the raw driver values happens in the driver adapter and
the interpreter's serializers (`serializeSql` / `serializeRawSql`), keyed on the
`SqlResultSet`'s `columnTypes` ([`driver-adapter-utils/src/types.ts`][adapterutils]). The
`TypedSQL` feature extends the same typing to raw SQL: `introspectSql` describes a `.sql`
file's parameters and result columns so `$queryRawTyped` returns a statically-typed row.

Result **hydration of relations** is done by the interpreter's `join` node, not by lazy
proxies: parent and child rows are fetched (via relation joins where the adapter reports
`supportsRelationJoins`, else separate queries) and stitched into a nested object graph in
memory by matching join keys ([`query-interpreter.ts`][interpreter]). The output is a plain
object tree — no tracked entities, no identity map making two loads share an instance.

---

## Effect model, transactions & error handling

This is the axis that most sharply separates Prisma from the effect-first libraries this survey
centres on.

### Async by Promise

Every Prisma query is a `PrismaPromise` — a thenable created by `_createPrismaPromise` that runs
the request when awaited; there is no `IO`/`Effect`/`ConnectionIO` description value. The
engine's `request` returns a `Promise`, and the model proxies wrap it. So `await
prisma.user.findMany(...)` triggers execution, and the query neither carries its error type nor
its required environment in a type — it is `Promise<User[]>`, and failure is a thrown exception
([`getPrismaClient.ts`][client], [`ClientEngine.ts`][clientengine]). This is the same
"great ergonomics, untyped effects" position as `Drizzle`, and the crisp contrast with
`Effect TS`'s `Effect<A, E, R>` and `Quill`'s ZIO channels.

### Transactions: interactive and batch

`$transaction` has two forms. The **interactive** form takes a callback and passes a
transaction-scoped client; the **batch** (sequential) form takes an array of queries run
atomically ([`getPrismaClient.ts`][client]):

```ts
// Interactive: a callback with a transaction-scoped client
await prisma.$transaction(async tx => {
  const from = await tx.account.update({
    where: { id: 1 },
    data: { balance: { decrement: 100 } },
  });
  const to = await tx.account.update({
    where: { id: 2 },
    data: { balance: { increment: 100 } },
  });
  return [from, to];
});

// Batch: an array of queries, committed together
await prisma.$transaction([
  prisma.user.create({ data: { email: 'a@b.c' } }),
  prisma.post.create({ data: { title: 'hi' } }),
]);
```

Under the interactive form, the `TransactionManager` starts a driver transaction with the
configured `maxWait`, `timeout`, and `isolationLevel`, tracks it by id, and enforces timeouts
([`transaction-manager.ts`][txmgr]). **Nested transactions become real
[savepoints][savepoint]**: a nested `$transaction` reuses the same transaction id, increments a
depth counter, and issues `createSavepoint` / `rollbackToSavepoint` / `releaseSavepoint` on the
driver adapter's `Transaction` — with names like `prisma_sp_0`, `prisma_sp_1`
([`transaction-manager.ts`][txmgr]). Savepoints are an _adapter capability_: if the driver does
not implement `createSavepoint`, nesting throws _"Nested transactions are not supported by
adapter …"_. Isolation levels map to the SQL strings (`READ COMMITTED`, `SERIALIZABLE`, …);
`SNAPSHOT` is rejected because it is _"Snapshot level only supported for MS SQL Server, which is
not supported via driver adapters so far"_ ([`transaction-manager.ts`][txmgr]). Provider quirks
are enforced too — Cloudflare D1 rejects interactive transactions, and MongoDB rejects nested
ones ([`getPrismaClient.ts`][client]).

### Errors are thrown, not typed

Prisma's error model is **exceptions with codes**, not a [typed error channel][effects]. The
client raises a small family of error classes — `PrismaClientKnownRequestError` (carrying a
`P####` code and `meta`), `PrismaClientUnknownRequestError`, `PrismaClientValidationError`,
`PrismaClientInitializationError`, and `PrismaClientRustPanicError` (a WASM panic)
([`ClientEngine.ts`][clientengine]). Underneath, the driver adapter classifies database failures
into a structured `MappedError` union — a rich taxonomy the engine translates into the
`P####`-coded exception ([`driver-adapter-utils/src/types.ts`][adapterutils]):

```ts
// @prisma/driver-adapter-utils — src/types.ts (excerpt of MappedError)
export type MappedError =
  | {
      kind: 'UniqueConstraintViolation';
      constraint?:
        | { fields: string[] }
        | { index: string }
        | { foreignKey: {} };
    }
  | {
      kind: 'ForeignKeyConstraintViolation';
      constraint?:
        | { fields: string[] }
        | { index: string }
        | { foreignKey: {} };
    }
  | {
      kind: 'NullConstraintViolation';
      constraint?:
        | { fields: string[] }
        | { index: string }
        | { foreignKey: {} };
    }
  | { kind: 'TransactionWriteConflict' }
  | { kind: 'DatabaseNotReachable'; host?: string; port?: number };
// … TlsConnectionError | AuthenticationFailed | SocketTimeout | postgres | mysql | sqlite | mssql | …
```

The distinction that matters for this survey: this taxonomy is _dynamic_. A unique-constraint
violation surfaces as a thrown `PrismaClientKnownRequestError` with code `P2002`, which you must
`try`/`catch` and match on — there is **no** error type on the query, no `Either`/`Expected`
result, and no compiler-enforced handling. A `TransactionWriteConflict` (a retryable
serialization failure) is a kind in the union but not a typed, retryable channel the way
`Effect TS`'s `SqlError` exposes an `isRetryable` flag. Prisma is a thrown-exception ORM with an
unusually _structured_ set of exceptions — but exceptions nonetheless.

### Not a unit of work

There is no `SaveChanges`/flush, no identity map, and no change tracking. You never mutate a
returned object and expect an `UPDATE`; you call `prisma.user.update(...)` explicitly. That
keeps Prisma, despite sitting on the full-ORM rung, off the [unit-of-work / identity-map][ormpatterns]
machinery that defines `Hibernate`, `EF Core`, and `SQLAlchemy` — a deliberate simplification it
shares with `Drizzle` and the functional data mappers.

---

## Ecosystem & maturity

Prisma is among the most-adopted database toolkits in the Node.js ecosystem, licensed under the
permissive, patent-granting **Apache-2.0** ([`LICENSE`][license]). The supported backends are
the six named in the schema-provider comment — PostgreSQL, MySQL, SQLite, SQL Server, MongoDB,
CockroachDB ([`README.md`][readme]) — reached through official driver adapters:
`@prisma/adapter-pg`, `@prisma/adapter-neon`, `@prisma/adapter-libsql`,
`@prisma/adapter-better-sqlite3`, `@prisma/adapter-d1`, `@prisma/adapter-planetscale`,
`@prisma/adapter-mssql`, and `@prisma/adapter-mariadb`
([`driver-adapter-utils/src/types.ts`][adapterutils]). MongoDB is a first-class provider,
making Prisma one of the few tools in this survey to span SQL and a document store behind one
generated client.

The monorepo is large and layered: the schema engine and query compiler are Rust (delivered as
`@prisma/prisma-schema-wasm` / a WASM query compiler), while the client, CLI, generators,
migrate, driver adapters, and the `client-engine-runtime` interpreter are TypeScript. The pinned
checkout tracks the **`7.x`** line (`@prisma/engines-version` `7.8.0-…`,
[`packages/client/package.json`][clientpkg]) — the release series in which the driver-adapter +
pure-TS `ClientEngine` path is the default and a native engine binary is no longer required.
The companion `Prisma Studio` (a data browser), `Prisma Accelerate` (hosted pooling/caching),
and a large `prisma-examples` corpus round out the ecosystem. First release (Prisma ORM 2 GA
≈2021, succeeding the 2019 Prisma 1 GraphQL layer), download counts, and "latest version" are
web-attested, not tree facts. The **Effect** ecosystem's interest is worth noting: `Effect TS`
ships `@effect/sql-drizzle` and `@effect/sql-kysely` integrations but no first-party Prisma one,
reflecting Prisma's less composable, exception-based effect model.

---

## Strengths

- **Type safety with zero hand-written types.** The whole client — model methods, argument
  shapes, and result types narrowed by `select`/`include` — is generated from the schema; a
  bad column or filter is a compile error.
- **One schema, one source of truth.** A single declarative `.prisma` file drives the client,
  the migrations, and the docs — no drift between an ORM schema and a separate migration DSL.
- **Injection-safe by construction.** Criteria objects keep every data value at a data leaf;
  the compiler/interpreter always binds, never interpolates. Raw SQL is a parameterized
  tagged template, with the unsafe path explicitly marked.
- **Real migrations with a shadow database.** `migrate dev`/`deploy` emit reviewable SQL from
  schema diffs; `db pull` introspects; `migrateDiff` scripts arbitrary source-to-source diffs.
- **Nested writes and single-query relation loading.** `include`/`select` eager-load a nested
  graph in one plan; nested `create`/`connect` write a graph in one call — no N+1 by default.
- **Uniform behavior across six databases**, including MongoDB, from one plan format.
- **Real savepoints.** Nested interactive transactions map to `SAVEPOINT`/`ROLLBACK TO`.
- **Serverless-ready via driver adapters and Accelerate**, with a WASM engine that runs in
  edge runtimes rather than a native binary.

## Weaknesses

- **A schema DSL and a build step.** The `.prisma` language and `prisma generate` are extra
  moving parts; the DMMF is an unstable internal API, and the generated client can go stale if
  you forget to regenerate — a cost `Drizzle`/`Kysely` avoid by making TypeScript the schema.
- **No typed error channel.** Failures are thrown `PrismaClient*Error`s with `P####` codes;
  there is no error type on the query, no retryable classification in the type, no
  `Either`/`Expected` — pure `try`/`catch`.
- **Not an effect value.** A query is an eagerly-executed `PrismaPromise`, so it cannot be
  composed as a description carrying its environment and errors — effect-first composition is
  out of scope by design.
- **Opaque, non-host-language query mechanics.** The query language (JSON protocol) and its
  compiler are Rust/WASM; you cannot read or step through SQL generation in TypeScript, and the
  WASM module adds bundle weight.
- **Less raw-SQL flexibility than a builder.** Complex SQL that the criteria API can't express
  falls to `$queryRaw`/`$queryRawUnsafe`, losing the generated-type safety (partly recovered by
  the preview `TypedSQL`).
- **Non-owning resource lifetime.** Pooling and connection lifetime belong to the wrapped
  driver adapter; a leaked lease is a runtime concern, not a type error.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                                      | Trade-off                                                                                               |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **Schema-first: a `.prisma` DSL is the single source of truth**       | One authoritative model for types, queries, and migrations; validated by a real parser         | A separate language + `prisma generate` build step; type source is not the host language                |
| **Generate the whole client from the DMMF**                           | Full static types with no hand-written boilerplate; partial-select types come for free         | Codegen must be re-run on schema change; DMMF is an unstable internal API                               |
| **Query = structured criteria object, not SQL or a fluent builder**   | Injection-safe by structure; uniform across six databases; nested reads/writes in one call     | A bespoke query language (JSON protocol) to learn; opaque vs SQL you can read                           |
| **Compile queries to a plan via a Rust/WASM engine, interpret in TS** | One plan format for all dialects; a query-plan cache; edge-runtime-friendly WASM               | Rust/WASM in the bundle; query mechanics live outside readable TypeScript; a compile step per new shape |
| **Execute over a JS driver adapter (mandatory)**                      | Connectivity in JS, serverless-ready, no native engine binary; driver owns the pool            | Client owns no pool/lifetime discipline; a driver adapter is required to run at all                     |
| **Migrate by diffing the schema → SQL (shadow DB)**                   | Reviewable SQL migrations, code-first, plus `db pull` introspection for database-first seeding | Needs a shadow database and a schema-engine round trip; generated SQL still needs review                |
| **Async `PrismaPromise`, thrown `P####`-coded errors**                | Familiar Promise ergonomics; a structured, well-documented exception taxonomy                  | No typed/retryable error channel, no effect value — not effect-first                                    |
| **Stateless results (no identity map / unit of work)**                | Plain objects, explicit writes, predictable behavior; less "magic" than a classic ORM          | No object-graph mutate-and-flush; sits on the full-ORM rung without its automation                      |
| **Nested transactions → savepoints (adapter capability)**             | True nested rollback semantics where the driver supports it                                    | Adapters lacking `createSavepoint` reject nesting; `SNAPSHOT` isolation unsupported via adapters        |

---

## Sources

- [prisma/prisma — GitHub repository][repo] · [prisma.io/docs][docs] · [`LICENSE` (Apache-2.0)][license]
- [`README.md` — "next-generation ORM", the schema/generate/migrate pitch, client sample queries, driver-adapter instantiation][readme]
- [`ARCHITECTURE.md` — DMMF as the datamodel AST; "The whole Prisma Client is just generated based on the DMMF, which comes from the Rust engines"][arch]
- [`packages/client/README.md` — "auto-generated query builder … type-safe database access … reduces boilerplate"][clientreadme]
- [`packages/client/src/runtime/core/engines/client/ClientEngine.ts` — the TS engine: WASM compiler load, parameterize → compile → plan cache → execute; mandatory driver adapter; error transforms][clientengine]
- [`packages/client/src/runtime/core/engines/client/LocalExecutor.ts` — driver-adapter connect/dispose, interpreter + transaction manager wiring][localexec]
- [`packages/client/src/runtime/getPrismaClient.ts` — model proxies, `$queryRaw`/`$executeRaw` tags + unsafe variants, `$transaction` interactive/batch][client]
- [`packages/client/src/runtime/core/jsonProtocol/serializeJsonQuery.ts` — criteria object → JSON protocol `JsonQuery`][serialize]
- [`packages/client/src/runtime/core/raw-query/rawQueryArgsMapper.ts` — raw tag → prepared statement + params; the `ALTER`-injection guard][rawmapper]
- [`packages/client-engine-runtime/src/query-plan.ts` — the `QueryPlanNode` IR and scalar `FieldType`][queryplan]
- [`packages/client-engine-runtime/src/interpreter/query-interpreter.ts` — the plan interpreter (`query`/`let`/`join`/`transaction`/`dataMap`)][interpreter]
- [`packages/client-engine-runtime/src/interpreter/render-query.ts` — dialect placeholders (`$n`/`?`), parameter tuples, chunking][renderquery]
- [`packages/client-engine-runtime/src/transaction-manager/transaction-manager.ts` — interactive/nested transactions, savepoints, timeouts, isolation][txmgr]
- [`packages/driver-adapter-utils/src/types.ts` — `SqlDriverAdapter`/`Transaction` interfaces, official adapter list, `MappedError` taxonomy][adapterutils]
- [`packages/migrate/src/SchemaEngine.ts` — `createMigration`/`applyMigrations`/`schemaPush`/`introspect`/`migrateDiff`, shadow database][schemaengine]
- [`packages/client-generator-ts/src/generator.ts` — the `prisma-client` (TS) generator][gents] · [`client-generator-registry/src/default.ts` — `prisma-client` ↦ `prisma-client-ts`][genregistry]
- [`packages/internals/src/engine-commands/getConfig.ts` + `wasm.ts` — schema parsing via `@prisma/prisma-schema-wasm`][getconfig]
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [schema, migrations & codegen][schemamig] · [type mapping & decoding][typemap] · [effects, transactions & errors][effects] · [connections & pools][pools] · [N+1][nplusone] · [ORM patterns][ormpatterns] · [survey index][index]

<!-- References -->

[repo]: https://github.com/prisma/prisma
[docs]: https://www.prisma.io/docs
[license]: https://github.com/prisma/prisma/blob/cda80a4/LICENSE
[readme]: https://github.com/prisma/prisma/blob/cda80a4/README.md
[arch]: https://github.com/prisma/prisma/blob/cda80a4/ARCHITECTURE.md
[clientreadme]: https://github.com/prisma/prisma/blob/cda80a4/packages/client/README.md
[clientpkg]: https://github.com/prisma/prisma/blob/cda80a4/packages/client/package.json
[clientengine]: https://github.com/prisma/prisma/blob/cda80a4/packages/client/src/runtime/core/engines/client/ClientEngine.ts
[localexec]: https://github.com/prisma/prisma/blob/cda80a4/packages/client/src/runtime/core/engines/client/LocalExecutor.ts
[client]: https://github.com/prisma/prisma/blob/cda80a4/packages/client/src/runtime/getPrismaClient.ts
[applymodel]: https://github.com/prisma/prisma/blob/cda80a4/packages/client/src/runtime/core/model/applyModel.ts
[serialize]: https://github.com/prisma/prisma/blob/cda80a4/packages/client/src/runtime/core/jsonProtocol/serializeJsonQuery.ts
[rawmapper]: https://github.com/prisma/prisma/blob/cda80a4/packages/client/src/runtime/core/raw-query/rawQueryArgsMapper.ts
[queryplan]: https://github.com/prisma/prisma/blob/cda80a4/packages/client-engine-runtime/src/query-plan.ts
[interpreter]: https://github.com/prisma/prisma/blob/cda80a4/packages/client-engine-runtime/src/interpreter/query-interpreter.ts
[renderquery]: https://github.com/prisma/prisma/blob/cda80a4/packages/client-engine-runtime/src/interpreter/render-query.ts
[txmgr]: https://github.com/prisma/prisma/blob/cda80a4/packages/client-engine-runtime/src/transaction-manager/transaction-manager.ts
[adapterutils]: https://github.com/prisma/prisma/blob/cda80a4/packages/driver-adapter-utils/src/types.ts
[schemaengine]: https://github.com/prisma/prisma/blob/cda80a4/packages/migrate/src/SchemaEngine.ts
[migratereadme]: https://github.com/prisma/prisma/blob/cda80a4/packages/migrate/README.md
[gents]: https://github.com/prisma/prisma/blob/cda80a4/packages/client-generator-ts/src/generator.ts
[genjs]: https://github.com/prisma/prisma/blob/cda80a4/packages/client-generator-js/src/generator.ts
[genregistry]: https://github.com/prisma/prisma/blob/cda80a4/packages/client-generator-registry/src/default.ts
[getconfig]: https://github.com/prisma/prisma/blob/cda80a4/packages/internals/src/engine-commands/getConfig.ts
[internalswasm]: https://github.com/prisma/prisma/blob/cda80a4/packages/internals/src/wasm.ts
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

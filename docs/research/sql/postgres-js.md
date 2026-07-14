# postgres.js (JavaScript / TypeScript)

A dependency-free, PostgreSQL-only client for Node.js, Deno, Bun, and Cloudflare Workers whose entire surface is one overloaded `sql` tagged-template function: every `${…}` interpolation becomes a bound `$n` parameter, and the same `sql` — called as a _function_ — escapes identifiers and builds `insert`/`update`/`in` fragments. It is the thinnest injection-safe SQL interface, elegantly unified.

| Field              | Value                                                                                                            |
| ------------------ | ---------------------------------------------------------------------------------------------------------------- |
| Language           | JavaScript (ESM source, generated CJS/Deno/Workers builds); TypeScript declarations bundled (`types/index.d.ts`) |
| License            | [Unlicense][license] — public domain (`package.json`: `"license": "Unlicense"`)                                  |
| Repository         | [porsager/postgres][repo]                                                                                        |
| Documentation      | [`README.md`][readme] (the single canonical doc) · [`CHANGELOG.md`][changelog]                                   |
| Author             | Rasmus Porsager (`package.json` `author` field)                                                                  |
| Category           | [Driver][concepts-ladder] + [safe-SQL / micro-mapper][concepts-ladder] (tagged template)                         |
| Abstraction level  | [Driver / safe-SQL rung][concepts-ladder] — you write raw SQL, but every value auto-binds                        |
| Query model        | [Tagged template][concepts-qcm] + dynamic `sql()` helpers; escape hatch `sql.unsafe`                             |
| Effect/async model | [Async][concepts-eth] — a query is a lazy `Promise` subclass (a thenable that executes on `await`)               |
| Backends           | PostgreSQL only (speaks the wire protocol directly; no `libpq`)                                                  |
| First release      | `v1.0.0`, 2019-12-22 ([`CHANGELOG.md`][changelog]) — web/changelog-attested                                      |
| Latest version     | `3.4.9` (`package.json`; pinned checkout `e7dfa14`)                                                              |

> [!NOTE]
> postgres.js is this survey's **tagged-template baseline** — the JavaScript data point
> for the [driver][concepts-ladder] and [safe-SQL / micro-mapper][concepts-ladder] rungs,
> where you write all the SQL but never build a query string by hand. It is the plain-Promise
> sibling of the [Effect TS `sql`][effect-ts] layer: the same `` sql`… ${x}` `` idea that
> turns every interpolation into a [bound parameter][concepts-inj], but without an effect
> system, a typed error channel, or a query builder on top. Shared terms
> ([tagged template][concepts-qcm], [connection pool][concepts-cps], [savepoint][concepts-eth],
> [prepared statement][concepts-cps]) are defined in [`concepts.md`][concepts].

---

## Overview

### What it solves

postgres.js is a from-scratch PostgreSQL driver: it opens the socket, performs the
`SCRAM-SHA-256`/`MD5` handshake, drives the extended-query protocol (`Parse`/`Bind`/`Describe`/`Execute`),
and decodes result rows — all in ~1,400 lines of `src/connection.js`, with **no `libpq`
and no runtime dependencies**. On top of that wire engine it exposes a single ergonomic
primitive: a tagged-template `sql` that both _runs_ queries and _builds_ query fragments.
The project's own one-liners state the two commitments ([`README.md`][readme]):

> _"🚀 Fastest full-featured node & deno client"_

> _"🏷 ES6 Tagged Template Strings at the core"_

and the `package.json` description repeats the positioning: _"Fastest full featured
PostgreSQL client for Node.js"_ ([`package.json`][pkg]).

Where a bare [driver][concepts-ladder] like Go `database/sql` or JDBC hands you a
positional-parameter API you must feed manually (`?`/`$1` placeholders plus a separate
argument array), postgres.js makes the _syntactically obvious_ thing — interpolating a
value into a template string — also the _safe_ thing. The tagged template captures each
`${…}` as a bound parameter before any string concatenation happens, so the value can never
be parsed as SQL. That single design move is what lifts it from the driver rung onto the
safe-SQL / micro-mapper rung, and it is the reason the library exists.

### Design philosophy

**Tagged templates are the whole safety model.** postgres.js does not add a layer that
escapes strings; it never builds a string with your data in it at all. The README makes the
guarantee unconditional ([`README.md`][readme]):

> _"Postgres.js utilizes Tagged template functions to process query parameters **before**
> interpolation."_

> _"Parameters are automatically extracted and handled by the database so that SQL injection
> isn't possible. No special handling is necessary, simply use tagged template literals as
> usual."_

The mechanism is spelled out: _"Any generic value will be serialized according to an inferred
type, and replaced by a PostgreSQL protocol placeholder `$1, $2, ...`. The parameters are then
sent separately to the database which handles escaping & casting"_ ([`README.md`][readme]) —
i.e. text and data travel on [separate channels][concepts-inj], the definition of injection
safety.

**Rawness must be spelled out.** The only escape from the safe path is the explicit
`sql.unsafe(…)`, and the docs flag the risk in the same breath: _"If you know what you're
doing, you can use `unsafe` to pass any string you'd like to postgres. Please note that this
can lead to SQL injection if you're not careful"_ ([`README.md`][readme]). Calling the `sql`
value in a way that is _not_ a tagged template throws rather than silently building a string
(the `NOT_TAGGED_CALL` error below).

**One function, three jobs.** The distinguishing move is that the _same_ `sql` value is the
query tag, the identifier escaper, and the fragment builder — dispatched on how you call it.
A dynamic build stays composable and safe: _"It works by nesting ` sql` `fragments within
other` sql` ` calls or fragments. This allows you to build dynamic queries safely without
risking sql injections through usual string concatenation"_ ([`README.md`][readme]). This
unification is the library's signature idea and is developed in full below.

---

## Connection, pooling & resource lifetime

Calling `postgres(url, options)` returns a **pooled** `sql` — the whole setup is one line, and
opening it does no I/O. The [`README.md`][readme] states the laziness precisely:

> _"Connections are created lazily once a query is created."_ … _"No connection will be made
> until a query is made."_

The factory pre-allocates `max` `Connection` objects (default `10`, or `3` on Cloudflare) but
leaves their sockets closed, then wires them into a bank of queues that form the pool state
machine ([`src/index.js`][index]):

```js
// src/index.js — Postgres()
const queries = Queue(),
  connecting = Queue(),
  reserved = Queue(),
  closed = Queue(),
  ended = Queue(),
  open = Queue(),
  busy = Queue(),
  full = Queue(),
  queues = { connecting, reserved, closed, ended, open, busy, full };

const connections = [...Array(options.max)].map(() =>
  Connection(options, queues, { onopen, onend, onclose }),
);

const sql = Sql(handler);
```

A query flows through `handler(query)`: reuse an `open` connection, else warm up a `closed`
one, else steal a `busy` one (pipelining), else enqueue ([`src/index.js`][index]). The pool
grows to `max` under concurrency and each connection carries an `idleTimer`, a `lifeTimer`
(random `max_lifetime`), and a `connectTimer`. Because prepared statements accumulate per
connection, connections are recycled on a randomized lifetime to bound server-side memory —
the code computes `60 * (30 + Math.random() * 30)` seconds ([`src/index.js`][index]).

Two ways to pin a single connection out of the pool:

- **`sql.reserve()`** leases a dedicated connection wrapped as its own `sql`; `reserved.release()`
  returns it to the pool ([`README.md`][readme]). Used for work that must run on one isolated
  connection (session-scoped `SET`, advisory locks, `LISTEN`).
- **`sql.begin(fn)`** pins a connection for the length of a [transaction][concepts-eth]
  (below) and returns it automatically on commit/rollback: _"Connections are automatically
  taken out of the pool if you start a transaction using `sql.begin()`, and automatically
  returned to the pool once your transaction is done"_ ([`README.md`][readme]).

The wire protocol is implemented directly, so the connection layer speaks native Postgres
features no `libpq` wrapper exposes cleanly: `SCRAM-SHA-256` and `MD5` auth
([`src/connection.js`][conn]), the extended-query flow with per-connection
prepared-statement caching, server-side cursors (`PortalSuspended`), `COPY` in/out as Node
streams (`CopyInResponse`/`CopyOutResponse`), and the logical-replication `CopyBothResponse`
path used by `subscribe`. `LISTEN` and `subscribe` each spin up their own dedicated
single-connection `sql` with reconnect/backoff ([`src/index.js`][index],
[`src/subscribe.js`][subscribe]). The same portability lets it run on Node, Deno, Bun, and —
via the standard TCP-socket API — Cloudflare Workers.

## Query construction & injection safety

This is the heart of the library. The `sql` returned by `postgres()` is a single function
whose behaviour is **dispatched on the shape of its first argument** ([`src/index.js`][index]):

```js
// src/index.js — Sql()
function sql(strings, ...args) {
  const query =
    strings && Array.isArray(strings.raw)
      ? new Query(strings, args, handler, cancel)
      : typeof strings === 'string' && !args.length
        ? new Identifier(
            options.transform.column.to
              ? options.transform.column.to(strings)
              : strings,
          )
        : new Builder(strings, args);
  return query;
}
```

Three call shapes, three results:

| Call shape                                 | Detected by                                          | Produces     | Meaning                                          |
| ------------------------------------------ | ---------------------------------------------------- | ------------ | ------------------------------------------------ |
| `` sql`… ${v} …` ``                        | `strings.raw` is an array (a `TemplateStringsArray`) | `Query`      | A parameterized query; each `${v}` binds as `$n` |
| `sql('name')`                              | first arg is a `string`, no rest                     | `Identifier` | An **escaped identifier** (table/column name)    |
| `sql(obj)` / `sql(arr)` / `sql(o,'a','b')` | anything else                                        | `Builder`    | A **fragment builder** (column/value lists)      |

**Values become bound parameters.** When a `Query` is serialized, every interpolated value is
routed through `handleValue`, which pushes the value onto the out-of-band `parameters` array
and emits only a numbered placeholder into the SQL text ([`src/types.js`][types]):

```js
// src/types.js — handleValue()
return '$' + (types.push(
  x instanceof Parameter
    ? (parameters.push(x.value), /* … infer/resolve oid … */ )
    : (parameters.push(x), inferType(x))
))
```

So `` sql`select * from users where id = ${id}` `` sends the text `select * from users where
id = $1` and the bind array `[id]`, whatever `id` contains — exactly the
[tagged-template safety model][concepts-qcm]. The type is inferred from the JS value
(`inferType` maps `Date → 1184`, `Uint8Array → 17`, `bigint → 20`, …) or pinned explicitly with
`sql.typed(value, oid)`.

**Identifiers are escaped, not bound.** A parameter placeholder cannot stand in for a table or
column _name_, so those go through the `Identifier` path, whose escaping doubles embedded quotes
and quotes each dotted segment ([`src/types.js`][types]):

```js
// src/types.js
export const escapeIdentifier = function escape(str) {
  return '"' + str.replace(/"/g, '""').replace(/\./g, '"."') + '"';
};
```

Thus `` sql`select ${sql('user.id')} from ${sql('public.users')}` `` renders
`select "user"."id" from "public"."users"` — dynamic identifiers, still safe.

**The `Builder` reads the surrounding SQL to pick a helper.** The most elegant part: when you
interpolate an object or array, the resulting `Builder` inspects the SQL text that _precedes_
it and dispatches to the matching clause builder ([`src/types.js`][types]):

```js
// src/types.js — Builder.build()
build(before, parameters, types, options) {
  const keyword = builders.map(([x, fn]) => ({ fn, i: before.search(x) })).sort((a, b) => a.i - b.i).pop()
  return keyword.i === -1
    ? escapeIdentifiers(this.first, options)
    : keyword.fn(this.first, this.rest, parameters, types, options)
}
```

The `builders` set keys off the SQL keyword nearest the hole — `values`, `in`, `select`, `as`,
`returning`, `update`, `insert` — each a regexp anchored to whitespace/parens and constrained
to the _last_ occurrence ([`src/types.js`][types]). The result is that the same `sql(obj)`
expression means different, always-parameterized things by position:

```js
// src/types.js builders + README examples
sql`insert into users ${sql(user)}`; // → ("name","age")values($1,$2)
sql`insert into users ${sql(users)}`; // array → multi-row values($1,$2),($3,$4)
sql`update users set ${sql(user, 'name', 'age')}`; // → "name"=$1,"age"=$2
sql`select ${sql(columns)} from users`; // → "name","age"
sql`where age in ${sql([68, 75, 23])}`; // → in ($1,$2,$3)
```

The README calls out the sharp edge of the "omit columns" form: _"You can omit column names and
simply execute `sql(user)` to get all the fields from the object as columns. Be careful not to
allow users to supply columns that you do not want to be inserted"_ ([`README.md`][readme]) —
values are always safe, but an attacker-controlled _set of keys_ can widen an `insert`.

**Fragments nest, so conditional building stays safe.** A `Query` interpolated inside another
`Query` is spliced in as a fragment, merging its parameters into the parent's bind list
([`src/types.js`][types], `stringifyValue`/`fragment`). That is what makes conditional query
assembly injection-proof without string concatenation ([`README.md`][readme]):

```js
// README — Partial queries / dynamic filters
const olderThan = x => sql`and age > ${x}`;
await sql`
  select * from users
  where name is not null ${filterAge ? olderThan(50) : sql``}
`;
await sql`select * from users ${id ? sql`where user_id = ${id}` : sql``}`;
```

An empty ` sql` `` fragment contributes nothing; `olderThan(50)`'s `${x}` is still a bound
`$1`. Keywords/functions interpolate the same way (`` sql`now()` ``), so `date || sql`now()``
is safe.

**Misuse fails loud.** `Identifier` and `Builder` extend an internal `NotTagged` class whose
`then`/`catch`/`finally` throw, so accidentally `await`-ing a helper (rather than a real query)
raises `NOT_TAGGED_CALL` — _"Query not called as a tagged template literal"_
([`src/types.js`][types]). The README frames the whole restriction as a safety property:
_"Making queries has to be done using the sql function as a tagged template. This is to ensure
parameters are serialized and passed to Postgres as query parameters with correct types and to
avoid SQL injection"_ ([`README.md`][readme]).

**Escape hatches.** `sql.unsafe(string, args, options)` builds a `Query` from a raw string
(prepared statements defaulted off, since the text is presumed dynamic) and can be nested inside
a safe ` sql` ``when only a fragment is unsafe; `sql.file(path, args)` loads SQL from a file
([`src/index.js`][index]). Both re-expose injection risk by design.`` sql`…`.describe() ``
hands back the generated query string for inspection without executing it ([`README.md`][readme]).

## Schema, migrations & code generation

**None — deliberately.** postgres.js is a driver: it owns no schema, runs no migrations, and
generates no code. The README is explicit ([`README.md`][readme]):

> _"Postgres.js doesn't come with any migration solution since it's way out of scope"_

and points at external tools (`postgres-shift`, `ley`, `pgmg`). There is no
[code-first / db-first][concepts-schema] introspection of _your_ tables and no ORM. The one
place it reads the catalog is internal: on connect it queries `pg_catalog.pg_type` to learn the
array element/`typarray` OID pairs so it can (de)serialize array columns
([`src/connection.js`][conn], `fetchArrayTypes`), disableable via `fetch_types: false`. That
absence is the finding for this rung: you write every statement, and the library's job ends at
sending it safely and decoding the reply.

## Type mapping & result decoding

Result rows come back as **plain JavaScript objects**, keyed by column name — the README's
first promise is _"All queries will return a `Result` array, with objects mapping column names
to each row"_ ([`README.md`][readme]). The `Result` is an `Array` subclass carrying metadata
(`count`, `command`, `columns`, `statement`, `state`) as non-index properties
([`src/result.js`][result]); the row-assembly loop lives in the `DataRow` handler
([`src/connection.js`][conn]).

Two variants trade the object shape for speed/flexibility ([`src/query.js`][query],
[`README.md`][readme]):

- ``sql`…`.values()`` → each row is an **array of values** (handy for duplicate column names).
- ``sql`…`.raw()`` → each row is an **array of `Buffer`s**, undecoded.

Encoding/decoding is table-driven. `src/types.js` ships default codecs keyed by Postgres OID —
`string` (`25`), `number` (`21/23/26/700/701`), `json` (`114/3802`), `boolean` (`16`), `date`
(`1082/1114/1184`), `bytea` (`17`) — each a `{ to, from, serialize, parse }` record
([`src/types.js`][types]). A column's decoder is looked up by its type OID from the
`RowDescription` (`parsers[type]`), with arrays wrapped by a recursive `arrayParser`. Custom
types register through the `types` option or inline `sql.typed(value, oid)` ([`README.md`][readme]);
`bigint`/`numeric` return as strings by default (JS `Number` can't hold them) unless you opt into
`postgres.BigInt`.

Naming is handled by opt-in [transforms][concepts-dialect] — `postgres.camel`, `postgres.pascal`,
`postgres.kebab` (and their one-directional `to*`/`from*` variants) convert between
`snake_case` columns and JS casings on both the query and result sides ([`src/types.js`][types],
[`README.md`][readme]). Crucially the README warns that _static_ template text is never rewritten,
so column names in a query must go through the `sql()` helper for the transform to apply
([`README.md`][readme]).

**Nullability and row types are not enforced.** TypeScript support is a developer _assertion_:
`` sql<User[]>`select * from users` `` casts the result, and the README immediately cautions to
_check the array length_ because a missing row is `undefined`, not a type error
([`README.md`][readme], `types/index.d.ts`). There is no compile-time check that the SQL matches
`User`, nor that a column is nullable — contrast the macro-checked `sqlx`/`sqlc` family.

## Effect model, transactions & error handling

This is the dimension the survey weighs most, and where postgres.js sits at the opposite pole
from `Effect TS`: it is **plain async/await**, with laziness as its only cleverness.

**A query is a lazy `Promise` subclass.** `Query extends Promise`, and it does nothing until
someone consumes it ([`src/query.js`][query]):

```js
// src/query.js — Query
export class Query extends Promise {
  // …
  static get [Symbol.species]() {
    return Promise;
  }

  async handle() {
    !this.executed && (this.executed = true) && (await 1) && this.handler(this);
  }
  then() {
    this.handle();
    return super.then.apply(this, arguments);
  }
  catch() {
    this.handle();
    return super.catch.apply(this, arguments);
  }
  finally() {
    this.handle();
    return super.finally.apply(this, arguments);
  }
}
```

`handle()` defers a tick (`await 1`) before dispatching to the pool, so the query executes _at
the earliest on the next microtask_ — which is exactly what lets the library tell a nested
fragment (never awaited on its own) from the outer query that embeds it. The README makes this
explicit: _"queries are first executed when `awaited` – or instantly by using `.execute()`"_,
and _"The lazy Promise implementation in Postgres.js is what allows it to distinguish Nested
Fragments from the main outer query"_ ([`README.md`][readme]). The `Symbol.species` override
means `.then()` chains return ordinary `Promise`s, not `Query`s. A query built but never
awaited (nor `.execute()`d) simply never runs — the flip side of laziness.

Streaming variants reinterpret the same query object: `.cursor([rows], fn)` /
`for await (… of sql``…``.cursor())` throttle rows through a server-side
[cursor][concepts-cps]; `.forEach(fn)` iterates row-by-row; `.simple()` switches to the
multi-statement simple protocol; `.writable()`/`.readable()` expose `COPY` as Node
streams ([`src/query.js`][query], [`README.md`][readme]).

**Transactions: a scoped callback `sql`, with savepoints for nesting.** `sql.begin(options, fn)`
reserves a connection, sends `BEGIN`, and calls `fn` with a **transaction-scoped `sql`** whose
handler routes every query onto the pinned connection; it commits on success and rolls back on
throw ([`src/index.js`][index]):

```js
// src/index.js — begin() / scope() (abridged)
async function begin(options, fn) {
  // … await sql.unsafe('begin ' + options…).execute() …
  async function scope(c, fn, name) {
    const sql = Sql(handler); // a fresh sql bound to this connection
    sql.savepoint = savepoint;
    name && (await sql`savepoint ${sql(name)}`);
    try {
      result = await new Promise((resolve, reject) => {
        const x = fn(sql);
        Promise.resolve(Array.isArray(x) ? Promise.all(x) : x).then(
          resolve,
          reject,
        );
      });
    } catch (e) {
      await (name ? sql`rollback to ${sql(name)}` : sql`rollback`);
      throw e;
    }
    if (!name)
      prepare
        ? await sql`prepare transaction '${sql.unsafe(prepare)}'`
        : await sql`commit`;
    return result;

    function savepoint(name, fn) {
      // …
      return scope(c, fn, 's' + savepoints++ + (name ? '_' + name : ''));
    }
  }
}
```

The README summary: _"Postgres.js will reserve a connection for the transaction and supply a
scoped `sql` instance for all transaction uses in the callback function"_ ([`README.md`][readme]).
Nesting `sql.savepoint(fn)` recurses into `scope` with a generated `SAVEPOINT` name and, on a
caught rejection, issues `ROLLBACK TO` that savepoint — real nested transactions, not a flat
`BEGIN`/`COMMIT`. Returning an **array** of queries from the callback pipelines them; `sql.prepare(name)`
turns the commit into a two-phase `PREPARE TRANSACTION` ([`README.md`][readme]).

A guard enforces that transactions actually run on one connection: if a bare `BEGIN` completes on
a pooled connection (`max !== 1` and not reserved), the connection errors out rather than leak a
half-open transaction ([`src/connection.js`][conn]):

```js
// src/connection.js — CommandComplete
if (result.command === 'BEGIN' && max !== 1 && !connection.reserved)
  return errored(
    Errors.generic(
      'UNSAFE_TRANSACTION',
      'Only use sql.begin, sql.reserved or max: 1',
    ),
  );
```

**Errors are exceptions on the query's promise, not a typed channel.** postgres.js rejects the
individual query rather than surfacing errors globally ([`README.md`][readme]):

> _"Errors are all thrown to related queries and never globally. Errors coming from database
> itself are always in the native Postgres format"_

Database failures become a `PostgresError extends Error` ([`src/errors.js`][errors]) onto which
the full Postgres `ErrorResponse` fields are copied — `code` (the `SQLSTATE`), `message`,
`detail`, `hint`, `constraint_name`, `table_name`, … via the `errorFields` map
([`src/connection.js`][conn]). So callers branch on `err.code === '23505'` in a `try`/`catch`;
there is no discriminated reason union and no `isRetryable` flag (contrast `Effect TS`'s
`SqlError`). The query also carries a captured `origin` stack and, when `debug` is on, the
`query`/`parameters` (kept non-enumerable to avoid leaking secrets in logs)
([`src/connection.js`][conn], [`README.md`][readme]). Library-level failures use short string
codes — `UNSAFE_TRANSACTION`, `UNDEFINED_VALUE`, `MAX_PARAMETERS_EXCEEDED`, `NOT_TAGGED_CALL`,
`SASL_SIGNATURE_MISMATCH`, `CONNECTION_CLOSED/ENDED/DESTROYED`, `CONNECT_TIMEOUT` — enumerated in
the README ([`README.md`][readme]). One automatic recovery exists: when a cached prepared statement
is invalidated (routines `FetchPreparedStatement`, `RevalidateCachedQuery`, `transformAssignedExpr`),
the connection transparently re-prepares and retries ([`src/connection.js`][conn]).

**No effect system.** Because a query is just a `Promise`, there is no description-vs-execution
split beyond the one-tick laziness, no scoped resource type that makes a leaked connection a
compile error, and no error type in the signature. That is the whole trade: near-zero adoption
cost against none of the guarantees a value-level effect model buys. `Drizzle` and `Kysely`
(typed query builders) and `Effect TS` can all run _on top of_ postgres.js precisely because it
is this thin.

## Ecosystem & maturity

postgres.js is **public domain under the [Unlicense][license]** (`package.json`
`"license": "Unlicense"`, plus the full `UNLICENSE` text) — an unusually permissive choice for a
widely-used package. It is authored by Rasmus Porsager, `1.0.0` shipped 2019-12-22, and the pinned
checkout is `3.4.9` ([`CHANGELOG.md`][changelog], [`package.json`][pkg]). It is PostgreSQL-only:
the wire protocol, type OIDs, `LISTEN`/`NOTIFY`, logical-replication `subscribe`, `COPY`, and
large objects are all Postgres-specific, with no dialect abstraction (contrast the multi-backend
`Effect TS` core). It is a zero-dependency package with ESM, CJS, Deno, and Cloudflare-Workers
builds, and is broadly adopted across the Node/Deno/Bun/serverless ecosystem (web-attested), with
first-class Cloudflare Workers + Hyperdrive support ([`README.md`][readme]). It ships hand-written
TypeScript declarations (`types/index.d.ts`), typed well enough for row-shape assertions but not
for schema-level checking.

## Strengths

- **Injection-safe by construction.** Every non-fragment interpolation becomes a bound `$n`
  parameter; the only unsafe path is an explicit, greppable `sql.unsafe`.
- **One unified `sql`.** The same value is the query tag, the identifier escaper, and the
  clause-aware fragment builder — a single import and one mental model that composes cleanly.
- **Safe dynamic queries.** Fragments nest and merge their parameters, so conditional
  `where`/`insert`/`update`/`order by`/`in` assembly needs no string concatenation.
- **Thin and portable.** Zero dependencies, direct wire protocol (no `libpq`), running on
  Node, Deno, Bun, and Cloudflare Workers, exposing Postgres-native features (`LISTEN`/`NOTIFY`,
  logical replication, `COPY` streams, cursors, large objects).
- **Plain Promises.** A query is a thenable; adoption cost is essentially zero and it interops
  with any `async`/`await` code — no runtime to buy into.
- **Batteries included at the driver rung.** Built-in pool, `sql.begin` transactions with
  savepoints, `sql.reserve`, casing transforms, custom types, prepared-statement caching.
- **Permissive licence.** Public domain (Unlicense).

## Weaknesses

- **PostgreSQL only.** No MySQL/SQLite/others; every abstraction is Postgres-specific.
- **Driver-level — you write all the SQL.** No query builder, no typed columns, no schema
  awareness; correctness of the SQL itself is on you.
- **No compile-time query checking.** Row types are asserted (`` sql<T[]>`…` ``), not verified;
  nullability is not modeled. A wrong column name is a runtime error.
- **Untyped error channel.** Failures are thrown `Error`/`PostgresError` objects with a `code`
  string; no discriminated reason union or retryability flag to match on structurally.
- **Runtime-enforced safety.** The tagged-template requirement is checked at runtime (a mis-called
  helper throws `NOT_TAGGED_CALL`), not by the type system.
- **Implicit builder dispatch.** `sql(obj)` picks `insert`/`update`/`values`/… by _sniffing the
  preceding SQL text_ — powerful but magical, and historically a source of mis-match bugs.
- **No migrations / ORM / codegen.** Out of scope by design; bring your own.
- **Laziness foot-guns.** A query never awaited (nor `.execute()`d) silently never runs; execution
  timing is one microtask deferred.

## Key design decisions and trade-offs

| Decision                                                                       | Rationale                                                                                              | Trade-off                                                                                                            |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| One overloaded `sql` dispatched on argument shape (tag / identifier / builder) | One import, one primitive; the query tag and the fragment builder unify                                | Behaviour depends on _how_ you call it; a string is an identifier, an object is a builder — surprising until learned |
| Every non-fragment interpolation → `$n` bound parameter                        | Injection safety is the path of least resistance; no manual escaping                                   | You cannot interpolate identifiers/keywords as values — must reach for the `sql()` helper; `undefined` is rejected   |
| `Builder` chooses a clause helper by reading the preceding SQL                 | `sql(obj)` "just works" as `insert`/`update`/`values`/`in` by position                                 | Implicit and regex-driven; can mis-match, and the semantics aren't visible at the call site                          |
| `Query extends Promise`, lazy until awaited / `.execute()`                     | Thenable ergonomics; laziness distinguishes nested fragments from the outer query                      | Subtle one-tick timing; a query built but never consumed silently never executes                                     |
| Plain Promises, no effect system                                               | Zero adoption cost; interops with all `async`/`await` code                                             | No typed error channel, no scoped-resource safety, no query-as-value composition ([contrast `Effect TS`][effect-ts]) |
| `postgres()` returns a built-in pooled `sql`                                   | Simplest possible surface — `const sql = postgres()` is the entire setup                               | Execution order isn't guaranteed without a transaction or `max: 1`; pool internals are hidden                        |
| Transactions via a scoped callback `sql`; nesting → savepoints                 | Connection pinning is automatic and correct; nested `sql.savepoint` maps to `SAVEPOINT`/`ROLLBACK TO`  | Must use `sql.begin` (a bare `begin` errors `UNSAFE_TRANSACTION`); the scoped `sql` is a distinct instance           |
| PostgreSQL-only, direct wire protocol (no `libpq`)                             | Full native access (`LISTEN`/`NOTIFY`, logical replication, `COPY`, cursors); runs on Deno/Bun/Workers | Locked to Postgres; no dialect layer                                                                                 |
| No schema / migrations / ORM / codegen                                         | Stays a thin, focused driver — "way out of scope"                                                      | You own all SQL and all types; no compile-time schema safety                                                         |

---

## Sources

- [`src/index.js`][index] — the `postgres()` factory; the overloaded `sql(strings, …args)` dispatch (`Query`/`Identifier`/`Builder`); the pool queues; `reserve`; `begin`/`scope`/`savepoint`; `listen`/`notify`.
- [`src/types.js`][types] — `handleValue` (`$n` binding), `Builder`/`builders` (clause dispatch), `escapeIdentifier`, `Parameter`/`Identifier`/`NotTagged`, default type codecs, casing transforms, array (de)serialization.
- [`src/query.js`][query] — `Query extends Promise`; lazy `handle`/`then`/`catch`/`finally`; `.cursor`/`.forEach`/`.simple`/`.raw`/`.values`/`.describe`/`.execute`.
- [`src/connection.js`][conn] — the wire protocol: auth (`SCRAM`/`MD5`), `Parse`/`Bind`/`Execute`, `DataRow` decoding, `errorFields`, prepared-statement retry, `UNSAFE_TRANSACTION` guard, `COPY`/cursor streams, `fetchArrayTypes`.
- [`src/subscribe.js`][subscribe] · [`src/large.js`][large] · [`src/errors.js`][errors] · [`src/result.js`][result] — logical-replication `subscribe`; large objects; `PostgresError`; the `Result` array subclass.
- [`README.md`][readme] — tagged-template safety statements, dynamic-`sql()` helper docs, building queries, transactions/savepoints, the connection pool, error catalogue, migration-tools disclaimer.
- [`package.json`][pkg] · [`UNLICENSE`][license] · [`CHANGELOG.md`][changelog] — Unlicense, author, `3.4.9`, `v1.0.0` (2019-12-22).
- Shared vocabulary: [`concepts.md`][concepts] — [abstraction ladder][concepts-ladder], [query-construction models][concepts-qcm], [statements/parameters/injection][concepts-inj], [connections & pools][concepts-cps], [effects/transactions/errors][concepts-eth]. Sibling tagged-template exemplar: [Effect TS `sql`][effect-ts].

<!-- References -->

[repo]: https://github.com/porsager/postgres
[readme]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/README.md
[changelog]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/CHANGELOG.md
[pkg]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/package.json
[license]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/UNLICENSE
[index]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/src/index.js
[types]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/src/types.js
[query]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/src/query.js
[conn]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/src/connection.js
[subscribe]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/src/subscribe.js
[large]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/src/large.js
[errors]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/src/errors.js
[result]: https://github.com/porsager/postgres/blob/e7dfa14519f363229ccc3ead7b1b2f2051937efb/src/result.js
[effect-ts]: ./effect-ts.md
[concepts]: ./concepts.md
[concepts-ladder]: ./concepts.md#the-abstraction-ladder
[concepts-qcm]: ./concepts.md#query-construction-models
[concepts-inj]: ./concepts.md#statements-parameters-and-sql-injection
[concepts-cps]: ./concepts.md#connections-pools-and-sessions
[concepts-eth]: ./concepts.md#effects-transactions-and-error-handling
[concepts-dialect]: ./concepts.md#dialects-idioms-and-naming-strategies
[concepts-schema]: ./concepts.md#schema-migrations-code-generation

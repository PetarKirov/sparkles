# Effect (TypeScript)

A comprehensive TypeScript framework providing a fully-fledged functional effect system with typed errors, dependency injection, fiber-based concurrency, and a rich standard library -- essentially ZIO for TypeScript.

| Field         | Value                                                              |
| ------------- | ------------------------------------------------------------------ |
| Language      | TypeScript                                                         |
| License       | MIT                                                                |
| Repository    | [github.com/Effect-TS/effect](https://github.com/Effect-TS/effect) |
| Documentation | [effect.website](https://effect.website)                           |
| Key Authors   | Michael Arnaldi, Giulio Canti, Tim Smart, Maxwell Brown            |
| Encoding      | Fiber-based runtime with three-parameter effect type               |

---

## Overview

### What It Solves

Effect addresses the fragmented state of TypeScript application development. Without Effect, building production-grade applications requires combining multiple specialized libraries for error handling, dependency injection, concurrency, schema validation, serialization, and resource management. Effect unifies these concerns into a single, composable framework with maximum type safety. It replaces ad-hoc `try/catch` error handling, manual promise management, and runtime dependency injection with a principled, type-tracked effect system.

### Design Philosophy

Effect is the spiritual successor to fp-ts (Giulio Canti's functional programming library for TypeScript) and is heavily inspired by Scala's ZIO. The project is pragmatic rather than dogmatic: while it provides all the tools for functional programming, it does not mandate a purely functional style. Classes, imperative code, and incremental adoption are all supported. The core philosophy is that **side effects should be values** -- described, composed, and executed under program control rather than performed immediately.

Effect is designed for tree shakeability: its API surface uses standalone functions (not methods) so bundlers can eliminate unused code. This is a deliberate departure from method-heavy OOP APIs.

---

## Core Abstractions and Types

### Effect<A, E, R>

The central type mirrors ZIO's three-parameter design:

```typescript
Effect<A, E, R>;
```

| Parameter | Meaning                | When never/void              |
| --------- | ---------------------- | ---------------------------- |
| **A**     | Success value type     | `void` = no meaningful value |
| **E**     | Error channel type     | `never` = cannot fail        |
| **R**     | Requirements (context) | `never` = no requirements    |

An `Effect<A, E, R>` is an immutable description of a computation that, when executed, may succeed with a value of type `A`, fail with an error of type `E`, or require services of type `R` from the environment. Effects are values -- they do not execute until explicitly run.

### Common Type Aliases

```typescript
// An effect that cannot fail and needs no environment
Effect<A, never, never>;

// An effect that may fail with E but needs no environment
Effect<A, E, never>;
```

### Current Status

As of early 2026, Effect has entered the **Effect 4.0** era, codenamed **"smol"**. This major release focuses on radical performance improvements, a drastically reduced bundle size, and a simplified core runtime. Key additions in 4.0 include:

- **Core STM**: Software Transactional Memory is now integrated into the core library.
- **Unified Batching**: Dramatic improvements to the automatic query batching system.
- **Mailbox API**: A new high-performance messaging primitive replacing the older Queue patterns for many use cases.

---

## Core Abstractions and Types

### Creating Effects

```typescript
import { Effect } from "effect";

// Succeed with a value
const succeed = Effect.succeed(42);

// Fail with a typed error
const fail = Effect.fail(new HttpError({ status: 404 }));

// Wrap a synchronous computation
const sync = Effect.sync(() => Date.now());

// Wrap a promise
const async = Effect.tryPromise({
  try: () => fetch("https://api.example.com/data"),
  catch: (error) => new NetworkError({ cause: error }),
});
```

### Services and Tags

Services define capabilities that an effect requires. Each service is identified by a unique `Tag`:

```typescript
import { Context, Effect } from "effect";

class Database extends Context.Tag("@app/Database")<
  Database,
  {
    readonly query: (sql: string) => Effect.Effect<unknown[], DatabaseError>;
    readonly execute: (sql: string) => Effect.Effect<void, DatabaseError>;
  }
>() {}

class Logger extends Context.Tag("@app/Logger")<
  Logger,
  {
    readonly info: (msg: string) => Effect.Effect<void>;
    readonly error: (msg: string) => Effect.Effect<void>;
  }
>() {}
```

Services are accessed by yielding the Tag directly inside a generator:

```typescript
const getUser = (id: string) =>
  Effect.gen(function* () {
    const db = yield* Database;
    const logger = yield* Logger;
    const rows = yield* db.query(`SELECT * FROM users WHERE id = '${id}'`);
    yield* logger.info(`Found user: ${id}`);
    return rows[0] as User;
  });
// Inferred type: Effect<User, DatabaseError, Database | Logger>
```

The `R` parameter accumulates all required services automatically through composition.

---

## How Handlers/Interpreters Work

### Generator-Based Composition

`Effect.gen` allows writing sequential effectful code using JavaScript generators. It is the primary composition mechanism and plays the same role as `async/await` but with full effect tracking:

```typescript
const program = Effect.gen(function* () {
  const config = yield* ConfigService;
  const db = yield* Database;
  const user = yield* db.query(
    `SELECT * FROM users WHERE id = '${config.adminId}'`,
  );
  return user;
});
```

`yield*` replaces `await`. Each yielded effect adds its error and requirement types to the composite effect. If any step fails, execution stops and the error propagates -- similar to how exceptions work, but tracked at the type level.

### Pipe and Flow Composition

For point-free and pipeline-style composition, Effect provides `pipe` and `Effect.pipe`:

```typescript
import { pipe } from "effect";

const result = pipe(
  Effect.succeed(5),
  Effect.map((n) => n * 2),
  Effect.flatMap((n) => Effect.succeed(`Result: ${n}`)),
  Effect.tap((s) => Effect.log(s)),
);
```

Functions are tree-shakeable because unused operators are not bundled.

### The Layer System

`Layer<ROut, E, RIn>` is a blueprint for constructing services from their dependencies. Layers are the idiomatic way to wire up dependency graphs:

```typescript
import { Layer } from "effect";

const DatabaseLive = Layer.effect(
  Database,
  Effect.gen(function* () {
    const config = yield* ConfigService;
    const pool = yield* createPool(config.dbUrl);
    return {
      query: (sql) => Effect.tryPromise(() => pool.query(sql)),
      execute: (sql) => Effect.tryPromise(() => pool.execute(sql)),
    };
  }),
);

const LoggerLive = Layer.succeed(Logger, {
  info: (msg) => Effect.log(msg),
  error: (msg) => Effect.logError(msg),
});
```

Layers compose with `Layer.provide`, `Layer.merge`, and `Layer.provideMerge`:

```typescript
const AppLayer = DatabaseLive.pipe(
  Layer.provideMerge(LoggerLive),
  Layer.provide(ConfigLive),
);

// Run the program with all dependencies provided
Effect.runPromise(program.pipe(Effect.provide(AppLayer)));
```

Key properties of layers:

- **Automatic memoization**: Each layer is constructed once per scope
- **Resource management**: Layers integrate with `Scope` for cleanup
- **Compile-time verification**: Missing dependencies are caught by the type checker

### Error Handling

Errors are tracked at the type level. The `E` parameter composes automatically:

```typescript
const handled = program.pipe(
  Effect.catchTag("DatabaseError", (e) => Effect.succeed({ fallback: true })),
  Effect.catchAll((e) => Effect.logError(`Unhandled: ${e}`)),
);
```

`Effect.either` wraps the result to prevent short-circuiting:

```typescript
const safe = Effect.gen(function* () {
  const result = yield* Effect.either(riskyOperation);
  // result: Either<Error, Success> -- execution continues regardless
});
```

---

## Performance Approach

### Fiber-Based Concurrency

Effect uses lightweight fibers (green threads) managed by the Effect runtime:

```typescript
const concurrent = Effect.gen(function* () {
  const fiber1 = yield* Effect.fork(fetchUser("alice"));
  const fiber2 = yield* Effect.fork(fetchUser("bob"));
  const alice = yield* Fiber.join(fiber1);
  const bob = yield* Fiber.join(fiber2);
  return [alice, bob];
});
```

- Fibers are cheap to create (thousands or millions can be active)
- `Effect.fork` creates a child fiber attached to the parent's scope
- When the parent fiber terminates, child fibers are automatically interrupted (structured concurrency)
- Fibers support interruption with resource safety via finalizers

### Scope and Resource Management

`Scope` manages resource lifecycles across fiber boundaries:

```typescript
const managed = Effect.acquireRelease(
  openConnection(), // acquire
  (conn) => closeConnection(conn), // release (runs even on interruption)
);
```

Finalizers run even when fibers are interrupted, ensuring no resource leaks.

### Concurrency Primitives

| Primitive   | Purpose                                         |
| ----------- | ----------------------------------------------- |
| `Fiber`     | Lightweight concurrent execution unit           |
| `Semaphore` | Limit concurrent access to a resource           |
| `Queue`     | Bounded/unbounded async producer-consumer queue |
| `Ref`       | Atomic mutable reference                        |
| `Deferred`  | Single-value async communication                |
| `Latch`     | Synchronization barrier for multiple fibers     |

### Tree Shakeability

The function-based API design means bundlers can eliminate unused Effect modules. Methods on classes are not tree-shakeable, so Effect deliberately avoids method-heavy APIs.

---

## Composability Model

### Schema for Validation and Serialization

Effect includes a built-in schema library for defining, validating, and transforming structured data:

```typescript
import { Schema } from "effect";

const User = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  age: Schema.Number.pipe(Schema.positive()),
  email: Schema.String.pipe(Schema.pattern(/@/)),
});

type User = Schema.Schema.Type<typeof User>;

const decode = Schema.decodeUnknown(User);
// Returns Effect<User, ParseError>
```

Schema replaces libraries like Zod or io-ts with an Effect-native solution that integrates with the error channel.

### Ecosystem Packages

Effect is organized as a monorepo with composable packages:

| Package            | Purpose                                               |
| ------------------ | ----------------------------------------------------- |
| `effect`           | Core runtime, fibers, layers, schema                  |
| `@effect/platform` | Multi-runtime abstractions (Node, Bun, Deno, browser) |
| `@effect/sql`      | Database access (Postgres, MySQL, SQLite, ClickHouse) |
| `@effect/cluster`  | Distributed systems, RPC, cluster coordination        |
| `@effect/workflow` | Durable workflow execution                            |

The `@effect/platform` package provides runtime-agnostic abstractions. Applications switch runtimes by changing only the Layer at the entry point (e.g., `NodeContext.layer` to `BunContext.layer`) with no changes to business logic.

### Comparison to ZIO

Effect is essentially ZIO ported to TypeScript:

| ZIO Concept          | Effect Equivalent                  |
| -------------------- | ---------------------------------- |
| `ZIO[R, E, A]`       | `Effect<A, E, R>`                  |
| `ZLayer[In, E, Out]` | `Layer<Out, E, In>`                |
| `ZIO.serviceWithZIO` | `yield* Tag` inside `Effect.gen`   |
| `for` comprehension  | `Effect.gen(function* () { ... })` |
| Fiber runtime        | Fiber runtime                      |
| `ZIO.provide`        | `Effect.provide`                   |
| ZIO Test             | `@effect/vitest` / testing utils   |

The key divergence is that Effect leverages TypeScript's generator protocol (`yield*`) for monadic composition instead of Scala's `for` comprehensions. The parameter order is also reversed: `Effect<A, E, R>` puts the success type first.

---

## Strengths

- **Unified framework**: Replaces multiple libraries (Zod, RxJS, Lodash, dependency injection frameworks) with a single coherent system
- **Full type-level error tracking**: Every possible error is visible in the type signature
- **Incremental adoption**: Can be scoped to a single function or module without rewriting the entire application
- **Generator-based syntax**: Reads like imperative code while maintaining full effect tracking
- **Tree-shakeable API**: Function-based design enables efficient bundling
- **Multi-runtime support**: Same business logic runs on Node.js, Bun, Deno, and browsers
- **Active ecosystem**: Effect Days conference, production adoption, growing community

## Weaknesses

- **Steep learning curve**: Three type parameters, layers, fibers, and generators require significant upfront investment
- **Verbose type signatures**: `Effect<User, DatabaseError | ValidationError, Database | Logger>` can become unwieldy
- **Not true algebraic effects**: Fixed to two effect channels (E and R); cannot define arbitrary new effect types with custom handlers
- **Generator syntax limitations**: Requires `downlevelIteration` or ES2015+ target in `tsconfig.json`
- **Ecosystem lock-in**: Deep adoption creates coupling to the Effect framework
- **Bundle size**: The core `effect` package is substantial compared to individual specialized libraries
- **Community size**: Still smaller than established alternatives (though growing rapidly)

## Key Design Decisions and Trade-offs

| Decision                               | Rationale                                                     | Trade-off                                                                  |
| -------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Three type parameters (A, E, R)        | Typed errors + DI at type level, mirroring ZIO                | Verbose signatures; learning curve                                         |
| Generator-based composition            | Reads like imperative code; familiar to TS developers         | Requires specific tsconfig; less composable than pipe for point-free style |
| Function-based API (not methods)       | Tree shakeability; extensibility                              | Less discoverable via autocomplete; unfamiliar to OOP developers           |
| Layer system for DI                    | Compile-time verified; automatic memoization; resource safety | Complex API; debugging wiring errors can be difficult                      |
| Batteries-included (Schema, SQL, etc.) | Integrated experience; fewer dependency conflicts             | Larger framework; opinionated choices                                      |
| fp-ts merger                           | Unified community; shared maintenance                         | Breaking changes for fp-ts users migrating                                 |

---

## Sources

- [Effect documentation](https://effect.website)
- [Effect GitHub repository](https://github.com/Effect-TS/effect)
- [Using Generators -- Effect docs](https://effect.website/docs/getting-started/using-generators/)
- [Managing Services -- Effect docs](https://effect.website/docs/requirements-management/services/)
- [Managing Layers -- Effect docs](https://effect.website/docs/requirements-management/layers/)
- [Building Pipelines -- Effect docs](https://effect.website/docs/getting-started/building-pipelines/)
- [Fibers -- Effect docs](https://effect.website/docs/concurrency/fibers/)
- [Scope -- Effect docs](https://effect.website/docs/resource-management/scope/)
- [Effect 3.0 Release](https://effect.website/blog/releases/effect/30/)
- [A gentle introduction to Effect TS](https://blog.mavnn.eu/2024/09/16/intro_to_effect_ts.html)
- [Exploring Effect in TypeScript -- Tweag](https://www.tweag.io/blog/2024-11-07-typescript-effect/)
- [Complete introduction to using Effect -- Sandro Maglione](https://www.sandromaglione.com/articles/complete-introduction-to-using-effect-in-typescript)

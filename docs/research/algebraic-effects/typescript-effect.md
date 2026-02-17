# Effect (TypeScript)

Effect is a production-focused TypeScript effect framework inspired by ZIO, centered on the `Effect<A, E, R>` type and a fiber runtime.

**Last reviewed:** February 16, 2026.

| Field      | Value                                                              |
| ---------- | ------------------------------------------------------------------ |
| Language   | TypeScript                                                         |
| Repository | [github.com/Effect-TS/effect](https://github.com/Effect-TS/effect) |
| Docs       | [effect.website](https://effect.website/)                          |
| License    | MIT                                                                |

---

## Position in This Research Survey

Effect is highly relevant to effect-system practice, but it is not a full algebraic-handler language in the Plotkin/Pretnar sense.

- It provides typed error and environment channels plus rich runtime semantics.
- It does not expose arbitrary user-defined algebraic operations with resumable handlers as a first-class language feature.

That makes it best viewed as an industrial **effect framework** adjacent to algebraic handlers.

---

## Core Model

Effect uses a three-parameter type:

```ts
Effect<A, E, R>;
```

| Parameter | Meaning                | When `never`                 |
| --------- | ---------------------- | ---------------------------- |
| **A**     | Success value type     | `void` = no meaningful value |
| **E**     | Error channel type     | `never` = cannot fail        |
| **R**     | Requirements (context) | `never` = no requirements    |

An `Effect<A, E, R>` is an immutable description of a computation that, when executed, may succeed with `A`, fail with `E`, or require services of type `R`. Effects are values -- they do not execute until explicitly run.

### Generator-Based Composition

`Effect.gen` is the primary composition mechanism, playing the same role as `async/await` but with full effect tracking:

```typescript
import { Effect, Context } from "effect";

class Database extends Context.Tag("@app/Database")<
  Database,
  {
    readonly query: (sql: string) => Effect.Effect<unknown[], DatabaseError>;
  }
>() {}

class Logger extends Context.Tag("@app/Logger")<
  Logger,
  {
    readonly info: (msg: string) => Effect.Effect<void>;
  }
>() {}

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

Each `yield*` adds its error and requirement types to the composite effect. The `R` parameter accumulates all required services automatically.

### The Layer System

`Layer<ROut, E, RIn>` is a blueprint for constructing services from their dependencies:

```typescript
import { Layer } from "effect";

const DatabaseLive = Layer.effect(
  Database,
  Effect.gen(function* () {
    const config = yield* ConfigService;
    const pool = yield* createPool(config.dbUrl);
    return {
      query: (sql) => Effect.tryPromise(() => pool.query(sql)),
    };
  }),
);

// Run the program with all dependencies provided
Effect.runPromise(program.pipe(Effect.provide(AppLayer)));
```

Layers are memoized (each constructed once per scope), integrate with `Scope` for resource cleanup, and provide compile-time verification of missing dependencies.

Sources:

- [Using Generators](https://effect.website/docs/getting-started/using-generators/)
- [Services](https://effect.website/docs/requirements-management/services/)
- [Layers](https://effect.website/docs/requirements-management/layers/)
- [Fibers](https://effect.website/docs/concurrency/fibers/)
- [Scope](https://effect.website/docs/resource-management/scope/)

---

## Project Status (as of February 16, 2026)

### Stable line

The primary `effect` repository publishes an active **3.x** release line (for example, `effect@3.19.17` released February 16, 2026).

Source: [GitHub releases](https://github.com/Effect-TS/effect/releases)

### v4 direction

Effect maintainers publicly describe **Effect 4.0** as "on the way" and host active work in `effect-smol`.

Implication:

- v4 direction is real and active
- but documentation should distinguish "in progress" from "fully released/stable"

Sources:

- [Effect Days 2025 announcement](https://effect.website/blog/events/effect-days-2025/)
- [effect-smol repository](https://github.com/Effect-TS/effect-smol)

---

## Strengths

- Unified architecture for typed errors, dependency injection, and concurrency
- Strong TypeScript ergonomics for large applications
- Active ecosystem and release cadence
- Practical structured-concurrency and resource-safety model

## Trade-offs

- Conceptual overhead (three type parameters, layers, runtime model)
- Framework lock-in risk for deeply integrated codebases
- Runtime abstraction overhead compared to minimal Promise-only code
- Different semantics from true algebraic-handler systems

---

## Comparison Note

Effect and ZIO share similar design goals and type shape:

| ZIO Concept          | Effect Equivalent                  |
| -------------------- | ---------------------------------- |
| `ZIO[R, E, A]`       | `Effect<A, E, R>`                  |
| `ZLayer[In, E, Out]` | `Layer<Out, E, In>`                |
| `ZIO.serviceWithZIO` | `yield* Tag` inside `Effect.gen`   |
| `for` comprehension  | `Effect.gen(function* () { ... })` |
| Fiber runtime        | Fiber runtime                      |

TypeScript constraints (runtime model, type system ergonomics, JS interoperability) lead to different engineering trade-offs than JVM or pure FP language ecosystems.

---

## Sources

- [Effect documentation](https://effect.website/)
- [Effect GitHub repository](https://github.com/Effect-TS/effect)
- [Effect GitHub releases](https://github.com/Effect-TS/effect/releases)
- [Using Generators](https://effect.website/docs/getting-started/using-generators/)
- [Services](https://effect.website/docs/requirements-management/services/)
- [Layers](https://effect.website/docs/requirements-management/layers/)
- [Fibers](https://effect.website/docs/concurrency/fibers/)
- [Scope](https://effect.website/docs/resource-management/scope/)
- [Effect Days 2025](https://effect.website/blog/events/effect-days-2025/)
- [effect-smol repository](https://github.com/Effect-TS/effect-smol)

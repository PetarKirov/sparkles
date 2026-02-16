# Unison

A statically-typed functional programming language with content-addressed code and an algebraic effect system called abilities, designed for distributed computing.

| Field         | Value                                                                                      |
| ------------- | ------------------------------------------------------------------------------------------ |
| Language      | Unison                                                                                     |
| License       | MIT                                                                                        |
| Repository    | [github.com/unisonweb/unison](https://github.com/unisonweb/unison)                         |
| Documentation | [unison-lang.org/docs](https://www.unison-lang.org/docs/)                                  |
| Key Authors   | Paul Chiusano, Runar Bjarnason, Arya Irani                                                 |
| Encoding      | Abilities (algebraic effects) with content-addressed code storage and ambient polymorphism |

---

## Overview

### What It Solves

Unison addresses several interconnected problems. First, it provides an effect system -- called _abilities_ -- that tracks computational effects in types without requiring monadic notation, enabling direct-style effectful programming. Second, it eliminates an entire class of software engineering problems (builds, dependency conflicts, serialization) through content-addressed code: every definition is identified by a hash of its syntax tree rather than by name. Third, it leverages these properties for distributed computing, where code can be transparently deployed and executed across nodes because functions are globally addressable by hash.

### Design Philosophy

Unison's abilities system is directly inspired by the Frank language (Lindley, McBride, McLaughlin, 2017). Like Frank, Unison uses ambient ability polymorphism where effects propagate inward through the typing context rather than accumulating outward. However, Unison diverges from Frank in two key ways: ability polymorphism is provided by ordinary polymorphic type variables rather than implicit ambient propagation, and ability handling uses an explicit `handle ... with` construct rather than overloading function application.

The content-addressed codebase is Unison's other foundational idea. Code is stored as hashed abstract syntax trees in a database (not as text files), managed by the Unison Codebase Manager (UCM). Names are metadata pointing to hashes, so renaming never breaks anything, there are no build steps, and dependency conflicts based on name collisions are eliminated. This design also enables Unison Cloud, where functions can be deployed to remote nodes by hash reference.

---

## Core Abstractions and Types

### Ability Requirements in Types

Abilities appear in function types as annotations in curly braces to the right of arrows:

```unison
-- A pure function: no abilities required
increment : Nat -> Nat
increment n = n + 1

-- A function requiring the IO ability
readFile : Text ->{IO} Text

-- A function requiring multiple abilities
riskyRead : Text ->{IO, Exception} Text

-- A function with an empty ability set (explicitly pure)
pureAdd : Nat -> Nat ->{} Nat
pureAdd a b = a + b
```

The ability set `{IO, Exception}` means the function may perform IO operations and may raise exceptions. An empty set `{}` means the function is guaranteed pure. Omitting the braces entirely makes the function ability-polymorphic.

### The Request Type

The built-in `Request` type is how Unison represents ability operations flowing to handlers:

```unison
-- If e has type {A} T and h has type Request A T -> R,
-- then (handle e with h) has type R
```

`Request` is a special type constructor provided by the runtime. Handlers pattern-match on `Request` values to intercept ability operations.

### Structural vs Unique Types

Unison types (including abilities) can be `structural` or `unique`:

```unison
-- Structural: identified by structure alone
structural ability Store a where
  Store.get : {Store a} a
  Store.put : a ->{Store a} ()

-- Unique: identified by name (the default for types)
unique ability MyLogger where
  MyLogger.log : Text ->{MyLogger} ()
```

Structural types are considered equivalent when their constructors and parameters match structurally. Unique types are distinct even if structurally identical. Most abilities in the standard library are structural.

---

## How Effects Are Declared

### Ability Declarations

An ability is declared with the `structural ability` or `unique ability` keyword, followed by a name, optional type parameters, and a `where` block listing request constructors:

```unison
structural ability Store a where
  Store.get : {Store a} a
  Store.put : a ->{Store a} ()

structural ability Abort where
  Abort.abort : {Abort} a

structural ability Stream e where
  Stream.emit : e ->{Stream e} ()

structural ability Ask a where
  Ask.ask : {Ask a} a
```

Each request constructor is a function signature declaring the operation's arguments, required abilities, and return type. The ability name appears in the curly braces of its own constructors.

### Using Abilities in Functions

Functions declare ability requirements in their type signatures:

```unison
-- This function requires the Store ability
counter : Nat ->{Store Nat} Nat
counter times =
  current = Store.get
  Store.put (current + times)
  Store.get

-- This function requires both Abort and Stream
filteredStream : [Nat] ->{Stream Nat, Abort} ()
filteredStream items =
  List.foreach items cases
    0 -> Abort.abort
    n -> Stream.emit n
```

### Ability Polymorphism

Unison infers ability polymorphism using type variables. A function like `List.map` is ability-polymorphic -- it works whether or not the mapped function performs effects:

```unison
-- The inferred type includes an ability variable g:
-- List.map : (a ->{g} b) -> [a] ->{g} [b]
-- This means map inherits whatever abilities its argument needs
```

---

## How Handlers/Interpreters Work

### The handle ... with Construct

Handlers use `handle ... with` to intercept ability operations from a computation:

```unison
Abort.toOptional : '{g, Abort} a ->{g} Optional a
Abort.toOptional f =
  handle !f with cases
    { a }                 -> Some a
    { Abort.abort -> _ }  -> None
```

The handler receives a `Request Abort a` and pattern-matches on two cases: the _pure case_ `{ a }` where the computation completed without aborting, and the _request case_ `{ Abort.abort -> _ }` where `abort` was called. The underscore discards the continuation since abort terminates execution.

### Continuations and Resuming

When a handler intercepts a request, it receives a _continuation_ representing the rest of the computation. The handler can call, ignore, or multiply-invoke this continuation:

```unison
Store.run : s -> '{g, Store s} a ->{g} a
Store.run initial f =
  go state = cases
    { a }                  -> a
    { Store.get -> resume }    -> handle resume state with go state
    { Store.put s -> resume }  -> handle resume () with go s
  handle !f with go initial
```

In `{ Store.get -> resume }`, the variable `resume` is the continuation. Calling `resume state` provides the value `state` as the return value of `Store.get` and continues execution. The recursive `handle resume ... with go ...` ensures subsequent ability operations are also handled.

### Stateful Handlers

Handlers can thread state by passing updated values through recursive calls:

```unison
Stream.toList : '{g, Stream a} r ->{g} [a]
Stream.toList f =
  go acc = cases
    { _ }                       -> List.reverse acc
    { Stream.emit a -> resume } -> handle resume () with go (a +: acc)
  handle !f with go []
```

Each `emit` appends the emitted value to the accumulator, and the final pure case reverses the accumulated list.

### Nesting Handlers

When a function requires multiple abilities, handlers are nested, each peeling off one ability:

```unison
program : '{Store Nat, Stream Text, Abort} ()

result : Optional [Text]
result =
  Abort.toOptional '(Stream.toList '(Store.run 0 program))
```

The order of nesting determines semantics -- for example, whether state resets on abort depends on which handler is outermost.

---

## Performance Approach

Unison's runtime has evolved through several iterations:

- **Haskell-based interpreter**: The original UCM runtime interprets Unison code via the Haskell-based codebase manager
- **Native runtime**: A newer runtime compiles Unison to native code for improved performance, with ongoing development
- **Content-addressed caching**: Because definitions are identified by hash, compilation results are cached perfectly -- recompilation only occurs when the actual implementation changes, not when names or formatting change
- **Incremental compilation**: The hash-based system provides perfect incremental compilation; changing one function only recompiles its dependents

Ability handling uses continuation-based dispatch. Each ability operation allocates a continuation representing the rest of the computation, which the handler can then invoke. This is standard for algebraic effect implementations and incurs per-operation overhead compared to direct function calls.

The distributed computing model (Unison Cloud) transmits function hashes rather than serialized code, with nodes fetching implementations on demand. This avoids traditional serialization overhead but introduces network latency for cold function lookups.

---

## Composability Model

### Ability Composition

Multiple abilities compose naturally in type signatures as comma-separated lists:

```unison
complexProgram : Text ->{IO, Exception, Store Config, Stream LogEntry} Result
```

Each ability is independent and handled separately. The type system ensures all abilities are handled before a computation can be executed at the top level (with the exception of `IO` and `Exception`, which the UCM runtime handles directly).

### Handler Composition via Nesting

Handlers compose by nesting, with each handler removing one ability from the requirement set:

```unison
-- Start: '{IO, Store Config, Stream LogEntry} Result
-- After Store.run: '{IO, Stream LogEntry} Result
-- After Stream.toList: '{IO} [LogEntry]
-- IO is handled by the runtime
```

### Abilities and Distributed Computing

Abilities integrate with Unison's distributed computing model through the `Remote` ability, which enables forking computations to remote nodes:

```unison
-- The Remote ability enables distributed execution
distributedMap : (a ->{Remote} b) -> [a] ->{Remote} [b]
```

Because Unison code is content-addressed, functions can be transparently shipped to remote nodes -- the receiving node fetches the function implementation by hash. The `Remote` ability makes distribution explicit in the type system while keeping the programming model close to local function calls.

A local handler (`Remote.pure.run`) enables testing distributed programs without deploying to actual infrastructure.

### Built-in Abilities

Unison provides several built-in abilities:

| Ability     | Purpose                               |
| ----------- | ------------------------------------- |
| `IO`        | General input/output operations       |
| `Exception` | Raising failures (typed as `Failure`) |
| `STM`       | Software transactional memory         |
| `Scope`     | Scoped mutable references             |

`IO` and `Exception` are special: they can remain unhandled in the return type of `run` commands, with the UCM runtime providing default handlers.

---

## Strengths

- **Content-addressed code** eliminates builds, dependency conflicts, and serialization problems; enables perfect incremental compilation and caching
- **Direct-style effects** -- no monadic do-notation or transformer stacks; abilities look like ordinary function calls
- **Distributed computing** is a natural extension of the content-addressed model; code deploys by hash reference
- **Effect tracking in types** ensures all side effects are visible in function signatures; pure functions are guaranteed pure
- **Handler swappability** makes testing straightforward -- swap a real IO handler for an in-memory mock with no code changes
- **Rename safety** -- because code is identified by hash, renaming never breaks anything
- **Growing ecosystem** via Unison Share, a platform for publishing and discovering Unison libraries

## Weaknesses

- **Unfamiliar workflow** -- code-as-database rather than text files requires learning new tooling (UCM) and abandoning file-based workflows
- **Small ecosystem** compared to established languages; limited library availability
- **No traditional text files** -- while UCM can render code as text for editing, the database-first model conflicts with standard version control, editors, and CI tooling
- **Performance** is still maturing; the native runtime is under active development
- **Learning curve** for abilities, especially understanding continuations and recursive handler patterns
- **Limited IDE support** -- tooling beyond the UCM and basic editor integration is still developing
- **Vendor coupling** for distributed features -- Unison Cloud is a commercial platform from Unison Computing

## Key Design Decisions and Trade-offs

| Decision                                  | Rationale                                                                             | Trade-off                                                                                         |
| ----------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Content-addressed code                    | Eliminates builds, enables distributed deployment, perfect caching                    | Abandons text-file workflow; incompatible with traditional VCS and tooling                        |
| Abilities over monads                     | Direct-style programming; effects as function properties, not value wrappers          | Less mature ecosystem than Haskell's monad transformer libraries                                  |
| Explicit `handle ... with` (unlike Frank) | Clearer separation between using and handling effects                                 | More verbose than Frank's implicit handler syntax                                                 |
| Structural vs unique abilities            | Structural enables cross-library compatibility; unique prevents accidental conflation | Users must choose correctly; structural abilities can collide if structures match                 |
| Ability polymorphism via type variables   | Integrates with standard parametric polymorphism                                      | More explicit than Frank's invisible effect variables; ability variables appear in inferred types |
| Database-backed codebase                  | Enables semantic versioning, type-indexed search, perfect dependency tracking         | Cannot use grep, git diff, or standard text tools directly on source code                         |
| Unison Cloud as commercial platform       | Funds continued language development through public benefit corporation               | Creates vendor dependency for distributed computing features                                      |

---

## Sources

- [Unison language documentation](https://www.unison-lang.org/docs/)
- [Unison GitHub repository](https://github.com/unisonweb/unison)
- [Abilities and ability handlers (language reference)](https://www.unison-lang.org/docs/language-reference/abilities-and-ability-handlers/)
- [Ability declaration (language reference)](https://www.unison-lang.org/docs/language-reference/ability-declaration/)
- [Writing your own abilities](https://www.unison-lang.org/docs/fundamentals/abilities/writing-abilities/)
- [The big idea: content-addressed code](https://www.unison-lang.org/docs/the-big-idea/)
- [Unison Cloud documentation](https://www.unison.cloud/docs/core-concepts/)
- [Unison annotated bibliography](https://www.unison-lang.org/docs/usage-topics/bibliography/)
- [Do Be Do Be Do (Frank paper, POPL 2017)](https://arxiv.org/abs/1611.09259)
- [About Unison Computing](https://www.unison-lang.org/unison-computing/)

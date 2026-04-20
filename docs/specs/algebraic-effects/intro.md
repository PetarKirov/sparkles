# A Gentle Introduction to [Algebraic Effect Systems][glossary-effect-system]

If you already know D, you already know most of the ingredients needed to understand [algebraic effects][glossary-algebraic-effects]. The unfamiliar part is not the syntax. It is the style of decomposition.

The short version is this:

1. write code in terms of the [capabilities][glossary-capability] it needs
2. keep the meaning of those [capabilities][glossary-capability] separate from the business logic
3. install the meaning locally with [handlers][glossary-handler] or scoped [capabilities][glossary-capability]

That sounds abstract, but the motivation is practical. [Effect systems][glossary-effect-system] are an answer to a problem that grows with program size: once a program does logging, time, configuration, state, filesystem access, [cancellation][glossary-cancellation], concurrency, and failure handling, those concerns start leaking everywhere. The code still compiles, but it becomes harder to test, harder to change, and harder to reason about locally.

This tutorial explains why effect-oriented design exists, why production systems keep converging toward it, and how a D implementation could work today. For the concrete Sparkles design proposals, see the [Direct-Style Proposal] and [Effect-TS Style Proposal]. If a term looks unfamiliar, jump to the [Glossary](#glossary).

## The Problem [Effect Systems][glossary-effect-system] Try to Solve

Consider a small D function:

```d
string loadUserMessage(string userId)
{
    auto path = buildPathFor(userId);
    auto raw = readText(path);
    logger.info("loaded " ~ path);
    return raw.strip;
}
```

At first glance this looks simple. In reality it depends on several things:

1. path construction policy
2. filesystem access
3. logging
4. string allocation and formatting
5. failure behavior if the file is missing

As the program grows, more of these dependencies appear:

1. [cancellation][glossary-cancellation]
2. clocks and timeouts
3. retries and backoff
4. [structured concurrency][glossary-structured-concurrency]
5. configuration scopes
6. test doubles

Without a clear model, these concerns usually end up in one of three places:

1. hidden globals
2. giant argument lists
3. framework-specific control flow

All three scale badly.

Hidden globals destroy [Local Reasoning]. Giant argument lists make APIs noisy without giving structure. Framework-specific control flow often solves one problem by introducing another: your core logic stops looking like ordinary code.

## Why This Style Is Necessary

The need for effect-oriented design is really the need for better boundaries.

Sean Parent's work is useful here. Large systems only stay understandable when each part can be reasoned about locally. That means dependencies must be explicit, contracts must be narrow, and mutation must be disciplined. The same direction appears in the Sparkles guidelines on [Functional & Declarative Programming], [DbI Intro], and [DbI Guidelines].

[Effect systems][glossary-effect-system] help by making these questions explicit:

1. what can this code do
2. who gave it that authority
3. where does that authority stop
4. how are failures, [cancellation][glossary-cancellation], and cleanup handled

That is valuable even if the implementation underneath is "just" ordinary functions and structs.

## What an [Algebraic Effect System][glossary-effect-system] Is

At its core, an [algebraic effect system][glossary-effect-system] has three pieces:

1. [operations][glossary-operation] such as `get`, `put`, `raise`, `yield`, or `sleep`
2. [handlers][glossary-handler] that decide what those [operations][glossary-operation] mean
3. [resumptions][glossary-resumption] for the cases where a [handler][glossary-handler] pauses a computation and later continues it

The research overview in [Algebraic Effects Research] calls this "[operations][glossary-operation] + [handlers][glossary-handler] + [resumptions][glossary-resumption]." The important intuition is simpler:

The code that asks for an [effect][glossary-algebraic-effects] should not have to know the implementation details of that [effect][glossary-algebraic-effects].

For example:

```d
auto cfg = config.ask();
auto token = authState.get();
if (token.expired)
    authError.raise(AuthError.expired);
```

This code is written in terms of [capabilities][glossary-capability]. A [handler][glossary-handler] or scoped environment decides where `config` comes from, how `authState` is stored, and what it means to raise `AuthError`.

## Why This Is Valuable in Production

[Algebraic effects][glossary-algebraic-effects] are sometimes described as a research topic, but the motivation is deeply operational. Production systems need a way to structure:

1. I/O without hidden globals
2. testing without invasive mocking
3. concurrency without thread leaks
4. [cancellation][glossary-cancellation] without undefined cleanup rules
5. error handling without every layer hard-coding policy

The exact implementations differ, but many production ecosystems have converged on effect-shaped designs because the underlying problems are real.

### OCaml: [Direct Style][glossary-direct-style] I/O and [Structured Concurrency][glossary-structured-concurrency]

[OCaml Eio] uses OCaml 5's effect runtime to offer [direct-style][glossary-direct-style] I/O, [structured concurrency][glossary-structured-concurrency], and [capability]-based resource access. A function receives the filesystem or network [capability][glossary-capability] it needs and then writes ordinary sequential-looking code.

That matters in production because services, CLIs, and network applications need:

1. correct cleanup
2. [cancellation][glossary-cancellation] propagation
3. good backtraces
4. explicit authority over files, sockets, and clocks

Eio shows that [effects][glossary-algebraic-effects] are not just about fancy control flow. They are also a discipline for practical systems programming.

### Haskell: Fast [Effect Systems][glossary-effect-system] for Applications

[effectful] and [bluefin] are useful because they show two pragmatic directions.

1. [effectful] uses a concrete runtime model with fast environment lookup, typed effect sets, and [evidence passing][glossary-evidence-passing].
2. [bluefin] uses explicit value-level handles with lexical scoping, which makes multiple same-shape [effects][glossary-algebraic-effects] easy to manage.

These libraries are used for ordinary application structure: configuration, mutable state, errors, logging, resources, and application services. They are not just for toy examples. They are attractive precisely because they give better structure without forcing every program into a slow research encoding.

### Koka: Why the [Effect][glossary-algebraic-effects] Taxonomy Matters

[Koka] is especially useful as a teaching language because it distinguishes:

1. [effects][glossary-algebraic-effects] that resume immediately
2. [effects][glossary-algebraic-effects] that are [abortive][glossary-abortive]
3. [effects][glossary-algebraic-effects] that capture a [continuation][glossary-continuation]

That distinction matters because most production work is in the first two buckets. Reads, writes, configuration lookup, logging, state updates, and ordinary exceptions do not need full [continuation][glossary-continuation] capture. The research in [Theory and Compilation] shows why this matters for performance.

### Java Loom and Related Systems

Not every production system uses algebraic [handlers][glossary-handler] explicitly. [Java Loom] is a good example. Its virtual threads and [structured concurrency][glossary-structured-concurrency] are implemented with [continuation]-like machinery inside the JVM, but the public model is simpler: write [direct-style][glossary-direct-style] code, let the runtime handle suspension and [resumption][glossary-resumption].

That is relevant to D because it shows a recurring pattern:

1. users want [direct style][glossary-direct-style]
2. runtimes increasingly provide structured suspension and [resumption][glossary-resumption]
3. [structured concurrency][glossary-structured-concurrency] is becoming part of the platform model, not just a library trick

## The Big Payoff: Better Local Reasoning

The main benefit is not novelty. It is that a function can say what it needs without saying how the whole world works.

That improves:

1. testing
2. refactoring
3. reuse
4. auditability
5. portability between runtimes

If a function says it needs a clock, [cancellation][glossary-cancellation], and a reader for configuration, you can:

1. provide real implementations in production
2. provide fake implementations in tests
3. narrow or widen the environment explicitly
4. reason about the function without scanning the whole process for globals

This is exactly the kind of boundary discipline emphasized in [Local Reasoning], [Value Semantics], and [Safety].

## Why Not Just Pass Ordinary Arguments?

Sometimes you should. There is nothing magical about [effects][glossary-algebraic-effects].

For small programs, ordinary arguments are enough. The problem appears when a dependency is:

1. logically ambient across many call layers
2. scoped rather than process-global
3. optionally interpreted in different ways
4. part of concurrency, [cancellation][glossary-cancellation], or cleanup semantics

Consider [cancellation][glossary-cancellation]. Passing a `bool* stopped` flag through every layer is technically possible. It is also a poor abstraction. A scoped [cancellation][glossary-cancellation] [capability][glossary-capability] with clear ownership and cleanup rules is a better one.

The same is true for:

1. request-local configuration
2. task-local state
3. resource scopes
4. nursery-style concurrency
5. structured error policies

[Effect systems][glossary-effect-system] are valuable when they turn these recurring ambient concerns into explicit, composable vocabulary types.

## What This Could Look Like in D Today

The direct-style Sparkles design proposal in [Direct-Style Proposal] deliberately starts from D's strengths instead of pretending D is Haskell, Koka, or OCaml.

Those strengths are:

1. value types
2. templates and compile-time introspection
3. UFCS and free-function APIs
4. RAII and `scope`
5. `@safe`, `nothrow`, `pure`, and `@nogc`
6. the ability to write low-level runtime code when necessary

The likely shape of a D implementation is a hybrid.

### The Library-First Core

The core can be implemented today as:

1. zero-sized effect keys
2. explicit handle types
3. typed [effect rows][glossary-effect-row]
4. `Context!(Effects...)` bundles
5. lexical `withX` functions that install scoped [capabilities][glossary-capability]

That gives a D API shaped more like:

```d
auto result =
    withReader!ConfigTag(config, (scope cfg)
    {
        return withCancelScope((scope cancel)
        {
            return runJob(Context!(typeof(cfg), typeof(cancel))(cfg, cancel));
        });
    });
```

than like a giant inheritance hierarchy or a hidden thread-local registry.

This is closer to the production lessons from [effectful], [bluefin], and [OCaml Eio] than to a [free/freer encoding][glossary-free-freer] used as the main runtime.

### Fast Paths for the Common Case

The research in [Theory and Compilation] is useful here. Most [effect][glossary-algebraic-effects] [operations][glossary-operation] in real systems are [tail-resumptive][glossary-tail-resumptive] or [abortive][glossary-abortive]:

1. ask for configuration
2. read or write local state
3. check [cancellation][glossary-cancellation]
4. raise an error

These do not need full [continuation][glossary-continuation] capture. In D, they can compile down to:

1. direct function calls on handles
2. O(1) lookup from a small environment object
3. ordinary unwinding plus RAII for [abortive][glossary-abortive] paths

That is the reason the Sparkles design splits the system into a fast core and an experimental control layer.

## What About Real Algebraic [Handlers][glossary-handler]?

The moment you want user-defined control [effects][glossary-algebraic-effects] like:

1. generators
2. coroutines
3. nondeterminism
4. pausing and resuming computations

you need [continuation][glossary-continuation] machinery.

This is where things get harder. D does not currently have native [delimited continuation][glossary-delimited-continuation] support in the language or druntime. So a full algebraic [handler][glossary-handler] system in D has three plausible implementation strategies.

### 1. Pure Library Encoding

This is the easiest to prototype and the hardest to make fast.

You can represent computations as data and interpret them later. This is good for:

1. tests
2. reference semantics
3. experimentation

It is poor as the main production runtime because it adds allocation and interpretation overhead. The research survey in [Comparison and Analysis] explains why production systems increasingly avoid [free/freer encodings][glossary-free-freer] on hot paths.

### 2. Hybrid Library Runtime

This is the most plausible near-term direction.

Use:

1. ordinary [direct style][glossary-direct-style] for first-order [effects][glossary-algebraic-effects]
2. [one-shot][glossary-one-shot] control tokens for experimental [resumable][glossary-resumption] [effects][glossary-algebraic-effects]
3. [structured concurrency][glossary-structured-concurrency] scopes to constrain where [resumptions][glossary-resumption] may live

This means most code stays simple, while the rare [continuation]-heavy features live behind explicit opt-in APIs.

### 3. Druntime Support

If D ever wanted first-class algebraic [handlers][glossary-handler], druntime support would change the design space dramatically.

Useful hypothetical runtime features would include:

1. segmented fiber stacks or growable task stacks
2. a [one-shot][glossary-one-shot] [continuation][glossary-continuation] object in druntime
3. explicit [prompt][glossary-prompt] tags or [handler][glossary-handler] frames
4. safe `perform` and `resume` intrinsics
5. stack capture and resume hooks integrated with GC, exceptions, and debuggers

The OCaml 5 implementation in [OCaml 5 Effects] is a useful intuition pump here. It uses [one-shot][glossary-one-shot] [continuations][glossary-continuation] on fiber stacks, which keeps the fast path cheap and avoids forcing every function through a [CPS transform][glossary-cps].

For D, a hypothetical druntime extension could look something like:

1. each task or fiber carries a [handler][glossary-handler] stack
2. `perform` walks to the nearest matching [handler][glossary-handler] frame
3. [tail-resumptive][glossary-tail-resumptive] [operations][glossary-operation] can call through directly
4. resumable [operations][glossary-operation] package the current [delimited continuation][glossary-delimited-continuation] into a [one-shot][glossary-one-shot] runtime object
5. `resume` reinstalls the saved handler context and continues execution

To be viable, this would need tight integration with:

1. exception unwinding
2. stack tracing
3. GC root scanning
4. `scope` and lifetime rules
5. synchronization and task scheduling

The [WasmFX] document is also useful here because it shows the shape of a low-level substrate for typed [one-shot][glossary-one-shot] [resumptions][glossary-resumption].

## Why [One-Shot][glossary-one-shot] [Resumptions][glossary-resumption] Matter

Many research systems allow resuming the same [continuation][glossary-continuation] multiple times. That is powerful, but it is also exactly where resource cleanup, aliasing, and lifetime problems get painful.

For D, [one-shot][glossary-one-shot] [resumptions][glossary-resumption] are the natural default because they fit:

1. [affine][glossary-affine] resource ownership
2. RAII cleanup
3. [structured concurrency][glossary-structured-concurrency]
4. predictable performance

This is why the Sparkles design treats [multi-shot][glossary-multi-shot] control as out of scope for the main model. The combination of [Parallelism], [Theory and Compilation], and [Safety] makes the trade-off clear.

## A Practical Mental Model for D Developers

If the phrase "[algebraic effect system][glossary-effect-system]" still feels too abstract, use this simpler mental model:

1. a [capability][glossary-capability] is a typed handle that grants authority
2. a [handler][glossary-handler] is a scope that installs a [capability][glossary-capability] or interprets an [operation][glossary-operation]
3. an [effect row][glossary-effect-row] is a compile-time summary of what a function may need
4. a [resumption][glossary-resumption] is a suspended [continuation][glossary-continuation] that may be resumed under explicit rules

That is already enough to design useful systems in D.

You do not need to start with advanced control [effects][glossary-algebraic-effects]. A valuable D [effect system][glossary-effect-system] can begin with:

1. readers for configuration
2. scoped mutable state
3. typed errors
4. [cancellation][glossary-cancellation]
5. clocks
6. nursery-style concurrency

Then, if the runtime support becomes available, more powerful control [effects][glossary-algebraic-effects] can be layered on top.

## Glossary

The literature uses a lot of overloaded terminology. This section fixes the meaning of each term as it is used in these Sparkles documents.

<a id="glossary-algebraic-effects"></a>

<details>
<summary><code>algebraic effect</code></summary>

An abstract effectful operation such as reading configuration, updating state, raising an error, or yielding control. "Algebraic" means the effect is described by operations and interpreted by handlers rather than hard-coded everywhere.

```d
auto port = config.ask();
state.put(port);
```

In this example, reading configuration and updating state are effects; the code does not say where the configuration lives or how the state is stored.

</details>

<a id="glossary-effect-system"></a>

<details>
<summary><code>effect system</code></summary>

A programming model and usually some static typing machinery for expressing what side effects code may perform or what capabilities it may require.

```d
alias Needs = EffectRow!(Reader!(ConfigTag, Config), Cancel);
```

The row states that the function needs configuration access and cancellation authority.

</details>

<a id="glossary-operation"></a>

<details>
<summary><code>operation</code></summary>

An individual effectful request such as `ask`, `get`, `put`, `raise`, or `yield`.

```d
auto cfg = reader.ask();
```

Here `ask()` is an operation belonging to a reader-like effect.

</details>

<a id="glossary-handler"></a>

<details>
<summary><code>handler</code></summary>

The scope or interpreter that gives an operation its meaning.

```d
withReader!ConfigTag(config, (scope rd)
{
    return run(rd);
});
```

The `withReader` scope is the handler. Inside it, `ask()` knows what value to return.

</details>

<a id="glossary-capability"></a>

<details>
<summary><code>capability</code></summary>

A value that grants permission to do something. Capability-based APIs make authority explicit by requiring the value to be passed in.

```d
void serve(scope Net net, scope Clock clock)
{
    // This function can use the network and the clock,
    // but nothing else unless it receives more capabilities.
}
```

</details>

<a id="glossary-effect-row"></a>

<details>
<summary><code>effect row</code></summary>

A type-level summary of the effects or capabilities required by a function.

```d
alias Needs = EffectRow!(
    Reader!(ConfigTag, Config),
    State!(RequestTag, RequestState),
    Cancel
);
```

Rows are common in the literature even when the exact encoding differs.

</details>

<a id="glossary-direct-style"></a>

<details>
<summary><code>direct style</code></summary>

Ordinary call-return code. The control flow looks like normal sequential code rather than explicit callbacks or nested combinators.

```d
auto txt = file.readAll();
auto parsed = parse(txt);
return parsed;
```

The code reads top to bottom like ordinary D code.

</details>

<a id="glossary-structured-concurrency"></a>

<details>
<summary><code>structured concurrency</code></summary>

A concurrency model where child tasks belong to a parent scope and must finish or be cancelled before the scope exits.

```d
withNursery((scope nursery)
{
    nursery.fork(&taskA);
    nursery.fork(&taskB);
    // Scope does not finish until both tasks are done or cancelled.
});
```

</details>

<a id="glossary-cancellation"></a>

<details>
<summary><code>cancellation</code></summary>

A scoped request to stop ongoing work, usually with cleanup guarantees.

```d
cancel.check(); // throws, returns an error, or otherwise aborts this task
```

The important part is not just stopping, but stopping in a way that preserves resource invariants.

</details>

<a id="glossary-continuation"></a>

<details>
<summary><code>continuation</code></summary>

The "rest of the computation" from a particular point onward.

```d
// Pseudocode:
auto k = captureContinuation();
k.resume(42);
```

Resuming the continuation continues the suspended work as if the original operation returned `42`.

</details>

<a id="glossary-resumption"></a>

<details>
<summary><code>resumption</code></summary>

The act of continuing a suspended computation, or the object used to do so.

```d
resume(token, value);
```

The literature often uses "resumption" when emphasizing the handler's point of view, and "continuation" when emphasizing the captured control state.

</details>

<a id="glossary-tail-resumptive"></a>

<details>
<summary><code>tail-resumptive</code></summary>

An operation whose handler immediately continues the computation without needing to keep extra work after the resume.

```d
auto x = state.get();
state.put(x + 1);
```

Reader and state operations are the classic examples. They are usually the cheapest kind of effect to implement.

</details>

<a id="glossary-abortive"></a>

<details>
<summary><code>abortive</code></summary>

An operation that stops the current computation instead of resuming it.

```d
err.raise(AppError.notFound);
```

Errors and early exits are usually abortive.

</details>

<a id="glossary-delimited-continuation"></a>

<details>
<summary><code>delimited continuation</code></summary>

A captured continuation for only part of the stack, bounded by a handler or prompt rather than the whole program.

```d
// Pseudocode:
withPrompt(tag, {
    perform(tag, value);
});
```

The delimiter says how much of the control stack is captured.

</details>

<a id="glossary-prompt"></a>

<details>
<summary><code>prompt</code></summary>

A boundary that marks where a delimited continuation starts or stops.

```d
auto tag = makePrompt();
withPrompt(tag, &runComputation);
```

Many continuation implementations use prompts internally even if user code never sees them directly.

</details>

<a id="glossary-one-shot"></a>

<details>
<summary><code>one-shot</code></summary>

A continuation or resumption that may be used at most once.

```d
auto k = captureOnce();
k.resume(1);
// k.resume(2); // invalid
```

One-shot models are usually easier to combine with RAII and resource cleanup.

</details>

<a id="glossary-multi-shot"></a>

<details>
<summary><code>multi-shot</code></summary>

A continuation that may be resumed multiple times.

```d
auto k = captureMulti();
auto a = k.resume(1);
auto b = k.resume(2);
```

This is powerful, but harder to implement efficiently and harder to reconcile with linear resource ownership.

</details>

<a id="glossary-affine"></a>

<details>
<summary><code>affine</code></summary>

A value that may be used at most once. In effect systems this often applies to continuations, cleanup tokens, or resources.

```d
struct ResumeOnce
{
    @disable this(this);
}
```

Affine discipline is a natural fit for one-shot resumptions.

</details>

<a id="glossary-cps"></a>

<details>
<summary><code>CPS transform</code></summary>

Continuation-passing style rewrites functions so that they receive an explicit continuation argument instead of returning normally.

```d
// Ordinary style
int add1(int x) => x + 1;

// CPS-style pseudocode
void add1Cps(int x, scope void delegate(int) k)
{
    k(x + 1);
}
```

This is a classic implementation technique for advanced control flow.

</details>

<a id="glossary-evidence-passing"></a>

<details>
<summary><code>evidence passing</code></summary>

A compilation strategy where calls carry explicit proof or lookup data showing which handler should interpret an effect.

```d
struct Context(E...)
{
    // Carries the evidence needed to satisfy requests for E.
}
```

The big benefit is fast dispatch without runtime stack search.

</details>

<a id="glossary-free-freer"></a>

<details>
<summary><code>free / freer encoding</code></summary>

A way of representing effectful computations as data structures that are interpreted later.

```d
// Pseudocode:
auto program = getConfig.then!(cfg => putState(cfg.port));
auto result = interpret(program);
```

This is great for clarity and experimentation, but often slower than direct runtimes.

</details>

## Where to Go Next

1. Read the [Direct-Style Proposal] and [Effect-TS Style Proposal] for the concrete Sparkles design proposals.
2. Use [Algebraic Effects Research] to compare ecosystems and terminology.
3. Read [Theory and Compilation] for the runtime and performance intuition.
4. Read [OCaml Eio], [effectful], [bluefin], and [Koka] for the most relevant reference points.
5. Re-read [Local Reasoning] and [DbI Guidelines] with [effects][glossary-algebraic-effects] in mind. They explain why the shape of the API matters as much as the runtime.

## References

- [Direct-Style Proposal]
- [Effect-TS Style Proposal]
- [Comparison]
- [Functional & Declarative Programming]
- [DbI Intro]
- [DbI Guidelines]
- [Algebraic Effects Research]
- [Comparison and Analysis]
- [Theory and Compilation]
- [Parallelism]
- [Koka]
- [effectful]
- [bluefin]
- [OCaml 5 Effects]
- [OCaml Eio]
- [Java Loom]
- [WasmFX]
- [Sean Parent: Better Code]
- [Local Reasoning]
- [Value Semantics]
- [Safety]

[Direct-Style Proposal]: ./proposal-direct-style.md
[Effect-TS Style Proposal]: ./proposal-effect-ts-style.md
[Comparison]: ./comparison.md
[Functional & Declarative Programming]: ../../guidelines/functional-declarative-programming-guidelines.md
[DbI Intro]: ../../guidelines/design-by-introspection-00-intro.md
[DbI Guidelines]: ../../guidelines/design-by-introspection-01-guidelines.md
[Algebraic Effects Research]: ../../research/algebraic-effects/
[Comparison and Analysis]: ../../research/algebraic-effects/comparison.md
[Theory and Compilation]: ../../research/algebraic-effects/theory-compilation.md
[Parallelism]: ../../research/algebraic-effects/parallelism.md
[Koka]: ../../research/algebraic-effects/koka.md
[effectful]: ../../research/algebraic-effects/haskell-effectful.md
[bluefin]: ../../research/algebraic-effects/haskell-bluefin.md
[OCaml 5 Effects]: ../../research/algebraic-effects/ocaml-effects.md
[OCaml Eio]: ../../research/algebraic-effects/ocaml-eio.md
[Java Loom]: ../../research/algebraic-effects/java-loom.md
[WasmFX]: ../../research/algebraic-effects/wasmfx.md
[Sean Parent: Better Code]: ../../research/sean-parent/
[Local Reasoning]: ../../research/sean-parent/local-reasoning.md
[Value Semantics]: ../../research/sean-parent/value-semantics.md
[Safety]: ../../research/sean-parent/safety.md
[glossary-algebraic-effects]: #glossary-algebraic-effects
[glossary-effect-system]: #glossary-effect-system
[glossary-operation]: #glossary-operation
[glossary-handler]: #glossary-handler
[glossary-capability]: #glossary-capability
[glossary-effect-row]: #glossary-effect-row
[glossary-direct-style]: #glossary-direct-style
[glossary-structured-concurrency]: #glossary-structured-concurrency
[glossary-cancellation]: #glossary-cancellation
[glossary-continuation]: #glossary-continuation
[glossary-resumption]: #glossary-resumption
[glossary-tail-resumptive]: #glossary-tail-resumptive
[glossary-abortive]: #glossary-abortive
[glossary-delimited-continuation]: #glossary-delimited-continuation
[glossary-prompt]: #glossary-prompt
[glossary-one-shot]: #glossary-one-shot
[glossary-multi-shot]: #glossary-multi-shot
[glossary-affine]: #glossary-affine
[glossary-cps]: #glossary-cps
[glossary-evidence-passing]: #glossary-evidence-passing
[glossary-free-freer]: #glossary-free-freer
[capability]: #glossary-capability
[continuation]: #glossary-continuation

# Proposal A: Direct-Style Algebraic Effect System

## Status

Draft v0.1 (Proposal A)

## Goal

Design a D-native algebraic effect system for Sparkles using a direct-style architecture (passing a `Context` bundle explicitly) with:

1. A production-friendly core that works as a library on current D compilers.
2. Typed effect-set tracking at API boundaries.
3. Explicit scoped capabilities with strong local reasoning.
4. Structured concurrency, cancellation, and RAII cleanup as first-class semantics.
5. An opt-in experimental control layer for one-shot resumable handlers.

## Design Principles

This design explicitly applies the Sparkles guidelines and research conclusions from [Functional & Declarative Programming], [DbI Guidelines], [Algebraic Effects Research], and [Sean Parent: Better Code]:

1. Local reasoning and explicit contracts.
2. Value semantics where honest, explicit affinity where required.
3. Functional, composable APIs built from free functions and UFCS.
4. Design by introspection: small shell, optional hooks, centralized capability detection.
5. Separate pure description from execution policy whenever possible.
6. Optimize the common first-order path without promising runtime features D does not have.

## Delivery Target

The primary target is a library implementation on today's D, with an experimental extension path for lower-level control/runtime work later. This follows the trade-offs documented in [Comparison and Analysis], [Theory and Compilation], [effectful], [bluefin], [OCaml 5 Effects], and [OCaml Eio].

## Non-Goals

1. Multi-shot continuations in the main runtime model.
2. A Koka-style compiler-integrated effect inference system.
3. Hidden ambient handlers, thread-local global effect state, or implicit dynamic stacks.
4. Free/freer tree interpretation as the production execution path.
5. Unstructured spawn or detached background work in the core concurrency model.

## Deliverables

1. Docs-visible specification under `docs/specs/algebraic-effects/`.
2. A core library package for first-order effects and structured concurrency.
3. An experimental control package for resumable effects.
4. Compile-time and runtime test suites covering capability traits, semantics, and safety rules.

## High-Level Architecture

The system is split into two layers.

### Layer 1: Core Effects

This is the default production surface.

1. Works in direct style.
2. Uses explicit scoped handles introduced lexically by handlers.
3. Tracks required effects statically through explicit type-level rows.
4. Executes common operations as direct calls or O(1) context lookups.
5. Treats structured concurrency, cancellation, and resource cleanup as mandatory semantics.

This layer is most strongly informed by [effectful], [bluefin], [OCaml Eio], and [Scala 3 Capabilities].

### Layer 2: Experimental Control Effects

This layer is opt-in and deliberately narrower.

1. Supports resumable operations only for selected control effects.
2. Uses one-shot resumptions only.
3. Forbids continuation escape across resource scopes, borrowed references, or scheduler boundaries.
4. Exists behind a separate namespace and separate capability traits so the core layer stays simple and fast.

This layer is constrained by [Theory and Compilation], [OCaml 5 Effects], [Parallelism], and the limits summarized in [Comparison and Analysis].

## Public Model

### Effect Keys

Effects are identified by explicit key types, not by payload type alone.

Examples:

```d
struct Console;
struct Clock;
struct Cancel;
struct Nursery;
struct MainConfigTag;
struct RequestTag;

struct Reader(Tag, T);
struct State(Tag, S);
struct Error(Tag, E);
```

The `Tag` parameter distinguishes multiple effects with the same payload shape, following the named-handle and value-level capability direction described in [bluefin], [Koka], and [Scala 3 Capabilities].

### Effect Rows

Static effect requirements are represented as explicit type-level rows:

```d
alias Required = EffectRow!(
    Reader!(MainConfigTag, Config),
    State!(RequestTag, RequestState),
    Error!(RequestTag, AppError),
    Cancel,
    Nursery
);
```

Rules:

1. Rows are explicit, not inferred.
2. Row operations such as merge, subtraction, and membership are compile-time utilities.
3. Row normalization preserves distinct tagged instances.
4. Missing effects fail at the API boundary with clear diagnostics.

This keeps the static surface closer to D-friendly explicit rows than to full inference-heavy systems such as [Koka].

### Context

`Context!(E...)` is the ergonomic bundle for active handles.

```d
struct Context(Effects...)
{
    // Stores the active handles for the listed effects.
}
```

Rules:

1. `Context` is a value-level bundle, not hidden global state.
2. Lookup is by exact effect key and must be O(1) or compile-time direct where possible.
3. Reusable APIs may accept a `scope Context!(...)` instead of many individual handles.
4. Explicit handles remain the semantic ground truth; `Context` is only a bundling convenience.

### Handles

Handles are the primitive operational interface.

Examples:

```d
auto n = st.get();
st.put(n + 1);
auto cfg = rd.ask();
err.raise(AppError.init);
cancel.check();
nursery.fork(&worker);
```

Rules:

1. Operations are free functions or UFCS-enabled free functions.
2. Handles introduced by `withX` scopes must not escape.
3. Handles for resources, cancellation scopes, nurseries, and future resumptions are affine when needed.
4. If a handle cannot honestly be regular, the type must make that visible.

This is aligned with [Local Reasoning], [Value Semantics], and [Safety].

### Handler Introduction

Effects are introduced lexically:

```d
auto result =
    withReader!(MainConfigTag)(cfg, (scope rd)
    {
        return withState!(RequestTag)(RequestState.init, (scope st)
        {
            return withError!(RequestTag, AppError)((scope err)
            {
                return runApp(Context!(typeof(rd), typeof(st), typeof(err))(rd, st, err));
            });
        });
    });
```

Required handler forms:

1. `withReader`
2. `withState`
3. `withError`
4. `withCancelScope`
5. `withNursery`
6. `withResource` or `bracket`-style scoped resources

Handler nesting defines precedence and semantics. No separate global resolution order exists.

### Operation Classes

The runtime distinguishes three operation classes and generates different machinery for each.

#### Tail-Resumptive

Examples: `Reader.ask`, `State.get`, `State.put`, clock reads.

Rules:

1. Resume exactly once and immediately.
2. Must stay on the zero-allocation fast path.
3. Compile to direct handle calls or O(1) context lookup.

This follows the compilation guidance in [Theory and Compilation].

#### Abortive

Examples: `Error.raise`, cancellation, early-return style exits.

Rules:

1. Do not capture continuations.
2. Unwind to the nearest lexical handler.
3. Must run cleanup deterministically.

#### General Resumable

Examples: user-defined control effects such as `yield`, `choose`, or protocol-driven pause/resume.

Rules:

1. Available only in the experimental control layer.
2. Continuations are one-shot.
3. Resume-twice and escape-after-scope are hard errors.
4. Crossing thread, domain, or resource boundaries is forbidden unless a later experiment proves it safe.

### Higher-Order Operations

Higher-order behaviors are not primitive effect ops in the core layer. They are library combinators elaborated into smaller pieces.

This includes:

1. `local`
2. `catch`
3. `bracket`
4. masking and cleanup regions
5. `timeout`
6. resource scopes

Rationale:

1. This keeps the core algebra first-order and tractable.
2. It avoids the known unsoundness traps around higher-order handlers.
3. It fits D's strengths: RAII, `scope`, and explicit lexical structure.

This reflects the direction argued by [Comparison and Analysis], [Theory and Compilation], and [Koka].

## Structured Concurrency

Concurrency is modeled as a scoped capability, not a free-floating effect.

Required semantics:

1. Every child task belongs to a `Nursery` or switch-like scope.
2. Exiting the scope guarantees all child tasks are complete or cancelled.
3. Sibling failure triggers structured cancellation.
4. Cleanup runs before the scope returns.
5. Detached fire-and-forget work is out of scope for the core model.

The concurrency API should support:

1. `fork`
2. `join`
3. `both`
4. `all`
5. `race`
6. cancellation propagation
7. timeouts built from cancellation and clock capabilities

This section is primarily motivated by [OCaml Eio], [Concurrency], and [Parallelism].

## Safety and Attributes

The public surface defaults to the strongest practical attributes:

1. `@safe` by default.
2. `pure` where the operation only depends on explicit inputs and handles.
3. `nothrow` where abortive paths are encoded as values or controlled unwinds.
4. `@nogc` where the chosen handles and storage strategy allow it.

Rules:

1. Attribute propagation must be documented and tested.
2. Unsafe code belongs only in small audited kernels.
3. Fast paths must remain behaviorally equivalent to fallback paths.

This section follows [DbI Guidelines], [Functional & Declarative Programming], and [Safety].

## Capability Detection and DbI Rules

Capability detection is centralized in one detail module.

Required trait families:

1. `hasHandleLookup!(Ctx, EffectKey)`
2. `supportsEffect!(Ctx, EffectKey)`
3. `canFork!NurseryHandle`
4. `canResumeOnce!ResumeToken`
5. `isAbortiveEffect!EffectKey`
6. `isTailResumptiveEffect!EffectKey`

Rules:

1. Traits must check the exact expression that the runtime calls.
2. Business logic must not scatter ad hoc `__traits(compiles)` checks.
3. `void` or empty-hook baselines must compile for the generic shells that permit them.

These rules are inherited directly from [DbI Intro] and [DbI Guidelines].

## Core API Shape

The system uses a hybrid surface:

1. Boundary APIs declare typed effect rows explicitly.
2. Internal implementations may accept either explicit handles or a `Context`.
3. Convenience layers may reduce manual threading, but they must lower to explicit handles and lexical scopes.

This hybrid surface balances the explicitness of [bluefin] with the bundling ergonomics suggested by [effectful] and [Scala 3 Capabilities].

Illustrative boundary pattern:

```d
Result runRequest(Ctx)(scope Ctx ctx)
if (supportsAll!(Ctx, EffectRow!(
    Reader!(MainConfigTag, Config),
    State!(RequestTag, RequestState),
    Error!(RequestTag, AppError),
    Cancel,
    Nursery
)))
{
    // ...
}
```

## Experimental Control Layer

The experimental namespace exposes explicit control primitives:

1. `perform`
2. `handleControl`
3. `ResumeOnce`
4. control-effect key traits

Restrictions:

1. Deep handlers are the default.
2. Shallow handlers are reserved for protocol/state-machine use cases.
3. Multi-shot semantics are explicitly out of scope.
4. Reference semantics or tree interpreters may exist for testing and research, not for production dispatch.

The restrictions here are intentionally conservative relative to [OCaml 5 Effects], [Parallelism], and [Comparison and Analysis].

## Testing and Verification

Required test categories:

1. Compile-time tests for row membership, row normalization, tagged duplicates, and diagnostics.
2. Scope tests proving handles cannot escape `withX` callbacks.
3. Semantics tests for handler order, reader shadowing, state/error interaction, and cancellation propagation.
4. Structured concurrency tests for sibling cancellation, join guarantees, and cleanup ordering.
5. Attribute tests for `@safe`, `pure`, `nothrow`, and `@nogc` propagation.
6. Experimental control tests for one-shot resume, abort-without-resume, and forbidden cross-scope resume.
7. Performance tests confirming the fast path performs no avoidable allocation.

## Staging Plan

### Stage 1

1. Define effect keys, rows, `Context`, and centralized capability traits.
2. Implement `Reader`, `State`, and `Error`.
3. Add compile-time diagnostics and baseline semantics tests.

### Stage 2

1. Implement `Cancel`, `Clock`, and `Nursery`.
2. Add structured concurrency and timeout combinators.
3. Validate cleanup and cancellation semantics under failure.

### Stage 3

1. Add higher-order library combinators such as `local`, `catch`, and `bracket`.
2. Benchmark direct-handle and bundled-context paths.
3. Tighten `@nogc` and attribute-propagation coverage.

### Stage 4

1. Add the experimental control namespace.
2. Support one-shot resumable effects behind explicit opt-in APIs.
3. Keep production-facing first-order APIs independent from control-layer machinery.

## Acceptance Criteria

The design is successful when:

1. Core first-order effects compose without runtime-global state.
2. API boundaries can state their effect requirements with explicit typed rows.
3. Multiple same-shape effects work through tags and scoped handles.
4. Structured concurrency guarantees hold under success, failure, and cancellation.
5. The experimental control layer does not contaminate the core fast path.

## References

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
- [Scala 3 Capabilities]
- [Sean Parent: Better Code]
- [Local Reasoning]
- [Value Semantics]
- [Concurrency]
- [Safety]

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
[Scala 3 Capabilities]: ../../research/algebraic-effects/scala-capabilities.md
[Sean Parent: Better Code]: ../../research/sean-parent/
[Local Reasoning]: ../../research/sean-parent/local-reasoning.md
[Value Semantics]: ../../research/sean-parent/value-semantics.md
[Concurrency]: ../../research/sean-parent/concurrency.md
[Safety]: ../../research/sean-parent/safety.md

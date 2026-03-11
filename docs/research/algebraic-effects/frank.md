# Frank

A functional programming language with algebraic effect handlers and **ambient ability polymorphism**. Frank eliminates the distinction between effectful and pure functions, making effects implicit in the type system through "abilities."

| Field         | Value                                                   |
| ------------- | ------------------------------------------------------- |
| Language      | Frank                                                   |
| License       | BSD-3-Clause (inferred)                                 |
| Repository    | [Frank GitHub repository]                               |
| Documentation | [Frank README with examples]                            |
| Key Authors   | Sam Lindley, Conor McBride, Craig McLaughlin            |
| Encoding      | Ambient ability polymorphism; call-by-push-value (CBPV) |

---

## Overview

### What It Solves

Frank addresses the "effect annotation burden" problem: in most effect systems, programmers must explicitly track and combine effect annotations. Frank makes effects **implicit** through ambient abilities that propagate automatically through the typing context. This eliminates the `lift` operations and effect tracking boilerplate common in other systems.

### Design Philosophy

Frank is built on **Call-by-Push-Value (CBPV)**, a lambda calculus variant that cleanly separates values (computation producers) from computations (effect producers). Handlers in Frank use **multihandlers** -- pattern matching on multiple operations simultaneously.

The language demonstrates that effect polymorphism can be entirely invisible in source code while remaining rigorous in the type system.

---

## Core Abstractions and Types

### Ambient Abilities

In Frank, effects appear as **abilities** in the type system:

```frank
-- A function that uses the State ability
get : Int -> Int [State Int]

-- A function that uses multiple abilities
process : Int -> Int [State Int, Console]
```

Crucially, **ability polymorphism is invisible**. The function `map` has type:

```frank
map : {A -> B} -> List A -> List B
```

It says nothing about effects! The type system infers that `map` has whatever abilities its function argument has. This is **ambient polymorphism** -- the abilities "float" through the context without explicit annotation.

### Multihandlers

Frank handlers can pattern-match on multiple operations at once:

```frank
handle : Int -> Int [State Int, Error] -> Int
handle seed computation =
  on computation
    return x -> x
    {get -> k} -> handle !k state
    {put x -> k} -> handle !k x
    {raise e -> k} -> -1  -- default value on error
```

The `{op -> k}` syntax binds the continuation as `k`. Note the `!k` syntax for forcing thunks (CBPV explicit computation forcing).

### Call-by-Push-Value

Frank uses CBPV as its core calculus:

- **Values** (type `A`) are inert data: integers, functions, thunks
- **Computations** (type `F A` or `A -> B`) can perform effects
- **Thunking** (`thunk`) suspends a computation into a value
- **Forcing** (`!`) executes a thunked computation

This separation makes effect boundaries explicit in the operational semantics while keeping types clean.

---

## How Effects Are Declared

Effects are declared as **ability signatures**:

```frank
ability State S where
  get : S
  put : S -> Unit

ability Console where
  print : String -> Unit
  read : String
```

Each operation declares its value type and (implicitly) its continuation type. The `State` ability is parameterized by the state type `S`.

---

## How Handlers/Interpreters Work

### Shallow vs Deep Handlers

Frank supports both:

**Shallow handlers** handle one operation and return:

```frank
handleOnce : Int [State Int] -> Int [State Int]
handleOnce computation =
  on computation
    return x -> x
    {get -> k} -> !k 42  -- resume with 42 once
```

**Deep handlers** recursively handle all operations:

```frank
runState : S -> A [State S] -> Pair S A
runState initial computation =
  on computation
    return x -> (initial, x)
    {get -> k} -> runState initial (!k initial)
    {put s -> k} -> runState s (!k unit)
```

### Composition via Nesting

Multiple handlers nest naturally:

```frank
runProgram : Int [State Int, Error] -> Int
runProgram = handleError << runState 0
```

The order of nesting determines semantics, but Frank's ability system ensures this is always explicit in the types.

---

## Composability Model

### Ability Polymorphism

The signature of `map` in most effect systems is:

```haskell
-- In most effect systems
map :: (a -> b) -> List a -> List b        -- loses effect information
mapM :: Monad m => (a -> m b) -> List a -> m (List b)  -- separate monadic version
```

In Frank:

```frank
-- One function handles both pure and effectful cases
map : {A -> B} -> List A -> List B
```

The type system tracks abilities automatically. If the function argument uses `State`, then `map` applied to it requires `State`.

### No Lift Operations

Unlike monad transformer stacks that require `lift` to access effects from deeper layers, Frank's abilities propagate implicitly. There is no "stack" -- abilities are a flat set that the type system tracks.

---

## Strengths

- **Invisible effect polymorphism** eliminates effect variable clutter from source code; the ambient ability propagation is elegant and reduces annotation burden
- **No separate handler syntax** -- functions and handlers share the same mechanism, reducing conceptual overhead
- **No monadic notation needed** -- effects are implicit in the type, so programs read as direct-style code
- **Formal foundations** are thoroughly developed with a sound small-step operational semantics for Core Frank
- **Influenced [Unison]** -- Frank's ambient ability system directly inspired Unison's abilities, demonstrating practical impact

## Weaknesses

- **Research prototype** -- the implementation is not production-ready; it compiles to an interpreted intermediate language
- **CBPV learning curve** -- Call-by-Push-Value differs from familiar call-by-value or lazy semantics
- **No Haskell ecosystem** -- cannot leverage existing Haskell libraries; standalone language
- **Limited documentation** -- primarily academic papers and README; few tutorials
- **Ambiguity challenges** -- invisible polymorphism can make type error messages harder to understand

## Key Design Decisions and Trade-offs

| Decision                     | Rationale                              | Trade-off                             |
| ---------------------------- | -------------------------------------- | ------------------------------------- |
| CBPV core calculus           | Clean value/computation separation     | Unfamiliar to most programmers        |
| Ambient ability polymorphism | Reduced annotation burden              | Type errors can be harder to localize |
| Multihandlers                | Symmetric handling of multiple effects | Handler patterns can be more complex  |
| Invisible effect variables   | Source code readability                | Type inference algorithm complexity   |
| Research language focus      | Exploration of language design         | Limited practical tooling             |

---

## Comparison with Other Languages

| Feature             | Frank               | [Koka]                | [Unison]                   |
| ------------------- | ------------------- | --------------------- | -------------------------- |
| Effect polymorphism | Invisible (ambient) | Visible row variables | Invisible (type variables) |
| Handler style       | Multihandlers       | Deep handlers         | Deep handlers              |
| Core calculus       | CBPV                | Call-by-value         | Call-by-value              |
| Effect syntax       | `[Ability]`         | `<effect>`            | `{Ability}`                |
| Production status   | Research            | Research              | Active development         |
| Implementation      | Interpreter         | Compiler to C/JS/WASM | Runtime + UCM              |

---

## Sources

- [Frank GitHub repository]
- [Do Be Do Be Do (Frank paper, POPL 2017)]
- [Frank README with examples]
- [Call-by-Push-Value book] -- Paul Levy
- [Unison documentation] (for comparison with Frank's influence)

<!-- References -->

[Unison]: unison.md
[Koka]: koka.md
[Frank GitHub repository]: https://github.com/frank-lang/frank
[Do Be Do Be Do (Frank paper, POPL 2017)]: https://arxiv.org/abs/1611.09259
[Frank README with examples]: https://github.com/frank-lang/frank/blob/master/README.md
[Call-by-Push-Value book]: https://doi.org/10.1017/S095679680100422X
[Unison documentation]: https://www.unison-lang.org/docs/

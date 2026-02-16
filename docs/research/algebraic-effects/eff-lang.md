# Eff

The first programming language designed specifically around algebraic effects and handlers, serving as a reference implementation and research vehicle for the theory of computational effects as algebraic operations.

| Field         | Value                                                                       |
| ------------- | --------------------------------------------------------------------------- |
| Language      | Eff                                                                         |
| License       | BSD-2-Clause                                                                |
| Repository    | [github.com/matijapretnar/eff](https://github.com/matijapretnar/eff)        |
| Documentation | [eff-lang.org](https://www.eff-lang.org/)                                   |
| Key Authors   | Andrej Bauer, Matija Pretnar (University of Ljubljana)                      |
| Encoding      | Native algebraic effect handlers with first-class effects and continuations |

---

## Overview

### What It Solves

Eff demonstrates that algebraic effects and handlers can serve as a unified foundation for computational effects. Rather than encoding effects through monads (which compose poorly without transformers) or through ad-hoc language features (exceptions, async, generators), Eff treats all effects uniformly: effects are algebraic operations, and handlers are homomorphisms from free algebras. This gives a single mechanism that subsumes exceptions, state, I/O, nondeterminism, concurrency, and any user-defined effect.

### Design Philosophy

Eff is a research language that embodies the theory of Plotkin and Pretnar's "Handlers of Algebraic Effects" (ESOP 2009) directly in a programming language. The design prioritizes clarity and faithfulness to the algebraic semantics over production concerns like performance or ecosystem size. Eff uses OCaml-like syntax, is statically typed with parametric polymorphism and type inference, and treats both effects and handlers as first-class values. The language serves as a testbed for exploring the expressiveness and composability of algebraic effect handlers.

---

## Core Abstractions and Types

### Effects as Algebraic Operations

In Eff, a computational effect is a set of operation symbols, each with an input and output type. A computation may perform operations; the meaning of those operations is determined by an enclosing handler. This separates the interface of an effect (what operations are available) from its implementation (what the operations do).

### Type System

Eff is statically typed with parametric polymorphism and Hindley-Milner type inference. The types include products, sums, records, and recursive type definitions. The type system is similar to OCaml and other ML-family languages. In later versions, Eff includes an effect system that tracks which effects a computation may perform, with safety guarantees (progress and preservation) proven with respect to the operational semantics.

### First-Class Handlers

Handlers in Eff are first-class values. They can be stored in variables, passed as arguments, and returned from functions. A handler is constructed with the `handler` keyword and applied with `with ... handle ...`:

```eff
let my_handler = handler
  | effect Fail k -> None
  | x -> Some x
```

---

## How Effects Are Declared

Effects are declared by specifying their operation signatures. In modern Eff syntax, an effect is declared with the `effect` keyword followed by the operation name and its type:

```eff
(* A simple exception-like effect *)
effect Fail : empty

(* Nondeterministic choice *)
effect Decide : bool

(* Stateful operations *)
effect Get : int
effect Set : int -> unit
```

Each declaration introduces an operation that computations can perform. The type after the colon describes the return type of the operation (what the handler must provide when resuming). For operations that take arguments, an arrow type is used.

In earlier versions of Eff, effects were grouped into effect types:

```eff
(* Older Eff syntax *)
type choice = effect
  operation decide : unit -> bool
end
```

The modern syntax declares individual effect operations, which is simpler and more compositional.

---

## How Handlers/Interpreters Work

### Handler Structure

A handler in Eff consists of a value clause and zero or more operation clauses:

```eff
handler
  | x -> value_expression           (* value clause: what to do with the final result *)
  | effect Op k -> handler_body     (* operation clause: how to handle the operation *)
```

The value clause transforms the final result of the handled computation. Each operation clause receives the operation's arguments and a continuation `k` representing the rest of the computation after the operation was performed.

### Exception Handler

The simplest handler catches an effect and does not resume:

```eff
let optionalize = handler
  | effect Fail k -> None
  | x -> Some x

with optionalize handle
  let n = perform Get in
  if n < 0 then perform Fail
  else Some n
```

When `Fail` is performed, the handler returns `None` without invoking the continuation `k`. The value clause wraps successful results in `Some`.

### Nondeterminism: Resuming Multiple Times

The power of algebraic effect handlers becomes clear when the continuation is invoked more than once:

```eff
let choose_all = handler
  | effect Decide k -> k true @ k false
  | x -> [x]

with choose_all handle
  let x = (if perform Decide then 10 else 20) in
  let y = (if perform Decide then 0 else 5) in
  x + y
(* Result: [10; 15; 20; 25] *)
```

Each time `Decide` is performed, the handler resumes the continuation twice -- once with `true` and once with `false` -- and concatenates the results. The value clause wraps each leaf result in a singleton list. This implements backtracking search purely through handler composition.

### State Handler

State can be implemented by threading a value through the continuation:

```eff
let state initial = handler
  | effect Get k -> (fun s -> (k s) s)
  | effect (Set s') k -> (fun _ -> (k ()) s')
  | x -> (fun _ -> x)
```

The handler transforms the computation into a function from state to result. `Get` passes the current state to the continuation and threads it through. `Set` replaces the state and continues with unit. The value clause discards the final state, returning only the result.

---

## Performance Approach

Eff is an interpreted language implemented in OCaml. Performance is not a primary design goal; the language exists to explore the semantics and expressiveness of algebraic effects. The interpreter directly implements the operational semantics from the foundational papers, prioritizing correctness and clarity.

For production use of algebraic effects, languages like Koka (evidence passing to C), OCaml 5 (native one-shot continuations), and Multicore OCaml provide efficient compiled implementations. Eff's contribution is on the design and theory side: it demonstrates what is expressible with algebraic effects and serves as a specification against which optimized implementations can be validated.

The companion paper "An Effect System for Algebraic Effects and Handlers" (Bauer, Pretnar 2013) provides the formal type-and-effect system, proving safety of the operational semantics. This theoretical foundation has informed the design of effect systems in production languages.

---

## Composability Model

### Handler Nesting

Effects compose by nesting handlers. The order of nesting determines the interaction semantics:

```eff
(* Nondeterminism outside state: each branch gets independent state *)
with choose_all handle
with state 0 handle
  perform (Set 1);
  if perform Decide then perform Get else 0

(* State outside nondeterminism: state is shared across branches *)
with state 0 handle
with choose_all handle
  perform (Set 1);
  if perform Decide then perform Get else 0
```

This is the same phenomenon seen in monad transformer ordering, but with algebraic effects it arises naturally from handler nesting rather than requiring explicit transformer plumbing.

### First-Class Handler Composition

Because handlers are first-class values, they can be composed programmatically:

```eff
let handle_all comp =
  with optionalize handle
  with state 0 handle
  with choose_all handle
  comp ()
```

### Default Effects and Resources

Eff provides built-in resources that give default behavior to operations interacting with the outside world (standard I/O, file system, etc.). A resource associates a default handler with an effect instance:

```eff
let r = new ref 0 in
perform (r#lookup ())   (* returns 0 *)
perform (r#update 42);
perform (r#lookup ())   (* returns 42 *)
```

Resources can be overridden by enclosing handlers, allowing redirection (e.g., silencing output, redirecting I/O to a buffer, grouping state changes into transactions).

---

## Strengths

- First language built entirely around algebraic effects, directly embodying the theory
- Faithful implementation of Plotkin/Pretnar's algebraic semantics with full continuation support
- First-class handlers enable programmatic composition and abstraction over effect interpretations
- Multi-shot continuations allow expressing backtracking, nondeterminism, and probabilistic programming
- Clean demonstration that exceptions, state, I/O, concurrency, and nondeterminism are all instances of the same mechanism
- OCaml-like syntax lowers the barrier for ML-family programmers
- Static type system with parametric polymorphism and type inference
- Excellent pedagogical value for understanding algebraic effects

## Weaknesses

- Interpreted only; not suitable for performance-sensitive applications
- Small ecosystem with no package manager or third-party library support
- Research language with limited maintenance and no production deployment path
- Earlier versions lacked a proper effect system (types did not track effects)
- No support for concurrency primitives beyond what can be expressed through cooperative handlers
- Documentation is primarily academic papers rather than practical guides
- Multi-shot continuations have inherent performance costs that are not optimized

## Key Design Decisions and Trade-offs

| Decision                   | Rationale                                                                     | Trade-off                                                         |
| -------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| OCaml-like syntax          | Familiarity for ML programmers; straightforward implementation                | Less syntactic innovation compared to Koka or Frank               |
| First-class handlers       | Maximum flexibility; handlers as composable values                            | Harder to optimize than restricted handler forms                  |
| Multi-shot continuations   | Full generality for nondeterminism and backtracking                           | Significant performance cost; cannot reuse one-shot optimizations |
| Interpreted implementation | Rapid iteration on language design; faithful to operational semantics         | Not viable for production workloads                               |
| Resources for I/O          | Provides default behavior for real-world interaction; overridable by handlers | Mixes pure algebraic model with imperative defaults               |
| Separate effect operations | Each operation is independently declared; compositional                       | Loses grouping information compared to effect type declarations   |
| Research-first design      | Clean exploration of the algebraic effect theory space                        | Limited tooling, ecosystem, and community investment              |

---

## Sources

- [Eff GitHub repository](https://github.com/matijapretnar/eff)
- [Eff language website](https://www.eff-lang.org/)
- [Programming with Algebraic Effects and Handlers (Bauer, Pretnar 2012)](https://arxiv.org/abs/1203.1539)
- [An Effect System for Algebraic Effects and Handlers (Bauer, Pretnar 2013)](https://arxiv.org/abs/1306.6316)
- [Handlers of Algebraic Effects (Plotkin, Pretnar 2009)](https://link.springer.com/chapter/10.1007/978-3-642-00590-9_7)
- [An Introduction to Algebraic Effects and Handlers (Pretnar 2015)](https://www.eff-lang.org/handlers-tutorial.pdf)
- [Handling Algebraic Effects (Plotkin, Pretnar 2013, LMCS journal version)](<https://doi.org/10.2168/LMCS-9(4:23)2013>)
- [Eff Directly in OCaml (Kiselyov, Sivaramakrishnan 2018)](https://arxiv.org/abs/1812.11664)

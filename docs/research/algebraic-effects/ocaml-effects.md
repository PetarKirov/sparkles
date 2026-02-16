# OCaml 5 Effects (OCaml)

Native algebraic effect handlers built into the OCaml 5 runtime, providing first-class delimited continuations via fiber-based stack switching.

| Field         | Value                                                                 |
| ------------- | --------------------------------------------------------------------- |
| Language      | OCaml 5.x                                                             |
| License       | LGPL-2.1                                                              |
| Repository    | [github.com/ocaml/ocaml](https://github.com/ocaml/ocaml)              |
| Documentation | [OCaml Manual - Effects](https://ocaml.org/manual/5.2/effects.html)   |
| Key Authors   | KC Sivaramakrishnan, Stephen Dolan, Leo White, Anil Madhavapeddy      |
| Encoding      | Untyped algebraic effects with one-shot continuations on fiber stacks |

---

## Overview

### What It Solves

OCaml 5.0 introduced algebraic effect handlers as a runtime-level mechanism for non-local control flow. Before OCaml 5, exceptions were the only non-local control flow primitive, but they discard the continuation at the raise site. Effect handlers generalize exceptions by capturing a delimited continuation that can be resumed, enabling generators, async/await, lightweight threads, coroutines, and transactional memory as user-level libraries.

### Design Philosophy

The implementation prioritizes backwards compatibility and performance. Rather than adding a full effect type system (still an active research area), OCaml 5 ships effects as an untyped runtime mechanism -- the type system does not track which effects a function may perform. An unhandled effect raises `Effect.Unhandled` rather than a compile-time error. This pragmatic choice allowed shipping a working implementation while typed effect theory matures. The design is described in the PLDI 2021 paper "Retrofitting Effect Handlers onto OCaml" by Sivaramakrishnan et al.

---

## Core Abstractions and Types

The top-level `Effect` module defines the core types:

```ocaml
module Effect : sig
  type _ t = ..                              (* extensible variant *)
  exception Unhandled : 'a t -> exn          (* unhandled effect *)
  exception Continuation_already_resumed     (* one-shot violation *)
  external perform : 'a t -> 'a             (* trigger an effect *)
end
```

`perform` transfers control to the nearest enclosing handler. It is implemented as a fiber stack switch in the runtime. Both `Effect.Deep` and `Effect.Shallow` define a continuation type `('a, 'b) continuation` representing a suspended computation expecting a value of type `'a` and ultimately producing `'b`. Continuations are one-shot -- resuming twice raises `Continuation_already_resumed`.

```ocaml
val continue : ('a, 'b) continuation -> 'a -> 'b       (* resume with value *)
val discontinue : ('a, 'b) continuation -> exn -> 'b    (* resume by raising *)
```

---

## How Effects Are Declared

Effects are declared by extending the extensible variant `Effect.t` with GADT constructors specifying parameter and return types:

```ocaml
type _ Effect.t += Get : int Effect.t               (* returns int *)
                 | Put : int -> unit Effect.t        (* takes int, returns unit *)
                 | Yield : 'a -> unit Effect.t       (* polymorphic parameter *)
```

Since `Effect.t` is extensible, effects can be declared in any module. There is no grouping into "effect signatures" -- each constructor is independent. This differs from the literature, where operations are grouped under named effects.

Performing an effect is straightforward:

```ocaml
let get () = Effect.perform Get
let put v = Effect.perform (Put v)

let example () =
  let x = get () in
  put (x + 1);
  get ()
```

---

## How Handlers/Interpreters Work

### Deep Handlers

Deep handlers handle all effects performed by a computation until it terminates. When a deep handler resumes a continuation, the handler is automatically re-installed around the resumed computation.

The `Effect.Deep` module provides two handler combinators:

```ocaml
(* Full handler: handles return values, exceptions, and effects *)
type ('a, 'b) handler = {
  retc : 'a -> 'b;
  exnc : exn -> 'b;
  effc : 'c. 'c Effect.t -> (('c, 'b) continuation -> 'b) option;
}

val match_with : ('c -> 'a) -> 'c -> ('a, 'b) handler -> 'b

(* Simplified handler: only handles effects *)
type 'a effect_handler = {
  effc : 'b. 'b Effect.t -> (('b, 'a) continuation -> 'a) option;
}

val try_with : ('b -> 'a) -> 'b -> 'a effect_handler -> 'a
```

`match_with f v h` runs `f v` under handler `h`, which specifies all three cases. `try_with f v h` runs `f v` under a handler that only specifies effect cases; return values pass through unchanged and exceptions re-raise.

#### Example: Stateful Computation with Deep Handlers

```ocaml
open Effect
open Effect.Deep

type _ Effect.t += Get : int t
                 | Put : int -> unit t

let run_state (init : int) (comp : unit -> 'a) : 'a =
  let state = ref init in
  match_with comp ()
    { retc = (fun x -> x);
      exnc = (fun e -> raise e);
      effc = fun (type c) (eff : c t) ->
        match eff with
        | Get   -> Some (fun (k : (c, _) continuation) ->
            continue k !state)
        | Put v -> Some (fun (k : (c, _) continuation) ->
            state := v; continue k ())
        | _ -> None }

(* Usage *)
let result = run_state 0 (fun () ->
  let x = perform Get in
  perform (Put (x + 10));
  perform Get)
(* result = 10 *)
```

#### OCaml 5.3 Syntax Sugar

OCaml 5.3 introduced syntactic sugar for deep handlers using the `effect` keyword:

```ocaml
let run_state init comp =
  let state = ref init in
  try comp () with
  | effect Get, k -> continue k !state
  | effect (Put v), k -> state := v; continue k ()
```

The `effect` keyword in a `try...with` block distinguishes effect patterns from exception patterns. This eliminates the verbose `effc` record and explicit locally abstract type annotations required in earlier versions.

### Shallow Handlers

Shallow handlers handle only the first effect performed by a computation. The continuation captured in a shallow handler does not include the handler, so when the continuation is resumed, a new handler must be provided. This makes shallow handlers suitable for enforcing protocols or sequences of effects.

```ocaml
module Shallow = Effect.Shallow

type ('a, 'b) handler = {
  retc : 'a -> 'b;
  exnc : exn -> 'b;
  effc : 'c. 'c Effect.t -> (('c, 'a) continuation -> 'b) option;
}

val fiber : ('a -> 'b) -> ('a, 'b) continuation
val continue_with : ('c, 'a) continuation -> 'c -> ('a, 'b) handler -> 'b
val discontinue_with : ('c, 'a) continuation -> exn -> ('a, 'b) handler -> 'b
```

#### Example: Protocol Enforcement with Shallow Handlers

```ocaml
open Effect
open Effect.Shallow

type _ Effect.t += Send : int -> unit Effect.t
                 | Recv : int Effect.t

(* Enforce alternating Send/Recv protocol *)
let run comp =
  let handler effc_fn = { retc = Fun.id; exnc = raise; effc = effc_fn } in
  let rec expect_send (k : (unit, unit) continuation) =
    continue_with k () @@ handler (fun (type c) (eff : c Effect.t) ->
      match eff with
      | Send n -> Some (fun (k : (c, unit) continuation) ->
          Printf.printf "Sent: %d\n" n;
          expect_recv k)
      | _ -> None)
  and expect_recv (k : (unit, unit) continuation) =
    continue_with k () @@ handler (fun (type c) (eff : c Effect.t) ->
      match eff with
      | Recv -> Some (fun (k : (c, unit) continuation) ->
          Printf.printf "Received: 42\n";
          expect_send k)
      | _ -> None)
  in
  expect_send (fiber comp)
```

The mutually recursive `expect_send` and `expect_recv` enforce alternation between `Send` and `Recv`. Because shallow handlers do not re-install themselves, each resumption provides a new handler specifying the next expected effect. OCaml does not provide syntax sugar for shallow handlers.

---

## Performance Approach

### Fiber-Based Implementation

Effect handlers are implemented via fibers -- small, heap-allocated stack segments. Each fiber begins at 16 words and grows by copying to a doubled allocation on overflow. A fiber contains a `handler_info` block (parent pointer and handler closures), a DWARF/GC context block, an exception forwarding frame, and a variable-sized area for OCaml stack frames. A red zone optimization eliminates stack overflow checks for leaf functions with small frames.

### Performance Characteristics

The PLDI 2021 paper reports:

| Metric                             | Result                                |
| ---------------------------------- | ------------------------------------- |
| Overhead on code not using effects | ~1% mean on macro benchmarks          |
| Stack switching cost               | Userland only; no kernel involvement  |
| Fiber initial size                 | 16 words (~128 bytes)                 |
| Growth strategy                    | Copy-on-overflow, double size         |
| Continuation semantics             | One-shot (dynamic check)              |
| Tool compatibility                 | DWARF unwinding, debuggers, profilers |

The 1% overhead is achieved by piggybacking effect checks onto existing stack overflow checks in function prologues. Continuations are restricted to one-shot resumption (enforced dynamically), which enables efficient in-place fiber resumption without stack copying.

---

## Composability Model

Effect handlers compose through nesting. The innermost matching handler handles an effect; if `effc` returns `None`, the effect propagates outward:

```ocaml
(* Compose handlers by nesting *)
let result =
  run_emitter (fun () ->
    run_state 0 (fun () ->
      let x = perform Get in
      perform (Emit x);
      perform (Put (x + 1))))
```

Since effects are untyped, there is no compile-time verification that all effects are handled -- an unhandled effect raises `Effect.Unhandled` at runtime. Deep handlers compose transparently because they re-install themselves around resumed continuations. Shallow handlers require explicit handler threading, trading verbosity for fine-grained control.

---

## Strengths

- **Runtime-native implementation** with minimal overhead (~1%) on existing code
- **Generalizes exceptions**: exceptions are a special case where the continuation is discarded
- **Fiber-based stack switching** is entirely in userland with no kernel involvement
- **Backwards compatible** with all existing OCaml 4.x code
- **Tool compatible** with DWARF debuggers, profilers, and backtraces
- **Expressive**: can encode generators, async/await, lightweight threads, coroutines, state, and nondeterminism
- **Both deep and shallow handlers** are available, covering different use cases
- **OCaml 5.3 syntax sugar** significantly reduces boilerplate for deep handlers

## Weaknesses

- **Effects are untyped**: the type system does not track which effects a function may perform
- **One-shot continuations only**: cannot resume more than once, ruling out backtracking patterns
- **No effect polymorphism**: function signatures do not indicate their effects
- **Shallow handlers have no syntax support**: require verbose, manually annotated code
- **Experimental status**: the `Effect` module API is subject to change
- **No effect subtyping**: cannot express that a handler removes one effect from a set

## Key Design Decisions and Trade-offs

| Decision                       | Rationale                                                      | Trade-off                                                |
| ------------------------------ | -------------------------------------------------------------- | -------------------------------------------------------- |
| Untyped effects                | Ship working implementation before typed effect theory matures | Runtime errors for unhandled effects; no static tracking |
| One-shot continuations         | Avoids stack copying; sufficient for concurrency               | Cannot express multi-shot patterns like backtracking     |
| Fiber-based stacks             | Constant-time switching; DWARF and GC compatible               | Memory overhead; stack growth requires copying           |
| Deep as default                | Easier to use; handler re-installs automatically               | Less control than shallow handlers                       |
| Extensible variant for effects | Decentralized declaration across modules                       | No grouping of related effects into signatures           |
| No syntax in 5.0; added in 5.3 | Minimize surface change for experimental feature               | Verbose code in 5.0-5.2; resolved in 5.3                 |
| ~1% overhead budget            | Must not regress existing code performance                     | Constrains implementation choices                        |

---

## Sources

- [OCaml 5.2 Manual - Language Extensions: Effect Handlers](https://ocaml.org/manual/5.2/effects.html)
- [Effect.Deep API Documentation](https://ocaml.org/manual/5.2/api/Effect.Deep.html)
- [Effect.Shallow API Documentation](https://ocaml.org/manual/5.2/api/Effect.Shallow.html)
- [Retrofitting Effect Handlers onto OCaml (PLDI 2021)](https://dl.acm.org/doi/10.1145/3453483.3454039)
- [Retrofitting Effect Handlers onto OCaml (arXiv preprint)](https://arxiv.org/abs/2104.00250)
- [OCaml Effects Tutorial](https://github.com/ocaml-multicore/ocaml-effects-tutorial)
- [Effects Examples Repository](https://github.com/ocaml-multicore/effects-examples)
- [Effective Programming: Adding an Effect System to OCaml (Jane Street)](https://www.janestreet.com/tech-talks/effective-programming/)
- [Introducing OxCaml (Jane Street Blog)](https://blog.janestreet.com/introducing-oxcaml/)
- [Add Effect Syntax PR #12309](https://github.com/ocaml/ocaml/pull/12309)

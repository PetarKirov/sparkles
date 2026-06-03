# OCaml 5 Effect Handlers

Native algebraic effect handlers built into the OCaml 5 multicore runtime, exposing first-class one-shot delimited continuations via heap-allocated fiber stacks that are switched without kernel involvement.

| Field         | Value                                                                                     |
| ------------- | ----------------------------------------------------------------------------------------- |
| Language      | OCaml 5.x (source inspected: `5.6.0+dev`)                                                 |
| License       | LGPL-2.1-with-linking-exception                                                           |
| Repository    | [github.com/ocaml/ocaml]                                                                  |
| Core sources  | `stdlib/effect.{ml,mli}`, `runtime/fiber.c`, `runtime/caml/fiber.h`, `runtime/amd64.S`    |
| Documentation | [OCaml 5.3 Manual — Effect Handlers]                                                      |
| Key Authors   | KC Sivaramakrishnan, Stephen Dolan, Leo White, Tom Kelly, Sadiq Jaffer, Anil Madhavapeddy |
| Encoding      | Untyped algebraic effects with one-shot continuations on fiber stacks                     |

---

## Overview

### What It Solves

OCaml 5.0 (December 2022) introduced algebraic effect handlers as a _runtime-level_ mechanism for non-local control flow, shipped together with the new multicore runtime. Before OCaml 5, exceptions were the only non-local control-flow primitive, but a `raise` discards the continuation at the raise site. Effect handlers generalize exceptions: an effect can capture the **delimited continuation** between the `perform` site and its enclosing handler, and that continuation can later be _resumed_. This makes generators, async/await, lightweight threads, coroutines, and cooperative schedulers expressible as ordinary user-level libraries — most prominently [Eio](./ocaml-eio.md), whose scheduler is built directly on `Effect.Deep`.

The PLDI 2021 paper "Retrofitting Effect Handlers onto OCaml" states the goal precisely: implement effect handlers while _maintaining the backwards compatibility and performance profile of existing OCaml code_, reporting a **mean 1% overhead on a macro-benchmark suite that does not use effects**.

### Design Philosophy

Two pragmatic decisions dominate the design:

1. **No static effect typing.** The type system does _not_ track which effects a function may perform. The manual is explicit: "Unlike languages such as Eff and Koka, effect handlers in OCaml do not provide effect safety; the compiler does not statically ensure that all the effects performed by the program are handled." An effect with no matching handler raises the ordinary exception `Effect.Unhandled` _at runtime_ rather than being a compile-time error. This let the team ship a working implementation while typed-effect theory (see [Theory and Compilation](./theory-compilation.md)) continues to mature.

2. **One-shot continuations only.** A captured continuation must be resumed _exactly once_ (via `continue` or `discontinue`). Resuming it a second time raises `Continuation_already_resumed`. The manual's rationale: one-shot is "sufficient for almost all concurrent programming needs" and "much cheaper to implement compared to multi-shot continuations since they do not require stack frames to be copied" — the fiber stack is resumed _in place_ rather than cloned.

The `Effect` interface is still flagged unstable in the standard library:

```ocaml
(* stdlib/effect.mli *)
[@@@alert unstable
    "The Effect interface may change in incompatible ways in the future."
]
```

---

## Core Abstractions and Types

The `Effect` module (`stdlib/effect.mli`, authored by KC Sivaramakrishnan, IIT Madras, 2021) defines a small surface:

```ocaml
(* stdlib/effect.mli *)
type 'a t = 'a eff = ..                          (* the extensible effect variant *)

exception Unhandled : 'a t -> exn                (* no handler for the performed effect *)
exception Continuation_already_resumed           (* one-shot violation *)

external perform : 'a t -> 'a = "%perform"       (* trigger an effect; @raise Unhandled *)

module Deep : sig ... end
module Shallow : sig ... end
```

`type 'a t = 'a eff = ..` is an **extensible GADT-style variant**: `perform e` returns a value whose type is the index of the constructor `e`. `perform` is a compiler intrinsic (`"%perform"`), not an ordinary call — the native backend lowers it to the `Pperform` primitive (and the assembly routine `caml_perform`), and the bytecode backend to the `PERFORM` instruction.

Both handler modules expose a delimited-continuation type `('a, 'b) continuation`, "a delimited continuation that expects a `'a` value and returns a `'b` value." In `Deep` this is a re-export of the runtime's built-in `('a,'b) continuation`; in `Shallow` it is a distinct abstract type. The continuation is the concrete representation of the suspended fiber chain (see [How handlers work](#how-handlersinterpreters-work)).

---

## How Effects Are Declared

Effects are declared by extending the extensible variant `Effect.t` with constructors whose result type fixes what `perform` returns:

```ocaml
type _ Effect.t += Xchg : int -> int Effect.t     (* takes int, perform returns int *)

type _ Effect.t += Get  : int Effect.t             (* perform returns int *)
                 | Put  : int -> unit Effect.t     (* takes int, perform returns unit *)
                 | Yield : 'a -> unit Effect.t      (* polymorphic payload *)
```

Because `Effect.t` is extensible, an effect can be declared in _any_ module — there is no syntactic grouping of operations into named "effect signatures" as in the literature on effect rows. (An upcoming OCaml release will even let effects be declared locally: `let type Effect.t += Yield in ...` is being added as part of generalizing `let type`/`let module`/`let exception` to most structure items — see PR #14040 in the in-development `Changes` section.) Each constructor stands alone, and dispatch is by ordinary pattern matching inside a handler.

```ocaml
let get () : int  = Effect.perform Get
let put (v:int)   = Effect.perform (Put v)
```

---

## How Handlers/Interpreters Work

### Deep handlers (`Effect.Deep`)

A _deep_ handler handles **all** effects of a computation until it terminates, and re-installs itself automatically around any resumed continuation. The interface (`stdlib/effect.mli`):

```ocaml
module Deep : sig
  type nonrec ('a,'b) continuation = ('a,'b) continuation

  val continue   : ('a, 'b) continuation -> 'a -> 'b        (* resume with a value *)
  val discontinue : ('a, 'b) continuation -> exn -> 'b      (* resume by raising exn *)
  val discontinue_with_backtrace :
    ('a, 'b) continuation -> exn -> Printexc.raw_backtrace -> 'b

  type ('a,'b) handler =
    { retc : 'a -> 'b;                                       (* value handler *)
      exnc : exn -> 'b;                                      (* exception handler *)
      effc : 'c. 'c t -> (('c,'b) continuation -> 'b) option }  (* effect handler *)

  val match_with : ('c -> 'a) -> 'c -> ('a,'b) handler -> 'b

  type 'a effect_handler =
    { effc : 'b. 'b t -> (('b, 'a) continuation -> 'a) option }
  val try_with : ('b -> 'a) -> 'b -> 'a effect_handler -> 'a

  external get_callstack :
    ('a,'b) continuation -> int -> Printexc.raw_backtrace
    = "caml_get_continuation_callstack"
end
```

The implementation (`stdlib/effect.ml`) shows that a handler is _just a freshly allocated fiber stack_ whose three closures are `retc`, `exnc`, and an `effc` wrapper. Crucially, when the user's `effc` returns `None`, the runtime **re-performs** the effect on the parent handler via the `%reperform` intrinsic — this is the propagation mechanism that makes nested handlers compose:

```ocaml
(* stdlib/effect.ml — Deep.match_with *)
external reperform : 'a t -> ('a, 'b) continuation -> 'b = "%reperform"

let match_with comp arg handler =
  let effc eff k =
    match handler.effc eff with
    | Some f -> f k
    | None   -> reperform eff k          (* not ours: walk up the handler chain *)
  in
  let s = alloc_stack handler.retc handler.exnc effc in
  runstack s comp arg                    (* %runstack: run comp on the new fiber *)
```

`continue`/`discontinue` first detach the fiber from the continuation object with `caml_continuation_use_noexc` (this is what enforces one-shot — see below), then `%resume` it:

```ocaml
(* stdlib/effect.ml *)
let continue k v =
  resume (take_cont_noexc k) (fun x -> x) v
let discontinue k e =
  resume (take_cont_noexc k) (fun e -> raise e) e
```

#### Example — state via a deep handler

```ocaml
open Effect
open Effect.Deep

type _ Effect.t += Get : int t | Put : int -> unit t

let run_state (init : int) (comp : unit -> 'a) : 'a =
  let state = ref init in
  match_with comp ()
    { retc = (fun x -> x);
      exnc = (fun e -> raise e);
      effc = (fun (type c) (eff : c t) ->
        match eff with
        | Get   -> Some (fun (k : (c,_) continuation) -> continue k !state)
        | Put v -> Some (fun (k : (c,_) continuation) -> state := v; continue k ())
        | _     -> None) }
```

#### OCaml 5.3 syntax sugar

Syntax support for _deep_ handlers landed in **OCaml 5.3** (`Changes`: "#12309, #13158: Add syntax support for deep effect handlers"). A `try … with` block may now carry `effect` patterns alongside exception patterns:

```ocaml
(* OCaml >= 5.3 *)
try comp1 () with
| effect (Xchg n), k -> continue k (n + 1)
```

Per the manual, "`effect` is a keyword which signifies that the `Xchg n` pattern matches effects and not exceptions." Introducing the keyword can shadow `effect`-named identifiers, so it can be disabled via the `-keywords` lexer flag for backwards compatibility (`Changes`, `-keywords 5.2` disables it). There is **no** sugar for shallow handlers.

### Shallow handlers (`Effect.Shallow`)

A _shallow_ handler handles only the **first** effect; the captured continuation does **not** re-install the handler, so each resumption must supply a fresh handler. This suits protocol/state-machine encodings.

```ocaml
module Shallow : sig
  type ('a,'b) continuation                              (* distinct abstract type *)
  val fiber : ('a -> 'b) -> ('a, 'b) continuation        (* build a suspended fiber *)

  type ('a,'b) handler =
    { retc : 'a -> 'b;
      exnc : exn -> 'b;
      effc : 'c. 'c t -> (('c,'a) continuation -> 'b) option }

  val continue_with    : ('c,'a) continuation -> 'c -> ('a,'b) handler -> 'b
  val discontinue_with : ('c,'a) continuation -> exn -> ('a,'b) handler -> 'b
  val discontinue_with_backtrace :
    ('a,'b) continuation -> exn -> Printexc.raw_backtrace -> ('b,'c) handler -> 'c
end
```

`Shallow.fiber f` is built by running `f` on a fresh stack until it performs a private `Initial_setup__` effect, capturing the continuation at that point (`stdlib/effect.ml`):

```ocaml
(* stdlib/effect.ml — Shallow.fiber *)
let fiber : type a b. (a -> b) -> (a, b) continuation = fun f ->
  let module M = struct type _ t += Initial_setup__ : a t end in
  let exception E of (a,b) continuation in
  let f' () = f (perform M.Initial_setup__) in
  ...
```

`continue_with` differs from `Deep.continue` by installing the supplied handler onto the existing fiber before resuming, via `caml_continuation_use_and_update_handler_noexc`:

```ocaml
(* stdlib/effect.ml *)
let continue_gen k resume_fun v handler =
  let effc eff k =
    match handler.effc eff with Some f -> f k | None -> reperform eff k in
  let stack = update_handler k handler.retc handler.exnc effc in
  resume stack resume_fun v
```

#### Example — alternating Send/Recv protocol (shallow)

```ocaml
open Effect
open Effect.Shallow

type _ Effect.t += Send : int -> unit Effect.t | Recv : int Effect.t

let run comp =
  let h effc_fn = { retc = Fun.id; exnc = raise; effc = effc_fn } in
  let rec expect_send (k : (unit,unit) continuation) =
    continue_with k () @@ h (fun (type c) (eff : c Effect.t) ->
      match eff with
      | Send n -> Some (fun (k:(c,unit) continuation) -> expect_recv k)
      | _ -> None)
  and expect_recv (k : (unit,unit) continuation) =
    continue_with k () @@ h (fun (type c) (eff : c Effect.t) ->
      match eff with
      | Recv -> Some (fun (k:(c,unit) continuation) -> expect_send k)
      | _ -> None)
  in expect_send (fiber comp)
```

---

## Runtime, Scheduler, and the Fiber Stack

This is where the design earns its keep, and where the regrounded detail lives. (See `runtime/caml/fiber.h` and `runtime/fiber.c`.)

### Fiber-stack layout

Each handler owns a fiber: a single heap allocation holding a `struct stack_info` header, a usable OCaml-frame area, and a `struct stack_handler` at the high end (the stack grows _downward_). The handler block holds the three handler closures plus the all-important **parent pointer** (`runtime/caml/fiber.h`):

```c
/* runtime/caml/fiber.h */
struct stack_handler {
  value handle_value;
  value handle_exn;
  value handle_effect;
  struct stack_info* parent;   /* parent OCaml stack if any */
};
```

The documented native layout (high → low address):

```
+------------------------+
|  struct stack_handler  |
+------------------------+ <--- Stack_high
|  caml_runstack /       |
|  caml_start_program    |
+------------------------+
|      OCaml frames      | <--- sp
+------------------------+ <--- Stack_threshold
|        Red Zone        |
+------------------------+ <--- Stack_base
|   struct stack_info    |
+------------------------+ <--- Caml_state->current_stack
```

### Initial size and growth-by-copying

The _effect fiber_ size is **not** 16 words — that figure is incorrect. From `runtime/gc_ctrl.c`:

```c
caml_fiber_wsz = (Stack_threshold * 2) / sizeof(value);   /* = Stack_threshold_words * 2 = 64 words */
```

with `Stack_threshold_words = 32` (`runtime/caml/config.h`). So a fresh fiber created by `caml_alloc_stack` starts at **64 words (~512 bytes on 64-bit)**. (The _main_ domain stack uses a separate, larger initial size `Stack_init_bsize = 4096 * sizeof(value)` in release builds, i.e. 4096 words.)

When a fiber needs more room, `caml_try_realloc_stack` (`runtime/fiber.c`) **doubles** the size and **copies** the live region into the new allocation, capped by `caml_max_stack_wsize`:

```c
/* runtime/fiber.c — caml_try_realloc_stack (abridged) */
do {
  if (wsize >= max_stack_wsize) return 0;     /* hit the cap -> stack overflow */
  wsize *= 2;
} while (wsize < stack_used + required_space);
...
new_stack = caml_alloc_stack_noexc(wsize, /* same handlers + id */ ...);
memcpy(Stack_high(new_stack) - stack_used,
       Stack_high(old_stack) - stack_used,
       stack_used * sizeof(value));
new_stack->sp = Stack_high(new_stack) - stack_used;
Stack_parent(new_stack) = Stack_parent(old_stack);   /* preserve the chain */
caml_rewrite_exception_stack(old_stack, ..., new_stack);  /* fix absolute exn ptrs */
```

Because growth re-bases the stack, the runtime rewrites the linked exception handlers (`caml_rewrite_exception_stack`) and any `c_stack_link` records that point at the old stack. Freed fibers are recycled through a small per-domain free list (`caml_alloc_stack_cache`, `NUM_STACK_SIZE_CLASSES = 5` size classes) to avoid churning `malloc`.

### The parent-pointer handler chain and `perform`

A `perform` does a **linear walk up the parent chain** until it finds the nearest handler. The native routine `caml_perform` (`runtime/amd64.S`) reads `Handler_parent`; if it is `NULL` there is _no_ enclosing handler, so it switches back to the performer and raises `Effect.Unhandled`:

```asm
; runtime/amd64.S — caml_perform (abridged)
        movq    Stack_handler(%rsi), %r11    ; %r11 := current_stack->handler
        movq    Handler_parent(%r11), %r10   ; %r10 := parent_stack
        cmpq    $0, %r10                      ; parent_stack == NULL ?
        je      LBL(112)                      ; -> raise Effect.Unhandled
        SWITCH_OCAML_STACKS
        movq    %rdx, Handler_parent(%r11)    ; connect cont_tail back to cont_head
        movq    Handler_effect(%r11), %rdi    ; load the effect handler closure
        jmp     GCALL(caml_apply2)            ; run handle_effect on the parent
LBL(112):                                     ; no parent stack:
        ...
        LEA_VAR(caml_raise_unhandled_effect, %rax)
        jmp     LBL(caml_c_call)
```

If the matched handler's `effc` returns `None`, `%reperform` (`caml_reperform`) continues the walk to the _next_ parent handler, threading the same continuation object so the eventual resume targets the original `perform` site. The continuation captures the suspended computation as a chain of fibers from `cont_head` (where the effect was performed) down to `cont_tail` (the fiber that handled it), linked through `Stack_parent` pointers (documented at length in `runtime/caml/fiber.h`).

### One-shot enforcement — `Continuation_already_resumed`

The exception is declared as plain text in `stdlib/effect.mli`:

> `Continuation_already_resumed` — "Exception raised when a continuation is continued or discontinued more than once."

Mechanically: resuming detaches the fiber from the continuation object by **swapping the stack pointer field to `NULL`** (`caml_continuation_use_noexc`, `runtime/fiber.c`) — a plain store when the domain runs alone, an atomic compare-and-swap otherwise (so a concurrent second resume sees `NULL`):

```c
/* runtime/fiber.c */
v = Field(cont, 0);
if (caml_domain_alone()) { Field(cont, 0) = null_stk; return v; }
if (atomic_compare_exchange_strong(Op_atomic_val(cont), &v, null_stk)) return v;
else return null_stk;
```

`caml_resume` then checks for that `NULL` and jumps straight to the raising routine if the continuation was already consumed (`runtime/amd64.S`):

```asm
; runtime/amd64.S — caml_resume
        leaq    -1(%rax), %rsi   ; cont_tail = Ptr_val(cont)
        testq   %rsi, %rsi        ; null stack?
        jz      1f
        ...
1:      LEA_VAR(caml_raise_continuation_already_resumed, %rax)
        jmp LBL(caml_c_call)
```

`caml_raise_continuation_already_resumed` (`runtime/fiber.c`) looks up the registered exception and raises it. Both `Effect.Unhandled` and `Effect.Continuation_already_resumed` are registered with the runtime from OCaml via `Callback.register_exception` (`stdlib/effect.ml`).

### Backtraces and tooling

Continuations are inspectable: `Effect.Deep.get_callstack`/`Effect.Shallow.get_callstack` map to `caml_get_continuation_callstack`, and `discontinue_with_backtrace` lets a handler re-raise into a suspended computation with a chosen origin backtrace. The C-stack-link list (`struct c_stack_link`) doubles as the structure used for **DWARF backtraces** across OCaml↔C transitions, and the GC scans every fiber in the chain via `caml_scan_stack`, walking `Stack_parent` and stopping on a detected loop. ThreadSanitizer is integrated through the `TSAN_*` hooks visible in `caml_perform`/`caml_resume`/`caml_runstack`.

---

## Performance Approach

### How the ~1% is achieved

The PLDI 2021 paper reports a **mean 1% overhead** on macro benchmarks that do not use effects. The technique is to fold the effect-dispatch bookkeeping into machinery the runtime already pays for:

- **Stack-switching is pure userland.** `perform`/`resume` swap an `sp` register and update one parent pointer — there is no kernel transition.
- **One-shot resumption needs no copying.** Because a continuation is consumed exactly once, the fiber is resumed in place; only _stack growth_ (rare) copies.
- **Growth-on-demand keeps fibers tiny.** Fibers start at 64 words and double only when the threshold is crossed, so the common case allocates little.

| Metric                             | Value (from source / paper)                                                                   |
| ---------------------------------- | --------------------------------------------------------------------------------------------- |
| Overhead on code not using effects | mean ~1% (PLDI 2021 macro-benchmark suite)                                                    |
| Stack switching cost               | userland only; no syscalls                                                                    |
| Fiber initial size                 | 64 words (`caml_fiber_wsz = Stack_threshold_words * 2`) ≈ 512 B on 64-bit                     |
| Main-stack initial size            | 4096 words (`Stack_init_bsize`, release build)                                                |
| Growth strategy                    | double size + `memcpy` of live region (`caml_try_realloc_stack`)                              |
| Continuation semantics             | one-shot, enforced by NULL-swap of the cont's stack field (atomic CAS under multiple domains) |
| Handler lookup                     | linear walk up `Stack_parent` chain on each (re)perform                                       |
| Stack pooling                      | per-domain free list, 5 size classes (`NUM_STACK_SIZE_CLASSES`)                               |
| Tooling                            | DWARF backtraces, `get_callstack`, GC stack scanning, TSan hooks                              |

---

## Composability Model

Handlers compose by **nesting**, with propagation driven by the `effc … None → reperform` pattern shown earlier:

```ocaml
let result =
  run_emitter (fun () ->
    run_state 0 (fun () ->
      let x = perform Get in
      perform (Emit x);
      perform (Put (x + 1))))
```

- **Deep handlers compose transparently** because resuming re-installs the deep handler around the continuation automatically.
- **Shallow handlers compose explicitly**: each resumption threads a new handler, trading verbosity for fine control (state machines, protocol enforcement).
- **No static composition guarantee.** Since effects are untyped, nothing verifies that every effect performed under a computation is handled; an uncaught one becomes a runtime `Effect.Unhandled`. This is the central limitation that the broader research effort (and Jane Street's typed-effects work) aims to remove. For how effect handlers slot into a real async/event-loop scheduler, see [Effects and event loops](../async-io/effects-and-event-loops.md) and the Eio writeup in [ocaml-eio.md](./ocaml-eio.md).

---

## Strengths

- **Runtime-native, low overhead** (~1% mean on existing code) — effect support coexists with the multicore runtime.
- **Generalizes exceptions**: an exception handler is the special case where the continuation is discarded.
- **Userland fiber switching** with no kernel involvement; ideal foundation for schedulers like Eio.
- **Backwards compatible**: existing OCaml 4.x programs run unchanged, paying only the small dispatch cost.
- **Tool-compatible**: DWARF backtraces, `get_callstack`, profilers, GC, and ThreadSanitizer all understand fibers.
- **Both deep and shallow handlers**, covering scheduler-style and protocol-style use cases.
- **5.3 `effect` syntax** removes most of the `effc`/locally-abstract-type boilerplate for deep handlers.

## Weaknesses

- **Untyped effects**: the type checker does not track effects; missing handlers surface only at runtime as `Effect.Unhandled`.
- **One-shot only**: cannot resume a continuation twice, ruling out multi-shot patterns like backtracking search without explicit cloning.
- **No effect polymorphism / subtyping**: signatures don't say what a function performs, nor that a handler discharges a specific effect.
- **Shallow handlers have no syntax sugar**: still need the verbose annotated `effc` record.
- **Unstable API**: `stdlib/effect.mli` carries an explicit `[@@@alert unstable]`.
- **Linear handler lookup**: each (re)perform walks the parent chain; deeply nested unrelated handlers add per-perform cost.

## Key Design Decisions and Trade-offs

| Decision                                  | Rationale                                                          | Trade-off                                                         |
| ----------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------- |
| Untyped effects                           | Ship a working runtime before typed-effect theory matures          | Unhandled effects are runtime `Effect.Unhandled`, no static check |
| One-shot continuations                    | Resume fiber in place; no stack copying on resume                  | No multi-shot/backtracking without explicit cloning               |
| Heap-allocated fiber stacks               | Constant-time switch; GC- and DWARF-compatible; per-domain pooling | Memory per handler; growth requires `memcpy` + pointer rewriting  |
| Parent-pointer handler chain              | Simple, allocation-free dispatch shared with backtrace/GC walking  | Linear search up the chain on each perform/reperform              |
| Initial fiber = 64 words, double on need  | Keep the common case tiny while allowing deep recursion            | Occasional copy + exception/`c_stack_link` pointer rewriting      |
| Deep as the default model                 | Auto-reinstalling handler is easy to use (schedulers, state)       | Less control than shallow for stepwise protocols                  |
| Extensible variant for effects            | Decentralized, even module-local effect declaration                | No grouping of operations into named effect signatures            |
| No syntax in 5.0; `effect` keyword in 5.3 | Minimize surface change for an experimental feature                | Verbose 5.0–5.2 code; new keyword can shadow identifiers          |
| ~1% overhead budget                       | Must not regress existing OCaml performance                        | Constrains the implementation (piggyback on existing checks)      |

---

## Sources

- [github.com/ocaml/ocaml] — source inspected at `5.6.0+dev`: `stdlib/effect.ml`, `stdlib/effect.mli`, `runtime/fiber.c`, `runtime/caml/fiber.h`, `runtime/amd64.S`, `runtime/gc_ctrl.c`, `runtime/caml/config.h`, `Changes`.
- [OCaml 5.3 Manual — Effect Handlers]
- [OCaml 5.0.0 Release Notes]
- [OCaml 5.3.0 Release Notes]
- [Retrofitting Effect Handlers onto OCaml (PLDI 2021)]
- [Retrofitting Effect Handlers onto OCaml (arXiv preprint)]
- [Add Effect Syntax PR #12309]
- Related corpus docs: [Eio (ocaml-eio.md)](./ocaml-eio.md) · [Theory and Compilation](./theory-compilation.md) · [Evolution](./evolution.md) · [Papers](./papers.md) · [Comparison](./comparison.md) · [WasmFX](./wasmfx.md) · [Index](./index.md) · [Async-IO: Effects and event loops](../async-io/effects-and-event-loops.md)

<!-- References -->

[github.com/ocaml/ocaml]: https://github.com/ocaml/ocaml
[OCaml 5.3 Manual — Effect Handlers]: https://ocaml.org/manual/5.3/effects.html
[OCaml 5.0.0 Release Notes]: https://ocaml.org/releases/5.0.0
[OCaml 5.3.0 Release Notes]: https://ocaml.org/releases/5.3.0
[Retrofitting Effect Handlers onto OCaml (PLDI 2021)]: https://dl.acm.org/doi/10.1145/3453483.3454039
[Retrofitting Effect Handlers onto OCaml (arXiv preprint)]: https://arxiv.org/abs/2104.00250
[Add Effect Syntax PR #12309]: https://github.com/ocaml/ocaml/pull/12309

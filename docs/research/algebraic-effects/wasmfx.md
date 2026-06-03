# WasmFX (WebAssembly Stack Switching)

A typed, low-level continuation primitive for WebAssembly: a single stack-switching mechanism that compilers target to implement async/await, generators, coroutines, lightweight threads, and effect handlers, instead of relying on whole-program CPS or state-machine transforms.

**Last reviewed:** June 2, 2026.

| Field              | Value                                                                          |
| ------------------ | ------------------------------------------------------------------------------ |
| Ecosystem          | WebAssembly Community Group / Working Group proposal                           |
| Proposal repo      | [WebAssembly/stack-switching]                                                  |
| Authoritative spec | [Stack-switching Explainer.md] (current instruction set)                       |
| Champions          | Francis McCabe, Sam Lindley                                                    |
| Standardization    | Phase 3 — Implementation Phase (CG + WG), per [WebAssembly proposals tracker]  |
| Research origin    | [Continuing WebAssembly with Effect Handlers (OOPSLA 2023)] — the WasmFX paper |
| Project site       | [WasmFX project site] (the original "typed continuations" explainer)           |
| Reference interp.  | OCaml interpreter under `interpreter/` in [WebAssembly/stack-switching]        |
| Base spec          | Wasm 3.0 + [function-references] + [exception-handling]                        |

---

## Overview

### What It Solves

Industrial languages rely on non-local control flow — async/await, coroutines, generators/iterators, effect handlers, lightweight (green) threads — and for some languages (Go, Erlang, OCaml 5) it is central to identity and to scalable concurrency. Compiling these features to a Wasm without first-class stacks forces toolchains into whole-program transforms (CPS, Asyncify-style state machines), which bloat code, destroy the natural call-stack structure (hurting debuggers and stack traces), and compose poorly across module boundaries.

The Explainer states the design strategy directly: "Rather than build specific control flow mechanisms for all possible varieties of non-local control flow, our strategy is to build a single mechanism, _continuations_, that can be used by language providers to construct their own language specific features" (`proposals/stack-switching/Explainer.md`, Motivation). WasmFX is the research line — "Continuing WebAssembly with Effect Handlers", OOPSLA 2023 — that produced this design; the standards-track spec carries it forward under the name **stack switching**.

### Design Philosophy

The proposal is a _low-level substrate_, not a high-level effect API. It reuses Wasm's existing machinery wherever possible:

- It reuses **tags** from the exception-handling proposal, generalizing them so a tag may also carry **result** types — "a control tag may be thought of as a _resumable_ exception" (Explainer, Declaring control tags).
- It adds exactly **one new reference type** (`cont`) and **seven new instructions**.
- Resuming a continuation establishes a **parent-child relationship** that "aligns with the caller-callee relationship for standard function calls," so traps, exceptions, and embedder integration compose without special plumbing (Explainer, Asymmetric switching).
- Continuations are **one-shot (linear)**: invoking one more than once traps. This sidesteps stack-copying and GC of continuation objects, at the cost of not directly supporting multi-shot use-cases (backtracking, probabilistic programming).

For where this sits in the broader compilation story for algebraic effects, see [Theory and Compilation]; for how stack switching as a target relates to async I/O runtimes and event loops, see [Effects and Event Loops].

---

## Core Abstractions and Types

### Continuation reference type

The single new reference type is the continuation, written in terms of an underlying function type `$ft`:

```wat
;; proposals/stack-switching/Explainer.md — Instruction set extension
(type $ft (func (param t1*) (result t2*)))
(type $ct (cont $ft))     ;; continuation over $ft
```

The Explainer also uses the shorthand `(cont [t1*] -> [t2*])`. The parameter types `t1*` describe the stack shape required to resume/start the continuation; the result types `t2*` describe the stack shape once it runs to completion.

In the [specification changes](#how-effects-are-declared), `cont <typeidx>` is added as a new form of _composite type_ (alongside `func`, `struct`, `array`), and two new heap types form a tiny lattice: `nocont <: cont`, where `nocont` is the bottom continuation type and `cont` the top. Continuations are explicitly **not castable**: the cast instructions `ref.test` / `ref.cast` / `br_on_cast(_fail)` gain a side-condition `rt castable` defined as `not (rt <: (ref null cont))`, so engines cannot inspect a continuation's concrete type at runtime.

### Control tags

Tags are the coordination mechanism shared with exception handling. A tag declares both a parameter and a (now possibly non-empty) result type:

```wat
;; proposals/stack-switching/Explainer.md — Generators
(tag $gen (param i32))          ;; suspend payload: i32 sent to handler; no value returned

;; proposals/stack-switching/Explainer.md — Extending the generator
(tag $gen (param i32) (result i32))  ;; suspend with i32; resumed with an i32 flag
```

The shorthand `$t : [t1*] -> [t2*]` says: when `suspend`ing on `$t`, the suspend site pushes values of type `t1*` to the handler, and expects values of type `t2*` back when resumed. A single tag may be used simultaneously by `throw`, `suspend`, and `switch`; the handler search only matches handlers of the _same kind_ of event (Explainer, Execution).

### The three relationships

- **Asymmetric switching** (`suspend`/`resume`): resuming splices a suspended continuation _onto_ the current one as a child; control returns to the parent's `resume` site when the child completes or suspends.
- **Symmetric switching** (`switch`): a direct peer-to-peer transfer that combines "suspend current + resume peer" into a single stack switch — the engine avoids bouncing through the parent handler.
- **Partial application** (`cont.bind`): pre-binds a prefix of a continuation's arguments, producing a new continuation of a narrower type. Because continuations are single-shot, no closure allocation is needed — slots for arguments are pre-allocated when the continuation is first created (Explainer, Producing continuations).

---

## How Effects Are Declared

There are no "effect declarations" at the Wasm level — effects are _encoded_. A source-language effect operation becomes a **control tag**; performing the operation becomes a `suspend` (or `switch`) on that tag; the source handler becomes a `resume` with an `(on $tag $label)` clause that catches the suspension.

The Explainer's [Specification changes](#how-handlers-and-interpreters-work) give the precise validation rules. The seven instructions and their typing:

```wast
;; proposals/stack-switching/Explainer.md — Instructions
cont.new $ct        : [(ref null $ft)] -> [(ref $ct)]            ;; $ct = cont $ft
cont.bind $ct $ct'  : [t1* (ref null $ct)] -> [(ref $ct')]       ;; bind a t1* prefix
suspend $e          : [t1*] -> [t2*]                             ;; $e : [t1*] -> [t2*]
resume $ct hdl*     : [t1* (ref null $ct)] -> [t2*]              ;; $ct = cont [t1*] -> [t2*]
resume_throw $ct $exn hdl*     : [te* (ref null $ct)] -> [t2*]   ;; $exn : [te*] -> []
resume_throw_ref $ct hdl*      : [exnref (ref null $ct)] -> [t2*]
switch $ct1 $e      : [t1* (ref null $ct1)] -> [t2*]             ;; see symmetric-switch typing
```

Handler clauses (`hdl`) have two shapes, defined in the [binary format](#how-effects-are-declared) with a leading byte:

| Clause           | Meaning                                                       | Binary tag |
| ---------------- | ------------------------------------------------------------- | ---------- |
| `(on $e $l)`     | Suspend handler: catching `suspend $e` branches to label `$l` | `0x00`     |
| `(on $e switch)` | Switch handler: delimiter for `switch` on tag `$e`            | `0x01`     |

The new instructions occupy opcode space `0xe0`–`0xe6`:

| Opcode | Instruction                 |
| ------ | --------------------------- |
| `0xe0` | `cont.new $ct`              |
| `0xe1` | `cont.bind $ct $ct'`        |
| `0xe2` | `suspend $t`                |
| `0xe3` | `resume $ct hdl*`           |
| `0xe4` | `resume_throw $ct $e hdl*`  |
| `0xe5` | `resume_throw_ref $ct hdl*` |
| `0xe6` | `switch $ct1 $t`            |

The validation rule for an `(on $e $l)` clause (Explainer, Instructions) is where the typing knot is tied: the label `$l` must expect the tag's _parameter_ types `t1*` followed by a continuation reference `(ref null? $ct)`, and that continuation's own parameter types must match the tag's _result_ types `t2*`. In other words, the handler receives both the payload and a freshly delimited continuation whose resume-shape is exactly what `suspend` promised to consume.

---

## How Handlers and Interpreters Work

### Asymmetric: `suspend` / `resume`

`resume` both runs a continuation _and_ acts as a **delimiter**: the suspended continuation it later produces captures execution "from the instruction immediately following `suspend $e` up to the `resume` instruction that handles `$e`" (Explainer, Generators). When the child runs `suspend $e`, control transfers to the _innermost ancestor_ whose `resume` installed an `(on $e ...)` clause — directly analogous to exception-handler search, but the handler is additionally passed the reified continuation.

The canonical pattern, from the Explainer's generator example (`proposals/stack-switching/Explainer.md`; full module in `examples/generator.wast`):

```wat
(func $consumer
  (local $c (ref $ct))
  (local.set $c (cont.new $ct (ref.func $generator)))
  (loop $loop
    (block $on_gen (result i32 (ref $ct))
      (resume $ct (on $gen $on_gen) (local.get $c))
      (return)                ;; $generator returned: no more data
    )
    ;; reached only via suspend: stack is [i32 (ref $ct)]
    (local.set $c)            ;; save the new (delimited) continuation
    (call $print)             ;; consume the yielded i32
    (br $loop)))
```

### Handler semantics — "sheep" handlers

The original WasmFX / "typed continuations" design (the explainer linked from the [WasmFX project site], preserved in the repo under `proposals/stack-switching/design-notes/continuations/Explainer.md`) names this hybrid **sheep handlers**: "The typed continuations proposal adopts a hybrid of shallow and deep handlers, which we call _sheep handlers_. Like a shallow handler, there is no automatic reinstallation of an existing handler. But like deep handlers a new handler is installed when a continuation is resumed." Concretely: a continuation handed to a handler is _bare_ (no handler attached, unlike deep handlers), but a fresh handler is installed _explicitly_ at each `resume` (unlike a raw shallow handler, where the consumer must re-wrap manually). This keeps the instruction set minimal while giving the programmer explicit control over handler installation.

### Symmetric: `switch`

`switch` optimizes the common scheduler pattern where a suspend is immediately followed by the handler resuming a _different_ continuation. Its typing makes the recursion explicit:

```wast
;; proposals/stack-switching/Explainer.md — Instructions
switch $ct1 $e : [t1* (ref null $ct1)] -> [t2*]
  where:
  - $e   : [] -> [t*]
  - $ct1 = cont [t1* (ref null? $ct2)] -> [t*]   ;; peer also receives a (ref $ct2)
  - $ct2 = cont [t2*] -> [t*]                      ;; the just-suspended current continuation
```

`switch` suspends the current continuation (type `$ct2`), then directly resumes the peer (`$ct1`), implicitly passing _itself_ as the peer's continuation argument so the peer can switch back. The matching handler is `(on $e switch)` — a **switch handler** that installs no suspend logic but acts as the delimiter for switch-suspended continuations. The Explainer's `$scheduler2` (`examples/scheduler2.wast`) builds a cooperative scheduler where tasks switch directly to each other, requiring a _recursive_ continuation type because each task receives a `(ref null $ct)` parameter.

### Aborting: `resume_throw` / `resume_throw_ref`

To cancel a suspended continuation, `resume_throw $ct $exn hdl*` resumes it only to immediately raise exception `$exn` at the suspension point, unwinding it. Because a value is not actually delivered, the continuation's input types `t1*` are unconstrained. `resume_throw_ref` is identical but takes the exception as an `exnref` operand. The Explainer's task-cancellation example wraps `resume_throw` in a `try_table` so the abort exception is swallowed and the old continuation is deallocated (`examples/scheduler2-throw.wast`):

```wat
;; proposals/stack-switching/Explainer.md — Canceling tasks
(block $exc_handler
  (try_table (catch $abort $exc_handler)
    (resume_throw $ct $abort (call $task_dequeue))))
```

### How the reference interpreter realizes this

The OCaml reference interpreter under `interpreter/` makes the semantics concrete and is the clearest source for the runtime model. In `interpreter/exec/eval.ml`:

```ocaml
(* interpreter/exec/eval.ml — Administrative Expressions & Continuations *)
| Prompt of handle_table * code               (* an installed handler *)
| Suspending of tag_inst * value stack * (int32 * ref_) option * ctxt
and ctxt = code -> code                        (* a captured continuation = a context function *)
and handle_table = (tag_inst * idx) list * tag_inst list  (* (on $e $l)* , (on $e switch)* *)

type cont = int32 * ctxt
type ref_ += ContRef of cont option ref        (* the option ref enforces one-shot use *)
```

Three details are worth quoting because they ground claims that are easy to hand-wave:

1. **One-shot is enforced by a mutable `option ref`.** Each invoker — `resume`, `resume_throw`, `resume_throw_ref`, `switch`, `cont.bind` — pattern-matches `ContRef {contents = Some (...)}` and then executes `cont := None`. Re-use hits `ContRef {contents = None}` and yields `Trapping "continuation already consumed"` (`eval.ml`, the `Resume`/`ContBind`/`Switch` cases). The spec's prose "destructively modify the suspended continuation such that any subsequent use will result in a trap" is literally this assignment.

2. **`resume` installs a `Prompt`; `suspend` produces a `Suspending` that bubbles up.** `Resume` reduces to `Prompt (hs, ctxt (args, []))`. `Suspend` reduces to `Suspending (tagt, args, None, fun code -> code)`. The `Suspending` administrative instruction then propagates outward through `Label`, `Frame`, and `Handler` frames, _accumulating the surrounding context into `ctxt`_ — that accumulated `ctxt` becomes the captured continuation.

3. **The prompt is where the search terminates and the continuation is reified** (`eval.ml`, ~line 1307):

   ```ocaml
   | Prompt ((hs, _), (vs', {it = Suspending (tagt, vs1, None, ctxt); _} :: es')), vs
     when List.mem_assq tagt hs ->
       let FuncT (_, ts) = func_type_of_tag_type c.frame.inst (Tag.type_of tagt) in
       let ctxt' code = compose (ctxt code) (vs', es') in
       [Ref (ContRef (ref (Some (Lib.List32.length ts, ctxt'))))] @ vs1 @ vs,
       [Plain (Br (List.assq tagt hs)) @@ e.at]
   ```

   When the bubbling `Suspending` reaches a `Prompt` whose handle-table contains the tag, the interpreter wraps the captured context `ctxt'` into a fresh `ContRef`, pushes it plus the payload `vs1` onto the stack, and branches to the handler's label. A non-matching `Prompt` re-wraps the context and keeps the `Suspending` propagating (the `| Prompt (hso, ... Suspending ...) -> ... Suspending (..., ctxt')` case), faithfully implementing innermost-handler search. The `switch` case has its own `Prompt ... (on ea switch)` reduction that resumes the peer in place without unwinding to the handler.

---

## Performance Approach

- **No whole-program transform.** Compilers emit ordinary call-stack-shaped code plus `suspend`/`resume`; the engine owns the actual stack switch. This preserves natural stack structure for debuggers and profilers, unlike CPS or Asyncify.
- **One-shot, no copying.** Linearity means an engine can implement a continuation as a real OS/segmented stack that is _moved_ on suspend/resume rather than copied. Multi-shot would require stack copying or GC of cyclic continuation graphs; the proposal deliberately forgoes it.
- **`switch` collapses two stack switches into one.** The asymmetric scheduler needs two switches per task hand-off (task→loop, loop→task); `switch` does it in one by transferring control peer-to-peer, "avoiding the need for an intermediate stack switch to the parent" (Explainer, Task scheduling).
- **`cont.bind` without allocation.** Argument slots are pre-allocated at `cont.new`, so partial application reuses the existing continuation object instead of allocating a closure (Explainer, Producing continuations).
- **Engine work is ongoing.** Implementation experience continues to be reported for Wasmtime-oriented tooling, e.g. the [Continuing Stack Switching in Wasmtime (WAW 2025)] session.

---

## Composability Model

Continuations are explicitly **composable**: "when a suspended continuation is resumed it is spliced onto the current continuation," and resuming may itself be the top-level (main) stack (Explainer, Continuations). Because the parent-child relationship mirrors caller-callee, the substrate composes with the rest of Wasm:

- **With exceptions.** Tags are shared with exception handling; aborting a continuation (`resume_throw`) raises a normal Wasm exception at its suspension point, caught by an ordinary `try_table`.
- **With traps and the embedder.** Returning from a continuation transfers control to the instruction after its `resume`, exactly like a function return, so embedder calls and traps unwind naturally.
- **As a universal target.** One mechanism serves many surface features:

| Source feature            | Example languages                 | WasmFX encoding                                       |
| ------------------------- | --------------------------------- | ----------------------------------------------------- |
| Generators / iterators    | C#, JavaScript, Kotlin, Python    | yield tag; `resume` loop with `(on $yield ...)`       |
| Async / await             | C#, Dart, JavaScript, Rust, Swift | async/await/yield/fulfill tags; suspend/resume on I/O |
| Coroutines                | C++, Kotlin                       | symmetric `switch`, or asymmetric suspend/resume      |
| Lightweight threads       | Erlang, Go, Haskell, [OCaml 5]    | yield tag; scheduler resumes from a task queue        |
| First-class continuations | Haskell, [OCaml 5], Scheme        | direct mapping onto `cont`                            |
| Effect handlers           | [Koka], [OCaml 5], [Eff]          | operation → tag; handler → `resume` + `(on ...)`      |

The proposal's own `examples/` directory ships runnable encodings: `async-await.wast` (`$async`/`$await`/`$yield`/`$fulfill` tags), `generators.wast`, `lwt.wast`/`fun-lwt.wast` (lightweight threads), `actor.wast`/`actor-lwt.wast` (actors), and `pipes.wast`/`fun-pipes.wast` (pipes). See [Koka] for a source effect system and [Effects and Event Loops] for how the async examples map onto real event loops.

---

## Strengths

- Strong theoretical grounding from the OOPSLA 2023 effect-handlers work (typed, sound formalization), now carried into a standards-track spec.
- A single low-level control substrate that many source features reuse, instead of N bespoke mechanisms.
- Better compilation target than mandatory whole-program transforms: smaller code, debugger-friendly stacks.
- Minimal surface: one reference type, seven instructions, tags reused from exception handling.
- No GC dependency — one-shot linearity avoids cyclic continuation graphs and stack copying.
- Composes cleanly with exceptions, traps, and embedder integration via the parent-child / caller-callee alignment.
- `switch` gives schedulers an efficient symmetric-transfer primitive.

## Weaknesses

- Not yet a finalized core standard: **Phase 3** is active implementation, not the finish line; engine and toolchain coverage is still uneven.
- One-shot continuations cannot directly express multi-shot effects (backtracking, nondeterminism, process duplication) — the Explainer acknowledges these use-cases are out of scope.
- It is a _substrate_: language implementers still need substantial frontend/runtime integration to lower a high-level effect system onto tags + `resume`.
- The typing of handler clauses and recursive continuation types (`$scheduler2`) is intricate; encoding correctness is easy to get subtly wrong.
- WAT/encoding is verbose and unergonomic for humans (it is a compiler target, not a source syntax).

---

## Key Design Decisions and Trade-offs

| Decision                                                             | Rationale                                                                                    | Trade-off                                                                                  |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| One mechanism (continuations) for all control flow                   | Avoids N special-purpose features; one thing to spec, implement, and optimize                | Source languages must do non-trivial lowering work themselves                              |
| One-shot (linear) continuations                                      | No stack copying, no GC of cyclic continuation graphs; engine can _move_ stacks              | Multi-shot effects (backtracking, nondeterminism) not directly expressible                 |
| Reuse exception-handling tags, extended with results                 | Minimal additions; resumable exceptions are a natural generalization                         | Tag namespace shared across `throw`/`suspend`/`switch`; handler search must filter by kind |
| "Sheep" handlers (shallow install + explicit re-install at `resume`) | Programmer controls handler lifetime; instruction set stays minimal                          | More verbose than deep handlers (no auto-reinstall); consumer manages the loop             |
| Asymmetric (`suspend`/`resume`) as the core                          | Parent-child mirrors caller-callee, so traps/exceptions/embedder compose for free            | Scheduler task hand-off costs two stack switches                                           |
| Add symmetric `switch` as a separate instruction                     | Collapses scheduler hand-off to one stack switch                                             | Needs switch-handler delimiters and recursive continuation types                           |
| `cont.bind` for partial application                                  | Reconciles Wasm's block-typing (all branches must agree on continuation type); no allocation | Extra instruction; subtle prefix-binding typing                                            |
| Continuations are non-castable (`rt castable` rule)                  | Engine need not store/expose concrete continuation type identity                             | No runtime downcasting of continuations                                                    |

---

## Where the Current Spec Differs from the 2023 Paper

The current [Stack-switching Explainer.md] has evolved beyond the OOPSLA 2023 / [WasmFX project site] "typed continuations" explainer. Notable differences:

- **Handler-clause syntax changed from `(tag $e $l)` to `(on $e $l)`,** and a second clause shape `(on $e switch)` was added for symmetric switching.
- **`switch` is now a first-class instruction.** The 2023 paper discussed `switch` / `switch_to` only as a _potential extension_ under "design considerations"; it is now standardized with its own opcode (`0xe6`), typing rule, and `(on $e switch)` handler form. Symmetric switching is a headline feature of the current spec.
- **`resume_throw_ref` was added** (opcode `0xe5`), letting an abort raise an exception supplied as an `exnref` operand rather than only by tag immediate.
- **The `barrier` instruction was dropped.** The original explainer defined `barrier` to trap any suspension crossing a boundary ("a catch-all handler that handles any control tag by immediately trapping"). It is not part of the current Explainer's instruction set.
- **Heap-type lattice and base spec.** The current spec adds the `nocont`/`cont` heap types (`nocont <: cont`) and the non-castability side-condition, and rebases on **Wasm 3.0** (function references + exception handling), reflecting how the surrounding standards moved since 2023.
- **"Sheep handler" terminology is de-emphasized** in the standards Explainer (which describes `resume` as installing a handler and acting as a delimiter) even though the underlying semantics remain the hybrid the paper called sheep handlers.

The seven-instruction set (`cont.new`, `cont.bind`, `suspend`, `resume`, `resume_throw`, `resume_throw_ref`, `switch`) plus the `cont` reference type is the current authoritative surface; the OOPSLA paper's headline summary — "our extension is minimal and only adds three main instructions for creating, suspending, and resuming continuations" — reflects the earlier, smaller design (`cont.new` to create, `suspend` to suspend, `resume` to resume; `resume_throw` and `cont.bind` round out the original instruction set).

---

## Relation to Other Wasm Proposals

| Proposal               | Relationship to stack switching                                          |
| ---------------------- | ------------------------------------------------------------------------ |
| Exception Handling     | Tags are reused and generalized with result types; `resume_throw` raises |
| Function References    | Required by `cont.new` (continuations are created from typed funcrefs)   |
| GC                     | Independent; one-shot continuations need no GC                           |
| JS Promise Integration | Alternative async path; stack switching is more general                  |
| Threads                | Orthogonal; stack switching manages concurrency _within_ one thread      |

---

## Why It Matters for Algebraic Effects

From an effect-systems viewpoint, stack switching gives Wasm a practical backend for handler-based control: operations map to `suspend` sites, handlers map to `resume` with `(on ...)` clauses, and continuation capture/resume happens at the runtime substrate level rather than via source transforms. It does not impose one source-language effect system — it is a shared target for many. See [Theory and Compilation] for compilation strategies, [Koka] for a source effect language whose `async` lowers onto exactly these primitives, [OCaml 5] for one-shot effect handlers that map almost directly, and [Effects and Event Loops] for how stack switching connects to async I/O runtimes and event loops. The corpus [index], [comparison], [evolution], [papers], and [parallelism] notes place WasmFX among the broader algebraic-effects landscape.

---

## Sources

- [WebAssembly/stack-switching] — proposal repository (read locally at `proposals/stack-switching/`)
- [Stack-switching Explainer.md] — authoritative current instruction set
- [WebAssembly proposals tracker] — phase status
- [Continuing WebAssembly with Effect Handlers (OOPSLA 2023)] — the WasmFX paper
- [WasmFX project site] — original typed-continuations explainer
- [function-references]
- [exception-handling]
- [Continuing Stack Switching in Wasmtime (WAW 2025)]

<!-- References -->

[OCaml 5]: ocaml-effects.md
[Koka]: koka.md
[Eff]: eff-lang.md
[Theory and Compilation]: theory-compilation.md
[Effects and Event Loops]: ../async-io/effects-and-event-loops.md
[index]: index.md
[comparison]: comparison.md
[evolution]: evolution.md
[papers]: papers.md
[parallelism]: parallelism.md
[WebAssembly/stack-switching]: https://github.com/WebAssembly/stack-switching
[Stack-switching Explainer.md]: https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md
[WebAssembly proposals tracker]: https://github.com/WebAssembly/proposals
[Continuing WebAssembly with Effect Handlers (OOPSLA 2023)]: https://doi.org/10.1145/3622814
[WasmFX project site]: https://wasmfx.dev/
[function-references]: https://github.com/WebAssembly/function-references
[exception-handling]: https://github.com/WebAssembly/exception-handling
[Continuing Stack Switching in Wasmtime (WAW 2025)]: https://popl25.sigplan.org/details/waw-2025-papers/7/Continuing-Stack-Switching-in-Wasmtime

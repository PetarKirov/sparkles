# WasmFX as a Compilation Target for D Stackful Fibers

This is the stackful-track WasmFX leaf of the _Coroutines for LDC_ survey. Where the cross-cutting overview ([wasm]) frames WasmFX as one of three wasm suspension strategies and the algebraic-effects deep-dive ([wasmfx]) specifies the instruction set itself, this doc answers exactly one narrower question: **how would a druntime `Fiber` backend _emit_ WasmFX stack-switching instructions?** It works out the operation-by-operation mapping of D's `core.thread.Fiber` API onto the seven `cont.*`/`suspend`/`resume`/`switch` instructions, the one-shot-continuation ↔ reusable-fiber impedance mismatch, cancellation via `resume_throw`, and the precise toolchain roadmap to make WasmFX a real `Fiber` backend. It is the wasm-native replacement for the hand-asm `fiber_switchContext` dissected in [d-fiber].

**Last reviewed:** June 4, 2026

---

> [!NOTE]
> **What the two sibling docs already cover — cite them, don't re-derive.** The
> WasmFX spec deep-dive ([wasmfx]) is the source of truth for _what the seven
> instructions mean_: the `cont $ft` reference type, the full typing of `cont.new` /
> `cont.bind` / `suspend` / `resume` / `resume_throw` / `resume_throw_ref` / `switch`,
> the `(on $e $l)` handler-clause table, "sheep handlers", the OCaml reference
> interpreter's one-shot enforcement, and tags-reused-from-EH. The cross-cutting
> overview ([wasm]) covers the central claim that LLVM Coro lowering is a _middle-end_
> transform (so D stackless coroutines compile to wasm 1.0 with zero engine support),
> the three-strategy comparison table, LDC's wasm maturity, and the orthogonality
> framing. **This** doc adds only the non-overlapping delta: the D-`Fiber`-API →
> WasmFX-instruction mapping, the reusable-fiber subtlety, cancellation, and the
> druntime-backend roadmap.

All druntime paths below are under `runtime/druntime/src/` in the LDC v1.42 tree (`$REPOS/dlang/ldc`); WasmFX paths under `$REPOS/wasm/stack-switching/proposals/stack-switching/` (the `Explainer.md` and the runnable `examples/*.wast`).

---

## Why stackful — and _only_ stackful — wants WasmFX

The load-bearing premise of this whole leaf is the dichotomy the survey draws between the two tracks. It is worth stating crisply before the mapping, because it is the reason this doc exists at all.

**A stackful fiber cannot be `CoroSplit`.** LLVM's `CoroSplit` pass builds a state machine by spilling _suspend-crossing_ live values into a frame struct — which requires the suspension points to be **statically known**, because they are the `await`/`yield` expressions the compiler can see in the coroutine body ([concepts], [wasm]). A D `Fiber` body has no such property: `Fiber.yield()` is a `static` call (`base.d:583`) reachable from _arbitrary call depth, behind any indirect call_. The compiler never sees those suspension points, so it cannot materialize a frame struct. This is exactly the conclusion drawn in [d-fiber]:

> "a stackful `Fiber` **cannot** be turned into a stackless state machine by `CoroSplit`, because its suspension points are _not statically visible_ — `yield()` can fire from any call depth, behind any indirect call. So on wasm a fiber needs Asyncify (whole-program CPS transform) or WasmFX (engine-level stack switching), while a stackless coroutine compiles to plain wasm directly."

The dichotomy that follows:

|                                     | Stackless D coroutine (hypothetical `await`/`yield`)           | Stackful D fiber (`core.thread.Fiber`)             |
| ----------------------------------- | -------------------------------------------------------------- | -------------------------------------------------- |
| Suspension points statically known? | **Yes** — they are lexical in the body                         | **No** — `yield()` from any depth/indirect call    |
| `CoroSplit`-able?                   | **Yes** → state machine + frame struct in the mid-end          | **No** — compiler can't materialize the frame      |
| What it needs on wasm               | **nothing** — compiles to plain wasm 1.0                       | an engine **stack-switch primitive** (or Asyncify) |
| Does it want WasmFX?                | **No** — would only trade a compiler frame for an engine stack | **Yes** — WasmFX _is_ the missing primitive        |

So WasmFX is the **principled native target for the stackful track, and the stackless track needs nothing from it**. The two are orthogonal, composable layers (the framing in [wasm] §5): a port ships the stackless path on wasm 1.0 _now_, and adds a WasmFX `Fiber` backend _later_ as engines ship the Phase-3 feature, without re-architecting either. The WasmFX `scheduler`/`lwt` examples used throughout this doc _are_ a green-thread runtime — precisely the workload class a `Fiber`-based runtime is.

---

## The `Fiber` control surface that must be mapped

The thing being retargeted is `core.thread.Fiber` (the API is dissected in detail in [d-fiber]). Its control surface — the operations a WasmFX backend must implement — is small (line numbers in `base.d` unless noted):

| D `Fiber` operation | Signature / location                                                                           | Semantics                                                                                                                                               |
| ------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **construct**       | `this(void function()/delegate(), size_t sz, …)` (`package.d:783`)                             | allocate + prime a _suspended_ fiber over `fn`/`dg`; **not `@nogc`** (`new StackContext` + `mmap`)                                                      |
| **resume**          | `final Throwable call(Rethrow = yes)` (`base.d:411`)                                           | transfer to the fiber; caller suspended until it `yield()`s or terminates. Requires state `HOLD`. Deliberately un-attributed (runs arbitrary user code) |
| **suspend**         | `static void yield() nothrow @nogc` (`base.d:583`)                                             | flip `EXEC→HOLD`, `switchOut()`, on resume flip `HOLD→EXEC`. Can yield from _any_ call depth                                                            |
| **suspend+throw**   | `static void yieldAndThrow(Throwable t) nothrow @nogc` (`base.d:608`)                          | yield, then throw `t` in the _resumer_ on its next `call`                                                                                               |
| **reset (reuse)**   | `final void reset() nothrow @nogc` (`base.d:478`); `reset(fn)`/`reset(dg)` (`base.d:492,499`)  | re-arm a `TERM` (or `HOLD`) fiber to `HOLD`, optionally with a new body                                                                                 |
| **state**           | `enum State { HOLD, EXEC, TERM }` (`base.d:511`)                                               | three-state machine; `TERM` ⇒ must `reset()` before reuse                                                                                               |
| **the raw switch**  | `extern (C) void fiber_switchContext(void** oldp, void* newp) nothrow @nogc` (`package.d:206`) | the hand-asm context switch: save callee-saved regs + `sp` to `*oldp`, load `sp` from `newp`                                                            |

The decisive wasm fact ([d-fiber], `package.d:576-578`): on WASI the entire stackful machinery is `assert(0, "Fibers not supported on WASI")` — in both `fiber_switchContext` and `initStack` (`package.d:1650-1652`) — because wasm exposes _no addressable machine stack, no `sp` register, no callee-saved register bank_ to swap. `fiber_switchContext` has **nothing to implement** on wasm. A WasmFX backend is exactly the thing that supplies a replacement for that missing primitive: instead of swapping `sp`, you `suspend`/`resume`/`switch` engine-managed stacks.

---

## The core mapping: `Fiber` ops → the seven stack-switching instructions

The seven instructions occupy opcode space `0xe0`–`0xe6` (`Explainer.md:1185-1195`):

```text
// Explainer.md:1187-1195
| Opcode | Instruction              | Immediates |
| ------ | ------------------------ | ---------- |
| 0xe0   | `cont.new $ct`           | `$ct : u32` |
| 0xe1   | `cont.bind $ct $ct'`     | `$ct : u32`, `$ct' : u32` |
| 0xe2   | `suspend $t`             | `$t : u32` |
| 0xe3   | `resume $ct hdl*` | `$ct : u32` (for hdl see below) |
| 0xe4   | `resume_throw $ct $e hdl*` | `$ct : u32`, `$e : u32` (for hdl see below) |
| 0xe5   | `resume_throw_ref $ct hdl*` | `$ct : u32` (for hdl see below) |
| 0xe6   | `switch $ct1 $t`          | `$ct1 : u32`, `$t : u32` |
```

The mapping below is the _asymmetric_ (`suspend`/`resume`) form — the one that matches `Fiber.call` / `Fiber.yield` directly — with the _symmetric_ (`switch`) form as the scheduler optimization. For the full typing of each instruction, see [wasmfx]; this table is only the D-operation correspondence.

| D `Fiber` operation                                          | WasmFX lowering                                                                                                                                      | Example grounding                                                     |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| **construct** `new Fiber(fn)`                                | `cont.new $ct (ref.func $fn)` — creates a _suspended_ continuation; runs only on first resume                                                        | `lwt.wast:26`; `scheduler1.wast:81`                                   |
| **resume** `fib.call()`                                      | `resume $ct (on $yield $l) (local.get $c)` — runs the cont under a handler that catches its suspensions                                              | `scheduler1.wast:90`; `lwt.wast:137-141`                              |
| **suspend** `Fiber.yield()`                                  | `suspend $yield` — transfers to the innermost enclosing `(on $yield …)`, reifying the continuation                                                   | `scheduler1.wast:114`; `generators.wast:21`                           |
| **scheduler loop** (`FiberScheduler`)                        | a `resume … (on $yield $l)` loop that re-enqueues the _fresh_ cont and dequeues the next; **or** `switch $ct $yield` for direct task→task hand-off   | asymmetric: `scheduler1.wast:83-98`; symmetric: `scheduler2.wast:179` |
| **partial application** (bind closure/args, adapt cont type) | `cont.bind $ct1 $ct2 …` — pre-binds a prefix of arguments with no allocation                                                                         | `async-await.wast:75`; `Explainer.md:773-817`                         |
| **suspend+throw** / **kill/reset of a live fiber**           | `resume_throw $ct $exn hdl*` / `resume_throw_ref $ct hdl*` — resume only to raise an exception at the suspension point, unwinding the fiber          | `scheduler2-throw.wast:90-91`                                         |
| **state `HOLD/EXEC/TERM`**                                   | not a wasm value; host bookkeeping. `TERM` = cont ran off its end (control returns to the parent's `resume` site); a consumed `cont` traps if reused | `Explainer.md:248-256`, `:906-915`                                    |

### `Fiber.call` → `cont.new` + `resume` (from `scheduler1.wast`)

`scheduler1.wast` is the cleanest "fiber == task" encoding. The scheduler `$entry` is the _resumer_; each task is a `Fiber`. Construction (`cont.new`) and the resume loop are verbatim (`scheduler1.wast:76-98`):

```wat
(func $entry (param $initial_task (ref $ft))
  (local $next_task (ref null $ct))
  ;; cont.new == new Fiber(fn): create suspended continuation, doesn't run yet
  (call $task_enqueue (cont.new $ct (local.get $initial_task)))
  (loop $resume_next
    (if (call $task_queue-empty)
      (then (return))
      (else (local.set $next_task (call $task_dequeue))))
    (block $on_yield (result (ref $ct))
      ;; resume == Fiber.call(): run task under a handler for its $yield
      (resume $ct (on $yield $on_yield) (local.get $next_task))
      ;; fell through resume without suspending => task ran to completion (== TERM)
      (br $resume_next))
    ;; reached only via suspend: stack = [(ref $ct)] -- a FRESH continuation (== HOLD)
    (call $task_enqueue)
    (br $resume_next)))
```

The task body's `(suspend $yield)` (`scheduler1.wast:114`) **is** `Fiber.yield()`. Note the two control-flow exits from `resume`: _falling through_ it = the fiber returned = `State.TERM`; _branching to_ `$on_yield` = the fiber suspended = `State.HOLD`. The host runtime's `State` enum (`base.d:511`) is exactly the bookkeeping distinguishing these two `resume` outcomes — it is _not_ a wasm-level value. (`State.EXEC` is the transient state between a `resume` and the cont's next `suspend`.)

### The scheduler loop: asymmetric vs symmetric

D's `std.concurrency.FiberScheduler` multiplexes `InfoFiber`s over one thread by _calling_ the next ready fiber and letting it `yield()` back ([d-fiber]). That is **exactly** the _asymmetric_ `scheduler1` shape: every task→task hand-off costs **two** stack switches. The Explainer names this cost (`Explainer.md:328-331`):

> "notice that this asymmetric approach requires two stack switches in order to change execution from one task to another: first when suspending from the a task to the event loop, and second when the event loop resumes the next task."

`scheduler2.wast` collapses that to **one** switch using the symmetric `switch` instruction. A yielding task calls `$yield_to_next`, which does `(switch $ct $yield (local.get $next_task))` (`scheduler2.wast:179`) to hand control _directly_ to the peer. The scheduler's `resume` installs a **switch** handler — `(on $yield switch)` (`scheduler2.wast:91`) — which acts only as the _delimiter_ for switch-suspended continuations. Two consequences a D backend must encode:

1. **The continuation type becomes recursive.** A task receives a `(ref null $ct)` param (the peer it must re-enqueue), so `$ft = (func (param (ref null $ct)))` sits inside a `(rec …)` (`scheduler2.wast:3-5`), and `$entry` passes `(ref.null $ct)` to signal "no previous task to enqueue".
2. **The task switched-_to_ enqueues the continuation it receives.** Per the Explainer (`Explainer.md:442-444`):

   > "The task that we switched to is now responsible for enqueuing the previous continuation (i.e., the one …) in the task list."

**Design takeaway for D.** A naive `FiberScheduler` → WasmFX lowering maps onto the asymmetric `resume`+`(on $yield $l)` form (`scheduler1`). The `switch`-based form (`scheduler2`) is the _performance_ lowering of a cooperative scheduler — the one worth emitting for green-thread-heavy workloads — at the cost of the recursive-cont-type and the "enqueue-the-peer-you-received" protocol. The `lwt.wast` example shows the same primitives supporting many scheduling disciplines: a `$fork` tag _and_ a `$yield` tag (`lwt.wast:8-9`), with five scheduler policies (`sync`, `kt`, `tk`, `ykt`, `ytk`) differing only in enqueue/dequeue order on fork (`lwt.wast:132-259`) — i.e. exactly the latitude a D runtime would want.

### `cont.bind` — where D would actually use it

`cont.bind` ("partial application", `Explainer.md:664-669`) matters in three concrete D lowering situations, all visible in the examples:

- **Binding constructor/closure arguments.** A D `Fiber` over a delegate with a captured frame, or a `Generator!T` body, is a partial application of a generic task-runner — bind the closure environment into the cont. The async-await example binds initial args into `$sum`: `cont.bind $iii-cont $i-cont (i32.const 1) (i32.const 3) (cont.new $iii-cont (ref.func $sum))` (`async-await.wast:75`).
- **Reconciling continuation types across a `block`.** wasm requires all branches out of a block to agree on the cont type, so a handler producing a `(ref $ct1)` that needs a `(ref $ct0)` uses `cont.bind` to unify them — the generator-extended example does this to feed a flag back to the generator (`Explainer.md:773-817`, `cont.bind $ct1 $ct0`).
- **async/await promise plumbing.** `async-await.wast` binds the promise value into a resumed continuation: `cont.bind $i-cont $cont (call $promise-value (local.get $p)) (local.get $ik)` (`async-await.wast:281`).

Crucially, `cont.bind` is **allocation-free**, which matters for `@nogc`-minded D (`Explainer.md:682-685`):

> "as continuations are single-shot no allocation is necessary: all allocation happens when the original continuation is created by preallocating one slot for each continuation argument."

---

## The one-shot ↔ reusable-fiber impedance mismatch

This is the load-bearing semantic gap, and the reason a naive "Fiber = one continuation" mental model is **wrong**.

### WasmFX continuations are one-shot; a D `Fiber` is multi-resume

WasmFX continuations are **single-shot (linear)** (`Explainer.md:907-915`):

> "Continuations in the current proposal are single-shot (aka linear), meaning that they should be invoked exactly once. A continuation can be invoked either by resuming it (with `resume`); by aborting it (with `resume_throw`); or by switching to it (with `switch`). An attempt to invoke a continuation more than once results in a trap."

The mechanism is destructive consumption (`Explainer.md:696-700`):

> "In order to ensure that continuations are one-shot, `resume`, `resume_throw`, `resume_throw_ref`, `switch`, and `cont.bind` destructively modify the suspended continuation such that any subsequent use of the same suspended continuation will result in a trap."

(The OCaml reference interpreter realizes this as a mutable `option ref` set to `None` on first use — see [wasmfx], and the one-shot effect-handler comparison in [ae-index] and [ocaml-effects].)

A D `Fiber`, by contrast, is **resumed many times**: `fib.call()` runs to the next `yield()`, control returns, and you call `fib.call()` _again_ on the _same_ object, repeatedly, until `State.TERM` ([d-fiber], `base.d:411`). `std.concurrency.Generator.popFront` _is_ `Fiber.call` and is invoked once per element ([d-fiber]). So a single long-lived `Fiber` object is resumed N times against N distinct one-shot continuations.

### Resolution: a `Fiber` is a _sequence_ of fresh one-shot continuations

The examples resolve this exactly the way a D backend must: **each `suspend` hands the handler a brand-new continuation**, and the runtime stores _that_ fresh cont as "the fiber's current continuation". You never resume the same `cont` twice; you resume a chain of distinct conts, each the successor of the last. This is explicit in the generator description (`Explainer.md:238-246`):

> "When the generator executes `suspend $gen`, execution continues in the `$on_gen` block in `$consumer`. … The topmost value is a new suspended continuation. It is the continuation of executing the generator following the `suspend` instruction (up to the handler). … the consumer simply prints the generated value and saves the new continuation in `$c` to be resumed in the next iteration."

`generators.wast`'s `$next` makes the "store the fresh cont back" pattern crystal clear with a mutable table slot — a generator handle _overwritten_ with the new cont on every call (`generators.wast:98-111`):

```wat
(func $next (export "next") (param $g i32) (result i32)
  (block $on_yield (result i32 (ref $cont))
    (resume $cont (on $yield $on_yield)
                  (table.get $active (local.get $g)))
    (return (i32.const -1)))            ;; generator done (== TERM)
  (local.set $next_k) (local.set $next_v)
  (table.set (local.get $g) (local.get $next_k))   ;; STORE the fresh cont over the old
  (return (local.get $next_v)))
```

The `lwt.wast` scheduler does the same with a `$nextk` local: every handler block result is `(ref $cont)`, so the handler _receives_ a fresh continuation it assigns back to `$nextk` (`lwt.wast:132-160`):

```wat
(block $on_yield (result (ref $cont))
  (block $on_fork (result (ref $cont) (ref $cont))
    (resume $cont (on $yield $on_yield) (on $fork $on_fork) (local.get $nextk))
    (local.set $nextk (call $dequeue))    ;; thread terminated: get next
    (br $l))
  (local.set $nextk) (call $enqueue) (br $l))  ;; $on_fork: current thread + new thread
(local.set $nextk)                              ;; $on_yield: FRESH cont becomes new $nextk
(br $l))
```

> [!IMPORTANT]
> **The D-backend rule.** A reusable `Fiber` object maps to a host-side _mutable cell_
> holding "the current one-shot continuation". `Fiber.call()` = `resume` the cell's
> cont; on `suspend`, overwrite the cell with the fresh cont the handler received; on
> fall-through (`TERM`), null the cell. The `Fiber` _identity_ is the cell, **not** any
> one cont. The `State` machine (`base.d:511`) maps onto the cell's occupancy:
> `State.HOLD` ⇔ cell holds a live cont; `State.TERM` ⇔ cell is empty/consumed;
> `State.EXEC` ⇔ this cont is currently between `resume` and its next `suspend`. This is
> _exactly_ what `$next`'s `table $active` slot and `lwt`'s `$nextk` local do.

### Consequences and a sharp edge

- **No multi-shot, no "rewind".** Backtracking or re-running a fiber from an _old_ suspension point is impossible (the old cont is consumed). A D `Fiber` never needs this — it only resumes _forward_ — so the one-shot model is sufficient. The Explainer notes multi-shot use-cases (backtracking, probabilistic programming, process duplication) are deliberately out of scope (`Explainer.md:912-915`).
- **`Fiber.reset()` is _not_ "resume the old cont again".** `reset()` (`base.d:478`) re-arms a `TERM`/`HOLD` fiber to run _from the start_ (optionally with a new body). On WasmFX that is a fresh `cont.new` over the (possibly new) function — **not** any reuse of a consumed continuation. So `reset(fn)`/`reset(dg)` (`base.d:492,499`) ⇒ drop the cell's old contents, `cont.new $ct (ref.func $fn)`, store into the cell. (Aborting a _still-suspended_ fiber before reset is the `resume_throw` story below.)
- **Linearity is the _performance_ win, not a tax.** Because a cont is used once, the engine can _move_ a real stack on suspend/resume rather than copy it ([wasmfx], performance) — the wasm-native analogue of D's `sp` swap in [d-fiber], but engine-managed. This is precisely the primitive `fiber_switchContext` cannot provide on wasm.

---

## Cancellation / unwinding: `resume_throw` (killing a green thread, `reset` of a live fiber)

D needs to **unwind a still-suspended fiber** in two situations: `Fiber.reset()` called on a `HOLD` (not-yet-`TERM`) fiber — which must run scope destructors / `scope(exit)` / RAII cleanup pending across the suspension point — and _killing a green thread_ (a scheduler that drops a task and must release its resources). The `yieldAndThrow` path (`base.d:608`) is the related "deliver an exception into a fiber" primitive.

WasmFX's `resume_throw $ct $exn hdl*` is exactly this. The instruction description (`Explainer.md:987-989`):

> "Execute a given continuation, but force it to immediately throw the annotated exception. … Used to abort a continuation."

It resumes the cont only to raise `$exn` at the _suspension point_, unwinding it through any `try_table`s in the fiber body. `resume_throw_ref` (opcode `0xe5`, `Explainer.md:996-998`) is identical but takes the exception as an `exnref` operand instead of a tag immediate — useful when the exception object is already in hand. The canonical cancellation encoding is verbatim in `scheduler2-throw.wast` (`:85-93`):

```wat
(func $schedule_task (param $c (ref null $ct))
  ;; If the task queue is too long, cancel a task in the queue
  (if (i32.ge_s (call $task_queue-count) (global.get $concurrent_task_limit))
    (then
      (block $exc_handler
        (try_table (catch $abort $exc_handler)
          ;; resume_throw raises $abort at the dequeued task's suspension point
          (resume_throw $ct $abort (call $task_dequeue))))))
  ;; ... then enqueue the new continuation
  )
```

The Explainer's prose (`Explainer.md:862-869`): the `$abort` tag "denotes an exception that will be raised at the suspension point of the continuation. We then wrap the `resume_throw` instruction in a `try_table`, which installs an exception handler for `$abort`. This exception handler simply swallows the exception … The old continuation is deallocated."

**This composes with wasm exception handling**: `resume_throw` raises an _ordinary_ wasm exception caught by an _ordinary_ `try_table` ([wasmfx] §composability). The tag/exception machinery is _shared_ with EH — tags are reused from exception handling, generalized to carry result types (see [wasmfx]).

> [!WARNING]
> **The hard dependency: cancellation needs wasm EH in druntime — which is stubbed
> today.** `resume_throw`-based cancellation is the wasm-native analogue of unwinding a
> coroutine frame on `coro.destroy`, but it requires wasm exception handling wired into
> druntime. As [wasm] §1.3 documents, `rt/wasi_exceptions.d` makes `_d_throw_exception`
> and `_Unwind_Resume` call `abort()`. So `Fiber.call`, `Fiber.yield`, and
> `Fiber.reset`-of-a-`TERM`-fiber could work on a no-EH WasmFX backend, but
> **`resume_throw`-based cancellation, `reset` of a _live_ fiber, and `yieldAndThrow`
> need the wasm EH proposal in druntime first.** D's own per-fiber `ehContext` slot in
> `StackContext` and the SjLj-stack swapping the asm backend juggles manually ([d-fiber])
> are the moral equivalents a WasmFX backend would replace with engine-native EH +
> `resume_throw`.

> [!NOTE]
> **`yieldAndThrow` is the _opposite_ throw direction — do not conflate it with
> `resume_throw`.** `Fiber.yieldAndThrow(t)` (`base.d:608`) delivers an exception to the
> _resumer_ on its next `call`, whereas `resume_throw` injects an exception _into_ the
> suspended fiber. The clean WasmFX analogue of `yieldAndThrow` is therefore _not_
> `resume_throw` but suspending with an `exnref` payload the handler re-throws on the
> resumer's stack. The two throw-directions must be kept distinct in any backend.

---

## The toolchain gap and the roadmap (WasmFX is a _future_ target)

### What is missing today

1. **The LLVM wasm backend has NO stack-switching lowering.** Confirmed in [wasm] §2.4: `IntrinsicsWebAssembly.td` (full read) defines only memory/ref/table/EH/SIMD/atomic/TLS intrinsics — **zero** `cont.new`/stack-switch matches — and a grep of `llvm/lib/Target/WebAssembly/` for `cont\.new|stack.?switch|wasmfx|StackSwitch|coro` returns **0 matches**. There is no way today to emit `cont.*` from LLVM.
2. **Engine support is Phase 3** (active implementation), with engine + toolchain coverage still uneven ([wasmfx] status; Wasmtime work ongoing).
3. **`Fiber` is `assert(0)` on wasm.** `fiber_switchContext` and `initStack` both abort on WASI (`package.d:576-578`, `:1650-1652`).
4. **EH is stubbed** (`rt/wasi_exceptions.d` → `abort()`), blocking `resume_throw`-based cancellation.

**Consequence — what a D stackful fiber on wasm must do _today_:** either (a) use **Asyncify** (`wasm-opt --asyncify`, a whole-program CPS transform — the only way to suspend an opaque call graph today, at ~2× code-size and debuggability cost; see [wasm] §3.2), or (b) sidestep the stackful primitive entirely and run the **stackless path** (a `CoroSplit`-able coroutine), or (c) not support fibers on wasm at all (the status quo `assert(0)`). WasmFX is the _principled future_ replacement for (a).

### The three-step roadmap to a WasmFX `Fiber` backend

A working "druntime `Fiber` emits `cont.*` instead of asm" pipeline requires, in dependency order:

1. **An LLVM (or Binaryen) lowering of a fiber-switch primitive to `cont.*`.** Today no path emits the stack-switching opcodes. This means either new WebAssembly-backend intrinsics (`int_wasm_cont_new`, `…_suspend`, `…_resume`, `…_switch`, `…_resume_throw`) + ISel to opcodes `0xe0`–`0xe6`, _or_ a Binaryen pass that recognizes a fiber-switch builtin and emits the instructions. The druntime `fiber_switchContext(void** oldp, void* newp)` contract (`package.d:206`) is the natural seam: its wasm implementation would be a `suspend`/`switch` rather than the asm `sp` swap.
2. **Engine support** for the Phase-3 stack-switching instructions in the target runtime (Wasmtime et al.). Without this the emitted `cont.*` won't run.
3. **A druntime `Fiber` backend** that, on the wasm target, replaces the `assert(0)` (`package.d:578`) with `cont.*`-emitting code: `cont.new` in the constructor / `initStack`; `resume` in `callImpl`; `suspend` in `yield`; the mutable-cell "current cont" bookkeeping (above) to make the _reusable_ `Fiber` work over a sequence of one-shot conts; `resume_throw` in `reset`-of-a-live-fiber / `yieldAndThrow` (gated on wasm EH). The `State` machine (`base.d:511`) maps to the cell's occupancy.

> [!IMPORTANT]
> **Roadmap one-liner.** _Stackless_ coroutines are a wasm-1.0 middle-end feature
> needing no engine support and should ship first ([wasm], [roadmap]); the _stackful_
> `Fiber` on wasm is a future WasmFX track gated on (1) an LLVM/Binaryen `cont.*`
> lowering — which does not exist today — (2) Phase-3 engine support, and (3) a druntime
> `Fiber` backend emitting `cont.*` (with cancellation further gated on wasm EH in
> druntime). Until then, a D stackful fiber on wasm must use Asyncify or fall back to
> the stackless path.

> [!NOTE]
> A full, phased implementation plan for this port — the survives-vs-replaced
> seam, the `Fiber`-op → `cont.*` encoding, the three gating problems (toolchain,
> GC, exceptions), and an eight-phase roadmap with a dependency graph — is
> developed in the companion [`Fiber` → WasmFX implementation plan][fiber-plan].

---

## Open questions

1. **Does any LLVM/Binaryen path emit `cont.*` yet?** Confirmed _no_ in LLVM as of the checkout ([wasm] §2.4). _Not_ checked: whether Binaryen has a `wasm-opt` pass, or whether the wasm-tools / `wasmfx-tools` ecosystem can emit stack-switching from a higher-level builtin. Verify against Binaryen/wasm-tools before asserting "no toolchain at all".
2. **GC-managed vs linear-memory continuation state.** WasmFX continuations are engine-managed — the stack lives in the engine, out of module reach ([d-fiber] §WebAssembly). On the asm backend the GC conservatively scans `[bstack..tstack)` for every `StackContext`; with engine-managed WasmFX stacks the module _cannot see_ that memory. **Open:** does WasmFX expose stack contents for GC scanning, or must D's wasm GC be precise/handle-based? Likely a real design constraint; not resolved by the spec docs read here.
3. **Symmetric `switch` and D's API.** D's `Fiber` API has no direct "switch to peer" call — `FiberScheduler` is asymmetric. So the `scheduler2`-style `switch` lowering is an _optimization a green-thread runtime would choose_, not a 1:1 API mapping. Worth exposing a symmetric-switch fast path?
4. **Component Model / WASI interaction.** WASIp2/p3 force PIC and the Component Model ([wasm] §1.1). How stack-switching continuations cross component boundaries (do conts survive a component call?) is _not addressed_ by the docs read here. Flag as out-of-scope / future.

---

## Sources

**WasmFX / stack-switching** (`$REPOS/wasm/stack-switching/proposals/stack-switching/`):

- `Explainer.md:1185-1195` — the seven instructions and opcodes `0xe0`–`0xe6`.
- `Explainer.md:238-256` — generator `suspend` reifies a fresh continuation the consumer stores.
- `Explainer.md:328-346` — asymmetric two-stack-switch cost; symmetric `switch` optimization.
- `Explainer.md:442-444` — switched-to task is responsible for enqueuing the previous cont.
- `Explainer.md:664-685` — `cont.bind` partial application; allocation-free (slots preallocated at `cont.new`).
- `Explainer.md:696-700`, `:907-915` — destructive one-shot consumption; single-shot/linear continuations.
- `Explainer.md:862-869`, `:987-998` — `resume_throw`/`resume_throw_ref` abort semantics; `try_table` swallows `$abort`.
- `Explainer.md:773-817` — generator-extended example using `cont.bind` to reconcile cont types.
- `examples/scheduler1.wast:76-114` — asymmetric "fiber == task" scheduler (`cont.new`/`resume`/`suspend`).
- `examples/scheduler2.wast:3-5,91,179` — symmetric `switch`, `(on $yield switch)`, recursive cont type.
- `examples/scheduler2-throw.wast:85-93` — `resume_throw` + `try_table` cancellation.
- `examples/lwt.wast:8-9,26,132-160` — `$fork`/`$yield` tags; `$nextk` fresh-cont cell; five scheduler policies.
- `examples/generators.wast:21,98-111` — `$next` overwriting a `table $active` slot with the fresh cont.
- `examples/async-await.wast:75,281` — `cont.bind` binding args and promise values into conts.

**LDC v1.42 druntime / Phobos** (`$REPOS/dlang/ldc`, `$REPOS/dlang/phobos`):

- `runtime/druntime/src/core/thread/fiber/base.d:411,478,492,499,511,583,608` — `Fiber` `call`/`reset`/`yield`/`yieldAndThrow`/`State`.
- `runtime/druntime/src/core/thread/fiber/package.d:206,576-578,783,1650-1652` — `fiber_switchContext` contract; WASI `assert(0)`; constructors; `initStack`.
- `runtime/druntime/src/rt/wasi_exceptions.d:3-20` — wasm EH stubbed to `abort()`.

**Corpus cross-links:** [wasm] (three-strategy overview, LLVM-wasm-backend negative evidence, LDC maturity), [wasmfx] (instruction typing, reference interpreter, source-feature table), [d-fiber] (the stackful baseline being retargeted), [concepts] (stackless vs stackful), [roadmap] (dependency ordering), [ae-index] / [ocaml-effects] (one-shot effect-handler analogue).

**External (not on disk):** Binaryen Asyncify (`wasm-opt --asyncify`); "Continuing Stack Switching in Wasmtime" (WAW 2025) for Phase-3 engine status — summarized via [wasm] and [wasmfx].

<!-- References -->

[concepts]: ../concepts.md
[wasm]: ../wasm-and-wasmfx.md
[d-fiber]: ./d-fiber.md
[roadmap]: ../stackless/roadmap.md
[fiber-plan]: ./fiber-to-wasmfx-plan.md
[wasmfx]: ../../algebraic-effects/wasmfx.md
[ae-index]: ../../algebraic-effects/index.md
[ocaml-effects]: ../../algebraic-effects/ocaml-effects.md

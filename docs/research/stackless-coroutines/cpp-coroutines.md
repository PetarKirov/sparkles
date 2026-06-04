# The C++20 Coroutine Model as the Design Template

This deep-dive treats C++20 coroutines as the _design template_ for D stackless
coroutines on LDC. The thesis is concrete and load-bearing: LLVM's `llvm.coro.*`
intrinsics were built **for** the C++20 stackless model, so the cleanest path to D
coroutines is to adopt a C++20-shaped surface (a promise type, an awaiter protocol,
and a coroutine handle) and lower it onto the same intrinsic vocabulary Clang already
emits. This document establishes the surface model, the canonical compiler-synthesized
body rewrite that becomes the D lowering skeleton, the surface→intrinsic mapping tables,
and the N4134 stackless rationale that frames the whole survey. The mechanical bridge to
the intrinsics lives in [LLVM coroutines][llvm-coroutines]; the abstract concepts in
[concepts][concepts]; the head-to-head with fibers in [comparison][comparison].

**Last reviewed:** June 4, 2026

---

## Why C++20 is the template

The choice to mirror C++20 is not aesthetic. The LLVM coroutine intrinsics were
co-designed with the C++ Coroutines TS by Gor Nishanov (the author of N4134, which is
also the pivot paper of this survey), and the documentation says as much: the three
`coro.await.suspend.{void,bool,handle}` intrinsics literally name the three return-type
variants of C++'s `await_suspend` (`Coroutines.rst:1933-1934`, `2015-2016`,
`2105-2106`). A D frontend that wants `llvm.coro.*` to "just work" should present a
surface whose lowering produces the same intrinsic shapes Clang produces. Conversely, an
ABI that diverges from the switched-resume model (returned-continuation, async) forfeits
the HALO optimization that makes C++20 coroutines competitive (see [§ HALO](#halo--heap-allocation-elision-optimization)).

> [!NOTE]
> This document deliberately stays in the C++20 / LLVM frame. The mapping of this
> stackless model onto WebAssembly (and the contrast with WasmFX's _stackful_ stack
> switching) is its own forward link — see [wasm-and-wasmfx][wasm] and the closing
> design notes. The two mechanisms are not the same: C++20/LLVM coroutines are a
> _stackless_ state-machine transform; WasmFX is a _stackful_ primitive.

---

## Paper lineage: how the design reached "stackless, mandated"

The C++20 model is the endpoint of a six-year design evolution. The table tracks the
surface syntax and frame model at each step.

| Paper                                                   | Date       | Surface syntax                                                                                          | Frame model                                                                                                            |
| ------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **N3722** "Resumable Functions"                         | 2013-08-30 | `resumable` keyword + `await` operator; tied to `future<T>`                                             | library / `future`-centric                                                                                             |
| **N3858** "Resumable Functions"                         | 2014-01-19 | `resumable` keyword + `await`                                                                           | sketches **both**: "Resumable Side Stacks" (stackful) and "Heap-allocated activation frames" (stackless state-machine) |
| **N4134** "Resumable Functions v.2" (Nishanov, Radigan) | 2014-10-10 | **drops `resumable`**; `await`, `yield`, `for await`; library-extensible `promise` + `resumable_traits` | **stackless, mandated**                                                                                                |
| **N4680** "Coroutines TS"                               | 2017       | **`co_await` / `co_yield` / `co_return`**; `await_transform`; `operator co_await`                       | stackless; `std::experimental::coroutine_traits` / `coroutine_handle`                                                  |
| **N4775** "Coroutines TS"                               | 2018       | same `co_*` keywords                                                                                    | stackless; promise interface finalized                                                                                 |
| **P0913** "Symmetric coroutine control transfer"        | 2018       | (no new keyword) `await_suspend` may return a handle                                                    | stackless; enables tail-call chaining                                                                                  |
| **P0981** "HALO"                                        | 2018       | (no surface change)                                                                                     | stackless; heap-allocation elision                                                                                     |
| **P1745** "Divergence of coroutines and ranges" (Baker) | 2019       | splits `coroutine_handle` → `suspend_point_handle` + `continuation_handle`                              | stackless; HALO + symmetric transfer discussed                                                                         |

Three evolution facts matter for the D port:

- **N3858 evaluated stackful vs stackless and presented both.** Its §3.2 describes
  "Resumable Side Stacks" where "each resumable function has its own side stack. A side
  stack is a stack, separate from the thread's main stack" (`n3858:279-285`); its §3.3
  describes "Heap-allocated activation frames ... [which] requires considerably more
  'heavy lifting' from the compiler, but does not require allocation of a large,
  contiguous stack ... Activation frames for resumable functions are allocated in
  heap-based storage and are reference-counted" (`n3858:337-341`). N3858 already names
  the **coroutine frame** in all but name: a "real implementation would allocate a
  suitably large byte array and use that for storage of local variables and parameters"
  (`n3858:351-352`).

- **N4134 is the pivot that mandates stackless** and introduces the library-extensible
  promise/awaiter machinery LLVM later targeted. The whole stackless rationale is
  reproduced verbatim in [§ The stackless rationale](#the-stackless-rationale-n4134--the-surveys-thesis).

- **The keyword change** `await`→`co_await`, `yield`→`co_yield`, `return`→`co_return`
  happened in the TS to avoid clobbering existing identifiers. N4134 already flagged the
  hazard: "yield is a popular identifier ... Introducing a yield keyword will break
  existing code" (`n4134:754-755`). N4134 _also_ dropped the `resumable` keyword: "This
  proposal does away with resumable keyword relying on the presence of suspend/resume
  points" (`n4134:371-372`).

The last point crystallized into the C++20 rule that **a function is a coroutine iff its
body contains a suspend point**:

> "A function is a coroutine if it contains a coroutine-return-statement ..., an
> await-expression ..., a yield-expression ..., or a range-based for ... with co_await"
> (`n4775:502-503`).

This is the rule a D frontend should adopt: there is no `coroutine` keyword to add;
_the presence of an `await`/`yield`/`co_return`-equivalent makes a function a coroutine
and triggers the body rewrite._

---

## The surface model (C++20 / Coroutines TS)

### Keywords and restrictions

The TS adds three keywords — "Add the keywords co_await, co_yield, and co_return"
(`n4775:173`). The mere presence of any of them (or `for co_await`) turns an ordinary
function into a coroutine (`n4775:502-503`). The restrictions a D design must mirror or
consciously relax:

| Restriction                                                                                                 | Spec cite       |
| ----------------------------------------------------------------------------------------------------------- | --------------- |
| Cannot use a plain `return` — "A coroutine shall not return to its caller or resumer by a return statement" | `n4775:458-459` |
| Cannot be `constexpr`                                                                                       | `n4775:489`     |
| Cannot be `main`                                                                                            | `n4775:189`     |
| Cannot have a placeholder (`auto`) / deduced return type                                                    | `n4775:494-495` |
| Cannot use C-style varargs (parameter-declaration-clause "shall not terminate with an ellipsis")            | `n4775:503-505` |

The "no plain `return`" rule is the surface manifestation of the stackless transform: a
coroutine's return value is its _coroutine object_ (the `task`/`generator`), produced by
the promise before the body even runs (see below), not a value control-flowed out of the
function.

### The compiler-synthesized coroutine body — the D lowering skeleton

This is the single most important spec fragment for a D port. For a coroutine `f` with
parameters `P1..Pn`, return type `R`, and body `F`, the compiler rewrites the body to
(`n4775:535-543`, "§ 11.4.4"):

```cpp
{
  P p promise-constructor-arguments;          // construct promise
  co_await p.initial_suspend();               // initial suspend point
  try { F } catch(...) { p.unhandled_exception(); }
final_suspend:
  co_await p.final_suspend();                 // final suspend point
}
```

The surrounding facts that complete the skeleton:

- `T = std::coroutine_traits<R, P1..Pn>` and `P = T::promise_type` (`n4775:534-536`).
  The promise _type_ is computed from the coroutine's signature; this is the hook a D
  design uses to associate a `task!T` / `generator!T` return type with its promise.
- The promise is constructed with `(p1..pn)` if a viable constructor exists, else
  default-constructed (`n4775:546-549`).
- **`get_return_object()` is called once, sequenced _before_ `initial_suspend`**:
  "the return value is produced by a call to p.get_return_object(). A call to a
  get_return_object is sequenced before the call to initial_suspend and is invoked at
  most once." (`n4775:554-556`). This is what hands the caller its `task`/`generator`
  object while the coroutine is still suspended at the initial suspend point — the caller
  gets a handle to a not-yet-run computation.
- `return_void` / `return_value` are looked up in `P`; declaring both is ill-formed
  (`n4775:550-553`).
- Parameters are **copied into the frame**: "When a coroutine is invoked, a copy is
  created for each coroutine parameter ... an object with automatic storage duration ...
  The lifetime of parameter copies ends immediately after the lifetime of the coroutine
  promise object ends." (`n4775:642-650`). N4134 notes the copy can be **elided** "if a
  coroutine never suspends or if it suspends but its parameters will not be accessed
  after the coroutine is resumed" (`n4134:429-430`).

> [!IMPORTANT]
> The D frontend (DMD / `ldc/dmd`) must perform exactly this rewrite: construct the
> promise, call `getReturnObject` (sequenced before the first suspend), `co_await
initialSuspend()`, wrap the user body in `try { F } catch { unhandledError() }`, then
> `co_await finalSuspend()` — then emit the `llvm.coro.*` intrinsic sequence around the
> suspend points. The C++ body rewrite _is_ the D lowering skeleton.

### Promise customization points

The final TS promise interface (illustrated by the `generator` in `n4775:592-604`):

| Member                                                         | Role                                                                  | Cite                       |
| -------------------------------------------------------------- | --------------------------------------------------------------------- | -------------------------- |
| `get_return_object()`                                          | builds the object returned to the caller                              | `n4775:595`, `554-556`     |
| `initial_suspend()` → awaitable                                | suspend before the user body runs                                     | `n4775:596`, `539`         |
| `final_suspend()` → awaitable (`noexcept`)                     | suspend after the user body / `co_return`                             | `n4775:597`, `542`         |
| `unhandled_exception()`                                        | called from the `catch(...)` around the body                          | `n4775:598`, `540`         |
| `return_void()` / `return_value(v)`                            | maps `co_return`                                                      | `n4775:466-468`, `599`     |
| `yield_value(v)` → awaitable                                   | maps `co_yield`                                                       | `n4775:600-603`            |
| `await_transform(e)` (optional)                                | rewrites `co_await e` operands                                        | `n4775:251-253`            |
| `get_return_object_on_allocation_failure()` (optional, static) | nothrow alloc-failure path; selects `operator new(size_t, nothrow_t)` | `n4775:571-578`, `594`     |
| `operator new` / `operator delete` in `P` (optional)           | custom frame allocation                                               | `n4775:562-570`, `628-636` |

N4134's earlier (pre-keyword) promise interface used different names: `set_result` /
`set_result(v)` (≈ `return_void` / `return_value`), `set_exception(e)` (≈
`unhandled_exception`), `yield_value`, `initial_suspend`, `final_suspend`, and a
`cancellation_requested()` (`n4134:493-588`). The N4134 promise-requirements table is the
original spec of these customization points; the TS renamed and trimmed them (notably
dropping `cancellation_requested`). A D design picking names can favor the modern TS set
(`getReturnObject` / `initialSuspend` / `finalSuspend` / `unhandledError` /
`returnVoid` / `returnValue` / `yieldValue`).

### The Awaitable / Awaiter protocol

The `co_await e` expansion (`n4775:266-284`, "§ 8.3.8") introduces auxiliary objects:
`p` = the enclosing coroutine's promise; `a` = `p.await_transform(e)` if present else
`e`; `operator co_await` overload resolution on `a` gives `o`; `e`(the awaiter) = the
materialized `o`; and `h` = a `coroutine_handle<P>` to the enclosing coroutine. The
awaiter exposes three members:

- "**await-ready** is the expression `e.await_ready()`, contextually converted to bool."
  (`n4775:268`)
- "**await-suspend** is the expression `e.await_suspend(h)`, which shall be a prvalue of
  type **void, bool, or `std::coroutine_handle<Z>`** for some type Z." (`n4775:269-270`)
- "**await-resume** is the expression `e.await_resume()`." (`n4775:271`)

Operational semantics (`n4775:273-284`):

1. Evaluate `await_ready()`.
2. If `false` ⇒ the coroutine is **considered suspended**, then `await_suspend(h)` is
   evaluated, with behavior keyed on its return type:
   - **`coroutine_handle<Z>`** evaluating to `s` ⇒ "the coroutine referred to by s is
     resumed as if by a call s.resume()" — this is **symmetric transfer**
     (`n4775:274-277`; see [§ Symmetric transfer](#symmetric-transfer-p0913)).
   - **`bool`** == `false` ⇒ "the coroutine is resumed" (i.e. do _not_ suspend; fall
     straight through to `await_resume`) (`n4775:279`).
   - **`void`** ⇒ "control flow returns to the current coroutine caller or resumer ...
     without exiting any scopes" (`n4775:281-282`).
   - An exception escaping `await_suspend` ⇒ "the exception is caught, the coroutine is
     resumed, and the exception is immediately re-thrown" (`n4775:280-281`).
3. If `await_ready()` was `true`, or upon resumption, evaluate `await_resume()`; its
   value is the value of the whole `co_await` expression (`n4775:283-284`, `272`).

`co_await` may appear only in a _suspension context_ — the function body, not in a
default argument or a namespace-scope array initializer (`n4775:240-245`, `323-324`).
N4134 additionally forbids `await` inside a `catch` block "to avoid interfering with
existing exception propagation mechanisms" (`n4134:656`, `698-700`).

The stdlib (`<coroutine>`) provides **trivial awaiters**: `suspend_always` (whose
`await_ready` returns `false`) and `suspend_never` (whose `await_ready` returns `true`),
each with empty `await_suspend` / `await_resume`. N4134 spec'd these plus a `suspend_if`
(`n4134:838-859`); the TS keeps `suspend_always` / `suspend_never` (`n4775:1087`,
`1097`). These are exactly the awaiters a D `initialSuspend`/`finalSuspend` returns to
choose "suspend here" vs "run straight through".

### `co_yield` and `co_return` desugaring

- **`co_yield e` ≡ `co_await p.yield_value(e)`** (`n4775:346-349`). N4134's identical
  earlier rule: "yield <something>; is equivalent to (void)(await
  <Promise>.yield_value(<something>))" (`n4134:745-746`). A generator's `yield_value`
  stores the value into the promise and returns `suspend_always`.
- **`co_return e`** desugars to `{ S; goto final_suspend; }` where `S` is
  `p.return_value(e)` (non-void) or `{ e; p.return_void(); }` (void) (`n4775:460-469`).
  Flowing off the end of the body is equivalent to `co_return;`, which is valid iff
  `return_void` is declared, else UB (`n4775:470-472`).

### The `coroutine_handle<P>` interface — the runtime handle

The handle is the runtime object the caller holds to drive the coroutine. Synopsis
(`n4775:892-930`, "§ 21.11.2"):

```cpp
template <> struct coroutine_handle<void> {
  constexpr coroutine_handle() noexcept;
  constexpr coroutine_handle(nullptr_t) noexcept;
  constexpr void* address() const noexcept;
  constexpr static coroutine_handle from_address(void* addr);
  constexpr explicit operator bool() const noexcept;
  bool done() const;
  void operator()() const;  void resume() const;  void destroy() const;
private: void* ptr;
};
template <class Promise> struct coroutine_handle : coroutine_handle<> {
  static coroutine_handle from_promise(Promise&);
  Promise& promise() const;
  constexpr static coroutine_handle from_address(void* addr);
};
```

- `resume()` / `operator()` resume the coroutine; `destroy()` destroys the frame,
  running in-scope destructors in reverse order (`n4775:621-627`); `done()` tests the
  final-suspend state.
- **The handle round-trips through `void*`**: `from_address(address()) == *this`
  (`n4775:984-985`) — crucial for C-callback / OS interop. N4134 stressed the same: "a
  resumption function object can be 'round tripped' to void \* and back ... allows
  seamless interactions of resumable functions with existing C APIs" (`n4134:636-637`).
- `from_promise(Promise&)` recovers the handle from the promise sub-object
  (`n4775:971-974`): `addressof(h.promise()) == addressof(p)`.
- `noop_coroutine()` returns a handle whose `resume`/`destroy` do nothing
  (`n4775:1072-1075`) — used as the "stop here" target for symmetric transfer. It maps
  directly to the LLVM intrinsic `llvm.coro.noop` (`Coroutines.rst:1265-1287`).

The handle's `void*` round-trip is the property that makes the C++ model
interop-friendly with raw OS APIs, and a D design should preserve it: the D coroutine
handle is, underneath, the `llvm.coro.begin` frame pointer.

---

## Symmetric transfer (P0913)

**What it is.** When `await_suspend(h)` returns a `coroutine_handle<Z>` value `s`, the
current coroutine suspends and `s.resume()` is invoked as a **tail call** rather than
returning to the original resumer. The spec: "If that expression has type
`coroutine_handle<Z>` and evaluates to a value s, the coroutine referred to by s is
resumed as if by a call s.resume()." with the critical Note:

> "[ Note: Any number of coroutines may be successively resumed in this fashion,
>
> > eventually returning control flow to the current coroutine caller or resumer. — end
> > note ]" (`n4775:276-279`)

**Why it matters — the unbounded-chaining / no-stack-growth argument.** Without symmetric
transfer, resuming coroutine A which awaits coroutine B which resumes A's continuation,
and so on, makes each `resume()` an ordinary call that **grows the C stack**. A
ping-pong between two coroutines (or a long `task`-await chain) eventually overflows the
stack. Symmetric transfer makes the resume a **guaranteed tail call**, so the stack does
not grow no matter how long the chain. P1745 frames this as the core capability: a
`ContinuationHandle` "can then either be invoked asymmetrically using `operator()` or can
be invoked symmetrically (ie. with tail-recursion) by returning the handle from
`await_suspend()`." (`p1745:199-200`).

The chain terminator is `noop_coroutine()` (≡ the LLVM `llvm.coro.noop`). P1745: "In
cases where an awaitable does not have another continuation to transfer execution to it
needs to be able to suspend and return execution back to the most-recent caller on the
stack that asymmetrically invoked a continuation handle ... If such a handle was returned
from `await_suspend()` then this would cause the top-most call to `resume()` on the stack
to return to its caller." (`p1745:602-610`). Symmetric transfer arrived via P0913 ("Add
symmetric coroutine control transfer", Nishanov; `p1745:138`, `200`, `872`, `1437`).

**The LLVM bridge.** This is encoded by `llvm.coro.await.suspend.handle`
(`Coroutines.rst:2081-2167`). Its semantics, verified against the source:

> "`await_suspend_function` must return a pointer to a valid coroutine frame. The
> intrinsic will be lowered to a tail call resuming the returned coroutine frame. It will
> be marked `musttail` on targets that support that. Instructions following the intrinsic
> will become unreachable." (`Coroutines.rst:2129-2132`)

The lowered form (`Coroutines.rst:2149-2157`):

```llvm
await.suspend:
  %save = call token @llvm.coro.save(ptr %hdl)
  %next = call ptr @await_suspend_function(ptr %awaiter, ptr %hdl)
  musttail call void @llvm.coro.resume(%next)
  ret void
```

So D's symmetric-transfer lowering is mechanical: emit `coro.await.suspend.handle` with a
wrapper that calls the D awaiter's `awaitSuspend` and returns the next frame pointer;
`CoroSplit` turns it into a `musttail call coro.resume`. The no-stack-growth guarantee is
delegated entirely to LLVM. The detailed intrinsic semantics are in
[LLVM coroutines][llvm-coroutines].

---

## HALO — Heap Allocation eLision Optimization

### The pattern that enables elision

N4134 already describes the optimization premise — the famous "as-if" allowance for
removing the coroutine's heap allocation:

> "An implementation is allowed to elide calls to the allocator's allocate and deallocate
> functions and use stack memory of the caller instead if the meaning of the program will
> be unchanged except for the execution of the allocate and deallocate functions."
> (`n4134:435-437`)

The TS leaves room for allocation — "implementation may need to allocate additional
storage" (`n4775:562`) — and **HALO** (P0981, "Halo: coroutine Heap Allocation eLision
Optimisation", Smith et al.; referenced `p1745:900`, `1439`) is the optimization that
removes it when the as-if rule permits.

### How LLVM realizes it — the intrinsic protocol

The whole allocation/deallocation is expressed via intrinsics _specifically so it can be
elided_, verbatim from the source:

> "There is a somewhat complex protocol of intrinsics for allocating and deallocating the
> coroutine object. It is complex in order to allow the allocation to be elided due to
> inlining." (`Coroutines.rst:115-118`)

The pre-elision shape (`Coroutines.rst:421-446`) makes both the allocation _and_ the
deallocation conditional and intrinsic-mediated:

```llvm
entry:
  %id = call token @llvm.coro.id(...)
  %need.dyn.alloc = call i1 @llvm.coro.alloc(token %id)   ; true => must heap-alloc
  br i1 %need.dyn.alloc, label %dyn.alloc, label %coro.begin
dyn.alloc:
  %size = call i32 @llvm.coro.size.i32()
  %alloc = call ptr @CustomAlloc(i32 %size)
  br label %coro.begin
coro.begin:
  %phi = phi ptr [ null, %entry ], [ %alloc, %dyn.alloc ]
  %hdl = call noalias ptr @llvm.coro.begin(token %id, ptr %phi)
...
cleanup:
  %mem = call ptr @llvm.coro.free(token %id, ptr %hdl)   ; null if elided
  %need.dyn.free = icmp ne ptr %mem, null
  br i1 %need.dyn.free, label %dyn.free, label %if.end
```

- `llvm.coro.alloc` returns "`true` if dynamic allocation is required ... and `false`
  otherwise" (`Coroutines.rst:1227-1228`).
- `llvm.coro.free` returns the block to free "or `null` if this instance ... did not use
  dynamically allocated memory" (`Coroutines.rst:1135-1137`).

> [!WARNING]
> A D frontend must emit this conditional protocol and _not_ unconditionally `malloc` the
> frame. If the frontend hard-codes a `malloc`, `CoroElide` has nothing to elide and the
> coroutine pays a heap allocation per call even when it provably outlives nothing. This
> is the single most consequential ABI decision for D coroutine performance.

### The condition for elision

The elidable pattern is the RAII shape where the coroutine's lifetime is bounded by its
creator (verified against the source):

> "[a coroutine usage pattern] where a coroutine is created, manipulated and destroyed by
> the same calling function, is common for coroutines implementing RAII idiom and is
> suitable for allocation elision optimization which avoid dynamic allocation by storing
> the coroutine frame as a static `alloca` in its caller." (`Coroutines.rst:408-413`)

The core requirement is that the coroutine's `destroy()` runs **synchronously** and the
frame's lifetime is bounded by the caller — P1745: "optimisations like HALO (See P0981R0)
rely on `destroy()` completing synchronously so that it knows the memory used by the
coroutine frame is no longer in-use." (`p1745:899-901`).

Two LLVM passes implement it (`Coroutines.rst:2209-2225`):

- **`CoroElide`** — "examines if the inlined coroutine is eligible for heap allocation
  elision optimization. If so, it replaces `coro.begin` ... with an address of a coroutine
  frame placed on its caller and replaces `coro.alloc` and `coro.free` ... with `false`
  and `null` respectively to remove the deallocation code. This pass also replaces
  `coro.resume` and `coro.destroy` intrinsics with direct calls ..."
  (`Coroutines.rst:2216-2224`). The hard prerequisite, verified against the source: "The
  CoroElide optimization pass relies on coroutine ramp function to be inlined."
  (`Coroutines.rst:2287-2289`).
- **`CoroAnnotationElide`** — handles "must elide" usages; with the `coro_elide_safe` call
  attribute `CoroSplit` generates an `f.noalloc` ramp that "suppresses any allocations or
  deallocations" and takes a caller-provided frame pointer (`Coroutines.rst:2209-2214`,
  `2242-2252`). The recursion caveat: "Note that for recursive or mutually recursive
  functions this elision is usually not possible." (`Coroutines.rst:2251-2252`).
- `llvm.coro.dead` is an optimization hint marking end-of-frame-lifetime for HALO of
  coroutines not explicitly destroyed (`Coroutines.rst:1180-1198`).

After elision the example collapses to straight-line code with the frame on the caller's
stack (`Coroutines.rst:454-460`, `669-675`): the inlined body's `print` calls remain and
the `malloc`/`free` vanish.

### Frontend hooks the D compiler must emit for HALO

- Emit the `coro.alloc` / `coro.size` / `coro.begin` / `coro.free` protocol exactly as
  above — do **not** unconditionally `malloc`.
- Tag the ramp with `presplitcoroutine` (`Coroutines.rst:1359`) and emit exactly one
  `coro.id` and one `coro.begin` per coroutine (`Coroutines.rst:1357`, `1092`).
- Ensure the ramp is _inlinable_ into its caller — without ramp inlining, `CoroElide` is
  inert.
- Optionally use `coro_elide_safe` on calls and `coro.outside.frame` metadata to keep
  internal control allocas out of the frame (`Coroutines.rst:2257-2268`).

The lifetime/attribute consequences of these hooks are explored in
[attributes-and-memory][attributes].

---

## Explicit mapping: surface construct → `llvm.coro.*` intrinsic

These are the most actionable tables for the D design: the precise correspondence between
each C++20 surface construct and the intrinsic it lowers to. All examples are
**switched-resume lowering** (the default; signaled by `llvm.coro.id` —
`Coroutines.rst:67-68`). LLVM also has returned-continuation (`coro.id.retcon[.once]`,
`Coroutines.rst:128-174`) and async (`coro.id.async`, `Coroutines.rst:179-256`)
lowerings; for a C++20/D-shaped surface, **switched-resume is the match**.

### Frame / identity / allocation

| Surface concept                                                                              | Intrinsic                                         | Cite                                  |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------- |
| coroutine identity (ties id/alloc/begin together; 2nd arg designates the promise alloca)     | `llvm.coro.id(align, promise, coroaddr, fnaddrs)` | `Coroutines.rst:1321-1357`            |
| "do I need to heap-allocate the frame?"                                                      | `llvm.coro.alloc(id)` → i1                        | `Coroutines.rst:1218-1242`            |
| frame size / align (lowered to constants post-split)                                         | `llvm.coro.size.iN()`, `llvm.coro.align`          | `Coroutines.rst:1009-1061`, `310-311` |
| initialize frame, get frame ptr (the "coroutine handle")                                     | `llvm.coro.begin(id, mem)`                        | `Coroutines.rst:1062-1092`            |
| get this coroutine's own frame address                                                       | `llvm.coro.frame()`                               | `Coroutines.rst:1291-1313`            |
| frame ptr to free (or null if elided)                                                        | `llvm.coro.free(id, frame)`                       | `Coroutines.rst:1124-1172`            |
| handle of a do-nothing coroutine (≡ `noop_coroutine()`)                                      | `llvm.coro.noop()`                                | `Coroutines.rst:1263-1287`            |
| mark end of frame access (ramp: no-op; resume/destroy: `ret void`; unwind: unwind-to-caller) | `llvm.coro.end(handle, unwind, token)`            | `Coroutines.rst:1487-1601`            |
| custom-ABI begin (plugin ABIs)                                                               | `llvm.coro.begin.custom.abi(id, mem, abi-index)`  | `Coroutines.rst:1096-1122`, `753-762` |

### Suspend points (`co_await` / `co_yield` / initial / final)

| Surface concept                                                                                | Intrinsic                             | Cite                                  |
| ---------------------------------------------------------------------------------------------- | ------------------------------------- | ------------------------------------- |
| prepare-for-resumption point (store resume index) — separated from suspend for async callbacks | `llvm.coro.save(handle)` → token      | `Coroutines.rst:1759-1804`            |
| the suspend itself; result switches: default=suspend(-1), 0=resumed, 1=destroyed               | `llvm.coro.suspend(save, final)` → i8 | `Coroutines.rst:1695-1755`            |
| `final_suspend()` point → set `final=true` arg of `coro.suspend`                               | `llvm.coro.suspend(token, i1 true)`   | `Coroutines.rst:683-685`, `1718-1721` |
| query "is at final suspend?" (≡ `coroutine_handle::done()`)                                    | `llvm.coro.done(handle)`              | `Coroutines.rst:905-929`, `686-692`   |

The canonical `co_await` / `co_yield` / initial / final suspend all lower to a
`coro.save` → (await-suspend logic) → `coro.suspend` + `switch` triple
(`Coroutines.rst:298-299`, `587-597`):

```llvm
%save = call token @llvm.coro.save(ptr %hdl)
; ... awaiter.await_suspend(...) logic here ...
%s = call i8 @llvm.coro.suspend(token %save, i1 false)
switch i8 %s, label %suspend [i8 0, label %resume   ; coro.resume came in
                              i8 1, label %cleanup]  ; coro.destroy came in
```

`co_yield` / `yield_value` stores the yielded value into the promise alloca before
suspending; the consumer reads it via `coro.promise` (see the next table and
`Coroutines.rst:609-663`, the generator example).

### The `await_suspend` body → the three `coro.await.suspend.*` intrinsics

**This is the heart of the C++→LLVM bridge.** The `await_suspend` block "is essentially
asynchronous to the execution of the coroutine. Inlining it normally into an unsplit
coroutine can cause miscompilation because the coroutine CFG misrepresents the true
control flow" (`Coroutines.rst:1924-1931`). So the frontend wraps it in one of three
intrinsics keyed on `await_suspend`'s return type. Each "must be used between
corresponding `coro.save` and `coro.suspend` calls. It is lowered to a direct
`await_suspend_function` call during `CoroSplit`" (`Coroutines.rst:1953-1955`).

| `await_suspend` return type | Intrinsic                                             | Lowered behavior                                                                             | Cite                                               |
| --------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `void`                      | `llvm.coro.await.suspend.void(awaiter, hdl, fn)`      | direct call to wrapper, then `coro.suspend`                                                  | `Coroutines.rst:1909-1987`                         |
| `bool`                      | `llvm.coro.await.suspend.bool(awaiter, hdl, fn)` → i1 | if wrapper returns **true** ⇒ "the current coroutine is immediately resumed" (skips suspend) | `Coroutines.rst:1991-2077` (semantics `2039-2040`) |
| `coroutine_handle<Z>`       | `llvm.coro.await.suspend.handle(awaiter, hdl, fn)`    | wrapper returns next frame ptr ⇒ `musttail call coro.resume(next)` (symmetric transfer)      | `Coroutines.rst:2079-2167`                         |

The wrapper-function signatures the D frontend must emit (`Coroutines.rst:1948`, `2030`,
`2120`):

```llvm
declare void @await_suspend_function(ptr %awaiter, ptr %hdl)  ; void variant
declare i1   @await_suspend_function(ptr %awaiter, ptr %hdl)  ; bool variant
declare ptr  @await_suspend_function(ptr %awaiter, ptr %hdl)  ; handle variant
```

Each wrapper reconstructs the language handle from `%hdl` and calls the user awaiter's
`await_suspend` (`Coroutines.rst:1983-1987`, `2073-2077`, `2160-2166`). The
`await_ready` / `await_resume` halves are emitted by the frontend as ordinary calls and
branches _around_ this intrinsic (the `bool` example shows `await.ready: call
Awaiter::await_resume`, `Coroutines.rst:2058-2060`).

> [!NOTE]
> The fact that the three intrinsics are named `void` / `bool` / `handle` — exactly the
> three legal `await_suspend` return types — is the clearest evidence that LLVM's
> coroutine support was built for the C++20 model. A D awaiter's `awaitSuspend` returning
> `void` / `bool` / `D coroutine handle` maps 1:1 onto these three intrinsics.

### Promise + handle manipulation (caller / consumer side)

| Surface concept                                                               | Intrinsic                                                                      | Cite                                      |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------- |
| `coroutine_handle::resume()` / `operator()`                                   | `llvm.coro.resume(handle)`                                                     | `Coroutines.rst:880-903`                  |
| `coroutine_handle::destroy()`                                                 | `llvm.coro.destroy(handle)`                                                    | `Coroutines.rst:847-877`                  |
| `coroutine_handle::done()`                                                    | `llvm.coro.done(handle)`                                                       | `Coroutines.rst:905-929`                  |
| `coroutine_handle::promise()` / `from_promise` (project promise out of frame) | `llvm.coro.promise(ptr, align, from)`                                          | `Coroutines.rst:84-87`, `933-1001`        |
| `from_address` / `address()`                                                  | (no intrinsic — the handle _is_ the `coro.begin` ptr; round-trips via `void*`) | `Coroutines.rst:120-123`; `n4775:980-985` |

`resume` / `destroy` are "When possible ... replaced with a direct call to the [resume /
destroy] function" (`Coroutines.rst:871-877`, `900-903`) — the `CoroElide`
devirtualization that turns an indirect resume into a direct call once the
implementation is known.

### When each construct is consumed (the lowering pipeline)

- **`CoroEarly`**: lowers `coro.promise`, `coro.frame`, `coro.done`
  (`Coroutines.rst:2194-2199`); sets `coro.id`'s 3rd arg to the function
  (`Coroutines.rst:1341-1342`).
- **`CoroSplit`**: builds the frame, outlines the ramp / resume / destroy functions, and
  **lowers the three `coro.await.suspend.*` intrinsics** (`Coroutines.rst:2203-2207`).
  Splits the coroutine into ramp + resume + destroy (`Coroutines.rst:92-109`).
  Live-across-suspend values get frame slots (`Coroutines.rst:339-346`); a suspend-index
  in the frame drives a `switch` in the shared resume/destroy functions
  (`Coroutines.rst:104-109`, `497-533`).
- **`CoroElide` / `CoroAnnotationElide`**: HALO (see above).
- **`CoroCleanup`**: lowers any remaining intrinsics late (`Coroutines.rst:2226-2229`).

The pass-by-pass walk-through is detailed in [LLVM coro internals][llvm-internals].

### Worked end-to-end example (from the `.rst`)

The frontend emits an unsplit ramp tagged `presplitcoroutine` (`Coroutines.rst:287`):

```llvm
define ptr @f(i32 %n) presplitcoroutine {
entry:
  %id    = call token @llvm.coro.id(i32 0, ptr null, ptr null, ptr null)
  %size  = call i32   @llvm.coro.size.i32()
  %alloc = call ptr   @malloc(i32 %size)
  %hdl   = call noalias ptr @llvm.coro.begin(token %id, ptr %alloc)
  br label %loop
loop:
  ...
  %0 = call i8 @llvm.coro.suspend(token none, i1 false)
  switch i8 %0, label %suspend [i8 0, label %loop, i8 1, label %cleanup]
cleanup:
  %mem = call ptr @llvm.coro.free(token %id, ptr %hdl)
  call void @free(ptr %mem)
  br label %suspend
suspend:
  call void @llvm.coro.end(ptr %hdl, i1 false, token none)
  ret ptr %hdl
}
```

(`Coroutines.rst:287-308`.) `CoroSplit` produces `@f` (the ramp), `@f.resume`, and
`@f.destroy` (`Coroutines.rst:363-403`); with multiple suspend points a frame `i32`
index plus a `switch` selects the resume block (`Coroutines.rst:502-533`). The caller
side resumes / destroys via `coro.resume` / `coro.destroy` (`Coroutines.rst:29-36`).

---

## The stackless rationale (N4134) — the survey's thesis

N4134 is explicit that the **design goals force stackless**. This is the paragraph the
whole survey turns on:

> "Design goals of scalability and seamless interaction with existing facilities without
> overhead (namely calling into existing libraries and OS APIs without restrictions)
> **necessitates stackless coroutines**." (`n4134:138-140`, "Stackless vs Stackful")

The design goals it enumerates (`n4134:122-131`):

- "Highly scalable (to billions of concurrent coroutines)"
- "Highly efficient resume and suspend operations comparable in cost to a function call
  overhead"
- "Seamless interaction with existing facilities with no overhead"
- "Open ended coroutine machinery allowing library designers to develop coroutine
  libraries"
- "Usable in environments where exception are forbidden"

### The scalability / memory argument against stackful

> "General purpose stackful coroutines that reserve default stack for every coroutine
> (1MB on Windows, 2MB on Linux) will exhaust all available virtual memory in 32-bit
> address space with only a few thousand coroutines. Besides consuming virtual memory,
> stackful coroutines lead to memory fragmentation, since with common stack
> implementations, besides reserving virtual memory, the platform also commits first two
> pages of the stack ... even though the actual state required by a coroutine could be as
> small as a few bytes." (`n4134:142-148`)

N4134 then rejects the two standard mitigations:

- **Split / segmented stacks**: "requires the entire program (including all the libraries
  and OS facilities it calls) to be either compiled with split-stacks or to incur
  run-time penalties when invoking code that is not compiled with split-stack support."
  (`n4134:150-152`)
- **Small fixed-size stacks**: "limits what can be called from such coroutines as it must
  be guaranteed that none of the functions called shall ever consume more memory than
  allotted in a small fixed sized stack." (`n4134:154-156`)

### The stackless ↔ stackful distinction (definitions)

- **Stackless coroutine**: "a coroutine which state includes variables and temporaries
  with automatic storage duration in the body of the coroutine and **does not include the
  call stack**." (`n4134:102-104`)
- **Stackful coroutine / fiber**: "state includes the **full call stack** associated with
  its execution enabling suspension from nested stack frames. Stackful coroutines are
  equivalent to fibers or user-mode threads." (`n4134:106-108`)
- The frame holds: "coroutine promise, formal parameters, variables and temporaries with
  automatic storage duration declared in the coroutine body and an implementation defined
  platform context." (`n4134:79-81`)

This is exactly the axis explored against D's existing `core.thread.fiber` in the
[D fiber baseline][d-fiber] and quantified in [comparison][comparison].

### The cost of stackless: cannot suspend across nested frames

The acknowledged limitation: a stackless coroutine **can only suspend within its own
frame, not from a function it calls** (because the callee's frame lives on the real
stack, not in the captured coroutine frame). N4134's mitigation is **recursive
composition of coroutines**:

> "Recursive application of generators allows to mitigate stackless coroutine inability to
> suspend from nested stack frames." (`n4134:219-220`)

— illustrated by the `recursive_generator<int> range(...)` that does `yield range(a,
mid); yield range(mid, b)` (`n4134:222-247`). This is the precise tradeoff the D survey
must state plainly:

> **Stackful** = suspend anywhere (including from deep nested calls), heavy memory per
> coroutine.
> **Stackless** = suspend only at lexical await points in the coroutine body; the frame
> is exactly the live state (bytes); deep composition is achieved via await-chaining +
> symmetric transfer rather than a captured call stack.

### Efficiency / zero-overhead evidence (N4134 implementation experience)

- Async I/O example: "Execution of this program incurs **only one memory allocation and
  no virtual function calls**. The generated code is as good as or better than what could
  be written in C over raw OS facilities." — because `OVERLAPPED` structures live on the
  coroutine frame instead of separate heap allocations (`n4134:185-193`). The `future`
  shared state is fused into the frame: "Allocation of a future shared state ... is
  combined with coroutine frame allocation and does not incur an extra allocation."
  (`n4134:192-193`).
- Scalability demonstrated: one million goroutines connected by channels
  (`n4134:275-303`); a parent-stealing `fib(42)` runs "in less than 12k of space, whereas
  ... more traditional scheduling will cause state explosion that will consume more than
  2gig of memory around fib(32)." (`n4134:269-271`).

### The exception-free / `@nogc`-friendly angle

N4134 deliberately makes coroutines usable without exceptions ("Usable in environments
where exception are forbidden", `n4134:131`; the whole "no-except operations" section,
`n4134:933-1042`):

- `get_return_object_on_allocation_failure` for the nothrow alloc-failure path
  (`n4134:944-965`);
- `await_suspend` returning `bool false` to abort a launch (`n4134:1023-1039`);
- a generalized `set_exception(E)` over arbitrary error types (`n4134:971-976`).

This maps cleanly onto D's `@nogc nothrow` + `Expected!(T,E)` idioms: a D promise can
avoid GC and exceptions and report failures via `Expected` instead of an `unhandledError`
that throws. The interplay of these attributes with the frame allocation is the subject
of [attributes-and-memory][attributes].

> [!NOTE]
> P1745's `suspend_point_handle` / `continuation_handle` split (multi-path resume,
> `set_done()`, async RVO, heterogeneous resume) is **post-C++20 and not shipped**; C++20
> kept the single-path `coroutine_handle` (`p1745:159-200`, `839-883`). A D design can
> start with the single-path handle and leave room for a multi-path extension later.

---

## Caveats from the LLVM side

These are the known sharp edges that a D-on-LDC lowering inherits from the intrinsic
layer (sourced from `Coroutines.rst`):

- **No frame access on the suspend path.** "When `coro.suspend` returns -1, the coroutine
  is suspended, and it's possible that the coroutine has already been destroyed (hence the
  frame has been freed). We cannot access anything on the frame on the suspend path." —
  and LICM was disabled for loops with `coro.suspend` to avoid use-after-free; "the
  general problem still exists and requires a general solution." (`Coroutines.rst:2275-2281`).
- **`inalloca` parameters unsupported.** "Cannot handle coroutines with `inalloca`
  parameters (used in x86 on Windows)." (`Coroutines.rst:2294`).
- **Alignment quirk.** "Alignment is ignored by coro.begin and coro.free intrinsics."
  (`Coroutines.rst:2296`).
- **LTO.** "Make required changes to make sure that coroutine optimizations work with
  LTO." (`Coroutines.rst:2298-2299`).
- **Stability.** "Compatibility across LLVM releases is not guaranteed."
  (`Coroutines.rst:9-10`) — the intrinsic set / ABI can shift; pin to the LDC-linked LLVM
  (here 23.0.0git).

---

## Design notes for D-on-LDC

A synthesis of the actionable conclusions for adding stackless coroutines to LDC:

1. **Adopt the C++20 promise + awaiter + handle shape directly.** It is what `llvm.coro.*`
   was built to lower; the `coro.await.suspend.{void,bool,handle}` intrinsics literally
   name the three `await_suspend` return-type variants (`Coroutines.rst:1933-1934`,
   `2015-2016`, `2105-2106`). A D awaiter exposes `awaitReady` / `awaitSuspend` /
   `awaitResume`; a D promise exposes `getReturnObject` / `initialSuspend` /
   `finalSuspend` / `unhandledError` (or `returnValue` / `returnVoid`) / `yieldValue`.

2. **The canonical body rewrite (`n4775:535-543`) is the D lowering skeleton.** Construct
   the promise → `co_await initialSuspend()` → `try { F } catch { unhandledError() }` →
   `co_await finalSuspend()`, with `getReturnObject` sequenced before the initial suspend.
   The D frontend (DMD / `ldc/dmd`) performs this rewrite and emits the intrinsic sequence
   around the suspend points.

3. **Symmetric transfer is mandatory for tasks.** D's `await` of another task must lower
   its `awaitSuspend`-returns-handle case to `coro.await.suspend.handle` to get the
   `musttail call coro.resume` and avoid stack growth on long await chains
   (`Coroutines.rst:2129-2132`). Provide a D `noopCoroutine()` (≡ `llvm.coro.noop`) as the
   chain terminator.

4. **Emit the full alloc/free intrinsic protocol** (not a hard `malloc`) so `CoroElide`
   can HALO the frame onto the caller's stack; ensure the ramp is inlinable
   (`Coroutines.rst:115-118`, `421-446`, `2287-2289`). Use `coro_elide_safe` /
   `coro.outside.frame` where appropriate.

5. **Mark the ramp `presplitcoroutine`, emit exactly one `coro.id` / `coro.begin`, and
   designate the D promise as the `coro.id` promise alloca** (`Coroutines.rst:1357-1359`,
   `1092`, `1338-1339`). The promise alloca lets `coro.promise` project it for the
   consumer (`Coroutines.rst:933-1001`) — the D `task` / `generator` wrapper reads
   results / yields from it.

6. **Switched-resume is the right default ABI** for a general D surface (default;
   resume/destroy/done/promise queryable without knowing the implementation,
   `Coroutines.rst:64-123`). Returned-continuation / async lowerings are for lower-level
   or Swift-style ABIs (`Coroutines.rst:125-256`) and are notably "ineffective at
   statically eliminating allocations after fully inlining" (`Coroutines.rst:170-174`) —
   i.e. worse HALO.

7. **`@nogc nothrow` is achievable** via the exception-free customization points
   (`get_return_object_on_allocation_failure`, `await_suspend` returning `bool false`,
   generalized `set_exception`); align with the project's `Expected!(T,E)` error model.

8. **WasmFX is a forward link, not this design's mechanism.** WasmFX / wasm stack-switching
   is a _stackful_ primitive; the C++20/LLVM model here is _stackless_. A D-on-Wasm port
   would lower the same stackless surface to `llvm.coro.*` (a state-machine), independent
   of whether the runtime later uses WasmFX for _stackful_ fibers. See [wasm-and-wasmfx][wasm]
   and [roadmap][roadmap] for the sequencing of these decisions; the cross-cutting concept
   contrast lives in [concepts][concepts].

---

## Sources

Primary artifacts used for this document:

- C++ proposals / TS revisions (PDFs in `$REPOS/papers/`, citations are
  `paper:line` against `pdftotext -layout` extractions):
  - `n3722-preliminary-coroutines-2013.pdf` — N3722 "Resumable Functions"
  - `n3858-resumable-functions-2014.pdf` — N3858 (stackful vs stackless evaluation)
  - `n4134-resumable-functions-2014.pdf` — N4134 (the stackless-mandate pivot)
  - `n4680-coroutines-ts-2017.pdf` — N4680 Coroutines TS
  - `n4775-coroutines-ts-2018.pdf` — N4775 Coroutines TS (the canonical body rewrite,
    promise interface, awaiter protocol, handle synopsis)
  - `p1745-divergence-coroutines-ranges-2019.pdf` — P1745 (symmetric transfer & HALO
    framing, handle split)
- P0913 "Add symmetric coroutine control transfer" (Nishanov) — open-std,
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0913r1.html>
- P0981 "Halo: coroutine Heap Allocation eLision Optimisation" (Smith et al.) — open-std,
  <https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0981r0.html>
- LLVM 23.0.0git: `$REPOS/llvm-project/llvm/docs/Coroutines.rst`
  (intrinsic semantics, lowering passes, HALO, `await_suspend` intrinsics, worked
  example) — key quotes re-verified against the source file.

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[llvm-coroutines]: ./llvm-coroutines.md
[llvm-internals]: ./llvm-coro-internals.md
[comparison]: ./comparison.md
[d-fiber]: ./d-fiber-baseline.md
[d-design]: ./d-language-design.md
[attributes]: ./attributes-and-memory.md
[wasm]: ./wasm-and-wasmfx.md
[roadmap]: ./roadmap.md

# Koka

A strongly typed functional language whose every function carries a row-polymorphic effect type, and whose algebraic effect handlers are compiled to plain C via _evidence passing_ — no stack walking, no state machine, just a selective monadic translation that runs on the native C call stack and only reifies a continuation on a genuine suspend.

| Field         | Value                                                                                                                                         |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Koka (compiler in Haskell; runtime `kklib` in C99)                                                                                            |
| Version       | `koka.cabal`/`package.yaml` at 3.2.7 (in-development); latest tagged release v3.2.3 (2026-03-17), the 3.2.x line opened with v3.2.0 (2025-07) |
| License       | Apache-2.0 (Koka, `kklib`, `libhandler`, `nodec`); MIT (`libmprompt`)                                                                         |
| Repositories  | [koka], [libmprompt], [libhandler], [nodec]                                                                                                   |
| Documentation | [The Koka Programming Language (Book)]                                                                                                        |
| Key Authors   | Daan Leijen, Ningning Xie (Microsoft Research) and contributors                                                                               |
| Encoding      | Row-polymorphic effect types + generalized evidence passing, compiled to C / JS / WASM                                                        |

---

## Overview

### What it solves

Koka tracks _every_ effect a function may perform in its type, while keeping effects almost entirely inferred (Hindley–Milner extended to rows). Rather than building exceptions, generators, async/await, iterators, and nondeterminism into the language, Koka derives them all from one mechanism — algebraic effect handlers — and then compiles that mechanism efficiently enough that it competes with hand-written C. The interesting engineering question Koka answers is _how_ to compile general (multi-shot, scoped) handlers without a tracing GC, without a bytecode VM, and without giving up the C stack: the answer is the **evidence-passing monadic translation** described in the ICFP'21 paper and implemented across the Haskell compiler and the C `kklib` runtime.

The async-I/O relevance is two-fold. First, the compiled-handler runtime (`kklib`) shows exactly how a _suspendable_ computation is represented at the machine level (an evidence vector, a yield record, a Kleisli composition of continuations). Second, the sibling [nodec] project demonstrates the payoff: it wraps libuv's callback-based async I/O as _direct-style_ effect operations in C, so the call `async_read(stream)` looks synchronous but actually yields to an event-loop handler and resumes from a libuv callback. See [Effects and Event Loops] and [libuv] for the broader event-loop context.

### Design philosophy

- **Small, general core.** First-class functions, algebraic data types, a polymorphic type-and-effect system, and effect handlers. Control constructs are libraries, not keywords.
- **Effects are semantic, not cosmetic.** A type without `exn` provably never throws; without `div` it provably terminates. The effect row is part of the function's meaning.
- **No runtime, no GC.** Compilation targets C; memory is managed by Perceus precise reference counting with reuse analysis, so cycle-free programs are garbage-free.
- **Pay only for what you use.** Operation kinds (`val`/`fun`/`ctl`/`final ctl`) let the _handler author_ choose how much continuation machinery a clause needs; tail-resumptive operations compile to near-direct calls.

---

## Core abstractions and types

### Row-polymorphic effect types

Every function type carries an effect row of kind `::E`; an atomic effect has kind `::X`. A row is a multiset of effect labels, either closed or open (ending in an effect variable `e`):

```koka
// Closed effect: only console
fun greet() : console ()
  println("hello")

// Open effect: console plus whatever else `e` is
fun greet-and(action : () -> <console|e> ()) : <console|e> ()
  println("hello")
  action()
```

Inference is row-based Hindley–Milner, so effect annotations are rarely written. `map` below has effect exactly `e` — the effect of the supplied function, no more:

```koka
fun map(xs : list<a>, f : (a) -> e b) : e list<b>
  match xs
    Nil        -> Nil
    Cons(x,xx) -> Cons(f(x), map(xx, f))
```

Built-in effect constants include `total` (pure & terminating), `exn`, `div`, `pure` (= `exn`+`div`), `console`, `ndet`, and `io`.

### Evidence: the runtime representation of "an effect is in scope"

The whole compilation strategy is documented from the inside in `koka/lib/std/core/hnd.kk` — the module that the compiler implicitly imports and that is itself compiled _without_ the monadic translation, so its primitives are hand-written. Its header comment cites the two driving papers directly:

> The paper: Ningning Xie, and Daan Leijen. _Generalized Evidence Passing for Effect Handlers_ … ICFP'21 … describes precisely how the monadic evidence translation works on which this module is based. … Another paper of interest is: _Effect Handlers in Haskell, Evidently_ (Haskell'20) which explains the internal typing of handlers, evidence vectors, etc. in a simpler setting.
> — `koka/lib/std/core/hnd.kk`

The runtime types defined there are the heart of the system:

- A **marker** `:marker<e,r>` is a unique integer identifying an _answer context_ (a handler's result/effect pair). It behaves as a dependent tag: when the marker matches at runtime, the answer type matches.
- A **handler** `:h<e,r>` is a record of all operation clauses (a virtual method table generated per effect type).
- **Evidence** `:ev<h>` is a quadruple `Ev(htag, marker, handler, hevv)`: the handler's runtime tag (for dynamic lookup), the marker, the handler record, and `hevv` — the _evidence vector at the point where the handler was defined_, so operations execute "under" the right context.

```koka
// from koka/lib/std/core/hnd.kk
value type marker<e::E,a>            // a unique integer per answer context
abstract value type htag<h::(E,V)->V>
  Htag(tagname:string)              // e.g. "exn/core/std"
// ev<h> is Ev(tag, marker, handler, hevv) — defined in std/core/types
```

An **evidence vector** `:evv<e>` is the ordered list of in-scope evidence, indexed statically by the compiler wherever possible. In the C runtime it is represented compactly (`koka/lib/std/core/inline/hnd.h`):

```c
// koka/lib/std/core/inline/hnd.h
typedef kk_datatype_ptr_t kk_evv_t;   // either a kk_evv_vector_t, or a single evidence
```

So a singleton evidence vector is just the evidence pointer itself (no allocation), and only size-0 or size-N≥2 vectors box into a `kk_evv_vector_t`. The current vector lives in a _register-favored_ field of the thread context.

---

## How effects are declared

An effect declares its operations; each operation's _kind_ fixes how much control it captures:

```koka
effect reader<a>
  fun ask() : a                 // tail-resumptive: resumes once, immediately

effect yield<a>
  ctl yield(value : a) : bool   // captures the continuation `resume`

effect raise
  final ctl raise(msg : string) : a  // never resumes (exception-like)
```

The control-flow lattice is spelled out in `hnd.kk` and mirrored exactly in the C effect libraries below:

| Operation kind | Resumes?                | Continuation captured? | Cost                       |
| -------------- | ----------------------- | ---------------------- | -------------------------- |
| `val`          | implicitly (a value)    | no                     | cheapest                   |
| `fun`          | implicitly (tail)       | no                     | runs in-place, no yield    |
| `ctl`          | explicitly via `resume` | yes (0/1/many times)   | general; full bubbling     |
| `final ctl`    | never                   | no                     | exception-like, no capture |

The handler _author_ picks the kind; the _call site_ is unchanged. The comment in `hnd.kk` shows both extremes for a one-argument clause: the general `Clause1(fn(m,ev,x) yield-to(m, fn(k) op(k,x)))` versus the tail-resumptive `Clause1(fn(m,ev,x) under1(ev,op,x))`, where `under1` re-installs the handler's own evidence vector (`hevv`) so the operation body runs under the correct context.

---

## How handlers/interpreters work

### `@hhandle`: installing a handler

The compiler lowers a `with handler … action()` into a call to `@hhandle` (`koka/lib/std/core/hnd.kk`). It allocates a fresh marker, builds the evidence, inserts it into the current vector, sets the vector, and then runs the action under a `prompt`:

```koka
// koka/lib/std/core/hnd.kk
pub noinline fun @hhandle( tag:htag<h>, h : h<e,r>, ret: a -> e r, action : () -> e1 a ) : e r
  val w0 = evv-get()
  val m  = fresh-marker()
  val ev = Ev(tag,m,h,w0)
  val w1 = evv-insert(w0,ev)
  evv-set(w1)
  prompt(w0,w1,ev,m,ret,cast-ev0(action)())
```

`@named-handle` is the variant for **named handlers**: it uses a unique _negative_ marker that is _not_ inserted into the evidence vector, and passes the `ev` value explicitly to the action. This is how multiple instances of one effect coexist (a `named effect ref<a>`), distinguished by lexical identity rather than by position in the evidence vector.

### `perform`: invoking an operation

Performing an operation is a rank-2 dispatch through the evidence — no stack search:

```koka
// koka/lib/std/core/hnd.kk
pub inline fun @perform1<a,b,h>( ev : ev<h>, op : (forall<e1,r> h<e1,r> -> clause1<a,b,h,e1,r>), x : a ) : e b
  match ev
    Ev(_tag,m,h,_w) -> match h.op
      Clause1(f) -> cast-clause1(f)(m,ev,x)
```

The compiler computes the evidence index statically (`@evv-index`/`@evv-at`) wherever the effect type pins it down, so `perform` is typically: load evidence at a known index, select the clause field, call it. The C `kk_evv_at` (in `hnd.h`) is a couple of pointer loads with the singleton fast path inlined.

### `prompt` + `yield-to`: general control

For a `ctl` clause, the clause body calls `yield-to(m, …)`, which records the target marker and clause in the thread-local yield slot and starts the program _bubbling_ back toward the matching `prompt`. The `prompt` function is the delimiter that catches the bubble (`koka/lib/std/core/hnd.kk`):

```koka
// koka/lib/std/core/hnd.kk (abridged)
fun prompt( w0, w1, ev, m, ret, result )
  guard(w1); evv-set(w0)
  match yield-prompt(m)
    Pure          -> ret(result)                 // normal return
    YieldingFinal -> keep-yielding-final()       // exception: keep bubbling
    Yielding      -> yield-cont(fn(cont,res) …)   // someone else's yield: re-extend
    Yield(clause,cont) ->                         // our marker matched
      fun resume(r)
        match r
          Deep(x)     -> … prompt(…, cont({x}))   // resume: re-enter under fresh prompt
          Shallow(x)  -> yield-bind( cont({x}), ret )
          Finalize(x) -> … prompt(…, cont({ yield-to-final(m, fn(_k) x) }))
      clause(resume)
```

`resume(Deep)` resumes the captured continuation under a _fresh_ prompt with the same marker (multi-shot capable); `resume-shallow` resumes once without re-installing the prompt; `finalize` runs the continuation only to drive finalizers and then re-raises a final yield. The public `resume`/`resume-shallow`/`finalize` are thin wrappers over a `resume-context` holding `k : resume-result<b,r> -> e r`.

### Exception-like and named handlers (Koka surface)

```koka
fun with-catch(action : () -> <raise|e> a) : e maybe<a>
  with handler
    return(x)            Just(x)
    final ctl raise(msg) Nothing      // never resumes -> no continuation capture
  action()

named effect ref<a>
  fun get() : a
  fun set(value : a) : ()             // multiple instances coexist via @named-handle
```

---

## Performance approach

### The selective monadic / CPS transform (`Core/Monadic.hs`)

The compiler does **not** CPS-convert everything. `Core/Monadic.hs` (`monTransform`) walks Core and only inserts monadic _binds_ around applications whose type is actually effectful (`isMonType`); everything else stays a direct call on the native C stack:

```haskell
-- koka/src/Core/Monadic.hs (App case, abridged)
if ((not (isMonType ftp || isAlwaysMon f)) || isNeverMon f)
  then return $ \k -> f' (\ff -> applies args' (\argss -> k (App ff argss)))      -- direct call
  else do nameY <- uniqueName "y"
          return $ \k -> f' (\ff -> applies args' (\argss ->
                            appBind resTp feff (typeOf contBody) ff argss cont))  -- monadic bind
```

The pass also specially lowers `effect-open` applications (effect subsumption coercions) and is paired with `Core/MonadicLift.hs`, which lifts local functions/continuations to the top level so the bind chains become first-class functions. The result is exactly the "monadic translation into plain lambda calculus" the ICFP'21 paper targets: ordinary code runs on the C stack; only a genuine yield reifies the stack into an explicit continuation.

### Yield bubbling in C (`kklib` + `inline/hnd.c`)

When an operation yields, the thread context (`kk_context_t` in `koka/kklib/include/kklib.h`) does the bookkeeping. Its first, register-favored fields are precisely the ones touched on the hot path:

```c
// koka/kklib/include/kklib.h
typedef struct kk_context_s {
  int8_t            yielding;   // 0:no, 1:KK_YIELD_NORMAL, 2:KK_YIELD_FINAL
  const kk_heap_t   heap;
  ...
  kk_datatype_ptr_t evv;        // current evidence vector (single ev or vector)
  kk_yield_t        yield;      // inlined yield record (for efficiency)
  ...
} kk_context_t;
```

The yield record stores the target marker, the operation clause, and an in-place array of continuation fragments:

```c
// koka/kklib/include/kklib.h
#define KK_YIELD_CONT_MAX (8)
typedef struct kk_yield_s {
  int32_t       marker;                    // handler to yield to
  kk_function_t clause;                    // op clause to run when found
  kk_intf_t     conts_count;
  kk_function_t conts[KK_YIELD_CONT_MAX];  // f1..fN; composed as fN ∘ … ∘ f1
} kk_yield_t;
```

As the yield bubbles outward, each suspended frame appends its continuation via `kk_yield_extend`; the fragments accumulate in the fixed `conts[8]` array and only spill to a heap-allocated **Kleisli composition** (`kcompose`) when the array fills (`koka/lib/std/core/inline/hnd.c`):

```c
// koka/lib/std/core/inline/hnd.c
kk_box_t kk_yield_extend( kk_function_t next, kk_context_t* ctx ) {
  kk_yield_t* yield = &ctx->yield;
  if (kk_unlikely(kk_yielding_final(ctx))) { kk_function_drop(next,ctx); }  // exception: drop
  else {
    if (kk_unlikely(yield->conts_count >= KK_YIELD_CONT_MAX)) {            // array full
      kk_function_t comp = new_kcompose( yield->conts, yield->conts_count, ctx );
      yield->conts[0] = comp; yield->conts_count = 1;
    }
    yield->conts[yield->conts_count++] = next;
  }
  return kk_box_any(ctx);
}
```

`kk_yield_to` sets `yielding = KK_YIELD_NORMAL`, records `marker`/`clause`, and resets `conts_count`; `kk_yield_final` does the same but flips to `KK_YIELD_FINAL` so extensions are dropped (an exception cannot be resumed). `kk_yield_prompt` is the C side of the Koka `prompt`: when the bubbling reaches the matching marker, it composes the accumulated continuations into the resumption `k` and hands it to the clause. A final-yield resume traps via `kk_fatal_resume_final`.

The net effect: the _fast path_ (no yield) pays only a predicted-not-taken `kk_yielding(ctx)` branch plus the evidence dispatch; continuation capture cost is incurred _only_ on the rare frames between the operation and its handler, and is bounded by an 8-slot in-place buffer before any allocation.

### Perceus + FBIP

Koka uses **Perceus** reference counting with reuse analysis (`Backend/C/Parc.hs`, `ParcReuse.hs`, `ParcReuseSpec.hs` in the compiler). Properties: garbage-free for cycle-free programs (objects freed at last use, often while still in cache), in-place _reuse_ when a uniquely-referenced value is matched and a same-size value rebuilt, and no GC/runtime. This enables **FBIP** (Functional But In-Place); the `fip`/`fbip` keywords let the compiler _verify_ that a function allocates nothing (`fip`) or reuses in-place where possible (`fbip`). For the theory linking this compilation pipeline to the papers, see [Theory & Compilation].

### Compilation targets

| Target     | Flag            | Backend         | Notes                                          |
| ---------- | --------------- | --------------- | ---------------------------------------------- |
| C          | `--target=c`    | GCC/Clang       | Primary; `kklib` runtime; Perceus RC; fastest  |
| JavaScript | `--target=js`   | Node.js/Browser | `inline/hnd.js` mirrors the C evidence runtime |
| WASM       | `--target=wasm` | Emscripten      | via the C backend                              |

---

## The C-level handler libraries: `libhandler` and `libmprompt`

Koka's C runtime descends from two standalone C libraries that implement algebraic effects _without_ a Koka compiler, and which clarify the two implementation strategies (monadic vs. stack-copying).

### `libhandler` — effect handlers in C99 over `setjmp`/asm (the older approach, used by nodec)

`libhandler` (`koka/libhandler/inc/libhandler.h`) provides handlers in portable C99, capturing/restoring the C stack via `setjmp`/`longjmp` plus a small amount of hand-written assembly (`koka/libhandler/src/asm/`) to copy stack fragments. Its API matches the Koka operation-kind lattice exactly:

```c
// koka/libhandler/inc/libhandler.h
typedef enum _lh_opkind {
  LH_OP_NULL, LH_OP_FORWARD,
  LH_OP_NORESUMEX,  // never resume; don't even run destructors
  LH_OP_NORESUME,   // never resume
  LH_OP_TAIL_NOOP,  // resume at most once, in tail position, performs no operations
  LH_OP_TAIL,       // resume at most once, in tail position
  LH_OP_SCOPED,     // resume only within the operation's scope
  LH_OP_GENERAL     // resume 0/1/many times, possibly outside scope  (always safe)
} lh_opkind;

lh_value lh_handle(const lh_handlerdef* def, lh_value local, lh_actionfun* body, lh_value arg);
lh_value lh_yield(lh_optag optag, lh_value arg);
lh_value lh_call_resume(lh_resume r, lh_value local, lh_value res);   // general resume
lh_value lh_tail_resume(lh_resume r, lh_value local, lh_value res);   // efficient tail resume
void     lh_release(lh_resume r);                                     // drop a resumption
```

Effects are declared with `LH_DEFINE_EFFECTn`/`LH_DEFINE_OPn` macros that build a `const char*[]` effect descriptor and per-operation `lh_optag`s.

### `libmprompt` — multi-prompt delimited control over in-place growable stacks (the newer approach)

`libmprompt` (`koka/libmprompt/include/mprompt.h`) is a cleaner foundation: a multi-prompt delimited-control API where each prompt runs on its own _in-place growable_ light-weight stack (`gstack`). The core API is tiny:

```c
// koka/libmprompt/include/mprompt.h
typedef struct mp_prompt_s mp_prompt_t;   // resumable prompt (an in-place growable stack chain)
typedef struct mp_resume_s mp_resume_t;   // abstract resumption

void* mp_prompt(mp_start_fun_t* fun, void* arg);              // run fun under a fresh prompt
void* mp_yield (mp_prompt_t* p, mp_yield_fun_t* fun, void* arg); // yield up to prompt p
void* mp_resume(mp_resume_t* resume, void* arg);             // resume (at most once)
void* mp_resume_tail(mp_resume_t* resume, void* arg);        // resume in tail position
void  mp_resume_drop(mp_resume_t* resume);                   // discard without resuming

// Multi-shot: use with care around linear resources
mp_resume_t* mp_resume_multi(mp_resume_t* r);  // turn a resumption into a multi-shot one
mp_resume_t* mp_resume_dup(mp_resume_t* r);    // dup a multi-shot resumption
```

The implementation uses virtual memory so a gstack can grow (up to ~8 MiB by default, `stack_max_size`) while starting with only one committed OS page (4 KiB, `stack_initial_commit`). The `koka/libmprompt/README.md` describes the key property — **address stability**:

> The implementation is based on _in-place_ growable light-weight gstacks … which use virtual memory to enable growing the gstack (up to 8MiB) but start out using just 4KiB of committed memory. … this library has _address stability_: using the in-place growable gstacks (through virtual memory), these stacks are never moved, which ensures addresses to the stack are always valid (in their lexical scope).
> — `koka/libmprompt/README.md`

Because gstacks form a _chain_ and never move, capturing a resumption captures all gstacks up to a prompt, and resuming restores that chain — without copying or relocating stack data. On systems lacking overcommit, `libmprompt` uses internal **gpools** plus a `SIGSEGV` handler to commit stack pages on demand. The `mpeff.h` layer on top exposes a higher-level effect-handler API (`mpe_handle`/`mpe_perform`/`mpe_resume`) with the same operation-kind lattice (`MPE_OP_TAIL`, `MPE_OP_ONCE`, `MPE_OP_MULTI`, `MPE_OP_ABORT`, …). Both `libmprompt` and `nodec` are authored by Daan Leijen (Microsoft Research), as the file headers state.

---

## Async I/O: nodec turns libuv callbacks into direct-style effects

[nodec] is a "lean and mean" Node.js-in-C built on libuv and `libhandler`. Its premise (from `nodec/readme.md`): async/await-style programming in C is painful with raw callbacks, so nodec uses algebraic effect handlers to make asynchronous code read like straight-line synchronous code. This is the most concrete async-I/O instance of the effect machinery — compare with the event-loop discussion in [Effects and Event Loops] and the libuv internals in [libuv].

### The `async` effect and its handler

`nodec/src/async.c` declares an `async` effect with five operations, the central one being `req_await`:

```c
// koka/nodec/src/async.c
LH_DEFINE_EFFECT5(async, req_await, uv_loop, req_register, uv_cancel, owner_release)
LH_DEFINE_OP1(async, req_await, int, async_request_ptr)
// ...
static const lh_operation _async_ops[] = {
  { LH_OP_GENERAL,   LH_OPTAG(async,req_await),      &_async_req_await },     // general: stash resume
  { LH_OP_TAIL_NOOP, LH_OPTAG(async,uv_loop),        &_async_uv_loop },
  { LH_OP_TAIL_NOOP, LH_OPTAG(async,req_register),   &_async_req_register },
  { LH_OP_TAIL_NOOP, LH_OPTAG(async,uv_cancel),      &_async_uv_cancel },
  { LH_OP_TAIL_NOOP, LH_OPTAG(async,owner_release),  &_async_owner_release },
  { LH_OP_NULL, lh_op_null, NULL }
};
static const lh_handlerdef _async_def = { LH_EFFECT(async), NULL, _async_release, NULL, _async_ops };
```

The whole program runs _inside_ this handler, which itself runs _inside_ libuv's `uv_run` loop. `async_main` initializes the loop, schedules a startup timer, installs the `async` handler around the user's entry point, then enters `uv_run`:

```c
// koka/nodec/src/async.c
static void uv_main_cb(uv_timer_t* t_start) {
  async_handler(t_start->loop, &uv_main_try_action, lh_value_fun_ptr(...));   // install async handler
}
uv_errno_t async_main( nodec_main_fun_t* entry ) {
  ...
  uv_timer_start(t_start, &uv_main_cb, 0, 0);
  err = uv_run(loop, UV_RUN_DEFAULT);   // the event loop drives everything
  ...
}
```

### Yield on await, resume from the libuv callback

The `req_await` operation is `LH_OP_GENERAL` because the resumption is captured now and invoked _later_ from a libuv callback. The operation function simply _stores the resumption_ in the request structure and returns `lh_value_null`, which unwinds back out of the handler to `uv_run`:

```c
// koka/nodec/src/async.c
static lh_value _async_req_await(lh_resume resume, lh_value local, lh_value arg) {
  async_request_t* req = lh_async_request_ptr_value(arg);
  req->local  = local;
  req->resume = resume;                                   // remember where to come back to
  if (req->resumefun==NULL) req->resumefun = &async_resume_default;
  return lh_value_null;  // this exits our async handler back to the main event loop
}
```

Each libuv request stores a pointer to this `async_request_t` in its `uv_req_t.data`. When libuv completes the operation and fires the callback, the callback funnels into `async_req_resume`, which dispatches to `async_request_resume`, which finally calls `lh_release_resume` to resume back to the exact `async_await` point with the result code:

```c
// koka/nodec/src/async.c
static void async_resume_default(lh_resume resume, lh_value local, uv_req_t* req, int err) {
  if (resume != NULL) lh_release_resume(resume, local, lh_value_int(err));  // resume the awaiter
}
void async_req_resume(uv_req_t* uvreq, int err) {            // libuv callback entry point
  async_request_t* req = (async_request_t*)uvreq->data;
  if (req != NULL && req != UVREQ_FREE_ON_RESUME && req != UVREQ_FREE_ON_OWNER_RELEASE)
    async_request_resume(req, uvreq, err);
}
```

### The direct-style payoff (`dns.c`)

The result is that a domain library reads as if I/O were blocking. `nodec/src/dns.c` issues a libuv request with a callback that _just resumes_, then `await`s:

```c
// koka/nodec/src/dns.c
static void addrinfo_cb(uv_getaddrinfo_t* req, int status, struct addrinfo* res) {
  async_req_resume((uv_req_t*)req, status >= 0 ? 0 : status);   // callback only resumes
}
struct addrinfo* async_getaddrinfo(const char* node, const char* service, const struct addrinfo* hints) {
  struct addrinfo* info = NULL;
  {using_req(uv_getaddrinfo_t,req) {
    nodec_check_msg(uv_getaddrinfo(async_loop(), req, &addrinfo_cb, node, service, hints), node);
    uv_errno_t err = asyncx_await_once((uv_req_t*)req);        // looks synchronous; actually yields
    if (err==0) info = req->addrinfo;
  }}
  return info;
}
```

`async_getaddrinfo` _appears_ to block on the DNS lookup, but `asyncx_await_once` performs the `req_await` operation, which yields all the way out to `uv_run`; when libuv resolves the name it calls `addrinfo_cb`, which resumes the captured continuation, and execution lands right after the `await`. The same shape recurs across `fs.c`, `tcp.c`, `stream.c`, `http.c`, etc. nodec also layers **structured concurrency** on this: `async_interleave` / `async_interleave_dynamic` run multiple strands by routing each strand's resumption through a `channel_t` (the `_channel_async_*` handler in `async.c`), and `async_scoped_cancel` cancels outstanding requests within a cancelation scope. For how this pattern compares to OCaml's effect-based Eio and to Loom, see [Eio backend] and [Effects and Event Loops]; for the `io_uring` alternative to libuv's readiness/completion model, see [io_uring].

---

## Composability model

- **Effect-row unification.** Calling a `<reader<int>|e>` function from a `<console|e'>` context unifies the rows to `<reader<int>,console|e''>`. Union semantics, fully inferred.
- **Lexical handler nesting.** Order matters: wrapping `with-state` inside `with-catch` rolls state back on exception; the reverse order keeps it. The nesting order is the evidence-insertion order in the vector.
- **Effect polymorphism for free.** A higher-order `for-each(xs, f) : e ()` has exactly the effects of `f`; no annotations.
- **`mask`/`open`.** `@mask-at` removes one evidence entry for the duration of an action (to skip an inner handler of the same effect); `effect-open` injects an effect coercion that the monadic pass lowers specially.
- **Named & scoped handlers.** Named handlers (`@named-handle`) give first-class handler instances; scoped/rank-2 typing keeps instances from escaping their scope.

---

## Strengths

- Full effect inference; deep semantic guarantees (no `exn` ⇒ no exceptions, no `div` ⇒ termination).
- One mechanism (handlers) subsumes exceptions, generators, async/await, nondeterminism, dynamic binding, and more — all as libraries.
- Evidence-passing monadic compilation runs on the native C stack; cost of continuation capture is incurred _only_ on a real yield and is bounded (8-slot in-place buffer before any allocation).
- Operation kinds (`val`/`fun`/`ctl`/`final ctl`) let handler authors trade generality for speed clause-by-clause.
- Perceus RC + FBIP: deterministic, garbage-free, no GC pauses; `fip`/`fbip` are compiler-verified.
- The async story (nodec) shows the model scales to real callback-based OS I/O without a VM.

## Weaknesses

- Research language: small ecosystem, limited libraries and tooling.
- Perceus is cycle-free only; cyclic data needs explicit weak references / manual breaking.
- Evidence-vector adjustment (insert/swap on handler entry/resume) adds overhead with deeply nested effect rows.
- nodec relies on the older `setjmp`/asm `libhandler` (stack copying), and is explicitly experimental; the cleaner `libmprompt` gstack approach is a separate library, not yet the nodec backend.
- General multi-shot resumptions interact subtly with linear resources (the `mp_resume_multi` API is "use with care").
- Debugging through generated C and demand-paged gstacks (spurious `SIGSEGV` under gdb) is awkward.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                                             | Trade-off                                                                               |
| ------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Row-polymorphic effects with full inference       | Union semantics; no manual effect plumbing; effects part of a function's meaning      | Row-unification errors can be unintuitive; type messages get large                      |
| Evidence passing (not dynamic stack search)       | Operation dispatch is a static-index load + clause call; no walking the handler stack | Evidence vectors must be threaded and adjusted on handler entry/resume                  |
| Selective monadic translation (`Core/Monadic.hs`) | Non-effectful code stays direct on the C stack; only effectful binds become monadic   | A real yield must reify the stack into a continuation; bind chains add a layer          |
| In-place yield buffer + Kleisli `kcompose` spill  | Fast path is one branch; capture bounded to 8 slots before heap allocation            | Deep handler/op nesting eventually allocates the composition function                   |
| Operation kinds `fun`/`ctl`/`final ctl`           | Tail-resumptive ops avoid continuation capture; exceptions avoid it entirely          | Authors must understand the lattice; wrong kind is either slow or unsound               |
| Perceus RC + reuse (no GC)                        | Deterministic, garbage-free, in-cache frees; enables FBIP                             | No cycles; RC traffic on hot paths; reuse analysis is best-effort                       |
| `libmprompt` in-place growable gstacks            | Address stability; cheap multi-shot via stack chains; ~4 KiB per active prompt        | 64-bit only (needs large virtual address space); overcommit-less systems need `SIGSEGV` |
| nodec over `libhandler` + libuv                   | Direct-style async I/O in C; callbacks become resumptions                             | Stack-copying `setjmp`/asm runtime; experimental; not the `libmprompt` backend          |

---

## Sources

Primary (cloned repositories, read directly):

- [koka] — `koka/src/Core/Monadic.hs`, `Core/MonadicLift.hs` (selective monadic/CPS transform); `koka/lib/std/core/hnd.kk` (evidence/handler runtime in Koka); `koka/lib/std/core/inline/hnd.c`, `inline/hnd.h` (C primitives: `kk_yield_extend`, `kcompose`, `kk_evv_at`); `koka/kklib/include/kklib.h` (`kk_context_t`, `kk_yield_t`, evidence vector).
- [libmprompt] — `include/mprompt.h`, `include/mpeff.h`, `README.md`, `src/readme.md` (multi-prompt API; in-place growable gstacks; gpools; multi-shot).
- [libhandler] — `inc/libhandler.h`, `src/libhandler.c`, `src/asm/` (C99 effect handlers over `setjmp`/asm; operation-kind lattice).
- [nodec] — `inc/nodec.h`, `src/async.c`, `src/dns.c`, `readme.md` (libuv callbacks wrapped as direct-style effect operations).

Papers & docs (web-verified):

- [Effect Handlers, Evidently (ICFP 2020)]
- [Generalized Evidence Passing for Effect Handlers (ICFP 2021)]
- [First-class Named Effect Handlers (OOPSLA 2022)] — the theory behind `@named-handle`
- [Koka: Programming with Row Polymorphic Effect Types (MSFP 2014)]
- [Perceus: Garbage Free Reference Counting with Reuse (PLDI 2021)]
- [FP2: Fully in-Place Functional Programming (ICFP 2023)] — the theory behind `fip`/`fbip`
- [The Koka Programming Language (Book)]
- [Koka at Microsoft Research]

Related corpus docs: [Theory & Compilation] · [Eff] · [Comparison] · [Index] · [Papers] · [Parallelism] · [Evolution] · [Effects and Event Loops] · [Eio backend] · [io_uring] · [libuv].

<!-- References -->

[koka]: https://github.com/koka-lang/koka
[libmprompt]: https://github.com/koka-lang/libmprompt
[libhandler]: https://github.com/koka-lang/libhandler
[nodec]: https://github.com/koka-lang/nodec
[The Koka Programming Language (Book)]: https://koka-lang.github.io/koka/doc/book.html
[Koka at Microsoft Research]: https://www.microsoft.com/en-us/research/project/koka/
[Koka: Programming with Row Polymorphic Effect Types (MSFP 2014)]: https://arxiv.org/abs/1406.2061
[Effect Handlers, Evidently (ICFP 2020)]: https://doi.org/10.1145/3408981
[Generalized Evidence Passing for Effect Handlers (ICFP 2021)]: https://dl.acm.org/doi/10.1145/3473576
[Perceus: Garbage Free Reference Counting with Reuse (PLDI 2021)]: https://dl.acm.org/doi/10.1145/3453483.3454032
[First-class Named Effect Handlers (OOPSLA 2022)]: https://dl.acm.org/doi/10.1145/3563289
[FP2: Fully in-Place Functional Programming (ICFP 2023)]: https://dl.acm.org/doi/10.1145/3607840
[Theory & Compilation]: ./theory-compilation.md
[Eff]: ./eff-lang.md
[Comparison]: ./comparison.md
[Index]: ./index.md
[Papers]: ./papers.md
[Parallelism]: ./parallelism.md
[Evolution]: ./evolution.md
[Effects and Event Loops]: ../async-io/effects-and-event-loops.md
[Eio backend]: ../async-io/eio-backend.md
[io_uring]: ../async-io/io-uring/index.md
[libuv]: ../async-io/libuv.md

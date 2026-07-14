# Unison

A statically-typed functional language with content-addressed code and an algebraic-effect system called **abilities**, run by a Haskell-implemented **ANF bytecode abstract machine** that handles abilities by capturing delimited continuations on its own continuation stack and bridges all `IO`/concurrency to the **GHC runtime system** (`forkIO`/`MVar`/`threadDelay`/STM) — there is no event loop and no `io_uring` inside Unison.

| Field         | Value                                                                                                                                     |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Unison (runtime + compiler written in Haskell)                                                                                            |
| License       | MIT (Unison Computing, public benefit corp, 2013–2024)                                                                                    |
| Repository    | [Unison GitHub repository] (`unison-runtime/` holds the abstract machine)                                                                 |
| Documentation | [Unison language documentation] / [runtime design notes]                                                                                  |
| Releases      | 1.0 (Nov 2025) through 1.3.0 (May 2026); analysis tracks `trunk` (commit `0452fca`, May 2026)                                             |
| Key Authors   | Paul Chiusano, Rúnar Bjarnason, Arya Irani, Dan Doel (runtime), Chris Penner (runtime), Mitchell Rosen                                    |
| Encoding      | Abilities (algebraic effects) as `Request` values; delimited continuations captured on the machine's `K` stack; IO bridged to the GHC RTS |

---

## Overview

### What it solves

Unison addresses three interlocking problems with one design.

1. **Effects in types without monads.** _Abilities_ track computational effects in
   function types and let you call effectful operations in direct style — no
   do-notation, no transformer stacks. The runtime, not the type system alone, makes
   this work: it manipulates continuations so a handler can resume, drop, or re-run the
   rest of a computation.
2. **Builds, dependency hell, serialization.** Every definition is identified by a hash
   of its (ANF-normalized) syntax tree. Names are metadata over hashes, so renaming
   never breaks anything, recompilation is perfectly incremental, and there is no link
   step.
3. **Distribution.** Because code is content-addressed and the runtime can hash,
   serialize, deserialize, and decompile _any_ value (including functions and captured
   continuations), code can be shipped to remote nodes by hash. The runtime design notes
   ([`unison-runtime/src/Unison/Runtime/docs.markdown`][runtime design notes]) make this
   an explicit design constraint: "_it needs to be possible to have functions like
   `encode : forall a . a -> Bytes`_", and "_The runtime should support algebraic
   effects, which requires being able to manipulate continuations of a running
   program._"

### Design philosophy

Unison's abilities are based on [Frank] (Lindley, McBride, McLaughlin, _Do Be Do Be Do_,
POPL 2017). Like Frank, abilities propagate through the typing context rather than being
threaded explicitly; unlike Frank, ability polymorphism is carried by ordinary
polymorphic type variables and handling uses an explicit `handle … with` form rather
than overloaded application.

The runtime philosophy is stated bluntly in the design notes: "_This first version of the
Haskell runtime isn't aiming for extreme speed. It should be correct, simple, and easy
for us to understand and maintain._" The architecture is deliberately **modular** — term
→ let-rec-minimization → lambda-lifting → **A-normal form (ANF)** → **MCode** (a flat
bytecode) → evaluation — so that the front end can later target a faster backend without
rewriting everything. That faster backend is now in progress: a **JIT compiling to Chez
Scheme** (see _Performance approach_), chosen precisely because LLVM "_doesn't provide
any runtime services out of the box, such as a garbage collector, continuations and/or
delimited continuations, lightweight threads, async I/O._"

The crucial point for an effects/async survey: Unison does **not** own an event loop the
way [Go's netpoller](../async-io/go-netpoller.md) or [Eio](../async-io/eio-backend.md)
do. Unison's abstract machine owns only the **continuation stack and the ability
dispatch**; everything that actually blocks on the kernel is a _foreign call_ into the
GHC RTS, which owns the I/O manager and the M:N green-thread scheduler. Contrast this
with [OCaml 5 + Eio](../async-io/effects-and-event-loops.md), where the _language_
runtime suspends an effect and a _user-space_ scheduler drives `io_uring`.

---

## Core abstractions and types

### Ability requirements in types

Abilities appear to the right of arrows in `{}`:

```unison
increment : Nat -> Nat              -- pure, no abilities
increment n = n + 1

readFile : Text ->{IO} Text         -- requires IO
riskyRead : Text ->{IO, Exception} Text
pureAdd : Nat -> Nat ->{} Nat       -- explicitly pure (empty ability set)
```

Omitting the braces makes a function ability-polymorphic; the inferred type carries an
ability variable (commonly written `g`).

### The `Request` value (and how it is _represented_ at runtime)

A handler conceptually receives values of the built-in `Request a r` type: if `e :
{A} T` and `h : Request A T -> R`, then `handle e with h : R`. The runtime design notes
describe the conceptual shape directly:

```text
-- from unison-runtime/src/Unison/Runtime/docs.markdown
Request Reference CtorId [v]  IR
--      ability   ctor   args continuation
```

In the _current_ machine there is no boxed `Request` constructor sitting around at all
times. Instead, when an ability operation reaches a handler, the machine wraps the
captured payload in a one-field data closure tagged with the special `effectRef`:

```haskell
-- unison-runtime/src/Unison/Runtime/Machine.hs  (yield/leap)
leap (Mark a ps cs k) | HEnv aenv0 denv0 <- henv0 = do
  ...
  v   <- peek stk
  stk <- bump stk
  bpoke stk $ Data1 Rf.effectRef (PackedTag 0) v   -- this *is* the Request value
  ...
  apply yld env henv activeThreads stk k False (VArg1 0) h  -- invoke handler h
```

A handler is compiled into a `MatchRequest` over this value; the machine's `RMatch`
instruction inspects the tag, taking the _pure_ branch when the tag is `pureEffectTag`
(`PackedTag 0`, defined in `Unison/Runtime/TypeTags.hs`) and otherwise unpacking the
`(ability, constructor)` tag pair to select the right request branch:

```haskell
-- unison-runtime/src/Unison/Runtime/Machine.hs  (eval' for RMatch)
(t, stk) <- dumpDataValNoTag stk =<< peekOff stk i
if t == TT.pureEffectTag
  then eval ... pu                       -- pure return case  { a }
  else case ANF.unpackTags t of
    (ANF.rawTag -> e, ANF.rawTag -> t)
      | Just ebs <- EC.lookup e br -> eval ... (selectBranch t ebs)
      | otherwise -> unhandledAbilityRequest
```

### Structural vs unique abilities

```unison
structural ability Store a where        -- identified by structure
  Store.get : {Store a} a
  Store.put : a ->{Store a} ()

unique ability MyLogger where           -- identified by a fresh GUID
  MyLogger.log : Text ->{MyLogger} ()
```

Structural abilities are equal when their constructors line up; unique abilities are
distinct even if structurally identical. Each constructor is compiled by ANF to a request
former (`anfFunc (Request' (ConstructorReference r t)) = … FReq r t`, in
`Unison/Runtime/ANF.hs`).

---

## How effects are declared

### Ability declarations

```unison
structural ability Abort where
  Abort.abort : {Abort} a

structural ability Stream e where
  Stream.emit : e ->{Stream e} ()

structural ability Ask a where
  Ask.ask : {Ask a} a
```

### Using abilities

```unison
counter : Nat ->{Store Nat} Nat
counter times =
  current = Store.get
  Store.put (current + times)
  Store.get
```

Calling `Store.get` is, at the bytecode level, a _reference into the dynamic environment_:
`resolve` looks the ability up by its numeric tag in the handler environment and either
finds an installed handler value (`denv`) or an affine-handler reference (`aenv`):

```haskell
-- unison-runtime/src/Unison/Runtime/Machine.hs
resolve env (HEnv aenv denv) _ (Dyn i)
  | Just v       <- EC.lookup i denv = pure v
  | Just (ARef r)<- EC.lookup i aenv = BoxedVal <$> readIORef r
  | otherwise    = unhandledErr "resolve" env i      -- "unhandled ability request"
```

### Ability polymorphism

`List.map : (a ->{g} b) -> [a] ->{g} [b]` is ability-polymorphic via the type variable
`g`: the inferred row inherits whatever abilities the mapped function needs.

---

## How handlers / interpreters work

### Surface syntax: `handle … with`

```unison
Abort.toOptional : '{g, Abort} a ->{g} Optional a
Abort.toOptional f =
  handle !f with cases
    { a }                -> Some a              -- pure case
    { Abort.abort -> _ } -> None                -- request case; continuation discarded

Store.run : s -> '{g, Store s} a ->{g} a
Store.run initial f =
  go state = cases
    { a }                     -> a
    { Store.get   -> resume } -> handle resume state with go state
    { Store.put s -> resume } -> handle resume () with go s
  handle !f with go initial
```

`resume` is the **delimited continuation** — the rest of the computation up to this
handler. The handler may call it (resume), ignore it (abort), or call it more than once
(non-determinism / generators).

### The continuation stack and marks (the real mechanism)

A `handle … with` compiles, through ANF's `AHnd`/`AShift` nodes
(`Unison/Runtime/ANF.hs`), into two MCode instructions
(`Unison/Runtime/MCode.hs`):

- **`Reset !(EnumSet Word64) !Int !(Maybe Int)`** — installs a handler for a set of
  ability tags by pushing a **prompt marker** onto the continuation stack.
- **`Capture !Word64`** — captures the continuation up to a given prompt tag, producing a
  reusable continuation value.

The continuation stack is the `K` type in `Unison/Runtime/Stack.hs`. Its relevant
constructors are exactly the markers and frames the machine walks during ability dispatch:

```haskell
-- unison-runtime/src/Unison/Runtime/Stack.hs
data K
  = KE                                   -- empty continuation (bottom)
  | CB Callback                          -- foreign/callback hook
  | AMark !Int AEnv !AffineRef !K        -- affine prompt marker (see optimization below)
  | Mark  !Int !(EnumSet Word64) DEnv !K -- prompt marker for a set of ability tags
  | Push  !Int !Int !CombIx !Int !(RSection Val) !K   -- a frame to resume
  | Local HEnv !Int !K                   -- saved env during an affine handler
  | forall a. Keep !a !Int !K            -- GC anchor
```

**Installing a handler.** `exec … (Reset ps nhi mah)` (in `Machine.hs`) unions the new
handler into the dynamic environment `denv` and pushes a `Mark a ps clos k` frame that
records which ability tags `ps` this handler intercepts and the previously-shadowed
handlers `clos` (so they can be restored on the way out).

**Performing an operation → handing it to the handler.** When the active computation
_yields_ a value past a `Mark`, `yield`'s inner `leap` (shown above) fires: it builds the
`Data1 Rf.effectRef …` request value, looks up the handler `h` keyed by the prompt's
minimum ability tag, restores the shadowed environment, and `apply`s `h` to the request.

**Capturing the continuation.** `Capture p` calls `splitCont`, which **walks the `K`
stack** accumulating how many data-stack cells lie above the matching prompt `p`, then
grabs that slice into a `Captured` closure:

```haskell
-- unison-runtime/src/Unison/Runtime/Machine.hs  (splitCont)
walk !denv !sz !ck (Mark a ps cs k)
  | EC.member p ps = finish denv' sz a ck k          -- found our prompt: stop here
  | otherwise      = walk denv' (sz + a) (Mark a ps cs' ck) k
...
finish !denv !sz !a !ck !k = do
  (seg, stk) <- grabSeg stk sz
  stk <- adjustArgs stk a
  return (BoxedVal $ Captured ck asz seg, denv, stk, k)   -- a reusable continuation
```

The result is a `Captured` closure (`GCaptured !K !Int !Seg` in `Stack.hs`) holding the
code continuation, the pending-argument size, and the captured data-stack segment.

**Resuming.** Invoking a captured continuation routes through `jump`, which `repush`es the
captured `K` frames back onto the live stack, threading the dynamic environment through
each `Mark` it re-enters:

```haskell
-- unison-runtime/src/Unison/Runtime/Machine.hs  (repush)
go !denv (Mark a ps cs sk) !k = go denv' sk $ Mark a ps cs' k
  where denv' = cs <> EC.withoutKeys denv ps
        cs'   = EC.restrictKeys denv ps
```

Because the captured segment is a copied stack slice, `resume` can be invoked zero, one,
or many times — that is what makes Unison handlers full _multi-shot_ delimited
continuations (and what the JIT effort calls out as the hard part to reimplement).

### The affine-handler fast path (recent optimization)

A large fraction of real handlers are _affine_: they either never resume (exception-like)
or resume the continuation **in tail position with a handler for the same abilities**
(the typical deep recursive handler, like `Store.run` above). For these, capturing and
copying a continuation segment is pure overhead. The runtime now special-cases them
(`Stack.hs` comment): "_The advantage of affine handlers is that they do not need to be
implemented by continuation capture. Case 1 can be implemented by simply discarding the
continuation … it is sufficient to simply keep track of the current state of each
handler._"

This adds a parallel mechanism: an `AMark` prompt holds a mutable `AffineRef` (an
`IORef Closure`); the `GAffine` closure carries the handler's ability set and environment;
`Discard` aborts an affine continuation (`abortCont`) without copying; `InLocal`/`Local`
and `SetAff`/`AUpdate` let an affine handler update its own state in place. The
`Reset` instruction picks the affine path when "_denv is null, and there's an affine
handler_". This is the runtime's answer to the standard criticism that delimited-
continuation effect handlers are slow: keep handlers affine and you pay no capture cost.
(Affine handlers were merged in 2025; see `Stack.hs` `GAffine` and the
`affine-handler` transcripts in the repo.)

### Nesting handlers

```unison
result : Optional [Text]
result = Abort.toOptional '(Stream.toList '(Store.run 0 program))
```

Each `handle` peels one ability off the row; nesting order is semantically significant
(e.g. whether `Store` state survives an `Abort`). Internally each is one more `Mark`
frame on the `K` stack.

---

## Performance approach

- **ANF + flat bytecode.** Let-rec minimization arranges that "_`let` is the one place in
  the runtime where we need to expect an ability request_", which "_makes it very easy to
  construct the continuations which are passed to the ability handlers_" (design notes).
  ANF is then lowered to **MCode** (`MCode.hs`), a flat instruction set
  (`App`, `Call`, `Jump`, `Let`, `Match`, `Reset`, `Capture`, `ForeignCall`, …) executed
  by `eval'`/`exec` in `Machine.hs`. The boxed/unboxed data stack lives in `Stack.hs`
  with `BangPatterns`, `MagicHash`, and `UnboxedTuples` for speed.
- **Affine-handler avoidance of capture** (above) removes the per-operation continuation
  copy in the common case.
- **Content-addressed caching.** Definitions are keyed by hash, so the `cacheAdd` path in
  `Machine.hs` compiles each combinator once; recompilation only happens when an
  _implementation_ changes, never on rename or reformat — perfect incremental
  compilation.
- **JIT to Chez Scheme (in progress).** The successor backend compiles Unison to **Chez
  Scheme** rather than LLVM, for its tail calls, dynamic code loading, GC, and
  _delimited continuations_ — exactly the runtime services abilities need. Early
  arithmetic microbenchmarks reported ~470× over the interpreter; the open challenge is
  reimplementing ability handlers via Scheme's delimited continuations. See
  [JIT compilation is coming to Unison].
- **No event loop.** The machine never polls; blocking is delegated to the GHC RTS (next
  section). This is the opposite end of the spectrum from
  [the netpoller](../async-io/go-netpoller.md), where the _language runtime_ integrates an
  epoll/kqueue/IOCP loop with its scheduler.

---

## How `IO` and concurrency work — the GHC-RTS bridge

There is **no `io_uring`, no epoll loop, and no user-space scheduler in Unison's runtime.**
The built-in `IO` ability is handled by the machine evaluating it down to **foreign
calls** that delegate straight to GHC's `base`/`concurrent` libraries; GHC's threaded
RTS then provides green threads, the I/O manager, and the scheduler.

- **Spawning threads.** The `IO.forkComp.v2` builtin compiles to the `FORK` primop
  (`fork'comp` in `Builtin.hs`), whose `exec` case runs `forkEval`, which is literally
  `UnliftIO.forkFinally` over `forkIO`:

  ```haskell
  -- unison-runtime/src/Unison/Runtime/Machine.hs
  forkEval env activeThreads clo = do
    threadId <- UnliftIO.forkFinally (apply1 err env activeThreads clo) (const cleanupThread)
    trackThread threadId
    pure threadId
  ```

  Spawned `ThreadId`s are recorded in an `ActiveThreads` `IORef` so the host can reap them.

- **Sleeping.** `IO.delay` (`IO_delay_impl_v3`) is `threadDelay`, with a loop to handle
  delays larger than `maxBound :: Int`:

  ```haskell
  -- unison-runtime/src/Unison/Runtime/Foreign/Function.hs
  IO_delay_impl_v3 -> mkForeignIOF customDelay
  ...
  customDelay n
    | n < mx    = threadDelay (fromIntegral n)
    | otherwise = threadDelay maxBound >> customDelay (n - mx)
  ```

- **Killing threads.** `IO_kill_impl_v3 -> mkForeignIOF killThread`.

- **Synchronization.** `MVar.*` map one-to-one onto `Control.Concurrent.MVar`
  (`newMVar`, `takeMVar`, `putMVar`, `tryTakeMVar`, `readMVar`, …) over `MVar Val`.

- **Transactions.** `STM.atomically` compiles to the `ATOM` primop, whose `exec`
  case (`Atomically i`) runs the computation inside GHC STM via
  `atomically . unsafeIOToSTM …`; `TVar.*` and `STM.retry` wrap
  `Control.Concurrent.STM`.

- **Sockets / files / processes** are GHC foreign calls too (`IO_serverSocket_impl_v3`,
  `IO_socketAccept_impl_v3`, `runInteractiveProcess`, …). Blocking socket reads block a
  green thread; the GHC I/O manager (epoll/kqueue on the platform) unblocks it. None of
  this is visible to, or controlled by, the Unison machine.

The imports at the top of `Foreign/Function.hs` make the dependency explicit:
`import Control.Concurrent (ThreadId, forkIO)`, `import Control.Concurrent as SYS
(killThread, threadDelay)`, `import Control.Concurrent.MVar as SYS`,
`import Control.Concurrent.STM qualified as STM`.

So Unison's async story is: **abilities give the suspension/structuring vocabulary;
the GHC runtime is the event loop.** For a worked example of the _other_ arrangement —
language effect + user-space `io_uring` scheduler — see
[Effect systems & event loops](../async-io/effects-and-event-loops.md). For "runtime
owns the readiness loop with no user-facing event loop," see
[Go's netpoller](../async-io/go-netpoller.md); Unison is similar in that the _programmer_
never sees a loop, but different in that the loop lives in GHC, not in Unison's own
scheduler.

---

## Composability model

### Ability composition

```unison
complexProgram : Text ->{IO, Exception, Store Config, Stream LogEntry} Result
```

Abilities compose as a comma-separated row; each is handled independently. The type system
requires every ability to be handled before top-level execution, **except** `IO` and
`Exception`, for which the runtime supplies default handling — `resolveExceptionHandler`
in `Machine.hs` looks `Exception` up by `exceptionTag` in the handler environment, and an
unhandled non-`IO`/`Exception` request reaches `unhandledAbilityRequest`.

### Handler composition via nesting

```text
'{IO, Store Config, Stream LogEntry} Result
  -- after Store.run   -> '{IO, Stream LogEntry} Result
  -- after Stream.toList-> '{IO} [LogEntry]
  -- IO handled by the runtime (GHC RTS)
```

### Abilities and distributed computing

Because the runtime can serialize/deserialize/decompile any value (a stated design
constraint) and code is content-addressed, computations — including captured
continuations — can be shipped by hash. A `Remote` ability (in the Unison Cloud library —
described as "_the I/O of the Cloud_") makes distribution explicit in types while
keeping the call site looking local. The same `splitCont`/`Captured` machinery that
implements local handlers is what makes a continuation a transmissible value.

### Built-in abilities

| Ability     | Purpose                                    | Runtime backing                        |
| ----------- | ------------------------------------------ | -------------------------------------- |
| `IO`        | General input/output                       | GHC foreign calls (`forkIO`, sockets…) |
| `Exception` | Typed failures (`Failure`)                 | `resolveExceptionHandler` + GHC `try`  |
| `STM`       | Software transactional memory              | GHC `Control.Concurrent.STM`           |
| `Scope`     | Scoped mutable references / region cleanup | machine-managed scope + GHC `IORef`    |

---

## Strengths

- **Direct-style effects** with full multi-shot handlers, implemented by genuine
  delimited-continuation capture on the machine's `K` stack — no monad transformers.
- **Affine-handler fast path** removes continuation-copy overhead for the common
  recursive/exception-like handlers, a concrete answer to "effect handlers are slow."
- **Content-addressed code** → no builds, no dependency conflicts, perfect incremental
  compilation and caching, rename safety.
- **Serializable values & continuations** are a runtime design constraint, enabling
  transparent distribution by hash.
- **Effects visible in types**; pure functions are provably pure.
- **Handler swappability** makes testing trivial (real `IO` ↔ in-memory mock).

## Weaknesses

- **Interpreter overhead.** The current machine is explicitly "_not aiming for extreme
  speed_"; the Chez-Scheme JIT that closes this gap is still in progress and does not yet
  handle ability handlers.
- **Multi-shot continuations are expensive** when handlers are _not_ affine (full
  `splitCont` segment copy per operation).
- **Unfamiliar workflow** — code-as-database (UCM), not text files; clashes with git
  diff, grep, and standard editors/CI.
- **Small ecosystem**; base library hosting has migrated to Unison Share and the
  in-repo `base/` is now a deprecated historical snapshot.
- **IO is whatever GHC offers.** No `io_uring`, no pluggable scheduler; concurrency
  characteristics are inherited from the GHC RTS rather than tunable by the program.
- **Learning curve** for abilities, continuations, and recursive handler patterns.
- **Vendor coupling** for the richest distributed features (Unison Cloud).

## Key design decisions and trade-offs

| Decision                                                                            | Rationale                                                                                     | Trade-off                                                                       |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Handle abilities at `let` only, via ANF                                             | Makes continuation construction "_very easy_"; one place to deal with requests                | Requires a normalization pass and a flat bytecode (`MCode`) layer               |
| Delimited continuations on a machine-owned `K` stack (`Mark`/`Capture`/`splitCont`) | Full multi-shot handlers; continuations are first-class, serializable values                  | Per-operation segment copy is costly unless avoided                             |
| Affine-handler fast path (`AMark`/`GAffine`/`Discard`)                              | Most handlers never copy a continuation; in-place state update                                | Extra machine complexity; only applies while no non-affine handler is installed |
| Bridge `IO`/concurrency to the GHC RTS                                              | Reuse a mature scheduler, I/O manager, STM, green threads — runtime stays "_correct, simple_" | No control over the event loop; no `io_uring`; perf tied to GHC                 |
| Content-addressed code                                                              | Eliminates builds & dependency conflicts; perfect caching; enables distribution by hash       | Abandons text-file/VCS/grep workflow; needs UCM                                 |
| Abilities over monads (Frank-inspired)                                              | Direct-style effectful code; effects as a type row                                            | Younger ecosystem than Haskell's transformer libraries                          |
| Explicit `handle … with` (unlike [Frank])                                           | Clear separation of using vs handling effects                                                 | More verbose than Frank's implicit handling                                     |
| JIT targets Chez Scheme, not LLVM                                                   | Need GC + delimited continuations + tail calls + green threads "_out of the box_"             | Another runtime to maintain; handlers not yet ported to the JIT                 |

---

## Sources

- [Unison language documentation]
- [Unison GitHub repository] — `unison-runtime/src/Unison/Runtime/{Machine,ANF,MCode,Stack,Builtin}.hs`, `Foreign/Function.hs`
- [runtime design notes] (`unison-runtime/src/Unison/Runtime/docs.markdown`)
- [Abilities and ability handlers (language reference)]
- [Ability declaration (language reference)]
- [Abilities: a mental model]
- [Announcing Unison 1.0]
- [JIT compilation is coming to Unison]
- [The big idea: content-addressed code]
- [Unison Cloud documentation]
- [Do Be Do Be Do (Frank paper, POPL 2017)]
- Related corpus docs: [Frank], [Koka], [Effect systems & event loops], [Go runtime netpoller], [Eio's io_uring backend]

<!-- References -->

[Frank]: frank.md
[Koka]: koka.md
[Effect systems & event loops]: ../async-io/effects-and-event-loops.md
[Go runtime netpoller]: ../async-io/go-netpoller.md
[Eio's io_uring backend]: ../async-io/eio-backend.md
[Unison language documentation]: https://www.unison-lang.org/docs/
[Unison GitHub repository]: https://github.com/unisonweb/unison
[runtime design notes]: https://github.com/unisonweb/unison/blob/e1870038739ffcb27b4e3b483dafd2c21f6541b2/unison-runtime/src/Unison/Runtime/docs.markdown
[Abilities and ability handlers (language reference)]: https://www.unison-lang.org/docs/language-reference/abilities-and-ability-handlers/
[Ability declaration (language reference)]: https://www.unison-lang.org/docs/language-reference/ability-declaration/
[Abilities: a mental model]: https://www.unison-lang.org/docs/fundamentals/abilities/
[Announcing Unison 1.0]: https://www.unison-lang.org/unison-1-0/
[JIT compilation is coming to Unison]: https://www.unison-lang.org/whats-new/jit-announce/
[The big idea: content-addressed code]: https://www.unison-lang.org/docs/the-big-idea/
[Unison Cloud documentation]: https://www.unison.cloud/docs/core-concepts/
[Do Be Do Be Do (Frank paper, POPL 2017)]: https://arxiv.org/abs/1611.09259

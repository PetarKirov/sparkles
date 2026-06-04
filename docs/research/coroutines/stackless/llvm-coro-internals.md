# Inside LLVM's Coroutine Passes — How the Stackless Transform Works

This is the implementation deep-dive for the LLVM half of the survey. Where
[llvm-coroutines][llvm-coroutines] catalogs the `@llvm.coro.*` intrinsic surface a
frontend emits, this document descends one level: it traces what the middle-end
_does_ with those intrinsics — how `CoroSplit` turns a single annotated function
into a state machine plus out-of-line resume/destroy functions, how `CoroFrame`
discovers which SSA values must be spilled and lays out the heap frame, and how
`CoroElide`/`CoroAnnotationElide` claw the heap allocation back when a caller fully
contains the coroutine's lifetime. The payoff for [ldc-codegen][ldc-codegen] and the
[roadmap][roadmap] is concrete: an LDC that merely _emits_ these intrinsics inherits
this entire machine from the stock optimizer pipeline, with one custom-ABI escape
hatch reserved for when the default lowerings do not fit.

**Last reviewed:** June 4, 2026

---

## 1. The shape of the pipeline

LLVM's coroutine support is a **stackless** transform: a single LLVM function whose
suspension points are marked with intrinsics is rewritten into a state machine plus
one or more out-of-line "resume" functions, with every SSA value that is live across
a suspend spilled into a heap-or-stack-allocated **coroutine frame** struct. The
frontend (Clang for C++20, Swift for async, and — prospectively — LDC) emits the
intrinsics; the middle-end passes lower them.

The governing philosophy is stated in the `CoroSplit.cpp` header comment, and it
explains the entire pass ordering:

> We present a coroutine to an LLVM as an ordinary function with suspension
> points marked up with intrinsics. We let the optimizer party on the coroutine
> as a single function for as long as possible. Shortly before the coroutine is
> eligible to be inlined into its callers, we split up the coroutine into parts
> corresponding to an initial, resume and destroy invocations of the coroutine,
> add them to the current SCC and restart the IPO pipeline to optimize the
> coroutine subfunctions we extracted before proceeding to the caller of the
> coroutine.

(`CoroSplit.cpp:11-18`)

Keeping the coroutine as one function for as long as possible means inlining, SROA,
GVN, and the rest of the scalar optimizers run on it _before_ the frame is built —
so values that get optimized away never make it onto the frame. The split happens
inside the CGSCC pipeline, after the inliner, and then the original ramp plus its
clones are re-enqueued onto the CGSCC worklist so the IPO pipeline reprocesses them.

### 1.1 Pass families and the conditional wrapper

| Pass                     | Scope    | When                    | Role                                                              |
| ------------------------ | -------- | ----------------------- | ----------------------------------------------------------------- |
| `CoroEarly`              | Module   | early simplification    | pre-split lowering of "simple" intrinsics (§6.1)                  |
| `CoroSplit`              | CGSCC    | after the inliner       | the core: build frame + split into resume/destroy/cleanup (§3–§5) |
| `CoroElide`              | Function | function simplification | stack-promote + devirtualize in _callers_ (§7.1)                  |
| `CoroAnnotationElide`    | CGSCC    | right after `CoroSplit` | rewrite `coro_elide_safe` calls to the `.noalloc` ramp (§7.2)     |
| `CoroCleanup`            | Module   | late                    | post-split lowering of remaining intrinsics (§6.2)                |
| `CoroConditionalWrapper` | Module   | wraps all of the above  | cheap gate: only run if coro intrinsics exist                     |

The core sequence is assembled in `buildCoroWrapper`, gated by
`CoroConditionalWrapper` so the whole machine is a no-op on modules that never touch
a coroutine (`PassBuilderPipelines.cpp:474-485`):

```llvm
ModulePassManager CoroPM;
CoroPM.addPass(CoroEarlyPass());
CGSCCPassManager CGPM;
CGPM.addPass(CoroSplitPass());
CoroPM.addPass(createModuleToPostOrderCGSCCPassAdaptor(std::move(CGPM)));
CoroPM.addPass(CoroCleanupPass());
CoroPM.addPass(GlobalDCEPass());
return CoroConditionalWrapper(std::move(CoroPM));
```

The wrapper's guard is one line — it checks whether the module declares _any_ coro
intrinsic before running the pipeline:

```text
if (!coro::declaresAnyIntrinsic(M)) return PreservedAnalyses::all();
return PM.run(M, AM);
```

(`CoroConditionalWrapper.cpp:18-24`)

### 1.2 Placement in the O1+ pipeline

The full integration into the optimizer pipeline (`PassBuilderPipelines.cpp`):

- **`CoroEarlyPass`** runs as a Module pass early in module simplification
  (`:1162`, `:2144`).
- **`CoroSplitPass`** runs inside the **main CGSCC pipeline**, after the inliner and
  function-attribute deduction (`:1054-1056`):

  ```llvm
  if (!isThinLTOPreLink(Phase)) {
    MainCGPipeline.addPass(CoroSplitPass(Level != OptimizationLevel::O0));
    MainCGPipeline.addPass(CoroAnnotationElidePass());
  }
  ```

  The constructor argument `Level != O0` becomes the pass's `OptimizeFrame` flag —
  the toggle that enables alloca slot-merging (§5.4). It is wired in at several
  pipeline variants (`:1106-1108`, `:1845-1846`, `:2213-2214`).

- **`CoroElidePass`** runs as a Function pass in function simplification (`:607`,
  `:822`) — note it runs on _callers_, eliding frames after callees are split.
- **`CoroAnnotationElidePass`** runs immediately after `CoroSplitPass` in the CGSCC
  pipeline (`:1056`, `:1108`, `:1846`, `:2214`).
- **`CoroCleanupPass`** runs late as a Module pass (`:1334`, `:1848`, `:2366`).

> [!NOTE]
> The CGSCC placement is load-bearing, not incidental. `CoroSplit` deliberately
> runs _after_ the inliner so the coroutine body is fully inlined-into and
> optimized as one function; it then re-enqueues the ramp and clones onto the CGSCC
> worklist (`CoroSplit.cpp:2267-2276`) so the freshly-minted resume/destroy
> functions get the same IPO treatment. This is the "split, then restart the IPO
> pipeline" half of the header-comment philosophy.

---

## 2. The four ABI classes

Everything `CoroSplit` does is parameterized by a `coro::ABI` enum that names the
lowering strategy. There are four built-in classes (`CoroShape.h:26-49`), each with
its own resume-function calling convention, signature, and frame discipline.

| ABI          | Resume model                                                    | Promise? | Frontend / use               |
| ------------ | --------------------------------------------------------------- | -------- | ---------------------------- |
| `Switch`     | shared resume + destroy fns, frame stores fn ptrs + index       | yes      | C++20 coroutines             |
| `Retcon`     | one continuation fn per suspend, used for resume _and_ destroy  | no       | Swift returned-continuation  |
| `RetconOnce` | like `Retcon`, suspends at most once, continuation returns void | no       | unwind/cleanup continuations |
| `Async`      | one continuation fn per suspend, continuation is an intrinsic   | n/a      | Swift async/await            |

The `Switch` doc comment captures exactly why it is the model a general D coroutine
should follow:

> The "resume-switch" lowering, where there are separate resume and
> destroy functions that are shared between all suspend points. The
> coroutine frame implicitly stores the resume and destroy functions,
> the current index, and any promise value.

(`CoroShape.h:27-30`)

### 2.1 The Switch resume signature is `void(ptr)` with `CallingConv::C`

For the `Switch` ABI the resume function type is fixed and trivial — it takes the
frame pointer and returns void (`CoroShape.h:174-189`):

```llvm
case coro::ABI::Switch:
  return FunctionType::get(Type::getVoidTy(CoroBegin->getContext()),
                           PointerType::getUnqual(CoroBegin->getContext()),
                           /*IsVarArg=*/false);
```

`Retcon`/`RetconOnce` instead return the resume-prototype's own type, and `Async`
returns `nullptr` because, in the comment's words, "The function type depends on the
active suspend." Critically, the `Switch` resume function uses the **platform C
calling convention**, and the comment spells out why — interoperability of the
function pointers stored in the frame (`CoroShape.h:211-217`):

```llvm
case coro::ABI::Switch:
  // Use the platform C calling convention so that resume/destroy
  // function pointers stored in the coroutine frame are
  // interoperable with other compilers.
  return CallingConv::C;
```

This is the property that makes a Switch-lowered frame a portable ABI artifact: a
`{resumeFn, destroyFn, …}` struct whose function pointers any C-ABI caller can
invoke. `Retcon` uses the prototype's CC; `Async` uses `AsyncLowering.AsyncCC`.

### 2.2 The `Shape` struct and the per-ABI object model

A `coro::Shape` (`CoroShape.h:53-267`) is the analysis result for one coroutine
function: it collects every structural intrinsic (`CoroBegin`, `CoroEnds`,
`CoroSuspends`, `CoroSizes`, `CoroAligns`, `CoroAwaitSuspends`, `SymmetricTransfers`,
`SwiftErrorOps`; `:54-64`), the computed `FrameAlign`/`FrameSize`/`FramePtr`/
`AllocaSpillBlock` (`:99-102`), and a union of per-ABI storage. The
`SwitchLoweringStorage` (`:104-115`) carries `ResumeSwitch`, `PromiseAlloca`,
`ResumeEntryBlock`, `IndexType`, `DestroyOffset`, `IndexAlign`/`IndexOffset`,
`HasFinalSuspend`, and `HasUnwindCoroEnd`. A telling comment fixes the frame layout:
`// ResumeOffset always 0;` (`:109`) — the resume function pointer always sits at
frame offset 0.

The behavioral dispatch is object-oriented. `coro::BaseABI` (`ABI.h:41-65`) is the
abstract interface; `SwitchABI`, `AsyncABI`, and `AnyRetconABI` (one class handles
both `Retcon` and `RetconOnce`) subclass it (`ABI.h:67-104`). The header documents
the design intent and, importantly, the extension mechanism:

> This interface/API is to provide an object oriented way to
> implement ABI functionality… The ABIs (e.g. Switch, Async, Retcon{Once}) are
> the common ABIs… specific users may need to modify the behavior of these. This
> can be accomplished by inheriting one of the common ABIs and overriding one or
> more of the methods to create a custom ABI. To use a custom ABI for a given
> coroutine the **coro.begin.custom.abi** intrinsic is used in place of the
> coro.begin intrinsic.

(`ABI.h:30-39`)

Only `init()` and `splitCoroutine()` are pure-virtual; `buildCoroutineFrame()` has a
default implementation (the standard frame builder of §5) that custom ABIs usually
inherit unchanged. We return to the plugin mechanism in §8 — it is the cleanest path
for a new D/wasm lowering.

---

## 3. `CoroSplit`: the orchestration

### 3.1 Pass entry — `CoroSplitPass::run`

`CoroSplit` is a **CGSCC pass**; its entry collects the coroutines in the SCC and
processes each (`CoroSplit.cpp:2209-2284`):

- It harvests `llvm.coro.prepare.retcon`/`.async` users (`:2220-2222`), then finds
  coroutines by attribute:

  ```llvm
  for (LazyCallGraph::Node &N : C)
    if (N.getFunction().isPresplitCoroutine())
      Coroutines.push_back(&N);
  ```

  (`:2226-2228`)

- For each coroutine it first calls `removeUnreachableBlocks(F)` — and the comment
  explains the necessity: "The suspend-crossing algorithm in `buildCoroutineFrame`
  gets tripped up by unreachable blocks" (`:2240-2243`). It then constructs
  `coro::Shape Shape(F)` (`:2245`), bails if there is no `CoroBegin`, and marks
  `F.setSplittedCoroutine()` (`:2249`).
- `CreateAndInitABI(F, Shape)` (`:2251`) instantiates the per-ABI object (the factory
  of §8), then `doSplitCoroutine(F, Clones, *ABI, TTI, OptimizeFrame)` (`:2255`) does
  the work.
- After splitting, `updateCallGraphAfterCoroutineSplit(...)` (`:2256`) re-enqueues
  the original ramp and every clone onto the CGSCC worklist (`:2267-2276`):

  ```llvm
  UR.CWorklist.insert(CurrentSCC);
  for (Function *Clone : Clones)
    UR.CWorklist.insert(CG.lookupSCC(CG.get(*Clone)));
  ```

### 3.2 The fixed orchestration — `doSplitCoroutine`

`doSplitCoroutine` (`CoroSplit.cpp:1996-2043`) runs a fixed sequence regardless of
ABI; the ABI-specific work is funneled through the `BaseABI` virtuals:

1. `lowerAwaitSuspends(F, Shape)` (`:2004`) lowers `@llvm.coro.await.suspend.*` into
   a call to the wrapper function; for `coro_await_suspend_handle` it also emits a
   symmetric-transfer resume call recorded in `Shape.SymmetricTransfers`
   (`lowerAwaitSuspend`, `:86-149`).
2. `simplifySuspendPoints(Shape)` (`:2006`) — Switch-only (§3.4).
3. `normalizeCoroutine(F, Shape, TTI)` (`:2008`) — CFG normalization (§4.1).
4. `ABI.buildCoroutineFrame(OptimizeFrame)` (`:2009`) — frame layout + spills (§5).
5. `replaceFrameSizeAndAlignment(Shape)` (`:2010`) — RAUW `coro.size`/`coro.align`
   with constants (and, for Async, patch the async func-pointer global's context
   size).
6. If `Shape.CoroSuspends.empty()`, `handleNoSuspendCoroutine` turns the frame into a
   plain stack alloca without splitting (`:1160-1192`); otherwise
   `ABI.splitCoroutine(...)` (`:2023`).
7. `replaceSwiftErrorOps`, salvage debug info, `removeCoroEndsFromRampFunction`,
   `removeCoroIsInRampFromRampFunction` (`:2028-2039`).
8. If `shouldCreateNoAllocVariant` holds (Switch ABI, `hasSafeElideCaller(F)`, not
   noinline; `:2014-2016`), `SwitchCoroutineSplitter::createNoAllocVariant(F, Shape,
Clones)` (`:2042`) emits the `.noalloc` ramp that `CoroAnnotationElide` will call
   (§7.2).

---

## 4. CFG normalization and the cloners

### 4.1 `normalizeCoroutine`

Frame analysis demands a tidy CFG, so `coro::normalizeCoroutine`
(`CoroFrame.cpp:1954-2002`) runs first:

- `eliminateSwiftError` (`:1957-1958`); for Switch, clear the promise from `coro.id`
  (`:1960-1963`).
- `splitAround` each `coro.save` and `coro.suspend` so each lives alone in its own
  block (`:1968-1972`) — "to simplify the logic of building up SuspendCrossing data";
  likewise `splitAround` each `coro.end` (`:1975-1993`).
- `cleanupSinglePredPHIs(F)` (`:1997`) and `rewritePHIs(F)` (`:2001`).

`rewritePHIs` (`:1386-1472`) is the subtle one: multi-incoming PHIs are split so each
incoming value gets its own single-value PHI in a freshly split predecessor edge
block, with the explicit invariant that downstream liveness can ignore them:

> After this rewrite, further analysis will ignore any phi nodes with more than one
> incoming edge.

(`CoroFrame.cpp:1402-1403`)

Exception-handling cleanup-pads get special handling (`rewritePHIsForCleanupPad`,
`:1294-1367`) — a dispatcher block with an `i8` switch is built because "all EH
blocks must have the same unwind edge."

### 4.2 The cloner

The actual outlining is done by a cloner hierarchy (`CoroCloner.h` + impl in
`CoroSplit.cpp`). `CloneKind` (`CoroCloner.h:25-40`) enumerates `SwitchResume`,
`SwitchUnwind`, `SwitchCleanup`, `Continuation`, `Async`. `BaseCloner`
(`CoroCloner.h:42-126`) holds `OrigF`, `Shape`, `FKind`, a `ValueToValueMapTy VMap`,
`NewF`, `NewFramePtr`, and `ActiveSuspend` (meaningful only for continuation and
async ABIs). `SwitchCloner` (`:128-149`) is the Switch subclass; its `create()` runs
`createCloneDeclaration` then `BaseCloner::create()`, and for `SwitchCleanup` it also
calls `elideCoroFree(NewFramePtr)` (`CoroSplit.cpp:1094-1105`) — the cleanup clone
must not free the frame.

`BaseCloner::create()` (`CoroSplit.cpp:880-1092`) is the heart of cloning:

- Replace original args with freeze-poison dummies (`:888-892`), then
  `CloneFunctionInto(NewF, &OrigF, VMap, LocalChangesOnly, Returns)` (`:908-909`).
- Per-ABI attribute setup (`:943-987`): Switch copies fn attrs plus frame-ptr attrs;
  Async adds `SwiftAsync`/`SwiftSelf`; Retcon takes the prototype's attributes
  wholesale.
- Returns handling (`:989-1012`): Switch/RetconOnce `changeToUnreachable(Return)`;
  Retcon/Async leave returns intact.
- `NewF->setCallingConv(Shape.getResumeFunctionCC())` (`:1015`).
- `replaceEntryBlock()` (`:1018`, def `:673-737`) makes the cloned `AllocaSpillBlock`
  the new entry; the Switch clone branches into the resume-entry switch (§5.1), while
  continuation ABIs branch to the successor of the active suspend.
- Symmetric transfers become musttail calls when the target supports it (`:1020-1036`):
  `ResumeCall->setTailCallKind(TCK_MustTail)` if `TTI.supportsTailCallFor(ResumeCall)`.
- `NewFramePtr = deriveNewFramePointer()` (`:1039`) then RAUW the old frame pointer
  (`:1042-1044`). The `deriveNewFramePointer` Switch branch (`:745-746`) is the
  simplest case — "the argument is the frame pointer" → `return &*NewF->arg_begin();`.
- `replaceCoroSuspends()` (`:1080`, def `:514-549`) replaces each non-active
  `coro.suspend` with `i8 1` in destroy clones and `i8 0` in the resume clone
  (`:524-525`), then `replaceCoroEnds()`, `replaceCoroIsInRamp()`,
  `salvageDebugInfo()` (`:1086-1091`).

`handleFinalSuspend()` (`:404-433`) removes the final-suspend case from the cloned
switch (it is UB to resume past final suspend) and, in destroy clones, inserts a
null-check on the resume fn ptr to branch to the resume BB versus the rest of the
switch.

---

## 5. The Switch lowering and frame-building heart

### 5.1 `SwitchCoroutineSplitter::split`

The Switch ABI produces **three clones** (`CoroSplit.cpp:1368-1401`):

```llvm
createResumeEntryBlock(F, Shape);
auto *ResumeClone  = SwitchCloner::createClone(F, ".resume",  Shape, CloneKind::SwitchResume,  TTI);
auto *DestroyClone = SwitchCloner::createClone(F, ".destroy", Shape, CloneKind::SwitchUnwind,  TTI);
auto *CleanupClone = SwitchCloner::createClone(F, ".cleanup", Shape, CloneKind::SwitchCleanup, TTI);
```

After `postSplitCleanup` on each (`:1385-1387`), it calls `updateCoroFrame` to store
the fn pointers into the frame (`:1390`), pushes all three into `Clones`, and
`setCoroInfo(F, Shape, Clones)` (`:1400`) to build the resumers array.

**The resume-index switch.** `createResumeEntryBlock` (`:1474-1598`) builds the
`resume.entry` block; the comment sketches the IR (`:1486-1493`):

```llvm
resume.entry:
  %index.addr = getelementptr inbounds %f.Frame, ptr %FramePtr, i32 0, i32 2
  %index = load i32, ptr %index.addr
  switch i32 %index, label %unreachable [
    i32 0, label %resume.0
    i32 1, label %resume.1
    ...
  ]
```

The index pointer is built by `createSwitchIndexPtr` (`:305-310`) from
`Shape.SwitchLowering.IndexOffset`, and the switch is stored as
`Shape.SwitchLowering.ResumeSwitch` (`:1504`). For each suspend point
(`:1508-1591`), it replaces the `coro.save` with a store of the suspend's index into
the frame index field (`:1515-1524`) — or for the final suspend, calls
`markCoroutineAsDone` (`:1517-1520`). It then splits the suspend block into
`resume.N`/`resume.N.landing`, adds a switch case, and inserts a PHI selecting
between `-1` (initial fallthrough) and the actual suspend result (`:1553-1565`).
Debug labels `__coro_resume_N` are emitted (`:1567-1588`).

**Storing the fn pointers.** `updateCoroFrame` (`:1601-1626`):

```llvm
Builder.CreateStore(ResumeFn, Shape.FramePtr);            // resume ptr at offset 0
... DestroyAddr = FramePtr + DestroyOffset;
Builder.CreateStore(DestroyOrCleanupFn, DestroyAddr);
```

If a `CoroAlloc` exists, `DestroyOrCleanupFn = select(CoroAlloc, DestroyFn,
CleanupFn)` (`:1613-1617`) — the destroy path frees the frame, the cleanup path does
not (used when the frame was elided onto the stack, §7.1).

**The resumers array.** `setCoroInfo` (`:1641-1660`) builds a private constant
`[N x ptr]` holding `{resume, destroy, cleanup}` and stores it via
`Shape.getSwitchCoroId()->setInfo(BC)`. This array is the linchpin of heap-elision,
and the comment ties the two together:

> This only works under the switch-lowering ABI because coro elision only works on
> the switch-lowering ABI.

(`CoroSplit.cpp:1643-1644`)

`CoroElide` later reads this array off the post-split `coro.id` to recover the
literal `@f.resume`/`@f.destroy`/`@f.cleanup` constants (§7.1).

**Frame-pointer attributes.** The cloned resume function's frame-pointer parameter
(arg 0) is decorated `NonNull`, `NoUndef`, with alignment, and
`dereferenceable(FrameSize)` by `addFramePointerAttrs` (`CoroSplit.cpp:849-862`,
called `:950-951`). This is not cosmetic: `CoroElide` reads `dereferenceable` +
`align` back off the resume signature to recover the frame's size and alignment
(`CoroElide.cpp:115-122`, `getFrameLayout`). The signature _is_ the frame-size
channel.

### 5.2 Suspend-crossing liveness — `SuspendCrossingInfo`

Which values must be spilled is a liveness question: a value needs the frame iff its
definition precedes a suspend and a use follows it. The `CoroFrame.cpp` header states
the contract:

> discover if for a particular value its definition precedes and its uses follow a
> suspend block… a suspend crossing value… form a Coroutine Frame structure to
> contain those values. All uses of those values are replaced with appropriate GEP +
> load… At the point of the definition we spill the value into the coroutine frame.

(`CoroFrame.cpp:8-16`)

`SuspendCrossingInfo` computes this with a per-block bitvector dataflow
(`SuspendCrossingInfo.h:54-67`):

- `Consumes` — "set of indices of blocks that can reach block 'i'. A block can
  trivially reach itself."
- `Kills` — "blocks that can reach block 'i' but there is a path crossing a suspend
  point not repeating 'i'."
- plus `AlwaysKill`/`NeverKill` booleans and `KillLoop` (a self-loop crossing a
  suspend).

Construction (`SuspendCrossingInfo.cpp:148-210`): `BlockToIndexMapping` numbers the
BBs (`SuspendCrossingInfo.h:33-52`); each block starts consuming itself (`:153-160`).
`coro.end` blocks are `setNeverKill()` because "code beyond coro.end is reachable
during initial invocation" (`:162-171`). `coro.suspend` and its `coro.save` blocks
are `setAlwaysKill()` with `B.Kills |= B.Consumes` (`markSuspendBlock`, `:185-200`),
and the comment makes the key point that **crossing `coro.save` — not just
`coro.suspend` — forces a spill**:

> crossing coro.save also requires a spill, as any code between coro.save and
> coro.suspend may resume the coroutine.

(`SuspendCrossingInfo.cpp:181-184`)

The lattice is iterated to a fixpoint over RPO: `computeBlockData<Initialize=true>`
once, then `while (computeBlockData<false>(RPOT));` (`:202-207`). `computeBlockData`
(`:91-146`) propagates `Consumes`/`Kills` from predecessors —
`if (P.isAlwaysKill()) B.Kills |= P.Consumes;` (`:124-125`) — and for normal blocks
clears the self bit but records `KillLoop |= B.Kills[BBNo]` (`:135-136`).

The query the spill collectors call is `isDefinitionAcrossSuspend`
(`SuspendCrossingInfo.h:135-198`): "is value V live across a suspend at use U",
which reduces to `hasPathCrossingSuspendPoint(DefBB, UseBB)` — itself just
`Block[ToIndex].Kills[FromIndex]` (`:70-78`). Two special cases matter for a
frontend: a use by `coro.suspend.retcon`/`.async` is treated as occurring in the
suspend's predecessor (`:149-152`), and a value _defined by_ `coro.suspend.*` is
treated as defined in the successor (`:164-170`). Multi-incoming PHIs return false —
they were already rewritten in normalization (`:140-141`).

### 5.3 Spill collection — `SpillUtils`

Spills are collected into a `SpillInfo` map — `SmallMapVector<Value*,
SmallVector<Instruction*, 2>, 8>` (`SpillUtils.h:18`) — mapping each to-be-spilled
def to the list of users needing a reload. Allocas get a richer `AllocaInfo`
(`SpillUtils.h:20-29`): `{Alloca, Aliases, MayWriteBeforeCoroBegin}`. Three
collectors run:

- `collectSpillsFromArgs` (`SpillUtils.cpp:457-464`): arguments whose uses cross a
  suspend. When an `Argument` is spilled, `removeParamAttr(..., Captures)`
  (`getSpillInsertionPt`, `:597`).
- `collectSpillsAndAllocasFromInsts` (`:466-519`): iterates every instruction,
  skipping `coro.id`/`coro.save`/`coro.begin` (`isNonSpilledIntrinsic`, `:24-28`),
  handling `coro.alloca.alloc` (`:480-499`), and for ordinary instructions adding a
  spill for any user where `Checker.isDefinitionAcrossSuspend(I, U)` (`:510-517`). A
  token type that crosses a suspend is a fatal error (`:513-515`).
- `collectSpillsFromDbgInfo` (`:521-536`): salvages `dbg.value`s for already-framed
  values.

**Alloca residency.** Whether a stack slot must live on the frame is decided by
`AllocaUseVisitor` (`:146-422`), a `PtrUseVisitor` answering three questions
(`:116-144`): should the alloca live on the frame; could it be written before
`coro.begin` (→ needs a memcpy into the frame); and are aliases created before
`coro.begin` but used after (→ recreate them off the frame).
`computeShouldLiveOnFrame` (`:337-390`) uses `lifetime.start`/`lifetime.end` markers
when available (`:342-369`): if a `lifetime.start`→suspend path has no matching
`lifetime.end`, the alloca persists across the suspend and must be framed; otherwise
it falls back to "escaped or any user-pair crossing a suspend" (`:381-389`).

Two exclusions are worth flagging for a frontend author: `collectFrameAlloca`
(`:425-455`) does **not** frame the promise alloca, nor any alloca carrying
`MD_coro_outside_frame` metadata (`:432-440`); and lifetime-based shrinking is
disabled for Async/Retcon ABIs because it "does not work for functions with loops
without exit" (`:442-447`). For Async/Retcon, `sinkSpillUsesAfterCoroBegin`
(`:540-584`) moves every spill user that precedes `coro.begin` to after it — those
ABIs "assume that all spill uses can be sunk after the coro.begin intrinsic"
(`SpillUtils.h:43-44`).

Where the _store_ into the frame lands is decided by `getSpillInsertionPt`
(`:586-629`): arguments store right after the frame pointer; suspend results store
into the suspend's single successor ("Don't spill immediately after a suspend",
`:598-601`); invoke results in a split normal edge; PHIs after the EH-pad / first
insertion point; everything else right after the def.

### 5.4 Frame struct construction — `FrameTypeBuilder`

`FrameTypeBuilder` (`CoroFrame.cpp:159-294`) assembles the frame struct. A field is
`{Size, Offset, Alignment, DynamicAlignBuffer}` (`:161-166`). `addField`
(`:224-275`) computes field size as `DL.getTypeAllocSize(Ty)`, caps spill-value
alignment at `MaxFrameAlignment` (`:233-237`), collapses zero-size fields to index 0
(`:248-249`), and requests a `DynamicAlignBuffer` for runtime re-alignment when
`FieldAlignment > MaxFrameAlignment` (`:254-260`). Header fields get a concrete
offset immediately; everything else gets a `FlexibleOffset` (`:262-271`).
`finish()` (`:444-472`) hands the fields to `performOptimizedStructLayout` (LLVM's
`OptimizedStructLayout`), which computes size/align/offsets to minimize padding.

**Alloca slot merging.** When `OptimizeFrame` is on (opt level above `O0`),
`addFieldForAllocas` (`:315-442`) uses `StackLifetime` analysis
(`LivenessType::May`, `:370-372`) to group allocas with **non-overlapping live
ranges** into the same frame slot (`DoAllocasInterfere`, `:373-376`). Larger allocas
sort first to prioritize merging (`:387-389`), and two allocas can share a slot only
if non-interfering _and_ alignment-compatible — `largest.align % candidate.align ==
0` (`:407-411`). The comment notes a side effect to be aware of: alloca order in the
frame may differ from source order (`:218-219`).

### 5.5 Whole-frame layout — `buildFrameLayout`

`buildFrameLayout` (`CoroFrame.cpp:803-922`) lays out the whole struct. The summary
comment (`:796-802`) gives the canonical Switch order: resume fn ptr at offset 0,
destroy fn ptr at pointer-size, promise alloca, suspend index, then spills and
allocas. The Switch-specific code (`:818-838`):

```llvm
(void)B.addField(FnPtrTy, MaybeAlign(), /*header*/ true);   // resume fn ptr
(void)B.addField(FnPtrTy, MaybeAlign(), /*header*/ true);   // destroy fn ptr
... if (PromiseAlloca) addFieldForAlloca(PromiseAlloca, /*header*/ true);
unsigned IndexBits = std::max(1U, Log2_64_Ceil(Shape.CoroSuspends.size()));
SwitchIndexType = Type::getIntNTy(F.getContext(), IndexBits);
SwitchIndexFieldId = B.addField(SwitchIndexType, MaybeAlign());
```

The index field is sized to the **minimum bit-width** for the suspend count
(`:835-836`) — a 3-suspend coroutine gets an `i2` index, not an `i32`. After
`addFieldForAllocas` and one `addField` per spill (`:843-871`; `byval` args store the
_pointed-to value_ in the frame, not the pointer, `:860-867`), `B.finish()` runs and
`Shape.FrameAlign`/`Shape.FrameSize` are set (`:873-877`). The per-ABI epilogue
(`:879-921`): Switch records `DestroyOffset = DL.getPointerSize()`, the index
align/offset, and rounds the frame size up to alignment (`:880-894`); Retcon decides
`IsFrameInlineInStorage` (whether the frame fits in caller-provided storage,
`:898-905`); Async computes `FrameOffset`/`ContextSize` and errors if frame align
exceeds context align (`:906-920`). `MaxFrameAlignment` is set only for Async
(`= ContextAlignment`, `:809-811`); otherwise it is nullopt (no cap).

### 5.6 Spill and reload insertion — `insertSpills`

`insertSpills` (`CoroFrame.cpp:1060-1272`) rewrites defs and uses. For each spilled
def it inserts the **store into the frame** at `getSpillInsertionPt`
(`createStoreIntoFrame`, `:938-961` — `byval` args use `CreateMemCpy`, otherwise
`CreateAlignedStore`). For each user block it inserts a **reload** (GEP + aligned
load) at the block's first insertion point (`:1090-1131`); the GEP is built by
`createGEPToFramePointer` (`:965-993`), which handles dynamic alignment via
round-up-and-mask (`:973-983`) and address-space casts. A TBAA "Frame Slot" scalar
tag is attached to reload loads so alias analysis knows frame slots do not alias user
memory (`:1067-1080`, `:1108-1109`). Single-edge PHIs are replaced directly by the
reload (`:1162-1169`).

It then creates the **`AllocaSpillBB`** (`:1181-1186`): it splits the block after the
frame pointer into `AllocaSpillBB` → `PostSpill`, and this block becomes the new
entry of the resume clones (via `replaceEntryBlock`, §4.2). For Retcon/Async, allocas
are RAUW'd with frame GEPs and lifetime intrinsics dropped (`:1188-1211`). For Switch,
alloca uses dominated by `coro.begin` are GEP-replaced (`:1218-1250`), and
`handleAccessBeforeCoroBegin` inserts a memcpy when `MayWriteBeforeCoroBegin`, plus
recreates aliases as `frameptr + offset` (`:1251-1271`).

### 5.7 The frame driver — `BaseABI::buildCoroutineFrame`

All of §5.2–§5.6 is sequenced by the default frame driver
(`CoroFrame.cpp:2004-2045`):

```text
SuspendCrossingInfo Checker(F, Shape);
doRematerializations(F, Checker, IsMaterializable);          // §6
... sinkLifetimeStartMarkers(F, Shape, Checker, DT);          // non-Async/Retcon
collectSpillsFromArgs / collectSpillsAndAllocasFromInsts / collectSpillsFromDbgInfo
... sinkSpillUsesAfterCoroBegin(...)                          // Async/Retcon
buildFrameLayout(F, DT, Shape, FrameData, OptimizeFrame);
Shape.FramePtr = Shape.CoroBegin;
buildFrameDebugInfo(F, Shape, FrameData);                     // C++ only
insertSpills(FrameData, Shape);
lowerLocalAllocas(LocalAllocas, DeadInstructions);
```

Two lines deserve emphasis. `Shape.FramePtr = Shape.CoroBegin` (`:2036`) — the
`coro.begin` return value _is_ the frame pointer until the cloner remaps it.
`sinkLifetimeStartMarkers` (`:1734-1811`) shrinks alloca lifetimes by sinking
`lifetime.start` to the dominating block when the alloca is used within one suspended
region, "minimizing the amount of data we end up putting on the frame."

> [!WARNING]
> Debug-info frame construction is **C++-gated**. `buildFrameDebugInfo`
> (`CoroFrame.cpp:619-764`) builds the synthetic `__coro_frame` `DICompositeType`
> (with `__resume_fn`/`__destroy_fn`/`__coro_index` members for Switch, `:711-728`)
> only for C++ FullDebug (`:628-635`). A D frontend emitting a non-C++ source
> language gets no `__coro_frame` debug info unless that guard is relaxed — an
> open issue flagged for [ldc-codegen][ldc-codegen] and the [roadmap][roadmap].

---

## 6. Rematerialization and the simple-intrinsic passes

### 6.1 `MaterializationUtils` — rematerialize to shrink the frame

Rather than spill a cheap value across a suspend, LLVM prefers to _recompute_ it
afterward — the file's one-liner: "materialize insts after suspends points"
(`MaterializationUtils.cpp:9`). `coro::doRematerializations` (`:308-369`) finds
materializable instructions whose uses cross a suspend (seeding `Spills`,
`:319-325`), builds a `RematGraph` (a DAG of rematerializable defs) per crossing user
(`:343-363`), then `rewriteMaterializableInstructions(AllRemats)` (`:155-229`) clones
each remat node just before the use — or into the suspend's predecessor terminator if
the use is itself a suspend (`:182-188`) — rewires operands, and RAUWs the original
uses (`:218-228`). It relies on later CSE to dedup (`:333-337`) and bails entirely
under `hasOptNone()` (`:311`).

What counts as materializable is the `defaultMaterializable` set (`:234-290`): casts,
GEPs, binary/unary ops, compares, selects, and a curated list of FP/integer-math
intrinsics (`fabs`, `sqrt`, `sin`, `cos`, `floor`, `ctpop`, `smax`, saturating
arithmetic, …). `isTriviallyMaterializable` (`:292-294`) forwards to it — this is the
default `IsMaterializable` callback the ABI receives (`CoroSplit.cpp:2168`). A custom
ABI may supply its own predicate (§8).

### 6.2 `CoroEarly` — pre-split lowering of simple intrinsics

`CoroEarlyPass::run` (`CoroEarly.cpp:201-212`) bails unless the module declares coro
intrinsics (`declaresCoroEarlyIntrinsics`, `:191-199`), then runs
`lowerEarlyIntrinsics` (`:105-189`) over each function. It lowers:

- **`coro.resume`/`coro.destroy`** → an _indirect_ call through `coro.subfn.addr`
  (`lowerResumeOrDestroy`, `:43-47`). The comment explains why this indirection is
  introduced _early_:

  > This is done so that CGPassManager recognizes devirtualization when CoroElide
  > pass replaces a call to coro.subfn.addr with an appropriate function address.

  (`CoroEarly.cpp:39-42`)

  This is the linchpin that lets `CoroElide`'s devirtualization re-trigger the
  CGSCC re-optimization (§7.1).

- **`coro.promise`** → a constant GEP from the frame ptr to the promise slot,
  computed from a mock `{resumeFn, destroyFn, i8}` layout (`lowerCoroPromise`,
  `:56-75`).
- **`coro.done`** → load the resume-fn ptr at frame offset 0 and compare to null
  (`lowerCoroDone`, `:81-93` — at the final suspend the resume fn ptr is zeroed).
- `coro.id` presplit: assert the `presplitcoroutine` attribute, `setCannotDuplicate`
  on `coro.begin`, `setCoroutineSelf` (`:142-153`); `coro.id.retcon`/`.retcon.once`/
  `.async` → `F.setPresplitCoroutine()` (`:154-158`).
- The final `coro.suspend` and the fallthrough `coro.end` get `setCannotDuplicate`
  (`CoroSplit` assumes at most one of each, `:128-141`).
- If `HasCoroSuspend`, strip `noalias` off all args (suspension may modify args
  out-of-function, `:182-188`).

It preserves CFG analyses (`PA.preserveSet<CFGAnalyses>()`, `:210`).

### 6.3 `CoroCleanup` — post-split lowering of the rest

`CoroCleanupPass::run` (`CoroCleanup.cpp:270-293`) lowers leftover intrinsics, then
runs `SimplifyCFGPass` on any changed function (`:278-289`). `Lowerer::lower`
(`:93-167`) handles:

- `coro.begin`/`coro.begin.custom.abi` → its mem arg (`:104-107`).
- `coro.free` → its arg-1 (`:108`); `coro.alloc` → `true` (`:113`).
- `coro.id*` → `ConstantTokenNone` (`:120-125`).
- **`coro.subfn.addr`** → load the fn ptr from a `{ptr, ptr}` frame at the given
  index (`lowerSubFn`, `:59-72`) — the _non-devirtualized_ fallback that runs when
  `CoroElide` did not fire.
- `coro.noop` → a global `NoopCoro.Frame.Const` whose resume/destroy both point to an
  empty `__NoopCoro_ResumeDestroy` function (`lowerCoroNoop`, `:169-202`);
  `NoopCoroElider` (`:39-56`, `:204-258`) recursively erases resume/destroy calls on
  the noop coro.
- `coro.async.size.replace` patches async context sizes (`:141-157`).

It returns `PreservedAnalyses::none()` (`:292`).

---

## 7. Heap-allocation elision (HALO in code)

Two complementary passes implement the Heap Allocation eLision Optimization. The
C++ rationale and the symmetric-transfer interplay are discussed at the language
level in [cpp][cpp]; this section is the _implementation_.

### 7.1 `CoroElide` — stack-promote + devirtualize in the caller

`CoroElide` is a **Function pass** that fires on _callers_: when a caller fully
contains a coroutine's lifetime it replaces the heap frame with a stack alloca and
devirtualizes the resume/destroy calls. `CoroElidePass::run` (`CoroElide.cpp:451-472`)
only acts on post-split `coro.id`s observed in the caller (`collectPostSplitCoroIds`,
`:147-167` — `CII->getInfo().isPostSplit()` and not the coroutine itself); it needs
`AAResults`, `DominatorTree`, and an `OptimizationRemarkEmitter`.

`CoroIdElider::attemptElide` (`:388-449`) is the engine:

- It reads the resumers array off the post-split `coro.id` —
  `ConstantArray *Resumers = CoroId->getInfo().Resumers;` (`:391`) — the array that
  `setCoroInfo` built (§5.1).
- It _always_ devirtualizes resume:
  `replaceWithConstant(ResumeAddrConstant, ResumeAddr)` (`:394-397`) RAUWs
  `coro.subfn.addr(frame, ResumeIndex)` with the literal `@f.resume`.
- `lifetimeEligibleForElide()` (`:330-386`) decides whether the heap alloc can be
  removed. If eligible, destroy devirtualizes to `CleanupIndex` (no free); otherwise
  to `DestroyIndex` (`:401-405`).
- If eligible and the frame size is known, `elideHeapAllocations(FrameSize,
FrameAlign)` (`:412-413`) does the promotion.

`getFrameLayout` (`:115-122`) recovers the frame size/align from the resume
function's arg-0 `dereferenceable` + `align` attributes — the channel
`addFramePointerAttrs` set up in `CoroSplit` (§5.1). `lifetimeEligibleForElide`
(`:330-386`) requires `CoroAllocs` non-empty (`:332-334`) and, per `coro.begin`,
that every function terminator is dominated by a `coro.dead`/destroy referencing
that SSA value (`:357-371`), else falls back to the path-sensitive
`canCoroBeginEscape` (`:247-328`). `elideHeapAllocations` (`:208-245`) replaces
`coro.alloc` with `false` (suppress malloc), creates a stack `alloca [FrameSize x
i8]` with `FrameAlign`, RAUWs each `coro.begin` with it, calls `elideCoroFree`, and
`removeTailCallAttribute` (frame-referencing tail calls become non-tail now that the
frame is on the stack, `:104-111`).

> [!IMPORTANT]
> The whole devirtualization chain depends on `CoroEarly` having turned direct
> `coro.resume`/`coro.destroy` into indirect calls through `coro.subfn.addr`
> (§6.2). That indirection is what lets the CGSCC pass manager _recognize_ the
> devirtualization when `CoroElide` substitutes a function address, re-triggering
> optimization of the now-direct call. And, per `setCoroInfo`'s comment, elision
> only works for the **Switch** ABI — the resumers-array machinery is
> Switch-specific (`CoroSplit.cpp:1643-1644`).

### 7.2 `CoroAnnotationElide` — the `.noalloc` ramp

`CoroAnnotationElide` is a **CGSCC pass** that uses a different mechanism: a frontend
marks a call to a coroutine with the `coro_elide_safe` attribute
(`Attribute::CoroElideSafe`), and this pass rewrites that call to invoke the
`.noalloc` ramp variant (the one `createNoAllocVariant` produced, §3.2/§7.3), with
the frame allocated as a caller alloca. The file comment:

> transforms all Call or Invoke instructions that are annotated 'coro_elide_safe'
> to call the `.noalloc` variant… The frame of the callee coroutine is allocated
> inside the caller. A pointer to the allocated frame will be passed into the
> `.noalloc` ramp function.

(`CoroAnnotationElide.cpp:9-14`)

`run` (`:115-214`) looks up `Callee->getName() + ".noalloc"` (`:127-129`) and fires
only when the _caller_ is a presplit coroutine, the call carries `CoroElideSafe`
(`:153-155`), and a block-frequency threshold is met (`CoroElideBranchRatio` default
`0.55`, `:39-41`, `:156-163`). `processCall` (`:70-113`) calls
`allocateFrameInCaller` (a caller-entry alloca sized from the `.noalloc`'s
`dereferenceable`/`align` on its last param, `:53-63`, `:140-144`), builds a new
call/invoke with the frame ptr appended, removes the `CoroElideSafe` attr, and then
**inlines** the `.noalloc` function (`InlineFunction`, `:105-112`), updating the call
graph (`updateCGAndAnalysisManagerForCGSCCPass`, `:194-196`).

### 7.3 The `.noalloc` ramp and its gate

`createNoAllocVariant` (`CoroSplit.cpp:1410-1469`) clones the ramp function with one
trailing `ptr` frame parameter, suppresses `coro.alloc`/`coro.free`, and replaces
`coro.begin` with the frame arg (`:1438-1445`). Frame-ptr attributes (deref/align)
are attached to the new last arg (`:1454-1456`). Its emission is gated by
`hasSafeElideCaller` (`CoroSplit.cpp:1978-1988`), which checks for a presplit-coroutine
caller carrying the `CoroElideSafe` attr — so the `.noalloc` variant is only produced
when a `coro_elide_safe` call site actually exists.

---

## 8. The custom-ABI / plugin mechanism

The factory `CreateNewABI` (`CoroSplit.cpp:2141-2163`) is where a coroutine's ABI
object is chosen — and it is the documented extension point:

```llvm
if (S.CoroBegin->hasCustomABI()) {
  unsigned CustomABI = S.CoroBegin->getCustomABI();
  if (CustomABI >= GenCustomABIs.size())
    llvm_unreachable("Custom ABI not found amoung those specified");
  return GenCustomABIs[CustomABI](F, S);
}
switch (S.ABI) {
  case Switch:     return std::make_unique<coro::SwitchABI>(F, S, IsMatCallback);
  case Async:      return std::make_unique<coro::AsyncABI>(F, S, IsMatCallback);
  case Retcon:     return std::make_unique<coro::AnyRetconABI>(F, S, IsMatCallback);
  case RetconOnce: return std::make_unique<coro::AnyRetconABI>(F, S, IsMatCallback);
}
```

`CoroSplitPass::BaseABITy` is `std::function<std::unique_ptr<coro::BaseABI>(Function&,
coro::Shape&)>` (`CoroSplit.h:32-33`). Four `CoroSplitPass` constructors
(`CoroSplit.h:35-47`, impls `CoroSplit.cpp:2165-2207`) accept an optional
`SmallVector<BaseABITy> GenCustomABIs` and/or a custom materializable callback; they
store a closure `CreateAndInitABI` that calls `CreateNewABI` then `ABI->init()`. The
pass entry then calls `CreateAndInitABI(F, Shape)` (`:2251`).

So a plugin — a D frontend backend, or a WasmFX lowering — supplies a vector of ABI
generators to the `CoroSplitPass` constructor, and the frontend emits
`@llvm.coro.begin.custom.abi` with the matching index. The custom ABI subclasses
`coro::BaseABI` (or one of Switch/Async/AnyRetcon), overrides `init()` +
`splitCoroutine()` (and optionally `buildCoroutineFrame`), and inherits the entire
frame builder of §5. **No upstream LLVM patch is required.**

---

## 9. Why this matters for LDC

The single most important takeaway for the [roadmap][roadmap] is one of _leverage_:

> [!IMPORTANT]
> If LDC emits the `@llvm.coro.*` intrinsics from the DMD frontend, it gets the
> entire transform described in this document — `CoroEarly`, `CoroSplit`, frame
> building, rematerialization, `CoroElide`/`CoroAnnotationElide`, `CoroCleanup` —
> **for free from the stock LLVM pipeline**. No pass authoring is needed, because
> the passes already ship in LDC's LLVM and are already wired into the O1+ pipeline
> behind the cheap `CoroConditionalWrapper` gate.

What LDC must do is the frontend-side intrinsic emission (the subject of
[ldc-codegen][ldc-codegen]): declare the intrinsics, mark the coroutine function
`presplitcoroutine`, emit `coro.id`/`coro.begin`/`coro.save`/`coro.suspend`/
`coro.end` in the right CFG positions, and — to enable HALO — annotate elision-safe
call sites with `coro_elide_safe`. The middle-end does the rest.

The **Switch ABI** is the natural target for a general stackless D coroutine: a
single frame with embedded resume/destroy function pointers plus an index, a
`void(ptr)` resume signature, and the C calling convention for cross-module interop
(§2.1). Crucially, heap-elision (§7) only works for the Switch ABI — the
resumers-array dependency in `setCoroInfo` is Switch-specific — so choosing Switch
keeps D coroutines in the path of the zero-allocation optimization.

A **custom ABI** (§8) is the escape hatch, not the default. LDC would register a
generator from C++ glue (subclassing `coro::BaseABI`) and emit
`coro.begin.custom.abi` _only_ if D needs a lowering the four built-ins cannot
express — for instance, a bespoke resume signature, a frame layout matching D's
existing [`core.thread.Fiber`][d-fiber] runtime contract, or integration with a
WasmFX continuation runtime. For the stackless state-machine lowering itself, the
Switch ABI suffices, and the custom-ABI path can be deferred until a concrete need
appears.

Finally, a few `report_fatal_error` boundaries a D frontend will hit if it emits
malformed coroutine IR: non-static/`vscale` allocas are rejected
(`CoroFrame.cpp:187-189`); tokens may not cross a suspend
(`SpillUtils.cpp:513-515`); and at most one final suspend and one fallthrough
`coro.end` are allowed (`Coroutines.cpp:231-233`, `CoroEarly.cpp:128-141`). These,
plus the C++-gated frame debug info (§5.7), are the known sharp edges to surface in
the [roadmap][roadmap].

---

## Sources

Primary artifacts (LLVM 23.0.0git, `$REPOS/llvm-project`):

- `llvm/lib/Transforms/Coroutines/CoroSplit.cpp` — splitting, cloners, no-alloc
  variant, ABI factory.
- `llvm/lib/Transforms/Coroutines/CoroFrame.cpp` — CFG normalization, frame layout,
  spill/reload insertion, frame debug info.
- `llvm/lib/Transforms/Coroutines/SpillUtils.cpp` /
  `llvm/include/llvm/Transforms/Coroutines/SpillUtils.h` — spill
  collection, alloca residency.
- `llvm/lib/Transforms/Coroutines/SuspendCrossingInfo.cpp` /
  `llvm/include/llvm/Transforms/Coroutines/SuspendCrossingInfo.h`
  — suspend-crossing liveness dataflow.
- `llvm/lib/Transforms/Coroutines/MaterializationUtils.cpp` — rematerialization.
- `llvm/lib/Transforms/Coroutines/CoroElide.cpp`,
  `.../CoroAnnotationElide.cpp` — heap-allocation elision.
- `llvm/lib/Transforms/Coroutines/CoroEarly.cpp`,
  `.../CoroCleanup.cpp` — simple/structural intrinsic lowering.
- `llvm/lib/Transforms/Coroutines/CoroConditionalWrapper.cpp` — pipeline gate.
- `llvm/lib/Transforms/Coroutines/Coroutines.cpp` — Shape analysis + ABI init.
- `llvm/include/llvm/Transforms/Coroutines/CoroShape.h`, `.../ABI.h`,
  `.../CoroInstr.h`, `.../CoroSplit.h` — data structures + ABI interface.
- `llvm/lib/Transforms/Coroutines/CoroCloner.h` — the cloner hierarchy.
- `llvm/lib/Passes/PassBuilderPipelines.cpp` — pass registration and ordering.

<!-- References -->

[llvm-coroutines]: ./llvm-coroutines.md
[ldc-codegen]: ./ldc-codegen.md
[roadmap]: ./roadmap.md
[cpp]: ./cpp-coroutines.md
[d-fiber]: ../stackful/d-fiber.md

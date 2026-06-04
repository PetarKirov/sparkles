# LDC Code Generation for `llvm.coro.*`

The concrete LDC glue-layer path for emitting LLVM coroutine intrinsics, and the
plumbing that already exists. This doc is the "how do we actually wire it into
LDC" leaf of the survey: where the LLVM coroutine passes already run, how to
expose `llvm.coro.*` to D source today with no compiler changes, which existing
glue-layer machinery (varargs prologue, closure frames, runtime hooks) is the
structural template for a coroutine prologue/epilogue, and the two insertion
strategies — library-via-pragma vs. first-class glue emission — with a concrete
recommendation. It pairs with [the LLVM coroutine model][llvm-coroutines] and
[its internals][llvm-internals] (what the passes expect to see), the
[D language-design][d-design] options (what D syntax would feed this), and the
[memory/attribute][attributes] and [wasm][wasm] consequences downstream.

**Last reviewed:** June 4, 2026

---

## Bottom line up front

Three facts establish that LDC is already most of the way to stackless
coroutines, and that a useful prototype needs no compiler patch at all:

1. **The LLVM `Coro*` passes already ship in LDC's optimizer pipeline at every
   `-O` level.** LDC drives the standard LLVM pipeline builders
   (`buildPerModuleDefaultPipeline` / `buildO0DefaultPipeline`), and those embed
   a `CoroConditionalWrapper` that self-activates the moment a module declares
   any `llvm.coro.*` intrinsic. No new pass plumbing is required — `CoroSplit`
   will run, even at `-O0` (`gen/optimizer.cpp:527-558`,
   `PassBuilderPipelines.cpp:475-485`).
2. **`llvm.coro.*` can be exposed to D source with zero compiler changes** via
   the existing `pragma(LDC_intrinsic, "llvm.coro.…")` mechanism — the same one
   that exposes `llvm.returnaddress` / `llvm.stacksave` — or, for the
   `token`-typed intrinsics that have no D representation, via the
   `pragma(LDC_inline_ir)` raw-IR escape hatch (`gen/inlineir.cpp`).
3. **The nested-function/closure frame machinery** (`gen/nested.cpp`) is the
   closest existing analog to a coroutine-frame allocator: a per-function struct
   that is either stack-`alloca`'d or heap-allocated through the
   `_d_allocmemory` runtime hook. It is the model for _the allocation call and
   hidden-pointer threading_ — **not** for hand-rolling the frame struct, because
   under the `CoroSplit` ABI it is LLVM, not LDC, that lays out the frame.

> [!IMPORTANT]
> The division of labour with LLVM's coroutine lowering is the single most
> important thing to internalize before reading the rest. LDC emits only the
> _markers_ — `coro.id`, `coro.size`, `coro.begin`, `coro.suspend`, `coro.end`,
> plus the allocation call — into an ordinary-looking function. The `CoroSplit`
> pass then discovers the suspend points, computes the frame layout, spills live
> values, and splits the body into ramp/resume/destroy clones. LDC never builds
> the state machine itself. See [LLVM coroutine internals][llvm-internals].

All citations below are `path:line` against the LDC checkout at
`$REPOS/dlang/ldc` (v1.42) and the LLVM checkout at
`$REPOS/llvm-project` (LLVM 23.0.0git) that LDC links.

---

## 1. The D-body → IR pipeline

### 1.1 `DtoDefineFunction` — the glue-layer skeleton

`gen/functions.cpp:966` — `void DtoDefineFunction(FuncDeclaration *fd, bool
linkageAvailableExternally)` — is _the_ function that turns a D function body
into LLVM IR. Its body-emission skeleton (lines 966–1343) is the template a
first-class coroutine prologue/epilogue would slot into:

| Step                             | Location                      | What it does                                                                                                 |
| -------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Push per-function state          | `gen/functions.cpp:1113`      | `gIR->funcGenStates.emplace_back(new FuncGenState(*irFunc, *gIR));` (popped via `SCOPE_EXIT` at `:1117`)     |
| Entry BB + IRBuilder scope       | `gen/functions.cpp:1195,1199` | `BasicBlock::Create(...)` then `setInsertPoint(beginbb)`                                                     |
| Allocas block                    | `gen/functions.cpp:1211`      | a separate `"allocas"` BB collecting every `alloca`, spliced into entry at the end                           |
| Trace / instrumentation prologue | `gen/functions.cpp:1214-1219` | `emitInstrumentationFnEnter`, `emitDMDStyleFunctionTrace` (`:861`, pushes a `_c_trace_epi` epilogue cleanup) |
| `this` + parameters              | `gen/functions.cpp:1222-1245` | `defineParameters`                                                                                           |
| Nested-context construction      | `gen/functions.cpp:1250`      | `DtoCreateNestedContext(funcGen);` — see §3                                                                  |
| **D-style varargs**              | `gen/functions.cpp:1259-1282` | `va_start` prologue + `va_end` cleanup — the structural template (§1.3)                                      |
| Body emission                    | `gen/functions.cpp:1288`      | `Statement_toIR(fd->fbody, gIR);`                                                                            |
| Cleanup blocks + implicit return | `gen/functions.cpp:1290-1323` | inserts the missing terminator DMD omits (`CreateRetVoid` / `CreateRet`)                                     |
| Alloca splice (epilogue glue)    | `gen/functions.cpp:1326-1327` | `beginbb->splice(beginbb->begin(), funcGen.allocasBlock);` then erase                                        |

`Statement_toIR` is declared `gen/irstate.h:289` `void Statement_toIR(Statement
*s, IRState *irs);`.

### 1.2 Statement and expression lowering hooks

`gen/statements.cpp` is an `extern(C++)` visitor with one `visit(...)` per
statement kind. The relevant hook for a coroutine's return-value capture /
final suspend is `gen/statements.cpp:161` `void visit(ReturnStatement *stmt)
override`, which computes the return value and either stores it to `sretArg`
(sret path, `:205-235`) or returns it by value. Other suspend-relevant control
flow visitors: `visit(WhileStatement)` `:527`, `visit(ForStatement)` `:650`,
`visit(ForeachStatement)` `:1297`, `visit(TryFinallyStatement)` `:831`,
`visit(TryCatchStatement)` `:904`.

> [!NOTE]
> There is **no** statement kind for `yield`/`await` in D today. A coroutine
> design either introduces one in the frontend (the [language-design][d-design]
> doc weighs this) or — far more cheaply — expresses suspend as an ordinary
> intrinsic _call expression_, which `toir.cpp` already lowers for free.

`gen/toir.cpp` lowers expressions; the hot path is `CallExp` lowering at
`gen/toir.cpp:710` `static DValue *call(IRState *p, CallExp *e, LLValue
*sretPointer)`. Magic intrinsics and inline asm/IR are intercepted _before_ a
normal call is emitted:

```cpp
// gen/toir.cpp:718-731
    // handle magic intrinsics and inline asm/IR
    if (auto ve = e->e1->isVarExp()) {
      if (auto fd = ve->var->isFuncDeclaration()) {
        if (fd->llvmInternal == LLVMinline_asm) {
          return DtoInlineAsmExpr(e->loc, fd, e->arguments, sretPointer);
        }
        if (fd->llvmInternal == LLVMinline_ir) {
          return DtoInlineIRExpr(e->loc, fd, e->arguments, sretPointer);
        }

        DValue *result = nullptr;
        if (DtoLowerMagicIntrinsic(p, fd, e, result))
          return result;
      }
    }
```

This is the crux of strategy (A): a `pragma(LDC_intrinsic, "llvm.coro.suspend")`
call in D source flows through this path and lands as a real `llvm.coro.suspend`
call instruction with no special handling. Direct C++-side intrinsic emission
also exists for reference (`gen/toir.cpp:820,1796,1953` use
`GET_INTRINSIC_DECL(assume, ...)` / `GET_INTRINSIC_DECL(trap, {})`).

### 1.3 The varargs prologue/epilogue — the structural template

The single most directly relevant existing pattern is the D-style-varargs
handling: it is _glue-layer intrinsic emission inserted into the prologue with a
matching cleanup in the epilogue_ — structurally exactly where a
`coro.id`/`coro.begin` prologue and a `coro.end` epilogue cleanup would go.

```cpp
// gen/functions.cpp:1259-1282
  if (f->isDstyleVariadic()) {
    // allocate _argptr (of type core.stdc.stdarg.va_list)
    Type *tvalist = target.va_listType(fd->loc, fd->_scope);
    LLValue *argptrMem = DtoAlloca(tvalist, "_argptr_mem");
    irFunc->_argptr = argptrMem;

    // initialize _argptr with a call to the va_start intrinsic
    DLValue argptrVal(tvalist, argptrMem);
    LLValue *llAp = gABI->prepareVaStart(&argptrVal);
    llvm::CallInst::Create(GET_INTRINSIC_DECL(vastart, llAp->getType()), llAp, "",
                           gIR->scopebb());

    // copy _arguments to a memory location
    irFunc->_arguments = DtoAllocaDump(irFunc->_arguments, 0, "_arguments_mem");

    // Push cleanup block that calls va_end to match the va_start call.
    {
      auto *vaendBB = llvm::BasicBlock::Create(gIR->context(), "vaend", func);
      const auto savedInsertPoint = gIR->saveInsertPoint();
      gIR->ir->SetInsertPoint(vaendBB);
      gIR->ir->CreateCall(GET_INTRINSIC_DECL(vaend, llAp->getType()), llAp);
      funcGen.scopes.pushCleanup(vaendBB, gIR->scopebb());
    }
  }
```

For a coroutine this maps almost one-to-one: emit `coro.id`/`coro.size`/
`coro.begin` (+ the allocation call) in place of `va_start`, and push a cleanup
block that runs the `coro.free`/`coro.end` epilogue in place of `va_end`. The
same `funcGen.scopes.pushCleanup(...)` machinery that pairs `va_end` with its
`va_start` (and that DMD-style tracing reuses, `gen/functions.cpp:861`) gives
correct ordering with respect to D's scope/destructor unwinding.

The IRBuilder/insertion-point helpers available either way:
`gen/irstate.cpp:61` `setInsertPoint`, `:67` `saveInsertPoint`, `:89` `insertBB`,
`:77/:82` `insertBBBefore/After`, `:72` `scopereturned`, and `nextAllocaPos()`
(`gen/irstate.cpp:49`, the insertion point inside `allocasBlock`).

---

## 2. Exposing the intrinsics to D source

### 2.1 The `pragma(LDC_intrinsic, "…")` mechanism

This is the canonical path and the reason no compiler change is needed for a
prototype. The pragma is parsed in `DtoGetPragma`:

```cpp
// gen/pragma.cpp:122-160 (LDC_intrinsic)
  if (ident == Id::LDC_intrinsic) {
    if (!args || args->length != 1 || !parseStringExp(getFirstArg(), arg1str)) {
      pragmaError("requires exactly 1 string literal parameter");
      fatal();
    }
    ...
    return LLVMintrinsic;
  }
```

`DtoCheckPragma` then tags the declaration and stores the intrinsic name as the
**mangle override**:

```cpp
// gen/pragma.cpp:353-361 (case LLVMintrinsic)
    int count = applyFunctionPragma(s, [=](FuncDeclaration *fd) {
      fd->llvmInternal = llvm_internal;
      fd->mangleOverride = {strlen(arg1str), arg1str};
    });
    count += applyTemplatePragma(s, [=](TemplateDeclaration *td) {
      td->llvmInternal = llvm_internal;
      td->intrinsicName = arg1str;
    });
```

So a `pragma(LDC_intrinsic, "llvm.coro.id")`-tagged D function gets its LLVM
symbol name set to the literal `"llvm.coro.id"`. When `DtoDeclareFunction`
(`gen/functions.cpp:560-603`) emits the declaration:

- `forceC = DtoIsIntrinsic(fdecl) || …` (`gen/functions.cpp:563`) — intrinsics use
  the C calling convention.
- The IR mangled name is the override string (`getIRMangledName`, `:566`), and
  `LLFunction::Create(functype, linkage, irMangle, &gIR->module)` (`:578`, where
  `linkage` is `ExternalLinkage` for an ordinary declaration) emits it. Because the name begins with `llvm.`, **LLVM automatically
  recognizes it as an intrinsic** and assigns it an `IntrinsicID`. At call time,
  `tocall.cpp` picks up the intrinsic's attributes from the recognized ID:

```cpp
// gen/tocall.cpp:1043-1052
  if (auto cf = call->getCalledFunction()) {
    call->setCallingConv(cf->getCallingConv());
    if (cf->isIntrinsic()) { // override intrinsic attrs
      attrlist = llvm::Intrinsic::getAttributes(gIR->context(), cf->getIntrinsicID()
#if LLVM_VERSION_MAJOR >= 21
                                         ,cf->getFunctionType()
#endif
                                         );
    }
  }
```

The intrinsic ABI itself is a no-padding pass-through: `gen/abi/abi.cpp:300`
`struct IntrinsicABI : TargetABI { ... }` (returns false from `returnInArg` /
`passByVal`, strips struct padding), obtained via `TargetABI::getIntrinsic()`
(`gen/abi/abi.cpp:323`) and selected in `DtoFunctionType`:
`gen/functions.cpp:85` `TargetABI *abi = fd && DtoIsIntrinsic(fd) ?
TargetABI::getIntrinsic() : gABI;`.

The `ldc.intrinsics` module (`runtime/druntime/src/ldc/intrinsics.di`) is the
existing precedent — the whole file is `nothrow @nogc` (`:45-46`) — and is the
natural home for coroutine declarations. The existing analogs:

```d
// runtime/druntime/src/ldc/intrinsics.di:55-56
pragma(LDC_intrinsic, "llvm.returnaddress")
    void* llvm_returnaddress(uint level);
// :67-68
pragma(LDC_intrinsic, "llvm.stacksave")
    void* llvm_stacksave();
// :74-75
pragma(LDC_intrinsic, "llvm.stackrestore")
    void llvm_stackrestore(void* ptr);
```

New coro declarations would follow the same shape (illustrative):

```d
pragma(LDC_intrinsic, "llvm.coro.size.i64")
    size_t llvm_coro_size_i64();
pragma(LDC_intrinsic, "llvm.coro.begin")
    void* llvm_coro_begin(/* token */ void* id, void* mem);
pragma(LDC_intrinsic, "llvm.coro.suspend")
    ubyte llvm_coro_suspend(/* token */ void* save, bool final_);
pragma(LDC_intrinsic, "llvm.coro.end")
    void llvm_coro_end(void* handle, bool unwind, /* token none */ void* result);
```

### 2.2 Overloaded intrinsics and the `anyint` suffix

Type-overloaded intrinsics (the `.i#`/`.f#` family) are resolved through
`DtoOverloadedIntrinsicName` (`gen/llvmhelpers.cpp:1215`) and
`DtoSetFuncDeclIntrinsicName` (`gen/llvmhelpers.cpp:1289`), which rewrite a `#`
placeholder into `i32`/`f64`/`v4f32`/etc. from the template type parameter.

Most `llvm.coro.*` intrinsics are **not** type-overloaded in that `i#`/`f#`
manner — they use `token`, `ptr`, `i1`, `i8` types (§2.4) — so the plain
non-template `pragma(LDC_intrinsic, …)` form suffices for `coro.id`,
`coro.begin`, `coro.suspend`, `coro.end`, `coro.free`, `coro.alloc`,
`coro.resume`, `coro.destroy`, `coro.done`, `coro.promise`, `coro.frame`,
`coro.subfn.addr`. The exceptions are the `anyint`-overloaded `coro.size` and
`coro.align`, which need an explicit suffix baked into the name string, e.g.
`"llvm.coro.size.i64"` / `"llvm.coro.align.i32"`.

### 2.3 The `token`-type problem and the inline-IR escape hatch

> [!WARNING]
> LLVM's `token` type has **no representation in D's type system**, yet several
> coro intrinsics produce or consume one: `coro.id` returns a `token`, `coro.save`
> returns a `token`, `coro.begin`/`coro.suspend` consume one, and `coro.end`
> takes a `token` operand (§2.4). A `void*` D declaration cannot model a `token`,
> so the plain pragma cannot fully express the begin→suspend→end token chain.

The escape hatch is `pragma(LDC_inline_ir)` (`gen/inlineir.cpp`), parsed at
`gen/pragma.cpp:316-323` and checked by `DtoCheckInlineIRPragma`
(`gen/inlineir.cpp:53`). It exposes two templates:

```text
// gen/inlineir.cpp:71-75 (comment)
//   R inlineIR(string code, R, P...)(P);
//   R inlineIREx(string prefix, string code, string suffix, R, P...)(P);
```

`DtoInlineIRExpr` (`gen/inlineir.cpp:104`) literally builds an LLVM IR `define`
string from the `code` template argument, parses it with
`llvm::parseAssemblyString` (`gen/inlineir.cpp:192-193`), links it into the
module (`gen/inlineir.cpp:208`
`llvm::Linker(gIR->module).linkInModule(std::move(m))`), marks the synthesized
function `AlwaysInline` + `PrivateLinkage` (`:225-227`), and emits a call
(`:237`). Each instantiation defines a fresh `inline.ir.N` function that is
always inlined (`gen/inlineir.cpp:116-117`), so the spliced instructions land
_inline in the caller_ — exactly where `CoroSplit` expects to find them.

The `inlineIREx` form's `prefix`/`suffix` parameters (`:162-188`) can emit
**module-level declarations** alongside the body, so they can hand-declare the
`token`-typed coro intrinsics in raw IR and splice an arbitrary `llvm.coro.*`
sequence — `token` chain and all — directly into a function body. This is the
robust way to express the token-typed intrinsics today without a frontend
change. (A small frontend special-case mapping `token` to an opaque D type is the
alternative; it is flagged as an **open implementation detail** below.)

### 2.4 The LLVM coro intrinsic surface (target side)

`llvm/include/llvm/IR/Intrinsics.td:1870-1968` declares the coroutine
intrinsics, cross-referenced to the docs: `// These are documented in
docs/Coroutines.rst` (`Intrinsics.td:1871`). Verbatim type lists for the core
set:

| Intrinsic          | Result / operands              | Definition           |
| ------------------ | ------------------------------ | -------------------- |
| `int_coro_id`      | `[token] (i32, ptr, ptr, ptr)` | `Intrinsics.td:1875` |
| `int_coro_alloc`   | `[i1] (token)`                 | `Intrinsics.td:1887` |
| `int_coro_begin`   | `[ptr] (token, ptr)`           | `Intrinsics.td:1907` |
| `int_coro_free`    | `[ptr] (token, ptr)`           | `Intrinsics.td:1912` |
| `int_coro_end`     | `[] (ptr, i1, token)`          | `Intrinsics.td:1917` |
| `int_coro_frame`   | `[ptr] ()`                     | `Intrinsics.td:1922` |
| `int_coro_size`    | `[anyint] ()`                  | `Intrinsics.td:1926` |
| `int_coro_align`   | `[anyint] ()`                  | `Intrinsics.td:1927` |
| `int_coro_save`    | `[token] (ptr)`                | `Intrinsics.td:1929` |
| `int_coro_suspend` | `[i8] (token, i1)`             | `Intrinsics.td:1930` |
| `int_coro_resume`  | `[] (ptr)` `[Throws]`          | `Intrinsics.td:1941` |
| `int_coro_destroy` | `[] (ptr)` `[Throws]`          | `Intrinsics.td:1942` |
| `int_coro_done`    | `[i1] (ptr)`                   | `Intrinsics.td:1943` |
| `int_coro_promise` | `[ptr] (ptr, i32, i1)`         | `Intrinsics.td:1946` |

The `token` types are explicit in the TableGen: `def int_coro_id :
DefaultAttrsIntrinsic<[llvm_token_ty], [llvm_i32_ty, llvm_ptr_ty, llvm_ptr_ty,
llvm_ptr_ty], ...>` (`Intrinsics.td:1875-1878`), and `def int_coro_end :
Intrinsic<[], [llvm_ptr_ty, llvm_i1_ty, llvm_token_ty], []>;`
(`Intrinsics.td:1917`). The retcon/async variants for the "returned-continuation"
and Swift-async ABIs are also present — `int_coro_id_retcon`
(`Intrinsics.td:1879`), `int_coro_id_retcon_once` (`:1883`), `int_coro_id_async`
(`:1888`), `int_coro_suspend_retcon` (`:1931`), `int_coro_suspend_async`
(`:1901`), `int_coro_end_async` (`:1919`). The **retcon / retcon.once** ABIs are
the most relevant for D ranges/generators that yield a value at each suspend
without keeping a persistent heap handle alive; see [LLVM coroutine
internals][llvm-internals] for the ABI differences.

### 2.5 The `llvmInternal` / `LDCPragma` enum

`gen/dpragma.d:22-48` is the `extern(C++) enum LDCPragma` shared with the
frontend; relevant members are `LLVMintrinsic`, `LLVMinline_ir`,
`LLVMinline_asm`, `LLVMalloca`, the `LLVMva_*` family, etc., with
`DtoIsIntrinsic` / `DtoIsMagicIntrinsic` at `gen/pragma.cpp:575/579`. **Adding a
dedicated coroutine pragma is possible but unnecessary** — `LLVMintrinsic`
already covers any `llvm.*` name. A dedicated `LDCPragma` member would only earn
its keep if LDC wanted to _generate the begin/suspend/end scaffolding
automatically_ rather than letting D library code arrange the calls (i.e.
strategy (B), §7).

---

## 3. The closure-frame analog (`gen/nested.cpp`)

`gen/nested.cpp` builds the closest existing analog to a coroutine frame: a
per-function struct holding captured locals, laid out by the glue layer and
either stack- or heap-allocated. It is the right mental model for _the allocation
call and the hidden-pointer threading_ — with one crucial caveat (§3.3).

### 3.1 Frame layout — `DtoCreateNestedContextType`

`gen/nested.cpp:355` `static void DtoCreateNestedContextType(FuncDeclaration
*fd)`. A frame is created only if `fd->closureVars.length != 0`
(`gen/nested.cpp:376`); otherwise the parent's frame type/depth are inherited
(`:378-386`). For nesting depth `> 0` the frame begins with pointer fields to all
enclosing frames (`:413-421`) via an `AggrTypeBuilder` (`:411`). Each captured
variable is appended, recording its field index and depth on the `IrLocal`:

```cpp
// gen/nested.cpp:451-456
    IrLocal &irLocal = *(isParam ? getIrParameter(vd, true) : getIrLocal(vd, true));
    irLocal.nestedIndex = builder.currentFieldIndex();
    irLocal.nestedDepth = depth;
    builder.addType(t, getTypeAllocSize(t));
```

Capture-by-ref vars store a pointer (`:432-434`); lazy params store a delegate
(`:435-440`); everything else stores the value type (`:442`). The resulting
struct is stashed on `IrFunction`:

```cpp
// gen/nested.cpp:462-470
  LLStructType *frameType = LLStructType::create(
      gIR->context(), builder.defaultTypes(),
      std::string("nest.") + fd->toChars(), builder.isPacked());
  irFunc.frameType = frameType;
  irFunc.frameTypeAlignment = maxAlignment;
```

### 3.2 Allocation — stack vs. heap via `_d_allocmemory`

`gen/nested.cpp:473` `void DtoCreateNestedContext(FuncGenState &funcGen)`, called
from the prologue at `gen/functions.cpp:1250`, performs the allocation. The
heap-vs-stack decision is driven by `dmd::needsClosure(fd)`:

```cpp
// gen/nested.cpp:489-512
    LLValue *frame = nullptr;
    bool needsClosure = dmd::needsClosure(fd);
    IF_LOG Logger::println("Needs closure (GC) flag: %d", (int)needsClosure);
    if (needsClosure) {
      LLFunction *fn =
          getRuntimeFunction(fd->loc, gIR->module, "_d_allocmemory");
      auto size = getTypeAllocSize(frameType);
      if (frameAlignment > 16) // GC guarantees an alignment of 16
        size += frameAlignment - 16;
      LLValue *mem =
          gIR->CreateCallOrInvoke(fn, DtoConstSize_t(size), ".gc_frame");
      if (frameAlignment <= 16) {
        frame = mem;
      } else {
        const uint64_t mask = frameAlignment - 1;
        mem = gIR->ir->CreatePtrToInt(mem, DtoSize_t());
        mem = gIR->ir->CreateAdd(mem, DtoConstSize_t(mask));
        mem = gIR->ir->CreateAnd(mem, DtoConstSize_t(~mask));
        frame =
            gIR->ir->CreateIntToPtr(mem, LLPointerType::get(getGlobalContext(), 0), ".frame");
      }
    } else {
      frame = DtoRawAlloca(frameType, frameAlignment, ".frame");
    }
```

The result becomes the per-function frame base, stored at `gen/nested.cpp:536`
`funcGen.nestedVar = frame;` (the field is `gen/funcgenstate.h:195`
`llvm::Value *nestedVar = nullptr;`). After allocation, captured
params/locals are copied into the frame (`gen/nested.cpp:539-587`): params are
memcpy'd in, the NRVO sret pointer is stored, and plain locals get a GEP into the
frame as their lvalue (`:583`).

This is precisely the pattern a coroutine-frame allocator hook would follow:
**call a druntime `_d_*` allocation function, store its result as the frame
base.**

### 3.3 The hidden context pointer — and what differs for coroutines

`gen/nested.cpp:63` `DValue *DtoNestedVariable(...)` walks the frame chain to
load a captured var, locating the context (own `funcGen().nestedVar`, the
incoming `irfunc->nestArg`, or a `this`-embedded `vthis`) then GEPing by
`nestedIndex`/`nestedDepth` (`:146-203`). The **hidden context pointer** is the
extra function parameter `irFunc.nestArg` (`gen/nested.cpp:113,271,516`) that a
nested function receives; `DtoNestedContext` (`gen/nested.cpp:231`) computes what
to pass for a given callee.

> [!IMPORTANT]
> **A coroutine frame is conceptually the same object — but LDC must not build
> the struct.** A stackless coroutine frame holds everything that survives across
> suspends (live locals, the resume-index/state, the promise). Under LLVM's
> `CoroSplit` ABI the **frame layout is computed by the pass, not by LDC**: LDC
> emits `coro.id`/`coro.size`/`coro.begin` plus the allocation call, and
> `CoroSplit` decides which values spill into the frame and at what offsets. So,
> unlike closures, LDC would **not** create the `LLStructType` itself. The closure
> code is the model for _the allocation call and hidden-pointer threading_, never
> for hand-rolling the layout.

---

## 4. The runtime-hook allocator (`gen/runtime.cpp`)

`getRuntimeFunction(Loc, Module &, const char *name)` (declared
`gen/runtime.h:30`, defined `gen/runtime.cpp:296`) is the single entry point for
obtaining an LLVM `Function*` for any `_d_*` compiler-support routine. The
mechanism is a lazy registry:

- A static registry of _lazy_ forward declarations is built once by
  `buildRuntimeModule()` (`gen/runtime.cpp:466`), each via `createFwdDecl(LINK,
returnType, {names…}, {paramTypes…}, …)` (`gen/runtime.cpp:276`). The closure
  allocator is registered there:

  ```cpp
  // gen/runtime.cpp:599-600
    // void* _d_allocmemory(size_t sz)
    createFwdDecl(LINK::c, voidPtrTy, {"_d_allocmemory"}, {sizeTy});
  ```

  alongside `_d_allocmemoryT` (`:603`), `_d_newclass` (`:619`), etc.

- `createFwdDecl` stores a `LazyFunctionDeclarer` keyed by name
  (`gen/runtime.cpp:271,288-289`). The first `getRuntimeFunction` call
  materializes the declaration into the runtime module (`:303-314`) and then
  `getOrInsertFunction`s a matching declaration into the _target_ module with
  copied attributes/callconv (`:325-329`).
- `LazyFunctionDeclarer::declare` (`gen/runtime.cpp:236`) builds a `TypeFunction`,
  calls `DtoType(dty)` to get the `llvm::FunctionType`, applies ABI param attrs
  (`:253-255`), and creates the function (`:257-265`).
- `getRuntimeFunction` also fires `checkForImplicitGCCall(loc, name)`
  (`gen/runtime.cpp:298`) — relevant to `-betterC` / `@nogc` interaction for a
  coroutine allocator hook (see [attributes & memory][attributes]).

The registered allocation hooks are enumerated near the top:
`gen/runtime.cpp:66-67` `"_d_allocmemory", "_d_allocmemoryT",`.

**Adding the coroutine allocator.** To introduce `_d_coro_alloc(size_t) ->
void*` and `_d_coro_free(void*)`, add two `createFwdDecl(LINK::c, …)` lines in
`buildRuntimeModule()` and call `getRuntimeFunction(loc, module,
"_d_coro_alloc")` at the coroutine prologue — exactly mirroring the
`_d_allocmemory` use in `gen/nested.cpp:494`. The frame size comes from
`llvm.coro.size.i64` and the alignment from `llvm.coro.align.i64`. The two paths
are:

```text
begin:  coro.id → coro.size → coro.alloc (branch) → _d_coro_alloc → coro.begin
end:    coro.free → _d_coro_free
```

Routing the frame through the GC (`_d_allocmemory`) is the simplest correct
default; a dedicated `_d_coro_alloc` is the hook for a custom (e.g. pooled or
`@nogc`) allocator later. The `coro.alloc` branch lets `CoroSplit` elide the heap
allocation entirely when the coroutine is provably eliminable.

---

## 5. The optimizer pipeline — `Coro*` passes already present

`gen/optimizer.cpp` drives the new-PM pipeline. `runOptimizationPasses`
(`gen/optimizer.cpp:413`) constructs an LLVM `PassBuilder` (`:447`) and selects a
_standard_ pipeline builder by optimization level and LTO mode:

```cpp
// gen/optimizer.cpp:527-558 (abridged)
  if (optLevelVal == 0) {
    ...
    mpm = pb.buildO0DefaultPipeline(level, ltoPrelink);
  } else if (opts::ltoFatObjects && opts::isUsingLTO()) {
    mpm = pb.buildFatLTODefaultPipeline(level, ...);
  } else if (opts::isUsingThinLTO()) {
    mpm = pb.buildThinLTOPreLinkDefaultPipeline(level);
  } else if (opts::isUsingLTO()) {
    mpm = pb.buildLTOPreLinkDefaultPipeline(level);
  } else {
    mpm = pb.buildPerModuleDefaultPipeline(level);
  }
```

**Every one of these builders embeds the coroutine passes.** At `-O1..-O3`,
`buildPerModuleDefaultPipeline` runs `CoroEarlyPass`, a CGSCC `CoroSplitPass` +
`CoroAnnotationElidePass`, a `CoroElidePass` in the function-simplification
pipeline, and a trailing `CoroCleanupPass` (`PassBuilderPipelines.cpp:1162`,
`:1055-1056`, `:1106-1108`, `:607`, `:822`, `:1334`). At LDC's **default `-O0`**,
`buildO0DefaultPipeline` ends with `MPM.addPass(buildCoroWrapper(Phase));`
(`PassBuilderPipelines.cpp:2490`), and `buildCoroWrapper` is:

```cpp
// PassBuilderPipelines.cpp:475-485
static CoroConditionalWrapper buildCoroWrapper(ThinOrFullLTOPhase Phase) {
  // TODO: Skip passes according to Phase.
  ModulePassManager CoroPM;
  CoroPM.addPass(CoroEarlyPass());
  CGSCCPassManager CGPM;
  CGPM.addPass(CoroSplitPass());
  CoroPM.addPass(createModuleToPostOrderCGSCCPassAdaptor(std::move(CGPM)));
  CoroPM.addPass(CoroCleanupPass());
  CoroPM.addPass(GlobalDCEPass());
  return CoroConditionalWrapper(std::move(CoroPM));
}
```

The LTO pipelines also include `CoroSplit`/`CoroCleanup`
(`PassBuilderPipelines.cpp:1845-1848,2213-2214,2366`). The wrapper is **gated on
coro-intrinsic presence**, so it is a no-op for ordinary D code and
self-activates when `llvm.coro.*` appear:

```cpp
// llvm/lib/Transforms/Coroutines/CoroConditionalWrapper.cpp:18-23
PreservedAnalyses CoroConditionalWrapper::run(Module &M,
                                              ModuleAnalysisManager &AM) {
  if (!coro::declaresAnyIntrinsic(M))
    return PreservedAnalyses::all();

  return PM.run(M, AM);
}
```

`coro::declaresAnyIntrinsic` checks for `coro_id`, `coro_id_retcon`,
`coro_id_retcon_once`, `coro_id_async`, etc. (the intrinsic switch in
`llvm/lib/Transforms/Coroutines/CoroEarly.cpp:142-156,194-195`).

> [!NOTE]
> **Conclusion (high confidence): LDC needs zero optimizer-pipeline changes to
> lower coroutines.** The moment a D module emits `llvm.coro.id` (and friends),
> `CoroSplit` runs — even at `-O0`. The only caveat: at `-O0`, `CoroSplitPass` is
> constructed with `OptimizeFrame=false`, so the frame layout is unoptimized
> (larger) but still correct.

### 5.1 LDC's own passes and the `GarbageCollect2Stack` caveat

`gen/passes/` contains D-specific, _non-coroutine_ passes:
`DLLImportRelocation.cpp`, `GarbageCollect2Stack.{cpp,h}`,
`SimplifyDRuntimeCalls.{cpp,h}`, `StripExternals.{cpp,h}` (create-functions
declared `gen/passes/Passes.h:22-28`). They are registered as extension-point
callbacks in `optimizer.cpp`: `addSimplifyDRuntimeCallsPass` (`:306`, O2/O3),
`addGarbageCollect2StackPass` (`:321`, O2/O3), `addStripExternalsPass`
(`:289`, O1-O3).

> [!WARNING]
> **`GarbageCollect2Stack` interacts with `_d_allocmemory`.** It promotes GC
> allocations to stack allocations. If a coroutine frame is GC-allocated via
> `_d_allocmemory`, this pass could in principle try to stack-promote a frame
> that must outlive its enclosing call. It is registered at the OptimizerLast
> extension point (`registerOptimizerLastEPCallback`, `optimizer.cpp:508`),
> whereas `CoroSplit` runs in the CGSCC inliner pipeline / coro wrapper. Their
> ordering relative to `CoroSplit` needs validation, and a dedicated
> `_d_coro_alloc` hook (which `GarbageCollect2Stack` does not recognize) sidesteps
> the risk entirely. **Open question.**

### 5.2 `callOrInvoke` and the `[Throws]` coro intrinsics

`callOrInvoke` (`gen/funcgenstate.cpp:106`) chooses `call` vs `invoke` based on
active EH cleanups. Because `llvm.coro.resume` and `llvm.coro.destroy` are marked
`[Throws]` (`Intrinsics.td:1941-1942`), they correctly become `invoke`s through
this path when emitted inside a `try`/`catch` scope — LDC's existing EH machinery
handles them with no special casing. The transient-state objects involved are
`IRState` (`gen/irstate.h:109`, owns the IRBuilder, the `funcGenStates` stack,
and `CreateCallOrInvoke` overloads at `:185-200`) and `FuncGenState`
(`gen/funcgenstate.h:168`, owning `allocasBlock` `:192`, `nestedVar` `:195`,
`retBlock` `:198`, and `callOrInvoke` `:206`). The C++-side intrinsic-emission
helper is `GET_INTRINSIC_DECL(_X, _TY)` (`gen/llvm.h:38-47`), e.g.
`GET_INTRINSIC_DECL(coro_size, {i64Ty})`.

---

## 6. Two insertion strategies

There are two viable ways to get `coro.id/begin/suspend/end` into the IR, both
backed by existing infrastructure.

|                                | **(A) Library via pragma**                                                         | **(B) Glue-layer emission**                                                 |
| ------------------------------ | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Where the intrinsics originate | D library code calls `pragma(LDC_intrinsic, …)` decls (or `inlineIR`)              | `DtoDefineFunction` + `statements.cpp` emit them in C++                     |
| Compiler change                | **None**                                                                           | New `STC`/UDA recognition + emission code                                   |
| Suspend point                  | An intrinsic call expression, lowered free by `toir.cpp` (§1.2)                    | A `yield`/`await` statement visitor                                         |
| `token` handling               | via `inlineIREx` raw-IR (§2.3)                                                     | native (`token` `llvm::Value*` in C++)                                      |
| Frame allocation               | `_d_allocmemory` / `_d_coro_alloc` arranged by the library                         | routed through the same hook in the prologue                                |
| Mirrors                        | Clang's `co_await` (frontend emits raw intrinsics; `CoroSplit` builds the machine) | LDC's own `va_start`/`va_end` prologue/epilogue (`functions.cpp:1259-1282`) |
| Effort / risk                  | Lowest                                                                             | Higher, but tighter D-scope/GC integration                                  |

**Recommendation: prototype with (A), graduate to (B)/frontend.** Strategy (A)
requires the least new glue and matches both LDC's existing `_d_*` lowering
practice (§7) and Clang's `co_await` lowering — get a working stackless coroutine
end-to-end, validate the `CoroSplit` interaction and the `-O0` frame correctness,
and exercise the wasm target ([wasm & WasmFX][wasm]) before committing to syntax.
Then graduate to (B) — explicit `coro.id`/`begin` after the nested-context setup
(alongside the `va_start` block at `gen/functions.cpp:1259`), `coro.suspend` at
each yield, and `coro.end` in the implicit-return/cleanup epilogue
(`:1290-1323`) via `pushCleanup` — once frame allocation must integrate with D's
GC/scope semantics. The [roadmap][roadmap] sequences these phases.

---

## 7. Frontend lowering vs. glue emission

The DMD frontend already performs **AST-level lowering to `_d_*` runtime-hook
calls** for several constructs — `dmd/expressionsem.d:2597,2611-2615` enumerate
`_d_newitemT`, `_d_newarrayT`, `_d_arrayappendT`, `_d_arraycatnTX`,
`_d_newclassT`, `_d_assocarrayliteralTX`, `_d_arrayliteralTX`, `_d_aaGetY`, and
`dmd/expressionsem.d:4077` lowers `CastExp → object._d_cast`. This is the
precedent that **D constructs can be rewritten in the frontend into ordinary
calls to magic library functions**, which the glue layer then emits normally.

For coroutines this yields two clean designs that bracket strategies (A) and (B):

- **Frontend-lowering design.** A `yield`/`await` (or a generator-function
  attribute) is lowered in `semantic` to calls into a druntime template library
  (`core.coroutine` or similar) whose functions are `pragma(LDC_intrinsic,
"llvm.coro.…")`. The glue layer needs _no_ special code — it already lowers the
  intrinsic calls (§1.2, §2.1), and `CoroSplit` (§5) does the rest. **Lowest
  risk; matches existing `_d_*` lowering and C++ `co_await`.**
- **Glue-layer design.** A function flagged as a coroutine gets explicit
  `coro.id/begin/suspend/end` emission inside `DtoDefineFunction` and
  `statements.cpp`, reusing the `va_start`/`va_end` prologue/epilogue + cleanup
  pattern (`gen/functions.cpp:1259-1282`, `emitDMDStyleFunctionTrace` at `:861`).
  More invasive, but allows tight integration with D scope/destruction and the
  GC.

The [language-design][d-design] doc weighs the surface-syntax question that
feeds both; this doc establishes that _either_ terminates in the same small set
of `llvm.coro.*` emissions, and that the lowest-risk first cut needs no compiler
patch at all.

---

## Open questions

- **`token`-type representation.** The clean long-term answer (a frontend opaque
  `token` mapping) vs. the immediate workaround (`inlineIREx` raw-IR, §2.3) is
  unresolved. The workaround is sufficient for a prototype.
- **`GarbageCollect2Stack` × `CoroSplit` ordering** (§5.1) — whether a
  GC-allocated coroutine frame can be wrongly stack-promoted, and whether a
  dedicated `_d_coro_alloc` is therefore mandatory rather than merely preferable.
- **WasmFX vs. stackless on wasm.** This LLVM tree has **no** native WasmFX /
  wasm stack-switching backend, so the _stackless_ `llvm.coro.*` + `CoroSplit`
  path is the only one viable today on wasm; a stackful/WasmFX path is
  upstream-LLVM-blocked. See [wasm & WasmFX][wasm] and the algebraic-effects
  [WasmFX deep-dive][wasmfx].

---

## Sources

- LDC v1.42 (`$REPOS/dlang/ldc`): `gen/functions.cpp`,
  `gen/statements.cpp`, `gen/toir.cpp`, `gen/tocall.cpp`, `gen/pragma.cpp`,
  `gen/dpragma.d`, `gen/inlineir.cpp`, `gen/nested.cpp`, `gen/runtime.cpp`,
  `gen/runtime.h`, `gen/optimizer.cpp`, `gen/llvmhelpers.cpp`, `gen/irstate.cpp`,
  `gen/irstate.h`, `gen/funcgenstate.h`, `gen/funcgenstate.cpp`, `gen/llvm.h`,
  `gen/abi/abi.cpp`, `gen/passes/Passes.h`,
  `runtime/druntime/src/ldc/intrinsics.di`.
- DMD frontend (`$REPOS/dlang/ldc/dmd`): `expressionsem.d`.
- LLVM 23.0.0git (`$REPOS/llvm-project`):
  `llvm/include/llvm/IR/Intrinsics.td`,
  `llvm/lib/Passes/PassBuilderPipelines.cpp`,
  `llvm/lib/Transforms/Coroutines/CoroConditionalWrapper.cpp`,
  `llvm/lib/Transforms/Coroutines/CoroEarly.cpp`, `llvm/docs/Coroutines.rst`.

<!-- References -->

[llvm-coroutines]: ./llvm-coroutines.md
[llvm-internals]: ./llvm-coro-internals.md
[d-design]: ./d-language-design.md
[attributes]: ./attributes-and-memory.md
[wasm]: ../wasm-and-wasmfx.md
[roadmap]: ./roadmap.md
[wasmfx]: ../../algebraic-effects/wasmfx.md

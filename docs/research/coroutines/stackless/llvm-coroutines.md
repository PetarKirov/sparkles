# LLVM's Coroutine Model and Intrinsic Surface

The deep-dive on the mechanism that LDC would target. LLVM coroutines are ordinary functions sprinkled with `llvm.coro.*` intrinsics that the middle-end splits into a ramp function plus resume/destroy clones, with cross-suspend state spilled into a heap-or-elided coroutine frame. This document reads the LLVM 23 specification (`llvm/docs/Coroutines.rst`) and the intrinsic definitions (`llvm/include/llvm/IR/Intrinsics.td`) end to end: the three lowering ABIs, the full intrinsic catalog (documented and not), the worked switched-resume transformation, heap-allocation elision, exception-handling integration, custom-ABI plugins, and what all of this implies for a D frontend. It is the IR contract every later document in this survey ([ldc-codegen], [llvm-internals], [comparison]) builds on.

**Last reviewed:** June 4, 2026

---

> [!WARNING]
> **The LLVM coroutine IR contract is not stable across releases.** The first substantive line of the spec is a compatibility warning (`Coroutines.rst:9-10`):
>
> > ".. warning:: Compatibility across LLVM releases is not guaranteed."
>
> This is load-bearing for any frontend. The intrinsic signatures, the frame ABI, the switch-edge encoding, and the set of intrinsics that even exist can all change between LLVM versions. LDC v1.42 pins **LLVM 23.0.0git**; every signature, line number, and quote in this document is verified against that checkout. Re-validate against the actual LLVM that LDC links before relying on any of it — especially the undocumented intrinsics flagged in [§ Undocumented intrinsics](#undocumented-intrinsics-flag).

## The core mental model

A coroutine, in LLVM, is a function that can suspend and later resume. The spec's opening (`Coroutines.rst:17-20`):

> "LLVM coroutines are functions that have one or more `suspend points`. When a suspend point is reached, the execution of a coroutine is suspended and control is returned back to its caller. A suspended coroutine can be resumed to continue execution from the last suspend point or it can be destroyed."

The state that must outlive a suspension lives in the **coroutine frame** (`Coroutines.rst:38-45`):

> "there is an additional region of storage that contains objects that keep the coroutine state when a coroutine is suspended. This region of storage is called the **coroutine frame**. It is created when a coroutine is called and destroyed when a coroutine either runs to completion or is destroyed while suspended."

The frame is the _stackless_ part: instead of parking an entire OS/fiber stack (the model D's `core.thread.fiber` uses today — see [d-fiber]), the compiler computes exactly which values cross a suspend point and stores _only those_ in a flat heap allocation. This is the central distinction the whole survey turns on; [concepts] develops it, and [comparison] tabulates the trade-offs against the stackful fiber baseline.

### The split model

Every LLVM coroutine starts life as a perfectly ordinary function carrying coroutine intrinsics, and is rewritten by the lowering passes (`Coroutines.rst:52-62`):

> "an LLVM coroutine is initially represented as an ordinary LLVM function that has calls to `coroutine intrinsics` defining the structure of the coroutine. The coroutine function is then, in the most general case, rewritten by the coroutine lowering passes to become the "ramp function", the initial entrypoint of the coroutine, which executes until a suspend point is first reached. The remainder of the original coroutine function is split out into some number of "resume functions". Any state which must persist across suspensions is stored in the coroutine frame. The resume functions must somehow be able to handle either a "normal" resumption, which continues the normal execution of the coroutine, or an "abnormal" resumption, which must unwind the coroutine without attempting to suspend it."

So the frontend emits one function; the middle-end produces a **ramp** (runs to the first suspend, returns to the caller) plus **resume** clones (re-enter at later suspend points), with abnormal resumption used to unwind on destruction. The mechanics of _how_ CoroSplit performs this rewrite are the subject of [llvm-internals]; this document is concerned with the _contract_ a frontend must satisfy.

> [!NOTE]
> **Doc bug: "two styles" vs. three ABIs.** The spec body claims "LLVM currently supports two styles of coroutine lowering" (`Coroutines.rst:47`), but the sections that follow document **three** distinct ABIs — Switched-Resume, Returned-Continuation (itself with two variants, `retcon` and `retcon.once`), and Async. The "two styles" wording is stale. Treat it as a documentation bug and rely on the three-ABI taxonomy below.

---

## The three lowering ABIs

The ABI is selected by _which `coro.id` flavor_ the frontend uses. Each has a different notion of who owns the frame, how resumption is expressed, and which real-world frontend drives it.

| ABI                       | Signaling intrinsic                    | Frame ownership                                                                     | Resume mechanism                                                                                                                        | Real users                                                                                                                |
| ------------------------- | -------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Switched-Resume**       | `llvm.coro.id`                         | Heap-allocated (frontend `malloc`) or elided onto caller's stack                    | Opaque handle; `coro.resume`/`coro.destroy` dispatch through fn-ptrs stored at fixed frame offsets, switching on a stored suspend index | C++20 coroutines (Clang); the `coro.await.suspend.*` intrinsics _are_ the C++ `co_await` lowering (`Coroutines.rst:1921`) |
| **Returned-Continuation** | `llvm.coro.id.retcon` / `.retcon.once` | Caller-provided **fixed-size buffer** (spills to a frontend allocator if too small) | Suspend _returns_ a continuation function pointer + yielded values; caller resumes by calling the pointer                               | Swift `yield`-based accessor coroutines (`read`/`modify`)                                                                 |
| **Async**                 | `llvm.coro.id.async`                   | Caller-allocated **async context**; frame appended as a tail                        | `musttail` transfer to a callee at suspend; per-suspend resume function via `coro.async.resume`; `swiftcc`                              | Swift Concurrency (`async`/`await`)                                                                                       |

### Switched-Resume — `llvm.coro.id`

The default, "handle-based" model (`Coroutines.rst:64-72`):

> "In LLVM's standard switched-resume lowering, signaled by the use of `llvm.coro.id`, the coroutine frame is stored as part of a "coroutine object" which represents a handle to a particular invocation of the coroutine. All coroutine objects support a common ABI allowing certain features to be used without knowing anything about the coroutine's implementation"

Four common operations work on the opaque handle without knowing the coroutine's body (`Coroutines.rst:74-87`): query completion with `llvm.coro.done`; resume with `llvm.coro.resume`; destroy with `llvm.coro.destroy` ("This must be done separately even if the coroutine has reached completion normally"); and project promise storage with `llvm.coro.promise`. Touching the handle while the coroutine runs is undefined (`Coroutines.rst:89-90`):

> "In general, interacting with a coroutine object in any of these ways while it is running has undefined behavior."

The coroutine splits into **three** functions (`Coroutines.rst:92-103`): the _ramp_ ("takes arbitrary arguments and returns a pointer to the coroutine object"), the _resume_ function ("takes a pointer to the coroutine object and returns `void`"), and the _destroy_ function (likewise `void`). The name comes from how those shared functions re-enter the right place (`Coroutines.rst:105-109`):

> "Because the resume and destroy functions are shared across all suspend points, suspend points must store the index of the active suspend in the coroutine object, and the resume/destroy functions must switch over that index to get back to the correct point. Hence the name of this lowering."

The resume and destroy function pointers live "at known offsets which are fixed for all coroutines. A completed coroutine is represented with a null resume function" (`Coroutines.rst:111-113`). Allocation goes through "a somewhat complex protocol of intrinsics ... complex in order to allow the allocation to be elided due to inlining" (`Coroutines.rst:115-118`) — see [§ Heap-allocation elision](#heap-allocation-elision). The frontend calls the coroutine like any function and treats the result as a handle (`Coroutines.rst:120-123`):

> "The frontend may generate code to call the coroutine function directly; this will become a call to the ramp function and will return a pointer to the coroutine object. The frontend should always resume or destroy the coroutine using the corresponding intrinsics."

This is the turnkey path: LLVM owns the frame layout, the allocation protocol, and the resume dispatch. It is the model behind Clang's C++20 coroutines (see [cpp]) and the most natural fit for a _general_ D coroutine surface.

### Returned-Continuation — `llvm.coro.id.retcon` / `.retcon.once`

Here the frontend takes on more of the ABI (`Coroutines.rst:128-137`):

> "In returned-continuation lowering, signaled by the use of `llvm.coro.id.retcon` or `llvm.coro.id.retcon.once`, some aspects of the ABI must be handled more explicitly by the frontend. In this lowering, every suspend point takes a list of "yielded values" which are returned back to the caller along with a function pointer, called the continuation function. The coroutine is resumed by simply calling this continuation function pointer."

There is no opaque handle and no fixed-offset fn-ptr table — _suspending returns the continuation directly_. Two variants (`Coroutines.rst:142-155`):

- **Normal `retcon` (multi-suspend):** "the coroutine may suspend itself multiple times. This means that a continuation function itself returns another continuation pointer, as well as a list of yielded values." Completion is signaled by "returning a null continuation pointer."
- **Yield-once `retcon.once`:** "the coroutine must suspend itself exactly once (or throw an exception). The ramp function returns a continuation function pointer and yielded values, the continuation function may optionally return ordinary results when the coroutine has run to completion."

The frame lives in a caller-provided buffer (`Coroutines.rst:157-164`):

> "The coroutine frame is maintained in a fixed-size buffer that is passed to the `coro.id` intrinsic, which guarantees a certain size and alignment statically. The same buffer must be passed to the continuation function(s). The coroutine will allocate memory if the buffer is insufficient, in which case it will need to store at least that pointer in the buffer; therefore, the buffer must always be at least pointer-sized."

The frontend supplies allocator/deallocator functions (arguments 5 and 6 of `coro.id.retcon`); continuation functions take, besides the buffer, "an argument indicating whether the coroutine is being resumed normally (zero) or abnormally (non-zero)" (`Coroutines.rst:166-168`). One caveat is decisive for `@nogc`/no-malloc ambitions (`Coroutines.rst:170-174`):

> "LLVM is currently ineffective at statically eliminating allocations after fully inlining returned-continuation coroutines into a caller. This may be acceptable if LLVM's coroutine support is primarily being used for low-level lowering and inlining is expected to be applied earlier in the pipeline."

So `retcon` _avoids the implicit `malloc`_ (the buffer is caller-owned) but _weakens post-inlining elision_. This is the lowering most analogous to a low-level "split here, hand me a continuation" primitive, and it is attractive for D generators where the caller can stack-allocate the buffer.

### Async — `llvm.coro.id.async`

The model behind Swift Concurrency, where control flow is the frontend's job (`Coroutines.rst:179-185`):

> "In async-continuation lowering, signaled by the use of `llvm.coro.id.async`, handling of control-flow must be handled explicitly by the frontend. In this lowering, a coroutine is assumed to take the current `async context` as one of its arguments (the argument position is determined by `llvm.coro.id.async`). It is used to marshal arguments and return values of the coroutine. Therefore, an async coroutine returns `void`."

The shape carries `swiftcc` (`Coroutines.rst:189`):

```llvm
define swiftcc void @async_coroutine(ptr %async.ctxt, ptr, ptr) {
}
```

The frame is **appended to the caller-allocated async context** (`Coroutines.rst:192-194`): "Values live across a suspend point need to be stored in the coroutine frame ... This frame is stored as a tail to the `async context`." The frontend allocates that context (`Coroutines.rst:229-230`: "The frontend is responsible for allocating the memory for the `async context`"), and lowering grows the context size to fit the frame, writing the new size into the _async function pointer_ struct (`Coroutines.rst:224-237`):

```c
struct async_function_pointer {
  uint32_t relative_function_pointer_to_async_impl;
  uint32_t context_size;
}
```

Lowering "will split an async coroutine into a ramp function and one resume function per suspend point" (`Coroutines.rst:239-240`), and crucially "How control-flow is passed between caller, suspension point, and back to resume function is left up to the frontend" (`Coroutines.rst:242-243`). Suspension is a tail-call transfer (`Coroutines.rst:245-248`):

> "The suspend point takes a function and its arguments. The function is intended to model the transfer to the callee function. It will be tail called by lowering and therefore must have the same signature and calling convention as the async coroutine."

This caller-allocated-context + `musttail`-transfer-at-suspend + one-resume-fn-per-suspend shape is the closest LLVM analogue to wasm's `cont`/`resume`/`suspend` stack-switching primitive — see [wasm] and [wasmfx]. It is the most interesting ABI for executor-hopping and WasmFX-adjacent lowering, at the cost of the frontend owning nearly all the plumbing.

---

## The `llvm.coro.*` intrinsic catalog

The `.td` comment ties the surface to the spec (`Intrinsics.td:1870-1871`): "// Coroutine Intrinsics. // These are documented in docs/Coroutines.rst". The `.td` groups them as _Structure_ (line 1873), _Manipulation_ (1939), and "Coroutine Lowering Intrinsics. Used internally by coroutine passes" (1962); the `.rst` uses the _opposite_ grouping order and a slightly different partition — the `.rst` puts `coro.id`/`coro.begin`/etc. under "Structure" and `resume`/`destroy`/`done`/`promise` under "Manipulation." The tables below follow the `.rst` partition.

### Manipulation intrinsics

Usable wherever a frame or promise pointer is in hand, even outside a coroutine (`Coroutines.rst:841-843`):

| Intrinsic           | Signature (`.rst`)                                                       | `.td` definition                                                                                                  | Semantics                                                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `llvm.coro.destroy` | `void @llvm.coro.destroy(ptr <handle>)` (`:855`)                         | `Intrinsic<[], [llvm_ptr_ty], [Throws]>` (`:1942`)                                                                | Destroys a _suspended_ switched-resume coroutine. "Destroying a coroutine that is not suspended leads to undefined behavior" (`:874`); "implies `coro.dead`" (`:876`). |
| `llvm.coro.resume`  | `void @llvm.coro.resume(ptr <handle>)` (`:885`)                          | `Intrinsic<[], [llvm_ptr_ty], [Throws]>` (`:1941`)                                                                | Resumes a suspended switched-resume coroutine. "Resuming a coroutine that is not suspended leads to undefined behavior" (`:903`).                                      |
| `llvm.coro.done`    | `i1 @llvm.coro.done(ptr <handle>)` (`:912`)                              | `Intrinsic<[llvm_i1_ty],[llvm_ptr_ty],[IntrArgMemOnly, ReadOnly<ArgIndex<0>>, NoCapture<ArgIndex<0>>]>` (`:1943`) | True iff a suspended coroutine sits at its `final suspend`. UB if there is no final suspend or it is not suspended (`:928`).                                           |
| `llvm.coro.promise` | `ptr @llvm.coro.promise(ptr <ptr>, i32 <alignment>, i1 <from>)` (`:938`) | `Intrinsic<[llvm_ptr_ty],[llvm_ptr_ty, llvm_i32_ty, llvm_i1_ty],[IntrNoMem, NoCapture<ArgIndex<0>>]>` (`:1946`)   | Maps handle↔promise pointer. `from=false`: handle→promise; `from=true`: promise→handle. `alignment` and `from` must be constants (`:957,962`).                         |

### Structure intrinsics

Only valid inside a coroutine body (`Coroutines.rst:1004-1005`):

| Intrinsic                        | Signature (`.rst`)                                                                                                                      | `.td` definition                                                                                                                                                                                            | Semantics                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `llvm.coro.size.i32/.i64`        | `iN @llvm.coro.size.iN()` (`:1013-1014`)                                                                                                | `Intrinsic<[llvm_anyint_ty],[],[IntrNoMem]>` (`:1926`)                                                                                                                                                      | Bytes for the frame; switched-resume only; lowered to a constant (`:1019,1031`).                                                                                                                                                                                                                                                                                                                                                                      |
| `llvm.coro.align.i32/.i64`       | `iN @llvm.coro.align.iN()` (`:1040-1041`)                                                                                               | `Intrinsic<[llvm_anyint_ty],[],[IntrNoMem]>` (`:1927`)                                                                                                                                                      | Frame alignment; switched-resume only; lowered to a constant (`:1046,1057`).                                                                                                                                                                                                                                                                                                                                                                          |
| `llvm.coro.begin`                | `ptr @llvm.coro.begin(token <id>, ptr <mem>)` (`:1066`)                                                                                 | `Intrinsic<[llvm_ptr_ty],[llvm_token_ty, llvm_ptr_ty],[WriteOnly<ArgIndex<1>>]>` (`:1907`)                                                                                                                  | Returns the frame address; arg2 is memory for a dynamic frame ("ignored for returned-continuation coroutines" `:1081`); the returned ptr may be offset from `%mem` (`:1086-1090`); "exactly one `coro.begin` per coroutine" (`:1092`).                                                                                                                                                                                                                |
| `llvm.coro.begin.custom.abi`     | `ptr @llvm.coro.begin.custom.abi(token <id>, ptr <mem>, i32)` (`:1100`)                                                                 | `Intrinsic<[llvm_ptr_ty],[llvm_token_ty, llvm_ptr_ty, llvm_i32_ty],[WriteOnly<ArgIndex<1>>]>` (`:1909`)                                                                                                     | Like `coro.begin` plus an i32 index into CoroSplit's generator list selecting the custom ABI (`:1116-1117`).                                                                                                                                                                                                                                                                                                                                          |
| `llvm.coro.free`                 | `ptr @llvm.coro.free(token %id, ptr <frame>)` (`:1130`)                                                                                 | `Intrinsic<[llvm_ptr_ty],[llvm_token_ty, llvm_ptr_ty],[IntrReadMem, IntrArgMemOnly, ReadOnly<ArgIndex<1>>, NoCapture<ArgIndex<1>>]>` (`:1912`)                                                              | Returns the frame-memory pointer to free, or `null` if the frame was not dynamically allocated; "not supported for returned-continuation coroutines" (`:1138`).                                                                                                                                                                                                                                                                                       |
| `llvm.coro.dead`                 | `void @llvm.coro.dead(ptr <frame>)` (`:1180`)                                                                                           | `Intrinsic<[], [llvm_ptr_ty], [IntrNoMem]>` (`:1916`)                                                                                                                                                       | HALO hint marking the end of frame lifetime so coroutines _not_ destroyed via `coro.destroy` can still be elided (`:1185,1197`).                                                                                                                                                                                                                                                                                                                      |
| `llvm.coro.alloc`                | `i1 @llvm.coro.alloc(token <id>)` (`:1222`)                                                                                             | `Intrinsic<[llvm_i1_ty], [llvm_token_ty], []>` (`:1887`)                                                                                                                                                    | True iff a dynamic allocation is needed; "not supported for returned-continuation coroutines" (`:1229`); "at most one ... per coroutine" (`:1240`).                                                                                                                                                                                                                                                                                                   |
| `llvm.coro.noop`                 | `ptr @llvm.coro.noop()` (`:1269`)                                                                                                       | `Intrinsic<[llvm_ptr_ty], [], [IntrNoMem]>` (`:1925`)                                                                                                                                                       | Frame of a do-nothing coroutine (empty resume/destroy). "in different translation units llvm.coro.noop may return different pointers" (`:1287`).                                                                                                                                                                                                                                                                                                      |
| `llvm.coro.frame`                | `ptr @llvm.coro.frame()` (`:1295`)                                                                                                      | `Intrinsic<[llvm_ptr_ty], [], [IntrNoMem]>` (`:1922`)                                                                                                                                                       | Frontend convenience; lowered to the enclosing `coro.begin` (`:1311`).                                                                                                                                                                                                                                                                                                                                                                                |
| `llvm.coro.id`                   | `token @llvm.coro.id(i32 <align>, ptr <promise>, ptr <coroaddr>, ptr <fnaddrs>)` (`:1321`)                                              | `DefaultAttrsIntrinsic<[llvm_token_ty],[llvm_i32_ty, llvm_ptr_ty, llvm_ptr_ty, llvm_ptr_ty],[IntrArgMemOnly, IntrReadMem, ReadNone<ArgIndex<1>>, ReadOnly<ArgIndex<2>>, NoCapture<ArgIndex<2>>]>` (`:1875`) | Identifies a switched-resume coroutine. arg1 align (0 ⇒ `2*sizeof(ptr)`); arg2 promise alloca; arg3 null from the frontend (CoroEarly sets it to the function); arg4 null pre-split, replaced with a global array of `{resume,destroy}` fn-ptrs (`:1333-1346`). Ties id/alloc/begin together to block duplication (`:1352-1355`). "exactly one `coro.id` per coroutine" + emit `presplitcoroutine` (`:1357-1359`).                                    |
| `llvm.coro.id.async`             | `token @llvm.coro.id.async(i32 <context size>, i32 <align>, ptr <context arg>, ptr <async function pointer>)` (`:1367`)                 | `Intrinsic<[llvm_token_ty],[llvm_i32_ty, llvm_i32_ty, llvm_i32_ty, llvm_ptr_ty],[]>` (`:1888`)                                                                                                              | Identifies an async coroutine. arg1 initial async-context size (lowering adds the frame size), arg2 align, arg3 the context arg, arg4 the address of the async-function-pointer struct whose size field lowering updates (`:1379-1392`).                                                                                                                                                                                                              |
| `llvm.coro.id.retcon`            | `token @llvm.coro.id.retcon(i32 <size>, i32 <align>, ptr <buffer>, ptr <continuation prototype>, ptr <alloc>, ptr <dealloc>)` (`:1408`) | `Intrinsic<[llvm_token_ty],[llvm_i32_ty, llvm_i32_ty, llvm_ptr_ty, llvm_ptr_ty, llvm_ptr_ty, llvm_ptr_ty],[]>` (`:1879`)                                                                                    | Multi-suspend retcon. The "result-type sequence": void ⇒ empty; struct ⇒ element types; else ⇒ return type. First element must be ptr (continuation); the rest are yield types (`:1418-1431`). arg4 prototype defines the cc/attrs of continuations; arg5 alloc fn (int→ptr, may not fail); arg6 dealloc fn (ptr→void) (`:1439-1452`).                                                                                                                |
| `llvm.coro.id.retcon.once`       | `token @llvm.coro.id.retcon.once(i32 <size>, i32 <align>, ptr <buffer>, ptr <prototype>, ptr <alloc>, ptr <dealloc>)` (`:1463`)         | `Intrinsic<[llvm_token_ty],[llvm_i32_ty, llvm_i32_ty, llvm_ptr_ty, llvm_ptr_ty, llvm_ptr_ty, llvm_ptr_ty],[]>` (`:1883`)                                                                                    | Unique-suspend retcon. "As for llvm.core.id.retcon, except that the return type of the continuation prototype must represent the normal return type of the continuation (instead of matching the coroutine's return type)" (`:1476-1478`).                                                                                                                                                                                                            |
| `llvm.coro.end`                  | `void @llvm.coro.end(ptr <handle>, i1 <unwind>, token <result.token>)` (`:1491`)                                                        | `Intrinsic<[], [llvm_ptr_ty, llvm_i1_ty, llvm_token_ty], []>` (`:1917`)                                                                                                                                     | Marks the end of frame access. arg1 handle (the frontend may pass null; CoroEarly fills it `:1501-1504`); arg2 unwind flag; arg3 a non-none token only for `retcon.once` via `coro.end.results`; "Only none token is allowed for coro.end calls in unwind sections" (`:1510-1514`). See the [EH table](#coroend-and-exception-handling).                                                                                                              |
| `llvm.coro.end.results`          | `token @llvm.coro.end.results(...)` (`:1609`)                                                                                           | `Intrinsic<[llvm_token_ty], [llvm_vararg_ty]>` (`:1918`)                                                                                                                                                    | Captures the values returned from a `retcon.once` coroutine; arg count/types must match the continuation return type (`:1620-1628`).                                                                                                                                                                                                                                                                                                                  |
| `llvm.coro.end.async`            | `void @llvm.coro.end.async(ptr <handle>, i1 <unwind>, ...)` (`:1655`)                                                                   | `Intrinsic<[], [llvm_ptr_ty, llvm_i1_ty, llvm_vararg_ty], []>` (`:1919`)                                                                                                                                    | End of an async resume part; an optional trailing `(fn, args...)` is `musttail`-called as the last action before returning (`:1660-1682`).                                                                                                                                                                                                                                                                                                            |
| `llvm.coro.suspend`              | `i8 @llvm.coro.suspend(token <save>, i1 <final>)` (`:1699`)                                                                             | `Intrinsic<[llvm_i8_ty], [llvm_token_ty, llvm_i1_ty], []>` (`:1930`)                                                                                                                                        | Switched-resume suspend. The i8 result feeds a `switch`: **-1 (default) ⇒ suspend, 0 ⇒ resume, 1 ⇒ destroy** (`:1706-1708`, `:1748-1752`). arg1 a `coro.save` token or `none` (implicit save right before); arg2 the `final` flag (constant) (`:1713-1721`).                                                                                                                                                                                          |
| `llvm.coro.save`                 | `token @llvm.coro.save(ptr <handle>)` (`:1763`)                                                                                         | `Intrinsic<[llvm_token_ty], [llvm_ptr_ty], [IntrNoMerge]>` (`:1929`)                                                                                                                                        | Marks where state must become resumable (the resume index is stored). "It is illegal to merge two llvm.coro.save calls unless their llvm.coro.suspend users are also merged. So llvm.coro.save is currently tagged with the no_merge function attribute" (`:1770-1772`).                                                                                                                                                                              |
| `llvm.coro.suspend.async`        | `{ptr, ptr, ptr} @llvm.coro.suspend.async(...)` (`:1812`)                                                                               | `Intrinsic<[llvm_any_ty],[llvm_i32_ty, llvm_ptr_ty, llvm_ptr_ty, llvm_vararg_ty],[IntrNoMerge, IntrNoDuplicate]>` (`:1901`)                                                                                 | Async suspend = transfer to a callee. arg1 the result of `coro.async.resume`; arg2 a context-projection fn `ptr(ptr)`; arg3 the transfer fn (`musttail`-called, takes 3 args); arg4+ its args. Results map to resume-fn args (`:1827-1846`). The `.td` carries a leading `i32` not shown in the `.rst` signature.                                                                                                                                     |
| `llvm.coro.suspend.retcon`       | `i1 @llvm.coro.suspend.retcon(...)` (`:1874`)                                                                                           | `Intrinsic<[llvm_any_ty], [llvm_vararg_ty], []>` (`:1931`)                                                                                                                                                  | Retcon suspend. Arg types must exactly match the coroutine's yielded-type sequence; they become return values along with the next continuation (`:1891-1893`). The result is the abnormal-resume flag (non-zero) (`:1898`). **No separate save points** — "they are not useful when the continuation function is not locally accessible. That would be a more appropriate feature for a passcon lowering that is not yet implemented" (`:1883-1886`). |
| `llvm.coro.await.suspend.void`   | `void @llvm.coro.await.suspend.void(ptr <awaiter>, ptr <handle>, ptr <await_suspend_function>)` (`:1913`)                               | `Intrinsic<[],[llvm_ptr_ty, llvm_ptr_ty, llvm_ptr_ty],[Throws]>` (`:1950`)                                                                                                                                  | Encapsulates C++ `void awaiter.await_suspend(...)` between `coro.save`/`coro.suspend`; lowered to a direct call during CoroSplit (`:1921-1955`).                                                                                                                                                                                                                                                                                                      |
| `llvm.coro.await.suspend.bool`   | `i1 @llvm.coro.await.suspend.bool(ptr <awaiter>, ptr <handle>, ptr <await_suspend_function>)` (`:1995`)                                 | `Intrinsic<[llvm_i1_ty],[llvm_ptr_ty, llvm_ptr_ty, llvm_ptr_ty],[Throws]>` (`:1954`)                                                                                                                        | C++ `bool await_suspend` variant; if the wrapper returns true the coroutine is immediately resumed (`:2039-2040`).                                                                                                                                                                                                                                                                                                                                    |
| `llvm.coro.await.suspend.handle` | `void @llvm.coro.await.suspend.handle(ptr <awaiter>, ptr <handle>, ptr <await_suspend_function>)` (`:2085`)                             | `Intrinsic<[],[llvm_ptr_ty, llvm_ptr_ty, llvm_ptr_ty],[Throws]>` (`:1958`)                                                                                                                                  | C++ `std::coroutine_handle<> await_suspend` variant; the wrapper returns a frame ptr, lowered to a `musttail` `coro.resume`; following instructions become unreachable (`:2129-2132`).                                                                                                                                                                                                                                                                |
| `llvm.coro.is_in_ramp`           | `i1 @llvm.coro.is_in_ramp()` (`:2172`)                                                                                                  | `Intrinsic<[llvm_i1_ty], [], [IntrNoMem], "llvm.coro.is_in_ramp">` (`:1923`)                                                                                                                                | CoroSplit replaces it with `true` in the ramp and `false` in resume/destroy, letting the frontend separate ramp-only cleanup from resume/destroy cleanup (`:2188-2190`). Used in EH cleanup blocks with `coro.end` (`:1553`, `:1566-1569`).                                                                                                                                                                                                           |

The three `coro.await.suspend.*` intrinsics are explicitly the C++ `co_await await_suspend` lowering and exist primarily for Clang; [cpp] walks through how the C++ awaiter protocol maps onto them.

### Undocumented intrinsics (FLAG)

A meaningful subset of the intrinsics defined in `Intrinsics.td` have **no dedicated section in `Coroutines.rst`** (verified by grep — only incidental mentions). Their contract lives only in the `.td` plus the LLVM source. This is a real hazard for a frontend that relies on the spec.

> [!WARNING]
> **These coroutine intrinsics are present in LLVM 23's `Intrinsics.td` but undocumented in `Coroutines.rst`.** Their behavior is inferred from the `.td` signature and surrounding prose; confirm against the LLVM source before emitting them.
>
> | Intrinsic                         | `.td` definition                                                                                                                                        | Inferred role                                                                                                                                                                                                                    |
> | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
> | `llvm.coro.async.context.alloc`   | `Intrinsic<[llvm_ptr_ty],[llvm_ptr_ty, llvm_ptr_ty],[]>` (`:1891`)                                                                                      | Allocate an async context (async-fn-ptr struct + caller context).                                                                                                                                                                |
> | `llvm.coro.async.context.dealloc` | `Intrinsic<[], [llvm_ptr_ty], []>` (`:1894`)                                                                                                            | Deallocate an async context.                                                                                                                                                                                                     |
> | `llvm.coro.async.resume`          | `Intrinsic<[llvm_ptr_ty], [], [IntrNoMerge, IntrNoDuplicate]>` (`:1897`)                                                                                | Returns the resume-fn ptr for an async suspend (referenced in prose `:199,219,1827`, no own section); lowering replaces it with the real resume function.                                                                        |
> | `llvm.coro.async.size.replace`    | `Intrinsic<[], [llvm_ptr_ty, llvm_ptr_ty], []>` (`:1900`)                                                                                               | Patch one async-fn-ptr struct's context-size field from another's.                                                                                                                                                               |
> | `llvm.coro.prepare.async`         | `Intrinsic<[llvm_ptr_ty], [llvm_ptr_ty], [IntrNoMem]>` (`:1905`)                                                                                        | Blocks inlining of an async coroutine until after splitting; lowered to its argument (`:1854-1866`, _is_ documented).                                                                                                            |
> | `llvm.coro.prepare.retcon`        | `Intrinsic<[llvm_ptr_ty], [llvm_ptr_ty], [IntrNoMem]>` (`:1932`)                                                                                        | Retcon analog of `prepare.async`; **no `.rst` section at all**.                                                                                                                                                                  |
> | `llvm.coro.alloca.alloc`          | `Intrinsic<[llvm_token_ty],[llvm_anyint_ty, llvm_i32_ty], []>` (`:1934`)                                                                                | Dynamic alloca that may live across suspends (size, align) → token. **No `.rst` section.**                                                                                                                                       |
> | `llvm.coro.alloca.get`            | `Intrinsic<[llvm_ptr_ty], [llvm_token_ty], []>` (`:1936`)                                                                                               | Get the pointer for a `coro.alloca.alloc` token. **No `.rst` section.**                                                                                                                                                          |
> | `llvm.coro.alloca.free`           | `Intrinsic<[], [llvm_token_ty], []>` (`:1937`)                                                                                                          | Free a `coro.alloca.alloc`. **No `.rst` section.**                                                                                                                                                                               |
> | `llvm.coro.subfn.addr`            | `DefaultAttrsIntrinsic<[llvm_ptr_ty],[llvm_ptr_ty, llvm_i8_ty],[IntrReadMem, IntrArgMemOnly, ReadOnly<ArgIndex<0>>, NoCapture<ArgIndex<0>>]>` (`:1964`) | Internal lowering: load the resume(0)/destroy(1) sub-function ptr at index i8 from a frame. The `.td` block at `:1962` labels these "Coroutine Lowering Intrinsics. Used internally by coroutine passes." **No `.rst` section.** |
>
> The `coro.alloca.*` family matters most for a D frontend: it is how a coroutine expresses _dynamic stack allocation that survives a suspend_ — the closest IR analogue to D's variable-length stack arrays inside an `async` body — yet it has no spec coverage at all.

> [!NOTE]
> **Unwinding through resume/destroy.** `coro.resume`, `coro.destroy`, and the three `coro.await.suspend.*` intrinsics all carry the `Throws` attribute (`Intrinsics.td:1941-1942,1950-1960`), meaning a resume or destroy can unwind into the caller — directly relevant to D's exception-handling integration (see [§ coro.end and exception handling](#coroend-and-exception-handling)). The async suspend pair (`coro.async.resume`, `coro.suspend.async`) carry `IntrNoMerge, IntrNoDuplicate`, and `coro.save` carries `IntrNoMerge`.

---

## Coroutines by example: the switched-resume transformation

The worked examples in the spec are all switched-resume (`Coroutines.rst:261`). They are the clearest picture of the IR a frontend emits and what CoroSplit does with it.

### Pre-split IR

A generator that prints an incrementing counter and suspends each iteration (`Coroutines.rst:287-308`):

```llvm
define ptr @f(i32 %n) presplitcoroutine {
entry:
  %id = call token @llvm.coro.id(i32 0, ptr null, ptr null, ptr null)
  %size = call i32 @llvm.coro.size.i32()
  %alloc = call ptr @malloc(i32 %size)
  %hdl = call noalias ptr @llvm.coro.begin(token %id, ptr %alloc)
  br label %loop
loop:
  %n.val = phi i32 [ %n, %entry ], [ %inc, %loop ]
  %inc = add nsw i32 %n.val, 1
  call void @print(i32 %n.val)
  %0 = call i8 @llvm.coro.suspend(token none, i1 false)
  switch i8 %0, label %suspend [i8 0, label %loop
                                i8 1, label %cleanup]
cleanup:
  %mem = call ptr @llvm.coro.free(token %id, ptr %hdl)
  call void @free(ptr %mem)
  br label %suspend
suspend:
  call void @llvm.coro.end(ptr %hdl, i1 false, token none)
  ret ptr %hdl
}
```

The block roles (`Coroutines.rst:310-334`): `entry` establishes the frame — `coro.size` becomes a constant, `coro.begin` initializes the frame and returns the handle (arg2 is the dynamically allocated memory), and `coro.id` is the identity token that stops jump-threading from duplicating `coro.begin`. The `cleanup` block destroys the frame: `coro.free` hands back the pointer to free (or null if the frame was not dynamically allocated). The `suspend` block returns to the caller via `coro.end`. The `loop`'s `coro.suspend`-plus-`switch` selects suspend (default), resume (0), or destroy (1).

### Frame building

CoroSplit decides what to spill (`Coroutines.rst:339-355`):

> "The def-use chains are analyzed to determine which objects need to be kept alive across suspend points."

Here `%inc` is computed before the suspend and used after, so it crosses a suspend point: an i32 slot is allocated in the frame, and `%inc` is spilled before the suspend and reloaded after. Together with the resume/destroy function pointers (stored so the manipulation intrinsics work without knowing the coroutine's identity), the frame becomes:

```llvm
%f.frame = type { ptr, ptr, i32 }
```

That is the whole stackless idea concretely: one heap struct holding `{resume-fn, destroy-fn, the single live-across-suspend value}` — nothing like an entire call stack.

### Ramp and the resume/destroy clones

After splitting, the **ramp** stores `@f.resume`/`@f.destroy` into frame slots 0/1, runs up to the first suspend, and returns the frame pointer (`coro.size` having collapsed to a constant 24 here) (`Coroutines.rst:363-379`). The **resume** and **destroy** clones (`Coroutines.rst:385-403`):

```llvm
define internal void @f.resume(ptr %frame.ptr.resume) {
  ; reload %inc, recompute, tail call @print, ret void
}
define internal void @f.destroy(ptr %frame.ptr.destroy) {
  ; tail call @free(ptr ...); ret void
}
```

Note that the general split model speaks of three resume-side functions (`Coroutines.rst:55-62`), but this worked example only materializes `f.resume` + `f.destroy` — the cleanup path is folded into `f.destroy`.

### Multiple suspend points and the resume-index switch

With more than one suspend point, the frame gains a suspend index and the resume clone switches on it (`Coroutines.rst:462-536`). The frame grows a second i32:

```llvm
%f.frame = type { ptr, ptr, i32, i32 }
```

and the resume function loads the index to branch to the right re-entry block:

```llvm
%index = load i8, ptr %index.addr, align 1
%switch = icmp eq i8 %index, 0
br i1 %switch, label %loop.resume, label %loop
...
suspend:
  %storemerge = phi i8 [ 0, %loop ], [ 1, %loop.resume ]
  store i8 %storemerge, ptr %index.addr, align 1
  ret void
```

The spec notes this index-plus-switch is a deliberate strategy choice (`Coroutines.rst:538-546`): an alternative of distinct `f.resume1`/`f.resume2` updating the function pointer per suspend was explored, but "the current approach is easier on the optimizer than the latter so it is a lowering strategy implemented at the moment."

### The `coro.suspend` i8 → switch-edge encoding

This encoding is the single most important contract the frontend's code generator must get right (`Coroutines.rst:1706-1708`):

> "Conditional branches consuming the result of this intrinsic lead to basic blocks where coroutine should proceed when suspended (-1), resumed (0) or destroyed (1)."

The canonical pattern (`Coroutines.rst:1728-1730`):

```llvm
%0 = call i8 @llvm.coro.suspend(token none, i1 false)
switch i8 %0, label %suspend [i8 0, label %resume
                              i8 1, label %cleanup]
```

For a _final_ suspend, the resume (0) edge is unreachable — the example routes it to `@llvm.trap()` + `unreachable` (`Coroutines.rst:1737-1743`), and "If suspend intrinsic is marked as final, it can consider the `true` branch unreachable and can perform optimizations that can take advantage of that fact" (`Coroutines.rst:1754-1755`).

---

## Heap-allocation elision

The reason the allocation protocol is "somewhat complex" is to let LLVM _delete the heap allocation entirely_ when a coroutine is created, used, and destroyed within one inlined scope — turning a stackless coroutine into pure stack data. This is what makes C++ coroutines competitive, and it is exactly what D would want for generators consumed in a `foreach`.

### The alloc/size/begin/free protocol

Instead of unconditionally calling `malloc`, an elidable coroutine guards allocation on `coro.alloc` (`Coroutines.rst:405-447`):

```llvm
entry:
  %id = call token @llvm.coro.id(i32 0, ptr null, ptr null, ptr null)
  %need.dyn.alloc = call i1 @llvm.coro.alloc(token %id)
  br i1 %need.dyn.alloc, label %dyn.alloc, label %coro.begin
dyn.alloc:
  %size = call i32 @llvm.coro.size.i32()
  %alloc = call ptr @CustomAlloc(i32 %size)
  br label %coro.begin
coro.begin:
  %phi = phi ptr [ null, %entry ], [ %alloc, %dyn.alloc ]
  %hdl = call noalias ptr @llvm.coro.begin(token %id, ptr %phi)
```

The cleanup conditionalizes the free on `coro.free`'s null/non-null result (`Coroutines.rst:439-447`). When a self-contained create/use/destroy is fully inlined, `coro.alloc` lowers to `false`, `coro.free` to `null`, and the whole thing collapses to just the coroutine body on the caller's stack (`Coroutines.rst:454-460`).

### CoroElide and CoroAnnotationElide

Two passes perform elision. `CoroElide` (`Coroutines.rst:2216-2224`):

> "examines if the inlined coroutine is eligible for heap allocation elision ... replaces `coro.begin` ... with an address of a coroutine frame placed on its caller and replaces `coro.alloc` and `coro.free` ... with `false` and `null` ... This pass also replaces `coro.resume` and `coro.destroy` intrinsics with direct calls ... where possible."

`CoroAnnotationElide` (`Coroutines.rst:2209-2214`) does the same begin/alloc/free rewrite for usages annotated as "must elide."

### The elision attributes

Two function attributes (both `EnumAttr`s in `Attributes.td`) drive annotation-based elision:

- `coro_only_destroy_when_complete` (`Coroutines.rst:2234-2240`; `Attributes.td:402-403`: `def CoroDestroyOnlyWhenComplete : EnumAttr<"coro_only_destroy_when_complete", IntersectPreserve, [FnAttr]>;`) — "indicates the coroutine must reach the final suspend point when it get destroyed. This attribute only works for switched-resume coroutines now."
- `coro_elide_safe` (`Coroutines.rst:2242-2252`; `Attributes.td:405-407`: `def CoroElideSafe : EnumAttr<"coro_elide_safe", IntersectPreserve, [FnAttr]>;`):

  > "When a Call or Invoke instruction to switch ABI coroutine `f` is marked with `coro_elide_safe`, CoroSplitPass generates a `f.noalloc` ramp function. `f.noalloc` has one more argument than its original ramp function `f`, which is the pointer to the allocated frame. `f.noalloc` also suppresses any allocations or deallocations that may be guarded by @llvm.coro.alloc and @llvm.coro.free. CoroAnnotationElidePass performs the heap elision when possible. Note that for recursive or mutually recursive functions this elision is usually not possible."

### `coro.dead` and `coro.outside.frame`

`coro.dead` (`Coroutines.rst:1185-1214`) is an optimization hint to the "Heap Allocation eLision Optimization (HALO)" that marks the end of frame lifetime, "allowing coroutines that are not explicitly destroyed via coro.destroy to be elided."

`coro.outside.frame` metadata (`Coroutines.rst:2257-2271`) is the most _directly useful to a D frontend_ piece of the whole elision story:

> "`coro.outside.frame` metadata may be attached to an alloca instruction to ... signify that it shouldn't be promoted to the coroutine frame, useful for filtering allocas out by the frontend when emitting internal control mechanisms. Additionally, this metadata is only used as a flag, so the associated node must be empty."

```llvm
%__coro_gro = alloca %struct.GroType, align 1, !coro.outside.frame !0
!0 = !{}
```

A D frontend emitting its own control or exception machinery inside an `async` body can tag those allocas with `!coro.outside.frame` to keep them off the spilled frame — exactly the escape hatch needed when LLVM's automatic "what crosses a suspend" analysis would otherwise capture internal scaffolding.

---

## Promise, final suspend, save-vs-suspend, and parameter attributes

### Promise

A coroutine may designate a distinguished alloca for caller↔coroutine communication (`Coroutines.rst:599-675`):

> "A coroutine author or a frontend may designate a distinguished `alloca` that can be used to communicate with the coroutine. This distinguished alloca is called **coroutine promise** and is provided as the second parameter to the `coro.id` intrinsic."

Consumers read/write it via `coro.promise(handle, align, from=false)`. It is UB to ask for the promise of a coroutine that has none (`Coroutines.rst:967`); reading/writing the promise of a currently executing coroutine is allowed but the author/user must avoid data races (`Coroutines.rst:968-970`). This is the natural slot for a generator's "current value" or a task's result.

### Final suspend

Setting the second `coro.suspend` argument to `true` marks a _final_ suspend (`Coroutines.rst:677-751`). Its properties: `coro.done` can test it, and "a resumption of a coroutine stopped at the final suspend point leads to undefined behavior. The only possible action ... is destroying it via coro.destroy." The Python-generator example shows the standard frontend pattern of an _initial_ suspend (start suspended) plus a `final=true` suspend at the end (`Coroutines.rst:732-741`) — precisely the shape a D `Generator!T` would emit.

### Distinct save vs suspend

For callback-driven async, the coroutine must be made resumable _before_ the operation that may resume it (possibly from another thread) is even kicked off (`Coroutines.rst:548-597`, `:1757-1804`). `coro.save` returns a token marking that "ready to be resumed" point; `coro.suspend(token %save, ...)` consumes it. Passing `none` means an implicit save immediately before the suspend. (Retcon has no separate save — `Coroutines.rst:1883-1886`.) This split is essential for any executor that hands the coroutine handle to a reactor before the suspend actually happens — see [effects-event-loops] for how completion-based runtimes resume suspended computations.

### Parameter attributes

Two pointer-argument attributes interact with frame building (`Coroutines.rst:813-833`):

- **ByVal** (`:817-822`): "a ByVal argument is treated much like an alloca. Space is allocated for it on the coroutine frame and the uses of the argument pointer are replaced with a pointer to the coroutine frame." This is how a by-value struct parameter that outlives a suspend gets onto the frame.
- **swifterror** (`:824-833`): swifterror data flow must be perfectly modeled in the alloca for CodeGen, and naive alloca→frame promotion would break the swifterror rules, so "When split a coroutine it is consequently necessary to keep both the frame slot as well as the alloca itself and then keep them in sync." Relevant only if D ever interoperates with `swiftcc`.

---

## Custom ABIs and plugin libraries

Beyond the three built-in ABIs, LLVM lets a frontend define its own lowering by subclassing an existing ABI (`Coroutines.rst:753-762`):

> "Plugin libraries can extend coroutine lowering enabling a wide variety of users to utilize the coroutine transformation passes. An existing coroutine lowering is extended by:
>
> 1. defining custom ABIs that inherit from the existing ABIs,
> 2. give a list of generators for the custom ABIs when constructing the `CoroSplit` pass, and
> 3. use `coro.begin.custom.abi` in place of `coro.begin` that has an additional parameter for the index of the generator/ABI to be used for the coroutine."

A custom ABI is a C++ class (`Coroutines.rst:768-772`):

```cpp
class CustomSwitchABI : public coro::SwitchABI {
public:
  CustomSwitchABI(Function &F, coro::Shape &S)
    : coro::SwitchABI(F, S, ExtraMaterializable) {}
};
```

registered as a generator on the `CoroSplit` pass (`Coroutines.rst:779-784`):

```cpp
CoroSplitPass::BaseABITy GenCustomABI = [](Function &F, coro::Shape &S) {
  return std::make_unique<CustomSwitchABI>(F, S);
};

CGSCCPassManager CGPM;
CGPM.addPass(CoroSplitPass({GenCustomABI}));
```

The coroutine IR then carries the `presplitcoroutine_custom_abi` function attribute and uses `coro.begin.custom.abi(token, ptr, i32 <generator index>)` (`Coroutines.rst:786-811`):

```llvm
define ptr @f(i32 %n) presplitcoroutine_custom_abi {
entry:
  %id = call token @llvm.coro.id(i32 0, ptr null, ptr null, ptr null)
  %hdl = call noalias ptr @llvm.coro.begin.custom.abi(token %id, ptr %alloc, i32 0)
  ...
}
```

> [!IMPORTANT]
> **Custom ABIs are a C++ API, not reachable from IR or LLVM-C alone — a real constraint on LDC.** The custom-ABI hook is the `CoroSplitPass` constructor plus the `coro::SwitchABI` / `coro::Shape` C++ classes; the IR only carries the `presplitcoroutine_custom_abi` attribute and the generator index. There is no IR-only or LLVM-C path to register a generator. So LDC must either (a) register custom ABI generators from **C++ glue** when it builds its own pass pipeline (LDC already links LLVM as C++, so this is feasible), or (b) live entirely within the stock `SwitchABI`/`retcon`/`async` ABIs driven purely from emitted IR. Also note: `presplitcoroutine` and the `coro_*` attributes are `EnumAttr`s in `Attributes.td:400-407`, but **`presplitcoroutine_custom_abi` is _not_ an `EnumAttr` there** (grep found no def) — confirm how it is spelled/registered in the LLVM 23 source before a frontend relies on it.

How LDC's pass pipeline is constructed, and where such glue would slot in, is the subject of [ldc-codegen]; the internals of `coro::Shape` and the ABI base classes are covered in [llvm-internals].

---

## `coro.end` and exception handling

`coro.end` marks the end of frame access, and its behavior depends on _where_ it sits and the EH personality in play (`Coroutines.rst:1516-1601`). In the ramp/start function it is a no-op (normal) or marks-the-coroutine-done (unwind); in resume/destroy it becomes `ret void` (normal) or unwinds to the caller (unwind). For landingpad EH, the frontend pairs `coro.end(null, true, none)` with `coro.is_in_ramp` to branch between ramp-only cleanup and `eh.resume` (`Coroutines.rst:1546-1569`). For WinEH, the frontend attaches a `"funclet"` bundle to a `cleanuppad`, and CoroSplit inserts `cleanupret ... unwind to caller` (`Coroutines.rst:1571-1583`). The summary table (`Coroutines.rst:1592-1601`):

| `coro.end` form           | In Start Function      | In Resume/Destroy Functions              |
| ------------------------- | ---------------------- | ---------------------------------------- |
| `unwind=false`            | nothing                | `ret void`                               |
| `unwind=true`, WinEH      | mark coroutine as done | `cleanupret unwind to caller`; mark done |
| `unwind=true`, Landingpad | mark coroutine as done | mark coroutine done                      |

For retcon, `coro.end` behaves differently again: it "fully destroys the coroutine frame" and returns a null continuation on the normal path (`Coroutines.rst:1527-1533`).

Because D's exception model spans both schemes (Itanium landingpad on most platforms, WinEH on MSVC targets) and `coro.resume`/`coro.destroy` are themselves `Throws`, getting this table right is a prerequisite for `nothrow`-correctness and for D `try`/`finally`/`scope(exit)` inside an `async` body. [d-design] and [ldc-codegen] develop the D-side EH lowering.

---

## Known limitations

The spec's "Areas Requiring Attention" (`Coroutines.rst:2273-2304`) lists open issues a D port must plan around:

- **Code motion across the suspend(-1) path** can introduce use-after-free; "At the moment we disabled LICM for loops that have coro.suspend, but the general problem still exists" (`:2275-2281`).
- "Cannot handle coroutines with `inalloca` parameters (used in x86 on Windows)" (`:2294`).
- "Alignment is ignored by coro.begin and coro.free intrinsics" (`:2296`).
- "Make required changes to make sure that coroutine optimizations work with LTO" (`:2298-2299`).
- Cross-ABI elision is unsolved: "Design a convention that would make it possible to apply coroutine heap elision optimization across ABI boundaries" (`:2291-2292`).
- WinEH exception objects must be stack-allocated, identified as allocas with `catchpad` users (`:2301-2302`).

---

## What this means for LDC

LDC's `gen/` today has **no** references to `coro_*`, `llvm.coro`, `CoroSplit`, or `presplitcoroutine` (a grep over the v1.42 tree returns nothing) — coroutine lowering is greenfield. The mechanical shape of a port is: the DMD frontend emits an `async`/generator function as an ordinary function carrying `presplitcoroutine` (or `presplitcoroutine_custom_abi`) plus the coro intrinsics; LDC's `gen/` generates the `coro.id`/`coro.begin`/`coro.suspend`/`coro.end` calls and wires the suspend `switch` (default/-1, 0, 1); the stock middle-end passes do the split. The ABI choice falls out of the use case:

| D surface                                               | Best-fit ABI                                         | Why                                                                                                                                                                                                                  |
| ------------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| General `async`/awaitable functions, structured `await` | **Switched-Resume** + `coro.await.suspend.*`         | Turnkey: LLVM owns the frame layout, allocation protocol, resume dispatch, and elision. Same path Clang's C++20 coroutines take ([cpp]).                                                                             |
| Generators / `foreach` iterators                        | **Returned-Continuation** (`retcon` / `retcon.once`) | Caller-owned fixed-size buffer avoids the implicit `malloc` (good for `@nogc`); the frontend supplies alloc/dealloc. Caveat: post-inlining elision is weak (`Coroutines.rst:170-174`).                               |
| Executor-hopping, WasmFX-adjacent stack switching       | **Async**                                            | Caller-allocated context, `musttail` transfer at suspend, one resume fn per suspend, `swiftcc` — the closest LLVM analogue to wasm `cont`/`resume`/`suspend` ([wasm], [wasmfx]). The frontend owns all control flow. |

The constraints to carry forward: the IR contract is version-unstable (`Coroutines.rst:9-10`), so pin to LLVM 23 and re-validate the undocumented `coro.alloca.*`, `coro.async.*`, `coro.subfn.addr`, and `coro.prepare.retcon` intrinsics against source; custom ABIs need C++ glue, not IR alone; and `coro.outside.frame` is the lever for keeping D's internal control machinery off the spilled frame. The roadmap in [roadmap] sequences these decisions; the head-to-head against C++ and the stackful fiber baseline is in [comparison] and [d-fiber].

---

## Sources

- `llvm/docs/Coroutines.rst` — LLVM 23.0.0git, 2304 lines. The authoritative coroutine specification. (`$REPOS/llvm-project/llvm/docs/Coroutines.rst`)
- `llvm/include/llvm/IR/Intrinsics.td` — coroutine intrinsic definitions, lines 1870–1967. (`$REPOS/llvm-project/llvm/include/llvm/IR/Intrinsics.td`)
- `llvm/include/llvm/IR/Attributes.td` — coroutine function attributes (`presplitcoroutine`, `coro_only_destroy_when_complete`, `coro_elide_safe`), lines ~399–407. (`$REPOS/llvm-project/llvm/include/llvm/IR/Attributes.td`)
- C. Nishanov, _LLVM Coroutines_ (LLVM Developers' Meeting 2016) — background on the original switched-resume design. (`$REPOS/papers/llvm-coroutines-nishanov-devmtg-2016`)

<!-- References -->

[index]: ../index.md
[concepts]: ../concepts.md
[llvm-internals]: ./llvm-coro-internals.md
[cpp]: ./cpp-coroutines.md
[comparison]: ./comparison.md
[d-fiber]: ../stackful/d-fiber.md
[d-design]: ./d-language-design.md
[ldc-codegen]: ./ldc-codegen.md
[wasm]: ../wasm-and-wasmfx.md
[roadmap]: ./roadmap.md
[wasmfx]: ../../algebraic-effects/wasmfx.md
[effects-event-loops]: ../../async-io/effects-and-event-loops.md

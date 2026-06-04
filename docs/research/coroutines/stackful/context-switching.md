# Stackful Context-Switching Mechanics: SP Swap, Register Save, Stack Priming

This is the **mechanism** leaf of the stackful half of the survey. Where [d-fiber] characterizes D's `core.thread.Fiber` as a _cost-model baseline_ (default stack size, the per-fiber memory tax, the GC-scan and migration hazards), this doc opens the hood on the one operation underneath all of that: **the context switch itself**. It walks the contract of `fiber_switchContext(void** oldp, void* newp)`, how a fresh stack is allocated, guarded, aligned, and _primed_ so the first switch enters the body, the per-ABI register sets (x86-64 SysV, AArch64, RISC-V, and the Win64 outlier), why that switch is an order of magnitude cheaper than a kernel thread switch, and how the POSIX `ucontext` family, Boost.Context, and Windows Fibers implement the same idea. The recurring theme — _saving/restoring `sp` implicitly saves/restores the instruction pointer, because the resume PC rides on top of the target stack_ — is the engine that every stackful coroutine, green thread, and fiber library runs on.

**Last reviewed:** June 4, 2026

---

> [!NOTE]
> This doc is the _physics_ behind two definitions established elsewhere. [concepts] fixes the vocabulary — a stackful coroutine's saved state "includes the **full call stack** ... equivalent to fibers or user-mode threads" (`n4134:106-108`) — and [d-fiber] gives the D primitive and its costs. **This** doc answers "what does the CPU actually do at a `yield`?": which registers move, where `sp` is published, how the instruction pointer is smuggled through, and what the portable fallbacks cost. The scheduler/I/O layer that drives these switches is [green-threads]; the growth-vs-fixed-stack axis is [stack-management]; the wasm engine primitive that stands in for the missing `sp`-swap is [wasmfx-target].

All druntime paths below are under `runtime/druntime/src/` in the LDC v1.42 tree (`$REPOS/dlang/ldc`). Go paths are under `$REPOS/go/go/src/runtime/` (note the doubled `go/go`). Anything attributed to knowledge — `ucontext`/Windows/Boost cycle costs and exact register sets not read from source here — is **marked inline**.

---

## 1. The contract: `fiber_switchContext(void** oldp, void* newp)`

Every D context switch is one call to one `extern(C)` symbol (`package.d:206`):

```d
extern (C) void fiber_switchContext( void** oldp, void* newp ) nothrow @nogc;
```

The parameter contract is documented verbatim in the long internals comment that precedes `class Fiber` (`package.d:618-623`, identical copy at `base.d:185-190`):

> ```
>  * void** a:  This is the _location_ where we have to store the current stack pointer,
>  *            the stack pointer of the currently executing Context (Fiber or Thread).
>  * void*  b:  This is the pointer to the stack of the Context which we want to switch into.
>  *            Note that we get the same pointer here as the one we stored into the void** a
>  *            in a previous call to fiber_switchContext.
> ```

So `*oldp` **receives** the outgoing stack pointer, and `newp` **is** the incoming stack pointer. The decisive design choice is what is _absent_: **there is no separate register-save area.** The callee-saved registers of the suspending context are pushed onto _that context's own stack_, just below the SP that gets written to `*oldp`. The conceptual algorithm, quoted from the same comment (`package.d:625-634`):

```text
fiber_switchContext:
    push {return Address}
    push {registers}
    copy {stack pointer} into {location pointed to by a}   // *oldp = sp
    //We have now switch to the stack of a different Context!
    copy {b} into {stack pointer}                          // sp = newp
    pop {registers}
    pop {return Address}
    jump to {return Address}
```

> [!IMPORTANT]
> **The instruction pointer is never named.** Where execution resumes is encoded entirely as the **return address sitting on top of the target stack**; the trailing `pop {return Address}; jump` consumes it. This is the whole trick of stack-switched coroutines: by saving and restoring `sp`, you _implicitly_ save and restore the program counter, because the resume PC was pushed onto that very stack before the switch. There is no `mov` into the IP — there is no architectural way to do that — only a `ret`-shaped indirect jump through a value that lives on the stack you just adopted.

`oldp` is a `void**` rather than a `void*` because the **caller** owns the slot that records the suspended SP. For a fiber that slot is `&m_ctxt.tstack` (the per-fiber `StackContext.tstack`); for the host thread it is `&tobj.m_curr.tstack`. The state-machine wrapper that supplies those two pointers — `switchIn` for outer→fiber, `switchOut` for fiber→enclosing — is [d-fiber]'s territory; this doc is the asm those wrappers call.

The internals comment also frames the symmetry that makes a fiber a peer of a thread, not a child of one (`package.d`, internals header):

> "not only each Fiber has a Context, but each thread also has got a Context which describes the threads stack and state ... You can call a Fiber from within another Fiber, then you switch Contexts between the Fibers and the Thread Context is not involved."

That is why `oldp`/`newp` are untyped stack pointers and not "the fiber" and "the thread": the switch is fully symmetric between any two contexts.

---

## 2. Stack allocation: size, guard page, alignment

Before a context can be switched _into_, it needs a stack — and unlike a stackless frame (sized by the compiler from the live-across-suspend set, see [concepts]), a fiber's stack is a fixed, reserved-whole region chosen at construction. [stack-management] develops the fixed-vs-growable axis in depth; here is just the allocation machinery the switch depends on.

### 2.1 Default size

```d
version (Windows)        enum defaultStackPages = 8;   // DbgHelp.dll headroom
else version (OSX) { version (X86_64) enum defaultStackPages = 8; else 4; }
else                     enum defaultStackPages = 4;
```

That cascade is `package.d:749-766`; the constructor default is `pageSize * defaultStackPages` (`package.d:783-784`). On Linux with 4 KiB pages that is a **16 KiB stack** plus a one-page guard; macOS-AArch64's 16 KiB page makes four pages **64 KiB**. The number matters here only as the region the SP swap moves between — its _density implications_ are [d-fiber]'s and [stack-management]'s.

### 2.2 POSIX: `mmap` + `mprotect` guard

`allocStack` rounds the request to a page multiple, GC-allocates a `StackContext` so the fiber stays collectable, then maps the stack (`package.d:955-966`):

```d
sz += guardPageSize;                          // :955  one extra page for the guard

int mmap_flags = MAP_PRIVATE | MAP_ANON;
version (OpenBSD)
    mmap_flags |= MAP_STACK;

m_pmem = mmap( null, sz, PROT_READ | PROT_WRITE, mmap_flags, -1, 0 );   // :961
```

Stacks grow down (`version = StackGrowsDown`, `package.d:41`), so base and top sit at the **high** end of the mapping and the guard page lands at the **low** address — exactly where an overflow runs off the end. The guard is armed `PROT_NONE` (`package.d:1000-1005`):

```d
if (guardPageSize)
{
    // protect end of stack
    if ( mprotect(guard, guardPageSize, PROT_NONE) == -1 )
        abort();
}
```

A descent past the reserved size touches the `PROT_NONE` page and faults — a `SIGSEGV`, not a growth event. **The stack never grows;** there is no segmented or copying expansion in D (contrast Go, §7). That is the single structural fact that makes the per-switch asm so cheap (no growth check) and the per-fiber memory so expensive (over-provisioned).

### 2.3 Windows: `VirtualAlloc` reserve/commit + `PAGE_GUARD`

On Windows the allocation is reserve-then-commit, with a one-shot `PAGE_GUARD` page (`package.d:883-928`): `VirtualAlloc(MEM_RESERVE, PAGE_NOACCESS)` for the whole region, `MEM_COMMIT, PAGE_READWRITE` for the usable stack, and `MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD` for the guard. `PAGE_GUARD` raises `STATUS_GUARD_PAGE_VIOLATION` exactly once on touch — Windows' native stack-overflow trap.

### 2.4 Alignment — 16 bytes

`version = AlignFiberStackTo16Byte` is set for x86/x86-64/AArch64/PPC and friends. `initStack` masks the working pointer down to a 16-byte boundary (`package.d:1082-1092`):

```d
version (AlignFiberStackTo16Byte)
{
    version (StackGrowsDown)
        pstack = cast(void*)(cast(size_t)(pstack) - (cast(size_t)(pstack) & 0x0F));
    else
        pstack = cast(void*)(cast(size_t)(pstack) + (cast(size_t)(pstack) & 0x0F));
}
```

16-byte SP alignment at call boundaries is required by the SysV AMD64 and IA-32 macOS ABIs (so a `movaps`/`movdqa` into a stack slot doesn't fault). Getting this wrong is invisible until the first SIMD spill in the fiber body — which is why the priming (§3) is so finicky about the parity of pushed slots.

`freeStack` is the symmetric, `nothrow @nogc`, cheap teardown — `ThreadBase.remove(m_ctxt)` then `munmap`/`VirtualFree` (`package.d:1021-1047`).

---

## 3. Priming the stack: a fake initial call frame (`initStack`)

A freshly `mmap`'d stack is empty; the first switch into it has nothing to `pop`. `initStack` hand-builds a frame that makes that first switch **indistinguishable** from a later resume — the stackful analog of `makecontext` (§5) or Boost's `make_fcontext` (§6).

### 3.1 The requirement

The internals comment states the invariant precisely (`base.d:253-258`):

> "initStack must produce exactly the same stack layout as the part of `fiber_switchContext` which saves the registers. Pay special attention to set the stack pointer correctly if you use the GC optimization mentioned before. the return Address saved in initStack must be the address of `fiber_entrypoint`."

and then the subtle first-vs-later distinction that makes the trick work (`base.d:260-266`):

> "On the first switch, `Fiber.call` is used and the returnAddress in `fiber_switchContext` will point to `fiber_entrypoint`. The important thing here is that this jump is a function call, we call `fiber_entrypoint` by jumping before it's function prologue. On later calls, the user used `yield()` in a function, and therefore the return address points into a user function, after the yield call. So here the jump in `fiber_switchContext` is a function return, not a function call!"

Both paths run the _same_ `pop {regs}; pop {retaddr}; jmp` epilogue. The CPU cannot tell "returning into a function after a `yield`" from "jumping to the top of a fresh function" — both are just "load `sp`, restore callee-saved regs, jump to the popped address." `initStack` simply manufactures a frame whose saved registers are zero and whose saved return address is `&fiber_entryPoint`.

### 3.2 The `push` helper and x86-64 SysV priming

`push` writes one word toward the growth direction (`package.d:1065-1077`); the x86-64 SysV priming then mirrors the switch's save order exactly (`package.d:1303-1313`):

```d
else version (AsmX86_64_Posix)
{
    push( 0x00000000_00000000 );             // Return address of fiber_entryPoint call
    push( cast(size_t) &fiber_entryPoint );  // RIP   <- popped & jmp'd to on first switch
    push( cast(size_t) m_ctxt.bstack );      // RBP
    push( 0x00000000_00000000 );             // RBX
    push( 0x00000000_00000000 );             // R12
    push( 0x00000000_00000000 );             // R13
    push( 0x00000000_00000000 );             // R14
    push( 0x00000000_00000000 );             // R15
}
```

Read it bottom-up against the SysV switch (§4.1): the switch pops R15→R14→R13→R12→RBX→RBP, then `pop RCX; jmp RCX` consumes `&fiber_entryPoint`. The extra zero word labelled "Return address of fiber*entryPoint call" sits \_above* the RIP slot purely so that when `fiber_entryPoint` runs its own prologue the stack is 16-aligned and a stack walker finds a readable slot. `fiber_entryPoint` never returns, so that fake return address is never used as a jump target — only as alignment and an unwind anchor.

### 3.3 The trampoline pattern (AArch64, RISC-V, ARM, …)

On RISC-style ABIs the resume PC lives in a **link register** (`lr`/`x30`/`ra`), not on the stack, so a stack walker that finds a stale `lr` would try to unwind _past_ the fiber's entry point and crash. The internals comment spells out the hazard (`base.d:269-279`):

> "the link register will still be saved to the stack in fiber_entrypoint and some exception handling / stack unwinding code might read it from this stack location and crash. The exact solution depends on your architecture, but see the ARM implementation for a way to deal with this issue. ... The ARM implementation is meant to be used as a kind of documented example implementation."

The AArch64 priming therefore stores a **trampoline** address as the saved `lr` (`package.d:1588-1609`):

```d
// fiber_switchContext expects newp sp to look like this:
//    9: x29 (fp)  <-- newp tstack
//    8: x30 (lr)  [&fiber_entryPoint]   7: d8 ... 0: d15
pstack -= size_t.sizeof * 11;            // skip past x19-x29
push(cast(size_t) &fiber_trampoline);    // lr <- trampoline
pstack += size_t.sizeof;                 // adjust sp (newp) above lr
```

and the trampoline poisons the return register via CFI before tail-calling the real entry (`switch_context_asm.S:874-885`):

```asm
CSYM(fiber_trampoline):
        .cfi_startproc
        .cfi_undefined x30          // tell the unwinder: lr is "undefined" -> stop here
        // fiber_entryPoint never returns
        bl CSYM(fiber_entryPoint)
        .cfi_endproc
```

The comment explains the choice (`switch_context_asm.S:863-873`): the unwinder must "stop at our Fiber main entry point, i.e. ... mark the bottom of the call stack ... cfi_undefined seems to yield better results in gdb." RISC-V is identical in spirit (`switch_context_riscv.S:86-93`):

```asm
fiber_trampoline:
.cfi_startproc // necessary for .eh_frame
    // discard ra value - fiber_entryPoint never returns
    .cfi_undefined ra
    // non-returnable jump (i.e., a non-unwinding tail-call) to fiber_entryPoint
    tail fiber_entryPoint
.cfi_endproc
```

The classic ARM EABI does the same job inline (`switch_context_asm.S:786-803`) — it clears `lr` and "returns" by writing into `pc`:

```asm
    // ... long comment: a non-zero lr makes the unwinder think fiber_entryPoint
    //     was called by the function in lr and continue unwinding past the stack base and crash.
    mov lr, #0
    // return by writing lr into pc
    mov pc, r1
```

### 3.4 Windows x86-64 priming is the heaviest

Win64 priming pushes a trampoline (`sub RSP,32; call fiber_entryPoint` — reserving the Win64 shadow space while keeping 16-byte alignment), then six GPRs, **XMM6–XMM15** (ten 16-byte slots), RBX, and three `GS:[...]` TIB slots (stack base/limit/dealloc). The XMM and TIB entries exist because the Win64 ABI makes XMM6–15 non-volatile and the OS reads the TIB stack range during SEH unwinding. x86-32 Windows additionally fabricates an `EXCEPTION_REGISTRATION` SEH-chain node to satisfy SEHOP. This is the priming counterpart of §4.4's heavy switch.

---

## 4. The switch per ABI: which registers, SP swap, IP transfer

The universal five-step pattern across every backend:

1. push the **callee-saved** registers onto the _current_ stack;
2. `*oldp = sp` (publish the suspended SP — placed _above_ the FP/return-addr region, §6);
3. `sp = newp` (adopt the target stack);
4. pop the target's callee-saved registers;
5. consume the target's saved return address (`ret`, or `pop+jmp`).

Only **callee-saved** registers are touched, and the internals comment enumerates exactly why (`base.d:238-251`):

> "If a register is callee-save ... it needs to be saved/restored in switchContext. If a register is caller-save it needn't be saved/restored. (Calling fiber_switchContext is a function call and the compiler therefore already must save these registers before calling fiber_switchContext). Argument registers ... needn't ... The return register needn't ... All scratch registers needn't ... The frame pointer register - if it exists - is usually callee-save. All current implementations do not save control registers."

Because `fiber_switchContext` is an ordinary C call, the C ABI has already obliged the _caller_ to spill any live caller-saved registers before the call. The switch only has to preserve what the ABI says survives a call — a handful of integer registers, the frame pointer, the low halves of a few SIMD registers. This is _the_ reason a fiber switch is far cheaper than a thread switch (§4.5).

### 4.1 x86-64 SysV / POSIX — the primary Linux target

The whole switch (`package.d:543-575`):

```asm
naked;
// save current stack state
push RBP;  mov RBP, RSP;
push RBX;  push R12;  push R13;  push R14;  push R15;
// store oldp                                  (RDI = oldp, RSI = newp per SysV arg regs)
mov [RDI], RSP;          // *oldp = sp
// load newp to begin context switch
mov RSP, RSI;            // sp = newp
// load saved state from new stack
pop R15;  pop R14;  pop R13;  pop R12;  pop RBX;  pop RBP;
// 'return' to complete switch
pop RCX;  jmp RCX;       // IP transfer: pop saved return addr, indirect jump
```

Callee-saved set: **RBX, RBP, R12, R13, R14, R15** — exactly the SysV AMD64 non-volatile GPRs. **Not saved:** RAX/RCX/RDX/RSI/RDI/R8–R11 (caller-saved and argument registers), the x87/SSE register bank, and the MXCSR/x87 control word. The cost is six pushes + an SP store + an SP load + six pops + one indirect branch — roughly a dozen memory ops and a single (mispredict-prone) indirect jump, with **no syscall and no allocation**.

> [!NOTE]
> The POSIX path uses `pop RCX; jmp RCX` rather than a bare `ret`. Same effect; the indirect jump is what makes the first-switch _call_ and the later-switch _return_ (§3.1) execute through one identical epilogue.

### 4.2 AArch64

Callee-saved per AAPCS64: **x19–x28**, **x29 (fp)**, **x30 (lr)**, and **d8–d15** (the low 64 bits of the callee-saved SIMD set). The whole switch (`switch_context_asm.S:805-861`):

```asm
CSYM(fiber_switchContext):
        stp     d15, d14, [sp, #-20*8]!   // 20 slots = 8 d-reg + 12 x-reg, pre-decrement sp
        stp     d13, d12, [sp, #2*8]
        stp     d11, d10, [sp, #4*8]
        stp     d9, d8,   [sp, #6*8]
        stp     x30, x29, [sp, #8*8]      // lr, fp
        stp     x28, x27, [sp, #10*8]
        ...
        stp     x20, x19, [sp, #18*8]

        // oldp is set above saved lr (x30) to hide it and float regs from GC
        add     x19, sp, #9*8
        str     x19, [x0]                 // *oldp = sp+9*8   (x0 = oldp)
        sub     sp, x1, #9*8              // sp = newp-9*8     (x1 = newp)

        ldp     x20, x19, [sp, #18*8]
        ...
        ldp     x30, x29, [sp, #8*8]      // lr, fp
        ldp     d9, d8,   [sp, #6*8]
        ...
        ldp     d15, d14, [sp], #20*8
        ret                               // IP transfer via the restored lr (x30)
```

Two things to notice. First, the IP transfer is a genuine `ret` through the restored `x30` — no on-stack return address as on x86. Second, the **`+9*8` / `-9*8` bias**: the published SP (`*oldp`) points _above_ `lr` and the eight float slots, so the conservative GC scan (§6) stops before them; the `sub sp, x1, #9*8` re-biases on the way back in. The priming in §3.3 builds a frame matching this exact layout.

### 4.3 RISC-V

Callee-saved: **s0–s11** (`x8`, `x9`, `x18–x27`) plus **fs0–fs11** when `__riscv_flen` (hard-float). `ra` and the float registers are stored _below_ the published SP — the same GC-hiding bias as AArch64. The SP swap is `save sp,(a0)` / `addi sp,a1,0`, and the IP transfer is `jr ra` through the loaded `ra` (`switch_context_riscv.S:118-212`). The macros adapt to XLEN/FLEN (`sd`/`ld`, `fsd`/`fld`) so one source covers RV32/RV64 and soft/hard float.

### 4.4 x86-64 Windows — the heavy outlier

The Win64 switch saves far more (`package.d:439-509`): RBP, R12–R15, RDI, RSI, RBX, **XMM6–XMM15** (160 bytes of `movdqa`), and three `GS:[...]` TIB slots. The save block is explicit about alignment:

```asm
naked;
// NOTE: ... make sure that the XMM registers are still aligned.
//       On function entry, the stack is guaranteed to not
//       be aligned to 16 bytes because of the return address ...
push RBP;  mov RBP, RSP;
push R12;  push R13;  push R14;  push R15;  push RDI;  push RSI;
// 7 registers = 56 bytes; stack is now aligned to 16 bytes
sub RSP, 160;
movdqa [RSP + 144], XMM6;
movdqa [RSP + 128], XMM7;
...
movdqa [RSP], XMM15;
push RBX;
xor  RAX,RAX;
push qword ptr GS:[RAX];      // TIB: stack base
push qword ptr GS:8[RAX];     // TIB: stack limit
push qword ptr GS:16[RAX];    // TIB: dealloc stack
```

RDI/RSI and XMM6–15 are non-volatile under the Win64 ABI (unlike SysV, where RDI/RSI are argument registers and the whole XMM bank is caller-saved), and the TIB stack-base/limit/dealloc fields must travel with the fiber so SEH unwinding sees the right range. This is the ABI reason a Windows fiber switch costs meaningfully more than a Linux one. (There is even a unittest in `package.d` that asserts the non-volatile registers survive a switch.)

### 4.5 Why a fiber switch ≪ a thread switch

|                        | Fiber switch (`fiber_switchContext`)               | Kernel thread switch                                                            |
| ---------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------- |
| Privilege              | user-space, `nothrow @nogc` asm                    | syscall / scheduler round-trip                                                  |
| Registers saved        | **callee-saved only** (C ABI handles the rest)     | the _full_ architectural file (all GPRs, full SIMD bank, control/segment state) |
| FP/SIMD bank           | not saved on the hot path (SysV/RISC-V soft-float) | saved/restored in full                                                          |
| FP status/control word | **not saved** — a documented limitation            | saved per-thread by the kernel                                                  |
| Signal mask            | untouched (no `sigprocmask`)                       | kernel-managed                                                                  |
| Switch point           | cooperative, at a known call boundary              | arbitrary instruction boundary (preemption)                                     |

Five reasons, drawn from the asm above:

1. **No kernel transition.** A user-space sequence of a dozen memory ops versus a syscall that drags in TLB/page-table work, scheduler bookkeeping, and cache pollution. (Knowledge: order-of-magnitude — a fiber switch is ~tens of ns / dozens of instructions; a thread switch is ~1–several µs.)
2. **Minimal register set.** Only callee-saved regs (§4.1). A kernel switch must save the _full_ register file because it can preempt at an arbitrary instruction boundary, not a call boundary.
3. **No FP/SIMD bank on the hot path** (outside Win64). The switch explicitly does _not_ save the FP **status/control** word — documented as a limitation (`package.d:729-732`): "Status registers are not saved ... floating point exception status bits ... rounding mode and similar stuff is set per-thread, not per Fiber!" A correctness caveat, but also part of why it is fast.
4. **No signal-mask syscall.** Cooperative scheduling means there is no per-switch `sigprocmask` — the explicit reason druntime rolls its own asm instead of `swapcontext` (§5.2).
5. **Deterministic switch points.** The switch only fires at `yield()`/`call()`, a known call boundary, so the compiler's caller-saved spill is already sufficient and no extra architectural state needs preserving.

---

## 5. POSIX `ucontext`: the capability-detected fallback

druntime hand-writes asm for every first-class target. For anything left over, it falls back to the POSIX `ucontext` family — but reluctantly, and only when no asm backend matches.

### 5.1 The API (from knowledge, corroborated by druntime usage)

```c
int  getcontext(ucontext_t *ucp);                                  // snapshot current
int  setcontext(const ucontext_t *ucp);                            // jump to a context
void makecontext(ucontext_t *ucp, void (*func)(), int argc, ...);  // prime a fresh context
int  swapcontext(ucontext_t *oucp, const ucontext_t *ucp);         // save current, switch to ucp
```

`makecontext` plays exactly `initStack`'s role (§3): given a `getcontext`-initialized `ucp` and an assigned `uc_stack`, it _fabricates the initial frame_ so a later `swapcontext`/`setcontext` enters `func`. `swapcontext(oucp, ucp)` is the suspend+resume primitive: save into `oucp`, activate `ucp`. druntime delegates priming to libc here instead of hand-building the frame (`package.d:1654-1665`).

### 5.2 Why it's the _fallback_, not the default

The capability check itself documents the demotion (`package.d:182-187`):

> "the ucontext implementation requires architecture specific data definitions to operate so testing for it must be done by checking for the existence of `ucontext_t` rather than by a version identifier. Please note that this is considered an **obsolescent feature** according to the POSIX spec, so a **custom solution is still preferred**."

The switch, when reached, is a single `swapcontext` (`package.d:580-588`):

```d
else static if ( __traits( compiles, ucontext_t ) )
{
    Fiber   cfib = Fiber.getThis();
    void*   ucur = cfib.m_ucur;

    *oldp = &ucur;
    swapcontext( **(cast(ucontext_t***) oldp),
                  *(cast(ucontext_t**)  newp) );
}
```

Three reasons druntime prefers its own asm:

- **`swapcontext` saves/restores the signal mask** — historically a `sigprocmask(2)` **syscall** per switch. That kernel round-trip dwarfs the dozen user-space memory ops of the hand asm. _(Knowledge — this is the canonical reason fiber libraries, Boost.Context, libco, and Go all abandon `ucontext`. druntime's own comment only calls it "obsolescent" and says a "custom solution is still preferred"; it does not itself spell out the syscall. Verify against the target libc before stating it unqualified.)_
- It saves more machine state than necessary (a full `mcontext_t`).
- It is **marked obsolescent / removed** from POSIX.1-2008, so it is not even guaranteed present — hence the `__traits(compiles, ucontext_t)` capability check rather than a `version` flag.

The version cascade (`package.d:56-191`) routes all of x86/x86-64/AArch64/ARM/PPC/MIPS/LoongArch/RISC-V to asm backends, so `ucontext` is effectively dead code on mainstream targets — the capability-detected last resort, present only so an unported triple still _works_, slowly.

---

## 6. GC coupling: the FP-below-SP trick

The published SP (`*oldp`) is deliberately placed **above** the saved FP registers and return address, so the conservative GC — which scans `[bstack .. tstack)` for every registered context — never scans the spill region. The internals comment is explicit (`package.d:636-643`):

> "By storing registers which can not contain references to memory managed by the GC outside of the region marked by the stack base pointer and the stack pointer saved in fiber_switchContext we can prevent the GC from scanning them. Such registers are usually floating point registers and the return address. In order to implement this, we return a modified stack pointer from fiber_switchContext."

This is precisely why the AArch64 (§4.2) and RISC-V (§4.3) switches bias the published SP by `±9*8` / the `ra`+float region, and why the x86-64 priming (§3.2) puts RIP and the fake return address _below_ where the eventual `*oldp` will land. The mechanic and the GC are co-designed: the switch publishes SP _exactly_ at the boundary between "pointers the GC must scan" (the user's stack frames, above) and "non-reference register spill" (floats + return address, below). The [d-fiber] doc develops the cost side — every live fiber is one extra conservative scan range on a global intrusive list; this doc grounds _why the switch publishes SP where it does_.

---

## 7. Cross-language reference points

### 7.1 Boost.Context / Boost.Coroutine2 (C++) — from knowledge

The C++ reference implementation of the same idea. The low-level primitive is `fcontext_t` (an opaque pointer to the top of a saved stack) and the switch is `jump_fcontext`:

```cpp
// modern Boost.Context (v2), shape from knowledge
typedef void* fcontext_t;
struct transfer_t { fcontext_t fctx; void* data; };
transfer_t  jump_fcontext(fcontext_t const to, void* vp);                    // switch to `to`
fcontext_t  make_fcontext(void* sp, size_t size, void(*fn)(transfer_t));     // prime a stack
transfer_t  ontop_fcontext(fcontext_t const to, void* vp, transfer_t(*fn)(transfer_t));
```

- `make_fcontext` **is** D's `initStack` (§3): it hand-builds the initial frame on a caller-provided stack so the first `jump_fcontext` enters `fn`.
- `jump_fcontext` **is** `fiber_switchContext` (§4): save callee-saved regs + SP on the current stack, swap SP, restore, return — hand-written per-ABI `.S` (x86-64 SysV/MS, AArch64, ARM, PPC, RISC-V), **no syscall, no signal mask** (the very reason Boost abandoned `ucontext`). It returns a `transfer_t` carrying the _previous_ context handle plus a data pointer, so it doubles as a value channel — the one API-shape difference from D's out-param-SP form.
- `Boost.Coroutine2` layers a symmetric `coroutine<T>::push_type`/`pull_type` API (and a `protected_fixedsize_stack` with a guard page) on top — structurally `std.concurrency.Generator` over `Fiber`. _(Mark: precise Boost prototypes shifted across versions; older `jump_fcontext` took `fcontext_t*`.)_

### 7.2 Windows Fibers — from knowledge

Windows ships fibers as a first-class OS facility (`kernel32`): `ConvertThreadToFiber`, `CreateFiber(stackSize, start, param)`, `SwitchToFiber(fiber)`, `DeleteFiber`, plus Fiber-Local Storage (`FlsAlloc`).

- `SwitchToFiber` is the OS-provided `fiber_switchContext`: a user-mode, non-preemptive switch saving the non-volatile register set _plus_ the **TIB stack base/limit/dealloc** fields — which is precisely _why_ D's own Win64 priming (§3.4) and switch (§4.4) carry the three `GS:[...]` TIB slots.
- D does **not** call `CreateFiber`/`SwitchToFiber`; it rolls its own asm on Windows too, for the same speed/control reasons it avoids `ucontext` on POSIX — plus to own the GC scan range and SEH chain itself. Windows Fibers are the _conceptual_ cousin, not the implementation.
- `FlsAlloc` is Windows' acknowledgement of the **same TLS-migration hazard** D documents at `getThis()` (`base.d:644-647`, ldc#666): plain TLS is thread-, not fiber-affine. That hazard is [d-fiber]'s subject; here it is the reason both runtimes need a fiber-affine storage class.

### 7.3 Go goroutines — grounded in `$REPOS/go`

Go is the large-scale stackful runtime, and its switch differs from D's on the two axes that matter most for the survey. First, **Go saves to a side struct (`gobuf`), not onto the goroutine's own stack** (`runtime2.go:303-320`):

```go
type gobuf struct {
    sp   uintptr
    pc   uintptr
    g    guintptr
    ctxt unsafe.Pointer
    lr   uintptr           // link register (non-x86)
    bp   uintptr           // frame pointer
}
```

The switch is `gogo` — restore SP/BP/PC from a `gobuf` and `JMP` (`asm_amd64.s`, `gogo<>`):

```asm
TEXT gogo<>(SB), NOSPLIT, $0
        get_tls(CX)
        MOVQ    DX, g(CX)             // set current g in TLS
        MOVQ    DX, R14               // g register
        MOVQ    gobuf_sp(BX), SP      // restore SP
        MOVQ    gobuf_ctxt(BX), DX
        MOVQ    gobuf_bp(BX), BP
        MOVQ    gobuf_pc(BX), BX
        JMP     BX                    // IP transfer
```

`mcall` saves the caller's PC/SP/BP into `g.sched` (a `gobuf`) and switches to the **g0 (system) stack** to run the scheduler — the moral equivalent of D's `switchOut` to the enclosing context, except Go's enclosing context is always the per-M scheduler stack. Note that Go names `sp`, `pc`, `lr`, and `bp` as _struct fields_; D leaves the same values in stack slots below `*oldp`. Both avoid a separate register file; they just disagree about where the saved registers live.

Second, **Go stacks are tiny and growable; D stacks are large and fixed.** A goroutine starts at `stackMin = 2048` — **2 KiB** (`stack.go:78`) — and **copies to a bigger stack** on overflow via `copystack` (`stack.go:900`) and the `morestack`/`newstack` machinery. D's fiber is 16 KiB fixed with a guard page and _no_ growth (§2.2). Go pays a pointer-adjustment pass when a stack grows; D pays nothing on growth because it forbids it (faults instead). This is the central memory-density difference between the two stackful designs — and the subject of [stack-management].

| Axis              | D `Fiber` switch                           | Go `gogo`/`mcall`                             |
| ----------------- | ------------------------------------------ | --------------------------------------------- |
| Save location     | on the suspended stack (below `*oldp`)     | `gobuf` side struct (`g.sched`)               |
| Registers saved   | callee-saved only, on stack                | `sp`/`pc`/`bp`/`ctxt`(+`lr`) named in `gobuf` |
| IP transfer       | `ret` / `pop+jmp` through on-stack retaddr | `MOVQ gobuf_pc; JMP`                          |
| Stack size        | **16 KiB fixed** + guard page              | **2 KiB**, copy-grows on overflow             |
| GC of the stack   | conservative scan of `[bstack..tstack)`    | precise (Go has stack maps)                   |
| Scheduler context | enclosing thread/outer fiber               | always the g0 system stack                    |

The full G-M-P scheduler that drives these switches — and how the netpoller parks/readies a goroutine around a `gogo` — is [go-netpoller] and [green-threads].

### 7.4 Java Loom — cross-survey

Loom's virtual threads are stackful continuations (`jdk.internal.vm.Continuation`) multiplexed onto carrier platform threads (mount/unmount). The switch is _inside the JVM_, not user asm, but the model is identical: capture the full stack, release the carrier, remount later — and it hits the **same TLS-affinity hazard** ("`Thread.currentThread()` can change mid-method") that D's `CheckFiberMigration` guards against. The JVM cousin is surveyed in [java-loom] and [java].

---

## 8. The wasm wall, and the engine that scales it

Every mechanism in this doc presupposes one thing wasm does not provide: **a native, addressable, downward-growing machine stack with a raw `sp` register to swap.** WebAssembly exposes no linear machine stack you can point at, no `sp` to overwrite, and keeps the call stack inside the engine out of the module's reach. `fiber_switchContext` therefore has _nothing to implement_, and so it asserts (`package.d:576-578`):

```d
else version (WASI)
    assert(0, "Fibers not supported on WASI");
```

This is the precise boundary the survey's porting goal runs into. A _stackless_ coroutine sidesteps it — its suspend points are statically visible, so it lowers to a `switch`-on-state-index function whose frame lives in linear memory, no `sp`-swap required (see [concepts], and the wasm strategies in [wasmfx-target]). A _stackful_ fiber cannot be `CoroSplit`-ed (its yields fire from arbitrary depth), so on wasm it needs either Asyncify (a whole-program CPS transform) or a real engine primitive.

That engine primitive is **WasmFX / stack-switching**, and the analogy to this doc is exact: think of `fiber_switchContext`'s `sp`-swap as a _car engine swap done by hand on a lift_ — the mechanic disconnects the old engine (saves callee-saved regs, publishes `*oldp`), bolts in the new one (loads `newp`, restores its regs), and turns the key (`ret` through the resumed PC). WasmFX moves that swap _inside the engine_: where D needs a register named `sp` and a downward stack, WasmFX provides one reference type, `cont`, and a handful of instructions — `cont.new` (build a suspendable context = `initStack`), `resume` (= `fiber_switchContext` into it = `Fiber.call`), and `suspend` (= switch back out = `Fiber.yield`). The hand-built fake frame, the trampoline, the per-ABI register choreography — all of it collapses into engine-managed, one-shot continuations. [wasmfx-target] develops that mapping (`Fiber.call → cont.new + resume`, `Fiber.yield → suspend`) in full, and [wasmfx] is the mechanism's standards-track deep-dive.

---

## 9. Mechanism summary

| Property                | D `Fiber`                          | `ucontext`                      | Boost.Context              | Windows Fiber        | Go goroutine              |
| ----------------------- | ---------------------------------- | ------------------------------- | -------------------------- | -------------------- | ------------------------- |
| Switch site             | hand asm, user-space               | `swapcontext` (libc)            | hand asm (`jump_fcontext`) | OS (`SwitchToFiber`) | hand asm (`gogo`/`mcall`) |
| Saved regs              | callee-saved only                  | full `mcontext_t`               | callee-saved only          | non-volatile + TIB   | named in `gobuf`          |
| FP status/ctrl saved?   | **No** (`package.d:729-732`)       | yes (in `mcontext`)             | No                         | No                   | No                        |
| Signal mask per switch? | No                                 | **Yes (syscall)** _(knowledge)_ | No                         | No                   | No                        |
| Save location           | on suspended stack (below `*oldp`) | `ucontext_t.uc_mcontext`        | on suspended stack         | OS fiber object      | `g.sched` (`gobuf`)       |
| IP transfer             | on-stack retaddr (`ret`/`pop+jmp`) | libc-internal                   | on-stack retaddr           | OS-internal          | `gobuf.pc` + `JMP`        |
| Stack growth            | **fixed**, guard-page trap         | fixed                           | fixed (guard option)       | OS-managed           | **copy-grows from 2 KiB** |
| `@nogc` switch?         | **Yes** (alloc in ctor)            | n/a                             | n/a                        | n/a                  | n/a (GC-managed)          |
| Works on wasm?          | **No** — `assert(0)`               | no                              | no                         | no (OS)              | n/a (host runtime)        |

The through-line: **a stackful context switch is `sp`-swap + callee-saved save/restore + an implicit IP transfer through the target stack's top.** Everything else — guard pages, the fake initial frame, the trampolines, the GC-hiding SP bias, the `ucontext` fallback — exists to make that one operation safe, cheap, and uniform between the first switch and every later one. It is fast precisely because it is cooperative and ABI-aware (only callee-saved state, no syscall), and it is _impossible on wasm_ precisely because it needs a register and a stack the wasm machine model does not expose. That impossibility is the case for a stackless lowering ([concepts], [d-fiber]) and for the WasmFX engine primitive ([wasmfx-target], [wasmfx]).

---

## Sources

- `core/thread/fiber/package.d` (LDC v1.42 druntime) — `fiber_switchContext` contract and conceptual algorithm (`:206`, `:618-634`), x86-64 SysV switch (`:543-575`) and priming (`:1303-1313`), Win64 switch (`:439-509`), `ucontext` capability check (`:182-187`) / switch (`:580-588`) / priming (`:1654-1665`), guard page + `mmap` (`:955-1005`), alignment (`:1082-1092`), AArch64 priming (`:1588-1609`), GC SP-publish comment (`:636-643`), FP-status caveat (`:729-732`), WASI `assert(0)` (`:576-578`): `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/package.d`
- `core/thread/fiber/base.d` (LDC v1.42 druntime) — `initStack` requirement + first-vs-later distinction (`:253-282`), callee-save rule (`:238-251`), TLS-migration note (`:644-647`): `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/base.d`
- `core/thread/fiber/switch_context_asm.S` — AArch64 switch (`:805-861`), `fiber_trampoline` + `.cfi_undefined` rationale (`:863-885`), ARM EABI `mov lr,#0; mov pc,r1` example (`:786-803`): `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/switch_context_asm.S`
- `core/thread/fiber/switch_context_riscv.S` — RISC-V switch (`:118-212`) and `fiber_trampoline` (`:86-93`): `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/switch_context_riscv.S`
- Go runtime — `gobuf` (`runtime2.go:303-320`), `gogo`/`mcall` (`asm_amd64.s`), `stackMin = 2048` (`stack.go:78`), `copystack` (`stack.go:900`): `$REPOS/go/go/src/runtime/`
- POSIX `ucontext`, Boost.Context (`fcontext_t`/`jump_fcontext`/`make_fcontext`), and Windows Fibers (`CreateFiber`/`SwitchToFiber`/`FlsAlloc`) — API shapes and cycle costs from knowledge, marked inline.
- WasmFX stack-switching (`cont`, `resume`, `suspend`): `$REPOS/wasm/stack-switching/proposals/stack-switching/Explainer.md` — see [wasmfx-target], [wasmfx].

<!-- References -->

[concepts]: ../concepts.md
[d-fiber]: ./d-fiber.md
[green-threads]: ./green-threads.md
[stack-management]: ./stack-management.md
[wasmfx-target]: ./wasmfx-as-target.md
[wasmfx]: ../../algebraic-effects/wasmfx.md
[java-loom]: ../../algebraic-effects/java-loom.md
[go-netpoller]: ../../async-io/go-netpoller.md
[java]: ../../async-io/java.md

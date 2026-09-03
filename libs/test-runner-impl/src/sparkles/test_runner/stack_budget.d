/**
 * 512 KiB worker stacks and a 384 KiB per-test budget.

 * macOS `core.thread.Thread` workers default to 512 KiB; Linux pthreads
 * default to ~8 MiB, so a 1 MiB stack local passes CI and SIGSEGV/SIGBUS on
 * a developer Mac. The runner pins every worker to the Darwin size and
 * `mprotect`s the stack below a 384 KiB watermark so crossing it is a named
 * test failure rather than a process-killing guard-page fault.
 */
module sparkles.test_runner.stack_budget;

/// Darwin's default pthread worker stack — the production constraint.
///
/// Under AddressSanitizer (`LDC_AddressSanitizer`) the watermark below is
/// off (ASan owns SIGSEGV) and redzones inflate every frame, so the 384 KiB
/// budget is neither enforced nor measurable there. Workers get 4 MiB
/// instead: a body that fits the budget cannot then walk off a guard page
/// and take the whole process down with it.
version (LDC_AddressSanitizer)
    enum size_t workerStackBytes = 4 * 1024 * 1024;
else
    enum size_t workerStackBytes = 512 * 1024;

/// A test that grows the stack more than this fails with
/// $(LREF StackBudgetExceeded) instead of a raw SIGSEGV.
///
/// 384 KiB sits under the 512 KiB worker stack with room for thread
/// startup, and still catches the 1 MiB workspaces this budget exists
/// for. Fuzzy query tests already split around ~26 KiB `QueryStorage`
/// values so a handful fit a Darwin worker; 256 KiB was too tight once
/// LDC inlined `parseQuery` into those frames.
enum size_t stackBudgetBytes = 384 * 1_024;

/// Thrown when a test body crosses $(LREF stackBudgetBytes). Recorded as a
/// failure, not a skip; the process keeps running the rest of the suite.
class StackBudgetExceeded : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(msg, file, line);
    }
}

/// Installs the SIGSEGV/SIGBUS handler that turns a watermark fault into
/// $(LREF StackBudgetExceeded). Call once at runner start-up; subsequent
/// calls are no-ops. No-op on non-POSIX hosts.
void installStackBudgetHandler()
{
    // ASan owns SIGSEGV for its shadow map. Stealing the handler makes
    // both tools lie; workers get $(LREF workerStackBytes) of 4 MiB instead.
    version (LDC_AddressSanitizer) {}
    else version (Posix)
        installHandlerOnce();
}

/// Sets up this thread's sigaltstack so a watermark fault can run the handler
/// after the main stack is exhausted. Call once per worker (and on the main
/// thread for `-t 1`). No-op on non-POSIX hosts, and under ASan, which
/// installs its own alternate signal stack per thread for its SIGSEGV
/// reports — replacing it would hand ASan a stack it did not size.
void prepareCurrentThreadForStackBudget()
{
    version (LDC_AddressSanitizer) {}
    else version (Posix)
        prepareAltStack();
}

/**
Runs `dg` with the unused stack below the 384 KiB watermark marked
`PROT_NONE`. A fault in that region longjmps here and throws
$(LREF StackBudgetExceeded). Nested calls (the runner's own
`executeTest` unittests) reuse the outer watermark.
*/
void runWithStackBudget(scope void delegate() dg, string label = null)
{
    version (LDC_AddressSanitizer)
        dg();
    else version (Posix)
        runArmed(dg, label);
    else
        dg();
}

/// POSIX `pthread` stack size of the calling thread, or 0 when unknown.
size_t currentThreadStackBytes() @trusted nothrow @nogc
{
    version (Posix)
        return threadStack().size;
    else
        return 0;
}

version (Posix):

import core.atomic : cas;
import core.sys.posix.sys.types : pid_t;
import core.sys.posix.unistd : getpid;
import core.sys.posix.pthread : pthread_self, pthread_t;
import core.sys.posix.signal : SA_ONSTACK, SA_RESTART, SA_SIGINFO, SIGBUS,
    SIGSEGV, SIG_DFL, SIG_IGN, sigaction, sigaction_t, sigemptyset, siginfo_t,
    sigaltstack, stack_t;
import core.sys.posix.sys.mman : MAP_ANON, MAP_PRIVATE, PROT_NONE, PROT_READ,
    PROT_WRITE, mmap, mprotect, munmap;
import core.memory : pageSize;

// Druntime's posix.setjmp has no Darwin arm; bind libc directly there.
version (linux)
{
    import core.sys.posix.pthread : pthread_attr_t, pthread_t;

    // glibc's non-POSIX query for a running thread's attributes. druntime
    // declares no `core.sys.linux.pthread` and `core.sys.posix.pthread` does
    // not carry it; a function-local `extern (C)` gets D mangling and does
    // not link, so it lives at module scope.
    extern (C) int pthread_getattr_np(pthread_t, pthread_attr_t*) nothrow @nogc @system;
}

version (OSX)
{
    private alias SigJmpBuf = int[49];
    extern (C) private int sigsetjmp(ref SigJmpBuf, int) nothrow @nogc;
    extern (C) private void siglongjmp(ref SigJmpBuf, int) nothrow @nogc;
}
else
{
    import core.sys.posix.setjmp : sigjmp_buf;

    private alias SigJmpBuf = sigjmp_buf;

    // druntime declares glibc's `__sigsetjmp`/`siglongjmp` with the buffer by
    // value. A 200-byte aggregate goes to the stack under the SysV ABI, so the
    // callee reads its buffer pointer from the next register — the `savemask`
    // argument, 1 — and writes to address 1: SIGSEGV at 0x1 on the first
    // `sigsetjmp`. Bind both by reference, as the Darwin arm above does.
    version (CRuntime_Glibc)
    {
        extern (C) private int __sigsetjmp(ref SigJmpBuf, int) nothrow @nogc;
        private alias sigsetjmp = __sigsetjmp;
    }
    else
        extern (C) private int sigsetjmp(ref SigJmpBuf, int) nothrow @nogc;
    extern (C) private void siglongjmp(ref SigJmpBuf, int) nothrow @nogc;
}

private enum size_t altStackBytes = 64 * 1024;
private enum string budgetMessage =
    "stack usage exceeded the 384 KiB test-worker budget";

private struct Guard
{
    SigJmpBuf jmp;
    void* stackLow;
    void* protectBase;
    size_t protectLen;
    void* usableLow;
    int nesting;
    bool altStackReady;
    string label; /// the running test, for a fault the budget did not cause
}

private Guard tlsGuard;
private shared bool handlerInstalled;
private sigaction_t oldSegv;
private sigaction_t oldBus;
private pid_t installedPid; /// the process the handler was installed in

private struct StackRegion
{
    void* low;
    size_t size;
    void* high() const @safe pure nothrow @nogc
        => cast(void*)(cast(size_t) low + size);
}

version (OSX)
{
    extern (C) private void* pthread_get_stackaddr_np(pthread_t) nothrow @nogc;
    extern (C) private size_t pthread_get_stacksize_np(pthread_t) nothrow @nogc;
}

private StackRegion threadStack() @trusted nothrow @nogc
{
    version (OSX)
    {
        auto self = pthread_self();
        auto high = pthread_get_stackaddr_np(self);
        const sz = pthread_get_stacksize_np(self);
        if (high is null || sz == 0)
            return StackRegion.init;
        return StackRegion(cast(void*)(cast(size_t) high - sz), sz);
    }
    else version (linux)
    {
        import core.sys.posix.pthread : pthread_attr_destroy, pthread_attr_init,
            pthread_attr_t, pthread_attr_getstack;

        pthread_attr_t attr;
        if (pthread_getattr_np(pthread_self(), &attr) != 0)
            return StackRegion.init;
        scope (exit)
            pthread_attr_destroy(&attr);
        void* low;
        size_t sz;
        if (pthread_attr_getstack(&attr, &low, &sz) != 0 || low is null || sz == 0)
            return StackRegion.init;
        return StackRegion(low, sz);
    }
    else
        return StackRegion.init;
}

private void* currentSP() @trusted pure nothrow @nogc
{
    ubyte probe = void;
    const p = cast(size_t)(cast(void*) &probe);
    return cast(void*) p;
}

private size_t alignDown(size_t value, size_t align_) @safe pure nothrow @nogc
    => value & ~(align_ - 1);

private size_t alignUp(size_t value, size_t align_) @safe pure nothrow @nogc
    => (value + align_ - 1) & ~(align_ - 1);

private void prepareAltStack() @trusted
{
    if (tlsGuard.altStackReady)
        return;
    auto mem = mmap(null, altStackBytes, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mem is cast(void*) -1)
        return;
    stack_t ss;
    ss.ss_sp = mem;
    ss.ss_size = altStackBytes;
    ss.ss_flags = 0;
    if (sigaltstack(&ss, null) != 0)
    {
        munmap(mem, altStackBytes);
        return;
    }
    tlsGuard.altStackReady = true;
}

private void installHandlerOnce() @trusted
{
    if (!cas(&handlerInstalled, false, true))
        return;
    sigaction_t sa;
    sa.sa_sigaction = &onFault;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &oldSegv);
    sigaction(SIGBUS, &sa, &oldBus);
    installedPid = getpid();
}

private void chainPrevious(int sig, siginfo_t* info, void* ctx) @trusted nothrow
{
    // Not the budget's fault. Hand it back: restore the disposition this
    // handler replaced and return, so the faulting instruction re-executes
    // and the signal is delivered as if the runner had never been here —
    // the process dies of SIGSEGV, not of an abort that hides which. A
    // forked child (a test's own `fork`, the forkserver) inherits the
    // handler and gets the same treatment without the diagnostic: its
    // stderr is its parent's to read.
    import core.sys.posix.unistd : getpid, write;

    sigaction(sig, sig == SIGBUS ? &oldBus : &oldSegv, null);
    if (getpid() != installedPid)
        return;

    // Say what faulted — the signal, the address, the guard's state and the
    // test — with nothing but `write(2)`, which is async-signal-safe.
    char[320] line = void;
    size_t n;
    void putText(scope const(char)[] s) nothrow @nogc
    {
        foreach (c; s)
            if (n < line.length)
                line[n++] = c;
    }

    void putHex(size_t v) nothrow @nogc
    {
        char[16] hex = void;
        size_t i = hex.length;
        do
        {
            const d = v & 15;
            hex[--i] = cast(char)(d < 10 ? '0' + d : 'a' + d - 10);
            v >>= 4;
        }
        while (v);
        putText("0x");
        putText(hex[i .. $]);
    }

    putText("stack_budget: fatal signal ");
    putHex(sig);
    putText(" at ");
    putHex(info is null ? 0 : cast(size_t) info.si_addr);
    putText(tlsGuard.protectLen ? ", armed (watermark " : ", unarmed (watermark ");
    putHex(cast(size_t) tlsGuard.usableLow);
    putText(", stack low ");
    putHex(cast(size_t) tlsGuard.stackLow);
    putText("), nesting ");
    putHex(cast(size_t) tlsGuard.nesting);
    if (tlsGuard.label.length)
    {
        putText(", in ");
        putText(tlsGuard.label);
    }
    putText("\n");
    write(2, line.ptr, n);
}

extern (C) private void onFault(int sig, siginfo_t* info, void* ctx) nothrow
{
    if (tlsGuard.nesting <= 0)
    {
        chainPrevious(sig, info, ctx);
        return;
    }
    // Page 0 is a null dereference, not a stack overflow.
    const addr = info is null ? null : info.si_addr;
    if (addr !is null && cast(size_t) addr < 0x1_0000)
    {
        chainPrevious(sig, info, ctx);
        return;
    }
    const usable = tlsGuard.usableLow;
    const low = tlsGuard.stackLow;
    const inProtect = tlsGuard.protectLen != 0
        && addr >= tlsGuard.protectBase
        && addr < cast(void*)(cast(size_t) tlsGuard.protectBase + tlsGuard.protectLen);
    const belowWatermark = usable !is null && addr !is null && addr < usable
        && (low is null || addr >= cast(void*)(cast(size_t) low - pageSize));
    if (!inProtect && !belowWatermark)
    {
        chainPrevious(sig, info, ctx);
        return;
    }
    tlsGuard.nesting = 0;
    siglongjmp(tlsGuard.jmp, 1);
}

private void disarm() @trusted nothrow @nogc
{
    if (tlsGuard.protectLen != 0 && tlsGuard.protectBase !is null)
        mprotect(tlsGuard.protectBase, tlsGuard.protectLen, PROT_READ | PROT_WRITE);
    tlsGuard.protectBase = null;
    tlsGuard.protectLen = 0;
    tlsGuard.usableLow = null;
}

private bool arm() @trusted
{
    auto region = threadStack();
    if (region.low is null || region.size == 0)
        return false;
    const page = pageSize;
    if (page == 0)
        return false;
    auto sp = cast(size_t) currentSP();
    auto low = alignUp(cast(size_t) region.low, page);
    auto watermark = alignDown(sp - stackBudgetBytes, page);
    if (watermark <= low)
        return false;
    const len = watermark - low;
    if (len < page)
        return false;
    if (mprotect(cast(void*) low, len, PROT_NONE) != 0)
        return false;
    tlsGuard.stackLow = region.low;
    tlsGuard.protectBase = cast(void*) low;
    tlsGuard.protectLen = len;
    tlsGuard.usableLow = cast(void*) watermark;
    return true;
}

private void runArmed(scope void delegate() dg, string label)
{
    if (tlsGuard.nesting > 0)
    {
        dg();
        return;
    }
    tlsGuard.label = label;
    scope (exit)
        tlsGuard.label = null;
    if (sigsetjmp(tlsGuard.jmp, 1) != 0)
    {
        disarm();
        throw new StackBudgetExceeded(budgetMessage);
    }
    tlsGuard.nesting = 1;
    const armed = arm();
    scope (exit)
    {
        if (armed)
            disarm();
        tlsGuard.nesting = 0;
    }
    dg();
}

@("stack_budget.workerStackIsPinned")
@system
unittest
{
    import core.thread : Thread;

    shared size_t measured;
    auto t = new Thread({
        measured = currentThreadStackBytes();
    }, workerStackBytes);
    t.start();
    t.join();
    assert(measured >= workerStackBytes,
        "worker stack is smaller than the requested size");
    // glibc adds TLS onto the requested size; allow a page-rounded slack.
    assert(measured <= workerStackBytes + 128 * 1024,
        "worker stack was not pinned near the requested size");
}

@("stack_budget.workerStackBytes.asanGetsRoom")
@safe pure nothrow @nogc
unittest
{
    version (LDC_AddressSanitizer)
        static assert(workerStackBytes == 4 * 1024 * 1024);
    else
        static assert(workerStackBytes == 512 * 1024);
    static assert(stackBudgetBytes < workerStackBytes);
}

@("stack_budget.hogFailsWithNamedError")
@system
unittest
{
    import core.thread : Thread;
    import sparkles.test_runner.skip : skipTest;

    version (LDC_AddressSanitizer)
        skipTest("ASan owns SIGSEGV; the mprotect watermark is disabled");

    installStackBudgetHandler();

    static void hog()
    {
        ubyte[stackBudgetBytes + 64 * 1024] buf;
        buf[0] = 1;
        buf[$ / 2] = 2;
        buf[$ - 1] = 3;
    }

    shared bool failedBudget;
    auto t = new Thread({
        prepareCurrentThreadForStackBudget();
        try
            runWithStackBudget({ hog(); });
        catch (StackBudgetExceeded)
            failedBudget = true;
    }, workerStackBytes);
    t.start();
    t.join();
    assert(failedBudget, "a frame over the 384 KiB watermark must fail");
}

@("stack_budget.smallFramePassesOnWorker")
@system
unittest
{
    import core.thread : Thread;

    installStackBudgetHandler();

    static void tiny()
    {
        int n = 1;
        n += 1;
        assert(n == 2);
    }

    shared bool threw;
    auto t = new Thread({
        prepareCurrentThreadForStackBudget();
        try
            runWithStackBudget({ tiny(); });
        catch (Exception)
            threw = true;
    }, workerStackBytes);
    t.start();
    t.join();
    assert(!threw, "tiny frame failed on a 512 KiB worker");
}

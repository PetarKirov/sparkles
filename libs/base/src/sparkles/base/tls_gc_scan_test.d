/**
Whether the collector scans this thread's thread-local storage.

A GC reference held only in a thread-local variable stays alive only if
druntime hands the collector the right TLS range. A static druntime on
x86/x86_64 Bionic once computed that range as an offset below the TCB, which
is wrong in a `dlopen`'d shared library (ldc-developers/ldc#5311): the
collector swept such references while they were in use. Run in an executable
the shortcut happens to be right, so this test proves the fix only where the
test binary is itself a loaded `.so` — `nix/packages/android/base-tests.nix`
builds it that way too.
*/
module sparkles.base.tls_gc_scan_test;

version (unittest)
{
    private int tlsProbe; // thread-local, as module variables are
}

@("base.tlsGcScan.coversModuleThreadLocals")
@system nothrow
unittest
{
    import core.thread : ScanType, thread_resumeAll, thread_scanAllType, thread_suspendAll;

    auto probe = cast(void*) &tlsProbe;
    bool covered, sawTls;
    // The scan reads every thread's registers and stacks, so the world must
    // be stopped; the delegate only compares addresses.
    thread_suspendAll();
    thread_scanAllType((ScanType type, void* lo, void* hi) nothrow {
        if (type != ScanType.tls)
            return;
        sawTls = true;
        if (lo <= probe && probe < hi)
            covered = true;
    });
    thread_resumeAll();
    assert(sawTls, "the collector scans some thread-local storage");
    assert(covered, "the collector's TLS ranges cover this module's thread-locals");
}

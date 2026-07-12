/**
 * macOS-safe, in-process stack-trace handler for the test runner.
 *
 * On macOS, druntime's default `Throwable.TraceInfo` resolves each frame's
 * source file/line by forking `atos -p <pid>` (see
 * `core.internal.backtrace.dwarf`) and blocking on an un-timed read of its
 * output. Attaching `atos` to the live process needs `task_for_pid`, and on
 * sandboxed CI runners that attach intermittently stalls forever — hanging the
 * entire test binary the instant any test throws, because the runner iterates
 * `thrown.info` in `execution.toThrown`. (Linux is unaffected: its binaries
 * carry embedded DWARF and symbolicate in-process.)
 *
 * This module installs a drop-in replacement handler that keeps the full
 * backtrace — every frame, with demangled symbol names taken from the
 * in-process `backtrace_symbols` — but never spawns `atos`, so it cannot hang.
 * The only thing lost versus the default macOS handler is per-frame source
 * file/line (exactly the part `atos` supplies). The throw-site file/line that
 * `toThrown` records is read from `Throwable.file` / `.line` and is unaffected.
 *
 * `installInProcessTraceHandler` is invoked once at runner start-up on macOS
 * (`runner_impl.sparkles_test_runner_run`). The class and handler compile on
 * every `backtrace`-capable platform, so the logic is exercised by the runner's
 * own unittests on Linux; only the install call is gated to macOS.
 */
module sparkles.test_runner.macos_trace;

import core.internal.execinfo : hasExecinfo;

static if (hasExecinfo)
{
    import core.internal.execinfo : backtrace, backtrace_symbols, getMangledSymbolName;
    import core.demangle : demangle;
    import core.runtime : Runtime;
    import core.stdc.stdlib : free;
    import core.stdc.string : memmove, strlen;

    private enum maxFrames = 128;

    /// A `Throwable.TraceInfo` that symbolicates entirely in-process — via
    /// `backtrace_symbols` + `demangle` — and never spawns `atos`.
    final class InProcessTraceInfo : Throwable.TraceInfo
    {
        private void*[maxFrames] callstack = void;
        private int numframes;

        this() @nogc nothrow
        {
            // Bias each return address back into its CALL instruction's range,
            // matching druntime's `DefaultTraceInfo`.
            enum callInstructionOffset = 1;
            numframes = backtrace(callstack.ptr, maxFrames);
            if (numframes >= 2)
                foreach (ref frame; callstack[0 .. numframes])
                    frame -= callInstructionOffset;
        }

        override int opApply(scope int delegate(ref const(char[])) dg) const
        {
            return opApply((ref size_t, ref const(char[]) buf) => dg(buf));
        }

        override int opApply(scope int delegate(ref size_t, ref const(char[])) dg) const
        {
            auto framelist = backtrace_symbols(callstack.ptr, numframes);
            if (framelist is null)
                return 0;
            scope (exit) free(framelist);

            int ret = 0;
            foreach (size_t pos; 0 .. numframes)
            {
                char[4096] fixbuf = void;
                auto raw = framelist[pos][0 .. strlen(framelist[pos])];
                auto line = demangleFrame(raw, fixbuf);
                ret = dg(pos, line);
                if (ret)
                    break;
            }
            return ret;
        }

        override string toString() const
        {
            string result;
            foreach (const(char[]) line; this)
                result ~= (result.length ? "\n" : "") ~ line.idup;
            return result;
        }
    }

    /// Reformat one `backtrace_symbols` line, demangling the symbol name in
    /// place. Mirrors druntime's private `DefaultTraceInfo.fixline`.
    private const(char)[] demangleFrame(const(char)[] buf, return ref char[4096] fixbuf)
        nothrow @trusted
    {
        static size_t min(size_t a, size_t b) @nogc nothrow pure => a <= b ? a : b;

        size_t symBeg, symEnd;
        getMangledSymbolName(buf, symBeg, symEnd);

        if (symBeg == symEnd || symBeg >= fixbuf.length)
        {
            immutable len = min(buf.length, fixbuf.length);
            fixbuf[0 .. len] = buf[0 .. len];
            return fixbuf[0 .. len];
        }

        fixbuf[0 .. symBeg] = buf[0 .. symBeg];
        auto sym = demangle(buf[symBeg .. symEnd], fixbuf[symBeg .. $]);
        if (sym.ptr !is fixbuf.ptr + symBeg)
        {
            // demangle allocated its own buffer; copy the result back in.
            immutable len = min(fixbuf.length - symBeg, sym.length);
            memmove(fixbuf.ptr + symBeg, sym.ptr, len);
            if (symBeg + len == fixbuf.length)
                return fixbuf[];
        }
        immutable pos = symBeg + sym.length;
        immutable tail = buf.length - symEnd;
        immutable len = min(fixbuf.length - pos, tail);
        fixbuf[pos .. pos + len] = buf[symEnd .. symEnd + len];
        return fixbuf[0 .. pos + len];
    }

    /// `Runtime.traceHandler`-compatible factory. Allocated on the GC — the test
    /// process has one, and passing a `null` deallocator lets the GC reclaim it.
    Throwable.TraceInfo inProcessTraceHandler(void* ptr = null) nothrow
    {
        return new InProcessTraceInfo();
    }

    /// Install the in-process handler process-wide. Idempotent; called once at
    /// runner start-up on macOS. (`Runtime.traceHandler`'s setter is not
    /// `nothrow`, so neither is this.)
    void installInProcessTraceHandler() @system
    {
        Runtime.traceHandler(&inProcessTraceHandler, null);
    }

    @("macos_trace.InProcessTraceInfo.capturesFullBacktraceWithoutAtos")
    @system unittest
    {
        // The handler captures a non-empty, symbolicated backtrace purely
        // in-process — no `atos` is ever spawned (structurally: this file never
        // references it). Here we only assert it yields frames and formats them.
        auto info = new InProcessTraceInfo();

        size_t count;
        bool nonEmptyLine;
        foreach (size_t i, const(char[]) line; info)
        {
            count++;
            if (line.length)
                nonEmptyLine = true;
        }
        assert(count > 0, "expected a non-empty in-process backtrace");
        assert(nonEmptyLine, "expected at least one symbolicated frame");

        // toString mirrors opApply and must not be empty for a captured trace.
        assert(info.toString().length > 0);
    }

    @("macos_trace.inProcessTraceHandler.returnsUsableTraceInfo")
    @system unittest
    {
        auto ti = inProcessTraceHandler();
        assert(ti !is null);
        size_t frames;
        foreach (const(char[]) line; ti)
            frames++;
        assert(frames > 0);
    }
}

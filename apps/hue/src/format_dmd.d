/**
The in-process D formatter provider behind the format preview
([spec](../../../docs/specs/hue/format-preview.md) `FPR2`/`FPR7`): a thin
adapter over `sparkles:dmd-fmt` that keeps the rest of hue free of `dmd.*`
imports. Compiled only under the `HueDmdFmt` version (the `application`,
`no-gui` and `unittest` configurations — never `android`); elsewhere this is
an empty module, the `android_glue.d` pattern.

The base `FormatConfig` comes from `.editorconfig` discovery for the file
being viewed (dfmt keys honored — dmd-fmt M7); the ruler overrides exactly
one knob, the soft maximum line length.
*/
module format_dmd;

version (HueDmdFmt)  :  // strip the whole module outside the gated configs

import sparkles.dmd_fmt.config : configFor, FormatConfig;
import sparkles.dmd_fmt.printer : formatText;

/// Format D `source` at `widthCols`. Total: unparseable input degrades to
/// bracket-only structure inside `formatText`, it never fails.
string formatDSource(const(char)[] source, string path, ushort widthCols) @system
{
    auto cfg = configFor(path, FormatConfig());
    cfg.softMaxLineLength = widthCols;
    return formatText(source, cfg);
}

// The FP0 gate: the whole in-process design rests on `formatText` being
// repeat-safe within one process (DMD's frontend globals survive re-use; the
// module lock serializes). A failure here invalidates FPR2 before any UI
// code exists.
@("format_dmd.repeatedInProcessUse")
@system unittest
{
    enum source = q"SRC
module spike;

struct Widget { int x; int y; string label; }

int layout(Widget[] widgets, int available, int spacing, bool wrapRows, int minCell)
{
    int used = 0;
    foreach (w; widgets)
    {
        used += w.x + spacing;
        if (wrapRows && used > available)
            used = minCell;
    }
    return used;
}
SRC";

    const at80 = formatDSource(source, "spike.d", 80);
    assert(at80.length, "formatDSource returned empty output");
    foreach (i; 0 .. 50)
    {
        // From 1, not 40: the ruler's floor is 1 (`minRulerCol`), so the
        // narrow widths a drag to the gutter reaches are part of the gate.
        const width = cast(ushort) (1 + (i * 7) % 240);
        const got = formatDSource(source, "spike.d", width);
        assert(got.length, "formatDSource returned empty output");
    }
    // Determinism across repeats: the 51st format at a width seen before
    // yields the same bytes (no state accumulation between runs).
    assert(formatDSource(source, "spike.d", 80) == at80);
}

@("format_dmd.worksFromNonMainThread")
@system unittest
{
    import core.thread : Thread;

    // The format service runs the provider off the UI thread (FPR9); prove
    // the DMD substrate holds away from the main thread too.
    string got;
    auto t = new Thread({ got = formatDSource("int  a;\n", "spike.d", 80); });
    t.start();
    t.join();
    assert(got == "int a;\n");
}

/// The ruler's starting column for `path` (`FPR7`): the discovered
/// `.editorconfig` soft max (dfmt keys honored). Total — no config files
/// found means the formatter's default.
ushort discoveredWidth(string path) @system
    => cast(ushort) configFor(path, FormatConfig()).softMaxLineLength;

// ── the fork-server execution backend (FPR10 / event-horizon M18) ───────────
// The zygote runs `warmDmdFrontend` once; every per-request grandchild then
// inherits initialized DMD globals by CoW — no repeated init, no lock, and a
// frontend crash costs one format, not hue.

version (Posix)
{
    import sparkles.event_horizon.forkserver : ForkServer, ForkServerConfig;

    private __gshared ForkServer formatForkServer;
    private __gshared bool formatForkUp;

    /// Wire framing for a fork-format request:
    /// `[ushort width][uint pathLen][path][source]`.
    ubyte[] encodeForkFormat(const(char)[] source, string path,
        ushort widthCols) @system
    {
        auto buf = new ubyte[](2 + 4 + path.length + source.length);
        buf[0] = widthCols & 0xff;
        buf[1] = (widthCols >> 8) & 0xff;
        const plen = cast(uint) path.length;
        buf[2 .. 6] = [cast(ubyte)(plen & 0xff), cast(ubyte)((plen >> 8) & 0xff),
            cast(ubyte)((plen >> 16) & 0xff), cast(ubyte)((plen >> 24) & 0xff)];
        buf[6 .. 6 + path.length] = cast(const(ubyte)[]) path;
        buf[6 + path.length .. $] = cast(const(ubyte)[]) source;
        return buf;
    }

    /// The grandchild's work: decode, format, publish. Top-level function —
    /// the zygote runs the pointer.
    private size_t forkFormatHandler(scope const(ubyte)[] input, uint kind,
        scope ubyte[] output) @system
    {
        cast(void) kind;
        if (input.length < 6)
            return size_t.max;
        const width = cast(ushort)(input[0] | (input[1] << 8));
        const plen = input[2] | (input[3] << 8) | (input[4] << 16)
            | (input[5] << 24);
        if (6 + plen > input.length)
            return size_t.max;
        const path = cast(const(char)[]) input[6 .. 6 + plen];
        const source = cast(const(char)[]) input[6 + plen .. $];
        const text = formatDSource(source, path.idup, width);
        if (text.length > output.length)
            return size_t.max;
        output[0 .. text.length] = cast(const(ubyte)[]) text;
        return text.length;
    }

    /// The zygote's one-time init: run the whole pipeline once so `Id`,
    /// `global` and the lexer/parse tables initialize — the CoW payload.
    private void warmDmdFrontend() @system
    {
        cast(void) formatDSource("int a;\n", "warmup.d", 120);
    }

    /**
    Fork the format zygote (`FPR10`). Call from the app entry $(B before any
    thread exists); refusal (already threaded, non-Posix, fork failure) is
    quiet — the provider falls back to the worker-thread backend.
    */
    bool startFormatForkServer() @system
    {
        if (formatForkUp)
            return true;
        const r = ForkServer.start(formatForkServer, &forkFormatHandler,
            ForkServerConfig(slots: 2, childInit: &warmDmdFrontend));
        formatForkUp = !r.hasError;
        return formatForkUp;
    }

    /// The running server, or null (the thread backend's cue).
    ForkServer* formatForkInstance() @system
        => formatForkUp ? &formatForkServer : null;
}
else
{
    bool startFormatForkServer() @safe => false;
    typeof(null) formatForkInstance() @safe => null;
}

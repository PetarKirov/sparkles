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
        const width = cast(ushort) (40 + (i * 7) % 200);
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

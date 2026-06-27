/**
 * Layer 10 — width vs Python's `wcwidth` (jquast), the de-facto width model of
 * the Python TUI ecosystem (prompt_toolkit, blessed, pytest, …).
 *
 * Python is embedded **in process** via PyD (the engine behind autowrap), not a
 * subprocess: `py_init` once, `py_import("wcwidth")`, then a single bulk
 * `InterpContext` evaluation per axis (a list comprehension over all inputs) so
 * the 297k-code-point sweep is one interpreter call, not 297k.
 *
 *   - per code point (ratcheted, like Layer 5): `wcwidth.wcwidth(chr(cp))` vs
 *     `codepointWidth` over assigned scalars;
 *   - per string (informational note): `wcwidth.wcswidth(s)` vs `visibleWidth`.
 *
 * PyD requires the fixed upstream (PR #172, untagged) — the harness pins it by
 * commit. Gated behind `version(TextConformancePython)`; runtime-skips if the
 * `wcwidth` module can't be imported.
 */
module sparkles.text_conformance.layer10_python_wcwidth;

import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.utf : byDchar;

import sparkles.base.text.grapheme : visibleWidth;
import sparkles.base.text.width : codepointWidth;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.corpus : emojiStrings, graphemeBreakStrings;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.ucd : loadWidthData, WidthData;
import sparkles.text_conformance.util : cpClass, isNoncharacter;

version (TextConformancePython)
{
    import pyd.pyd : py_init;
    import pyd.embedded : InterpContext;
    import pyd.pydobject : PydObject;
    import sparkles.utf8proc;

    // Initialise the embedded interpreter lazily (only when Layer 10 runs), so
    // an unrelated `--layers 0` invocation needn't bring up libpython.
    private __gshared bool _pyReady;
    private void ensurePython()
    {
        if (!_pyReady) { py_init(); _pyReady = true; }
    }

    // Convert a Python list of ints element-wise. (Avoids PyD's
    // `python_to_d!(int[])` buffer-protocol path, which doesn't compile on D
    // 2.111 — a switch-fallthrough in make_object.match_format_type.)
    private int[] pyIntList(PydObject list)
    {
        const n = list.length;
        auto r = new int[](n);
        foreach (i; 0 .. n)
            r[i] = list[i].to_d!int;
        return r;
    }
}


version (TextConformancePython)
LayerResult runLayer10(in Config cfg)
{
    LayerResult r;
    r.name = "10: python wcwidth";

    InterpContext ctx;
    try
    {
        ensurePython();
        ctx = new InterpContext();
        ctx.py_stmts("import wcwidth"); // fail fast if the module is missing
    }
    catch (Exception e)
    {
        r.skipped = true;
        r.skipReason = "python wcwidth module unavailable (set PYTHONPATH): " ~ e.msg;
        return r;
    }

    auto d = loadWidthData(cfg);

    // --- per code point, over assigned scalars (one bulk interpreter call) ---
    int[] cps;
    dchar[] dcps;
    foreach (uint cp; 0 .. 0x110000)
    {
        if (cp >= 0xD800 && cp <= 0xDFFF)
            continue;
        if (utf8proc_category(cast(int) cp) == UTF8PROC_CATEGORY_CN && !isNoncharacter(cast(dchar) cp))
            continue;
        cps ~= cast(int) cp;
        dcps ~= cast(dchar) cp;
    }

    ctx.cps = cps;
    // __import__ (a builtin) is used inside the comprehension because its inner
    // expression runs in a scope that can't see the context's imported names.
    auto pw = pyIntList(ctx.py_eval("[__import__('wcwidth').wcwidth(chr(c)) for c in cps]"));
    if (pw.length != dcps.length)
        throw new Exception(format("wcwidth: got %s widths for %s inputs", pw.length, dcps.length));

    size_t[string] buckets;
    foreach (i, cp; dcps)
    {
        const got = codepointWidth(cp);
        if (got == pw[i])
        {
            r.passed++;
            continue;
        }
        buckets[cpClass(cp, d)]++;
        r.divergences ~= Divergence(10, format("U+%04X", cast(uint) cp),
            got.to!string, pw[i].to!string, causeOf(cp, d));
    }
    foreach (k, n; buckets)
        r.notes ~= format("%s: %d", k, n);

    // --- per string, over the corpus (informational: grapheme-(un)awareness) ---
    auto corpus = emojiStrings(cfg) ~ graphemeBreakStrings(cfg);
    ctx.strs = corpus;
    auto sw = pyIntList(ctx.py_eval("[__import__('wcwidth').wcswidth(s) for s in strs]"));
    size_t agree, diff;
    foreach (i, s; corpus)
        if (i < sw.length && cast(int) visibleWidth(s) == sw[i])
            agree++;
        else
            diff++;
    r.notes ~= format("per-string: agrees %s/%s; %s diffs (not ratcheted)",
        agree, corpus.length, diff);

    return r;
}
else
LayerResult runLayer10(in Config cfg)
{
    LayerResult r;
    r.name = "10: python wcwidth";
    r.skipped = true;
    r.skipReason = "built without PyD/python (use the default 'application' config)";
    return r;
}

private string causeOf(dchar cp, in WidthData d) @safe nothrow
{
    if (cp >= 0x1F1E6 && cp <= 0x1F1FF)
        return "regional indicator: sparkles applies kitty's flag rule (2); wcwidth gives 1";
    if (isNoncharacter(cp))
        return "noncharacter: sparkles 0; wcwidth differs";
    if (cp >= 0x1160 && cp <= 0x11FF)
        return "conjoining Hangul jamo: sparkles forces 0; wcwidth differs";
    if (codepointWidth(cp) == 0)
        return "control/zero-width: sparkles 0; wcwidth returns -1 for non-printable";
    if (d.mn[cp] || d.mc[cp] || d.me[cp] || d.cf[cp])
        return "Mark/format: width-class or version difference";
    return "codepointWidth vs python wcwidth";
}

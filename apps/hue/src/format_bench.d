/**
Where a ruler drag's time actually goes.

The format preview's per-width cost splits across two threads: the provider
runs on the format service (`FPR9`), but everything after it — re-highlight,
buffer swap, re-wrap, re-layout — runs on the UI thread, so only that second
half can stall a frame. These benchmarks decompose it, over a synthetic
~2 kLOC D module reformatted at rotating widths (a drag never revisits the
same buffer twice in a row, which is what keeps every retained parse cold).

Run with `dub test :hue -- --bench -i format_preview.bench`.

Test-only module: `@benchmark` lives in the test-runner shim, a dependency of
the unittest configuration alone.
*/
module format_bench;

version (unittest):
version (HueDmdFmt):

import std.process : environment;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.syntax : builtinDark, GrammarRegistry, HighlightEvent,
    highlightInjected, LabelSet, TsConfigCache;
import sparkles.syntax.ts.highlighter : ParsedLayer;
import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchIter, blackBox;
import sparkles.test_runner.skip : skipTest;

import format_dmd : formatDSource;
import gui_preview : PreviewModel;
import sparkles.twoslash.protocol : TwoslashReturn;
import viewer_model : ViewerModel;

// ~2 kLOC of ordinary D: a 20-line unit repeated 100 times with unique names,
// wide enough that the ruler's travel actually re-wraps lines.
private string bigSource() @safe
{
    import std.array : appender;
    import std.format : formattedWrite;

    static string cached;
    if (cached.length)
        return cached;

    auto w = appender!string;
    w.put("module bench_fixture;\n\n");
    foreach (i; 0 .. 100)
        w.formattedWrite!(
            "/// Frobnicates the %1$s-th widget.\n" ~
            "auto frob%1$s(T, U)(T input, U seed, string label) @safe pure\n" ~
            "if (isInputRange!T && is(U : long))\n" ~
            "in (seed > 0)\n" ~
            "{\n" ~
            "    // local bookkeeping\n" ~
            "    auto acc = seed + %1$s + input.length * 3 + label.length;\n" ~
            "    if (acc > 1) { acc = frobImpl(input, acc, label, seed); }\n" ~
            "    version (Tracing) { trace(\"frob%1$s\", acc, label); }\n" ~
            "    return wrap(acc, label, seed, input);\n" ~
            "}\n" ~
            "\n" ~
            "struct Widget%1$s\n" ~
            "{\n" ~
            "    int x = %1$s;\n" ~
            "    string name = \"widget-%1$s\";\n" ~
            "    invariant (x >= 0);\n" ~
            "    int scaled() const @safe pure nothrow => x * 2;\n" ~
            "}\n" ~
            "\n")(i);
    cached = w[];
    return cached;
}

/// The widths a drag sweeps through, pre-formatted once so the timed loop
/// measures one phase and not the provider.
private string[] formattedWidths() @system
{
    static string[] cached;
    if (cached.length)
        return cached;
    foreach (i; 0 .. 8)
        cached ~= formatDSource(bigSource(), "bench.d", cast(ushort)(72 + i * 8));
    return cached;
}

private bool grammarsAvailable() @safe
    => environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length != 0;

// ── phase 1: the provider (runs OFF the UI thread) ──────────────────────────

@("format_preview.bench.format-2kloc")
@benchmark @system unittest
{
    const source = bigSource();
    ushort w = 72;
    benchIter({
        w = cast(ushort)(w == 128 ? 72 : w + 8);
        auto out_ = formatDSource(source, "bench.d", w);
        blackBox(out_.length);
    }, ["phase": "provider", "thread": "format-service", "corpus": "2kloc-d"]);
}

// ── the grammar-backed fixture ─────────────────────────────────────────────

// A class, so the registry, the config cache that points at it and the model
// all live at stable heap addresses: `benchIter`'s body is a delegate, and a
// closure that reaches a `TsConfigCache` whose registry sits in the enclosing
// stack frame crashes under the GC traffic these loops generate.
private final class BenchFixture
{
    GrammarRegistry reg;
    TsConfigCache cache;
    LabelSet labels;
    ViewerModel vm;
    string[] texts;
    HighlightEvent[][] events;

    this() @system
    {
        reg = GrammarRegistry.fromEnvironment();
        labels = LabelSet.standard();
        cache = TsConfigCache.create(&reg, labels);
        texts = formattedWidths();

        vm.names = ["dark"];
        vm.themes = [builtinDark];
        vm.labels = labels;
        vm.cache = &cache;
        vm.widthCols = 120;
        vm.applyTheme(0);
        const src = bigSource();
        vm.setDocument("bench.d", "", src,
            [HighlightEvent.sourceSpan(0, src.length)], PreviewModel.init,
            TwoslashReturn.init, "d");
    }

    ParsedLayer*[][] layers;

    /// Highlight events (and their parses) per width, so a leg can time the
    /// rebuild alone — with or without a parse to adopt.
    void precomputeEvents() @system
    {
        foreach (t; texts)
        {
            SmallBuffer!HighlightEvent ev;
            ParsedLayer*[] ls;
            cast(void) highlightInjected(cache, "d", t, ev, ls).hasError;
            events ~= ev[].dup;
            layers ~= ls;
        }
    }

    /// What `FormatPreviewSession.rehighlight` does, verbatim — including
    /// keeping the layers, which is what spares the rebuild a second parse.
    HighlightEvent[] highlight(string text, out ParsedLayer*[] layers) @system
    {
        SmallBuffer!HighlightEvent ev;
        if (highlightInjected(cache, "d", text, ev, layers).hasError)
        {
            layers = null;
            ev.clear();
            ev ~= HighlightEvent.sourceSpan(0, text.length);
        }
        return ev[].dup;
    }
}

// ── phase 2: re-highlight (UI thread) ───────────────────────────────────────

@("format_preview.bench.rehighlight-2kloc")
@benchmark @system unittest
{
    if (!grammarsAvailable)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto fx = new BenchFixture;
    size_t i;
    benchIter({
        // A fresh allocation per iteration: the real path idups the
        // provider's buffer, and slice identity is what keeps every retained
        // parse honest.
        ParsedLayer*[] layers;
        auto ev = fx.highlight(fx.texts[i++ % fx.texts.length].idup, layers);
        blackBox(ev.length);
    }, ["phase": "rehighlight", "thread": "ui", "corpus": "2kloc-d"]);
}

// ── phase 3: the buffer swap (UI thread) ────────────────────────────────────

@("format_preview.bench.swapContent-2kloc")
@benchmark @system unittest
{
    if (!grammarsAvailable)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto fx = new BenchFixture;
    fx.precomputeEvents();
    size_t i;
    benchIter({
        const k = i++ % fx.texts.length;
        fx.vm.swapContent(fx.texts[k].idup, fx.events[k]);
        blackBox(fx.vm.rows.length);
    }, ["phase": "swap-rebuild", "thread": "ui", "corpus": "2kloc-d"]);
}

// The same rebuild with the parse handed over — a cache hit's redisplay, and
// what every applied width costs once `rehighlight`'s layers travel with it.
@("format_preview.bench.swapContent-adopted-2kloc")
@benchmark @system unittest
{
    if (!grammarsAvailable)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto fx = new BenchFixture;
    fx.precomputeEvents();
    size_t i;
    benchIter({
        const k = i++ % fx.texts.length;
        fx.vm.swapContent(fx.texts[k], fx.events[k], fx.layers[k]);
        blackBox(fx.vm.rows.length);
    }, ["phase": "swap-adopted", "thread": "ui", "corpus": "2kloc-d"]);
}

// ── the whole UI-thread stall, as `pump` actually spends it ─────────────────

@("format_preview.bench.applyWidth-2kloc")
@benchmark @system unittest
{
    if (!grammarsAvailable)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto fx = new BenchFixture;
    size_t i;
    benchIter({
        const text = fx.texts[i++ % fx.texts.length].idup;
        ParsedLayer*[] layers;
        auto ev = fx.highlight(text, layers);
        fx.vm.swapContent(text, ev, layers);
        blackBox(fx.vm.rows.length);
    }, ["phase": "ui-apply-total", "thread": "ui", "corpus": "2kloc-d"]);

}

// The same apply with the parse thrown away — what the path cost before the
// layers were carried through, kept as the standing comparison leg.
@("format_preview.bench.applyWidth-reparsing-2kloc")
@benchmark @system unittest
{
    if (!grammarsAvailable)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto fx = new BenchFixture;
    size_t i;
    benchIter({
        const text = fx.texts[i++ % fx.texts.length].idup;
        ParsedLayer*[] layers;
        auto ev = fx.highlight(text, layers);
        fx.vm.swapContent(text, ev);
        blackBox(fx.vm.rows.length);
    }, ["phase": "ui-apply-reparse", "thread": "ui", "corpus": "2kloc-d"]);
}

// ── the parse itself, the cost the two apply legs differ by ────────────────

@("format_preview.bench.parseLayers-2kloc")
@benchmark @system unittest
{
    import sparkles.syntax.ts.highlighter : parseLayers;

    if (!grammarsAvailable)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto fx = new BenchFixture;
    size_t i;
    benchIter({
        const text = fx.texts[i++ % fx.texts.length].idup;
        ParsedLayer*[] layers;
        const failed = parseLayers(fx.cache, "d", text, layers).hasError;
        assert(!failed);
        blackBox(layers.length);
    }, ["phase": "retained-parse", "thread": "ui", "corpus": "2kloc-d"]);
}

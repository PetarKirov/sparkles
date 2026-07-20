/++
The `@benchmark` matrix: renderer × viewport-size × background, plus a
theme-switch scenario.

`name` is the varying dimension compared per row (the renderer / scenario);
`size`, `bg`, and `lang` are labels (`--group-by=size,bg` gives one table per
group). Metrics per row: throughput as MB/s of *source* highlighted
(`Unit("B")` rate — comparable across renderers and against the foreign panel)
and output bytes per render (`Unit("B")` level — this is what balloons when the
page background is emitted, so it makes the regression legible).

Cases:
    - `ansi`        renderAnsi over the cached event stream (one theme). The
        app's per-frame cost once events are parsed.
    - `ansi-switch` for each theme in a rotation: resolveTheme + renderAnsi.
        The interactive theme-switch hot path (what got slow).
    - `html`        renderHtml over the cached event stream.

The `bg` label toggles `AnsiOptions.emitBackground` — the exact axis the
background-color feature flips, so baseline-vs-regression is one column.

Subset with $SYNTAX_BENCH_MODES, $SYNTAX_BENCH_SIZES, $SYNTAX_BENCH_LANGS
(comma lists; empty = all). Parsing (tree-sitter) is untimed setup. Run:

    dub test -b bench --root=libs/syntax/bench/render -- --bench --group-by=size,bg
+/
module sparkles.syntax_render_bench.runner;

import std.array : Appender;

import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, blackBox, Metric, Unit;

import sparkles.syntax.color : ColorDepth;
import sparkles.syntax.event : HighlightEvent;
import sparkles.syntax.label : LabelSet;
import sparkles.syntax.render.ansi : renderAnsi, AnsiOptions;
import sparkles.syntax.render.html : renderHtml, HtmlOptions, HtmlMode;
import sparkles.syntax.theme : ResolvedTheme, resolveTheme, Theme;
import sparkles.syntax.themes : builtinThemes, builtinDark;

import sparkles.syntax_render_bench.corpus : corpora, parse, sized;

// Fixed color tier: the regression shows at any depth, and trueColor is what
// modern terminals negotiate — pinning it keeps rows comparable and avoids the
// env-dependent detectColorDepth().
private enum ColorDepth depth = ColorDepth.trueColor;

private struct SizeSpec
{
    size_t lines; // 0 = whole file
    string label;
}

// Viewport heights (visible code lines) the app would render per frame, plus
// the whole file for a steady end-to-end throughput number.
private immutable SizeSpec[] sizes = [
    SizeSpec(24, "24l"),
    SizeSpec(40, "40l"),
    SizeSpec(51, "51l"),
    SizeSpec(0, "full"),
];

// The theme rotation for `ansi-switch` — a representative spread across the
// builtin set. Missing names are skipped (kept resilient to theme renames).
private immutable string[] switchThemes = [
    "catppuccin-mocha", "catppuccin-latte", "dracula", "nord",
    "gruvbox-dark", "solarized-dark", "tokyo-night", "one-dark",
];

@("render")
@benchmark
@system
unittest
{
    const labels = LabelSet.standard();
    bool any;
    foreach (const ref c; corpora)
    {
        if (!envAllows("SYNTAX_BENCH_LANGS", c.lang))
            continue;
        foreach (const ref sz; sizes)
        {
            if (!envAllows("SYNTAX_BENCH_SIZES", sz.label))
                continue;

            const source = c.source.sized(sz.lines);
            auto events = parse(c.lang, source, labels);

            if (envAllows("SYNTAX_BENCH_MODES", "ansi"))
                foreach (bg; [false, true])
                {
                    registerAnsi(c.lang, source, events, labels, sz, bg);
                    any = true;
                }
            if (envAllows("SYNTAX_BENCH_MODES", "ansi-switch"))
            {
                foreach (bg; [false, true])
                {
                    registerSwitch(c.lang, source, events, labels, sz, bg);
                    any = true;
                }
            }
            if (envAllows("SYNTAX_BENCH_MODES", "html"))
            {
                registerHtml(c.lang, source, events, labels, sz);
                any = true;
            }
            // The apps/hue per-frame path, measured both ways on the whole file:
            // `whole` renders the entire source then slices (the theme-switch
            // regression); `viewport` slices first (the fix). Only meaningful at
            // full size, where "whole" ≫ "viewport".
            if (sz.lines == 0 && envAllows("SYNTAX_BENCH_MODES", "app-frame"))
            {
                foreach (viewport; [false, true])
                    registerAppFrame(c.lang, source, events, labels, viewport);
                any = true;
            }
        }
    }
    if (!any)
        benchCase(name: "(filtered out)", timed: () {}, after: () {});
}

// --- ansi: render cached events with one resolved theme --------------------

private void registerAnsi(string lang, string source, HighlightEvent[] events,
    LabelSet labels, in SizeSpec sz, bool bg)
{
    static struct St
    {
        string source;
        HighlightEvent[] events;
        ResolvedTheme theme;
        AnsiOptions opts;
        Appender!(char[]) sink;
    }

    auto st = new St;
    st.source = source;
    st.events = events;
    st.theme = resolveNamed("catppuccin-mocha", labels);
    st.opts = AnsiOptions(depth: depth, italics: true, emitBackground: bg);

    const outBytes = renderedAnsiBytes(source, events, st.theme, st.opts);

    benchCase(
        name: "ansi",
        timed: () {
        st.sink.clear();
        renderAnsi(st.source, st.events, st.theme, st.sink, st.opts);
        blackBox(st.sink.data.length);
    },
        after: () {},
        metrics: throughput(source.length, outBytes),
        labels: ["lang": lang, "size": sz.label, "bg": bg ? "on" : "off"],
    );
}

// --- ansi-switch: resolve + render, rotating themes (the hot path) ---------

private void registerSwitch(string lang, string source, HighlightEvent[] events,
    LabelSet labels, in SizeSpec sz, bool bg)
{
    static struct St
    {
        string source;
        HighlightEvent[] events;
        LabelSet labels;
        immutable(Theme)*[] themes;
        AnsiOptions opts;
        Appender!(char[]) sink;
    }

    auto st = new St;
    st.source = source;
    st.events = events;
    st.labels = labels;
    st.opts = AnsiOptions(depth: depth, italics: true, emitBackground: bg);
    foreach (n; switchThemes)
        if (auto t = n in builtinThemes)
            st.themes ~= t;
    if (st.themes.length == 0)
        st.themes ~= &builtinDark;

    // Output bytes for the level metric: average across the rotation.
    size_t total;
    foreach (t; st.themes)
        total += renderedAnsiBytes(source, events, resolveTheme(*t, labels), st.opts);
    const outBytes = total / st.themes.length;

    benchCase(
        name: "ansi-switch",
        timed: () {
        foreach (t; st.themes)
        {
            // Exactly the app's per-frame work: re-resolve the theme, then
            // render the cached events into a reused buffer.
            const resolved = resolveTheme(*t, st.labels);
            st.sink.clear();
            renderAnsi(st.source, st.events, resolved, st.sink, st.opts);
            blackBox(st.sink.data.length);
        }
    },
        after: () {},
        // Work per iteration = the whole rotation, so the rate is themes-worth
        // of source bytes per second.
        metrics: throughput(source.length * st.themes.length, outBytes),
        labels: ["lang": lang, "size": sz.label, "bg": bg ? "on" : "off"],
    );
}

// --- html: render cached events --------------------------------------------

private void registerHtml(string lang, string source, HighlightEvent[] events,
    LabelSet labels, in SizeSpec sz)
{
    static struct St
    {
        string source;
        HighlightEvent[] events;
        ResolvedTheme theme;
        HtmlOptions opts;
        Appender!(char[]) sink;
    }

    auto st = new St;
    st.source = source;
    st.events = events;
    st.theme = resolveNamed("catppuccin-mocha", labels);
    st.opts = HtmlOptions(mode: HtmlMode.cssClasses);

    Appender!(char[]) probe;
    renderHtml(source, events, st.theme, probe, st.opts);
    const outBytes = probe.data.length;

    benchCase(
        name: "html",
        timed: () {
        st.sink.clear();
        renderHtml(st.source, st.events, st.theme, st.sink, st.opts);
        blackBox(st.sink.data.length);
    },
        after: () {},
        metrics: throughput(source.length, outBytes),
        labels: ["lang": lang, "size": sz.label],
    );
}

// --- app-frame: the apps/hue per-frame path (render + idup + splitLines) ----

private void registerAppFrame(string lang, string source, HighlightEvent[] events,
    LabelSet labels, bool viewport)
{
    import std.string : splitLines;

    static struct St
    {
        string source;
        HighlightEvent[] events;
        ResolvedTheme theme;
        AnsiOptions opts;
        Appender!(char[]) sink;
    }

    enum size_t viewportLines = 40; // a typical terminal height

    auto st = new St;
    // `viewport` slices to the visible lines first (the fix); `whole` renders
    // the entire file then would slice (the regression). Events stay the full
    // stream either way — renderAnsi clamps spans to the source length, exactly
    // as the app does with its parse-once event buffer.
    st.source = viewport ? source.sized(viewportLines) : source;
    st.events = events;
    st.theme = resolveNamed("catppuccin-mocha", labels);
    st.opts = AnsiOptions(depth: depth, italics: true, emitBackground: true);

    const outBytes = renderedAnsiBytes(st.source, events, st.theme, st.opts);

    benchCase(
        name: "app-frame",
        timed: () {
        st.sink.clear();
        renderAnsi(st.source, st.events, st.theme, st.sink, st.opts);
        // The app copies the render out and splits it into lines every frame —
        // both are GC allocations the viewport fix shrinks by the same factor.
        auto rendered = st.sink.data.idup;
        auto lines = rendered.splitLines();
        blackBox(lines.length);
    },
        after: () {},
        metrics: throughput(st.source.length, outBytes),
        labels: ["lang": lang, "frame": viewport ? "viewport" : "whole"],
    );
}

// --- helpers ---------------------------------------------------------------

private Metric[] throughput(size_t sourceBytes, size_t outBytes) @safe pure nothrow
{
    return [
        Metric(unit: Unit("B"), amount: cast(double) sourceBytes, mode: Metric.Mode.rate),
        Metric(unit: Unit("B"), amount: cast(double) outBytes, mode: Metric.Mode.level),
    ];
}

private size_t renderedAnsiBytes(string source, HighlightEvent[] events,
    in ResolvedTheme theme, in AnsiOptions opts) @safe
{
    Appender!(char[]) probe;
    renderAnsi(source, events, theme, probe, opts);
    return probe.data.length;
}

private ResolvedTheme resolveNamed(string name, LabelSet labels) @safe nothrow
{
    if (auto t = name in builtinThemes)
        return resolveTheme(*t, labels);
    return resolveTheme(builtinDark, labels);
}

private bool envAllows(string var, string name) @safe
{
    import std.algorithm : canFind, splitter;
    import std.process : environment;

    const v = environment.get(var, "");
    return v.length == 0 || v.splitter(',').canFind(name);
}

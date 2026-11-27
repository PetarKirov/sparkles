/**
Where a DSV scroll notch's time actually goes.

`DSN4` bounded the *build*: the grid materializes a window of rows rather
than the whole file, and the first paint went from 756 ms to 31 ms. What it
did not bound was everything upstream of the build — a window change re-sniffed,
re-parsed and re-projected the entire buffer before slicing ~50 rows out of the
result. These benchmarks decompose one scroll notch into the phases
`Workspace.applyDsvBrowser` actually runs, which is what aimed `DSN7` at the
model rather than at the widget tree:

$(UL
$(LI `sniff` / `parse` / `project` — the **model** half, O(file))
$(LI `adapt-window` — the windowed table synthesis, O(window))
$(LI `view` / `layout` / `display-list` — the **view** half, O(window)))

The `scroll-notch-*` legs are the before/after pair: `-resolving-` re-derives
the model per notch (the pre-`DSN7` path, kept as the standing comparison),
`-retained-` queries a `DsvModel` the host holds for the life of the document.

Run with

---
dub test :hue -b bench -- --bench -i dsv.bench \
    --perf --metrics=instr --perf-iters=8 --bench-min-time 200
---

`-b bench` is required — the runner warns that assert-enabled numbers are
meaningless. The other three matter almost as much: without a pinned counting
pass and a wide enough wall budget the auto-scaler batches different legs
differently, and at this scale the medians wander far enough to invert a
comparison. Compare `instr/iter` rather than wall time whenever the question is
whether something does less work.

Every leg is a batched case (`BenchTiming.batched`) that owns what it reads.

Test-only module: `@benchCases` lives in the test-runner shim, a dependency of
the unittest configuration alone.
*/
module dsv_bench;

version (unittest):

import std.array : appender;

import sparkles.dsv : applyProjection, ColumnType, detectHeader, Dialect,
    DsvDoc,
    inferColumnTypes, parseDsv, ProjectionSpec, seedForExtension, sniff,
    sniffMaxBytes, sniffMaxRecords, SortKey;
import sparkles.base.buffer : SharedBuffer;
import sparkles.syntax : HighlightEvent, TsConfigCache;
import sparkles.test_runner.attributes : benchCases;
import sparkles.test_runner.bench : BenchTiming, benchCase, blackBox;
import sparkles.ui.themes : builtinDark;

import sparkles.doc_view.dsv_view : adaptDsv, DsvAdapted, DsvFlags, DsvModel, DsvProjection,
    DsvWindow;
import sparkles.doc_view.preview_model : PreviewModel, previewOf;
import sparkles.doc_view.viewer_model : ViewerModel;

/// The corpus: a `files.csv`-shaped table — one row per tracked file, the
/// column mix (paths, sizes, extensions, dates) the sample corpus generates —
/// at the scale that made scrolling visibly slow.
private string bigCsv(size_t rows) @safe
{
    import std.format : formattedWrite;

    static string[size_t] cached;
    if (auto hit = rows in cached)
        return *hit;

    auto w = appender!string;
    w.put("path,lines,bytes,ext,author,modified,commits,churn\n");
    static immutable exts = ["d", "md", "nix", "sdl", "json", "c"];
    static immutable dirs = ["libs/base", "libs/ui", "apps/hue",
        "libs/event-horizon", "docs/research/ui-layout", "nix/packages"];
    foreach (i; 0 .. rows)
        w.formattedWrite!"%s/module_%s.%s,%s,%s,%s,Petar Kirov,2026-%02d-%02d,%s,%s\n"(
            dirs[i % dirs.length], i, exts[i % exts.length],
            40 + i % 900, 1024 + i * 7, exts[i % exts.length],
            1 + i % 12, 1 + i % 28, i % 50, i % 3000);
    cached[rows] = w[];
    return cached[rows];
}

/// The window a pane of ordinary height materializes (`dsvWindowRows`).
private enum windowRows = 48;

/// The rows the benchmarks scale over — the corpus file is ~3 k rows.
private enum benchRows = 3012;

/// The resolved dialect, so a phase leg times its own phase and not the
/// sniffer that precedes it.
private Dialect benchDialect(string src) @safe
{
    const len = src.length < sniffMaxBytes ? src.length : sniffMaxBytes;
    return sniff(src[0 .. len], seedForExtension("csv")).dialect;
}

// ── the model half: O(file), re-run on every window change ─────────────────

@("dsv.bench.parse-3k")
@benchCases @safe unittest
{
    static struct Parse
    {
        enum timing = BenchTiming.batched;
        string src;
        Dialect dialect;

        void timed() @safe
        {
            auto parsed = parseDsv(src, dialect);
            blackBox(parsed.value.records.length);
        }
    }

    const src = bigCsv(benchRows);
    benchCase(Parse(src, benchDialect(src)),
        labels: ["phase": "parse", "scope": "whole-file", "rows": "3012"]);
}

/// The parsed model a phase leg reads: the corpus parsed and typed once,
/// outside the timed loop. The assertions in the legs check that it is the
/// whole corpus, so a leg that timed an empty document would fail.
private final class ModelFixture
{
    string src;
    typeof(parseDsv("", Dialect.init)) parsed;
    DsvDoc doc;
    SharedBuffer!(ColumnType, 16) types;

    this() @safe
    {
        src = bigCsv(benchRows);
        parsed = parseDsv(src, benchDialect(src));
        doc = parsed.value;
        doc.hasHeader = true;
        inferColumnTypes(doc, sniffMaxRecords, types);
    }

    size_t project(in ProjectionSpec spec) @safe
    {
        SharedBuffer!(uint, 64) perm;
        applyProjection(doc, types[], spec, perm);
        return perm.length;
    }
}

/// A whole-file projection of the model under `spec`.
private struct Project
{
    enum timing = BenchTiming.batched;
    ModelFixture fx;
    ProjectionSpec spec;

    void timed() @safe
    {
        const n = fx.project(spec);
        assert(n == benchRows, "the projection must cover every row");
        blackBox(n);
    }
}

@("dsv.bench.project-3k")
@benchCases @safe unittest
{
    benchCase(Project(new ModelFixture),
        labels: ["phase": "project", "scope": "whole-file", "sort": "none"]);
}

@("dsv.bench.project-sorted-3k")
@benchCases @safe unittest
{
    ProjectionSpec spec;
    spec.sortKeys = [SortKey(column: 1, descending: false)];
    benchCase(Project(new ModelFixture, spec),
        labels: ["phase": "project", "scope": "whole-file", "sort": "one-key"]);
}

/// The sniffer, which `adaptDsv` re-runs on every call even when the caller
/// already knows the dialect — over a sample bounded at `sniffMaxBytes`
/// (256 KiB), i.e. essentially the whole of a file this size.
@("dsv.bench.sniff-3k")
@benchCases @safe unittest
{
    static struct Sniff
    {
        enum timing = BenchTiming.batched;
        string sample;

        void timed() @safe
        {
            const s = sniff(sample, seedForExtension("csv"));
            blackBox(s.dialect.delimiter);
        }
    }

    const src = bigCsv(benchRows);
    const len = src.length < sniffMaxBytes ? src.length : sniffMaxBytes;
    benchCase(Sniff(src[0 .. len]),
        labels: ["phase": "sniff", "scope": "256KiB-sample", "rows": "3012"]);
}

@("dsv.bench.detectHeader-3k")
@benchCases @safe unittest
{
    static struct DetectHeader
    {
        enum timing = BenchTiming.batched;
        ModelFixture fx;

        void timed() @safe { blackBox(detectHeader(fx.doc)); }
    }

    benchCase(DetectHeader(new ModelFixture),
        labels: ["phase": "detect-header", "scope": "bounded", "rows": "3012"]);
}

@("dsv.bench.inferTypes-3k")
@benchCases @safe unittest
{
    static struct InferTypes
    {
        enum timing = BenchTiming.batched;
        ModelFixture fx;

        void timed() @safe
        {
            SharedBuffer!(ColumnType, 16) t;
            inferColumnTypes(fx.doc, sniffMaxRecords, t);
            blackBox(t.length);
        }
    }

    benchCase(InferTypes(new ModelFixture),
        labels: ["phase": "infer-types", "scope": "100-record-sample", "rows": "3012"]);
}

// ── what a scroll notch pays today, end to end through the adapter ─────────

/// `adaptDsv` over a window of `src` that moves `step` rows per iteration,
/// wrapping at `wrap`.
private struct AdaptWindow
{
    enum timing = BenchTiming.batched;
    string src;
    uint step;
    uint wrap;
    uint top;

    void timed() @safe
    {
        top = (top + step) % wrap;
        auto a = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
            DsvWindow(start: top, rows: windowRows));
        blackBox(a.text.length);
    }
}

@("dsv.bench.adapt-window-3k")
@benchCases @safe unittest
{
    benchCase(AdaptWindow(bigCsv(benchRows), windowRows, benchRows - windowRows),
        labels: ["phase": "adapt-window", "scope": "model+build", "rows": "3012"]);
}

/// The same adaptation with no window — the pre-`DSN4` cost, kept as the
/// standing comparison leg for what windowing already bought.
@("dsv.bench.adapt-whole-3k")
@benchCases @safe unittest
{
    static struct AdaptWhole
    {
        enum timing = BenchTiming.batched;
        string src;

        void timed() @safe
        {
            auto a = adaptDsv(src, "csv", DsvFlags());
            blackBox(a.text.length);
        }
    }

    benchCase(AdaptWhole(bigCsv(benchRows)),
        labels: ["phase": "adapt-whole", "scope": "model+build", "rows": "3012"]);
}

/// The build alone, with the model hoisted out of the timed loop — the floor
/// a scroll notch could reach if the parse and the projection were retained.
@("dsv.bench.adapt-window-100")
@benchCases @safe unittest
{
    benchCase(AdaptWindow(bigCsv(100), 8, 40),
        labels: ["phase": "adapt-window", "scope": "model+build", "rows": "100"]);
}

// ── the view half: O(window) already ───────────────────────────────────────

private final class ViewFixture
{
    TsConfigCache cache;
    ViewerModel vm;
    string[] texts;          /// one materialized window per scroll position
    PreviewModel[] previews;

    this(size_t positions) @system
    {
        const src = bigCsv(benchRows);
        vm.names = ["dark"];
        vm.themes = [builtinDark];
        vm.widthCols = 120;
        vm.applyTheme(0);

        foreach (i; 0 .. positions)
        {
            auto a = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
                DsvWindow(start: cast(uint)(i * windowRows), rows: windowRows));
            auto pm = previewOf(cache, a.doc);
            pm.tableExtras = a.extras;
            texts ~= a.text;
            previews ~= pm;
        }

        auto ev = new HighlightEvent[](1);
        ev[0] = HighlightEvent.sourceSpan(0, texts[0].length);
        vm.setDocument("bench.csv", "", texts[0], ev, previews[0],
            typeof(vm.tw).init, "csv");
    }

    HighlightEvent[] spanFor(size_t i) @safe
    {
        auto ev = new HighlightEvent[](1);
        ev[0] = HighlightEvent.sourceSpan(0, texts[i].length);
        return ev;
    }
}

/// `previewOf`: the md preview model over the built window (fence
/// highlighting, decorations). No grammar is needed — a DSV window is one
/// table block and no fences.
@("dsv.bench.previewOf-window")
@benchCases @system unittest
{
    static struct PreviewOfWindow
    {
        enum timing = BenchTiming.batched;
        TsConfigCache cache;
        DsvAdapted a;

        void setup()
        {
            a = adaptDsv(bigCsv(benchRows), "csv", DsvFlags(), DsvProjection.init,
                DsvWindow(start: 0, rows: windowRows));
        }

        void timed()
        {
            auto pm = previewOf(cache, a.doc);
            blackBox(pm.doc.root.children.length);
        }
    }

    benchCase(PreviewOfWindow(),
        labels: ["phase": "preview-model", "scope": "window", "rows": "48"]);
}

/// `ViewerModel.remateralizeWindow`: md model → widget tree → layout →
/// display list, over one window. This is the whole view half of a notch.
@("dsv.bench.remateralize-window")
@benchCases @system unittest
{
    static struct Remateralize
    {
        enum timing = BenchTiming.batched;
        ViewFixture fx;
        size_t i;

        void timed()
        {
            const k = i++ % fx.texts.length;
            fx.vm.remateralizeWindow(fx.texts[k], fx.spanFor(k), fx.previews[k]);
            blackBox(fx.vm.ops.length);
        }
    }

    benchCase(Remateralize(new ViewFixture(8)),
        labels: ["phase": "view+layout+ops", "scope": "window", "rows": "48"]);
}

/// One scroll notch the way it was spent **before `DSN7`**: re-derive the
/// whole model under `proj`, then build and re-materialize the window.
private struct ScrollNotchResolving
{
    enum timing = BenchTiming.batched;
    ViewFixture fx;
    DsvProjection proj;
    string src;
    TsConfigCache cache;
    uint top;

    void setup() { src = bigCsv(benchRows); }

    void timed()
    {
        top = (top + windowRows) % (benchRows - windowRows);
        auto a = adaptDsv(src, "csv", DsvFlags(), proj,
            DsvWindow(start: top, rows: windowRows));
        remateralize(fx, cache, a);
    }
}

/// The same notch over a **retained model** (`DSN7`), resolved once in
/// `setup`, outside the timed loop, exactly as a host holds it for the life of
/// the document.
private struct ScrollNotchRetained
{
    enum timing = BenchTiming.batched;
    ViewFixture fx;
    DsvProjection proj;
    DsvModel model;
    TsConfigCache cache;
    uint top;

    void setup() { model = DsvModel.of(bigCsv(benchRows), "csv", DsvFlags()); }

    void timed()
    {
        top = (top + windowRows) % (benchRows - windowRows);
        auto a = adaptDsv(model, proj, DsvWindow(start: top, rows: windowRows));
        remateralize(fx, cache, a);
    }
}

/// The view half of a notch: `a`'s preview model, re-materialized into `fx`.
private void remateralize(ViewFixture fx, ref TsConfigCache cache, ref DsvAdapted a)
    @system
{
    auto pm = previewOf(cache, a.doc);
    pm.tableExtras = a.extras;
    auto ev = new HighlightEvent[](1);
    ev[0] = HighlightEvent.sourceSpan(0, a.text.length);
    fx.vm.remateralizeWindow(a.text, ev, pm);
    blackBox(fx.vm.ops.length);
}

/// The pre-`DSN7` notch, kept as the standing comparison leg.
@("dsv.bench.scroll-notch-resolving-3k")
@benchCases @system unittest
{
    benchCase(ScrollNotchResolving(new ViewFixture(1)),
        labels: ["phase": "scroll-notch", "model": "re-derived",
            "scope": "model+build+view", "rows": "3012"]);
}

/// What a scroll costs now.
@("dsv.bench.scroll-notch-retained-3k")
@benchCases @system unittest
{
    benchCase(ScrollNotchRetained(new ViewFixture(1)),
        labels: ["phase": "scroll-notch", "model": "retained",
            "scope": "build+view", "rows": "3012"]);
}

/// The sorted case, which is where re-deriving hurt most: the permutation is
/// a function of the projection, and a scroll does not change the projection.
@("dsv.bench.scroll-notch-sorted-resolving-3k")
@benchCases @system unittest
{
    DsvProjection proj;
    proj.spec = ProjectionSpec(sortKeys: [SortKey(column: 1)]);
    benchCase(ScrollNotchResolving(new ViewFixture(1), proj),
        labels: ["phase": "scroll-notch", "model": "re-derived",
            "scope": "model+build+view", "rows": "3012-sorted"]);
}

/// ditto, retained.
@("dsv.bench.scroll-notch-sorted-retained-3k")
@benchCases @system unittest
{
    DsvProjection proj;
    proj.spec = ProjectionSpec(sortKeys: [SortKey(column: 1)]);
    benchCase(ScrollNotchRetained(new ViewFixture(1), proj),
        labels: ["phase": "scroll-notch", "model": "retained",
            "scope": "build+view", "rows": "3012-sorted"]);
}

// ── inside the view half: where the remaining 26.6M instructions go ─────────
//
// `DSN7` left the notch dominated by the view rebuild. These legs isolate the
// two stages with clean inputs — layout over the built arena, and the display
// list over the laid-out frames — so the remainder (the md-model-to-arena
// build, plus `derive`/`keyedRects`/`collectStructure`) is what
// `remateralize-window` costs minus these. The next round gets aimed the same
// way this one was.

/// A fixture whose preview model is already built, so a leg times one stage.
private final class StageFixture
{
    TsConfigCache cache;
    ViewerModel vm;
    string text;
    PreviewModel preview;

    this() @system
    {
        auto a = adaptDsv(DsvModel.of(bigCsv(benchRows), "csv", DsvFlags()),
            DsvProjection.init, DsvWindow(start: 600, rows: windowRows));
        text = a.text;
        preview = previewOf(cache, a.doc);
        preview.tableExtras = a.extras;

        vm.names = ["dark"];
        vm.themes = [builtinDark];
        vm.widthCols = 120;
        vm.applyTheme(0);
        auto ev = new HighlightEvent[](1);
        ev[0] = HighlightEvent.sourceSpan(0, text.length);
        vm.setDocument("bench.csv", "", text, ev, preview,
            typeof(vm.tw).init, "csv");
    }
}

/// One stage over a `StageFixture`: `stage(fx)` is what is timed.
private struct Stage(alias stage)
{
    enum timing = BenchTiming.batched;
    StageFixture fx;

    void timed() { stage(fx); }
}

/// Stage 2 — box-flow layout over that arena.
@("dsv.bench.stage-layout")
@benchCases @system unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    static void stage(StageFixture fx)
    {
        auto frames = layout(fx.vm.tree, Constraints(maxW: fx.vm.widthCols));
        blackBox(frames.length);
    }

    benchCase(Stage!stage(new StageFixture),
        labels: ["stage": "2-layout", "scope": "window", "rows": "48"]);
}

/// Stage 3 — the display list (slot resolution + clip stack + draw ops).
@("dsv.bench.stage-displayList")
@benchCases @system unittest
{
    import sparkles.ui.display_list : buildDisplayList;

    static void stage(StageFixture fx)
    {
        auto ops = buildDisplayList(fx.vm.tree, fx.vm.frames,
            fx.vm.palette, fx.vm.pageFg, fx.vm.pageBg);
        blackBox(ops.length);
    }

    benchCase(Stage!stage(new StageFixture),
        labels: ["stage": "3-display-list", "scope": "window", "rows": "48"]);
}

/// Stage 1 — the md model becomes a widget arena (`viewMarkdownInto`), into
/// a fresh builder per iteration or (`retained`) one kept across them. The
/// options are the table-relevant subset the viewer builds; the grid path
/// touches no fences, links or folds, so the rest are defaults.
private struct ViewMarkdown(bool retained)
{
    import sparkles.source_view.markdown : MdViewOptions, viewMarkdownInto;
    import sparkles.ui.widget : Builder;

    enum timing = BenchTiming.batched;
    StageFixture fx;
    // On the heap: the options hold a (here unset) delegate, which a case may
    // not hold itself.
    MdViewOptions* opt;
    static if (retained)
        Builder* mb;

    void setup()
    {
        opt = new MdViewOptions;
        opt.maxWidth = 120;
        opt.tableExtras = fx.preview.tableExtras;
        static if (retained)
            mb = new Builder;
    }

    void timed()
    {
        static if (retained)
        {
            mb.reset();
            blackBox(viewMarkdownInto(*mb, fx.preview.doc, *opt));
        }
        else
        {
            auto fresh = Builder();
            blackBox(viewMarkdownInto(fresh, fx.preview.doc, *opt));
        }
    }
}

@("dsv.bench.stage-viewMarkdown")
@benchCases @system unittest
{
    benchCase(ViewMarkdown!false(new StageFixture),
        labels: ["stage": "1-view", "scope": "window", "rows": "48", "arena": "fresh"]);
}

/// Stage 1, with the arena kept (`DSN9`). Same tree, same nodes — the only
/// difference is that the builder was not thrown away after the last frame,
/// so the 3307 `Widget`s are written over storage the view already owns.
@("dsv.bench.stage-viewMarkdown-retained")
@benchCases @system unittest
{
    benchCase(ViewMarkdown!true(new StageFixture),
        labels: ["stage": "1-view", "scope": "window", "rows": "48", "arena": "retained"]);
}

/// Stage 4 — `keyedRects`, one of the derived-data passes that run after the
/// display list on every rebuild.
@("dsv.bench.stage-keyedRects")
@benchCases @system unittest
{
    import sparkles.ui.state : keyedRects;

    static void stage(StageFixture fx)
    {
        blackBox(keyedRects(fx.vm.tree, fx.vm.frames).length);
    }

    benchCase(Stage!stage(new StageFixture),
        labels: ["stage": "4-keyed-rects", "scope": "window", "rows": "48"]);
}

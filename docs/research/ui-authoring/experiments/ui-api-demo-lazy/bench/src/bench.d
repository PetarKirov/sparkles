/**
Build cost per node of three `sparkles:ui` authoring prototypes producing the
same tree: inside-out (`insideout.d`), lazy variadic children
(`../../ui_sketch.d`) and scoped `with` (`scoped.d`).
*/
module bench;

import std.format : format;

import sparkles.test_runner.attributes : benchCases;
import sparkles.test_runner.bench : benchCase, blackBox, Metric, Unit;

import model;
static import insideout, scoped, ui_sketch, lazystack, lazysplit, lazysoa;
static import views_insideout, views_lazy, views_lazystack, views_lazysplit, views_lazysoa, views_scoped;

private const(MemberRow)[] makeRows(size_t n)
{
    auto rows = new MemberRow[n];
    foreach (i, ref r; rows)
        r = MemberRow(format("row%06d", i), format("value-%06d", i));
    return rows;
}

private struct Input
{
    string shape;  // "stats" or "panels"
    size_t size;   // rows, or panel depth
    IdsView ids;
}

private enum Builder { insideOut, lazyVariadic, lazyStack, lazySplit, lazySoa, scopedWith }

private struct Built { ulong hash; size_t count; }

/// Builds `input` once on builder `b` into a heap-owned `Ui`, checksums it.
private Built buildOnce(Builder b)(Input input)
{
    auto c = BuildCase!b(input);
    c.timed();
    auto r = c.check();
    c.ui.reset();
    return r;
}

/// One build case on builder `b`, also the reference build. The `Ui` is
/// heap-owned (its text pool and argument arena are ~20 MiB; test workers
/// have 512 KiB stacks).
private struct BuildCase(Builder b)
{
    static if (b == Builder.insideOut)
    {
        alias UiT = insideout.Ui;
        alias NodeT = insideout.Node;
    }
    else static if (b == Builder.lazyVariadic)
    {
        alias UiT = ui_sketch.Ui;
        alias NodeT = ui_sketch.Node;
    }
    else static if (b == Builder.lazyStack || b == Builder.lazySplit || b == Builder.lazySoa)
    {
        alias UiT = StackModule!b.Ui;
        alias NodeT = StackModule!b.Node;
    }
    else
        alias UiT = scoped.Ui!StatsMsg;

    Input input;
    Built expected; // what `after` checks against (unused by `buildOnce`)
    UiT* ui;
    Stats stats;
    typeof(Env!b(comfortable: true)) env;
    static if (b != Builder.scopedWith)
        NodeT root;

    this(Input input, Built expected = Built.init)
    {
        this.input = input;
        this.expected = expected;
        stats = Stats(true, 300);
        env = Env!b(comfortable: true);
        ui = new UiT;
        static if (b != Builder.insideOut && b != Builder.scopedWith)
            ui.expectMsg!StatsMsg;
    }

    size_t timed()
    {
        static if (b == Builder.insideOut)
        {
            root = input.shape == "stats"
                ? views_insideout.statsPane(*ui, blackBox(stats), blackBox(input.ids))
                : views_insideout.panel(*ui, blackBox(cast(uint) input.size));
            return blackBox(root.index);
        }
        else static if (b == Builder.lazyVariadic)
        {
            root = input.shape == "stats"
                ? ui.frame(env, views_lazy.statsPane(*ui, blackBox(stats), blackBox(input.ids)))
                : ui.frame(env, views_lazy.panel(*ui, blackBox(cast(uint) input.size)));
            return blackBox(root.index);
        }
        else static if (b == Builder.scopedWith)
        {
            with (ui.frame(env))
            {
                if (input.shape == "stats")
                    views_scoped.statsPane(*ui, blackBox(stats), blackBox(input.ids));
                else
                    views_scoped.panel(*ui, blackBox(cast(uint) input.size));
            }
            return blackBox(cast(size_t) ui.viewRoot);
        }
        else
        {
            alias V = StackViews!b;
            root = input.shape == "stats"
                ? ui.frame(env, V.statsPane(*ui, blackBox(stats), blackBox(input.ids)))
                : ui.frame(env, V.panel(*ui, blackBox(cast(uint) input.size)));
            return blackBox(root.index);
        }
    }

    Built check()
    {
        Built r;
        static if (b == Builder.scopedWith)
            ui.checksum(ui.viewRoot, r.hash, r.count);
        else
            ui.checksum(root, r.hash, r.count);
        return r;
    }

    /// Untimed after every build: the tree must be the reference's, and the
    /// `Ui` is reset for the next one.
    void after(ref size_t)
    {
        const got = check();
        if (got.hash != expected.hash || got.count != expected.count)
            throw new Exception(format("tree mismatch: %s nodes #%016x, expected %s #%016x",
                got.count, got.hash, expected.count, expected.hash));
        ui.reset();
    }
}

/// The children-stack builders' modules: one source, three storage layouts.
private template StackModule(Builder b)
{
    static if (b == Builder.lazyStack)
        alias StackModule = lazystack;
    else static if (b == Builder.lazySplit)
        alias StackModule = lazysplit;
    else
        alias StackModule = lazysoa;
}

/// ditto, their views.
private template StackViews(Builder b)
{
    static if (b == Builder.lazyStack)
        alias StackViews = views_lazystack;
    else static if (b == Builder.lazySplit)
        alias StackViews = views_lazysplit;
    else
        alias StackViews = views_lazysoa;
}

private string builderName(Builder b)
{
    final switch (b)
    {
        case Builder.insideOut: return "inside-out";
        case Builder.lazyVariadic: return "lazy-variadic";
        case Builder.lazyStack: return "lazy-stack";
        case Builder.lazySplit: return "lazy-split";
        case Builder.lazySoa: return "lazy-soa";
        case Builder.scopedWith: return "scoped-with";
    }
}

/// The positions pass after a build: the tree is built once (untimed), then
/// `place` is timed; `after` checks the positions against the reference.
private ulong placeOnce(Builder b)(Input input)
{
    alias M = StackModule!b;
    auto ui = new M.Ui;
    ui.expectMsg!StatsMsg;
    const env = Env!b(comfortable: true);
    const stats = Stats(true, 300);
    cast(void) (input.shape == "stats"
        ? ui.frame(env, StackViews!b.statsPane(*ui, stats, input.ids))
        : ui.frame(env, StackViews!b.panel(*ui, cast(uint) input.size)));
    ui.place();
    return ui.positionsHash();
}

/// The positions pass on a tree built at registration (untimed): `place` is
/// timed, and `after` checks the positions against the reference.
private struct PlaceCase(Builder b)
{
    StackModule!b.Ui* ui;
    ulong expected;

    size_t timed()
    {
        ui.place();
        return blackBox(cast(size_t) 0);
    }

    void after(ref size_t)
    {
        const got = ui.positionsHash();
        if (got != expected)
            throw new Exception(format("positions mismatch: #%016x, expected #%016x", got, expected));
    }
}

private void registerPlace(Builder b)(Input input, size_t nodes, ulong expected)
{
    alias M = StackModule!b;
    auto ui = new M.Ui;
    ui.expectMsg!StatsMsg;
    const env = Env!b(comfortable: true);
    const stats = Stats(true, 300);
    cast(void) (input.shape == "stats"
        ? ui.frame(env, StackViews!b.statsPane(*ui, stats, input.ids))
        : ui.frame(env, StackViews!b.panel(*ui, cast(uint) input.size)));
    benchCase(PlaceCase!b(ui, expected),
        name: builderName(b),
        labels: ["shape": input.shape, "size": format("%s=%s", input.shape == "stats" ? "rows" : "depth", input.size),
            "nodes": format("%s", nodes), "pass": "place"],
        metrics: [Metric(Unit("node"), nodes, Metric.Mode.rate)]);
}

/// Each builder's own `Env`, comfortable and wide.

private auto Env(Builder b)(bool comfortable)
{
    static if (b == Builder.insideOut)
        return insideout.Env(insideout.Layout.wide, insideout.Density.comfortable);
    else static if (b == Builder.lazyVariadic)
        return ui_sketch.Env(ui_sketch.Layout.wide, ui_sketch.Density.comfortable);
    else static if (b == Builder.lazyStack || b == Builder.lazySplit || b == Builder.lazySoa)
        return StackModule!b.Env(StackModule!b.Layout.wide, StackModule!b.Density.comfortable);
    else
        return scoped.Env(scoped.Layout.wide, scoped.Density.comfortable);
}

private void register(Builder b)(Input input, Built expected)
{
    benchCase(BuildCase!b(input, expected),
        name: builderName(b),
        labels: ["shape": input.shape, "size": format("%s=%s", input.shape == "stats" ? "rows" : "depth", input.size),
            "nodes": format("%s", expected.count), "pass": "build"],
        metrics: [Metric(Unit("node"), expected.count, Metric.Mode.rate)]);
}

@("ui.build") @benchCases @system
unittest
{
    Input[] inputs;
    foreach (n; [10, 1000, 100_000])
        inputs ~= Input("stats", n, IdsView(true, "ab", makeRows(n)));
    foreach (d; [4, 9, 14])
        inputs ~= Input("panels", d);

    foreach (input; inputs)
    {
        // The reference: every builder must produce this tree.
        const expected = buildOnce!(Builder.lazyVariadic)(input);
        foreach (b; [buildOnce!(Builder.insideOut)(input), buildOnce!(Builder.lazyStack)(input), buildOnce!(Builder.lazySplit)(input),
                buildOnce!(Builder.lazySoa)(input), buildOnce!(Builder.scopedWith)(input)])
            assert(b == expected, format("%s/%s: builders disagree: %s vs %s",
                input.shape, input.size, b, expected));
        register!(Builder.insideOut)(input, expected);
        register!(Builder.lazyVariadic)(input, expected);
        register!(Builder.lazyStack)(input, expected);
        register!(Builder.lazySplit)(input, expected);
        register!(Builder.lazySoa)(input, expected);
        // the positions pass, on the three storage layouts
        const placed = placeOnce!(Builder.lazyStack)(input);
        foreach (p; [placeOnce!(Builder.lazySplit)(input), placeOnce!(Builder.lazySoa)(input)])
            assert(p == placed, format("%s/%s: positions disagree", input.shape, input.size));
        registerPlace!(Builder.lazyStack)(input, expected.count, placed);
        registerPlace!(Builder.lazySplit)(input, expected.count, placed);
        registerPlace!(Builder.lazySoa)(input, expected.count, placed);
        register!(Builder.scopedWith)(input, expected);
    }
}

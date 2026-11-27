/**
The Clay builder's cases (`clayui.d`, `views_clay.d`, Clay by ImportC), beside
`bench.d`'s: the same inputs, checked against the same reference tree
(`lazy-stack`'s, which `bench.d` asserts equals every other builder's).

- `clay-build`: `Clay_BeginLayout` + declaring every element (each element's
    fit size is computed at its `Clay__CloseElement`) — the other builders'
    build. `Clay_EndLayout` runs untimed in `after`, keeping Clay's cross-frame
    state as a real frame loop would.
- `clay-full`: the same plus `Clay_EndLayout` (the remaining sizing passes,
    positions, render commands), timed.
- `clay-side`: `clay-build` plus the per-leaf side work the sketches do and
    Clay does not (texts interned into a `BumpTextPool`, `ui.on` messages copied
    into an arena + table).

Not `rows=100000`: Clay keeps an element's child count in a `uint16_t`
(`Clay__LayoutElementChildren.length`), so a column of 100 003 children wraps
(34 467 seen) and its fit size and child list are wrong.
*/
module bench_clay;

import std.format : format;

import sparkles.test_runner.attributes : benchCases;
import sparkles.test_runner.bench : benchCase, blackBox, Metric, Unit;

import model;
static import lazystack, views_lazystack;
import clayui : ClayUi;
static import views_clay;

private const(MemberRow)[] makeRows(size_t n)
{
    auto rows = new MemberRow[n];
    foreach (i, ref r; rows)
        r = MemberRow(format("row%06d", i), format("value-%06d", i));
    return rows;
}

private struct Input
{
    string shape;
    size_t size;
    IdsView ids;
}

private struct Built { ulong hash; size_t count; }

private enum Variant { build, full, side }

/// The reference tree, on `lazy-stack`.
private Built reference(Input input)
{
    const stats = Stats(true, 300);
    auto ui = new lazystack.Ui;
    ui.expectMsg!StatsMsg;
    const env = lazystack.Env(lazystack.Layout.wide, lazystack.Density.comfortable);
    const root = input.shape == "stats"
        ? ui.frame(env, views_lazystack.statsPane(*ui, stats, input.ids))
        : ui.frame(env, views_lazystack.panel(*ui, cast(uint) input.size));
    Built r;
    ui.checksum(root, r.hash, r.count);
    ui.reset();
    return r;
}

/// One Clay case on variant `v`, its `ClayUi` heap-owned.
private struct ClayCase(Variant v)
{
    enum side = v == Variant.side;

    Input input;
    Built expected;
    ClayUi!side* ui;
    Stats stats;

    this(Input input, Built expected)
    {
        this.input = input;
        this.expected = expected;
        stats = Stats(true, 300);
        ui = new ClayUi!side;
        ui.setup(cast(int) expected.count + 16);
    }

    size_t timed()
    {
        ui.begin();
        if (input.shape == "stats")
            views_clay.statsPane(*ui, blackBox(stats), blackBox(input.ids));
        else
            views_clay.panel(*ui, blackBox(cast(uint) input.size));
        static if (v == Variant.full)
            return blackBox(cast(size_t) ui.end().length);
        else
            return blackBox(ui.elementCount);
    }

    Built check()
    {
        Built r;
        ui.checksum(ui.viewRoot, r.hash, r.count);
        if (ui.errorCount)
            throw new Exception(format("Clay reported %s errors", ui.errorCount));
        return r;
    }

    /// Untimed after every build: the tree must be the reference's; the
    /// frame is ended (unless timed) and the `ClayUi` reset.
    void after(ref size_t)
    {
        const got = check();
        if (got.hash != expected.hash || got.count != expected.count)
            throw new Exception(format("tree mismatch: %s nodes #%016x, expected %s #%016x",
                got.count, got.hash, expected.count, expected.hash));
        static if (v != Variant.full)
            cast(void) ui.end();
        ui.reset();
    }
}

private void register(Variant v)(Input input, Built expected)
{
    auto c = ClayCase!v(input, expected);
    // the tree once, before registering
    cast(void) c.timed();
    const got = c.check();
    assert(got == expected, format("clay %s/%s: %s vs %s", input.shape, input.size, got, expected));
    static if (v != Variant.full)
        cast(void) c.ui.end();
    c.ui.reset();

    benchCase(c,
        name: v == Variant.build ? "clay-build" : v == Variant.full ? "clay-full" : "clay-side",
        labels: ["shape": input.shape, "size": format("%s=%s", input.shape == "stats" ? "rows" : "depth", input.size),
            "nodes": format("%s", expected.count), "pass": v == Variant.full ? "build+end" : "build"],
        metrics: [Metric(Unit("node"), expected.count, Metric.Mode.rate)]);
}

@("ui.build.clay") @benchCases @system
unittest
{
    Input[] inputs;
    foreach (n; [10, 1000]) // not 100_000: see the module comment
        inputs ~= Input("stats", n, IdsView(true, "ab", makeRows(n)));
    foreach (d; [4, 9, 14])
        inputs ~= Input("panels", d);

    foreach (input; inputs)
    {
        const expected = reference(input);
        register!(Variant.build)(input, expected);
        register!(Variant.full)(input, expected);
        register!(Variant.side)(input, expected);
    }
}

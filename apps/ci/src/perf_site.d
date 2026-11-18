/++
`ci perf site` (observability §17): the dashboard, built from the verified
history as static pages.

Three layers, so a new view is one function:

$(LIST
    $(ITEM $(LREF SiteData): the records, read and verified once, and what
        OBJ5 derives from them.)
    $(ITEM Panels: each tab is a list of $(LREF Panel) values, built by a
        pure function of the data. A panel is data: its kind, its series,
        its labels.)
    $(ITEM Renderers: one per panel kind, writing plain HTML and CSS. No
        script, no chart library, nothing loaded from elsewhere (OBW3).)
)

The same panel functions, filtered to one pull request, make its page.
+/
module perf_site;

import std.algorithm.comparison : max, min;
import std.algorithm.iteration : filter, map, sum, uniq;
import std.algorithm.searching : any, canFind, countUntil, endsWith, maxElement, minElement, startsWith;
import std.algorithm.sorting : sort;
import std.array : Appender, appender, array, join, replace, split;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.format : format;
import std.math : ceil, round, sqrt;
import std.string : strip;

import sparkles.docs.options : ChromePalette, escapeInto;
import sparkles.docs.sidebar : sidebarCss, sidebarItemsHtml, SidebarItem;

import perf_pr : figuresOf, groupOf, PrFigures, PrJob, PrRecord, Scope;

// === The data (layer 1) ===

/// One package's wall time, in seconds, on one placement for one landing.
struct PackageWall
{
    string placement;
    long pr;
    string pkg;
    double seconds;
}

/// Which packages a pull request's paths reach (OBW2, Test selection).
struct Reach
{
    long pr;
    size_t reached;
    size_t total;
    bool everything;  /// a path outside every package and the docs
    string[] why;     /// those paths' top directories, or the root files
    double testShare; /// the reached packages' share of a run's test time
}

/// A runner type's price per minute, from `ci/runner-rates.json`.
struct RunnerRate
{
    string runner;
    double perMinute; /// NaN when the file leaves it unset
}

/// Everything the pages are built from.
struct SiteData
{
    PrRecord[] records; /// by merge time
    PrFigures[] figures; /// the same order
    PackageWall[] walls;
    Reach[] reach;
    RunnerRate[] rates;
    string tip; /// the history commit the site was built from
}

/// The figures of `records`, kept in merge order.
SiteData withFigures(PrRecord[] records) @safe
{
    SiteData d;
    d.records = records.sort!((a, b) => a.merged < b.merged || (a.merged == b.merged && a.number < b.number))
        .release;
    d.figures = d.records.map!(r => figuresOf(r)).array;
    return d;
}

/**
Which packages `paths` reach, by ownership: a path a package's directory
holds seeds that package and its dependents; a path under `docs/`, or a
Markdown file at the root, seeds none; any other path seeds every package.
`owner` maps a path to its package or `null`; `dependents` a package to the
ones depending on it, directly.
*/
Reach reachOf(long pr, in string[] paths, scope string delegate(string) @safe owner,
    in string[][string] dependents, in string[] all, in double[string] testShare) @safe
{
    Reach r = Reach(pr, 0, all.length);
    bool[string] seen;
    string[] queue;
    foreach (p; paths)
    {
        const o = owner(p);
        if (o.length)
        {
            if (o !in seen)
            {
                seen[o] = true;
                queue ~= o;
            }
            continue;
        }
        if (p.startsWith("docs/") || (p.endsWith(".md") && !p.canFind('/')))
            continue;
        r.everything = true;
        const slash = p.countUntil('/');
        const top = slash > 0 ? p[0 .. slash + 1] : p;
        if (!r.why.canFind(top))
            r.why ~= top;
    }
    if (r.everything)
    {
        r.reached = all.length;
        r.testShare = 1;
        r.why.sort;
        return r;
    }
    while (queue.length)
    {
        const x = queue[0];
        queue = queue[1 .. $];
        foreach (y; dependents.get(x, null))
            if (y !in seen)
            {
                seen[y] = true;
                queue ~= y;
            }
    }
    r.reached = seen.length;
    r.testShare = seen.keys.map!(k => testShare.get(k, 0.0)).sum;
    return r;
}

@("perfSite.reachOf.ownershipAndDependents")
@safe unittest
{
    string owner(string p) @safe => p.startsWith("libs/base/") ? "base" : p.startsWith("libs/ui/") ? "ui" : null;
    const deps = ["base": ["ui"], "ui": ["hue"]];
    const all = ["base", "hue", "ui", "wired"];
    const share = ["base": 0.1, "ui": 0.2, "hue": 0.3, "wired": 0.4];
    const a = reachOf(1, ["libs/base/src/x.d", "docs/a.md", "README.md"], &owner, deps, all, share);
    assert(!a.everything && a.reached == 3 && round(a.testShare * 10) == 6, "base, ui and hue");
    const b = reachOf(2, ["libs/ui/x.d", "nix/a.nix", ".gitignore"], &owner, deps, all, share);
    assert(b.everything && b.reached == 4 && b.why == [".gitignore", "nix/"]);
}

// === Panels (layer 2) ===

/// What a panel draws.
enum Kind
{
    kpis,
    multiples,
    columns,
    rows,
    gantt,
    table,
    scatter,
    empty,
}

/// One coloured part of a bar; `hatch` draws it striped.
struct Seg
{
    double value;
    string color;
    bool hatch;
}

/// One entry of a panel's legend.
struct Key
{
    string label;
    string color;
    bool hatch;
}

/// One headline figure.
struct Tile
{
    string label;
    string value;
    string note;
    string tone; /// "", "bad" or "good"
}

/// One column of a column chart.
struct Column
{
    string label;
    string top;   /// written above the column: a clipped value
    string title; /// its tooltip
    Seg[] segs;   /// bottom first
}

/// A small chart of the overview, linking to its tab.
struct Small
{
    string title;
    string latest;
    string sub;
    string delta;
    string tone;
    string href;
    string tab;
    double cap;
    double goal; /// NaN for none
    Column[] cols;
}

/// One cell of a table or a row's trailing columns.
struct Cell
{
    string text;
    bool numeric;
    string tone;
    double bar = -1;   /// a bar before the text, 0–1 of the column's widest; <0 for none
    string barColor;
    double[] spark;    /// a sparkline, values 0–1
    string href;
}

/// One row of a bar-row chart.
struct Row
{
    string label;
    string href;
    double width; /// 0–1 of the track
    Seg[] segs;
    Cell[] cells;
}

/// One job of a timeline, in minutes from the push.
struct Span
{
    string name;
    double created, start, end;
    string color;
}

/// One point of a scatter, both axes 0–1.
struct Point
{
    double x, y;
    string label;
    string color;
    string title;
}

/// A panel: its kind, and the fields that kind reads.
struct Panel
{
    Kind kind;
    string title;
    string aside;
    string note;
    Key[] legend;
    Tile[] tiles;
    Small[] smalls;
    Column[] columns;
    double height = 200;
    double goal; /// NaN for none, in the chart's units
    double cap;
    Row[] rows;
    string[] heads; /// a table's or rows' trailing column titles
    Cell[][] cells; /// a table's rows
    double mark;    /// rows: a dashed mark at this fraction of the track; NaN for none
    Span[] spans;
    double span;    /// the timeline's length in minutes
    Point[] points;
    string xLabel, yLabel;
    string emptyTitle, emptyText;
}

/// The colours of the series: design-system tokens, each with its fallback.
enum Colors : string
{
    // The four runner types differ in lightness as well as hue, in either theme.
    ubuntu = "var(--spk-accent-primary-fg, #1f4fa8)",
    arm = "color-mix(in srgb, var(--spk-accent-primary-fg, #1f4fa8) 45%, var(--spk-page-bg, #ffffff))",
    macos = "var(--spk-status-warning-fg, #e8892b)",
    windows = "color-mix(in srgb, var(--spk-status-warning-fg, #e8892b) 50%, var(--spk-page-fg, #17181c))",
    other = "var(--spk-text-muted-fg, #5b5e66)",
    wait = "var(--spk-status-error-fg, #9a3412)",
    before = "var(--spk-border-strong-fg, #a9acb5)",
    after = "var(--spk-text-secondary-fg, #3c3f47)",
    run = "var(--spk-accent-primary-fg, #1f4fa8)",
    neutral = "var(--spk-text-secondary-fg, #3c3f47)",
    light = "var(--spk-border-default-fg, #c9cbd2)",
}

/// The runner types in the order the views list them, with their colours.
immutable string[2][] runnerColors = [
    ["ubuntu-latest", Colors.ubuntu], ["ubuntu-24.04-arm", Colors.arm],
    ["macos-latest", Colors.macos], ["windows-latest", Colors.windows],
];

/// A runner type's colour; unlisted types share one.
string colorOf(string runner) @safe pure nothrow
{
    foreach (rc; runnerColors)
        if (rc[0] == runner)
            return rc[1];
    return Colors.other;
}

/// The runner types `figs` name, in the views' order.
string[] runnersOf(const(PrFigures)[] figs) @safe pure
{
    bool[string] seen;
    foreach (ref f; figs)
        foreach (ref t; f.every)
            seen[t.runner] = true;
    string[] out_;
    foreach (rc; runnerColors)
        if (rc[0] in seen)
            out_ ~= rc[0];
    foreach (k; seen.keys.sort)
        if (!out_.canFind(k))
            out_ ~= k;
    return out_;
}

/// Minutes, rounded, with thousands separated.
string num(double v) @safe pure
{
    const n = cast(long) round(v);
    auto s = (n < 0 ? -n : n).to!string;
    string out_;
    foreach (i, c; s)
    {
        if (i && (s.length - i) % 3 == 0)
            out_ ~= ',';
        out_ ~= c;
    }
    return n < 0 ? "−" ~ out_ : out_;
}

/// A duration in seconds as minutes, or hours past two of them.
string dur(double seconds) @safe pure
{
    const m = seconds / 60;
    return m >= 120 ? format("%.1f h", m / 60) : num(m) ~ " min";
}

/// The median of `xs`; zero for none.
double median(in double[] xs) @safe pure
{
    if (xs.length == 0)
        return 0;
    auto s = xs.dup.sort.release;
    return s.length % 2 ? s[$ / 2] : (s[$ / 2 - 1] + s[$ / 2]) / 2;
}

/// The change of `latest` against the median of the ten values before it.
private string[2] deltaOf(in double[] values) @safe pure
{
    if (values.length < 2)
        return ["", ""];
    const prev = median(values[max(0, cast(long) values.length - 11) .. $ - 1]);
    if (prev == 0)
        return ["", ""];
    const d = (values[$ - 1] - prev) / prev * 100;
    return [format("%s%.0f%% vs the 10 before", d >= 0 ? "+" : "−", d < 0 ? -d : d), d > 5 ? "bad" : d < -5 ? "good" : ""];
}

private Seg[] runnerSegs(const ref PrFigures f, Scope s, in string[] runners) @safe pure
{
    long[string] secs;
    foreach (ref t; s == Scope.every ? f.every : s == Scope.final_ ? f.final_ : f.latest)
        secs[t.runner] = t.seconds;
    return runners.map!(r => Seg(secs.get(r, 0) / 60.0, colorOf(r))).array;
}

private Key[] runnerKeys(in string[] runners) @safe pure => runners.map!(r => Key(r, colorOf(r))).array;

private enum Key[] splitKeys = [Key("before the job existed", Colors.before), Key("waiting for a runner", Colors.wait),
    Key("running", Colors.run), Key("after it, until all done", Colors.after)];

/// How many landed pull requests the charts show.
enum window = 30;

/// The tabs, in the sidebar's order: route, label, group.
immutable string[3][] tabs = [
    ["", "Overview", ""],
    ["green", "Time to green", "Time"], ["load", "Runner load", "Time"],
    ["minutes", "Runner minutes", "Cost"], ["jobs", "Jobs", "Cost"],
    ["packages", "Packages", "Code"], ["selection", "Test selection", "Code"],
    ["efficiency", "Efficiency", "Later"],
];

private string href(string route) @safe pure => "/" ~ route;
private string prHref(long n) @safe pure => format("/pr/%d", n);

private const(PrFigures)[] recent(const ref SiteData d) @safe pure => d.figures[max(0, cast(long) d.figures.length - window) .. $];

private Panel splitRows(const(PrFigures)[] figs, string title, bool link) @safe pure
{
    Panel p = Panel(Kind.rows, title, "bar: 0 → 300 min; dashed: the 15-minute goal");
    p.legend = splitKeys;
    p.mark = 15.0 / 300;
    p.heads = ["to green", "green → merge", "job that finished last"];
    foreach_reverse (ref f; figs)
    {
        const parts = [f.before, f.waiting, f.running, f.after];
        Row r = Row("#" ~ f.number.to!string, link ? prHref(f.number) : null, min(f.timeToGreen / 60.0, 300) / 300);
        foreach (i, k; splitKeys)
            r.segs ~= Seg(parts[i], k.color);
        r.cells = [Cell(dur(f.timeToGreen), true), Cell(dur(f.greenToMerge), true,
            f.greenToMerge > f.timeToGreen ? "bad" : ""), Cell(f.lastJob)];
        p.rows ~= r;
    }
    p.note = "Red green → merge: the pull request waited longer for a person than CI took. “Before the job "
        ~ "existed” is time on the jobs it needs, or until a rerun created it again.";
    return p;
}

/// The Overview: headline figures, and one small chart per tab.
Panel[] overview(const ref SiteData d) @safe
{
    const figs = recent(d);
    if (figs.length == 0)
        return [emptyHistory()];
    const last = figs[$ - 1];
    const last10 = figs[max(0, cast(long) figs.length - 10) .. $];
    size_t flaky;
    foreach (ref f; figs)
        foreach (ref g; f.groups)
            flaky += g.flaky;
    Panel k = Panel(Kind.kpis);
    k.tiles = [
        Tile("Time to green, #" ~ last.number.to!string, dur(last.timeToGreen),
            last.timeToGreen <= 900 ? "within the 15-minute goal" : format("%.1f× the 15-minute goal", last.timeToGreen / 900.0),
            last.timeToGreen <= 900 ? "good" : "bad"),
        Tile("Median time to green, last 10", dur(median(last10.map!(f => cast(double) f.timeToGreen).array)), "goal: 15 min"),
        Tile("Runner minutes, #" ~ last.number.to!string, num(last.seconds(Scope.every) / 60.0),
            "median, last 10: " ~ num(median(last10.map!(f => f.seconds(Scope.every) / 60.0).array))),
        Tile("Longest wait for a runner, #" ~ last.number.to!string, dur(last.queueMax), "one job, created to started"),
        Tile("Flaky failures", flaky.to!string, format("in the last %d pull requests", figs.length)),
    ];
    const runners = runnersOf(figs);
    Small small(string title, string route, in double[] values, double cap, double goal, string unit,
        Seg[] delegate(size_t) @safe segsOf)
    {
        const dl = deltaOf(values);
        Small s = Small(title, num(values[$ - 1]) ~ unit,
            "median, last 10: " ~ num(median(values[max(0, cast(long) values.length - 10) .. $])) ~ unit, dl[0], dl[1],
            href(route), tabs[tabs.countUntil!(t => t[0] == route)][1], cap, goal);
        foreach (i, v; values)
            s.cols ~= Column(null, null, format("#%d: %s%s", figs[i].number, num(v), unit), segsOf(i));
        return s;
    }
    Panel m = Panel(Kind.multiples, format("Over the last %d pull requests", figs.length), "oldest left");
    const ttg = figs.map!(f => f.timeToGreen / 60.0).array;
    const g2m = figs.map!(f => f.greenToMerge / 60.0).array;
    const mins = figs.map!(f => f.seconds(Scope.every) / 60.0).array;
    const wait = figs.map!(f => f.queueMax / 60.0).array;
    const sel = figs.map!(f => skippable(d, f) / 60.0).array;
    const wasted = figs.map!(f => (f.rerunSeconds + f.cancelledSeconds) / 60.0).array;
    m.smalls = [
        small("Time to green", "green", ttg, 300, 15, " min", i => [Seg(ttg[i], Colors.neutral)]),
        small("Green → merge", "green", g2m, 900, double.nan, " min", i => [Seg(g2m[i], Colors.before)]),
        small("Runner minutes", "minutes", mins, 3600, double.nan, "", i => runnerSegs(figs[i], Scope.every, runners)),
        small("Longest wait for a runner", "load", wait, 90, double.nan, " min", i => [Seg(wait[i], Colors.wait)]),
        small("Skippable test minutes", "selection", sel, 320, double.nan, " min", i => [Seg(sel[i], Colors.arm)]),
        small("Rerun and cancelled minutes", "minutes", wasted, 400, double.nan, " min", i => [Seg(wasted[i], Colors.before)]),
    ];
    return [k, m];
}

/// Time to green, by part (slices 1 and 3).
Panel[] green(const ref SiteData d) @safe
{
    const figs = recent(d);
    return figs.length ? [splitRows(figs, "Time to green, by part", true)] : [emptyHistory()];
}

/// Runner load: running and waiting, hour by hour, and by hour of day (slices 2 and 12).
Panel[] load(const ref SiteData d) @safe
{
    const(PrJob)[] jobs;
    foreach (ref r; d.records[max(0, cast(long) d.records.length - window) .. $])
        foreach (ref run; r.runs)
            jobs ~= run.jobs.filter!(j => j.ran).array;
    if (jobs.length == 0)
        return [emptyHistory()];
    const lo = jobs.map!(j => j.created > 0 ? j.created : j.start).minElement / 3600 * 3600;
    const hi = jobs.map!(j => j.end).maxElement;
    const runners = runnersOf(d.figures);
    double[][] running; // per hour, per runner
    double[] waiting;
    double[24] byHour = 0, hoursOf = 0;
    for (long h = lo; h < hi; h += 3600)
    {
        auto row = new double[runners.length];
        row[] = 0;
        double w = 0;
        foreach (ref j; jobs)
        {
            const i = runners.countUntil(j.runner);
            if (i >= 0)
                row[i] += max(0, min(j.end, h + 3600) - max(j.start, h)) / 3600.0;
            if (j.queue > 0)
                w += max(0, min(j.start, h + 3600) - max(j.created, h)) / 3600.0;
        }
        running ~= row;
        waiting ~= w;
        const hod = SysTime.fromUnixTime(h).toUTC.hour;
        byHour[hod] += w;
        hoursOf[hod] += 1;
    }
    const peakRun = running.map!(r => r.sum).maxElement;
    const peakWait = waiting.maxElement;
    string dayOf(long h) => SysTime.fromUnixTime(h).toUTC.toISOExtString[5 .. 10];
    Panel a = Panel(Kind.columns, "Jobs running, hour by hour", format("peak hour: %.0f jobs", peakRun));
    a.legend = runnerKeys(runners);
    a.height = 150;
    a.cap = max(peakRun, 1);
    Panel b = Panel(Kind.columns, "Jobs waiting for a runner, hour by hour", format("peak hour: %.0f", peakWait));
    b.height = 110;
    b.cap = max(peakWait, 1);
    foreach (i, row; running)
    {
        const h = lo + cast(long) i * 3600;
        const label = (h % 86_400 == 0) ? dayOf(h) : null;
        a.columns ~= Column(label, null, format("%s %02d:00: %.1f running", dayOf(h), SysTime.fromUnixTime(h).toUTC.hour,
            row.sum), runners.length.iota.map!(k => Seg(row[k], colorOf(runners[k]))).array);
        b.columns ~= Column(label, null, format("%.1f waiting", waiting[i]), [Seg(waiting[i], Colors.wait)]);
    }
    Panel c = Panel(Kind.columns, "Jobs waiting, by hour of day (UTC)", "the average over these hours");
    c.height = 120;
    double[24] avg;
    foreach (i; 0 .. 24)
        avg[i] = hoursOf[i] ? byHour[i] / hoursOf[i] : 0;
    c.cap = max(avg[].maxElement, 0.1);
    foreach (i; 0 .. 24)
        c.columns ~= Column(format("%02d", i), avg[i] ? format("%.1f", avg[i]) : null, format("%02d:00 UTC", i),
            [Seg(avg[i], Colors.wait)]);
    c.note = "Waiting follows the busy hours: pull requests that run together queue behind each other's shards.";
    return [a, b, c];
}

private import std.range : iota;

/// Runner minutes: per pull request and runner type, the charge, and what no result needed.
Panel[] minutes(const ref SiteData d) @safe
{
    const figs = recent(d);
    if (figs.length == 0)
        return [emptyHistory()];
    const runners = runnersOf(figs);
    Panel[] out_;
    static immutable scopes = [Scope.every, Scope.final_, Scope.latest];
    static immutable titles = ["Every run and attempt", "The final run, every attempt",
        "The final run, each job's latest execution"];
    foreach (si, s; scopes)
    {
        const title = titles[si];
        Panel p = Panel(Kind.columns, title, "runner minutes per pull request");
        p.legend = runnerKeys(runners);
        p.height = 210;
        p.cap = 3600;
        foreach (ref f; figs)
        {
            const total = f.seconds(s) / 60.0;
            p.columns ~= Column("#" ~ f.number.to!string, total > p.cap ? "↑" ~ num(total) : null,
                format("#%d: %s min", f.number, num(total)), runnerSegs(f, s, runners));
        }
        out_ ~= p;
    }
    // The charge, every run and attempt, billed minutes.
    Panel t = Panel(Kind.table, format("By runner type, the last %d pull requests", figs.length));
    t.heads = ["Runner type", "Minutes", "Billed minutes", "Share", "Rate", "Estimated charge"];
    long[string] secs, billed;
    foreach (ref f; figs)
        foreach (ref x; f.every)
        {
            secs[x.runner] += x.seconds;
            billed[x.runner] += x.billedMinutes;
        }
    const total = secs.byValue.sum;
    const widest = secs.length ? secs.byValue.maxElement : 1;
    foreach (r; runners)
    {
        const rate = d.rates.filter!(x => x.runner == r).map!(x => x.perMinute).array;
        const known = rate.length && rate[0] == rate[0];
        t.cells ~= [Cell(r), Cell(num(secs.get(r, 0) / 60.0), true, "", secs.get(r, 0) / cast(double) widest, colorOf(r)),
            Cell(num(billed.get(r, 0)), true), Cell(format("%.0f%%", secs.get(r, 0) * 100.0 / max(total, 1)), true),
            Cell(known ? format("%.4f", rate[0]) : "—", true, known ? "" : "muted"),
            Cell(known ? format("%.2f", rate[0] * billed.get(r, 0)) : "—", true, known ? "" : "muted")];
    }
    t.note = "Standard runners are free on a public repository. The charge is what the same minutes would "
        ~ "cost a private one, at each label's list price per minute (ci/runner-rates.json); billed minutes round "
        ~ "each job up to a whole minute, as the provider does.";
    Panel w = Panel(Kind.table, "Minutes no result needed");
    w.heads = ["Pull request", "Total", "Reruns", "Cancelled", "Share"];
    foreach_reverse (ref f; figs)
    {
        const all = f.seconds(Scope.every);
        const waste = f.rerunSeconds + f.cancelledSeconds;
        w.cells ~= [Cell("#" ~ f.number.to!string, false, "", -1, null, null, prHref(f.number)), Cell(num(all / 60.0), true),
            Cell(f.rerunSeconds ? num(f.rerunSeconds / 60.0) : "—", true), Cell(f.cancelledSeconds ? num(f.cancelledSeconds / 60.0) : "—", true),
            Cell(format("%.1f%%", waste * 100.0 / max(all, 1)), true, waste * 10 > all ? "bad" : "")];
    }
    return out_ ~ [t, w];
}

/// Jobs: groups against what they caught, setup, shard balance (slices 4, 5, 7, 8).
Panel[] jobs(const ref SiteData d) @safe
{
    const figs = recent(d);
    if (figs.length == 0)
        return [emptyHistory()];
    import perf_pr : GroupTime;

    GroupTime[string] g;
    long[string] setup, secs;
    foreach (ref f; figs)
    {
        foreach (ref x; f.groups)
        {
            auto y = &g.require(x.group, GroupTime(x.group));
            y.seconds += x.seconds;
            y.jobs += x.jobs;
            y.failures += x.failures;
            y.alone += x.alone;
            y.flaky += x.flaky;
            y.rerunSeconds += x.rerunSeconds;
        }
        foreach (ref s; f.setup)
        {
            setup[s.runner] += s.setupSeconds;
            secs[s.runner] += s.seconds;
        }
    }
    auto groups = g.values.filter!(x => x.seconds >= 3600).array.sort!((a, b) => a.seconds > b.seconds).release;
    Panel t = Panel(Kind.table, "Job groups, by runner minutes", format("the last %d pull requests", figs.length));
    t.heads = ["Group", "Runner minutes", "Jobs", "Failed", "Failed alone", "Flaky", "Rerun minutes"];
    const widest = groups.length ? groups[0].seconds : 1;
    foreach (ref x; groups)
        t.cells ~= [Cell(x.group), Cell(num(x.seconds / 60.0), true, "", x.seconds / cast(double) widest,
            x.alone ? Colors.ubuntu : Colors.neutral), Cell(x.jobs.to!string, true), Cell(x.failures.to!string, true),
            Cell(x.alone.to!string, true), Cell(x.flaky.to!string, true, x.flaky ? "bad" : ""),
            Cell(num(x.rerunSeconds / 60.0), true)];
    t.note = "Failed alone: the only failing group of its attempt, the gate aside, so nothing else would have caught "
        ~ "it. Dark bars never did: candidates for the merge queue or a nightly run.";

    Panel s = Panel(Kind.rows, "Setup against the job's own work");
    s.legend = [Key("set up job, checkout, Nix setup, caches", Colors.wait), Key("the rest", Colors.light)];
    s.heads = ["setup share"];
    foreach (r; runnersOf(figs))
        if (secs.get(r, 0))
        {
            const share = setup.get(r, 0) / cast(double) secs[r];
            s.rows ~= Row(r, null, 1, [Seg(share, Colors.wait), Seg(1 - share, Colors.light)],
                [Cell(format("%.0f%% of %s min", share * 100, num(secs[r] / 60.0)), true)]);
        }

    Panel b = Panel(Kind.table, "Shard balance: the longest shard ÷ the shortest", "first attempt on the final head");
    const lastSix = figs[max(0, cast(long) figs.length - 6) .. $];
    string[] placements;
    foreach (ref f; lastSix)
        foreach (ref x; f.shards)
            if (!placements.canFind(x.placement))
                placements ~= x.placement;
    placements.sort;
    b.heads = ["Placement"] ~ lastSix.map!(f => "#" ~ f.number.to!string).array;
    foreach (pl; placements)
    {
        Cell[] row = [Cell(pl)];
        foreach (ref f; lastSix)
        {
            const x = f.shards.filter!(y => y.placement == pl).array;
            if (x.length && x[0].shortest > 0)
            {
                const ratio = x[0].longest / cast(double) x[0].shortest;
                row ~= Cell(format("%.2f", ratio), true, ratio > 1.5 ? "bad" : "");
            }
            else
                row ~= Cell("—", true, "muted");
        }
        b.cells ~= row;
    }
    return [t, s, b];
}

/// Packages: trend, median and spread per placement (slice 9).
Panel[] packages(const ref SiteData d) @safe
{
    string[] placements = d.walls.map!(w => w.placement.idup).array.sort.uniq.array;
    if (placements.length == 0)
    {
        Panel p = Panel(Kind.empty);
        p.emptyTitle = "No run records yet";
        p.emptyText = "Test shards append a run record per package at each landing; this tab draws them once there "
            ~ "are any.";
        return [p];
    }
    Panel[] out_;
    foreach (pl; placements)
    {
        const ws = d.walls.filter!(w => w.placement == pl).array;
        long[] prs = ws.map!(w => cast(long) w.pr).array.sort.uniq.array;
        prs = prs[max(0, cast(long) prs.length - 10) .. $];
        double[][string] series;
        foreach (pr; prs)
            foreach (ref w; ws.filter!(w => w.pr == pr))
            {
                auto s = &series.require(w.pkg, new double[prs.length]);
                (*s)[prs.countUntil(pr)] += w.seconds;
            }
        auto names = series.keys.sort!((a, b) => series[a][$ - 1] > series[b][$ - 1]).release;
        Panel t = Panel(Kind.table, "Slowest packages, " ~ pl, format("landings #%d → #%d", prs[0], prs[$ - 1]));
        t.heads = ["Package", "Trend", "Latest", "Median", "Spread (max ÷ min)"];
        foreach (n; names[0 .. min(15, $)])
        {
            const v = series[n].filter!(x => x > 0).array;
            if (v.length == 0)
                continue;
            const mx = v.maxElement, mn = v.dup.sort[0];
            t.cells ~= [Cell(n), Cell(null, false, "", -1, null, series[n].map!(x => x / mx).array),
                Cell(mmss(series[n][$ - 1]), true), Cell(mmss(median(v)), true),
                Cell(format("%.2f", mx / mn), true, mx / mn > 2 ? "bad" : "")];
        }
        out_ ~= t;
    }
    out_[$ - 1].note = "Wall time of each package's dub build and test, both legs, from the run records the shards "
        ~ "append. A spread over 2 with no change to the package is runner noise.";
    return out_;
}

private string mmss(double s) @safe pure => format("%d:%02d", cast(long) s / 60, cast(long) round(s) % 60);

/// The test minutes test selection would have skipped for `f`.
double skippable(const ref SiteData d, const ref PrFigures f) @safe pure
{
    const r = d.reach.filter!(x => x.pr == f.number).array;
    if (r.length == 0 || r[0].everything)
        return 0;
    return testSeconds(f) * (1 - r[0].testShare);
}

private double testSeconds(const ref PrFigures f) @safe pure
    => f.groups.filter!(g => g.group == "test" || g.group == "Sanitizers").map!(g => cast(double) g.seconds).sum;

/// Test selection: what testing only the reached packages would save (slices 10 and 11).
Panel[] selection(const ref SiteData d) @safe
{
    const figs = recent(d);
    if (figs.length == 0 || d.reach.length == 0)
        return [emptyHistory()];
    Panel r = Panel(Kind.rows, "Test and sanitizer shard minutes, and the share selection would skip");
    r.legend = [Key("packages the change reaches", Colors.ubuntu), Key("skippable", Colors.arm, true)];
    r.heads = ["reached", "saved", "why every package ran"];
    const widest = max(1.0, figs.map!(f => testSeconds(f)).maxElement);
    int[string] counts;
    foreach_reverse (ref f; figs)
    {
        const x = d.reach.filter!(y => y.pr == f.number).array;
        if (x.length == 0)
            continue;
        const keep = x[0].everything ? 1 : x[0].testShare;
        const saved = skippable(d, f);
        r.rows ~= Row("#" ~ f.number.to!string, prHref(f.number), testSeconds(f) / widest,
            [Seg(keep, Colors.ubuntu), Seg(1 - keep, Colors.arm, true)],
            [Cell(format("%d/%d", x[0].reached, x[0].total), true), Cell(saved ? num(saved / 60.0) : "—", true,
                saved > 3600 ? "good" : "muted"), Cell(x[0].everything ? x[0].why.join(" ") : "(packages only)")]);
        foreach (w; x[0].why)
            ++counts[w];
    }
    Panel t = Panel(Kind.table, "What made a pull request test everything");
    t.heads = ["Path", "Pull requests"];
    const most = counts.length ? counts.byValue.maxElement : 1;
    foreach (k; counts.keys.sort!((a, b) => counts[a] > counts[b] || (counts[a] == counts[b] && a < b)))
        t.cells ~= [Cell(k), Cell(counts[k].to!string, true, "", counts[k] / cast(double) most, Colors.neutral)];
    t.note = "Any file outside a package and the docs reaches every package. Many cannot change a test's result "
        ~ "(.gitignore, lychee.toml, ci/placements.json): telling them apart is what would make selection pay.";
    Panel s = Panel(Kind.scatter, "Cost against the size of the change", "one point per pull request");
    s.xLabel = "files changed (square-root scale)";
    s.yLabel = "runner minutes";
    const fmax = sqrt(max(1.0, figs.map!(f => cast(double) f.paths.length).maxElement));
    const mmax = max(1.0, figs.map!(f => cast(double) f.seconds(Scope.every)).maxElement);
    foreach (ref f; figs)
    {
        const x = d.reach.filter!(y => y.pr == f.number).array;
        s.points ~= Point(sqrt(cast(double) f.paths.length) / fmax, f.seconds(Scope.every) / mmax, "#" ~ f.number.to!string,
            x.length && x[0].everything ? Colors.neutral : Colors.ubuntu,
            format("#%d: %d files, %s min", f.number, f.paths.length, num(f.seconds(Scope.every) / 60.0)));
    }
    s.legend = [Key("reached every package", Colors.neutral), Key("packages only", Colors.ubuntu)];
    s.note = "Reach follows package ownership and the sparkles: dependencies of the dub.sdl files; each package's "
        ~ "share of a run is its share of the latest landing's recorded test time.";
    return [r, t, s];
}

/// Efficiency: what it waits for (slice 13).
Panel[] efficiency(const ref SiteData d) @safe pure
{
    Panel p = Panel(Kind.empty);
    p.emptyTitle = "Waiting for the build graph's run metrics";
    p.emptyText = "This tab draws each job's parallel efficiency, run.cpu ÷ (run.cores × run.wall), against the "
        ~ "worker count it ran with, and each task's CPU time and peak memory. The history holds them once build "
        ~ "graph E3 records them (observability O1 and O2); until then the tab stays empty rather than estimate.";
    return [p];
}

/// A pull request's page: every tab's panels for it alone, and its timeline.
Panel[] prPage(const ref SiteData d, size_t i) @safe
{
    const f = d.figures[i];
    const rec = d.records[i];
    const runners = runnersOf([f]);
    Panel k = Panel(Kind.kpis);
    const r = d.reach.filter!(x => x.pr == f.number).array;
    k.tiles = [
        Tile("Time to green", dur(f.timeToGreen), f.timeToGreen <= 900 ? "within the goal"
            : format("%.1f× the goal", f.timeToGreen / 900.0), f.timeToGreen <= 900 ? "good" : "bad"),
        Tile("Open → merge", dur(f.timeToMerge), "green → merge: " ~ dur(f.greenToMerge)),
        Tile("Runner minutes", num(f.seconds(Scope.every) / 60.0), "reruns and cancelled: "
            ~ num((f.rerunSeconds + f.cancelledSeconds) / 60.0)),
        Tile("Jobs", f.jobs.to!string, "longest wait " ~ dur(f.queueMax)),
        Tile("Selection would skip", r.length && !r[0].everything ? dur(skippable(d, f)) : "—",
            r.length ? format("%d of %d packages reached", r[0].reached, r[0].total) : ""),
    ];
    Panel m = Panel(Kind.rows, "Runner minutes by runner type");
    m.legend = runnerKeys(runners);
    m.heads = ["minutes"];
    m.rows = [Row("all", null, 1, runnerSegs(f, Scope.every, runners), [Cell(num(f.seconds(Scope.every) / 60.0), true)])];
    // The final head's runs, from their push.
    Panel g = Panel(Kind.gantt, "Jobs of the final run, from its push");
    g.legend = [Key("waiting for a runner", Colors.light, true), Key("running, by runner type", Colors.ubuntu)];
    long t0 = long.max;
    foreach (ref run; rec.runs)
        if (run.head == rec.head && run.created < t0)
            t0 = run.created;
    foreach (ref run; rec.runs)
        if (run.head == rec.head)
            foreach (ref j; run.jobs)
                if (j.ran)
                    g.spans ~= Span(j.name, (max(j.created, t0) - t0) / 60.0, (j.start - t0) / 60.0, (j.end - t0) / 60.0,
                        colorOf(j.runner));
    g.spans.sort!((a, b) => a.created < b.created || (a.created == b.created && a.start < b.start));
    g.span = g.spans.length ? ceil(g.spans.map!(s => s.end).maxElement / 10) * 10 : 10;
    return [k, m, splitRows([f], "Time to green, by part", false), g];
}

private Panel emptyHistory() @safe pure
{
    Panel p = Panel(Kind.empty);
    p.emptyTitle = "No pull request records yet";
    p.emptyText = "Each landing appends its pull request's record to refs/perf/data; ci perf import-prs seeds "
        ~ "earlier ones. The views fill in as they arrive.";
    return p;
}

// === Rendering (layer 3) ===

private void esc(ref Appender!string w, scope const(char)[] s) @safe pure => escapeInto(w, s);

private string pct(double frac) @safe pure => format("%.2f%%", max(0.0, min(1.0, frac)) * 100);

private string fill(string color, bool hatch) @safe pure
    => hatch ? "repeating-linear-gradient(45deg, " ~ color ~ " 0 3px, transparent 3px 6px)" : color;

private void legend(ref Appender!string w, in Key[] keys) @safe pure
{
    if (keys.length == 0)
        return;
    w ~= `<div class="legend">`;
    foreach (ref k; keys)
    {
        w ~= `<span><i aria-hidden="true" style="background:` ~ fill(k.color, k.hatch) ~ (k.hatch ? ";border:1px solid "
            ~ k.color : "") ~ `"></i>`;
        esc(w, k.label);
        w ~= `</span>`;
    }
    w ~= "</div>\n";
}

private void stack(ref Appender!string w, in Seg[] segs, double cap, double height) @safe pure
{
    const total = segs.map!(s => s.value).sum;
    const scale = total > cap && total > 0 ? cap / total : 1;
    foreach_reverse (ref s; segs) // drawn top first in a column-reverse flex
        if (s.value > 0)
            w ~= format(`<b style="height:%.1fpx;background:%s"></b>`, max(1.0, s.value * scale / cap * height),
                fill(s.color, s.hatch));
}

private void cell(ref Appender!string w, in Cell c, string tag) @safe pure
{
    w ~= "<" ~ tag ~ (c.numeric ? ` class="n` ~ (c.tone.length ? " " ~ c.tone : "") ~ `"` : c.tone.length ? ` class="`
        ~ c.tone ~ `"` : "") ~ ">";
    if (c.bar >= 0)
        w ~= format(`<i class="bar" aria-hidden="true" style="width:%.0fpx;background:%s"></i>`, max(2.0, c.bar * 140),
            c.barColor.length ? c.barColor : Colors.neutral);
    if (c.spark.length)
    {
        w ~= `<span class="spark" aria-hidden="true">`;
        foreach (i, v; c.spark)
            w ~= format(`<i style="height:%.0fpx" class="%s"></i>`, max(2.0, v * 20), i + 1 == c.spark.length ? "last" : "");
        w ~= `</span>`;
    }
    if (c.href.length)
    {
        w ~= `<a href="`;
        esc(w, c.href);
        w ~= `">`;
        esc(w, c.text);
        w ~= `</a>`;
    }
    else
        esc(w, c.text);
    w ~= "</" ~ tag ~ ">";
}

/// One panel's HTML.
void render(ref Appender!string w, in Panel p) @safe pure
{
    w ~= `<section class="panel">` ~ "\n";
    if (p.title.length)
    {
        w ~= `<header><h2>`;
        esc(w, p.title);
        w ~= `</h2><span>`;
        esc(w, p.aside);
        w ~= "</span></header>\n";
    }
    legend(w, p.legend);
    final switch (p.kind)
    {
        case Kind.kpis:
            w ~= `<div class="tiles">`;
            foreach (ref t; p.tiles)
            {
                w ~= `<div class="tile"><span>`;
                esc(w, t.label);
                w ~= `</span><strong>`;
                esc(w, t.value);
                w ~= `</strong><span class="` ~ t.tone ~ `">`;
                esc(w, t.note);
                w ~= "</span></div>";
            }
            w ~= "</div>\n";
            break;
        case Kind.multiples:
            w ~= `<div class="smalls">`;
            foreach (ref s; p.smalls)
            {
                w ~= `<a class="small" href="` ~ s.href ~ `"><span class="top"><b>`;
                esc(w, s.title);
                w ~= `</b><strong>`;
                esc(w, s.latest);
                w ~= `</strong></span><span class="sub"><span>`;
                esc(w, s.sub);
                w ~= `</span><span class="` ~ s.tone ~ `">`;
                esc(w, s.delta);
                w ~= `</span></span><span class="cols mini">`;
                if (s.goal == s.goal)
                    w ~= format(`<i class="goal" style="bottom:%.1fpx"></i>`, s.goal / s.cap * 52);
                foreach (ref c; s.cols)
                {
                    w ~= `<span class="col" title="`;
                    esc(w, c.title);
                    w ~= `">`;
                    stack(w, c.segs, s.cap, 52);
                    w ~= "</span>";
                }
                w ~= `</span><span class="open">Open `;
                esc(w, s.tab);
                w ~= " →</span></a>";
            }
            w ~= "</div>\n";
            break;
        case Kind.columns:
            w ~= format(`<div class="scroll"><div class="cols" style="height:%.0fpx">`, p.height + 16);
            if (p.goal == p.goal)
                w ~= format(`<i class="goal" style="bottom:%.1fpx"></i>`, p.goal / p.cap * p.height);
            foreach (ref c; p.columns)
            {
                w ~= `<span class="col" title="`;
                esc(w, c.title);
                w ~= `">`;
                stack(w, c.segs, p.cap, p.height);
                if (c.top.length)
                {
                    w ~= `<em>`;
                    esc(w, c.top);
                    w ~= `</em>`;
                }
                w ~= "</span>";
            }
            w ~= `</div><div class="labels">`;
            foreach (ref c; p.columns)
            {
                w ~= "<span>";
                esc(w, c.label);
                w ~= "</span>";
            }
            w ~= "</div></div>\n";
            break;
        case Kind.rows:
            w ~= `<div class="scroll"><table class="rows"><thead><tr><th></th><th></th>`;
            foreach (h; p.heads)
            {
                w ~= `<th>`;
                esc(w, h);
                w ~= `</th>`;
            }
            w ~= "</tr></thead><tbody>\n";
            foreach (ref r; p.rows)
            {
                w ~= `<tr><th scope="row">`;
                if (r.href.length)
                {
                    w ~= `<a href="` ~ r.href ~ `">`;
                    esc(w, r.label);
                    w ~= `</a>`;
                }
                else
                    esc(w, r.label);
                w ~= `</th><td class="track"><span class="trackbar">`;
                if (p.mark == p.mark)
                    w ~= `<i class="mark" style="left:` ~ pct(p.mark) ~ `"></i>`;
                w ~= `<span class="fillbar" style="width:` ~ pct(r.width) ~ `">`;
                const total = r.segs.map!(s => s.value).sum;
                foreach (ref s; r.segs)
                    if (s.value > 0)
                        w ~= `<b style="width:` ~ pct(total > 0 ? s.value / total : 0) ~ `;background:`
                            ~ fill(s.color, s.hatch) ~ `"></b>`;
                w ~= `</span></span></td>`;
                foreach (ref c; r.cells)
                    cell(w, c, "td");
                w ~= "</tr>\n";
            }
            w ~= "</tbody></table></div>\n";
            break;
        case Kind.gantt:
            w ~= `<div class="scroll"><table class="rows gantt"><thead><tr><th></th><th class="ticks">`;
            for (double m = 0; m <= p.span; m += p.span > 60 ? 20 : 10)
                w ~= format(`<span style="left:%s">%.0fm</span>`, pct(m / p.span), m);
            w ~= "</th></tr></thead><tbody>\n";
            foreach (ref s; p.spans)
            {
                w ~= `<tr><th scope="row" title="`;
                esc(w, s.name);
                w ~= `">`;
                esc(w, s.name);
                w ~= `</th><td class="track"><span class="trackbar">`;
                w ~= `<i class="mark" style="left:` ~ pct(15 / p.span) ~ `"></i>`;
                if (s.start > s.created)
                    w ~= `<b class="wait" style="left:` ~ pct(s.created / p.span) ~ `;width:` ~ pct((s.start - s.created) / p.span)
                        ~ `"></b>`;
                w ~= `<b class="run" style="left:` ~ pct(s.start / p.span) ~ `;width:` ~ pct(max(0.004, (s.end - s.start) / p.span))
                    ~ `;background:` ~ s.color ~ `" title="`;
                esc(w, format("%s: waited %.1f, ran %.1f min", s.name, s.start - s.created, s.end - s.start));
                w ~= "\"></b></span></td></tr>\n";
            }
            w ~= "</tbody></table></div>\n";
            break;
        case Kind.table:
            w ~= `<div class="scroll"><table class="data"><thead><tr>`;
            foreach (i, h; p.heads)
            {
                w ~= i ? `<th class="n">` : `<th>`;
                esc(w, h);
                w ~= `</th>`;
            }
            w ~= "</tr></thead><tbody>\n";
            foreach (row; p.cells)
            {
                w ~= "<tr>";
                foreach (i, ref c; row)
                    cell(w, c, i ? "td" : "th");
                w ~= "</tr>\n";
            }
            w ~= "</tbody></table></div>\n";
            break;
        case Kind.scatter:
            w ~= `<div class="scroll"><div class="scatter"><span class="ylabel">`;
            esc(w, p.yLabel);
            w ~= `</span><div class="plot">`;
            foreach (ref pt; p.points)
            {
                w ~= format(`<span class="pt" style="left:%s;bottom:%s" title="`, pct(pt.x * 0.92 + 0.04), pct(pt.y * 0.9 + 0.04));
                esc(w, pt.title);
                w ~= `"><i style="background:` ~ pt.color ~ `"></i>`;
                esc(w, pt.label);
                w ~= `</span>`;
            }
            w ~= `</div><span class="xlabel">`;
            esc(w, p.xLabel);
            w ~= "</span></div></div>\n";
            break;
        case Kind.empty:
            w ~= `<div class="empty"><b>`;
            esc(w, p.emptyTitle);
            w ~= `</b><p>`;
            esc(w, p.emptyText);
            w ~= "</p></div>\n";
            break;
    }
    if (p.note.length)
    {
        w ~= `<p class="note">`;
        esc(w, p.note);
        w ~= "</p>\n";
    }
    w ~= "</section>\n";
}

/// The site's stylesheet: the design system's tokens, then the layout.
string siteCss() @safe
{
    import sparkles.docs.assets : tokenStylesheet, TokenSheetOptions;
    import sparkles.ui.themes : builtinThemes;

    const chrome = ChromePalette(
        background: "var(--spk-page-bg, #ffffff)",
        surface: "var(--spk-surface-sunken-bg, #f7f7f5)",
        border: "var(--spk-border-default-fg, #e9e9e7)",
        text: "var(--spk-page-fg, #17181c)",
        muted: "var(--spk-text-muted-fg, #5b5e66)",
        faint: "var(--spk-text-muted-fg, #8a8d94)",
        link: "var(--spk-accent-primary-fg, #1f4fa8)",
    );
    return tokenStylesheet(builtinThemes["github-light"], builtinThemes["github-dark"], TokenSheetOptions(followSystem: true))
        ~ sidebarCss(chrome) ~ import("perf_site.css");
}

/// One page: its sidebar and its panels.
string page(const ref SiteData d, string route, string heading, string lede, in Panel[] panels) @safe
{
    auto w = appender!string;
    w ~= "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        ~ "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>";
    esc(w, heading);
    w ~= " · sparkles-perf</title>\n<link rel=\"stylesheet\" href=\"/site.css\">\n<style>.site-sidebar a.sb-link[href=\"";
    esc(w, href(route));
    w ~= "\"] { font-weight: 600; background: var(--spk-surface-raised-bg, #e9e9e6); }</style>\n</head>\n<body>\n"
        ~ "<div class=\"shell\">\n<aside class=\"site-sidebar\"><nav aria-label=\"Dashboard\">\n"
        ~ "<p class=\"brand\"><b>sparkles-perf</b><span>CI cost and time to green</span></p>\n";
    w ~= sidebarItemsHtml(sidebar(d));
    w ~= "<p class=\"built\">Built from refs/perf/data at ";
    esc(w, d.tip.length >= 9 ? d.tip[0 .. 9] : d.tip);
    w ~= ". Every record's signature verified. This site requests nothing from anywhere else.</p>\n"
        ~ "</nav></aside>\n<main>\n<h1>";
    esc(w, heading);
    w ~= "</h1>\n<p class=\"lede\">";
    esc(w, lede);
    w ~= "</p>\n";
    foreach (ref p; panels)
        render(w, p);
    w ~= "</main>\n</div>\n</body>\n</html>\n";
    return w.data;
}

/// The sidebar: the tabs by group, then the latest pull requests.
SidebarItem[] sidebar(const ref SiteData d) @safe
{
    SidebarItem[] items;
    foreach (t; tabs)
    {
        if (t[2].length == 0)
        {
            items ~= SidebarItem(t[1], href(t[0]));
            continue;
        }
        if (items.length == 0 || items[$ - 1].text != t[2])
            items ~= SidebarItem(t[2]);
        items[$ - 1].items ~= SidebarItem(t[1], href(t[0]));
    }
    SidebarItem prs = SidebarItem("Pull requests");
    foreach_reverse (ref f; d.figures[max(0, cast(long) d.figures.length - 12) .. $])
        prs.items ~= SidebarItem(format("#%d · %s", f.number, dur(f.timeToGreen)), prHref(f.number));
    if (prs.items.length)
        items ~= prs;
    return items;
}

/// Every page of the site, path → content, the stylesheet included (OBW1).
string[string] buildSite(const ref SiteData d) @safe
{
    string[string] files;
    files["site.css"] = siteCss();
    immutable string[2][string] ledes = [
        "": ["Overview", "Headline figures, and one small chart per question; each opens the tab that answers it."],
        "green": ["Time to green", "Each pull request's last push to every workflow done, split along the job that "
            ~ "finished last, and the wait for a person afterwards."],
        "load": ["Runner load", "Every pull request at once: whether the runners were the limit, and when."],
        "minutes": ["Runner minutes", "What a provider would charge for each pull request, per runner type, and the "
            ~ "minutes no result needed."],
        "jobs": ["Jobs", "What each group of jobs cost against what it caught, how much of each job is setup, and "
            ~ "whether a placement's shards finish together."],
        "packages": ["Packages", "Each package's test time per placement: its trend, and its spread between runs."],
        "selection": ["Test selection", "What testing only the packages a change can reach would save, and what "
            ~ "made a pull request reach them all."],
        "efficiency": ["Efficiency", "How well each job uses its machine, and the thread count past which more "
            ~ "threads stop paying."],
    ];
    Panel[] panelsOf(string route)
    {
        switch (route)
        {
            case "": return overview(d);
            case "green": return green(d);
            case "load": return load(d);
            case "minutes": return minutes(d);
            case "jobs": return jobs(d);
            case "packages": return packages(d);
            case "selection": return selection(d);
            default: return efficiency(d);
        }
    }
    foreach (t; tabs)
        files[t[0].length ? t[0] ~ ".html" : "index.html"] = page(d, t[0], ledes[t[0]][0], ledes[t[0]][1], panelsOf(t[0]));
    foreach (i, ref f; d.figures)
        files[format("pr/%d.html", f.number)] = page(d, format("pr/%d", f.number), format("Pull request #%d", f.number),
            "Every tab's figures for this pull request alone, and the timeline of its final run.", prPage(d, i));
    return files;
}

@("perfSite.buildSite.deterministicAndSelfContained")
@safe unittest
{
    import std.regex : matchAll, regex;
    import perf_pr : fixtureRecord;

    auto d = withFigures([fixtureRecord()]);
    d.tip = "0123456789abcdef";
    d.reach = [Reach(7, 3, 76, false, null, 0.25)];
    d.walls = [PackageWall("x86_64-linux-ldc2", 7, "base", 120)];
    d.rates = [RunnerRate("ubuntu-latest", 0.008)];
    const a = buildSite(d), b = buildSite(d);
    assert(a == b, "two builds from one tip are byte-identical");
    foreach (path; ["index.html", "green.html", "load.html", "minutes.html", "jobs.html", "packages.html",
            "selection.html", "efficiency.html", "pr/7.html", "site.css"])
        assert(path in a, path);
    foreach (path, content; a)
        foreach (m; content.matchAll(regex(`(?:src|href)="(https?:)?//`)))
            assert(false, path ~ " loads from another origin: " ~ m.hit);
    assert(a["pr/7.html"].canFind("Jobs of the final run"));
    assert(a["green.html"].canFind(`href="/pr/7"`), "a row opens its pull request");
}

// === Loading (impure) ===

/**
Read the site's data: the trusted pull request and run records of `tip`
(OBH8), the package graph of the checkout at `repoRoot` for test selection's
reach, and the rates of `ratesPath`. A record that does not decode is
reported in `report` and left out, as an untrusted commit's are.
*/
SiteData loadSite(string remote, string signersFile, string requestedTip, string repoRoot, string ratesPath,
    out string report) @trusted
{
    import std.file : exists, readText;
    import std.json : JSONType, parseJSON;
    import sparkles.build_primitives.dub_manifest : hostPlatformTokens;
    import sparkles.build_primitives.workspace.package_graph : discoverPackages, RecipeRole;
    import perf_history : historyCacheDir, historyRef, listFiles, openHistory, readFiles, taskWalls, trustedDirs,
        trustedRuns;
    import perf_pr : decode;

    SiteData d;
    auto opened = openHistory(historyCacheDir(remote), remote, signersFile);
    if (opened.hasError)
    {
        report ~= opened.error ~ "\n";
        return d;
    }
    const h = opened.value;
    const tip = requestedTip.length ? requestedTip : historyRef;
    string[] ignored;

    // Pull request records.
    const prDirs = trustedDirs(h, tip, "prs", 4, ignored);
    const prFiles = readFiles(h, tip, prDirs.map!(x => x.dir ~ "/pr.json").array);
    PrRecord[] records;
    foreach (path; prFiles.keys.sort)
    {
        auto r = decode(prFiles[path]);
        if (r.hasError)
            report ~= "left out " ~ path ~ ": " ~ r.error ~ "\n";
        else
            records ~= r.value;
    }
    d = withFigures(records);
    {
        import perf_history : git;

        d.tip = git(h.gitDir, ["rev-parse", tip]).output.strip;
    }

    // Run records of the landings the charts show: package walls per placement.
    bool[long] shown;
    foreach (ref f; d.figures[max(0, cast(long) d.figures.length - window) .. $])
        shown[f.number] = true;
    const runDirs = trustedRuns(h, tip, ignored);
    const runJson = readFiles(h, tip, runDirs.map!(x => x.dir ~ "/run.json").array);
    // A CI run record of a landing: its placement and pull request, or null.
    string[2] landingOf(string content)
    {
        try
        {
            auto v = parseJSON(content);
            if (v["origin"].str != "ci" || "invocation" !in v || "placement" !in v["invocation"]
                || "source" !in v || "pullRequest" !in v["source"]
                || v["source"]["pullRequest"].type != JSONType.integer)
                return [null, null];
            return [v["invocation"]["placement"].str, v["source"]["pullRequest"].integer.to!string];
        }
        catch (Exception)
            return [null, null];
    }
    // The latest landing with records gives each package's share of a run,
    // whether or not the charts show it.
    long latestPr;
    foreach (path, content; runJson)
    {
        const m = landingOf(content);
        if (m[0] !is null)
            latestPr = max(latestPr, m[1].to!long);
    }
    string[] taskPaths;
    string[2][string] meta; // dir -> [placement, pull request]
    foreach (path, content; runJson)
    {
        const m = landingOf(content);
        if (m[0] is null || (m[1].to!long !in shown && m[1].to!long != latestPr))
            continue;
        const dir = path[0 .. $ - "/run.json".length];
        meta[dir] = m;
        taskPaths ~= listFiles(h, tip, dir ~ "/tasks").map!(t => t.idup).array;
    }
    PackageWall[] latestWalls;
    foreach (path, content; readFiles(h, tip, taskPaths))
    {
        const dir = path[0 .. path.countUntil("/tasks/")];
        const m = meta[dir];
        foreach (id, ns; taskWalls(content))
        {
            const parts = id.split(":");
            if (parts.length < 2 || parts[0] != "test")
                continue;
            const w = PackageWall(m[0], m[1].to!long, parts[1], ns / 1e9);
            if (w.pr in shown)
                d.walls ~= w;
            if (w.pr == latestPr)
                latestWalls ~= w;
        }
    }
    d.walls.sort!((a, b) => a.placement < b.placement || (a.placement == b.placement
        && (a.pr < b.pr || (a.pr == b.pr && a.pkg < b.pkg))));

    // Test selection's reach, by the package graph of this checkout.
    auto graph = discoverPackages(repoRoot, RecipeRole.test, hostPlatformTokens());
    if (graph.hasError)
        report ~= "no package graph, so no test selection view\n";
    else
    {
        const g = graph.value;
        string[][string] dependents;
        foreach (ref e; g.edges)
            dependents[g.packages[e.dependency].shortName] ~= g.packages[e.dependent].shortName;
        const all = g.packages.map!(p => p.shortName).array;
        // Each package's share of the latest landing's test time, over every
        // placement; with no record yet, an equal share each.
        double[string] share;
        double total = 0;
        foreach (ref w; latestWalls)
        {
            share[w.pkg] += w.seconds;
            total += w.seconds;
        }
        if (total > 0)
            foreach (k; share.keys)
                share[k] /= total;
        else
            foreach (k; all)
                share[k] = 1.0 / all.length;
        string owner(string path) @safe
        {
            const i = g.owner(path);
            // The root package owns every path; it reaches everything, as an unowned path does.
            return i < 0 || g.packages[i].path.length == 0 ? null : g.packages[i].shortName;
        }
        foreach (ref f; d.figures)
            d.reach ~= reachOf(f.number, f.paths, &owner, dependents, all, share);
    }

    // Rates.
    if (exists(ratesPath))
    {
        try
        {
            auto v = parseJSON(readText(ratesPath));
            foreach (k, x; v["perMinute"].object)
                d.rates ~= RunnerRate(k, x.type == JSONType.null_ ? double.nan
                    : x.type == JSONType.integer ? cast(double) x.integer : x.floating);
            d.rates.sort!((a, b) => a.runner < b.runner);
        }
        catch (Exception e)
            report ~= ratesPath ~ ": " ~ e.msg ~ "\n";
    }
    foreach (c; ignored)
        report ~= "ignored the unverified commit " ~ c ~ "\n";
    return d;
}

/// Write `files` under `outDir`.
void writeSite(in string[string] files, string outDir) @trusted
{
    import std.file : mkdirRecurse, write;
    import std.path : buildPath, dirName;

    foreach (path, content; files)
    {
        const full = buildPath(outDir, path);
        mkdirRecurse(dirName(full));
        write(full, content);
    }
}

/**
 * The benchmark metric catalog: a unified, named, filterable view over every
 * measured column — client throughput/level `Metric`s and hardware `PerfStats`
 * counters today, cheap `/proc` counters and syscall counts as later sources.
 *
 * Each column is one named `MetricCell` (per row), described by a
 * `MetricDescriptor` (per catalog). A `MetricClass` tags every metric
 * `quantitative` (near-zero perturbation — the only inputs a reported number may
 * read) or `diagnostic` (perturbs — explains a result, never a headline). This
 * is the single seam the reporting layer renders through and that
 * `--metrics`/`--list-metrics` select over.
 *
 * Units-of-measure alignment (see the roadmap): a `Unit` is treated as an
 * open-basis "mint-by-name" symbol *label*, not a dimension. All unit/rate/format
 * semantics — the `scaled`/`fixed` formatters and the rate ÷time derivation in
 * `clientCells` — live here, so a later `sparkles.quantities` swap is a localized
 * change to this module and nothing else in the catalog.
 */
module sparkles.test_runner.metrics;

import sparkles.test_runner.bench : BenchStats, Metric, Unit;
import sparkles.test_runner.perf : branchMissPercent, cacheMissPercent, ipc,
    PerfStats;
import sparkles.test_runner.syscalls : SyscallStats;
import sparkles.test_runner.tier0 : cacheHitPercent, Tier0Stats;

/// Whether a metric perturbs the measurement. Only `quantitative` metrics may
/// feed a reported/gated number; `diagnostic` ones explain, in a separate region.
enum MetricClass
{
    quantitative, /// near-zero perturbation — safe to report
    diagnostic,   /// perturbs — explains a result, never a headline
}

/// How a metric value renders — the formatting seam (later: quantity-aware).
enum MetricFormat
{
    ratio,   /// fixed 2-decimal ratio, e.g. IPC
    count,   /// SI-prefixed magnitude, e.g. instructions/iter, a throughput rate
    percent, /// fixed 2-decimal percentage, e.g. branch-miss rate
}

/// One metric's value for one row. `value` is `nan` when the row lacks it → em dash.
struct MetricCell
{
    string name;   /// stable id, e.g. "ipc", "instr", "B/s"
    string header; /// column label
    double value = double.nan;
    MetricFormat format;
    MetricClass cls;
}

/// A metric the catalog knows about — for `--list-metrics` and column selection.
struct MetricDescriptor
{
    string name;
    string header;
    MetricFormat format;
    MetricClass cls;
    string source;  /// "client" | "perf" (later: "tier0" | "syscall")
    bool available; /// producible on this run (perf opened / present in the rows)
    bool isDefault; /// shown in the default (no `--metrics`) column set
}

// ─────────────────────────────────────────────────────────────────────────────
// The perf family: static column metadata + the value projection
// ─────────────────────────────────────────────────────────────────────────────

private struct PerfInfo
{
    string name;
    string header;
    MetricFormat format;
    bool isDefault;
}

/// The perf counters as catalog columns. The first four are the default set
/// (today's `--perf` columns, byte-for-byte); the rest are listable / opt-in.
private static immutable PerfInfo[7] perfInfos = [
    PerfInfo("ipc", "IPC", MetricFormat.ratio, true),
    PerfInfo("instr", "instr/iter", MetricFormat.count, true),
    PerfInfo("br-miss", "br-miss", MetricFormat.percent, true),
    PerfInfo("cache-miss", "cache-miss", MetricFormat.percent, true),
    PerfInfo("cycles", "cycles/iter", MetricFormat.count, false),
    PerfInfo("branches", "branch/iter", MetricFormat.count, false),
    PerfInfo("page-faults", "pgflt/iter", MetricFormat.count, false),
];

/// Projects one `PerfStats` to its named cells, in `perfInfos` order.
MetricCell[] perfCells(in PerfStats p) @safe pure nothrow
{
    const double[7] values = [
        p.ipc, p.instructions, p.branchMissPercent, p.cacheMissPercent,
        p.cycles, p.branches, p.pageFaults,
    ];
    MetricCell[] cells;
    cells.reserve(perfInfos.length);
    foreach (i, ref info; perfInfos)
        cells ~= MetricCell(info.name, info.header, values[i], info.format,
            MetricClass.diagnostic);
    return cells;
}

/// The perf family as descriptors (for `--list-metrics`), with the given
/// availability — no rows needed.
MetricDescriptor[] perfFamily(bool available) @safe pure nothrow
{
    MetricDescriptor[] result;
    result.reserve(perfInfos.length);
    foreach (ref info; perfInfos)
        result ~= MetricDescriptor(info.name, info.header, info.format,
            MetricClass.diagnostic, "perf", available, info.isDefault);
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// The tier0 family: cheap /proc counters (all quantitative, opt-in columns)
// ─────────────────────────────────────────────────────────────────────────────

private struct Tier0Info
{
    string name;
    string header;
    MetricFormat format;
}

/// The Tier-0 counters as catalog columns. All opt-in (not in the default set):
/// selected via `--metrics`; the derived `cache-hit` is a percentage.
private static immutable Tier0Info[11] tier0Infos = [
    Tier0Info("syscr", "syscr", MetricFormat.count),
    Tier0Info("syscw", "syscw", MetricFormat.count),
    Tier0Info("minflt", "min-flt", MetricFormat.count),
    Tier0Info("majflt", "maj-flt", MetricFormat.count),
    Tier0Info("vol-cs", "vol-cs", MetricFormat.count),
    Tier0Info("invol-cs", "invol-cs", MetricFormat.count),
    Tier0Info("rchar", "rchar", MetricFormat.count),
    Tier0Info("wchar", "wchar", MetricFormat.count),
    Tier0Info("rd-bytes", "rd-bytes", MetricFormat.count),
    Tier0Info("wr-bytes", "wr-bytes", MetricFormat.count),
    Tier0Info("cache-hit", "cache-hit", MetricFormat.percent),
];

/// Projects one `Tier0Stats` to its named cells, in `tier0Infos` order.
MetricCell[] tier0Cells(in Tier0Stats t) @safe pure nothrow
{
    const double[11] values = [
        t.syscr, t.syscw, t.minflt, t.majflt, t.volCs, t.involCs,
        t.rdChars, t.wrChars, t.rdBytes, t.wrBytes, cacheHitPercent(t),
    ];
    MetricCell[] cells;
    cells.reserve(tier0Infos.length);
    foreach (i, ref info; tier0Infos)
        cells ~= MetricCell(info.name, info.header, values[i], info.format,
            MetricClass.quantitative);
    return cells;
}

/// The tier0 family as descriptors (for `--list-metrics`), with the given
/// availability — no rows needed. All opt-in (`isDefault = false`).
MetricDescriptor[] tier0Family(bool available) @safe pure nothrow
{
    MetricDescriptor[] result;
    result.reserve(tier0Infos.length);
    foreach (ref info; tier0Infos)
        result ~= MetricDescriptor(info.name, info.header, info.format,
            MetricClass.quantitative, "tier0", available, false);
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// The syscall family: perf-tracepoint counts (dynamic names from `--syscalls`)
// ─────────────────────────────────────────────────────────────────────────────

/// Projects one `SyscallStats` to its named cells: the `syscalls` total plus one
/// `syscalls:<name>` per requested tracepoint (`nan` where it couldn't be opened).
MetricCell[] syscallCells(in SyscallStats s) @safe pure nothrow
{
    MetricCell[] cells;
    cells.reserve(1 + s.named.length);
    cells ~= MetricCell("syscalls", "syscalls", s.total, MetricFormat.count,
        MetricClass.quantitative);
    foreach (i, name; s.named)
        cells ~= MetricCell("syscalls:" ~ name, "sc:" ~ name, s.counts[i],
            MetricFormat.count, MetricClass.quantitative);
    return cells;
}

/// The syscall total as a descriptor (for `--list-metrics`), with the given
/// availability. Per-syscall columns are dynamic (named via `--syscalls`) and
/// appear in the table when present, not in the static listing.
MetricDescriptor[] syscallFamily(bool available) @safe pure nothrow
    => [MetricDescriptor("syscalls", "syscalls", MetricFormat.count,
        MetricClass.quantitative, "syscall", available, true)];

// ─────────────────────────────────────────────────────────────────────────────
// Client metrics: a unit symbol is the (mint-by-name) column label; a `rate`
// metric divides its amount by iteration-time (the ÷time yielding `unit·s⁻¹`).
// ─────────────────────────────────────────────────────────────────────────────

/// The column label / id for a client metric: `<sym>/s` for a rate, `<sym>` for a
/// level. (The two-valued `Mode` stands in for the unit's time-exponent.) Taken
/// by value (not `in`/`scope`) so the returned symbol slice may escape.
/// Whether `name` is one of the runner's own column names: the static
/// perf/tier0 families, or the dynamic syscall family's `syscalls` /
/// `syscalls:<name>` ids (and their `sc:<name>` display headers).
private bool isBuiltinMetricName(string name) @safe pure nothrow @nogc
{
    import std.algorithm.searching : startsWith;

    foreach (ref info; perfInfos)
        if (info.name == name)
            return true;
    foreach (ref info; tier0Infos)
        if (info.name == name)
            return true;
    return name == "syscalls" || name.startsWith("syscalls:")
        || name.startsWith("sc:");
}

/// The column name a client `Metric` mints: `<unit>/s` for rates, the unit
/// symbol for levels. A name that would collide with a built-in column
/// (`ipc`, `syscr`, `syscalls`, …) is disambiguated as `user.<name>`, so the
/// built-in keeps its documented meaning and the client column stays visible.
private string clientLabel(const Metric m) @safe pure nothrow
{
    const label = m.mode == Metric.Mode.rate ? m.unit.symbol ~ "/s" : m.unit.symbol;
    return isBuiltinMetricName(label) ? "user." ~ label : label;
}

/// Projects client metrics to named cells; `rate` metrics become a per-second
/// quantity via `amount ÷ iteration-time`, `level` metrics pass `amount` through.
MetricCell[] clientCells(in Metric[] metrics, double nsPerIterMedian) @safe pure nothrow
{
    MetricCell[] cells;
    cells.reserve(metrics.length);
    foreach (ref m; metrics)
    {
        const value = m.mode == Metric.Mode.rate
            ? (nsPerIterMedian > 0 ? m.amount * 1e9 / nsPerIterMedian : double.nan)
            : m.amount;
        const label = clientLabel(m);
        cells ~= MetricCell(label, label, value, MetricFormat.count,
            MetricClass.quantitative);
    }
    return cells;
}

/// Every metric cell of one row: client columns first (in call order), then perf,
/// then tier0 — each present only when the row carries that source.
MetricCell[] rowCells(in BenchStats row) @safe pure nothrow
{
    auto cells = clientCells(row.metrics, row.nsPerIterMedian);
    if (!row.perf.isNull)
        cells ~= perfCells(row.perf.get);
    if (!row.tier0.isNull)
        cells ~= tier0Cells(row.tier0.get);
    if (!row.syscalls.isNull)
        cells ~= syscallCells(row.syscalls.get);
    return cells;
}

/// The sort key's value for `--sort-by`: `"name"` compares the benchmark name;
/// anything else looks up that metric cell's `value` via `rowCells` (`nan` when
/// the row lacks it, e.g. an error row or a column another row doesn't carry).
private double sortValue(in BenchStats row, string sortBy) @safe pure nothrow
{
    foreach (ref c; rowCells(row))
        if (c.name == sortBy)
            return c.value;
    return double.nan;
}

/// The unit-separator joining a group key's label values. `US` (`0x1f`) can't
/// occur in a label value, so distinct label tuples never collide the way a
/// printable separator (`/`) would when a value itself contains it; the reporter
/// maps it back to `/` for display (see `groupKeyDisplay`).
enum groupKeySep = "\x1f";

/// The group key of a case from its `labels`: the values of the selected label
/// `keys`, in order, joined with `groupKeySep`. `keys` empty → `""` (every row in
/// one group = no grouping). A key absent from `labels` contributes an empty part.
string groupKeyOf(in string[string] labels, in string[] keys) @safe
{
    if (keys.length == 0)
        return "";
    string result;
    foreach (n, key; keys)
    {
        if (n)
            result ~= groupKeySep;
        if (auto v = key in labels)
            result ~= *v;
    }
    return result;
}

/// A group key rendered for humans: `groupKeySep` → `/`, an empty part (a case
/// missing that label) → `?`, and an all-empty key → `(unlabeled)` — so a
/// group of label-less cases gets a legible title instead of a bare `/` that
/// collides visually with a real `/` label value.
string groupKeyDisplay(string key) @safe pure
{
    import std.algorithm.iteration : map, splitter;
    import std.array : join;
    import std.algorithm.searching : all;

    if (key.splitter(groupKeySep).all!(p => !p.length))
        return "(unlabeled)";
    return key.splitter(groupKeySep).map!(p => p.length ? p : "?").join("/");
}

@("metrics.groupKeyOf.selectsLabels")
@safe
unittest
{
    auto labels = ["dataset": "twitter", "operation": "parse"];
    assert(groupKeyOf(labels, ["dataset", "operation"]) == "twitter" ~ groupKeySep ~ "parse");
    assert(groupKeyDisplay(groupKeyOf(labels, ["dataset", "operation"])) == "twitter/parse");
    assert(groupKeyOf(labels, []) == "");
    assert(groupKeyOf(labels, ["operation"]) == "parse");
    assert(groupKeyOf(labels, ["missing"]) == ""); // absent key → empty part

    // A '/' inside a value no longer collides distinct tuples (the bug the US
    // separator fixes): {a:"x/y", b:"z"} vs {a:"x", b:"y/z"} stay distinct.
    assert(groupKeyOf(["a": "x/y", "b": "z"], ["a", "b"])
        != groupKeyOf(["a": "x", "b": "y/z"], ["a", "b"]));
}

/// The sorted union of every label key present across `rows` — the set of keys a
/// `--group-by` selection can name (and what `--group-by=all` / `=list` expand to).
string[] labelKeyUnion(in BenchStats[] rows) @safe
{
    import std.algorithm.sorting : sort;

    bool[string] seen;
    foreach (ref row; rows)
        foreach (key; row.labels.byKey)
            seen[key] = true;
    return seen.keys.sort.release;
}

@("metrics.labelKeyUnion.sortedDistinct")
@safe
unittest
{
    BenchStats[3] rows;
    rows[0].labels = ["operation": "parse", "dataset": "twitter"];
    rows[1].labels = ["dataset": "canada"];
    rows[2].labels = null; // no labels
    assert(labelKeyUnion(rows) == ["dataset", "operation"]);
}

/// The display order for benchmark `rows`, as a permutation of `[0 .. rows.length)`
/// — an index array rather than a copied/re-sorted `BenchStats[]`, since `BenchStats`
/// carries mutable slice fields (`metrics`, nested `syscalls.counts`) that a `const`
/// row can't cheaply detach from.
///
/// Grouping and sorting are orthogonal. `groupKeys` (label keys) partitions rows by
/// their `labels` values under those keys and keeps each group contiguous, with
/// groups ordered by their key (alphabetical); empty = no grouping. `sortBy` then
/// orders rows *within* each group: `"name"` (alphabetical), empty/`"median/iter"`
/// (ascending median ns/iter — the default), or any other metric column name
/// (ascending value, via `rowCells`; rows missing it sort last). Error rows sort
/// last under every order (their timing fields are unset — the default-0 median
/// would masquerade as the fastest row), by name among themselves. Ties keep
/// discovery order (stable sort).
size_t[] sortOrder(in BenchStats[] rows, string sortBy, in string[] groupKeys = null) @safe
{
    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.math.traits : isNaN;
    import std.range : iota;

    // The within-group comparator selected by `sortBy`.
    bool within(size_t i, size_t j)
    {
        const iErr = rows[i].error.length > 0, jErr = rows[j].error.length > 0;
        if (iErr || jErr)
            return iErr == jErr ? iErr && rows[i].name < rows[j].name : jErr;
        if (sortBy == "name")
            return rows[i].name < rows[j].name;
        if (sortBy.length == 0 || sortBy == "median/iter")
            return rows[i].nsPerIterMedian < rows[j].nsPerIterMedian;
        const vi = sortValue(rows[i], sortBy), vj = sortValue(rows[j], sortBy);
        return !isNaN(vi) && (isNaN(vj) || vi < vj);
    }

    // Precompute group keys (all `""` when not grouping → the group comparison
    // is a no-op and `within` alone decides the order).
    auto keys = new string[rows.length];
    foreach (k, ref row; rows)
        keys[k] = groupKeyOf(row.labels, groupKeys);

    auto order = iota(rows.length).array;
    order.sort!((i, j) {
        if (keys[i] != keys[j])
            return keys[i] < keys[j];
        return within(i, j);
    }, SwapStrategy.stable);
    return order;
}

@("metrics.sortOrder.nameAndMedian")
@safe
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;

    BenchStats b, a;
    a.name = "b-slow";
    a.nsPerIterMedian = 20;
    b.name = "a-fast";
    b.nsPerIterMedian = 10;
    const rows = [a, b];

    auto names(string sortBy) => sortOrder(rows, sortBy).map!(i => rows[i].name).array;

    assert(names("name") == ["a-fast", "b-slow"]);
    assert(names(null) == ["a-fast", "b-slow"]);
    assert(names("median/iter") == ["a-fast", "b-slow"]);
}

@("metrics.sortOrder.errorRowsLast")
@safe
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;

    // An error row's timing fields are unset (median 0) — it must not
    // masquerade as the fastest row; it sorts last under every order.
    const rows = [
        BenchStats(name: "crashed-b", error: "boom"),
        BenchStats(name: "slow", nsPerIterMedian: 20),
        BenchStats(name: "crashed-a", error: "boom"),
        BenchStats(name: "fast", nsPerIterMedian: 10),
    ];

    auto names(string sortBy) => sortOrder(rows, sortBy).map!(i => rows[i].name).array;

    assert(names(null) == ["fast", "slow", "crashed-a", "crashed-b"]);
    assert(names("median/iter") == ["fast", "slow", "crashed-a", "crashed-b"]);
    assert(names("name") == ["fast", "slow", "crashed-a", "crashed-b"]);
}

@("metrics.sortOrder.groupByThenSortWithin")
@safe
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;

    // name = engine; labels carry dataset/operation. Group by [dataset, operation].
    static BenchStats row(string engine, string dataset, double median)
    {
        return BenchStats(name: engine,
            labels: ["dataset": dataset, "operation": "parse"], nsPerIterMedian: median);
    }

    BenchStats[4] rows = [
        row("asdf", "twitter", 30),
        row("mir-ion", "canada", 10),
        row("mir-ion", "twitter", 20),
        row("asdf", "canada", 40),
    ];

    auto names(string sortBy, in string[] keys)
        => sortOrder(rows, sortBy, keys).map!(i => rows[i].name).array;

    // Groups ordered by key (canada before twitter); within each, default sort
    // (median ascending) ranks the engines fastest-first — orthogonal axes.
    assert(names("median/iter", ["dataset", "operation"]) == [
        "mir-ion", "asdf",  // canada: 10, 40
        "mir-ion", "asdf",  // twitter: 20, 30
    ]);
    // Same grouping, but sort engines by name within each group instead.
    assert(names("name", ["dataset", "operation"]) == [
        "asdf", "mir-ion",  // canada
        "asdf", "mir-ion",  // twitter
    ]);
    // No grouping: pure median order across everything.
    assert(names("median/iter", null) == ["mir-ion", "mir-ion", "asdf", "asdf"]);
}

@("metrics.sortOrder.byMetricNameMissingLast")
@safe
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import sparkles.test_runner.bench : Metric, Unit;

    BenchStats withMetric, without;
    withMetric.name = "has-ipc";
    withMetric.nsPerIterMedian = 1000;
    withMetric.metrics = [Metric(Unit("op"), 5.0, Metric.Mode.level)];
    without.name = "no-ipc";
    without.nsPerIterMedian = 1000;

    const rows = [without, withMetric];
    const order = sortOrder(rows, "op");
    assert(order.map!(i => rows[i].name).array == ["has-ipc", "no-ipc"]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Catalog + selection
// ─────────────────────────────────────────────────────────────────────────────

/// The catalog across all rows: client columns (first-seen order, always
/// available) followed by the perf family (available iff any row carries
/// counters). This is the universe `--list-metrics` and `--metrics` range over.
MetricDescriptor[] catalog(in BenchStats[] rows) @safe pure nothrow
{
    import std.algorithm.searching : any;

    MetricDescriptor[] result;
    foreach (ref row; rows)
        foreach (ref m; row.metrics)
        {
            const label = clientLabel(m);
            if (!result.any!(d => d.name == label))
                result ~= MetricDescriptor(label, label, MetricFormat.count,
                    MetricClass.quantitative, "client", true, true);
        }
    const perfAvail = rows.any!(r => !r.perf.isNull);
    result ~= perfFamily(perfAvail);
    const tier0Avail = rows.any!(r => !r.tier0.isNull);
    result ~= tier0Family(tier0Avail);
    // syscall columns are dynamic (names from --syscalls); add those that appear.
    foreach (ref row; rows)
        if (!row.syscalls.isNull)
            foreach (ref c; syscallCells(row.syscalls.get))
                if (!result.any!(d => d.name == c.name))
                    result ~= MetricDescriptor(c.name, c.header, c.format, c.cls,
                        "syscall", true, true);
    return result;
}

/// The catalog metric names belonging to a static family (`perf` or `tier0`);
/// used to decide whether a `--metrics` filter would select any of them.
private string[] familyNames(string source) @safe pure nothrow
{
    string[] names;
    if (source == "perf")
        foreach (ref info; perfInfos)
            names ~= info.name;
    else if (source == "tier0")
        foreach (ref info; tier0Infos)
            names ~= info.name;
    else if (source == "syscall")
    {
        // The total only; per-syscall columns are dynamic (`syscallSelectorNames`).
        names ~= "syscalls";
    }
    return names;
}

/// The tracepoint names a `--metrics` filter requests through `syscalls:<name>`
/// selectors — the dynamic per-syscall columns, which `familyNames` can't know.
/// Naming one implies opening the syscall pass with that tracepoint, exactly as
/// `--syscalls=<name>` would.
string[] syscallSelectorNames(string metricFilter) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : startsWith;

    enum prefix = "syscalls:";
    string[] names;
    if (metricFilter == "all" || !metricFilter.length)
        return names;
    foreach (p; metricFilter.splitter(','))
        if (p.startsWith(prefix) && p.length > prefix.length)
            names ~= p[prefix.length .. $];
    return names;
}

/// The `--metrics` selectors that match nothing in `names` (the validation
/// universe) — typo candidates for a stderr warning, mirroring `--sort-by` and
/// `--group-by`. `all`/`?`/`help`/empty select by other means and are never
/// unknown.
string[] unknownMetricSelectors(in string[] names, string metricFilter) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : any;

    string[] unknown;
    if (metricFilter == "all" || metricFilter == "?" || metricFilter == "help"
        || !metricFilter.length)
        return unknown;
    foreach (p; metricFilter.splitter(','))
        if (!names.any!(n => matchesMetricGlob(n, p)))
            unknown ~= p;
    return unknown;
}

@("metrics.unknownMetricSelectors")
@safe
unittest
{
    static immutable names = ["B/s", "ipc", "cache-miss", "syscalls"];
    assert(unknownMetricSelectors(names, "ipc,nope") == ["nope"]);
    assert(unknownMetricSelectors(names, "cache-*") == [], "glob matches");
    assert(unknownMetricSelectors(names, "x*") == ["x*"], "glob matching nothing");
    assert(unknownMetricSelectors(names, "all") == []);
    assert(unknownMetricSelectors(names, "") == []);
}

/// The canonical column id for a `--sort-by` key: `sc:<name>` is the display
/// header of the `syscalls:<name>` column id `sortValue` matches on, so both
/// spellings are accepted and normalized to the id.
string canonicalSortKey(string sortBy) @safe pure nothrow
{
    import std.algorithm.searching : startsWith;

    enum display = "sc:", id = "syscalls:";
    return sortBy.startsWith(display) ? id ~ sortBy[display.length .. $] : sortBy;
}

@("metrics.canonicalSortKey")
@safe pure nothrow
unittest
{
    assert(canonicalSortKey("sc:getpid") == "syscalls:getpid");
    assert(canonicalSortKey("syscalls:getpid") == "syscalls:getpid");
    assert(canonicalSortKey("median/iter") == "median/iter");
    assert(canonicalSortKey("") == "");
}

@("metrics.syscallSelectorNames")
@safe
unittest
{
    assert(syscallSelectorNames("syscalls:futex,ipc,syscalls:write")
        == ["futex", "write"]);
    assert(syscallSelectorNames("syscalls") == [], "the total names no tracepoint");
    assert(syscallSelectorNames("all") == [], "'all' opens the pass via selectsSource");
    assert(syscallSelectorNames("") == []);
}

/// Whether a `--metrics` filter would select any metric of `source` — the gate
/// for opening that source's (opt-in) counting pass. `all` selects every source;
/// the default (empty) filter selects none of the opt-in families.
bool selectsSource(string metricFilter, string source) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : any;
    import std.array : array;

    if (metricFilter == "all")
        return true;
    if (metricFilter.length == 0)
        return false;
    auto patterns = metricFilter.splitter(',').array;
    foreach (name; familyNames(source))
        if (patterns.any!(p => matchesMetricGlob(name, p)))
            return true;
    return false;
}

/// Whether `name` matches `pattern`: a trailing `*` is a prefix match, otherwise
/// exact.
bool matchesMetricGlob(string name, string pattern) @safe pure nothrow @nogc
{
    if (pattern.length && pattern[$ - 1] == '*')
    {
        const prefix = pattern[0 .. $ - 1];
        return name.length >= prefix.length && name[0 .. prefix.length] == prefix;
    }
    return name == pattern;
}

/// The visible metric columns for a table, in catalog order, honoring `filter`:
/// null/empty = the default set (byte-identical to the legacy table — client
/// columns + the four default perf columns when available); `all` = every
/// available column; otherwise a comma-separated glob list (a selected-but-
/// unavailable column still shows, as an em-dash column, so the request is seen).
MetricDescriptor[] visibleMetrics(in BenchStats[] rows, string metricFilter) @safe
{
    import std.algorithm.iteration : filter, splitter;
    import std.algorithm.searching : any;
    import std.array : array;

    auto cat = catalog(rows);
    if (metricFilter.length == 0)
        return cat.filter!(d => d.isDefault && d.available).array;
    if (metricFilter == "all")
        return cat.filter!(d => d.available).array;
    auto patterns = metricFilter.splitter(',').array;
    return cat.filter!(d => patterns.any!(p => matchesMetricGlob(d.name, p))).array;
}

// ─────────────────────────────────────────────────────────────────────────────
// The formatting seam (later delegates to `sparkles.quantities`)
// ─────────────────────────────────────────────────────────────────────────────

/// SI-prefixed magnitude (1000-base) for a count / rate. `nan` → em dash.
package string scaled(double value) @safe
{
    import std.format : format;
    import std.math : abs, isNaN;

    if (value.isNaN)
        return "—";
    const a = abs(value);
    if (a >= 1e12)
        return format!"%.2fT"(value / 1e12);
    if (a >= 1e9)
        return format!"%.2fG"(value / 1e9);
    if (a >= 1e6)
        return format!"%.2fM"(value / 1e6);
    if (a >= 1e3)
        return format!"%.2fk"(value / 1e3);
    return format!"%.3g"(value);
}

/// A ratio/percentage cell at fixed precision. `nan` (unavailable counter) → em dash.
private string fixed(double value, int decimals, string suffix = "") @safe
{
    import std.format : format;
    import std.math : isNaN;

    return value.isNaN ? "—" : format!"%.*f%s"(decimals, value, suffix);
}

/// Renders one metric cell per its `MetricFormat`.
string formatCell(in MetricCell c) @safe
{
    final switch (c.format)
    {
    case MetricFormat.ratio:
        return fixed(c.value, 2);
    case MetricFormat.count:
        return scaled(c.value);
    case MetricFormat.percent:
        return fixed(c.value, 2, "%");
    }
}

@("metrics.matchesMetricGlob")
@safe pure nothrow @nogc
unittest
{
    assert(matchesMetricGlob("ipc", "ipc"));
    assert(!matchesMetricGlob("ipc", "instr"));
    assert(matchesMetricGlob("syscalls:futex", "syscalls:*"));
    assert(matchesMetricGlob("syscalls", "syscalls*"));
    assert(!matchesMetricGlob("syscalls", "syscalls:*")); // prefix "syscalls:" not present
    assert(matchesMetricGlob("anything", "*"));
}

@("metrics.clientCells.rateMath")
@safe pure nothrow
unittest
{
    const rate = clientCells([Metric(Unit("B"), 1000.0, Metric.Mode.rate)], 1_000_000.0);
    assert(rate[0].name == "B/s");
    assert(rate[0].value == 1e6); // 1000 units / 1ms = 1e6 units/s
    assert(rate[0].cls == MetricClass.quantitative);

    const level = clientCells([Metric(Unit("req"), 42.0, Metric.Mode.level)], 1_000_000.0);
    assert(level[0].name == "req" && level[0].value == 42.0);

    const zero = clientCells([Metric(Unit("B"), 1000.0, Metric.Mode.rate)], 0.0);
    import std.math : isNaN;

    assert(zero[0].value.isNaN); // median 0 → nan, never a divide-by-zero
}

@("metrics.catalog.defaultAndProjection")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import std.algorithm.iteration : map;
    import std.array : array;

    BenchStats withPerf;
    withPerf.name = "a";
    withPerf.nsPerIterMedian = 1_000_000.0;
    withPerf.metrics = [Metric(Unit("B"), 1000.0, Metric.Mode.rate)];
    PerfStats p;
    p.cycles = 100;
    p.instructions = 200;
    withPerf.perf = p;

    const cells = rowCells(withPerf);
    assert(cells.map!(c => c.name).array == ["B/s", "ipc", "instr", "br-miss",
        "cache-miss", "cycles", "branches", "page-faults"]);
    assert(cells[1].name == "ipc" && cells[1].value == 2.0); // 200/100

    // Default set: client column + the four default perf columns, in order.
    const def = visibleMetrics([withPerf], null);
    assert(def.map!(d => d.name).array == ["B/s", "ipc", "instr", "br-miss", "cache-miss"]);

    // `all` adds the opt-in perf extras; a glob narrows to one family.
    assert(visibleMetrics([withPerf], "all").map!(d => d.name).canFind("cycles"));
    assert(visibleMetrics([withPerf], "ipc,cycles").map!(d => d.name).array == ["ipc", "cycles"]);
}

@("metrics.catalog.clientNameCollisionPrefixed")
@safe
unittest
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : canFind;
    import std.array : array;

    // A client Metric whose label collides with a built-in column ("ipc") is
    // minted as "user.ipc": the built-in keeps its documented meaning and the
    // client value stays visible under the disambiguated name.
    BenchStats row;
    row.name = "a";
    row.metrics = [Metric(Unit("ipc"), 7.0, Metric.Mode.level)];
    PerfStats p;
    p.cycles = 100;
    p.instructions = 200;
    row.perf = p;

    const cat = catalog([row]);
    auto client = cat.filter!(d => d.name == "user.ipc").array;
    assert(client.length == 1 && client[0].source == "client");
    auto builtin = cat.filter!(d => d.name == "ipc").array;
    assert(builtin.length == 1 && builtin[0].source == "perf");

    // The cells agree with the catalog names, so both columns render.
    const cells = rowCells(row);
    assert(cells.canFind!(c => c.name == "user.ipc" && c.value == 7.0));
    assert(cells.canFind!(c => c.name == "ipc" && c.value == 2.0)); // 200/100
}

@("metrics.tier0.selectionAndProjection")
@safe
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;

    // selectsSource gates the (opt-in) tier0 pass: default off, `all` on, and a
    // matching glob on; a perf-only filter leaves tier0 off.
    assert(!selectsSource("", "tier0"));
    assert(selectsSource("all", "tier0"));
    assert(selectsSource("majflt,cache-hit", "tier0"));
    assert(selectsSource("syscalls:*", "tier0") == false);
    assert(!selectsSource("ipc", "tier0") && selectsSource("ipc", "perf"));

    Tier0Stats t;
    t.rdChars = 4096;
    t.rdBytes = 512; // 1 - 512/4096 = 87.5% cache hit
    t.majflt = 3;
    const cells = tier0Cells(t);
    assert(cells.map!(c => c.name).array[0] == "syscr");
    assert(cells[$ - 1].name == "cache-hit" && cells[$ - 1].value == 87.5);
    assert(cells[3].name == "majflt" && cells[3].value == 3);
}

@("metrics.syscalls.projectionAndDefault")
@safe
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;

    SyscallStats s;
    s.total = 88.7;
    s.named = ["futex", "sched_yield"];
    s.counts = [55.0, double.nan]; // sched_yield tracepoint unavailable → nan

    const cells = syscallCells(s);
    assert(cells.map!(c => c.name).array == ["syscalls", "syscalls:futex", "syscalls:sched_yield"]);
    assert(cells[0].value == 88.7 && cells[1].header == "sc:futex" && cells[1].value == 55.0);

    // syscall columns are default-visible when present (unlike tier0).
    BenchStats row;
    row.name = "walk";
    row.nsPerIterMedian = 1000.0;
    row.syscalls = s;
    assert(visibleMetrics([row], null).map!(d => d.name).array
        == ["syscalls", "syscalls:futex", "syscalls:sched_yield"]);
}

@("metrics.catalog.noPerfNoColumns")
@safe
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;

    BenchStats plain;
    plain.name = "a";
    plain.nsPerIterMedian = 1000.0;
    // No perf, no client metrics: default set is empty (legacy: no metric columns).
    assert(visibleMetrics([plain], null).length == 0);
    // A selected-but-unavailable perf column still appears (em-dash column).
    assert(visibleMetrics([plain], "ipc").map!(d => d.name).array == ["ipc"]);
}

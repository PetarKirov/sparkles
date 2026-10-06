/**
The log page (`TPG8`, mockup LG1): the application's log, dense, one entry a
row — time, level, source, message — read from the ring
`logging.installTerminalLog` keeps.

$(LIST
    * $(B Search on its own row) under the header: free text, `source:<name>`
        and `/regex/`. The free text is matched and ranked by `sparkles:fuzzy`
        (best first); `source:` keeps the entries of the sources it names (a
        prefix: `source:am` is the `am` server); a `/regex/` keeps the entries
        whose message it matches.
    * $(B Filters on the row below): level chips (debug off by default) and a
        source chip that steps through the sources seen.
    * $(B Following the tail) while scrolled to the bottom; scrolled up, the
        view is anchored on an entry, so a new one never moves a reader.
    * Copy (the entries the filters keep), Share (Android `ACTION_SEND`),
        and the previous run's file (`terminal.log.1`, `TPG5`).
)

Keys (`KBD1`): `/` search, arrows and PgUp/PgDn scroll, End follows again,
`d` `i` `w` `e` toggle the levels, `s` steps the source, `p` switches to the
previous run and back, `c` copies.
*/
module log_page;

import sparkles.base.log_sinks : RingCoreLogger, RingLogRecord;
import sparkles.base.logger : LogLevel;
import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.geometry : Insets, Point, Rect, SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind, WidgetTree;

import chrome : button, column, label, row, uiLabel;
import settings : ButtonLabels;
import page_kit : bodyRowsFor, chip, finishPage, firstOwnHit, header, Page, PageServices,
    searchField;
import surfaces : SurfaceContext;

/// The four levels the chips filter by.
enum LevelChip : ubyte
{
    debug_, /// `trace`
    info,
    warn,
    error, /// `error`, `critical` and `fatal`
}

/// The chip a level falls under.
LevelChip chipOf(LogLevel l) @safe pure nothrow @nogc
{
    if (l <= LogLevel.trace)
        return LevelChip.debug_;
    if (l <= LogLevel.info)
        return LevelChip.info;
    if (l <= LogLevel.warning)
        return LevelChip.warn;
    return LevelChip.error;
}

/// One entry, copied out of the ring or read from the previous run's file.
struct LogLine
{
    ulong seq;
    LogLevel level;
    string source;
    string time; /// `HH:MM:SS`
    string message;
}

/**
An entry's source: its file's base name up to the first `_` or `.` —
`am_server.d` and `am_command.d` are `am`, `installer.d` is `installer`,
`settings_load.d` is `settings`.
*/
string logSource(scope const(char)[] file) @safe pure nothrow
{
    size_t start;
    foreach (i, c; file)
        if (c == '/' || c == '\\')
            start = i + 1;
    size_t end = start;
    while (end < file.length && file[end] != '_' && file[end] != '.')
        end++;
    return end > start ? file[start .. end].idup : "?";
}

///
@("log_page.logSource.byFile")
@safe pure nothrow unittest
{
    assert(logSource("apps/terminal/src/am_server.d") == "am");
    assert(logSource("am_command.d") == "am");
    assert(logSource("/x/installer.d") == "installer");
    assert(logSource("settings_load.d") == "settings");
    assert(logSource("") == "?");
}

/**
Parses one line of the log file (`RotatingFileCoreLogger`'s
`HH:MM:SS LVL file.d:line: message`); false for a line that is not one — a
message's own continuation lines.
*/
bool parseLogFileLine(string text, ulong seq, out LogLine l) @safe pure nothrow
{
    import std.algorithm.searching : findSplit;

    if (text.length < 13 || text[2] != ':' || text[5] != ':' || text[8] != ' '
        || text[12] != ' ')
        return false;
    LogLevel level;
    switch (text[9 .. 12])
    {
        case "TRC": level = LogLevel.trace; break;
        case "INF": level = LogLevel.info; break;
        case "WRN": level = LogLevel.warning; break;
        case "ERR": level = LogLevel.error; break;
        case "CRT": level = LogLevel.critical; break;
        case "FTL": level = LogLevel.fatal; break;
        default: return false;
    }
    auto rest = text[13 .. $].findSplit(": ");
    if (!rest[1].length)
        return false;
    l = LogLine(seq, level, logSource(rest[0]), text[0 .. 8], rest[2]);
    return true;
}

///
@("log_page.parseLogFileLine.theFileFormat")
@safe pure nothrow unittest
{
    LogLine l;
    assert(parseLogFileLine("09:14:41 WRN settings_load.d:212: config.json:12:5: bad", 3, l));
    assert(l.level == LogLevel.warning && l.source == "settings" && l.time == "09:14:41");
    assert(l.message == "config.json:12:5: bad" && l.seq == 3);
    assert(!parseLogFileLine("  continued", 4, l));
    assert(!parseLogFileLine("09:14:41 XXX a.d:1: m", 5, l));
}

/// What a search asks: free text, the sources named, a regex.
struct LogQuery
{
    string text;      /// the free text, for `sparkles:fuzzy`
    string[] sources; /// `source:<name>` prefixes, any of which admits
    string regex;     /// `/regex/`, without the slashes
}

/// Splits a search into its parts; tokens are separated by spaces.
LogQuery parseLogQuery(string q) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : startsWith;
    import std.array : join;

    LogQuery r;
    string[] free;
    foreach (tok; q.splitter(' '))
    {
        if (!tok.length)
            continue;
        if (tok.startsWith("source:") && tok.length > 7)
            r.sources ~= tok[7 .. $];
        else if (tok.length > 2 && tok[0] == '/' && tok[$ - 1] == '/')
            r.regex = tok[1 .. $ - 1];
        else
            free ~= tok;
    }
    r.text = free.join(" ");
    return r;
}

///
@("log_page.parseLogQuery.threeKinds")
@safe pure unittest
{
    const q = parseLogQuery("post source:notify  /denied|refused/ toast");
    assert(q.text == "post toast");
    assert(q.sources == ["notify"]);
    assert(q.regex == "denied|refused");
    assert(parseLogQuery("source:").text == "source:", "an empty source is text");
}

/**
The entries `lines` keeps under `levels`, `source` (null: every source) and
`q`, as indices into `lines`: oldest first without free text; with it, ranked
by `sparkles:fuzzy`, best first, a tie to the newer entry. `regexError` says
why a regex was ignored.
*/
size_t[] filterLog(in LogLine[] lines, in bool[4] levels, string source, const LogQuery q,
    out string regexError) @safe
{
    import std.algorithm.searching : startsWith;
    import std.algorithm.sorting : sort;
    import std.regex : Regex, matchFirst, regex;

    import sparkles.fuzzy.common : CandidateView, DefaultFuzzyCaps, FuzzyLimits;
    import sparkles.fuzzy.match : match, MatchConfig, MatcherWorkspace, MatchKind, Scoring;
    import sparkles.fuzzy.query : parseQuery, QueryStorage;

    Regex!char re;
    bool useRegex;
    if (q.regex.length)
    {
        try
        {
            re = regex(q.regex);
            useRegex = true;
        }
        catch (Exception e)
            regexError = e.msg;
    }

    QueryStorage!()* fuzzy;
    if (q.text.length)
    {
        auto parsed = parseQuery(q.text);
        if (!parsed.hasError && parsed.value.hasFuzzyParts)
        {
            fuzzy = new QueryStorage!();
            *fuzzy = parsed.value;
        }
    }
    auto ws = fuzzy !is null ? new MatcherWorkspace!() : null;

    static struct Ranked
    {
        size_t index;
        long score;
    }

    Ranked[] kept;
    foreach (i, ref l; lines)
    {
        if (!levels[chipOf(l.level)])
            continue;
        if (source.length && l.source != source)
            continue;
        if (q.sources.length)
        {
            bool any;
            foreach (s; q.sources)
                any |= l.source.startsWith(s);
            if (!any)
                continue;
        }
        if (useRegex)
        {
            bool hit;
            try
                hit = !matchFirst(l.message, re).empty;
            catch (Exception)
                hit = false;
            if (!hit)
                continue;
        }
        long score;
        if (q.text.length)
        {
            if (fuzzy !is null)
            {
                CandidateView cand = {path: utf8Prefix(l.message, DefaultFuzzyCaps.maxCandidateBytes)};
                auto r = match(*fuzzy, cand, MatchConfig.init, Scoring.init, FuzzyLimits.init, *ws);
                if (r.hasError || !r.value.admitted)
                    continue;
                score = r.value.score;
            }
            else if (!containsFolded(l.message, q.text))
                continue; // the query has no fuzzy part: a literal match
        }
        kept ~= Ranked(i, score);
    }
    if (q.text.length)
        kept.sort!((a, b) => a.score != b.score ? a.score > b.score : a.index > b.index);
    auto r = new size_t[kept.length];
    foreach (i, k; kept)
        r[i] = k.index;
    return r;
}

/// The longest prefix of `s` at most `n` bytes that ends on a UTF-8 boundary.
private const(char)[] utf8Prefix(return scope const(char)[] s, size_t n) @safe pure nothrow @nogc
{
    if (s.length <= n)
        return s;
    while (n > 0 && (s[n] & 0xC0) == 0x80)
        n--;
    return s[0 .. n];
}

/// Whether `hay` contains `needle`, ASCII case folded.
private bool containsFolded(scope const(char)[] hay, scope const(char)[] needle) @safe pure nothrow @nogc
{
    static char lower(char c) => c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
    if (needle.length > hay.length)
        return false;
    outer: foreach (i; 0 .. hay.length - needle.length + 1)
    {
        foreach (j, c; needle)
            if (lower(hay[i + j]) != lower(c))
                continue outer;
        return true;
    }
    return false;
}

@("log_page.filterLog.levelsSourcesRegexAndRank")
@safe unittest
{
    LogLine[] ls = [
        LogLine(0, LogLevel.info, "am", "09:00:00", "server on am.sock"),
        LogLine(1, LogLevel.trace, "session", "09:00:01", "login pid 4211"),
        LogLine(2, LogLevel.warning, "settings", "09:00:02", "links.tap: confrim is not a value"),
        LogLine(3, LogLevel.error, "notify", "09:00:03", "post refused: permission denied"),
        LogLine(4, LogLevel.info, "notify", "09:00:04", "notification posted for pane 2"),
    ];
    bool[4] std = [false, true, true, true];
    string err;

    // Debug is off by default; every other entry, oldest first.
    assert(filterLog(ls, std, null, LogQuery.init, err) == [0, 2, 3, 4]);
    // The source chip and `source:`.
    assert(filterLog(ls, std, "notify", LogQuery.init, err) == [3, 4]);
    assert(filterLog(ls, std, null, parseLogQuery("source:se"), err) == [2]);
    // A regex keeps what it matches; a broken one is reported and ignored.
    assert(filterLog(ls, std, null, parseLogQuery("/refused|posted/"), err) == [3, 4]);
    assert(filterLog(ls, std, null, parseLogQuery("/(/"), err).length == 4 && err.length);
    // Free text through sparkles:fuzzy: a typo still finds it, ranked.
    const hits = filterLog(ls, std, null, parseLogQuery("notifcation"), err);
    assert(hits.length && hits[0] == 4);
}

/// Hit ids.
private enum Hit : size_t
{
    level = firstOwnHit, // + LevelChip
    source = firstOwnHit + 8,
    previous,
    copy,
    share,
    follow,
}

/// The log page.
final class LogPage : Page
{
    private RingCoreLogger ring;
    private string previousPath;

    private LogLine[] current; // copied from the ring
    private ulong nextSeq;     // the ring's next entry to copy
    private LogLine[] previous; // the previous run's file, when shown
    private bool showingPrevious;

    private bool[4] levels = [false, true, true, true];
    private string source;    // the source chip's choice; null: all
    private size_t[] shown;   // filtered (and ranked) indices
    private bool stale = true; // `shown` must be recomputed
    private bool following = true;
    private ulong topSeq;     // the anchored first entry, when not following
    private size_t rankTop;   // the first ranked entry shown, while searching
    private string regexError;

    /// `ring` is the log (`logging.terminalLog`); `previousPath` the previous
    /// run's file (`logging.previousLogPath`), empty for none.
    this(RingCoreLogger ring, string previousPath, PageServices services) @safe
    {
        super(services);
        this.ring = ring;
        this.previousPath = previousPath;
    }

    override bool hasSearch() const @safe pure nothrow @nogc => true;

    override void queryChanged() @safe
    {
        stale = true;
        following = true;
        rankTop = 0;
    }

    /// The entries now shown in order (for tests and Copy).
    private ref LogLine[] lines() @safe pure nothrow @nogc return
        => showingPrevious ? previous : current;

    private bool ranked() const @safe pure => parseLogQuery(query).text.length > 0;

    /// Copies what the ring gained since the last look.
    private void pull() @safe
    {
        if (ring is null)
            return;
        import std.format : format;

        const before = nextSeq;
        ring.each((scope const ref RingLogRecord r) {
            current ~= LogLine(r.seq, r.level, logSource(r.file),
                format!"%02d:%02d:%02d"(r.hour, r.minute, r.second), r.message.idup);
            nextSeq = r.seq + 1;
        }, nextSeq);
        if (nextSeq == before)
            return;
        // The ring forgot the oldest: so does the page, keeping its own
        // bounded copy.
        enum keep = RingCoreLogger.defaultCapacity;
        if (current.length > keep + keep / 4)
            current = current[$ - keep .. $].dup;
        if (!showingPrevious)
        {
            stale = true;
            if (services.repaint !is null)
                services.repaint();
        }
    }

    /// Reads the previous run's file.
    private void loadPrevious() @system
    {
        import std.algorithm.iteration : splitter;
        import std.file : exists, readText;

        previous = null;
        if (!previousPath.length)
            return;
        try
        {
            if (!previousPath.exists)
                return;
            ulong seq;
            foreach (line; readText(previousPath).splitter('\n'))
            {
                LogLine l;
                if (parseLogFileLine(line, seq, l))
                {
                    previous ~= l;
                    seq++;
                }
                else if (line.length && previous.length)
                    previous[$ - 1].message ~= "\n" ~ line;
            }
        }
        catch (Exception e)
        {
            if (services.toast !is null)
                services.toast("Cannot read the previous run: " ~ e.msg);
        }
    }

    private void refilter() @safe
    {
        if (!stale)
            return;
        shown = filterLog(lines, levels, source, parseLogQuery(query), regexError);
        stale = false;
    }

    /// The index into `shown` of the first row, for `rows` rows of body.
    private size_t firstRow(int rows) @safe
    {
        const n = shown.length;
        const r = rows > 0 ? cast(size_t) rows : 1;
        if (ranked)
            return rankTop + r > n ? (n > r ? n - r : 0) : rankTop;
        if (following)
            return n > r ? n - r : 0;
        // Anchored on an entry: the first shown at or after it.
        size_t i;
        while (i < n && lines[shown[i]].seq < topSeq)
            i++;
        return i + r > n ? (n > r ? n - r : 0) : i;
    }

    override void scrolled(int delta) @safe
    {
        refilter();
        const rows = viewRows > 0 ? viewRows : 1;
        const first = firstRow(rows);
        long to = cast(long) first + delta;
        const last = shown.length > rows ? shown.length - rows : 0;
        if (to < 0)
            to = 0;
        if (to >= last)
            to = last;
        if (ranked)
        {
            rankTop = cast(size_t) to;
            return;
        }
        // At the bottom it follows; anywhere above it stays put (`TPG8`).
        following = to >= last;
        if (!following && shown.length)
            topSeq = lines[shown[cast(size_t) to]].seq;
    }

    override WidgetTree buildPage(in SurfaceContext ctx, int cols, int rows) @safe
    {
        import std.conv : text;

        if (!showingPrevious)
            pull();
        refilter();

        // A phone held upright: one-letter level chips, icon-only buttons, no
        // source column — the message keeps the width.
        const narrow = cols < 60;
        const labels = narrow ? ButtonLabels.icon : ctx.labels;
        Builder b;
        uint[] actions;
        if (services.share !is null)
            actions ~= button(b, "↗", "Share", labels, Hit.share, minRows: ctx.targetRows);
        const head = header(b, showingPrevious ? "Logs · previous run" : "Logs", ctx, actions);

        const search = b.add(Widget(kind: WidgetKind.panel,
            children: [searchField(b, query, searching,
                "Search · text, source:am, /regex/", ctx.targetRows)],
            width: SizeSpec.grow(), padding: Insets(0, 1, 0, 1)));

        static immutable string[4] names = ["debug", "info", "warn", "error"];
        static immutable string[4] letters = ["D", "I", "W", "E"];
        uint[] chips;
        foreach (i, name; names)
            chips ~= chip(b, narrow ? letters[i] : name, levels[i], Hit.level + i, ctx.targetRows);
        chips ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
        chips ~= chip(b, (narrow ? "" : "source: ") ~ (source.length ? source : "all") ~ " ▾", source.length > 0,
            Hit.source, ctx.targetRows);
        const filters = b.add(Widget(kind: WidgetKind.row, children: chips, gap: 1,
            width: SizeSpec.grow(), padding: Insets(0, 1, 0, 1)));

        // The body: as many entries as fit — laid out once empty to learn
        // how many that is.
        uint body_(ref Builder bb, size_t first, size_t count)
        {
            uint[] items;
            foreach (k; first .. first + count)
                items ~= entryRow(bb, lines[shown[k]], !narrow);
            if (!shown.length)
                items ~= uiLabel(bb, lines.length ? "No entry matches." : "The log is empty.",
                    Slot.muted);
            return bb.add(Widget(kind: WidgetKind.column, children: items,
                width: SizeSpec.grow()));
        }

        string status;
        Slot statusSlot = Slot.muted;
        if (regexError.length)
        {
            status = "✗ regex: " ~ regexError;
            statusSlot = Slot.error;
        }
        else if (ranked)
            status = text("⌕ ", shown.length, " ranked");
        else if (showingPrevious)
            status = text("⟲ ", shown.length, " entries");
        else if (following)
        {
            status = "● following";
            statusSlot = Slot.success;
        }
        else
            status = narrow ? "○ paused" : "○ paused · End follows";
        // The footer has room for captions on a phone too (LG1).
        uint[] foot = [uiLabel(b, status, statusSlot),
            b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()))];
        if (previousPath.length)
            foot ~= button(b, "⟲", showingPrevious ? "This run" : "Previous run", ctx.labels,
                Hit.previous, minRows: ctx.targetRows);
        if (services.copy !is null)
            foot ~= button(b, "⧉", "Copy", ctx.labels, Hit.copy, minRows: ctx.targetRows);
        const footer = b.add(Widget(kind: WidgetKind.row, children: foot, gap: 1,
            alignY: Alignment.center, width: SizeSpec.grow(), padding: Insets(0, 1, 0, 1),
            slot: Slot.surfaceSunken, paintBackground: true));

        // Measure the body with nothing in it, then fill it.
        viewRows = bodyRowsFor(b, [head, search, filters], [footer], cols, rows);
        const first = firstRow(viewRows);
        const count = shown.length - first < viewRows ? shown.length - first : viewRows;
        int noScroll; // the window is the scroll: the body is exactly the rows shown
        return finishPage(b, [head, search, filters], body_(b, first, count), [footer],
            viewRows, noScroll, cols, rows);
    }

    /// One entry: time, level letter, source, message — the level's colour
    /// on warnings and errors, its letter in every case (`ACC3`).
    private static uint entryRow(ref Builder b, const LogLine l, bool withSource = true) @safe
    {
        import std.array : replace;

        static immutable letters = ["D ", "I ", "W ", "E "];
        const c = chipOf(l.level);
        const slot = c == LevelChip.error ? Slot.error : c == LevelChip.warn ? Slot.warn
            : c == LevelChip.debug_ ? Slot.muted : Slot.textPrimary;
        string src = l.source;
        if (src.length < 10)
            src ~= "          "[0 .. 10 - src.length];
        if (!withSource)
            src = null;
        auto spans = new TextSpan[4];
        spans[0] = TextSpan(text: l.time ~ " ", slot: Slot.muted);
        spans[1] = TextSpan(text: letters[c], slot: slot,
            textStyle: TextStyle(bold: c >= LevelChip.warn));
        spans[2] = TextSpan(text: src, slot: Slot.textSecondary);
        spans[3] = TextSpan(text: l.message.replace("\n", " ⏎ "), slot: slot);
        return b.add(Widget(kind: WidgetKind.rich, spans: spans));
    }

    override bool onHit(size_t id) @system
    {
        if (id >= Hit.level && id < Hit.level + 4)
        {
            levels[id - Hit.level] = !levels[id - Hit.level];
            stale = true;
            following = true;
            return false;
        }
        switch (id)
        {
            case Hit.source:
                stepSource();
                break;
            case Hit.previous:
                togglePrevious();
                break;
            case Hit.copy:
                if (services.copy !is null)
                {
                    services.copy(visibleText());
                    if (services.toast !is null)
                        services.toast("Copied the log");
                }
                break;
            case Hit.share:
                if (services.share !is null)
                    services.share(visibleText());
                break;
            default:
                break;
        }
        return false;
    }

    override bool onKey(in KeyEvent k) @system
    {
        if (k.key != Key.char_)
            return false;
        switch (k.ch)
        {
            case 'd': return onHit(Hit.level + LevelChip.debug_) || true;
            case 'i': return onHit(Hit.level + LevelChip.info) || true;
            case 'w': return onHit(Hit.level + LevelChip.warn) || true;
            case 'e': return onHit(Hit.level + LevelChip.error) || true;
            case 's': return onHit(Hit.source) || true;
            case 'p': return onHit(Hit.previous) || true;
            case 'c': return onHit(Hit.copy) || true;
            default: return false;
        }
    }

    /// The source chip's next choice: all, then each source seen, in order.
    private void stepSource() @safe
    {
        import std.algorithm.sorting : sort;
        import std.algorithm.iteration : uniq;
        import std.array : array;

        string[] seen;
        foreach (ref l; lines)
            seen ~= l.source;
        auto names = seen.sort.uniq.array;
        size_t at = names.length; // "all"
        foreach (i, n; names)
            if (n == source)
                at = i;
        source = at + 1 < names.length ? names[at + 1] : at == names.length && names.length
            ? names[0] : null;
        stale = true;
        following = true; // a new filter shows its tail
    }

    private void togglePrevious() @system
    {
        showingPrevious = !showingPrevious;
        if (showingPrevious)
            loadPrevious();
        stale = true;
        rankTop = 0;
        following = true;
    }

    /// What Copy and Share take: the entries the filters keep, in order.
    private string visibleText() @safe
    {
        import std.array : appender;

        refilter();
        auto w = appender!string;
        static immutable letters = ["D", "I", "W", "E"];
        foreach (i; shown)
        {
            const l = lines[i];
            w.put(l.time);
            w.put(' ');
            w.put(letters[chipOf(l.level)]);
            w.put(' ');
            w.put(l.source);
            w.put(": ");
            w.put(l.message);
            w.put('\n');
        }
        return w[];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private RingCoreLogger testRing(size_t n) @safe
    {
        import sparkles.base.logger : CoreLogEntry;

        auto r = new RingCoreLogger(LogLevel.all);
        foreach (i; 0 .. n)
            ringWrite(r, i % 7 == 6 ? LogLevel.warning : LogLevel.info, "entry");
        return r;
    }

    private void ringWrite(RingCoreLogger r, LogLevel level, string msg) @trusted
    {
        import sparkles.base.logger : CoreLogEntry;

        CoreLogEntry e;
        e.level = level;
        e.file = "apps/terminal/src/am_server.d";
        e.moduleName = "am_server";
        r.forwardCoreLog(e, msg);
    }

    private string[] rowTexts(in WidgetTree t) @safe
    {
        string[] r;
        foreach (ref n; t.nodes)
            if (n.kind == WidgetKind.rich && n.spans.length == 4)
                r ~= n.spans[3].text.idup;
        return r;
    }
}

@("log_page.LogPage.followsTheTailAndStaysWhenScrolledUp")
@system unittest
{
    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.area = Rect(0, 0, 80, 20);
    auto ring = new RingCoreLogger(LogLevel.all);
    foreach (i; 0 .. 40)
    {
        import std.conv : text;

        ringWrite(ring, LogLevel.info, text("entry ", i));
    }
    auto p = new LogPage(ring, null, PageServices.init);
    auto rows = rowTexts(p.build(ctx, 80));
    assert(rows.length == p.bodyRows && rows[$ - 1] == "entry 39", "following: the tail");

    // A new entry while following: it shows.
    ringWrite(ring, LogLevel.info, "entry 40");
    rows = rowTexts(p.build(ctx, 80));
    assert(rows[$ - 1] == "entry 40");

    // Scrolled up, a new entry never moves the reader (`TPG8`).
    p.scrolled(-5);
    const before = rowTexts(p.build(ctx, 80));
    ringWrite(ring, LogLevel.info, "entry 41");
    assert(rowTexts(p.build(ctx, 80)) == before);
    assert(!p.following);

    // Back to the bottom: following again, the new entry shows.
    p.scrolled(1000);
    assert(p.following);
    assert(rowTexts(p.build(ctx, 80))[$ - 1] == "entry 41");
}

@("log_page.LogPage.chipsSearchAndCopy")
@system unittest
{
    import std.algorithm.searching : canFind, count;

    string copied;
    PageServices s;
    s.copy = (string t) { copied = t; };
    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.area = Rect(0, 0, 80, 30);
    auto ring = new RingCoreLogger(LogLevel.all);
    ringWrite(ring, LogLevel.info, "server on am.sock");
    ringWrite(ring, LogLevel.trace, "accepted a connection");
    ringWrite(ring, LogLevel.warning, "request refused");
    auto p = new LogPage(ring, null, s);
    assert(rowTexts(p.build(ctx, 80)) == ["server on am.sock", "request refused"]);

    // `d` turns debug on; `w` turns warnings off.
    assert(p.key(KeyEvent(Key.char_, 'd')) && p.key(KeyEvent(Key.char_, 'w')));
    assert(rowTexts(p.build(ctx, 80)) == ["server on am.sock", "accepted a connection"]);

    // Searching ranks by sparkles:fuzzy.
    p.setQuery("conection");
    assert(rowTexts(p.build(ctx, 80)) == ["accepted a connection"]);

    // Copy takes what the filters keep.
    assert(p.key(KeyEvent(Key.char_, 'c')));
    assert(copied.count('\n') == 1 && copied.canFind("I am: accepted a connection")
        || copied.canFind("D am: accepted a connection"));
}

@("log_page.LogPage.previousRunFromTheFile")
@system unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir, "log_page-previous-test.log");
    write(path, "09:00:00 INF app.d:10: started\n09:00:01 ERR am_server.d:5: crashed\n  at here\n");
    scope (exit) remove(path);
    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.area = Rect(0, 0, 80, 20);
    auto p = new LogPage(testRing(3), path, PageServices.init);
    assert(rowTexts(p.build(ctx, 80)).length == 3);
    assert(p.key(KeyEvent(Key.char_, 'p')));
    assert(rowTexts(p.build(ctx, 80)) == ["started", "crashed ⏎   at here"]);
    assert(p.key(KeyEvent(Key.char_, 'p')));
    assert(rowTexts(p.build(ctx, 80)).length == 3);
}

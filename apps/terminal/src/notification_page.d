/**
The notification log page (`TPG9`–`TPG11`, `TPG18`, mockup N2): every
notification a pane raised, grouped by a control on the page.

$(LIST
    * $(B Grouping) (D38): none (one list, newest first), tab/split, app, coding
        agent, project, or the user's rules (`notifications.groups`, first
        match wins, the rest in "Other"). The app is the pane's foreground
        process when the notification arrived; the project its working
        directory collapsed to the enclosing git root; an agent is a process
        on $(LREF knownAgents) or `notifications.agents`. An entry whose app
        or directory was unknown falls in "Unknown". The choice persists
        (`<state>/sparkles-terminal/pages.json`).
    * $(B Activating) an entry selects its tab and focuses its pane (`TPG10`);
        an entry whose pane has closed says so and stays inert.
    * $(B Unseen) entries carry a dot (`TPG11`); opening the page marks them
        seen — they keep their dot while it is open — and Mark all read clears
        the dots.
)

Keys (`KBD1`): arrows move the selection, Enter opens it, `g`/`G` step the
grouping, `r` marks all read.
*/
module notification_page;

import std.datetime.systime : SysTime;

import sparkles.input.events : Key, KeyEvent;
import sparkles.terminal_view.notification_log : NotificationLog, NotificationRecord,
    NotificationRoute;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.style : Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind, WidgetTree;

import chrome : button, column, label, row;
import page_kit : bodyRowsFor, chip, finishPage, firstOwnHit, header, Page, PageServices, prose;
import settings : ButtonLabels, NotificationGroupRule, NotificationsConfig;
import surfaces : SurfaceContext;

/// How the log is grouped (`TPG18`).
enum Grouping : ubyte
{
    time,    /// one list, newest first
    tab,     /// by the tab the pane was in
    app,     /// by the foreground process
    agent,   /// coding agents by name; everything else together
    project, /// by the working directory's git root
    rules,   /// by `notifications.groups`
}

/// The coding agents recognised without configuration.
immutable string[] knownAgents = ["claude", "codex", "aider", "gemini", "opencode",
    "goose", "amp", "cursor-agent", "copilot", "crush", "qwen"];

/// What a grouping needs besides the record: the rules, the agents, and how
/// to find a directory's project.
struct GroupContext
{
    NotificationGroupRule[] rules;
    string[] agents; /// beyond $(LREF knownAgents)
    string home;     /// `~` in rules and in shown paths
    /// The project of a directory: its git root (default: walks up for `.git`).
    string delegate(string dir) @safe projectOf;
}

/// The group a record falls in under `g`; "" under `Grouping.time`.
string groupOf(const NotificationRecord r, Grouping g, const GroupContext c) @safe
{
    import std.algorithm.searching : canFind;

    final switch (g)
    {
        case Grouping.time:
            return "";
        case Grouping.tab:
            return r.tabTitle.length ? "tab \"" ~ r.tabTitle ~ "\"" : "Unknown";
        case Grouping.app:
            return r.process.length ? r.process : "Unknown";
        case Grouping.agent:
            if (!r.process.length)
                return "Unknown";
            return knownAgents.canFind(r.process) || c.agents.canFind(r.process)
                ? r.process : "Not an agent";
        case Grouping.project:
            if (!r.cwd.length)
                return "Unknown";
            return tildeOf(c.projectOf !is null ? c.projectOf(r.cwd) : r.cwd, c.home);
        case Grouping.rules:
            foreach (ref rule; c.rules)
                if (ruleMatches(rule, r, c.home))
                    return rule.group.length ? rule.group : "Other";
            return "Other";
    }
}

/// Whether every field `rule` sets matches `r`: `app` is a `|` list of
/// process names; `cwd` and `tab` are globs (`~` is the home directory).
bool ruleMatches(const NotificationGroupRule rule, const NotificationRecord r, string home) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind, startsWith;
    import std.path : globMatch;

    if (!rule.app.length && !rule.cwd.length && !rule.tab.length)
        return false;
    if (rule.app.length && !(r.process.length && rule.app.splitter('|').canFind(r.process)))
        return false;
    if (rule.cwd.length)
    {
        const pattern = home.length && rule.cwd.startsWith("~") ? home ~ rule.cwd[1 .. $] : rule.cwd;
        if (!r.cwd.length || !globMatch(r.cwd, pattern))
            return false;
    }
    if (rule.tab.length && !globMatch(r.tabTitle, rule.tab))
        return false;
    return true;
}

/// `path` with the home directory spelled `~`.
string tildeOf(string path, string home) @safe pure nothrow
{
    import std.algorithm.searching : startsWith;

    if (home.length && path.startsWith(home)
        && (path.length == home.length || path[home.length] == '/'))
        return "~" ~ path[home.length .. $];
    return path;
}

/// The enclosing git root of `dir` (a directory holding `.git`), or `dir`
/// itself when there is none.
string gitRootOf(string dir) @safe
{
    import std.file : exists;
    import std.path : buildPath, dirName;

    try
    {
        for (string d = dir; d.length; )
        {
            if (buildPath(d, ".git").exists)
                return d;
            const up = d.dirName;
            if (up == d)
                break;
            d = up;
        }
    }
    catch (Exception)
    {
    }
    return dir;
}

/// How long ago `t` was, from `now`: `now`, `5 min`, `3 h`, `2 d`.
string agoText(SysTime t, SysTime now) @safe
{
    import std.conv : text;

    const s = (now - t).total!"seconds";
    if (s < 60)
        return "now";
    if (s < 3600)
        return text(s / 60, " min");
    if (s < 86_400)
        return text(s / 3600, " h");
    return text(s / 86_400, " d");
}

/// One group: its title and its entries (indices into the log), newest first.
struct Group
{
    string title;
    size_t[] entries;
}

/// The log's entries grouped by `g`: groups ordered by their newest entry,
/// entries newest first.
Group[] groupLog(ref const NotificationLog log, Grouping g, const GroupContext c) @safe
{
    Group[] groups;
    size_t[string] at;
    foreach_reverse (i; 0 .. log.length)
    {
        const key = groupOf(log[i], g, c);
        if (auto p = key in at)
            groups[*p].entries ~= i;
        else
        {
            at[key] = groups.length;
            groups ~= Group(key, [i]);
        }
    }
    return groups;
}

/// The page's own state, kept across runs.
struct PagesState
{
    Grouping notificationGrouping = Grouping.tab;
}

/// Hit ids.
private enum Hit : size_t
{
    markRead = firstOwnHit,
    grouping = firstOwnHit + 0x10, // + Grouping
    entry = firstOwnHit + 0x100,   // + the entry's index in the log
}

/// The notification log page.
final class NotificationPage : Page
{
    private NotificationLog* log;
    private GroupContext context;
    private Grouping grouping;
    private string statePath; // where the grouping persists; empty: nowhere
    private ulong seenBefore; // entries seen before the page opened (absolute)
    private size_t[] order;   // the entries as shown, top to bottom
    private size_t selected;  // into `order`
    private bool keyboard;    // the selection is shown (a key moved it)
    private SysTime now;      // for "… ago"; set per build unless a test pins it
    private bool pinnedNow;

    /**
    `log` is the application's (`WorkspaceHost.notifications`); `config` its
    `notifications` section; `statePath` the file the grouping persists in.
    Opening the page marks the log seen (`TPG11`).
    */
    this(NotificationLog* log, NotificationsConfig config, string statePath,
        PageServices services) @safe
    {
        import std.process : environment;

        super(services);
        this.log = log;
        this.statePath = statePath;
        context.rules = config.groups.dup;
        context.agents = config.agents.dup;
        context.home = environment.get("HOME");
        string[string] roots;
        context.projectOf = (string dir) @safe {
            if (auto p = dir in roots)
                return *p;
            return roots[dir] = gitRootOf(dir);
        };
        grouping = loadGrouping(statePath);
        seenBefore = log.total - log.unseen;
        log.markAllSeen();
    }

    /// Pins "now" (tests).
    void pinNow(SysTime t) @safe pure nothrow @nogc
    {
        now = t;
        pinnedNow = true;
    }

    private bool unseen(size_t i) const @safe pure nothrow @nogc
        => log.total - log.length + i >= seenBefore;

    override WidgetTree buildPage(in SurfaceContext ctx, int cols, int rows) @safe
    {
        import std.datetime.systime : Clock;

        if (!pinnedNow)
            now = Clock.currTime;
        log.markAllSeen(); // the page is open: what arrives is seen

        // A phone held upright: the six chips take two rows, the header's
        // button its icon.
        const narrow = cols < 60;
        Builder b;
        const head = header(b, "Notifications", ctx,
            [button(b, "✓", "Mark all read", narrow ? ButtonLabels.icon : ctx.labels,
                Hit.markRead, minRows: ctx.targetRows)]);

        static immutable string[6] names = ["Time", "Tab/split", "App", "Agents", "Project", "Rules"];
        uint chipRow(ref Builder bb, uint[] children)
            => bb.add(Widget(kind: WidgetKind.row, children: children, gap: 1,
                alignY: Alignment.center, width: SizeSpec.grow(), padding: Insets(0, 1, 0, 1)));
        uint[] chips;
        foreach (i, name; names)
            chips ~= chip(b, name, grouping == i, Hit.grouping + i, ctx.targetRows);
        uint[] top = [head];
        if (narrow)
            top ~= [chipRow(b, chips[0 .. 3]), chipRow(b, chips[3 .. $])];
        else
            top ~= chipRow(b, label(b, "Group", Slot.muted) ~ chips);
        if (grouping == Grouping.rules)
            top ~= rulesBand(b);

        uint[] cards;
        uint reveal = uint.max;
        order = null;
        foreach (ref g; groupLog(*log, grouping, context))
        {
            uint[] lines;
            if (grouping != Grouping.time)
                lines ~= b.add(Widget(kind: WidgetKind.row, gap: 1, width: SizeSpec.grow(),
                    children: [label(b, g.title, Slot.textPrimary, bold: true),
                        b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow())),
                        label(b, countText(g.entries.length), Slot.muted)]));
            foreach (i; g.entries)
            {
                const isSelected = keyboard && order.length == selected;
                const node = entry(b, i, isSelected, ctx.targetRows);
                if (isSelected)
                    reveal = node;
                order ~= i;
                lines ~= node;
            }
            cards ~= b.add(Widget(kind: WidgetKind.panel, children: [column(b, lines, 1)],
                width: SizeSpec.grow(), padding: Insets(0, 1, 0, 1), slot: Slot.surfaceRaised,
                paintBackground: true, decoration: Decoration(borderRadius: 10)));
        }
        if (!cards.length)
            cards ~= prose(b, "No notifications yet. A program raises one with OSC 9, 99 or 777 "
                ~ "— a build finishing, an agent waiting.", Slot.muted);
        if (selected >= order.length)
            selected = order.length ? order.length - 1 : 0;

        const content = b.add(Widget(kind: WidgetKind.column, children: cards, gap: 1,
            width: SizeSpec.grow(), padding: Insets(1, 0, 1, 0)));
        viewRows = bodyRowsFor(b, top, null, cols, rows);
        return finishPage(b, top, content, null, viewRows, scroll, cols, rows, reveal);
    }

    private static string countText(size_t n) @safe
    {
        import std.conv : text;

        return text(n);
    }

    /// The rules in effect, first match first (N2's band under the chips).
    private uint rulesBand(ref Builder b) @safe
    {
        uint[] lines = [label(b, "Rules, first match wins · notifications.groups in the config",
            Slot.muted)];
        foreach (ref r; context.rules)
        {
            string s;
            if (r.app.length)
                s ~= "app " ~ r.app ~ " ";
            if (r.cwd.length)
                s ~= "cwd " ~ r.cwd ~ " ";
            if (r.tab.length)
                s ~= "tab " ~ r.tab ~ " ";
            lines ~= label(b, s ~ "→ " ~ (r.group.length ? r.group : "Other"), Slot.code);
        }
        if (!context.rules.length)
            lines ~= label(b, "No rules yet: every entry is in Other.", Slot.textSecondary);
        return b.add(Widget(kind: WidgetKind.panel, children: [column(b, lines)],
            width: SizeSpec.grow(), padding: Insets(0, 1, 0, 1), slot: Slot.surfaceSunken,
            paintBackground: true));
    }

    /// One entry: the unseen dot, the title and its age, the body, and where
    /// it came from — a target unless its pane has closed (`TPG10`).
    private uint entry(ref Builder b, size_t i, bool isSelected, int targetRows) @safe
    {
        import std.algorithm.searching : canFind;

        const r = (*log)[i];
        const fresh = unseen(i);
        const open = r.source != 0 && services.paneOpen !is null && paneOpen(r.source);

        auto head = new TextSpan[0];
        head ~= TextSpan(text: isSelected ? "▶ " : fresh ? "● " : "  ",
            slot: fresh || isSelected ? Slot.accentPrimary : Slot.muted);
        head ~= TextSpan(text: r.title.length ? r.title : "Notification",
            slot: Slot.textPrimary, textStyle: TextStyle(bold: fresh));
        head ~= TextSpan(text: " · " ~ agoText(r.time, now), slot: Slot.muted);
        uint[] lines = [b.add(Widget(kind: WidgetKind.rich, spans: head))];
        if (r.body.length)
            lines ~= prose(b, "  " ~ r.body, Slot.textPrimary);

        string meta = "  ";
        if (r.tabTitle.length)
            meta ~= "tab \"" ~ r.tabTitle ~ "\" · ";
        if (r.paneTitle.length && r.paneTitle != r.tabTitle)
            meta ~= r.paneTitle ~ " · ";
        meta ~= (r.process.length ? r.process : "unknown app") ~ " · "
            ~ (r.cwd.length ? tildeOf(r.cwd, context.home) : "unknown directory");
        final switch (r.route)
        {
            case NotificationRoute.system: meta ~= " · notified"; break;
            case NotificationRoute.toast: meta ~= " · toast"; break;
            case NotificationRoute.none: break;
        }
        if (!open)
            meta ~= " · pane closed";
        lines ~= prose(b, meta, Slot.muted);

        return b.add(Widget(
            kind: WidgetKind.column,
            children: lines,
            width: SizeSpec.grow(),
            height: targetRows > 1 ? SizeSpec(SizeSpec.Kind.fit, 0, targetRows) : SizeSpec.fit_,
            hitId: open ? Hit.entry + i : 0,
            slot: isSelected ? Slot.chromeAccent : Slot.inherit,
            paintBackground: isSelected,
        ));
    }

    private bool paneOpen(ulong id) @trusted => services.paneOpen(id);

    override bool onHit(size_t id) @system
    {
        if (id == Hit.markRead)
        {
            seenBefore = log.total;
            log.markAllSeen();
            return false;
        }
        if (id >= Hit.grouping && id < Hit.grouping + 6)
        {
            setGrouping(cast(Grouping)(id - Hit.grouping));
            return false;
        }
        if (id >= Hit.entry && id < Hit.entry + log.length)
            return openEntry(id - Hit.entry);
        return false;
    }

    /// Focuses entry `i`'s pane: true (the page closes) when it is open.
    private bool openEntry(size_t i) @system
    {
        const r = (*log)[i];
        if (r.source != 0 && services.focusPane !is null && services.focusPane(r.source))
            return true;
        if (services.toast !is null)
            services.toast("That pane has closed");
        return false;
    }

    override bool confirm() @system
        => order.length && selected < order.length && openEntry(order[selected]);

    override void scrolled(int delta) @safe
    {
        // The keyboard moves the selection; the view follows it. The first
        // key only shows where the selection is.
        if (!keyboard)
        {
            keyboard = true;
            return;
        }
        long s = cast(long) selected + delta;
        if (s < 0)
            s = 0;
        if (order.length && s >= order.length)
            s = order.length - 1;
        selected = cast(size_t) s;
    }

    override bool onKey(in KeyEvent k) @system
    {
        if (k.key != Key.char_)
            return false;
        switch (k.ch)
        {
            case 'g':
                setGrouping(cast(Grouping)((grouping + 1) % 6));
                return true;
            case 'G':
                setGrouping(cast(Grouping)((grouping + 5) % 6));
                return true;
            case 'r':
                return !onHit(Hit.markRead);
            default:
                return false;
        }
    }

    private void setGrouping(Grouping g) @safe
    {
        grouping = g;
        selected = 0;
        scroll = 0;
        saveGrouping(statePath, g);
    }
}

/// The persisted grouping; the default (tab) when none was saved.
Grouping loadGrouping(string path) @safe
{
    import std.file : exists;

    import sparkles.wired.json : readJSONFile;

    try
    {
        if (!path.length || !path.exists)
            return PagesState.init.notificationGrouping;
        auto r = readJSONFile!PagesState(path);
        return r.hasError ? PagesState.init.notificationGrouping : r.value.notificationGrouping;
    }
    catch (Exception)
        return PagesState.init.notificationGrouping;
}

/// Saves the grouping; a failure is logged, never fatal.
void saveGrouping(string path, Grouping g) @safe
{
    import std.file : mkdirRecurse;
    import std.path : dirName;

    import sparkles.base.logger : warning;
    import sparkles.wired.json : writeJSONFile;

    if (!path.length)
        return;
    try
        mkdirRecurse(path.dirName);
    catch (Exception e)
    {
        warning(i"pages: cannot create $(path.dirName): $(e.msg)");
        return;
    }
    auto r = writeJSONFile(PagesState(g), path);
    if (r.hasError)
        warning(i"pages: grouping not saved: $(r.error.toString)");
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private NotificationRecord rec(string title, string tab, string process, string cwd,
        ulong source, int minutesAgo = 0) @safe
    {
        import core.time : minutes;
        import std.datetime.systime : SysTime;
        import std.datetime.date : DateTime;

        return NotificationRecord(
            time: SysTime(DateTime(2026, 10, 2, 12, 0, 0)) - minutesAgo.minutes,
            tabTitle: tab, process: process, cwd: cwd, title: title, source: source);
    }

    private GroupContext testContext() @safe
    {
        GroupContext c;
        c.home = "/home/u";
        c.rules = [
            NotificationGroupRule(app: "claude|codex|aider", group: "Agents"),
            NotificationGroupRule(cwd: "~/code/repos/mine/*", group: "My projects"),
            NotificationGroupRule(tab: "build*", group: "CI"),
        ];
        c.projectOf = (string d) @safe => d == "/home/u/code/repos/mine/sparkles/apps"
            ? "/home/u/code/repos/mine/sparkles" : d;
        return c;
    }
}

@("notification_page.groupOf.everyGrouping")
@safe unittest
{
    const c = testContext();
    const claude = rec("Claude is waiting", "sparkles", "claude",
        "/home/u/code/repos/mine/sparkles/apps", 2);
    const build = rec("Build finished", "build", "nix", "/tmp", 1);
    const unknown = rec("?", "", "", "", 3);

    assert(groupOf(claude, Grouping.time, c) == "");
    assert(groupOf(claude, Grouping.tab, c) == `tab "sparkles"`);
    assert(groupOf(claude, Grouping.app, c) == "claude");
    assert(groupOf(claude, Grouping.agent, c) == "claude");
    assert(groupOf(build, Grouping.agent, c) == "Not an agent");
    assert(groupOf(claude, Grouping.project, c) == "~/code/repos/mine/sparkles", "the git root");
    // Rules: first match wins; unmatched is Other.
    assert(groupOf(claude, Grouping.rules, c) == "Agents");
    assert(groupOf(build, Grouping.rules, c) == "CI");
    assert(groupOf(rec("x", "t", "zsh", "/home/u/code/repos/mine/x", 4), Grouping.rules, c)
        == "My projects");
    assert(groupOf(rec("x", "t", "zsh", "/srv", 5), Grouping.rules, c) == "Other");
    // Unknown app or directory: Unknown.
    foreach (g; [Grouping.tab, Grouping.app, Grouping.agent, Grouping.project])
        assert(groupOf(unknown, g, c) == "Unknown");
    // A configured agent.
    GroupContext extra = testContext();
    extra.agents = ["myagent"];
    assert(groupOf(rec("x", "t", "myagent", "/", 6), Grouping.agent, extra) == "myagent");
}

@("notification_page.groupLog.newestFirst")
@safe unittest
{
    NotificationLog log;
    log.record(rec("a", "one", "zsh", "/", 1, 30));
    log.record(rec("b", "two", "zsh", "/", 2, 20));
    log.record(rec("c", "one", "zsh", "/", 1, 10));
    const g = groupLog(log, Grouping.tab, testContext());
    assert(g.length == 2);
    assert(g[0].title == `tab "one"` && g[0].entries == [2, 0]);
    assert(g[1].title == `tab "two"` && g[1].entries == [1]);
    assert(groupLog(log, Grouping.time, testContext())[0].entries == [2, 1, 0]);
}

@("notification_page.agoText")
@safe unittest
{
    import core.time : hours, minutes, seconds;
    import std.datetime.date : DateTime;

    const now = SysTime(DateTime(2026, 10, 2, 12, 0, 0));
    assert(agoText(now - 5.seconds, now) == "now");
    assert(agoText(now - 6.minutes, now) == "6 min");
    assert(agoText(now - 3.hours, now) == "3 h");
    assert(agoText(now - 50.hours, now) == "2 d");
}

@("notification_page.NotificationPage.activateFocusesOrSaysClosed")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.datetime.date : DateTime;

    import chrome : place, Place;

    auto log = new NotificationLog;
    log.record(rec("Build finished", "build", "nix", "/tmp", 1, 2));
    log.record(rec("Tests failed", "gone", "dub", "/tmp", 7, 1));
    ulong focused;
    string toast;
    PageServices s;
    s.paneOpen = (ulong id) => id == 1;
    s.focusPane = (ulong id) { focused = id; return id == 1; };
    s.toast = (string t) { toast = t; };
    assert(log.unseen == 2);
    auto p = new NotificationPage(log, NotificationsConfig.init, null, s);
    p.pinNow(SysTime(DateTime(2026, 10, 2, 12, 0, 0)));
    assert(log.unseen == 0, "opening the page marks the log seen (TPG11)");

    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.area = Rect(0, 0, 70, 40);
    const l = place(p.build(ctx, 70), 70, 40, 0, 0, 1, 1, Place.top);
    bool closedSaid, dots;
    size_t targets;
    foreach (ref n; l.tree.nodes)
    {
        closedSaid |= n.text.canFind("pane closed");
        foreach (ref sp; n.spans)
            dots |= sp.text == "● ";
    }
    foreach (ref t; l.hits)
        targets += t.hitId >= Hit.entry;
    assert(closedSaid && dots, "the closed pane is said; unseen entries keep their dot");
    assert(targets == 1, "a closed pane's entry is inert");

    // The open pane's entry focuses it and closes the page.
    assert(p.activate(Hit.entry + 0) && focused == 1);
    // The keyboard: the newest (the closed one) is first; Enter says so.
    p.scrolled(0);
    assert(!p.confirm() && toast == "That pane has closed");
    // Mark all read clears the dots.
    cast(void) p.activate(Hit.markRead);
    const after = place(p.build(ctx, 70), 70, 40, 0, 0, 1, 1, Place.top);
    foreach (ref n; after.tree.nodes)
        foreach (ref sp; n.spans)
            assert(sp.text != "● ");
}

@("notification_page.grouping.persists")
@system unittest
{
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;

    const path = buildPath(tempDir, "notification_page-test", "pages.json");
    scope (exit)
        if (path.exists)
            remove(path);
    assert(loadGrouping(path) == Grouping.tab, "the default");
    auto log = new NotificationLog;
    auto p = new NotificationPage(log, NotificationsConfig.init, path, PageServices.init);
    assert(p.key(KeyEvent(Key.char_, 'g')));
    assert(loadGrouping(path) == Grouping.app);
    auto again = new NotificationPage(log, NotificationsConfig.init, path, PageServices.init);
    assert(again.grouping == Grouping.app);
}

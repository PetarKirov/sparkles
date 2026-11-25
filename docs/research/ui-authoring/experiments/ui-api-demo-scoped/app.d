/// The explorer's Stats pane, built top-down (Clay-style scoped construction).
module app;

import std.sumtype : SumType, match;

import ui_sketch;

// ── the app's model and messages ───────────────────────────────────────────

struct MemberRow { string name; string value; }
struct Stats { bool hashOnEdit; int debounceMs; }
struct IdsView { bool computing; string query; const(MemberRow)[] rows; }
struct Model { Stats stats; IdsView ids; bool tutorial; }

/// The Stats pane's own messages: it knows nothing of the explorer's.
struct ToggleHash {}
struct SetDebounce { int ms; }
struct CopyName { string name; }
alias StatsMsg = SumType!(ToggleHash, SetDebounce, CopyName);

/// The explorer's messages; the Stats pane's arrive wrapped.
struct Quit {}
alias ExplorerMsg = SumType!(StatsMsg, Quit);

alias liftStats = (StatsMsg sm) => ExplorerMsg(sm);

// ── a composite: statements, not an expression ─────────────────────────────

/// `Ui!StatsMsg`: this pane can only send `StatsMsg`, checked at compile time.
void statsPane(ref Ui!StatsMsg ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
{
    with (ui.column(gap: ui.env.density == Density.compact ? 0 : 1))
    {
        with (ui.row(gap: 2))
        {
            ui.label(slot: Slot.heading, text: "Stats");
            ui.toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash())));
            ui.numberField(value: s.debounceMs, unit: "ms",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v))));
        }
        if (ids.computing)
            ui.label(slot: Slot.dim, text: ui.text(i"computing… (query $(ids.query))"));
        foreach (r; ids.rows)
            ui.keyValue(key: r.name, name: r.name, value: r.value,
                onPress: ui.on(StatsMsg(CopyName(r.name))));
        // Structure chosen from context: only the comfortable layout shows a hint.
        if (ui.env.density == Density.comfortable)
            ui.label(slot: Slot.dim, text: "click a name to copy it");
    }
}

/// Its value form, `statsPane(s, ids)`: a `Part` to hold and `ui.place` later.
mixin(componentForm!"statsPane");

// ── the root composite ─────────────────────────────────────────────────────

void explorerView(ref Ui!ExplorerMsg ui, in Model m) @safe pure nothrow @nogc
{
    with (ui.column())
    {
        ui.label(slot: Slot.heading, text: ui.text(i"members: $(m.ids.rows.length)"));

        // Was "deferred": the column opens (and pushes compact, disabled)
        // before the pane is built, so a plain call sees both.
        with (ui.column(env: ui.env.withDensity(Density.compact), disabled: m.tutorial))
        with (auto stats = ui.mapMsg!liftStats)
            statsPane(stats, m.stats, m.ids);

        // Was "eager": the same call, under the caller's env (comfortable).
        version (BadMissingMapMsg)
            statsPane(ui, m.stats, m.ids); // compile error: `Ui!ExplorerMsg` is not `Ui!StatsMsg`
        else
            with (auto stats = ui.mapMsg!liftStats)
                statsPane(stats, m.stats, m.ids);

        // Was "memo": a memo element keyed by the arguments and the env.
        with (auto stats = ui.mapMsg!liftStats)
            stats.memo!statsPane(m.stats, m.ids);

        version (BadOnDirect)
            ui.toggle(label: "x", onPress: ui.on(StatsMsg(ToggleHash()))); // compile error, with the static assert's text

        version (BadOuterHandle)
            with (auto stats = ui.mapMsg!liftStats)
                ui.toggle(label: "quit", onPress: ui.on(ExplorerMsg(Quit()))); // the outer `ui`
    }
}

// ── subtrees as values ─────────────────────────────────────────────────────

/**
(a)+(b)+(c) in one slot: `content` is anything `ui.place` accepts — a value
form, a callable `(ref Ui!M)`, or a recorded `Subtree!M`. `card` is generic
over the message type, so it works under any `mapMsg`.
*/
void card(M, C)(ref Ui!M ui, string title, auto ref C content,
    string file = __FILE__, size_t line = __LINE__)
{
    // The card's own column takes the *card's* call site, so two cards under
    // one parent are two identities, not one site repeated.
    with (ui.column(gap: 0, file: file, line: line))
    {
        ui.label(slot: Slot.heading, text: title);
        ui.place(content);
    }
}

/// (a) as a template alias slot: the lambda's parameter types are inferred.
void cardOf(alias content, M)(ref Ui!M ui, string title,
    string file = __FILE__, size_t line = __LINE__)
{
    with (ui.column(gap: 0, file: file, line: line))
    {
        ui.label(slot: Slot.heading, text: title);
        content(ui);
    }
}

/// A list whose rows a caller-supplied function builds. The list keys each
/// row from `key`, so the caller's row function never has to.
void keyedList(alias key, alias row, M, R)(ref Ui!M ui, R items)
{
    with (ui.column())
        foreach (ref e; items)
            with (ui.row(key: key(e)))
                row(ui, e);
}

void subtrees(ref Ui!StatsMsg ui, in IdsView ids, bool wide) @safe pure nothrow @nogc
{
    // (a) a delegate slot: typed parameter, `scope`, so no closure (`@nogc`).
    card(ui, title: "(a) delegate", content: (ref Ui!StatsMsg u) {
        u.label(text: ids.query);
    });
    // (a') an alias slot: `(ref u)` infers.
    cardOf!((ref u) { u.label(text: ids.query); })(ui, title: "(a') alias");

    // A subtree stored in a variable, placed in one of two places.
    scope rows = (ref Ui!StatsMsg u) {
        foreach (r; ids.rows)
            u.keyValue(key: r.name, name: r.name, value: r.value,
                onPress: u.on(StatsMsg(CopyName(r.name))));
    };
    // (b) a value form held in a variable.
    const pane = statsPane(Stats(false, 10), ids);
    // (c) a subtree recorded now, attached below.
    auto recorded = ui.record!((ref u) { u.label(text: "recorded"); });

    with (ui.row(gap: 3))
    {
        with (ui.column(key: "left"))
            if (wide)
            {
                ui.place(rows);
                ui.place(recorded);
            }
        with (ui.column(key: "right"))
            if (!wide)
            {
                ui.place(rows);
                ui.place(recorded);
            }
    }
    card(ui, title: "(b) value form", content: pane);
    keyedList!(r => r.name, (ref u, in r) => u.label(text: r.value))(ui, ids.rows);
}

/// What a debug build reports: a `foreach` repeating one call site under one
/// parent with no key; a recorded subtree attached twice, under another env,
/// or never.
void identityMistakes(ref Ui!StatsMsg ui, in IdsView ids) @safe pure nothrow @nogc
{
    with (ui.column())
        foreach (r; ids.rows)
            ui.label(text: r.name); // no `key:` — identity falls back to occurrence
    auto t = ui.record!((ref u) => u.label(text: "once"));
    ui.attach(t);
    ui.attach(t);
    // Recorded under comfortable, attached under compact: built too early.
    auto early = ui.record!((ref u) => u.label(text: "early"));
    with (ui.column(env: ui.env.withDensity(Density.compact)))
        ui.attach(early);
    // Recorded and dropped.
    auto lost = ui.record!((ref u) => u.label(text: "lost"));
}

// ── what the API rejects ───────────────────────────────────────────────────

int impureCounter;
void impurePane(ref Ui!StatsMsg ui) { ui.label(text: impureCounter++ ? "a" : "b"); }

void rejected(ref Ui!ExplorerMsg ui, ref Ui!StatsMsg sui, in IdsView ids) @safe pure nothrow @nogc
{
    // Attributes are named-only: the first parameter is a private sentinel.
    static assert(!__traits(compiles, ui.label(Slot.dim, "x")));
    // An IES expands to several arguments, so it cannot be one named argument.
    static assert(!__traits(compiles, ui.label(text: i"q $(ids.query)")));
    // A payload lambda may not capture: nothing outlives the frame.
    int local = 3;
    static assert(!__traits(compiles, sui.on!((int v) => StatsMsg(SetDebounce(v + local)))));

    // The message check is compile time: a `StatsMsg` where `ExplorerMsg` is sent…
    static assert(!__traits(compiles, ui.on(StatsMsg(ToggleHash()))));
    static assert(!__traits(compiles, ui.on!((int v) => StatsMsg(SetDebounce(v)))));
    // …a pane that sends `StatsMsg` called without the `mapMsg` that lifts it…
    static assert(!__traits(compiles, statsPane(ui, Stats.init, ids)));
    // …a `mapMsg` that lifts into the wrong type…
    static assert(!__traits(compiles, sui.mapMsg!liftStats));
    // …and a subtree recorded under one message type, attached under another.
    static assert(!__traits(compiles, (ref Subtree!StatsMsg t) => ui.attach(t)));

    // A handle may not be dropped: `ui.column();` alone would open and close
    // an empty column on the spot (`@mustuse`).
    static assert(!__traits(compiles, { ui.column(); }));
    static assert(!__traits(compiles, { ui.mapMsg!liftStats; }));
    // Handles are not copyable: an element closes exactly once.
    static assert(!__traits(compiles, { auto a = ui.column(); auto b = a; }));
    // Only subtrees can be placed, and a memoised composite must be pure.
    static assert(!__traits(compiles, ui.place(42)));
    static assert(!__traits(compiles, sui.memo!impurePane()));
    // The value form is not callable with a `Ui` by mistake; that is the eager call.
    static assert(is(typeof(statsPane(sui, Stats.init, ids)) == void));
    static assert(!is(typeof(statsPane(Stats.init, ids)) == void));
    // An untyped `(ref u)` lambda cannot go to a runtime (delegate) slot: there is
    // no type to infer it against. It needs the alias form, or a typed parameter.
    static assert(!__traits(compiles, card(sui, title: "x", content: (ref u) {})));
}

// ── run frames, then deliver three events ──────────────────────────────────

void main() @system
{
    import std.stdio : writefln, writeln;
    import std.range : repeat;
    import std.array : join;

    static immutable MemberRow[2] rows = [MemberRow("NarHash", "sha256-q2v…"), MemberRow("castore", "b3:9f1…")];
    const m = Model(Stats(true, 300), IdsView(true, "ab", rows[]), tutorial: true);

    void line(uint depth, string s) @safe { writeln("  ".repeat(depth).join, s); }
    void diag(string s) @safe { writeln("  ! ", s); }

    Ui!ExplorerMsg ui; // on the stack, typed by the app's message
    with (ui.frame(Env(Layout.wide, Density.comfortable)))
        explorerView(ui, m);

    writeln("── tree ──");
    ui.dump(&line);
    writeln("── diagnostics ──");
    ui.diagnostics(&diag);
    writeln("messages type-check: at compile time (every `ui.on` is checked against its `Ui!Msg`)");

    writeln("── events ──");
    void deliver(ExplorerMsg e) @safe
    {
        e.match!(
            (StatsMsg sm) => sm.match!(
                (ToggleHash _) => writeln("update: stats ▸ toggle hash-on-edit"),
                (SetDebounce d) => writefln("update: stats ▸ debounce = %s ms", d.ms),
                (CopyName c) => writefln("update: stats ▸ copy %s", c.name),
            ),
            (Quit _) => writeln("update: quit"),
        );
    }
    // The first toggle is the compact (formerly deferred) pane's.
    ui.dispatch(ui.find("toggle", "hash on edit"), &deliver);
    ui.dispatch(ui.find("numberField", "ms"), &deliver, payload: 500);
    ui.dispatch(ui.find("keyValue", "castore"), &deliver);

    foreach (wide; [true, false])
    {
        Ui!StatsMsg sub;
        with (sub.frame(Env(Layout.wide, Density.comfortable)))
            subtrees(sub, m.ids, wide);
        writefln("── subtrees as values (wide = %s) ──", wide);
        sub.dump(&line);
        sub.diagnostics(&diag);
        writefln("  ids: rows' castore #%s, recorded #%s",
            sub.shortId(sub.find("keyValue", "castore")), sub.shortId(sub.find("label", "recorded")));
    }

    {
        Ui!StatsMsg bad;
        with (bad.frame(Env.init))
            identityMistakes(bad, m.ids);
        writeln("── identity mistakes ──");
        bad.dump(&line);
        bad.diagnostics(&diag);
    }
}

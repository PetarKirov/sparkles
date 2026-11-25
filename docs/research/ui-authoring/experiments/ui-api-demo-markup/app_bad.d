/// The explorer's Stats pane, written in the `markup` DSL over a top-down builder.
module app_bad;

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

// ── the Stats pane ─────────────────────────────────────────────────────────

@emits!StatsMsg
void statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column(gap: ui.env.density == Density.compact ? 0 : 1) {
            row(gap: 2) {
                label(slot: Slot.heading, text: "Stats");
                toggle(on: s.hashOnEdit, label: "hash on edit",
                    onPress: ui.on(StatsMsg(ToggleHash())));
                numberField(value: s.debounceMs, unit: "ms",
                    onChange: ui.on!((int v) => StatsMsg(SetDebounce(v))));
            }
            if (ids.computing) {
                label(slot: Slot.dim, text: i"computing… (query $(ids.query))");
            }
            foreach (r; ids.rows; key: r.name) {
                keyValue(name: r.name, value: r.value,
                    onPress: ui.on(StatsMsg(CopyName(r.name))));
            }
            // Structure chosen from context: only the comfortable layout shows a hint.
            if (ui.env.density == Density.comfortable) {
                label(slot: Slot.dim, text: "click a name to copy it");
            }
        }
    });
}

// ── composites that take subtrees as values ───────────────────────────────

/// A titled box around a caller-supplied body. It sends nothing itself (no
/// `@emits`), so the body keeps the message type of the place it was written.
void card(F)(ref Ui ui, string title, scope F body) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column(gap: 0) {
            label(slot: Slot.heading, text: i"┌ $(title)");
            embed(body);
        }
    });
}

/// A keyed list whose rows the caller builds: `row` is a fragment taking a row.
void memberList(F)(ref Ui ui, in MemberRow[] rows, scope F row) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column {
            foreach (r; rows; key: r.name) { embed(row, r); }
        }
    });
}

/// Trailing children become a `children:` fragment, as in JSX.
void indent(F)(ref Ui ui, scope F children) @safe pure nothrow @nogc
{
    mixin(markup!q{
        row(gap: 2) { label(text: "│"); embed(children); }
    });
}

@emits!ExplorerMsg
void valueDemos(ref Ui ui, in Model m) @safe pure nothrow @nogc
{
    // A subtree as a value, outside markup: a `scope` delegate (no closure is
    // allocated), tagged with this component's message type.
    scope status = mixin(fragment!q{
        label(slot: Slot.dim, text: i"query: $(m.ids.query)");
    });

    mixin(markup!q{
        column(gap: 1) {
            // … and inside markup.
            auto quit = { keyValue(name: "quit", value: "q", onPress: ui.on(ExplorerMsg(Quit()))); };

            // A composite receiving a body.
            card(title: "Query", body: { embed(status); embed(quit); });

            // The same value placed in one of two places, by a condition.
            if (m.ids.computing) {
                row(gap: 1) { label(text: "busy:"); embed(status); }
            } else {
                embed(status);
            }

            // Rows produced by a caller-supplied fragment, under the pane's messages.
            mapMsg((StatsMsg sm) => ExplorerMsg(sm)) {
                memberList(rows: m.ids.rows, row: (in MemberRow r) {
                    keyValue(name: r.name, value: "copy", onPress: ui.on(StatsMsg(CopyName(r.name))));
                });
            }

            indent {
                label(text: "nested children");
            }
        }
    });
}

// ── the root composite ─────────────────────────────────────────────────────

@emits!ExplorerMsg
void explorerView(ref Ui ui, in Model m) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column {
            label(slot: Slot.heading, text: i"members: $(m.ids.rows.length)");

            // The override applies at open: the pane below is built compact.
            column(env: ui.env.withDensity(Density.compact), disabled: m.tutorial) {
                mapMsg((StatsMsg sm) => ExplorerMsg(sm)) {
                    statsPane(s: m.stats, ids: m.ids);
                }
            }

            // Built under the caller's env (comfortable) -- and missing its mapMsg.
            statsPane(s: m.stats, ids: m.ids);

            // The seam a memo site would fill: today it only builds.
            mapMsg((StatsMsg sm) => ExplorerMsg(sm)) {
                memo(deps: m.stats) { statsPane(s: m.stats, ids: m.ids); }
            }

            valueDemos(m: m);
        }
    });
}

// ── what the API rejects ───────────────────────────────────────────────────

/// A markup body to test: compiles only if `src` is accepted. (A `{ … }`
/// lambda inside `__traits(compiles)` cannot capture `in` parameters in a
/// `@nogc` function, so each case is a template instance instead.)
@emits!ExplorerMsg
void probe(string src)(ref Ui ui, in IdsView ids, in Stats s, int local)
{
    mixin(markup!src);
}

void rejected(ref Ui ui, in IdsView ids, in Stats s) @safe pure nothrow @nogc
{
    enum accepts(string src) = __traits(compiles, probe!src(ui, ids, s, 3));

    // The control: the shapes below, written correctly, compile.
    static assert(accepts!q{
        foreach (r; ids.rows; key: r.name) { label(text: r.name); }
        mapMsg((StatsMsg sm) => ExplorerMsg(sm)) {
            statsPane(s: s, ids: ids);
            toggle(on: true, onPress: ui.on(StatsMsg(ToggleHash())));
            numberField(onChange: ui.on!((int v) => StatsMsg(SetDebounce(v))));
        }
        auto f = { toggle(onPress: ui.on(ExplorerMsg(Quit()))); };
        embed(f);
        label(text: i"q $(ids.query)");
    });
    // A `foreach` without a key is a markup error.
    static assert(!accepts!q{ foreach (r; ids.rows) { label(text: r.name); } });
    // A Stats message where the explorer's is expected (no mapMsg).
    static assert(!accepts!q{ toggle(on: true, onPress: ui.on(StatsMsg(ToggleHash()))); });
    // A component sending StatsMsg placed without mapMsg.
    static assert(!accepts!q{ statsPane(s: s, ids: ids); });
    // A mapMsg that lifts to the wrong type.
    static assert(!accepts!q{ mapMsg((ToggleHash t) => StatsMsg(t)) { label(text: "x"); } });
    // Attributes are named-only.
    static assert(!accepts!q{ label(Slot.dim, "x"); });
    // A leaf has no children.
    static assert(!accepts!q{ label(text: "x") { label(text: "y"); } });
    // A payload lambda may not capture: nothing outlives the frame.
    static assert(!accepts!q{
        mapMsg((StatsMsg sm) => ExplorerMsg(sm)) {
            numberField(onChange: ui.on!((int v) => StatsMsg(SetDebounce(v + local))));
        }
    });
    // A fragment written under StatsMsg cannot be placed where ExplorerMsg is expected.
    static assert(!accepts!q{
        auto f = { toggle(onPress: ui.on(StatsMsg(ToggleHash()))); };
        mapMsg((StatsMsg sm) => ExplorerMsg(sm)) { embed(f); }
    });
    static assert(!accepts!q{
        mapMsg((StatsMsg sm) => ExplorerMsg(sm)) {
            memberList(rows: ids.rows, row: (in MemberRow r) { label(text: r.name); });
        }
        auto g = { label(text: "x"); };
        mapMsg((StatsMsg sm) => ExplorerMsg(sm)) { card(title: "t", body: g); }
    });
    // Outside markup, `ui.on` has no scope to check against, so it does not compile.
    static assert(!__traits(compiles, ui.on(StatsMsg(ToggleHash()))));
    // A positional attribute after the site is refused by the sentinel.
    static assert(!__traits(compiles, ui.label(Site(1), Slot.dim)));
}

// ── run one frame, then deliver three events ───────────────────────────────

void main() @system
{
    import std.stdio : writefln, writeln;
    import std.range : repeat;
    import std.array : join;

    static immutable MemberRow[2] rows = [MemberRow("NarHash", "sha256-q2v…"), MemberRow("castore", "b3:9f1…")];
    const m = Model(Stats(true, 300), IdsView(true, "ab", rows[]), tutorial: true);

    Ui ui; // on the stack: its arenas are a few tens of KiB
    const root = ui.frame!(ExplorerMsg, explorerView)(Env(Layout.wide, Density.comfortable), m);

    writeln("── tree ──");
    ui.dump(root, (uint depth, string line) @safe {
        writeln("  ".repeat(depth).join, line);
    });
    writefln("messages type-check: compile time (runtime walk agrees: %s)", ui.messagesTypeCheck(root));
    writefln("ids unique: %s", ui.idsUnique);

    // Identity is the call site: hiding the `computing…` label (an `if`) does
    // not shift its siblings' ids.
    Ui ui2;
    const m2 = Model(Stats(true, 300), IdsView(false, "ab", rows[]), tutorial: true);
    ui2.frame!(ExplorerMsg, explorerView)(Env(Layout.wide, Density.comfortable), m2);
    writefln("ids stable under if: %s", ui.idOf(ui.find("keyValue", "castore"))
        == ui2.idOf(ui2.find("keyValue", "castore")));

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
    // The first toggle is the compact pane's; the next one the comfortable pane's.
    ui.dispatch!ExplorerMsg(ui.find("toggle", "hash on edit"), &deliver);
    ui.dispatch!ExplorerMsg(ui.find("numberField", "ms"), &deliver, payload: 500);
    ui.dispatch!ExplorerMsg(ui.find("keyValue", "castore"), &deliver);
    ui.dispatch!ExplorerMsg(ui.find("keyValue", "quit"), &deliver);
}

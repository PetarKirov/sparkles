/// The explorer's Stats pane, written against the sketch (UI-Q1–Q6).
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

// ── a composite: eager form, then its value form ───────────────────────────

Node statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
    => ui.Column(gap: ui.env.density == Density.compact ? 0 : 1, children: [
        ui.Row(gap: 2, children: [
            ui.Label(slot: Slot.heading, text: "Stats"),
            ui.Toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash()))),
            ui.NumberField(value: s.debounceMs, unit: "ms",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v)))),
        ]),
        ids.computing
            ? ui.Label(slot: Slot.dim, text: ui.text(i"computing… (query $(ids.query))"))
            : Node.none,
        ids.rows
            .toUi(ui)
            .mapKeyed!(
                r => r.name,
                r => ui.KeyValue(name: r.name, value: r.value,
                    onPress: ui.on(StatsMsg(CopyName(r.name)))),
            ),
        // Structure chosen from context: only the comfortable layout shows a hint.
        ui.env.density == Density.comfortable
            ? ui.Label(slot: Slot.dim, text: "click a name to copy it")
            : Node.none,
    ]);

mixin(componentForm!"statsPane");

// ── the root composite ─────────────────────────────────────────────────────

Node explorerView(ref Ui ui, in Model m) @safe pure nothrow @nogc
    => ui.Column(children: [
        ui.Label(slot: Slot.heading, text: ui.text(i"members: $(m.ids.rows.length)")),

        // Deferred: built after this Column exists, so it sees the override
        // (compact) and inherits `disabled` at layout time.
        ui.Column(env: ui.env.withDensity(Density.compact), disabled: m.tutorial, children: [
            ui.mapMsg!((StatsMsg sm) => ExplorerMsg(sm))(
                ui.place(statsPane(m.stats, m.ids))),
        ]),

        // Eager: built right here, under the caller's env (comfortable).
        ui.mapMsg!((StatsMsg sm) => ExplorerMsg(sm))(
            statsPane(ui, m.stats, m.ids)),

        // The seam a memo site would fill (UI-Q3): today it only builds.
        ui.mapMsg!((StatsMsg sm) => ExplorerMsg(sm))(
            ui.place(memo(statsPane(m.stats, m.ids)))),
    ]);

mixin(componentForm!"explorerView");

// ── what the API rejects ───────────────────────────────────────────────────

int impureCounter;
Node impurePane(ref Ui ui) => ui.Label(text: impureCounter++ ? "a" : "b");
mixin(componentForm!"impurePane");

void rejected(ref Ui ui, in IdsView ids) @safe pure nothrow @nogc
{
    import std.algorithm : map;

    // Attributes are named-only: the first parameter is a private sentinel.
    static assert(!__traits(compiles, ui.Label(Slot.dim, "x")));
    // An IES expands to several arguments, so it cannot be one named argument.
    static assert(!__traits(compiles, ui.Label(text: i"q $(ids.query)")));
    // A bare range is not a child: lists go through `mapKeyed`/`mapByIndex`.
    static assert(!__traits(compiles, ui.Column(children: [ids.rows])));
    static assert(!__traits(compiles, ids.rows.toUi(ui).map!(r => ui.Label(text: r.name))));
    // A payload lambda may not capture: nothing outlives the frame.
    int local = 3;
    static assert(!__traits(compiles, ui.on!((int v) => StatsMsg(SetDebounce(v + local)))));
    // Only value forms can be placed, and a composite must be pure.
    static assert(!__traits(compiles, ui.place(42)));
    static assert(!__traits(compiles, ui.place(impurePane())));
    // The value form is not callable with a `Ui` by mistake; that is the eager form.
    static assert(is(typeof(statsPane(ui, Stats.init, ids)) == Node));
    static assert(!is(typeof(statsPane(Stats.init, ids)) == Node));
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
    ui.expectMsg!ExplorerMsg;
    const root = ui.frame(explorerView(m), Env(Layout.wide, Density.comfortable));

    writeln("── tree ──");
    ui.dump(root, (uint depth, string line) @safe {
        writeln("  ".repeat(depth).join, line);
    });
    writefln("messages type-check: %s", ui.messagesTypeCheck(root));

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
    // The first toggle is the deferred pane's; the next one the eager pane's.
    const toggle = ui.find("toggle", "hash on edit");
    ui.dispatch!ExplorerMsg(toggle, &deliver);
    ui.dispatch!ExplorerMsg(ui.find("numberField", "ms"), &deliver, payload: 500);
    ui.dispatch!ExplorerMsg(ui.find("keyValue", "castore"), &deliver);
}

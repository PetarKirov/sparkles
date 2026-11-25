/// The explorer's Stats pane, built top-down from expressions: children are
/// lazy variadic arguments, evaluated by their parent after it opens.
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

// ── a composite: one expression, children evaluated top-down ───────────────

Node statsPane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
    => ui.column(gap: ui.env.density == Density.compact ? 0 : 1, children:
        ui.row(gap: 2, children:
            ui.label(slot: Slot.heading, text: "Stats"),
            ui.toggle(on: s.hashOnEdit, label: "hash on edit",
                onPress: ui.on(StatsMsg(ToggleHash()))),
            ui.numberField(value: s.debounceMs, unit: "ms",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v)))),
        ),
        ids.computing
            ? ui.label(slot: Slot.dim, text: ui.text(i"computing… (query $(ids.query))"))
            : Node.none,
        ids.rows
            .toUi(ui)
            .mapKeyed!(
                r => r.name,
                r => ui.keyValue(name: r.name, value: r.value,
                    onPress: ui.on(StatsMsg(CopyName(r.name)))),
            ),
        // Structure chosen from context: the column above has opened, so this
        // reads the env it is evaluated under (compact under the override).
        ui.env.density == Density.comfortable
            ? ui.label(slot: Slot.dim, text: "click a name to copy it")
            : Node.none,
    );

// ── the root composite ─────────────────────────────────────────────────────

Node explorerView(ref Ui ui, in Model m) @safe pure nothrow @nogc
    => ui.column(children:
        ui.label(slot: Slot.heading, text: ui.text(i"members: $(m.ids.rows.length)")),

        // Was "deferred": now a plain call. The column opens (pushing compact
        // and `disabled`) before its child slot runs, so the pane sees both.
        ui.column(env: ui.env.withDensity(Density.compact), disabled: m.tutorial, children:
            ui.mapMsg!liftStats(statsPane(ui, m.stats, m.ids)),
        ),

        // Was "eager": the same plain call, under the caller's env (comfortable).
        // There is no longer any difference between the two placements.
        badOrGood(ui, m),

        // Was "memo": a memo element keyed by the arguments and the env.
        ui.mapMsg!liftStats(ui.memo!statsPane(m.stats, m.ids)),
    );

version (BadMissingMapMsg)
{
    // The pane's `StatsMsg`s are sent where `ExplorerMsg` is expected. `ui.on`
    // runs inside the explorer's column, so the check fires right there — at
    // run time (debug): `ui` carries no message type to fail at compile time.
    Node badOrGood(ref Ui ui, in Model m) @safe pure nothrow @nogc
        => statsPane(ui, m.stats, m.ids);
}
else
{
    Node badOrGood(ref Ui ui, in Model m) @safe pure nothrow @nogc
        => ui.mapMsg!liftStats(statsPane(ui, m.stats, m.ids));
}

// ── subtrees as values ─────────────────────────────────────────────────────

/// A composite receiving a subtree from its caller: `content` is a lazy
/// builder, evaluated in the card's second slot, under the card's env.
Node card(ref Ui ui, string title, scope ChildFn content) @safe pure nothrow @nogc
    => ui.column(gap: 0, children:
        ui.label(slot: Slot.heading, text: title),
        content(),
    );

/// A list whose rows a caller-supplied function builds; the list keys them.
Node memberList(ref Ui ui, in IdsView ids,
    scope Node delegate(in MemberRow) @safe pure nothrow @nogc row) @safe pure nothrow @nogc
    => ui.column(children: ids.rows.toUi(ui).mapKeyed!(r => r.name, r => row(r)));

Node subtrees(ref Ui ui, in IdsView ids, bool wide) @safe pure nothrow @nogc
{
    // A subtree stored in a variable: a `scope` delegate, so no closure. It is
    // *not* built here — only where it is placed, under that place's env.
    scope ChildFn names = () => ui.column(children:
        ids.rows.toUi(ui).mapKeyed!(r => r.name, r => ui.label(text: r.name)));

    return ui.column(gap: 1, children:
        card(ui, title: "(a) inline content", content: () => ui.label(text: ids.query)),
        card(ui, title: "(b) stored content", content: names),
        // Placed in one of two places: left when wide, right otherwise.
        ui.row(gap: 3, children:
            ui.column(children: ui.label(text: "left"), wide ? names() : Node.none),
            ui.column(env: ui.env.withDensity(Density.compact), children:
                ui.label(text: "right"), wide ? Node.none : names()),
        ),
        memberList(ui, ids, (in MemberRow r) => ui.label(text: r.value)),
    );
}

/// The hazard: a `Node` expression outside a children slot is built at once,
/// under whatever is open (here: the frame's root slot), not where it is used.
Node misplaced(ref Ui ui) @safe pure nothrow @nogc
{
    auto early = ui.label(text: "early"); // built now, before the column
    return ui.column(env: ui.env.withDensity(Density.compact), children:
        ui.label(text: "a"),
        early, // only the handle is passed: the slot returns an old node
    );
}

// ── what the API rejects ───────────────────────────────────────────────────

int impureCounter;
Node impurePane(ref Ui ui) => ui.label(text: impureCounter++ ? "a" : "b");

struct Stash { ChildFn kept; }

void rejected(ref Ui ui, in IdsView ids) @safe pure nothrow @nogc
{
    import std.algorithm : map;

    // Attributes are named-only: the first parameter is a private sentinel.
    static assert(!__traits(compiles, ui.label(Slot.dim, "x")));
    // `children:` is required: with no attribute the child hits the first
    // sentinel, after the last attribute it hits the second.
    static assert(!__traits(compiles, ui.column(ui.label(text: "x"))));
    static assert(!__traits(compiles, ui.row(gap: 2, ui.label(text: "x"))));
    static assert(__traits(compiles, ui.row(gap: 2, children: ui.label(text: "x"))));
    // An IES expands to several arguments, so it cannot be one named argument.
    static assert(!__traits(compiles, ui.label(text: i"q $(ids.query)")));
    // A bare range is not a child: lists go through `mapKeyed`/`mapByIndex`.
    static assert(!__traits(compiles, ui.column(children: ids.rows)));
    static assert(!__traits(compiles, ids.rows.toUi(ui).map!(r => ui.label(text: r.name))));
    // A child is a `Node` expression, nothing else.
    static assert(!__traits(compiles, ui.column(children: 42)));
    // A payload lambda may not capture: nothing outlives the frame.
    int local = 3;
    static assert(!__traits(compiles, ui.on!((int v) => StatsMsg(SetDebounce(v + local)))));
    // A child slot is `@safe pure nothrow @nogc`: an impure composite is no child,
    // and a memoised composite must be pure.
    static assert(!__traits(compiles, ui.column(children: impurePane(ui))));
    static assert(!__traits(compiles, ui.memo!impurePane()));
    // A child builder is `scope`: it cannot be kept past the frame.
    Stash stash;
    static assert(!__traits(compiles, (scope ChildFn c) @safe { stash.kept = c; }));
    // Not rejected — the hazard `misplaced` shows: a `Node` built outside a
    // slot still type-checks as a child. Only the debug check reports it.
    static assert(__traits(compiles, (Node early) => ui.column(children: early)));
}

// ── run one frame, then deliver three events ───────────────────────────────

void main() @system
{
    import std.stdio : writefln, writeln;
    import std.range : repeat;
    import std.array : join;

    static immutable MemberRow[2] rows = [MemberRow("NarHash", "sha256-q2v…"), MemberRow("castore", "b3:9f1…")];
    const m = Model(Stats(true, 300), IdsView(true, "ab", rows[]), tutorial: true);

    void line(uint depth, string s) @safe { writeln("  ".repeat(depth).join, s); }
    void diag(string s) @safe { writeln("  ! ", s); }

    Ui ui; // on the stack: its arenas are a few tens of KiB
    ui.expectMsg!ExplorerMsg;
    cast(void) ui.frame(Env(Layout.wide, Density.comfortable), explorerView(ui, m));

    writeln("── tree ──");
    ui.dump(&line);
    writeln("── diagnostics ──");
    ui.diagnostics(&diag);
    writefln("messages type-check: %s (checked at each `ui.on`, at run time)", ui.messagesTypeCheck);

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
    version (BadMissingMapMsg)
        writeln("(not dispatching: the frame failed its message check)");
    else
    {
        // The first toggle is the compact (formerly deferred) pane's.
        ui.dispatch!ExplorerMsg(ui.find("toggle", "hash on edit"), &deliver);
        ui.dispatch!ExplorerMsg(ui.find("numberField", "ms"), &deliver, payload: 500);
        ui.dispatch!ExplorerMsg(ui.find("keyValue", "castore"), &deliver);
    }

    foreach (wide; [true, false])
    {
        Ui sub;
        sub.expectMsg!StatsMsg;
        cast(void) sub.frame(Env(Layout.wide, Density.comfortable), subtrees(sub, m.ids, wide));
        writefln("── subtrees as values (wide = %s) ──", wide);
        sub.dump(&line);
        sub.diagnostics(&diag);
    }

    {
        Ui bad;
        bad.expectMsg!StatsMsg;
        cast(void) bad.frame(Env(Layout.wide, Density.comfortable), misplaced(bad));
        writeln("── hazard: a Node built outside a children slot ──");
        bad.dump(&line);
        bad.diagnostics(&diag);
    }
}

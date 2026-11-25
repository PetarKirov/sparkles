// Clay's open/close, in D: `with (ui.column(...)) { children }` closes in a destructor.
struct Env { bool compact; }
private struct NamedOnly {}

struct Ui
{
    uint depth; uint count; Env env;
    char[512] log; uint logLen;
    void note(string s) @safe pure nothrow @nogc { log[logLen .. logLen + s.length] = s; logLen += cast(uint) s.length; }
}

/// The open element. It holds nothing a `with` body could name by accident.
struct Opened
{
    private Ui* owner;
    private Env saved;
    @disable this(this);
    ~this() scope @safe pure nothrow @nogc
    {
        if (owner is null) return;
        owner.depth--;          // close: pop, compute the fit size from the children here
        owner.env = saved;      // context pops with the element
        owner.note(")");
    }
}

Opened column(return ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, bool compact = false,
    size_t line = __LINE__) @trusted pure nothrow @nogc
{
    ui.count++;
    ui.depth++;
    const saved = ui.env;
    if (compact) ui.env.compact = true;   // known before any child is built
    ui.note("(");
    return Opened(&ui, saved);
}

void label(ref Ui ui, NamedOnly _ = NamedOnly.init, string text = null, size_t line = __LINE__)
    @safe pure nothrow @nogc
{
    ui.count++;
    ui.note(ui.env.compact ? "c" : "L");
}

void pane(ref Ui ui, bool computing, in int[] rows) @safe pure nothrow @nogc
{
    with (ui.column(gap: 1))
    {
        ui.label(text: "Stats");
        if (computing)
            ui.label(text: "computing…");
        foreach (r; rows)
            ui.label(text: "row");
        with (ui.column(compact: true))
        {
            ui.label(text: "inside");
            if (rows.length > 1)
                return;               // early exit still closes both elements
            ui.label(text: "never");
        }
        ui.label(text: "after");
    }
}

void main() @system
{
    import std.stdio : writeln;
    Ui ui;
    static immutable int[2] rows = [1, 2];
    pane(ui, true, rows[]);
    writeln(ui.log[0 .. ui.logLen], "  depth after: ", ui.depth);
    ui = Ui.init;
    pane(ui, false, rows[0 .. 1]);
    writeln(ui.log[0 .. ui.logLen], "  depth after: ", ui.depth);
}

// Clay's open/close for-latch, in D: `foreach (_; ui.column(...)) { children }`.
struct Env { bool compact; }
private struct NamedOnly {}

struct Ui
{
    uint[32] stack; uint depth; uint count; Env env;
    uint[64] parentOf; ulong[64] idOf;
    char[512] log; uint logLen;
    private void note(string s) @safe pure nothrow @nogc { log[logLen .. logLen + s.length] = s; logLen += cast(uint) s.length; }
}

/// The open element: `opApply` runs the block once, then closes, even on `break`.
struct Open
{
    private Ui* ui;
    private Env saved;
    int opApply(scope int delegate(ref Open) @safe pure nothrow @nogc body) @safe pure nothrow @nogc
    {
        const r = body(this);
        ui.depth--;           // close: pop, compute fit size from children here
        ui.env = saved;       // context pops with the element
        ui.note(")");
        return r;
    }
}

Open column(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, bool compact = false,
    size_t line = __LINE__) @trusted pure nothrow @nogc
{
    const self = ui.count++;
    ui.parentOf[self] = ui.depth ? ui.stack[ui.depth - 1] : uint.max;
    ui.idOf[self] = (ui.depth ? ui.idOf[ui.stack[ui.depth - 1]] * 31 : 7) ^ line; // parent id + call site
    ui.stack[ui.depth++] = self;
    const saved = ui.env;
    if (compact) ui.env.compact = true;   // context for the subtree, known before any child
    ui.note("(");
    return Open(&ui, saved);
}

void label(ref Ui ui, NamedOnly _ = NamedOnly.init, string text = null, size_t line = __LINE__)
    @safe pure nothrow @nogc
{
    ui.count++;
    ui.note(ui.env.compact ? "c" : "L");
}

void pane(ref Ui ui, bool computing, in int[] rows) @safe pure nothrow @nogc
{
    foreach (_; ui.column(gap: 1))
    {
        ui.label(text: "Stats");
        if (computing)                      // plain `if`: no Node.none, no ternary
            ui.label(text: "computing…");
        foreach (r; rows)                   // plain `foreach`
            ui.label(text: "row");
        foreach (_; ui.column(compact: true))
        {
            ui.label(text: "inside");       // sees compact: the parent is already open
            if (rows.length > 1)
                break;                      // `break` still closes the element
            ui.label(text: "never");
        }
        ui.label(text: "after");
    }
}

void main() @safe
{
    import std.stdio : writeln;
    Ui ui;
    static immutable int[2] rows = [1, 2];
    pane(ui, true, rows[]);
    writeln(ui.log[0 .. ui.logLen], "  depth after: ", ui.depth);
}

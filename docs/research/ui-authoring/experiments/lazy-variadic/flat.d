module flat;
@safe pure nothrow @nogc:

private struct NamedOnly {}
struct Node { uint id; }
struct Env { bool compact; }

struct Ui
{
    char[256] log; size_t n; Env env; uint depth;
    uint[16] childIx; // per-depth child index = argument position
    void note(char c) @safe pure nothrow @nogc { log[n++] = c; }
}

// Children are lazy: the parent opens, sets context, evaluates each child, closes.
Node column(return ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, bool compact = false,
    scope Node delegate() @safe pure nothrow @nogc [] children...)
{
    ui.note('(');
    const saved = ui.env;
    if (compact) ui.env.compact = true;
    ui.depth++;
    foreach (i, child; children)
    {
        ui.childIx[ui.depth] = cast(uint) i; // identity slot = syntactic position
        cast(void) child();
    }
    ui.depth--;
    ui.env = saved;
    ui.note(')');
    return Node(1);
}

Node label(return ref Ui ui, NamedOnly _ = NamedOnly.init, string text = null)
{
    ui.note(ui.env.compact ? 'c' : 'L');
    return Node(2);
}

enum Node none = Node(0);
Node f(ref Ui ui, bool c) => ui.column(gap: 1, children: ui.label(text: "a"), c ? ui.label(text: "b") : none);

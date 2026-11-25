module probe;
@safe pure nothrow @nogc {

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

Node pane(ref Ui ui, bool computing, int rows)
    => ui.column(gap: 1, children:
        ui.label(text: "Stats"),
        computing ? ui.label(text: "computing") : none,
        ui.column(compact: true, children:
            ui.label(text: "inside"),
            ui.label(text: "inside2"),
        ),
        ui.label(text: "after"),
    );

// Named `children:` into the variadic, then more positionals continue into it.
Node named(ref Ui ui) => ui.column(gap: 2, children: ui.label(text: "a"), ui.label(text: "b"));
// Attribute order other than declaration order, then positionals.
Node reordered(ref Ui ui) => ui.column(compact: true, gap: 3, children: ui.label(text: "a"));
// No attributes at all.
Node bare(ref Ui ui) => ui.column(children: ui.label(text: "a"));
// A subtree held as a value: a lazy delegate the caller places later.
Node card(ref Ui ui, scope Node delegate() @safe pure nothrow @nogc content) => ui.column(gap: 1, children: ui.label(text: "title"), content());
Node usesCard(ref Ui ui) => card(ui, () => ui.column(compact: true, children: ui.label(text: "body")));

}
void main() @system
{
    import core.stdc.stdio : printf;
    static foreach (f; ["pane(ui, true, 2)", "pane(ui, false, 2)", "named(ui)", "reordered(ui)", "bare(ui)", "usesCard(ui)"])
    {{
        Ui ui;
        cast(void) mixin(f);
        printf("%-20s %.*s\n", f.ptr, cast(int) ui.n, ui.log.ptr);
    }}
}

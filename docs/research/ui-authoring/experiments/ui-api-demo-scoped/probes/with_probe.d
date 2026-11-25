module with_probe;
struct Ui(M) { int n; }
struct Handle(M) {
    Ui!M* p;
    @disable this(this);
    ~this() scope @safe pure nothrow @nogc {}
    ref Ui!M ui() return @safe pure nothrow @nogc => *p;
    ref Ui!M inner() return scope @safe pure nothrow @nogc => *p;
}
Handle!int open(return ref Ui!int u) @trusted pure nothrow @nogc => Handle!int(&u);

void f(ref Ui!int u) @safe pure nothrow @nogc { u.n++; }

version (Shadow)
void shadow(ref Ui!int ui) @safe pure nothrow @nogc { with (open(ui)) f(ui); }

version (WithDecl)
void withDecl(ref Ui!int ui) @safe pure nothrow @nogc { with (auto h = open(ui)) f(h.inner); }

void named(ref Ui!int ui) @safe pure nothrow @nogc { with (open(ui)) f(inner); }

// Lambda slot inference: card generic over M, content a scope delegate.
void card(M)(ref Ui!M ui, scope void delegate(ref Ui!M) @safe pure nothrow @nogc content) { content(ui); }
void card2(alias content, M)(ref Ui!M ui) { content(ui); }

void useCard(ref Ui!int ui, int captured) @safe pure nothrow @nogc
{
    card(ui, (ref Ui!int u) { u.n += captured; });
    static if (__traits(compiles, card(ui, (ref u) { u.n += captured; })))
        pragma(msg, "untyped `(ref u)` lambda to delegate param: compiles");
    else
        pragma(msg, "untyped `(ref u)` lambda to delegate param: does NOT compile");
    card2!((ref u) { u.n += captured; })(ui);
    scope dg = (ref Ui!int u) { u.n += captured; };   // stored in a variable
    if (captured) card(ui, dg); else card2!dg(ui);
}
void main() @safe { Ui!int u; named(u); useCard(u, 2); }

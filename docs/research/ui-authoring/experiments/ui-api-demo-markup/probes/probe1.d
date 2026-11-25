import std.stdio;
enum string where(string src, string file = __FILE__, size_t line = __LINE__) = "enum __w = \"" ~ file ~ "\"; enum __l = " ~ line.stringof ~ ";";
template Loc(string f = __FILE__, size_t l = __LINE__) { enum Loc = l; }

void apply(scope void delegate(int ui) @safe pure nothrow @nogc dg) @safe pure nothrow @nogc { dg(1); }

void f(int ui) @safe pure nothrow @nogc
{
    int local = 3;
    scope dg = delegate (int ui) @safe pure nothrow @nogc { cast(void) (ui + local); };
    dg(2);
    apply(delegate (int ui) @safe pure nothrow @nogc { cast(void) (ui + local); });
    int body = 1;
}

void g()
{
    mixin("struct A1 {}");
    pragma(msg, "plain mixin: ", __traits(getLocation, A1));
    mixin("\n\nstruct A2 {}");
    pragma(msg, "mixin line 3: ", __traits(getLocation, A2));
    mixin("#line 100 \"app.d\"\n      struct A3 {}");
    pragma(msg, "with #line: ", __traits(getLocation, A3));
    struct Here {}
    pragma(msg, "after: ", __traits(getLocation, Here));
    pragma(msg, "fn: ", __FUNCTION__);
    mixin(where!q{
        a
        b
    });
    pragma(msg, "where: ", __w, " ", __l);
    pragma(msg, "parent: ", __traits(identifier, __traits(parent, Here)));
    auto x = delegate () { struct In {} pragma(msg, "in lambda parent: ", __traits(identifier, __traits(parent, In)), " fn=", __FUNCTION__); };
    auto y = delegate (int a = mixin("__LINE__")) { };
}
void main() { g(); }

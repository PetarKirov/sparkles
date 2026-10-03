module sparkles.effects_direct;

// Minimal prototype of Context-based capability passing
struct Context(Effects...)
{
    Effects effects;

    // simplistic lookup
    ref auto get(T)() return
    {
        import std.meta : staticIndexOf;
        enum idx = staticIndexOf!(T, Effects);
        static assert(idx >= 0, "Effect not found in Context");
        return effects[idx];
    }
}

struct Reader(T)
{
    T value;
    T ask() { return value; }
}

// Helper to deduce context
auto withReader(T, Ctx...)(T value, Ctx ctx)
{
    return Context!(Reader!T, Ctx)(Reader!T(value), ctx);
}

unittest
{
    auto ctx = withReader!int(42);
    assert(ctx.get!(Reader!int).ask() == 42);
}

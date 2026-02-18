module doc_coverage.mixed.templates;

/// Generic box used to exercise aggregate template docs.
struct Box(T)
{
    T value;

    this(T value)
    {
        this.value = value;
    }

    this(this)
    {
    }

    invariant()
    {
    }

    ~this()
    {
    }
}

/// Returns a boxed value.
///
/// Examples:
/// ---
/// auto b = makeBox!int(9);
/// assert(b.value == 9);
/// ---
Box!T makeBox(T)(T value)
{
    return Box!T(value);
}

/// Constrained template overload.
string stringify(T)(T value)
if (is(T : int))
{
    import std.conv : to;
    return value.to!string;
}

@("docCoverage.mixed.templates.makeBox")
@safe
unittest
{
    auto b = makeBox!int(3);
    assert(b.value == 3);
}

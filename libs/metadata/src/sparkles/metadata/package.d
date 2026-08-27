/**
Dependency-free passive metadata shared across Sparkles libraries.

These attributes describe names and values; each consuming domain decides how
to interpret them. Behavioral policy such as CLI parsing, serialization,
visibility, and mutation deliberately remains in its owning package.
*/
module sparkles.metadata;

/// Canonical machine-readable name, independent of a serialization format.
struct Name
{
    string name;
}

/// Additional accepted names, in preference order.
struct Aliases
{
    string[] names;

    this(Args...)(Args args) if (Args.length > 0)
    {
        names = [args];
    }
}

/// Short human-facing label.
struct Label
{
    string text;

    /// Compatibility spelling used by the former input `WireDisplayName` UDA.
    string name() const @safe pure nothrow @nogc => text;
}

/// Human-facing explanatory prose.
struct Description
{
    string text;
}

/// Numeric domain bounds; consumers decide whether these are advisory or enforced.
struct Range
{
    double lo;
    double hi;
    double step = 0;
}

@("metadata.passiveAttributes")
@safe pure nothrow @nogc
unittest
{
    enum N = Name("canonical");
    enum A = Aliases("short", "legacy");
    enum L = Label("Display");
    enum D = Description("Details");
    enum R = Range(1, 4);

    static assert(N.name == "canonical");
    static assert(A.names == ["short", "legacy"]);
    static assert(L.text == "Display" && L.name == "Display");
    static assert(D.text == "Details");
    static assert(R.lo == 1 && R.hi == 4 && R.step == 0);
}

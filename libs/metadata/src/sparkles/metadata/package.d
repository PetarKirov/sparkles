/**
Dependency-free passive metadata shared across Sparkles libraries.

These attributes describe names and values; each consuming domain decides how
to interpret them. Behavioral policy such as CLI parsing, serialization,
visibility, and mutation deliberately remains in its owning package.
*/
module sparkles.metadata;

/// The format vocabulary: `@WireName`, `@WireCase`, `@WireRepr` and the
/// format tags; a member's canonical name is `@WireName` under `AnyFormat`.
public import sparkles.metadata.wire;
/// ditto
public import sparkles.metadata.case_style : CaseStyle;

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

/// A heading that groups a field's contents with a human-facing title; a
/// presenting domain shows the field as a section under it.
struct Section
{
    string label;
}

/// A text field holding a colour (`#rrggbb` or `#rgb`; empty for "none"). On
/// an array field it marks every element.
enum colorValue;

@("metadata.passiveAttributes")
@safe pure nothrow @nogc
unittest
{
    enum A = Aliases("short", "legacy");
    enum L = Label("Display");
    enum D = Description("Details");
    enum R = Range(1, 4);

    static assert(A.names == ["short", "legacy"]);
    static assert(L.text == "Display" && L.name == "Display");
    static assert(D.text == "Details");
    static assert(R.lo == 1 && R.hi == 4 && R.step == 0);
}

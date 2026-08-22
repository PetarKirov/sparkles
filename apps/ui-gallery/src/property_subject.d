/**
The Property page's subject and live state.

`DemoLayer` is shaped so every property-tree behavior has a row to happen on:
all six leaf kinds, `@Label`/`@Doc`/`@Range`/`@ShowIf`/`@readOnly`/`@hidden`/
`@Editor!symbol` metadata, a keyed collection (`[#7]`), a positional one, an
`@opaqueValue` handle, a type-erased `propChildren` subtree (with a key the
bare path grammar cannot spell), and a heap self-cycle behind `linked` so
"open all" runs straight into the `⋯ (capped)` budget rows.

A separate module (not `state.d`, not the page) because both need it: the
state holds `PropertyDemo`, the page holds the behavior.
*/
module property_subject;

import std.conv : text;

import sparkles.ui.components.tree_view : TreeViewState;
import sparkles.ui.property_tree : Doc, Editor, hidden, Label, opaqueValue,
    PropertyEditState, PropertyTree, Range, readOnly, ShowIf;

@safe:

///
enum FillKind : ubyte { solid, gradient, texture }

///
enum BlendMode : ubyte { normal, multiply, screen, overlay }

/// `@opaqueValue`: a leaf via its own `toString` — never descended, never
/// editable (VS Code's `Complex` posture).
@opaqueValue struct Handle
{
    ulong bits = 0xC0FFEE; ///

    ///
    string toString() const @safe pure => text("Handle(0x", bits, ")");
}

/// The `@Editor` demo symbol: accepts and emits the field's concrete type —
/// a symbol, not a registry key, so a mismatch is a build error.
uint tintSwatch(uint v) @safe pure nothrow @nogc => v;

/// A keyed element: identity by `propElementKey`, so `[#7]` survives
/// removal and reorder, and disclosure/selection/history follow the element.
struct GradientStop
{
    ulong id;                                   ///
    @Label("stop name") string name;            ///
    @Range(0, 1, 0.05) double offset = 0;       ///

    ///
    ulong propElementKey() const @safe pure nothrow @nogc => id;
}

///
struct FillStyle
{
    @Doc("how the shape is painted") FillKind kind; ///
    @Range(0, 1, 0.05) @Doc("0 = transparent, 1 = solid")
    double opacity = 1;                             ///
    /// Visible only while `kind == gradient` — `@ShowIf` re-evaluates on
    /// every rebuild, so editing `kind` reveals/hides this row live.
    @ShowIf("kind == FillKind.gradient") @Label("stop count") int stops = 2;
    GradientStop[] stopList;                        ///
}

///
struct Metrics
{
    @Range(16, 4096, 8) int width = 320;         ///
    @Range(16, 4096, 8) int height = 200;        ///
    @Doc("device pixel ratio") double dpr = 1;   ///
}

/// The statically typed erased value (`PRT5`): a `JsonValue`-shaped sum that
/// supplies its own children/expandability/reading. Read-only in v1.
struct Dyn
{
    ///
    enum Kind : ubyte { nil, boolean, number, str, object }

    Kind kind;      ///
    bool b;         ///
    double num;     ///
    string s;       ///
    Pair[] fields;  ///

    ///
    static struct Pair { string key; Dyn value; }

    ///
    static Dyn of(bool v) @safe pure nothrow
    {
        Dyn d;
        d.kind = Kind.boolean;
        d.b = v;
        return d;
    }

    /// ditto
    static Dyn of(double v) @safe pure nothrow
    {
        Dyn d;
        d.kind = Kind.number;
        d.num = v;
        return d;
    }

    /// ditto
    static Dyn of(string v) @safe pure nothrow
    {
        Dyn d;
        d.kind = Kind.str;
        d.s = v;
        return d;
    }

    /// ditto
    static Dyn obj(Pair[] v) @safe pure nothrow
    {
        Dyn d;
        d.kind = Kind.object;
        d.fields = v;
        return d;
    }

    /// The erased seam: children as `(index, name, ref child)`.
    auto propChildren() return @safe
    {
        static struct R
        {
            Dyn* self;
            int opApply(
                scope int delegate(size_t, const(char)[], ref Dyn) @safe dg)
                @safe
            {
                if (self.kind == Kind.object)
                    foreach (i, ref f; self.fields)
                        if (auto r = dg(i, f.key, f.value))
                            return r;
                return 0;
            }
        }
        return (() @trusted => R(&this))();
    }

    /// ditto
    bool propExpandable() const @safe pure nothrow @nogc
        => kind == Kind.object;

    /// ditto
    string propText() const @safe pure
    {
        final switch (kind)
        {
            case Kind.nil: return "null";
            case Kind.boolean: return b ? "true" : "false";
            case Kind.number: return text(num);
            case Kind.str: return text('"', s, '"');
            case Kind.object: return text("{", fields.length, " keys}");
        }
    }
}

/// The subject: one value, every behavior.
struct DemoLayer
{
    @Label("name") @Doc("shown in the layer list") string name = "background"; ///
    bool visible = true;                                       ///
    @Doc("compositing operator") BlendMode blend;              ///
    FillStyle fill;                                            ///
    Metrics metrics;                                           ///
    @Doc("positional collection — indices re-point on removal")
    int[] dashes;                                              ///
    @readOnly @Doc("engine-assigned; @readOnly refuses in the dispatch")
    ulong id = 42;                                             ///
    @hidden uint revision;                                     ///
    @Editor!tintSwatch @Doc("custom editor: a symbol, not a registry key")
    uint tint = 0x336699;                                      ///
    Handle handle;                                             ///
    @Doc("plugin-supplied settings — the erased read seam") Dyn extra; ///
    @Doc("a self-cycle: open all to meet the caps") DemoLayer* linked; ///
}

/// A populated subject, with the heap self-cycle attached.
DemoLayer demoSubject() @safe
{
    DemoLayer l;
    l.dashes = [4, 2, 1];
    l.fill.stopList = [
        GradientStop(7, "start", 0),
        GradientStop(9, "end", 1),
    ];
    l.extra = Dyn.obj([
        Dyn.Pair("retries", Dyn.of(3.0)),
        Dyn.Pair("tls", Dyn.obj([Dyn.Pair("verify", Dyn.of(true))])),
        Dyn.Pair("weird.key [0]", Dyn.of("needs quoted addressing")),
    ]);
    auto cyc = new DemoLayer;
    cyc.name = "linked";
    (() @trusted { cyc.linked = cyc; })(); // the cycle lives on the heap, so
    l.linked = cyc;                        // copying the state cannot dangle
    return l;
}

/// The Property page's whole live state, as one value in `GalleryState`.
struct PropertyDemo
{
    DemoLayer subject;          ///
    PropertyTree!DemoLayer tree; ///
    TreeViewState!string tv;    ///
    PropertyEditState edits;    ///
    bool previewing;            /// a 'v' preview session is live (`PRT19`)
    bool built;                 /// lazy first build happened
    int externalPokes;          /// how often 'e' mutated the subject directly

    /// First-use initialisation + a rebuild; safe to call every time.
    void ensure() @safe
    {
        if (!built)
        {
            subject = demoSubject();
            tv.width = 64;
            tv.height = 14;
            tv.chromeRows = 0;
            // The default gutter stays reserved: propertyView frames the
            // rows and emits the machine-driven animated bar (SCV1) — the
            // same look every tree view scrolls with.
            tv.scrollGutterV = 1;
            tv.scrollGutterH = 0;
            built = true;
        }
        refresh();
    }

    /// Rebuild rows from the subject, pinning a pending edit's path.
    void refresh() @safe
    {
        tree.rebuild(subject, tv,
            edits.pendingActive ? edits.pendingPath : null);
    }
}

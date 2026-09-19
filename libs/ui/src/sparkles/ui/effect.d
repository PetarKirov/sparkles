/**
Subtree effects for $(MREF sparkles,ui) (`EFX`): the identity a widget carries,
the tier that says what an effect may read, and the registry that resolves one.

$(B An effect is shaped exactly like a clip.) The display list already brackets
subtrees — `pushClip`/`popClip` are two of the nine original ops, and `TGT12`
settled how they nest. `pushEffect`/`popEffect` is the same shape: bracket a
subtree, let the backend decide what that means. So it costs the op vocabulary
two entries and the canvas seam two optional primitives, and reuses nesting
rules that already exist.

$(B Tiered by what the effect may read), following SwiftUI's
`colorEffect`/`distortionEffect`/`layerEffect` split, because that is the axis
along which a cell grid's ability actually changes:

$(TABLE
    $(TR $(TH Tier) $(TH Reads) $(TH Cell grid))
    $(TR $(TD `color`) $(TD its own position and colour) $(TD $(B yes)))
    $(TR $(TD `distortion`) $(TD position only, and rewrites it) $(TD no))
    $(TR $(TD `layer`) $(TD arbitrary samples of the rendered layer) $(TD no))
)

Tiering makes degradation a property of the tier — answerable once — instead of
an argument re-litigated per effect. The toolkit's central claim is that one
`view` serves the terminal and the window; an effect system only a GPU could
honour would quietly turn that into "one view, one of which is plainer".
*/
module sparkles.ui.effect;

import std.algorithm : canFind;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.geometry : Point, Size;

/**
An effect's identity, stable for the life of the registry that issued it.

Opaque, and $(B four bytes) — which is the point: `EFX4` puts the id on the
widget and keeps the implementation out, so the arena stays flat. `0` is the
null id, which $(LREF EffectRegistry) never issues, so a default-constructed
widget carries no effect.
*/
struct EffectId
{
    /// The registry's index, biased by one so `0` is "no effect".
    uint value;

    /// Whether this names an effect at all.
    bool valid() const @safe pure nothrow @nogc => value != 0;
}

/// What an effect is allowed to read — and therefore which canvases can
/// honour it (`EFX7`).
enum EffectTier : ubyte
{
    /// Tier 0: a pure colour transform over each resolved cell. No texture,
    /// no neighbour reads — so a cell grid can run it (`EFX8`, `EFX9`).
    color,
    /// Tier 1: rewrites position. Barrel distortion, ripple. Needs a texture.
    distortion,
    /// Tier 2: samples the rendered layer arbitrarily. Blur, glow, bloom.
    layer,
}

/**
What a tier-0 transform is handed: where the cell is, how big the bracket is,
and the colour resolved for it.

A struct rather than three parameters so the input can grow without every
registered effect's signature changing — and so the GPU twin `EFX20` aims at
has one thing to mirror.

$(B `at` is relative to the bracket's origin), not absolute on the grid. An
effect describes its own subtree; a scanline pattern that shifted when the
panel moved would be describing the screen instead. It is also the analogue of
the normalized coordinate a fragment shader gets, which is what keeps one D
function able to serve both.
*/
struct Tier0Input
{
    Point at;       /// cell position, relative to the bracket's origin
    Size extent;    /// the bracket's size in cells
    RgbColor color; /// the colour resolved for this cell
}

/**
A tier-0 colour transform (`EFX8`).

`@safe pure nothrow @nogc` is required, not preferred: it runs per cell, and
the constraint is also what keeps `EFX20` — one D function compiled both for
the terminal and to SPIR-V — reachable.
*/
alias Tier0Fn = RgbColor function(in Tier0Input) @safe pure nothrow @nogc;

/**
What a canvas that cannot honour an effect's tier does instead (`EFX12`).

Stated rather than assumed. "Unaffected" is a perfectly good answer and is the
common one; requiring it to be spelled is what stops "no fallback" from being
the path of least resistance.
*/
enum Degradation : ubyte
{
    /// Paint the bracketed subtree with no effect at all.
    unaffected,
    /// A tier-1/2 effect that also registered a tier-0 transform, which is a
    /// deliberate approximation rather than the effect itself.
    colorApproximation,
}

/**
A backend's own artifact for an effect (`EFX13`).

$(B The toolkit never looks inside `source`, and never interprets `backend`) —
it compares the key and hands the bytes over. That is what keeps a GLSL string
and, later, a SPIR-V blob from turning `sparkles:ui` into something that knows
about devices: a record carries artifacts the way a registry carries anything
else, and the backend that recognises the key is the only code that can read
them.

$(B Why a string beside a D function.) For a tier-0 effect the two are twins —
the same transform written twice — and `EFX20` exists because that is a
temporary state, not the design. Keeping them adjacent in this module is the
weakest form of the enforcement that eventually replaces them: a reader sees
both at once, and `ui_raylib.effect_gpu`'s golden test checks they agree.
*/
struct EffectImpl
{
    /// A key the toolkit only compares. $(LREF glslBackend) is the one both
    /// GL targets use.
    string backend;
    /// The artifact. For $(LREF glslBackend), the body of a
    /// `vec3 effectColor(vec2 at, vec2 extent, vec3 color)` function — the
    /// GLSL twin of a $(LREF Tier0Fn), in the same cell coordinates.
    string source;
}

/// The `EffectImpl.backend` key for a GLSL fragment target (desktop and ES
/// alike — the dialect difference is a prologue the backend supplies).
enum string glslBackend = "glsl";

/// One registered effect: its tier, its tier-0 transform where it has one, and
/// what it degrades to (`EFX13`).
struct EffectRecord
{
    /// A human name, for inspectors and for the `EFX17` diagnostic. Not an
    /// identity — two effects may share a name; only the id is identity.
    string name;
    EffectTier tier;
    /// The tier-0 transform. Non-null for every `EffectTier.color` effect, and
    /// optionally present on a higher tier as its `colorApproximation`.
    Tier0Fn tier0;
    Degradation degradation;

    /// Per-backend artifacts (`EFX13`), looked up by key.
    EffectImpl[] impls;

    /// Whether a cell grid can honour this — i.e. whether there is a transform
    /// to run at all.
    bool honouredByCells() const @safe pure nothrow @nogc => tier0 !is null;

    /// The artifact `backend` recognises, or `null`. A backend with no entry
    /// degrades per `EFX3`/`EFX12` rather than failing.
    const(EffectImpl)* implFor(scope const(char)[] backend) const
        @safe pure nothrow @nogc return
    {
        foreach (ref const i; impls)
            if (i.backend == backend)
                return &i;
        return null;
    }
}

/**
The effect index (`EFX13`): ids in, records out.

$(B Runtime, uniformly across all tiers.) One mechanism, one lookup, one place
a hot-reloaded shader is swapped while it is being tuned by eye (`EFX18`). The
alternative — compile-time effect values, capability-checked per backend — was
considered and rejected; what it costs is recorded in the spec's Decisions, and
the honest summary is that `hasTier0!E` becomes a runtime lookup, so `EFX12`
and `EFX17` carry a guarantee the type system would otherwise have carried.

$(B Ids are never reused) (`EFX14`). `remove` clears a record and keeps its
slot: a registry that reissued an id would silently repaint a subtree with
someone else's effect, and nothing about the frame would look wrong.

$(B The built-ins are registered, not special-cased) (`EFX15`, `EFX19`).
$(LREF builtinEffects) fills a registry with them and hands back their ids, so
there is exactly one resolution path — the compile-time one `EFX19` rules out
would otherwise arrive here first, as a `final switch` on a built-in id.
*/
struct EffectRegistry
{
    private EffectRecord[] _records;

@safe:

    /// Registers `record`, returning the id that addresses it.
    EffectId register(EffectRecord record) pure nothrow
    {
        _records ~= record;
        return EffectId(cast(uint) _records.length);
    }

    /// ditto — the common case: a tier-0 transform under a name, optionally
    /// with the GLSL twin a GPU target needs to run the same thing.
    EffectId registerTier0(string name, Tier0Fn fn, string glsl = null)
        pure nothrow
        => register(EffectRecord(name: name, tier: EffectTier.color, tier0: fn,
            impls: glsl is null ? null : [EffectImpl(glslBackend, glsl)]));

    /**
    Replaces what `id` resolves to, keeping the id (`EFX18`).

    Safe between frames by construction — a frame resolves each bracket as it
    paints it, so a swap lands whole or not at all, never half-applied across
    one subtree.
    */
    void replace(EffectId id, EffectRecord record) pure nothrow @nogc
    {
        if (auto slot = slotOf(id))
            *slot = record;
    }

    /// Forgets `id`'s record. The slot is kept, so the id is never reissued.
    void remove(EffectId id) pure nothrow @nogc
    {
        if (auto slot = slotOf(id))
            *slot = EffectRecord.init;
    }

    /**
    The record `id` names, or `null`.

    $(B A null is not an error) (`EFX17`). An unregistered, removed or stale id
    resolves to nothing and the subtree paints unaffected. An effect is
    decoration; a missing one must not be able to take the frame down.
    */
    const(EffectRecord)* lookup(EffectId id) const pure nothrow @nogc return
    {
        if (!id.valid || id.value > _records.length)
            return null;
        const r = &_records[id.value - 1];
        return r.name is null && r.tier0 is null ? null : r;
    }

    /// The tier-0 transform `id` resolves to, or `null` — the one question a
    /// cell backend asks.
    Tier0Fn tier0Of(EffectId id) const pure nothrow @nogc
    {
        const r = lookup(id);
        return r is null ? null : r.tier0;
    }

    /// How many ids have been issued (including removed ones).
    size_t length() const pure nothrow @nogc => _records.length;

    private EffectRecord* slotOf(EffectId id) pure nothrow @nogc return
        => !id.valid || id.value > _records.length
            ? null : &_records[id.value - 1];
}

// ---------------------------------------------------------------------------
// The built-in set (`EFX15`).
// ---------------------------------------------------------------------------

/// The ids $(LREF builtinEffects) registers, in the order it registers them.
struct BuiltinEffects
{
    EffectId scanlines; /// alternate rows darkened — a CRT's horizontal raster
    EffectId phosphor;  /// tinted toward a monochrome phosphor's colour
    EffectId dim;       /// uniformly darkened, for an inactive pane
}

/**
Registers the built-in effects into `reg` and returns their ids (`EFX15`).

All three are tier 0, which is deliberate: the built-in set is the part of the
vocabulary every target can honour, so naming one costs an application nothing
on a terminal. `EFX24`'s claim — that a terminal showing scanlines and a
phosphor tint proves the tier split is real — is these.
*/
BuiltinEffects builtinEffects(ref EffectRegistry reg) @safe pure nothrow
{
    BuiltinEffects b;
    b.scanlines = reg.registerTier0("scanlines", &scanlinesTier0, scanlinesGlsl);
    b.phosphor = reg.registerTier0("phosphor", &phosphorTier0, phosphorGlsl);
    b.dim = reg.registerTier0("dim", &dimTier0, dimGlsl);
    return b;
}

private RgbColor scale(in RgbColor c, int numerator, int denominator)
    @safe pure nothrow @nogc
{
    static ubyte part(ubyte v, int n, int d)
    {
        const scaled = (cast(int) v * n) / d;
        return cast(ubyte)(scaled > 255 ? 255 : (scaled < 0 ? 0 : scaled));
    }
    return RgbColor(part(c.r, numerator, denominator),
        part(c.g, numerator, denominator), part(c.b, numerator, denominator));
}

/// Every other row darkened — the raster a CRT's beam skips.
RgbColor scanlinesTier0(in Tier0Input i) @safe pure nothrow @nogc
    => (i.at.y & 1) ? scale(i.color, 62, 100) : i.color;

/// ditto — the GLSL twin. Kept touching its D original on purpose: these are
/// one transform written twice until `EFX20` removes the duplication, and a
/// reader must be able to see both without going looking.
enum string scanlinesGlsl = q{
vec3 effectColor(vec2 at, vec2 extent, vec3 color)
{
    return mod(at.y, 2.0) >= 1.0 ? color * 0.62 : color;
}
};

/**
Tinted toward a green phosphor, keeping each cell's own luminance.

Luminance rather than a flat green, so text stays readable and the tint reads
as a display characteristic rather than as a colour wash: a bright cell is
bright green and a dim one is dim green, which is what a monochrome tube does.
*/
RgbColor phosphorTier0(in Tier0Input i) @safe pure nothrow @nogc
{
    // Rec. 601 luma, integer: the cheapest weighting that does not make blue
    // text vanish, which a naive average does.
    const luma = (299 * i.color.r + 587 * i.color.g + 114 * i.color.b) / 1000;
    const l = cast(ubyte)(luma > 255 ? 255 : luma);
    return RgbColor(scale(RgbColor(l, l, l), 30, 100).r, l,
        scale(RgbColor(l, l, l), 45, 100).b);
}

/// ditto
enum string phosphorGlsl = q{
vec3 effectColor(vec2 at, vec2 extent, vec3 color)
{
    float l = dot(color, vec3(0.299, 0.587, 0.114));
    return vec3(l * 0.30, l, l * 0.45);
}
};

/// Uniformly darkened — an inactive pane, without the view knowing it is one.
RgbColor dimTier0(in Tier0Input i) @safe pure nothrow @nogc
    => scale(i.color, 55, 100);

/// ditto
enum string dimGlsl = q{
vec3 effectColor(vec2 at, vec2 extent, vec3 color)
{
    return color * 0.55;
}
};

@("ui.effect.builtins.eachCarriesBothHalvesOfItsTwin")
@safe pure nothrow unittest
{
    // `EFX13`: every built-in must ship the GPU artifact beside the D
    // function, or the GPU target silently degrades on an effect the
    // terminal honours — which is the inversion this gate exists to end.
    EffectRegistry reg;
    const b = builtinEffects(reg);
    foreach (id; [b.scanlines, b.phosphor, b.dim])
    {
        const rec = reg.lookup(id);
        assert(rec.tier0 !is null, "the CPU half");
        const impl = rec.implFor(glslBackend);
        assert(impl !is null, "the GPU half");
        // The contract the backend wraps: one function, one name, one
        // signature. A twin that declared something else would compile into
        // the wrapper and fail at link with no line number worth reading.
        assert(impl.source.canFind("vec3 effectColor(vec2 at, vec2 extent, vec3 color)"));
    }
    assert(reg.lookup(b.dim).implFor("spirv") is null,
        "an unknown backend key resolves to nothing, not to the wrong blob");
}

@("ui.effect.registry.resolvesAndNeverReusesAnId")
@safe pure nothrow unittest
{
    EffectRegistry reg;
    assert(!EffectId.init.valid, "a default widget carries no effect");
    assert(reg.lookup(EffectId.init) is null);
    assert(reg.tier0Of(EffectId.init) is null);

    const b = builtinEffects(reg);
    assert(b.scanlines.valid && b.phosphor.valid && b.dim.valid);
    assert(b.scanlines != b.phosphor && b.phosphor != b.dim);
    assert(reg.lookup(b.scanlines).name == "scanlines");
    assert(reg.lookup(b.scanlines).tier == EffectTier.color);
    assert(reg.lookup(b.scanlines).honouredByCells);

    // `EFX17`: an id from beyond the end resolves to nothing rather than
    // reading past the array or aborting the frame.
    assert(reg.lookup(EffectId(9999)) is null);
    assert(reg.tier0Of(EffectId(9999)) is null);

    // `EFX14`: removing keeps the slot, so the next registration gets an id
    // of its own and the stale one stays dead.
    reg.remove(b.dim);
    assert(reg.lookup(b.dim) is null);
    const later = reg.registerTier0("later", &dimTier0);
    assert(later != b.dim && reg.lookup(later).name == "later");

    // `EFX18`: an id can be rebound in place, which is what hot-reload is.
    reg.replace(b.phosphor, EffectRecord(name: "amber",
        tier: EffectTier.color, tier0: &dimTier0));
    assert(reg.lookup(b.phosphor).name == "amber");
    assert(b.phosphor.valid, "the id survives its record being swapped");
}

@("ui.effect.builtins.areHonouredByACellGrid")
@safe pure nothrow @nogc unittest
{
    const white = RgbColor(255, 255, 255);
    const extent = Size(10, 4);

    // Scanlines: even rows untouched, odd rows darkened. Both halves matter —
    // an effect that darkened everything would be `dim` wearing a name.
    assert(scanlinesTier0(Tier0Input(Point(0, 0), extent, white)) == white);
    const odd = scanlinesTier0(Tier0Input(Point(0, 1), extent, white));
    assert(odd.r < white.r && odd == RgbColor(158, 158, 158));
    assert(scanlinesTier0(Tier0Input(Point(0, 2), extent, white)) == white);

    // Phosphor keeps luminance: a bright cell stays bright, a dim one dim,
    // and green dominates in both.
    const bright = phosphorTier0(Tier0Input(Point(0, 0), extent, white));
    const dark = phosphorTier0(Tier0Input(Point(0, 0), extent, RgbColor(40, 40, 40)));
    assert(bright.g > dark.g, "luminance survives the tint");
    assert(bright.g > bright.r && bright.g > bright.b, "green dominates");

    // Blue text must not vanish — the reason this is luma and not an average.
    const blue = phosphorTier0(Tier0Input(Point(0, 0), extent, RgbColor(0, 0, 255)));
    assert(blue.g > 0);

    // `dim` is uniform: position cannot change it.
    assert(dimTier0(Tier0Input(Point(0, 0), extent, white))
        == dimTier0(Tier0Input(Point(7, 3), extent, white)));

    // Saturating, not wrapping — the failure mode of integer colour maths.
    const black = RgbColor(0, 0, 0);
    assert(dimTier0(Tier0Input(Point(0, 1), extent, black)) == black);
    assert(scanlinesTier0(Tier0Input(Point(0, 1), extent, black)) == black);
}

// ---------------------------------------------------------------------------
// Theme rebinding (`EFX16`).
// ---------------------------------------------------------------------------

/**
What a theme says about one built-in effect (`EFX16`).

$(B Rebinding, not overriding at the call site.) A design language turns an
effect off, or swaps it for its own, without any view changing: the widget
still names the same id, and the registry answers differently. That is the
whole reason ids are semantic for built-ins and anonymous for app-registered
ones — an app's effect has no name a theme could address.
*/
struct EffectBinding
{
    /// Whether the theme says anything at all. `false` leaves the built-in
    /// exactly as registered, which is different from binding it to nothing.
    bool bound;
    /// `false` rebinds the id to $(B nothing): it resolves to no record, so
    /// `EFX17` paints the subtree unaffected. This is "turn it off".
    bool enabled = true;
    /// Replaces the transform when non-null; the built-in's is kept otherwise.
    Tier0Fn tier0;
    /// Replaces the GLSL twin when non-null.
    string glsl;
}

/// A theme's say over the built-in set. All-default means "leave them alone".
struct ThemeEffects
{
    EffectBinding scanlines; ///
    EffectBinding phosphor;  ///
    EffectBinding dim;       ///
}

/**
Applies `bindings` to the built-ins already registered in `reg` (`EFX16`).

Idempotent against the original set: it rebinds from `builtin`'s ids, so
calling it again with different bindings does not compound. An application
calls it when the theme changes, between frames — which is exactly the window
`EFX18` says a rebind is safe in.
*/
// `bindings` is taken by VALUE, not `in`. Under `-preview=in` it would be
// `scope const`, and a binding's `tier0`/`glsl` then cannot be stored into the
// registry at all — the documented dip1000 clash, relaxed on exactly the
// parameter that needs it rather than on the function's safety.
void applyThemeEffects(ref EffectRegistry reg, in BuiltinEffects builtin,
    ThemeEffects bindings) @safe pure nothrow
{
    static void bind(ref EffectRegistry reg, EffectId id, EffectBinding b,
        string name, Tier0Fn fallback, string fallbackGlsl) @safe pure nothrow
    {
        if (!b.bound)
            return;
        if (!b.enabled)
        {
            reg.remove(id); // resolves to nothing; `EFX17` does the rest
            return;
        }
        const glsl = b.glsl is null ? fallbackGlsl : b.glsl;
        reg.replace(id, EffectRecord(
            name: name,
            tier: EffectTier.color,
            tier0: b.tier0 is null ? fallback : b.tier0,
            impls: glsl is null ? null : [EffectImpl(glslBackend, glsl)]));
    }

    bind(reg, builtin.scanlines, bindings.scanlines, "scanlines",
        &scanlinesTier0, scanlinesGlsl);
    bind(reg, builtin.phosphor, bindings.phosphor, "phosphor",
        &phosphorTier0, phosphorGlsl);
    bind(reg, builtin.dim, bindings.dim, "dim", &dimTier0, dimGlsl);
}

@("ui.effect.theme.rebindsABuiltinWithoutTheViewChanging")
@safe pure nothrow unittest
{
    EffectRegistry reg;
    const b = builtinEffects(reg);

    // Untouched by default: an all-default `ThemeEffects` is not an
    // instruction to clear everything.
    applyThemeEffects(reg, b, ThemeEffects.init);
    assert(reg.lookup(b.scanlines).name == "scanlines");
    assert(reg.tier0Of(b.dim) !is null);

    // Off: the id stays on the widget, and resolves to nothing.
    ThemeEffects off;
    off.scanlines = EffectBinding(bound: true, enabled: false);
    applyThemeEffects(reg, b, off);
    assert(reg.lookup(b.scanlines) is null, "rebound to nothing");
    assert(b.scanlines.valid, "the id itself is unchanged — no view moves");
    assert(reg.tier0Of(b.phosphor) !is null, "siblings are untouched");

    // Swapped: same id, different transform, and the GPU twin follows.
    ThemeEffects swap;
    swap.phosphor = EffectBinding(bound: true, tier0: &dimTier0,
        glsl: dimGlsl);
    applyThemeEffects(reg, b, swap);
    assert(reg.tier0Of(b.phosphor) is &dimTier0);
    assert(reg.lookup(b.phosphor).implFor(glslBackend).source == dimGlsl);

    // A swap that names only the CPU half keeps the built-in's GPU half, so
    // a partial binding cannot silently desynchronise the two.
    EffectRegistry reg2;
    const b2 = builtinEffects(reg2);
    ThemeEffects half;
    half.dim = EffectBinding(bound: true, tier0: &scanlinesTier0);
    applyThemeEffects(reg2, b2, half);
    assert(reg2.tier0Of(b2.dim) is &scanlinesTier0);
    assert(reg2.lookup(b2.dim).implFor(glslBackend).source == dimGlsl);
}

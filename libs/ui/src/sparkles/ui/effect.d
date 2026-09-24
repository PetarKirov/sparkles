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
import sparkles.shader : clamp, v2, v3, vec3, x, y, z;
import sparkles.ui.geometry : Point, Size;
import sparkles.ui.glsl_dialect : activePrologue;
static import sparkles.ui.effect_shaders;

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
the terminal and to SPIR-V — reachable. The built-ins are that function: a
transform from $(MREF sparkles,ui,effect_shaders) behind $(LREF tier0Fn),
which is how the same source the GPU runs is called here per cell.
*/
alias Tier0Fn = RgbColor function(in Tier0Input) @safe pure nothrow @nogc;

/**
Adapts a single-source transform to a $(LREF Tier0Fn) (`EFX20`).

`fn` is `vec3 fn(in vec2 at, in vec2 extent, in vec3 color)` — one of the
functions in $(MREF sparkles,ui,effect_shaders), or an application's own
written the same way. The adapter is the CPU's answer to what the fragment
shader's prologue does on the GPU: a byte colour becomes a colour in `[0, 1]`,
the cell position and the bracket's extent become the shader's `at` and
`extent`, and the result rounds back to bytes — the RGBA8 store the GPU
performs.
*/
RgbColor tier0Adapter(alias fn)(in Tier0Input i) @safe pure nothrow @nogc
{
    const c = fn(v2(i.at.x, i.at.y), v2(i.extent.width, i.extent.height),
        v3(i.color.r / 255.0f, i.color.g / 255.0f, i.color.b / 255.0f));
    return RgbColor(toByte(c.x), toByte(c.y), toByte(c.z));
}

/// ditto — as the function pointer a record stores.
enum Tier0Fn tier0Fn(alias fn) = &tier0Adapter!fn;

/// `[0, 1]` to a byte, rounding to nearest as an RGBA8 render target does.
private ubyte toByte(float v) @safe pure nothrow @nogc
    => cast(ubyte)(clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f);

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

$(B Why a string beside a D function, and why that is not duplication.) The
built-ins' GLSL is $(I generated) from the same D function the `tier0`
pointer calls (`EFX20`): `shader-compile` compiles
$(MREF sparkles,ui,effect_shaders) through LDC's Vulkan target to SPIR-V and
spirv-cross to the GLSL under `libs/ui/src/sparkles/ui/shaders/`, which this module
string-imports. Nothing here is written twice; the string is an artifact of
the function, the way an object file is.
*/
struct EffectImpl
{
    /// A key the toolkit only compares. $(LREF glslBackend) is the one both
    /// GL targets use.
    string backend;
    /// The artifact. For $(LREF glslBackend), a $(B complete) fragment shader
    /// against raylib's pipeline: `fragTexCoord`/`fragColor` in, `texture0`
    /// the rendered subtree, `finalColor` out, plus `uExtentCells` (the
    /// bracket's size in cells, for a tier-0 transform's `at`) and whatever
    /// $(LREF EffectParam)s the effect declares. Desktop GLSL 330, or ES 100
    /// on Android.
    ///
    /// Ignored when $(LREF passes) is non-empty.
    string source;

    /**
    A multi-pass artifact (tier 2), in order; empty for the one-pass case.

    Each pass is a complete fragment shader of its own. The last one
    composites into whatever the bracket sits on; every earlier one renders
    into an intermediate the backend owns. See $(LREF EffectPass) for how a
    pass names what it samples.
    */
    EffectPass[] passes;
}

/**
One pass of a multi-pass artifact — how a tier-2 effect is declared $(I as
data) (`EFX11`, `EFX21`).

The images a pass can read are numbered: `0` is the bracket's own rendering,
and `k` is what pass `k - 1` produced. A pass samples image $(LREF from) as
`texture0` — the quad it is drawn with — and each of $(LREF inputs) as
`texture1`, `texture2`, … in order. So bloom is four passes: extract `0` at
half size, blur that horizontally, blur that vertically, then composite
from `0` with image `3` as `texture1`.

The backend supplies, when a pass declares them: `uResolution` (this pass's
output size in pixels), `uExtentCells` (the bracket's size in cells) and
`uTime` (the frame clock, which a capture pins). Everything else is an
$(LREF EffectParam).
*/
struct EffectPass
{
    /// A complete fragment shader, as `EffectImpl.source`.
    string source;
    /// Output size as a divisor of the bracket's: `1` is full size, `2` half.
    /// Ignored for the last pass, which always draws at the bracket's size.
    ubyte downscale = 1;
    /// The image drawn as `texture0`. $(LREF previousImage) (the default)
    /// means the one just before this pass.
    ubyte from = previousImage;
    /// Further images, bound as `texture1` onward.
    ubyte[] inputs;
}

/// $(LREF EffectPass.from)'s default: whatever the previous pass produced
/// (the bracket itself, for the first pass).
enum ubyte previousImage = ubyte.max;

/**
One named scalar an effect reads at paint time (`EFX21`).

$(B Why a channel at all.) A tier-0 transform is a pure function and needs
nothing; a real tier-1 effect does — a curvature amount, a lens radius, a
pointer position that moves every frame. Without this an application could
only register a new shader to change a number.

$(B Backend-neutral by being dumb.) A name and up to four floats. The backend
that recognises the artifact also knows what the names mean; the toolkit
carries them and never reads one. Refresh them between frames with
$(REF EffectRegistry.setParams, sparkles,ui,effect) — the same window
`EFX18` makes safe for rebinding.
*/
struct EffectParam
{
    string name;        /// the uniform's name in the backend's artifact
    float[4] value = 0; /// up to four components
    ubyte arity = 1;    /// how many of them are meaningful (1..4)
}

/// The `EffectImpl.backend` key for a GLSL fragment target. The dialect is
/// the build's: a source registered under it is desktop GLSL, or ES on
/// Android — the generated built-ins come in both, and pick by `version`.
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

    /// Values the artifact reads at paint time (`EFX21`). Replaced wholesale
    /// by `setParams`, never mutated in place, so a frame either sees the old
    /// set or the new one.
    EffectParam[] params;

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

$(B Every registry starts with the built-ins) (`EFX15`), at the fixed ids
$(LREF Builtin) names, so an application can put `Builtin.scanlines` on a
widget without registering anything. They are still $(I registered), not
special-cased (`EFX19`): the first mutation seeds the registry by passing each
of $(LREF builtinRecords) through $(LREF register), and until then the `const`
view answers from that same table, computed at compile time. One definition,
one resolution path — no `final switch` on a built-in id anywhere.

$(B Why seeding is lazy.) A D struct has no default constructor, and a host
receives the registry as `const(EffectRegistry)*`: a registry the application
declared and never touched must still resolve every constant, and `lookup`
must stay `@nogc`. So an unseeded registry reads the compile-time table, and
the first `register`/`replace`/`setParams`/`remove` copies it in.
*/
struct EffectRegistry
{
    private EffectRecord[] _records;
    private bool _seeded;

@safe:

    /// Registers `record`, returning the id that addresses it. The first
    /// application-registered effect gets the id after the last $(LREF Builtin).
    EffectId register(EffectRecord record) pure nothrow
    {
        seed();
        return append(record);
    }

    /// ditto — the common case: a tier-0 transform under a name, optionally
    /// with the fragment shader a GPU target needs to run the same thing.
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
    void replace(EffectId id, EffectRecord record) pure nothrow
    {
        seed();
        if (auto slot = slotOf(id))
            *slot = record;
    }

    /**
    Replaces the values `id`'s artifact reads (`EFX21`), leaving everything
    else about the record alone.

    The per-frame call. It is separate from `replace` because changing a
    number and changing an effect are different events: one happens sixty
    times a second, the other when a shader is reloaded.
    */
    void setParams(EffectId id, EffectParam[] params) pure nothrow
    {
        seed();
        if (auto slot = slotOf(id))
            slot.params = params;
    }

    /// Forgets `id`'s record. The slot is kept, so the id is never reissued.
    void remove(EffectId id) pure nothrow
    {
        seed();
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
        const records = view;
        if (!id.valid || id.value > records.length)
            return null;
        const r = &records[id.value - 1];
        return r.name is null && r.tier0 is null ? null : r;
    }

    /// The tier-0 transform `id` resolves to, or `null` — the one question a
    /// cell backend asks.
    Tier0Fn tier0Of(EffectId id) const pure nothrow @nogc
    {
        const r = lookup(id);
        return r is null ? null : r.tier0;
    }

    /// How many ids have been issued (including removed ones, and the
    /// built-ins every registry starts with).
    size_t length() const pure nothrow @nogc => view.length;

    // What the registry holds: its own records once seeded, the compile-time
    // built-in table before.
    private const(EffectRecord)[] view() const pure nothrow @nogc return
        => _seeded ? _records : builtinTable[];

    // The one place the built-ins enter a registry: each goes through the
    // same append `register` uses, so their ids are the ones `Builtin` names.
    private void seed() pure nothrow
    {
        if (_seeded)
            return;
        _seeded = true;
        foreach (r; builtinRecords())
            append(r);
    }

    private EffectId append(EffectRecord record) pure nothrow
    {
        _records ~= record;
        return EffectId(cast(uint) _records.length);
    }

    private EffectRecord* slotOf(EffectId id) pure nothrow @nogc return
        => !id.valid || id.value > _records.length
            ? null : &_records[id.value - 1];
}

// ---------------------------------------------------------------------------
// The built-in set (`EFX15`).
// ---------------------------------------------------------------------------

/**
The built-in effects' ids (`EFX15`): constants, valid in every
$(LREF EffectRegistry) from the moment it is declared.

Four are tier 0, which is deliberate: the built-in set is the part of the
vocabulary every target can honour, so naming one costs an application nothing
on a terminal. `EFX24`'s claim — that a terminal showing scanlines and a
phosphor tint proves the tier split is real — is these. Each one is
$(B one function) in $(MREF sparkles,ui,effect_shaders): the terminal calls
it through $(LREF tier0Fn), and the GPU runs the GLSL `shader-compile`
generated from it (`EFX20`).

The values are the order $(LREF builtinRecords) lists them in, which a test
pins; appending is the only compatible change, since an id is never reused
(`EFX14`).
*/
enum Builtin : EffectId
{
    scanlines = EffectId(1), /// alternate rows darkened — a CRT's horizontal raster
    phosphor = EffectId(2),  /// tinted toward a monochrome phosphor's colour
    dim = EffectId(3),       /// uniformly darkened, for an inactive pane
    /// A 24-bit hue sweep across the bracket's COLUMNS, at each cell's own
    /// luminance. The built-in set's per-column member: `scanlines` varies
    /// down the rows and needs height to read, so a four-row panel shows it
    /// as barely anything — this one varies along the axis a panel always
    /// has, and puts a distinct truecolor value in every cell.
    spectrum = EffectId(4),
    /// Barrel distortion — $(B tier 1), so a cell grid cannot honour it and
    /// says so. The built-in set's proof that the tier boundary is real in
    /// both directions, and the shape `EFX21`'s CRT is built from.
    curvature = EffectId(5),
    /**
    A glow around whatever is bright — $(B tier 2), four passes over
    intermediates the backend owns (`EffectPass`). The built-in set's
    multi-pass member, and the half of the CRT a single pass could not
    express. A cell grid cannot sample a neighbourhood, so it paints the
    subtree unaffected and says so.
    */
    bloom = EffectId(6),
}

/**
The built-in records, in $(LREF Builtin)'s order — the single definition both
a seeded registry and an unseeded one's `const` view are made from.
*/
EffectRecord[] builtinRecords() @safe pure nothrow
{
    return [
        EffectRecord(name: "scanlines", tier: EffectTier.color,
            tier0: &scanlinesTier0, impls: [EffectImpl(glslBackend, scanlinesGlsl)]),
        EffectRecord(name: "phosphor", tier: EffectTier.color,
            tier0: &phosphorTier0, impls: [EffectImpl(glslBackend, phosphorGlsl)]),
        EffectRecord(name: "dim", tier: EffectTier.color,
            tier0: &dimTier0, impls: [EffectImpl(glslBackend, dimGlsl)]),
        EffectRecord(name: "spectrum", tier: EffectTier.color,
            tier0: &spectrumTier0, impls: [EffectImpl(glslBackend, spectrumGlsl)]),
        EffectRecord(
            name: "curvature",
            tier: EffectTier.distortion,
            // No tier-0 transform: warping position is not something a cell
            // grid can approximate, and claiming otherwise is what `EFX12`
            // exists to stop. A terminal states the degradation instead.
            degradation: Degradation.unaffected,
            impls: [EffectImpl(glslBackend, curvatureGlsl)],
            params: [EffectParam("uAmount", [0.18f, 0, 0, 0], 1)],
        ),
        EffectRecord(
            name: "bloom",
            tier: EffectTier.layer,
            degradation: Degradation.unaffected,
            impls: [EffectImpl(glslBackend, passes: bloomPasses)],
            // The CRT's defaults (`CRT3`).
            params: [
                EffectParam("uBloomThreshold", [0.65f, 0, 0, 0], 1),
                EffectParam("uBloomRadius", [2.0f, 0, 0, 0], 1),
                EffectParam("uBloomIntensity", [0.35f, 0, 0, 0], 1),
            ],
        ),
    ];
}

/**
The `bloom` built-in's four passes: extract the bright part at half size,
blur it horizontally, then vertically, then add it back over the bracket.

Hand-written GLSL (`shaders/tier2/bloom.frag`), one body compiled four ways by
a `BLOOM_PASS` define. Public because a larger tier-2 effect — the CRT —
reuses them as its own first three passes rather than keeping a second copy.
*/
EffectPass[] bloomPasses() @safe pure nothrow
{
    return [
        EffectPass(bloomPassSource!0, downscale: 2, from: 0),
        EffectPass(bloomPassSource!1, downscale: 2),
        EffectPass(bloomPassSource!2, downscale: 2),
        EffectPass(bloomPassSource!3, from: 0, inputs: [3]),
    ];
}

/// One pass of `bloom`, in this build's GLSL dialect.
enum string bloomPassSource(int pass) = activePrologue
    ~ "#define BLOOM_PASS " ~ cast(char)('0' + pass) ~ "\n"
    ~ import("tier2/bloom.frag");

// The unseeded registry's view: the same records, evaluated at compile time.
private static immutable EffectRecord[] builtinTable = builtinRecords();

// `Builtin`'s values ARE positions in that table; a reordering fails here
// rather than silently renaming every effect on screen.
static foreach (m; __traits(allMembers, Builtin))
    static assert(builtinTable[__traits(getMember, Builtin, m).value - 1].name == m,
        "Builtin." ~ m ~ " does not name the record at its position");
static assert(builtinTable.length == __traits(allMembers, Builtin).length);

/// The built-ins' tier-0 transforms, as the cell grid calls them: each is
/// $(LREF tier0Adapter) over the one function in
/// $(MREF sparkles,ui,effect_shaders) that the GPU also runs.
alias scanlinesTier0 = tier0Adapter!(sparkles.ui.effect_shaders.scanlines);
/// ditto
alias phosphorTier0 = tier0Adapter!(sparkles.ui.effect_shaders.phosphor);
/// ditto
alias dimTier0 = tier0Adapter!(sparkles.ui.effect_shaders.dim);
/// ditto
alias spectrumTier0 = tier0Adapter!(sparkles.ui.effect_shaders.spectrum);

// The generated fragment shaders (`libs/ui/src/sparkles/ui/shaders/`), in the
// dialect this build's GL speaks. Regenerate with `nix run .#shader-compile`;
// `--verify` is the guard that they still come from the D source.
version (Android)
    private enum string glslDialect = ".es.frag";
else
    private enum string glslDialect = ".frag";

/// The built-ins' fragment shaders, generated from their D transforms.
enum string scanlinesGlsl = import("scanlines" ~ glslDialect);
/// ditto
enum string phosphorGlsl = import("phosphor" ~ glslDialect);
/// ditto
enum string dimGlsl = import("dim" ~ glslDialect);
/// ditto
enum string spectrumGlsl = import("spectrum" ~ glslDialect);
/// ditto — the tier-1 warp, sampling at what `effect_shaders.curvature` returns.
enum string curvatureGlsl = import("curvature" ~ glslDialect);

@("ui.effect.builtins.eachCarriesBothHalvesOfItsTwin")
@safe pure nothrow unittest
{
    // `EFX13`: every built-in must ship the GPU artifact beside the D
    // function, or the GPU target silently degrades on an effect the
    // terminal honours — which is the inversion this gate exists to end.
    EffectRegistry reg;
    alias b = Builtin;
    foreach (EffectId id; [b.scanlines, b.phosphor, b.dim, b.spectrum])
    {
        const rec = reg.lookup(id);
        assert(rec.tier0 !is null, "the CPU half");
        const impl = rec.implFor(glslBackend);
        assert(impl !is null, "the GPU half");
        // A complete shader against raylib's interface, generated from the
        // same function `tier0` points at — `shader-compile --verify` is what
        // proves the "same function" part; this proves it is the whole shader.
        assert(impl.source.canFind("#version"), "a complete shader, not a body");
        assert(impl.source.canFind("void main()"));
        assert(impl.source.canFind("texture0") && impl.source.canFind("fragTexCoord"));
    }
    // A transform that reads its position needs the bracket's extent; one
    // that does not (phosphor, dim) has it optimised away, and the backend
    // treats the missing uniform as exactly that.
    assert(reg.lookup(b.scanlines).implFor(glslBackend).source.canFind("uExtentCells"));
    assert(reg.lookup(b.spectrum).implFor(glslBackend).source.canFind("uExtentCells"));
    assert(reg.lookup(b.curvature).implFor(glslBackend).source.canFind("uAmount"),
        "the tier-1 shader reads its EffectParam");
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

    alias b = Builtin;
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

@("ui.effect.builtins.areConstantsInEveryRegistry")
@safe pure nothrow unittest
{
    // `EFX15`: a registry nobody has touched — reached only through the
    // `const` pointer a host receives — already resolves every built-in.
    EffectRegistry fresh;
    const(EffectRegistry)* view = &fresh;
    static foreach (m; __traits(allMembers, Builtin))
        assert(view.lookup(__traits(getMember, Builtin, m)).name == m);
    assert(view.tier0Of(Builtin.dim) is &dimTier0);
    assert(view.lookup(Builtin.curvature).tier == EffectTier.distortion);
    assert(view.length == __traits(allMembers, Builtin).length);

    // ... and it is the same registry after the first mutation: seeding goes
    // through `register`, so the ids do not move and an application's first
    // effect lands after the last built-in.
    const mine = fresh.registerTier0("mine", &dimTier0);
    assert(mine.value == __traits(allMembers, Builtin).length + 1);
    assert(fresh.lookup(Builtin.scanlines).name == "scanlines");
    assert(fresh.lookup(mine).name == "mine");

    // A built-in is mutable like any record — rebinding is how a theme turns
    // one off (`EFX16`) — and removing one keeps its id dead (`EFX14`).
    fresh.remove(Builtin.phosphor);
    assert(fresh.lookup(Builtin.phosphor) is null);
    EffectRegistry other;
    assert(other.lookup(Builtin.phosphor) !is null,
        "one registry's rebinding is not another's");
}

@("ui.effect.bloom.isAMultiPassTier2Effect")
@safe pure nothrow unittest
{
    EffectRegistry reg;
    const rec = reg.lookup(Builtin.bloom);
    assert(rec.tier == EffectTier.layer);
    // `EFX9`/`EFX12`: a neighbourhood is not something a cell samples, so
    // there is no transform to run and the degradation says so.
    assert(!rec.honouredByCells && rec.degradation == Degradation.unaffected);

    const impl = rec.implFor(glslBackend);
    assert(impl.source is null && impl.passes.length == 4);
    // The chain as data: half-size extract from the bracket, two blurs of
    // what came before, and a full-size composite of the bracket with the
    // blurred glow as `texture1`.
    assert(impl.passes[0].from == 0 && impl.passes[0].downscale == 2);
    assert(impl.passes[1].from == previousImage && impl.passes[2].downscale == 2);
    assert(impl.passes[3].from == 0 && impl.passes[3].inputs == [3]);
    foreach (i, ref p; impl.passes)
    {
        assert(p.source.canFind("#version"), "each pass is a complete shader");
        assert(p.source.canFind("BLOOM_PASS"));
    }
    assert(impl.passes[3].source.canFind("uBloomIntensity"));
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
    // and green dominates in both. White is the pinned case: full luma,
    // tinted (0.30, 1, 0.45), rounded as an RGBA8 target rounds.
    const bright = phosphorTier0(Tier0Input(Point(0, 0), extent, white));
    assert(bright == RgbColor(77, 255, 115));
    const dark = phosphorTier0(Tier0Input(Point(0, 0), extent, RgbColor(40, 40, 40)));
    assert(bright.g > dark.g, "luminance survives the tint");
    assert(bright.g > bright.r && bright.g > bright.b, "green dominates");

    // Blue text must not vanish — the reason this is luma and not an average.
    const blue = phosphorTier0(Tier0Input(Point(0, 0), extent, RgbColor(0, 0, 255)));
    assert(blue.g > 0);

    // `dim` is uniform: position cannot change it.
    assert(dimTier0(Tier0Input(Point(0, 0), extent, white))
        == dimTier0(Tier0Input(Point(7, 3), extent, white)));
    assert(dimTier0(Tier0Input(Point(0, 0), extent, white)) == RgbColor(140, 140, 140));

    // Saturating, not wrapping — the failure mode of integer colour maths.
    const black = RgbColor(0, 0, 0);
    assert(dimTier0(Tier0Input(Point(0, 1), extent, black)) == black);
    assert(scanlinesTier0(Tier0Input(Point(0, 1), extent, black)) == black);
}

@("ui.effect.spectrum.variesAcrossColumnsAndKeepsLuminance")
@safe pure nothrow @nogc unittest
{
    const extent = Size(24, 4);
    const white = RgbColor(255, 255, 255);

    // The point of the effect: neighbouring COLUMNS differ, and a whole
    // column is one colour whatever row it is on. `scanlines` is the mirror
    // of this, and a four-row panel is why both exist.
    const a = spectrumTier0(Tier0Input(Point(0, 0), extent, white));
    const b = spectrumTier0(Tier0Input(Point(1, 0), extent, white));
    assert(a != b, "adjacent columns differ");
    assert(a == spectrumTier0(Tier0Input(Point(0, 3), extent, white)),
        "the row cannot change it");

    // A sweep, not a repeat: 24 columns land on 24 distinct truecolor values.
    RgbColor[24] seen;
    foreach (x; 0 .. 24)
    {
        seen[x] = spectrumTier0(Tier0Input(Point(x, 0), extent, white));
        foreach (y; 0 .. x)
            assert(seen[y] != seen[x], "a distinct 24-bit colour per column");
    }

    // Luminance survives: a dim cell stays dim at the same hue position.
    const dimmed = spectrumTier0(Tier0Input(Point(5, 0), extent, RgbColor(40, 40, 40)));
    const bright = spectrumTier0(Tier0Input(Point(5, 0), extent, white));
    assert(dimmed.r <= bright.r && dimmed.g <= bright.g && dimmed.b <= bright.b);
    assert(bright.r + bright.g + bright.b > dimmed.r + dimmed.g + dimmed.b);

    // Black stays black, and a degenerate extent cannot divide by zero.
    const black = RgbColor(0, 0, 0);
    assert(spectrumTier0(Tier0Input(Point(3, 0), extent, black)) == black);
    assert(spectrumTier0(Tier0Input(Point(9, 0), Size(0, 0), white)).r == 255);
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
    EffectBinding spectrum;  ///
}

/**
Applies `bindings` to `reg`'s built-ins (`EFX16`).

Idempotent against the original set: it rebinds each $(LREF Builtin) id from
the built-in's own transform, so calling it again with different bindings does
not compound. An application
calls it when the theme changes, between frames — which is exactly the window
`EFX18` says a rebind is safe in.
*/
// `bindings` is taken by VALUE, not `in`. Under `-preview=in` it would be
// `scope const`, and a binding's `tier0`/`glsl` then cannot be stored into the
// registry at all — the documented dip1000 clash, relaxed on exactly the
// parameter that needs it rather than on the function's safety.
void applyThemeEffects(ref EffectRegistry reg, ThemeEffects bindings)
    @safe pure nothrow
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

    bind(reg, Builtin.scanlines, bindings.scanlines, "scanlines",
        &scanlinesTier0, scanlinesGlsl);
    bind(reg, Builtin.phosphor, bindings.phosphor, "phosphor",
        &phosphorTier0, phosphorGlsl);
    bind(reg, Builtin.dim, bindings.dim, "dim", &dimTier0, dimGlsl);
    bind(reg, Builtin.spectrum, bindings.spectrum, "spectrum",
        &spectrumTier0, spectrumGlsl);
}

@("ui.effect.theme.rebindsABuiltinWithoutTheViewChanging")
@safe pure nothrow unittest
{
    EffectRegistry reg;
    alias b = Builtin;

    // Untouched by default: an all-default `ThemeEffects` is not an
    // instruction to clear everything.
    applyThemeEffects(reg, ThemeEffects.init);
    assert(reg.lookup(b.scanlines).name == "scanlines");
    assert(reg.tier0Of(b.dim) !is null);

    // Off: the id stays on the widget, and resolves to nothing.
    ThemeEffects off;
    off.scanlines = EffectBinding(bound: true, enabled: false);
    applyThemeEffects(reg, off);
    assert(reg.lookup(b.scanlines) is null, "rebound to nothing");
    assert(b.scanlines.valid, "the id itself is unchanged — no view moves");
    assert(reg.tier0Of(b.phosphor) !is null, "siblings are untouched");

    // Swapped: same id, different transform, and the GPU twin follows.
    ThemeEffects swap;
    swap.phosphor = EffectBinding(bound: true, tier0: &dimTier0,
        glsl: dimGlsl);
    applyThemeEffects(reg, swap);
    assert(reg.tier0Of(b.phosphor) is &dimTier0);
    assert(reg.lookup(b.phosphor).implFor(glslBackend).source == dimGlsl);

    // A swap that names only the CPU half keeps the built-in's GPU half, so
    // a partial binding cannot silently desynchronise the two.
    EffectRegistry reg2;
    alias b2 = Builtin;
    ThemeEffects half;
    half.dim = EffectBinding(bound: true, tier0: &scanlinesTier0);
    applyThemeEffects(reg2, half);
    assert(reg2.tier0Of(b2.dim) is &scanlinesTier0);
    assert(reg2.lookup(b2.dim).implFor(glslBackend).source == dimGlsl);
}

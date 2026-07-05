/**
Portable operation vocabulary: typed op descriptors and the `user_data`
token discipline (SPEC §4). This module is portable — it imports no backend
and never sees an SQE; backend-specific lowering lives in
`sparkles.event_horizon.backend.*`.

The M2 surface covers the token machinery and the buffer-less descriptors;
buffer-carrying descriptors and the op-slot slab land with the callback tier
(M3).
*/
module sparkles.event_horizon.op;

import sparkles.event_horizon.errors : OpKind;

/// What kind of slot a completion routes to (packed into the token's top
/// byte). Internal classes let the loop consume its own completions (timers,
/// waker, cancel bookkeeping) without heap contexts.
enum OpClass : ubyte
{
    user,     /// a user-submitted op
    timer,    /// loop-internal timer
    wake,     /// loop-internal waker op
    internal, /// other loop-internal bookkeeping (e.g. cancel CQEs)
}

/**
ABA-safe packed `user_data`: `| class:8 | generation:24 | index:32 |`.

`raw == 0` is reserved invalid — a default `OpToken` never matches a live
slot (slot 0 starts at generation 1).
*/
struct OpToken
{
    ulong raw;

    @safe pure nothrow @nogc const:

    /// Slot index within the op slab.
    uint index() => cast(uint) raw;

    /// Generation counter; must match the slot's to resolve.
    uint generation() => cast(uint) ((raw >> 32) & 0xFF_FFFF);

    /// Which completion route this token takes.
    OpClass cls() => cast(OpClass) (raw >> 56);

    /// `false` for the reserved invalid token.
    bool opCast(T : bool)() => raw != 0;

    /// Packs the three fields; the generation is masked to its 24 bits.
    static OpToken pack(uint index, uint generation, OpClass cls) @safe pure nothrow @nogc
        => OpToken((ulong(cls) << 56) | (ulong(generation & 0xFF_FFFF) << 32) | index);
}

/// Public, copyable reference to an in-flight op — the target of
/// cancellation and detach (SPEC §4.2, §5.1).
struct OpHandle
{
    package OpToken token;

    /// `false` for a default (never-submitted) handle.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => cast(bool) token;
}

/// `__kernel_timespec` mirror — library-owned so peer backends satisfy the
/// concept without importing `during` (SPEC §4.1).
struct KernelTimespec
{
    long tv_sec;  /// seconds
    long tv_nsec; /// nanoseconds
}

/// The no-op descriptor: a pure submit/complete round-trip.
struct OpNop
{
    /// The portable kind every descriptor names (SPEC §4.1).
    enum kind = OpKind.nop;
}

/// DbI trait: exactly what submission accepts — any struct naming its
/// portable `OpKind`.
enum bool isOpDesc(Op) = __traits(compiles, { enum OpKind k = Op.kind; });

static assert(isOpDesc!OpNop);
static assert(!isOpDesc!int);

@("op.OpToken.packRoundTrip")
@safe pure nothrow @nogc
unittest
{
    const t = OpToken.pack(7, 0xABCDEF, OpClass.timer);
    assert(t.index == 7);
    assert(t.generation == 0xABCDEF);
    assert(t.cls == OpClass.timer);
    assert(t);
}

@("op.OpToken.generationMask")
@safe pure nothrow @nogc
unittest
{
    // Generations wrap at 24 bits; the class byte must survive untouched.
    const t = OpToken.pack(uint.max, 0x1FF_FFFF, OpClass.internal);
    assert(t.index == uint.max);
    assert(t.generation == 0xFF_FFFF);
    assert(t.cls == OpClass.internal);
}

@("op.OpToken.invalidDefault")
@safe pure nothrow @nogc
unittest
{
    OpToken zero;
    assert(!zero);

    OpHandle none;
    assert(!none);
}

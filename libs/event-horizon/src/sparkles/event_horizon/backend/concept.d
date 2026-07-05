/**
The DbI completion-backend concept (SPEC §3.1). A backend is a struct
satisfying `isCompletionBackend!B` — capability traits, no interface, no
vtable: the loop is `EventLoop!Backend`, submission lowering is a statically
dispatched overload set, and the whole submit path inlines.

The concept is defined by completion $(I semantics), not by `io_uring`: a
backend that synthesizes completion over readiness (kqueue) must still
deliver `(userData, res, flags)` triples where `res` is a byte count / fd or
`-errno`.
*/
module sparkles.event_horizon.backend.concept;

import std.traits : lvalueOf;

import sparkles.event_horizon.errors : IoResult, OpKind;
import sparkles.event_horizon.op : KernelTimespec, OpNop, OpSlot, OpToken;

/// What the backend hands the loop per completion — the raw
/// `(user_data, res, flags)` triple; the loop resolves the token and builds
/// the typed `Completion`.
struct RawCompletion
{
    ulong userData; /// the submitted `OpToken.raw`
    int res;        /// `>= 0` payload or `-errno`
    uint rawFlags;  /// backend-native completion flags
}

/// Backend-level configuration (the loop's `LoopConfig` embeds this).
struct BackendConfig
{
    uint sqEntries = 256; /// submission-queue entries (rounded to a power of two)
    uint cqEntries = 0;   /// completion-queue entries; 0 = backend default (uring: 2× sq)
    ubyte mode;           /// requested `LoopMode` (kept `ubyte` to stay leaf-friendly)
    ubyte modePolicy;     /// `ModePolicy` for mode negotiation
}

/**
Per-descriptor submission capability; the backend owns the lowering and
receives the op's slot (`ref OpSlot`) — the loop has already moved owned
buffers into `slot.pinned` and kernel-stable operands into `slot.operands`,
so the SQE points only at slot-stable memory (SPEC §4.1).

The probe passes an rvalue op: descriptors carrying an owned buffer are
move-only, so submission moves the op — an lvalue probe would statically
reject every buffer-carrying op (SPEC §3.1).
*/
enum bool canSubmitOp(B, Op) = __traits(compiles, {
    bool r = lvalueOf!B.trySubmit(Op.init, OpToken.init, lvalueOf!OpSlot);
});

/**
Required backend primitives — checked as the exact expressions the loop
calls (DbI guidelines §4.3). All must infer `nothrow @nogc` for the uring
backend; the unittests static-assert that.
*/
enum bool isCompletionBackend(B) = __traits(compiles, {
    BackendConfig cfg;
    IoResult!void o = lvalueOf!B.open(cfg);
    auto caps = lvalueOf!B.caps();
    bool queued = lvalueOf!B.trySubmit(OpNop(), OpToken.init, lvalueOf!OpSlot); // false = SQ full
    IoResult!uint f = lvalueOf!B.flush();
    IoResult!uint w = lvalueOf!B.submitAndWait(1u, cast(const(KernelTimespec)*) null);
    uint n = lvalueOf!B.reap((ref const RawCompletion c) {});  // non-blocking drain
    lvalueOf!B.close();
}) && canSubmitOp!(B, OpNop);

// Optional capabilities (SPEC §3.1) — absence degrades, never breaks. The
// remaining traits (hasRegisteredBuffers, hasBufRing, hasNativeCancel,
// hasNativeTimeout, hasMsgRing, hasDirectFds) land with the features that
// consume them (M3+); defining them before any generic code dispatches on
// them would leave them untested.

/// Multishot support is runtime-caps-backed; the trait gates the call shape.
enum bool hasMultishot(B) = __traits(compiles, {
    bool r = lvalueOf!B.supportsMultishot(OpKind.init);
});

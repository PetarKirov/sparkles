/**
 * Constant-time byte-buffer comparisons.
 *
 * The crypto code compares secret-derived bytes — MAC tags, derived keys,
 * authentication results — against attacker-influenced values. A naive
 * `a == b` short-circuits on the first differing byte, leaking via timing
 * how many leading bytes matched. The primitives here instead fold every
 * byte of the inputs into a single accumulator and compare that to zero
 * exactly once, so the running time depends only on the input *lengths*,
 * not on their contents.
 *
 * Length is treated as public: `ctEquals` returns `false` immediately when
 * the two slices differ in length (a length mismatch is not secret in the
 * age protocol — tag and key sizes are fixed and known). When the lengths
 * match, no data-dependent branch is taken.
 *
 * An optimization barrier (a volatile round-trip of the accumulator) stops
 * the compiler from recovering the short-circuit it would otherwise be free
 * to synthesize. Because that barrier is a deliberate, compiler-visible
 * side effect, these functions are `@safe nothrow @nogc` but **not** `pure`.
 *
 * Modeled on libsodium's `sodium_memcmp` / `sodium_is_zero`; the backend MAY
 * route through those when present, but this pure-D implementation is the
 * dependency-free default (§3.3).
 */
module sparkles.crypto.ct;

import core.volatile : volatileLoad, volatileStore;

@safe nothrow @nogc:

/**
 * Returns `true` iff `a` and `b` are byte-for-byte equal, in time that
 * depends only on the slice lengths and never on their contents.
 *
 * Slices of differing length compare unequal (length is public). For equal
 * lengths every byte pair is XOR-ed and OR-folded into one accumulator with
 * no early exit, then compared to zero a single time behind an optimization
 * barrier so the compiler cannot reintroduce a content-dependent branch.
 *
 * Params:
 *   a = first byte slice
 *   b = second byte slice
 * Returns: `true` if equal length and equal contents, else `false`.
 */
bool ctEquals(scope const(ubyte)[] a, scope const(ubyte)[] b)
{
    // Length is not secret; comparing it directly is fine and avoids
    // reading out of bounds. Bail before the fold on a mismatch.
    if (a.length != b.length)
        return false;

    ubyte acc = 0;
    foreach (i; 0 .. a.length)
        acc |= cast(ubyte)(a[i] ^ b[i]);

    return barrierIsZero(acc);
}

///
@("crypto.ct.ctEquals.equal")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[4] x = [1, 2, 3, 4];
    static immutable ubyte[4] y = [1, 2, 3, 4];
    assert(ctEquals(x[], y[]));
    assert(ctEquals(null, null));      // two empty slices are equal
    assert(ctEquals(x[0 .. 0], y[0 .. 0]));
}

@("crypto.ct.ctEquals.unequal.sameLength")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[4] x = [1, 2, 3, 4];
    // Difference in the last byte must be caught (no early-out before it).
    static immutable ubyte[4] lastByte = [1, 2, 3, 5];
    // Difference in the first byte must be caught too.
    static immutable ubyte[4] firstByte = [9, 2, 3, 4];
    assert(!ctEquals(x[], lastByte[]));
    assert(!ctEquals(x[], firstByte[]));
}

@("crypto.ct.ctEquals.lengthMismatch")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[4] x = [1, 2, 3, 4];
    static immutable ubyte[3] shorter = [1, 2, 3];
    assert(!ctEquals(x[], shorter[]));
    assert(!ctEquals(shorter[], x[]));
    assert(!ctEquals(x[], null));      // one empty, one not
}

/**
 * Returns `true` iff every byte of `a` is zero, in time that depends only on
 * the slice length. An empty slice is vacuously all-zero (returns `true`).
 *
 * Used for the X25519 contributory-behaviour check, where an all-zero shared
 * secret must be rejected without leaking, via timing, where the first
 * non-zero byte sits (§9.1).
 *
 * Params:
 *   a = byte slice to test
 * Returns: `true` if `a` is empty or all bytes are zero, else `false`.
 */
bool ctIsZero(scope const(ubyte)[] a)
{
    ubyte acc = 0;
    foreach (i; 0 .. a.length)
        acc |= a[i];

    return barrierIsZero(acc);
}

///
@("crypto.ct.ctIsZero.allZero")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[8] zeros = [0, 0, 0, 0, 0, 0, 0, 0];
    assert(ctIsZero(zeros[]));
    assert(ctIsZero(null));            // empty is vacuously all-zero
    assert(ctIsZero(zeros[0 .. 0]));
}

@("crypto.ct.ctIsZero.nonZero")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[8] trailing = [0, 0, 0, 0, 0, 0, 0, 1];
    static immutable ubyte[8] leading = [1, 0, 0, 0, 0, 0, 0, 0];
    assert(!ctIsZero(trailing[]));
    assert(!ctIsZero(leading[]));
}

/**
 * Optimization barrier: returns `acc == 0` after forcing `acc` through a
 * volatile round-trip, so the optimizer cannot fold the surrounding fold
 * loop into a content-dependent early-out.
 *
 * `volatileStore`/`volatileLoad` are observable side effects, so this is not
 * `pure`; the `@trusted` scope is the single-byte stack round-trip and is
 * obviously memory-safe.
 */
private bool barrierIsZero(ubyte acc) @trusted nothrow @nogc
{
    volatileStore(&acc, acc);
    return volatileLoad(&acc) == 0;
}

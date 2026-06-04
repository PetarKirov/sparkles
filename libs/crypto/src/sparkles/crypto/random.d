/**
 * Cryptographically-secure random bytes from the OS CSPRNG.
 *
 * This module exposes the backend's CSPRNG as backend-templated free
 * functions, following the same `B = DefaultBackend` pattern as the other
 * primitives (§4.1). The work is delegated to `B.randomBytes`, gated on
 * $(REF hasCsprng, sparkles,crypto,backend,traits).
 *
 * $(B Purity.) `randomBytes` is the $(I only) primitive that is not `pure`:
 * every call draws fresh entropy from the operating system, so two calls with
 * identical arguments do not return identical results. It keeps `@safe nothrow
 * @nogc` — libsodium's `randombytes_buf` neither allocates nor throws — but
 * deliberately drops `pure`. The deterministic primitives (`sha256`, `x25519`,
 * …) are also not modelled as `pure` because they share libsodium's attribute
 * set, but `randomBytes` is the one whose impurity is semantically essential.
 *
 * See `docs/specs/age/SPEC.md` §6 (primitives) for the normative description.
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.random;

import sparkles.crypto.backend : DefaultBackend, hasCsprng, isCryptoBackend;

@safe nothrow @nogc:

/**
 * Fill `buf` with cryptographically-secure random bytes from the OS CSPRNG.
 *
 * A zero-length `buf` is a no-op. This function is $(B not) `pure`: each call
 * produces independent, unpredictable output.
 *
 * Params:
 *   B   = the crypto backend (defaults to $(REF DefaultBackend,
 *         sparkles,crypto,backend)); must provide a CSPRNG
 *   buf = destination slice, filled in full
 */
void randomBytes(B = DefaultBackend)(scope ubyte[] buf)
if (isCryptoBackend!B && hasCsprng!B)
{
    B.randomBytes(buf);
}

/// Filling a buffer twice yields differing, non-zero output (probabilistically).
@("crypto.random.randomBytes")
@safe nothrow @nogc
unittest
{
    ubyte[32] first = 0;
    ubyte[32] second = 0;
    randomBytes(first[]);
    randomBytes(second[]);

    ubyte[32] allZero = 0;
    assert(first != allZero);
    assert(second != allZero);
    assert(first != second);

    // A zero-length request must not crash.
    randomBytes(null);
}

/**
 * Return a fresh `ubyte[N]` filled with cryptographically-secure random bytes.
 *
 * A convenience over $(LREF randomBytes) for the common case of a fixed-size
 * key, nonce, or salt. Like `randomBytes`, this is $(B not) `pure`.
 *
 * Params:
 *   N = number of random bytes to produce
 *   B = the crypto backend (defaults to $(REF DefaultBackend,
 *       sparkles,crypto,backend)); must provide a CSPRNG
 * Returns: an `N`-byte array of fresh random bytes.
 */
ubyte[N] randomArray(size_t N, B = DefaultBackend)()
if (isCryptoBackend!B && hasCsprng!B)
{
    ubyte[N] out_ = void;
    randomBytes!B(out_[]);
    return out_;
}

/// A 32-byte draw is non-zero and two draws differ (probabilistically).
@("crypto.random.randomArray")
@safe nothrow @nogc
unittest
{
    auto first = randomArray!32();
    auto second = randomArray!32();

    ubyte[32] allZero = 0;
    assert(first != allZero);
    assert(second != allZero);
    assert(first != second);

    // A zero-length array is the empty array.
    auto none = randomArray!0();
    assert(none.length == 0);
}

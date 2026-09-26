/**
 * X25519 Diffie-Hellman primitives (§6).
 *
 * Backend-templated free-function wrappers over a crypto backend's X25519
 * scalar multiplication. Both functions default to
 * $(REF DefaultBackend, sparkles,crypto,backend) (libsodium) and are
 * constrained on $(REF hasX25519, sparkles,crypto,backend,traits), so a partial
 * backend that lacks X25519 is rejected at compile time rather than silently
 * mis-dispatched.
 *
 * X25519 is the elliptic-curve Diffie-Hellman function over Curve25519 defined
 * by [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748). $(LREF x25519)
 * computes a shared point `scalar · point`; $(LREF x25519Base) computes the
 * fixed-base multiple `scalar · basepoint` to derive a public key from a secret
 * scalar.
 *
 * $(B Contributory behaviour.) $(LREF x25519) returns `false` when the result
 * is the all-zero point. That happens for low-order input points (e.g. the
 * all-zero point), and an all-zero shared secret carries no contribution from
 * `scalar` — accepting it would let a malicious peer force a known shared
 * secret. age requires this check, so callers MUST treat a `false` return as a
 * hard failure and discard `outShared`.
 *
 * The functions here are thin wrappers; the `@trusted` libsodium calls live in
 * $(REF SodiumBackend, sparkles,crypto,backend,sodium). They are
 * `@safe nothrow @nogc` but $(B not) `pure` (the backend is not modelled as
 * pure). They operate on plain fixed-size `ubyte[32]` arrays; wrapping scalars
 * in secret-memory types is the age layer's job.
 *
 * See `docs/specs/age/SPEC.md` §6 (primitives) for the normative description.
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.x25519;

import sparkles.crypto.backend : DefaultBackend, hasX25519, isCryptoBackend;

@safe nothrow @nogc:

/**
 * X25519 Diffie-Hellman: `outShared = scalar · point`.
 *
 * Multiplies the peer public point by the secret scalar to obtain the shared
 * secret. The result is rejected (and `false` returned) when it is the all-zero
 * point — see the module-level note on contributory behaviour.
 *
 * Params:
 *   B         = the crypto backend (defaults to libsodium)
 *   scalar    = 32-byte secret scalar
 *   point     = 32-byte peer public point
 *   outShared = 32-byte output shared secret; undefined when `false` is returned
 * Returns: `true` on success, `false` if the shared secret is the all-zero
 *   (non-contributory) point.
 */
bool x25519(B = DefaultBackend)(in ubyte[32] scalar, in ubyte[32] point,
    ref ubyte[32] outShared)
if (isCryptoBackend!B && hasX25519!B)
    => B.x25519(scalar, point, outShared);

/**
 * X25519 fixed-base scalar multiplication: `outPublic = scalar · basepoint`.
 *
 * Derives the X25519 public key for a secret `scalar`. The base point is never
 * low-order, so this always succeeds and returns nothing.
 *
 * Params:
 *   B         = the crypto backend (defaults to libsodium)
 *   scalar    = 32-byte secret scalar
 *   outPublic = 32-byte output public key
 */
void x25519Base(B = DefaultBackend)(in ubyte[32] scalar, ref ubyte[32] outPublic)
if (isCryptoBackend!B && hasX25519!B)
    => B.x25519Base(scalar, outPublic);

// ─────────────────────────────────────────────────────────────────────────
// Tests — known-answer vectors from RFC 7748, plus the Diffie-Hellman
// agreement property and the contributory (low-order point) check.
//
// Hex literals are decoded with sparkles.crypto.encoding.hex.decodeHex into
// stack buffers so the tests stay allocation-free.
// ─────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.crypto.encoding.hex : decodeHex;

    /// Decode a compile-time-known hex string into a fixed `ubyte[N]`,
    /// asserting it decodes cleanly. `N` is the expected byte length.
    private ubyte[N] fromHex(size_t N)(scope const(char)[] s) @safe nothrow @nogc
    in (s.length == N * 2, "fromHex: hex length does not match N")
    {
        ubyte[N] out_ = void;
        auto r = decodeHex(s, out_[]);
        assert(r.hasValue, "fromHex: invalid hex literal");
        assert(r.value.length == N, "fromHex: decoded length mismatch");
        return out_;
    }
}

/// `x25519` matches the RFC 7748 §5.2 first X25519 test vector
/// (scalar, u-coordinate → output u-coordinate), via the default backend.
@("crypto.x25519.rfc7748")
@safe nothrow @nogc
unittest
{
    const scalar = fromHex!32(
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4");
    const point = fromHex!32(
        "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c");

    ubyte[32] shared_ = void;
    assert(x25519(scalar, point, shared_));

    const expected = fromHex!32(
        "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552");
    assert(shared_ == expected);
}

/// `x25519Base` matches the RFC 7748 §6.1 worked Diffie-Hellman example:
/// Alice's and Bob's public keys are the base-point multiples of their private
/// keys, and the two sides agree on the same shared secret `K`.
@("crypto.x25519.rfc7748.dh")
@safe nothrow @nogc
unittest
{
    const alicePriv = fromHex!32(
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    const alicePubExpected = fromHex!32(
        "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    const bobPriv = fromHex!32(
        "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    const bobPubExpected = fromHex!32(
        "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    const sharedExpected = fromHex!32(
        "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");

    // Derive both public keys from the private keys.
    ubyte[32] alicePub = void, bobPub = void;
    x25519Base(alicePriv, alicePub);
    x25519Base(bobPriv, bobPub);
    assert(alicePub == alicePubExpected);
    assert(bobPub == bobPubExpected);

    // Each side multiplies its own private key by the peer's public key; the
    // exchange must agree and equal the published shared secret K.
    ubyte[32] sharedAB = void, sharedBA = void;
    assert(x25519(alicePriv, bobPub, sharedAB));
    assert(x25519(bobPriv, alicePub, sharedBA));
    assert(sharedAB == sharedBA);
    assert(sharedAB == sharedExpected);
}

/// A fresh ephemeral exchange agrees: with random private keys, the derived
/// public keys produce identical shared secrets on both sides.
@("crypto.x25519.agreement")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.backend : DefaultBackend;

    ubyte[32] skA = void, skB = void;
    DefaultBackend.randomBytes(skA[]);
    DefaultBackend.randomBytes(skB[]);

    ubyte[32] pkA = void, pkB = void;
    x25519Base(skA, pkA);
    x25519Base(skB, pkB);

    ubyte[32] sharedAB = void, sharedBA = void;
    assert(x25519(skA, pkB, sharedAB));
    assert(x25519(skB, pkA, sharedBA));
    assert(sharedAB == sharedBA);
}

/// `x25519` enforces the contributory check: a low-order input point (the
/// canonical all-zero point) yields the all-zero shared secret, so the function
/// returns `false`.
@("crypto.x25519.lowOrderPoint")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.backend : DefaultBackend;

    ubyte[32] scalar = void;
    DefaultBackend.randomBytes(scalar[]);

    // The all-zero point is low-order; the multiplication is non-contributory.
    ubyte[32] zeroPoint = 0;

    ubyte[32] shared_ = void;
    assert(!x25519(scalar, zeroPoint, shared_));
}

/// A second canonical small-order point from the X25519 contributory-check
/// literature (the order-8 point `e0eb7a7c…`) is also rejected as
/// non-contributory.
@("crypto.x25519.lowOrderPoint.order8")
@safe nothrow @nogc
unittest
{
    const scalar = fromHex!32(
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4");
    // One of the canonical small-order Curve25519 points (order 8).
    const lowOrder = fromHex!32(
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800");

    ubyte[32] shared_ = void;
    assert(!x25519(scalar, lowOrder, shared_));
}

/// Both free functions accept an explicit backend argument and route to it;
/// substituting a backend is purely a compile-time `B` choice.
@("crypto.x25519.explicitBackend")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.backend : SodiumBackend;

    ubyte[32] sk = void;
    SodiumBackend.randomBytes(sk[]);

    ubyte[32] pk = void;
    x25519Base!SodiumBackend(sk, pk);

    ubyte[32] shared_ = void;
    // Self-DH: sk · (sk · basepoint) is contributory and succeeds.
    assert(x25519!SodiumBackend(sk, pk, shared_));
}

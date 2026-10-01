/**
 * SHA-2 digests (§6): backend-templated `sha256` and `sha512`.
 *
 * These are thin, backend-templated free functions that forward to the active
 * crypto backend's digest primitives. They default to
 * $(REF DefaultBackend, sparkles,crypto,backend) (libsodium) but accept any
 * conforming backend as the `B` template parameter, so the same call site can
 * be retargeted at a pure-D backend without changing the call:
 *
 * ---
 * ubyte[32] digest;
 * sha256(message, digest);              // uses DefaultBackend
 * sha256!MyBackend(message, digest);    // uses a custom backend
 * ---
 *
 * The digest is written into a caller-provided fixed-size array
 * (`ubyte[32]` for SHA-256, `ubyte[64]` for SHA-512), so a caller can
 * stack-allocate exactly the right buffer and the type system enforces the
 * width. The marker types $(LREF Sha256) and $(LREF Sha512) carry those widths
 * as compile-time `OUTPUT_SIZE` constants and satisfy
 * $(REF isDigest, sparkles,crypto,concepts).
 *
 * SHA-256 and SHA-512 are part of the $(B required) backend surface
 * ($(REF isCryptoBackend, sparkles,crypto,backend,traits)), so both functions
 * are constrained only on `isCryptoBackend!B`; no per-primitive capability gate
 * is needed.
 *
 * Following the §6 `pure` boundary, these functions are `@safe nothrow @nogc`
 * but $(B not) `pure`: the libsodium-backed digests are not modelled as pure.
 *
 * See `docs/specs/age/SPEC.md` §6 (primitives) for the normative description.
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.hash;

import sparkles.crypto.backend : DefaultBackend, isCryptoBackend;
import sparkles.crypto.concepts : isDigest;

@safe nothrow @nogc:

/**
 * The SHA-256 digest algorithm tag.
 *
 * A zero-size marker type exposing the digest width as a compile-time
 * constant; it satisfies $(REF isDigest, sparkles,crypto,concepts). It carries
 * no behaviour — the hashing is done by $(LREF sha256) — but lets callers write
 * $(REF Output, sparkles,crypto,concepts)`!Sha256` for the output-buffer type.
 */
struct Sha256
{
    /// Digest width in bytes.
    enum size_t OUTPUT_SIZE = 32;
}

/// `Sha256` is a digest tag.
@("crypto.hash.Sha256.isDigest")
@safe pure nothrow @nogc
unittest
{
    static assert(isDigest!Sha256);
    static assert(Sha256.OUTPUT_SIZE == 32);
}

/**
 * The SHA-512 digest algorithm tag.
 *
 * A zero-size marker type exposing the digest width as a compile-time
 * constant; it satisfies $(REF isDigest, sparkles,crypto,concepts). The
 * hashing is done by $(LREF sha512); the tag exists for
 * $(REF Output, sparkles,crypto,concepts)`!Sha512` buffer sizing.
 */
struct Sha512
{
    /// Digest width in bytes.
    enum size_t OUTPUT_SIZE = 64;
}

/// `Sha512` is a digest tag.
@("crypto.hash.Sha512.isDigest")
@safe pure nothrow @nogc
unittest
{
    static assert(isDigest!Sha512);
    static assert(Sha512.OUTPUT_SIZE == 64);
}

/**
 * Computes the SHA-256 digest of `msg` into the 32-byte `out_`.
 *
 * Forwards to the backend's `sha256`. SHA-256 is part of the required backend
 * surface, so the only constraint is $(REF isCryptoBackend,
 * sparkles,crypto,backend,traits).
 *
 * Params:
 *   B    = the crypto backend (defaults to $(REF DefaultBackend,
 *          sparkles,crypto,backend), libsodium)
 *   msg  = message bytes to hash (may be empty)
 *   out_ = 32-byte output digest
 */
void sha256(B = DefaultBackend)(scope const(ubyte)[] msg, ref ubyte[Sha256.OUTPUT_SIZE] out_)
if (isCryptoBackend!B)
    => B.sha256(msg, out_);

/// SHA-256 of "abc" matches the FIPS 180-4 example, and the empty message
/// matches the well-known digest.
@("crypto.hash.sha256")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.encoding.hex : decodeHex;

    ubyte[32] expected = void;

    // SHA-256("") — RFC / FIPS well-known value.
    ubyte[32] empty = void;
    sha256(null, empty);
    assert(decodeHex(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        expected[]).hasValue);
    assert(empty == expected);

    // SHA-256("abc") — FIPS 180-4 example.
    static immutable ubyte[3] abc = ['a', 'b', 'c'];
    ubyte[32] digest = void;
    sha256(abc[], digest);
    assert(decodeHex(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        expected[]).hasValue);
    assert(digest == expected);
}

/**
 * Computes the SHA-512 digest of `msg` into the 64-byte `out_`.
 *
 * Forwards to the backend's `sha512`. SHA-512 is part of the required backend
 * surface, so the only constraint is $(REF isCryptoBackend,
 * sparkles,crypto,backend,traits).
 *
 * Params:
 *   B    = the crypto backend (defaults to $(REF DefaultBackend,
 *          sparkles,crypto,backend), libsodium)
 *   msg  = message bytes to hash (may be empty)
 *   out_ = 64-byte output digest
 */
void sha512(B = DefaultBackend)(scope const(ubyte)[] msg, ref ubyte[Sha512.OUTPUT_SIZE] out_)
if (isCryptoBackend!B)
    => B.sha512(msg, out_);

/// SHA-512 of "abc" matches the FIPS 180-4 example digest.
@("crypto.hash.sha512")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.encoding.hex : decodeHex;

    static immutable ubyte[3] abc = ['a', 'b', 'c'];
    ubyte[64] digest = void;
    sha512(abc[], digest);

    ubyte[64] expected = void;
    assert(decodeHex(
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
        ~ "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        expected[]).hasValue);
    assert(digest == expected);
}

/// Both digests accept a custom backend via the `B` template parameter; the
/// `Output!T` alias resolves to the right buffer width for each tag.
@("crypto.hash.customBackend")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.concepts : Output;

    // A trivial backend that satisfies isCryptoBackend; the digest functions
    // forward to it unchanged, proving the dispatch is backend-templated.
    static struct CountingBackend
    {
    @safe nothrow @nogc:
        static void sha256(scope const(ubyte)[] msg, ref ubyte[32] outDigest)
        {
            outDigest[] = 0;
            outDigest[0] = cast(ubyte) msg.length;
        }

        static void sha512(scope const(ubyte)[] msg, ref ubyte[64] outDigest)
        {
            outDigest[] = 0;
            outDigest[0] = cast(ubyte) msg.length;
        }

        // Remaining required surface (unused here).
        static void hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] msg,
            ref ubyte[32] outTag) {}
    }

    static assert(isCryptoBackend!CountingBackend);

    static immutable ubyte[5] msg = [1, 2, 3, 4, 5];

    Output!Sha256 d256 = void;
    sha256!CountingBackend(msg[], d256);
    assert(d256[0] == 5);

    Output!Sha512 d512 = void;
    sha512!CountingBackend(msg[], d512);
    assert(d512[0] == 5);
}

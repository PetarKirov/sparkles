/**
 * scrypt key derivation (RFC 7914), the passphrase KDF for the age `scrypt`
 * recipient stanza.
 *
 * A thin, backend-templated wrapper over the backend's `scrypt` capability. The
 * age profile fixes `r = 8`, `p = 1`, and a 32-byte output; the only tunable is
 * the cost `N = 2^logN`. The age scrypt identity bounds `logN` (a work-factor
 * cap) before calling, so a malicious header cannot request an unbounded
 * allocation.
 *
 * Like the other libsodium-backed primitives this is `@safe nothrow @nogc` but
 * $(B not) `pure`.
 *
 * See `docs/specs/age/SPEC.md` §6 (primitives) and §9.2 (the scrypt recipient).
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.scrypt;

import sparkles.crypto.backend : DefaultBackend, isCryptoBackend, hasScrypt;

/**
 * Derive a 32-byte key from `password` and `salt` with scrypt
 * (`r = 8`, `p = 1`, `N = 2^logN`).
 *
 * Params:
 *   B        = the crypto backend (defaults to libsodium)
 *   password = passphrase bytes (may be empty)
 *   salt     = salt bytes (may be empty)
 *   logN     = base-2 log of the cost parameter `N`
 *   outKey   = 32-byte derived key
 * Returns: `true` on success; `false` if the backend could not derive the key
 *          (e.g. `N` exceeds the available memory). On `false`, `outKey` is
 *          unspecified and MUST NOT be used.
 */
bool scrypt(B = DefaultBackend)(scope const(ubyte)[] password,
    scope const(ubyte)[] salt, ubyte logN, ref ubyte[32] outKey)
if (isCryptoBackend!B && hasScrypt!B)
    => B.scrypt(password, salt, logN, outKey);

/// RFC 7914 §12 known-answer vector (the `r = 8, p = 1` case): scrypt of
/// "pleaseletmein" with salt "SodiumChloride" at `N = 16384` (logN = 14). The
/// published vector is 64 bytes; the age profile takes the first 32 (a scrypt
/// `dkLen = 32` output equals the 64-byte output truncated, since the final
/// PBKDF2 step uses `c = 1`).
@("crypto.scrypt.rfc7914")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.encoding.hex : decodeHex;

    static immutable char[] password = "pleaseletmein";
    static immutable char[] salt = "SodiumChloride";

    // First 32 bytes of the RFC 7914 §12 N=16384,r=8,p=1,dkLen=64 vector
    // 7023bdcb3afd7348461c06cd81fd38eb...
    ubyte[32] expected = void;
    auto exp = decodeHex(
        "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2",
        expected[]);
    assert(exp.hasValue);

    ubyte[32] key = void;
    const ok = scrypt(
        cast(const(ubyte)[]) password, cast(const(ubyte)[]) salt, 14, key);
    assert(ok);
    assert(key == expected);
}

/// `logN >= 64` violates the precondition (it would overflow `1 << logN`); in a
/// non-release build the backend's `in` contract catches it.
@("crypto.scrypt.smallCostRoundTrips")
@safe nothrow @nogc
unittest
{
    // A tiny cost (N = 2) just exercises the path cheaply and deterministically.
    ubyte[32] a = void, b = void;
    const okA = scrypt(cast(const(ubyte)[]) "pw", cast(const(ubyte)[]) "salt", 1, a);
    const okB = scrypt(cast(const(ubyte)[]) "pw", cast(const(ubyte)[]) "salt", 1, b);
    assert(okA && okB);
    assert(a == b); // deterministic
}

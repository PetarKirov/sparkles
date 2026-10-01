/**
Crypto-backend concept and per-primitive capability predicates.

A crypto backend is a plain struct — typically zero-size — that exposes its
primitives as `static` methods. The library never instantiates a backend; it
calls `B.method(...)` directly. This module defines the compile-time contract
those structs are checked against:

- $(LREF isCryptoBackend) — the $(B required) surface every backend MUST
    provide: `sha256`, `sha512`, and `hmacSha256`. These are the primitives the
    age header MAC and key derivation always need, so they have no fallback and
    are part of the concept itself.
- The per-primitive capability predicates $(LREF hasChaCha20Poly1305),
    $(LREF hasX25519), $(LREF hasEd25519ToX25519), $(LREF hasScrypt),
    $(LREF hasCsprng), and $(LREF hasConstantTimeCompare) — each gates an
    $(I optional) primitive that a partial backend MAY omit. Public algorithm
    functions are constrained on these so a pure-D backend can cover the gaps a
    native backend leaves (the same optional-capability discipline as
    `sparkles:versions`).

Each predicate checks the $(B exact) canonical signature it intends to call
via `__traits(compiles, ...)`, not mere member existence, so a backend with a
mistyped method is correctly reported as lacking the capability rather than
silently mis-dispatched.

This module is $(B pure D): it carries no implementation and depends on no
backend. It MUST NOT reference $(D sparkles.crypto.backend.sodium) — the real
`SodiumBackend` only satisfies these predicates once it lands in M3; until
then the contract is exercised entirely by local mock backends.

See `docs/specs/age/SPEC.md` §4 (The crypto backend) for the normative
description.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.crypto.backend.traits;

@safe nothrow @nogc:

/**
Detects whether `B` is a conforming crypto backend.

A backend MUST provide the always-present digest and MAC primitives. The
check is delegated to the private `checkCryptoBackend!B`, which calls each
required method with its canonical signature; if any is missing or mistyped,
the resulting diagnostic names that specific method rather than failing
opaquely.

Required static methods:

---
static void sha256(scope const(ubyte)[] msg, ref ubyte[32] outDigest);
static void sha512(scope const(ubyte)[] msg, ref ubyte[64] outDigest);
static void hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] msg, ref ubyte[32] outTag);
---

The MAC key is a $(B variable-length) slice, not a fixed `ubyte[32]`: the age
key-derivation path (HKDF-Extract) feeds salts of arbitrary length, so the
required surface admits any key length.

Params:
    B = the candidate backend type

See_Also:
    $(LREF hasChaCha20Poly1305), $(LREF hasX25519),
    $(LREF hasEd25519ToX25519), $(LREF hasScrypt), $(LREF hasCsprng),
    $(LREF hasConstantTimeCompare)
*/
enum bool isCryptoBackend(B) = is(typeof(checkCryptoBackend!B));

/**
Exercises the three required backend primitives so a constraint failure
points at the specific missing or mistyped method.

This is the validation body behind $(LREF isCryptoBackend). It is never run;
its only purpose is to be type-checked. Keeping each call on its own line
means the compiler's error (when used via the
[`concepts`](https://github.com/atilaneves/concepts) idiom or a plain
instantiation) identifies which primitive a backend failed to provide.

Params:
    B = the candidate backend type
*/
private void checkCryptoBackend(B)()
{
    ubyte[32] digest256 = void;
    ubyte[64] digest512 = void;
    ubyte[32] tag = void;
    scope const(ubyte)[] key;
    scope const(ubyte)[] msg;

    B.sha256(msg, digest256);
    B.sha512(msg, digest512);
    B.hmacSha256(key, msg, tag);
}

/**
Capability: authenticated encryption with ChaCha20-Poly1305 (IETF, 12-byte
nonce).

Detection rule — both of the canonical static methods must compile:

---
static void chaCha20Poly1305Encrypt(in ubyte[32] key, in ubyte[12] nonce,
    scope const(ubyte)[] pt, scope const(ubyte)[] aad, ubyte[] ct);
static bool chaCha20Poly1305Decrypt(in ubyte[32] key, in ubyte[12] nonce,
    scope const(ubyte)[] ct, scope const(ubyte)[] aad, ubyte[] pt);
---

Params:
    B = the candidate backend type

See_Also: $(LREF isCryptoBackend)
*/
enum bool hasChaCha20Poly1305(B) = __traits(compiles, {
    ubyte[32] key = void;
    ubyte[12] nonce = void;
    scope const(ubyte)[] pt;
    scope const(ubyte)[] aad;
    ubyte[] ct;
    ubyte[] out_;
    B.chaCha20Poly1305Encrypt(key, nonce, pt, aad, ct);
    bool ok = B.chaCha20Poly1305Decrypt(key, nonce, ct, aad, out_);
});

/**
Capability: X25519 Diffie-Hellman scalar multiplication.

Detection rule — the canonical static method must compile:

---
static bool x25519(in ubyte[32] scalar, in ubyte[32] point, ref ubyte[32] outShared);
---

The `bool` return reports the contributory-behaviour check (a backend returns
`false` on an all-zero shared secret).

Params:
    B = the candidate backend type

See_Also: $(LREF isCryptoBackend)
*/
enum bool hasX25519(B) = __traits(compiles, {
    ubyte[32] scalar = void;
    ubyte[32] point = void;
    ubyte[32] shared_ = void;
    bool ok = B.x25519(scalar, point, shared_);
});

/**
Capability: Ed25519-to-X25519 (Montgomery) key conversion, for ssh-ed25519
recipients.

Detection rule — both of the canonical static methods must compile:

---
static void ed25519PkToX25519(in ubyte[32] edPk, ref ubyte[32] curvePk);
static void ed25519SkToX25519(in ubyte[64] edSk, ref ubyte[32] curveSk);
---

Params:
    B = the candidate backend type

See_Also: $(LREF isCryptoBackend)
*/
enum bool hasEd25519ToX25519(B) = __traits(compiles, {
    ubyte[32] edPk = void;
    ubyte[64] edSk = void;
    ubyte[32] curvePk = void;
    ubyte[32] curveSk = void;
    B.ed25519PkToX25519(edPk, curvePk);
    B.ed25519SkToX25519(edSk, curveSk);
});

/**
Capability: the scrypt password-based key-derivation function.

Detection rule — the canonical static method must compile:

---
static void scrypt(scope const(ubyte)[] password, scope const(ubyte)[] salt, ubyte logN, ref ubyte[32] outKey);
---

The cost parameter is passed as `logN` (N = 2^logN); `r` and `p` are fixed by
the age profile and so are not part of the signature.

Params:
    B = the candidate backend type

See_Also: $(LREF isCryptoBackend)
*/
enum bool hasScrypt(B) = __traits(compiles, {
    scope const(ubyte)[] password;
    scope const(ubyte)[] salt;
    ubyte logN;
    ubyte[32] outKey = void;
    B.scrypt(password, salt, logN, outKey);
});

/**
Capability: a cryptographically-secure pseudo-random number generator.

Detection rule — the canonical static method must compile:

---
static void randomBytes(ubyte[] buf);
---

Params:
    B = the candidate backend type

See_Also: $(LREF isCryptoBackend)
*/
enum bool hasCsprng(B) = __traits(compiles, {
    ubyte[] buf;
    B.randomBytes(buf);
});

/**
Capability: a constant-time byte-slice comparison primitive.

Detection rule — the canonical static method must compile:

---
static bool ctEquals(scope const(ubyte)[] a, scope const(ubyte)[] b);
---

A backend MAY offer this (e.g. routing to `sodium_memcmp`); the pure-D
$(D sparkles.crypto.ct.ctEquals) is the fallback when it is absent.

Params:
    B = the candidate backend type

See_Also: $(LREF isCryptoBackend)
*/
enum bool hasConstantTimeCompare(B) = __traits(compiles, {
    scope const(ubyte)[] a;
    scope const(ubyte)[] b;
    bool ok = B.ctEquals(a, b);
});

// ─────────────────────────────────────────────────────────────────────────
// Tests
//
// Exercised against local mock backends only. The real SodiumBackend is
// incomplete until M3, so it is NOT referenced here.
// ─────────────────────────────────────────────────────────────────────────

version (unittest)
{
    /// A backend providing the required surface plus every capability.
    private struct MockFullBackend
    {
    @safe nothrow @nogc:
        static void sha256(scope const(ubyte)[] msg, ref ubyte[32] outDigest) {}
        static void sha512(scope const(ubyte)[] msg, ref ubyte[64] outDigest) {}
        static void hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] msg, ref ubyte[32] outTag) {}

        static void chaCha20Poly1305Encrypt(in ubyte[32] key, in ubyte[12] nonce,
            scope const(ubyte)[] pt, scope const(ubyte)[] aad, ubyte[] ct) {}
        static bool chaCha20Poly1305Decrypt(in ubyte[32] key, in ubyte[12] nonce,
            scope const(ubyte)[] ct, scope const(ubyte)[] aad, ubyte[] pt) => true;

        static bool x25519(in ubyte[32] scalar, in ubyte[32] point, ref ubyte[32] outShared) => true;

        static void ed25519PkToX25519(in ubyte[32] edPk, ref ubyte[32] curvePk) {}
        static void ed25519SkToX25519(in ubyte[64] edSk, ref ubyte[32] curveSk) {}

        static void scrypt(scope const(ubyte)[] password, scope const(ubyte)[] salt,
            ubyte logN, ref ubyte[32] outKey) {}

        static void randomBytes(ubyte[] buf) {}

        static bool ctEquals(scope const(ubyte)[] a, scope const(ubyte)[] b) => true;
    }

    /// A backend providing only the required surface and a subset of
    /// capabilities (AEAD + CSPRNG), exercising the negative path for the rest.
    private struct MockMinimalBackend
    {
    @safe nothrow @nogc:
        static void sha256(scope const(ubyte)[] msg, ref ubyte[32] outDigest) {}
        static void sha512(scope const(ubyte)[] msg, ref ubyte[64] outDigest) {}
        static void hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] msg, ref ubyte[32] outTag) {}

        static void chaCha20Poly1305Encrypt(in ubyte[32] key, in ubyte[12] nonce,
            scope const(ubyte)[] pt, scope const(ubyte)[] aad, ubyte[] ct) {}
        static bool chaCha20Poly1305Decrypt(in ubyte[32] key, in ubyte[12] nonce,
            scope const(ubyte)[] ct, scope const(ubyte)[] aad, ubyte[] pt) => true;

        static void randomBytes(ubyte[] buf) {}
        // No x25519, ed25519ToX25519, scrypt, or ctEquals.
    }

    /// A backend whose `scrypt` has the wrong signature (`uint` cost instead
    /// of `ubyte logN`), to prove the predicates check the exact form, not
    /// just member existence.
    private struct MockBadScryptBackend
    {
    @safe nothrow @nogc:
        static void sha256(scope const(ubyte)[] msg, ref ubyte[32] outDigest) {}
        static void sha512(scope const(ubyte)[] msg, ref ubyte[64] outDigest) {}
        static void hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] msg, ref ubyte[32] outTag) {}

        static void scrypt(scope const(ubyte)[] password, scope const(ubyte)[] salt,
            uint cost, ref ubyte[64] outKey) {}
    }
}

/// A backend exposing the three required primitives conforms; a type lacking
/// them (e.g. `int`) does not.
@("crypto.backend.traits.isCryptoBackend")
@safe pure nothrow @nogc
unittest
{
    static assert(isCryptoBackend!MockFullBackend);
    static assert(isCryptoBackend!MockMinimalBackend);

    static assert(!isCryptoBackend!int);
    static assert(!isCryptoBackend!(ubyte[]));
}

/// A fully-capable backend reports every capability as present.
@("crypto.backend.traits.fullCapabilities")
@safe pure nothrow @nogc
unittest
{
    static assert(hasChaCha20Poly1305!MockFullBackend);
    static assert(hasX25519!MockFullBackend);
    static assert(hasEd25519ToX25519!MockFullBackend);
    static assert(hasScrypt!MockFullBackend);
    static assert(hasCsprng!MockFullBackend);
    static assert(hasConstantTimeCompare!MockFullBackend);
}

/// A partial backend reports exactly the capabilities it provides and no
/// more; the absent ones (X25519, Ed25519 conversion, scrypt, constant-time
/// compare) are correctly detected as missing.
@("crypto.backend.traits.partialCapabilities")
@safe pure nothrow @nogc
unittest
{
    // Present.
    static assert(hasChaCha20Poly1305!MockMinimalBackend);
    static assert(hasCsprng!MockMinimalBackend);

    // Absent.
    static assert(!hasX25519!MockMinimalBackend);
    static assert(!hasEd25519ToX25519!MockMinimalBackend);
    static assert(!hasScrypt!MockMinimalBackend);
    static assert(!hasConstantTimeCompare!MockMinimalBackend);
}

/// Predicates check the exact signature: a `scrypt` with a mistyped cost
/// parameter and output width is rejected, and `int` has no capabilities.
@("crypto.backend.traits.signatureMismatch")
@safe pure nothrow @nogc
unittest
{
    static assert(!hasScrypt!MockBadScryptBackend);

    static assert(!hasChaCha20Poly1305!int);
    static assert(!hasX25519!int);
    static assert(!hasEd25519ToX25519!int);
    static assert(!hasScrypt!int);
    static assert(!hasCsprng!int);
    static assert(!hasConstantTimeCompare!int);
}

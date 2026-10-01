/**
 * The `sparkles.crypto.backend` package: the backend concept, the per-primitive
 * capability predicates, and the default libsodium backend.
 *
 * Importing this package gives a consumer everything needed to write a
 * backend-templated primitive:
 *
 * ---
 * import sparkles.crypto.backend;
 *
 * void sha256(B = DefaultBackend)(scope const(ubyte)[] msg, ref ubyte[32] out_)
 * if (isCryptoBackend!B)
 *     => B.sha256(msg, out_);
 * ---
 *
 * $(REF DefaultBackend) is the alias the free-function primitives default their
 * `B` template parameter to; it currently resolves to
 * $(REF SodiumBackend, sparkles,crypto,backend,sodium).
 *
 * See `docs/specs/age/SPEC.md` §4 (the crypto backend) for the normative
 * description.
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.backend;

public import sparkles.crypto.backend.traits;
public import sparkles.crypto.backend.sodium : SodiumBackend;

/**
 * The default crypto backend for the backend-templated primitive functions.
 *
 * Free-function primitives declare `B = DefaultBackend` so that, unless a
 * caller substitutes a different backend, every primitive routes to libsodium.
 */
alias DefaultBackend = SodiumBackend;

// The default backend satisfies the required surface and every capability.
static assert(isCryptoBackend!DefaultBackend);
static assert(hasChaCha20Poly1305!DefaultBackend);
static assert(hasX25519!DefaultBackend);
static assert(hasEd25519ToX25519!DefaultBackend);
static assert(hasCsprng!DefaultBackend);
static assert(hasConstantTimeCompare!DefaultBackend);
static assert(hasScrypt!DefaultBackend);

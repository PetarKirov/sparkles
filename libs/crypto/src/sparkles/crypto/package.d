/**
 * `sparkles:crypto` — backend-abstracted cryptographic and encoding primitives.
 *
 * The default backend binds [libsodium](https://libsodium.org) via D's ImportC
 * (see $(D sparkles.crypto.sodium_c)). This package module re-exports the public
 * surface.
 *
 * See `docs/specs/age/SPEC.md` for the full specification.
 */
module sparkles.crypto;

public import sparkles.crypto.backend.sodium : sodiumAvailable;

// M3 public surface.
public import sparkles.crypto.backend;
public import sparkles.crypto.hash;
public import sparkles.crypto.hmac;
public import sparkles.crypto.hkdf;
public import sparkles.crypto.aead;
public import sparkles.crypto.x25519;
public import sparkles.crypto.ed25519;
public import sparkles.crypto.random;
public import sparkles.crypto.scrypt;

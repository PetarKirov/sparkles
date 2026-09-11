/**
 * `sparkles:age` — a D implementation of the
 * [age-encryption.org/v1](https://c2sp.org/age) file-encryption format.
 *
 * A port of the Rust `rage` implementation, built on `sparkles:crypto` for the
 * cryptographic primitives. See `docs/specs/age/SPEC.md` for the full
 * specification and `docs/specs/age/PLAN.md` for the delivery plan.
 */
module sparkles.age;

// Public re-exports are added as the modules land (M5+):
public import sparkles.age.errors;
public import sparkles.age.format.stanza;
public import sparkles.age.format.header;
public import sparkles.age.mac;
public import sparkles.age.stream;
public import sparkles.age.armor;

public import sparkles.age.keys;
public import sparkles.age.recipient;
public import sparkles.age.identity;
public import sparkles.age.recipients.x25519;
public import sparkles.age.recipients.scrypt;
public import sparkles.age.recipients.ssh_keys;
public import sparkles.age.recipients.ssh_ed25519;
public import sparkles.age.identity_file;
public import sparkles.age.protocol;
public import sparkles.age.simple;
public import sparkles.age.keygen;

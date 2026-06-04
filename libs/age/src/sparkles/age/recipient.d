/**
The `Recipient` concept — a public key (or passphrase) that can wrap an opaque
file key into one or more header stanzas — plus the runtime-erased
$(LREF AnyRecipient) sum type.

This is a faithful port of rage's `Recipient` trait (`age/src/lib.rs`). In rage
the trait method is

```rust
fn wrap_file_key(&self, file_key: &FileKey)
    -> Result<(Vec<Stanza>, HashSet<String>), EncryptError>;
```

returning both the stanzas to place in the header and a set of *labels* that
constrain how those stanzas may be combined with other recipients'. We model
the `(Vec<Stanza>, HashSet<String>)` pair as $(LREF WrapResult) and the
`Result<_, EncryptError>` as an [expected.Expected] (this layer never throws).

D has no trait objects, so the trait surface is expressed two ways:

$(UL
    $(LI $(LREF isRecipient) — a structural-typing trait any concrete recipient
        struct (`X25519Recipient`, `ScryptRecipient`, …) satisfies by exposing
        the right `wrapFileKey` signature; and)
    $(LI $(LREF AnyRecipient) — a `std.sumtype.SumType` over the shipped native
        recipient structs, with a $(LREF wrapFileKey) dispatcher that `match`es
        on the active member, mirroring `sparkles.versions.any.AnyVersion`.))

# Labels

`Encryptor` (see `sparkles.age.protocol`) succeeds only if every recipient
returns the **same** label set — subsets or partial overlaps are rejected with
$(REF EncryptErrorCode.incompatibleRecipients, sparkles,age,errors). A
plain X25519 recipient returns the empty label set; the scrypt (passphrase)
recipient returns a single random label, which forces it to be the **sole**
recipient. See `docs/specs/age/SPEC.md` §8.

This layer MAY use the GC: a $(LREF WrapResult) owns its `Stanza[]` / `string[]`
arrays.
*/
module sparkles.age.recipient;

import std.sumtype : SumType, match;

import expected : Expected;

import sparkles.core_cli.text.errors : NoGcHook;

import sparkles.age.errors : EncryptError;
import sparkles.age.format.stanza : Stanza;
import sparkles.age.keys : FileKey;

// Re-export the concrete native recipient structs so `AnyRecipient`'s members
// are nameable by callers that only import this module (mirrors
// `sparkles.versions.any`). These modules are written in a later phase; the
// build-fix loop resolves the ordering.
public import sparkles.age.recipients.x25519 : X25519Recipient;
public import sparkles.age.recipients.scrypt : ScryptRecipient;
public import sparkles.age.recipients.ssh_ed25519 : SshEd25519Recipient;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// WrapResult
// ─────────────────────────────────────────────────────────────────────────────

/**
The successful product of wrapping a file key for one recipient: the header
$(LREF Stanza)s to emit, and the recipient's $(I labels).

This is the D analogue of rage's `(Vec<Stanza>, HashSet<String>)` return pair.
$(UL
    $(LI $(LREF stanzas) — one or more stanzas to place in the age header. A
        single "actual recipient" may produce more than one (e.g. to offer
        multiple formats); the native X25519 / scrypt recipients each produce
        exactly one.)
    $(LI $(LREF labels) — the recipient's label set. `Encryptor` requires every
        recipient in a single encryption to return an $(I identical) set
        (compared exactly, case-sensitively). An empty set means "no
        constraints"; see the module summary.))

The arrays are GC-owned; their order within $(LREF labels) is not significant
to the label-set comparison (the encryptor compares them as sets).
*/
struct WrapResult
{
    /// The header stanza(s) wrapping the file key for this recipient.
    Stanza[] stanzas;

    /// The recipient's label set (see the module summary). Empty == no
    /// constraints.
    string[] labels;
}

// ─────────────────────────────────────────────────────────────────────────────
// isRecipient
// ─────────────────────────────────────────────────────────────────────────────

/**
Produces an lvalue reference of type `T` in an unevaluated context.

Both the recipient `R` and the `FileKey` may be non-copyable (`ScryptRecipient`
holds a secret passphrase; `FileKey` disables its postblit), so $(LREF
isRecipient) cannot construct a value to probe with. This `@safe`-but-bodyless
function lets the trait name an lvalue of any type — including a non-copyable
one — inside a `typeof` it never evaluates, mirroring `std.traits`'
internal `lvalueOf`.
*/
private ref T lvalueOf(T)() @safe;

/**
Structural trait: `true` iff `R` is an age recipient — i.e. it exposes

```d
Expected!(WrapResult, EncryptError, NoGcHook) wrapFileKey(in FileKey fileKey) const @safe;
```

This is the D analogue of implementing rage's `Recipient` trait. The probe pins
the exact `Expected` return type (so a recipient whose `wrapFileKey` returns the
wrong type does not qualify) and runs entirely in an unevaluated `typeof`, using
$(LREF lvalueOf) so that a non-copyable recipient (e.g. a passphrase-holding
`ScryptRecipient`) or the non-copyable `FileKey` is never copied or constructed.
The `const R` receiver enforces that `wrapFileKey` is callable on a `const`
recipient, matching the contract above.
*/
enum bool isRecipient(R) = is(
    typeof(lvalueOf!(const R)().wrapFileKey(lvalueOf!(const FileKey)()))
    == Expected!(WrapResult, EncryptError, NoGcHook));

///
@("age.recipient.isRecipient.mockTrueIntFalse")
@safe pure nothrow @nogc
unittest
{
    // A minimal struct that satisfies the recipient surface. Its body is never
    // run here — `isRecipient` only inspects the static signature.
    static struct MockRecipient
    {
        Expected!(WrapResult, EncryptError, NoGcHook) wrapFileKey(in FileKey) const @safe
            => typeof(return).init;
    }

    static assert(isRecipient!MockRecipient);

    // A type with no `wrapFileKey` at all is not a recipient.
    static assert(!isRecipient!int);
}

/// `isRecipient` rejects a `wrapFileKey` whose return type is not the pinned
/// `Expected!(WrapResult, EncryptError, NoGcHook)`, and accepts a recipient
/// that is itself non-copyable (the passphrase recipient holds a secret).
@("age.recipient.isRecipient.returnTypeAndNonCopyable")
@safe pure nothrow @nogc
unittest
{
    // Wrong return type → not a recipient (an `int` does not convert to the
    // pinned `Expected`).
    static struct WrongReturn
    {
        int wrapFileKey(in FileKey) const @safe => 0;
    }
    static assert(!isRecipient!WrongReturn);

    // A non-copyable recipient still qualifies: the trait probes via lvalues
    // and never copies or constructs `R`.
    static struct NonCopyableRecipient
    {
        @disable this(this);
        Expected!(WrapResult, EncryptError, NoGcHook) wrapFileKey(in FileKey) const @safe
            => typeof(return).init;
    }
    static assert(isRecipient!NonCopyableRecipient);
}

// ─────────────────────────────────────────────────────────────────────────────
// AnyRecipient
// ─────────────────────────────────────────────────────────────────────────────

/**
A recipient of statically-unknown concrete type: a `std.sumtype.SumType` over
the shipped native recipient structs (`X25519Recipient`, `ScryptRecipient`).

Callers that collect a heterogeneous recipient list (e.g. the CLI, or
`Encryptor.withRecipients`) erase each concrete recipient into an
`AnyRecipient`. Build one by wrapping a concrete recipient
(`AnyRecipient(X25519Recipient(...))`); wrap a file key with the free
$(LREF wrapFileKey) overload below, which `match`es on the active member.

Mirrors `sparkles.versions.any.AnyVersion`. Every member satisfies
$(LREF isRecipient) (the per-type conformance `static assert`s live in the
recipient modules themselves).
*/
alias AnyRecipient = SumType!(X25519Recipient, ScryptRecipient, SshEd25519Recipient);

/**
Wraps `fileKey` with whichever concrete recipient `r` currently holds,
dispatching via `std.sumtype.match` to the active member's `wrapFileKey`.

The per-type `wrapFileKey` does the real work (ephemeral-key agreement and AEAD
for X25519; scrypt KDF for the passphrase recipient); this just routes to it,
exactly as `sparkles.versions.any.toString` routes to the active scheme. `r` is
taken by `ref const` — not `in` — because `std.sumtype.match` forwards its
argument to a non-`scope` parameter, which a `scope`-inferring `in` cannot bind
when a member holds indirections (the `ScryptRecipient` secret store). The
non-copyable `FileKey` is taken by `in` so it is never copied.
*/
Expected!(WrapResult, EncryptError, NoGcHook) wrapFileKey(
    ref const(AnyRecipient) r,
    in FileKey fileKey,
)
{
    return r.match!((ref active) => active.wrapFileKey(fileKey));
}

// ─────────────────────────────────────────────────────────────────────────────
// Conformance scaffold
// ─────────────────────────────────────────────────────────────────────────────

// Compile-time guard that every `AnyRecipient` member satisfies the recipient
// surface. The authoritative per-type asserts live alongside each recipient
// struct; this mirror keeps the sum type honest once those modules compile.
//
// The recipient modules (`recipients.x25519` / `recipients.scrypt`) have landed,
// so these asserts are live: every `AnyRecipient` member must structurally
// satisfy `isRecipient`.
static foreach (R; AnyRecipient.Types)
    static assert(isRecipient!R,
        R.stringof ~ " must satisfy isRecipient to be an AnyRecipient member");

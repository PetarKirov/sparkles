/**
The age $(B Identity) concept — the decryption-side counterpart of
$(REF isRecipient, sparkles,age,recipient).

An identity is a private key (or other secret value) that can recognise and
unwrap the file key from a recipient $(REF Stanza, sparkles,age,format,stanza)
in an age header. This module defines:

$(UL
    $(LI $(LREF UnwrapOutcome) — the not-mine / malformed / success trichotomy
        an identity reports for a stanza;)
    $(LI $(LREF isIdentity) — the structural trait every identity satisfies;)
    $(LI $(LREF hasUnwrapStanzas) — an $(I optional) capability for identities
        (like scrypt) that need whole-header context;)
    $(LI $(LREF AnyIdentity) — a runtime sum type over the two native identity
        types, with $(LREF unwrapStanza) / $(LREF unwrapStanzas) dispatchers.))

This is a faithful port of rage's `Identity` trait (`age/src/lib.rs`), with the
`Option<Result<FileKey, DecryptError>>` return value re-expressed in D as a
$(LREF UnwrapOutcome). Because `FileKey` is non-copyable (see the
$(REF SecretArray, sparkles,crypto,secret) design), it never travels through the
`Expected`/`Nullable`; instead the unwrap methods $(I fill) a caller-provided
`ref FileKey fileKeyOut` on success, and the outcome only carries the
present/absent and ok/error bits.

See `docs/specs/age/SPEC.md` §8–§10.
*/
module sparkles.age.identity;

import std.sumtype : SumType, match;
import std.typecons : Nullable, nullable;

import expected : Expected;
import sparkles.core_cli.text.errors : NoGcHook;

import sparkles.age.errors : DecryptError, DecryptErrorCode, decryptOk, decryptErr;
import sparkles.age.format.stanza : Stanza;
import sparkles.age.keys : FileKey;

// Re-export the concrete native identity structs so `AnyIdentity`'s members are
// nameable by callers that only import this module (mirrors the `AnyVersion`
// pattern in `sparkles.versions.any`).
public import sparkles.age.recipients.x25519 : X25519Identity;
public import sparkles.age.recipients.scrypt : ScryptIdentity;
public import sparkles.age.recipients.ssh_ed25519 : SshEd25519Identity;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// UnwrapOutcome
// ─────────────────────────────────────────────────────────────────────────────

/**
The result an identity reports for a single recipient stanza (or a whole
header's worth of stanzas) — the D rendering of rage's
`Option<Result<FileKey, DecryptError>>`.

The three states encode the not-mine / malformed / success trichotomy:

$(UL
    $(LI `null` (the `Nullable` is null) — the stanza is $(B not addressed) to
        this identity, so the caller should skip it and try the next identity.)
    $(LI non-null carrying an $(B error) `Expected` — the stanza $(I is) ours
        but is malformed or failed to unwrap; the caller should surface the
        $(LREF DecryptError).)
    $(LI non-null carrying a $(B success) `Expected` (`void` payload) — the file
        key was recovered and written into the caller's `ref FileKey
        fileKeyOut`; decryption may proceed.))

The `void` payload is deliberate: the recovered file key is non-copyable and is
delivered out-of-band through the `fileKeyOut` reference, never through this
value.
*/
alias UnwrapOutcome = Nullable!(Expected!(void, DecryptError, NoGcHook));

/**
Builds the "not addressed to this identity" outcome — a null
$(LREF UnwrapOutcome). The caller should skip this stanza/identity pair.
*/
UnwrapOutcome unwrapSkip() @safe pure nothrow @nogc
    => UnwrapOutcome.init;

///
@("age.identity.UnwrapOutcome.skip")
@safe pure nothrow @nogc
unittest
{
    assert(unwrapSkip().isNull);
}

/**
Builds the "unwrapped successfully" outcome — a non-null $(LREF UnwrapOutcome)
carrying a success `Expected`. The recovered file key must already have been
written into the caller's `ref FileKey fileKeyOut`.
*/
UnwrapOutcome unwrapDone() @safe pure nothrow @nogc
    => nullable(decryptOk());

///
@("age.identity.UnwrapOutcome.done")
@safe pure nothrow @nogc
unittest
{
    auto o = unwrapDone();
    assert(!o.isNull);
    assert(!o.get.hasError);   // `Expected!void` exposes `hasError`
}

/**
Builds the "this stanza is ours but failed" outcome — a non-null
$(LREF UnwrapOutcome) carrying the given $(LREF DecryptError).
*/
UnwrapOutcome unwrapFail(DecryptError error) @safe pure nothrow @nogc
    => nullable(decryptErr!void(error));

/// ditto — the common bare-`code` form.
UnwrapOutcome unwrapFail(DecryptErrorCode code) @safe pure nothrow @nogc
    => nullable(decryptErr!void(code));

///
@("age.identity.UnwrapOutcome.fail")
@safe pure nothrow @nogc
unittest
{
    auto o = unwrapFail(DecryptErrorCode.invalidHeader);
    assert(!o.isNull);
    assert(o.get.hasError);
    assert(o.get.error.code == DecryptErrorCode.invalidHeader);
}

// ─────────────────────────────────────────────────────────────────────────────
// Traits
// ─────────────────────────────────────────────────────────────────────────────

/**
Detects a type `I` that satisfies the age $(B Identity) concept: it exposes

---
UnwrapOutcome unwrapStanza(in Stanza stanza, ref FileKey fileKeyOut) const @safe;
---

`unwrapStanza` examines a single recipient stanza and reports an
$(LREF UnwrapOutcome): `null` if the stanza is not addressed to this identity,
a non-null error if it is ours but malformed/failed, or a non-null success
(having filled `fileKeyOut`).

This is the structural analogue of rage's `Identity::unwrap_stanza`.

The receiver is probed through a `ref const(I)` parameter — not a by-value `in
I` — so the check works for identities whose fields are non-copyable secrets
(e.g. a $(REF SecretArray, sparkles,crypto,secret) scalar), and the `@safe`
probe lambda additionally requires the method to be `const @safe`.
*/
enum bool isIdentity(I) = is(typeof(
    (ref const(I) id, in Stanza stanza, ref FileKey fileKeyOut) @safe
        => id.unwrapStanza(stanza, fileKeyOut)
) : UnwrapOutcome function(ref const(I), in Stanza, ref FileKey) @safe);

/**
Detects whether an identity `I` additionally provides the whole-header
$(B unwrapStanzas) capability:

---
UnwrapOutcome unwrapStanzas(in Stanza[] stanzas, ref FileKey fileKeyOut) const @safe;
---

This mirrors rage's `Identity::unwrap_stanzas`, whose default implementation
simply scans `unwrap_stanza` over the header's stanzas. An identity overrides
it only when it must see the $(I whole) header to make a decision — the scrypt
identity, for example, must verify it is the file's $(B sole) recipient before
attempting to unwrap (see $(REF ScryptIdentity, sparkles,age,recipients,scrypt)).

When this capability is absent, $(LREF unwrapStanzas)`(AnyIdentity, …)` falls
back to looping $(LREF unwrapStanza) over the stanzas.
*/
enum bool hasUnwrapStanzas(I) = is(typeof(
    (ref const(I) id, in Stanza[] stanzas, ref FileKey fileKeyOut) @safe
        => id.unwrapStanzas(stanzas, fileKeyOut)
) : UnwrapOutcome function(ref const(I), in Stanza[], ref FileKey) @safe);

// ─────────────────────────────────────────────────────────────────────────────
// AnyIdentity
// ─────────────────────────────────────────────────────────────────────────────

/**
An identity of statically-unknown type: a `SumType` over the two native age
identity structs,
$(REF X25519Identity, sparkles,age,recipients,x25519) and
$(REF ScryptIdentity, sparkles,age,recipients,scrypt).

Construct one by wrapping a concrete identity
(`AnyIdentity(X25519Identity.generate())`), and unwrap a header's stanzas with
the $(LREF unwrapStanza) / $(LREF unwrapStanzas) free-function dispatchers.
*/
alias AnyIdentity = SumType!(X25519Identity, ScryptIdentity, SshEd25519Identity);

static assert(isIdentity!X25519Identity,
    "X25519Identity must satisfy isIdentity to be an AnyIdentity member");
static assert(isIdentity!ScryptIdentity,
    "ScryptIdentity must satisfy isIdentity to be an AnyIdentity member");
static assert(isIdentity!SshEd25519Identity,
    "SshEd25519Identity must satisfy isIdentity to be an AnyIdentity member");

/**
Dispatches $(LREF isIdentity.unwrapStanza) to the active member of `id`.

This is the runtime erasure of the `Identity` trait's per-stanza entry point:
it forwards a single recipient `stanza` to whichever concrete identity `id`
currently holds, returning that identity's $(LREF UnwrapOutcome) verbatim and
filling `fileKeyOut` on success.
*/
UnwrapOutcome unwrapStanza(ref const(AnyIdentity) id, in Stanza stanza, ref FileKey fileKeyOut)
{
    return id.match!((ref active) => active.unwrapStanza(stanza, fileKeyOut));
}

/**
Dispatches the whole-header unwrap to the active member of `id`.

For a member that provides the $(LREF hasUnwrapStanzas) capability (e.g. the
scrypt identity, which must confirm it is the sole recipient), this calls that
member's `unwrapStanzas` directly. For a member without it (e.g. the X25519
identity), it reproduces rage's default `unwrap_stanzas` behaviour by scanning
$(LREF isIdentity.unwrapStanza) over `stanzas` and returning the first non-null
outcome — success or error — that any stanza yields. If every stanza is
not-mine (null), the result is null.
*/
UnwrapOutcome unwrapStanzas(ref const(AnyIdentity) id, in Stanza[] stanzas, ref FileKey fileKeyOut)
{
    return id.match!((ref active) {
        alias A = typeof(active);
        static if (hasUnwrapStanzas!A)
        {
            return active.unwrapStanzas(stanzas, fileKeyOut);
        }
        else
        {
            // rage's default `unwrap_stanzas`:
            //     stanzas.iter().find_map(|s| self.unwrap_stanza(s))
            foreach (ref stanza; stanzas)
            {
                auto outcome = active.unwrapStanza(stanza, fileKeyOut);
                if (!outcome.isNull)
                    return outcome;
            }
            return unwrapSkip();
        }
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // A minimal in-module identity used to exercise the traits and the
    // dispatcher's fallback path without depending on the (separately authored)
    // native recipient modules. It recognises stanzas tagged "mock", filling
    // `fileKeyOut` from a fixed byte, and ignores everything else.
    private struct MockIdentity
    {
        ubyte marker = 0x42;

        UnwrapOutcome unwrapStanza(in Stanza stanza, ref FileKey fileKeyOut) const @safe
        {
            if (stanza.tag != "mock")
                return unwrapSkip();
            fileKeyOut.exposeSecretMut()[] = marker;
            return unwrapDone();
        }
    }

    // A second mock that also overrides the whole-header path, so
    // `hasUnwrapStanzas` is true for it. It recognises a sole "whole" stanza.
    private struct MockWholeHeaderIdentity
    {
        UnwrapOutcome unwrapStanza(in Stanza stanza, ref FileKey fileKeyOut) const @safe
        {
            if (stanza.tag != "whole")
                return unwrapSkip();
            fileKeyOut.exposeSecretMut()[] = 0x7;
            return unwrapDone();
        }

        UnwrapOutcome unwrapStanzas(in Stanza[] stanzas, ref FileKey fileKeyOut) const @safe
        {
            if (stanzas.length != 1 || stanzas[0].tag != "whole")
                return unwrapSkip();
            fileKeyOut.exposeSecretMut()[] = 0x7;
            return unwrapDone();
        }
    }
}

@("age.identity.isIdentity.detection")
@safe pure nothrow @nogc
unittest
{
    // A struct exposing the required `unwrapStanza` shape is an identity.
    static assert(isIdentity!MockIdentity);
    static assert(isIdentity!MockWholeHeaderIdentity);

    // Arbitrary non-identity types are rejected.
    static assert(!isIdentity!int);
    static assert(!isIdentity!Stanza);

    struct NoUnwrap { int x; }
    static assert(!isIdentity!NoUnwrap);
}

@("age.identity.hasUnwrapStanzas.detection")
@safe pure nothrow @nogc
unittest
{
    // Only the type that defines `unwrapStanzas` advertises the capability.
    static assert(!hasUnwrapStanzas!MockIdentity);
    static assert(hasUnwrapStanzas!MockWholeHeaderIdentity);

    // A non-identity is trivially without the capability.
    static assert(!hasUnwrapStanzas!int);
}

@("age.identity.MockIdentity.unwrapStanza.trichotomy")
@safe
unittest
{
    auto id = MockIdentity(0x99);
    FileKey fk;

    // not-mine → null.
    assert(id.unwrapStanza(Stanza("X25519", [], []), fk).isNull);

    // ours → success, fills the file key.
    auto ok = id.unwrapStanza(Stanza("mock", [], []), fk);
    assert(!ok.isNull);
    assert(!ok.get.hasError);
    foreach (b; fk.exposeSecret())
        assert(b == 0x99);
}

@("age.identity.unwrapStanza.dispatchesViaMock")
@safe
unittest
{
    // The dispatcher logic is identical for any member; verify it against a
    // local sum type built from the mocks so the test does not depend on the
    // native recipient modules.
    alias AnyMock = SumType!(MockIdentity, MockWholeHeaderIdentity);

    auto id = AnyMock(MockIdentity(0x55));
    FileKey fk;

    // Reuse the same dispatch shape as `unwrapStanza(AnyIdentity, …)`.
    UnwrapOutcome dispatch(in AnyMock m, in Stanza s, ref FileKey out_)
        => m.match!((ref a) => a.unwrapStanza(s, out_));

    assert(dispatch(id, Stanza("nope", [], []), fk).isNull);

    auto ok = dispatch(id, Stanza("mock", [], []), fk);
    assert(!ok.isNull && !ok.get.hasError);
    foreach (b; fk.exposeSecret())
        assert(b == 0x55);
}

@("age.identity.unwrapStanzas.fallbackLoopsUnwrapStanza")
@safe
unittest
{
    // For a member WITHOUT `hasUnwrapStanzas`, the dispatcher must scan
    // `unwrapStanza` across the header's stanzas and return the first non-null
    // outcome (rage's `find_map` default).
    alias AnyMock = SumType!(MockIdentity, MockWholeHeaderIdentity);

    UnwrapOutcome dispatchAll(in AnyMock m, in Stanza[] stanzas, ref FileKey out_)
    {
        return m.match!((ref active) {
            alias A = typeof(active);
            static if (hasUnwrapStanzas!A)
                return active.unwrapStanzas(stanzas, out_);
            else
            {
                foreach (ref s; stanzas)
                {
                    auto o = active.unwrapStanza(s, out_);
                    if (!o.isNull)
                        return o;
                }
                return unwrapSkip();
            }
        });
    }

    auto id = AnyMock(MockIdentity(0x33));
    FileKey fk;

    // A header whose second stanza is the matching "mock": the loop skips the
    // first and unwraps the second.
    auto stanzas = [Stanza("other", [], []), Stanza("mock", [], [])];
    auto ok = dispatchAll(id, stanzas, fk);
    assert(!ok.isNull && !ok.get.hasError);
    foreach (b; fk.exposeSecret())
        assert(b == 0x33);

    // A header that matches nothing → null.
    auto none = [Stanza("a", [], []), Stanza("b", [], [])];
    assert(dispatchAll(id, none, fk).isNull);
}

@("age.identity.unwrapStanzas.usesWholeHeaderCapability")
@safe
unittest
{
    // For a member WITH `hasUnwrapStanzas`, the dispatcher calls it directly —
    // here the mock requires exactly one "whole" stanza, so a multi-stanza
    // header is rejected with null even though a single one would succeed.
    alias AnyMock = SumType!(MockIdentity, MockWholeHeaderIdentity);

    UnwrapOutcome dispatchAll(in AnyMock m, in Stanza[] stanzas, ref FileKey out_)
    {
        return m.match!((ref active) {
            alias A = typeof(active);
            static if (hasUnwrapStanzas!A)
                return active.unwrapStanzas(stanzas, out_);
            else
            {
                foreach (ref s; stanzas)
                {
                    auto o = active.unwrapStanza(s, out_);
                    if (!o.isNull)
                        return o;
                }
                return unwrapSkip();
            }
        });
    }

    auto id = AnyMock(MockWholeHeaderIdentity.init);
    FileKey fk;

    // Sole "whole" stanza → success.
    auto ok = dispatchAll(id, [Stanza("whole", [], [])], fk);
    assert(!ok.isNull && !ok.get.hasError);
    foreach (b; fk.exposeSecret())
        assert(b == 0x7);

    // Two stanzas → the whole-header check rejects it (null), proving the
    // capability path, not the per-stanza loop, was taken.
    assert(dispatchAll(id, [Stanza("whole", [], []), Stanza("whole", [], [])], fk).isNull);
}

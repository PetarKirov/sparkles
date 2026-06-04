/**
 * HMAC-SHA256: the one-shot $(LREF hmacSha256) and the streaming
 * $(LREF HmacWriter) sink (§6).
 *
 * Two shapes of the same primitive:
 *
 * $(UL
 *   $(LI $(LREF hmacSha256) — a one-shot, backend-templated free function. It
 *     forwards `(key, msg)` to `B.hmacSha256` and writes the 32-byte tag. The
 *     key is $(B variable-length): HKDF-Extract (the age key-derivation path)
 *     feeds salts of arbitrary size, so the required backend surface admits any
 *     key length.)
 *   $(LI $(LREF HmacWriter) — a streaming `put`-based output range backed by
 *     libsodium's `crypto_auth_hmacsha256_state`. The age header MAC streams the
 *     exact header wire bytes into it (§7.4) without first gathering them into a
 *     contiguous buffer, then $(D finalize)s and $(D verify)s the result with a
 *     constant-time compare.)
 * )
 *
 * The one-shot routes through the configurable backend; the streaming writer
 * holds the libsodium incremental state directly via the same `@trusted`
 * function-pointer-cast attribute-laundering pattern the backend uses (the
 * ImportC declarations carry no D safety attributes). Both are
 * `@safe nothrow @nogc` but $(B not) `pure` (the libsodium boundary is not
 * modelled as pure).
 *
 * See `docs/specs/age/SPEC.md` §6 (primitives) and §7.4 (the header MAC) for
 * the normative description.
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.hmac;

import sparkles.crypto.backend : DefaultBackend, isCryptoBackend;

@safe nothrow @nogc:

/// The HMAC-SHA256 tag (and incremental-state output) width, in bytes.
enum size_t hmacSha256TagBytes = 32;

/**
 * One-shot HMAC-SHA256 of `msg` under a $(B variable-length) `key`.
 *
 * Forwards to `B.hmacSha256`, which the default $(REF SodiumBackend,
 * sparkles,crypto,backend,sodium) implements with libsodium's
 * `init`/`update`/`final` API so that keys (HKDF salts) of any length are
 * accepted.
 *
 * Params:
 *   B    = the crypto backend (defaults to $(REF DefaultBackend,
 *          sparkles,crypto,backend)); must satisfy $(REF isCryptoBackend,
 *          sparkles,crypto,backend,traits)
 *   key  = HMAC key of any length (may be empty)
 *   msg  = message bytes (may be empty)
 *   out_ = 32-byte output tag
 */
void hmacSha256(B = DefaultBackend)(scope const(ubyte)[] key,
    scope const(ubyte)[] msg, ref ubyte[hmacSha256TagBytes] out_)
if (isCryptoBackend!B)
{
    B.hmacSha256(key, msg, out_);
}

/// HMAC-SHA256 over RFC 4231 Test Case 2 (key = "Jefe").
@("crypto.hmac.hmacSha256.rfc4231.case2")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.encoding.hex : decodeHex;

    static immutable ubyte[4] key = ['J', 'e', 'f', 'e'];
    immutable(ubyte)[] data =
        cast(immutable(ubyte)[]) "what do ya want for nothing?";

    ubyte[32] tag = void;
    hmacSha256(key[], data, tag);

    ubyte[32] expected = void;
    auto r = decodeHex(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        expected[]);
    assert(r.hasValue);
    assert(tag == expected);
}

/**
 * Streaming HMAC-SHA256 output range, backed by libsodium's incremental
 * `crypto_auth_hmacsha256_state`.
 *
 * The intended consumer is the age header MAC (§7.4): the header bytes are fed
 * in as they are produced — `put(ubyte)` for a single byte, `put(slice)` for a
 * run — without first assembling them into one contiguous buffer. After all
 * bytes are streamed, $(LREF finalize) writes the 32-byte tag, or $(LREF verify)
 * compares it against an expected tag in constant time.
 *
 * The key is fixed at construction. It is $(B variable-length) (HKDF salts have
 * no fixed size), matching the one-shot $(LREF hmacSha256). A default-
 * constructed writer is unusable; construct via $(LREF HmacWriter.this) with a
 * key.
 *
 * The libsodium state must be consumed exactly once: $(LREF finalize) (and
 * therefore $(LREF verify), which calls it) MUST be called at most once per
 * writer. The writer is non-copyable to prevent two finalizers running over a
 * shared state; build a fresh writer for each MAC.
 *
 * The `@trusted` boundary is confined to the three private wrapper methods that
 * launder the ImportC functions' missing D attributes via a function-pointer
 * cast (libsodium documents these as non-allocating and non-throwing, so the
 * asserted `nothrow @nogc` is sound).
 */
struct HmacWriter
{
    import sparkles.crypto.sodium_c : crypto_auth_hmacsha256_state,
        crypto_auth_hmacsha256_init, crypto_auth_hmacsha256_update,
        crypto_auth_hmacsha256_final;

@safe nothrow @nogc:

    private crypto_auth_hmacsha256_state _state = void;

    /// No implicit copies: the incremental state must be finalized exactly
    /// once, and a copy would let two writers each finalize the same context.
    @disable this(this);

    /// A default-constructed (key-less) writer is not a valid HMAC context.
    @disable this();

    /**
     * Begin an HMAC-SHA256 computation under `key`.
     *
     * Params:
     *   key = HMAC key of any length (may be empty)
     */
    this(scope const(ubyte)[] key)
    {
        initImpl(key);
    }

    /**
     * Absorb a single byte into the running MAC.
     *
     * Params:
     *   b = the byte to append to the MAC input
     */
    void put(ubyte b)
    {
        ubyte[1] one = b;
        updateImpl(one[]);
    }

    /**
     * Absorb a run of bytes into the running MAC.
     *
     * Params:
     *   bytes = the bytes to append to the MAC input (may be empty)
     */
    void put(scope const(ubyte)[] bytes)
    {
        updateImpl(bytes);
    }

    /**
     * Finish the MAC, writing the 32-byte tag into `out_`.
     *
     * MUST be called at most once per writer; the underlying libsodium state is
     * consumed and is not valid for further `put` or `finalize` afterward.
     *
     * Params:
     *   out_ = 32-byte output tag
     */
    void finalize(ref ubyte[hmacSha256TagBytes] out_)
    {
        finalImpl(out_);
    }

    /**
     * Finish the MAC and compare it, in constant time, against `expected`.
     *
     * A constant-time compare means the running time reveals nothing about
     * which (if any) byte first differs — essential when verifying an
     * attacker-supplied header MAC (§7.4). Like $(LREF finalize), this consumes
     * the state and MUST be called at most once.
     *
     * Params:
     *   expected = the 32-byte tag to match against
     * Returns: `true` iff the computed tag equals `expected`.
     */
    bool verify(in ubyte[hmacSha256TagBytes] expected)
    {
        import sparkles.crypto.ct : ctEquals;

        ubyte[hmacSha256TagBytes] computed = void;
        finalImpl(computed);
        return ctEquals(computed[], expected[]);
    }

    // ── @trusted libsodium boundary ──────────────────────────────────────
    // The ImportC declarations are plain extern(C) with no D safety
    // attributes, so they cannot be called from @safe nothrow @nogc directly.
    // Each wrapper casts the function pointer to launder the (libsodium-
    // documented) nothrow @nogc property, matching SodiumBackend's pattern.

    private void initImpl(scope const(ubyte)[] key) @trusted
    {
        alias InitFn = extern(C) int function(
            scope crypto_auth_hmacsha256_state*, scope const(ubyte)*, size_t)
            @nogc nothrow @system;
        (cast(InitFn) &crypto_auth_hmacsha256_init)(&_state, key.ptr, key.length);
    }

    private void updateImpl(scope const(ubyte)[] bytes) @trusted
    {
        alias UpdateFn = extern(C) int function(
            scope crypto_auth_hmacsha256_state*, scope const(ubyte)*, ulong)
            @nogc nothrow @system;
        (cast(UpdateFn) &crypto_auth_hmacsha256_update)(
            &_state, bytes.ptr, bytes.length);
    }

    private void finalImpl(ref ubyte[hmacSha256TagBytes] out_) @trusted
    {
        alias FinalFn = extern(C) int function(
            scope crypto_auth_hmacsha256_state*, scope ubyte*)
            @nogc nothrow @system;
        (cast(FinalFn) &crypto_auth_hmacsha256_final)(&_state, out_.ptr);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Tests — RFC 4231 HMAC-SHA256 known-answer vectors.
//
// Each case is checked both one-shot and via HmacWriter streamed in two
// chunks; the two paths must agree with the published tag. Hex literals are
// decoded into stack buffers with sparkles.crypto.encoding.hex so the tests
// stay allocation-free.
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

    /// Run one RFC 4231 vector: compute the tag one-shot, and again by
    /// streaming the data into an `HmacWriter` split at `splitAt`; assert both
    /// match the expected tag and that `verify` agrees.
    private void checkRfc4231(scope const(ubyte)[] key, scope const(ubyte)[] data,
        in ubyte[32] expected, size_t splitAt) @safe nothrow @nogc
    {
        // One-shot.
        ubyte[32] oneShot = void;
        hmacSha256(key, data, oneShot);
        assert(oneShot == expected, "one-shot tag mismatch");

        // Streamed in two chunks: [0 .. splitAt] then [splitAt .. $].
        ubyte[32] streamed = void;
        {
            auto w = HmacWriter(key);
            w.put(data[0 .. splitAt]);
            w.put(data[splitAt .. $]);
            w.finalize(streamed);
        }
        assert(streamed == expected, "streamed tag mismatch");
        assert(streamed == oneShot, "streamed and one-shot disagree");

        // verify() must accept the right tag and reject a tampered one.
        {
            auto w = HmacWriter(key);
            w.put(data);
            assert(w.verify(expected), "verify rejected the correct tag");
        }
        {
            ubyte[32] wrong = expected;
            wrong[0] ^= 0x01;
            auto w = HmacWriter(key);
            w.put(data);
            assert(!w.verify(wrong), "verify accepted a tampered tag");
        }
    }
}

/// RFC 4231 Test Case 1: key = 0x0b × 20, data = "Hi There". One-shot and the
/// two-chunk `HmacWriter` stream both match the published tag.
@("crypto.hmac.rfc4231.case1")
@safe nothrow @nogc
unittest
{
    ubyte[20] key = 0x0b;
    static immutable ubyte[8] data = ['H', 'i', ' ', 'T', 'h', 'e', 'r', 'e'];

    const expected = fromHex!32(
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");

    // Split "Hi There" as "Hi " ‖ "There".
    checkRfc4231(key[], data[], expected, 3);
}

/// RFC 4231 Test Case 2: key = "Jefe", data = "what do ya want for nothing?".
/// Exercises a short, variable-length key; one-shot and the two-chunk stream
/// both match the published tag.
@("crypto.hmac.rfc4231.case2")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[4] key = ['J', 'e', 'f', 'e'];
    immutable(ubyte)[] data =
        cast(immutable(ubyte)[]) "what do ya want for nothing?";

    const expected = fromHex!32(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    // Split at "what do ya " ‖ "want for nothing?".
    checkRfc4231(key[], data, expected, 11);
}

/// The `HmacWriter` is an output range: byte-at-a-time `put(ubyte)` produces
/// the same tag as one-shot HMAC over the whole message.
@("crypto.hmac.HmacWriter.byteAtATime")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[4] key = ['J', 'e', 'f', 'e'];
    immutable(ubyte)[] data =
        cast(immutable(ubyte)[]) "what do ya want for nothing?";

    const expected = fromHex!32(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    ubyte[32] tag = void;
    auto w = HmacWriter(key[]);
    foreach (b; data)
        w.put(b);
    w.finalize(tag);
    assert(tag == expected);
}

/// An `HmacWriter` over no input produces the HMAC of the empty message —
/// matching the one-shot path with an empty message.
@("crypto.hmac.HmacWriter.emptyMessage")
@safe nothrow @nogc
unittest
{
    static immutable ubyte[4] key = ['J', 'e', 'f', 'e'];

    ubyte[32] oneShot = void;
    hmacSha256(key[], null, oneShot);

    ubyte[32] streamed = void;
    auto w = HmacWriter(key[]);
    w.finalize(streamed);

    assert(streamed == oneShot);
}

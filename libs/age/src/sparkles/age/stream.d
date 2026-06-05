/**
The age STREAM payload codec (§7.5).

The age payload is the file body encrypted with the
[STREAM](https://eprint.iacr.org/2015/189.pdf) construction, instantiated with
ChaCha20-Poly1305 over fixed 64 KiB plaintext chunks. Each chunk is sealed
under the 32-byte payload key and a [aead.StreamNonce]: an 11-byte big-endian
chunk counter (from zero) followed by a 1-byte last-chunk flag (`0x01` for the
final chunk, `0x00` otherwise). The final chunk MAY be shorter than 64 KiB but
MUST NOT be empty $(I unless) the whole payload is empty (in which case the
payload is exactly one empty final chunk — a bare 16-byte tag). Decryption MUST
error if EOF is reached without a valid final chunk.

This module is a faithful port of rage's `age/src/primitives/stream.rs`
(`Stream`, `StreamWriter`, `StreamReader`), restructured to the `sparkles`
conventions: `@safe` throughout, `Expected`-based errors
([errors.DecryptError]), output-range writers, and a mandatory
$(LREF StreamWriter.finish). It offers two layers:

$(UL
    $(LI the one-shot helpers $(LREF streamEncrypt) / $(LREF streamDecrypt) for
        in-memory payloads (used by the M6 simple API);)
    $(LI the streaming $(LREF StreamWriter) / $(LREF StreamReader) for large data
        that should not be fully buffered.)
)

`@nogc` is $(I not) required at this layer (the AEAD primitive itself is
`@safe nothrow @nogc` but not `pure`, so neither are these), and the GC is used
for the owned ciphertext/plaintext slices. The STREAM hot path still avoids
needless per-chunk allocation where it can.

See `docs/specs/age/SPEC.md` §7.5 and `https://c2sp.org/age` ("Payload").

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.stream;

import std.range.primitives : isOutputRange;

import sparkles.age.errors : DecryptErrorCode, DecryptExpected,
    decryptOk, decryptErr;
import sparkles.crypto.aead : aeadOpen, aeadSeal, ChaCha20Poly1305, StreamNonce;
import sparkles.crypto.zeroize : zeroizeMemory;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// STREAM sizing constants
// ─────────────────────────────────────────────────────────────────────────────

/// Plaintext bytes per STREAM chunk: 64 KiB.
enum size_t CHUNK_SIZE = 64 * 1024;

/// ChaCha20-Poly1305 authentication-tag size, in bytes.
enum size_t TAG_SIZE = ChaCha20Poly1305.TAG_SIZE;

/// Ciphertext bytes per full STREAM chunk: a 64 KiB chunk plus its 16-byte tag.
enum size_t ENC_CHUNK_SIZE = CHUNK_SIZE + TAG_SIZE;

static assert(TAG_SIZE == 16, "the STREAM AEAD tag is 16 bytes (Poly1305)");

// ─────────────────────────────────────────────────────────────────────────────
// One-shot helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
Encrypts an in-memory `plaintext` payload under `payloadKey`, returning the
STREAM ciphertext (allocated on the GC heap).

The plaintext is split into $(LREF CHUNK_SIZE)-byte chunks; every chunk but the
last is sealed with the last-chunk flag clear, and the final (possibly short,
possibly — for an empty payload — empty) chunk is sealed with the flag set. An
empty `plaintext` therefore produces a single empty final chunk: exactly
$(LREF TAG_SIZE) (16) bytes of ciphertext.

`payloadKey` MUST be unique to this stream; age guarantees this by deriving it
via HKDF from a fresh file key and a fresh per-file nonce (§7.5).

Params:
    payloadKey = the 32-byte STREAM payload key (HKDF-derived, §7.5)
    plaintext  = the payload to encrypt (may be empty)
Returns: the STREAM ciphertext (`plaintext.length + ceil/chunks * TAG_SIZE`
    bytes).
*/
ubyte[] streamEncrypt(in ubyte[32] payloadKey, scope const(ubyte)[] plaintext)
{
    // Number of plaintext chunks: at least one, even for the empty payload
    // (which becomes a single empty final chunk).
    const size_t numChunks = plaintext.length == 0
        ? 1
        : (plaintext.length + CHUNK_SIZE - 1) / CHUNK_SIZE;

    auto ciphertext = new ubyte[plaintext.length + numChunks * TAG_SIZE];

    StreamNonce nonce;
    size_t ptPos;
    size_t ctPos;
    foreach (chunkIndex; 0 .. numChunks)
    {
        const bool last = chunkIndex + 1 == numChunks;
        const size_t take = plaintext.length - ptPos < CHUNK_SIZE
            ? plaintext.length - ptPos
            : CHUNK_SIZE;
        const chunk = plaintext[ptPos .. ptPos + take];

        nonce.setLast(last);
        aeadSeal(payloadKey, nonce.bytes, chunk, null,
            ciphertext[ctPos .. ctPos + take + TAG_SIZE]);

        ptPos += take;
        ctPos += take + TAG_SIZE;
        if (!last)
            nonce.incrementCounter();
    }

    return ciphertext;
}

/**
Decrypts an in-memory STREAM `ciphertext` under `payloadKey`, returning the
recovered plaintext (allocated on the GC heap).

The ciphertext is split into $(LREF ENC_CHUNK_SIZE)-byte chunks; a chunk shorter
than that is the final chunk. A chunk that authenticates only as a non-final
chunk when expected to be last (the exact-multiple-of-chunk-size edge case) is
retried as a final chunk, matching rage. A final chunk that decrypts to empty is
only legal when it is the entire payload — an empty final chunk after earlier
plaintext is a `payloadError`.

Params:
    payloadKey = the 32-byte STREAM payload key (HKDF-derived, §7.5)
    ciphertext = the STREAM ciphertext (at least one chunk)
Returns: $(LREF DecryptExpected)`!(ubyte[])` — the plaintext on success;
    $(D DecryptErrorCode.truncatedPayload) if the ciphertext ends before a valid
    final chunk; $(D DecryptErrorCode.payloadError) if a chunk fails to
    authenticate or violates the chunking rules.
*/
DecryptExpected!(ubyte[]) streamDecrypt(
    in ubyte[32] payloadKey, scope const(ubyte)[] ciphertext)
{
    // A ciphertext that cannot even hold one chunk's tag carries no valid final
    // chunk. Guarding `< TAG_SIZE` (rather than `== 0`) is what keeps the
    // upper-bound below from underflowing on a sub-tag input.
    if (ciphertext.length < TAG_SIZE)
        return decryptErr!(ubyte[])(DecryptErrorCode.truncatedPayload);

    // Upper bound on the recovered plaintext. Every chunk strips a 16-byte tag,
    // so the final plaintext is `ciphertext.length - numChunks * TAG_SIZE`; but
    // that total can under-allocate relative to an *intermediate* `ptPos` (a full
    // leading chunk yields CHUNK_SIZE plaintext, while the formula front-loads the
    // tag deduction for every chunk, including a short trailing one). Sizing the
    // buffer at `ciphertext.length - TAG_SIZE` — at least one chunk is always
    // present, so this never underflows — is a safe bound: after k≥1 chunks the
    // running `ptPos` is `(sum of takes) - k*TAG_SIZE ≤ ciphertext.length - TAG_SIZE`.
    // The result is trimmed to the exact `ptPos` on return.
    auto plaintext = new ubyte[ciphertext.length - TAG_SIZE];

    StreamNonce nonce;
    size_t ctPos;
    size_t ptPos;
    bool sawLast;
    while (ctPos < ciphertext.length)
    {
        const size_t remaining = ciphertext.length - ctPos;
        const size_t take = remaining < ENC_CHUNK_SIZE ? remaining : ENC_CHUNK_SIZE;

        // A short chunk is unambiguously the final chunk. A full chunk is the
        // final chunk only when no ciphertext follows it (the exact-multiple
        // edge case), where we first try it as non-last and fall back to last.
        const bool short_ = take < ENC_CHUNK_SIZE;
        const bool moreFollows = ctPos + take < ciphertext.length;

        // Every chunk must carry the tag; otherwise the input is truncated.
        if (take < TAG_SIZE)
        {
            zeroizeMemory(plaintext);
            return decryptErr!(ubyte[])(DecryptErrorCode.truncatedPayload);
        }

        const encChunk = ciphertext[ctPos .. ctPos + take];
        const size_t ptLen = take - TAG_SIZE;
        auto outChunk = plaintext[ptPos .. ptPos + ptLen];

        bool ok;
        bool last;
        if (short_)
        {
            // Genuinely the last chunk.
            last = true;
            nonce.setLast(true);
            ok = aeadOpen(payloadKey, nonce.bytes, encChunk, null, outChunk);
        }
        else if (moreFollows)
        {
            // A full chunk with more data after it: a non-final chunk.
            last = false;
            nonce.setLast(false);
            ok = aeadOpen(payloadKey, nonce.bytes, encChunk, null, outChunk);
        }
        else
        {
            // A full chunk with nothing after it (length is an exact multiple
            // of ENC_CHUNK_SIZE). Try non-last first, then last.
            nonce.setLast(false);
            ok = aeadOpen(payloadKey, nonce.bytes, encChunk, null, outChunk);
            if (ok)
            {
                last = false;
            }
            else
            {
                // Retry the same chunk as the final chunk.
                nonce.setLast(true);
                ok = aeadOpen(payloadKey, nonce.bytes, encChunk, null, outChunk);
                last = true;
            }
        }

        if (!ok)
        {
            // Wipe any plaintext recovered so far before surfacing the error.
            zeroizeMemory(plaintext);
            return decryptErr!(ubyte[])(DecryptErrorCode.payloadError);
        }

        // An empty final chunk is legal only as the whole payload.
        if (last && ptLen == 0 && ptPos > 0)
        {
            zeroizeMemory(plaintext);
            return decryptErr!(ubyte[])(DecryptErrorCode.payloadError);
        }

        ptPos += ptLen;
        ctPos += take;
        if (last)
        {
            sawLast = true;
            break;
        }
        nonce.incrementCounter();
    }

    if (!sawLast)
    {
        zeroizeMemory(plaintext);
        return decryptErr!(ubyte[])(DecryptErrorCode.truncatedPayload);
    }

    // `plaintext` was sized as an upper bound; the empty-payload case (one empty
    // final chunk) and any short final chunk leave it exactly right because the
    // tag accounting is exact per chunk. Trim defensively in case of the
    // exact-multiple fallthrough.
    return decryptOk(plaintext[0 .. ptPos]);
}

// ─────────────────────────────────────────────────────────────────────────────
// StreamWriter — incremental encryption around a caller output range
// ─────────────────────────────────────────────────────────────────────────────

/**
Wraps STREAM encryption around a caller output range `W`, encrypting plaintext
incrementally as it is written.

`put` buffers up to $(LREF CHUNK_SIZE) plaintext bytes; once a full chunk has
accumulated $(I and) more data follows, that chunk is sealed (last-chunk flag
clear) and flushed to the wrapped output. The final chunk — the buffered
remainder, which is empty only when the whole payload was empty — is emitted by
$(LREF finish), which is $(B mandatory): without it the produced file is
truncated and will fail to decrypt.

The wrapped output is held $(B by pointer): an output range such as
[smallbuffer.SmallBuffer] is non-copyable, so the writer must not copy it. The
caller therefore keeps `output` alive for the writer's whole lifetime.

In `debug` builds, destroying a `StreamWriter` whose $(LREF finish) was never
called trips an `assert(false)`, catching the truncation bug at its source.

Params:
    W = the wrapped output range; must accept `const(ubyte)[]`.
*/
struct StreamWriter(W)
if (isOutputRange!(W, const(ubyte)[]))
{
    @disable this(this);

    private
    {
        W* _output;
        ubyte[32] _payloadKey;
        StreamNonce _nonce;
        // Buffered plaintext for the current (not-yet-flushed) chunk.
        ubyte[] _chunk;
        size_t _chunkLen;
        bool _finished;
    }

    @disable this();

    /**
    Constructs a writer that seals plaintext under `payloadKey` into `output`.

    Params:
        payloadKey = the 32-byte STREAM payload key (HKDF-derived, §7.5)
        output     = the wrapped output range, held by pointer for the writer's
            lifetime
    */
    this(in ubyte[32] payloadKey, return ref W output) @trusted
    {
        _output = &output;
        _payloadKey = payloadKey;
        _chunk = new ubyte[CHUNK_SIZE];
        _chunkLen = 0;
        _finished = false;
    }

    /**
    Buffers `data` and flushes complete non-final chunks to the wrapped output.

    A full $(LREF CHUNK_SIZE) chunk is sealed and flushed only when more data
    follows; the trailing partial (or full) chunk is left buffered for
    $(LREF finish).
    */
    void put(scope const(ubyte)[] data)
    in (!_finished, "StreamWriter.put after finish()")
    {
        while (data.length != 0)
        {
            const size_t space = CHUNK_SIZE - _chunkLen;
            const size_t take = data.length < space ? data.length : space;
            _chunk[_chunkLen .. _chunkLen + take] = data[0 .. take];
            _chunkLen += take;
            data = data[take .. $];

            // Either `data` is now empty or we just completed a full chunk.
            // Only flush a full chunk when more data follows: the final chunk
            // must be written by finish().
            if (data.length != 0)
            {
                assert(_chunkLen == CHUNK_SIZE,
                    "StreamWriter: data remains but chunk is not full");
                flushChunk(false);
            }
        }
    }

    /// Seals the buffered chunk (last-chunk flag = `last`) and writes it out.
    private void flushChunk(bool last)
    {
        ubyte[ENC_CHUNK_SIZE] enc = void;
        _nonce.setLast(last);
        aeadSeal(_payloadKey, _nonce.bytes, _chunk[0 .. _chunkLen], null,
            enc[0 .. _chunkLen + TAG_SIZE]);
        (*_output).put(cast(const(ubyte)[]) enc[0 .. _chunkLen + TAG_SIZE]);
        _chunkLen = 0;
        if (!last)
            _nonce.incrementCounter();
    }

    /**
    Emits the final chunk and completes the stream. $(B Mandatory.)

    Seals the buffered remainder with the last-chunk flag set (an empty buffer
    yields a bare 16-byte tag — the empty-payload case) and writes it to the
    wrapped output. Calling `finish` more than once is a no-op after the first.
    */
    void finish()
    {
        if (_finished)
            return;
        flushChunk(true);
        _finished = true;
    }

    /// Trips in `debug` builds if $(LREF finish) was never called (the produced
    /// file would be truncated). The GC-owned working buffer is reclaimed
    /// normally; nothing else needs releasing here.
    ~this()
    {
        debug assert(_finished,
            "StreamWriter destroyed without calling finish(): the file is truncated");
    }
}

/**
Convenience factory for $(LREF StreamWriter), inferring the output-range type.

Params:
    payloadKey = the 32-byte STREAM payload key (HKDF-derived, §7.5)
    output     = the wrapped output range, held by pointer for the writer's
        lifetime
Returns: a `StreamWriter!W` sealing into `output`.
*/
StreamWriter!W streamWriter(W)(in ubyte[32] payloadKey, return ref W output)
if (isOutputRange!(W, const(ubyte)[]))
{
    return StreamWriter!W(payloadKey, output);
}

// ─────────────────────────────────────────────────────────────────────────────
// StreamReader — bulk decryption over a ciphertext slice
// ─────────────────────────────────────────────────────────────────────────────

/**
Decrypts a STREAM ciphertext held entirely in memory, exposing it through a
bulk $(LREF readAll).

This is the slice-backed analogue of rage's `StreamReader`: it owns no I/O, just
a borrowed view of the ciphertext, and applies the same chunking and
final-chunk rules as $(LREF streamDecrypt). Seekable decryption (rage's `Seek`
impl) is designed-for but intentionally deferred.

The reader borrows the `ciphertext` slice for its lifetime and does not copy it.
*/
struct StreamReader
{
    private const(ubyte)[] _ciphertext;
    private ubyte[32] _payloadKey;

    @disable this();

    /**
    Constructs a reader over `ciphertext`, decrypting under `payloadKey`.

    The `ciphertext` slice is borrowed (its reference is stored, not its
    bytes); the caller MUST keep it alive for the reader's lifetime.

    Params:
        payloadKey = the 32-byte STREAM payload key (HKDF-derived, §7.5)
        ciphertext = the STREAM ciphertext to decrypt (borrowed, not copied)
    */
    this(in ubyte[32] payloadKey, const(ubyte)[] ciphertext) @safe
    {
        _payloadKey = payloadKey;
        _ciphertext = ciphertext;
    }

    /**
    Decrypts the whole ciphertext and returns the plaintext (GC-allocated).

    Equivalent to $(LREF streamDecrypt) over the borrowed ciphertext; the same
    `truncatedPayload` / `payloadError` semantics apply.

    Returns: $(LREF DecryptExpected)`!(ubyte[])` — the plaintext or a
        $(LREF errors.DecryptError).
    */
    DecryptExpected!(ubyte[]) readAll()
    {
        return streamDecrypt(_payloadKey, _ciphertext);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    /// A fixed, non-trivial 32-byte payload key used across the round-trip
    /// tests. Bytes 0..31; the value itself is irrelevant, only that encrypt
    /// and decrypt share it.
    private ubyte[32] testKey() @safe pure nothrow @nogc
    {
        ubyte[32] k = void;
        foreach (i; 0 .. 32)
            k[i] = cast(ubyte)(i * 7 + 3);
        return k;
    }

    /// A deterministic `length`-byte plaintext (a simple byte ramp), so the
    /// round-trip assertions don't depend on a CSPRNG.
    private ubyte[] ramp(size_t length) @safe pure nothrow
    {
        auto p = new ubyte[length];
        foreach (i; 0 .. length)
            p[i] = cast(ubyte)(i & 0xFF);
        return p;
    }
}

/// One-shot round-trip across the payload sizes that exercise every chunking
/// boundary: empty, one byte, exactly one chunk, one-past-a-chunk, and just
/// over two chunks.
@("age.stream.roundTrip.sizes")
@safe
unittest
{
    const key = testKey();

    foreach (len; [
        cast(size_t) 0,
        1,
        CHUNK_SIZE,
        CHUNK_SIZE + 1,
        2 * CHUNK_SIZE + 5,
    ])
    {
        const plaintext = ramp(len);
        const ciphertext = streamEncrypt(key, plaintext);

        const decrypted = streamDecrypt(key, ciphertext);
        assert(decrypted.hasValue, "streamDecrypt failed on a valid ciphertext");
        assert(decrypted.value == plaintext, "round-trip plaintext mismatch");
    }
}

/// The empty payload encrypts to exactly one empty final chunk — a bare
/// 16-byte tag — and decrypts back to an empty plaintext.
@("age.stream.empty.singleTagChunk")
@safe
unittest
{
    const key = testKey();

    const ciphertext = streamEncrypt(key, []);
    assert(ciphertext.length == TAG_SIZE,
        "an empty payload must encrypt to exactly one 16-byte tag");

    const decrypted = streamDecrypt(key, ciphertext);
    assert(decrypted.hasValue, "empty-payload ciphertext failed to decrypt");
    assert(decrypted.value.length == 0, "empty payload did not decrypt to empty");
}

/// A multi-chunk payload produces ciphertext of the expected length: every
/// chunk adds its 16-byte tag.
@("age.stream.encrypt.ciphertextLength")
@safe
unittest
{
    const key = testKey();

    // Just over two chunks => three chunks => three tags.
    const len = 2 * CHUNK_SIZE + 5;
    const ciphertext = streamEncrypt(key, ramp(len));
    assert(ciphertext.length == len + 3 * TAG_SIZE,
        "ciphertext length must be plaintext + one tag per chunk");
}

/// Flipping a single ciphertext byte makes `streamDecrypt` fail with
/// `payloadError` (a per-chunk authentication failure).
@("age.stream.tampered.payloadError")
@safe
unittest
{
    const key = testKey();

    auto ciphertext = streamEncrypt(key, ramp(CHUNK_SIZE + 100));
    // Tamper with a byte in the first chunk.
    ciphertext[10] ^= 0x01;

    const decrypted = streamDecrypt(key, ciphertext);
    assert(!decrypted.hasValue, "a tampered ciphertext must not decrypt");
    assert(decrypted.error.code == DecryptErrorCode.payloadError,
        "tampering must surface as a payloadError");
}

/// Tampering with the tag of the final chunk also surfaces as `payloadError`.
@("age.stream.tamperedTag.payloadError")
@safe
unittest
{
    const key = testKey();

    auto ciphertext = streamEncrypt(key, ramp(1024));
    ciphertext[$ - 1] ^= 0x80; // last byte is part of the final chunk's tag

    const decrypted = streamDecrypt(key, ciphertext);
    assert(!decrypted.hasValue);
    assert(decrypted.error.code == DecryptErrorCode.payloadError);
}

/// A ciphertext truncated before a valid final chunk — here, a two-chunk
/// payload with its entire (last) final chunk dropped — fails with
/// `truncatedPayload`. `2 * CHUNK_SIZE` plaintext is exactly two chunks: chunk
/// 0 sealed non-last and chunk 1 sealed last. Dropping chunk 1 leaves a single
/// full chunk that authenticates only as a non-last chunk, so the stream ends
/// without ever seeing a last-flagged chunk.
@("age.stream.truncated.truncatedPayload")
@safe
unittest
{
    const key = testKey();

    const plaintext = ramp(2 * CHUNK_SIZE);
    const full = streamEncrypt(key, plaintext);
    assert(full.length == 2 * ENC_CHUNK_SIZE);

    // Keep only chunk 0 (a full non-last chunk); drop the entire last chunk.
    const truncated = full[0 .. ENC_CHUNK_SIZE];

    const decrypted = streamDecrypt(key, truncated);
    assert(!decrypted.hasValue, "a truncated stream must not decrypt");
    assert(decrypted.error.code == DecryptErrorCode.truncatedPayload,
        "dropping the final chunk must surface as truncatedPayload");
}

/// An entirely empty ciphertext (no chunks at all) is a truncated payload.
@("age.stream.emptyCiphertext.truncatedPayload")
@safe
unittest
{
    const key = testKey();

    const decrypted = streamDecrypt(key, []);
    assert(!decrypted.hasValue);
    assert(decrypted.error.code == DecryptErrorCode.truncatedPayload);
}

/// Dropping the short final chunk of a payload whose last chunk is partial also
/// yields `truncatedPayload` (the remaining full chunk authenticates only as a
/// non-final chunk, so the stream is incomplete).
@("age.stream.truncatedPartial.truncatedPayload")
@safe
unittest
{
    const key = testKey();

    // One full chunk + a short final chunk.
    const plaintext = ramp(CHUNK_SIZE + 50);
    const full = streamEncrypt(key, plaintext);
    // Keep only the first (full) chunk.
    const truncated = full[0 .. ENC_CHUNK_SIZE];

    const decrypted = streamDecrypt(key, truncated);
    assert(!decrypted.hasValue);
    assert(decrypted.error.code == DecryptErrorCode.truncatedPayload);
}

/// The `StreamWriter` round-trips through a caller output range: writing the
/// plaintext in several uneven `put`s then `finish()` produces a ciphertext
/// identical to the one-shot `streamEncrypt`, which `streamDecrypt` recovers.
@("age.stream.StreamWriter.roundTrip")
@safe
unittest
{
    const key = testKey();
    const plaintext = ramp(2 * CHUNK_SIZE + 1234);

    SmallBuffer!(ubyte, 64) out_;
    {
        auto w = streamWriter(key, out_);
        // Feed the plaintext in awkward slices that straddle chunk boundaries.
        size_t pos;
        foreach (step; [cast(size_t) 100, CHUNK_SIZE - 50, 7, CHUNK_SIZE, 999])
        {
            const end = pos + step < plaintext.length ? pos + step : plaintext.length;
            w.put(plaintext[pos .. end]);
            pos = end;
        }
        if (pos < plaintext.length)
            w.put(plaintext[pos .. $]);
        w.finish();
    }

    // Byte-identical to the one-shot encoder.
    const oneShot = streamEncrypt(key, plaintext);
    assert(out_[] == oneShot, "StreamWriter output diverged from streamEncrypt");

    const decrypted = streamDecrypt(key, out_[]);
    assert(decrypted.hasValue);
    assert(decrypted.value == plaintext);
}

/// A `StreamWriter` that never receives any data still produces the single
/// empty final chunk on `finish()` — the empty-payload form.
@("age.stream.StreamWriter.empty")
@safe
unittest
{
    const key = testKey();

    SmallBuffer!(ubyte, 64) out_;
    {
        auto w = streamWriter(key, out_);
        w.finish();
    }

    assert(out_.length == TAG_SIZE, "an empty StreamWriter must emit one tag");
    assert(out_[] == streamEncrypt(key, []));
}

/// `StreamReader.readAll` decrypts a borrowed ciphertext exactly like
/// `streamDecrypt`.
@("age.stream.StreamReader.readAll")
@safe
unittest
{
    const key = testKey();
    const plaintext = ramp(CHUNK_SIZE + 1);
    const ciphertext = streamEncrypt(key, plaintext);

    auto reader = StreamReader(key, ciphertext);
    const decrypted = reader.readAll();
    assert(decrypted.hasValue);
    assert(decrypted.value == plaintext);
}

/// `finish()` is mandatory: a `StreamWriter` destroyed without it trips a
/// `debug` `assert`. We confirm the assertion fires (in `debug` builds) by
/// letting the writer fall out of a nested scope without `finish()` and
/// catching the `AssertError` its destructor throws.
@("age.stream.StreamWriter.finishMandatory")
@system
unittest
{
    import core.exception : AssertError;

    const key = testKey();
    SmallBuffer!(ubyte, 64) out_;

    bool tripped = false;
    try
    {
        // Inner scope: the writer's destructor runs (exactly once) at the
        // closing brace, before `out_` is destroyed. With finish() skipped it
        // must throw in debug builds.
        auto w = streamWriter(key, out_);
        w.put(cast(const(ubyte)[]) "data");
    }
    catch (AssertError)
        tripped = true;

    // In release builds the assert is compiled out; only require it in debug.
    debug assert(tripped,
        "destroying a StreamWriter without finish() must trip the debug assert");
}

/// A `StreamWriter` whose `finish()` is called normally must NOT trip the
/// destructor assert (the common, correct path).
@("age.stream.StreamWriter.finishNoAssert")
@safe
unittest
{
    const key = testKey();

    SmallBuffer!(ubyte, 64) out_;
    auto w = streamWriter(key, out_);
    w.put(cast(const(ubyte)[]) "hello world");
    w.finish();
    // Destructor runs at scope exit; with finish() called it must be silent.
}

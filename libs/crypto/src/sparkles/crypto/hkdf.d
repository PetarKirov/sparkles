/**
 * HKDF-SHA256 key derivation (RFC 5869), built from the backend's HMAC-SHA256.
 *
 * libsodium has no HKDF primitive, so HKDF is assembled here in pure D from a
 * crypto backend's $(B variable-length-key) `hmacSha256`. The three public
 * functions mirror RFC 5869:
 *
 * $(UL
 *   $(LI $(LREF hkdfExtract) — `PRK = HMAC-SHA256(salt, IKM)` (§2.2);)
 *   $(LI $(LREF hkdfExpand) — `OKM = T(1) ‖ T(2) ‖ … ‖ T(N)` (§2.3);)
 *   $(LI $(LREF hkdfSha256) — the combined extract-then-expand convenience,
 *     `hkdf(salt, label, ikm)` as used throughout age.)
 * )
 *
 * Per RFC 5869 §2.2, when `salt` is empty $(LREF hkdfExtract) substitutes a
 * `HashLen` (32) byte string of zeros. The expand step is bounded at
 * `255 * 32 = 8160` output bytes (RFC 5869 §2.3, `L <= 255 * HashLen`).
 *
 * Every function is templated on the crypto backend (`B = DefaultBackend`,
 * SPEC §4.1) and constrained on $(REF isCryptoBackend,
 * sparkles,crypto,backend,traits). They use fixed stack buffers for the
 * intermediate `T(n)` blocks, so they stay `@safe nothrow @nogc` (but, like
 * all libsodium-backed code, $(B not) `pure`; SPEC §6).
 *
 * See `docs/specs/age/SPEC.md` §6 (Primitives) for the normative description.
 *
 * Copyright: © 2026, Petar Kirov
 * License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Petar Kirov
 */
module sparkles.crypto.hkdf;

import sparkles.crypto.backend : DefaultBackend, isCryptoBackend;

@safe nothrow @nogc:

/// SHA-256 output length in bytes — the HKDF `HashLen` (RFC 5869).
private enum size_t hashLen = 32;

/// Maximum output length of a single HKDF-Expand: `255 * HashLen` (RFC 5869
/// §2.3). Exposed so callers can size output buffers and assert against it.
enum size_t hkdfMaxExpandLength = 255 * hashLen;

/**
 * HKDF-Extract (RFC 5869 §2.2): `PRK = HMAC-SHA256(salt, IKM)`.
 *
 * The `salt` is the HMAC key and the input keying material `ikm` is the HMAC
 * message. Per §2.2, an empty `salt` is replaced by a `HashLen`-byte (32) block
 * of zeros, so the two calls below are equivalent for an absent salt.
 *
 * Params:
 *   B    = the crypto backend (defaults to the libsodium-backed
 *          $(REF DefaultBackend, sparkles,crypto,backend))
 *   salt = optional salt (the HMAC key); empty selects the 32 zero-byte salt
 *   ikm  = input keying material (the HMAC message)
 *   prk  = 32-byte output pseudorandom key
 */
void hkdfExtract(B = DefaultBackend)(
    scope const(ubyte)[] salt, scope const(ubyte)[] ikm, ref ubyte[hashLen] prk)
if (isCryptoBackend!B)
{
    if (salt.length == 0)
    {
        // RFC 5869 §2.2: when not provided, the salt is HashLen zero bytes.
        static immutable ubyte[hashLen] zeroSalt = 0;
        B.hmacSha256(zeroSalt[], ikm, prk);
    }
    else
    {
        B.hmacSha256(salt, ikm, prk);
    }
}

/**
 * HKDF-Expand (RFC 5869 §2.3): expand a pseudorandom key `prk` into `okm`.
 *
 * Computes `T(1) ‖ T(2) ‖ … ‖ T(N)` where
 * `T(0) = ""`, `T(n) = HMAC-SHA256(prk, T(n-1) ‖ info ‖ byte(n))`, and copies
 * the leading `okm.length` bytes into `okm`. The output length is bounded at
 * $(LREF hkdfMaxExpandLength) (`255 * 32`), enforced by an `in` contract.
 *
 * Params:
 *   B    = the crypto backend
 *   prk  = 32-byte pseudorandom key from $(LREF hkdfExtract)
 *   info = optional context/label string
 *   okm  = output keying material; `okm.length` MUST be `<= 255 * 32`
 */
void hkdfExpand(B = DefaultBackend)(
    in ubyte[hashLen] prk, scope const(ubyte)[] info, ubyte[] okm)
if (isCryptoBackend!B)
in (okm.length <= hkdfMaxExpandLength,
    "hkdfExpand: okm.length must be <= 255 * 32")
{
    if (okm.length == 0)
        return;

    // T(0) is the empty string. Each round computes a full 32-byte block T(n)
    // into `t` and copies out only what `okm` still needs. `prev` is the slice
    // of the previous block carried forward (empty for the first block). The
    // `hmacBlock` helper stages `prev ‖ info ‖ counter` into a separate buffer
    // before writing `t`, so recomputing T(n) into `t` while `prev` aliases it
    // is sound.
    ubyte[hashLen] t = void;
    size_t produced = 0;
    ubyte counter = 0;
    scope const(ubyte)[] prev = null;

    while (produced < okm.length)
    {
        ++counter; // RFC 5869: T(1) uses byte 0x01, T(2) 0x02, …

        // T(n) = HMAC(prk, T(n-1) ‖ info ‖ counter).
        hmacBlock!B(prk, prev, info, counter, t);

        const remaining = okm.length - produced;
        const take = remaining < hashLen ? remaining : hashLen;
        okm[produced .. produced + take] = t[0 .. take];
        produced += take;

        prev = t[]; // T(n) feeds the next round.
    }
}

/**
 * Compute one HKDF-Expand block `HMAC-SHA256(prk, prev ‖ info ‖ counter)`.
 *
 * The backend's `hmacSha256` is one-shot over a single message slice, but the
 * HKDF message is three concatenated pieces. To stay allocation-free we
 * assemble `prev ‖ info ‖ counter` into a single fixed stack buffer of
 * `hashLen + hkdfInfoMax + 1` bytes and HMAC it in one call. `prev` is at most
 * `HashLen` (32) bytes and `counter` is one byte; `info` is bounded by
 * $(LREF hkdfInfoMax). Age `info` labels are short (e.g. "header", "payload",
 * "key"), so the fixed bound is never reached in practice; the `in` contract
 * enforces it regardless.
 *
 * Params:
 *   prk     = 32-byte pseudorandom key (the HMAC key)
 *   prev    = previous block `T(n-1)` (empty for `T(1)`)
 *   info    = context/label
 *   counter = the block index byte `n`
 *   out_    = 32-byte output block `T(n)`
 */
private void hmacBlock(B)(
    in ubyte[hashLen] prk, scope const(ubyte)[] prev, scope const(ubyte)[] info,
    ubyte counter, ref ubyte[hashLen] out_) @safe nothrow @nogc
in (info.length <= hkdfInfoMax,
    "hkdfExpand: info too long for the staging buffer")
{
    // Stage `prev ‖ info ‖ counter` into one slice and HMAC it in a single
    // call. prev is at most HashLen (32) bytes, plus the 1 counter byte, plus
    // info (bounded by hkdfInfoMax).
    ubyte[hashLen + hkdfInfoMax + 1] staging = void;
    size_t n = 0;

    staging[n .. n + prev.length] = prev[];
    n += prev.length;
    staging[n .. n + info.length] = info[];
    n += info.length;
    staging[n] = counter;
    ++n;

    B.hmacSha256(prk[], staging[0 .. n], out_);
}

/// Maximum `info` length supported by $(LREF hkdfExpand)'s staging buffer.
/// Age labels are short; 256 bytes is far beyond any age use and keeps the
/// stack staging buffer small.
private enum size_t hkdfInfoMax = 256;

/**
 * Combined HKDF-SHA256 (extract then expand): `hkdf(salt, label, ikm)`.
 *
 * This is the form used throughout age — `OKM = HKDF-Expand(HKDF-Extract(salt,
 * ikm), info)`. It runs $(LREF hkdfExtract) into an internal PRK, then
 * $(LREF hkdfExpand) into `okm`.
 *
 * Note the argument order: the age convention is `hkdf(salt, label, ikm)`, so
 * `info` (the label) precedes `ikm` here, matching rage.
 *
 * Params:
 *   B    = the crypto backend
 *   salt = optional salt (empty selects the 32 zero-byte salt; §2.2)
 *   info = context/label (the age "label" argument)
 *   ikm  = input keying material
 *   okm  = output keying material; `okm.length` MUST be `<= 255 * 32`
 */
void hkdfSha256(B = DefaultBackend)(
    scope const(ubyte)[] salt, scope const(ubyte)[] info, scope const(ubyte)[] ikm,
    ubyte[] okm)
if (isCryptoBackend!B)
in (okm.length <= hkdfMaxExpandLength,
    "hkdfSha256: okm.length must be <= 255 * 32")
{
    ubyte[hashLen] prk = void;
    hkdfExtract!B(salt, ikm, prk);
    hkdfExpand!B(prk, info, okm);
}

// ─────────────────────────────────────────────────────────────────────────
// Tests — RFC 5869 Appendix A test cases for HKDF-SHA256.
//
// Hex literals are decoded with sparkles.crypto.encoding.hex.decodeHex into
// stack buffers so the tests stay allocation-free (@safe nothrow @nogc).
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
}

/// RFC 5869 Appendix A.1 (Test Case 1): basic HKDF-SHA256 with salt and info.
/// Verifies the intermediate PRK and the 42-byte OKM, and that the combined
/// `hkdfSha256` agrees with the separate extract/expand steps.
@("crypto.hkdf.rfc5869.case1")
@safe nothrow @nogc
unittest
{
    const ikm = fromHex!22("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
    const salt = fromHex!13("000102030405060708090a0b0c");
    const info = fromHex!10("f0f1f2f3f4f5f6f7f8f9");

    const expectedPrk = fromHex!32(
        "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5");
    const expectedOkm = fromHex!42(
        "3cb25f25faacd57a90434f64d0362f2a"
        ~ "2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
        ~ "34007208d5b887185865");

    ubyte[32] prk = void;
    hkdfExtract(salt[], ikm[], prk);
    assert(prk == expectedPrk);

    ubyte[42] okm = void;
    hkdfExpand(prk, info[], okm[]);
    assert(okm == expectedOkm);

    // The combined convenience must match the two-step result.
    ubyte[42] combined = void;
    hkdfSha256(salt[], info[], ikm[], combined[]);
    assert(combined == expectedOkm);
}

/// RFC 5869 Appendix A.2 (Test Case 2): longer inputs and a 82-byte OKM,
/// exercising multiple `T(n)` blocks.
@("crypto.hkdf.rfc5869.case2")
@safe nothrow @nogc
unittest
{
    const ikm = fromHex!80(
        "000102030405060708090a0b0c0d0e0f"
        ~ "101112131415161718191a1b1c1d1e1f"
        ~ "202122232425262728292a2b2c2d2e2f"
        ~ "303132333435363738393a3b3c3d3e3f"
        ~ "404142434445464748494a4b4c4d4e4f");
    const salt = fromHex!80(
        "606162636465666768696a6b6c6d6e6f"
        ~ "707172737475767778797a7b7c7d7e7f"
        ~ "808182838485868788898a8b8c8d8e8f"
        ~ "909192939495969798999a9b9c9d9e9f"
        ~ "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf");
    const info = fromHex!80(
        "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
        ~ "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
        ~ "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
        ~ "e0e1e2e3e4e5e6e7e8e9eaebecedeeef"
        ~ "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");

    const expectedPrk = fromHex!32(
        "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244");
    const expectedOkm = fromHex!82(
        "b11e398dc80327a1c8e7f78c596a4934"
        ~ "4f012eda2d4efad8a050cc4c19afa97c"
        ~ "59045a99cac7827271cb41c65e590e09"
        ~ "da3275600c2f09b8367793a9aca3db71"
        ~ "cc30c58179ec3e87c14c01d5c1f3434f"
        ~ "1d87");

    ubyte[32] prk = void;
    hkdfExtract(salt[], ikm[], prk);
    assert(prk == expectedPrk);

    ubyte[82] okm = void;
    hkdfExpand(prk, info[], okm[]);
    assert(okm == expectedOkm);

    ubyte[82] combined = void;
    hkdfSha256(salt[], info[], ikm[], combined[]);
    assert(combined == expectedOkm);
}

/// RFC 5869 Appendix A.3 (Test Case 3): zero-length salt and info. The empty
/// salt must select the 32-byte zero salt (§2.2), so passing `null` salt and
/// `null` info reproduces the published vector.
@("crypto.hkdf.rfc5869.case3")
@safe nothrow @nogc
unittest
{
    const ikm = fromHex!22("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");

    const expectedPrk = fromHex!32(
        "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04");
    const expectedOkm = fromHex!42(
        "8da4e775a563c18f715f802a063c5a31"
        ~ "b8a11f5c5ee1879ec3454e5f3c738d2d"
        ~ "9d201395faa4b61a96c8");

    // Empty salt -> the 32-byte zero salt; empty info.
    ubyte[32] prk = void;
    hkdfExtract(null, ikm[], prk);
    assert(prk == expectedPrk);

    ubyte[42] okm = void;
    hkdfExpand(prk, null, okm[]);
    assert(okm == expectedOkm);

    ubyte[42] combined = void;
    hkdfSha256(null, null, ikm[], combined[]);
    assert(combined == expectedOkm);
}

/// An explicit 32-byte zero salt produces the same PRK as an empty salt
/// (RFC 5869 §2.2 equivalence), confirming the empty-salt substitution.
@("crypto.hkdf.emptySaltEqualsZeroSalt")
@safe nothrow @nogc
unittest
{
    const ikm = fromHex!22("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
    static immutable ubyte[32] zeroSalt = 0;

    ubyte[32] prkEmpty = void;
    ubyte[32] prkZero = void;
    hkdfExtract(null, ikm[], prkEmpty);
    hkdfExtract(zeroSalt[], ikm[], prkZero);
    assert(prkEmpty == prkZero);
}

/// A zero-length OKM request is a well-defined no-op: `hkdfExpand` writes
/// nothing and does not touch the (empty) output.
@("crypto.hkdf.expand.zeroLength")
@safe nothrow @nogc
unittest
{
    ubyte[32] prk = 0;
    ubyte[0] okm;
    hkdfExpand(prk, null, okm[]); // must not crash or assert
    assert(okm.length == 0);
}

/// HKDF-Expand of exactly one block (`okm.length == 32`) equals just `T(1)`,
/// i.e. `HMAC-SHA256(prk, info ‖ 0x01)`, confirming the single-block path.
@("crypto.hkdf.expand.oneBlock")
@safe nothrow @nogc
unittest
{
    import sparkles.crypto.backend : DefaultBackend;

    const prk = fromHex!32(
        "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5");
    const info = fromHex!10("f0f1f2f3f4f5f6f7f8f9");

    ubyte[32] okm = void;
    hkdfExpand(prk, info[], okm[]);

    // T(1) = HMAC(prk, "" ‖ info ‖ 0x01); build the message and compare.
    ubyte[11] msg = void; // 10 info bytes + 1 counter byte
    msg[0 .. 10] = info[];
    msg[10] = 0x01;
    ubyte[32] expected = void;
    DefaultBackend.hmacSha256(prk[], msg[], expected);

    assert(okm == expected);
}

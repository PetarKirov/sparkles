# Implementation task: power-of-two bit-regrouping codecs (RFC 4648 family) for a D module

## Role & context

You are working inside an existing D module that already provides scalar integer
text conversion:

```d
Expected!T readInteger(T, ubyte radix = 10)(string input);
void        writeInteger(ubyte radix = 10, Writer, T)(ref Writer w, const T val);
```

`Expected!T` is the module's existing result type (a `Result`/`Expected` that supports
`Expected!void` and error construction via a helper `err(string)` — inspect the module and
reuse whatever is already there; do **not** introduce a new error type or a second radix
integer type).

Your job is to add a **binary-to-text codec layer** for the **power-of-two "base" family
only** — RFC 4648 Base16/Base32/Base32hex/Base64/Base64url and alphabet-compatible
relatives (z-base-32, base64 line-wrapped variants, uuencode/xxencode alphabets).

### Non-goals — do NOT implement these

- Non-power-of-two block codecs (Ascii85, Z85, Base45).
- Whole-integer radix codecs (Base58, Base62).
- Escape encodings (quoted-printable, yEnc, percent-encoding).
- Unicode high-density codecs (Base122, Base2048/32768/65536) or Punycode.
- The scalar `readInteger`/`writeInteger` (already done — leave untouched).

Everything here is a single kernel: an MSB-first bit accumulator emitting `log2(radix)`
bits per character. All per-base behavior must be **derived at compile time from the
alphabet**, never hardcoded per base.

## Core abstraction

```d
struct Alphabet {
    string digits;                 // index == symbol value; radix == digits.length
    bool   caseInsensitive = false;// decode accepts either case
    string aliases = "";           // decode-only (aliasChar, canonicalDigit) pairs, e.g. Crockford "O0I1L1"
    char   padding = '\0';         // '\0' == none; e.g. '=' for RFC base32/base64

    ubyte radix() const @safe pure nothrow @nogc { return cast(ubyte) digits.length; }
}
```

`Alphabet` is a **template value parameter** (modern D allows struct value params; all members
are `string`/`bool`/`char`, no mutable indirection). Provide named presets AND allow anonymous
literals to bind:

```d
enum Alphabet base16    = Alphabet("0123456789ABCDEF", true);
enum Alphabet base32    = Alphabet("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", false, "", '=');
enum Alphabet base32hex = Alphabet("0123456789ABCDEFGHIJKLMNOPQRSTUV", false, "", '=');
enum Alphabet base64    = Alphabet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", false, "", '=');
enum Alphabet base64url = Alphabet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", false, "", '=');
enum Alphabet zbase32   = Alphabet("ybndrfg8ejkmcpqxot1uwisza345h769");
```

## Compile-time derivation (single source of truth)

Everything derives from the radix via CTFE. Guard the whole layer with `isPow2`.

```d
bool   isPow2(ulong n)    @safe pure nothrow @nogc { return n && !(n & (n - 1)); }
ubyte  log2Exact(ulong n) @safe pure nothrow @nogc { ubyte k; while (n > 1) { n >>= 1; ++k; } return k; }
size_t gcdCT(size_t a, size_t b) @safe pure nothrow @nogc { while (b) { auto t = a % b; a = b; b = t; } return a; }

// bitsPerChar   = log2Exact(radix)
// charsPerGroup = 8 / gcdCT(8, bitsPerChar)   // base16->2, base32->8, base64->4
size_t encodedLen(Alphabet a, size_t n) @safe pure nothrow @nogc {
    immutable bpc = log2Exact(a.radix);
    immutable raw = (n * 8 + bpc - 1) / bpc;
    immutable cpg = 8 / gcdCT(8, bpc);
    return a.padding != '\0' ? (raw + cpg - 1) / cpg * cpg : raw;
}
```

## Reference kernels (implement these first, exactly)

These are the correctness oracle. Keep them `@safe pure nothrow @nogc`-friendly (the streaming
encoder is `@safe`; the allocating decoder is not `@nogc` — that's fine for the reference).

### Encoder — MSB-first accumulator

```d
void encodePow2(Alphabet a, Writer)(ref Writer w, scope const(ubyte)[] data)
    if (isOutputRange!(Writer, char) && isPow2(a.radix))
{
    enum ubyte  bpc = log2Exact(a.radix);
    enum uint   msk = a.radix - 1;
    enum size_t cpg = 8 / gcdCT(8, bpc);

    uint buf = 0; int nbits = 0; size_t n = 0;
    foreach (ubyte b; data) {
        buf = (buf << 8) | b; nbits += 8;
        while (nbits >= bpc) { nbits -= bpc; put(w, a.digits[(buf >> nbits) & msk]); ++n; }
        buf &= (1u << nbits) - 1;
    }
    if (nbits > 0) { put(w, a.digits[(buf << (bpc - nbits)) & msk]); ++n; }  // MSB-aligned partial
    if (a.padding != '\0')
        foreach (_; 0 .. (cpg - n % cpg) % cpg) put(w, a.padding);
}
```

### Decoder — CTFE reverse table + three strictness checks

```d
byte[256] makeDecodeTable(Alphabet a) @safe pure nothrow {
    byte[256] t = -1;
    foreach (i, char c; a.digits) t[cast(ubyte) c] = cast(byte) i;
    if (a.caseInsensitive)
        foreach (i, char c; a.digits) {
            if      (c >= 'A' && c <= 'Z') t[cast(ubyte)(c + 32)] = cast(byte) i;
            else if (c >= 'a' && c <= 'z') t[cast(ubyte)(c - 32)] = cast(byte) i;
        }
    for (size_t i = 0; i + 1 < a.aliases.length; i += 2) {
        immutable from  = cast(ubyte) a.aliases[i];
        immutable canon = t[cast(ubyte) a.aliases[i + 1]];
        t[from] = canon;
        if (a.caseInsensitive) {
            if      (from >= 'A' && from <= 'Z') t[from + 32] = canon;
            else if (from >= 'a' && from <= 'z') t[from - 32] = canon;
        }
    }
    return t;
}

Expected!(ubyte[]) decodePow2(Alphabet a)(scope const(char)[] text)
    if (isPow2(a.radix))
{
    enum ubyte  bpc = log2Exact(a.radix);
    enum size_t cpg = 8 / gcdCT(8, bpc);
    static immutable table = makeDecodeTable(a);

    ubyte[] outp;
    uint buf = 0; int nbits = 0; size_t sc = 0, padCount = 0; bool sawPad = false;
    foreach (char c; text) {
        if (a.padding != '\0' && c == a.padding) { sawPad = true; ++padCount; continue; }
        if (sawPad) return err("data after padding");
        immutable v = table[cast(ubyte) c];
        if (v < 0) return err("invalid symbol");
        buf = (buf << bpc) | cast(uint) v; nbits += bpc; ++sc;
        while (nbits >= 8) { nbits -= 8; outp ~= cast(ubyte)((buf >> nbits) & 0xFF); }
        buf &= (1u << nbits) - 1;
    }
    immutable r = sc % cpg;
    if (r != 0 && (r * bpc) % 8 >= bpc) return err("truncated group");            // (1)
    if (buf != 0)                       return err("non-canonical trailing bits"); // (2)
    if (a.padding != '\0' && padCount != (cpg - r) % cpg)
                                        return err("bad padding count");           // (3)
    return outp;
}
```

The three checks are the strictness dial. Default = all three ON (RFC 4648 §3.5 "MUST reject").
Check (1)'s valid-final-length rule must stay **derived** (`(r*bpc)%8 < bpc`), not a per-base
lookup table. Later expose a `lax` flag or a second `Alphabet`-adjacent policy to relax them, but
the reference and default must reject.

### Known-answer anchors (must pass before anything else)

- `encodePow2!base64` of `"M"`  → `"TQ=="`; of `"Ma"` → `"TWE="`; of `"Man"` → `"TWFu"`.
- `encodePow2!base32` of `"f"`   → `"MY======"`; of `"foobar"` → `"MZXW6YTBOI======"`.
- `encodePow2!base16` of `[0xDE,0xAD,0xBE,0xEF]` → `"DEADBEEF"` (no padding, `cpg==2`).
- Round-trip `decodePow2!a(encodePow2!a(x)) == x` for all presets over random `x`.
- Use the full RFC 4648 §10 test vectors for base16/32/32hex/64 as fixed unit tests.

## Fixed-length specialization (the primary performance lever)

Many real inputs are fixed-size (hashes, public keys). When `N` is known at compile time, the
tail handling, loop counter, and padding math are all compile-time constants → emit fully
unrolled straight-line code into a fixed-size output buffer, `@safe @nogc`:

```d
void encodePow2(Alphabet a, size_t N)(ref const ubyte[N] src,
                                      ref char[encodedLen(a, N)] dst) @safe @nogc;
// plus a decode counterpart with a compile-time-known exact input length where padding is fixed.
```

This must produce byte-identical output to the streaming reference (differential test it).

## Line-wrapping variants (decorator, NOT in the kernel)

MIME (76-char), PEM (64-char), uuencode per-line length bytes: implement as a thin wrapping
writer/decorator around `encodePow2`. Keep the kernel free of wrapping/framing logic.

## Performance work (staged — land each milestone independently, gated on tests)

Toolchain: **LDC** (LLVM intrinsics, `core.simd` `__vector`, `@target`/`ldc.attributes` for
per-function ISA). GDC acceptable as a secondary path. The scalar reference always remains as the
portable fallback and the differential oracle.

Runtime ISA dispatch via `core.cpuid` **once at startup** into a function pointer per
(alphabet, N) that matters — never `cpuid` per call.

- **M1 — Fixed-length unrolled scalar** for base16/32/64 + `encodedLen` CTFE. Biggest
  effort-to-payoff; pure scalar, no intrinsics. **Do this first.**
- **M2 — AVX2 hex (base16) encode+decode.** Byte-independent, embarrassingly parallel, packable
  across record boundaries. Encode: nibble split + one `pshufb` alphabet lookup + interleave.
  Decode: `pshufb` validate-and-translate + `pmaddubsw` (×[16,1]) nibble combine. Captures most
  real-world speedup.
- **M3 — AVX2 base64** per the Muła–Lemire vectorized-base64 method: `vpshufb` triplet placement,
  6-bit field extraction via multiply-as-shift (`vpmulhuw`/`vpmullw` magic constants), branchless
  6-bit→ASCII via range-offset `pshufb`. Decode via paired hi/lo-nibble `pshufb` (translate +
  validity mask) then `pmaddubsw`+`pmaddwd`+shuffle pack.
- **M4 — AVX-512 VBMI base64** (`vpmultishiftqb` for one-shot 6-bit gather, `vpermb` for the
  64-entry map) and **SWAR base32** (load 5 bytes as a 40-bit big-endian `ulong`, eight fixed-shift
  extractions, 32-entry lookup — do NOT force SIMD on base32; wide-GPR SWAR is the SOTA-comparable
  approach). Optionally BMI2 `pdep`/`pext` for the regroup step, **gated off AMD Zen1/Zen2** where
  it is microcoded and slow.

Batch design: prefer record-at-a-time with a force-inlined specialized kernel (a 32-byte record is
one `ymm`; cross-record packing reintroduces bit-boundary issues for base32/64 unless the record
length is a multiple of 3/5, which 32 is not — hex is the exception and may span records freely).
You become memory-bound almost immediately, so also: contiguous output buffers (no per-record
allocation), cache-resident chunking, software prefetch of upcoming records, SoA input layout if
records aren't already contiguous.

## Testing (non-negotiable, especially for SIMD)

- RFC 4648 §10 known-answer vectors for base16/32/32hex/64 as fixed unit tests.
- Round-trip property tests for every preset over random data of every length `0..M`.
- **Differential fuzzing: every SIMD path vs the scalar reference**, over random inputs and every
  tail length. This MUST include the **rejection paths** — invalid symbol, data-after-padding,
  truncated group (check 1), non-canonical trailing bits (check 2), wrong padding count (check 3).
  The vector decoder must reject *exactly* what the scalar decoder rejects; validation divergence is
  the most common SIMD bug.
- Fixed-length specialization vs streaming reference: byte-identical output.
- CI runs the scalar path everywhere; SIMD paths run behind their `cpuid` gate (and, if possible,
  force-enabled in CI on capable runners so they're actually exercised).

## Deliverables

1. `Alphabet` + presets + CTFE helpers (`isPow2`, `log2Exact`, `gcdCT`, `encodedLen`).
2. Reference `encodePow2` / `decodePow2` (streaming) matching the code above, reusing the module's
   `Expected`/`err`.
3. Fixed-length `@safe @nogc` specializations (M1).
4. Line-wrap decorator.
5. SIMD paths M2–M4 with `core.cpuid` dispatch and scalar fallback.
6. Full test suite (KAT + property + differential fuzz + rejection-path tests).
7. A short `README`/doc section: the numeral-vs-codec distinction, the strictness dial (three
   checks), per-base performance notes, and how to add a new alphabet.

## Acceptance criteria

- All RFC 4648 §10 vectors pass; all presets round-trip.
- Default decoders reject all three non-canonical/padding cases; a documented lax mode relaxes them.
- No per-base hardcoded tables — everything derives from `Alphabet` via CTFE.
- Every SIMD path is differential-fuzz-clean against the scalar reference including rejections.
- Fixed-length path is `@safe @nogc` and byte-identical to streaming.
- Scalar-only build compiles and passes with no intrinsics (portability guaranteed).

## Working method

Land M1 and the reference + full test suite first and get them green before writing any
intrinsics. Commit per milestone. If any design detail here conflicts with something already in the
module, prefer the module's existing conventions (error type, naming, radix parameter type) and note
the deviation in the PR description rather than inventing a parallel mechanism.


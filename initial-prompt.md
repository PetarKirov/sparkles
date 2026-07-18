# Implementation task: power-of-two bit-regrouping codecs (RFC 4648 family) for `sparkles.base.text`

## Role & context

You are working in the `sparkles` monorepo (see `AGENTS.md` — read it first; its
conventions override anything here that conflicts). The target is the
`sparkles.base.text` package (`libs/base/src/sparkles/base/text/`), which
already provides:

- **Slice-advance readers** (`readers.d`): `readInteger!T(ref scope const(char)[] s)`
  (decimal-only today, unsigned, advances the cursor on success, leaves it
  untouched on failure), `isHexDigit`/`hexNibble`, `tryConsume`, `readUntil`, …
- **Output-range writers** (`writers.d`): `writeInteger` (decimal-only today),
  `writeFixedPoint!(radix)` (the one existing radix precedent, 2–16, backed by
  a private lower-case `hexDigit`), `writeFloat`, `writeHexByte` (two
  **lower-case** hex digits), escaped-string writers — all templated on
  `Writer`, attributes inferred.
- **A structured error vocabulary** (`errors.d`): `ParseExpected!T`
  (= `Expected!(T, ParseError, NoGcHook)`), constructed via `parseOk(value)` /
  `parseErr!T(ParseErrorCode.code, offset[, context])`. `ParseError` carries a
  machine-readable `ParseErrorCode`, the byte **offset** of the failure, and an
  optional borrowed `context` string (a CTFE literal). Do **not** introduce a
  new error type or string-typed errors.

Your job has two parts:

1. **Generalize the scalar integer conversions**: add a `radix` template
   parameter (default 10) to `readInteger` / `writeInteger`, deriving their
   digit tables from the same `Alphabet` machinery the codec layer uses (see
   "Scalar radix generalization" below). This is the prep step — land it first.
2. Add a **binary-to-text codec layer** for the **power-of-two "base" family
   only** — RFC 4648 Base16/Base32/Base32hex/Base64/Base64url and
   alphabet-compatible relatives (z-base-32, base64 line-wrapped variants,
   uuencode/xxencode alphabets) — as a **new feature module**
   `sparkles.base.text.base_codecs`
   (`libs/base/src/sparkles/base/text/base_codecs.d`), re-exported from
   `package.d`. Tests live in the feature module, never in `package.d` (the
   test runner cannot discover tests there).

### Non-goals — do NOT implement these

- Non-power-of-two block codecs (Ascii85, Z85, Base45).
- Whole-integer radix codecs (Base58, Base62).
- Escape encodings (quoted-printable, yEnc, percent-encoding).
- Unicode high-density codecs (Base122, Base2048/32768/65536) or Punycode.
- Rewriting the existing scalar readers/writers beyond the radix
  generalization below (`writeHexByte` stays two lower-case digits;
  `writeFloat` and the escaped-string writers are untouched).

Everything here is a single kernel: an MSB-first bit accumulator emitting
`log2(radix)` bits per character. All per-base behavior must be **derived at
compile time from the alphabet**, never hardcoded per base.

## Core abstraction

```d
struct Alphabet
{
    string digits;                  // index == symbol value; radix == digits.length
    bool   caseInsensitive = false; // decode accepts either case
    string aliases = "";            // decode-only (aliasChar, canonicalDigit) pairs, e.g. Crockford "O0I1L1"
    char   padding = '\0';          // '\0' == none; e.g. '=' for RFC base32/base64

    ubyte radix() const @safe pure nothrow @nogc => cast(ubyte) digits.length;
}
```

`Alphabet` is a **template value parameter** (all members are
`string`/`bool`/`char`, no mutable indirection). Provide named presets AND
allow anonymous literals to bind. Use named arguments (DIP1030, repo
convention) for the presets so the boolean/char fields stay readable:

```d
enum Alphabet base16    = Alphabet(digits: "0123456789ABCDEF", caseInsensitive: true);
enum Alphabet base32    = Alphabet(digits: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", padding: '=');
enum Alphabet base32hex = Alphabet(digits: "0123456789ABCDEFGHIJKLMNOPQRSTUV", padding: '=');
enum Alphabet base64    = Alphabet(digits: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", padding: '=');
enum Alphabet base64url = Alphabet(digits: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", padding: '=');
enum Alphabet zbase32   = Alphabet(digits: "ybndrfg8ejkmcpqxot1uwisza345h769");
```

(RFC base16 is upper-case; the existing `writeHexByte` is lower-case by
design. They coexist — do not unify them.)

### Named convenience wrappers (aliases, not new code paths)

The generic spellings (`encodeBase!base64(w, data)`) are the mechanism, not
the everyday API. Ship per-preset names as **aliases of the partially
instantiated templates** — zero-cost, one overload-resolution seam, and UFCS
reads naturally (`buf.encodeBase64(data)`):

```d
alias encodeBase16    = encodeBase!base16;    alias decodeBase16    = decodeBase!base16;
alias encodeBase32    = encodeBase!base32;    alias decodeBase32    = decodeBase!base32;
alias encodeBase32Hex = encodeBase!base32hex; alias decodeBase32Hex = decodeBase!base32hex;
alias encodeBase64    = encodeBase!base64;    alias decodeBase64    = decodeBase!base64;
alias encodeBase64Url = encodeBase!base64url; alias decodeBase64Url = decodeBase!base64url;
alias encodeZBase32   = encodeBase!zbase32;   alias decodeZBase32   = decodeBase!zbase32;
```

Rules:

- Aliases only — a wrapper must never re-state parameters or add logic. If it
  can't be an `alias`, that's a smell in the underlying API, not a reason to
  write a forwarding function.
- **Verify the overload-set interaction early**: `encodeBase` names two
  templates (streaming + fixed-length), both with `Alphabet` as the sole
  explicit parameter. Check that `alias encodeBase64 = encodeBase!base64;`
  still resolves both overloads at the call site (IFTI through a partial
  instantiation of an overload set). If the compiler rejects it as ambiguous,
  restructure the _generic_ layer so the alias works — e.g. make `encodeBase`
  an eponymous template over `Alphabet` whose members are the streaming and
  fixed-length overloads — rather than demoting the wrappers to forwarding
  functions.
- Each alias is a public symbol: give it a one-line DDoc (`/// RFC 4648
Base64, streaming — see $(LREF encodeBase)`) and at least one DDoc-ed
  unittest, per the repo's testing rule. The KAT tests should exercise the
  _aliases_ (`encodeBase64` of `"Man"` → `"TWFu"`), which covers the generic
  kernel through the seam users actually touch.
- Docs and the README example use the named wrappers; only the "how to add a
  new alphabet" page leads with the generic spelling.

## Compile-time derivation (single source of truth)

Everything derives from the radix via CTFE. Guard the whole layer with a
power-of-two constraint. **Reuse Phobos/druntime instead of hand-rolling**
where CTFE-compatible: `std.math.traits.isPowerOf2`, `core.bitop.bsr` (for
`log2Exact`), `std.numeric.gcd`. Only `encodedLen` is genuinely new:

```d
// bitsPerChar   = bsr(a.radix)
// charsPerGroup = 8 / gcd(8, bitsPerChar)   // base16->2, base32->8, base64->4
size_t encodedLen(in Alphabet a, size_t n) @safe pure nothrow @nogc
{
    immutable bpc = bsr(a.radix);
    immutable raw = (n * 8 + bpc - 1) / bpc;
    immutable cpg = 8 / gcd(8, bpc);
    return a.padding != '\0' ? (raw + cpg - 1) / cpg * cpg : raw;
}
```

Non-template helpers get explicit `@safe pure nothrow @nogc` (module-scope
attribute block is fine, as in `readers.d`).

## Scalar radix generalization (prep — land before the codec kernels)

Generalize the scalar integer conversions with a `radix` template parameter
defaulting to 10, so every existing call site and test compiles unchanged:

```d
ParseExpected!T readInteger(T, ubyte radix = 10)(ref scope const(char)[] s)
if (isUnsigned!T && radix >= 2 && radix <= 36);

void writeInteger(ubyte radix = 10, Writer, T)(ref Writer w, const T val)
if (__traits(isIntegral, T) && radix >= 2 && radix <= 36);
```

(`radix` leads `writeInteger`'s parameter list — the same shape as the
existing `writeFixedPoint!(radix)` — so `Writer`/`T` still infer.)

The single source of truth is one **alphanumeric `Alphabet`** —
`Alphabet(digits: "0123456789abcdefghijklmnopqrstuvwxyz", caseInsensitive: true)`
— with `digits` sliced to `[0 .. radix]`. That is the reuse point between the
numeral layer and the codec layer.

### Writer side — collapse the four digit walks

`writers.d` currently contains four near-copies of "turn an integer into
base-R digits", plus one trivial fifth:

| Site                              | Shape                            | Radix        | Case               |
| --------------------------------- | -------------------------------- | ------------ | ------------------ |
| `writeUnsignedImpl`               | LSB-first into CTFE-sized buffer | 10 hardcoded | —                  |
| `writeFixedPoint`'s non-10 branch | do-while walk into `char[64]`    | 2–16 runtime | lower (`hexDigit`) |
| `writeFractionDigits`             | fixed-count zero-padded walk     | 2–16         | lower (`hexDigit`) |
| `writeEscapedChar`'s `\x` branch  | two nibble lookups, own table    | 16           | **upper**          |
| `writeHexByte`                    | two `hexDigit` calls             | 16           | lower              |

Consolidate: promote `writeUnsignedImpl` to a radix-templated
`writeUnsigned!(radix)` whose buffer is sized by a CTFE `maxDigits!(T, radix)`
(replacing the decimal-only `sizeForUnsignedNumberBuffer`; base 2 needs 64
chars for `ulong`) and whose digit emission indexes the shared alnum `digits`
string. Then:

- `writeInteger!(radix)` = sign handling + `writeUnsigned`. The signed/`T.min`
  dance is copy-pasted between `writeInteger` and `writeIntegerPadded` today —
  factor it into one private helper while touching it.
- `writeUnsignedPadded` currently makes two passes (a division loop to count
  digits, then a re-walk); with the buffer walk factored out it is one pass:
  fill the buffer, emit `minDigits - len` zeros, emit the slice.
- `writeFixedPoint` loses its private walk entirely — including its
  `static if (radix == 10)` special case, since `writeUnsigned!10` _is_ the
  optimized path — and its `radix <= 16` bound widens to 36.
  `writeFractionDigits` becomes the zero-padded variant of the same walk.
  Behavior unchanged; their unittests must pass untouched.
- `writeEscapedChar` emits **upper-case** `\xAB` while `hexDigit` is
  lower-case — an invisible divergence between two private tables today. Keep
  the behavior, make it explicit: the escape branch indexes the upper-case
  base16 preset's `digits`, the numeral path the lower-case alnum string.

### Reader side — one table serves every radix

- **Do not instantiate a table per radix.** A single case-insensitive alnum
  decode table (`'0'..'9'`/`'a'..'z'`/`'A'..'Z'` → 0..35, else −1) — i.e.
  `makeDecodeTable` over the alnum alphabet — serves all radices: the
  validity check is `v = table[c]; if (v < 0 || v >= radix) break;`. For
  `radix <= 10` keep an arithmetic fast path
  (`cast(uint)(c - '0') < radix`) so decimal codegen is unchanged.
- **Hoist the overflow check.** Today `readInteger` divides every iteration
  (`(T.max - digit) / 10`). Use the strtol formulation: with compile-time
  radix, `enum cutoff = T.max / radix; enum cutlim = T.max % radix;` and the
  loop check is `value > cutoff || (value == cutoff && digit > cutlim)` — no
  division in the loop.
- `isHexDigit`/`hexNibble` stay as public conveniences (they are used and
  `@betterC`-tested), but `readInteger!(T, 16)` must not call them — the
  table loop subsumes the test-then-convert pair in one lookup.

The common radices also get named shorthands, same alias-only rule as the
codec wrappers (`writeInteger` leads with `radix` precisely so the write-side
partial instantiation can be aliased; `readInteger` leads with `T`, so its
shorthand is a template alias):

```d
alias writeHex    = writeInteger!16;          alias readHex(T)    = readInteger!(T, 16);
alias writeBinary = writeInteger!2;           alias readBinary(T) = readInteger!(T, 2);
alias writeOctal  = writeInteger!8;           alias readOctal(T)  = readInteger!(T, 8);
```

So call sites read `writeHex(w, 0xDEADu)` → `"dead"` and
`s.readHex!uint` — naming consistent with the existing
`isHexDigit`/`hexNibble`/`writeHexByte` family.

This is a numeral (whole-integer positional) conversion, not a bit-regrouping
codec — the layers stay separate; only the `Alphabet`/table derivation is
shared. Since `readers.d`/`writers.d` will import it, `Alphabet` +
`makeDecodeTable` live in `base_codecs` (which must not import the readers,
so no cycle) — intra-package imports are fine.

Cursor rules stay: `readInteger` still advances only on success. Tests:
write→read round trips for radices {2, 8, 10, 16, 36} across boundary values
(`T.max` per radix, overflow-by-one rejections), plus KATs like
`writeInteger!16(w, 0xDEADu)` → `"dead"`; the existing decimal tests must
pass unmodified. Once the codec kernel exists, add a differential anchor:
`writeHexByte` is definitionally the fixed-length `encodeBase` of one byte
with a lower-case base16 alphabet — assert they agree.

### Drive-by fixes and non-fixes (while in these modules)

- The `readers.d` module header cross-references
  `$(REF …, sparkles,core_cli,text,…)` — stale paths; these modules live in
  `sparkles.base.text`. Fix the two refs.
- The manual char loops in `tryConsumeAny`/`readUntil` are **load-bearing**:
  `std.algorithm.canFind` over `char[]` autodecodes (throws `UTFException`,
  breaking `nothrow @nogc`). Leave them; add a one-line comment saying why.
- Known further dedup, **out of scope for this branch** (separate
  `refactor(base.text)` if ever): `readEnumString` / `enumExpectedList` /
  `writeEnumMemberName` each run their own `static foreach` +
  `convertCase!style` over the members and could share one CTFE name table;
  `writeStyledValue` re-implements `writeValue`'s leaf dispatch. Don't bundle
  either with the radix work.

## Reference kernels (implement these first, exactly)

These are the correctness oracle. Both are templates generic over a `Writer`
— **let attributes infer** (repo rule: never force `@safe` on templates; both
must _infer_ `@safe pure nothrow @nogc` when the writer is, e.g. a
`SmallBuffer`). Never a whole-function `@trusted`; if an unsafe op is
unavoidable, wrap only it in a `@trusted` lambda.

### Encoder — MSB-first accumulator

Writer-first, `void`, matching the `writers.d` shape:

```d
void encodeBase(Alphabet a, Writer)(ref Writer w, scope const(ubyte)[] data)
if (isPowerOf2(a.radix))
{
    enum ubyte  bpc = bsr(a.radix);
    enum uint   msk = a.radix - 1;
    enum size_t cpg = 8 / gcd(8, bpc);

    uint buf = 0; int nbits = 0; size_t n = 0;
    foreach (ubyte b; data)
    {
        buf = (buf << 8) | b; nbits += 8;
        while (nbits >= bpc) { nbits -= bpc; put(w, a.digits[(buf >> nbits) & msk]); ++n; }
        buf &= (1u << nbits) - 1;
    }
    if (nbits > 0) { put(w, a.digits[(buf << (bpc - nbits)) & msk]); ++n; }  // MSB-aligned partial
    if (a.padding != '\0')
        foreach (_; 0 .. (cpg - n % cpg) % cpg) put(w, a.padding);
}
```

(If `put(w, char)` trips dip1000/`scope`, use the array-copy trick from the
guidelines: `char[1] c = a.digits[…]; put(w, c[]);`.)

### Decoder — CTFE reverse table + three strictness checks

The decoder writes decoded bytes into an output range of `ubyte` (so it stays
`@nogc`-capable — **no allocating `ubyte[]` return**) and reports failures as
`ParseExpected` with the repo's structured codes and offsets. On success it
returns the number of bytes written. Extend `ParseErrorCode` in `errors.d`
with two additive members for the outcomes the vocabulary lacks:

```d
nonCanonicalTrailing, /// unused trailing bits in a final group were not zero
paddingMismatch,      /// padding count did not match the final group's length
```

Map the rest onto existing codes: invalid symbol →
`unexpectedCharacter` (offset = index of the bad char), data after padding →
`unexpectedCharacter` with context `"data after padding"`, truncated final
group → `unexpectedEnd`.

```d
byte[256] makeDecodeTable(in Alphabet a) @safe pure nothrow
{
    byte[256] t = -1;
    foreach (i, char c; a.digits) t[cast(ubyte) c] = cast(byte) i;
    if (a.caseInsensitive)
        foreach (i, char c; a.digits)
        {
            if      (c >= 'A' && c <= 'Z') t[cast(ubyte)(c + 32)] = cast(byte) i;
            else if (c >= 'a' && c <= 'z') t[cast(ubyte)(c - 32)] = cast(byte) i;
        }
    for (size_t i = 0; i + 1 < a.aliases.length; i += 2)
    {
        immutable from  = cast(ubyte) a.aliases[i];
        immutable canon = t[cast(ubyte) a.aliases[i + 1]];
        t[from] = canon;
        if (a.caseInsensitive)
        {
            if      (from >= 'A' && from <= 'Z') t[from + 32] = canon;
            else if (from >= 'a' && from <= 'z') t[from - 32] = canon;
        }
    }
    return t;
}

ParseExpected!size_t decodeBase(Alphabet a, Writer)(ref Writer w, scope const(char)[] text)
if (isPowerOf2(a.radix))
{
    enum ubyte  bpc = bsr(a.radix);
    enum size_t cpg = 8 / gcd(8, bpc);
    static immutable table = makeDecodeTable(a);

    uint buf = 0; int nbits = 0; size_t sc = 0, padCount = 0, written = 0;
    bool sawPad = false;
    foreach (i, char c; text)
    {
        if (a.padding != '\0' && c == a.padding) { sawPad = true; ++padCount; continue; }
        if (sawPad)
            return parseErr!size_t(ParseErrorCode.unexpectedCharacter, i, "data after padding");
        immutable v = table[cast(ubyte) c];
        if (v < 0)
            return parseErr!size_t(ParseErrorCode.unexpectedCharacter, i);
        buf = (buf << bpc) | cast(uint) v; nbits += bpc; ++sc;
        while (nbits >= 8) { nbits -= 8; put(w, cast(ubyte)((buf >> nbits) & 0xFF)); ++written; }
        buf &= (1u << nbits) - 1;
    }
    immutable r = sc % cpg;
    if (r != 0 && (r * bpc) % 8 >= bpc)                                             // (1)
        return parseErr!size_t(ParseErrorCode.unexpectedEnd, text.length);
    if (buf != 0)                                                                   // (2)
        return parseErr!size_t(ParseErrorCode.nonCanonicalTrailing, text.length);
    if (a.padding != '\0' && padCount != (cpg - r) % cpg)                           // (3)
        return parseErr!size_t(ParseErrorCode.paddingMismatch, text.length);
    return parseOk(written);
}
```

**Deviation from the `readers.d` cursor convention, and why:** the readers
take a `ref` cursor and guarantee "unchanged on failure". A streaming decoder
cannot un-write bytes already `put` into `w`, so `decodeBase` instead takes
the whole payload by value and documents that on failure the writer may hold
a partial prefix (callers needing all-or-nothing use the fixed-length
overload, or a throwaway buffer). State this in the module DDoc.

The three checks are the strictness dial. Default = all three ON (RFC 4648
§3.5 "MUST reject"). Check (1)'s valid-final-length rule must stay **derived**
(`(r*bpc)%8 < bpc`), not a per-base lookup table. Later expose a lax policy
(e.g. an `enum DecodeStrictness { strict, lax }` template param defaulting to
`strict`) — but the reference and default must reject.

### Known-answer anchors (must pass before anything else)

- `encodeBase64` of `"M"` → `"TQ=="`; of `"Ma"` → `"TWE="`; of `"Man"` → `"TWFu"`.
- `encodeBase32` of `"f"` → `"MY======"`; of `"foobar"` → `"MZXW6YTBOI======"`.
- `encodeBase16` of `[0xDE,0xAD,0xBE,0xEF]` → `"DEADBEEF"` (no padding, `cpg==2`).
  (KATs exercise the named aliases — see the wrapper rules above.)
- Round-trip `decodeBase!a(encodeBase!a(x)) == x` for all presets over random `x`.
- Use the full RFC 4648 §10 test vectors for base16/32/32hex/64 as fixed unit tests.

## Fixed-length specialization (the primary performance lever)

Many real inputs are fixed-size (hashes, public keys). When `N` is known at
compile time, the tail handling, loop counter, and padding math are all
compile-time constants → emit fully unrolled straight-line code into a
fixed-size output buffer:

```d
void encodeBase(Alphabet a, size_t N)(ref const ubyte[N] src,
                                      ref char[encodedLen(a, N)] dst);
ParseExpected!void decodeBase(Alphabet a, size_t N)(in char[encodedLen(a, N)] src,
                                                    ref ubyte[N] dst);
```

These are non-generic enough to verify as `@safe pure nothrow @nogc` — but
they're still templates, so verify via the unittests' explicit attributes
rather than forcing attributes on the declarations. Must produce
byte-identical output to the streaming reference (differential-test it).

## Line-wrapping variants (decorator, NOT in the kernel)

MIME (76-char), PEM (64-char), uuencode per-line length bytes: implement as a
thin column-counting wrapping writer/decorator around `encodeBase`. Keep the
kernel free of wrapping/framing logic. Note: `sparkles.base.text.wrap` is
Unicode/ANSI-aware **prose** wrapping — unrelated machinery; do not reuse it
for this (codec output is pure ASCII with a hard column count).

## Testing (non-negotiable, especially for SIMD)

Repo conventions apply: string-UDA names (`@("text.base_codecs.…")`), every
unittest carries an explicit safety attribute plus `pure nothrow @nogc` where
possible. Import runner attributes **unconditionally** (see the existing
`import sparkles.test_runner.attributes : …;` in `readers.d`). Mark
KAT/round-trip tests `@betterC` where the body sticks to the public API (they
then also run under `dub test :base -- --better-c`). Use
`SmallBuffer!(char|ubyte, N)` as the test writer, and `checkWriter` from
`sparkles.base.smallbuffer` for expected/actual diffs on encoder output.

- RFC 4648 §10 known-answer vectors for base16/32/32hex/64 as fixed unit tests.
- Round-trip property tests for every preset over data of every length
  `0..M`, generated by a deterministic inline PRNG (keeps tests
  `pure nothrow @nogc`; don't pull in `std.random`).
- Rejection-path tests asserting the exact `ParseErrorCode` **and offset**
  for: invalid symbol, data-after-padding, truncated group (1), non-canonical
  trailing bits (2), wrong padding count (3).
- **Differential fuzzing: every SIMD path vs the scalar reference**, over
  random inputs and every tail length — **including the rejection paths**.
  The vector decoder must reject _exactly_ what the scalar decoder rejects
  (same code, same offset); validation divergence is the most common SIMD bug.
- Fixed-length specialization vs streaming reference: byte-identical output.
- ISA-gated tests call `skipTest("no AVX2 on this host")` from
  `sparkles.test_runner.skip` when `core.cpuid` says the path can't run — a
  skip renders as `⊘`, never as a silent pass. CI runs the scalar path
  everywhere; SIMD paths exercise wherever the runner's host supports them.

## Benchmarks (sparkles:test-runner is the harness)

No hand-rolled timing loops — benchmarks are `@benchmark` unittests in the
feature module, measured by the repo's own runner
(`docs/libs/test-runner/how-to/benchmark.md` is the full guide):

- Build the matrix with **`benchCase`**: `name:` = the kernel variant
  (`scalar`, `fixed<N>`, `avx2`, …), `labels:` = the other dimensions
  (`"preset"`: base16/base32/base64, `"op"`: encode/decode, `"size"`: 32/1k/64k),
  and a throughput column via
  `metrics: [Metric(Unit("B"), inputLen, Metric.Mode.rate)]` → B/s.
  Register cases from a helper taking varying state **by value** (closures
  run deferred, after the body returns). Use `after:` to verify the result
  each iteration (decode output matches, encode output length) — a mismatch
  becomes an error row, so a broken kernel can't post a fast number.
- Route inputs and results through **`blackBox`** or the optimizer folds the
  work away.
- Real numbers need release codegen: add a `bench` buildType to
  `libs/base/dub.sdl` following the precedent in
  `libs/wired/bench/runtime/dub.sdl`
  (`buildOptions "unittests" "releaseMode" "optimize" "inline"` +
  `dflags "-mcpu=native" "-O3" "-allinst" platform="ldc"`; `unittests` is
  load-bearing). Do **not** add `-enable-cross-module-inlining` to the build
  type (see the cross-module-inlining section of the benchmark guide).
- Run: `dub test :base -b bench -- --bench --group-by=preset,op,size`.
  For scalar-vs-SIMD comparisons add `--metrics=instr,ipc` (retired
  instructions/iter is the host-stable anchor; ns/iter explains). Snapshot
  milestone baselines with `--bench-json` so M2–M4 claims are reproducible.
- Normal `dub test :base` skips `@benchmark` tests automatically — the bench
  matrix costs CI nothing.

## Performance work (staged — land each milestone independently, gated on tests)

Toolchain: **LDC** (LLVM intrinsics, `core.simd` `__vector`,
`ldc.attributes` `@target` for per-function ISA), behind `version (LDC)` with
the scalar reference as the always-compiled portable fallback — `dub test`
must stay green on DMD (the CI matrix has a DC dimension). GDC acceptable as
a secondary path.

Runtime ISA dispatch via `core.cpuid` **once at startup** into a function
pointer per (alphabet, N) that matters — never `cpuid` per call.

- **M1 — Fixed-length unrolled scalar** for base16/32/64 + `encodedLen` CTFE.
  Biggest effort-to-payoff; pure scalar, no intrinsics. **Do this first.**
- **M2 — AVX2 hex (base16) encode+decode.** Byte-independent, embarrassingly
  parallel, packable across record boundaries. Encode: nibble split + one
  `pshufb` alphabet lookup + interleave. Decode: `pshufb`
  validate-and-translate + `pmaddubsw` (×[16,1]) nibble combine. Captures
  most real-world speedup.
- **M3 — AVX2 base64** per the Muła–Lemire vectorized-base64 method:
  `vpshufb` triplet placement, 6-bit field extraction via multiply-as-shift
  (`vpmulhuw`/`vpmullw` magic constants), branchless 6-bit→ASCII via
  range-offset `pshufb`. Decode via paired hi/lo-nibble `pshufb` (translate +
  validity mask) then `pmaddubsw`+`pmaddwd`+shuffle pack.
- **M4 — AVX-512 VBMI base64** (`vpmultishiftqb` for one-shot 6-bit gather,
  `vpermb` for the 64-entry map) and **SWAR base32** (load 5 bytes as a
  40-bit big-endian `ulong`, eight fixed-shift extractions, 32-entry lookup —
  do NOT force SIMD on base32; wide-GPR SWAR is the SOTA-comparable
  approach). Optionally BMI2 `pdep`/`pext` for the regroup step, **gated off
  AMD Zen1/Zen2** where it is microcoded and slow.

Batch design: prefer record-at-a-time with a force-inlined specialized kernel
(a 32-byte record is one `ymm`; cross-record packing reintroduces
bit-boundary issues for base32/64 unless the record length is a multiple of
3/5, which 32 is not — hex is the exception and may span records freely). You
become memory-bound almost immediately, so also: contiguous output buffers
(no per-record allocation), cache-resident chunking, software prefetch of
upcoming records, SoA input layout if records aren't already contiguous.

## Deliverables

1. `sparkles.base.text.base_codecs`: `Alphabet` + presets + `encodedLen`
   (+ `makeDecodeTable`), re-exported from `package.d`; the two
   `ParseErrorCode` additions in `errors.d`.
2. The scalar radix generalization: `readInteger!(T, radix)` /
   `writeInteger!(radix)` (+ `writeFixedPoint`/`hexDigit` re-expressed),
   deriving their tables from the shared `Alphabet` machinery, plus the
   `readHex`/`writeHex`-family aliases.
3. Reference `encodeBase` / `decodeBase` (streaming, writer-based) as above,
   plus the per-preset `encodeBase64`-family aliases.
4. Fixed-length specializations (M1), `@safe pure nothrow @nogc` per their tests.
5. Line-wrap decorator writer.
6. SIMD paths M2–M4 with `core.cpuid` dispatch and scalar fallback.
7. Full test suite (KAT + property + differential fuzz + rejection-path
   tests) + the `@benchmark` matrix + the `bench` buildType.
8. Docs: `base` already has a Diátaxis tree — add
   `docs/libs/base/reference/` + `explanation/` pages covering the
   numeral-vs-codec distinction, the strictness dial (three checks), per-base
   performance notes, and how to add a new alphabet; link them from
   `docs/libs/base/index.md`. Add a runnable `README.md` example
   (dub single-file block with `version="*"` + a ` ```[Output] ` fence,
   verified by `nix run .#ci -- --verify --files README.md`).

## Acceptance criteria

- `readInteger`/`writeInteger` accept `radix` 2–36 (default 10); every
  existing decimal call site and test compiles and passes unchanged;
  write→read round-trips hold across radices; digit tables come from the
  shared `Alphabet` machinery, not a parallel mechanism.
- All RFC 4648 §10 vectors pass; all presets round-trip.
- Default decoders reject all three non-canonical/padding cases with the
  documented `ParseErrorCode`s and offsets; a documented lax mode relaxes them.
- No per-base hardcoded tables — everything derives from `Alphabet` via CTFE.
- Every named wrapper is a true `alias` (no forwarding bodies), resolves both
  streaming and fixed-length overloads at the call site, and has its own
  DDoc-ed unittest; KATs go through the aliases.
- Every SIMD path is differential-fuzz-clean against the scalar reference,
  including rejections (same code, same offset).
- Fixed-length path infers `@safe pure nothrow @nogc` and is byte-identical
  to streaming.
- Scalar-only build compiles and passes with no intrinsics on DMD and LDC
  (portability guaranteed).
- `dub test :base` green; `dub test :base -b bench -- --bench` produces the
  matrix; `nix run .#ci -- --test` unaffected.

## Working method

Land the scalar radix generalization as its own preparation commit(s) first
(`feat(base.text): add radix parameter to readInteger/writeInteger` — repo
hygiene puts prep commits at the front of the branch), then M1 and the
reference + full test suite, green before writing any intrinsics. Commit as
you go — one atomic, individually-green commit per milestone, conventional
scopes (`feat(base.text.base_codecs): …`, `test(base.text.base_codecs): …`,
`docs(libs/base): …`, `build(base): add bench buildType`). Remember the repo
footguns: `git add` new files before any flake/`nix develop` build sees them;
dip1000/`-preview=in` may force relaxing a `scope` parameter to
`const(char)[]` — do that per-parameter, don't drop the preview flags. If any
design detail here conflicts with something already in the module, prefer the
module's existing conventions and note the deviation in the PR description
rather than inventing a parallel mechanism.

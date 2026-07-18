# Base codecs: design notes

Why `sparkles.base.text.base_codecs` is shaped the way it is.

## Numeral vs codec

Two different things get called "base N", and the module keeps them apart:

- A **numeral conversion** treats the input as one whole integer and
  re-expresses it positionally: `writeInteger!16(w, 0xDEAD)` → `"dead"`.
  Any radix 2–36 works; leading zeros are insignificant; the input has no
  byte structure.
- A **bit-regrouping codec** treats the input as a byte _stream_ and
  re-groups its bits MSB-first, `log2(radix)` bits per character:
  `encodeBase64` and friends. Only power-of-two radices regroup without
  arbitrary-precision arithmetic — which is exactly why Base58/Base62
  (whole-integer codecs) are out of scope here.

What the two layers genuinely share is the **digit vocabulary**: an
`Alphabet` (digit string, case folding, decode aliases, padding) and its
CTFE reverse table (`makeDecodeTable`). The scalar `readInteger` /
`writeInteger` draw their digits from the `alnum` alphabet sliced to the
radix; the codecs bind a whole `Alphabet` as a template value parameter.
Nothing per-base is hardcoded in either layer.

## The strictness dial: three checks

RFC 4648 §3.5 says non-canonical encodings MUST be rejected — otherwise the
same bytes have many encodings, which breaks signatures, content addressing,
and dedup, and has enabled real-world exploits. The decoder enforces three
independent checks, all derived from the alphabet (never a per-base table):

1. **Truncated group** — a final group with fewer characters than can
   carry one byte (e.g. 1 of 4 base64 chars = 6 bits). Derived rule: a
   remainder `r` is invalid iff `(r * bitsPerChar) % 8 >= bitsPerChar`.
2. **Non-canonical trailing bits** — the unused low bits of the final
   partial character must be zero (`"TQ=="` is canonical; `"TR=="` decodes
   to the same byte but is rejected).
3. **Padding count** — for padding alphabets, exactly the count that
   completes the final group (`"TQ"`, `"TQ="`, and `"TQ==="` are all
   rejected; only `"TQ=="` passes).

Default = all three ON. A documented lax mode (a `DecodeStrictness`
template parameter) is planned but deliberately not the default; the
reference decoder must reject.

## Adding a new alphabet

Define an `Alphabet` and every operation derives from it:

```d
enum Alphabet crockford = Alphabet(
    digits: "0123456789ABCDEFGHJKMNPQRSTVWXYZ",
    caseInsensitive: true,
    aliases: "O0I1L1");         // decode-only: O→0, I→1, L→1

alias encodeCrockford = encodeBase!crockford;
alias decodeCrockford = decodeBase!crockford;
```

Constraints: `digits.length` must be a power of two for the codec layer
(the numeral layer takes any 2–36); `aliases` are (from, to) character
pairs applied at decode only; a padding character makes encode emit
group-completing padding and decode require it.

## Performance notes

Scalar baselines on one x86-64 host (LDC `-O3 -mcpu=native`, via
`dub test :base -b bench -- --bench`):

| Path                      | base16    | base32    | base64    |
| ------------------------- | --------- | --------- | --------- |
| streaming encode, 64 KiB  | 0.59 GB/s | 0.84 GB/s | 0.94 GB/s |
| fixed-length encode, 32 B | 12.5 ns   | 14.0 ns   | 10.8 ns   |

- The **fixed-length** overloads are the first performance lever: with `N`
  known at compile time, group count, tail handling, and padding are
  constants and the per-group loops unroll — no accumulator state machine.
- The streaming kernel is the portable reference and the differential
  oracle for everything faster. Planned successors (each gated on
  differential fuzzing against it, including the rejection paths): AVX2
  base16, AVX2 base64 (Muła–Lemire), AVX-512-VBMI base64 and SWAR base32,
  behind one-time `core.cpuid` dispatch.
- The benchmark matrix (`@benchmark` tests in the module) is the
  measurement harness those milestones will extend — one row per kernel
  variant, grouped by preset/op/size, with B/s columns and a verifying
  `after` hook so a broken kernel cannot post a fast number.

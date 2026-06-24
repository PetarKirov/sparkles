# Known divergences

Reviewed, accepted divergences between `sparkles.base.text` and the
conformance oracles. Only divergences **absent** from this table fail the
run, so the harness is a ratchet.

The common, expected cause is **Unicode version skew**: the width tables
are pinned to a fixed UCD release (see `gen_unicode_tables.d`), but the
library's general-category and grapheme data come from the toolchain's
Phobos `std.uni`, which may lag. A newly-assigned combining mark therefore
reads as width 1 (impl) vs 0 (oracle, current UCD) until the compiler
catches up. Re-review and regenerate with `text-conformance --update-allowlist`
after a toolchain bump.

| layer | key     | observed | expected | reason               |
| ----- | ------- | -------- | -------- | -------------------- |
| 1     | U+1ACF  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD0  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD1  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD2  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD3  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD4  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD5  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD6  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD7  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD8  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AD9  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1ADA  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1ADB  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1ADC  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1ADD  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE0  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE1  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE2  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE3  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE4  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE5  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE6  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE7  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE8  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AE9  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AEA  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1AEB  | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+10EFA | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+10EFB | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+11B60 | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+11B61 | 1        | 0        | Mc (impl=1 oracle=0) |
| 1     | U+11B62 | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+11B63 | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+11B64 | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+11B65 | 1        | 0        | Mc (impl=1 oracle=0) |
| 1     | U+11B66 | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+11B67 | 1        | 0        | Mc (impl=1 oracle=0) |
| 1     | U+1E6E3 | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1E6E6 | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1E6EE | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1E6EF | 1        | 0        | Mn (impl=1 oracle=0) |
| 1     | U+1E6F5 | 1        | 0        | Mn (impl=1 oracle=0) |

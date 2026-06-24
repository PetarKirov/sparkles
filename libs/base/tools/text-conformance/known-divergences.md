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

| layer | key                              | observed | expected | reason                                                                                                                                  |
| ----- | -------------------------------- | -------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | U+1ACF                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD0                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD1                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD2                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD3                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD4                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD5                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD6                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD7                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD8                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AD9                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1ADA                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1ADB                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1ADC                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1ADD                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE0                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE1                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE2                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE3                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE4                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE5                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE6                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE7                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE8                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AE9                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AEA                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1AEB                           | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+10EFA                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+10EFB                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+11B60                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+11B61                          | 1        | 0        | Mc (impl=1 oracle=0)                                                                                                                    |
| 1     | U+11B62                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+11B63                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+11B64                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+11B65                          | 1        | 0        | Mc (impl=1 oracle=0)                                                                                                                    |
| 1     | U+11B66                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+11B67                          | 1        | 0        | Mc (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1E6E3                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1E6E6                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1E6EE                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1E6EF                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 1     | U+1E6F5                          | 1        | 0        | Mn (impl=1 oracle=0)                                                                                                                    |
| 3     | F09F9690F09F8FBB                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F9690F09F8FBC                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F9690F09F8FBD                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F9690F09F8FBE                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F9690F09F8FBF                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8CF09F8FBB                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8CF09F8FBC                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8CF09F8FBD                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8CF09F8FBE                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8CF09F8FBF                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E2989DF09F8FBB                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E2989DF09F8FBC                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E2989DF09F8FBD                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E2989DF09F8FBE                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E2989DF09F8FBF                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8DF09F8FBB                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8DF09F8FBC                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8DF09F8FBD                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8DF09F8FBE                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29C8DF09F8FBF                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B5F09F8FBB                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B5F09F8FBC                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B5F09F8FBD                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B5F09F8FBE                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B5F09F8FBF                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B4F09F8FBB                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B4F09F8FBC                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B4F09F8FBD                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B4F09F8FBE                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F95B4F09F8FBF                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8CF09F8FBB                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8CF09F8FBC                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8CF09F8FBD                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8CF09F8FBE                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8CF09F8FBF                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29BB9F09F8FBB                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29BB9F09F8FBC                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29BB9F09F8FBD                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29BB9F09F8FBE                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | E29BB9F09F8FBF                   | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8BF09F8FBB                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8BF09F8FBC                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8BF09F8FBD                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8BF09F8FBE                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | F09F8F8BF09F8FBF                 | 1        | 2        | RGI emoji-modifier sequence: width.d takes the (narrow) base width, missing kitty spec rule 3 (modifier-sequence base → 2)              |
| 3     | 20E186A8                         | 1        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | 20CC88E186A8                     | 1        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | 0DE186A8                         | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | 0DCC88E186A8                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | 0AE186A8                         | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | 0ACC88E186A8                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | 01E186A8                         | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | 01CC88E186A8                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | CD8FE186A8                       | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | CD8FCC88E186A8                   | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | F09F87A6E186A8                   | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | F09F87A6CC88E186A8               | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | D880CC88E186A8                   | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E0A483E186A8                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E0A483CC88E186A8                 | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E18480E186A8                     | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E18480CC88E186A8                 | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E185A0CC88E186A8                 | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A820                         | 1        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC8820                     | 1        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A80D                         | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC880D                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A80A                         | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC880A                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A801                         | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC8801                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CD8F                       | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88CD8F                   | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8F09F87A6                   | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88F09F87A6               | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8D880                       | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88D880                   | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8E0A483                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88E0A483                 | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8E18480                     | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88E18480                 | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8E185A0                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88E185A0                 | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8E186A8                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88E186A8                 | 0        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8EAB080                     | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88EAB080                 | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8EAB081                     | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88EAB081                 | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8E28C9A                     | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88E28C9A                 | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC80                       | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88CC80                   | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8E2808D                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88E2808D                 | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CDB8                       | 1        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E186A8CC88CDB8                   | 1        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | EAB080CC88E186A8                 | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | EAB081CC88E186A8                 | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E28C9AE186A8                     | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E28C9ACC88E186A8                 | 2        | 3        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | CC80E186A8                       | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | CC80CC88E186A8                   | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E2808DE186A8                     | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E2808DCC88E186A8                 | 0        | 1        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | CDB8E186A8                       | 1        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | CDB8CC88E186A8                   | 1        | 2        | conjoining Hangul jamo: width.d forces width 0 via its conjoining-range hack; kitty gives an isolated medial/final jamo width 1         |
| 3     | E29C81E2808DE29C81               | 1        | 2        | ZWJ sequence: kitty widens the joined emoji/dingbat to 2; width.d takes the (neutral) base width                                        |
| 4     | 20D880                           | 1        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | 20CC88D880                       | 1        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | 20E0A483                         | 1        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | 20CC88E0A483                     | 1        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | CD8FD880                         | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | CD8FCC88D880                     | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | CD8FE0A483                       | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | CD8FCC88E0A483                   | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | F09F87A6D880                     | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | F09F87A6CC88D880                 | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D88020                           | 0        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC8820                       | 1        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CD8F                         | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88CD8F                     | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880F09F87A6                     | 0        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88F09F87A6                 | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880D880                         | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88D880                     | 0        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880E0A483                       | 0        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | D880CC88E0A483                   | 0        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | D880E18480                       | 0        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88E18480                   | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880E185A0                       | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88E185A0                   | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880E186A8                       | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88E186A8                   | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880EAB080                       | 0        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88EAB080                   | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880EAB081                       | 0        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88EAB081                   | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880E28C9A                       | 0        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88E28C9A                   | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC80                         | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88CC80                     | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880E2808D                       | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88E2808D                   | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CDB8                         | 0        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | D880CC88CDB8                     | 1        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E0A48320                         | 1        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC8820                     | 1        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CD8F                       | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88CD8F                   | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483F09F87A6                   | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88F09F87A6               | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483D880                       | 0        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88D880                   | 0        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483E0A483                     | 0        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88E0A483                 | 0        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483E18480                     | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88E18480                 | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483E185A0                     | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88E185A0                 | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483E186A8                     | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88E186A8                 | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483EAB080                     | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88EAB080                 | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483EAB081                     | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88EAB081                 | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483E28C9A                     | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88E28C9A                 | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC80                       | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88CC80                   | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483E2808D                     | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88E2808D                 | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CDB8                       | 1        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E0A483CC88CDB8                   | 1        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E18480D880                       | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E18480CC88D880                   | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E185A0D880                       | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E185A0CC88D880                   | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E185A0E0A483                     | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E185A0CC88E0A483                 | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E186A8D880                       | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E186A8CC88D880                   | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E186A8E0A483                     | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E186A8CC88E0A483                 | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | EAB080D880                       | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | EAB080CC88D880                   | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | EAB081D880                       | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | EAB081CC88D880                   | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E28C9AD880                       | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E28C9ACC88D880                   | 2        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | CC80D880                         | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | CC80CC88D880                     | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | CC80E0A483                       | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | CC80CC88E0A483                   | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E2808DD880                       | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E2808DCC88D880                   | 0        | 1        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E2808DE0A483                     | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | E2808DCC88E0A483                 | 0        | 1        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | CDB8D880                         | 1        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | CDB8CC88D880                     | 1        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | CDB8E0A483                       | 1        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | CDB8CC88E0A483                   | 1        | 2        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | 61E0A48362                       | 2        | 3        | spacing mark (Mc): ghostty advances a cell per mark; width.d & the kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable) |
| 4     | 61D88062                         | 1        | 3        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | 61F09F8FBFF09F91B6               | 3        | 5        | RGI emoji-modifier sequence                                                                                                             |
| 4     | 61F09F8FBFF09F91B6E2808DF09F9B91 | 3        | 5        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |
| 4     | E29C81E2808DE29C81               | 1        | 2        | prepended/format (Cf): ghostty advances a cell; the TSP treats it as zero-width                                                         |

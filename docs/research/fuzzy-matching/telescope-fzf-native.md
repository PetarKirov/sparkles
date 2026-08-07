# telescope-fzf-native (C)

A faithful C port of [fzf]'s matcher — byte-identical constants and slab model
— whose value to this survey is as the only **in-process proxy for fzf's
algorithm** in cross-matcher benchmarks.

|                   |                                                                   |
| ----------------- | ----------------------------------------------------------------- |
| Language          | C (Lua FFI wrapper for Neovim/telescope)                          |
| License           | MIT                                                               |
| Repository        | [nvim-telescope/telescope-fzf-native.nvim][tfn-repo]              |
| Surveyed revision | [`b25b749b`][tfn-src] (all file/line citations pin this commit)   |
| Category          | Matcher library (no UI of its own)                                |
| Algorithm class   | Smith-Waterman variant, no substitution, single matrix ([fzf] V2) |

## Overview

### What it solves

telescope.nvim needed fzf's ranking _inside_ the editor process — fzf itself
is only usable as a child process. [`src/fzf.c`][tfn-src] (1272 lines) ports
the whole matcher surface: `fzf_fuzzy_match_v1`, `fzf_fuzzy_match_v2`,
`fzf_exact_match_naive`, `fzf_prefix_match`, `fzf_suffix_match`,
`fzf_equal_match`, plus `fzf_parse_pattern` with the full `!`/`^`/`$`/`'`
term syntax.

### Design philosophy

Fidelity. The constants are byte-identical including the derived forms:

```c
typedef enum {
  ScoreMatch = 16, ScoreGapStart = -3, ScoreGapExtention = -1,
  BonusBoundary = ScoreMatch / 2,
  BonusNonWord = ScoreMatch / 2,
  BonusCamel123 = BonusBoundary + ScoreGapExtention,
  BonusConsecutive = -(ScoreGapStart + ScoreGapExtention),
  BonusFirstCharMultiplier = 2,
} score_t;
```

and the slab allocator is faithful (`fzf_make_default_slab()` =
`{100*1024, 2048}`), including the V2→V1 degradation on slab overflow.

## The divergences — all Unicode, all TODO-marked

```c
static char_class char_class_of(char ch) {
  return char_class_of_ascii(ch);
  // if (ch <= 0x7f) { return char_class_of_ascii(ch); }
  // return char_class_of_non_ascii(ch);
}
```

Every non-ASCII byte classifies as `CharNonWord`, producing spurious boundary
bonuses _inside_ multi-byte codepoints, and `normalize_rune` is an identity
no-op. **Scores diverge from real fzf on any non-ASCII input.** For
benchmarking ASCII path corpora it remains the best available in-process
stand-in for fzf's algorithm — which is how the [comparison]'s independent
numbers use it.

## Analysis spine (delta-only)

This port intentionally has no design of its own; against the
[fzf deep-dive][fzf]'s spine it differs only in: **Unicode & case handling**
(ASCII-only classification, no normalization — above) and
**incremental & streaming architecture** (none; telescope drives it
per-keystroke over Lua FFI, re-matching the full list). Algorithm, scoring,
prefiltering, and memory strategy are the upstream design verbatim.

## Key design decisions and trade-offs

| Decision                          | Rationale                              | Trade-off                                           |
| --------------------------------- | -------------------------------------- | --------------------------------------------------- |
| Port verbatim, constants included | Ranking parity with fzf is the product | Inherits the single-matrix non-optimality           |
| Skip the Unicode tier (TODOs)     | ASCII covers most file paths           | Non-ASCII scores are wrong, not merely unnormalized |
| C + Lua FFI                       | In-process, editor-embeddable          | Manual memory management across the FFI boundary    |

## Sources

- [`src/fzf.c`][tfn-src] — the port (constants, matchers, slab, pattern
  parser; the `char_class_of` TODO quoted above).

<!-- References -->

[tfn-repo]: https://github.com/nvim-telescope/telescope-fzf-native.nvim
[tfn-src]: https://github.com/nvim-telescope/telescope-fzf-native.nvim/blob/b25b749b9db64d375d782094e2b9dce53ad53a40/src/fzf.c
[fzf]: ./fzf.md
[comparison]: ./comparison.md

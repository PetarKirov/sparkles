# text-conformance

A differential-testing harness that cross-checks
[`sparkles.base.text`](../../../../libs/base/src/sparkles/base/text/) — terminal
cell **width** and UAX #29 **grapheme segmentation** — against independent
Unicode oracles. It replaces ad-hoc, font-dependent spot checks with exhaustive,
data-driven comparison against authoritative sources.

It is the executable companion to the normative
[cell-splitting & width spec](./index.md) and its curated
[conformance test cases](./test-cases.md). The tool itself lives at
[`libs/base/tools/text-conformance/`](../../../../libs/base/tools/text-conformance/).

## The eleven layers

| Layer  | Checks                                                         | Oracle                                                                  |
| ------ | -------------------------------------------------------------- | ----------------------------------------------------------------------- |
| **0**  | segmentation: `byGraphemeCluster` boundaries                   | the official `GraphemeBreakTest.txt` (`÷`/`×` ground truth)             |
| **1**  | per-code-point width over **all** of `0..0x10FFFF`             | a clean-room oracle re-derived from raw UCD (`oracle.d`)                |
| **2**  | cluster width + single-cluster segmentation of every RGI emoji | `emoji-test.txt` + the clean-room oracle                                |
| **3**  | `visibleWidth` over an emoji + segmentation corpus             | **kitty** `wcswidth` (CLI binary, `+runpy`)                             |
| **4**  | `visibleWidth` over the same corpus                            | **ghostty** VT engine as a **library** (`libghostty-vt` cursor advance) |
| **5**  | `codepointWidth` over assigned code points                     | **utf8proc** `utf8proc_charwidth` (library)                             |
| **6**  | `byGraphemeCluster` boundaries (live)                          | **utf8proc** `utf8proc_grapheme_break` (library, Unicode 17.0)          |
| **7**  | `byGraphemeCluster` boundaries (live)                          | **ICU** `ubrk_*` (library, the UAX #29 reference)                       |
| **8**  | `visibleWidth` over the corpus                                 | **notcurses** `ncstrwidth` (library)                                    |
| **9**  | `codepointWidth` (assigned) + `visibleWidth` (corpus)          | **Rust** `unicode-width` crate (helper binary)                          |
| **10** | `codepointWidth` (assigned) + `visibleWidth` (corpus)          | **Python** jquast `wcwidth`, **embedded in-process via PyD**            |

The layers fall into four families that triangulate the library from different
angles:

- **Ground truth & clean-room** (0, 1, 2) — the official UCD test files and a
  raw-UCD oracle re-derived independently of `std.uni` and the generated tables.
  The oracle deliberately mirrors `width.d`'s _model_, so a shared simplification
  is invisible to it (see "Shared constants").
- **Live segmenters** (6 utf8proc, 7 ICU) — independent UAX #29 implementations
  at current Unicode, cross-checking `byGraphemeCluster` (whose `std.uni` tables
  lag — see "The two Unicode versions"). Layer 0 is the static-file version of
  the same check.
- **Terminal width models** (3 kitty, 4 ghostty, 8 notcurses) — three real
  terminal emulators measuring whole strings (grapheme-aware).
- **Library width models** (5 utf8proc, 9 Rust, 10 Python) — the dominant
  per-code-point width libraries of three ecosystems.

The terminal and library oracles are entirely separate _implementations_, so
they catch the shared-simplification cases the clean-room oracle can't — and,
crucially, **they disagree with each other**, showing which width questions are
genuinely contested rather than simple bugs.

### Where the models disagree

`sparkles` follows the kitty **Text Sizing Protocol** and sits between the others:

| Case                                               | sparkles | kitty | ghostty | utf8proc | rust  | notcurses |
| -------------------------------------------------- | -------- | ----- | ------- | -------- | ----- | --------- |
| RGI emoji-modifier, neutral base (✌🏻 `270C 1F3FB`) | 1        | **2** | 1       | —        | —     | —         |
| isolated Hangul medial/final jamo (`U+11A8`)       | 0        | **1** | 0       | 0        | —     | —         |
| Brahmic spacing mark (`की`, `U+0903`)              | 0        | 0     | **1**   | 0        | **1** | —         |
| prepended format (`U+0600`)                        | 0        | 0     | **1**   | 0        | **1** | —         |
| regional indicator half (`U+1F1FA`)                | 2        | 2     | 2       | **1**    | **1** | —         |
| emoji + VS16 (☠️)                                  | 2        | 2     | 2       | 2        | —     | **1**     |

(Terminal cells are bold where they differ from `sparkles`; `—` = agrees or
not directly comparable.) No oracle is "right": the harness documents exactly
where each model parts ways, and `sparkles` consistently follows the kitty TSP
(Marks → 0, one cell per Brahmic syllable).

The two terminal **library** oracles drive a real engine. Layer 4 (ghostty)
enables DEC mode 2027 (grapheme clustering — **off by default**, the difference
between per-codepoint and modern grapheme width), writes the bytes, and reads the
cursor column. Layer 8 (notcurses) calls `ncstrwidth` on a NUL-terminated, UTF-8
locale-forced string. Both are restricted to control-free strings (the cursor /
column count reflects real placement); kitty's pure `wcswidth` covers the rest.

## Running

```bash
# all layers (downloads UCD on first run, caches under $XDG_CACHE_HOME)
dub run --root=libs/base/tools/text-conformance -- --layers all

# a single layer, or a comma list
dub run --root=libs/base/tools/text-conformance -- --layers 1,6,7

# offline: the `offline` config drops every native dep (libcurl + all the
# binding/helper oracles), so only the pure layers run.
dub run --root=libs/base/tools/text-conformance --config=offline -- \
    --layers 0,1,2 --ucd-dir ~/.cache/sparkles-text-conformance --no-network

# unit tests for the oracle
dub test --root=libs/base/tools/text-conformance
```

Oracle requirements (all provided by the dev shell):

- **Layer 3 (kitty)** needs the `kitty` binary on `PATH` — optional, skips when
  absent; `--require-kitty` makes it a hard error.
- **Layers 4–8** link native libraries at build time via ImportC bindings under
  [`bindings/`](../../../../libs/base/tools/text-conformance/bindings/)
  (`libghostty-vt`, `utf8proc`, `icu-uc`, `notcurses-core`).
- **Layer 9 (Rust)** shells out to the `uwidth-rs` helper (built by
  `nix build .#uwidth-rs`); runtime-skips if absent.
- **Layer 10 (Python)** embeds CPython 3.11 in-process via PyD; needs the
  `python311`-with-`wcwidth` env and the `PYTHONPATH`/libpython variables the dev
  shell sets. The dev shell pins `wcwidth` 0.8.2; PyD is pinned to an untagged
  upstream commit (see the layer source).

All binding/helper layers are gated behind `version(...)` flags, so the
`offline`/`unittest` builds compile and run without any native dependency.

Exit code is `0` unless a layer has a **new** (non-allowlisted) divergence or a
hard error (a download failure, or required-but-missing kitty).

## The two Unicode versions

The harness pins **two** versions because the library itself does:

- **Width** (`--width-unicode-version`, default `17.0.0`) — matches the EAW /
  emoji-VS tables generated by
  [`gen_unicode_tables.d`](../../../../libs/base/tools/gen_unicode_tables.d).
- **Segmentation** (`--segmentation-unicode-version`, default `15.0.0`) — must
  match the toolchain's Phobos `std.uni` grapheme tables, which lag the width
  pin. Found empirically: Layer 0 reports **zero** divergences at 15.0.0 and a
  cluster of Indic-conjunct/emoji-ZWJ divergences at 15.1+, and the live
  segmenters (6, 7) at current Unicode confirm it.

`--unicode-version` sets both. **After a compiler upgrade**, re-run `--layers 0`
across a few versions to find the new matching segmentation version and bump
`phobosGraphemeUnicodeVersion` in `config.d`.

## The ratchet: `known-divergences.md`

Only divergences **absent** from
[`known-divergences.md`](../../../../libs/base/tools/text-conformance/known-divergences.md)
fail the run; listed ones are reported as "known" (yellow count) and do not fail.
This makes the harness a ratchet: a new regression turns the run red, while
already-understood divergences stay documented and green.

Regenerate after reviewing changes (with all oracles present):

```bash
nix shell nixpkgs#kitty --command \
    dub run --root=libs/base/tools/text-conformance -- --layers all --update-allowlist
```

Each row carries a `reason`. The ledger's classes, by layer:

- **Version skew (Layer 1, 42).** Combining marks `U+1ACF..U+1AE4` are width 0 in
  UCD 17.0 but width 1 from the older `std.uni`. Resolve on a toolchain bump.
- **Live segmentation (Layer 6, 1).** `U+2701 U+200D U+2701` — utf8proc 17.0
  splits the scissors-ZWJ sequence; `std.uni` 15.0 (and ICU 16 / Layer 7) keep
  it whole. Layer 7 has **0** divergences (ICU 16 matches `std.uni` for the
  corpus).
- **Model gaps vs kitty (Layer 3, 108).** `sparkles` matches ghostty but not
  kitty: emoji-modifier sequences with a neutral base, conjoining jamo, a ZWJ
  dingbat.
- **Model gaps vs ghostty (Layer 4, 99).** `sparkles` matches kitty but not
  ghostty: spacing marks (Mc) and prepended format (Cf) that ghostty advances.
- **Per-code-point gaps vs utf8proc / Rust / Python (Layers 5/9/10, 299 / 661 /
  260).** Regional indicators (sparkles 2 vs 1), noncharacters, conjoining jamo
  and spacing marks (the libraries give 1, like ghostty), plus the 42 version-skew
  marks that utf8proc (17.0) independently confirms. Python additionally returns
  `-1` for non-printables. Each of Layers 9 and 10 also reports a _per-string_
  agreement count as an informational note (not ratcheted) — those libraries are
  grapheme-unaware, so they diverge on most multi-scalar clusters.
- **notcurses (Layer 8, 417).** Its own model: it keeps emoji + VS16 at width 1
  (sparkles/kitty promote to 2), plus ZWJ / jamo differences.

The headline holds across all eleven: the contested width classes are
**implementation-dependent**, `sparkles` consistently follows the kitty Text
Sizing Protocol, and the independent oracles corroborate the version skew and the
segmentation lag from multiple angles.

## Shared constants (Layer 1's honest limitation)

The clean-room oracle differentially tests the **data-driven** classes
(East-Asian Width, general category). But a few inputs are spec constants, not
UCD properties — the regional-indicator range, the noncharacter formula, and the
four conjoining/format ranges. Both `width.d` and the oracle encode the same
literals, so Layer 1 only **asserts** them. The real terminals (Layers 3, 4, 8)
cover that blind spot.

## Comparing compilers (LDC vs DMD)

Segmentation rides Phobos `std.uni`, so it can differ between compilers. The
`offline` config drops all native deps and reads everything from `--ucd-dir`:

```bash
for c in ldc2 dmd; do for v in 15.0.0 17.0.0; do
  dub run --root=libs/base/tools/text-conformance --config=offline --compiler=$c -- \
    --layers 0 --segmentation-unicode-version $v \
    --ucd-dir ~/.cache/sparkles-text-conformance --no-network
done; done
```

Result (LDC 1.41 / Phobos 2.111 vs DMD 2.112.1): **both** segment Indic conjuncts
(InCB) like Unicode **15.0** — the Phobos "Update to Unicode 17.0.0" (v2.112.0)
bumped property _data_ but not grapheme-break behavior — and disagree on exactly
**one** boundary, `U+2701 U+200D U+2701`, where DMD's `Extended_Pictographic`
data flips the GB11 result. So `phobosGraphemeUnicodeVersion = 15.0.0` is right
for both.

## Layout

```
text-conformance/
├── dub.sdl
├── known-divergences.md          # the ratchet ledger
├── bindings/                     # ImportC shims (scoped to the harness)
│   ├── utf8proc/                 #   utf8proc_charwidth + grapheme_break
│   ├── icu/                      #   ubrk_* grapheme wrapper (icu_c.c)
│   └── notcurses/                #   ncstrwidth prototype
├── oracles/
│   └── uwidth-rs/                # Rust unicode-width helper (cargo + nix)
└── src/
    ├── app.d                     # CLI, orchestration, summary, exit code
    └── sparkles/text_conformance/
        ├── config.d  ucd.d  oracle.d  corpus.d  allowlist.d  report.d  subprocess.d
        ├── layer0_segmentation.d   layer1_width.d      layer2_emoji.d
        ├── layer3_kitty.d          layer4_ghostty.d    layer5_utf8proc.d
        ├── layer6_utf8proc_seg.d   layer7_icu_seg.d    layer8_notcurses.d
        └── layer9_rust_uwidth.d    layer10_python_wcwidth.d
```

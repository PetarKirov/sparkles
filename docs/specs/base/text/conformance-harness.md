---
status: accepted
owner: sparkles:base
reviewed: 2026-10-05
---

# text-conformance

## Abstract

`text-conformance` is the `sparkles:base` tool that cross-checks terminal
[grid-cell](../../../glossary.md#grid-cell) **width**, default **boundaries**,
**bidi**, **normalization**, and **casing** against independent Unicode oracles.
Official corpora and clean-room raw-data oracles provide reproducible checks
without a font-dependent visual oracle. The oracles include the official Unicode
test files, an oracle written independently from raw Unicode data, the kitty,
ghostty and notcurses terminal engines, the utf8proc, Rust `unicode-width` and
Python `wcwidth` width libraries, and the utf8proc and ICU segmenters. The terminal
engines and width libraries are other width policies, not Unicode authorities, so
a disagreement with them is classified rather than assumed to be ours.
Disagreements between implementations that are understood are recorded in a
ledger, so a foreign-policy run fails only on a new one; normative failures
cannot be waived.

## Introduction

The [cell-splitting & width specification](./index.md) states the
`terminalKitty` [width profile](../../../glossary.md#width-profile), and its
[case table](./test-cases.md) pins curated, hand-picked inputs. Neither can show how the implementation behaves on every code point, or
where it parts ways with other terminals. This harness is their executable
companion: it compares the library with every independent implementation it can
drive, layer by layer. It sorts each disagreement into one of three kinds. A
_version skew_ is a code point whose answer differs only because two sides use
different Unicode releases. A _contested width class_ is one where independent
implementations disagree among themselves. Anything else is a regression. The
tool lives at
[`libs/base/tools/text-conformance/`](../../../../libs/base/tools/text-conformance/).

The owned implementation and normative layers use one authenticated Unicode
18.0.0 manifest. The [owned Unicode contract](./SPEC.md) and
[acceptance strategy](./testing.md) require zero normative divergences, reached
at the gate tracked in [the delivery plan](./PLAN.md). _Owned_ there means that
sparkles implements the Unicode data and algorithms itself
([ownership](./SPEC.md#_1-scope-vocabulary-and-ownership)).

The compiler-derived baseline previously took Unicode data from two places:
generated width tables for one release and toolchain grapheme tables for an older
one. Its two version axes and compiler comparison are historical observations,
not the owned implementation's release selection.

The ledger records disagreements between oracles. Most historical entries are
contested width classes and version skew; one is a boundary on which the two live
segmenters disagreed. A failure against the official Unicode test files (Layer 0)
is never added to it. Terminal-width interoperability remains a separate
differential policy: an allowlist may document foreign model differences, never
waive an official boundary, bidi, normalization, or casing failure.

The sections below describe the layers, how to run them, the single manifest
identity, the ratchet ledger, the limitation of the clean-room oracle (derived
from raw Unicode data, independently of `std.uni` and the generated tables), and
the historical compiler comparison. Executed evidence covers the prior contract
subset; it does not establish the newly added width-profile, glyph-channel,
overflow-storage, or scaled-footprint requirements. Their implementation and
independent-review gates remain open as recorded in
[the acceptance strategy](./testing.md#_9-independent-contract-review).

## The seventeen layers

| Layer  | Checks                                                               | Oracle                                                                              |
| ------ | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **0**  | segmentation: `byGraphemeCluster` boundaries                         | the official `GraphemeBreakTest.txt` (`÷`/`×` ground truth)                         |
| **1**  | per-code-point width over **all** of `0..0x10FFFF`                   | a clean-room oracle re-derived from raw UCD (`oracle.d`)                            |
| **2**  | cluster width + single-cluster segmentation of every RGI emoji       | `emoji-test.txt` + the clean-room oracle                                            |
| **3**  | `visibleWidth` over an emoji + segmentation corpus                   | **kitty** `wcswidth` (CLI binary, `+runpy`)                                         |
| **4**  | `visibleWidth` over the same corpus                                  | **ghostty** VT engine as a **library** (`libghostty-vt` cursor advance)             |
| **5**  | `codepointWidth` over assigned code points                           | **utf8proc** `utf8proc_charwidth` (library)                                         |
| **6**  | `byGraphemeCluster` boundaries (live)                                | **utf8proc** `utf8proc_grapheme_break` (library, Unicode 17.0)                      |
| **7**  | `byGraphemeCluster` boundaries (live)                                | **ICU** `ubrk_*` (library, the UAX #29 reference)                                   |
| **8**  | `visibleWidth` over the corpus                                       | **notcurses** `ncstrwidth` (library)                                                |
| **9**  | `codepointWidth` (assigned) + `visibleWidth` (corpus)                | **Rust** `unicode-width` crate (helper binary)                                      |
| **10** | `codepointWidth` (assigned) + `visibleWidth` (corpus)                | **Python** jquast `wcwidth`, **embedded in-process via PyD**                        |
| **11** | default word boundaries in UTF-32 and UTF-8                          | official `WordBreakTest.txt`                                                        |
| **12** | default sentence boundaries in UTF-32 and UTF-8                      | official `SentenceBreakTest.txt`                                                    |
| **13** | default line opportunities and mandatory breaks                      | official `LineBreakTest.txt`                                                        |
| **14** | bidi levels, order, maps, paragraph and line behavior                | official `BidiTest.txt` and `BidiCharacterTest.txt`                                 |
| **15** | all normalization forms, omitted-scalar identities, exact provenance | official `NormalizationTest.txt`                                                    |
| **16** | exhaustive simple/full casing and root/tr/az/lt contexts             | clean-room `UnicodeData`, `SpecialCasing`, `CaseFolding` and raw context properties |

The layers fall into four families that triangulate the library from different
angles:

- **Ground truth & clean-room** (0, 1, 2, 11–16) — the official UCD test files and a
  raw-UCD oracle re-derived independently of `std.uni` and the generated tables.
  The oracle deliberately mirrors `width.d`'s _model_, so a shared simplification
  is invisible to it (see "Shared constants").
- **Live segmenters** (6 utf8proc, 7 ICU) — independent UAX #29 implementations
  cross-checking the owned Unicode 18 `byGraphemeCluster`. Installed foreign
  versions (Unicode 17.0 for utf8proc and ICU 16's data in the historical run)
  are comparison evidence, not the implementation's data source or normative
  release selection. Layer 0 is the static-file version of the same check.
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
# all layers, explicitly opting into foreign-library dependencies
# (downloads UCD on first run, caches under $XDG_CACHE_HOME)
dub run --root=libs/base/tools/text-conformance \
    --recipe=libs/base/tools/text-conformance/oracles.sdl -- --layers all

# a single foreign layer, or a comma list
dub run --root=libs/base/tools/text-conformance \
    --recipe=libs/base/tools/text-conformance/oracles.sdl -- --layers 1,6,7

# offline is the default recipe/configuration; no native or downloader deps
dub run :text-conformance --config=offline -- \
    --layers 0,11,12,13,14,15,16 \
    --manifest libs/base/tools/unicode/manifest.json \
    --ucd-dir libs/base/tools/unicode/18.0.0 --no-network

# unit tests for the oracle
dub test --root=libs/base/tools/text-conformance
```

### Required CI gate

```bash
nix build -L .#checks.x86_64-linux.text-conformance
```

The unconditional **Owned Unicode conformance** job runs this derivation on every
CI trigger and participates in the required `CI` fan-in. `nix flake check` also
includes it. The derivation builds the existing executable through the shared
Sparkles DUB builder, then runs complete layers **0, 1, 2, 11, 12, 13, 14, 15, 16** in
the Nix build sandbox with `--no-network`, an explicit manifest, and an immutable
input directory. The summary and per-corpus totals are retained as the check's
output file; `nix log` exposes the execution log even when a cached result is used.

Layers 1 and 2 independently check every Unicode scalar's width against raw UCD
and every fully-qualified emoji's cluster width and segmentation. The expanded
sandboxed gate passed 1,112,064 scalar checks and 3,963 emoji checks with zero
known or new failures, in addition to the complete normative algorithm corpora.

Only `libs/base/tools/unicode/manifest.json` is tracked as raw-input metadata.
All 35 reviewed artifacts, including the official boundary, bidi and normalization
corpora, raw casing/context inputs, and license, are ignored local cache data.
`unicode-conformance-data` provisions each artifact through a manifest-driven Nix
fixed-output download pinned to its SHA-256, then assembles an immutable inventory.
Provisioning may fetch missing store objects; normative execution does not download,
consult a user cache, or sample the corpora.
Each consumed input is authenticated by the D harness against manifest identity
`df3659783f974cb439f4f6436dc4e72f0d06313a45b865c04921dba1d938abcc`,
which must also match the generated implementation.

Default/root and unittest builds do not resolve or link the foreign oracles.
DUB resolves dependencies in inactive configurations too, so those declarations
live in the opt-in `oracles.sdl` recipe rather than an inactive block of the default
recipe. Both recipes build the same harness sources and executable. Required
normative layers fail on errors, skipped/zero-check execution, or any divergence;
the foreign-policy allowlist cannot waive their failures.

Foreign-oracle requirements (all provided by the default development shell):

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

All binding/helper implementations are gated behind `version(...)` flags.
The default `offline`/`unittest` recipe needs no native dependency; `oracles.sdl`
enables the foreign-library versions.

Exit code is `0` unless a layer has a **new** (non-allowlisted) divergence or a
hard error (a download failure, or required-but-missing kitty).

## One manifest identity

The generator and harness authenticate the same Unicode 18.0.0 inputs, including
the license and official test corpora. `--manifest` selects the checked manifest
and `--ucd-dir` supplies its `ucd/`, `emoji/`, and license artifacts. Cache entries
are namespaced by manifest identity. Compiler upgrades cannot select a different
segmentation or width release; the former version-axis CLI options are removed.

The integrated CLI run of layers 11–16 passed 16,974 word endpoint checks
(1,944 records), 4,734 sentence endpoint checks (512 records), 80,131 line checks
(19,346 cases), 861,948 bidi direction cases, 4,783,064 normalization checks,
and 11,120,810 casing checks. Normalization includes 99,999-nonstarter exact
provenance stress; casing includes 5,560,490 full transforms and 5,560,320
simple-map comparisons with root/tr/az/lt contexts. These are scoped algorithm
results, not whole-package, font, platform, or final M6 signoff, and not evidence
for the newly added width-profile, glyph-channel, or scaled-footprint obligations.

### Historical compiler-derived baseline

The former CLI pinned two axes:

- **Width** (`--width-unicode-version`, default `17.0.0`) matched the EAW /
  emoji-VS tables generated by
  [`gen_unicode_tables.d`](../../../../libs/base/tools/gen_unicode_tables.d).
- **Segmentation** (`--segmentation-unicode-version`, default `15.0.0`) had to
  match the toolchain's Phobos `std.uni` grapheme tables. Under LDC 1.41, Layer 0
  had zero divergences at 15.0.0 and a cluster of Indic-conjunct/emoji-ZWJ
  divergences at 15.1 and later; the live segmenters (6, 7) confirmed the gap.

The former `--unicode-version` set both axes. Compiler upgrades previously
required probing Layer 0 across versions and updating
`phobosGraphemeUnicodeVersion` in `config.d`; neither that selector nor the
compiler-derived release-selection procedure applies to the owned implementation.

Under LDC 1.42.0, the offline run passes all 1,112,064 scalar width cases and
all 3,655 RGI emoji cases, and Layer 0 passes 601 of 602 Unicode 15 cases:
`U+2701 U+200D U+2701` splits as `[2, 1]` code points instead of the expected
`[3]`. A direct Phobos probe returns the same first stride of two as the
`SharedBuffer`-based cluster window, so the divergence comes from Phobos, not
from the SIMD/window optimization. It is a failing conformance observation:
it is neither an allowlist entry nor a reason to change the normative expected
boundary. See the [performance report](../../../research/simd-unicode/performance.md).

## The ratchet: `known-divergences.md`

Foreign-policy divergences absent from
[`known-divergences.md`](../../../../libs/base/tools/text-conformance/known-divergences.md)
fail the run; listed ones are reported as known. Official normative layers 0 and
11–16 always fail on any divergence, even if a matching allowlist row exists.
`--update-allowlist` excludes their failures. Missing or malformed required data
is a hard error, not an oracle skip.

Regenerate after reviewing changes (with all oracles present):

```bash
nix shell nixpkgs#kitty --command \
    dub run --root=libs/base/tools/text-conformance \
    --recipe=libs/base/tools/text-conformance/oracles.sdl -- --layers all --update-allowlist
```

The recorded historical ledger rows carry a `reason`. Their classes, by layer
(these counts are not a post-cutover foreign-oracle acceptance run):

- **Version skew (Layer 1, 42).** Combining marks `U+1ACF..U+1AE4` are width 0 in
  UCD 17.0 but width 1 from the Unicode 15.0 categories of `std.uni`. A
  toolchain whose `std.uni` classifies them as marks resolves these rows.
- **Live segmentation (Layer 6, 1).** `U+2701 U+200D U+2701` — utf8proc 17.0
  splits the scissors-ZWJ sequence; LDC 1.41's `std.uni` (and ICU 16 / Layer 7) keep
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

The historical headline across all eleven layers was that contested width
classes were **implementation-dependent**, `sparkles` followed the kitty Text
Sizing Protocol, and independent oracles corroborated the version skew between
the width and segmentation axes from multiple angles. It does not establish the
new width-profile or scaled-footprint requirements.

## Shared constants (Layer 1's honest limitation)

The clean-room oracle differentially tests the **data-driven** classes
(East-Asian Width, general category). But a few inputs are spec constants, not
UCD properties — the regional-indicator range, the noncharacter formula, and the
four conjoining/format ranges. Both `width.d` and the oracle encode the same
literals, so Layer 1 only **asserts** them. The real terminals (Layers 3, 4, 8)
cover that blind spot.

## Comparing compilers (LDC vs DMD)

The owned algorithms use the same authenticated Unicode 18 manifest with either
compiler; switching compilers does not select a Phobos Unicode release:

```bash
for c in ldc2 dmd; do
  dub run :text-conformance --config=offline --compiler=$c -- \
    --layers 0,11,12,13,14,15,16 --no-network \
    --manifest libs/base/tools/unicode/manifest.json \
    --ucd-dir libs/base/tools/unicode/18.0.0
done
```

The compiler-derived results above are historical baselines, not current owned
conformance expectations. The former segmentation-version selector no longer
exists.

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

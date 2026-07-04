# Grounding ledger — units-of-measure survey

Claim-by-claim source verification for every published page of the
`docs/research/units-of-measure/` tree. Each survey page has a companion ledger
here that lists its material claims and the **local** artifact each was checked
against (`$REPOS = /home/petar/code/repos`; the pinned corpus is mapped in
[`_sources.md`](./_sources.md)).

> Not published research. This tree is excluded from the VitePress build
> (`srcExclude`) and from `lychee` (`exclude_path`). Do not link to it from the
> survey pages.

## Status legend

| Mark | Meaning                                                                                      |
| ---- | -------------------------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact (locator recorded)                                 |
| `⚠`  | Discrepancy — wrong/misattributed/imprecise; correction recorded **and** applied to the page |
| `◯`  | Not locally groundable — editorial/opinion, or source unobtainable (secondary named)         |

Claim **Types:** `quote` · `fact` (date/author/venue/attribution) · `figure`
(number/bound/line) · `behavior` (system does X / reproduced error) ·
`exposition` (textbook-standard) · `opinion`.

## Per-page ledgers

`Rows` counts material claim rows; `⚠` the discrepancies found and fixed this
pass; `◯` the rows groundable only to a secondary or to an unobtainable primary
(all named per row). Every material discrepancy was **applied** to its page; the
few wave-2 ⚠ rows that flag only a condensed-but-faithful quote or a secondary
attribution — needing no page change — are named per row.

| Page                               | Ledger                                                                   | Rows     | ⚠       | ◯      | Status |
| ---------------------------------- | ------------------------------------------------------------------------ | -------- | ------- | ------ | ------ |
| `theory/whitney.md`                | [`theory-whitney.md`](./theory-whitney.md)                               | 63       | 4       | 4      | ✅     |
| `theory/buckingham-pi.md`          | [`theory-buckingham-pi.md`](./theory-buckingham-pi.md)                   | 77       | 5       | 2      | ✅     |
| `theory/free-abelian-group.md`     | [`theory-free-abelian-group.md`](./theory-free-abelian-group.md)         | 71       | 6       | 5      | ✅     |
| `theory/tensor-of-lines.md`        | [`theory-tensor-of-lines.md`](./theory-tensor-of-lines.md)               | 69       | 2       | 3      | ✅     |
| `theory/torsor-representation.md`  | [`theory-torsor-representation.md`](./theory-torsor-representation.md)   | 81       | 9       | 2      | ✅     |
| `theory/kennedy-types.md`          | [`theory-kennedy-types.md`](./theory-kennedy-types.md)                   | 69       | 2       | 3      | ✅     |
| `theory/hart-multidimensional.md`  | [`theory-hart-multidimensional.md`](./theory-hart-multidimensional.md)   | 51       | 4       | 4      | ✅     |
| `theory/type-system-mechanisms.md` | [`theory-type-system-mechanisms.md`](./theory-type-system-mechanisms.md) | 52       | 3       | 4      | ✅     |
| `fsharp-uom.md`                    | [`fsharp-uom.md`](./fsharp-uom.md)                                       | 76       | 4       | 4      | ✅     |
| `haskell-uom-plugin.md`            | [`haskell-uom-plugin.md`](./haskell-uom-plugin.md)                       | 69       | 6       | 2      | ✅     |
| `haskell-dimensional.md`           | [`haskell-dimensional.md`](./haskell-dimensional.md)                     | 70       | 6       | 2      | ✅     |
| `rust-uom.md`                      | [`rust-uom.md`](./rust-uom.md)                                           | 47       | 3       | 1      | ✅     |
| `rust-dimensioned.md`              | [`rust-dimensioned.md`](./rust-dimensioned.md)                           | 54       | 5       | 3      | ✅     |
| `cpp-mp-units.md`                  | [`cpp-mp-units.md`](./cpp-mp-units.md)                                   | 72       | 3       | 0      | ✅     |
| `cpp-boost-units.md`               | [`cpp-boost-units.md`](./cpp-boost-units.md)                             | 65       | 1       | 1      | ✅     |
| `cpp-au.md`                        | [`cpp-au.md`](./cpp-au.md)                                               | 85       | 4       | 1      | ✅     |
| `d-quantities.md`                  | [`d-quantities.md`](./d-quantities.md)                                   | 78       | 3       | 0      | ✅     |
| `python-pint.md`                   | [`python-pint.md`](./python-pint.md)                                     | 65       | 5       | 2      | ✅     |
| `julia-unitful.md`                 | [`julia-unitful.md`](./julia-unitful.md)                                 | 62       | 1       | 2      | ✅     |
| `ada-gnat-dimensions.md`           | [`ada-gnat-dimensions.md`](./ada-gnat-dimensions.md)                     | 54       | 0       | 5      | ✅     |
| `lean-mathlib-units.md`            | [`lean-mathlib-units.md`](./lean-mathlib-units.md)                       | 56       | 3       | 1      | ✅     |
| `wolfram-matlab.md`                | [`wolfram-matlab.md`](./wolfram-matlab.md)                               | 58       | 3       | 1      | ✅     |
| `scala-coulomb.md`                 | [`scala-coulomb.md`](./scala-coulomb.md)                                 | 52       | 2       | 3      | ✅     |
| `scala-squants.md`                 | [`scala-squants.md`](./scala-squants.md)                                 | 49       | 4       | 2      | ✅     |
| `nim-unchained.md`                 | [`nim-unchained.md`](./nim-unchained.md)                                 | 51       | 3       | 3      | ✅     |
| `swift-units.md`                   | [`swift-units.md`](./swift-units.md)                                     | 47       | 7       | 2      | ✅     |
| `kotlin-measured.md`               | [`kotlin-measured.md`](./kotlin-measured.md)                             | 49       | 6       | 3      | ✅     |
| `ucum-qudt.md`                     | [`ucum-qudt.md`](./ucum-qudt.md)                                         | 48       | 8       | 3      | ✅     |
| `comparison.md`                    | [`comparison.md`](./comparison.md)                                       | 78       | 9       | 3      | ✅     |
| `concepts.md`                      | [`concepts.md`](./concepts.md)                                           | 81       | 4       | 4      | ✅     |
| `index.md`                         | [`page-index.md`](./page-index.md)                                       | 46       | 1       | 1      | ✅     |
| `theory/index.md`                  | [`theory-index.md`](./theory-index.md)                                   | 39       | 1       | 2      | ✅     |
| **Total**                          |                                                                          | **1984** | **127** | **78** | ✅     |

Each `◯` row names its fallback in the per-page ledger. The tree-wide
unobtainable primaries and their secondaries (Whitney 1968 I & II, ISO 80000-1,
Hart 1995) are enumerated in [`_sources.md`](./_sources.md).

## Master discrepancy register

Every discrepancy below was **fixed in the same pass** (page + ledger edited);
`Fixed?` is `✓` throughout. The full claim / correction / source-proof for each
lives in the per-page ledger's `## Discrepancies` section under the local ID.
Severity: **S** = substantive (wrong fact/quote/attribution/figure), **m** =
minor (imprecise locator, quote truncation, cosmetic).

### Theory (R1–R35)

| R   | Page                            | ID      | Sev | Location  | Fixed? |
| --- | ------------------------------- | ------- | --- | --------- | ------ |
| R1  | `theory/whitney`                | `#D1`   | S   | :584      | ✓      |
| R2  | `theory/whitney`                | `#D2`   | m   | :518      | ✓      |
| R3  | `theory/whitney`                | `#D3`   | m   | :80       | ✓      |
| R4  | `theory/whitney`                | `#D4`   | m   | :48, :463 | ✓      |
| R5  | `theory/buckingham-pi`          | `#B-D1` | m   | :645      | ✓      |
| R6  | `theory/buckingham-pi`          | `#B-D2` | m   | :508-509  | ✓      |
| R7  | `theory/buckingham-pi`          | `#B-D3` | m   | :224-225  | ✓      |
| R8  | `theory/buckingham-pi`          | `#B-D4` | m   | :651-652  | ✓      |
| R9  | `theory/buckingham-pi`          | `#B-D5` | m   | :66-68    | ✓      |
| R10 | `theory/free-abelian-group`     | `#D1`   | S   | :689      | ✓      |
| R11 | `theory/free-abelian-group`     | `#D2`   | S   | :439-441  | ✓      |
| R12 | `theory/free-abelian-group`     | `#D3`   | m   | :453      | ✓      |
| R13 | `theory/free-abelian-group`     | `#D4`   | m   | :58-59    | ✓      |
| R14 | `theory/free-abelian-group`     | `#D5`   | m   | :702-704  | ✓      |
| R15 | `theory/free-abelian-group`     | `#D6`   | m   | :539      | ✓      |
| R16 | `theory/tensor-of-lines`        | `#D1`   | m   | :613-614  | ✓      |
| R17 | `theory/tensor-of-lines`        | `#D2`   | m   | :432-433  | ✓      |
| R18 | `theory/torsor-representation`  | `#D1`   | m   | :481      | ✓      |
| R19 | `theory/torsor-representation`  | `#D2`   | m   | :534      | ✓      |
| R20 | `theory/torsor-representation`  | `#D3`   | m   | :221      | ✓      |
| R21 | `theory/torsor-representation`  | `#D4`   | m   | :345-346  | ✓      |
| R22 | `theory/torsor-representation`  | `#D5`   | m   | :451      | ✓      |
| R23 | `theory/torsor-representation`  | `#D6`   | m   | :649-655  | ✓      |
| R24 | `theory/torsor-representation`  | `#D7`   | m   | :50       | ✓      |
| R25 | `theory/torsor-representation`  | `#D8`   | m   | :663-665  | ✓      |
| R26 | `theory/torsor-representation`  | `#D9`   | m   | :766-768  | ✓      |
| R27 | `theory/kennedy-types`          | `#D1`   | S   | :674      | ✓      |
| R28 | `theory/kennedy-types`          | `#D2`   | m   | :298-300  | ✓      |
| R29 | `theory/hart-multidimensional`  | `#D1`   | m   | :242      | ✓      |
| R30 | `theory/hart-multidimensional`  | `#D2`   | m   | :443-445  | ✓      |
| R31 | `theory/hart-multidimensional`  | `#D3`   | m   | :199      | ✓      |
| R32 | `theory/hart-multidimensional`  | `#D4`   | m   | :74-75    | ✓      |
| R33 | `theory/type-system-mechanisms` | `#D1`   | m   | :93, :589 | ✓      |
| R34 | `theory/type-system-mechanisms` | `#D2`   | m   | :235      | ✓      |
| R35 | `theory/type-system-mechanisms` | `#D3`   | m   | :504      | ✓      |

### Systems (R36–R82)

| R   | Page                  | ID    | Sev | Location | Fixed? |
| --- | --------------------- | ----- | --- | -------- | ------ |
| R36 | `fsharp-uom`          | `#D1` | m   | :17      | ✓      |
| R37 | `fsharp-uom`          | `#D2` | S   | :44-45   | ✓      |
| R38 | `fsharp-uom`          | `#D3` | m   | :367-368 | ✓      |
| R39 | `fsharp-uom`          | `#D4` | m   | :441-442 | ✓      |
| R40 | `haskell-uom-plugin`  | `#D1` | S   | :219     | ✓      |
| R41 | `haskell-uom-plugin`  | `#D2` | m   | :273     | ✓      |
| R42 | `haskell-uom-plugin`  | `#D3` | m   | :538     | ✓      |
| R43 | `haskell-uom-plugin`  | `#D4` | m   | :542     | ✓      |
| R44 | `haskell-uom-plugin`  | `#D5` | m   | :554     | ✓      |
| R45 | `haskell-uom-plugin`  | `#D6` | m   | :589     | ✓      |
| R46 | `haskell-dimensional` | `#D1` | m   | :530     | ✓      |
| R47 | `haskell-dimensional` | `#D2` | m   | :446     | ✓      |
| R48 | `haskell-dimensional` | `#D3` | m   | :477     | ✓      |
| R49 | `haskell-dimensional` | `#D4` | m   | :573-574 | ✓      |
| R50 | `haskell-dimensional` | `#D5` | m   | :236-238 | ✓      |
| R51 | `haskell-dimensional` | `#D6` | m   | :337-338 | ✓      |
| R52 | `rust-uom`            | `#D1` | m   | :359-360 | ✓      |
| R53 | `rust-uom`            | `#D2` | m   | :435     | ✓      |
| R54 | `rust-uom`            | `#D3` | m   | :558-560 | ✓      |
| R55 | `rust-dimensioned`    | `#D1` | m   | :67-71   | ✓      |
| R56 | `rust-dimensioned`    | `#D2` | m   | :97      | ✓      |
| R57 | `rust-dimensioned`    | `#D3` | m   | :524     | ✓      |
| R58 | `rust-dimensioned`    | `#D4` | m   | :325-327 | ✓      |
| R59 | `rust-dimensioned`    | `#D5` | m   | :421-423 | ✓      |
| R60 | `cpp-mp-units`        | `#D1` | m   | :222-223 | ✓      |
| R61 | `cpp-mp-units`        | `#D2` | m   | :16      | ✓      |
| R62 | `cpp-mp-units`        | `#D3` | m   | :503     | ✓      |
| R63 | `cpp-boost-units`     | `#D1` | m   | :161     | ✓      |
| R64 | `cpp-au`              | `#D1` | m   | :382     | ✓      |
| R65 | `cpp-au`              | `#D2` | m   | :415-417 | ✓      |
| R66 | `cpp-au`              | `#D3` | m   | :220     | ✓      |
| R67 | `cpp-au`              | `#D4` | m   | :241     | ✓      |
| R68 | `d-quantities`        | `#D1` | S   | :578     | ✓      |
| R69 | `d-quantities`        | `#D2` | m   | :596-597 | ✓      |
| R70 | `d-quantities`        | `#D3` | m   | :236-239 | ✓      |
| R71 | `python-pint`         | `#D1` | m   | :627     | ✓      |
| R72 | `python-pint`         | `#D2` | m   | :326-328 | ✓      |
| R73 | `python-pint`         | `#D3` | m   | :317-319 | ✓      |
| R74 | `python-pint`         | `#D4` | m   | :154-155 | ✓      |
| R75 | `python-pint`         | `#D5` | m   | :109-120 | ✓      |
| R76 | `julia-unitful`       | `#D1` | m   | :38-39   | ✓      |
| R77 | `lean-mathlib-units`  | `#D1` | m   | :216-218 | ✓      |
| R78 | `lean-mathlib-units`  | `#D2` | m   | :70-71   | ✓      |
| R79 | `lean-mathlib-units`  | `#D3` | m   | :79      | ✓      |
| R80 | `wolfram-matlab`      | `#D1` | m   | :150-156 | ✓      |
| R81 | `wolfram-matlab`      | `#D2` | m   | :110-115 | ✓      |
| R82 | `wolfram-matlab`      | `#D3` | m   | :304-308 | ✓      |

### Synthesis (R83–R97)

| R   | Page                   | ID    | Sev | Location | Fixed? |
| --- | ---------------------- | ----- | --- | -------- | ------ |
| R83 | `comparison`           | `#D1` | S   | :172-176 | ✓      |
| R84 | `comparison`           | `#D2` | m   | :81-83   | ✓      |
| R85 | `comparison`           | `#D3` | m   | :110-111 | ✓      |
| R86 | `comparison`           | `#D4` | S   | :388     | ✓      |
| R87 | `comparison`           | `#D5` | S   | :625     | ✓      |
| R88 | `comparison`           | `#D6` | m   | :226-227 | ✓      |
| R89 | `comparison`           | `#D7` | m   | :526     | ✓      |
| R90 | `comparison`           | `#D8` | m   | :518-522 | ✓      |
| R91 | `comparison`           | `#D9` | m   | :36      | ✓      |
| R92 | `concepts`             | `#D1` | m   | :311-313 | ✓      |
| R93 | `concepts`             | `#D2` | m   | :335     | ✓      |
| R94 | `concepts`             | `#D3` | m   | :360-362 | ✓      |
| R95 | `concepts`             | `#D4` | m   | :399     | ✓      |
| R96 | `index` (`page-index`) | `#D1` | m   | :214     | ✓      |
| R97 | `theory/index`         | `#D1` | m   | :76      | ✓      |

### Systems — wave 2 (R98–R118)

The twenty-one **material** discrepancies caught by the wave-2 grounding pass,
all applied to the pages in commit `bc7dc75`. (The six wave-2 ledgers additionally
mark nine rows ⚠ for condensed-but-faithful quotes or secondary attributions that
needed no page change — they are noted in-ledger, not listed here.) The rows the
wave-2 systems added to `comparison.md`'s matrix and `index.md`'s catalog derive
from these six page ledgers; no new primary claim was introduced in the synthesis
pages.

| R    | Page              | ID    | Sev | Location       | Fixed? |
| ---- | ----------------- | ----- | --- | -------------- | ------ |
| R98  | `scala-squants`   | `#D1` | S   | :155-156,:297  | ✓      |
| R99  | `scala-squants`   | `#D2` | m   | :313-317       | ✓      |
| R100 | `scala-squants`   | `#D3` | m   | :434           | ✓      |
| R101 | `scala-squants`   | `#D4` | m   | :496           | ✓      |
| R102 | `nim-unchained`   | `#D1` | m   | :326-329,:577  | ✓      |
| R103 | `nim-unchained`   | `#D2` | m   | :17            | ✓      |
| R104 | `swift-units`     | `#D7` | S   | :292           | ✓      |
| R105 | `swift-units`     | `#D1` | m   | :52            | ✓      |
| R106 | `swift-units`     | `#D2` | m   | :286           | ✓      |
| R107 | `swift-units`     | `#D3` | m   | :130           | ✓      |
| R108 | `swift-units`     | `#D4` | m   | :395           | ✓      |
| R109 | `swift-units`     | `#D5` | m   | :101,:406,:409 | ✓      |
| R110 | `swift-units`     | `#D6` | m   | :415           | ✓      |
| R111 | `kotlin-measured` | `#D1` | m   | :50-53         | ✓      |
| R112 | `kotlin-measured` | `#D2` | m   | :57            | ✓      |
| R113 | `kotlin-measured` | `#D3` | m   | :174,:459      | ✓      |
| R114 | `ucum-qudt`       | `#D1` | m   | :294           | ✓      |
| R115 | `ucum-qudt`       | `#D2` | m   | :164,:174      | ✓      |
| R116 | `ucum-qudt`       | `#D3` | m   | :254           | ✓      |
| R117 | `ucum-qudt`       | `#D4` | m   | :220,:223,:287 | ✓      |
| R118 | `ucum-qudt`       | `#D5` | m   | :163           | ✓      |

## Substantive corrections (spelled out)

The twelve `S` rows are the corrections that changed a claim's meaning, not just a
locator or a transcription. Each is detailed in its ledger; in brief:

- **R1 — `whitney` `#D1`.** The mechanization table filed Wand & O'Keefe under
  the `ℝ`-exponent row; Kennedy §3.4 and the W&O paper itself put their dimension
  exponents over the **rationals**. Moved to the `ℚ` row (also aligns
  `whitney.md` with `kennedy-types.md`).
- **R10 — `free-abelian-group` `#D1`.** The typed-libraries table gave the D
  artifacts (`quantities`/`units-d`/`std.units`) exponent domain `ℤ`; all three
  canonicalize **`ℚ`** (gcd-normalized `Rational` per dimension). Now agrees with
  `d-quantities.md`.
- **R11 — `free-abelian-group` `#D2`.** The closing line attributed "formal sums
  / direct sums of fibers" to Hart; the 1994 SIAM paper never forms cross-dimension
  sums (tuples only). Softened to the tuple/product reading per `comparison.md`.
- **R27 — `kennedy-types` `#D1`.** An F#-internals aside over-claimed
  surface-level integrality maintenance; corrected against Gundry 2015 fn. 21 and
  the F# behavior (rational measure exponents survive).
- **R37 — `fsharp-uom` `#D2`.** The generic-`sqr` example claimed inference "with
  no annotation at all"; the spec's own example uses a `float<_>` carrier
  annotation. Corrected to match §9.
- **R40 — `haskell-uom-plugin` `#D1`.** Claimed contradictory wanteds are
  reported as `TcPluginContradiction`; at the pin they are deliberately **not**
  reported that way. Corrected against the plugin source.
- **R68 — `d-quantities` `#D1`.** The compilability table claimed Nadlinger's
  `std.units` unittests "all pass" under a modern compiler; the reproduction shows
  otherwise. Corrected to the actual `ldc2 1.41` result.
- **R83 — `comparison` `#D1`.** The Hart reconciliation parenthetical described
  the pre-fix `free-abelian-group` attribution as current; reworded to historical
  now that R11 landed.
- **R86 — `comparison` `#D4`.** "nine systems where mismatches are compile errors"
  — the page's own matrix has **eleven**. Figure corrected.
- **R87 — `comparison` `#D5`.** Called Pint "the only shipped dB"; Unitful.jl also
  ships `dB`/`B` via `@logscale`/`@logunit`. Corrected.
- **R98 — `scala-squants` `#D1`.** The base-quantity count read **seven**; squants
  mixes `BaseDimension` into **eight** quantities — the seven SI base plus
  `Information` (symbol `"B"`, `information/Information.scala:74,86`). Corrected to
  eight in both spots.
- **R104 — `swift-units` `#D7`.** The illustrative `20 °C + 68 °F` result was given
  as `≈ 548.5 K ≈ 275.4 °C`; both operands are 293.15 K and Foundation sums them via
  base kelvin, so the (deliberately meaningless) result is `≈ 586.3 K ≈ 313.2 °C`.
  Figure corrected; the point (summing absolute temperatures is nonsense) stands.

## Adversarial verification pass

After the per-page ledgers, an independent adversarial pass re-checked the
highest-risk rows **directly against the primary artifacts** (not the ledgers'
Evidence column): all OCR / re-typeset-excerpt / image-only / Wayback quotes,
every locally-reproduced compiler- and runtime-error transcript, the
vendor-doc-only claims on `wolfram-matlab.md`, and cross-page figure consistency
in `comparison.md`.

- Theory scope: **93 rows re-verified, 93 upheld, 0 drift missed.** Whitney's 21
  excerpt-quote fragments confirmed char-for-char (including the re-typeset's own
  quirks); the Drobot image-only scan was re-rendered and its two quoted phrases
  and axioms confirmed; the Buckingham/CLP/Bridgman OCR reconstructions verified
  against re-rendered pages.
- Systems + synthesis scope: **61 rows re-verified, 61 upheld, 0 corrections.**
  Every reproduced error transcript, the mp-units in-source line numbers at the
  pin, the VIM "to some extent arbitrary" quote, and the `comparison.md` figures
  all held.

- Wave-2 systems scope: the six wave-2 ledgers were each authored by an independent
  verifier reading the pinned clone directly (not the page author) — the adversarial
  check and the ledger are one pass here. **296 rows checked, 21 material
  discrepancies found and applied** (2 substantive: R98, R104), the remaining rows
  upheld or noted as acceptable imprecision. Every corrected locator was re-confirmed
  against the clone before editing.

No new discrepancies survived the adversarial pass; no ledger `Fix` was wrong.

## Status

All 32 pages ledgered (14 wave-1 systems + 8 theory + 3 synthesis + 6 wave-2
systems, plus the umbrellas); **1984** claim rows checked; **118** material
discrepancies found and applied (12 substantive, 106 minor/cosmetic), with **9**
further wave-2 ⚠ rows flagging condensed-but-faithful quotes or secondary
attributions that needed no page change; **78** rows are secondary- or
opinion-grounded with their fallback named. Independent adversarial verification
upheld every high-risk row re-checked (154 in wave 1; the six wave-2 ledgers are
themselves the independent pass). No open discrepancies.

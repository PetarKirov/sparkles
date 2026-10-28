# sparkles:font-oracle

Test-only: `sparkles:font` checked against HarfBuzz over the bundled fonts
(`$SPARKLES_FONTS_PATH`; tests skip without it). Oracles and known divergences:
[`parsing.md` § 7](../../docs/specs/font/parsing.md#_7-oracles),
[`variation-metrics.md` § 9](../../docs/specs/font/variation-metrics.md#_9-oracles).

HarfBuzz is declared by ImportC (`src/sparkles/font_oracle/harfbuzz_c.c`), set
up as the [ImportC guideline](../../docs/guidelines/importc-c-libraries.md)
describes.

The correction registry
([`testing.md` § Compatibility quirks](../../docs/specs/font/testing.md#compatibility-quirks-ftd8-ftd12))
is checked on fixtures rebuilt from the registry's own lists, which
`test/sparkles/font/oracle_registry.d` forwards out of their `package` module,
by `sparkles:font`'s fixture builder (`libs/font/test/sparkles/font/fixtures.d`,
compiled in alone): Cambria Math's minimum heights against
`hb_ot_math_get_constant`, on HarfBuzz's `MathTestFontPretendToBeCambria.ttf`
(a pinned corpus face, so its absence fails) and on near misses; every `GDEF`
blocklist triple and three near misses each against
`hb_ot_layout_get_glyph_class` and `hb_ot_layout_get_ligature_carets`; the
legacy Arabic pages against `hb_font_get_nominal_glyph`; and the tricky faces,
by name and by `cvt `/`fpgm`/`prep`, against FreeType 2.14.3's `FT_IS_TRICKY`.

Other inputs, all exported by the dev shell:

- `$SPARKLES_FONT_TEST_CORPUS`: faces tested against but not shipped
  (`nix/packages/font-test-corpus.nix`), for what the bundle lacks: variable
  `CFF2` faces; varied vertical metrics, from Adobe Blank VF and Source Han
  Sans VF (a collection, of which the first face is read); and `JSTF` faces,
  SIL's Scheherazade New and Lateef, whose `JSTF` records
  `oracle.jstf.agreesWithFontTools` compares with fontTools' reading in
  `test/goldens/jstf.txt`. Three directories hold M2's corpus gates: `base/`,
  real `BASE` tables (Adobe's CJK template, Noto Serif JP VF's variable
  `BASE`, M+, IPAex, Simon Cozens's baseline test); `math/`, `MATH` faces
  with math kerns (STIX Two Math, KpMath, Garamond-Math, Asana Math) and
  Latin Modern Math; and `harfbuzz/`, HarfBuzz's own API test fonts, whose
  `COLR` version 0, `sbix` and `CBDT` faces are the colour oracles' corpus
  beside the bundled emoji font.
  `test/goldens/manifest.txt` pins every face by SHA-256, with its licence,
  source and table inventory, and `oracle.corpus.manifest` checks it.
- `$SPARKLES_FLAKE_INPUT_HARFBUZZ_SRC`: the pinned HarfBuzz source, whose
  generated tables the `FTS8` manifest check reads.
- `$SPARKLES_HARFBUZZ_USE_UCD`: the older UCD release HarfBuzz's USE table was
  generated from, whose default ignorables that check compares with base's.

One input is opt-in: `$SPARKLES_FONT_UNFREE_CORPUS`, Microsoft's core Arial
and Times New Roman, which hold `JSTF` tables too. Their licence forbids
redistributing them, so neither the dev shell nor CI's cache builds them
(`nix/packages/font-unfree-corpus.nix`), and
`oracle.jstf.unfreeAgreesWithFontTools` and
`oracle.corrections.gdefBlocklistUnfree` (their glyph classes against
HarfBuzz's) skip without them:

```bash
SPARKLES_FONT_UNFREE_CORPUS=$(nix build --no-link --print-out-paths \
  .#sparkles-font-unfree-corpus) dub test :font-oracle
```

`test/goldens/shaping.txt` records `hb-shape` output for the shaping wrapper
check, with the engine version and each face's fingerprint: a SHA-256 of
every table but `name`, which the Maple Mono build writes in an order that
varies between builds. Regenerate it inside the dev shell with
`dub run --single libs/font-oracle/tools/gen_shaping_goldens.d` whenever the
pin or a face changes (the check names which).

Two more goldens come from readers written apart from this library, on
developer machines only:

- `test/goldens/base.txt`: fontTools' reading of every `BASE` table, from
  `tools/gen_base_goldens.d` (run under
  `nix shell --inputs-from . nixpkgs#python3Packages.fonttools`).
- `test/goldens/fontations.txt`: fontations' variation deltas, `BASE`
  coordinates and `MATH` glyph values, which `read-fonts` computes in integer
  fixed point as this library does, so they compare exactly. The Rust driver
  in `tools/fontations` prints them and `tools/gen_fontations_goldens.d`
  digests them (run under
  `nix shell --inputs-from . nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc`).

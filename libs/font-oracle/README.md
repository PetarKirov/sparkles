# sparkles:font-oracle

Test-only: `sparkles:font` checked against HarfBuzz over the bundled fonts
(`$SPARKLES_FONTS_PATH`; tests skip without it). Oracles and known divergences:
[`parsing.md` § 7](../../docs/specs/font/parsing.md#_7-oracles),
[`variation-metrics.md` § 9](../../docs/specs/font/variation-metrics.md#_9-oracles).

HarfBuzz is declared by ImportC (`src/sparkles/font_oracle/harfbuzz_c.c`), set
up as the [ImportC guideline](../../docs/guidelines/importc-c-libraries.md)
describes.

Other inputs, all exported by the dev shell:

- `$SPARKLES_FONT_TEST_CORPUS`: faces tested against but not shipped
  (`nix/packages/font-test-corpus.nix`), for what the bundle lacks: variable
  `CFF2` faces; varied vertical metrics, from Adobe Blank VF and Source Han
  Sans VF (a collection, of which the first face is read); and `JSTF` faces,
  SIL's Scheherazade New and Lateef, whose `JSTF` records
  `oracle.jstf.agreesWithFontTools` compares with fontTools' reading in
  `test/goldens/jstf.txt`.
- `$SPARKLES_FLAKE_INPUT_HARFBUZZ_SRC`: the pinned HarfBuzz source, whose
  generated tables the `FTS8` manifest check reads.
- `$SPARKLES_HARFBUZZ_USE_UCD`: the older UCD release HarfBuzz's USE table was
  generated from, whose default ignorables that check compares with base's.

One input is opt-in: `$SPARKLES_FONT_UNFREE_CORPUS`, Microsoft's core Arial
and Times New Roman, which hold `JSTF` tables too. Their licence forbids
redistributing them, so neither the dev shell nor CI's cache builds them
(`nix/packages/font-unfree-corpus.nix`), and
`oracle.jstf.unfreeAgreesWithFontTools` skips without them:

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

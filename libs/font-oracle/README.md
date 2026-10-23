# sparkles:font-oracle

Test-only: `sparkles:font` checked against HarfBuzz over the bundled fonts
(`$SPARKLES_FONTS_PATH`; tests skip without it). Oracles and known divergences:
[`parsing.md` § 7](../../docs/specs/font/parsing.md#_7-oracles),
[`variation-metrics.md` § 9](../../docs/specs/font/variation-metrics.md#_9-oracles).

HarfBuzz is declared by ImportC (`src/sparkles/font_oracle/harfbuzz_c.c`), set
up as the [ImportC guideline](../../docs/guidelines/importc-c-libraries.md)
describes.

Other inputs, all exported by the dev shell:

- `$SPARKLES_FONT_TEST_CORPUS`: faces tested against but not shipped, the
  variable `CFF2` faces the bundle lacks (`nix/packages/font-test-corpus.nix`).
- `$SPARKLES_FLAKE_INPUT_HARFBUZZ_SRC`: the pinned HarfBuzz source, whose
  generated tables the `FTS8` manifest check reads.
- `$SPARKLES_HARFBUZZ_USE_UCD`: the older UCD release HarfBuzz's USE table was
  generated from, whose default ignorables that check compares with base's.

`test/goldens/shaping.txt` records `hb-shape` output for the shaping wrapper
check, with the engine version and each face's SHA-256; regenerate it inside
the dev shell with `dub run --single libs/font-oracle/tools/gen_shaping_goldens.d`
whenever the pin or a face changes (the check names which).

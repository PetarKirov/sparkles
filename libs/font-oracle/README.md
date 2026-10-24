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

One input is opt-in: `$SPARKLES_FONT_UNFREE_CORPUS`, Microsoft's core Arial
and Times New Roman, the only faces found with a `JSTF` table. Their licence
forbids redistributing them, so neither the dev shell nor CI's cache builds
them (`nix/packages/font-unfree-corpus.nix`), and `oracle.jstf.agreesWithFontTools`
skips without them:

```bash
SPARKLES_FONT_UNFREE_CORPUS=$(nix build --no-link --print-out-paths \
  .#sparkles-font-unfree-corpus) dub test :font-oracle
```

`test/goldens/shaping.txt` records `hb-shape` output for the shaping wrapper
check, with the engine version and each face's SHA-256; regenerate it inside
the dev shell with `dub run --single libs/font-oracle/tools/gen_shaping_goldens.d`
whenever the pin or a face changes (the check names which).

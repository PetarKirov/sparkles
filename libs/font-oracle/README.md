# sparkles:font-oracle

Test-only: `sparkles:font` checked against HarfBuzz over the bundled fonts
(`$SPARKLES_FONTS_PATH`; tests skip without it). Oracles and known divergences:
[`parsing.md` § 7](../../docs/specs/font/parsing.md#_7-oracles),
[`variation-metrics.md` § 9](../../docs/specs/font/variation-metrics.md#_9-oracles).

HarfBuzz is declared by ImportC (`src/sparkles/font_oracle/harfbuzz_c.c`), set
up as the [ImportC guideline](../../docs/guidelines/importc-c-libraries.md)
describes.

/// Test-only: `sparkles:font` checked against HarfBuzz (docs/specs/font/parsing.md § 7).
module sparkles.font_oracle;

public import sparkles.font_oracle.harfbuzz_c;

/// `HB_SET_VALUE_INVALID`: a cast macro in `hb-set.h`, which ImportC does not import.
enum HB_SET_VALUE_INVALID = cast(hb_codepoint_t) -1;

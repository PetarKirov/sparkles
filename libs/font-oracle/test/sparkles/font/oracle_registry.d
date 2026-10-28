/**
The correction registry's signature data, handed read-only to the oracles in
`sparkles.font_oracle.corrections`. `sparkles.font.correction_data` is
`package` to `sparkles.font`, so this test-only module sits in that package
to forward it; the oracles build their fixtures from the very lists the
library recognizes, and compare the result with HarfBuzz and FreeType.
*/
module sparkles.font.oracle_registry;

import sparkles.font.correction_data : arabicPuaSimplified, arabicPuaTraditional, gdefBlocklist,
    trickyNames, trickyTables;

@safe pure nothrow @nogc:

/// FTD10: the `GDEF`, `GSUB` and `GPOS` lengths HarfBuzz ignores `GDEF` for (`gdef`, `gsub`, `gpos`).
auto registryGdefBlocklist() => gdefBlocklist;

/// FTD11: a legacy Arabic page's (`unicode`, `pua`) pairs; `traditional` picks `0xB3` over `0xB2`.
auto registryArabicPage(bool traditional) => traditional ? arabicPuaTraditional : arabicPuaSimplified;

/// FTD12: FreeType's tricky family names, matched as substrings.
auto registryTrickyNames() => trickyNames;

/// FTD12: FreeType's tricky faces by `cvt `, `fpgm` and `prep` (`checksum`, `length`; length 0: absent).
auto registryTrickyTables() => trickyTables;

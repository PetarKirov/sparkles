/// ImportC bindings for ICU (icu4c) grapheme segmentation, scoped to the
/// text-conformance harness.
///
/// Exposes one stable wrapper, `sp_icu_grapheme_lengths`, from
/// `sparkles.icu.icu_c` (compiled from `icu_c.c`). The wrapper hides ICU's
/// version-suffixed C symbols and UTF-16 `UChar` types behind a plain
/// `int(const char*, int, int*, int)` signature.
module sparkles.icu;

// `icu_c.c` is compiled as a root source (cSourcePaths, so its wrapper body is
// emitted), making its module the bare stem `icu_c` — import it unqualified.
public import icu_c;

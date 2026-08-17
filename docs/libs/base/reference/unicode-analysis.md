# Unicode analysis reference

`sparkles.base.text.analysis` provides a fixed-workspace pipeline for Unicode
17 NFC/NFKC normalization, canonical combining-class ordering, simple/full
case folding, mark removal, word-boundary flags, stopword removal, and
strict-plus-opaque UTF-8 decoding. The runtime analyzer does not consult the
compiler's potentially different `std.uni` property version.

The generated tables come from these Unicode Character Database inputs:
`UnicodeData.txt`, `CaseFolding.txt`, `DerivedNormalizationProps.txt`, and
`auxiliary/WordBreakProperty.txt`. Regenerate them together with the existing
width/emoji tables using:

```sh
dub run --single libs/base/tools/gen_unicode_tables.d
```

The generator pins Unicode 17.0.0 and accepts `--ucd-dir` for a local mirror.
`TextUnit.value` is a scalar or `opaqueByteBase + byte`; `sourceStart` and
`sourceEnd` are half-open byte offsets. Expansions share their source interval,
and compositions use the union of contributing intervals.

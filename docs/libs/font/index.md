# `sparkles:font`

`sparkles:font` reads OpenType and TrueType font files in D. It opens a face
or a collection over bytes the caller owns, finds its tables, reads the
fixed-layout tables as plain structs, maps characters to glyphs, decodes
`name` records and names glyphs. It builds instances of variable faces with
one normalized coordinate vector, measures advances and line, cell, vertical,
baseline and math metrics, decodes glyph outlines (`glyf` composites and
`gvar`, `CFF` charstrings), rasterizes glyphs to grayscale coverage, and —
in the separate `engine` configuration — shapes text with HarfBuzz. Every
read stays inside the caller's buffer, malformed data comes back as a
`FontError` rather than an assertion, and the library configuration
allocates nothing and links no C library.

These are milestones M1–M5 of the [font specification](../../specs/font/SPEC.md);
discovery and colour glyphs are the later milestones of the
[delivery plan](../../specs/font/PLAN.md).
Unicode semantics come from [`sparkles:base`](../base/index.md).

## Documentation

- [Tutorial: open a face and map text](./tutorial/getting-started.md)
- [How-to: inspect a damaged font](./how-to/inspect-a-font.md)
- [Reference: modules, operations and errors](./reference/api.md)
- [Explanation: borrowing, checking once, and leniency](./explanation/design.md)

The operation-level contracts are in
[`parsing.md`](../../specs/font/parsing.md), and the
[testing page](../../specs/font/testing.md) describes the oracles that check
them, including the HarfBuzz differential suite in `sparkles:font-oracle`.

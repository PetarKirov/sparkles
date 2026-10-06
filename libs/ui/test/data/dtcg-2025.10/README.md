# DTCG 2025.10 specification examples

Every `json` example of the
[Design Tokens Format Module 2025.10](https://www.designtokens.org/tr/2025.10/format/),
extracted verbatim from the sources of
[design-tokens/community-group at the commit that published it](https://github.com/design-tokens/community-group/tree/f0f32a7dce0b51b36488be9cbbf7cad2763c6f29/technical-reports/format):
`<source file>-<nn>.tokens` (the edition's recommended extension) is the `nn`-th `json` block of that Markdown file.

`sparkles.ui.dtcg`'s test `dtcg.specExamples.2025_10` loads each one: it must
parse, collect its tokens, and resolve every value, except the examples the
test lists as illustrations, which must be rejected. This is the independent
half of the design system's theme-file oracle (`O4`).

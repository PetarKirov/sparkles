# Grounding ledger — `lezer-highlight.md`

`$REPOS/js/lezer-highlight` `8b4907f` (2026-04-15; `package.json` 1.2.3, MIT; sole dep `@lezer/common ^1.3.0`).
The whole package is `src/highlight.ts` (~748 lines).

Status key: ✓ / ≈ / ⚠ / ◯ / 🌐. Load-bearing quotes (rows 2, 5, 9) re-grep-verified directly;
remaining locators from the exploration pass at the same pin.

| #   | Claim                                                                                                                                                                                                              | Type       | Source (local + locator)                                               | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- | ---------------------------------------------------------------------- | ------ |
| 1   | README: Lezer "is an incremental parser system intended for use in an editor or similar system" / "@lezer/highlight provides a syntax highlighting framework for Lezer parse trees."                               | QUOTE      | `README.md:7-11`                                                       | ✓      |
| 2   | Closed-vocabulary thesis: "CodeMirror uses a mostly _closed_ vocabulary of syntax tags (as opposed to traditional open string-based systems, which make it hard for highlighting themes to cover all the tokens…)" | QUOTE      | `src/highlight.ts:10-15` (verified)                                    | ✓      |
| 3   | Local tags "will not be picked up by regular highlighters (though you can derive them from standard tags…)"                                                                                                        | QUOTE      | `src/highlight.ts:17-21`                                               | ✓      |
| 4   | `Tag.set` = "The set of this tag and all its parent tags… sorted in order of decreasing specificity"; `Tag.define` pushes self + parent set                                                                        | QUOTE-code | `src/highlight.ts:30-32,46-61`                                         | ✓      |
| 5   | `defineModifier` algebra: same-modifier idempotence + order-independence (`m1(m2(t1)) == m2(m1(t1))`) + power-set parents                                                                                          | QUOTE      | `src/highlight.ts:63-79` (verified :63-66)                             | ✓      |
| 6   | Standard vocabulary: 78 tags + 6 modifiers (`definition, constant, function, standard, local, special`); family counts per exploration                                                                             | figure     | `src/highlight.ts:455-663,638-662`                                     | ✓      |
| 7   | "A full ontology of syntactic constructs would fill a stack of books… So try to make do with this set." + it's-okay-to-generalize guidance                                                                         | QUOTE      | `src/highlight.ts:437-451`                                             | ✓      |
| 8   | `styleTags` selector language: slash paths, `*` wildcard, `/...` inherit, `!` opaque; `Mode.{Opaque, Inherit, Normal}`; depth precedence                                                                           | QUOTE≈     | `src/highlight.ts:124-192,210,221-232`                                 | ✓      |
| 9   | `highlightTree(tree, highlighter, putStyle, from = 0, to = tree.length)` with the putStyle doc and range docs — the viewport clip                                                                                  | QUOTE-code | `src/highlight.ts:300-315` (verified)                                  | ✓      |
| 10  | Range-clipped recursion + mounted-overlay (mixed language) handling; `Highlighter { style(tags), scope?(node) }`; `tagHighlighter` specificity ("Classes associated with more specific tags will take precedence") | QUOTE≈     | `src/highlight.ts:240-285,354-418`                                     | ✓      |
| 11  | `classHighlighter` "stable, predictable classes… for styling with external CSS"; `tok-*` mappings incl. modifier compounds                                                                                         | QUOTE≈     | `src/highlight.ts:670-747`                                             | ✓      |
| 12  | `HighlightStyle` lives in `@codemirror/language`, not here (scope note)                                                                                                                                            | fact       | absence in package + 🌐 CodeMirror docs                                | ≈/🌐   |
| 13  | First npm release 0.16.0, 2022-04-20; 1.0.0 2022-06-06                                                                                                                                                             | fact       | 🌐 npm registry (see [synthesis ledger](./syntax-highlighting.md) D17) | 🌐     |
| 14  | Strengths / Weaknesses / trade-offs; "vocabulary design to study" framing                                                                                                                                          | synthesis  | derived                                                                | ◯      |

## Discrepancies

None found.

**Net:** 0 discrepancies.

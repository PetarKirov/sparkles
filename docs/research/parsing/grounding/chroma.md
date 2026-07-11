# Grounding ledger — `chroma.md`

`$REPOS/go/chroma` `01c740b` (2026-07-08; `git describe` = `v3.0.0-alpha.5`; stable line v2.27.0 = 🌐).

Status key: ✓ / ≈ / ⚠ / ◯ / 🌐. Load-bearing quotes (rows 1, 6) re-grep-verified directly
at the pin; remaining locators from the exploration pass against the same pin.

| #   | Claim                                                                                                                                                                                  | Type       | Source (local + locator)                                             | Status     |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------- | ---------- | --- |
| 1   | "Chroma is based heavily on Pygments, and includes translators for Pygments lexers and styles." + "converts it into syntax highlighted HTML, ANSI-coloured text, etc."                 | QUOTE      | `README.md:11-15`                                                    | ✓          |
| 2   | MIT © 2017 Alec Thomas; ~13.2 kLOC Go; v3 = `iter.Seq[Token]` + module path bump (README v3 note)                                                                                      | fact       | `COPYING:1`; `README.md:4`; `wc` at pin                              | ✓          |
| 3   | 282 XML lexers (`lexers/embedded/*.xml`) + 19 hand-written Go lexers + 74 styles                                                                                                       | figure     | `ls                                                                  | wc` at pin | ✓   |
| 4   | XML format = 1:1 serialization of Pygments `tokens` dicts (`<config>` + `<rules>/<state>/<rule pattern>`)                                                                              | fact       | `lexers/embedded/diff.xml:1-27` (exemplar)                           | ≈          |
| 5   | Converter imports the actual Pygments lexer class, renders via pystache: "In many cases lexers can be automatically converted directly from Pygments…"                                 | QUOTE≈     | `_tools/pygments2chroma_xml.py:1-40`; `README.md:229-237,250-252`    | ✓          |
| 6   | `regexp2` (backtracking, .NET-compatible) not stdlib RE2; `\G`-anchored patterns; `MatchTimeout = time.Millisecond * 250`                                                              | QUOTE-code | `go.mod:8`; `regexp.go:17,352-373` (timeout at :370, verified)       | ✓          |
| 7   | Whole-text stateful scan (`for l.Pos < end && len(l.Stack) > 0`); zero-width guard "A zero-width match that did not change state will never advance."                                  | QUOTE≈     | `regexp.go:202-259,272`                                              | ✓          |
| 8   | Fidelity caveats: "Pygments lexers for complex languages often include custom code…", "I mostly only converted languages I had heard of…", detection "very few languages support them" | QUOTE      | `README.md:322-331`                                                  | ✓          |
| 9   | Recovery copied from Pygments with attribution comment ("// From Pygments :\\ …")                                                                                                      | QUOTE-code | `regexp.go:238-255`                                                  | ✓          |
| 10  | Integer range-encoded token types (`Keyword = 1000`, `NameBuiltin = 2100`); `Parent()` arithmetic                                                                                      | QUOTE-code | `types.go:52-341`                                                    | ✓          |
| 11  | Formatters: HTML (classes/inline, `WriteCSS`, `.chroma.dark` mode classes), tty 8/16/256/truecolor, SVG, JSON                                                                          | fact       | `formatters/`; `README.md:200-246`                                   | ≈          |
| 12  | Redmean weighted-Euclidean color distance; doc comments overclaim "Lab colour space" (**doc-vs-code discrepancy, flagged in page**)                                                    | fact/⚠-src | `colour.go:62-69` vs `tty_indexed.go:267,272`                        | ✓          |
| 13  | Style inheritance: "when `CommentSpecial` is not defined, Chroma uses the token style from `Comment`."                                                                                 | QUOTE      | `README.md:267`                                                      | ✓          |
| 14  | Detection: `Match(filename)` "iterates over all file patterns in all lexers, so is not fast"; `Analyse` largely unimplemented                                                          | QUOTE      | `registry.go:118-182`; `README.md:330`                               | ✓          |
| 15  | `Coalesce` merges same-type runs (8192-char cap); `mutatorLimit = 10000`                                                                                                               | fact       | `coalesce.go:6-31`; `regexp.go:375`                                  | ≈          |
| 16  | Adoption: Hugo ("a static site generator that uses Chroma…"), moor, `less` LESSOPEN integration                                                                                        | QUOTE≈     | `README.md:271-301`                                                  | ✓          |
| 17  | Created Jun 2017, first tag Sep 2017; stable v2.27.0                                                                                                                                   | fact       | 🌐 GitHub API (see [synthesis ledger](./syntax-highlighting.md) D13) | 🌐         |
| 18  | Strengths / Weaknesses / trade-offs; "porting playbook" framing                                                                                                                        | synthesis  | derived                                                              | ◯          |

## Discrepancies

None in the page. The Lab-vs-redmean doc/code drift (row 12) is an **upstream**
discrepancy the page reports as a finding, mirroring the ledger discipline for
in-tree source disagreements (cf. rapidjson D-R1).

**Net:** 0 page discrepancies; 1 upstream doc-vs-code drift reported as content.

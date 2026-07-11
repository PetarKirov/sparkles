# Grounding ledger — `linguist.md`

`$REPOS/ruby/linguist` `e9fe3c9f` (2026-06-18; `v9.6.0-5-ge9fe3c9f`; MIT).

Status key: ✓ / ≈ / ⚠ / ◯ / 🌐. Load-bearing quotes (rows 1, 3) re-grep-verified directly;
remaining locators from the exploration pass at the same pin.

| #   | Claim                                                                                                                                                                                                                        | Type       | Source (local + locator)                                                          | Status |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | --------------------------------------------------------------------------------- | ------ |
| 1   | "This library is used on GitHub.com to detect blob languages, ignore binary or vendored files, suppress generated files in diffs, and generate language breakdown graphs."                                                   | QUOTE      | `README.md:7` (verified)                                                          | ✓      |
| 2   | MIT; v9.6.0; ~3.9 kLOC Ruby + flex C tokenizer                                                                                                                                                                               | fact       | `LICENSE:1`; `lib/linguist/VERSION`; `ext/linguist/`                              | ✓      |
| 3   | The `STRATEGIES` array (Modeline, Filename, Shebang, Extension, XML, Manpage, Heuristics, Classifier), verbatim                                                                                                              | QUOTE-code | `lib/linguist.rb:63-72` (verified)                                                | ✓      |
| 4   | Driver: 1 candidate → done; >1 → narrow (set **intersection** `candidates & languages`); 0 → keep previous                                                                                                                   | fact       | `lib/linguist.rb:20-52`; `strategy/extension.rb:23` etc.                          | ✓      |
| 5   | Docs mirror: "…each step either identifying the precise language or reducing the number of likely languages passed down…"                                                                                                    | QUOTE      | `docs/how-linguist-works.md:8`                                                    | ✓      |
| 6   | Strategy details: modeline first+last 5 lines; shebang env/version handling (`python2.6`→`python2`); XML only if no candidates                                                                                               | fact       | `strategy/modeline.rb`; `shebang.rb:21-55`; `strategy/xml.rb`                     | ≈      |
| 7   | `languages.yml`: 815 languages; field docs incl. `tm_scope` ("The TextMate scope… Use 'none' if there is no TextMate grammar…")                                                                                              | QUOTE≈     | `lib/linguist/languages.yml:1-36` (+ count at pin)                                | ✓      |
| 8   | `heuristics.yml`: 130 blocks + 21 named patterns; `.h` rule (Obj-C → C++ → pattern-less C fallthrough); `.m` block; timeout → `[]`                                                                                           | fact       | `lib/linguist/heuristics.yml:384-390,502-519,1077-1114`; `heuristics.rb:33,69-83` | ✓      |
| 9   | Classifier is **TF-ICF nearest-centroid cosine**, not naive Bayes (docs/tokenizer still say "bayes") — **upstream doc-vs-code drift, reported in the page**                                                                  | fact       | `classifier.rb:123-150,75-89,394-410` vs `tokenizer.rb:6-9`                       | ✓      |
| 10  | Classifier runs last over candidates; `CLASSIFIER_CONSIDER_BYTES = 50 * 1024`; samples = 3,310 files / 747 dirs; flex C tokenizer                                                                                            | figure     | `classifier.rb:10,23-28`; `samples/` count; `ext/linguist/tokenizer.l`            | ✓      |
| 11  | Exclusions: `vendor.yml` (168), `documentation.yml` (18), `generated.rb` (~40 detectors; "Generated source code is suppressed in diffs…")                                                                                    | QUOTE≈     | `lib/linguist/{vendor,documentation}.yml`; `generated.rb:44-46,134-541`           | ✓      |
| 12  | Overrides: `linguist-{language,vendored,generated,documentation,detectable}`; "`.gitattributes` will be used to determine language statistics and will be used to syntax highlight files"; default = programming/markup only | QUOTE      | `docs/overrides.md:7-8,32-43`                                                     | ✓      |
| 13  | Highlighting seam: 537 grammar submodules under `vendor/grammars/`; `grammars.yml` = 1,475 scopes; tree-sitter essentially absent                                                                                            | figure     | `.gitmodules` count; `grammars.yml`; grep at pin                                  | ✓      |
| 14  | Open-sourced May 2011                                                                                                                                                                                                        | fact       | 🌐 GitHub API (see [synthesis ledger](./syntax-highlighting.md) D14)              | 🌐     |
| 15  | Strengths / Weaknesses / trade-offs; "the cascade + registry + overrides triple" framing                                                                                                                                     | synthesis  | derived                                                                           | ◯      |

## Discrepancies

None in the page. Row 9's "Bayesian" doc-vs-code drift is upstream and is _reported_ by
the page as a finding (with the design lesson that the last-stage classifier is
replaceable).

**Net:** 0 page discrepancies; 1 upstream doc-vs-code drift reported as content.

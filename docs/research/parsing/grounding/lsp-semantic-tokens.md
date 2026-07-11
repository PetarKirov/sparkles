# Grounding ledger — `lsp-semantic-tokens.md`

`$REPOS/typescript/language-server-protocol` `25005c8` (2026-07-09). **Default branch is
`gh-pages`** — GitHub blob URLs use `/blob/gh-pages/` (a `/blob/main/` URL 404s; caught by the
local lychee pass and fixed before commit). Spec file: `_specifications/lsp/3.17/language/semanticTokens.md`
(535 lines); 3.16 text inlined in `_specifications/specification-3-16.md`; 3.18 draft alongside.

Status key: ✓ / ≈ / ⚠ / ◯ / 🌐. Load-bearing quotes (rows 1, 5, 6) re-grep-verified directly;
remaining locators from the exploration pass at the same pin.

| #   | Claim                                                                                                                                                                                               | Type        | Source (local + locator)                                                            | Status |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------- | ------ |
| 1   | Motivation: "Semantic tokens are used to add additional color information… A semantic token request usually produces a large result. The protocol therefore supports encoding tokens with numbers…" | QUOTE       | `3.17/language/semanticTokens.md:5` (verified)                                      | ✓      |
| 2   | "one token type combined with n token modifiers… clients are allowed to extend these and announce the values they support…"                                                                         | QUOTE       | `semanticTokens.md:9`                                                               | ✓      |
| 3   | 23 `SemanticTokenTypes` in 3.17 (22 in 3.16; `decorator` @since 3.17; 3.18 adds `label` → 24); list as quoted; `type` = fallback doc                                                                | fact/QUOTE≈ | `semanticTokens.md:14-45`; 3.18 file `:44-48`                                       | ✓      |
| 4   | 10 `SemanticTokenModifiers` (list as quoted)                                                                                                                                                        | fact        | `semanticTokens.md:51-62`                                                           | ✓      |
| 5   | Relative-encoding rationale + the five fields (deltaLine/deltaStart/length/tokenType `< 65536`/tokenModifiers bitset) verbatim                                                                      | QUOTE       | `semanticTokens.md:100-106` (verified); bitset example `:97-98`                     | ✓      |
| 6   | `augmentsSyntaxTokens` capability verbatim ("…both used for colorization… only uses the returned semantic tokens…"), @since 3.17                                                                    | QUOTE       | `semanticTokens.md:261-273` (verified)                                              | ✓      |
| 7   | Request family: full (`resultId` doc), full/delta (`previousResultId`, array-level `SemanticTokensEdit`, unsorted-apply caveat), range (two use-cases quoted), refresh (config-change rationale)    | QUOTE≈      | `semanticTokens.md:172-174,325-534`                                                 | ✓      |
| 8   | `multilineTokenSupport` / `overlappingTokenSupport` capabilities + truncate-at-EOL fallback behavior                                                                                                | QUOTE≈      | `semanticTokens.md:109-111,242-249`                                                 | ✓      |
| 9   | Introduced LSP 3.16 (2020-12-14): "Add semantic token support" changelog; 3.17 additions (cancelable, augmentation)                                                                                 | QUOTE≈      | `specification-3-16.md:19` + 3.18 spec changelog `:776`; 3.17 spec `:733-735`       | ✓      |
| 10  | VS Code default-on for TS/JS in v1.43 (Feb 2020), walked back to theme-opt-in in 1.43.1                                                                                                             | fact        | 🌐 VS Code release notes (see [synthesis ledger](./syntax-highlighting.md) D15-D16) | 🌐     |
| 11  | Server/client adoption (rust-analyzer, clangd, tsserver, gopls; Neovim/Helix clients)                                                                                                               | fact        | 🌐 ecosystem context                                                                | 🌐     |
| 12  | UTF-16 positions (LSP default encoding)                                                                                                                                                             | fact        | LSP base-protocol text (same repo)                                                  | ≈      |
| 13  | Strengths / Weaknesses / trade-offs; "overlay composition law" framing                                                                                                                              | synthesis   | derived                                                                             | ◯      |

## Discrepancies

None in the page. One authoring-time catch recorded: the initial reference URL used
`/blob/main/` — dead on this repo (`gh-pages` default) — caught by lychee before commit
and noted in `_sources.md` as a repo-specific trap.

**Net:** 0 discrepancies.

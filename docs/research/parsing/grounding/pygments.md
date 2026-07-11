# Grounding ledger — `pygments.md`

`$REPOS/python/pygments` `f1a91515` (2026-07-09; `__version__ = '2.20.0'`).

Status key: ✓ verified verbatim/exact · ≈ accurate paraphrase · ⚠ discrepancy ·
◯ opinion · 🌐 web/secondary. Load-bearing quotes (rows 1, 8, 13, 15) re-grep-verified
directly at the pin; remaining locators from the exploration pass against the same pin.

| #   | Claim                                                                                                                                            | Type       | Source (local + locator)                                                      | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- | ----------------------------------------------------------------------------- | ------ |
| 1   | "It is a generic syntax highlighter for general use in all kinds of software such as forum systems, wikis or other applications…"                | QUOTE      | `pygments/__init__.py:7-9`                                                    | ✓      |
| 2   | BSD-2-Clause; Georg Brandl; status "6 - Mature"; version 2.20.0                                                                                  | fact       | `pyproject.toml:9-26`; `pygments/__init__.py:31`                              | ✓      |
| 3   | 601 `LEXERS` entries / 263 lexer modules / 47 styles / 14 formatter modules; ~128 kLOC                                                           | figure     | `pygments/lexers/_mapping.py` (generated header :1-2); `ls`/`wc` at pin       | ✓      |
| 4   | "most languages use a simple regex-based lexing mechanism"                                                                                       | QUOTE      | `doc/index.rst:9-10`                                                          | ≈      |
| 5   | RegexLexer docstring: state stack starts `['root']`; `tokens` dict of `(regex, tokentype, new_state)`; `'#pop'`/`'#push'` semantics              | QUOTE      | `pygments/lexer.py:678-700`                                                   | ✓      |
| 6   | Transition mechanics: tuple pushes, `'#pop:2'`, int multi-pop; helpers `bygroups`/`using`/`this`/`default`/`include`/`inherit`/`words`           | fact       | `pygments/lexer.py:722-745,328-500`; `doc/docs/lexerdevelopment.rst:118-119`  | ≈      |
| 7   | `ExtendedRegexLexer` + `LexerContext` (mutable pos/stack); `DelegatingLexer` ("First everything is scanned using the language lexer…")           | QUOTE≈     | `pygments/lexer.py:764-790,289-320`; `lexerdevelopment.rst:578-582`           | ✓      |
| 8   | Whole-text scan: `pos = 0; while 1: … m = rexmatch(text, pos) … pos = m.end()`; `flags = re.MULTILINE` (anchors only, no line split)             | QUOTE-code | `pygments/lexer.py:708-721,676`                                               | ✓      |
| 9   | Token singletons; subsumption via `__contains__` prefix test; `split()`; aliases                                                                 | QUOTE-code | `pygments/token.py:12-83` (`__contains__` :28-32)                             | ✓      |
| 10  | `STANDARD_TYPES` short names (`Keyword: 'k'`, `Keyword.Reserved: 'kr'`, `String.Double: 's2'`, `Comment.Preproc: 'cp'`, `Generic.Deleted: 'gd'`) | fact       | `pygments/token.py:123-214`                                                   | ✓      |
| 11  | HTML formatter walks parents to a `STANDARD_TYPES` class; `get_style_defs`; `StyleMeta` fills undefined types `''` → parent inheritance          | fact       | `pygments/formatters/html.py:45-54,463-509`; `pygments/style.py:58-64`        | ≈      |
| 12  | Terminal256 nearest color by squared-Euclidean RGB (`_closest_color`)                                                                            | fact       | `pygments/formatters/terminal256.py:155-203`                                  | ✓      |
| 13  | Error fallback: unmatched newline → `statestack = ['root']`; else one-char `Token.Error` advance                                                 | QUOTE-code | `pygments/lexer.py:747-761`                                                   | ✓      |
| 14  | Detection: `guess_lexer` modeline first, then every lexer's `analyse_text`, short-circuit at 1.0; filename glob rating (+0.5 explicit)           | fact       | `pygments/lexers/__init__.py:169-209,304-340`                                 | ≈      |
| 15  | `make_analysator` clamps to [0,1] and swallows exceptions → 0.0                                                                                  | fact       | `pygments/util.py:123-137`                                                    | ✓      |
| 16  | Python's `analyse_text`: shebang or `'import '` in first 1000 chars                                                                              | fact       | `pygments/lexers/python.py:417-419`                                           | ≈      |
| 17  | **No pathology guards** — no regex timeout, line cap, or backtracking bound anywhere in the engine                                               | behavior   | absence over `pygments/lexer.py` + `regex` usage (CPython `re` direct)        | ✓      |
| 18  | "parsing and formatting is fast" (no benchmarks)                                                                                                 | QUOTE      | `doc/faq.rst:25`                                                              | ≈      |
| 19  | Plugin entry points (`pygments.lexers` etc. via `importlib.metadata`)                                                                            | fact       | `pygments/plugin.py:8-47`                                                     | ≈      |
| 20  | First release v0.5 "PyKleur", 30 Oct 2006; adoption (Sphinx, pre-2014 GitHub, minted)                                                            | fact       | `CHANGES` (in-tree changelog) + 🌐 (pygments.org changelog; adoption context) | 🌐/≈   |
| 21  | Strengths / Weaknesses / trade-offs; "the taxonomy that became a standard" framing                                                               | synthesis  | derived                                                                       | ◯      |

## Discrepancies

None found. The whole-text (not per-line) model — the page's load-bearing contrast —
was explicitly confirmed in the loop code (row 8) rather than inferred.

## Web-fallback / not-locally-groundable

Release date (in-tree `CHANGES` gives "Oct 30, 2006"; treated ✓-adjacent) and adoption
history (Sphinx/GitHub/minted) — see the [synthesis ledger](./syntax-highlighting.md) D11.

**Net:** 0 discrepancies.

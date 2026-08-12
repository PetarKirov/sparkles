# Grounding ledger — Quick reference table

> Not published. Do not link to it from the guide.

One row per “Feature / Since” in `index.md` § Quick reference. Pin:
`dlang.org` `351dd6d91bfed604b473c4dedd4b5fdf262c3629` (see `_sources.md`).

| #   | Section   | Claim (short)                                    | Type | Version(s) claimed | Source (changelog locator)                                                                                                                                | Status |
| --- | --------- | ------------------------------------------------ | ---- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1   | Quick ref | User-defined attributes                          | fact | [2.061]            | `2.061.dd` COMMENT `BUGZILLA 9222` “Add User Defined Attributes” (sparse WHATSNEW era)                                                                    | ≈      |
| 2   | Quick ref | `alias Name = Type;`                             | fact | [2.061]            | Intro not a TOC bullet in `2.061.dd`; `2.062.dd:48` “newly introduced `alias foo = int`”                                                                  | ≈      |
| 3   | Quick ref | `alias` covers function types                    | fact | [2.087]            | Cross-checked in declarations section ledger                                                                                                              | →      |
| 4   | Quick ref | `alias` covers `__traits` results                | fact | [2.084]            | Cross-checked in declarations section ledger                                                                                                              | →      |
| 5   | Quick ref | `package.d` package modules (DIP37)              | fact | [2.064]            | `2.064.dd` § `import-package` / `import_package` (DIP37 bugfixes also cite package.d)                                                                     | ✓      |
| 6   | Quick ref | Eponymous template shorthand                     | fact | [2.064]            | `2.064.dd` § `eponymous-template` / `eponymous_template`                                                                                                  | ✓      |
| 7   | Quick ref | `@nogc`                                          | fact | [2.066]            | `2.066.0.dd` § `nogc-attribute` / `nogc_attribute`                                                                                                        | ✓      |
| 8   | Quick ref | Multi-dimensional `opIndex`/`opSlice`/`opDollar` | fact | [2.066]            | `2.066.0.dd` § `opover-multidim-slicing`                                                                                                                  | ✓      |
| 9   | Quick ref | `return ref` parameters (DIP25)                  | fact | [2.067]            | `2.067.0.dd` § `sealed-references` (DIP25)                                                                                                                | ✓      |
| 10  | Quick ref | Attribute inference span                         | fact | [2.063]–[2.068]    | `2.063.dd` § `attribinference`; `2.065.0.dd` § `attribinference2`; `2.068.0.dd` § `attribinference3`                                                      | ✓      |
| 11  | Quick ref | `static foreach` (DIP1010)                       | fact | [2.076]            | `2.076.0.dd` (static foreach / DIP1010)                                                                                                                   | ✓      |
| 12  | Quick ref | Expression-based contracts (DIP1009)             | fact | [2.081]            | `2.081.0.dd` § `expression-based_contract_syntax` “Implement DIP 1009”                                                                                    | ✓      |
| 13  | Quick ref | `aa.require` / `aa.update`                       | fact | [2.082]            | `2.082.0.dd` § `require_update` “Additional functions for associative arrays”                                                                             | ✓      |
| 14  | Quick ref | Copy constructors (DIP1018)                      | fact | [2.086]            | `2.086.0.dd` (copy constructor / DIP1018)                                                                                                                 | ✓      |
| 15  | Quick ref | `in` parameters (`-preview=in`)                  | fact | [2.092]→[2.094]    | `2.092.0.dd` § `preview-in`; rework `2.094.0.dd` § `preview-in`                                                                                           | ✓      |
| 16  | Quick ref | `pragma(printf)` / `pragma(scanf)`               | fact | [2.092]            | `2.092.0.dd` (printf/scanf pragma)                                                                                                                        | ✓      |
| 17  | Quick ref | Shortened function bodies (DIP1043)              | fact | [2.096]→[2.101]    | Preview `2.096.0.dd` § `shortfunctions`; default `2.101.0.dd` § `dmd.shortenedMethodsEnabled`                                                             | ✓      |
| 18  | Quick ref | `while (auto x = …)`                             | fact | [2.097]            | `2.097.0.dd` § `while-condition-assignment`                                                                                                               | ✓      |
| 19  | Quick ref | ImportC                                          | fact | [2.098]            | `2.098.0.dd` § `ImportC`                                                                                                                                  | ✓      |
| 20  | Quick ref | Alias assignment                                 | fact | [2.098]            | `2.098.0.dd` (alias assignment sample / body)                                                                                                             | ✓      |
| 21  | Quick ref | `throw` expressions + `noreturn` (DIP1034)       | fact | [2.099]            | `2.099.0.dd` § `throw_expression`, § `main_return_type` (noreturn)                                                                                        | ✓      |
| 22  | Quick ref | `__traits(parameters)`                           | fact | [2.099]            | `2.099.0.dd` § `TraitsParameters`                                                                                                                         | ✓      |
| 23  | Quick ref | `@mustuse` (DIP1038)                             | fact | [2.100]            | `2.100.0.dd` (@mustuse / DIP1038)                                                                                                                         | ✓      |
| 24  | Quick ref | Static array `.tupleof`                          | fact | [2.100]            | `2.100.0.dd` § `static_array_tupleof`                                                                                                                     | ✓      |
| 25  | Quick ref | Bitfields                                        | fact | [2.101]→[2.112]    | Preview `2.101.0.dd` § `dmd.bitfields`; default `2.112.0.dd` § `dmd.bitfields`                                                                            | ✓      |
| 26  | Quick ref | `scope` array literals                           | fact | [2.102]            | `2.102.0.dd` § `dmd.scope-array-on-stack`                                                                                                                 | ✓      |
| 27  | Quick ref | `@system` variables (DIP1035) _(preview)_        | fact | [2.102]            | `2.102.0.dd` § `dmd.system-variables` (`-preview=systemVariables`)                                                                                        | ✓      |
| 28  | Quick ref | Multi-argument `static assert`                   | fact | [2.102]            | `2.102.0.dd` § `dmd.static-assert`                                                                                                                        | ✓      |
| 29  | Quick ref | Named arguments (DIP1030)                        | fact | [2.103]→[2.108]    | **Implemented** in dmd for `v2.103.0` (git: named-arg-resolve in tag); **documented** `2.108.0.dd` § `dmd.named-arguments`. No 2.103 changelog TOC entry. | ≈      |
| 30  | Quick ref | Static AA initialization                         | fact | [2.106]            | `2.106.0.dd` § `dmd.static-assoc-array`                                                                                                                   | ✓      |
| 31  | Quick ref | Interpolated Expression Sequences                | fact | [2.108]            | `2.108.0.dd` § `dmd.ies`                                                                                                                                  | ✓      |
| 32  | Quick ref | Hex strings & `import()` as binary data          | fact | [2.108]→[2.110]    | Hex→int arrays `2.108.0.dd` § `dmd.hexstring-cast`; import() `2.110.0.dd` § `dmd.import-exp-hexstring`                                                    | ✓      |
| 33  | Quick ref | `__ctfeWrite`                                    | fact | [2.109]            | `2.109.0.dd` § `dmd.ctfeWrite`                                                                                                                            | ✓      |
| 34  | Quick ref | `ref`/`auto ref` variables                       | fact | [2.111]            | `2.111.0.dd` § `dmd.auto-ref-local`                                                                                                                       | ✓      |
| 35  | Quick ref | `__rvalue`, move constructors, placement `new`   | fact | [2.111]            | `2.111.0.dd` § `dmd.rvalue`, § `dmd.placementNew`                                                                                                         | ✓      |
| 36  | Quick ref | `-preview=safer`                                 | fact | [2.111]            | `2.111.0.dd` § `dmd.safer`                                                                                                                                | ✓      |
| 37  | Quick ref | ImportC `#pragma attribute(push, nogc, nothrow)` | fact | [2.111]            | `2.111.0.dd` (ImportC `#pragma attribute(push, …)`)                                                                                                       | ✓      |

### Notes

- **Row 29 (named arguments):** Guide wording “implemented [2.103], completed &
  documented [2.108]” matches git + 2.108 release note. Changelog-only readers
  would only see 2.108; secondary is `$REPOS/dlang/dmd` tags containing the
  named-arg-resolve merge. Status `≈` not `⚠` — attribution is fair.
- Rows marked `→` are expanded in the themed section ledger with full locators;
  the quick-ref “Since” column only cites the primary intro version for that row’s
  main feature.
- Policy note in the guide’s IMPORTANT baseline box (`-preview=in` +
  `dip1000`) is `◯` — see `compiler-switches.md` / repo AGENTS.

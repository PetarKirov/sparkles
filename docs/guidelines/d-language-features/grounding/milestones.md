# Grounding ledger — Milestones table

> Not published. Do not link to it from the guide.

Date = guide’s month/year column vs `$(VERSION …)` in the release `.dd`.
Landmark = major TOC / body bullets (abridged match → `≈`).

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

| #   | Section    | Claim (short)                                                                         | Type | Version(s) | Source                                                                                                                      | Status |
| --- | ---------- | ------------------------------------------------------------------------------------- | ---- | ---------- | --------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1   | Milestones | [2.061] Jan 2013 — UDAs; `alias Name = Type`                                          | fact | [2.061]    | `2.061.dd` `$(VERSION Jan 1, 2013`; landmarks sparse (COMMENT / next-release wording) → see quick-ref                       | ≈      |
| 2   | Milestones | [2.064] Nov 2013 — `package.d`; eponymous; `getUnitTests`                             | fact | [2.064]    | `2.064.dd` `$(VERSION November 5, 2013`; § `import-package`, `eponymous-template`                                           | ✓      |
| 3   | Milestones | [2.066] Aug 2014 — `@nogc`; multi-dim slicing; uniform construction                   | fact | [2.066]    | `2.066.0.dd` `$(VERSION August 18, 2014`; § `nogc-attribute`, `opover-multidim-slicing`                                     | ✓      |
| 4   | Milestones | [2.067] Mar 2015 — DIP25; GC runs struct destructors                                  | fact | [2.067]    | `2.067.0.dd` `$(VERSION Mar 24, 2015`; § `sealed-references`                                                                | ✓      |
| 5   | Milestones | [2.071] Apr 2016 — DIP22 import/visibility                                            | fact | [2.071]    | `2.071.0.dd` `$(VERSION Apr 5, 2016`; import/DIP22 sections                                                                 | ✓      |
| 6   | Milestones | [2.076] Sep 2017 — `static foreach`; `-betterC` revival                               | fact | [2.076]    | `2.076.0.dd` `$(VERSION Sep 1, 2017`                                                                                        | ✓      |
| 7   | Milestones | [2.081] Jul 2018 — DIP1009 expression contracts                                       | fact | [2.081]    | `2.081.0.dd` `$(VERSION Jul 01, 2018`; § `expression-based_contract_syntax`                                                 | ✓      |
| 8   | Milestones | [2.086] May 2019 — Copy constructors DIP1018                                          | fact | [2.086]    | `2.086.0.dd` `$(VERSION May 04, 2019`                                                                                       | ✓      |
| 9   | Milestones | [2.092] May 2020 — `-preview=in`; `@live`; `pragma(printf)`                           | fact | [2.092]    | `2.092.0.dd` `$(VERSION May 10, 2020`; § `preview-in`                                                                       | ✓      |
| 10  | Milestones | [2.098] Oct 2021 — ImportC; alias assignment                                          | fact | [2.098]    | `2.098.0.dd` `$(VERSION Oct 10, 2021`; § `ImportC`                                                                          | ✓      |
| 11  | Milestones | [2.099] Mar 2022 — throw expr; noreturn; `__traits(parameters)`                       | fact | [2.099]    | `2.099.0.dd` `$(VERSION Mar 06, 2022`                                                                                       | ✓      |
| 12  | Milestones | [2.100] May 2022 — `@mustuse`; `delete` and D1 operators removed                      | fact | [2.100]    | `2.100.0.dd` `$(VERSION May 10, 2022`                                                                                       | ✓      |
| 13  | Milestones | [2.101] Nov 2022 — DIP1000 deprecations; bitfields preview; shortened methods default | fact | [2.101]    | `2.101.0.dd` `$(VERSION Nov 14, 2022`; § `dmd.dip1000_deprecation_warnings`, `dmd.bitfields`, `dmd.shortenedMethodsEnabled` | ✓      |
| 14  | Milestones | [2.106] Dec 2023 — Static AA; templatized runtime hooks begin                         | fact | [2.106]    | `2.106.0.dd` `$(VERSION Dec 01, 2023`; § `dmd.static-assoc-array`                                                           | ✓      |
| 15  | Milestones | [2.108] Apr 2024 — IES; named arguments                                               | fact | [2.108]    | `2.108.0.dd` `$(VERSION Apr 01, 2024`; § `dmd.ies`, `dmd.named-arguments`                                                   | ✓      |
| 16  | Milestones | [2.111] Apr 2025 — `__rvalue`/move/placement; ref locals; `-preview=safer`            | fact | [2.111]    | `2.111.0.dd` `$(VERSION Apr 01, 2025`                                                                                       | ✓      |
| 17  | Milestones | [2.112] Jan 2026 — Bitfields default; ImportC `__module`; AA/array hooks              | fact | [2.112]    | `2.112.0.dd` `$(VERSION Jan 07, 2026`; § `dmd.bitfields`                                                                    | ✓      |

All milestone months match `$(VERSION …)` at month granularity. No date discrepancies.

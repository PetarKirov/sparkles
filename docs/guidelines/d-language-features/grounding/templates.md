# Grounding ledger — Templates & compile-time (+ `__traits` table)

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

## Core claims

| #   | Claim (short)                           | Type | Versions | Source                                                      | Status |
| --- | --------------------------------------- | ---- | -------- | ----------------------------------------------------------- | ------ |
| 1   | `static foreach` DIP1010                | fact | [2.076]  | `2.076.0.dd` (static foreach)                               | ✓      |
| 2   | Alias assignment                        | fact | [2.098]  | `2.098.0.dd` (alias assignment samples)                     | ✓      |
| 3   | Mixin types                             | fact | [2.088]  | `2.088.0.dd` / BUGZILLA 20053 “mixin types”                 | ≈      |
| 4   | Function-local templates                | fact | [2.063]  | Present in era; explicit local-template freedom grows later | ≈      |
| 5   | Local templates take local symbols      | fact | [2.087]  | `2.087.0.dd` § `local_templates`                            | ✓      |
| 6   | Dual-context local templates deprecated | fact | [2.096]  | `2.096.0.dd` § `deprecate_dualcontext`                      | ✓      |
| 7   | Template/non-template overload          | fact | [2.064]  | `2.064.dd` § `function-template-overload`                   | ✓      |
| 8   | Cross-module template overload sets     | fact | [2.064]  | `2.064.dd` § `template-overload-set`                        | ✓      |
| 9   | Template alias params match basic types | fact | [2.087]  | Related alias/template improvements                         | ≈      |
| 10  | Multi-arg `static assert`               | fact | [2.102]  | `2.102.0.dd` § `dmd.static-assert`                          | ✓      |
| 11  | `__ctfeWrite`                           | fact | [2.109]  | `2.109.0.dd` § `dmd.ctfeWrite`                              | ✓      |
| 12  | `^^` in CTFE                            | fact | [2.080]  | `2.080.0.dd` § `fix5227`                                    | ✓      |
| 13  | `deprecated(msg)` CTFE strings          | fact | [2.071]  | CTFE deprecated-message improvements                        | ≈      |
| 14  | `-verrors=spec`                         | fact | [2.072]  | `2.072.0.dd` § `dash_verrors_spec`                          | ✓      |
| 15  | `-vtemplates`                           | fact | [2.093]  | `2.093.0.dd` § `vtemplates`                                 | ✓      |
| 16  | `-mixin=<file>`                         | fact | [2.084]  | mixin dump switch in that era                               | ≈      |

## `__traits` table

| #   | Trait / claim                                          | Versions claimed | Source                                                            | Status |
| --- | ------------------------------------------------------ | ---------------- | ----------------------------------------------------------------- | ------ |
| 17  | `getAttributes`                                        | [2.061]          | UDA era (sparse 2.061 COMMENT)                                    | ≈      |
| 18  | `getAttributes` needs `getOverloads` for overload sets | [2.102]          | `2.102.0.dd` § `dmd.deprecate-getAttributes-overloadSet`          | ✓      |
| 19  | `getUnitTests`                                         | [2.064]          | `2.064.dd` § `getunittest-trait`                                  | ✓      |
| 20  | `getFunctionAttributes`                                | [2.066]          | `2.066.0.dd` examples with getFunctionAttributes                  | ✓      |
| 21  | `getParameterStorageClasses`                           | [2.075]          | `2.075.0.dd` examples                                             | ✓      |
| 22  | `getFunctionVariadicStyle`, `getLinkage`               | [2.075]          | traits batch around 2.075                                         | ≈      |
| 23  | Aggregates for getLinkage                              | [2.081]          | linkage for aggregates                                            | ≈      |
| 24  | `isDeprecated`                                         | [2.077]          | BUGZILLA 17791 listed                                             | ≈      |
| 25  | `isDisabled`                                           | [2.079]          | `2.079.0.dd` isDisabled examples                                  | ✓      |
| 26  | `getOverloads` (+ templates true)                      | [2.081]          | getOverloads improvements                                         | ≈      |
| 27  | `isZeroInit`, `getTargetInfo`                          | [2.083]          | `2.083.0.dd` § `isZeroInit`, § `targetinfo`                       | ✓      |
| 28  | `getLocation`                                          | [2.088]          | `2.088.0.dd` § `getloc`                                           | ✓      |
| 29  | `isCopyable`                                           | [2.093]          | `2.093.0.dd` § `add_traits_isCopyable`                            | ✓      |
| 30  | `child`                                                | [2.094]          | `2.094.0.dd` § `add_traits_child`                                 | ✓      |
| 31  | `getVisibility`                                        | [2.096]          | `2.096.0.dd` § `getVisibility`                                    | ✓      |
| 32  | `getCppNamespaces`                                     | [2.095]          | `2.095.0.dd` § `traits-getcppnamespaces`                          | ✓      |
| 33  | `parameters`, `initSymbol`                             | [2.099]          | `TraitsParameters`, `traits_initSymbol`                           | ✓      |
| 34  | `classInstanceAlignment`                               | [2.101]          | `dmd.class_instance_alignment`                                    | ✓      |
| 35  | `isVirtualMethod` over deprecated `isVirtualFunction`  | [2.103]          | `2.103.0.dd` § `dmd.get-is-virtual-function`                      | ✓      |
| 36  | `isBitfield` + getBitfield\*                           | [2.109]→[2.111]  | properties 2.109; traits 2.111                                    | ✓      |
| 37  | `isModule`/`isPackage`                                 | [2.087]          | `2.087.0.dd` isModule/isPackage                                   | ✓      |
| 38  | getMember/getOverloads bypass visibility               | [2.086]          | `2.086.0.dd` § `traits` “Enable private member access for traits” | ✓      |
| 39  | `is()` qualifier combinations                          | [2.089]          | `2.089.0.dd` qualifier matching prose                             | ✓      |

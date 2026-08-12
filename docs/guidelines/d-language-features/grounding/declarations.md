# Grounding ledger — Declarations & modules

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

| #   | Claim (short)                                      | Type    | Versions | Source                                                       | Status |
| --- | -------------------------------------------------- | ------- | -------- | ------------------------------------------------------------ | ------ |
| 1   | `alias Name = Type;` form                          | fact    | [2.061]  | Sparse; “newly introduced” in `2.062.dd:48`                  | ≈      |
| 2   | Function-type alias syntax                         | fact    | [2.087]  | `2.087.0.dd` § `aliasdecly_func`                             | ✓      |
| 3   | Aliasing `__traits` / traits in type position      | fact    | [2.084]  | `2.084.0.dd` (BUGZILLA 7804 / traits alias examples)         | ≈      |
| 4   | Eponymous template shorthand                       | fact    | [2.064]  | `2.064.dd` § `eponymous-template`                            | ✓      |
| 5   | `package.d` DIP37                                  | fact    | [2.064]  | `2.064.dd` § `import-package`                                | ✓      |
| 6   | Unittests in package.d don't run under test-runner | opinion | —        | Sparkles AGENTS                                              | ◯      |
| 7   | DIP22 two-pass lookup / import visibility          | fact    | [2.071]  | `2.071.0.dd` import/DIP22 sections                           | ✓      |
| 8   | FQN cannot bypass private import (error)           | fact    | [2.084]  | `2.084.0.dd` § `fqn_imports_bypass_private_imports_error`    | ✓      |
| 9   | `ref`/`auto ref` variables                         | fact    | [2.111]  | `2.111.0.dd` § `dmd.auto-ref-local`                          | ✓      |
| 10  | Bitfields preview                                  | fact    | [2.101]  | `2.101.0.dd` § `dmd.bitfields`                               | ✓      |
| 11  | Bitfields default                                  | fact    | [2.112]  | `2.112.0.dd` § `dmd.bitfields`                               | ✓      |
| 12  | `.bitoffsetof` / `.bitwidth`                       | fact    | [2.109]  | `2.109.0.dd` bitfield properties                             | ✓      |
| 13  | `__traits(getBitfieldOffset/Width)`                | fact    | [2.111]  | `2.111.0.dd` § `dmd.getBitfieldInfo`                         | ✓      |
| 14  | `noreturn` (DIP1034)                               | fact    | [2.099]  | `2.099.0.dd` § `main_return_type` / throw_expression DIP1034 | ✓      |
| 15  | Static AA initialization                           | fact    | [2.106]  | `2.106.0.dd` § `dmd.static-assoc-array`                      | ✓      |
| 16  | `new int[string]` empty AA                         | fact    | [2.101]  | `2.101.0.dd` § `dmd.new-aa`                                  | ✓      |
| 17  | Mixin template assignment syntax                   | fact    | [2.111]  | `2.111.0.dd` (`mixin name = …`)                              | ✓      |
| 18  | `align` accepts CTFE expressions                   | fact    | [2.072]  | `2.072.0.dd` § `align_by_ctfe`                               | ✓      |
| 19  | `align(default)`                                   | fact    | [2.111]  | `2.111.0.dd` § `dmd.default-align`                           | ✓      |

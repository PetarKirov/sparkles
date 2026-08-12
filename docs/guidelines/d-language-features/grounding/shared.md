# Grounding ledger — `shared` & atomics

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

| #   | Claim (short)                                               | Type | Versions claimed | Source                                                                   | Status |
| --- | ----------------------------------------------------------- | ---- | ---------------- | ------------------------------------------------------------------------ | ------ |
| 1   | shared RMW (`x++`, `x +=`) error                            | fact | [2.080]          | `2.080.0.dd` § `rwm-shared-error`                                        | ✓      |
| 2   | shared RMW deprecation earlier                              | fact | [2.066]          | `2.066.0.dd` atomicOp recommendation / deprecation path                  | ≈      |
| 3   | `atomicFetchAdd` / `atomicFetchSub`                         | fact | [2.089]          | `2.089.0.dd` § `atomic_fetch_add`                                        | ✓      |
| 4   | `atomicExchange`                                            | fact | [2.088]          | `2.088.0.dd` § `atomic_exchange`                                         | ✓      |
| 5   | `cas` overloads                                             | fact | [2.088]          | `2.088.0.dd` § `atomic_cas`                                              | ✓      |
| 6   | shared opOpAssign/opUnary enables `x++` syntax              | fact | [2.088]          | `2.088.0.dd` shared opUnary/opOpAssign prose                             | ✓      |
| 7   | `-preview=nosharedaccess` (DIP1024)                         | fact | [2.093]          | `2.093.0.dd` nosharedaccess                                              | ✓      |
| 8   | `atomicLoad` preserves `shared` on indirections             | fact | [2.077]          | `2.077.0.dd` § `atomicLoad-return-types`                                 | ✓      |
| 9   | Invalid `MemoryOrder` rejected at compile time              | fact | [2.107]          | `2.107.0.dd` § `druntime.coreatomic`                                     | ✓      |
| 10  | `immutable` implicitly shared; init from shared static this | fact | [2.098]→[2.106]  | `2.098.0.dd` / `2.106.0.dd` shared static ctor + const/immutable globals | ≈      |

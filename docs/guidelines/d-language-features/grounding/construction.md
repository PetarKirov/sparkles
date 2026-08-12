# Grounding ledger — Construction, copy, move, destruction

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

| #   | Claim (short)                                  | Type | Versions claimed | Source                                                 | Status |
| --- | ---------------------------------------------- | ---- | ---------------- | ------------------------------------------------------ | ------ |
| 1   | Cross-link move guide                          | expo | —                | navigation                                             | ◯      |
| 2   | Qualified constructors                         | fact | [2.063]          | `2.063.dd` § `ctorqualifier`                           | ✓      |
| 3   | Unique expr → immutable                        | fact | [2.063]          | `2.063.dd` § `uniqueinference`                         | ✓      |
| 4   | Copy constructors DIP1018                      | fact | [2.086]          | `2.086.0.dd` (copy constructor / DIP1018)              | ✓      |
| 5   | User copy ctor + generated postblit deprecated | fact | [2.096]          | `2.096.0.dd` § `copy-constructor-priority`             | ✓      |
| 6   | `__rvalue` + move constructors                 | fact | [2.111]          | `2.111.0.dd` § `dmd.rvalue`                            | ✓      |
| 7   | Placement `new`                                | fact | [2.111]          | `2.111.0.dd` § `dmd.placementNew`                      | ✓      |
| 8   | `-preview=dtorfields`                          | fact | [2.083]          | `2.083.0.dd` transition=dtorfields; preview list 2.085 | ≈      |
| 9   | dtorfields default                             | fact | [2.098]          | `2.098.0.dd` § `dtorfileds`                            | ✓      |
| 10  | Attribute mismatch ctor/field dtor error       | fact | [2.111]          | `2.111.0.dd` § `dmd.deprecation-dtor-fields`           | ✓      |
| 11  | `delete` deprecated                            | fact | [2.079]          | `2.079.0.dd` § `deprecate_delete`                      | ✓      |
| 12  | `delete` removed (error)                       | fact | [2.100]          | `2.100.0.dd` § `deprecation_delete`                    | ✓      |
| 13  | `delete` ordinary identifier again             | fact | [2.111]          | `2.111.0.dd` § `dmd.delete-keyword`                    | ✓      |
| 14  | Class allocators/deallocators deprecated       | fact | [2.080]          | `2.080.0.dd` § `deprecate_class_allocators`            | ✓      |
| 15  | Class allocators removed                       | fact | [2.098]          | `2.098.0.dd` § `remove_alloc`                          | ✓      |
| 16  | GC runs heap-struct destructors                | fact | [2.067]          | `2.067.0.dd` § `heap-struct-destructors`               | ✓      |
| 17  | `GC.inFinalizer`                               | fact | [2.090]          | `2.090.0.dd` § `gc_in_finalizer`                       | ✓      |
| 18  | Unrestricted unions                            | fact | [2.072]          | `2.072.0.dd` § `unrestricted_unions`                   | ✓      |
| 19  | Only first union member default initializer    | fact | [2.098]          | `2.098.0.dd` § `union_initialization`                  | ✓      |
| 20  | Initialize other union members via named args  | fact | [2.108]          | `2.108.0.dd` named arguments / struct-union literals   | ≈      |

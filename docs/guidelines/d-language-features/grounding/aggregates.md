# Grounding ledger — Aggregates, operators & built-in collections

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

| #   | Claim (short)                                          | Type | Versions claimed | Source                                                | Status |
| --- | ------------------------------------------------------ | ---- | ---------------- | ----------------------------------------------------- | ------ |
| 1   | D2 opUnary/opBinary/…; D1 ops removed                  | fact | [2.100]          | `2.100.0.dd` § `d1_style_operators`                   | ✓      |
| 2   | Multi-dim opIndex/opSlice/opDollar                     | fact | [2.066]          | `2.066.0.dd` § `opover-multidim-slicing`              | ✓      |
| 3   | Struct equality structural                             | fact | [2.063]          | `2.063.dd` § `structuralcompare`                      | ✓      |
| 4   | Struct opEquals beats alias this member                | fact | [2.086]          | `2.086.0.dd` § `alias_this_opEquals`                  | ✓      |
| 5   | `-preview=fieldwise`                                   | fact | [2.085]          | `2.085.0.dd` fieldwise preview                        | ✓      |
| 6   | `opApply` delegates should be `scope`                  | fact | [2.072]          | `2.072.0.dd` § `iteration_closure`                    | ✓      |
| 7   | Constant non-zero `opApply` return deprecated          | fact | [2.112]          | `2.112.0.dd` § `dmd.opApply.return`                   | ✓      |
| 8   | Partial assignment via `alias this` error              | fact | [2.100]          | `2.100.0.dd` § `alias_this_assignment`                | ✓      |
| 9   | Class `alias this` deprecated                          | fact | [2.103]          | `2.103.0.dd` § `dmd.deprecate-alias-this-for-classes` | ✓      |
| 10  | `alias this = member;` spelling                        | fact | [2.105]          | `2.105.0.dd` § `dmd.alias-this-syntax`                | ✓      |
| 11  | AA keys need opEquals + toHash (equality not ordering) | fact | [2.066]          | `2.066.0.dd` § `aa-key-requirement`                   | ✓      |
| 12  | `aa.require` / `aa.update`                             | fact | [2.082]          | `2.082.0.dd` § `require_update`                       | ✓      |
| 13  | `byKeyValue`                                           | fact | [2.067]          | `2.067.0.dd` § `aa-keyvalue`                          | ✓      |
| 14  | Static AA init                                         | fact | [2.106]          | `2.106.0.dd` § `dmd.static-assoc-array`               | ✓      |
| 15  | Static array `.tupleof`                                | fact | [2.100]          | `2.100.0.dd` § `static_array_tupleof`                 | ✓      |
| 16  | Known-length slices → static array params              | fact | [2.063]          | `2.063.dd` § `implicitarraycast`                      | ✓      |
| 17  | Enum members UDAs / deprecated / @disable              | fact | [2.082]          | `2.082.0.dd` § `enum_attributes`                      | ✓      |
| 18  | Comparing different enum types error                   | fact | [2.081]          | `2.081.0.dd` § `implicit_enum_comparison_error`       | ✓      |

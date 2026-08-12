# Grounding ledger — Interop: C, C++, Objective-C

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

| #   | Claim (short)                               | Type    | Versions claimed | Source                                   | Status |
| --- | ------------------------------------------- | ------- | ---------------- | ---------------------------------------- | ------ |
| 1   | ImportC `.c` as modules                     | fact    | [2.098]          | `2.098.0.dd` § `ImportC`                 | ✓      |
| 2   | C can `__import` D                          | fact    | [2.099]          | ImportC evolution in 2.099               | ≈      |
| 3   | ImportC `typeof`                            | fact    | [2.101]          | ImportC extensions                       | ≈      |
| 4   | ImportC `__check`                           | fact    | [2.103]          | `2.103.0.dd` § `dmd.check`               | ✓      |
| 5   | `#pragma attribute(push, nogc, nothrow)`    | fact    | [2.111]          | `2.111.0.dd` § `dmd.importc-pragma-stc`  | ✓      |
| 6   | `-i` auto-includes `.c`                     | fact    | [2.111]          | `2.111.0.dd` ImportC `-i` prose          | ✓      |
| 7   | `__module` disambiguates C files            | fact    | [2.112]          | `2.112.0.dd` `__module`                  | ✓      |
| 8   | House ImportC workflow guide                | opinion | —                | navigation                               | ◯      |
| 9   | `extern (C++)` namespaces                   | fact    | [2.066]          | `2.066.0.dd` § `extern-cpp-nspace`       | ✓      |
| 10  | String-form `extern (C++, "std", "chrono")` | fact    | [2.083]          | `2.083.0.dd` string namespaces           | ✓      |
| 11  | C++ operator mangling / mixed hierarchies   | fact    | [2.081]          | C++ interop improvements                 | ≈      |
| 12  | `pragma(mangle)` on aggregates              | fact    | [2.097]          | `2.097.0.dd` § `pragma-mangle-aggregate` | ✓      |
| 13  | Base `pragma(mangle)` form                  | fact    | [2.063]          | earlier mangle support                   | ≈      |
| 14  | `-extern-std=c++11` default                 | fact    | [2.095]          | `2.095.0.dd` § `extern-std-standard`     | ✓      |
| 15  | `@gnuAbiTag`                                | fact    | [2.092]          | `2.092.0.dd` gnuAbiTag                   | ✓      |
| 16  | `__c_wchar_t`                               | fact    | [2.084]          | `2.084.0.dd` § `wchar_t`                 | ✓      |
| 17  | `-HC` C++ headers from D                    | fact    | [2.091]          | `2.091.0.dd` `-HC`                       | ✓      |
| 18  | `pragma(printf)` / `pragma(scanf)`          | fact    | [2.092]          | `2.092.0.dd`                             | ✓      |
| 19  | `extern (C)` cannot overload (error)        | fact    | [2.105]          | `2.105.0.dd` § `dmd.extern-c-overload`   | ✓      |
| 20  | `extern (C)` overload deprecated earlier    | fact    | [2.095]          | deprecation phase before 2.105           | ≈      |
| 21  | `extern (C)` in template mixins mangle as C | fact    | [2.089]          | C linkage mixin mangling                 | ≈      |
| 22  | Objective-C `@selector`                     | fact    | [2.069]          | `2.069.0.dd` § `objective-c-support`     | ✓      |
| 23  | Objective-C full class support              | fact    | [2.085]          | `2.085.0.dd` Objective-C class entries   | ✓      |
| 24  | Objective-C protocols `@optional`           | fact    | [2.095]          | ObjC protocol support                    | ≈      |
| 25  | Auto-generated selectors                    | fact    | [2.111]          | ObjC selector auto-generation            | ≈      |

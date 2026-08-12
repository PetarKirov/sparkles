# Grounding ledger — `@nogc`, BetterC & GC-free error handling

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

| #   | Claim (short)                                | Type    | Versions claimed | Source                                                        | Status |
| --- | -------------------------------------------- | ------- | ---------------- | ------------------------------------------------------------- | ------ |
| 1   | `@nogc`                                      | fact    | [2.066]          | `2.066.0.dd` § `nogc-attribute`                               | ✓      |
| 2   | `-vgc` / `-profile=gc`                       | fact    | [2.066]→[2.068]  | `2.066.0.dd` § `vgc-switch`; `2.068.0.dd` § `profile-gc`      | ✓      |
| 3   | Repo `@nogc` toolkit                         | opinion | —                | AGENTS                                                        | ◯      |
| 4   | `@mustuse` DIP1038                           | fact    | [2.100]          | `2.100.0.dd` (@mustuse)                                       | ✓      |
| 5   | House path Expected + recycledErrorInstance  | opinion | —                | AGENTS / expected idioms                                      | ◯      |
| 6   | `-preview=dip1008` / `-dip1008`              | fact    | [2.079]          | `2.079.0.dd` § `dip1008`                                      | ✓      |
| 7   | `__traits(initSymbol)`                       | fact    | [2.099]          | `2.099.0.dd` § `traits_initSymbol`                            | ✓      |
| 8   | `__traits(isZeroInit)`                       | fact    | [2.083]          | `2.083.0.dd` § `isZeroInit`                                   | ✓      |
| 9   | `__traits(classInstanceAlignment)`           | fact    | [2.101]          | `2.101.0.dd` § `dmd.class_instance_alignment`                 | ✓      |
| 10  | `-betterC` revival/enhancements              | fact    | [2.076]          | `2.076.0.dd` § `betterc`                                      | ✓      |
| 11  | `version (D_BetterC)` / runtime gates        | fact    | [2.077]→[2.082]  | BetterC-related version identifiers across span (abridged)    | ≈      |
| 12  | BetterC RAII / scope(exit) etc.              | fact    | [2.078]          | BetterC arc entries (span in guide)                           | ≈      |
| 13  | `pragma(crt_constructor)` / `crt_destructor` | fact    | [2.078]          | BetterC-related pragma entries                                | ≈      |
| 14  | Templatized runtime hooks begin              | fact    | [2.106]          | `2.106.0.dd` § `dmd.template-_d_newarrayT`                    | ✓      |
| 15  | AA ops / array hooks templatized complete    | fact    | [2.112]          | `2.112.0.dd` § `dmd.aa-lowered-to-templates`, arraysetlengthT | ✓      |
| 16  | `@nogc` exception TraceInfo                  | fact    | [2.102]          | `2.102.0.dd` § `druntime.nogc-traceinfo`                      | ✓      |

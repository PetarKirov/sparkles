---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-19
---

# `sparkles:shaders` — Device modules

Which modules are shader code, and the rules a device compilation enforces on
them. The requirements are the accepted contract of 2026-10-16, unchanged by
this revision. This page is part of the [specification](./SPEC.md).

A module is shader code because its own declaration says so; the attribute is
dcompute's, and the rules a device compilation enforces are LDC's.

**SHM1: Module modes.** A module whose declaration carries
`@compute(CompileFor.deviceOnly)`, or `@compute` alone, **must** be compiled
only for the device. One carrying `@compute(CompileFor.hostAndDevice)`
**must** be compiled for both. A module without `@compute` is host code.

**SHM2: Device selection.** Device compilation **must** be selected by
compiling with a dcompute target (`-mdcompute-targets=…`), which predefines
the version identifier `LDC_DCompute`. The vocabulary **must** select its
device representation (`SHV2`) and its real attributes (`SHV8`) on that
identifier alone, never on a version of its own.

_Rationale:_ One switch cannot disagree with itself. A private version beside
the target flag was a second statement of the same fact, and the two could
be set inconsistently.

**SHM3: Device rules.** When a `@compute` module is compiled for the device,
the rules of LDC's device pass apply to it: no classes, interfaces, global
variables, associative arrays, array literals, string literals, `new`,
`delete`, concatenation, length assignment, run-time type information,
inline assembly, exceptions, string `switch`, function pointers, delegates,
`synchronized` or recursion, and calls only into other `@compute` modules or LDC's
intrinsics. The authority is LDC's
[`gen/semantic-dcompute.cpp`](https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/semantic-dcompute.cpp)
at the pinned compiler revision; this library adds none.

**SHM4: Host-only tests.** A `@compute` module **must not** contain unit
tests. Tests of its functions live in a module without `@compute`.

_Rationale:_ A test's name is a string literal, which `SHM3` forbids in
device code; the tests would break the device compilation they exist to
protect.

**SHM5: Lexical detection.** Whether a module is a device module **must** be
decidable from the attributes before its `module` keyword alone, without
semantic analysis. `@compute` is recognised under any qualified name whose
last component is `compute`. Its argument, if any, **must** be
`CompileFor.deviceOnly` or `CompileFor.hostAndDevice`, optionally qualified;
any other spelling (a cast, arithmetic on the enum) is unsupported, and the
classification of a module that uses one is unspecified. `hostAndDevice`
counts only inside `@compute`'s own parentheses, and comments, string
literals and other attributes are skipped. A UTF-8 byte-order mark before the
declaration is skipped. A file without a module declaration is host code.

_Rationale:_ The build step (`SHP3`) and editors must classify modules
before, and without, compiling them.

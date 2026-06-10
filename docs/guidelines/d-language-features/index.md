# Modern D Language Features (2.060–2.112)

What fourteen years of DMD changelogs — [2.060] (August 2012) through [2.112]
(January 2026) — mean for code written today. This guide lists every notable
language feature new Sparkles code should use and the release that introduced
it. Legacy constructs appear only where something _still legal_ has a strictly
better modern form — removed and deprecated features are policed by the
compiler and catalogued in the official [deprecated features table][deprecate].
It is a _language_ survey: Phobos changes are out of scope except where a
library symbol is the designated replacement for a language construct.

**Last reviewed:** June 10, 2026.

> [!NOTE]
> This guide gives the one-line rule and the version; the _how_ lives in the
> dedicated guides it links: [Code Style], [Functional & Declarative
> Programming][fdp], [Design by Introspection][dbi], [Interpolated Expression
> Sequences][ies-guide], [Move Semantics & `__rvalue`][move-guide],
> [Expected Error Handling][expected-idioms], and
> [Integrating C Libraries (ImportC)][importc-guide].

> [!IMPORTANT]
> **Baseline:** every sub-package compiles with `-preview=in` and
> `-preview=dip1000` ([AGENTS § Preview flags][agents-preview]), and unittest
> builds add `-checkaction=context -allinst`. Entries below marked _(preview)_
> need their named `-preview` switch; everything else is on by default in a
> 2.112-era frontend (the Nix devshell ships `ldc2` ≥ 2.111 and `dmd` 2.112).

---

## Quick reference: features to reach for

One row per adoptable feature, in the order it landed. The themed sections
below give the rule, the syntax, and the caveats.

| Feature                                          | Since               | What it gives you                                                                            |
| ------------------------------------------------ | ------------------- | -------------------------------------------------------------------------------------------- |
| User-defined attributes                          | [2.061]             | declarative annotations, read with `__traits(getAttributes)`                                 |
| `alias Name = Type;`                             | [2.061]             | the only alias form to use; covers function types ([2.087]) and `__traits` results ([2.084]) |
| `package.d` package modules (DIP37)              | [2.064]             | one-import library surface via `public import`                                               |
| Eponymous template shorthand                     | [2.064]             | `enum isFoo(T) = …;` one-line traits                                                         |
| `@nogc`                                          | [2.066]             | statically GC-allocation-free functions                                                      |
| Multi-dimensional `opIndex`/`opSlice`/`opDollar` | [2.066]             | `m[1 .. 3, 2, 0 .. $]` container APIs                                                        |
| `return ref` parameters (DIP25)                  | [2.067]             | refs that may escape only through the return value                                           |
| Attribute inference                              | [2.063]–[2.068]     | templates, instantiations, and `auto`-return functions infer `pure nothrow @safe @nogc`      |
| `static foreach` (DIP1010)                       | [2.076]             | compile-time iteration for code generation                                                   |
| Expression-based contracts (DIP1009)             | [2.081]             | `in (x > 0, "msg")` — and no `do`/`body` keyword before the body                             |
| `aa.require` / `aa.update`                       | [2.082]             | single-lookup AA insert-or-update                                                            |
| Copy constructors (DIP1018)                      | [2.086]             | `this(ref S)` — qualifier-aware copying that replaces the postblit                           |
| `in` parameters (`-preview=in`)                  | [2.092]/[2.094]     | rvalue-accepting `scope const` inputs, optimal passing (repo baseline)                       |
| `pragma(printf)` / `pragma(scanf)`               | [2.092]             | compiler-checked format strings on your own C-variadic functions                             |
| Shortened function bodies (DIP1043)              | [2.096]→[2.101]     | `int f() pure => expr;`                                                                      |
| `while (auto x = …)`                             | [2.097]             | condition-scoped declarations in loops                                                       |
| ImportC                                          | [2.098]             | compile C11 directly as D modules                                                            |
| Alias assignment                                 | [2.098]             | iterative (non-recursive) template metaprogramming                                           |
| `throw` expressions + `noreturn` (DIP1034)       | [2.099]             | throwing lambdas/ternaries; a real bottom type                                               |
| `__traits(parameters)`                           | [2.099]             | perfect forwarding without variadic wrappers                                                 |
| `@mustuse` (DIP1038)                             | [2.100]             | result types that cannot be silently discarded (`Expected`)                                  |
| Static array `.tupleof`                          | [2.100]             | element-wise unpacking and assignment                                                        |
| Bitfields                                        | [2.101]→[2.112]     | C-compatible packed integer fields                                                           |
| `scope` array literals                           | [2.102]             | stack-allocated slices in `@nogc` code (under `dip1000`)                                     |
| `@system` variables (DIP1035)                    | [2.102] _(preview)_ | data that `@safe` code may not touch                                                         |
| Multi-argument `static assert`                   | [2.102]             | `static assert(cond, "a = ", a)` diagnostics                                                 |
| Named arguments (DIP1030)                        | [2.103]→[2.108]     | reorderable, skippable, self-documenting call sites                                          |
| Static AA initialization                         | [2.106]             | module-scope `immutable` AA tables                                                           |
| Interpolated Expression Sequences                | [2.108]             | `i"sum: $(a + b)"` typed interpolation                                                       |
| Hex strings & `import()` as binary data          | [2.108]/[2.110]     | zero-cast embedding into integral arrays                                                     |
| `__ctfeWrite`                                    | [2.109]             | printf-debugging inside CTFE                                                                 |
| `ref`/`auto ref` variables                       | [2.111]             | named references at any scope                                                                |
| `__rvalue`, move constructors, placement `new`   | [2.111]             | explicit move semantics; in-place construction                                               |
| `-preview=safer`                                 | [2.111]             | `@safe` checks inside unattributed functions                                                 |
| ImportC `#pragma attribute(push, nogc, nothrow)` | [2.111]             | wholesale `@nogc nothrow` C bindings                                                         |

---

## Declarations & modules

- **`alias Name = Type;`** ([2.061]) — always use the `=` form; it extends to
  function types `alias Handler = int(string);` and member-qualified forms
  `alias Getter(T) = T() const;` ([2.087]), and to aliasing traits directly:
  `alias member = __traits(getMember, Foo, "a");` ([2.084], where `__traits`
  also became usable in type position).
- **Eponymous template shorthand** ([2.064]) —
  `enum isIntOrFloat(T) = is(T == int) || is(T == float);` instead of a full
  `template … { … }` body.
- **Package modules — `package.d`, DIP37** ([2.064]) — `docs/libs`-style
  re-export points: a `package.d` holding `public import`s lets users
  `import sparkles.core_cli;`. Keep it to re-exports only — unittests in
  `package.d` [don't run under silly][agents-silly].
- **Module encapsulation is real — DIP22 two-pass lookup** ([2.071]) —
  `private` symbols are invisible to other modules, imports no longer shadow
  locals, selective/renamed imports are private by default, and fully
  qualified names cannot bypass a private import (error since [2.084]).
  Consequence: re-export deliberately with `public import`; never rely on
  leaked transitive imports.
- **`ref`/`auto ref` variables** ([2.111]) — `ref int r = s.a;` declares a
  reference at local, static, and global scope; `auto ref x = expr;` infers
  ref-ness (test with `__traits(isRef, x)`).
- **Bitfields** (preview [2.101], default [2.112]) — C-compatible
  `struct B { int x : 3, y : 2; }`; introspect with `.bitoffsetof`/`.bitwidth`
  ([2.109]) and `__traits(getBitfieldOffset/getBitfieldWidth)` ([2.111]).
- **`noreturn`** ([2.099], DIP1034) — the bottom type for never-returning
  functions; `main` may return it.
- **Static initialization of associative arrays** ([2.106]) —
  `immutable string[string] table = ["key": "value"];` at module scope; key
  `toHash`/`opEquals` must be CTFE-callable. `new int[string]` ([2.101])
  creates a shareable empty AA instance.
- **Mixin template assignment syntax** ([2.111]) —
  `mixin name = MyMixinTemplate!Args;` as a clearer alternative to the
  trailing-name form.
- **`align` accepts CTFE expressions** ([2.072]) and **`align(default)`**
  ([2.111]) resets to natural alignment inside an `align(N)` scope.

---

## Functions, parameters & contracts

```d
int clamp(int v, int lo, int hi) @safe pure nothrow @nogc
in (lo <= hi, "inverted bounds")
out (r; r >= lo && r <= hi)
    => v < lo ? lo : v > hi ? hi : v;
```

- **Expression-based contracts — DIP1009** ([2.081]) — `in (expr, "msg")`,
  `out (r; expr)`, `invariant (expr);`; multiple `in`/`out` per function, and
  the body's `{` (or `=>`) follows the contracts **directly** — `do` (which
  replaced `body` per DIP1003 in [2.075]; `body` deprecated [2.097]) exists
  only to terminate legacy block contracts and should never appear in new code.
  House rule: [Code Style § Expression-based contracts][code-style-contracts].
- **Shortened function bodies — DIP1043** (preview [2.096], default [2.101]) —
  `int next() pure => counter + 1;`; allowed in constructors since [2.111].
- **Named arguments — DIP1030** (implemented [2.103], completed & documented
  [2.108]) — `createWindow(title: "Skynet", width: 1280)`; arguments may be
  reordered, parameters with defaults skipped, and union/struct literals can
  initialize a non-first member (`U(asInt: 0x3F800000)`). Named _template_
  arguments are **not** implemented. House rules:
  [Code Style § Named arguments][code-style-named] and the
  [forced named arguments idiom][forced-named].
- **`in` parameters — `-preview=in`** (introduced [2.092], reworked [2.094]) —
  `in` means `scope const`, accepts rvalues, and passes by reference whenever
  optimal — killing the `foo(T)`/`foo(ref T)` overload explosion. `in ref` is
  deprecated ([2.104]). Repo baseline; see the
  [dip1000/Phobos clash warning][agents-preview] before sprinkling `in` on
  parameters that flow into `std.regex` and friends.
- **Defaulted parameters after template variadics** ([2.078]/[2.079]) —
  `string log(T...)(T args, string file = __FILE__, int line = __LINE__)` is
  the canonical pattern; since [2.108] the `__FILE__`-family defaults evaluate
  at the _call site_ even nested inside larger default expressions.
- **`__traits(parameters)`** ([2.099]) — perfect forwarding without variadic
  wrappers: `return impl(__traits(parameters));`.
- **`throw` is an expression** ([2.099], DIP1034) — usable in lambdas and
  ternaries: `(string e) => throw new Exception(e)`.
- **Condition-scoped declarations in `while`** ([2.097]) —
  `while (auto line = nextLine()) { … }`, matching `if (auto x = …)`.
- **Function literals can return by `ref`** ([2.086]); **`alias` to a function
  literal** ([2.070]) — `alias less = (a, b) => a < b;` names a template lambda.
- **UDAs on parameters** ([2.082]) and **template-argument UDA forms**
  ([2.104]) — `@int void f();`, `@"name" unittest { }` — anything valid after
  `foo!` may follow `@`. UDA symbols stay camelCase
  ([Code Style][code-style]).
- **`with (expression)` keeps its temporary alive** ([2.067]) —
  `with (File("out.log", "w")) { … }` is valid RAII.

---

## Memory safety: the `@safe`/`scope` arc

The single most consequential thread of 2.067–2.111. New code should be
written to compile cleanly under the repo's `-preview=dip1000` baseline:

- **DIP25 — `return ref`** (introduced [2.067], deprecations by default
  [2.092], errors by default [2.103]) — a `ref` parameter (incl. `this`) that
  the function returns must be annotated `return`:
  `ref int identity(return ref int v) => v;`.
- **DIP1000 — `scope` pointers** (developed 2.073–2.077 behind `-dip1000`,
  Phobos compiled with it since [2.087], deprecations by default [2.101]) —
  `scope` parameters/locals may not escape; `@safe` code gets stack-escape
  checking. Binding rule since [2.099]: in `ref scope return`-annotated
  parameters, `return` adjacent-after-`scope` (in that order) means
  `return scope` (escapes _through the pointer_), otherwise it pairs with
  `ref`. `inout` no longer implies `return` ([2.100]) — annotate explicitly.
- **Attribute inference** — methods of templated aggregates infer
  `pure nothrow @safe @nogc` ([2.063]), all instantiated functions ([2.065]),
  and non-template `auto`-return functions ([2.068]). This is why the house
  rule is [annotate non-templates, infer on templates][agents-attrs]. Since
  [2.104] failed-inference diagnostics print the offending call chain for
  `@nogc`/`nothrow`/`pure` (already done for `@safe` in [2.101]).
- **`@system` variables — DIP1035** (_preview_ `-preview=systemVariables`,
  [2.102]) — `@system int* p;` may not be touched from `@safe` code; the
  tool for "this data carries an invariant `@safe` code could break".
- **`scope` array literals allocate on the stack** ([2.102]) —
  `scope int[] a = [10, 20, 30];` is `@nogc`-legal under `dip1000` (elements
  without destructors, initialized at declaration).
- **`bool` must be 0 or 1 in `@safe`** ([2.109]/[2.110]) — void-initialized
  `bool`s, `bool` union fields, and casts to `bool[]`/`bool*` are deprecated
  in `@safe` code.
- **`-preview=fixImmutableConv`** ([2.101], extended [2.110]) — requires
  strong purity for the unique-result→`immutable` conversion and bans
  `const(void)[]` → `void[]` copies.
- **`-preview=safer`** ([2.111]) — applies the easily-fixed `@safe` checks to
  _unattributed_ functions; cheap extra checking for scripts and `main`.
- **`@live`** ([2.092]) — prototype ownership/borrowing checks for pointers;
  experimental, don't build APIs around it.
- **Misc. `@safe` tightenings** — slicing a static array is `@system`
  ([2.074]); `arr.ptr` is banned in `@safe` ([2.079], use `&arr[0]`);
  `debug { }` blocks may call `@system` ([2.082]) and throwing ([2.094]) code,
  so printf-debugging never forces attribute removal.

---

## Construction, copy, move, destruction

Covered in depth by [Move Semantics & `__rvalue`][move-guide]; the timeline:

- **Qualified constructors** ([2.063]) — `this() immutable` etc. are selected
  by `new immutable C`; a `pure` constructor can build any qualifier. Unique
  expressions (`new`, `.dup`) implicitly convert to `immutable` ([2.063]).
- **Copy constructors — DIP1018** ([2.086]) — `this(ref return scope S rhs)`
  replaces the postblit; defining both yourself is an error, and a user copy
  ctor beside a _generated_ postblit is deprecated ([2.096]) — `@disable
this(this)` when migrating a type that has postblit-bearing fields.
- **Move semantics** ([2.111]) — `__rvalue(expr)` forces rvalue treatment;
  move constructors `this(S)` and move assignment are enabled; **placement
  new** `new (storage) S(args)` constructs into caller-provided memory.
- **Destruction of partially constructed objects** (`-preview=dtorfields`
  [2.083], default [2.098], attribute mismatch an error [2.111]) — if a
  constructor throws, constructed fields are destructed; a `pure`/`nothrow`/
  `@nogc`/`@safe` constructor therefore requires field destructors at least
  as restrictive.
- **`destroy`, never `delete`** — `delete` deprecated [2.079], removed
  [2.100]; the word is an ordinary identifier again since [2.111]. Class
  allocators/deallocators (`new(size_t)`/`delete(void*)` members) are gone
  ([2.080]→[2.098]); `@disable new();` forbids GC construction of a type.
- **The GC runs heap-struct destructors** ([2.067]); guard finalizer-illegal
  work with `GC.inFinalizer` ([2.090]).
- **Unrestricted unions** ([2.072]) — fields with postblit/destructor/invariant
  are allowed; calling the right one is your job (`destroy(u.member)`). Only
  the first member may have a default initializer ([2.098]); initialize others
  via named arguments ([2.108]).

---

## `@nogc`, BetterC & GC-free error handling

- **`@nogc`** ([2.066]) — statically rejects GC allocation; pair with
  `-vgc`/`-profile=gc` ([2.066]/[2.068]) to find allocation points. The repo's
  `@nogc` toolkit ([AGENTS § @nogc primitives][agents-nogc]): `SmallBuffer`,
  the `text` readers/writers, `recycledErrorInstance`.
- **`@mustuse` — DIP1038** ([2.100]) — on a `struct`/`union`, makes silently
  discarding a returned value a compile error; designed for "alternative
  error-handling mechanisms for code that cannot use exceptions, including
  `@nogc` and BetterC code" — exactly the [`Expected`][expected-idioms] use
  case.
- **`-preview=dip1008`** ([2.079]) — `throw new Exception(…)` in `@nogc` code
  via refcounted allocation. The house path is `Expected` +
  `recycledErrorInstance` instead.
- **TypeInfo-free reflection** — `__traits(initSymbol, T)` ([2.099]) yields
  the init bytes for malloc-based construction; `__traits(isZeroInit, T)`
  ([2.083]) gates `memset` fast paths; `__traits(classInstanceAlignment)`
  ([2.101]) joins `classInstanceSize` for in-place class allocation.
- **BetterC arc** — `-betterC` became real in [2.076] (no druntime refs,
  C-`assert`); `version (D_BetterC)` and friends `D_ModuleInfo`/
  `D_Exceptions`/`D_TypeInfo` ([2.077]/[2.082]) gate runtime-dependent code;
  RAII + `scope(exit)`/`try`/`finally` work ([2.078]);
  `pragma(crt_constructor)`/`pragma(crt_destructor)` replace
  `shared static this` ([2.078]); array comparison and `switch` over strings
  work ([2.082]); a minimal `object.d` suffices ([2.079]).
- **Templatized runtime hooks** ([2.106]→[2.112]) — `new T[]`, `length`
  assignment, append, and AA operations now lower to templates instead of
  `TypeInfo`-driven calls, so they inline and infer attributes from your
  element types.
- **`@nogc` exception traces** ([2.102]) — default `Throwable.TraceInfo`
  generation is malloc-based; throwing in `@nogc` no longer touches the GC.

---

## Templates & compile-time

- **`static foreach` — DIP1010** ([2.076]) — declaration- and statement-level
  compile-time iteration over any CTFE-iterable (including ranges); introduces
  no scope. The backbone of [DBI][dbi]-style code generation.
- **Alias assignment** ([2.098]) — inside a template, a declared `alias` may
  be reassigned, turning recursive metaprogramming iterative and killing the
  instantiation explosion:

  ```d
  template staticMap(alias F, Ts...)
  {
      alias staticMap = AliasSeq!();
      static foreach (T; Ts)
          staticMap = AliasSeq!(staticMap, F!T); // alias assignment (2.098)
  }
  ```

- **Mixin types** ([2.088]) — `mixin("int[", n, "]")` in type position.
- **Function-local templates** ([2.063]); local templates may take _local
  symbols_ as alias arguments ([2.087]) — but that dual-context ability is
  deprecated ([2.096]) for GDC/LDC parity; don't design around it.
- **Overloading across kinds** ([2.064]) — template and non-template functions
  overload; same-named templates from different modules form cross-module
  overload sets; template `alias` parameters match basic types ([2.087], so
  `Example!int` works for `template Example(alias A)`).
- **CTFE quality of life** — `static assert(cond, "a = ", value)` multi-arg
  messages ([2.102]); `__ctfeWrite` prints _during_ interpretation ([2.109]);
  `^^` works in CTFE ([2.080]); `deprecated(msg)` accepts CTFE strings
  ([2.071]).
- **Speculative-error debugging** — `-verrors=spec` ([2.072]) shows errors
  swallowed by `__traits(compiles)`/constraints; `-vtemplates` ([2.093])
  prints instantiation statistics; `-mixin=<file>` ([2.084]) dumps generated
  mixins.

### `__traits` worth knowing

| Trait                                                       | Since           | Use for                                                                |
| ----------------------------------------------------------- | --------------- | ---------------------------------------------------------------------- |
| `getAttributes`                                             | [2.061]         | read UDAs (per overload via `getOverloads` — required since [2.102])   |
| `getUnitTests`                                              | [2.064]         | custom test runners (what `silly` builds on)                           |
| `getFunctionAttributes`                                     | [2.066]         | `"pure"`/`"nothrow"`/`"@safe"`/`"ref"`… of a callable                  |
| `getParameterStorageClasses`                                | [2.075]         | detect `return`/`scope`/`out`/`lazy` per parameter                     |
| `getFunctionVariadicStyle`, `getLinkage`                    | [2.075]         | variadic kind; linkage of symbols (aggregates since [2.081])           |
| `isDeprecated`, `isDisabled`                                | [2.077]/[2.079] | skip deprecated/`@disable` symbols when generating code                |
| `getOverloads` (incl. templates with `true` arg)            | [2.081]         | enumerate full overload sets                                           |
| `isZeroInit`, `getTargetInfo`                               | [2.083]         | `memset` fast paths; target/C++-runtime queries                        |
| `getLocation`                                               | [2.088]         | `(file, line, column)` of a declaration — source links                 |
| `isCopyable`                                                | [2.093]         | constraint checks without `std.traits` overhead                        |
| `child`                                                     | [2.094]         | re-bind a member alias to an instance: `__traits(child, obj, T.fn)(…)` |
| `getVisibility`, `getCppNamespaces`                         | [2.096]/[2.095] | visibility strings; C++ namespace tuples                               |
| `parameters`, `initSymbol`                                  | [2.099]         | forwarding; TypeInfo-free init bytes                                   |
| `classInstanceAlignment`                                    | [2.101]         | in-place class construction                                            |
| `isVirtualMethod` (use over deprecated `isVirtualFunction`) | [2.103]         | virtual-dispatch introspection                                         |
| `isBitfield` + `getBitfieldOffset`/`getBitfieldWidth`       | [2.109]/[2.111] | bitfield layout                                                        |
| `isModule`/`isPackage` + `is(sym == module/package)`        | [2.087]         | module-aware reflection                                                |

Also: `__traits(getMember/getOverloads)` bypass visibility since [2.086] —
private members are introspectable, which is what makes `allMembers`-driven
[DBI][dbi] practical. `is()` matches qualifier combinations correctly since
[2.089] (order `shared const` tests before bare `const` in `static if`
chains).

---

## Literals, strings & data embedding

- **Interpolated Expression Sequences** ([2.108]) — `i"sum: $(a + b)"`,
  `` i`…` ``, `iq{…}` lower to a tuple processed by any IES-aware sink. The
  foundation of `styled_template`; see the [IES guide][ies-guide].
- **Hex strings are the binary-data literal** — `x"deadbeef"` was deprecated
  ([2.079]) and an error ([2.086]) as a _string_, then reinstated for data:
  since [2.108] hex strings implicitly convert to integral arrays (big-endian;
  `w`/`d` postfixes select 16/32-bit elements), and `import("file.bin")`
  converts the same way ([2.110]):
  `immutable ubyte[] icon = import("icon.png");` — no cast.
- **Source-location keywords** — `__FUNCTION__`, `__PRETTY_FUNCTION__`,
  `__MODULE__` ([2.063]); `__FILE_FULL_PATH__` ([2.072]); all evaluate at the
  call site as default arguments (robustly so since [2.108]).
- **Lexer hygiene** — Unicode directionality overrides are banned in source
  (Trojan-Source defense, [2.101]); `#ident` inside `q{…}` token strings is
  deprecated ([2.103]); `0b`/`0x` without digits is an error ([2.087]).

---

## Aggregates, operators & built-in collections

- **Operator overloading is D2-only** — `opUnary`/`opBinary`/`opBinaryRight`/
  `opOpAssign` templates; the D1 names were removed in [2.100]. Multi-dim
  `opIndex`/`opSlice(size_t dim)`/`opDollar!dim` enable `m[1 .. 3, 2, 0 .. $]`
  ([2.066]).
- **Struct equality is structural** ([2.063]) — `==` without `opEquals`
  compares member-wise (arrays by value); a struct's own/generated `opEquals`
  beats an `alias this` member's ([2.086]); `-preview=fieldwise` ([2.085])
  makes the comparison strictly per-field.
- **`opApply` delegates must be `scope`** ([2.072]) —
  `int opApply(scope int delegate(ref T) dg)` — or every `foreach` over your
  type heap-allocates a closure. Returning a constant non-zero from `opApply`
  that isn't the delegate's result is deprecated ([2.112]).
- **`alias this`** — partial assignment through it is an error ([2.100]);
  class `alias this` is deprecated ([2.103]); assignment spelling
  `alias this = member;` allowed ([2.105]).
- **Associative arrays** — keys need `opEquals` + `toHash` (equality, not
  ordering, since [2.066]); `aa.require(key, value)` and
  `aa.update(key, create, update)` are single-lookup primitives ([2.082]);
  `byKeyValue` ([2.067]); static initialization ([2.106]).
- **Static arrays** — instances expose `.tupleof` ([2.100]); known-length
  slices convert to static array parameters ([2.063]).
- **Enums** — members accept UDAs, `deprecated`, `@disable` ([2.082]);
  comparing values of different enum types is an error ([2.081]).

---

## `shared` & atomics

- `shared` read-modify-write (`x++`, `x += 2`) is an error ([2.080], after
  deprecation in [2.066]) — use `core.atomic.atomicOp`, `atomicFetchAdd`/
  `atomicFetchSub` ([2.089]), `atomicExchange`, and `cas` ([2.088]).
- A `shared` struct/class that defines `opOpAssign`/`opUnary` may be used with
  `x++` syntax ([2.088]) — the operator is trusted to do the atomics; this is
  how `Atomic!T` wrapper types work.
- `-preview=nosharedaccess` ([2.093], from DIP1024) forbids _all_ direct
  reads/writes of `shared` — the end state to write towards: every access
  through `core.atomic` or after casting away `shared` under a lock.
- `atomicLoad` preserves `shared` on indirections ([2.077]); invalid
  `MemoryOrder` arguments are rejected at compile time ([2.107]).
- `immutable` is implicitly `shared`: initialize `immutable`/`const` globals
  from `shared static this()`, never per-thread `static this()` ([2.098]/[2.106]).

---

## Interop: C, C++, Objective-C

- **ImportC** — D compiles C11 directly: `.c` files as modules ([2.098]);
  C code can `__import` D modules ([2.099]); `typeof` ([2.101]) and `__check`
  ([2.103]) extensions; `#pragma attribute(push, nogc, nothrow)` makes whole
  C headers `@nogc nothrow` ([2.111]); `-i` auto-includes `.c` files
  ([2.111]); `__module hello.utils;` disambiguates same-named C files
  ([2.112]). House workflow: [Integrating C Libraries][importc-guide].
- **`extern (C++)`** — namespaces ([2.066]), string-form
  `extern (C++, "std", "chrono")` that doesn't occupy a D identifier
  ([2.083]); D operator overloads mangle as C++ operators and mixed-language
  class hierarchies construct/destruct correctly ([2.081]);
  `pragma(mangle)` on aggregates binds C++ classes whose names are D keywords
  ([2.097], base form since [2.063]); `-extern-std=c++11` is the default
  ([2.095]); `@gnuAbiTag` ([2.092]) and `__c_wchar_t` ([2.084]) cover ABI
  corners; `-HC` generates C++ headers from D ([2.091]).
- **`pragma(printf)` / `pragma(scanf)`** ([2.092]) — compiler-checked format
  strings for your own `extern (C)` variadic functions.
- **`extern (C)` functions cannot overload** ([2.105], deprecated [2.095]) —
  one name, one signature; `extern (C)` declarations inside template mixins
  mangle as C at module scope ([2.089]).
- **Objective-C** — `extern (Objective-C)` classes, `@selector` ([2.069]),
  full class support ([2.085]), protocols via `interface` + `@optional`
  ([2.095]), auto-generated selectors ([2.111]).

---

## Compiler switches that shape new code

`-preview=X` / `-revert=X` replaced the ad-hoc `-dipNNNN` flags in [2.085].
Previews that became defaults — the language as it now stands:

| Was preview            | Default since | Effect                                       |
| ---------------------- | ------------- | -------------------------------------------- |
| `intpromote`           | [2.099]       | C-style integral promotion for unary `-`/`~` |
| `dtorfields`           | [2.098]       | ctor throw destructs constructed fields      |
| `markdown`             | [2.094]       | Markdown in Ddoc                             |
| `shortenedMethods`     | [2.101]       | `=>` function bodies (DIP1043)               |
| `dip25`                | [2.103]       | `return ref` enforcement                     |
| `dip1000` deprecations | [2.101]       | `scope` escape checks warn by default        |
| `bitfields`            | [2.112]       | C-compatible bitfields                       |

Previews worth opting into today: **`in`** and **`dip1000`** (repo baseline),
`fixImmutableConv`, `systemVariables`, `safer`, `nosharedaccess` (aspirational).
No language _edition_ shipped through 2.112 — the editions mechanism is only
referenced prospectively (first in [2.109]).

Diagnostics and build switches that pay rent: `-verrors=context` (caret
diagnostics, [2.085]); `-checkaction=context` (assert prints operand values,
[2.085] — in the repo's unittest flags); `-verrors=spec` ([2.072]);
`-check=`/`-checkaction=` fine-grained runtime checks ([2.084]);
`-boundscheck=safeonly` keeps `@safe` bounds checks in release ([2.066]);
`-i` include-imports builds ([2.079]); `-vasm` per-function disassembly
([2.099]); `-ftime-trace` build profiling and `-oq` fully-qualified object
names ([2.111]); demangled linker errors with fix suggestions ([2.109]);
`-vgc`/`-profile=gc` allocation hunting ([2.066]/[2.068]); `-lowmem`
([2.086]); `-nothrow` ([2.106]); `-target=<triple>` cross-compilation
([2.098]).

---

## Legacy constructs still worth knowing

Removed features are hard errors and deprecated ones warn at the use site, so
neither needs memorizing — the authoritative what-and-when list is the official
[deprecated features table][deprecate]. The short list below is different: these
constructs **still compile silently** but have a strictly better modern form.

| Write…                                       | …instead of                                  | Modern since    |
| -------------------------------------------- | -------------------------------------------- | --------------- |
| expression contracts, then the body directly | `in { … }`/`out { … }` blocks + `do { … }`   | [2.081]         |
| copy constructor `this(ref S)`               | postblit `this(this)`                        | [2.086]         |
| `AliasSeq` (`std.meta`)                      | `TypeTuple` (compatibility alias)            | [2.068]         |
| `static foreach` / alias assignment          | recursive template self-instantiation        | [2.076]/[2.098] |
| `x"…"` hex strings / `import("file")`        | `std.conv.hexString` + casts for binary data | [2.108]/[2.110] |
| named arguments for struct literals          | positional `S(2, 8, 32, 80, true)` literals  | [2.108]         |

---

## Milestones

| Release | Date     | Landmark                                                                      |
| ------- | -------- | ----------------------------------------------------------------------------- |
| [2.061] | Jan 2013 | User-defined attributes; `alias Name = Type`                                  |
| [2.064] | Nov 2013 | `package.d` (DIP37); eponymous shorthand; `__traits(getUnitTests)`            |
| [2.066] | Aug 2014 | `@nogc`; multi-dim slicing; uniform construction                              |
| [2.067] | Mar 2015 | DIP25 `return ref`; GC runs struct destructors                                |
| [2.071] | Apr 2016 | DIP22 import/visibility overhaul                                              |
| [2.076] | Sep 2017 | `static foreach` (DIP1010); `-betterC` revival                                |
| [2.081] | Jul 2018 | DIP1009 expression contracts                                                  |
| [2.086] | May 2019 | Copy constructors (DIP1018)                                                   |
| [2.092] | May 2020 | `-preview=in`; `@live`; `pragma(printf)`                                      |
| [2.098] | Oct 2021 | ImportC; alias assignment                                                     |
| [2.099] | Mar 2022 | `throw` expressions; `noreturn`; `__traits(parameters)` (DIP1034)             |
| [2.100] | May 2022 | `@mustuse` (DIP1038); `delete` and D1 operators removed                       |
| [2.101] | Nov 2022 | DIP1000 deprecations by default; bitfields preview; shortened methods default |
| [2.106] | Dec 2023 | Static AA initialization; templatized runtime hooks begin                     |
| [2.108] | Apr 2024 | Interpolated Expression Sequences; named arguments (DIP1030)                  |
| [2.111] | Apr 2025 | `__rvalue` + move constructors; placement new; `ref` locals; `-preview=safer` |
| [2.112] | Jan 2026 | Bitfields default; ImportC `__module`; array/AA runtime hooks templatized     |

---

## Sources

- DMD changelogs 2.060–2.112 — `dlang/dlang.org` repository,
  `changelog/*.dd` (published at [dlang.org/changelog][changelog-index]);
  every version link below resolves to the corresponding release page.
- [D language specification][spec] — normative for features whose DIP text has
  drifted (notably DIP1000).

<!-- References -->

[2.060]: https://dlang.org/changelog/2.060.html
[2.061]: https://dlang.org/changelog/2.061.html
[2.063]: https://dlang.org/changelog/2.063.html
[2.064]: https://dlang.org/changelog/2.064.html
[2.065]: https://dlang.org/changelog/2.065.0.html
[2.066]: https://dlang.org/changelog/2.066.0.html
[2.067]: https://dlang.org/changelog/2.067.0.html
[2.068]: https://dlang.org/changelog/2.068.0.html
[2.069]: https://dlang.org/changelog/2.069.0.html
[2.070]: https://dlang.org/changelog/2.070.0.html
[2.071]: https://dlang.org/changelog/2.071.0.html
[2.072]: https://dlang.org/changelog/2.072.0.html
[2.074]: https://dlang.org/changelog/2.074.0.html
[2.075]: https://dlang.org/changelog/2.075.0.html
[2.076]: https://dlang.org/changelog/2.076.0.html
[2.077]: https://dlang.org/changelog/2.077.0.html
[2.078]: https://dlang.org/changelog/2.078.0.html
[2.079]: https://dlang.org/changelog/2.079.0.html
[2.080]: https://dlang.org/changelog/2.080.0.html
[2.081]: https://dlang.org/changelog/2.081.0.html
[2.082]: https://dlang.org/changelog/2.082.0.html
[2.083]: https://dlang.org/changelog/2.083.0.html
[2.084]: https://dlang.org/changelog/2.084.0.html
[2.085]: https://dlang.org/changelog/2.085.0.html
[2.086]: https://dlang.org/changelog/2.086.0.html
[2.087]: https://dlang.org/changelog/2.087.0.html
[2.088]: https://dlang.org/changelog/2.088.0.html
[2.089]: https://dlang.org/changelog/2.089.0.html
[2.090]: https://dlang.org/changelog/2.090.0.html
[2.091]: https://dlang.org/changelog/2.091.0.html
[2.092]: https://dlang.org/changelog/2.092.0.html
[2.093]: https://dlang.org/changelog/2.093.0.html
[2.094]: https://dlang.org/changelog/2.094.0.html
[2.095]: https://dlang.org/changelog/2.095.0.html
[2.096]: https://dlang.org/changelog/2.096.0.html
[2.097]: https://dlang.org/changelog/2.097.0.html
[2.098]: https://dlang.org/changelog/2.098.0.html
[2.099]: https://dlang.org/changelog/2.099.0.html
[2.100]: https://dlang.org/changelog/2.100.0.html
[2.101]: https://dlang.org/changelog/2.101.0.html
[2.102]: https://dlang.org/changelog/2.102.0.html
[2.103]: https://dlang.org/changelog/2.103.0.html
[2.104]: https://dlang.org/changelog/2.104.0.html
[2.105]: https://dlang.org/changelog/2.105.0.html
[2.106]: https://dlang.org/changelog/2.106.0.html
[2.107]: https://dlang.org/changelog/2.107.0.html
[2.108]: https://dlang.org/changelog/2.108.0.html
[2.109]: https://dlang.org/changelog/2.109.0.html
[2.110]: https://dlang.org/changelog/2.110.0.html
[2.111]: https://dlang.org/changelog/2.111.0.html
[2.112]: https://dlang.org/changelog/2.112.0.html
[agents-attrs]: ../AGENTS.md#safety-attributes--annotate-non-templates-infer-on-templates
[agents-nogc]: ../AGENTS.md#nogc-primitives-and-what-breaks-nogcnothrow
[agents-preview]: ../AGENTS.md#preview-flags
[agents-silly]: ../AGENTS.md#test-runner-silly
[changelog-index]: https://dlang.org/changelog/
[code-style]: ../code-style.md
[code-style-contracts]: ../code-style.md#expression-based-contracts-dip1009
[code-style-named]: ../code-style.md#named-arguments-dip1030
[dbi]: ../design-by-introspection-01-guidelines.md
[deprecate]: https://dlang.org/deprecate.html
[expected-idioms]: ../idioms/expected/index.md
[fdp]: ../functional-declarative-programming-guidelines.md
[forced-named]: ../idioms/forced-named-arguments/index.md
[ies-guide]: ../interpolated-expression-sequences.md
[importc-guide]: ../importc-c-libraries.md
[move-guide]: ../move-semantics/index.md
[spec]: https://dlang.org/spec/spec.html

# Move Semantics and `__rvalue` in D

This is a technical survey of D's **move semantics** — the language machinery
that lets a struct value be _moved_ (its representation transferred and the
source's lifetime ended) instead of _copied_. The feature set crystallised
across DMD 2.111–2.113 around three pillars:

1. The [`__rvalue(expr)`][spec-rvalue-expr] built-in, which forces an lvalue to
   be treated as an rvalue.
2. **Move constructors** and **move assignment** — overloads that take their
   argument _by value_ (no `ref`) and therefore bind only to rvalues.
3. A druntime layer ([`core.lifetime.move`][move-doc], `forward`, `opPostMove`)
   that wraps these primitives into the portable, `@safe`-friendly API user code
   should actually reach for.

Everything below is grounded in runnable snippets verified against three
toolchains (see [Compiler support](#_14-compiler-support-and-timeline)). The
verifiable examples are tagged with [`toolchainRequirements`][toolchain-req] so
`dub` selects a frontend new enough to compile them.

> [!NOTE]
> The examples that demonstrate **bleeding-edge behaviour** (the `@safe`
> aliasing rule, `ref`-returning `__rvalue` functions, and the 2024-edition
> assignment check) are shown as plain code blocks rather than `dub`
> single-file recipes, because they require a frontend newer than any released
> compiler at the time of writing. Run them with a development DMD.

---

## Background: a short history of copy and move semantics in D

D has reworked both **copying** and **moving** over its lifetime, and each time
the move was the same: replace a _blit-then-fix-up_ hook with a _direct
construction_ mechanism. Seeing the two stories side by side dissolves most of
the confusion around the older hooks — in particular, the move-side hook
`opPostMove` is the analogue of the copy-side postblit, **not** of the move
constructor.

**Copying.** The original mechanism was the **postblit**, `this(this)`: the
compiler bit-copies the source, then calls `this(this)` so the fresh copy can
repair whatever the raw byte-copy got wrong (e.g. duplicate an owned buffer).
Postblit can't inspect the source, can't change qualifiers, and runs on a
half-formed object. [DIP1018][dip1018] replaced it with the **copy constructor**
`this(ref S)` (DMD 2.086, 2019), which constructs the destination directly from
the source. The spec now calls postblit a legacy feature that copy constructors
will replace — though it isn't gone: druntime's dynamic-array and
associative-array hooks still require it pending [issue 20970][issue-20970].

**Moving.** The story repeats. [DIP1014][dip1014] introduced **`opPostMove`**:
when the compiler relocates a struct by bit-copy, it calls `opPostMove(ref S
old)` afterwards so a self-referential struct can fix up interior pointers. That
is the move analogue of the postblit — blit, then fix up. It lives in druntime
as `__move_post_blt` and still backs [`core.lifetime.move`][move-doc]. The work
surveyed in this document — [DIP1040][dip1040] (_Copying, Moving, and
Forwarding_, since superseded) realised via [`__rvalue`](#_1-the-__rvalue-expr-built-in)
and **move constructors** `this(S)` (DMD 2.111+, 2024–2025) — is the move
analogue of the _copy constructor_: it constructs the destination directly from
an expiring source, and you write the transfer (and any self-pointer fixup) in
the move-constructor body itself.

| Operation | Blit-then-fix-up hook (older)            | Direct construction (current)                                  |
| :-------- | :--------------------------------------- | :------------------------------------------------------------- |
| Copy      | postblit `this(this)`                    | copy constructor `this(ref S)` ([DIP1018][dip1018])            |
| Move      | `opPostMove(ref S)` ([DIP1014][dip1014]) | move constructor `this(S)` via `__rvalue` ([DIP1040][dip1040]) |

> [!NOTE]
> Both old hooks linger for the same reason — incomplete migration. Postblit
> survives because druntime's arrays/AAs still depend on it; `opPostMove`
> survives because `core.lifetime.move` still drives the DIP1014 blit path
> rather than calling a move constructor. New code should prefer copy/move
> **constructors**; reach for `opPostMove` only for a self-referential type that
> must survive a library `move()` (see [§11](#_11-the-druntime-layer-move-forward-oppostmove)).

---

## 1. The `__rvalue(expr)` built-in

**Problem:** Overload resolution and move construction key off whether an
argument is an _lvalue_ (has an address, persists) or an _rvalue_ (temporary,
about to expire). A named variable is always an lvalue — so how do you opt a
variable into rvalue treatment to trigger a move?

**Solution:** Wrap it in [`__rvalue(expr)`][spec-rvalue-expr]. Per the spec, _"An
`RvalueExpression` causes the embedded `AssignExpression` to be treated as an
rvalue whether it is an rvalue or an lvalue."_ When both a `ref` and a non-`ref`
overload exist, _"an rvalue is preferably matched to the non-ref parameter, and
an lvalue is preferably matched to the ref parameter."_

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "rvalue_overload"
    toolchainRequirements frontend=">=2.111"
+/
import std.stdio : writeln;

int foo(int)     { return 1; } // by value (rvalue-preferring)
int foo(ref int) { return 2; } // by ref   (lvalue-preferring)

void main()
{
    int s;
    writeln(i"foo(s)           = $(foo(s))");           // lvalue -> ref
    writeln(i"foo(__rvalue(s)) = $(foo(__rvalue(s)))"); // rvalue -> by value
}
```

```[Output]
foo(s)           = 2
foo(__rvalue(s)) = 1
```

`__rvalue` is a reserved keyword (it lexes like `__traits` and `__vector`); the
parser sets an `rvalue` flag on the wrapped expression rather than creating a
dedicated node, so it composes with any expression — including member and
`with`-scoped component accesses, which a [2.112 fix][pr-21694] corrected.

> [!WARNING]
> `__rvalue` ends the source's lifetime. The moved-from object is no longer a
> valid value; reading it is a logic error. The destructor still runs at scope
> exit, so a move constructor **must** reset the source to a benign,
> double-destroy-safe state (see [§9](#_9-lifetime-the-destroy-reset-contract)).

---

## 2. Move constructors: `this(S)` vs `this(ref S)`

A struct constructor is a **move constructor** when its first parameter is the
struct's own type _by value_ (not `ref`); the by-`ref` form is the familiar
**copy constructor**. From [`spec/struct.dd`][spec-struct]: _"copy constructors
make a copy of the original, while move constructors move the contents of the
original, and the lifetime of the original ends."_

```d
struct A
{
    this(ref return scope A rhs) {}                  // copy constructor
    this(return scope A rhs) {}                      // move constructor
    this(return scope const A rhs, int b = 7) {}     // move ctor + default arg
}
```

The move constructor's parameter **only accepts rvalues**, so it is selected by
a literal, a function returning by value, or an `__rvalue(...)`-wrapped lvalue.
The example below counts which special member fires for each form. Note the
symmetry: the same four signatures, by-`ref` vs by-value, give copy-vs-move for
both construction and assignment.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "move_vs_copy"
    toolchainRequirements frontend=">=2.111"
+/
import std.stdio : writeln;

__gshared int moveCtor, copyCtor, moveAss, copyAss;

struct S
{
    this(S s)              { ++moveCtor; } // move constructor  (by value)
    this(ref S s)          { ++copyCtor; } // copy constructor  (by ref)
    void opAssign(S s)     { ++moveAss; }  // move assignment   (by value)
    void opAssign(ref S s) { ++copyAss; }  // copy assignment   (by ref)
}

void main()
{
    S x;
    S a = x;             // lvalue -> copy constructor
    S b = __rvalue(x);   // rvalue -> move constructor
    a = x;               // lvalue -> copy assignment
    a = __rvalue(x);     // rvalue -> move assignment
    writeln(i"copyCtor=$(copyCtor) moveCtor=$(moveCtor) copyAss=$(copyAss) moveAss=$(moveAss)");
}
```

```[Output]
copyCtor=1 moveCtor=1 copyAss=1 moveAss=1
```

> [!NOTE]
> The compiler enforces consistency: a struct may not declare **both** a move
> constructor and a postblit (`this(this)`), and certain copy/move + postblit
> combinations are rejected outright. Move semantics are designed around copy
> constructors, not the legacy postblit.

---

## 3. Overload resolution: lvalues take `ref`, rvalues take by-value

The selection rule generalises beyond constructors to any overload set with a
`ref`/non-`ref` pair. An lvalue prefers `ref`; an rvalue (including
`__rvalue(...)`) prefers the by-value parameter.

::: code-group

```d [D]
struct S { this(ref return scope S) {} }

int overload(const S)     { return 1; } // rvalue-preferring
int overload(const ref S) { return 2; } // lvalue-preferring

void main()
{
    S s;
    assert(overload(s)            == 2); // lvalue   -> ref
    assert(overload(S())          == 1); // literal  -> by value
    assert(overload(__rvalue(s))  == 1); // forced rvalue -> by value
}
```

```cpp [C++ analogue]
struct S { S(const S&); };

int overload(S);         // by value / would bind rvalue ref
int overload(const S&);  // lvalue ref

S s;
overload(s);             // lvalue ref
overload(S{});           // by value
overload(std::move(s));  // std::move ≈ __rvalue
```

:::

`std::move` in C++ and `__rvalue` in D play the same role: a cast that changes
_value category_ without generating code. Neither moves anything by itself — the
move happens when the rvalue then binds to a move constructor or move assignment.

---

## 4. Move assignment

Move assignment is just an `opAssign` whose parameter is taken by value. It runs
when the right-hand side is an rvalue (and the type has a move-assign overload),
mirroring the `this(S)` / `this(ref S)` split shown in [§2](#_2-move-constructors-this-s-vs-this-ref-s).
A struct that wants the full set of special members — destructor, copy
constructor, copy assignment, move constructor, move assignment — implements
D's equivalent of C++'s _rule of five_:

```d
struct S
{
    ~this() {}                          // 1. destructor
    this(ref return scope S) {}         // 2. copy constructor
    void opAssign(ref S) {}             // 3. copy assignment
    this(return scope S) {}             // 4. move constructor
    void opAssign(S) {}                 // 5. move assignment
}
```

---

## 5. The `__rvalue` function attribute (a library primitive)

`__rvalue` may also be applied as an **attribute** on a function that returns by
`ref`. Per the spec: _"This makes the function's return value be treated as an
`RvalueExpression`. The attribute is only accepted on functions that return by
reference."_ At each call site, `f()` is implicitly lowered to `__rvalue(f())`.

This is the building block that lets druntime implement `move` without exposing
`__rvalue` in user code:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "rvalue_attribute"
    toolchainRequirements frontend=">=2.111"
+/
import std.stdio : writeln;

__gshared int moveCtor, copyCtor;

struct S
{
    int* p;
    this(S rhs)     { ++moveCtor; p = rhs.p; rhs.p = null; } // move ctor
    this(ref S rhs) { ++copyCtor; assert(0); }               // copy ctor
}

__gshared S g;

ref S myMove() __rvalue { return g; } // result treated as an rvalue

void main()
{
    g.p = new int(5);
    S t = myMove();   // lowered to `__rvalue(myMove())` -> move ctor
    writeln(i"*t.p=$(*t.p) moveCtor=$(moveCtor) copyCtor=$(copyCtor) g.p is null=$(g.p is null)");
}
```

```[Output]
*t.p=5 moveCtor=1 copyCtor=0 g.p is null=true
```

> [!TIP]
> The PR author's guidance was explicit: this attribute is _"essentially a
> library implementation detail"_ — the useful set of helpers built on it
> (`move`, `forward`, …) lives in druntime. Application code should call those,
> not annotate its own functions with `__rvalue`.

---

## 6. Implicit move constructors

If a struct has at least one (non-overlapped) field that itself has a move
constructor, and the struct declares no move constructor of its own, the
compiler **synthesises one**, analogous to how default copy constructors are
built. The generated body, from [`spec/struct.dd`][spec-struct]:

```d
this(return scope inout(S) src) inout
{
    foreach (i, ref inout field; src.tupleof)
        this.tupleof[i] = __rvalue(field); // each field is *moved*, not copied
}
```

We can observe the field-wise move by giving the field a copy ctor that computes
`i - 1` and a move ctor that computes `i + 1`:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "implicit_move_ctor"
    toolchainRequirements frontend=">=2.111"
+/
import std.stdio : writeln;

struct T
{
    int i;
    this(ref inout T t) inout { this.i = t.i - 1; } // copy constructor
    this(inout T t) inout     { this.i = t.i + 1; } // move constructor
}

struct S { T t; } // no explicit move ctor -> compiler generates one

void main()
{
    S s; s.t.i = 3;
    S u = s;            // copy: generated copy ctor copies field -> 2
    S v = __rvalue(u);  // move: generated move ctor moves field  -> 3
    writeln(i"u.t.i=$(u.t.i) v.t.i=$(v.t.i)");
}
```

```[Output]
u.t.i=2 v.t.i=3
```

If the generated move constructor fails to type-check, it is `@disable`d rather
than silently dropped. A [2.113 fix][pr-22173] further ensures fields with
elaborate copy/move constructors are never elided during these rewrites.

---

## 7. Qualifier overloads and the `inout` wildcard

A move constructor can be overloaded on qualifiers applied to the _source_ (the
parameter) and to the _destination_ (the method), exactly like copy
constructors. `inout` collapses the mutable/`const`/`immutable` matrix into a
single wildcard overload:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "inout_move_ctor"
    toolchainRequirements frontend=">=2.111"
+/
import std.stdio : writeln;

__gshared int moves;

struct A
{
    this(ref return scope inout A rhs) inout { assert(0); } // copy ctor
    this(return scope inout A rhs) inout     { ++moves; }   // move ctor (wildcard)
}

void main()
{
    A m; const A c; immutable A i;
    A a           = __rvalue(m); // mutable
    const A b     = __rvalue(c); // const
    immutable A d = __rvalue(i); // immutable
    writeln(i"moves=$(moves)");
}
```

```[Output]
moves=3
```

---

## 8. Move-only types and disabling moves

Declaring (or `@disable`-ing) a move constructor suppresses the implicit one.
Combine `@disable this(ref T)` (no copying) with a move constructor to get a
**move-only** type — D's analogue of `std::unique_ptr`:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "move_only"
    toolchainRequirements frontend=">=2.111"
+/
import std.stdio : writeln;

struct Unique
{
    int* p;
    this(int v)      { p = new int(v); }
    @disable this(ref Unique);                    // no copying
    this(Unique rhs) { p = rhs.p; rhs.p = null; } // move ctor (pilfer)
    ~this()          { p = null; }                // benign double-dtor
}

Unique make(int v) { return Unique(v); } // rvalue return: no copy required

void main()
{
    auto a = make(5);
    auto b = __rvalue(a);     // move; ownership leaves `a`
    // Unique c = b;          // would be a compile error: copy is @disabled
    writeln(i"a.p is null=$(a.p is null) *b.p=$(*b.p)");
}
```

```[Output]
a.p is null=true *b.p=5
```

> [!NOTE]
> A `union` (or anonymous union / overlapped fields) whose members have move
> constructors cannot be moved — the compiler issues _"could not generate move
> constructor"_ because it cannot know which overlapped member is live.

---

## 9. Lifetime: the destroy-reset contract

When an argument is matched to a by-value (rvalue) parameter, _"the function
will then call the destructor (if any) on the parameter at the conclusion of the
function."_ Critically, the spec warns that after `__rvalue` the source is
invalid but **its destructor still runs at scope exit**:

> The compiler won't always be able to detect a use of the lvalue after it has
> been passed to the function, which means that the destructor for the object
> must reset the object's contents to its initial value, or at least a benign
> value that can be destructed more than once.

This is why every move constructor above nulls the source's pointer (`rhs.p =
null`) — so the eventual second destructor call is a harmless no-op rather than a
double-free. The canonical hazard from the spec:

```d
import core.stdc.stdlib;

struct S
{
    ubyte* p;
    ~this() { free(p); /* WITHOUT `p = null;` this double-frees */ }
}

void sink(S s) { /* destructor of `s` frees `s.p` here */ }

void oops()
{
    S s;
    s.p = cast(ubyte*) malloc(10);
    sink(__rvalue(s));
    // destructor of `s` runs again at scope exit -> double free
}
```

---

## 10. `@safe` and the aliasing hazard (DMD 2.112+)

`__rvalue` is **not** a `@safe` primitive. Because it can alias an lvalue into a
by-value parameter, it can be used to observe a mutation through what should be
an immutable binding. The reduced case from [issue 21414][issue-21414]:

```d
@safe:
struct S { int x; this(int x) { this.x = x; } ~this() {} this(S s) {} }

void foo(S s, immutable S t)
{
    assert(t.x == 2);
    s.x = 3;
    assert(t.x == 2); // could fail: s and t alias the same storage
}

void main()
{
    auto s = S(2);
    foo(__rvalue(s), __rvalue(s)); // both params alias `s`
}
```

Since DMD 2.112 ([fix #21414][issue-21414]) the compiler **rejects** an
`__rvalue` move of a variable inside a `@safe` function:

```[Error]
Error: moving variable `__rvalue(s)` with `__rvalue` is not allowed in a `@safe` function
```

> [!DANGER]
> LDC 1.41 (frontend 2.111) does **not** yet enforce this — the code above
> compiles silently there. This is a concrete reason to prefer
> [`core.lifetime.move`](#_11-the-druntime-layer-move-forward-oppostmove), which
> infers safety correctly, over hand-written `__rvalue`.

---

## 11. The druntime layer: `move`, `forward`, `opPostMove`

User code should reach for [`core.lifetime.move`][move-doc] rather than
`__rvalue`. `move` performs a **destructive** move: it blits the source over the
target, runs any `opPostMove` hook, then — if the type has a destructor or
postblit — resets the source to `.init` so its later destruction is benign. It
does not require `__rvalue` at the call site and works on every modern frontend.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "lifetime_move"
    toolchainRequirements frontend=">=2.111"
+/
import std.stdio : writeln;
import core.lifetime : move;

struct S { int* p; ~this() {} }

void main()
{
    S a; a.p = new int(7);
    S b = move(a);        // destructive move: `a` reset to S.init
    writeln(i"a.p is null=$(a.p is null) *b.p=$(*b.p)");
}
```

```[Output]
a.p is null=true *b.p=7
```

The relevant druntime machinery:

| Symbol                                              | Module                 | Role                                                                        |
| :-------------------------------------------------- | :--------------------- | :-------------------------------------------------------------------------- |
| [`move(source)`][move-doc] / `move(source, target)` | `core.lifetime`        | Destructive move; resets source to `.init` when it needs destruction.       |
| `moveEmplace(source, target)`                       | `core.lifetime`        | Like `move` but assumes `target` is uninitialised (no destroy first).       |
| `forward!args`                                      | `core.lifetime`        | Perfect-forwarding: preserves `ref`/`out`/`lazy`, moves rvalues via `move`. |
| `__move_post_blt(tgt, src)`                         | `core.internal.moving` | Compiler-emitted hook after a blit; recursively calls `opPostMove`.         |
| `hasElaborateMove!T`                                | `core.internal.traits` | True if `T` (or a field) defines `opPostMove(ref T)`.                       |

`opPostMove(ref typeof(this))` is the _self-referential_ escape hatch from
[DIP1014][dip1014]: a struct that stores interior pointers to itself defines it
to fix those pointers up after druntime blits the bytes to a new address. It is
required to be `nothrow`. As the [history section](#background-a-short-history-of-copy-and-move-semantics-in-d)
explains, it is the move analogue of the postblit — a blit-then-fix-up hook that
move **constructors** supersede for ordinary types; you only need it for a
self-referential type that must survive a library `move()`.

> [!NOTE]
> These are the two move mechanisms from the history above: the
> **language-level** move constructor `this(S)` (you write the transfer logic
> directly), and the **DIP1014** `opPostMove` + `__move_post_blt` blit hook that
> `core.lifetime.move` still drives. The library `move()` has not yet been
> migrated to call move constructors, so for self-referential types `opPostMove`
> remains necessary today.

---

## 12. Compile-time introspection

Three traits distinguish the copy-family special members. A move constructor is
_"distinct from a copy constructor or a postblit"_:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "move_traits"
    toolchainRequirements frontend=">=2.111"
+/
import std.stdio : writeln;

struct MoveC    { this(MoveC) {} }     // move constructor
struct CopyC    { this(ref CopyC) {} } // copy constructor
struct Postblit { this(this) {} }      // postblit

static assert( __traits(hasMoveConstructor, MoveC));
static assert(!__traits(hasMoveConstructor, CopyC));
static assert(!__traits(hasMoveConstructor, Postblit)); // a postblit is not a move ctor
static assert( __traits(hasCopyConstructor, CopyC));
static assert( __traits(hasPostblit, Postblit));

void main()
{
    writeln(i"MoveC: move=$(__traits(hasMoveConstructor, MoveC)) copy=$(__traits(hasCopyConstructor, MoveC))");
    writeln(i"CopyC: move=$(__traits(hasMoveConstructor, CopyC)) copy=$(__traits(hasCopyConstructor, CopyC))");
    writeln(i"Postblit: postblit=$(__traits(hasPostblit, Postblit))");
}
```

```[Output]
MoveC: move=true copy=false
CopyC: move=false copy=true
Postblit: postblit=true
```

---

## 13. The 2024 edition: discarded rvalue assignment is an error

A separate but related tightening lives behind D's **2024 edition** (enabled
with `-edition=2024`). Assigning to a struct _rvalue_ and discarding the result
is now an error when the call lowers to `opAssign`/`opOpAssign`/`opUnary` and the
struct has no tail-mutable pointer fields, because the write almost certainly
vanishes:

```d
struct S
{
    int i;
    void opAssign(S s) {}
}

S foo() { return S(0); }

void main()
{
    foo() = S(2); // Error (with -edition=2024): assignment to struct rvalue is discarded
}
```

```[Error]
Error: assignment to struct rvalue `foo()` is discarded
       if the assignment is needed to modify a global, call `opAssign` directly or use an lvalue
```

Without `-edition=2024` the code compiles (the silent no-op the rule is meant to
catch). The gating is deliberate — editions let breaking diagnostics ship
without disturbing existing code.

---

## 14. Compiler support and timeline

Move semantics landed incrementally. The table maps each capability to the
frontend version that first shipped it, and to the toolchains this survey was
verified against: the Nix devshell's **DMD 2.110**, **LDC 1.41** (frontend
2.111), and a development **DMD 2.113-beta** build.

| Capability                                                         | First frontend | DMD 2.110 | LDC 1.41 (2.111) | DMD 2.113-beta |
| :----------------------------------------------------------------- | :------------: | :-------: | :--------------: | :------------: |
| `__rvalue(expr)`, move/copy ctor selection ([#17050][pr-17050])    |     2.111      |    ❌     |        ✅        |       ✅       |
| Implicit move constructors ([#20634][pr-20634])                    |     2.111      |    ❌     |        ✅        |       ✅       |
| `return __rvalue(x)` move-constructs NRVO ([#20585][pr-20585])     |     2.111      |    ❌     |        ✅        |       ✅       |
| `__rvalue` function attribute ([#20946][pr-20946])                 |     2.111      |    ❌     |        ✅        |       ✅       |
| `__traits(hasMoveConstructor)`                                     |     2.111      |    ❌     |        ✅        |       ✅       |
| `__rvalue` rejected in `@safe` ([#21414][issue-21414])             |     2.112      |    ❌     |        ❌        |       ✅       |
| `ref`-returning `__rvalue` calls move ctor ([#22111][issue-22111]) |     2.113      |    ❌     |        ❌        |       ✅       |
| Discarded rvalue-assignment error (`-edition=2024`)                |   unreleased   |    ❌     |        ❌        |       ✅       |

The contrast at the 2.113 boundary is observable. With `ref S moveS() __rvalue`
and `S copyS() => moveS();`, calling `copyS()`:

- **LDC 1.41 / 2.111** returns a bit-copy _without_ invoking any constructor
  (`moveCtor == 0`) — the bug fixed in [#22112][pr-22112].
- **DMD 2.113-beta** correctly invokes the move constructor (`moveCtor == 1`).

### Verifying these examples

The `dub` single-file recipes above carry `toolchainRequirements
frontend=">=2.111"`, so `dub` (and therefore `ci --verify`) selects a compliant
compiler and the recipes run as written. The repo's pinned **DMD 2.110 cannot
compile them** — by design the requirement produces a clear diagnostic instead
of a cryptic _"undefined identifier `__rvalue`"_:

```
Error Installed dmd-2.110.0 with frontend 2.110 does not comply with
  ... frontend requirement: >=2.111.0
```

`dub` honours the `DC` environment variable, which `ci` inherits, so you can pin
the compiler used for verification:

```bash
# Default: dub picks the first compliant compiler in PATH (LDC here)
nix run .#ci -- --verify --files docs/guidelines/move-semantics/index.md

# Force LDC explicitly
DC=ldc2 nix run .#ci -- --verify --files docs/guidelines/move-semantics/index.md

# Verify against a development DMD that implements the 2.113-era rules
DC=/path/to/dmd/generated/linux/release/64/dmd \
  nix run .#ci -- --verify --files docs/guidelines/move-semantics/index.md
```

---

## Cheat sheet: D move semantics vs C++ / Rust

| Concept              | D                                                                           | C++                          | Rust                                 |
| :------------------- | :-------------------------------------------------------------------------- | :--------------------------- | :----------------------------------- |
| Cast lvalue → rvalue | [`__rvalue(x)`][spec-rvalue-expr]                                           | `std::move(x)`               | moves are implicit (affine types)    |
| Move constructor     | [`this(S rhs)`][spec-struct]                                                | `S(S&&)`                     | (no ctors; `Self` returned by value) |
| Copy constructor     | [`this(ref S rhs)`][spec-copy-ctor]                                         | `S(const S&)`                | `#[derive(Clone)]` / `.clone()`      |
| Move assignment      | [`void opAssign(S)`][spec-opassign]                                         | `operator=(S&&)`             | move on `=`                          |
| Move-only type       | [`@disable this(ref S)`][spec-disable-copy] + move ctor                     | delete copy ctor             | the default (no `Copy`)              |
| Library move         | [`core.lifetime.move`][move-doc]                                            | `std::move` + move ctor      | `std::mem::replace` / `take`         |
| Self-pointer fixup   | in [`this(S)`][spec-struct] body; legacy [`opPostMove`][std-elaborate-move] | rewrite in move ctor         | (forbidden: no self-refs)            |
| Introspection        | [`__traits(hasMoveConstructor, S)`][spec-traits]                            | `std::is_move_constructible` | `T: !Copy` bounds                    |

D's model sits between the two: like C++ it is opt-in per type via constructors
(no automatic ownership transfer), but the moved-from object follows the
"destroy-reset" contract rather than C++'s looser "valid but unspecified" state,
and `__rvalue` is restricted to `@system` contexts to preserve `@safe`'s aliasing
guarantees.

---

## References

**Specification**

- [Struct move constructors][spec-struct] — `spec/struct.dd`
- [Struct copy constructors][spec-copy-ctor] / [postblits](https://dlang.org/spec/struct.html#struct-postblit) — `spec/struct.dd`
- [Rvalue expressions and the `__rvalue` attribute][spec-rvalue-expr] — `spec/expression.dd`
- [`__traits(hasMoveConstructor)`][spec-traits] — `spec/traits.dd`

**Design documents (DIPs)**

- [DIP1018 — The Copy Constructor][dip1018] _(Accepted)_ — replaced the postblit
- [DIP1014 — Hooking D's struct move semantics][dip1014] _(Accepted)_ — introduced `opPostMove`
- [DIP1040 — Copying, Moving, and Forwarding][dip1040] _(Superseded)_ — move constructors & move assignment

**Pull requests**

- [#17050 — add `__rvalue(expression)` builtin][pr-17050]
- [#20585 — returning `__rvalue` should move-construct the NRVO value][pr-20585]
- [#20634 — build default move constructors][pr-20634]
- [#20946 — accept `__rvalue` attribute on `ref` functions][pr-20946]
- [#22112 — call move constructor for `ref __rvalue` returns][pr-22112]
- [#22173 — don't elide fields with elaborate copy/move ctors][pr-22173]
- [#21694 — `__rvalue` ignored with component expressions][pr-21694]

**Issues**

- [#21414 — `__rvalue` must be `@system`][issue-21414]
- [#22111 — `ref`-returning `__rvalue` skipped move construction][issue-22111]

**Library**

- [`core.lifetime.move`][move-doc]

[spec-struct]: https://dlang.org/spec/struct.html#struct-move-constructor
[spec-rvalue-expr]: https://dlang.org/spec/expression.html#RvalueExpression
[spec-traits]: https://dlang.org/spec/traits.html#hasMoveConstructor
[spec-copy-ctor]: https://dlang.org/spec/struct.html#struct-copy-constructor
[spec-opassign]: https://dlang.org/spec/operatoroverloading.html#assignment
[spec-disable-copy]: https://dlang.org/spec/struct.html#disable-copy
[std-elaborate-move]: https://dlang.org/phobos/std_traits.html#hasElaborateMove
[move-doc]: https://dlang.org/phobos/core_lifetime.html#.move
[dip1014]: https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1014.md
[dip1018]: https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1018.md
[dip1040]: https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1040.md
[issue-20970]: https://github.com/dlang/dmd/issues/20970
[toolchain-req]: https://dub.pm/dub-reference/package_settings/#toolchainrequirements
[pr-17050]: https://github.com/dlang/dmd/pull/17050
[pr-20585]: https://github.com/dlang/dmd/pull/20585
[pr-20634]: https://github.com/dlang/dmd/pull/20634
[pr-20946]: https://github.com/dlang/dmd/pull/20946
[pr-22112]: https://github.com/dlang/dmd/pull/22112
[pr-22173]: https://github.com/dlang/dmd/pull/22173
[pr-21694]: https://github.com/dlang/dmd/pull/21694
[issue-21414]: https://github.com/dlang/dmd/issues/21414
[issue-22111]: https://github.com/dlang/dmd/issues/22111

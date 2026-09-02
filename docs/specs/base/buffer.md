# `sparkles.base.buffer` — Specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative and self-contained — it states which storage policies a
buffer may have, how elements get into one that cannot grow, and how the
C-string layer is built on top. `sparkles.base.text.cstring` and
`sparkles.base.text.writers` are specified here only where they touch the buffer
contract. For the library overview see
[`sparkles:base`](../../libs/base/index.md)._

## 1. Overview

A buffer holds a growable sequence of `T` without reaching for the collected
heap. Two properties vary independently, and naming them separately is the
point of this design:

- **Residency** — may the elements live in the inline `T[N]`, on the heap, or
  either? A buffer that may not allocate has a guarantee no other form can
  offer; a buffer with no inline array does not carry `N` elements' worth of
  dead weight in every copy of the struct.
- **Sharing** — is a copy a second handle on the same storage, or forbidden
  outright? Disabling copies is what makes the grow path refcount-free.

`Buffer` takes both as one flag set. Four aliases name the combinations worth
naming; the raw form is for generic code and the two rarer policies.

| Identifier      | Value                          |
| --------------- | ------------------------------ |
| Dub sub-package | `sparkles:base`                |
| Source root     | `libs/base/src/sparkles/base/` |
| Module          | `sparkles.base.buffer`         |

## 2. API surface

```d
/// What storage a buffer may use, and whether it may be copied.
enum Storage : ubyte
{
    none   = 0,      /// the empty set — not a valid policy on its own
    inline = 1 << 0, /// may hold elements in the inline `T[N]`
    heap   = 1 << 1, /// may allocate
    unique = 1 << 2, /// move-only: copying is disabled
}

struct Buffer(T, size_t N, Storage storage = Storage.inline | Storage.heap)
if (storage & (Storage.inline | Storage.heap));

// `extra` is the ownership axis only: a residency bit there is rejected.
template InlineBuffer(T, size_t N, Storage extra = Storage.none) if (!(extra & ~Storage.unique))
    { alias InlineBuffer = Buffer!(T, N, Storage.inline | extra); }
template HeapBuffer(T, Storage extra = Storage.none) if (!(extra & ~Storage.unique))
    { alias HeapBuffer = Buffer!(T, 0, Storage.heap | extra); }
alias SharedBuffer(T, size_t N) = Buffer!(T, N, Storage.inline | Storage.heap);
alias UniqueBuffer(T, size_t N) = Buffer!(T, N, Storage.inline | Storage.heap | Storage.unique);

/// Bounded writing into storage that cannot grow.
struct BoundedSink(T);

T[] tryWrite(T)(return T[] dest,
    scope void delegate(scope ref BoundedSink!T) @safe pure nothrow @nogc fn)
    @safe pure nothrow @nogc;
T[] tryWrite(T, Dg)(return T[] dest, scope Dg fn);
```

## 3. Storage policies (`BUF`)

The bits are capabilities, so the combination _is_ the policy. `Storage.none`
exists as the empty set — the neutral default for an alias's `extra` parameter,
and the value to mask against — but a buffer with neither storage bit has
nowhere to put anything and fails the template constraint.

| Policy                     | Alias                                 | Elements live     | A copy is                        |
| -------------------------- | ------------------------------------- | ----------------- | -------------------------------- |
| `inline`                   | `InlineBuffer!(T, N)`                 | inline only       | an independent copy of the bytes |
| `inline \| unique`         | `InlineBuffer!(T, N, Storage.unique)` | inline only       | disabled                         |
| `inline \| heap`           | `SharedBuffer!(T, N)`                 | inline, then heap | a second handle, cloned on write |
| `inline \| heap \| unique` | `UniqueBuffer!(T, N)`                 | inline, then heap | disabled                         |
| `heap`                     | `HeapBuffer!T`                        | heap only         | a second handle, cloned on write |
| `heap \| unique`           | `HeapBuffer!(T, Storage.unique)`      | heap only         | disabled                         |

`N` means one thing everywhere: the inline capacity. It is not a limit for a
policy carrying `Storage.heap`, and it must be `0` for a policy without
`Storage.inline` — `HeapBuffer` supplies that zero. A heap-only buffer is sized
up front with `reserve`, not with `N`.

`SharedBuffer` shares _storage_, not _value_. A write through one copy clones
the block first, so it is invisible to the others; copies behave as independent
values. This is unlike `shared_ptr`, where a mutation propagates.

### Requirements

| ID      | Requirement                                                                                                                                                                                                                                     | Status  |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `BUF1`  | `Buffer` must take residency and sharing as one `Storage` flag set, so the two are independently selectable and every combination is spellable.                                                                                                 | decided |
| `BUF2`  | A policy with neither `Storage.inline` nor `Storage.heap` must fail to instantiate.                                                                                                                                                             | full    |
| `BUF3`  | `N` must be `0` when `Storage.inline` is absent, enforced at compile time. `N` must never mean anything other than inline capacity.                                                                                                             | full    |
| `BUF4`  | A policy without `Storage.inline` must hold no inline array, so the struct costs one slice regardless of `N`.                                                                                                                                   | full    |
| `BUF5`  | A policy without `Storage.heap` must never allocate, and must have no destructor — it is plain data.                                                                                                                                            | full    |
| `BUF6`  | A policy without `Storage.heap` must store its elements in a plain `T[N]` field rather than a union, so that `-dip1000` rejects escaping a slice or pointer derived from a local.                                                               | full    |
| `BUF7`  | `Storage.unique` must disable copy construction and copy assignment, and must remove the reference count from the grow path.                                                                                                                    | full    |
| `BUF8`  | Without `Storage.unique`, a copy must share heap storage and clone it before a mutation, so copies behave as independent values.                                                                                                                | full    |
| `BUF9`  | Inline storage must be default-initialised when `T` has indirections, so a conservative scan never follows a garbage pointer in an untouched slot; it may be `= void` otherwise. Either way, capacity beyond `length` is not part of the value. | full    |
| `BUF10` | `opEquals` must compare `this[]` against `rhs[]`, so equality is content equality across every policy and never reads capacity beyond `length`.                                                                                                 | full    |
| `BUF11` | `reserve` must allocate on a buffer that is not yet on the heap, since that is the only way to size a `HeapBuffer` before use.                                                                                                                  | full    |
| `BUF12` | The four aliases must be the documented entry points; the raw `Buffer!(T, N, flags)` form is for generic code and the two policies without an alias.                                                                                            | decided |
| `BUF13` | A policy without `Storage.inline` must keep its heap block across `popBack`, a shrinking `length`, and `clear`; the block is released only by the destructor or transferred by `toShared`, so one `reserve` serves every reuse.                 | full    |

## 4. Bounded writing (`WRT`)

`put` promises to accept what it is given. A buffer that may not allocate cannot
keep that promise, so it is **not an output range**: `put` and `~=` are absent
exactly when `Storage.heap` is unset.

Such a buffer is written through a bracketed call instead. `tryWrite` marks the
length, runs the callback against a bounded sink, and rolls back if the callback
produced more than fits — so a failed write leaves the destination byte-for-byte
unchanged rather than truncated.

```d
if (auto path = buf[].tryWrite((scope ref BoundedSink!char w) {
        w.put("/proc/"); w.writeValue(pid); w.put("/status");
    }))
    return openAt(path.ptr);
return err(ENAMETOOLONG);
```

The result is the written slice, or `null` on overflow. A successful **empty**
write returns `dest[0 .. 0]`, whose pointer is `dest.ptr` and which is therefore
not `null` — that is what distinguishes "wrote nothing" from "did not fit".

`return` on `dest` ties the result's lifetime to the destination, so `-dip1000`
rejects returning the written slice out of a function whose buffer is a local.

Because `BoundedSink` _is_ an output range, the whole
`sparkles.base.text.writers` family reaches a fixed buffer through it unchanged.

### Requirements

| ID     | Requirement                                                                                                                                                                                                                                                                                                     | Status |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `WRT1` | A policy without `Storage.heap` must not expose `put` or `~=`, and must not satisfy `isOutputRange`.                                                                                                                                                                                                            | full   |
| `WRT2` | `BoundedSink!T` must satisfy `isOutputRange!(BoundedSink!T, T)` and must accept both a single element and a slice.                                                                                                                                                                                              | full   |
| `WRT3` | `tryWrite` must return the written slice on success and `null` on overflow. Over a raw slice the bytes left in `dest` are unspecified — the sink writes into it directly, so `null` is the only signal. `Buffer.tryWrite` must be transactional: it restores `length`, and a buffer's value is `[0 .. length]`. | full   |
| `WRT4` | A successful write of nothing must return a non-`null`, zero-length slice. This distinction must be stated wherever `tryWrite` is documented.                                                                                                                                                                   | full   |
| `WRT5` | `dest` must be declared `return`, so `-dip1000` rejects escaping the result past the destination's lifetime.                                                                                                                                                                                                    | full   |
| `WRT6` | `tryWrite` must be usable from `@safe pure nothrow @nogc` code with a callback that captures locals. A second overload with a deduced delegate type must accept callbacks that are not all four.                                                                                                                | full   |
| `WRT7` | `Buffer.tryWrite` must exist as a member wrapper that appends at the current length and takes a callback of the form `(ref w)`.                                                                                                                                                                                 | full   |
| `WRT8` | Overflow must be observable only through `tryWrite`'s result; a partially written sink must not be reachable by a caller.                                                                                                                                                                                       | full   |

## 5. Owned temporaries (`TMP`)

`TempBuffer` owns its storage and is meant to be built and consumed inside one
expression — the shape a C API call wants.

```d
struct TempBuffer(T, size_t N, sentinel...)
if (sentinel.length <= 1 && (sentinel.length == 0 || is(typeof(sentinel[0]) : T)));

alias TempStringz(size_t N = 256) = TempBuffer!(char, N, '\0');
```

The sentinel is one optional compile-time value, so "has a sentinel" and "which
sentinel" cannot disagree. It must be written explicitly: `T.init` is unusable
as a default, because `char.init` is `0xFF` rather than `'\0'` (§7).

**Read the pointer inside the expression that created the buffer.** A temporary
is destroyed at the end of the full expression — after the call it was passed
to — so `SetWindowTitle(title.toTempStringz.ptr)` is sound. Binding the pointer
to a variable ends that expression and leaves it dangling:

```d
auto p = title.toTempStringz.ptr;   // wrong: the buffer is already gone
```

That compiles, is `@safe`, and nothing diagnoses it: `-dip1000` reasons about
escapes, not about when a destructor runs. To keep a C string past one
expression, name the buffer — `auto z = title.toTempStringz;` — which makes it
an ordinary local.

### Requirements

| ID     | Requirement                                                                                                                                                                                                                              | Status  |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `TMP1` | `TempBuffer` must take at most one sentinel as a compile-time value, and must reject two.                                                                                                                                                | full    |
| `TMP2` | `TempBuffer` must not be default-constructible and must not be copyable, so exactly one owner frees the storage.                                                                                                                         | full    |
| `TMP3` | `TempBuffer` must own a `UniqueBuffer!(T, N)`: inline while the value fits, heap when it does not.                                                                                                                                       | full    |
| `TMP4` | `ptr` must be recomputed from `this` on each call, never cached, so a by-value return remains correct after the move.                                                                                                                    | full    |
| `TMP5` | The documentation must state that the pointer is valid only within the full expression that created the buffer, that binding it to a variable is undiagnosed, and that naming the buffer is the supported way to outlive the expression. | full    |
| `TMP6` | `TempStringz(N)` must be an alias for `TempBuffer!(char, N, '\0')`.                                                                                                                                                                      | decided |

## 6. C strings (`CST`)

`sparkles.base.text.cstring` sits on top of this module. `CString!N` is an
`InlineBuffer!(char, N)` plus a NUL invariant, rather than a separate
hand-rolled `char[N]`.

Which tool to reach for is one question: **is overflow a condition to report, or
input to accommodate?**

| Need                                                                         | Use                                |
| ---------------------------------------------------------------------------- | ---------------------------------- |
| overflow must be reported — a path past `PATH_MAX`, a name that will not fit | `CString!N` + `tryToCString`       |
| overflow is a programmer error at a size you chose                           | `CString!N` + `toCString`          |
| the input is someone else's text of no bounded length                        | `toTempStringz`                    |
| a C string that already exists elsewhere                                     | `CStr`, `cstr`, `CStr.fromStringz` |

### Requirements

| ID     | Requirement                                                                                                                                                                                         | Status |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `CST1` | `CString!N` must be implemented over `InlineBuffer!(char, N)` and must not declare its own raw array.                                                                                               | full   |
| `CST2` | `CString!N` must guarantee a terminator at `N - 1` or earlier, and `ptr` must never be `null`.                                                                                                      | full   |
| `CST3` | `CString` must inherit `BUF6`: `-dip1000` must reject escaping its slice or pointer from a `@safe` function.                                                                                        | full   |
| `CST4` | `toCString` must treat overflow as a programmer error; `tryToCString` must report it without writing.                                                                                               | full   |
| `CST5` | `CStr` must be the borrowed form — a pointer and the length before the terminator — and must appear in no D signature as a parameter; D APIs take `string` or `in char[]` and terminate internally. | full   |
| `CST6` | `stringz` must terminate a buffer that outlives the call and must be idempotent.                                                                                                                    | full   |

## 7. Mechanism proofs

The examples below are **not** API usage. Each is a self-contained program that
demonstrates a language property this design depends on, so the claims above are
checked rather than asserted.

**Escape rejection is a property of the layout, not of the type** (`BUF6`).
Dropping the union is what makes the elements provably frame-derived:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "buffer_escape_rejection"
    dependency "sparkles:base" version="*"
    dflags "-preview=in" "-preview=dip1000"
+/
import std.stdio : writeln;

// Stand-ins for the three layouts in §3.
struct InlineOnly(T, size_t N)
{
    private T[N] _inline;
    private size_t _length;
    const(T)[] opSlice() const return scope @safe => _inline[0 .. _length];
}

struct SmallBufferOptimized(T, size_t N)
{
    private union { T[N] _inline; T[] _block; }
    private size_t _length;
    const(T)[] opSlice() const return scope @trusted
        => _length > N ? _block[0 .. _length] : _inline[0 .. _length];
}

struct HeapOnly(T)
{
    private T[] _block;
    private size_t _length;
    const(T)[] opSlice() const return scope @safe => _block[0 .. _length];
}

enum rejects(alias Buf) = !__traits(compiles, {
    const(char)[] leak() @safe { Buf b; return b[]; }
});

void main()
{
    writeln("inline only : escape rejected = ", rejects!(InlineOnly!(char, 8)));
    writeln("inline+heap : escape rejected = ", rejects!(SmallBufferOptimized!(char, 8)));
    writeln("heap only   : escape rejected = ", rejects!(HeapOnly!char));
}
```

```ansi
inline only : escape rejected = true
inline+heap : escape rejected = false
heap only   : escape rejected = false
```

**Overflow is distinguishable from an empty write** (`WRT3`, `WRT4`), and
`@nogc` survives a capturing callback (`WRT6`):

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "buffer_try_write"
    dependency "sparkles:base" version="*"
    dflags "-preview=in" "-preview=dip1000"
+/
import std.stdio : writeln;

struct BoundedSink(T)
{
    private T[] _dest;
    private size_t _length;
    private bool _overflowed;

    void put(T v) @safe pure nothrow @nogc
    {
        if (_length >= _dest.length) { _overflowed = true; return; }
        _dest[_length++] = v;
    }
    void put(scope const(T)[] s) @safe pure nothrow @nogc { foreach (v; s) put(v); }
}

T[] tryWrite(T)(return T[] dest,
    scope void delegate(scope ref BoundedSink!T) @safe pure nothrow @nogc fn)
    @safe pure nothrow @nogc
{
    scope sink = BoundedSink!T(dest);
    fn(sink);
    return sink._overflowed ? null : dest[0 .. sink._length];
}

/// Captures `n`, and stays `@nogc`.
char[] label(return char[] dest, int n) @safe pure nothrow @nogc
{
    return dest.tryWrite((scope ref BoundedSink!char w) {
        w.put("cpu");
        char[4] d; size_t i;
        int v = n;
        if (v == 0) d[i++] = '0';
        while (v > 0) { d[i++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (j; 0 .. i) w.put(d[j]);
    });
}

void main() @safe
{
    char[16] room;
    auto ok = label(room[], 7);
    string shown; foreach (c; ok) shown ~= c;
    writeln("fits      : ", shown, " (null? ", ok is null, ")");

    char[2] tight;
    auto bad = label(tight[], 7);
    writeln("overflow  : null? ", bad is null, ", length ", bad.length);

    char[4] blank;
    auto none = blank[].tryWrite((scope ref BoundedSink!char w) {});
    writeln("wrote none: null? ", none is null, ", length ", none.length);
}
```

```ansi
fits      : cpu7 (null? false)
overflow  : null? true, length 0
wrote none: null? false, length 0
```

**`T.init` is not a usable default sentinel** (`TMP1`). `char.init` is `0xFF`,
an invalid UTF-8 byte, so a defaulted sentinel would terminate nothing:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "buffer_sentinel_default"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln;

void main()
{
    writefln("char.init  = 0x%02X, is NUL? %s", cast(ubyte) char.init, char.init == '\0');
    writefln("int.init   = %s", int.init);
}
```

```ansi
char.init  = 0xFF, is NUL? false
int.init   = 0
```

## 8. Verification

```bash
dub test :base                        # unit tests, including the escape static asserts
dub test :base -- --better-c          # the policies usable without druntime
nix run .#ci -- --verify --files docs/specs/base/buffer.md
```

Each requirement above that concerns a compile-time rejection — `BUF2`, `BUF3`,
`BUF6`, `BUF7`, `WRT1`, `WRT5`, `TMP1`, `TMP2`, `CST3` — must be pinned by a
`static assert(!__traits(compiles, …))` in the module, so that relaxing it fails
the build rather than the review.

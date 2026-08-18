/**
Building C strings without the GC.

Two destinations, because that is the only axis the call sites actually differ
on:

$(UL
$(LI $(LREF writeStringz) appends to an output range the caller already owns —
    a `SmallBuffer`, or a scratch buffer reused across frames. It grows.)
$(LI $(LREF CString) is a fixed `char[N]` that owns its bytes, built by
    $(LREF toCString) when the input is known to fit and by
    $(LREF tryToCString) when it is not.)
)

$(B Why the parts are an array literal) — `toCString!64([dir, "/", name])`
rather than `toCString!64(dir, "/", name)`. Both variadic spellings fail where
it matters. A template tuple (`scope Parts parts`) instantiates once per
distinct type tuple, and `string` and `char[]` are distinct types. A typesafe
variadic (`scope const(char)[][] parts...`) is worse: building its implicit
array takes the address of the `scope` data, which `-dip1000` rejects in `@safe`
code — so with `-preview=in` in force, where `in char[]` $(I is)
`scope const(char)[]`, it turns away the ordinary caller. Writing the `[]`
explicitly makes the literal a temporary bound to a `scope` parameter, which
`@safe` accepts. The cost is the two brackets, and that a lone `char` separator
has to be spelled `"/"` rather than `'/'`.

$(B Why a type rather than a bare `char[N]`.) A caller handed the raw buffer
has two ways to get it quietly wrong: omitting `= void`, which turns a 4 KiB
builder into a 4 KiB `memset` on every call, and mishandling a nullable
`const(char)*` result — `dlopen(null, …)` does not fault, it returns a handle
to the main program. $(LREF CString) makes neither representable: the `= void`
is inside it, and $(LREF CString.ptr) never returns `null`.

It lives in `sparkles:base` because it is the bottom of the C-interop stack and
cannot live any higher — `sparkles.base.hw_caps` open-codes it already. It lives
under `text/` rather than beside `SmallBuffer` because it is a text-encoding
concern that merely $(I uses) a buffer, like the `readers`/`writers` beside it.

This module does $(B not) own:

$(UL
$(LI $(B The read direction.) `std.string.fromStringz` has an array overload —
    `fromStringz(inout(Char)[])` — that slices a fixed-size C `char[N]` field at
    its first NUL and is `@safe @nogc pure nothrow`. Use it; note that writing
    `field.ptr.fromStringz` instead picks the `@system` pointer overload and
    gives up `@safe` for nothing.)
$(LI $(B C strings that outlive the call.) Those need the GC or an explicit
    anchor; use `std.string.toStringz`.)
$(LI $(B Encoding conversion.) UTF-8 bytes in, the same bytes plus a NUL out.)
$(LI $(B Path semantics.) It concatenates bytes; it does not know what a
    separator is.)
)
*/
module sparkles.base.text.cstring;

import std.range.primitives : put;

import sparkles.test_runner.attributes : betterC;

// The runner extracts a `@betterC` test body and compiles it standalone against
// the module's public API, so a test is marked only when it needs neither
// `SmallBuffer` (which would drag `std.experimental.allocator` in) nor a
// private symbol. That excludes the `writeStringz` trio and the `cStringBytes`
// test; everything reaching `CString` qualifies, since it is a plain `char[N]`.
// Everything here copies element-wise rather than by slice assignment for the
// same reason: `dest[a .. b] = src[]` lowers to druntime's
// `_d_array_slice_copy`. LDC turns the loops back into `memcpy`, so the only
// thing given up is the runtime dependency.

/**
Appends `s` and a terminating NUL to `w`.

The C string is then the writer's bytes; take `.ptr` off them yourself, in your
own `@trusted` block, because only you know whether the callee retains it.

Declared $(I before) this module's attribute label so its attributes are
inferred from `Writer`, the same convention every template in
`sparkles.base.text.writers` follows: a `@nogc` writer keeps the call `@nogc`,
and a writer that allocates is still accepted.

An interior NUL in `s` is copied verbatim, so the C string it produces stops
there. Nothing in this module scans for that: every consumer in this repository
passes either a literal, a path it built itself, or text that a NUL cannot reach
(the terminal's URL scan treats `'\0'` as a boundary). Where a caller does need
the check it is one `canFind('\0')`, at that call site rather than a pass on
every build.
*/
void writeStringz(Writer)(ref Writer w, in char[] s)
{
    put(w, s);
    put(w, '\0');
}

///
@("text.cstring.writeStringz.appendsTerminator")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    buf.writeStringz("abc");
    assert(buf[] == "abc\0");
}

@("text.cstring.writeStringz.emptyIsJustTheTerminator")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 8) buf;
    buf.writeStringz("");
    assert(buf[] == "\0");
}

@("text.cstring.writeStringz.appendsToExistingContent")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // The borrowed-scratch sites reuse one buffer, so the writer must append
    // rather than assume it starts empty.
    SmallBuffer!(char, 32) buf;
    buf ~= "keep";
    buf.writeStringz("more");
    assert(buf[] == "keepmore\0");
}

@safe pure nothrow @nogc:

// Bytes `parts` needs as one C string: the sum of their lengths, plus the NUL.
// Private: both callers are in this module, and a public one would be surface
// nothing outside asks for.
private size_t cStringBytes(scope const(char)[][] parts)
{
    size_t n = 1; // the terminator
    foreach (p; parts)
        n += p.length;
    return n;
}

// Not `@betterC`: the runner extracts a test body and compiles it against the
// module's public API, which this helper is deliberately not part of.
@("text.cstring.cStringBytes.countsPartsPlusTerminator")
unittest
{
    assert(cStringBytes(["abc"]) == 4);
    assert(cStringBytes(["ab", "c"]) == 4);
    assert(cStringBytes([""]) == 1);
    assert(cStringBytes([]) == 1);

    // CTFE, which is what sizes an `N` at a call site.
    static assert(cStringBytes(["/sys/fs/cgroup", "/cpu.max"]) == 23);
}

/**
A C string in a fixed `char[N]` — `N` counting the terminator. Build it with
$(LREF toCString) or $(LREF tryToCString).

$(B Lifetime.) $(LREF ptr) and $(LREF opSlice) are $(I borrowed): they address
this object, so they are valid only while it is alive and at its current
address. Unlike most such contracts, this one is $(B enforced). The buffer is a
plain `char[N]`, so a borrow out of it is a reference to the enclosing frame,
and returning one from a `@safe` function is a compile error — checked against
LDC 1.41 for the slice, the pointer, and the pointer off an rvalue.

That is why the storage is a fixed array rather than a `SmallBuffer`. A borrow
out of a small buffer addresses whatever its heap block points at, which the
compiler cannot prove is the frame, so it must permit the escape; recovering the
check would mean every caller remembering to write `scope`. Here it holds with
nothing written at the call site.

Being plain bytes, it copies — a copy owns its own buffer, and `ptr` on the copy
addresses the copy. A pointer taken before a copy or move still refers to the
original, so re-read `ptr` rather than caching it across one.

$(B Capacity is fixed) and `N` is the caller's choice, so $(LREF toCString)
treats exceeding it as a programmer error. Where the input is sized at runtime,
$(LREF tryToCString) reports it instead.
*/
struct CString(size_t N = 256)
if (N >= 1)
{
    // `= void`: a 4 KiB builder on a hot path should not memset itself, and
    // keeping the decision in here is half the reason this is a type at all.
    // Only `_data[0 .. _len]` and the terminator at `_data[_len]` are ever
    // read, and `ptr` answers from static storage while `_len` is 0.
    private char[N] _data = void;
    private size_t _len;

    private static immutable char[1] _emptyZ = "\0";

    /// Bytes, excluding the terminator.
    size_t length() const scope => _len;

    /// The C string. $(B Never `null`) — a default-constructed `CString`, and
    /// one left behind by a failed $(LREF tryToCString), both read `""`. That
    /// is deliberate: a caller who skips the check gets an empty string, which
    /// a C callee rejects, rather than a null a callee may silently accept
    /// (`dlopen(null, …)` returns a handle to the main program).
    ///
    /// `@trusted` for the `.ptr`, which is sound locally — `_data[_len]` is the
    /// terminator whenever `_len` is non-zero, and the empty branch answers
    /// from static storage rather than reading `= void` bytes.
    const(char)* ptr() const return scope @trusted
        => _len == 0 ? _emptyZ.ptr : _data.ptr;

    /// The bytes as a D slice, excluding the terminator.
    const(char)[] opSlice() const return scope => _data[0 .. _len];
}

/**
Builds a $(LREF CString) from the concatenation of `parts`, for input known to
fit.

---
auto path = toCString!512(["/sys/fs/cgroup", rel, "/cpu.max"]);
const fd = open(path.ptr, O_RDONLY);
---

Exceeding `N` is a programmer error — `N` is yours to choose — so it is an `in`
contract, with `@safe` bounds checks on `_data` as the backstop that outlives
`-release`. When the input is sized at runtime and overflow is a condition to
handle rather than a bug, use $(LREF tryToCString).

Bind the result to a variable before taking `.ptr`. `toCString(x).ptr` as a
sub-expression would address a dead temporary — and unlike most such traps,
`-dip1000` rejects it.
*/
CString!N toCString(size_t N = 256)(scope const(char)[][] parts)
in (cStringBytes(parts) <= N, "toCString: parts exceed N bytes")
{
    CString!N r;
    foreach (p; parts)
        foreach (c; p)
            r._data[r._len++] = c;
    r._data[r._len] = '\0';
    return r;
}

/**
Fills `dest` with the concatenation of `parts`, returning `false` — leaving
`dest` empty — when they exceed `N`.

Destination-first, matching `writeX(ref Writer w, …)`, and `N` is deduced from
`dest` so it is not spelled twice:

---
CString!4096 zpath;
if (!tryToCString(zpath, [dir, "/", name]))
    return err(ENAMETOOLONG);
const fd = open(zpath.ptr, O_RDONLY);
---

`out` rather than a return value on purpose. A caller who ignores the `bool`
still holds a `CString` reading `""`, so the mistake surfaces as `ENOENT` from
the callee rather than as a null pointer handed to C.
*/
bool tryToCString(size_t N)(out CString!N dest, scope const(char)[][] parts)
{
    if (cStringBytes(parts) > N)
        return false;

    foreach (p; parts)
        foreach (c; p)
            dest._data[dest._len++] = c;
    dest._data[dest._len] = '\0';
    return true;
}

///
@("text.cstring.toCString.roundTrip")
@betterC
unittest
{
    auto z = toCString!16(["abc"]);
    assert(z.length == 3);
    assert(z[] == "abc");
    assert((() @trusted => z.ptr[z.length])() == '\0');
}

@("text.cstring.toCString.joinsParts")
@betterC
unittest
{
    // The shape hw_caps and capability build by hand: a path join. A lone
    // `char` separator is spelled "/" — the cost of the array literal.
    auto z = toCString!32(["/sys", "/fs", "/", "cgroup"]);
    assert(z[] == "/sys/fs/cgroup");
    assert((() @trusted => z.ptr[z.length])() == '\0');
}

@("text.cstring.toCString.exactFit")
@betterC
unittest
{
    // N counts the terminator, so `N - 1` payload bytes is the boundary.
    auto z = toCString!4(["abc"]);
    assert(z[] == "abc");
    assert((() @trusted => z.ptr[3])() == '\0');
}

@("text.cstring.toCString.overflowIsAContractViolation")
@system
unittest
{
    // `toCString` is for input known to fit, so exceeding N must fail loudly
    // rather than truncate. Under `-release`, where the `in` contract is gone,
    // the `@safe` bounds check on `_data` is the backstop — it traps either
    // way. try/catch rather than `collectException`: the module's attribute
    // label makes this test `nothrow @nogc`, and catching is what satisfies it.
    bool threw;
    try
        cast(void) toCString!4(["abcd"]);
    catch (Error)
        threw = true;
    assert(threw, "exceeding N must not be silent");
}

///
@("text.cstring.tryToCString.reportsOverflow")
@betterC
unittest
{
    CString!8 z;
    assert(tryToCString(z, ["abc", "/", "d"]));   // N deduced from `z`
    assert(z[] == "abc/d");

    CString!4 tooSmall;
    assert(!tryToCString(tooSmall, ["abcd"]));
}

@("text.cstring.tryToCString.ignoredResultIsEmptyNotNull")
@betterC
unittest
{
    // The reason this takes an `out` parameter. A caller who drops the `bool`
    // is left holding a valid empty C string, so the callee reports ENOENT
    // rather than being handed a null it may silently accept.
    CString!4 z;
    cast(void) tryToCString(z, ["far too long for four bytes"]);
    assert(z.length == 0);
    assert(z.ptr !is null);
    assert((() @trusted => z.ptr[0])() == '\0');
}

@("text.cstring.CString.defaultIsEmptyString")
@betterC
unittest
{
    // Reads from static storage, never from the `= void` bytes.
    CString!8 z;
    assert(z.length == 0);
    assert(z.ptr !is null);
    assert((() @trusted => z.ptr[0])() == '\0');
    assert(z[].length == 0);
}

@("text.cstring.CString.emptyStringIsNotDefault")
@betterC
unittest
{
    auto z = toCString!8([""]);
    assert(z.length == 0);
    assert((() @trusted => z.ptr[0])() == '\0');

    auto none = toCString!8([]);
    assert(none.length == 0);
    assert((() @trusted => none.ptr[0])() == '\0');
}

@("text.cstring.CString.pointerStableAcrossReads")
@betterC
unittest
{
    // Regression guard: `ptr` and `opSlice` must keep answering from the same
    // storage, so neither can be changed into something that relocates bytes.
    auto z = toCString!16(["abc"]);
    assert(z.ptr is z.ptr);
    assert(z.ptr is z[].ptr);
}

@("text.cstring.CString.copyOwnsItsBytes")
unittest
{
    // Plain bytes, so a copy is independent — no refcount, no shared block.
    // Its `ptr` addresses the copy, which is why a cached pointer must not be
    // carried across one.
    auto a = toCString!32(["abc"]);
    auto b = a;
    assert(b[] == "abc");
    assert(b.ptr !is a.ptr);
}

@("text.cstring.CString.borrowContractIsEnforced")
unittest
{
    // The payoff for a fixed `char[N]`: `-dip1000` rejects every route out of a
    // dead local, with no `scope` written at the call site. A SmallBuffer-backed
    // version could only manage this if every caller remembered `scope`, because
    // a borrow out of it is not provably a reference to the frame.
    static assert(!__traits(compiles, {
        const(char)[] leak() @safe pure nothrow @nogc
        {
            auto z = toCString!64(["x"]);
            return z[];
        }
    }), "dip1000 should reject escaping the slice");

    static assert(!__traits(compiles, {
        const(char)* leak() @safe pure nothrow @nogc
        {
            auto z = toCString!64(["x"]);
            return z.ptr;
        }
    }), "dip1000 should reject escaping the pointer");

    static assert(!__traits(compiles, {
        const(char)* leak() @safe pure nothrow @nogc => toCString!64(["x"]).ptr;
    }), "dip1000 should reject escaping the pointer off an rvalue");

    // ... and the same holds for the out-parameter form.
    static assert(!__traits(compiles, {
        const(char)* leak() @safe pure nothrow @nogc
        {
            CString!64 z;
            cast(void) tryToCString(z, ["x"]);
            return z.ptr;
        }
    }), "dip1000 should reject escaping out of tryToCString's destination");

    // Contrast, so the test says what the guarantee is worth: dip1000 catches
    // the same shape on a bare static array, and does not on a SmallBuffer.
    static assert(!__traits(compiles, {
        const(char)[] leak() @safe pure nothrow @nogc
        {
            char[8] local = void;
            return local[];
        }
    }));
}

@("text.cstring.CString.acceptsScopeParts")
unittest
{
    // The property the array literal exists for: a `scope` slice — which is
    // what `-preview=in` makes of every `in char[]` parameter — must reach both
    // builders from `@safe` code. Both variadic spellings fail this.
    static assert(__traits(compiles, (scope const(char)[] a, scope const(char)[] b)
        @safe pure nothrow @nogc {
            auto z = toCString!128([a, "/", b]);
            return z.length;
        }));

    static assert(__traits(compiles, (scope const(char)[] a, scope const(char)[] b)
        @safe pure nothrow @nogc {
            CString!128 z;
            return tryToCString(z, [a, "/", b]);
        }));
}

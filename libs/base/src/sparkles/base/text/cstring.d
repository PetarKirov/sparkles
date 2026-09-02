/**
Building C strings without the GC.

Two destinations, because that is the only axis the call sites actually differ
on:

$(UL
$(LI $(LREF writeStringz) appends to an output range the caller already owns —
    a `SharedBuffer`, or a scratch buffer reused across frames. It grows.)
$(LI $(LREF CString) is a fixed `char[N]` that owns its bytes, built by
    $(LREF toCString) when the input is known to fit and by
    $(LREF tryToCString) when it is not.)
)

$(LREF CStr) is the $(B read) direction, in the sense Rust splits `CString` from
`&CStr`: a pointer plus the length before the terminator, owning nothing. It is
for C strings that already exist somewhere else — one a C library handed back,
or one a caller built into a buffer it still owns. It deliberately does $(B not)
appear in this repository's own signatures: a D API takes `string` or
`in char[]` and terminates internally, so a caller cannot supply an
unterminated pointer because it never supplies a pointer at all.

$(LREF stringz) is the bridge from the growing side. Where $(LREF CString)'s
capacity is fixed and known, a `SharedBuffer` grows to whatever it was given —
which is what an unbounded caller-supplied string needs — and `stringz` hands
back the $(LREF CStr) over its bytes, appending the terminator if it is not
already there.

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
under `text/` rather than beside `SharedBuffer` because it is a text-encoding
concern that merely $(I uses) a buffer, like the `readers`/`writers` beside it.

This module does $(B not) own:

$(UL
$(LI $(B Decoding a C string back into D text.) `std.string.fromStringz` has an
    array overload — `fromStringz(inout(Char)[])` — that slices a fixed-size C
    `char[N]` field at its first NUL and is `@safe @nogc pure nothrow`. Use it;
    note that writing `field.ptr.fromStringz` instead picks the `@system`
    pointer overload and gives up `@safe` for nothing. $(LREF CStr) is the
    complement, not a replacement: it keeps a pointer $(I as) a C string for
    handing onward, where `fromStringz` converts one into a D slice.)
$(LI $(B C strings that outlive the call.) Those need the GC or an explicit
    anchor; use `std.string.toStringz`.)
$(LI $(B Encoding conversion.) UTF-8 bytes in, the same bytes plus a NUL out.)
$(LI $(B Path semantics.) It concatenates bytes; it does not know what a
    separator is.)
)
*/
module sparkles.base.text.cstring;

import std.range.primitives : put;

import sparkles.base.buffer : BoundedSink, Buffer, InlineBuffer, SharedBuffer, UniqueBuffer, tryWrite;

import sparkles.test_runner.attributes : betterC;

// The runner extracts a `@betterC` test body and compiles it standalone against
// the module's public API, so a test is marked only when it needs neither
// `SharedBuffer` (which would drag `std.experimental.allocator` in) nor a
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
    SharedBuffer!(char, 32) buf;
    buf.writeStringz("abc");
    assert(buf[] == "abc\0");
}

@("text.cstring.writeStringz.emptyIsJustTheTerminator")
@safe pure nothrow @nogc
unittest
{
    SharedBuffer!(char, 8) buf;
    buf.writeStringz("");
    assert(buf[] == "\0");
}

@("text.cstring.writeStringz.appendsToExistingContent")
@safe pure nothrow @nogc
unittest
{
    // The borrowed-scratch sites reuse one buffer, so the writer must append
    // rather than assume it starts empty.
    SharedBuffer!(char, 32) buf;
    buf ~= "keep";
    buf.writeStringz("more");
    assert(buf[] == "keepmore\0");
}

/**
The C string held by `buf` — appending the terminator if it is not already
there.

---
SharedBuffer!(char, 256) path;
path ~= dir; path ~= "/"; path ~= name;
const fd = open(path.stringz.ptr, O_RDONLY);
---

For a buffer that $(B outlives the call) — a field, or a local the caller keeps
using. Where the C string is only needed for the duration of one call, reach for
$(LREF toTempStringz), which owns its buffer and needs no variable.

$(B Idempotent.) A buffer already ending in NUL is handed back as it is, so
bytes that $(LREF writeStringz) terminated do not grow a second one.

$(B Lifetime.) The result borrows `buf`: valid while `buf` is alive and
unmodified, since appending afterwards may reallocate. `return ref` makes that
checkable — `-dip1000` ties the result to the reference, so returning a borrow of
a local out of a `@safe` function is a compile error, pinned by a test below.

A free function rather than a method, called the same way through UFCS. The
annotation a method could carry is `return scope` on `this`, which ties the
result to the buffer's $(I contents) — and those may live in a heap block the
compiler cannot prove is the frame, so it would have to permit the escape this
rejects. `opSlice` has the same limitation, for the same reason.
*/
CStr stringz(Buffer)(return ref Buffer buf) @trusted
{
    if (buf.length == 0 || buf[][buf.length - 1] != '\0')
        buf ~= '\0';
    return CStr(buf[].ptr, buf.length - 1);
}

///
@("text.cstring.stringz.terminatesAndBorrows")
@safe pure nothrow @nogc
unittest
{
    SharedBuffer!(char, 32) buf;
    buf ~= "/tmp/";
    buf ~= "shot.png";

    const z = buf.stringz;
    assert(z[] == "/tmp/shot.png");
    assert((() @trusted => z.ptr[z.length])() == '\0');
}

@("text.cstring.stringz.isIdempotent")
@safe pure nothrow @nogc
unittest
{
    // Bytes `writeStringz` already terminated must not grow a second NUL, or
    // the reported length would drift past the text on every call.
    SharedBuffer!(char, 16) buf;
    buf.writeStringz("abc");
    assert(buf.stringz.length == 3);
    assert(buf.stringz.length == 3);
    assert(buf.length == 4);
}

@("text.cstring.stringz.emptyBufferIsTheEmptyString")
@safe pure nothrow @nogc
unittest
{
    SharedBuffer!(char, 8) buf;
    const z = buf.stringz;
    assert(z.length == 0);
    assert((() @trusted => z.ptr[0])() == '\0');
}

@("text.cstring.stringz.borrowContractIsEnforced")
unittest
{
    // What `return ref` buys, and the reason this is not a method: the result
    // aliases a reference to the buffer, so a borrow of a local cannot leave a
    // `@safe` function. A `return scope` method could not reject this.
    static assert(!__traits(compiles, {
        CStr leak() @safe
        {

            SharedBuffer!(char, 8) buf;
            buf ~= "x";
            return buf.stringz;
        }
    }), "dip1000 should reject escaping a borrow of a dead SharedBuffer");
}

/**
An owned, NUL-terminated copy of `s`, for handing to C within one expression.

---
SetWindowTitle(title.toTempStringz.ptr);
---

$(B It owns the bytes;) $(LREF CStr) and $(LREF stringz) borrow them. That is
the whole difference, and the reason this exists: a function that builds a
buffer and returns a borrow of it returns a dangling pointer, because the buffer
dies on return. Returning the buffer itself moves it into the caller's temporary,
which lives long enough.

$(B How long is long enough:) a temporary is destroyed at the end of the
$(B full expression) that created it — after the call it was passed to has
returned. So the form above is sound, and so is passing two of them to one call.

$(B $(RED Do not store the pointer.)) Binding it to a variable ends the full
expression, destroys the buffer, and leaves the pointer dangling:

---
auto p = title.toTempStringz.ptr;   // WRONG: p dangles here
SetWindowTitle(p);
---

That compiles, and $(B nothing will catch it.) `-dip1000` asks whether a
reference outlives the $(I scope) of what it points at; it has no model of when
a destructor runs, and a `SharedBuffer`'s bytes are behind a pointer rather than
in the frame, so there is nothing for it to bind to either.
`std.internal.cstring.tempCString` carries the identical hazard and documents it
the same way. Where the C string must outlive the expression, name the buffer —
`auto z = title.toTempStringz;` — and it becomes an ordinary local.

Where the input has a known bound, $(LREF toCString) is the stricter tool: its
fixed array $(I is) in the frame, so `-dip1000` rejects every route out of it.

`N` is the inline capacity, not a limit: past it the buffer grows on the heap.
*/
TempStringz!N toTempStringz(size_t N = 256)(scope const(char)[] s)
    => TempStringz!N(s);

/// The owning buffer $(LREF toTempStringz) returns. Construct it through that.
struct TempBuffer(T, size_t N, sentinel...)
if (sentinel.length <= 1 && (sentinel.length == 0 || is(typeof(sentinel[0]) : T)))
{
    // `unique`: a sole owner that is moved, never copied. That is what makes
    // the grow path refcount-free — the shared variant reaches its heap block
    // through an `AffixAllocator` control block this would never read.
    private UniqueBuffer!(T, N) _buf;

    /// Whether a sentinel is appended after the elements.
    enum bool hasSentinel = sentinel.length == 1;

    /// Non-copyable, so exactly one owner frees the storage; and never
    /// default-constructible, so an unterminated one cannot exist.
    @disable this();
    /// ditto
    @disable this(this);

    private this(scope const(T)[] s) @safe
    {
        _buf ~= s;
        static if (hasSentinel)
            _buf ~= sentinel[0];
    }

    /// Elements, excluding the sentinel.
    size_t length() const scope @safe => _buf.length - (hasSentinel ? 1 : 0);

    /// The elements, sentinel included if there is one. Read it within the
    /// expression that created the buffer.
    ///
    /// Recomputed from `_buf` on every call rather than cached at construction:
    /// returning by value moves the buffer, and a stored interior pointer would
    /// address the pre-move location. (`std.internal.cstring` needs a sentinel
    /// value to work around exactly this; a `Buffer` derives its view from
    /// `this`, so there is nothing to work around.)
    const(T)* ptr() const return scope @trusted => _buf[].ptr;

    /// The elements as a D slice, excluding the sentinel.
    const(T)[] opSlice() const return scope @safe => _buf[][0 .. length];
}

/// A `TempBuffer` of NUL-terminated `char` — the C-string case.
///
/// The sentinel is spelled out rather than defaulted: `T.init` would be
/// `char.init`, which is `0xFF` and terminates nothing.
alias TempStringz(size_t N = 256) = TempBuffer!(char, N, '\0');

///
@("text.cstring.toTempStringz.terminatesWithoutANamedBuffer")
@safe pure nothrow @nogc
unittest
{
    static size_t cLen(const(char)* p) @system nothrow @nogc
    {
        import core.stdc.string : strlen;

        return strlen(p);
    }

    // The shape every seam uses: build and consume in one expression.
    assert((() @trusted => cLen("hue — main.d".toTempStringz.ptr))() == 14);
}

@("text.cstring.toTempStringz.growsPastTheInlineCapacity")
@safe pure nothrow
unittest
{
    // `N` is the inline capacity, not a cap — the case a fixed `CString!N`
    // could not serve.
    char[300] long_ = 'x';
    const z = long_[].toTempStringz!8;
    assert(z.length == 300);
    assert(z[] == long_[]);
    assert((() @trusted => z.ptr[300])() == '\0');
}

@("text.cstring.toTempStringz.emptyInputIsTheEmptyString")
@safe pure nothrow @nogc
unittest
{
    const z = "".toTempStringz;
    assert(z.length == 0);
    assert((() @trusted => z.ptr[0])() == '\0');
}

@("text.cstring.toTempStringz.theValueMayBeReturnedBecauseItOwnsItsBytes")
@safe pure nothrow @nogc
unittest
{
    // Naming the buffer is how a C string outlives the expression that built
    // it — and the value may cross a function boundary, because it carries its
    // storage rather than pointing at someone else's.
    static TempStringz!16 make() @safe pure nothrow @nogc
        => "kept".toTempStringz!16;

    const z = make();
    assert(z[] == "kept");
    assert((() @trusted => z.ptr[4])() == '\0');
}

@("text.cstring.stringz.growsPastTheInlineCapacity")
@safe pure nothrow
unittest
{
    // The whole point of the growing side: a caller's text is not bounded by
    // whatever N the seam guessed. 300 bytes through an inline-8 buffer.
    SharedBuffer!(char, 8) buf;
    foreach (_; 0 .. 300)
        buf ~= 'x';

    const z = buf.stringz;
    assert(z.length == 300);
    assert((() @trusted => z.ptr[300])() == '\0');
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

// Does `s` contain a NUL? `memchr` at runtime; a loop under CTFE, where it has
// no source to interpret and `cstr` needs an answer. `std.algorithm.canFind`
// would serve both but reaches `std.uni` through `std.array`, and every
// `CString` test in this module is `@betterC`-marked.
private bool hasInteriorNul(scope const(char)[] s) @trusted
{
    if (__ctfe)
    {
        foreach (c; s)
            if (c == '\0')
                return true;
        return false;
    }

    import core.stdc.string : memchr;

    return s.length != 0 && memchr(s.ptr, '\0', s.length) !is null;
}

/**
Is `s` a complete C string — no NUL before the end, and a NUL at the end?

The precondition $(LREF CStr.fromStringzSlice) checks: a slice that already
carries its own terminator can become a `CStr` with no copy and no `strlen`.
Both halves matter. A missing final NUL means C reads past the end; an interior
one means the C string is shorter than the slice, so the length would be wrong.

Note that a D string $(I literal) does not satisfy this: the language guarantees
a NUL is emitted after the literal's bytes, but `.length` excludes it. Write the
terminator into the literal — `"VK_LAYER_KHRONOS_validation\0"` — where you want
this to accept one.
*/
bool isExactStringz(scope const(char)[] s)
    => s.length != 0 && s[$ - 1] == '\0' && !hasInteriorNul(s[0 .. $ - 1]);

///
@("text.cstring.isExactStringz.bothHalves")
unittest
{
    assert(isExactStringz("abc\0"));
    assert(isExactStringz("\0"));            // the empty C string

    assert(!isExactStringz("abc"));          // no terminator: C reads past the end
    assert(!isExactStringz(""));             // nothing to read at all
    assert(!isExactStringz("a\0b\0"));       // interior NUL: the length would be wrong

    // A bare literal is NOT one of these — the NUL the language emits is past
    // `.length`, which is exactly the trap this predicate exists to catch.
    assert(!isExactStringz("literal"));

    // Both evaluation paths agree: `memchr` at runtime, a loop under CTFE.
    static assert(isExactStringz("abc\0"));
    static assert(!isExactStringz("abc"));
    static assert(!isExactStringz("a\0b\0"));
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

That is why the storage is a fixed array rather than a `SharedBuffer`. A borrow
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
    // `InlineBuffer` rather than a raw `char[N]`: same never-allocating storage
    // and the same `-dip1000` escape rejection, but the buffer owns the length
    // and the bounds rather than this type restating them.
    private InlineBuffer!(char, N) _buf;

    // Writes `parts` plus the terminator in one bounded attempt, so a partial
    // build is never left behind. The single writer for this type.
    private bool fill(scope const(char)[][] parts) @safe
    {
        return _buf.tryWrite((scope ref BoundedSink!char w) {
            foreach (p; parts)
                w.put(p);
            w.put('\0');
        });
    }

    /// Bytes, excluding the terminator.
    size_t length() const scope => _buf.length == 0 ? 0 : _buf.length - 1;

    /// The C string. $(B Never `null`) — a default-constructed `CString`, and
    /// one left behind by a failed $(LREF tryToCString), both read `""`. That
    /// is deliberate: a caller who skips the check gets an empty string, which
    /// a C callee rejects, rather than a null a callee may silently accept
    /// (`dlopen(null, …)` returns a handle to the main program).
    ///
    /// `@trusted` for the `.ptr`, which is sound locally — the buffer holds the
    /// terminator whenever it is non-empty, and the empty branch answers from
    /// static storage rather than reading the buffer at all.
    const(char)* ptr() const return scope @trusted
        => _buf.length == 0 ? emptyZ.ptr : &_buf[][0];

    /// The bytes as a D slice, excluding the terminator.
    const(char)[] opSlice() const return scope => _buf[][0 .. length];
}

// Shared by both halves: what `ptr` answers when there are no bytes. Static
// storage, so neither type ever reads an uninitialised buffer.
private static immutable char[1] emptyZ = "\0";

/**
A borrowed NUL-terminated C string: a pointer, and the length before the
terminator.

$(B It owns nothing,) and it is the $(B read) direction. Every `CStr` addresses
bytes belonging to something else — memory a C library returned, or a buffer the
caller still holds. Keeping one past the owner's lifetime is the same mistake as
keeping a slice past its array's.

$(B Not a parameter type for D APIs.) A function in this repository that takes
text takes `string` or `in char[]` and terminates internally; that way a caller
cannot pass an unterminated pointer, because it never passes a pointer. `CStr`
is what such a function produces on the way out, and what a C boundary produces
on the way in — see $(LREF stringz) and $(LREF fromStringz).

$(B Fat, not thin.) It carries the length rather than making every reader call
`strlen`. At both construction sites that can know the length, it is already
known; only $(LREF fromStringz), where a bare pointer arrives from C with no
other provenance, has to measure.
*/
struct CStr
{
    // Explicit, because the module's attribute label above reaches this
    // declaration but not the members inside it — `CString` gets them only by
    // template inference, which a plain struct does not have.
@safe pure nothrow @nogc:

    private const(char)* _p;
    private size_t _len;

    /// Bytes, excluding the terminator.
    size_t length() const scope => _len;

    /// The C string. $(B Never `null`) — a default-constructed `CStr` reads
    /// `""`, for the reason $(LREF CString.ptr) gives: a callee rejects an
    /// empty string, where it may silently accept a null.
    ///
    /// `@trusted` for the null substitution, which answers from static storage
    /// rather than from a pointer this type never validated.
    const(char)* ptr() const return scope @trusted
        => _p is null ? emptyZ.ptr : _p;

    /// The bytes as a D slice, excluding the terminator.
    ///
    /// `@trusted` on the whole accessor: the construction sites are the entire
    /// proof that `_p` addresses `_len + 1` readable bytes, and they are all in
    /// this module.
    const(char)[] opSlice() const return scope @trusted
        => _p is null ? null : _p[0 .. _len];

    /**
    Wraps a NUL-terminated pointer that came from C, measuring it.

    `@system` and deliberately awkward: nothing here proves the pointer is
    terminated, still allocated, or yours. Reach for it at a C boundary — a
    `getenv`, a driver's reported extension name — and nowhere else. A null
    pointer yields the empty string rather than a `CStr` that faults on first
    read.
    */
    static CStr fromStringz(const(char)* p) @system
    {
        import core.stdc.string : strlen;

        return p is null ? CStr.init : CStr(p, strlen(p));
    }

    /**
    Wraps a slice that already ends in its own terminator — no copy, no
    `strlen`.

    ---
    enum layer = "VK_LAYER_KHRONOS_validation\0";
    vkInfo.ppEnabledLayerNames = &CStr.fromStringzSlice(layer).ptr;
    ---

    `@safe`, unlike $(LREF fromStringz), because a slice carries its own bounds:
    the only thing left to establish is that the terminator is inside them, and
    $(LREF isExactStringz) is that check as an `in` contract. Use it for a
    literal written with an explicit `\0`, or for bytes another buffer already
    terminated.
    */
    static CStr fromStringzSlice(return scope const(char)[] s) @trusted
    in (isExactStringz(s), "fromStringzSlice: not a complete C string")
        // `@trusted` for `.ptr` alone, which `@safe` forbids in favour of
        // `&s[0]` — a distinction without a difference here, since the contract
        // above has already established the slice is non-empty.
        => CStr(&s[0], s.length - 1);
}

/**
A $(LREF CStr) over a string literal, with no copy.

---
CStr ext = cstr!"VK_KHR_wayland_surface";
---

The language emits a NUL after every string literal, so a literal's own bytes
already $(I are) a C string — this names that fact in the type system, for a
literal that has to be $(B stored) and handed on later. Where one goes straight
to C in the same expression, `"...".ptr` says the same thing with less
ceremony.

Rejects an interior NUL, which would silently truncate the C string.
*/
template cstr(string s)
{
    static assert(!hasInteriorNul(s),
        "cstr: interior NUL would truncate the C string");

    static if (s.length == 0)
        enum CStr cstr = CStr.init;   // reads "" from static storage
    else
        // `@trusted` for `.ptr`, which `@safe` initialization forbids in
        // favour of `&s[0]`. The terminator is the language's guarantee here,
        // not something this code establishes.
        enum CStr cstr = (() @trusted => CStr(s.ptr, s.length))();
}

///
@("text.cstring.cstr.literalIsAlreadyACString")
@betterC
unittest
{
    const z = cstr!"abc";
    assert(z[] == "abc");
    assert(z.length == 3);
    assert((() @trusted => z.ptr[3])() == '\0');
}

@("text.cstring.cstr.emptyLiteral")
@betterC
unittest
{
    const z = cstr!"";
    assert(z.length == 0);
    assert((() @trusted => z.ptr[0])() == '\0');
}

@("text.cstring.cstr.acceptsAnEnumStringSymbol")
@betterC
unittest
{
    // The form the call sites use: a named `enum string` rather than an inline
    // literal. Same instantiation, but worth pinning — the real ones sit behind
    // `version (linux)` / `version (Windows)` and compile on no single host.
    enum string extension = "VK_KHR_wayland_surface";
    const z = cstr!extension;

    assert(z[] == extension);
    assert((() @trusted => z.ptr[z.length])() == '\0');
}


///
@("text.cstring.CStr.fromStringzSlice.borrowsWithoutCopying")
@betterC
unittest
{
    // Bound to a variable so the bytes are materialized once. As an `enum`,
    // each occurrence would expand to a fresh literal expression, and the
    // identity check below would be asking two of them to share an address —
    // which LDC grants by pooling constants and DMD does not.
    const(char)[] layer = "VK_LAYER_KHRONOS_validation\0";
    const z = CStr.fromStringzSlice(layer);

    assert(z[] == "VK_LAYER_KHRONOS_validation");
    assert(z.length == layer.length - 1);
    assert((() @trusted => z.ptr[z.length])() == '\0');
    // No copy: it addresses the very bytes it was handed.
    assert((() @trusted => z.ptr is &layer[0])());
}

@("text.cstring.CStr.fromStringzSlice.rejectsAnUnterminatedSlice")
@system
unittest
{
    // The contract is the whole safety argument: a bare literal has its NUL
    // past `.length`, so accepting one would hand C a pointer whose length is
    // a lie. try/catch rather than `collectException` — the module's attribute
    // label makes this test `nothrow @nogc`.
    bool threw;
    try
        cast(void) CStr.fromStringzSlice("no terminator");
    catch (Error)
        threw = true;
    assert(threw, "an unterminated slice must not become a CStr");
}

@("text.cstring.CStr.defaultIsEmptyString")
@betterC
unittest
{
    // Same contract as CString: never null, so a callee that would accept a
    // null (dlopen) gets an empty string it rejects instead.
    CStr z;
    assert(z.length == 0);
    assert(z.ptr !is null);
    assert((() @trusted => z.ptr[0])() == '\0');
    assert(z[].length == 0);
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
    const fitted = r.fill(parts);
    assert(fitted, "toCString: parts exceed N bytes");
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

    return dest.fill(parts);
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
    // dead local, with no `scope` written at the call site. A SharedBuffer-backed
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
    // the same shape on a bare static array, and does not on a SharedBuffer.
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
    //
    // Written as calls rather than `__traits(compiles, …)`: the compile is the
    // claim, so making it a claim about a value that must also be right is
    // strictly stronger, and a mistake shows up as a failing assert rather than
    // as a `compiles` that quietly went false.
    // Each helper checks its own result, because a `CString`'s bytes cannot
    // leave the frame that built them — which is the other property under test.
    static bool joins(scope const(char)[] a, scope const(char)[] b)
        @safe pure nothrow @nogc
    {
        auto z = toCString!128([a, "/", b]);
        return z[] == "usr/lib";
    }

    static bool joinsTry(scope const(char)[] a, scope const(char)[] b)
        @safe pure nothrow @nogc
    {
        CString!128 z;
        return tryToCString(z, [a, "/", b]) && z[] == "usr/lib";
    }

    assert(joins("usr", "lib"));
    assert(joinsTry("usr", "lib"));
}

@("text.cstring.TempBuffer.servesANonSentinelSequence")
@safe pure nothrow
unittest
{
    // The general case: a scratch array handed to C as `(ptr, len)` — a Vulkan
    // name array, an iovec — where no terminator is wanted.
    auto a = TempBuffer!(uint, 4)([1u, 2u, 3u]);
    assert(!typeof(a).hasSentinel);
    assert(a.length == 3);
    assert(a[] == [1u, 2u, 3u]);

    // And the C-string case is the same type with one value supplied.
    auto z = TempStringz!8("hue");
    assert(typeof(z).hasSentinel);
    assert(z.length == 3);
    assert((() @trusted => z.ptr[3])() == '\0');
}

@("text.cstring.TempBuffer.rejectsMoreThanOneSentinel")
unittest
{
    // One optional compile-time value, so "has a sentinel" and "which sentinel"
    // cannot disagree.
    static assert(__traits(compiles, TempBuffer!(char, 8, '\0')));
    static assert(__traits(compiles, TempBuffer!(char, 8)));
    static assert(!__traits(compiles, TempBuffer!(char, 8, '\0', 'x')));
}

@("text.cstring.TempBuffer.isNeitherDefaultConstructibleNorCopyable")
unittest
{
    // Exactly one owner frees the storage, and an unterminated one cannot exist.
    static assert(!__traits(compiles, { TempStringz!8 z; }));
    static assert(!__traits(compiles, {
        auto a = "x".toTempStringz!8;
        auto b = a;
    }));
}

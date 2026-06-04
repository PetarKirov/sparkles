/**
 * Secure memory zeroization — the single trusted primitive the whole
 * secret-memory foundation is built on.
 *
 * This module is **pure D**: it does not depend on the libsodium backend, so
 * it compiles and tests without any backend present. The libsodium backend MAY
 * later route $(LREF zeroizeMemory) through `sodium_memzero`, but the default
 * implementation here is sufficient and self-contained.
 *
 * It is modeled on RustCrypto's
 * $(LINK2 https://docs.rs/zeroize, `zeroize`) crate:
 *
 * $(UL
 *   $(LI $(LREF zeroizeMemory) overwrites a byte buffer with zeroes using
 *        volatile stores so the optimizer cannot elide the wipe.)
 *   $(LI $(LREF isZeroizable) detects value types whose all-zero bit pattern is
 *        the desired wiped state — scalars and (nested) static arrays of them.)
 *   $(LI $(LREF Zeroizing) is an RAII wrapper that wipes its payload on scope
 *        exit and forbids implicit copies.)
 * )
 *
 * See `docs/specs/age/SPEC.md` §3.1 for the normative description.
 */
module sparkles.crypto.zeroize;

import core.volatile : volatileStore;

/**
 * Overwrite `buf` with zeroes such that the write cannot be elided by the
 * optimizer.
 *
 * Ordinary `buf[] = 0;` is a dead store from the compiler's point of view when
 * `buf` is never read again before going out of scope, so an optimizing
 * compiler is free to remove it. This function instead issues a $(B volatile)
 * store per byte (`core.volatile.volatileStore`), which acts as an
 * optimization barrier: the writes are observable side effects on memory and
 * must be emitted.
 *
 * It is deliberately $(B not) `pure`: the wipe is an intentional, observable
 * mutation of memory that pure-function caching would defeat.
 *
 * Params:
 *   buf = The bytes to overwrite with zero. A zero-length slice is a no-op.
 */
void zeroizeMemory(scope ubyte[] buf) @trusted nothrow @nogc
{
    // A per-byte volatile store cannot be coalesced into a memset that the
    // optimizer might then prove dead, nor removed entirely.
    foreach (i; 0 .. buf.length)
        volatileStore(&buf[i], ubyte(0));
}

/// Zeroing a buffer overwrites every byte.
@("crypto.zeroize.zeroizeMemory.wipes")
@safe nothrow @nogc
unittest
{
    ubyte[8] data = [1, 2, 3, 4, 5, 6, 7, 8];
    zeroizeMemory(data[]);
    foreach (b; data[])
        assert(b == 0);
}

/// A zero-length slice is accepted and does nothing.
@("crypto.zeroize.zeroizeMemory.empty")
@safe nothrow @nogc
unittest
{
    ubyte[] empty;
    zeroizeMemory(empty); // must not crash
    assert(empty.length == 0);

    ubyte[4] data = [9, 9, 9, 9];
    zeroizeMemory(data[0 .. 0]); // empty sub-slice leaves the rest intact
    assert(data == [9, 9, 9, 9]);
}

/**
 * Detects value types whose all-zero (i.e. `T.init` for scalars) bit pattern
 * is the desired wiped result.
 *
 * This is true for:
 * $(UL
 *   $(LI scalar types: integral, `bool`, character (`char`/`wchar`/`dchar`),
 *        and floating-point types, and)
 *   $(LI static arrays whose element type is itself $(LREF isZeroizable)
 *        (recursively, so e.g. `ubyte[16][4]` qualifies).)
 * )
 *
 * It is deliberately $(B false) for types that hold references to memory the
 * wipe would not actually clear — dynamic arrays (only the fat pointer would
 * be zeroed, not the referenced bytes), pointers, classes, and aggregates
 * containing any of those. Such types would leave secret bytes behind a
 * dangling-but-zeroed handle, defeating the purpose.
 *
 * Params:
 *   T = The candidate type.
 */
enum bool isZeroizable(T) =
    __traits(isScalar, T) && !is(T == enum) && !isPointerLike!T
    || isZeroizableStaticArray!T;

private enum bool isPointerLike(T) = is(T == U*, U) || is(T == U[], U) || is(T == delegate)
    || is(T == function);

private template isZeroizableStaticArray(T)
{
    static if (is(T : E[n], E, size_t n))
        enum bool isZeroizableStaticArray = isZeroizable!E;
    else
        enum bool isZeroizableStaticArray = false;
}

/// Scalars and static arrays of scalars are zeroizable; reference-bearing
/// types are not.
@("crypto.zeroize.isZeroizable.classification")
@safe pure nothrow @nogc
unittest
{
    // Scalars.
    static assert(isZeroizable!int);
    static assert(isZeroizable!ubyte);
    static assert(isZeroizable!bool);
    static assert(isZeroizable!char);
    static assert(isZeroizable!double);

    // Static arrays (including nested) of scalars.
    static assert(isZeroizable!(ubyte[16]));
    static assert(isZeroizable!(int[4]));
    static assert(isZeroizable!(ubyte[16][4]));

    // Reference-bearing / indirect types are NOT zeroizable: wiping the
    // handle would leave the pointed-to secret bytes intact.
    static assert(!isZeroizable!(int[]));     // dynamic array (fat pointer)
    static assert(!isZeroizable!(int*));      // pointer
    static assert(!isZeroizable!string);      // immutable(char)[]

    // Aggregates with a pointer field are not scalars and not arrays.
    struct WithPointer { int* p; }
    static assert(!isZeroizable!WithPointer);

    // Plain enums are excluded (their identity is the named set, not bytes).
    enum Color { red, green, blue }
    static assert(!isZeroizable!Color);
}

/**
 * RAII wrapper that zeroizes its payload on destruction.
 *
 * Holds a value of type `T` and, in its destructor, overwrites the payload's
 * bytes via $(LREF zeroizeMemory) so the cleared state is the all-zero bit
 * pattern. Copying is disabled (`@disable this(this)`) to prevent a silent
 * duplicate from outliving — and leaking past — the wipe.
 *
 * The wrapped value is exposed by reference via $(LREF get) and, for
 * ergonomic use, `alias get this`, so a `Zeroizing!T` can largely be used
 * where a `T` is expected.
 *
 * Params:
 *   T = A $(LREF isZeroizable) value type (scalar or static array of scalars).
 *
 * Example:
 * ---
 * {
 *     auto key = Zeroizing!(ubyte[32])(freshKeyBytes);
 *     useKey(key.get);
 * } // key's 32 bytes are wiped here, on scope exit.
 * ---
 */
struct Zeroizing(T) if (isZeroizable!T)
{
    private T payload;

    /// Wraps `initial`, taking ownership of its lifetime.
    this(T initial)
    {
        payload = initial;
    }

    /// No implicit copies: a duplicate could outlive and leak past the wipe.
    @disable this(this);

    /// The single access path to the wrapped value, by reference. `inout`
    /// preserves the caller's mutability; `return` ties the reference's
    /// lifetime to `this` for `-preview=dip1000`.
    ref inout(T) get() inout return @safe nothrow @nogc => payload;

    /// Use a `Zeroizing!T` wherever a `T` (or `ref T`) is expected.
    alias get this;

    /// Overwrites the payload's bytes with zeroes on scope exit.
    ~this() @trusted nothrow @nogc
    {
        zeroizeMemory((cast(ubyte*)&payload)[0 .. T.sizeof]);
    }
}

/// `Zeroizing` exposes its payload and disables copying.
@("crypto.zeroize.Zeroizing.access")
@safe nothrow @nogc
unittest
{
    auto z = Zeroizing!int(42);
    assert(z.get == 42);
    assert(z == 42); // via alias get this

    // Mutate through the reference.
    z.get = 7;
    assert(z.get == 7);

    // Copy construction / postblit is disabled.
    static assert(!__traits(compiles, { auto a = Zeroizing!int(1); auto b = a; }));
}

/// `Zeroizing!(ubyte[N])` wipes every byte of its payload on destruction.
///
/// This `@system` test runs the destructor in place (`destroy!false` — the
/// destructor only, with no re-initialization that would itself zero the
/// payload) while the wrapper is still in scope, then reads its own, now-wiped
/// storage. It reads only live memory — never a freed or out-of-scope region —
/// so it is well-defined on every platform/allocator.
@("crypto.zeroize.Zeroizing.wipesOnDestruction")
@system nothrow @nogc
unittest
{
    auto z = Zeroizing!(ubyte[32])(cast(ubyte[32]) [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
    ]);
    assert(z.get[0] == 1 && z.get[31] == 32);

    destroy!false(z); // runs ~Zeroizing (wiping the payload), no re-initialization
    foreach (i; 0 .. 32)
        assert(z.get[i] == 0, "Zeroizing payload was not wiped on destruction");
}

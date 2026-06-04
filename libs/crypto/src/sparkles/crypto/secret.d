/**
 * Secret containers that zeroize on destruction, refuse implicit copy, and
 * never render their contents.
 *
 * This module is the secrecy half of the secret-memory foundation (see
 * `docs/specs/age/SPEC.md` §3). It provides:
 *
 * $(UL
 *   $(LI $(LREF SecretArray) — a fixed-size secret byte array, the common
 *        case for cryptographic keys. `FileKey = SecretArray!16`; derived
 *        wrap/payload keys are `SecretArray!32`.)
 *   $(LI $(LREF SecretBuffer) — a growable, `SmallBuffer`-shaped secret
 *        buffer that wipes its $(I full) capacity before freeing or
 *        reallocating.)
 *   $(LI $(LREF SecretString) — `SecretBuffer!(char, 64)` for passphrases.)
 *   $(LI $(LREF isSecret) — detects a type exposing `exposeSecret`.))
 *
 * Design rules (per spec §3.2):
 *
 * $(UL
 *   $(LI `exposeSecret`/`exposeSecretMut` are the $(I only) access paths to
 *        the bytes — explicit and greppable; there is no implicit conversion
 *        to `ubyte[]`.)
 *   $(LI `toString` is redacted — it writes `SecretArray!N([REDACTED])` /
 *        `SecretBuffer([REDACTED])`, never the bytes, so a secret cannot leak
 *        through the logger or pretty-printer.)
 *   $(LI Copy is opt-in via an explicit `clone()`; assignment and
 *        pass-by-value are disabled with `@disable this(this)`.))
 *
 * This layer is $(B pure D): it depends only on $(D sparkles.crypto.zeroize)
 * and $(D sparkles.crypto.ct), never on libsodium.
 */
module sparkles.crypto.secret;

import core.memory : pureMalloc, pureFree;

import sparkles.crypto.zeroize : zeroizeMemory, isZeroizable;
import sparkles.crypto.ct : ctEquals;

// ─────────────────────────────────────────────────────────────────────────────
// SecretArray
// ─────────────────────────────────────────────────────────────────────────────

/**
 * A fixed-size secret byte array of `N` bytes.
 *
 * The storage is inline (no heap allocation); the bytes are zeroized in the
 * destructor via $(D zeroizeMemory). The type is non-copyable
 * (`@disable this(this)`), compares in constant time via
 * $(D sparkles.crypto.ct.ctEquals), and never renders its bytes.
 *
 * `FileKey` is `SecretArray!16`; derived wrap/payload keys are `SecretArray!32`.
 *
 * Params:
 *   N = Number of secret bytes held inline.
 */
struct SecretArray(size_t N)
{
    static assert(N > 0, "SecretArray needs at least one byte");

    private ubyte[N] _bytes = 0;

    /// Disable implicit copy; use $(LREF clone) for an explicit copy.
    @disable this(this);

    /// The number of secret bytes.
    enum size_t length = N;

    /**
     * Construct a secret by filling its bytes in place.
     *
     * The callback receives a mutable reference to the inline storage and is
     * expected to populate it (e.g. from a CSPRNG). This avoids an
     * intermediate plaintext copy on the stack.
     *
     * Params:
     *   fill = Callback that writes the `N` secret bytes in place.
     */
    static SecretArray initWithMut(scope void delegate(ref ubyte[N]) @safe fill)
    in (fill !is null, "initWithMut requires a non-null fill delegate")
    {
        SecretArray result;
        fill(result._bytes);
        return result;
    }

    /**
     * Construct a secret from an existing byte array.
     *
     * The caller's `source` is copied into the secret's inline storage; the
     * caller remains responsible for wiping any temporary holding `source`.
     *
     * Params:
     *   source = The `N` bytes to copy into the secret.
     */
    static SecretArray fromBytes(in ubyte[N] source)
    {
        SecretArray result;
        result._bytes = source;
        return result;
    }

    /**
     * The $(B only) read path: a slice over the `N` secret bytes.
     *
     * The returned slice borrows the inline storage; it must not outlive the
     * secret (enforced by `return`).
     */
    inout(ubyte)[] exposeSecret() inout return @trusted => _bytes[];

    /**
     * The $(B only) write path: a mutable slice over the `N` secret bytes.
     *
     * The returned slice borrows the inline storage; it must not outlive the
     * secret (enforced by `return`).
     */
    ubyte[] exposeSecretMut() return @trusted => _bytes[];

    /// Explicit opt-in copy producing an independent secret.
    SecretArray clone() const @safe => SecretArray.fromBytes(_bytes);

    /// Constant-time equality via $(D sparkles.crypto.ct.ctEquals).
    bool opEquals(in SecretArray other) const @safe
        => ctEquals(_bytes[], other._bytes[]);

    /**
     * Output-range `toString` that renders the redacted form
     * `SecretArray!N([REDACTED])` — never the secret bytes.
     */
    void toString(W)(ref W w) const
    {
        w.put("SecretArray!");
        writeSizeT(w, N);
        w.put("([REDACTED])");
    }

    /// Destructor: zeroize the inline bytes so they do not linger in memory.
    ~this() @trusted
    {
        zeroizeMemory(_bytes[]);
    }
}

@("crypto.secret.SecretArray.initWithMut")
@safe
unittest
{
    // initWithMut fills the storage in place and exposeSecret reads it back.
    // Not pure (zeroizing destructor) and not nothrow/@nogc (the contract's
    // fill delegate type carries no such attributes).
    auto key = SecretArray!16.initWithMut((ref ubyte[16] b) {
        foreach (i; 0 .. 16)
            b[i] = cast(ubyte) i;
    });

    assert(key.length == 16);
    auto seen = key.exposeSecret();
    assert(seen.length == 16);
    foreach (i; 0 .. 16)
        assert(seen[i] == cast(ubyte) i);
}

@("crypto.secret.SecretArray.fromBytes")
@safe nothrow @nogc
unittest
{
    ubyte[4] raw = [0xDE, 0xAD, 0xBE, 0xEF];
    auto s = SecretArray!4.fromBytes(raw);
    assert(s.exposeSecret() == raw[]);
}

@("crypto.secret.SecretArray.exposeSecretMut")
@safe nothrow @nogc
unittest
{
    SecretArray!8 s;
    auto mut = s.exposeSecretMut();
    mut[3] = 0x7F;
    assert(s.exposeSecret()[3] == 0x7F);
}

@("crypto.secret.SecretArray.toString.redacted")
@safe nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    SecretArray!16 key;
    checkToString(key, "SecretArray!16([REDACTED])");

    SecretArray!32 big;
    checkToString(big, "SecretArray!32([REDACTED])");
}

@("crypto.secret.SecretArray.clone.independent")
@safe nothrow @nogc
unittest
{
    auto original = SecretArray!4.fromBytes([1, 2, 3, 4]);
    auto copy = original.clone();

    // Equal contents...
    assert(original == copy);

    // ...but mutating the copy does not touch the original.
    copy.exposeSecretMut()[0] = 0xFF;
    assert(original.exposeSecret()[0] == 1);
    assert(copy.exposeSecret()[0] == 0xFF);
    assert(original != copy);
}

@("crypto.secret.SecretArray.opEquals.constantTime")
@safe nothrow @nogc
unittest
{
    auto a = SecretArray!4.fromBytes([1, 2, 3, 4]);
    auto b = SecretArray!4.fromBytes([1, 2, 3, 4]);
    auto c = SecretArray!4.fromBytes([1, 2, 3, 5]);

    assert(a == b);
    assert(a != c);
    // Differing only in the first byte must still compare not-equal (no
    // early-out semantics observable at the value level).
    auto d = SecretArray!4.fromBytes([9, 2, 3, 4]);
    assert(a != d);
}

@("crypto.secret.SecretArray.wipeOnDrop")
@system
unittest
{
    // Run the destructor in place (destroy!false — the destructor only, no
    // re-initialization) and confirm it zeroized the inline bytes. We read
    // `key`'s own storage while it is still in scope — never an out-of-scope or
    // freed region — so this is well-defined on every platform/allocator.
    auto key = SecretArray!16.fromBytes(
        [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22,
         0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00]);
    assert(key.exposeSecret()[0] == 0xAA);

    destroy!false(key); // runs ~this, wiping _bytes, with no re-initialization
    foreach (b; key.exposeSecret())
        assert(b == 0, "SecretArray bytes were not wiped on drop");
}

// ─────────────────────────────────────────────────────────────────────────────
// SecretBuffer
// ─────────────────────────────────────────────────────────────────────────────

/**
 * A growable secret buffer modeled on $(D sparkles.core_cli.smallbuffer.SmallBuffer).
 *
 * Elements are stored inline up to `N`, then on the heap via $(D pureMalloc)
 * when capacity is exceeded. Unlike `SmallBuffer`, this type wipes its
 * $(B full) capacity (not merely the live elements) before any reallocation
 * and in the destructor, so no stale secret bytes are left behind on the heap
 * or in the inline storage. Copy is disabled; use $(LREF clone).
 *
 * Params:
 *   T = Element type (must be $(D isZeroizable)).
 *   N = Number of elements held inline before spilling to the heap.
 */
struct SecretBuffer(T, size_t N)
if (isZeroizable!T)
{
    static assert(N > 0, "SecretBuffer inline capacity must be greater than 0");

    private
    {
        T[N] _inline = void;
        // Heap storage pointer, or `null` while the buffer lives in `_inline`.
        // Crucially this is NOT a self-referential pointer into `_inline` (the
        // previous design stored `_inline.ptr` here, which made the struct
        // non-relocatable: a bitwise `move` — e.g. into a `SumType` — left this
        // pointer dangling at the moved-from inline storage, and the dtor then
        // zeroized freed/garbage memory). With heap-only `_heap`, a moved value
        // keeps a valid heap pointer, and inline access recomputes
        // `_inline.ptr` from the live `this`, so the buffer is freely movable.
        T* _heap = null;
        size_t _length = 0;
        size_t _capacity = N;
    }

    /// Disable implicit copy; use $(LREF clone) for an explicit copy.
    @disable this(this);

    /// The active storage pointer: the heap block once spilled, else the inline
    /// array of the $(I current) object (never a stored self-reference).
    private inout(T)* activePtr() inout return @trusted @nogc nothrow pure
        => _heap !is null ? _heap : _inline.ptr;

    /// The number of live elements.
    @property size_t length() const @safe => _length;

    /// Output-range interface: append a single secret element.
    void put(in T element) @trusted
    {
        ensureCapacity(_length + 1);
        activePtr[_length] = element;
        _length++;
    }

    /// Output-range interface: append a slice of secret elements.
    void put(scope const(T)[] elements) @trusted
    {
        if (elements.length == 0)
            return;
        ensureCapacity(_length + elements.length);
        activePtr[_length .. _length + elements.length] = elements[];
        _length += elements.length;
    }

    /**
     * The $(B only) read path: a slice over the live secret elements.
     *
     * The returned slice borrows internal storage; it must not outlive the
     * buffer (enforced by `return`) and is invalidated by a subsequent `put`
     * that triggers reallocation.
     */
    inout(T)[] exposeSecret() inout return @trusted
    {
        return activePtr[0 .. _length];
    }

    /**
     * The $(B only) write path: a mutable slice over the live secret elements.
     *
     * Same borrowing/invalidation rules as $(LREF exposeSecret).
     */
    T[] exposeSecretMut() return @trusted
    {
        return activePtr[0 .. _length];
    }

    /// Explicit opt-in copy producing an independent buffer with the same
    /// live elements.
    SecretBuffer clone() @safe
    {
        SecretBuffer result;
        result.put(exposeSecretConst());
        return result;
    }

    /**
     * Output-range `toString` that renders the redacted form
     * `SecretBuffer([REDACTED])` — never the secret bytes (and not even the
     * length, which can itself be sensitive for passphrases).
     */
    void toString(W)(ref W w) const
    {
        w.put("SecretBuffer([REDACTED])");
    }

    /// Destructor: zeroize the full capacity (heap or inline) before freeing.
    ~this() @trusted
    {
        wipeAll();
        if (_heap !is null)
            pureFree(_heap);
    }

private:

    // A const view over the live elements, used by clone(). Kept separate from
    // exposeSecret() so clone() can stay @safe without exposing a const path
    // in the public surface.
    const(T)[] exposeSecretConst() const return @trusted
    {
        return activePtr[0 .. _length];
    }

    bool onHeap() const @safe => _heap !is null;

    // Zeroize every element of the active storage (full capacity), regardless
    // of how many are live. When still inline and never written, the inline
    // buffer is uninitialized (`= void`) but writing zeros over it is harmless,
    // so we wipe unconditionally — there is no stored `null` sentinel to skip
    // on anymore.
    void wipeAll() @trusted
    {
        const byteLength = _capacity * T.sizeof;
        zeroizeMemory((cast(ubyte*) activePtr)[0 .. byteLength]);
    }

    void ensureCapacity(size_t needed) @trusted
    {
        if (needed <= _capacity)
            return;

        size_t newCap = _capacity;
        while (newCap < needed)
            newCap *= 2;

        reallocate(newCap);
    }

    void reallocate(size_t newCapacity) @trusted
    {
        import core.stdc.string : memcpy;

        const size = newCapacity * T.sizeof;
        void* newData = pureMalloc(size);
        if (newData is null)
            assert(false, "SecretBuffer: allocation failed");

        // Capture the OLD storage pointer (heap block or inline array) before
        // we repoint `_heap`.
        T* oldPtr = activePtr;
        const bool oldOnHeap = _heap !is null;

        if (_length > 0)
            memcpy(newData, oldPtr, _length * T.sizeof);

        // Wipe the OLD storage (full capacity) before releasing it, so the
        // secret never lingers in freed heap memory or the abandoned inline
        // buffer.
        const oldByteLength = _capacity * T.sizeof;
        zeroizeMemory((cast(ubyte*) oldPtr)[0 .. oldByteLength]);
        if (oldOnHeap)
            pureFree(oldPtr);

        _heap = cast(T*) newData;
        _capacity = newCapacity;
    }
}

@("crypto.secret.SecretBuffer.put.readback")
@safe nothrow @nogc
unittest
{
    SecretBuffer!(ubyte, 8) buf;
    buf.put(cast(ubyte) 0x10);
    buf.put([cast(ubyte) 0x20, 0x30, 0x40]);

    assert(buf.length == 4);
    assert(buf.exposeSecret() == cast(const(ubyte)[]) [0x10, 0x20, 0x30, 0x40]);
}

@("crypto.secret.SecretBuffer.put.growToHeap")
@safe nothrow @nogc
unittest
{
    SecretBuffer!(ubyte, 2) buf;
    foreach (i; 0 .. 10)
        buf.put(cast(ubyte) i);

    assert(buf.length == 10);
    foreach (i; 0 .. 10)
        assert(buf.exposeSecret()[i] == cast(ubyte) i);
}

@("crypto.secret.SecretBuffer.exposeSecretMut")
@safe nothrow @nogc
unittest
{
    SecretBuffer!(ubyte, 4) buf;
    buf.put([cast(ubyte) 1, 2, 3]);
    buf.exposeSecretMut()[1] = 0x99;
    assert(buf.exposeSecret() == cast(const(ubyte)[]) [1, 0x99, 3]);
}

@("crypto.secret.SecretBuffer.toString.redacted")
@safe nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    SecretBuffer!(ubyte, 8) buf;
    buf.put([cast(ubyte) 1, 2, 3]);
    checkToString(buf, "SecretBuffer([REDACTED])");
}

@("crypto.secret.SecretBuffer.clone.independent")
@safe nothrow @nogc
unittest
{
    SecretBuffer!(ubyte, 4) original;
    original.put([cast(ubyte) 1, 2, 3, 4]);

    auto copy = original.clone();
    assert(copy.length == original.length);
    assert(copy.exposeSecret() == original.exposeSecret());

    // Mutating the copy must not touch the original.
    copy.exposeSecretMut()[0] = 0xFF;
    assert(original.exposeSecret()[0] == 1);
    assert(copy.exposeSecret()[0] == 0xFF);
}

@("crypto.secret.SecretBuffer.wipeOnDrop.heap")
@system
unittest
{
    // The destructor wipes the full capacity (via wipeAll) before freeing. We
    // verify that wipe directly on the LIVE heap region: grow onto the heap,
    // call wipeAll() in place — exactly what ~this does immediately before
    // pureFree — and confirm the bytes are zeroed. This never reads freed memory
    // (which is UB and faults under some allocators, e.g. macOS); ~this then
    // wipes again and frees at scope exit.
    SecretBuffer!(ubyte, 4) buf;
    foreach (i; 0 .. 300) // force growth onto the heap
        buf.put(cast(ubyte) 0xA5);
    assert(buf.onHeap, "expected a heap allocation");
    assert(buf.exposeSecret()[0] == 0xA5);

    buf.wipeAll();
    foreach (b; buf.exposeSecretMut())
        assert(b == 0, "SecretBuffer heap bytes were not wiped");
}

@("crypto.secret.SecretBuffer.wipeOnRealloc")
@system
unittest
{
    // The inline storage must be wiped when the buffer spills to the heap.
    SecretBuffer!(ubyte, 4) buf;
    buf.put([cast(ubyte) 0x11, 0x22, 0x33, 0x44]);
    ubyte* inlinePtr = buf.exposeSecretMut().ptr; // points at _inline
    assert(*inlinePtr == 0x11);

    // Force reallocation off the inline storage.
    buf.put([cast(ubyte) 0x55, 0x66, 0x77, 0x88]);
    assert(buf.exposeSecretMut().ptr !is inlinePtr, "expected move to heap");

    // The abandoned inline storage must have been zeroized by reallocate().
    foreach (i; 0 .. 4)
        assert(inlinePtr[i] == 0, "inline storage was not wiped on realloc");
}

// ─────────────────────────────────────────────────────────────────────────────
// SecretString
// ─────────────────────────────────────────────────────────────────────────────

/// A UTF-8 secret string (passphrases), backed by a $(LREF SecretBuffer) of
/// `char` with 64 bytes of inline storage.
alias SecretString = SecretBuffer!(char, 64);

/**
 * Build a $(LREF SecretString) from a transient character slice.
 *
 * The caller's `source` is copied into the secret; the caller remains
 * responsible for wiping any temporary holding `source`.
 *
 * Params:
 *   source = The passphrase characters to copy.
 */
SecretString fromString(scope const(char)[] source) @safe nothrow @nogc
{
    SecretString s;
    s.put(source);
    return s;
}

@("crypto.secret.SecretString.fromString")
@safe nothrow @nogc
unittest
{
    auto pass = fromString("correct horse");
    assert(pass.length == "correct horse".length);
    assert(pass.exposeSecret() == "correct horse");
}

@("crypto.secret.SecretString.toString.redacted")
@safe nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    auto pass = fromString("hunter2");
    checkToString(pass, "SecretBuffer([REDACTED])");
}

// ─────────────────────────────────────────────────────────────────────────────
// isSecret
// ─────────────────────────────────────────────────────────────────────────────

/// Detects a type exposing an `exposeSecret` read path — the structural marker
/// for a secret container.
enum bool isSecret(T) = is(typeof((ref T s) => s.exposeSecret()));

@("crypto.secret.isSecret.detection")
@safe pure nothrow @nogc
unittest
{
    static assert(isSecret!(SecretArray!16));
    static assert(isSecret!(SecretArray!32));
    static assert(isSecret!(SecretBuffer!(ubyte, 8)));
    static assert(isSecret!SecretString);

    static assert(!isSecret!int);
    static assert(!isSecret!(ubyte[16]));

    struct NotSecret { int x; }
    static assert(!isSecret!NotSecret);
}

// ─────────────────────────────────────────────────────────────────────────────
// Private helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Writes a `size_t` as decimal digits into an output range, no allocation.
/// Used by $(LREF SecretArray.toString) to render the `N` in `SecretArray!N`.
private void writeSizeT(W)(ref W w, size_t value)
{
    if (value == 0)
    {
        w.put("0");
        return;
    }

    // size_t max is 20 decimal digits on 64-bit; 24 is comfortably enough.
    char[24] tmp = void;
    size_t i = tmp.length;
    while (value != 0)
    {
        tmp[--i] = cast(char) ('0' + (value % 10));
        value /= 10;
    }
    w.put(tmp[i .. $]);
}

@("crypto.secret.writeSizeT.digits")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeSizeT(b, 0))("0");
    checkWriter!((ref b) => writeSizeT(b, 7))("7");
    checkWriter!((ref b) => writeSizeT(b, 16))("16");
    checkWriter!((ref b) => writeSizeT(b, 32))("32");
    checkWriter!((ref b) => writeSizeT(b, 1234567890))("1234567890");
}

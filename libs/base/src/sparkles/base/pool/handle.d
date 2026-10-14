/**
Generational handles: an index plus the generation it was issued at.

A handle names one occupant of one slot. Removing the occupant advances the
slot's generation, so every handle issued before the removal stops resolving
instead of silently naming whatever the slot holds next. The tag parameter
makes handles from different pools distinct types.

See `docs/specs/base/pool.md` (`POOL1`, `POOL2`, `POOL7`).
*/
module sparkles.base.pool.handle;

import expected : Expected, err, ok;
import sparkles.base.text.errors : NoGcHook;
import sparkles.base.text.writers : writeText;

/// Why a handle did not resolve, or why a pool could not issue one.
enum PoolError : ubyte
{
    invalid, /// generation 0, or an index beyond the pool's capacity
    stale,   /// the slot's occupant was removed (and maybe replaced) since
    full,    /// no slot (or, for text, no byte) is free
}

/// A pool operation's result: a `T`, or the `PoolError` that prevented it.
/// Reading the wrong side is a bug (`NoGcHook`), not a default value.
alias PoolResult(T) = Expected!(T, PoolError, NoGcHook);

/// Constructs a successful `PoolResult`.
PoolResult!T poolOk(T)(T value) => ok!(PoolError, NoGcHook)(value);

/// Constructs a failed `PoolResult!T`.
PoolResult!T poolErr(T)(PoolError error) => err!(T, NoGcHook)(error);

/// Which freed slot `insert` hands out next.
enum Reuse : ubyte
{
    lifo, /// the most recently freed — cache-warm
    fifo, /// the least recently freed — the longest before a handle repeats
}

/// What happens to a slot whose generation cannot advance any further.
enum Wrap : ubyte
{
    /// The slot is never issued again; usable capacity shrinks by one. No
    /// handle can ever resolve after its occupant is removed.
    retire,
    /// The generation skips 0 and starts over. A handle held across a full
    /// cycle of reuses of one slot resolves again (ABA).
    skipZero,
}

/**
A generational identity issued by one pool.

`index` is the 0-based slot and `generation` the slot's generation when the
handle was issued, always ≥ 1, so `Handle.init` never resolves (`POOL1`).
Both fields are public plain data: a handle is a Regular value that can be
compared, hashed, logged and reflected over.

A handle is meaningful only to the pool that issued it (`POOL7`). The tag
separates pool $(I types), not pool instances: two pools of one type issue
equal handles, and resolving one's handle through the other is not detected.
*/
struct Handle(Tag)
{
    uint index;      /// 0-based slot
    uint generation; /// ≥ 1 for every issued handle; 0 means none

    /// Whether this could have been issued at all. Says nothing about whether
    /// it is still live — only its pool knows that.
    bool valid() const @safe pure nothrow @nogc => generation != 0;

    /// Renders `#index:generation`.
    void toString(Writer)(ref Writer w) const
    {
        w.writeText(i"#$(index):$(generation)");
    }
}

/// Whether `H` is some `Handle!Tag`.
enum isHandle(H) = is(H == Handle!Tag, Tag);

@("pool.handle.initIsInvalid")
@safe pure nothrow @nogc
unittest
{
    struct Tag {}

    assert(!Handle!Tag.init.valid);
    assert(!Handle!Tag(5, 0).valid);
    assert(Handle!Tag(0, 1).valid);
    assert(Handle!Tag(0, 1) == Handle!Tag(0, 1));
    assert(Handle!Tag(0, 1) != Handle!Tag(0, 2));
    static assert(Handle!Tag.sizeof == 8);
}

@("pool.handle.tagsSeparateTypes")
@safe pure nothrow @nogc
unittest
{
    struct A {}
    struct B {}

    static void takesA(Handle!A) {}

    static assert(isHandle!(Handle!A));
    static assert(!isHandle!uint);
    static assert(!is(Handle!B : Handle!A));
    static assert(!__traits(compiles, takesA(Handle!B(0, 1))));
    static assert(__traits(compiles, takesA(Handle!A(0, 1))));
}

@("pool.handle.toString")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkToString;

    struct Tag {}

    checkToString(Handle!Tag(3, 7), "#3:7");
}

# Own a heap value without the collector

Use `Unique` when one value must live on the heap, be freed deterministically,
and — this is the part `new` cannot give you — stay off the collected heap
while any GC references it holds stay reachable:

```d
import sparkles.base.unique;

struct Session
{
    string[] transcript; // a GC reference the block must keep alive
    ubyte[256 * 1024] scratch;
}

auto session = makeUnique!Session();
session.get.transcript ~= "hello";
// freed here, exactly once, when `session` leaves scope
```

`makeUnique` allocates from `Mallocator` by default, so a value this size
costs no GC block and triggers no collection. Because `Session` holds
indirections, the block is registered as a collector root range for as long as
the owner holds it — including while the constructor runs, so a constructor
that allocates cannot have its own references collected mid-construction.

## Move it, do not copy it

Copying is a compile error; ownership transfers explicitly:

```d
auto moved = session.move();     // or core.lifetime.move(session)
assert(session.empty);           // the moved-from owner destroys nothing
```

A `Unique` field makes its enclosing struct move-only too, which is usually
what you want for a type that owns a worker pool or a large workspace.

## Classes work the same way

`Unique!C` owns a class instance allocated outside the collected heap; `get`
yields the reference:

```d
auto widget = makeUnique!Widget(3, "dial");
widget.get.repaint();
```

## What to watch for

- **Allocation failure is a value.** A refused allocation yields an `empty`
  owner rather than throwing — check `empty` (or `if (owner)`) when the
  allocator can fail.
- **Borrowing is not tracked.** `get`, `*`, and `ptr` hand out references that
  are only valid while the owner is; the type gives ownership, not
  borrow-checking.
- **Over-aligned types need an aligned allocator.** `T.alignof` above the
  allocator's `alignment` is a compile error naming both, not a silently
  misaligned block — use `AlignedMallocator`.
- **Globals are never destroyed.** A `static`/`__gshared` owner leaks, as any
  global struct with a destructor does; call `reset` explicitly.

See the [API reference](../reference/api.md#sparklesbaseunique) for the full
surface.

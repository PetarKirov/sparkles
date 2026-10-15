---
status: accepted
owner: sparkles:base
reviewed: 2026-10-15
---

# `sparkles.base.pool` — Specification

## Abstract

`sparkles.base.pool` gives long-lived objects identities that stay safe after
their storage is reused. An identity names one occupant of one slot. Once that
occupant is removed, every copy of the identity is detectably stale, so it never
silently names whatever takes the slot next. On top of that identity the package
stores fixed records whose addresses never move, and variable-length text in one
shared buffer that can be compacted without disturbing anyone who holds an
identity. Storage is sized at compile time and lives inline, so no operation
allocates.

## Introduction

Programs refer to long-lived objects from places that outlive a single call:
an event names the window it happened in, a renderer names a texture, an
overlay names the anchor it follows. When such objects are kept in an array
and freed slots are reused, the reference has to say both _which slot_ and
_which occupant of it_. Otherwise a reference held across a removal names the
next occupant, and the mistake produces wrong behaviour rather than an error.

A plain index has exactly that flaw, and a pointer adds another: it ties the
identity to an address, so storage can never move. Reference counting keeps
the object alive instead of reporting that it is gone, and in D it makes any
`SumType` holding one unsafe to assign. Variable-length data sharpens the
problem. Text is cheap to store by appending it to one buffer, but a caller that
holds a byte offset into that buffer stops it from ever being compacted.

The approach is the [generational handle](../../glossary.md#generational-handle)
used by Rust's `slotmap`, Bevy's `Entity` and EnTT. A handle is a slot index
plus the generation the slot had when the handle was issued, and removing the
occupant advances the generation. A slot whose generation counter is exhausted
is retired rather than reused, so a stale handle stays stale; that costs one slot
per 2³² − 1 reuses of it. Callers identify
everything by handle and never by an offset into shared storage. A record's
address may be borrowed, and stays fixed while the record lives:

| Layer       | Holds                                                     | Use it when                               |
| ----------- | --------------------------------------------------------- | ----------------------------------------- |
| `Handle`    | an index and a generation                                 | always; it is the identity                |
| `SlotTable` | a generation and an occupied flag per slot, the free list | records live elsewhere, or there are none |
| `Pool`      | a `SlotTable` plus `Record[capacity]`, stored inline      | each live identity owns one record        |
| `TextPool`  | a `Pool` of byte ranges plus one byte arena               | each identity owns one immutable text     |

Stored text is immutable: changing a text means storing the new one and
releasing the old. The text pool's byte arena is sized separately from its
number of slots. Text is read through a callback, and no byte moves while one
runs, so compaction never disturbs a reader.

The package is fixed-capacity by design. A pool is a value as large as its
capacity and cannot be copied, so a large one belongs in a long-lived owner or
in heap memory its owner allocates. Growable storage, a struct-of-arrays record layout, ECS component
stores, and handles packed into one integer are outside this contract; §7
records how they would extend it. Pools are not `shared`: code that reaches one
from several threads synchronizes access itself.

§1 states the contract at a glance and §2 the API. §3–§5 specify the slot
table, the record pool and the text pool, and §6 traces each requirement to
the code and tests that satisfy it. The first consumer is
[`sparkles:wsi`](../window-system-integration/SPEC.md): each backend keeps its
windows in a `Pool`, and its event queue keeps the text its events carry in a
`TextPool` (requirement `ED8` there).

| Identifier      | Value                               |
| --------------- | ----------------------------------- |
| Dub sub-package | `sparkles:base`                     |
| Source root     | `libs/base/src/sparkles/base/pool/` |
| Package         | `sparkles.base.pool`                |

## 1. The contract at a glance

1. A handle issued by a pool resolves until its occupant is removed, and
   never again afterwards. The only exception is the opt-in `Wrap.skipZero`
   policy.
2. `Handle.init` never resolves.
3. A live record's address is fixed until the record is removed.
4. Removing a record destroys it immediately and exactly once.
5. Text is readable only inside a borrow, and no byte moves while a borrow is
   open.
6. Text is truncated only at its per-text bound. A pool that is short of
   space refuses new text rather than shortening it.
7. Every operation is `@safe pure nothrow @nogc`, unless a callback or a
   record's destructor the caller supplies is not.

## 2. API surface

```d
/// A generational identity issued by one pool. `Handle.init` is invalid.
struct Handle(Tag)
{
    uint index;      /// 0-based slot
    uint generation; /// ≥ 1 for every issued handle
    bool valid() const;
}

enum PoolError : ubyte { invalid, stale, full }
enum Reuse : ubyte { lifo, fifo }
enum Wrap : ubyte { retire, skipZero }
alias PoolResult(T) = Expected!(T, PoolError, NoGcHook);

struct SlotTable(H, size_t capacity, Reuse reuse = Reuse.lifo,
    Wrap wrap = Wrap.retire, uint generationLimit = uint.max);
    // insert, remove, resolve, isLive, liveAt, handleAt, byLive, clear

struct Pool(H, Record, size_t capacity, Reuse reuse = Reuse.lifo,
    Wrap wrap = Wrap.retire, uint generationLimit = uint.max);
    // the SlotTable operations, plus reserve, commit, cancel, insert(Record),
    // get, opIndex, at, indexOf, withRecord

struct TextPool(Tag, size_t slots, size_t bytes, size_t maxText = bytes,
    Reuse reuse = Reuse.lifo);
    // intern, withText, lengthOf, release, borrow

PoolResult!(Dst.Id) retain(Src, Id, Dst)(ref Src src, Id id, ref Dst dst);
```

## 3. Handles and the slot table

A _slot_ here is one position in a table. It is unrelated to the `sparkles:ui`
style slot of the same name. A slot is in exactly one of three states:

| State   | Entered by                                  | Left by  |
| ------- | ------------------------------------------- | -------- |
| free    | construction (generation 1), or `remove`    | `insert` |
| live    | `insert`                                    | `remove` |
| retired | `remove` when the generation cannot advance | never    |

**POOL1: The default handle is invalid.** `Handle.init`, whose generation is
0, **must** resolve to `invalid` in every table. No table **may** issue a
handle with generation 0.

**POOL2: Tags separate handle types.** A `Handle!A` **must not** convert to a
`Handle!B` implicitly, and passing one where the other is expected **must**
fail to compile.

**POOL3: A removed object's handles are stale.** After `remove(h)` succeeds,
`resolve(h)` **must** return `PoolError.stale`, `isLive(h)` **must** return
`false`, and a second `remove(h)` **must** return `PoolError.stale`. This
holds after the slot has been reused by a later `insert`.

**POOL4: Error precedence.** `resolve` **must** report `invalid` for
generation 0 or an index at or beyond the capacity, and otherwise `stale` for
a generation mismatch or a slot that is not live. `insert` **must** report
`full` only when no slot is free. A failed operation **must** leave the table
unchanged.

**POOL5: Generations advance on removal; exhausted slots retire.** `remove`
**must** increment the slot's generation. Under `Wrap.retire`, when the
increment would pass the generation limit, the slot **must** become retired
instead: it is never issued again, and the table's usable capacity shrinks by
one. Under `Wrap.skipZero` the generation restarts at 1 and the slot is
reused.

_Rationale:_ Retiring makes POOL3 hold forever, at the cost of one slot per
2³² − 1 reuses. Under `skipZero` a handle held across that many reuses of one
slot resolves again. That cost is acceptable only for handles that never
outlive a short operation, such as a completion token.

**POOL6: Reuse order.** Under `Reuse.lifo`, `insert` **must** return the most
recently freed slot; under `Reuse.fifo`, the least recently freed one. At
construction every slot counts as freed in increasing index order, so a fresh
table issues index 0 first under both policies.

_Rationale:_ LIFO reuses memory that is likely still in cache. FIFO maximizes
the time before a slot is reissued, which is longer protection under
`skipZero`.

**POOL7: Handles are pool-local.** A handle is meaningful only to the table
that issued it. Two tables of the same type issue equal handles, and resolving
one table's handle through another is not detected.

_Rationale:_ Detecting it would add a runtime owner identity to every handle.
The tag already separates pools of different types, which is where mixing
happens in practice.

## 4. The record pool

**POOL8: Records never move.** A live record's address **must** stay the same
from `reserve` until `remove`.

_Rationale:_ C code holds such addresses as callback data, such as a Wayland
listener's user data or a Win32 window's `GWLP_USERDATA`. `indexOf` maps an
address handed back by such a callback to its slot.

**POOL9: Identity before construction.** `reserve` **must** issue a live
handle whose record is `Record.init`. `commit(h, record)` moves a value into
it, and `cancel(h)` removes it again. The handle **must** be usable between
`reserve` and `commit`.

_Rationale:_ Creating a native object can call back synchronously, and those
callbacks find their record through the identity that was reserved for it.

**POOL10: Removal destroys the record exactly once.** `remove` **must** run
the record's destructor once and leave `Record.init` in the slot. `commit`
**must** destroy the value it overwrites.

_Rationale:_ A move-only member such as a `UniqueBuffer` then releases its
storage when the record is removed, rather than at the next reuse.

**POOL11: Checked access is scoped.** `get(h)` **must** return a pointer to
the record for a live handle and `null` otherwise. Under `-preview=dip1000`
that pointer **must not** outlive the pool. `withRecord(h, fn)` is the
callback form.

## 5. The text pool

The text pool generalises `DqlEngine.intern` in `sparkles:dql`: text is
appended to one byte arena and addressed by a `TextSpan`. Callers, however,
never see the span. They hold a `TextId`, which is a `Handle` into a pool of
spans. The arena can therefore reset and compact without invalidating
anything a caller holds.

**POOL12: The per-text bound is the only truncation.** `intern(text)` **must**
store at most `maxText` bytes and record that it truncated. The cut **must
not** fall before a continuation byte (`0b10xx_xxxx`), so it lands on a
code-point boundary. Invalid UTF-8 is otherwise stored as given.

_Rationale:_ Validating text is its producer's concern; the pool only refuses
to create a broken sequence that was not there.

**POOL13: Pressure fails, it never truncates.** When the arena cannot hold
the text, `intern` **must** compact (POOL15) if that frees enough room and
the pool is not borrowed. Otherwise it **must** return `full` with the pool
unchanged.

**POOL14: Text is read only inside a borrow.** The only read is
`withText(id, fn)`, which calls `fn(text, truncated)` with a `scope` slice.
While any borrow is open, the pool **must not** compact, reset or overwrite
live bytes. No accessor returns a slice.

_Rationale:_ `-preview=dip1000` stops a slice from escaping, but it cannot stop
a later `intern` from moving the bytes under one. Confining reads to a
callback makes the borrow's lifetime the callback's.

**POOL15: Compaction preserves text.** Compaction **must** move every live
text toward the start of the arena in increasing offset order and rewrite its
span. `withText` on every live id returns the same bytes before and after.

_Rationale:_ Once slots are reused, slot order is not offset order. Moving in
slot order can overwrite a text that has not moved yet.

**POOL16: Aliased input is safe.** If `intern`'s input lies inside the arena,
the pool **must not** compact during that call.

**POOL17: Release reclaims.** `release(id)` frees the slot. When no text is
live and no borrow is open, the arena **must** reset to empty.

_Rationale:_ A queue that drains fully then never needs to compact.

**POOL18: Text copies between pools.** `retain(src, id, dst)` **must** intern
the text of `id` into `dst`, carrying its truncation flag, and return the new
id or `dst`'s error.

## 6. Requirements and evidence

| ID     | Requirement                   | Status                  | Traces to                                                                                                                                 |
| ------ | ----------------------------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| POOL1  | default handle invalid        | full                    | `Handle.valid`, `SlotTable.resolve`, test `pool.handle.initIsInvalid`                                                                     |
| POOL2  | tags separate handle types    | full                    | `isHandle`, test `pool.handle.tagsSeparateTypes`                                                                                          |
| POOL3  | removed handles are stale     | full                    | `SlotTable.remove`, test `pool.slot_table.removedHandlesAreStale`                                                                         |
| POOL4  | error precedence              | full                    | `SlotTable.resolve`, test `pool.slot_table.errorPrecedence`                                                                               |
| POOL5  | advance and retire            | full                    | `Wrap`, tests `pool.slot_table.retireAtTheGenerationLimit`, `pool.slot_table.skipZeroWrapsAndReuses`                                      |
| POOL6  | reuse order                   | full                    | `Reuse`, tests `pool.slot_table.reuseOrder`, `pool.slot_table.fifoIssuesFreshSlotsFirst`                                                  |
| POOL7  | handles are pool-local        | full (documented limit) | `Handle`                                                                                                                                  |
| POOL8  | records never move            | full                    | `Pool.get`, test `pool.pool.recordsNeverMove`                                                                                             |
| POOL9  | identity before construction  | full                    | `Pool.reserve`, `Pool.commit`, `Pool.cancel`, test `pool.pool.reserveCommitCancel`                                                        |
| POOL10 | removal destroys exactly once | full                    | `Pool.remove`, tests `pool.pool.removalDestroysExactlyOnce`, `pool.pool.moveOnlyRecords`                                                  |
| POOL11 | checked access is scoped      | full                    | `Pool.get`, `Pool.withRecord`, test `pool.pool.withRecordAndEscape`                                                                       |
| POOL12 | per-text bound truncation     | full                    | `TextPool.intern`, tests `pool.text_pool.truncatesOnlyAtTheBound`, `pool.text_pool.invalidUtf8IsStoredAsGiven`                            |
| POOL13 | pressure fails                | full                    | `TextPool.intern`, test `pool.text_pool.pressureFailsNeverTruncates`                                                                      |
| POOL14 | read only inside a borrow     | full                    | `TextPool.withText`, `TextPool.borrow`, tests `pool.text_pool.noCompactionWhileBorrowed`, `pool.text_pool.callbackSliceSurvivesInterning` |
| POOL15 | compaction preserves text     | full                    | test `pool.text_pool.compactionPreservesTextInOffsetOrder`                                                                                |
| POOL16 | aliased input                 | full                    | test `pool.text_pool.aliasedInput`                                                                                                        |
| POOL17 | release reclaims              | full                    | `TextPool.release`, test `pool.text_pool.internReadRelease`                                                                               |
| POOL18 | text copies between pools     | full                    | `retain`, test `pool.text_pool.retainCopiesBetweenPools`                                                                                  |

## 7. Outside this contract

These extensions are out of scope. They are recorded so that any future layer
is designed against the requirements above rather than around them.

- **Struct-of-arrays records:** one column per record field, for passes that
  touch one field of every record. Such a layout gives up POOL8's single record
  address.
- **Growable storage:** heap columns that reallocate as the pool fills. They
  give up POOL8 entirely.
- **Dense and sparse-set layers:** swap-remove packing behind an index, and
  component stores keyed by another table's handles, as in EnTT.
- **Bit-packed handles:** for example event-horizon's
  `class:8 | generation:24 | index:32` completion token. `generationLimit`
  already lets a table respect a narrower generation field.

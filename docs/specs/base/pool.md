# `sparkles.base.pool` — Specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative for the generational pool: its handles, the slot table
that issues them, the fixed record pool over that table, and the text pool that
stores variable-length text behind handles. Status: accepted 2026-10-06;
requirements are delivered by the commits that flip their rows below. For the
library overview see [`sparkles:base`](../../libs/base/index.md)._

## 1. Overview

A long-lived object that other code refers to needs an identity that survives
the object's storage being reused. A bare index does not: once slot 3 is freed
and reallocated, an index held from before names the new occupant, and the
mistake is silent. A pointer is worse, because it also ties the identity to an
address. The answer used across the industry — Rust's `slotmap`, Bevy's
`Entity`, Daxa's resource ids, EnTT — is a **generational handle**: the slot
index plus the generation the slot was at when the handle was issued. Removing
the object advances the generation, so every outstanding handle to it is
detectably stale.

`sparkles` had nine local versions of this idea before this package (WSI's
window tables five times over, event-horizon's `OpSlab`, the diagram `World`,
dql's handle pools, the UI registries). The package is the one shared form.
It is layered, and each layer is usable on its own:

| Layer       | Holds                                                | Use it when                               |
| ----------- | ---------------------------------------------------- | ----------------------------------------- |
| `Handle`    | an index and a generation                            | always — it is the identity               |
| `SlotTable` | generations, live bits, the free list                | records live elsewhere, or there are none |
| `Pool`      | a `SlotTable` plus `Record[capacity]`, stored inline | each live identity owns one record        |
| `TextPool`  | a `Pool` of spans plus one byte arena                | each identity owns a variable-length text |

Everything is fixed capacity: the storage is sized by template parameters and
lives inline, so no operation allocates and a record's address never changes.
Growable storage, a struct-of-arrays layout and sparse-set component stores
are later layers (§7), not part of this contract.

| Identifier      | Value                               |
| --------------- | ----------------------------------- |
| Dub sub-package | `sparkles:base`                     |
| Source root     | `libs/base/src/sparkles/base/pool/` |
| Package         | `sparkles.base.pool`                |

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

struct SlotTable(H, size_t capacity, Reuse reuse = Reuse.lifo, Wrap wrap = Wrap.retire);
struct Pool(H, Record, size_t capacity, Reuse reuse = Reuse.lifo, Wrap wrap = Wrap.retire);
struct TextPool(Tag, size_t slots, size_t bytes, size_t maxText = bytes);
```

All operations are `@safe pure nothrow @nogc` except where a caller-supplied
callback or a record's own destructor infers otherwise.

## 3. Handles and the slot table

A slot is in exactly one of three states:

| State   | Entered by                                  | Left by  |
| ------- | ------------------------------------------- | -------- |
| free    | construction (generation 1), or `remove`    | `insert` |
| live    | `insert`                                    | `remove` |
| retired | `remove` when the generation cannot advance | never    |

**POOL1: The default handle is invalid.** `Handle.init` (generation 0) must
resolve to `invalid` in every table, and no table may issue a handle with
generation 0.

**POOL2: Tags separate handle types.** A `Handle!A` must not convert to a
`Handle!B` implicitly; passing one where the other is expected must fail to
compile.

**POOL3: A removed object's handles are stale.** After `remove(h)` succeeds,
`resolve(h)`, `isLive(h)` and a second `remove(h)` must report the handle as
stale (`PoolError.stale`, `false`, `false` respectively), including after the
slot has been reused by a later `insert`.

**POOL4: Error precedence.** `resolve` must report `invalid` for generation 0
or an index at or beyond the capacity, otherwise `stale` for a generation
mismatch or a slot that is not live. `insert` reports `full` only when no slot
is free. A failed operation must leave the table unchanged.

**POOL5: Generations advance on removal; exhausted slots retire.** `remove`
must increment the slot's generation. Under `Wrap.retire`, when the increment
would wrap to 0 the slot must instead become retired: it is never issued again
and the table's usable capacity shrinks by one. Under `Wrap.skipZero` the
generation skips 0 and the slot is reused; a handle held across 2³² − 1 reuses
of one slot then resolves again (ABA), which is the documented cost of that
policy.

**POOL6: Reuse order.** Under `Reuse.lifo`, `insert` must return the most
recently freed slot; under `Reuse.fifo`, the least recently freed one. At
construction every slot counts as freed in increasing index order, so a fresh
table issues index 0 first under both policies.

**POOL7: Handles are pool-local.** A handle is meaningful only to the table
that issued it. Two tables of the same type issue equal handles, and resolving
one table's handle through another is not detected; this is a documented
limitation, not a guarantee.

## 4. The record pool

**POOL8: Records never move.** A live record's address must stay the same from
`reserve` until `remove`, so it can be registered with C code (a listener's
user data, a window's `GWLP_USERDATA`).

**POOL9: Identity before construction.** `reserve` must issue a live handle
whose record is `Record.init`; `commit(h, record)` moves a value into it, and
`cancel(h)` removes it again. A handle is usable between `reserve` and
`commit`, because native creation can call back synchronously.

**POOL10: Removal destroys the record exactly once.** `remove` must run the
record's destructor once and leave `Record.init` in the slot, so a move-only
member (a `UniqueBuffer`) releases its storage at removal, not at the next
reuse. A `commit` must destroy the value it overwrites.

**POOL11: Checked access is scoped.** `get(h)` must return a reference only for
a live handle, and must not let that reference escape the pool under
`-preview=dip1000`.

## 5. The text pool

The text pool generalises `DqlEngine.intern`
(`libs/dql/src/sparkles/dql/engine.d`): text is appended to one byte arena and
addressed by a `TextSpan`. The difference is that callers never see the span.
They hold a `TextId`, a `Handle` into a pool of spans, so the arena can reset
and compact without invalidating anything a caller holds.

**POOL12: The per-text bound is the only truncation.** `intern(text)` must
store at most `maxText` bytes, cutting at a UTF-8 code-point boundary, and
record that it truncated. The cut never falls before a continuation byte
(`0b10xx_xxxx`); invalid UTF-8 is otherwise stored as given, since validating
it is the producer's concern.

**POOL13: Pressure fails, it never truncates.** When the arena cannot hold the
text, `intern` must compact (POOL15) if that frees enough room and the pool is
not borrowed, and otherwise return `full` with the pool unchanged.

**POOL14: Text is read only inside a borrow.** The only read is
`withText(id, fn)`, which calls `fn(text, truncated)` with a `scope` slice.
While any borrow is open, the pool must not compact, reset or overwrite live
bytes, so the slice stays valid for the callback's duration. There is no
accessor that returns a slice.

**POOL15: Compaction preserves text.** Compaction must move every live text
toward the start of the arena in increasing offset order and rewrite its span,
so `withText` on every live id returns the same bytes before and after,
whatever order the slots were reused in.

**POOL16: Aliased input is safe.** If `intern`'s input lies inside the arena,
the pool must not compact during that call.

**POOL17: Release reclaims.** `release(id)` frees the slot. When no text is
live and no borrow is open, the arena must reset to empty, so a pool used as a
queue's side storage never needs compaction while it drains fully.

**POOL18: Text copies between pools.** `retain(src, id, dst)` must intern the
text of `id` into `dst`, carrying the truncation flag, and return the new id or
`dst`'s error.

## 6. Requirements and evidence

| ID     | Requirement                   | Status  | Traces to      |
| ------ | ----------------------------- | ------- | -------------- |
| POOL1  | default handle invalid        | planned | `handle.d`     |
| POOL2  | tags separate handle types    | planned | `handle.d`     |
| POOL3  | removed handles are stale     | planned | `slot_table.d` |
| POOL4  | error precedence              | planned | `slot_table.d` |
| POOL5  | advance and retire            | planned | `slot_table.d` |
| POOL6  | reuse order                   | planned | `slot_table.d` |
| POOL7  | handles are pool-local        | planned | `handle.d`     |
| POOL8  | records never move            | planned | `pool.d`       |
| POOL9  | identity before construction  | planned | `pool.d`       |
| POOL10 | removal destroys exactly once | planned | `pool.d`       |
| POOL11 | checked access is scoped      | planned | `pool.d`       |
| POOL12 | per-text bound truncation     | planned | `text_pool.d`  |
| POOL13 | pressure fails                | planned | `text_pool.d`  |
| POOL14 | read only inside a borrow     | planned | `text_pool.d`  |
| POOL15 | compaction preserves text     | planned | `text_pool.d`  |
| POOL16 | aliased input                 | planned | `text_pool.d`  |
| POOL17 | release reclaims              | planned | `text_pool.d`  |
| POOL18 | text copies between pools     | planned | `text_pool.d`  |

## 7. Later layers

Recorded so they are designed against this contract, not delivered by it:

- **Struct-of-arrays records.** One column per field for systems-style passes;
  access by `field!"name"(h)`. Gives up POOL8's single record address.
- **Growable storage.** Heap columns that reallocate; gives up POOL8 entirely.
- **Dense and sparse-set layers.** Swap-remove packing behind an index, and
  component stores keyed by another table's handles (EnTT's sparse set).
- **A packed handle.** `OpToken`'s `class:8 | generation:24 | index:32` as a
  `Handle` instantiation, for event-horizon's `OpSlab`.
- **Adopters.** The diagram `World` (generations), `OverlayId` (`LYR3` in the
  popup spec), dql's string pool on `TextPool`.

---
status: draft
owner: sparkles:text-buffer
reviewed: 2026-10-21
---

# `sparkles:text-buffer` — Testing and evidence

## Oracles

**A plain byte array is the reference model.** Every text operation has an
obvious implementation over `ubyte[]`: replace is concatenation, a summary
is a count, a line lookup is a scan. The model shares no code with the
tree, so agreement after a random edit sequence is evidence the tree is
right rather than consistent with itself.

**Change-set laws are checked against the model, not each other.** Apply is
compared with the model's edit; invert, compose and mapping are then checked
by the identities in TXB-CHG3, TXB-CHG4 and TXB-CHG6, where each side is
evaluated by applying to the model.

**History is checked against an explicit list of versions.** A test keeps
every committed text in an array; undo, redo, `earlier` and `later` must
land on the array entry the navigation rule names.

## Generated tests

Generated tests follow the deterministic pseudo-random pattern of
`libs/diff/src/sparkles/diff/myers.d`: a fixed seed per test, a printed
seed and operation index on failure, and the minimized failing sequence kept
as a regular example test. Builds under `unittest` use small `minChunk`,
`maxChunk` and fan-out values so that a few hundred bytes already produce
trees several levels deep, as Zed and ropey do in their test builds.

| Scenario                                                                                                  | Requirements            |
| --------------------------------------------------------------------------------------------------------- | ----------------------- |
| Random replace/slice/append sequences over mixed ASCII, multi-byte, CR LF and malformed bytes vs. model   | TXB-TEXT1–4, TXB-POS2–3 |
| Every chunk boundary checked after every operation: no split sequence or CR LF, sizes within bounds       | TXB-TEXT3               |
| Node allocation counter around each edit compared with the TXB-TEXT6 bound                                | TXB-TEXT6               |
| Height and fan-out checked after each operation                                                           | TXB-TEXT5               |
| Copies edited independently; the original compared with a saved model                                     | TXB-TEXT1, TXB-TEXT2    |
| Chunk walks forward and backward from every position reassemble the model                                 | TXB-POS1                |
| Random edit lists (overlapping, unsorted, same-position inserts) vs. the model's union semantics          | TXB-CHG1, TXB-CHG2      |
| Invert, compose and mapping identities over random change-set pairs; CHG6 only where no edit touches p    | TXB-CHG3–6              |
| Every mapped position compared with the model's edit at both edges of every replaced range, each affinity | TXB-CHG5                |
| Touched ranges compared with a byte diff of the model before and after                                    | TXB-CHG7                |
| Equality of shared, partly shared and unshared equal texts, counting bytes read                           | TXB-TEXT7               |
| Commits with decreasing timestamps, then `earlier(d)` and `later(d)` targets                              | TXB-HIS6                |
| Counting allocator: every node allocated outside the GC heap, every one freed                             | TXB-OWN3, TXB-OWN1      |
| Summary counters checked at their type's limits through a synthetic summary                               | TXB-OWN4                |
| Every public operation compiled from an `@safe nothrow @nogc pure` unittest                               | TXB-OWN5                |
| Random commit/amend/undo/redo/earlier/later sequences vs. the version list                                | TXB-HIS1–5              |
| Live-node counter returns to zero after dropping every text, change set and history                       | TXB-OWN1                |
| Copies created and destroyed on several threads, then the live-node counter checked                       | TXB-OWN2                |

## Boundary examples

Example tests pin the cases a random generator reaches rarely: the empty
text; a text of exactly `maxChunk` bytes; an edit at position 0 and at the
end; an insertion and a deletion at the same position; a CR LF split by an
edit in its middle; a 4-byte sequence straddling the cut point the chunker
would otherwise choose; and mapping a position at both ends of an insertion
under each affinity.

## Evidence

| Evidence                              | Revision                                             | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `dub test :text-buffer` (LDC and DMD) | branch `feat/text-buffer` at `27f89284e`; 2026-10-28 | 25 of 25 tests pass under each compiler in the `unittest` configuration (8–24 byte chunks, fan-out 3–6). They cover every row of the scenario table above except the summary-counter limits of TXB-OWN4, which follow from `size_t` counters bounded by the byte count. Each of the following, when broken, failed at least one test: the CR LF cut rule, the underfull-root merge, the edge rule of `mapPos`, the keep/remove case of `compose`, timestamp clamping, redo re-pointing on travel, and pruning's childless test. An independent review confirmed four defects, each now covered by a regression test: a chunk range read after its text was reassigned, an overwritten change set that leaked, travel by time after an amend, and the column of the position between CR and LF. TXB-OWN2 is partial: there is no explicit transfer operation. |

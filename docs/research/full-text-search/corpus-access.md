# Corpus access — traversal, ignore rules, mmap, binary, encodings

Layer 4: how bytes reach the engine. The layer [thesis T1][index] predicts
matters more than the engine, and the one where every tool surveyed made a
different call.

> **Last reviewed:** August 28, 2026.

---

## Reading: `mmap` versus `read`

The field has converged, and it converged **away** from `mmap`:

| Tool                 | Policy                                                               |
| -------------------- | -------------------------------------------------------------------- |
| [GNU grep][gnu-grep] | `--mmap` existed and was **removed**                                 |
| [ripgrep][ripgrep]   | `MmapChoice::Never` by default; `auto()` is an **`unsafe fn`**       |
| [ag][ag]             | `mmap` by default                                                    |
| [ugrep][ugrep]       | `mmap.hpp` is a first-class component                                |
| [fff][fff-grep]      | A reusable read buffer for small files, fresh mmap above a threshold |

ripgrep's safety comment is the clearest statement of the hazard:

> _"The specific contract the caller is required to uphold isn't precise, but it
> basically amounts to something like, 'the caller guarantees that the underlying
> file won't be mutated.' […] However, command line tools may still decide to
> take the risk of, say, a `SIGBUS` occurring while attempting to read a memory
> map."_ `[source-verified]`

**A long-lived editor has less licence there than a CLI, not more.** A `SIGBUS`
in `rg` loses one search; a `SIGBUS` in hue loses the session. The conclusion for
Sparkles is `read` into a bounded buffer, and mmap only behind an explicit,
justified opt-in.

## The roll buffer, and why fixed capacity changes it

A line may span two reads. ripgrep's `line_buffer.rs` maintains a growable buffer
with an allocation limit so a `Matcher` always sees a whole line as one slice.
fff's vendored fork deletes the entire mechanism — _"Only `search_slice` is
supported"_ — and reads whole files instead.

For a `@nogc` fixed-capacity implementation the fork's answer is the tractable
one: **read a capped whole file, scan the slice**. That is also why the file-size
cap is a real design parameter rather than a safety valve.

## Size caps, and why fff's number is wrong for hue

[fff][fff-grep] skips files over `MAX_FFFILE_SIZE` = **10 MiB**;
[Google Code Search][gcs] indexes nothing over `1 << 30`.

The reasoning that matters is not the number but the _model_: fff caches content
in a resident process, so the tail of the size distribution is paid **once**. hue
re-reads per query, so the tail is paid **per keystroke**. Same tool shape,
different caching, an order-of-magnitude different answer — which is why this
catalog's guidance lands at ~1 MiB rather than copying 10.

## Binary detection: four positions

| Approach                                                | Who                                        | Property                                                                     |
| ------------------------------------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------- |
| **Off by default**, NUL mid-stream, `Quit`/`Convert`    | [ripgrep][ripgrep]                         | Correct; costs a decision per buffer; a CLI default a UI must override       |
| **Flag cached at index time** from a 16 KiB sniff       | [fff][fff-grep]                            | Cheapest; stale if the file changed since the walk                           |
| **Magic numbers** — ELF, PNG, JPEG, `!<arch>`           | [hypergrep][hypergrep]                     | No false positives on text; misses unknown formats                           |
| **Distinct-trigram count** per file                     | [Google Code Search][gcs]                  | Catches minified and generated files a NUL sniff misses; free while indexing |
| Three-way user policy (`binary`/`text`/`without-match`) | [GNU grep][gnu-grep], [git grep][git-grep] | The user-facing shape, orthogonal to detection                               |

`[source-verified]` throughout. There is **no consensus**, which means this is a
product decision. For hue the cheap composite is: a path/extension filter first —
`isRenderable` already exists and is what the tree pane uses, so grep and the
explorer would agree on what exists — then NUL-or-invalid-UTF-8 over the head
already read, with the prefix backed off to a lead byte so a truncated sequence at
the boundary is not a false positive.

## Traversal and ignore rules

ripgrep's `ignore` crate is the reference — a parallel walker respecting
`.gitignore`, `.ignore`, globs and type filters. Sparkles already has the
equivalent in `sparkles:build-primitives`
(`walkGitRepository`, `globWalkGitRepository`), including the precedence rule that
an explicit include beats an ignore.

The finding for the implementation is not an algorithm but a defect:
**hue's picker walks with the bare walker and re-implements the glob precedence
inline**, duplicating `passesGlobs`. A grep source needs the same walk, and
sharing one is both less code and the fix.

[git grep][git-grep] is the reminder that the filesystem is not the only corpus:
`GREP_SOURCE_{OID,FILE,BUF}` makes the source a variant, so history is searchable
without a checkout.

## Encodings

[Oniguruma][oniguruma] makes encoding a parameter object; [ugrep][ugrep] converts
on input; ripgrep supports `-E` with BOM sniffing; [fff][fff-grep] validates the
whole file as UTF-8 once and then uses unchecked per-line access, having measured
per-line checks at ~8% of runtime.

fff's trick is the one to copy — **validate once per file, then trust** — and hue
already has the primitive: `indexOfInvalidUtf8`, `@safe pure nothrow @nogc`. Full
encoding conversion is a generality hue's corpus does not need, and
[Oniguruma][oniguruma] shows what it costs.

## What this catalog concluded

1. **`read`, not `mmap`**, into a bounded buffer; whole capped files, no roll buffer.
2. **~1 MiB size cap**, because hue re-reads per query rather than caching.
3. **Layered binary detection**: extension filter, then a content sniff over the
   head already in hand.
4. **One shared repo walk** for the files and grep sources, over the real glob
   walker, which also closes an existing duplication.
5. **One UTF-8 validation per file**, then unchecked line access.

## Sources

All `[source-verified]` from the scanner deep-dives: [ripgrep][ripgrep],
[GNU grep][gnu-grep], [ugrep][ugrep], [fff-grep][fff-grep],
[hypergrep][hypergrep], [git-grep][git-grep], [ag][ag],
[Google Code Search][gcs]. Sparkles-side facts from the [baseline][baseline].

<!-- References -->

[index]: ./index.md
[ripgrep]: ./ripgrep.md
[gnu-grep]: ./gnu-grep.md
[ugrep]: ./ugrep.md
[fff-grep]: ./fff-grep.md
[hypergrep]: ./hypergrep.md
[git-grep]: ./git-grep.md
[ag]: ./silver-searcher.md
[gcs]: ./trigram-indexes/google-codesearch.md
[oniguruma]: ./oniguruma.md
[baseline]: ./sparkles-baseline.md

# Recommendations — a staged path for Sparkles

The terminus. Every milestone names its deliverable, the prior art it takes from,
the D/LDC feasibility risk, and **the measurement that would falsify it**.

> **Last reviewed:** August 28, 2026.

> [!IMPORTANT]
> This is a research conclusion, not a specification. It feeds
> [`docs/specs/hue/picker.md`][picker] and `docs/specs/fuzzy/`; the normative
> contracts land there. Where this page says "should", the spec decides.

---

## The two consumers, one engine

The survey's framing, restated because it constrains everything below: hue has
**two** content-search consumers, not one.

1. **Cross-file** — the grep source behind `<leader>/` (`PKS2`/`PKL5`/`PKL6`).
2. **In-document** — `FND`, which exists twice today and
   [disagrees with itself about case][baseline].

Both must be served by one matcher, **above the `sparkles:ui-app` seam** so it is
not implemented once per canvas, and built on `sparkles:fuzzy` so there is one
case rule. [Zed's buffer/disk split][editor] adds the requirement that makes them
genuinely one problem: the corpus is the working tree **plus modified open
documents**, and in-document search is the degenerate case with one file.

## The headline answers

### Regex: a bounded engine, and it is a re-hosting

**Recommended**, and the survey moved this from preference to evidence.

[`std.regex`'s Pike VM already runs on caller-supplied external memory][std-regex]
— one `enforceMalloc` block sized from the compiled pattern, threads from a
preallocated freelist, `GC.addRange` over the class header only. What blocks
`@safe nothrow @nogc` is the _compiler_, a process-global `matcherCache`, an OOM
throw, a range-based input model and the `dip1000` `scope` refusal. **None of that
is the matching loop.**

Scope, from [engine-comparison][engine]: **seventeen of `std.regex`'s thirty
opcodes**, dropping the thirteen concerned with captures, backreferences and
lookaround — the same refusal every guaranteeing engine makes, and the source of
the time bound. Leftmost-first, no captures, unanchored with a match-start slot,
`\b` yes, counted repetition by compile-time expansion with an error value,
`\p{…}` refused initially.

**Feasibility risk: low, and already partly retired.**
`theory/examples/pike-vm-line-search.d` runs an unanchored leftmost-first Pike VM
with a sparse-set thread list under exactly the target attributes.

**Falsified by:** a benchmark showing the Pike VM dominates a realistic grep's
wall-clock. Per T1 the prefilter and I/O should dominate; if they do not, the
engine tier needs a DFA and this recommendation's ordering is wrong.

### Index: `PKM6` stays deferred

**Not recommended now.** Three reasons, in order of force:

1. **Prefix queries defeat it.** A user typing `re`, `ren` extracts no trigram
   obligation for the first keystrokes — the index cannot help exactly when
   latency is most visible.
2. **A working tree is T2's adversarial case.**
3. **The unindexed path is needed anyway**, for verification and for short
   queries. It is the prerequisite, not a detour.

**If it is ever added**, the evidence points at [ugrep's per-file filter][ugrep] —
one changed file rewrites one filter — not global postings. Positional trigrams
(Zoekt's shape) are for a static corpus, i.e. git history.

**Falsified by:** measured whole-repo scan latency exceeding the frame budget on a
realistic tree at `grepMaxFileKiB`, with the prefilter in place.

### Ranking: structural, not statistical

**Do not adopt BM25.** Term frequency is an anti-signal in code, IDF is distorted
by generated files, and length normalisation punishes the short focused files
people want. Keep the composite formula hue already has, and add
definition-versus-mention as a term.

**Take the mechanics, not the model**: bounded top-`k` with score-bound early exit,
which `sparkles:fuzzy`'s `TopK` is already shaped for.

## The staged path

### S1 — Close the case-rule defect _(prerequisite, independent of everything else)_

**Deliverable:** one `smartCase(pattern)` and one substring primitive above the
`ui-app` seam, replacing both in-document searches.

**Prior art:** the smart-case convention as fzf/rg/fff define it;
`sparkles:fuzzy`'s "uppercase _cased scalar_" formulation, which is the careful one.

**Risk:** low. **Falsified by:** nothing — this is a defect fix. A user searching
`Foo` currently gets different results in `--tui` and `--gui`.

### S2 — The literal prefilter

**Deliverable:** `indexOfIC` promoted out of `tui.d` into `sparkles.base.text`,
then a packed-pair finder over a byte-frequency table derived from this
repository's own corpus, with Two-Way as the adversarial fallback.

**Prior art:** [memchr's packed pair][prefilters] — rare-byte selection by
background frequency, degrading to `memchr` without SIMD; Two-Way's constant-space
guarantee.

**Risk:** low. All three algorithms are `@safe pure nothrow @nogc` with fixed
tables. **Falsified by:** `memmem-vs-naive` measurement showing the naive scan is
within noise on realistic needles — in which case ship naive and stop.

### S3 — Corpus access

**Deliverable:** a bounded `readCapped`, a content binary sniff over the head
already read, `LineIndex`-free line iteration inside the job, and **one shared repo
walk** for the files and grep sources.

**Prior art:** [fff's vendored searcher][fff-grep] for "whole capped slice, no roll
buffer"; [ripgrep][ripgrep] for the mmap refusal; [hypergrep][hypergrep] and
[Google Code Search][gcs] for the binary-detection positions; `isRenderable` for
the path filter, which makes grep and the explorer agree on what exists.

**Decisions the spec must make** (the survey found no consensus): the size cap
(~1 MiB, because hue re-reads per query where fff caches), and the binary policy.

**Risk:** medium — this is the part with no existing facility. **Falsified by:**
whole-file reads blowing the frame budget on a realistic tree, which would force
an intra-file cursor.

### S4 — Match handling and the row model

**Deliverable:** a 512-byte stored window with elision, leading-whitespace
trimming that keeps the reported column true, stored match ranges, and the
`GrepMatch`-shaped row.

**Prior art:** [fff's `GrepMatch`][fff-grep] — file index, 1-based line, byte
column, **absolute byte offset so the preview can seek without scanning**,
truncated line, span list. [ripgrep's][ripgrep] `--max-columns-preview` for the
"truncate and say so" behaviour.

**Risk:** low. 512 bytes keeps every line inside `maxDpUnits`, so scoring never
silently degrades. **Falsified by:** user reports of matches lost past the window
— fixable by sliding it, which the design already does.

### S5 — The interactive contract _(mostly reuse)_

**Deliverable:** a per-file budget, generation cancellation polled **every file**,
a soft-limited resumable cursor, and counters.

**Prior art:** [fff][fff-grep] is the only source; [git-grep][git-grep] for ordered
output under parallelism. Two deliberate departures, both justified in
[interactive-contracts][interactive]: poll every file rather than every eighth
(fff's interval is a per-line artifact), and **do not** port the "refuse to abort
before two matches" rule, since hue already publishes ranked partial pages.

**Risk:** low — `PickerScheduler` already has the generation counter, the duration
budget and the synchronous fallback. **This is the field's hardest-won property
and hue already has it.**

### S6 — Fuzzy mode

**Deliverable:** exact subsequence admission (`maxTypos = 0`) over the stored
window, with span, density and gap filters.

**Prior art:** [fff's quality filters][approximate], each carrying the concrete
failure it prevents; its **distinct-character prefilter derived from the budget**,
which is nearly free and rejects most files.

**Risk:** low. **Falsified by:** users reporting that real typos are not tolerated
— at which point the primitive is [Myers' bit-vector distance][bitparallel] over
the window, _not_ a wider budget on the path scorer.

### S7 — Definition classification (`PKL6`)

**Deliverable:** a byte heuristic during the scan; tree-sitter refinement on the
selected row only, from the parse the preview already performed.

**Prior art:** [fff's `classify.rs`][fff-grep] for the shape — and explicitly not
for its content: it is a self-described POC, language-agnostic, and it never
checks that the match falls inside the identifier its keyword introduces.
[Zoekt][zoekt] for the principle: **do the expensive classification once, where it
is affordable, and let the cheap one rank.**

**Risk:** low. **Falsified by:** the heuristic's false-positive rate making the
ranking worse than no boost, measurable against a hand-labelled sample.

### S8 — Regex mode

**Deliverable:** the bounded engine above, behind the `LineMatcher` seam, with
`poolEligible(GrepMode)` so a non-`@nogc` outcome degrades one mode rather than
the design.

**Prior art:** [`std.regex`][std-regex] for the IR and the memory model,
[`regex-automata`][rust-regex] for the refusal list and size limits,
[.NET][dotnet] for **minterms** — the survey's most under-adopted idea, and the
one it recommends taking.

**Risk:** the schedule risk of the whole milestone, which is why it is last and
stubbed until then.

## Explicitly deferred, with reasons

| Deferred                 | Reason                               | Revisit when                             |
| ------------------------ | ------------------------------------ | ---------------------------------------- |
| Content index (`PKM6`)   | Prefix queries defeat it; T2         | Measured scan latency exceeds the budget |
| SIMD                     | No prefilter exists to vectorise yet | S2 ships and measurement asks for it     |
| Runtime ISA dispatch     | Nothing to dispatch between          | The first multi-versioned routine        |
| GPU                      | No compute path; T4 unresolved       | Never, for interactive search            |
| BM25 / inverted index    | Wrong model for code                 | —                                        |
| Suffix / self-indexes    | Space and rebuild cost               | Git-history search becomes a requirement |
| Structural search        | A parse per file; different question | As an explicit mode over a bounded set   |
| Full encoding conversion | hue's corpus is UTF-8 or bytes       | —                                        |

## The measurements that would change this page

1. **`memmem-vs-naive`** on a realistic corpus — decides whether S2 is worth it.
2. **`scanOneFile` throughput** per mode — decides whether whole-file work units
   hold, and whether the engine tier needs a DFA.
3. **Whole-repo scan latency** at the size cap — the T2 trigger for reopening
   `PKM6`.
4. **Classifier precision** against a hand-labelled sample — decides whether the
   definition boost helps.

All four are in-process, on a designated local runner, never in CI — per the
[measurement protocol][measurement].

<!-- References -->

[picker]: ../../specs/hue/picker.md
[baseline]: ./sparkles-baseline.md
[editor]: ./editor-search.md
[std-regex]: ./std-regex.md
[rust-regex]: ./rust-regex.md
[dotnet]: ./dotnet-nonbacktracking.md
[engine]: ./engine-comparison.md
[ugrep]: ./ugrep.md
[zoekt]: ./trigram-indexes/zoekt.md
[gcs]: ./trigram-indexes/google-codesearch.md
[fff-grep]: ./fff-grep.md
[ripgrep]: ./ripgrep.md
[hypergrep]: ./hypergrep.md
[git-grep]: ./git-grep.md
[prefilters]: ./literal-prefilters.md
[approximate]: ./approximate-search.md
[bitparallel]: ./theory/bit-parallel.md
[interactive]: ./interactive-contracts.md
[measurement]: ./measurement.md

# Interactive contracts — budget, cancellation, cursor, streaming

What a search backend must expose so a UI stays responsive. Answers research
question 11, and it is the dimension on which every general-purpose scanner in
this catalog scores **zero**.

> **Last reviewed:** August 28, 2026.

---

## The scoreboard

| Tool                                                   | Budget           | Cancel            | Cursor             | Partial results       |
| ------------------------------------------------------ | ---------------- | ----------------- | ------------------ | --------------------- |
| [GNU grep][gnu-grep]                                   | —                | —                 | —                  | —                     |
| [ripgrep][ripgrep]                                     | —                | —                 | —                  | —                     |
| [ag][ag], [git grep][git-grep], [hypergrep][hypergrep] | —                | —                 | —                  | —                     |
| [ugrep][ugrep] `-Q`                                    | —                | in-process TUI    | —                  | incremental redisplay |
| **[fff][fff-grep]**                                    | `time_budget_ms` | `Arc<AtomicBool>` | `next_file_offset` | yes, with counters    |
| [livegrep][livegrep]                                   | —                | —                 | —                  | served, incremental   |

**Only fff has the full set**, which is why `picker.md` names it as hue's design
source for exactly this — and why the [fuzzy-matching][fuzzy] tree's
`tick(budget) → Status{changed, running}` contract had to be assembled from
picker hosts rather than from a search tool.

## How everyone else gets these properties

**By killing a process.** telescope's `live_grep`, snacks.picker's grep source and
fzf's `change:reload(rg …)` all work the same way: debounce the keystroke, spawn
a searcher, parse `path:line:col:text`, and when the query changes, kill it and
spawn another. In-flight output is discarded.

That works, and it has three costs a resident implementation avoids: process spawn
per keystroke, no partial-result contract (output is a stream that either arrives
or is thrown away), and no way to _resume_ — a killed search restarts from the
beginning even when the query only got longer.

## The four properties, and what the field teaches about each

### Budget

fff's `time_budget_ms` is checked **between files**, not between lines, and
`0` means unlimited. The unit of work matters: a per-file check is cheap and
coarse, and it bounds latency to one file's scan.

The wrinkle worth knowing: fff's plain and regex paths refuse to honour the abort
until at least **two matches exist** — so a query with one match runs past its
deadline — while the fuzzy path checks unconditionally. Two paths, two rules, no
comment acknowledging it. `[source-verified]`

### Cancellation

An external `Arc<AtomicBool>` that _"overrides the picker's internal cancellation
flag"_, polled **every 8th file** to amortise the atomic. `[source-verified]`

The polling interval is a function of the work unit. fff's inner loop is per-line,
where a branch matters; a per-file loop can poll every file for free — which is
why this catalog's implementation guidance departs from fff here rather than
copying the constant.

### Cursor

`file_offset` in, `next_file_offset` out, `0` meaning "no more". File-granular,
**soft** page limit — the file that fills the page completes rather than being
truncated — with `files_consumed` tightened so the next page resumes correctly.
`[source-verified]`

The soft limit is the good idea: a hard cut mid-file leaves a page whose last
entry is arbitrary and a cursor that must encode an intra-file position.

### Partial results, and what the UI needs to say

fff's `GrepResult` carries `total_files`, `filtered_file_count`,
`total_files_searched` and `files_with_matches`. Those are not statistics — they
are what lets a UI render "332 / 2350" honestly instead of implying completeness
it does not have.

## Stable ordering

The property nobody advertises and everybody needs. [git grep][git-grep] is the
one tool surveyed that _guarantees_ it under parallelism: a producer/consumer ring
split into `[todo_done, todo_start)` and `[todo_start, todo_end)`, so work
completes out of order while output stays in corpus order. `[source-verified]`
[ripgrep][ripgrep]'s parallel walk gives this up.

For a picker, ordering instability is worse than latency: **a list that reorders
under the cursor is unusable even when every individual answer is correct.** hue's
existing answer is better than either — a globally-ranked bounded top-K
republished per generation, with selection preserved by candidate id — because
ranked order is stable by construction rather than by scheduling.

## First-result latency, not throughput

[Thesis T5][index] restated: above a few hundred milliseconds the query has
already changed, so total scan time is nearly irrelevant. What matters is when the
first row can be shown and how fast a cancelled search stops consuming.

The [measurement protocol][measurement] therefore measures this dimension
**in-process**, not by timing a binary: `fork`/`exec` dominates at the scales
where interactive latency is decided.

## What this catalog concluded

The contract hue's grep source needs, with the field's evidence behind each part:

1. **A wall-clock budget checked between whole files** — coarse is fine, and one
   file bounds the overshoot.
2. **Cancellation via a monotonic generation counter, polled every file** — hue
   already has this in its scheduler; fff's every-8th interval is a per-line
   artifact and buys nothing here.
3. **Honour cancellation immediately.** Do not port the ≥2-matches rule: hue
   already publishes globally-ranked partial pages, so an early stop still shows
   something.
4. **A resumable file-granular cursor with a soft limit.**
5. **Counters alongside results**, so the UI can be honest about completeness.
6. **Stable order by construction** — ranked top-K, not scheduling luck.

## Sources

`[source-verified]`: [fff-grep][fff-grep] (budget, abort, cursor, counters),
[git-grep][git-grep] (the ordered ring), [ugrep][ugrep] (`-Q`),
[ripgrep][ripgrep] and the other scanners for the absences. The spawn-per-keystroke
pattern is surveyed in [live-grep-hosts](./live-grep-hosts.md).

<!-- References -->

[gnu-grep]: ./gnu-grep.md
[ripgrep]: ./ripgrep.md
[ag]: ./silver-searcher.md
[git-grep]: ./git-grep.md
[hypergrep]: ./hypergrep.md
[ugrep]: ./ugrep.md
[fff-grep]: ./fff-grep.md
[livegrep]: ./livegrep.md
[fuzzy]: ../fuzzy-matching/index.md
[index]: ./index.md
[measurement]: ./measurement.md

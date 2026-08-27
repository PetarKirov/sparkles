# Live-grep hosts — telescope, snacks.picker, fzf `reload`

Three pickers, one architecture: spawn a searcher per keystroke, parse its
output, kill it when the query changes. The pattern hue is deliberately not
following, and the page that says what that choice costs and buys.

> **Last reviewed:** August 28, 2026.

---

## The shared shape

| Host                           | Mechanism                                                                                                                               |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| **telescope.nvim** `live_grep` | `job_start` an `rg --column --line-number --no-heading --color=never` per query; parse `path:line:col:text`; kill on the next keystroke |
| **snacks.picker** grep source  | Same, integrated with its own `tick`/generation model                                                                                   |
| **fzf** `change:reload(rg …)`  | A key-binding action: on query change, re-run the command and replace the candidate list                                                |

fzf's is the most interesting, because `reload` turned a _filter_ into a
**live-grep host** without fzf gaining any search capability at all. The
[fuzzy-matching][fuzzy] tree surveys fzf as a matcher; here it appears only as a
consumer.

All three parse the same wire format — `path:line:col:text` — which is, in effect,
the field's interchange protocol for content search.

## What the pattern gets right

**Composition.** Any searcher that prints that format plugs in. Users swap `rg`
for `ugrep`, add flags, pipe through filters. That is real value, and it is why
the pattern persists despite its costs.

**Simplicity.** No search code in the picker. Cancellation is `kill`, and
backpressure is the pipe.

**Robustness.** A crashing searcher takes down a subprocess, not the editor.

## What it costs

**A process per keystroke.** Debouncing hides it, but the floor is spawn plus
dynamic linking plus a fresh walk — and the walk is repeated in full for every
query, since the process keeps nothing.

**No partial-result contract.** Output is a stream that either arrives before the
kill or is discarded. There is no "here are the best 20 so far, still searching",
because the searcher has no ranking and the host has no cursor.

**No resume.** Typing `re` → `ren` → `rend` restarts from the top three times,
even though each query is strictly narrower than the last. This is exactly what
`sparkles:fuzzy`'s `QueryView.refines(previous)` probe exists to exploit, and it
is unavailable across a process boundary.

**Parsing an ambiguous format.** `path:line:col:text` is ambiguous when paths
contain colons, which is why every host has bug reports about Windows drive
letters — the same hazard `PKQ4`'s location parser guards against.

**No structural information.** The searcher has already discarded everything the
host might rank by: whether the line is a definition, how the match scored, where
the spans are. [fff][fff-grep] computes `is_definition` at match time explicitly
_"so output formatters don't need to re-scan"_ — a resident engine can afford that
and a text protocol cannot carry it.

## Why hue is not doing this

Not aesthetics. Four of `PIK`'s requirements are unreachable through a subprocess:

- **`PIK5`** — a real duration budget with globally-ranked _partial_ results.
- **`PIK6`** — no allocation on the keystroke path. A spawn is not that.
- **`PIK7`** — generation-based cancellation with stale results rejected, rather
  than a `SIGKILL` race.
- **`PKR1`** — composite ranking over frecency, git status and path distance,
  which needs the corpus and the history in the same process.

And the [baseline][baseline] adds a fifth consideration: hue must run as an
**Android APK**, where spawning `rg` is not an option at all.

## The one thing worth copying

**The wire format as a boundary, not as a protocol.** `path:line:col:text` is a
poor serialization but a good _model_ — it is exactly the fields a row needs, and
[fff's `GrepMatch`][fff-grep] is the same model with the ambiguity removed and the
spans added. A resident implementation should produce that shape in memory rather
than reinventing what a grep row is.

## Sources

`[literature]`: telescope.nvim's `live_grep` and `make_entry.gen_from_vimgrep`;
snacks.picker's grep source (cloned at `neovim/snacks.nvim`); fzf's `reload` and
`change:reload` actions. The matcher side of fzf and snacks is surveyed in
[`fuzzy-matching/`][fuzzy]. The resident alternative is [fff-grep][fff-grep];
the contract it exposes is [interactive-contracts](./interactive-contracts.md).

<!-- References -->

[fuzzy]: ../fuzzy-matching/index.md
[fff-grep]: ./fff-grep.md
[baseline]: ./sparkles-baseline.md

# Vim syntax & Emacs font-lock (C / Emacs Lisp)

The classic **in-process editor engines**, surveyed together because each contributes one mechanism the rest of the cluster lacks: Vim's **`:syn sync`** — re-deriving highlighting state _backwards_ from an arbitrary redraw position, the only engine that can start mid-file without a checkpoint or a whole-buffer parse — and Emacs' **jit-lock** — fontifying _only what becomes visible_, on demand, with idle-time background repair. Both are regex/syntax-table machines with no parse tree, hard cost ceilings, and decades of production hardening; both eventually grew tree-sitter escape hatches.

| Field                      | Value                                                                                                                                                 |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                   | Vim: C (`src/syntax.c`) + Vimscript syntax files; Emacs: Emacs Lisp (`font-lock.el`, `jit-lock.el`, `syntax.el`) over C redisplay                     |
| License                    | Vim: Vim License (charityware); Emacs: GPL-3.0-or-later                                                                                               |
| Repository                 | [`vim/vim`][vim-repo] · [`emacs-mirror/emacs`][emacs-repo] (Savannah mirror)                                                                          |
| Documentation              | [`runtime/doc/syntax.txt`][vim-syntax-txt] + `options.txt`; Emacs Lisp manual (`doc/lispref/modes.texi`) + library commentaries                       |
| Key authors                | Bram Moolenaar (Vim; syntax highlighting shipped in 5.0, Feb 1998); Jamie Zawinski (font-lock, 1992, Lucid Emacs) + Emacs maintainers                 |
| Category                   | Syntax highlighting — in-process editor engines (regex + syntactic state, windowed)                                                                   |
| Algorithm / grammar class  | Vim: per-window `:syn keyword`/`match`/`region` items (start/skip/end patterns, containment); Emacs: syntax-table pass + `font-lock-keywords` regexes |
| Lexing model               | Vim's own regex engine over buffer lines; Emacs regex + `parse-partial-sexp` syntactic scanning                                                       |
| Output                     | Editor display attributes (highlight groups → `:highlight`; faces via text properties)                                                                |
| Highlighting / theme model | Vim: syntax groups linked to highlight groups, colorschemes; Emacs: faces, per-mode keyword levels (`font-lock-maximum-decoration`)                   |
| Latest release             | Pins: vim `834b8d21` (v9.2.x, 2026-07-03); emacs `b22a3be` (2026-06-25, depth-1)                                                                      |

> [!NOTE]
> One combined deep-dive (the `bison-yacc`/Parsec-family precedent): the subject is the two load-bearing mechanisms and their cost models, not exhaustive surveys of either editor. Vim facts ground in `src/syntax.c`, `runtime/doc/{syntax,options}.txt`, `version5.txt`; Emacs facts in `lisp/{font-lock,jit-lock}.el`, `lisp/emacs-lisp/syntax.el`, `doc/lispref/modes.texi`, `etc/NEWS.*`. Their modern successors — [tree-sitter consumption in editors][helix], Emacs 29's `treesit.el` — are covered where they close each engine's documented gaps.

---

## Overview

### What it solves

Both engines answer the question a windowed display forces and no batch highlighter faces: **the screen shows the middle of the file — what state is the syntax in at the top of the window?** Vim's documentation states it as the founding problem ([`syntax.txt:5286-5288`][vim-syntax-txt]):

> _"Vim wants to be able to start redrawing in any position in the document. To make this possible it needs to know the syntax state at the position where redrawing starts."_

Emacs attacks the same economics from the other side — don't compute what isn't visible ([`jit-lock.el:194-198`][jit-lock-el]): _"initial fontification of the whole buffer does not occur. Instead, fontification occurs when necessary, such as when scrolling through the buffer would otherwise reveal unfontified areas. This is useful if buffer fontification is too slow for large buffers."_

### Design philosophy

1. **State is derived, cached, and disposable — never authoritative.** Vim caches per-line state stacks (`b_sst_array`) for _"all displayed lines, and states for 1 out of about 20 other lines"_ ([`structs.h:3176-3181`][vim-structs-h]) and **re-derives** anything missing by syncing; Emacs caches `parse-partial-sexp` results (`syntax-ppss`) and flushes the cache from the edit position on every change. Neither keeps a tree; both keep _just enough syntactic state to restart_.
2. **Cost ceilings are user-visible options.** Vim ships `'synmaxcol'` (default 3000 — columns beyond it simply aren't highlighted) and `'redrawtime'` (default 2000 ms — past it, _"syntax highlighting is disabled until CTRL-L is used"_). Emacs ships chunk sizes and idle timers. Degradation is configuration, not accident — the most explicit cost-model surface in the cluster.
3. **The regex confession.** Emacs' font-lock commentary admits the whole family's ceiling in one famous passage ([`font-lock.el:93-97`][font-lock-el]): _"Yes, obviously just about everything should be done in a single syntactic pass, but the only syntactic parser available understands only strings and comments. Perhaps one day someone will write some syntactic parsers for common languages and a son-of-font-lock.el could use them…"_ — written circa 1990s; `treesit.el` (Emacs 29) is that son-of-font-lock, thirty years later.

---

## How it works

### Vim: items, containment, and per-line state stacks

A syntax file declares three item kinds ([`syntax.c:31-37`][vim-syntax-c]): keywords, `match` items (one pattern), and `region` items (_"n start patterns, one skip pattern and m end patterns"_) — with containment (`contained`, `contains=`), transparency, and priority rules layered on. The engine scans window lines against the active items, maintaining a **state stack** of open regions (`current_state`); each displayed line's entry state is cached in `b_sst_array[]` — _"the state stack for the start of one line … This avoids having to recompute the syntax state too often"_ — invalidated per entry (`sst_change_lnum`) on edits. Functionally this is the [TextMate model's][sh-tm] carried-stack design, invented independently and instrumented with an explicit cache.

### `:syn sync` — starting mid-file by looking backwards

When the window shows line 5 000 and no cached state exists, Vim **synchronizes**: four documented strategies, each an accuracy/cost trade ([`syntax.txt:5292-5301`][vim-syntax-txt]):

1. **`sync fromstart`** — parse from line 1: _"This makes syntax highlighting accurate, but can be slow for long files. Vim caches previously parsed text, so that it's only slow when parsing the text for the first time. However, when making changes some part of the text needs to be parsed again (worst case: to the end of the file)."_
2. **`sync ccomment`** — exploit known C-comment structure to decide in/out of comment (with a documented accuracy hole when strings contain `*/`).
3. **`sync minlines={N}`** — just back up N lines and parse forward: _"{N} extra lines need to be parsed, which makes this method a bit slower."_
4. **`sync match/region` patterns** — **search backwards for a sync pattern** ([`syntax.txt:5380-5386`][vim-syntax-txt]): _"The idea is to synchronize on the end of a few specific regions, called a sync pattern. Only regions can cross lines, so when we find the end of some region, we might be able to know in which syntax item we are. The search starts in the line just above the one where redrawing starts. From there the search continues backwards in the file."_ — cheap because _"the search for the sync point can be much simpler than figuring out the highlighting. The reduced number of patterns means it will go (much) faster."_

All bounded by `minlines`/`maxlines`, with resync amortized so backwards scrolling doesn't resync every line (start _"further back … it resyncs only one out of N lines"_, [`syntax.c:608-613`][vim-syntax-c]). **This is the cluster's only answer to cold mid-file highlighting that needs neither a checkpoint ([syntect]/[Shiki][shiki]) nor a whole-buffer parse ([tree-sitter-highlight]):** grammar-authored heuristics that re-derive state from _below_ the window, accepting bounded inaccuracy for bounded cost.

### Vim's ceilings: `synmaxcol` and `redrawtime`

Two options make the cost model explicit ([`options.txt`][vim-options-txt]): `'synmaxcol'` (default **3000**) — _"In long lines the text after this column is not highlighted and following lines may not be highlighted correctly, because the syntax state is cleared. This helps to avoid very slow redrawing for an XML file that is one long line."_ — the ancestor of [bat]'s 16 KiB guard, per _column_ and honest about the state consequence; and `'redrawtime'` (default **2000 ms**) — a per-window wall-clock budget past which _"syntax highlighting is disabled until CTRL-L"_ — the ancestor of [Shiki][shiki]'s time budget, at whole-window granularity with sticky disablement.

### Emacs: three passes, a state cache, and the multiline hole

Font-lock fontifies in documented passes ([`font-lock.el:63-85`][font-lock-el]): the _syntactic_ pass colors strings/comments using the buffer's **syntax table** — via a parsing function, _"necessary because generally strings and/or comments can span lines"_ — then the _keyword_ pass runs `font-lock-keywords` regexes (at a per-mode decoration **level**: _"The higher the level, the more decoration, but the more time it takes to fontify"_). The syntactic state comes from **`syntax-ppss`** ([`syntax.el:606-617`][syntax-el]) — _"Parse-Partial-Sexp State at POS"_ — a cached incremental scan equivalent to running `parse-partial-sexp` from the buffer start, reusing the nearest cached position and **flushed from the edit point** on every modification (`syntax-ppss-flush-cache`). The documented weakness is the same one every line/region-scanned engine has ([`modes.texi:4165-4173`][modes-texi]): _"elements of `font-lock-keywords` should not match across multiple lines; that doesn't work reliably, because Font Lock usually scans just part of the buffer, and it can miss a multi-line construct that crosses the line boundary where the scan starts."_ — patched by `font-lock-multiline` properties and jit-lock's contextual repair pass.

### jit-lock — render-driven laziness

`jit-lock-mode` hooks fontification into **C redisplay** (_"Just-in-time fontification, triggered by C redisplay code"_, [`jit-lock.el:26`][jit-lock-el]): when the display engine is about to show unfontified text, `jit-lock-function` fontifies exactly one chunk (`jit-lock-chunk-size`, default **1500** chars — _"a little over the typical number of buffer characters which fit in a typical window"_). Two background tiers complete the design: **stealth** fontification of the rest of the buffer during idle time (`jit-lock-stealth-time`, off by default; nice/load throttles), and **deferred contextual** refontification (`jit-lock-context-time`, 0.5 s) that repairs text _after_ an edit whose syntactic context changed — _"useful where strings or comments span lines"_ — closing the multiline hole asynchronously. Made the default engine in Emacs 21 (2001), superseding Lazy Lock. This is the purest expression of the **render-on-demand** discipline that [Helix][helix] implements with windowed queries and [`@lezer/highlight`][lezer-hl] with `from`/`to` — here driven directly by the display engine, with correctness repair explicitly deferred to idle time.

---

## Algorithm & grammar class

- **Both are regex-family, tree-free engines:** Vim = ordered pattern items + containment over a region stack; Emacs = syntax-table scanning + keyword regexes. Multiline structure exists only as carried/derived _state_ — the same class as [TextMate][sh-tm]/[Pygments][pygments], predating both as editor infrastructure (font-lock 1992; Vim 5.0 1998).
- **Grammars are per-editor dialects** (Vimscript syntax files; elisp keyword lists) — no shared corpus, the historical cost that grammar-as-data ecosystems later solved.
- **The distinctive algorithms are the state-recovery ones:** backward sync search (Vim) and cached incremental `parse-partial-sexp` (Emacs) — both O(window + bounded-lookback) instead of O(file).

## Interface & composition model

- **Per-buffer, per-window, deeply editor-integrated:** Vim's items and highlight-group links are set by `:syntax` commands per filetype; Emacs' keywords/faces per major mode, with fontification functions on change/display hooks. Nothing is a library; everything is a convention inside the editor.
- **User-tunable degradation** is part of the interface (`synmaxcol`, `redrawtime`, decoration levels, jit-lock timers) — the engines _negotiate_ cost with the user rather than hiding it.
- **Escape hatches grew inward:** Neovim and Emacs 29 both graft [tree-sitter][ts-highlight] under the same display machinery (`treesit-font-lock-rules`: _"captured nodes are highlighted with the capture name as its face"_) — the old engines' windowing/display integration survives; only the classifier is replaced.

## Performance

- **Windowed by construction:** both engines spend proportional to the _display_, not the file — Vim via sync + per-line caches, Emacs via jit-lock chunks — the property every batch engine in this survey must bolt on.
- **Explicit worst-case controls:** 3000-column cutoff, 2000 ms redraw budget with sticky disable (Vim); chunking + idle/stealth throttles (Emacs' defaults: 1500 chars, 0.5 s context delay, stealth off).
- **The known pathologies are documented, not hidden:** Vim's long-line XML case (the `synmaxcol` rationale), sync inaccuracy trade-offs per strategy, Emacs' multiline miss — decades of issue-tracker wisdom condensed into options and manual nodes.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — editor-native indirection:** Vim syntax groups **link** to highlight groups (`hi link javaString String`), so colorschemes style a small conventional set (`String`, `Comment`, `Keyword`, …) — the same open-vocabulary-with-conventional-core solution as [Pygments][pygments]' taxonomy or [IntelliJ][intellij]'s fallback keys. Emacs uses **faces** with per-mode keyword lists and decoration levels.
- **Inter-unit state — derived syntactic state, cached and re-derivable:** Vim's per-line region stacks (displayed lines + 1-in-~20 others), Emacs' `syntax-ppss` position cache. Neither checkpoints for _resume_ like [syntect]/[Shiki][shiki] — they re-derive on demand, which is precisely what makes backward sync possible.
- **Theme resolution — editor themes** (colorschemes/faces) over the conventional group vocabulary; terminal tiering handled by the editors' own display layers.
- **Rendering targets — the editor display only;** the transferable designs are the sync strategies and the render-driven laziness, not any output path.

## Error handling & recovery

- **Mis-highlighting is the accepted failure mode,** and _bounded_ by design: Vim's sync strategies trade known inaccuracy windows for speed (each documented — the ccomment/string hole, `minlines` misses); `synmaxcol` explicitly warns that state is cleared past the limit; Emacs' multiline constructs may miss until the contextual pass repairs them.
- **Cost failure degrades visibly and recoverably:** `redrawtime` exhaustion disables highlighting with a documented re-enable (CTRL-L); jit-lock simply shows unfontified text until the chunk runs.
- **Nothing ever errors on content** — forty years of hostile input between them; the [degrade-gracefully][sh] posture in its original habitat.

## Ecosystem & maturity

- **Deployment measured in decades and default installs:** Vim's engine (5.0, February 1998) runs in every `$EDITOR` context; font-lock (1992, Zawinski/Lucid; jit-lock default since Emacs 21.1, October 2001) in every Emacs. Corpus: hundreds of syntax files / major modes maintained in-tree and by communities.
- **Both are now legacy-with-successors:** Neovim and Emacs 29+ prefer tree-sitter where grammars exist, keeping the classic engines as the universal fallback — a live case study of [precise-mode adoption economics][sh] (the regex engine survives because grammar coverage and zero-setup still win).
- **The mechanisms outlive the engines:** backward sync and render-driven laziness are cited (and needed) far beyond their birthplaces — including by [`sparkles:syntax`][sh-fit].

---

## Strengths

- **Vim's `:syn sync`: the only cold mid-file start in the survey** — bounded backward re-derivation with grammar-authored sync points, no checkpoints, no full parse.
- **Emacs' jit-lock: render-driven laziness done completely** — visible-first, idle-repair, contextual fix-up, all throttleable.
- **Explicit, user-facing cost ceilings** (`synmaxcol`, `redrawtime`, chunk/idle knobs) — honest degradation as configuration.
- **Cheap derived-state caches** (per-line stacks; ppss positions) — minimal memory for maximal restartability.
- **Unmatched production hardening** across every terminal, filetype, and pathological buffer since the 1990s.

## Weaknesses

- **Regex-family precision ceilings,** plus each engine's documented hole: sync inaccuracy windows (Vim), multiline misses pending repair (Emacs).
- **Per-editor grammar dialects** — no shared corpus, no reuse outside the editor; the exact problem grammar-as-data solved.
- **Notoriously slow syntax files exist** (Vim's own docs blame patterns, not the engine) — cost quality is grammar-author-bound with no per-rule budget.
- **Sticky degradation surprises users** (`redrawtime` silently disabling highlighting) — the flip side of honest ceilings.
- **Nothing is extractable as a library** — like [IntelliJ][intellij], these are reference architectures, not components.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                                                       | Trade-off                                                                   |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **Vim: re-derive state backwards (`:syn sync`)**    | Start anywhere with bounded lookback; no checkpoint storage; grammar authors pick the trade     | Accuracy holes per strategy; sync patterns are expert-authored per language |
| **Vim: per-line state cache (displayed + 1-in-20)** | Restartability at minimal memory; scrolling stays cheap                                         | Cache invalidation logic; sparse coverage means occasional resync work      |
| **Vim: `synmaxcol` / `redrawtime` ceilings**        | Pathological lines/files can't freeze the editor; user-tunable                                  | Silent state-clearing past the column; sticky disable confuses users        |
| **Emacs: syntactic pass + keyword pass split**      | Strings/comments (the cross-line troublemakers) handled by a real scanner; keywords stay simple | Two mechanisms to coordinate; the multiline hole lives at their boundary    |
| **Emacs: jit-lock on redisplay**                    | Pay only for visible text; huge buffers open instantly                                          | Unfontified flashes; correctness arrives asynchronously (stealth/context)   |
| **Emacs: `syntax-ppss` cached global scan**         | One incremental source of syntactic truth, flushed from the edit point                          | Whole-prefix semantics: worst-case re-scan cost after early edits           |
| **Both: editor-native grammars and themes**         | Deep integration, zero dependencies, per-buffer flexibility                                     | No corpus portability — the design cost the next generation paid down       |

---

## Sources

- Vim (pinned `834b8d21`): [`runtime/doc/syntax.txt`][vim-syntax-txt] §11 "Synchronizing" (the why + four strategies + bounds + cost rationale); [`runtime/doc/options.txt`][vim-options-txt] (`'synmaxcol'`, `'redrawtime'`); [`src/syntax.c`][vim-syntax-c] (item model :31-37, sync routine header :571-579, resync amortization :608-613); [`src/structs.h`][vim-structs-h] (`b_sst_array` cache design); `runtime/doc/version5.txt` (the 5.0 feature entry)
- Emacs (pinned `b22a3be`): [`lisp/font-lock.el`][font-lock-el] (passes commentary :63-85, decoration levels :48-52, the "son-of-font-lock" confession :93-97, `font-lock-multiline`); [`lisp/jit-lock.el`][jit-lock-el] (redisplay trigger :26, mode docstring tiers :191-211, chunk-size default + rationale); [`lisp/emacs-lisp/syntax.el`][syntax-el] (`syntax-ppss` doc + cache flush); [`doc/lispref/modes.texi`][modes-texi] ("Multiline Font Lock"); `etc/NEWS.21` (jit-lock default); `lisp/treesit.el` (`treesit-font-lock-rules`)
- Related deep-dives: [Helix][helix] (the tree-sitter successor pattern) · [syntect]/[Shiki][shiki] (checkpointing instead of sync) · [IntelliJ][intellij] (the other in-process reference architecture) · [the synthesis][sh]

<!-- References -->

[vim-repo]: https://github.com/vim/vim
[emacs-repo]: https://github.com/emacs-mirror/emacs
[vim-syntax-txt]: https://github.com/vim/vim/blob/master/runtime/doc/syntax.txt
[vim-options-txt]: https://github.com/vim/vim/blob/master/runtime/doc/options.txt
[vim-syntax-c]: https://github.com/vim/vim/blob/master/src/syntax.c
[vim-structs-h]: https://github.com/vim/vim/blob/master/src/structs.h
[font-lock-el]: https://github.com/emacs-mirror/emacs/blob/master/lisp/font-lock.el
[jit-lock-el]: https://github.com/emacs-mirror/emacs/blob/master/lisp/jit-lock.el
[syntax-el]: https://github.com/emacs-mirror/emacs/blob/master/lisp/emacs-lisp/syntax.el
[modes-texi]: https://github.com/emacs-mirror/emacs/blob/master/doc/lispref/modes.texi
[helix]: ./helix.md
[syntect]: ./syntect.md
[shiki]: ./shiki.md
[bat]: ./bat.md
[pygments]: ./pygments.md
[intellij]: ./intellij-highlighting.md
[lezer-hl]: ./lezer-highlight.md
[ts-highlight]: ./tree-sitter-highlight.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
[sh-fit]: ./syntax-highlighting.md#where-sparkles-syntax-fits

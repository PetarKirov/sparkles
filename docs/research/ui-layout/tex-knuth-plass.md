# TeX / Knuth-Plass Line-Breaking

The line-breaking algorithm described in Donald E. Knuth and Michael F. Plass's
1981 paper _Breaking Paragraphs into Lines_ (Software: Practice & Experience,
volume 11, number 11) and shipped with TeX since 1978. The algorithm replaces the
near-universal "fit as many words on each line as possible" greedy heuristic with
a **global** dynamic-programming optimisation over an entire paragraph, treating
text as a stream of _boxes_, _glue_, and _penalties_ and selecting the set of
break-points that minimises a sum of squared _demerits_. The result -- visible in
any TeX document -- is paragraphs noticeably more uniform in spacing than those
produced by browsers or word processors.

| Field                  | Value                                                                                                                 |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Original paper         | D. E. Knuth, M. F. Plass, _Breaking Paragraphs into Lines_, Software: Practice & Experience 11 (1981), pp. 1119--1184 |
| Reprint                | Chapter 3 of D. E. Knuth, _Digital Typography_, CSLI Publications, 1999, ISBN 1-57586-010-4                           |
| First shipped in       | TeX (Knuth, 1978; rewritten in WEB 1982)                                                                              |
| Complexity             | O(n) amortised with passive-node pruning; O(n\*L) worst case where L is the look-back window                          |
| Algorithm class        | Single-source shortest path / dynamic programming over a DAG of feasible break-points                                 |
| Reference impl.        | TeX `\linebreak` machinery, modules 813--880 of `tex.web`                                                             |
| Modern implementations | TeX, eTeX, pdfTeX, LuaTeX, XeTeX, ConTeXt, SILE; standalone JS port `knuthplass`; CSS `text-wrap: pretty`             |
| Authors                | Donald E. Knuth (Stanford), Michael F. Plass (Xerox PARC, later)                                                      |

---

## Overview

### What It Solves

Given a paragraph of text and a line width (or sequence of line widths), produce
a sequence of line breaks. The naive solution -- the "first-fit" or "greedy"
algorithm -- walks left to right, accumulating words until the next word would
overflow, then breaks. The greedy algorithm is local, fast, and produces lines
that match a human reading "this fits, this doesn't". It is also the algorithm
implemented by ([virtually every browser at the time of writing][css-normal-flow]
for normal flow), every classic word processor, every CLI `fold(1)` utility, and
every TUI library that paragraph-wraps text without further qualification.

Greedy line-breaking has two characteristic failure modes that the Knuth-Plass
paper documents at length:

1. **Last-line problems.** A greedy algorithm makes no attempt to leave a
   reasonable amount of text on the final line. The final line of a paragraph
   under greedy breaking is frequently a single word -- a "widow" of the
   paragraph, not the page -- because the previous lines were each packed as
   tightly as possible.
2. **Inter-line spacing variance.** Each greedy line is packed to "just under
   the maximum"; when the algorithm finally breaks, the surplus space falls on
   that single line. Justified output therefore has lines whose stretch varies
   widely: one line is comfortably set, the next stretches by 30%. Knuth and
   Plass's central observation is that _a slightly worse fit early in the
   paragraph can produce a strictly better overall fit_, but a greedy
   algorithm cannot see this.

Knuth-Plass formulates line-breaking as an optimisation over the entire
paragraph: choose the set of break-points that minimises the sum of a
per-line _demerit_ function. Because demerits grow quadratically with how far a
line stretches or shrinks from its natural width, the optimal solution
distributes the stretch _evenly_ across lines.

### Design Philosophy

The paper articulates four design constraints:

1. **The model must be data-driven**, not algorithm-driven. Different scripts,
   different font metrics, different break-point conventions
   (hyphenation/no-hyphenation, em-dash kerning, ...) are encoded in the
   _input_ sequence of boxes/glue/penalties, not by special-casing the
   algorithm.
2. **The optimisation function must respect human typographic judgement.**
   Demerits include not only "how stretched is this line" but "how different is
   the stretch from the previous line" (a _fitness class_ penalty), "did we
   hyphenate two lines in a row" (a _flagged-penalty_ penalty), and "did we
   leave a widow on the last line".
3. **The algorithm must run in linear time on real input.** Knuth and Plass
   demonstrate that with a bounded active-set (typically 8--10 active nodes per
   break-point), the algorithm runs in time linear in the paragraph length on
   practical input.
4. **There must be an escape hatch.** When the optimisation finds no feasible
   layout (because no set of breaks can fit the text), the algorithm relaxes
   constraints in well-defined stages: first allow over-full lines (returning
   the famous TeX warning "Overfull \hbox..."), then allow hyphenation, then
   re-run with a tolerance parameter raised.

### History

- **~1977.** Knuth begins TeX as a typesetting system for _The Art of Computer
  Programming_. An unpublished memo dated 1977 sketches the dynamic-programming
  approach to line-breaking; Plass, then a PhD student at Stanford, joins to
  formalise it.
- **1978.** First version of TeX (TeX78) ships with an early form of the
  algorithm.
- **1981.** Knuth and Plass publish _Breaking Paragraphs into Lines_ in
  _Software: Practice & Experience_. The paper presents the algorithm, the
  badness/demerits formulae, and the analyses of greedy vs. global breaking
  using paragraphs from _The Art of Computer Programming_ and works by Lewis
  Carroll and others as examples.
- **1982.** TeX82, rewritten in Knuth's WEB literate-programming system,
  contains the canonical implementation that almost every later port descends
  from.
- **1999.** Knuth republishes the paper as Chapter 3 of _Digital Typography_
  with a retrospective addendum.
- **2003 onwards.** pdfTeX, LuaTeX, XeTeX extend TeX while keeping the
  line-breaking core. Hans Hagen's ConTeXt, Simon Cozens's SILE, and Bram
  Stein's `typeset` rebuild the algorithm in modern languages
  (C, Lua, JavaScript).
- **2010s onwards.** Brian Tingley's [`knuthplass`][knuthplass-js] JS library is
  used in web typography demos. Bram Stein's [`typeset`][typeset-js]
  generalises it to SVG/canvas.
- **2023.** Chromium and WebKit ship `text-wrap: balance` and `text-wrap:
pretty` (CSS Text Level 4), the latter using a Knuth-Plass-like algorithm for
  paragraph balancing in normal flow. See
  ([css-normal-flow.md][css-normal-flow]) for the browser-wrapping comparison.
- **2010s--2020s.** A few CLI/terminal projects experiment with optimal
  line-breaking. Andrew Kelley (author of the Zig programming language) has
  publicly discussed applying Knuth-Plass to terminal text. The pattern is
  uncommon enough that the question "why doesn't `fold` use Knuth-Plass?"
  recurs on Stack Overflow every few years.

---

## Layout Model

### The Box/Glue/Penalty Stream

Input to the algorithm is a _horizontal list_ -- a sequence of three kinds of
items:

```
data Item = Box      { width :: Double, content :: Content }
          | Glue     { width :: Double, stretch :: Double, shrink :: Double }
          | Penalty  { width :: Double, cost :: Int, flagged :: Bool }
```

- A **Box** is an atomic, unbreakable unit -- typically a character or a
  pre-shaped word. Its `width` is the typeset width on the page. Boxes are
  never split.
- **Glue** is a stretchable, shrinkable space. Each glue item carries a
  _natural width_ (the width when no adjustment is needed), a _stretchability_
  (how far it can grow before the algorithm gives up), and a _shrinkability_
  (how far it can be compressed; never below `width - shrink`).
- A **Penalty** is a point in the stream where a line break may or may not
  occur. Its `cost` is an integer in `[-infinity, +infinity]`: `-infinity`
  forces a break (e.g. end of paragraph), `+infinity` forbids one (e.g.
  between a number and its units). A `flagged` penalty is one that, when used
  consecutively, accrues an additional aesthetic penalty -- this is how TeX
  discourages hyphenating two lines in a row.

A break may occur at a `Glue` item _immediately preceded by a `Box`_ (so that
white space between words is a valid break candidate, but white space at the
start of a paragraph is not), or at any `Penalty` whose cost is less than
`+infinity`.

This three-element vocabulary is enough to describe paragraphs, lists,
mathematical formulae, displayed equations, justified vs. ragged text, French
spacing, and a hundred other typographic phenomena -- the algorithm itself
never changes; only the input stream does.

### Badness

For each candidate line spanning items `i .. j`, the algorithm computes an
_adjustment ratio_ `r`:

```
let W = sum of widths of items (i..j)
let X = target line width
let Y = sum of stretchability of glue items in (i..j)
let Z = sum of shrinkability of glue items in (i..j)

r = (X - W) / Y   if X >= W   (line needs to stretch)
  = (X - W) / Z   if X <  W   (line needs to shrink)
```

When `r = 0` the line fits exactly. Positive `r` means glue stretches; negative
`r` means glue shrinks. `r = -1` is the maximum shrink (every shrinkable glue
fully compressed); `r < -1` is infeasible.

The **badness** of a line is then:

```
badness = 10000              if r < -1 or r > tolerance (infeasible)
        = 100 * |r|^3        otherwise
```

The cubic term penalises stretches and shrinks superlinearly: a line stretched
by 50% is 8x worse than one stretched by 25%, not 2x. This is the formal
expression of the typographic intuition that _very_ stretched lines are visibly
ugly while moderately stretched ones are tolerable.

### Demerits

Each feasible line's _demerits_ combine its badness with break-point penalties
and inter-line aesthetic costs:

```
let bad = badness of the line
let pen = penalty cost at the break-point (0 for glue breaks)
let linep = a global "line penalty" constant (e.g. 10 in plain TeX)
let hyph = 3000 if both this line and the previous one ended with a flagged
                  penalty (consecutive hyphenations), else 0

demerits = (linep + bad)^2 + sign(pen) * pen^2 + hyph

   where sign(pen) * pen^2 means:
     +pen^2   if pen >= 0
     -pen^2   if -infinity < pen < 0   (reward for explicit good breaks)
     not added at all if pen = -infinity (forced break)
```

The squaring of `(linep + bad)` is the key non-linearity. It means a paragraph
with three lines of badness 10 (total `3 * (10+10)^2 = 1200`) beats one with two
lines of badness 0 and one of badness 30 (total `(10)^2 + (10)^2 + (10+30)^2 =
1800`). Smoothing wins over packing.

A **fitness class** is also tracked: each feasible line is classified by its
adjustment ratio into one of four buckets (`< -0.5`, `[-0.5, 0.5]`, `[0.5, 1]`,
`> 1`). When two adjacent lines fall in non-adjacent classes, an extra
_adjacent-line_ demerit is added. This penalises "tight then loose" transitions
even when each line in isolation is fine.

### The Dynamic Programming Algorithm

Knuth and Plass cast the problem as a single-source shortest-path search in a
DAG. Vertices are _active break-points_; edges are feasible lines; edge weights
are demerits. The shortest path from the paragraph start to the paragraph end
is the optimal layout.

Pseudocode (transcribed from §3 of the paper, simplified):

```
ACTIVE := { (start, line=0, fitness=class_2, demerits=0) }

for b in 1 .. n:                          -- each candidate break-point
    feasible := []
    for a in ACTIVE:
        r := adjustment_ratio(a.position, b)
        if r < -1:                        -- this line shrinks too much
            ACTIVE.remove(a)              -- (and all later breaks from a
                                          --  are also infeasible: prune)
        else if -1 <= r <= rho:           -- rho = tolerance, default 200
            d := demerits(a, b, r)
            feasible.append( (predecessor=a, total=a.demerits+d) )
    if not empty(feasible):
        best := argmin(feasible, key=total)
        ACTIVE.add( BreakNode(position=b,
                              line=best.predecessor.line + 1,
                              fitness=fitness_class(r),
                              demerits=best.total,
                              prev=best.predecessor) )

best_final := argmin(ACTIVE where position is end-of-paragraph, key=demerits)
return reconstruct(best_final)
```

The crucial efficiency observation is that an `ACTIVE` node becomes "passive"
(removable) the moment it is too far back for any _future_ break-point to reach
without violating the shrink limit (`r < -1`). Because line widths are
typically a small multiple of average word width, the active set stays around
8--10 entries at steady state, giving amortised linear behaviour on real text.

When the algorithm finishes with an empty `ACTIVE` and never reached the end,
TeX falls back: it raises tolerance from 200 to 10000 (i.e. accepts almost any
stretch) and re-runs. If that also fails, it accepts an overfull box and
reports "Overfull \hbox by Xpt".

### Three Passes in Practice

TeX's actual line-breaker runs up to three passes:

1. **Pass 1: tolerance 200, no hyphenation.** Find an optimum using only
   already-broken words. Most well-set paragraphs succeed here.
2. **Pass 2: tolerance 200, hyphenation.** Introduce hyphenation points (using
   Liang's hyphenation algorithm) and try again. This is where flagged
   penalties earn their demerits.
3. **Pass 3: tolerance 9999, hyphenation, allow overfull.** Accept whatever fit
   is least bad; report.

Each pass shares the same algorithm; only the input stream's penalties change.

### A Worked Example

Consider the input stream (simplified) for the text "the quick brown fox":

```
Box "the"      width 18
Glue           width  3  stretch  2  shrink  1
Box "quick"    width 30
Glue           width  3  stretch  2  shrink  1
Box "brown"    width 28
Glue           width  3  stretch  2  shrink  1
Box "fox"      width 18
Penalty        cost -10000  (end of paragraph)
```

For a line width of 50, the candidate break-points after each glue produce:

| Break after | Line text         | Width | Adj. ratio    | Badness                        |
| ----------- | ----------------- | ----- | ------------- | ------------------------------ |
| "the"       | "the"             | 18    | (50-18)/2=16  | ~infeasible (stretch too high) |
| "quick"     | "the quick"       | 51    | (50-51)/1=-1  | 100\*1^3=100                   |
| "brown"     | "the quick brown" | 82    | (50-82)/2=-16 | infeasible (shrink too high)   |

For 26-wide lines, the algorithm explores three- and four-line layouts and
picks the one minimising squared demerits. With cubic badness, a layout with
three moderately stretched lines beats one with two perfect lines and one
heavily stretched line.

### Reference Implementation Sketch (Haskell)

A concise Haskell implementation, adapted from Knuth/Plass §6:

```haskell
data Item = Box Double | Glue Double Double Double | Penalty Double Int Bool

type Position = Int      -- index into the item stream
data Node = Node { pos      :: !Position
                 , line     :: !Int
                 , fitness  :: !Fitness
                 , width    :: !Double      -- cumulative width up to pos
                 , stretch  :: !Double
                 , shrink   :: !Double
                 , demerits :: !Double
                 , prev     :: Maybe Node
                 }

knuthPlass :: [Item] -> Double -> Double -> [Position]
knuthPlass items lineWidth tolerance =
    reconstruct $ minimumBy (comparing demerits) finalNodes
  where
    items'      = zip [0..] items
    initial     = Node 0 0 Class2 0 0 0 0 Nothing
    finalNodes  = foldl' step [initial] items'

    step active (b, item)
        | isBreakable item =
            let candidates = mapMaybe (tryBreak b item) active
                best       = bestByLineCount candidates
                pruned     = prune b active
            in pruned ++ best
        | otherwise = active

    tryBreak b item a =
        let r = adjustmentRatio a b lineWidth
        in if r < -1 || r > tolerance
             then Nothing
             else Just $ Node b (line a + 1) (fitClass r)
                              (cumWidth b) (cumStretch b) (cumShrink b)
                              (demerits a + lineDemerits a r item) (Just a)

    reconstruct n = case prev n of
                      Nothing -> [pos n]
                      Just p  -> reconstruct p ++ [pos n]
```

This omits the cumulative-width book-keeping (which in a production
implementation is done with running sums to make `adjustmentRatio` O(1)) but
captures the structural shape: a fold over the item stream that maintains an
active set, computing feasible predecessors at each break candidate.

### Reference Implementation Sketch (Python-like)

The same algorithm, in a more procedural style closer to TeX's WEB source
(modules 829--862 of `tex.web`):

```python
def knuth_plass(items, line_width, tolerance=200, line_penalty=10):
    active = [Node(position=0, line=0, fitness=1, demerits=0, prev=None)]
    cumW = cumY = cumZ = 0.0     # cumulative width, stretch, shrink

    for b, item in enumerate(items):
        if isinstance(item, Box):
            cumW += item.width
            continue
        if isinstance(item, Glue):
            if b > 0 and isinstance(items[b-1], Box):
                # candidate break-point at this glue
                explore_break(active, b, cumW, cumY, cumZ,
                              line_width, tolerance, line_penalty)
            cumW += item.width
            cumY += item.stretch
            cumZ += item.shrink
            continue
        if isinstance(item, Penalty) and item.cost < INF:
            explore_break(active, b, cumW, cumY, cumZ,
                          line_width, tolerance, line_penalty,
                          penalty=item.cost, flagged=item.flagged)

    end = min((a for a in active if a.position == len(items) - 1),
              key=lambda a: a.demerits)
    return reconstruct(end)
```

`explore_break` is the inner loop: for each `a in active`, compute the
adjustment ratio of a hypothetical line from `a` to `b`, drop `a` if it can
never feasibly reach `b` (prune), and if the line is feasible insert a new
active node at `b` recording `a` as predecessor.

### Adapting to Terminal Output

Translating the algorithm to terminal/CLI prose wrapping requires only that
"widths" become "columns":

- A `Box` is a _grapheme cluster_ (or, more practically, a word's width
  measured by Unicode display-width tables like `wcwidth(3)` -- East Asian
  wide characters count as 2, combining marks as 0).
- The natural width of a `Glue` is 1 (one space). Most terminal renderers do
  not have access to true stretchable glue: a column is either occupied or
  not. The closest approximation is to model glue stretchability as the
  _maximum_ extra spaces the renderer is willing to insert (e.g. up to 3
  extra), or to set stretch to 0 and shrink to 0 and use the algorithm only
  for ragged-right (unjustified) prose -- in which case it still wins by
  balancing line lengths.
- Penalties can be assigned at sentence boundaries (`-100`, "prefer to break
  here"), after dashes and slashes (`-50`), inside hyphenated compounds
  (positive penalty discouraging breaks unless necessary), and at clause
  punctuation.
- For ragged-right CLI output, the natural metric is "minimise the sum of
  squared trailing white-space columns" -- the simplification of Knuth-Plass
  to the case where all glue is rigid. Even this simplified case
  produces visibly better `--help` and `man`-page wrapping than greedy:

  ```
  Greedy wrap, width 50:
    The quick brown fox jumps over the lazy dog and
    then runs.
  Knuth-Plass wrap, width 50:
    The quick brown fox jumps over the lazy
    dog and then runs.
  ```

  The greedy output's first line is full and the second contains only two
  words; the optimal output spreads two words from line one to line two,
  producing more balanced lines.

### Modern Implementations

| Implementation                        | Language               | Notes                                                                      |
| ------------------------------------- | ---------------------- | -------------------------------------------------------------------------- |
| TeX                                   | WEB / Pascal / C       | The canonical implementation; tex.web modules 813--880                     |
| pdfTeX                                | C                      | Adds protrusion and font expansion (extension)                             |
| LuaTeX                                | C + Lua                | Exposes line-breaking via the `linebreak_filter` callback                  |
| XeTeX                                 | C++                    | Same algorithm, Unicode + OpenType                                         |
| ConTeXt                               | TeX + Lua              | Layered on top of LuaTeX; tweaks the demerit constants                     |
| SILE                                  | Lua                    | Modern reimplementation by Simon Cozens and Caleb Maclennan; clean Lua API |
| `knuthplass` (Tingley)                | JavaScript             | Standalone JS port; powers web demos                                       |
| `typeset` (Stein)                     | JavaScript             | SVG/canvas paragraph setter using Knuth-Plass                              |
| Microsoft Word's "Optimise paragraph" | C++                    | A balance algorithm shipped in Word 2003+ for justified text               |
| CSS `text-wrap: pretty`               | C++ (Chromium, WebKit) | Knuth-Plass-style balancing for normal-flow text                           |

For a comparison with the simpler greedy/first-fit algorithm dominant on the
web, see ([css-normal-flow.md][css-normal-flow]).

---

## Strengths and Weaknesses

### Strengths

- **Visibly better paragraphs.** The most cited demonstration is the
  side-by-side comparison in the original paper of a paragraph from _The Art
  of Computer Programming_: greedy breaking leaves wildly varying inter-word
  spacing, Knuth-Plass equalises it. Every TeX document one has ever read is
  evidence.
- **Linear time on real input.** Despite formulating the problem as
  optimisation over a DAG of `O(n^2)` candidate lines, the active-set pruning
  keeps the practical complexity linear with a small constant.
- **Composable extensions.** Because the algorithm operates on a stream of
  boxes/glue/penalties, new typographic features (hyphenation, French spacing,
  inhibited breaks around URLs, math display) integrate by emitting different
  items, not by patching the algorithm.
- **Principled escape hatches.** Three-pass fallback ensures the algorithm
  always returns _something_: progressively relaxed tolerances and an explicit
  "overfull" report mean no paragraph is left unset.
- **Well-studied.** Forty-five years of literature exist. The algorithm is
  taught in every typography text and analysed extensively in computer-science
  literature (Plass's own thesis on the NP-hardness of the more general
  two-dimensional layout problem grew out of this work).

### Weaknesses

- **Integration cost.** A caller must supply the glue/penalty stream. For a
  CLI program that wants to wrap a string, this means first lexing the string
  into atoms with width and stretchability information. That is mechanical but
  not zero work, and rules out simply replacing `printf "%s\n"` with a
  Knuth-Plass call.
- **Look-back memory.** The algorithm holds active nodes back to the
  furthest-feasible predecessor. For pathological input (very narrow columns,
  long words) the active set can grow; TeX caps it in practice but the bound
  is empirical.
- **Two-dimensional layout is out of scope.** Knuth-Plass solves _paragraph_
  line-breaking. It does not solve page-breaking (which TeX handles with a
  separate, simpler algorithm), column balancing, or float placement. Plass's
  PhD thesis showed the two-dimensional version is NP-hard, which is why
  TeX uses heuristics there.
- **Table cells are not paragraphs.** Most CLI table output (Sparkles
  `drawTable`, `column(1)`, `awk` tabular output, ...) wraps each cell to a
  width that is small relative to the words it contains. With cells of, say,
  20 columns and words of 8--10 columns, the active set never has more than
  one or two entries; the algorithm degenerates to greedy. Knuth-Plass shines
  in long-line prose, not narrow columns.
- **The terminal lacks stretchable glue.** A monospace grid cannot truly
  _stretch_ spaces; it can only insert or omit them. Justified output via
  Knuth-Plass on a monospace terminal therefore looks worse than on a
  proportional-font page, because the only way to widen a line is to add
  whole-column spaces. Ragged-right is the natural mode, and there
  Knuth-Plass is still useful.
- **Tolerance is a magic number.** TeX's default `tolerance = 200` and
  `linepenalty = 10` were chosen by Knuth empirically. They work well for
  English prose at typical book widths. Other scripts (German with its long
  compounds, Thai with no inter-word spacing, CJK with character-grid
  breaking) need different defaults, and Knuth-Plass on its own does not
  guide you.
- **Implementation complexity.** TeX's line-breaker in `tex.web` runs to
  ~70 WEB modules and ~1500 lines of Pascal-with-macros. The algorithm is
  compact, but the production code has a lot of accidental complexity (cursor
  positions, font expansion, alignment with display math, list
  reconstruction).

### Lessons for Sparkles

For Sparkles specifically, the relevance is partial but clear:

- **For `drawTable` cells: not directly applicable.** Table cells are too
  narrow for the global optimisation to outperform greedy. A greedy
  word-wrapper (already what most CLI table libraries use) is the right
  choice.
- **For `--help`, `--man`, and long-form prose output: highly relevant.**
  Sparkles `core-cli` already pretty-prints structured values; it does not
  currently pretty-print _prose_. If a future Sparkles feature wraps user-
  facing prose (`Usage: ...` text, error descriptions, multi-paragraph
  documentation), a Knuth-Plass-style optimiser would be visible win for
  paragraphs longer than a few lines.
- **The box/glue/penalty stream is a natural fit for D.** Sparkles already
  uses output ranges and `SmallBuffer` for `@nogc` text production. A
  Knuth-Plass implementation can be entirely `@nogc`: the item stream is a
  `SmallBuffer!(Item, 256)`, the active set is another `SmallBuffer!(Node,
16)`, and the demerit arithmetic is pure floating-point.
- **The simplified ragged-right case is cheap to ship first.** Setting all
  glue to non-stretchable (`stretch = shrink = 0`) reduces the algorithm to
  minimising `sum of squared (lineWidth - lineFilled)` over feasible
  break-point sets -- the _Plass-balancing_ problem. This drops all the
  hyphenation-passes complexity, runs in true `O(n*w/avgWord)` time, and
  already gives the bulk of the visible quality improvement over greedy.
  This is what we would recommend implementing first.
- **Stop-the-world hyphenation is optional.** Knuth-Plass without hyphenation
  works fine; one just turns off the second pass. Sparkles does not need to
  ship a hyphenation dictionary to ship Knuth-Plass wrapping.
- **A sketch of the API.** A future `sparkles.core_cli.wrap` module could expose:

  ```d
  @safe pure nothrow @nogc
  void wrapParagraph(Writer)(
      scope const(char)[] text,
      int lineWidth,
      ref Writer w,
      WrapOptions opt = WrapOptions.init);

  struct WrapOptions {
      WrapAlgorithm algorithm = WrapAlgorithm.knuthPlass;
      int tolerance = 200;       // KP only
      int linePenalty = 10;      // KP only
      bool justify = false;      // ragged-right is the default
  }

  enum WrapAlgorithm { greedy, knuthPlass }
  ```

  `WrapAlgorithm.greedy` keeps the existing fast path; `WrapAlgorithm.knuthPlass`
  delivers the better wrap for long-form prose. Both share the same surface
  API and both can be `@nogc`.

- **Comparison context.** For the contrast with greedy line-breaking dominant
  in CSS normal flow and almost every CLI text wrapper, see
  ([css-normal-flow.md][css-normal-flow]). For the wrap-rendering layer of a
  TUI library that gets this right via paragraph widgets, see
  ([../tui-libraries/brick.md][brick]) (Brick's `strWrap`/`txtWrap` and the
  `Paragraph` widget) and ([../tui-libraries/ratatui.md][ratatui]) (Ratatui's
  `Paragraph::wrap`, which is greedy first-fit).

---

## References

- **Primary paper**: D. E. Knuth, M. F. Plass. _Breaking Paragraphs into
  Lines_. Software: Practice and Experience, **11**(11):1119--1184,
  November 1981.
  PDF mirrors:
  - <https://www.eprg.org/G53DOC/pdfs/knuth-plass-breaking.pdf>
  - <http://defoe.sourceforge.net/folio/knuth-plass.html> (analysis + Java reimplementation)
- **Reprint**: Chapter 3 of D. E. Knuth, _Digital Typography_. CSLI
  Publications, Stanford, 1999. ISBN 1-57586-010-4.
- **TeX source**: D. E. Knuth, _TeX: The Program_. Computers & Typesetting
  Volume B. Addison-Wesley, 1986. ISBN 0-201-13437-3. Modules 813--880 contain
  the line-breaking machinery in WEB.
- **Plass's thesis**: M. F. Plass. _Optimal Pagination Techniques for
  Automatic Typesetting Systems_. PhD thesis, Stanford University, 1981.
  (Proves NP-hardness of the two-dimensional generalisation.)
- **Wikipedia overview**: <https://en.wikipedia.org/wiki/Line_wrap_and_word_wrap#Optimal_line-breaking_algorithm>
- **Liang's hyphenation algorithm** (used by TeX in pass 2):
  F. M. Liang. _Word Hy-phen-a-tion by Com-pu-ter_. PhD thesis, Stanford, 1983.
- **LuaTeX `linebreak_filter` documentation**:
  <https://www.luatex.org/svn/trunk/manual/luatex-nodes.tex>
- **SILE typesetter**: <https://sile-typesetter.org/> (Simon Cozens, Caleb
  Maclennan; written in Lua; reimplements Knuth-Plass line-breaking).
- **`knuthplass` (JavaScript)**: Brian Tingley.
  <https://github.com/bramstein/typeset> ports the algorithm to JS.
- **Bram Stein, _The State of Web Type_**: <https://stateofwebtype.com/> --
  discusses CSS `text-wrap: pretty` and its relationship to Knuth-Plass.
- **CSS Text Module Level 4**: <https://www.w3.org/TR/css-text-4/> -- defines
  `text-wrap: balance | pretty`.
- **Andrew Kelley on terminal text rendering**: see
  <https://andrewkelley.me/> and the Zig issue tracker for discussions of
  optimal paragraph layout in CLI contexts.
- **Sparkles cross-links**:
  - Greedy / fit-first line-breaking: ([css-normal-flow.md][css-normal-flow])
  - Paragraph widgets in TUI libraries:
    ([../tui-libraries/brick.md][brick]),
    ([../tui-libraries/ratatui.md][ratatui]),
    ([../tui-libraries/ink.md][ink])
  - Flexbox-style space distribution (a related but orthogonal problem):
    ([css-flexbox.md](./css-flexbox.md))

[css-normal-flow]: ./css-normal-flow.md
[brick]: ../tui-libraries/brick.md
[ratatui]: ../tui-libraries/ratatui.md
[ink]: ../tui-libraries/ink.md
[knuthplass-js]: https://github.com/robertknight/tex-linebreak
[typeset-js]: https://github.com/bramstein/typeset

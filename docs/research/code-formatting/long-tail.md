# The Long Tail — black, scalafmt, google-java-format, and the pre-AST generation

Systems that matter to the survey for one idea each, and do not need a full deep-dive because
their layout algorithm is already covered elsewhere. Each section states what it uniquely
contributes and why the rest is a duplicate.

---

## black (Python)

Layout: greedy, AST-based, [combinator][combinators]-adjacent. Its contributions are **policy**,
not algorithm, and both are worth stealing.

### The magic trailing comma

black's stated posture is uncompromising — and then it makes exactly one exception:

> "_Black_ in general does not take existing formatting into account. However, there are cases
> where you put a short collection or function call in your code but you anticipate it will grow
> in the future. … Early versions of _Black_ used to ruthlessly collapse those into one line (it
> fits!). Now, you can communicate that you don't want that by putting a trailing comma in the
> collection yourself. When you do, _Black_ will know to always explode your collection into one
> item per line. How do you make it stop? Just delete that trailing comma."
> — [`docs/the_black_code_style/current_style.md`][black-style]

This is the cleanest statement in the survey of a **one-bit author-to-formatter channel**. The
same mechanism appears as [zig fmt's whole paradigm][zig-fmt], as
[topiary's `@append_input_softline`][topiary], and inverted in
[swift-format's `commaDelimitedRegionStart`][swift-format], which _inserts_ the comma. Four
independent arrivals; it belongs in any opinionated formatter.

### The stability policy

black versions its _style_, not just its code:

> "This means projects can safely use `black ~= 26.0` without worrying about formatting changes
> disrupting their project in 2026. … The first release in a new calendar year _may_ contain
> formatting changes, although these will be minimised as much as possible."
>
> "The `--preview` and `--unstable` flags are exempt from this policy. … The `--preview` style at
> the end of a year should closely match the stable style for the next year."
> — [`docs/the_black_code_style/index.md`][black-index]

A **calendar-year style freeze** with a preview channel that becomes next year's stable style.
This solves the problem [dart_style solved differently][dart-style] (language-version gating): how
to keep improving a formatter without inflicting a repo-wide diff on every user at an arbitrary
moment. Both answers are better than the usual one, which is to inflict it.

black also documents the honest exception: "In rare cases, we may make changes affecting code that
has not been previously formatted with _Black_. For example, we have had bugs where we
accidentally removed some comments." Comment loss as a shipped bug class, admitted in the
stability policy — a data point for [verification][verification].

**The rest of black is a duplicate**: greedy AST-based printing, small option surface, hard line
length, whole-document output, refuses unparseable input. See [prettier][prettier].

---

## scalafmt (Scala)

Layout: [best-first search over a `Router`-generated graph][cost-search] — covered in full in the
theory page, from [Geirsson's 2016 thesis][geirsson]. What the thesis contributes that the systems
half does not:

- **The `Router` / search separation** — a language-aware component emits `Split`s with penalties
  and `Policy` constraints; the optimizer never learns Scala. [Oppen's producer/printer
  split][oppen] applied to a search engine.
- **The exponential-blowup example** — a three-line input with an unavoidably-over-long comment
  that explores "over 8 million states", at a measured "one state per 10 microseconds".
- **`dequeueOnNewStatements`** and its patch ("never run … inside a pair of parentheses"), with
  the author's own summary that "some optimizations are rather ad-hoc and require creative
  workarounds".

> [!NOTE]
> Everything here describes scalafmt **as of the 2016 thesis**. `$REPOS/scala/scalafmt` is cloned
> (`d425e565`) but was not read; the tool has had a decade of development since.

---

## google-java-format (Java)

Layout: a [combinator][combinators] `Doc` engine, and its pipeline is worth one paragraph because
it is a **three-stage** design nothing else here uses:

> "`JavaInputAstVisitor` outputs a sequence of `Op`s using `OpsBuilder`. This linear sequence is
> then transformed by `DocBuilder` into a tree-structured `Doc`."
> — [`core/src/main/java/com/google/googlejavaformat/Doc.java`][gjf-doc]

So: AST → a **flat sequence of `Op`s** → a **tree-structured `Doc`** → output. The intermediate
flat op-stream is the interesting part: the visitor emits `OpenOp`/`CloseOp`/`Doc` linearly
(exactly [Oppen's `begin`/`end` token stream][oppen]) and a separate builder recovers the tree.
This decouples "what the language means" from "what the document is", and is a plausible shape for
a D formatter whose front end is a DMD AST visitor.

Also present: `CommentsHelper`, `Newlines`, `Indent`, and an `Input`/`Output` split that keeps the
original text addressable. Zero style options, in the [gofmt][gofmt] tradition — the tool
implements Google Java Style and nothing else.

---

## astyle, uncrustify, and the pre-AST generation

The counterfactual that explains why everything else in this survey is tree- or token-based.

`astyle` and `uncrustify` predate the current generation and work by **pattern-matching over
characters and lines** with large tables of heuristics and hundreds of options. Neither parses.
The consequences are the reason the approach was abandoned:

- **No structural knowledge**, so every construct needs its own regex-adjacent rule, and rules
  interact unpredictably.
- **Option explosion** — uncrustify has several hundred options, because each unhandled case
  becomes a new switch rather than a new rule in a model.
- **No correctness argument at all.** There is no sense in which the output provably means the
  same thing; there is not even a token stream to compare.

Their historical role is real: they were the only option for C/C++ before clang-format, and they
are still in use. Their lesson for a D formatter is the negative one — the reason
[dfmt][dfmt] parses at all, even though it formats tokens, is that structural facts have to come
from somewhere.

> [!WARNING]
> **This section is not grounded in local artifacts.** Neither `astyle` nor `uncrustify` is
> cloned; the characterization above is general knowledge and is flagged 🌐 in
> this tree's internal ledger. It is included because the _absence_ of these tools from
> the modern design space is itself a finding, but it should be verified or removed before the
> tree is treated as complete.

---

## What a D formatter should take

| From                    | Take                                                                                               |
| ----------------------- | -------------------------------------------------------------------------------------------------- |
| **black**               | The magic trailing comma; a **calendar-year style freeze** with a preview channel                  |
| **scalafmt**            | The `Router`/search separation, if D ever adopts search — and the exponential example as a warning |
| **google-java-format**  | The **AST → flat `Op` stream → `Doc` tree** pipeline; it fits a DMD-visitor front end well         |
| **astyle / uncrustify** | The negative lesson: no structure ⇒ unbounded options and no correctness story                     |

---

## Sources

- [`psf/black`][black-repo] @ `74371e2041a3120a049ced8f1cab0e7a6bc8ecd3`:
  `docs/the_black_code_style/current_style.md`, `index.md`; `src/black/comments.py`
  (the `FMT_OFF` set)
- [`geirsson-2016-scalafmt-thesis-epfl.pdf`][geirsson] — §§2–4
- [`google/google-java-format`][gjf-repo] @ `b291d957157c737ee6ac9574c1ea9c8c0ec077c2`:
  `core/src/main/java/com/google/googlejavaformat/{Doc,DocBuilder,OpsBuilder,Op,OpenOp,CloseOp,CommentsHelper,Indent,Newlines,Input,Output}.java`
- astyle / uncrustify: **not held locally** — see the warning above

**Related deep-dives in this tree:**
[Cost & search][cost-search] · [Combinators][combinators] · [Concepts][concepts] ·
[prettier][prettier] · [dart_style][dart-style] · [zig fmt][zig-fmt] · [topiary][topiary] ·
[Verification][verification] · [Comparison][comparison]

<!-- References -->

[black-repo]: https://github.com/psf/black/tree/74371e2041a3120a049ced8f1cab0e7a6bc8ecd3
[black-style]: https://github.com/psf/black/blob/74371e2041a3120a049ced8f1cab0e7a6bc8ecd3/docs/the_black_code_style/current_style.md
[black-index]: https://github.com/psf/black/blob/74371e2041a3120a049ced8f1cab0e7a6bc8ecd3/docs/the_black_code_style/index.md
[gjf-repo]: https://github.com/google/google-java-format/tree/b291d957157c737ee6ac9574c1ea9c8c0ec077c2
[gjf-doc]: https://github.com/google/google-java-format/blob/b291d957157c737ee6ac9574c1ea9c8c0ec077c2/core/src/main/java/com/google/googlejavaformat/Doc.java
[geirsson]: https://geirsson.com/assets/olafur.geirsson-scalafmt-thesis.pdf
[oppen]: ./theory/oppen.md
[combinators]: ./theory/combinators.md
[cost-search]: ./theory/cost-and-search.md
[concepts]: ./concepts.md
[verification]: ./verification.md
[comparison]: ./comparison.md
[prettier]: ./prettier.md
[dfmt]: ./dfmt.md
[gofmt]: ./gofmt.md
[zig-fmt]: ./zig-fmt.md
[dart-style]: ./dart-style.md
[topiary]: ./topiary.md
[swift-format]: ./swift-format.md

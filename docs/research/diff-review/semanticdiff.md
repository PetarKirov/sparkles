# SemanticDiff (Proprietary — VS Code extension + GitHub App)

A closed-source, language-aware ("semantic") diff viewer by Sysmagine GmbH that parses both file versions into ASTs, hides changes proven irrelevant by per-language _invariance_ rules (formatting, optional tokens, equivalent literals), and layers moved-code and rename detection on top — delivered as a VS Code extension and a hosted GitHub pull-request app rather than a CLI.

| Field                | Value                                                                                                                       |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Language             | Not disclosed (closed source; VS Code extension ships a local engine)                                                       |
| License              | Proprietary; free tier (VS Code extension free for commercial use; GitHub App free for 3 seats and for public repositories) |
| Repository           | None public — [`Sysmagine/SemanticDiff`][gh-support] is an issues-only community-support repo, no source                    |
| Documentation        | [semanticdiff.com/docs][docs]; blog at [semanticdiff.com/blog][blog]                                                        |
| Category             | web-review (language-aware diff viewer: VS Code extension + GitHub PR app)                                                  |
| First/Latest release | Not publicly versioned end-to-end; latest release noted on the blog is `0.10.0` (Lua, XML/DTD support) — [blog post][v0100] |
| Surveyed sources     | Official site, docs, FAQ, and blog as of 2026-08-04 (URLs in [Sources](#sources))                                           |

> [!NOTE]
> SemanticDiff is proprietary: there is no source tree to survey. Everything below is grounded in the official documentation and blog, which are unusually candid about the design space (they publish comparison posts against difftastic and essays on where to draw the relevance line). The _algorithm itself_ (which tree-matching strategy, complexity bounds) is never disclosed; absence of that information is noted where it matters.

## Overview

### What it solves

Line-oriented diffs make reviewers wade through changes that cannot matter: re-wrapped lines after a formatter run, added trailing commas, re-ordered object keys, a decimal literal rewritten as hex. SemanticDiff's pitch is "a programming language aware diff that distinguishes between relevant and irrelevant changes" ([homepage][home]). It hides style-only edits, detects moved code (including edits _inside_ the moved block), and groups mechanical refactorings such as renames, so the reviewer reads only the semantic delta. It supports "14+ programming languages and data exchange formats" — per the [VS Code FAQ][faq]: C#, CSS/SCSS, Go, HTML, Java, JavaScript/JSX, JSON, Lua, PO, Python, Rust, Swift (GitHub App only), TypeScript/TSX, Vue, and XML/DTD. Notably absent: C/C++ (they call out preprocessor directives as a parser-quality trap in their difftastic comparison) and Markdown.

### Design philosophy

Two published essays define the product's stance more precisely than most open-source competitors document theirs:

- **Semantic, not merely structural.** From the [difftastic comparison][vs-difftastic] (2024-02-05): "While a structural diff treats `1337` and `0x539` as two distinct tokens, a semantic diff knows that they belong to the same number." Difftastic stops at grammar-level structure; SemanticDiff adds equivalence rules over token _values_.
- **A bounded relevance ladder.** The essay [How far should a programming language aware diff go?][how-far] (July 2024) defines four levels — (1) irrelevant whitespace, (2) irrelevant tokens (trailing commas), (3) semantic equivalence (`255 * 0x1A4 + 5` vs `0xff * 0o644 + 0b101`), (4) "mostly identical" rewrites (import reordering, where side effects could theoretically occur). Their cutoff: "The cutoff should probably be somewhere inside level 3" — implemented as "predefined rules" targeting linter-style rewrites, _not_ a general semantic-equivalence prover, because "ignoring all kinds of changes … is probably going too far" and would erode reviewer trust.
- **Hiding is only half the job.** On _invisible changes_ — edits whose semantic effect lands on text that did not change, e.g. removing the `f` from a Python f-string so `{bar}` silently becomes literal text — they highlight both the change and its effect, because "the purpose of a semantic diff is not only to hide changes, but also to inform developers about easily overlooked changes" ([blog][highlight], 2025-02-04). They acknowledge the resulting red/green noise and sketch the fix: "a third change type (besides added and removed code) that uses a different color (not red/green)."

## How it works

### 1. Diff computation & data model

Both file versions are parsed into ASTs ("SemanticDiff … understands the meaning of the change" by "converting code to Abstract Syntax Trees" — [FAQ][faq]); the diff is computed over trees, then per-language _invariance_ rules collapse equivalent subtrees (see §3). The concrete tree-matching algorithm is **not disclosed** — no GumTree/Dijkstra/A* claim anywhere in docs or blog, in contrast to difftastic's documented A* search. Where it runs: the VS Code extension computes **locally** — "All computations are performed locally on your machine. Our extension also works if you are offline" ([FAQ][faq]) — while the GitHub App is a hosted service that analyzes PRs server-side (the paid tier buys "Prioritized Processing," i.e. queue priority, [pricing][pricing]).

The output data model is _blocks_, not line pairs: "A block contains a list of old lines and new lines that correspond to the same code," and "SemanticDiff does not align individual lines (since this may be impossible), but only blocks" ([Understanding the Diff][understand]). This is the honest consequence of tree diffing — after re-wrapping, old and new lines have no 1:1 correspondence, so the two panes scroll block-aligned with independently laid-out interiors.

For unsupported file types a **fallback diff** reuses the same engine degenerately: it "uses the same algorithms as all our other diffs, but without taking the structure of the file into account. Each line is simply treated as a long text token," yielding "a standard text diff with moved line detection" ([fallback docs][fallback]). One engine, two granularities — an elegant unification.

### 2. Rendering & layout

Side-by-side is the default (and, unlike difftastic, there is no inline/unified mode). The viewer is an interactive web/VS Code surface with a **middle bar** connecting corresponding blocks, a **minimap** that after the 2024-10-09 UI refresh renders "a true thumbnail of the changes, including a rendering of the code" ([GitHub App UI post][new-ui]), and hunk headers that show **scopes**: "SemanticDiff keeps track of where scopes (classes, functions, structs, …) start/end and what name they are assigned"; headers "list all elements that are active in the first line of the hunk in hierarchical order" ([scopes docs][scopes]). Colors ([colors docs][colors]): "two shades of red and green" — full added/removed lines get the intense shade; moved lines get "a less intense color … to remind you that the line is actually new"; for partial-line edits "only the changed section is highlighted" (no faded whole-line wash); where one side has no counterpart, "the other side of the diff contains a diagonal pattern to indicate that there is no matching content." In VS Code, syntax colors come from the user's theme.

### 3. Intra-line & noise handling

This is the product's core and the best-documented part. The [invariances page][invariances] enumerates, per language, "changes that do not modify the program on a syntactic level" plus curated rules for changes "that modify the code on a syntactic level but that do not change the semantics." Representative entries:

| Language       | Invariances (verbatim highlights)                                                                                              |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| C#, Go         | "Adding/Removing unnecessary parenthesis", "Changing the base of an integer literal", "Escaping characters in strings"         |
| Go             | additionally "Reordering of type elements in a type term"                                                                      |
| JavaScript/JSX | "Reordering keys in an object declaration", "Converting between an anonymous/arrow function"                                   |
| Python         | "Splitting / combining of strings", "Reordering of keyword arguments" (`foo(a=1, b=2)` ≡ `foo(b=2, a=1)`)                      |
| HTML           | "Collapse whitespace according to CSS rules", "Ignore order of attributes in tags", tag/attribute case-insensitivity, entities |
| Rust           | "Exchanging the deprecated `...` range operator with `..=`"                                                                    |
| CSS            | "(Only syntactic equivalence)" — no semantic rules                                                                             |

Moved-code detection requires that a block "cover at least one complete line"; moves render "with a border around the old and new code. The border color is different for each move," and a `Compare With Original` mode diffs the moved block against its origin — unchanged moves display "Moved without changes" in italics ([moved-code docs][moved]). Refactoring detection "is currently limited to renames, but will be extended over time"; "Each rename uses a unique color to make it easy to spot each instance" ([refactoring docs][refactor]). Changes inside comments can be suppressed (`semanticdiff.diff.hideComments`). Invisible-change handling (highlight both cause and effect) is covered in §Design philosophy. A related security angle: their [Unicode-tricks study][unicode] (2023-12-19) tested GitHub/GitLab/Bitbucket against homoglyphs, invisible identifiers (Hangul Filler), and bidi overrides — "none of them warned me about homoglyph characters"; only bidi triggered warnings — positioning parser-backed diffs as a defense.

### 4. Navigation, folding & scale

Diffs open collapsed to context (`semanticdiff.diff.contextLines`, default 3); clicking a scope in the hunk header loads more context ("You can click on the scopes to load more context" — [scopes docs][scopes]). The toolbar has next/previous-change navigation; the minimap doubles as a scrollbar with move-colored blocks; hovering a moved block offers an arrow to "jump directly to the source or destination of a move" ([moved-code docs][moved]). The GitHub App adds a collapsible file-tree sidebar (`Ctrl+B`/`⌘+B`) and per-reviewer "mark files as reviewed" checkboxes whose state "is only visible to you, so multiple reviewers all have their own review status" ([UI post][new-ui]). No documented large-diff performance guards (no size cutoffs, no lazy-parse claims) — the only degradation path documented is the unsupported-format fallback.

### 5. VCS & review integration

The VS Code extension attaches to VS Code's own diff surfaces (SCM view, diff tabs; options to auto-switch to the SemanticDiff view and close the original tab), so git plumbing is whatever VS Code already resolved — the extension diffs the two buffers it is handed. The GitHub App is a genuine review surface, not just a viewer: the free tier already includes "write review comments, approve/request changes, public and private repositories" ([pricing][pricing]), and the Threads tab lists all comment threads with pending/resolved state and jump-to-code ([UI post][new-ui]). Billing is installation-scoped seats via Paddle ("Plans are always associated with installations and not individual users" — [plans docs][plans]); 0 € for 3 seats and unlimited public repos, 9 €/seat/month (7 € yearly) for Professional. **Absent:** stacked-PR or multi-revision (Gerrit-style patchset interdiff) support, staging/hunk selection, merge/conflict tooling, and any CLI — the delivery surfaces are exactly the two GUIs.

### 6. Architecture & reuse

Closed source throughout; `Sysmagine/SemanticDiff` on GitHub exists only for bug reports. The architecture splits into a local engine (VS Code extension — offline-capable, telemetry limited to "the file extensions of the files you diffed … but no information about their contents" [FAQ][faq]) and a hosted PR-analysis service (GitHub App). Parsers are proprietary and deliberately fewer than difftastic's ~50 tree-sitter grammars: their comparison post frames it as stricter parser requirements for semantic analysis, citing difftastic's C/C++ preprocessor weakness as the cost of breadth. Nothing is reusable as code; what travels are the _ideas_ — the invariance rule layer as a separate, per-language, curated pass over a structural diff; the block (not line) alignment model; the fallback-as-degenerate-case trick; the third-change-type color proposal; and the level-1..4 relevance ladder as a design vocabulary.

## Strengths

- The clearest published articulation of the formatting-noise problem: the four-level relevance ladder and the explicit "cutoff inside level 3" policy give a principled, trust-preserving boundary rather than an ad-hoc ignore list.
- Per-language invariance catalogs are documented user-facing contract, not folklore — reviewers can know exactly what is being hidden and why.
- Invisible-change detection (f-string prefix removal, and the Unicode-trick threat model) — a class of dangers line diffs and even structural diffs miss entirely.
- Moved-code UX is unusually complete: per-move border colors, minimap encoding, jump arrows, and `Compare With Original` for edits inside moves.
- Block-based pane alignment is honest about tree diffs: it never fakes a 1:1 line correspondence that re-wrapping destroyed.
- Local computation + minimal telemetry in the VS Code extension; offline-capable.
- Real review-platform integration (comments, approvals, per-reviewer viewed state) rather than viewer-only.

## Weaknesses

- Closed source: the matching algorithm, its complexity, and its failure modes are unauditable; no library or CLI to embed; longevity risk for a small vendor.
- Language coverage is narrow by design (no C/C++, no Markdown, Swift only on the hosted app) — the invariance approach demands hand-curated rules per language, which does not scale like grammar-only structural diffing.
- Rename detection is the only shipped refactoring type ("currently limited to renames").
- No unified/inline view, no stacked-PR/interdiff model, no hunk staging, no merge tooling.
- Server-side processing for the GitHub App (with paid queue priority) puts private-repo code through their service.
- Moved-code detection is within-file only (no cross-file move docs) and requires at least one full line.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                      | Trade-off                                                                                          |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Semantic invariances atop a structural diff, cutoff "inside level 3" | Hide what reviewers provably don't care about without becoming an untrusted equivalence prover | Every language needs hand-curated rules; coverage grows slowly (14+ languages vs difftastic's 50+) |
| Block alignment instead of line alignment                            | Tree diffs make 1:1 line pairing "impossible" after re-wrapping; blocks are the truthful unit  | Panes scroll with locally independent layout; users lose the familiar line-to-line reading grid    |
| Highlight invisible changes on _both_ cause and effect               | "not only to hide changes, but also to inform developers about easily overlooked changes"      | Extra red/green noise until the proposed third change-type color ships                             |
| GUI-only delivery (VS Code + GitHub App), no CLI                     | Interactive affordances (minimap, move jumps, context loading) are the product                 | Not scriptable, not embeddable, no `git difftool` story; difftastic keeps that niche               |
| Local engine in the extension, hosted service for PRs                | Privacy/offline story for editors; zero-install review surface for teams                       | Two deployment paths; private-repo PR analysis leaves the user's machine                           |
| Fallback = same engine with line-as-one-token                        | One code path; unsupported formats still get moved-line detection                              | Fallback quality is plain text diff — no word-level refinement documented for it                   |

## Sources

- Homepage — <https://semanticdiff.com/>
- Docs index — <https://semanticdiff.com/docs/> (What is SemanticDiff: <https://semanticdiff.com/docs/what-is-semanticdiff/>)
- Understanding the Diff — <https://semanticdiff.com/docs/understand-diff/> (colors, moved code, refactoring/grouping, scopes, fallback subpages)
- Invariances — <https://semanticdiff.com/docs/invariances/>
- VS Code options — <https://semanticdiff.com/docs/vscode/options/>; FAQ — <https://semanticdiff.com/vscode/faq/>
- GitHub App plans — <https://semanticdiff.com/docs/github/plans/>; pricing — <https://semanticdiff.com/pricing/>
- Blog: "SemanticDiff vs. Difftastic" (2024-02-05) — <https://semanticdiff.com/blog/semanticdiff-vs-difftastic/>
- Blog: "How far should a programming language aware diff go?" (July 2024) — <https://semanticdiff.com/blog/language-aware-diff-how-far/>
- Blog: "What should semantic diffs highlight: The change or its effect?" (2025-02-04) — <https://semanticdiff.com/blog/language-aware-diff-highlight/>
- Blog: "Unicode tricks in pull requests" (2023-12-19) — <https://semanticdiff.com/blog/pull-request-unicode-tricks/>
- Blog: "Improved User Interface For GitHub App" (2024-10-09) — <https://semanticdiff.com/blog/new-github-app-ui/>

<!-- References -->

[home]: https://semanticdiff.com/
[docs]: https://semanticdiff.com/docs/
[blog]: https://semanticdiff.com/blog/
[faq]: https://semanticdiff.com/vscode/faq/
[understand]: https://semanticdiff.com/docs/understand-diff/
[colors]: https://semanticdiff.com/docs/understand-diff/colors/
[moved]: https://semanticdiff.com/docs/understand-diff/moved-code/
[refactor]: https://semanticdiff.com/docs/understand-diff/refactoring-grouping/
[scopes]: https://semanticdiff.com/docs/understand-diff/scopes/
[fallback]: https://semanticdiff.com/docs/understand-diff/fallback-diff/
[invariances]: https://semanticdiff.com/docs/invariances/
[plans]: https://semanticdiff.com/docs/github/plans/
[pricing]: https://semanticdiff.com/pricing/
[vs-difftastic]: https://semanticdiff.com/blog/semanticdiff-vs-difftastic/
[how-far]: https://semanticdiff.com/blog/language-aware-diff-how-far/
[highlight]: https://semanticdiff.com/blog/language-aware-diff-highlight/
[unicode]: https://semanticdiff.com/blog/pull-request-unicode-tricks/
[new-ui]: https://semanticdiff.com/blog/new-github-app-ui/
[v0100]: https://semanticdiff.com/blog/semanticdiff-0.10.0/
[gh-support]: https://github.com/Sysmagine/SemanticDiff

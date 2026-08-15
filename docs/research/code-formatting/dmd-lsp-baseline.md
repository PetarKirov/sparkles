# The Substrate — What `sparkles:dmd-lsp` Actually Gives a Formatter

The survey's questions all converge on one: **what does a D formatter have to build on?** This
page inventories the substrate against the pinned `dmd:frontend` fork, and it reports a result that
changes the design.

**Last reviewed:** August 15, 2026

> [!IMPORTANT]
> **Headline finding: the token spine is already there.** The pinned DMD fork's lexer can emit
> **comments as tokens** (`commentToken` → `TOK.comment`) and **whitespace as tokens**
> (`whitespaceToken` → `TOK.whitespace`, a DMDLIB-only entry point), every `Token` carries a
> `const(char)* ptr` into the source buffer, and `Loc` exposes **`fileOffset()`**. `dmd.tokens` is
> already imported by `libs/dmd-lsp`, and `dmd:lexer` is already in the link closure. **A
> full-fidelity D token stream requires no new dependency, no tree-sitter, and no fork change.**
>
> This inverts the working assumption this survey started from. The earlier reading — "DMD gives
> you an AST with no trivia and `Loc` without offsets" — was true of the AST, and misleading about
> the substrate as a whole.

---

## The inventory

| Capability                   | Available?                     | Evidence                                                                                          |
| ---------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------- |
| Parsed AST                   | ✅                             | `dmd.frontend : parseModule`                                                                      |
| Semantic analysis            | ✅ (not needed for formatting) | `fullSemantic`                                                                                    |
| Declaration printing         | ✅                             | `dmd.hdrgen` — flat text, no break points                                                         |
| **Token stream**             | ✅                             | `dmd.lexer.Lexer`, already linked                                                                 |
| **Comments as tokens**       | ✅                             | `bool commentToken; // comments are TOK.comment's`                                                |
| **Whitespace as tokens**     | ✅                             | `bool whitespaceToken; // tokenize whitespaces (only for DMDLIB)`                                 |
| **Byte offsets per token**   | ✅                             | `Token.ptr` — "pointer to first character of this token within buffer"                            |
| **Byte offset from a `Loc`** | ✅                             | `Loc.fileOffset()`; `SourceLoc` carries `filename`, `line`, `column`, `fileOffset`, `fileContent` |
| **DDoc attached to tokens**  | ✅                             | `Token.blockComment` ("doc comment string prior to this token"), `Token.lineComment`              |
| **Node _end_ positions**     | ❓                             | Not inventoried — see [Q-b](#q-b-node-end-positions)                                              |
| Trivia in the AST            | ❌                             | DMD's AST discards comments and normalizes literals                                               |
| A full-fidelity tree         | ❌                             | No CST; the alternative is `libs/tree-sitter` + `tree-sitter-d`                                   |

### The lexer, in its own words

```d
bool commentToken;      // comments are TOK.comment's
…
bool whitespaceToken;   // tokenize whitespaces (only for DMDLIB)
```

```d
/***********************
 * Alternative entry point for DMDLIB, adds `whitespaceToken`
 */
this(const(char)* filename, const(char)* base, size_t begoffset, size_t endoffset,
    bool doDocComment, bool commentToken, bool whitespaceToken,
    ErrorSink errorSink, const CompileEnv* compileEnv = null)
```

— [`dmd/compiler/src/dmd/lexer.d`][lexer] @ `ea883751`

"Alternative entry point for **DMDLIB**" is the tell: this constructor exists for library consumers
of the frontend — which is exactly what `sparkles:dmd-lsp` is.

### The token

```d
extern (C++) struct Token
{
    Token* next;
    Loc loc;
    const(char)* ptr; // pointer to first character of this token within buffer
    TOK value;
    const(char)[] blockComment; // doc comment string prior to this token
    const(char)[] lineComment; // doc comment for previous token
```

— [`dmd/compiler/src/dmd/tokens.d`][tokens]

`ptr` gives an exact byte offset (`ptr - base`); the next token's `ptr` gives this one's end. So a
lossless token+trivia stream with exact spans is directly constructible, which is
[the three-layer architecture de Jonge & Visser prescribe][three-layer] minus the AST↔token
linkage.

`TOK.comment` and `TOK.whitespace` are both real enum members.

---

## The open questions, re-answered

### Q-a: is the lexer reachable with comments retained and exact offsets?

**Answered: yes, and it is already linked.** `dmd.tokens` is imported today by
`libs/dmd-lsp/src/sparkles/dmd_lsp/visitor.d:96`, and `libs/dmd-lsp/dub.sdl`'s link workaround
already names `dmd:lexer`. The remaining work is a spike, not a dependency negotiation:
instantiate `Lexer` with `commentToken: true, whitespaceToken: true` and confirm the stream
reconstructs the input byte-for-byte.

**Consequence: the tree-sitter route is no longer required.** `libs/tree-sitter` +
[`tree-sitter-d`][ts-d] remain a viable alternative substrate (see [topiary][topiary]), but they
are now a _choice_, not a necessity — and choosing them would mean maintaining a second D grammar
alongside the compiler's own lexer.

### Q-b: node end positions

**Still open, and now less important.** With a token spine, the formatter's primary index is the
token stream; the AST is only an oracle keyed by _start_ offsets, which is exactly how
[dfmt's `ASTInformation`][dfmt] works — ~24 sorted `size_t[]` arrays of positions, queried by
binary search. `Loc.fileOffset()` supplies those positions directly.

End positions would still be needed for a _verbatim-slice_ strategy ("reprint this subtree from the
original bytes"), which is [de Jonge & Visser's text patching][layout-preserving] and
[rustfmt's `missed_spans`][rustfmt] fallback. Worth measuring per node kind, but it no longer gates
the architecture.

### Q-c: print from the AST, or format the token stream?

The evidence across the survey now points one way, and the substrate finding removes the last
argument against it.

|                    | Print from AST                                                                                | **Format the token stream, AST as oracle**                                                  |
| ------------------ | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Comment attachment | a real module — [prettier: 1,255 lines for one language][prettier]; [rustfmt: 2,149][rustfmt] | **none needed** — token order is the answer ([dfmt][dfmt], [clang-format][clang-format])    |
| Broken input       | refuses ([prettier][prettier], [gofmt][gofmt], [rustfmt][rustfmt])                            | **formats anyway** ([dfmt][dfmt], [clang-format][clang-format]) — the LSP-on-keystroke case |
| Literals           | normalized by DMD's AST — a correctness hazard                                                | verbatim by construction                                                                    |
| Verification       | needs a reparse                                                                               | **token equality modulo whitespace**, cheap, and the lexer is already there                 |
| Precedent in D     | none                                                                                          | [dfmt][dfmt] and, differently, [sdfmt][d-landscape]                                         |

**Recommendation: format the token stream.** Every other question in this survey gets easier.

### Q-d: the verification contract

[Token equality modulo whitespace][verification], available essentially for free once the spine
exists, plus a **separate DDoc check** following [ocamlformat's `moved_docstrings`][ocamlformat] —
D has OCaml's hazard exactly, and `Token.blockComment`/`lineComment` make the check tractable.

### Q-e: the D-specific hard list

Constructs where the printer must be locally the identity function, or needs a special rule.
Each needs a fixture in the corpus before the printer touches it:

`q{ … }` token strings · `q"EOS … EOS"` and `q"( … )"` delimited strings · nested `/+ … +/`
comments · `mixin("…")` bodies containing D · `asm { … }` (verbatim) · `version`/`static if`
(both arms format) · `__traits(…)` · `is(…)` expressions · UDAs and attribute clusters ·
`in`/`out`/`invariant` contracts and template constraints · `extern(C++, ns)` · `#line` ·
`__EOF__` · and **DDoc**, whose internal `Params:`/`Returns:` layout is a second formatting
language ([embedded languages][concepts-embedded]).

### Q-g: latency

Formatting needs `parseModule` at most, and on the token-spine design it needs **only the lexer**
for the common path — the AST oracle is required for structural disambiguation, not for every
keystroke. `fullSemantic` is never needed. A p95 budget should be stated and measured in M0.

### Q-h: the output contract

[clang-format][clang-format] and [Roslyn][roslyn] agree from opposite architectures: a formatter
serving an editor emits **edits**, not a document. Both range formatting and cursor preservation
follow from that and are expensive to retrofit. Decide at M0.

### Q-i: the existing engines

[`signature_layout.d`][sig-layout] is a working staged `group` with an injected width measurer;
[`prettyprint.d`][prettyprint] is a value printer and is out of scope. The repository should not
end up with three layout engines — see [the proposal][proposal].

---

## What the substrate does _not_ give you

- **No CST.** The AST is lossy; the token stream is the fidelity layer, and keeping the two in
  correspondence is the formatter's job (the [three-layer architecture][three-layer]).
- **No `TextEdit` machinery.** Nothing here computes minimal edits.
- **No width model.** Grapheme/East-Asian width must come from elsewhere —
  [`signature_layout.d`'s injected measurer][sig-layout] is the existing seam, and
  [sdfmt counts graphemes][d-landscape] where dfmt counts bytes.
- **No `.editorconfig` reader.** dfmt has one (458 lines); migration compatibility needs it.

---

## Sources

- Pinned frontend: `dmd:frontend` @ `ea88375142644d2dc7755089357acdfdd69c6620`
  (`git+https://github.com/PetarKirov/dmd.git`, the `dmdserver-dub` LanguageServer fork), read at
  `~/.dub/packages/dmd/ea883751…/dmd/compiler/src/dmd/`: `lexer.d`, `tokens.d`, `location.d`
- In-repo: `libs/dmd-lsp/dub.sdl`, `libs/dmd-lsp/src/sparkles/dmd_lsp/{api,visitor,signature,ddoc}.d`,
  `libs/twoslash/src/sparkles/twoslash/signature_layout.d`
- Specs: [`docs/specs/dmd-lsp/`](../../specs/dmd-lsp/index.md) — TIP5 and SIG1–SIG6 are the
  existing layout requirements

**Related deep-dives in this tree:**
[The D landscape][d-landscape] · [Layout preservation][layout-preserving] · [dfmt][dfmt] ·
[clang-format][clang-format] · [swift-format][swift-format] · [topiary][topiary] ·
[Verification][verification] · [The proposal][proposal]

<!-- References -->

[lexer]: https://github.com/PetarKirov/dmd/blob/ea88375142644d2dc7755089357acdfdd69c6620/compiler/src/dmd/lexer.d
[tokens]: https://github.com/PetarKirov/dmd/blob/ea88375142644d2dc7755089357acdfdd69c6620/compiler/src/dmd/tokens.d
[location]: https://github.com/PetarKirov/dmd/blob/ea88375142644d2dc7755089357acdfdd69c6620/compiler/src/dmd/location.d
[ts-d]: https://github.com/PetarKirov/tree-sitter-d
[sig-layout]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/twoslash/src/sparkles/twoslash/signature_layout.d
[prettyprint]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/base/src/sparkles/base/prettyprint.d
[layout-preserving]: ./theory/layout-preserving.md
[three-layer]: ./theory/layout-preserving.md#text-patching-stop-unparsing
[concepts-embedded]: ./concepts.md#10-embedded-and-foreign-languages
[verification]: ./verification.md
[d-landscape]: ./d-landscape.md
[proposal]: ./dmd-fmt-proposal.md
[dfmt]: ./dfmt.md
[prettier]: ./prettier.md
[rustfmt]: ./rustfmt.md
[gofmt]: ./gofmt.md
[clang-format]: ./clang-format.md
[roslyn]: ./roslyn.md
[swift-format]: ./swift-format.md
[topiary]: ./topiary.md
[ocamlformat]: ./ocamlformat.md

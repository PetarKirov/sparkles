# nixpkgs `lib.fileset` (Nix)

The functional model this repository's fileset abstraction is built on, and
the only subject in the survey that has written down _why_ each API decision
was taken. It is also the one with no textual syntax at all — which is the gap
this survey exists to close.

|                   |                                                                    |
| ----------------- | ------------------------------------------------------------------ |
| Language          | Nix                                                                |
| License           | MIT                                                                |
| Repository        | [NixOS/nixpkgs][nixpkgs]                                           |
| Surveyed revision | [`82339b1b`][fs-readme] (all file/line citations pin this commit)  |
| Category          | Build-input file selection                                         |
| Composition model | Set algebra (union / intersection / difference), **no complement** |
| Grammar           | None — a combinator API in the host language                       |

## Overview

### What it solves

Choosing which local files enter the Nix store, so that a rebuild is not
triggered by an edit to a file the derivation never reads.

### Design philosophy

Stated as three properties and one explicit non-goal:

> - Easy: The functions should have obvious semantics, be low in number and be
>   composable.
> - Safe: Throw early and helpful errors when mistakes are detected.
> - Lazy: Only compute values when necessary.
>
> Non-goals are:
>
> - Efficient: If the abstraction proves itself worthwhile but too slow, it can
>   still be optimized further.
>
> — [`lib/fileset/README.md`][fs-readme]

## How it works

The public surface is eleven functions — `union`, `unions`, `intersection`,
`difference`, `fileFilter`, `maybeMissing`, `gitTracked`, `gitTrackedWith`,
`fromSource`, `toSource`, `toList`, plus `trace`/`traceVal` and the `empty`
identity ([`lib/fileset/default.nix`][fs-default]). Paths coerce to filesets
implicitly, so `union ./foo ./bar` needs no constructor.

The internal representation is a **versioned tree**, not a predicate:

> - `_internalBase` (path): Any files outside of this path cannot influence the
>   set of files. This is always a directory and should be as long as possible.
> - `_internalTree` (filesetTree): A tree representation of all included files
>   under `_internalBase`.
>
> — [`lib/fileset/README.md`][fs-readme]

with `"directory"` as a special node meaning "all of it, recursively, **allowing
early cutoff**".

## Analysis

### 1. Composition model

Set algebra, and the omissions are argued rather than accidental.

**No complement.** There is no `complement`/`not`; `difference` is the only
subtractive form. The README does not frame this as a pruning decision — it
falls out of `_internalBase` influence tracking, which requires every set to
name a directory that bounds it. A complement has no such bound. This is the
same conclusion the [recommendations][rec] reach from the traversal side,
arrived at from the representation side.

**No `intersections`.** A deliberate asymmetry with `unions`:

> There is no suitable return value for `intersections [ ]` … Could throw an
> error for that case … Create a special value to represent "all the files" and
> return that — (+) Such a value could then not be used with `fileFilter`
> unless the internal representation is changed considerably.
>
> — [`lib/fileset/README.md`][fs-readme]

The nullary-intersection problem is exactly the "do we need a universe
primary?" question, and nixpkgs' answer is: a universe value would be a
different kind of thing from every other fileset, so don't have one.

**A special empty.** `empty` is `_internalIsEmptyWithoutBase`, a representation
with no base path at all, introduced because the obvious encoding
(`_internalBase = /.`) would poison `toSource`:

> `union empty ./.` would have `/.` as the base path, which would then prevent
> `toSource { root = ./.; fileset = union empty ./.; }` from working, which is
> not as one would expect.
>
> — [`lib/fileset/README.md`][fs-readme]

### 2. Operator surface & precedence

Not applicable: composition is function application, so precedence is Nix's.
This is the whole reason a textual surface is wanted — `union (difference ./src
(unions [ ./src/generated ./src/vendor ])) ./docs` is the same expression as
`(src ~ (src/generated | src/vendor)) | docs` and is markedly harder to read or
to type into a prompt.

### 3. Primary vocabulary & the kind namespace

Primaries are paths (coerced), `gitTracked`, `fileFilter pred path`, and
`fromSource`. `fileFilter`'s predicate receives `{ name, type, hasExt }` — a
deliberately small property set, chosen so it can later become reproducible
data (`subpath`, `components`) rather than an arbitrary closure.

Note the design decision that `fileFilter` takes a **path**, not a fileset, and
the documented workaround, which is quoted verbatim inside the error message
the library throws:

```nix
lib.fileset.fileFilter: Second argument is a file set, but it should be a path instead.
    If you need to filter files in a file set, use `intersection fileset (fileFilter pred ./.)` instead.
```

— [`lib/fileset/default.nix`][fs-default]

That is the survey's best example of an error message that teaches the algebra
instead of merely reporting a type.

### 4. Anchoring & glob semantics

There are no globs. A path is a path; recursion is implied by a directory.
Anchoring is absolute, via the Nix path type. This is why the library is
"safe" in the sense it claims — no pattern means no pattern-anchoring
ambiguity — and why a textual front end must re-introduce the entire question
this survey's other subjects spend their design budget on.

### 5. Lexis: quoting, escaping, reserved characters

Not applicable; Nix's own lexis applies. Worth noting that the library
**refuses store paths in strings** (`"/nix/store/...-source"`), partly because
string coercion would make `union "${root}/foo" "${root}/bar"` plausible-looking
and dangerous.

### 6. Evaluation strategy & pruning

Laziness plus the `"directory"` early-cutoff node is the pruning mechanism: an
unexamined subtree that is wholly included never gets enumerated. **Empty
directories are not representable at all**, which is argued for at length:

> File sets can only represent a _set_ of local files. Directories on their own
> are not representable. … This matches how Git only supports files, so
> developers should already be used to it.
>
> — [`lib/fileset/README.md`][fs-readme]

and strict existence checking makes a missing path an error rather than an
empty set, with `maybeMissing` as the explicit opt-out:

> This is dangerous, because you wouldn't be protected against typos anymore.
> E.g. when trying to prevent `./secret` from being imported, a typo like
> `difference ./. ./sercet` would import it regardless.
>
> — [`lib/fileset/README.md`][fs-readme]

That argument transfers directly to a textual language: a misspelled literal
path should not silently widen a `difference`.

## Strengths

- Every API decision is written down with its alternatives and their costs —
  the README is the model this survey's own recommendations imitate.
- Influence tracking (`_internalBase`) gives a real guarantee: adding a new file
  to a project can never change an existing expression's meaning.
- Errors teach the algebra (`fileFilter`'s message names the `intersection`
  idiom).
- Strict existence checking turns typos into errors.

## Weaknesses

- No textual syntax, so it cannot be typed into a prompt, a flag or a config
  string — the gap this survey closes.
- No globs, so "every `.d` file under `libs/`" is a `fileFilter` closure rather
  than a pattern.
- The versioned internal representation is a genuine maintenance cost
  (three versions so far, with conversions between them).

## Key design decisions and trade-offs

| Decision                                 | Rationale                                                         | Trade-off                                                          |
| ---------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------ |
| Influence tracking via `_internalBase`   | Adding files can never change an expression's meaning             | `toSource { root = ./dir; fileset = ./.; }` errors on a valid case |
| No complement                            | A complement has no bounding base path                            | `difference` must be written explicitly every time                 |
| No `intersections` list form             | No sound return value for the nullary case                        | Asymmetric with `unions`                                           |
| Special `empty` without a base           | Gives `union` an identity without poisoning `toSource`            | One more case in every internal function                           |
| Directories are not representable        | No coherent combinator semantics exist for them                   | Empty directories are silently dropped                             |
| Strict path existence                    | A typo in a `difference` would otherwise silently import a secret | `difference ./. ./maybe-missing` needs `maybeMissing`              |
| `fileFilter` takes a path, not a fileset | Keeps the door open for reproducible predicate properties         | Composition needs the `intersection` idiom                         |

## Sources

- [`lib/fileset/README.md`][fs-readme] — goals, internal representation and the whole "API design decisions" section (quoted above).
- [`lib/fileset/default.nix`][fs-default] — the public functions and their error messages (quoted above).
- [`lib/fileset/internal.nix`][fs-internal] — the versioned representation and the coercion machinery.

<!-- References -->

[nixpkgs]: https://github.com/NixOS/nixpkgs
[fs-readme]: https://github.com/NixOS/nixpkgs/blob/82339b1bf90e105158550241d073e4641a274528/lib/fileset/README.md
[fs-default]: https://github.com/NixOS/nixpkgs/blob/82339b1bf90e105158550241d073e4641a274528/lib/fileset/default.nix
[fs-internal]: https://github.com/NixOS/nixpkgs/blob/82339b1bf90e105158550241d073e4641a274528/lib/fileset/internal.nix
[rec]: ./recommendations.md

# Implicit-conjunction pickers: fzf and fff

The model hue's picker uses today, and the one this survey replaces inside the
fileset region. Surveyed for two things: the precedence inversion that implicit
AND forces, and the shape of the heuristics needed to decide, per token,
whether the user meant a filter or a search.

|                    |                                                             |
| ------------------ | ----------------------------------------------------------- |
| Subjects           | [fzf][fzf-repo] (Go) · [fff][fff-repo] (Rust)               |
| Surveyed revisions | fzf [`b1be3a8b`][fzf-readme] · fff [`3a0ce85c`][fff-parser] |
| Category           | Interactive finder query syntax                             |
| Composition model  | Implicit conjunction over juxtaposed terms                  |
| Grammar            | Whitespace tokenisation + per-token classification          |

## Overview

### What they solve

Narrowing a list of a few hundred thousand strings, interactively, while the
user is still typing — so every keystroke must produce a legal query and the
notation must have no closing delimiters to leave unbalanced.

### Design philosophy

**fzf** filters strings. Its terms are all string predicates over one axis, so
conjunction is the only combinator anyone needs and can be left implicit.

**fff** filters _files_, which is the step hue took and the reason its query is
a different kind of thing:

> fzf's pattern mods (`'exact`, `^prefix`, `suffix$`, `!inverse`) are a filter
> over strings. fff's query is a filter over **files**.
>
> — [hue's picker spec][picker]

## How it works

fzf's whole language is a table:

| Token    | Match type           | Description                                  |
| -------- | -------------------- | -------------------------------------------- |
| `sbtrkt` | fuzzy-match          | Items that match `sbtrkt`                    |
| `'wild`  | exact-match (quoted) | Items that include `wild`                    |
| `'wild'` | exact-boundary-match | Items that include `wild` at word boundaries |
| `^music` | prefix-exact-match   | Items that start with `music`                |
| `.mp3$`  | suffix-exact-match   | Items that end with `.mp3`                   |
| `!fire`  | inverse-exact-match  | Items that do not include `fire`             |

— [`README.md`][fzf-readme]

fff replaces the sigil table with a `Constraint` enum — `Extension`, `Glob`,
`PathSegment`, `FilePath`, `FileType`, `GitStatus`, `Not`, plus `Text`/`Parts`
for the fuzzy remainder ([`constraints.rs`][fff-constraints]) — and a
`parse_token` that dispatches on the first byte.

## Analysis

### 1. Composition model

Conjunction of every term, with `!` negating one term. fzf then adds a single
disjunction operator, and here is the consequence worth recording:

> A single bar character term acts as an OR operator. For example, the
> following query matches entries that start with `core` and end with either
> `go`, `rb`, or `py`.
>
> ```
> ^core go$ | rb$ | py$
> ```
>
> — [`README.md`][fzf-readme]

`|` binds **tighter** than the implicit conjunction — the exact inverse of
every explicit-operator language in this survey, and of boolean algebra. It has
to: if `|` bound loosely, `a b | c d` would be unwritable without parentheses,
and parentheses are what an implicit-AND language is avoiding. **Implicit
conjunction forces the precedence inversion.** That is the strongest single
argument against extending an implicit-AND query with set operators rather than
delimiting an explicit region.

### 2. Operator surface & precedence

fzf: sigils (`'`, `^`, `$`, `!`) plus `|`; two levels, inverted. fff: no infix
operators at all — negation is a token prefix, and there is no disjunction.

### 3. Primary vocabulary & the kind namespace

fff's dispatch is a chain of first-byte cases with a `key:value` fallback:

```rust
match first_byte {
    b'*' if config.enable_extension() => …      // *.rs → Extension
    b'!' if config.enable_exclude()   => …      // !test → Not(…)
    b'/' if config.enable_path_segments() => …  // /src/ → PathSegment
    _ if … token.ends_with('/') => …            // www/  → PathSegment
    _ if … is_filename_constraint_token(token) => Some(Constraint::FilePath(token)),
    _ => {
        if config.enable_glob() && config.is_glob_pattern(token) { … }
        if let Some(colon_idx) = memchr(b':', token.as_bytes()) {
            match key {
                "type"  if config.enable_type_filter() => …
                "status" | "st" | "g" | "git" if config.enable_git_status() => …
```

— [`parser.rs`][fff-parser]

Two things to take from this. The `kind:` namespace is real and useful
(`type:`, `git:`), but the **one- and two-letter aliases `g:` and `st:`** —
which hue inherited — collide with any short bare token containing a colon,
Windows drive letters included. And every other arm is a heuristic.

### 4. Anchoring & glob semantics

Delegated: fff's `Glob` constraint hands the token to `globset`, whose rules
are `.gitignore`'s. The classifier `is_glob_pattern` decides _whether_ a token
is a glob at all, which means the anchoring question is downstream of a guess.

### 5. Lexis: quoting, escaping, reserved characters

There is no quoting. Tokens are whitespace-separated, so a path containing a
space cannot be written, and escaping is a single global carve-out:

```rust
// Backslash escape: \token → treat as literal text, skip all constraint parsing.
if token.starts_with('\\') && token.len() > 1 { return None; }
```

— [`parser.rs`][fff-parser]

i.e. `\` suppresses **classification**, not globbing — a different meaning from
the `\` of every other subject in this survey.

The cost of classification-by-heuristic is visible in the source. To decide
whether a bare token like `score.rs` is a path filter or fuzzy text, fff needs:

- a whole-query arity check (a single-token query is never a `FilePath`, "the
  user is fuzzy-searching, not filtering");
- a location-suffix check, because `/Users/x/file.rs:12` would otherwise be
  eaten by the `PathSegment` arm;
- a per-consumer `treat_lone_path_as_text()` switch, because grep wants the
  opposite answer from files;
- and, inside `is_filename_constraint_token`, an extension shape test — "starts
  with an ASCII letter (rejects version numbers like `v2.0`), followed by
  alphanumeric chars, max 10 chars total"

— all in [`parser.rs`][fff-parser] and [`constraints.rs`][fff-constraints].
None of these are bugs; they are the irreducible cost of asking one token
stream to be two languages. A delimited region removes every one of them.

### 6. Evaluation strategy & pruning

No plan, and none is possible: the corpus is an already-materialised path list
held in a resident index. Constraints are evaluated as a predicate per
candidate. This is why the implicit-AND model survives at all — it never has to
turn a query into a traversal.

## Strengths

- Nothing to close: every prefix of a legal query is a legal query, which is
  the property an interactive prompt actually needs.
- No syntax to learn for the 90% case.
- fff's `Constraint` enum is a good factoring of _what_ a file query filters
  on, independent of how it is spelled.

## Weaknesses

- Implicit conjunction forces `|` to bind tighter than AND.
- No quoting, so a path with a space is unwritable.
- Per-token classification needs a growing table of carve-outs, and the same
  token means different things to different consumers.
- Short `kind:` aliases (`g:`, `st:`) are ambiguous with paths.

## Key design decisions and trade-offs

| Decision                         | Rationale                                              | Trade-off                                                 |
| -------------------------------- | ------------------------------------------------------ | --------------------------------------------------------- |
| Implicit conjunction             | Every prefix of the query is legal while typing        | Forces `\|` to bind tighter than AND                      |
| Per-token classification         | No delimiter, no mode                                  | A chain of heuristics, and consumer-specific overrides    |
| `\` suppresses classification    | One escape for the whole problem                       | Diverges from `\`-escapes-a-metacharacter everywhere else |
| One- and two-letter kind aliases | Fewer keystrokes in a hot loop                         | Collides with drive letters and short paths               |
| No quoting                       | Whitespace is the only token boundary a typist expects | Paths with spaces are unreachable                         |

## Sources

- [fzf `README.md` § Search syntax][fzf-readme] — the token table and the `|` precedence note (quoted above).
- [fff `crates/fff-query-parser/src/parser.rs`][fff-parser] — `parse_token`, the escape carve-out and the single-token special cases (quoted above).
- [fff `crates/fff-query-parser/src/constraints.rs`][fff-constraints] — the `Constraint` enum and `is_filename_constraint_token` (quoted above).
- [hue picker spec][picker] — `PKQ1`–`PKQ6`, the requirements this survey re-derives.

<!-- References -->

[fzf-repo]: https://github.com/junegunn/fzf
[fzf-readme]: https://github.com/junegunn/fzf/blob/b1be3a8be1b833ce5b92fbbac11637643d60a046/README.md
[fff-repo]: https://github.com/dmtrKovalenko/fff
[fff-parser]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-query-parser/src/parser.rs
[fff-constraints]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-query-parser/src/constraints.rs
[picker]: ../../specs/hue/picker.md

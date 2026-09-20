# Recommendations — the fileset query DSL

What the survey concludes, stated as decisions. Each answers one of the open
questions the design brief left, cites the evidence that settles it, and says
what it costs. The [contradictions] page lists the three places this document
argues against a decision that arrived marked settled.

**Last reviewed:** September 20, 2026

> [!NOTE]
> **Scope.** This is a design document, not an implementation plan. The IR these
> recommendations compile to is being built on a separate track; nothing here
> should be read as a commitment to a module layout.

---

## O1 — Anchoring

**Decision.** Adopt `.gitignore`'s rule, **plus prefix closure**, and retire
`glob_walk.globAny`'s double match.

1. A pattern with no unescaped `/` (a trailing `/` does not count) **floats**:
   it matches any single path segment, i.e. it behaves as `**/p`.
2. A pattern with an unescaped `/` anywhere else is **anchored** to the fileset
   root.
3. A leading `/` forces root anchoring and is not itself part of the pattern.
4. A trailing `/` restricts the match to directories.
5. **Prefix closure**: if a pattern matches path `p` and `p` is a directory,
   every file beneath `p` is in the set. `file:` is the kind that turns this
   off.
6. `*` and `?` never cross `/`; `**` does.

**Why this rule and not the other three.** The field splits by _context_, not
by taste — [Mercurial][hg] ships both rules in one tool and says so, anchoring
`glob:` at the cwd while stating that ".hgignore are not rooted". Our language
serves two contexts at once, so the tie has to be broken on other grounds:

- Rule 1 costs nothing in pruning. A floating pattern has no literal prefix, so
  it forces a full walk — but so does the explicit `**/p` a user would
  otherwise have to type. Anchoring only buys pruning for patterns that contain
  a `/`, and rule 2 anchors exactly those.
- Our users arrive from ripgrep and `.gitignore`, where rule 1 is the law
  ([ripgrep][shell]: "Globbing rules match `.gitignore` globs").
- Rule 5 is the one place the search tools are wrong and the VCS languages are
  right. ripgrep has to document the consequence in its own `--help` — "`-g
foo` is incorrect because `foo/bar` does not match the glob `foo`" — while
  [jj][jj] makes closure the default pattern kind precisely so that `jj diff
src` means what it looks like. A picker whose `src` matches nothing is
  broken. (We diverge from jj in one detail: jj's `glob:` is the
  _non_-closure kind and `prefix-glob:` the closure one; ours are `file:` and
  everything else.)

### The behaviour change, measured

`globAny` today tries each glob against **both** the root-relative path and the
base name, over Phobos' `std.path.globMatch`, whose `*` is path-unaware. The
program below runs the current rule and the proposed one side by side:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "anchoring_rules"
    dependency "sparkles:fuzzy" version="*"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

import sparkles.fuzzy.common : PathFlavor;
import sparkles.fuzzy.glob : GlobMatchWorkspace, GlobProgram, compileGlob, globMatch;

import std.path : baseName, globMatch2 = globMatch;
import std.stdio : writefln;

/// Today: `glob_walk.globAny` — each glob tried against the whole relative
/// path *and* the base name, over Phobos' path-unaware matcher.
bool today(string rel, string pattern) @safe
    => globMatch2(rel, pattern) || globMatch2(rel.baseName, pattern);

/// Proposed: one `.gitignore`-shaped rule over the bounded NFA — a pattern
/// with no unescaped `/` floats, otherwise it is anchored.
bool proposed(string rel, string pattern) @safe
{
    if (!hasUnescapedSlash(pattern))
        // Float: `**/p`, plus `p` itself, because a leading `**/` in the
        // engine consumes at least one separator (see the note below).
        return matches(pattern, rel) || matches("**/" ~ pattern, rel);
    return matches(pattern, rel);
}

bool matches(string pattern, string rel) @safe
{
    GlobProgram!() program;
    GlobMatchWorkspace!() workspace;
    if (compileGlob(pattern, PathFlavor.unix, true, program).hasError)
        return false;
    auto hit = globMatch(program, rel, workspace);
    return hit.hasValue && hit.value;
}

bool hasUnescapedSlash(string pattern) @safe pure nothrow @nogc
{
    // A trailing `/` marks "directories only"; it does not anchor.
    const body_ = pattern.length && pattern[$ - 1] == '/'
        ? pattern[0 .. $ - 1] : pattern;
    for (size_t i; i < body_.length; ++i)
    {
        if (body_[i] == '\\') { ++i; continue; }
        if (body_[i] == '/') return true;
    }
    return false;
}

void main() @safe
{
    static immutable string[2][] cases = [
        ["src/main.d", "*.d"],
        ["src/main.d", "main.d"],
        ["src/deep/main.d", "src/*.d"],
        ["src/main.d", "src/*.d"],
        ["docs/x.md", "docs*md"],
        ["x", "**/x"],
        ["a/b/x", "**/x"],
        ["a/src/main.d", "src/*.d"],
        ["libs/base/src/x.d", "**/src/*.d"],
    ];
    writefln("%-20s %-12s %-7s %s", "path", "pattern", "today", "proposed");
    foreach (c; cases)
        writefln("%-20s %-12s %-7s %s", c[0], c[1],
            today(c[0], c[1]) ? "match" : "-",
            proposed(c[0], c[1]) ? "match" : "-");
}
```

```ansi
path                 pattern      today   proposed
src/main.d           *.d          match   match
src/main.d           main.d       match   match
src/deep/main.d      src/*.d      match   -
src/main.d           src/*.d      match   match
docs/x.md            docs*md      match   -
x                    **/x         -       -
a/b/x                **/x         match   match
a/src/main.d         src/*.d      -       -
libs/base/src/x.d    **/src/*.d   match   match
```

Three things fall out of the run:

- **The common cases are unchanged.** `*.d` and `main.d` still reach
  `src/main.d`; `src/*.d` still reaches `src/main.d`; `src/*.d` still does not
  reach `a/src/main.d`.
- **Two over-matches disappear**, both caused by Phobos' `*` crossing `/`:
  `src/*.d` no longer swallows `src/deep/main.d`, and `docs*md` no longer
  swallows `docs/x.md`. Both are corrections, and both bring us into agreement
  with `.gitignore`, ripgrep and minimatch — the last of which matters because
  `docs/.vitepress/docs-config.json`'s `srcExclude` list is evaluated by
  **VitePress**, not by us, so `ci --audit-fences` and the site build can
  silently disagree today. Every current `srcExclude` entry already begins
  `**/` and is unaffected.
- **One engine gap is exposed.** `**/x` does not match `x`, because
  `sparkles.fuzzy.glob`'s `starAny` before a separator consumes at least that
  separator. `.gitignore` is explicit that "`**/foo` matches file or directory
  `foo` anywhere, the same as pattern `foo`", so this must be fixed in the
  compiler — a leading `**/` should emit an alternation over zero directories —
  rather than papered over in the anchoring layer as the example does.

**Consumers to update.** `libs/docs`' `source_set.d` and hue's
`picker_sources.d`/`picker_grep.d`/`site.d` all go through `globWalkGitRepository`
and inherit the change; hue's tree pane (`explorer.d`) has its **own** copy of
`globAny` plus a hand-rolled string-prefix test that re-admits a directory when
"a path-carrying include glob descends into it". That test is a literal-prefix
lattice with one element, and it is wrong for `**/x/*.log` and for
`{a,b}/*.log`; it should be deleted in favour of the real lattice
([O-lattice](#the-literal-path-prefix-lattice)).

---

## O2 — Reserved characters and escaping

**Decision.** Define the bare-token charset **positively**, with deliberate
headroom; make `\` an escape only for reserved characters, and an **error**
otherwise.

### Bare-token charset

A bare token is one or more bytes drawn from:

- `A`–`Z`, `a`–`z`, `0`–`9`
- `_ - . + @ # % ^ $ = ! ? * [ ] { } , : ; /`
- every byte `>= 0x80`

Everything else is reserved. The reserved set is:

| Reserved                   | Why                                     |
| -------------------------- | --------------------------------------- |
| space, tab, CR, LF, FF, VT | token separator                         |
| `(` `)`                    | grouping                                |
| `\|` `&` `~`               | union, intersection, difference         |
| `"` `'`                    | quoting                                 |
| `\`                        | escape                                  |
| `<` `>` `` ` ``            | **held in reserve** — no meaning today  |
| NUL                        | cannot occur in a POSIX filename anyway |

Defining the set positively is [jj][jj]'s and [Mercurial][hg]'s choice, and the
reason is evolution, not taste: with a positive charset, reserving a new
operator character cannot change the meaning of any query that parses today.
With a "terminates at these characters" rule, every future operator is a silent
breaking change. The three characters held in reserve buy that headroom at a
cost of three escapes on filenames that essentially never occur.

Note what is deliberately **not** reserved: `{ } ,` stay bare because
`sparkles.fuzzy.glob` already compiles `{a,b}` alternation and ripgrep users
expect it; `!` stays bare because there is no unary complement to spell with it
(so `!important!.txt` is a bare token); `:` stays bare because a colon only
begins a kind when the token's leading run matches the kind shape (see O3).

### Escaping

- `\` followed by a **reserved** character yields that character literally.
- `\` followed by anything else is an **error** (`invalidEscape`), not the
  identity.
- A trailing `\` is an error (`unexpectedEnd`).
- `'…'` is a **raw** string: no escapes, no closing-quote escape, so a literal
  backslash needs no doubling.
- `"…"` is a **quoted** string: reserved characters and `\"` may appear; the
  same escape rule applies inside.
- **Quotes do not suppress globbing** (a settled decision this survey agrees
  with — see the worked examples), and they **do** suppress `kind:` parsing,
  because the kind is lexically outside the quotes exactly as in
  [jj's grammar][jj].

Making `\a` an error rather than `a` is a deliberate divergence from
`.gitignore`, whose own documentation says "`\a` matches `a`, even though there
is no need for escaping there". That rule is a one-way door: once `\a` means
`a`, `a` can never become meaningful. It also silently swallows a user who
expected `\n` to be a newline. rsync shows the other failure mode — an escape
whose validity depends on whether a wildcard appears elsewhere in the token —
and is not worth copying under any circumstances.

**Separator.** `/` is the only path separator in pattern text; `\` is always an
escape, never a separator. A Windows user typing `src\app.d` gets
`invalidEscape` at `\a` with a message naming `/`, which is better than the
silent reinterpretation the alternative produces. `PathFlavor.windows` continues
to govern _candidate_ paths only.

### Verification against pathological names

POSIX permits every byte but `/` and NUL in a filename — `find(1)` states it
plainly: "File names are a potential problem since they can contain any
character except `\0` and `/`". Each is reachable:

| Real filename         | Bare?   | How to write it                                      |
| --------------------- | ------- | ---------------------------------------------------- | --- |
| `report 2026.md`      | no      | `"report 2026.md"` or `report\ 2026.md`              |
| `a\|b`                | no      | `"a\|b"` or `a\\                                     | b`  |
| `a&b`                 | no      | `"a&b"` or `a\&b`                                    |
| `main.d~`             | no      | `main.d\~` or `"main.d~"`                            |
| `(draft)`             | no      | `"(draft)"`                                          |
| `!important!.txt`     | **yes** | `!important!.txt`                                    |
| `#notes`              | **yes** | `#notes`                                             |
| `-n`                  | **yes** | `-n`                                                 |
| `a"b`                 | no      | `'a"b'`                                              |
| `a'b`                 | no      | `"a'b"`                                              |
| `a\b`                 | no      | `'a\b'` or `a\\b`                                    |
| a literal `*`         | no      | `\*`                                                 |
| `foo:bar`             | no      | `"foo:bar"` (quoting suppresses the kind)            |
| `C:/data`             | **yes** | `C:/data` — `C` is one character, so not kind-shaped |
| `résumé.md`           | **yes** | bytes ≥ 0x80 are bare                                |
| a name with a newline | no      | **not representable** in the surface syntax          |

The last row is honest rather than a gap to close: a newline cannot be typed
into a picker prompt and cannot appear in a shell word without quoting the
whole expression. Such a path is reachable through the host's own file APIs,
not through this language.

---

## O3 — The `kind:` namespace shape

**Decision.** Reserve the _shape_, not a closed table; widen it beyond the
proposal; retire `g:` and `st:` through an error, not a silent reinterpretation.

### Shape

```
kind = lower , { lower | digit } , { "-" , ( lower | digit ) , { lower | digit } } ;
```

with a **minimum of two characters** before the `:`, and recognised only when
it is the token's leading run and is immediately followed by `:`.

The proposal's `^[a-z]{2,}:` is too narrow on two counts the survey settles:

- **Digits.** Mercurial ships `listfile0:`. A kind table that cannot hold a
  digit will need one.
- **Hyphens.** jj's kinds are `cwd-prefix-glob:`, `root-file:`, `glob-i:`. A
  modifier suffix (`-i`) is the cheapest way to add case-insensitivity, and it
  needs the hyphen.

The two-character minimum is what excludes Windows drive letters: `C:` and `c:`
are one character, so `C:/data` is a path, and the drive-letter guard `PKQ4`
already carries for the neighbouring `:line:col` syntax does not need a sibling
here.

### Retiring `g:` and `st:`

Neither should become a path. Follow [jj revsets][revsets]' pattern of keeping a
foreign spelling in the grammar purely so it can be rejected by name —
`compat_add_op = { "+" }` exists only to produce `` `+` is not an infix
operator `` with `similar_op: "|"`. So:

- `st:` is kind-shaped and is not in the table → `retiredKind`, "`st:` is no
  longer a selector — write `git:staged`".
- `g:` is one character and would therefore lex as a path. Special-case it into
  the same `retiredKind` diagnostic rather than letting it silently become a
  pattern; a query that used to filter and now matches a file named `g:…` is
  the worst possible migration.
- `status:` is kind-shaped and in the table today; keep it as an accepted
  synonym or retire it the same way, but decide explicitly.

### Modifiers

Adopt jj's `-i` suffix now (`glob-i:`, `seg-i:`), and adopt
[git's `:(word,word)` long form][pathspec] if a second modifier ever appears.
git's is the only shape in the survey where modifiers compose additively
instead of multiplying kind names, and jj's `root-prefix-glob-i:` is what the
alternative looks like at four axes.

### Unknown kinds

An unknown well-shaped prefix is an **error naming the selector**, never a
silent path — with a candidate list, as [jj][jj] (`NoSuchFunction { name,
candidates }`) and [Bazel][bazel] ("expected one of [...]") both do. The
candidate ranking is free: `sparkles:fuzzy` is already linked.

### The starting table

| Kind                    | Value                                             | Notes                                            |
| ----------------------- | ------------------------------------------------- | ------------------------------------------------ |
| `glob:`                 | a glob                                            | explicit form of a bare pattern; closure applies |
| `file:`                 | an exact root-relative path                       | **no** prefix closure                            |
| `ext:`                  | an extension, no dot                              | exists today                                     |
| `seg:`                  | one path segment                                  | exists today                                     |
| `git:`                  | `modified`/`staged`/`untracked`/`ignored`/`clean` | exists today                                     |
| `re:`                   | a bounded regex                                   | reserved, pending [`PKC16`][picker]              |
| any of the above + `-i` | —                                                 | case-insensitive matching only, never identity   |

---

## O4 — Bare-word residue

**Decision.** None, and no universe primary either. Drop the sketched `.`; do
not add `all:` or `all()`.

Three arguments converge:

- **A universe re-creates the construct the no-complement decision exists to
  forbid.** `all: ~ x` is `¬x` with extra steps: its literal prefix is `⊤`, so
  any plan containing it must start at the root. Forbidding `~x` while shipping
  `all:` forbids nothing.
- **It is already expressible where it is legitimate.** `glob:**` denotes every
  file under the fileset root — and, unlike `all:`, it has a literal prefix
  (the root itself), so it prunes exactly as well as the walk it describes. If
  a rooted universe is wanted, that is its spelling.
- **nixpkgs reached the same conclusion from the representation side.** The
  README rejects a universe value for `intersections []` because "such a value
  could then not be used with `fileFilter` unless the internal representation is
  changed considerably" — a universe is a different kind of thing from every
  other member of the type.

**The empty expression** is an error (`emptyExpression`), not the empty set and
not the universe. In the picker this matters: an **absent** region means "the
source's default corpus", while an **empty** region (`… --` with nothing after)
is a typo and must say so. `none:` is not needed either — a host generating an
expression emits no region rather than an empty set.

---

## O5 — The delimiter

**Decision.** Replace `{…}` with a `--` **separator token**. The picker prompt
is `fuzzy-text`, optionally followed by a whitespace-delimited `--`, after which
everything is a fileset expression.

```
prompt = fuzzy-text , [ ws , "--" , ws , expression ] ;
```

### Why not `{…}`

The collision is not hypothetical. `sparkles.fuzzy.glob` **already compiles
`{a,b}` brace alternation** (its own test asserts `**/*.{rs,md}` matches
`src/main.rs`), ripgrep documents the same extension and notes that it is
"currently enabled in gitignore files, even though this syntax isn't supported
by git itself", and Mercurial lists `{a,b}` among its two glob extensions. A
user who has typed `*.{rs,md}` for years should not have to reason about
`{*.{rs,md}}`. Shell brace expansion is a second, smaller hazard for text
copied between a prompt and a `--expr` invocation.

`(…)` is grouping and `[…]` is a character class, so neither is available. A
novel pair such as `%{…}` is available and ugly, and still needs an
unbalanced-delimiter diagnostic.

### Why `--`

- It is the universal "the rest of this is paths" marker — git's pathspec
  separator, and the convention `ripgrep`, `fd` and every picker that forwards
  flags already use.
- It **has no closing form**, so the entire "unbalanced delimiter" diagnostic
  class disappears. In an interactive prompt that matters more than it looks:
  every prefix of a legal prompt stays legal, which is the property
  [fzf and fff][implicit] get from having no delimiter at all.
- It cannot collide with glob syntax, because it is a whole token rather than a
  character.
- A literal `--` in the fuzzy text is written `\--` or `"--"`; the first
  whitespace-delimited bare `--` wins.

### What it costs

The region must be a **suffix**: fuzzy text cannot follow it. fff's own example
puts the constraints first (`git:modified src/**/*.rs … user controller`), so
this is a real ergonomic change — after typing `--` the caret lives in the
filter, and refining the fuzzy text means moving it. Two mitigations, both
cheap: the prompt should render the region as a visually distinct chip (it is a
mode, and modes need an affordance), and a binding should toggle the caret
between the two halves.

`--expr` and configuration values are unchanged: a bare expression, no
separator, because nothing else shares that input.

---

## O6 — Diagnostics

**Decision.** Every diagnostic is a `(code, byte span, static context)` triple
rendered by the host; the library never formats a message.

That is forced by the implementation contract: `FuzzyError` is
`{ FuzzyErrorCode code; size_t offset; string context; }` and the parser is
`@safe pure nothrow @nogc` with every span borrowed, so a message containing
the offending kind's _name_ cannot be built inside the library. The host has
the input and the span, so it renders. This is strictly better than every
surveyed subject — jj, Mercurial and Bazel all allocate their message strings —
and is worth preserving rather than trading away for convenience.

One further requirement, easy to get wrong: a glob error's offset must be
mapped back to the **original input**, not to the decoded buffer.
`decodeGlobInto` re-inserts backslashes while decoding, so an offset taken from
the decoded bytes points at the wrong column in the user's text.

### The catalogue

Codes in **bold** do not exist in `FuzzyErrorCode` today and would be added;
the rest are reused.

| Code                               | Trigger                             | Message                                                                                                                      | Span                |
| ---------------------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| **`emptyExpression`**              | region present, nothing in it       | empty fileset expression — write a pattern, or remove the `--`                                                               | the `--` token      |
| **`missingOperator`**              | two primaries juxtaposed            | two patterns with no operator between them — write `&` for both, `\|` for either                                             | start of the second |
| **`missingOperand`**               | operator with a side missing        | `&` needs a pattern on both sides                                                                                            | the operator        |
| **`unaryComplement`**              | `~` in prefix position              | `~` means difference, not "not" — it needs a pattern on its left. Name the set you mean, e.g. `src/** ~ src/**/generated/**` | the `~`             |
| **`unclosedGroup`**                | `(` never closed                    | unclosed `(` opened here                                                                                                     | the `(`             |
| **`unexpectedCloseParen`**         | `)` with no `(`                     | `)` with no matching `(`                                                                                                     | the `)`             |
| **`unknownKind`**                  | kind-shaped prefix not in the table | unknown selector `<name>:` — did you mean `<candidates>`? To match a path containing a colon, quote it                       | the kind identifier |
| **`retiredKind`**                  | `g:`, `st:`                         | `st:` is no longer a selector — write `git:staged`                                                                           | the prefix          |
| `emptyValue`                       | `git:` with no value                | `git:` needs a value — one of modified, staged, untracked, ignored, clean                                                    | after the colon     |
| `unknownValue` / `ambiguousValue`  | bad or prefix-ambiguous kind value  | `git:m` is ambiguous between modified and … / `git:z` is not a status                                                        | the value           |
| `invalidEscape`                    | `\` before an unreserved byte       | `\a` is not an escape — a backslash is only needed before a space or one of `( ) \| & ~ " ' \ < >` and `` ` ``               | the backslash       |
| `unexpectedEnd`                    | trailing `\`                        | a trailing backslash escapes nothing                                                                                         | the backslash       |
| **`unterminatedQuote`**            | `"` or `'` never closed             | unterminated quote opened here                                                                                               | the opening quote   |
| **`reservedCharacter`**            | bare `<`, `>`, `` ` ``              | `<` is reserved for future use — quote it to match a file named that                                                         | the character       |
| `malformedGlob` / `globTooComplex` | the glob compiler refuses           | passthrough, offset remapped to the original input                                                                           | inside the pattern  |
| **`staticallyEmpty`**              | the lattice proves the result empty | this expression cannot match any file: `src/**` is under `src/`, `libs/**` is under `libs/`. Did you mean `\|`?              | the `&`             |

Two of these deserve their rationale stated.

**`missingOperator` is the most important message in the list.** Every other
file-selection tool our users touch — [fzf, fff][implicit], [`find`][shell],
`fd` — treats juxtaposition as conjunction. Ours is a syntax error, so the
message must not merely say "unexpected token"; it must name the two operators
and what they do.

**`staticallyEmpty` is a diagnostic, not a failure.** [Bazel][bazel] makes the
dynamic version fatal (`allow_empty = False`, "didn't match anything, but
allow_empty is set to False"), which catches the same class of bug after the
I/O. The static version costs a lattice join and catches the disjoint case
before a single `readdir`. Whether it is an error or a warning is a host
policy; the library reports it.

---

## The grammar

```ebnf
(* ---------- entry points ---------- *)

prompt      = fuzzy-text , [ ws , "--" , ws , expression ] ;   (* picker prompt *)
program     = ws , expression , ws ;                           (* --expr, config values *)

(* ---------- expression ---------- *)

expression  = term , { ws , "|" , ws , term } ;
term        = factor , { ws , ( "&" | "~" ) , ws , factor } ;
factor      = "(" , ws , expression , ws , ")"
            | primary ;

primary     = [ kind , ":" ] , pattern ;
kind        = lower , ( lower | digit ) , { lower | digit }
            , { "-" , ( lower | digit ) , { lower | digit } } ;

(* ---------- patterns ---------- *)

pattern     = pattern-part , { pattern-part } ;
pattern-part = bare-run | escape | quoted | raw ;
bare-run    = bare-char , { bare-char } ;
escape      = "\" , reserved-char ;
quoted      = '"' , { quoted-char | escape } , '"' ;
raw         = "'" , { raw-char } , "'" ;

bare-char    = letter | digit | "_" | "-" | "." | "+" | "@" | "#" | "%"
             | "^" | "$" | "=" | "!" | "?" | "*" | "[" | "]" | "{" | "}"
             | "," | ":" | ";" | "/" | high-byte ;
reserved-char = " " | "\t" | "(" | ")" | "|" | "&" | "~"
             | '"' | "'" | "\" | "<" | ">" | "`" ;
quoted-char  = ? any byte except '"' and "\" ? ;
raw-char     = ? any byte except "'" ? ;
high-byte    = ? any byte >= 0x80 ? ;
ws           = { " " | "\t" | "\r" | "\n" } ;
```

Notes the grammar does not carry:

- `kind` is recognised **only** when the token's leading bare-run matches it and
  is immediately followed by `:`; a `:` anywhere else is an ordinary bare
  character. A `pattern` whose first part is `quoted` or `raw` never has a
  kind, which is how `"foo:bar"` names a file.
- `&` and `~` share one level and are left-associative; `|` is looser and also
  left-associative. `~` has **no prefix form** — the grammar simply lacks one,
  so `~x` fails as `missingOperand` and is reported as `unaryComplement`.
- The empty `expression` is not derivable, so an empty region is a parse error
  rather than an empty set.

---

## Worked examples

| #   | Input                                           | Means                                                                             |
| --- | ----------------------------------------------- | --------------------------------------------------------------------------------- |
| 1   | `src`                                           | every file under any directory named `src`, at any depth (float + closure)        |
| 2   | `/src`                                          | the root `src/` subtree only                                                      |
| 3   | `*.d`                                           | every `.d` file at any depth                                                      |
| 4   | `src/**/*.d`                                    | `.d` files anywhere under the root `src/`; literal prefix `src/`                  |
| 5   | `src/*.d`                                       | `.d` entries directly in root `src/`, plus the subtree of any that is a directory |
| 6   | `file:src/app.d`                                | exactly that one file; no closure                                                 |
| 7   | `libs/** & git:modified`                        | modified files under `libs/`                                                      |
| 8   | `libs/** ~ **/generated/**`                     | everything under `libs/` except generated trees                                   |
| 9   | `(libs/** \| apps/**) & *.d`                    | `.d` files in either tree                                                         |
| 10  | `a \| b & c`                                    | `a \| (b & c)` — `&` binds tighter                                                |
| 11  | `a ~ b & c`                                     | `(a ~ b) & c` — same level, left-associative                                      |
| 12  | `ext:d \| ext:di`                               | `.d` or `.di` files                                                               |
| 13  | `glob-i:**/*.TXT`                               | case-insensitive glob; identity and ordering stay byte-exact                      |
| 14  | `"report 2026.md"`                              | a quoted path with a space — **still a glob**, quotes only delimit                |
| 15  | `"src/*.d"`                                     | identical to `src/*.d`; quoting does not make the `*` literal                     |
| 16  | `literal\*.d`                                   | a file whose name contains a literal `*`                                          |
| 17  | `my\ dir/*.d`                                   | escaped space instead of quotes                                                   |
| 18  | `'a\b'`                                         | raw string — a file named `a\b`, no doubling needed                               |
| 19  | `"foo:bar"`                                     | a file named `foo:bar`; quoting suppresses kind parsing                           |
| 20  | `!important!.txt`                               | bare — `!` is not an operator here                                                |
| 21  | `main.d\~`                                      | an editor backup file; `~` escaped because it is the difference operator          |
| 22  | `*.{rs,md}`                                     | brace alternation, bare — the reason `{…}` is not the region delimiter            |
| 23  | `C:/data/**`                                    | a Windows drive letter — one character, so not kind-shaped                        |
| 24  | `controller user -- git:modified & apps/**/*.d` | a picker prompt: fuzzy text, then the region                                      |
| 25  | `src/** & libs/**`                              | **error** `staticallyEmpty` — disjoint literal prefixes                           |
| 26  | `~ src`                                         | **error** `unaryComplement`                                                       |
| 27  | `libs/** apps/**`                               | **error** `missingOperator` — juxtaposition is not conjunction                    |
| 28  | `gti:modified`                                  | **error** `unknownKind`, candidate `git:`                                         |
| 29  | `st:staged`                                     | **error** `retiredKind` — write `git:staged`                                      |
| 30  | `src\app.d`                                     | **error** `invalidEscape` at `\a` — `/` is the only separator in pattern text     |
| 31  | `--`                                            | **error** `emptyExpression` (in a prompt); absent region ≠ empty region           |

---

## The literal-path-prefix lattice

The analysis that makes the Plan possible, and the reason several decisions
above went the way they did. For each node:

```
prefix(file:"src/app.d")     = "src/app.d"
prefix("src/**/*.d")         = "src/"
prefix("*.d")                = ⊤
prefix(kind:… non-path)      = ⊤
prefix(a | b)                = longest common prefix of prefix(a), prefix(b)
prefix(a & b)                = the longer, when one extends the other;
                               otherwise the node is statically empty
prefix(a ~ b)                = prefix(a)
```

Start roots are the prefixes of the top-level union's arms, deduplicated by
containment. `⊤` in any arm means "start at the fileset root".

Two engineering notes the survey supplies:

- [git's pathspec][pathspec] has done the per-argument version of this for
  decades — "the pathspec up to the last slash represents a directory prefix.
  The scope of that pathspec is limited to that subtree" — so the lattice is
  the generalisation of a proven idea, not a speculative one.
- [Mercurial's optimiser][hg] is the other half. Once the plan exists, the
  **predicate** should be reordered by cost, as `filesetlang.optimize` does:
  commute `&` so the cheap arm runs first (`WEIGHT_CHECK_FILENAME = 0.5` against
  `WEIGHT_READ_CONTENTS = 30`), rewrite `a & (b-as-negation)` into a difference,
  and coalesce a union of plain patterns into one compiled matcher. Our
  `git:` and future `re:`/content predicates are exactly the expensive arms that
  make this pay.

---

## Sources

Every claim above is cited in the deep-dive it comes from: [jj filesets][jj],
[jj revsets][revsets], [Mercurial][hg], [Bazel][bazel], [git pathspec][pathspec],
[ordered-rule filters][ordered], [nixpkgs][nix],
[implicit-conjunction pickers][implicit], [shell tools][shell], and the
cross-subject [comparison].

<!-- References -->

[jj]: ./jj-filesets.md
[revsets]: ./jj-revsets.md
[hg]: ./mercurial-filesets.md
[bazel]: ./bazel.md
[pathspec]: ./git-pathspec.md
[ordered]: ./ordered-rule-filters.md
[nix]: ./nixpkgs-fileset.md
[implicit]: ./implicit-and-pickers.md
[shell]: ./shell-tools.md
[comparison]: ./comparison.md
[contradictions]: ./contradictions.md
[picker]: ../../specs/hue/picker.md

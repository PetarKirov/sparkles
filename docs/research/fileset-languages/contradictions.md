# Where the research contradicts the brief

The design brief that started this survey arrived with twelve decisions marked
settled and six questions marked open. Three of the settled items are
contradicted by primary sources; four more survive but for different reasons
than the ones stated. Nothing here changes an open question — those are answered
in the [recommendations].

**Last reviewed:** September 20, 2026

---

## Contradicted

### C1 — `{…}` is not available as the region delimiter

**Settled item 5** proposed `{…}` for the fileset region inside the picker
prompt, noting a collision "with glob `{a,b}` alternation **if we ever support
it**".

We already support it. `sparkles.fuzzy.glob` compiles brace alternation today,
with nesting to depth 32 and a dedicated `empty brace alternative` diagnostic,
and its own unit test asserts that `**/*.{rs,md}` matches `src/main.rs`. The
collision is live, not prospective. Independently, [ripgrep][shell] documents
the same extension as one its users rely on ("`-g 'ab{c,d}*'` is equivalent to
`-g abc -g abd`"), and [Mercurial][hg] lists `{a,b}` as one of only two glob
syntax extensions it supports.

→ [O5][rec-o5] replaces the delimiter with a `--` separator token.

### C2 — erroring on `\a` is _not_ the `.gitignore` convention

**Open question 2** proposed "backslash escapes (the `.gitignore` convention);
`\` before an unreserved character is an error, not an identity".

Those are two different rules, and `.gitignore` specifies the second one the
other way round:

> A backslash (`\`) can be used to escape any character. E.g., `\*` matches a
> literal asterisk (**and `\a` matches `a`, even though there is no need for
> escaping there**).
>
> — [`Documentation/gitignore.adoc`][ordered]

`.gitignore` also makes a trailing backslash "an invalid pattern that never
matches" — silently, with no diagnostic.

The recommendation keeps the proposed behaviour (error, not identity) because
the identity rule is a one-way door that freezes the reserved set forever. But
it is a deliberate **divergence** from `.gitignore`, not an adoption of it, and
the design should say so where it is written down.

→ [O2][rec-o2].

### C3 — the `^[a-z]{2,}:` kind shape is too narrow

**Open question 3** proposed reserving the shape `^[a-z]{2,}:`.

Two shipped kind namespaces exceed it. [Mercurial][hg] has `listfile0:` — a
digit. [jj][jj] has `cwd-prefix-glob:`, `root-file:` and `glob-i:` — hyphens,
and a modifier suffix that is the cheapest available answer to
case-insensitivity. A shape that cannot hold either will be widened within the
first two selectors added.

→ [O3][rec-o3] widens it to `lower , (lower|digit) , {lower|digit} , {"-" …}`
with the two-character minimum kept, since that is what excludes Windows drive
letters.

---

## Amended — right conclusion, different reason

### A1 — "No unary complement" is vacuous without also forbidding a universe

**Settled item 4** forbids `~x` because "a complement has no literal path
prefix, so the root-set analysis must widen to 'walk everything', destroying the
plan's pruning". That reasoning is sound and is independently confirmed by
[nixpkgs][nix], which has no complement either — reached from the
representation side, because every fileset must name a bounding `_internalBase`
and a complement has none.

But **open question 4** then sketches a universe primary (`.`, possibly
`all:`/`root:`), and a universe reopens exactly what item 4 closed: `all: ~ x`
is `¬x`, with the same `⊤` prefix and the same full walk. The ban only holds if
the universe is banned with it.

→ [O4][rec-o4] drops the universe primary and notes that `glob:**` already
denotes "everything under the fileset root" **with** a literal prefix.

### A2 — "No word operators" is right, but not for the stated reason

**Settled item 7** rejects `and`/`or`/`except` because "`--expr` needs shell
quoting anyway because globs contain `*` and spaces, so aliases buy nothing".

Shell ergonomics is not why word operators exist. [Mercurial][hg] ships both
spellings so that a **configuration file** reads well
(`set:hgignore() and not ignored()`), and [Bazel][bazel] ships both so a
**script** reads well; `find`'s `-and`/`-or`/`-not` are explicitly marked "not
POSIX compliant" and exist only for legibility. Since a settled decision
already puts named filesets in configuration files, the real argument is the
one Mercurial's own help text supplies: word operators reserve ordinary
filenames, so "identifiers … must be quoted … if they match one of the
predefined predicates".

The conclusion stands. The rationale should be the filename one.

### A3 — "One grammar, parsed identically from four inputs" needs one qualifier

**Settled item 1** requires the language to be parsed identically from the
picker prompt, `--expr`, a config value and the REPL.

With a `--` separator, the _expression_ grammar is identical in all four, but
the picker prompt has an outer production the others do not: `fuzzy-text`
followed by an optional separator. That is unavoidable in any design — the
prompt carries something that is not an expression — and it is why the brief
itself carried a region in the first place. Worth stating as `program` versus
`prompt` entry points over one shared `expression`, rather than as "identically
parsed".

### A4 — retiring `globAny` is narrower _and_ wider than expected

**Open question 1** describes `globAny`'s double match — each glob tried against
both the base name and the root-relative path — as making anchoring
inexpressible, and asks for the behaviour change to be noted.

Measured against the current implementation, the base-name arm turns out to be
**dead for every slash-carrying pattern**: `globMatch("app.d", "src/app.d")` is
false, so that arm only ever fires for slash-free globs, where the proposed
float rule reproduces it. The real behaviour change comes from somewhere the
brief does not mention — Phobos' `std.path.globMatch` has no path awareness at
all, so its `*` crosses `/`. Today `src/*.d` matches `src/deep/main.d` and
`docs*md` matches `docs/x.md`; under the bounded NFA neither does.

That is a narrowing, and it brings us into agreement with `.gitignore`,
ripgrep and minimatch — which matters specifically for
`docs/.vitepress/docs-config.json`'s `srcExclude`, since that list is evaluated
by VitePress for the site build and by us for `ci --audit-fences`, and the two
can disagree today. Every current entry begins `**/` and is unaffected.

→ [O1][rec-o1], with a CI-verified runnable example.

---

## Not a contradiction, but worth recording

The glob engine does not implement the leading-`**/` rule of `.gitignore`. git
specifies that "`**/foo` matches file or directory `foo` anywhere, the same as
pattern `foo`" — that is, a leading `**/` matches **zero** directories as well
as many. `sparkles.fuzzy.glob` requires at least one separator, so `**/x` does
not match `x`. The example in [O1][rec-o1] demonstrates this. It is a compiler
fix (emit an alternation over the zero-directory case), not a language decision,
but it has to land with the anchoring rule or the rule is wrong.

<!-- References -->

[recommendations]: ./recommendations.md
[rec-o1]: ./recommendations.md#o1-anchoring
[rec-o2]: ./recommendations.md#o2-reserved-characters-and-escaping
[rec-o3]: ./recommendations.md#o3-the-kind-namespace-shape
[rec-o4]: ./recommendations.md#o4-bare-word-residue
[rec-o5]: ./recommendations.md#o5-the-delimiter
[jj]: ./jj-filesets.md
[hg]: ./mercurial-filesets.md
[bazel]: ./bazel.md
[nix]: ./nixpkgs-fileset.md
[ordered]: ./ordered-rule-filters.md
[shell]: ./shell-tools.md

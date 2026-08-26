# Authoring brief — `docs/research/autological-artifacts/`

Read this in full before writing. It is the contract every deep-dive in this tree
obeys. The tree must be **stylistically indistinguishable** from
`docs/research/async-io/` and `docs/research/application-packaging/`; open
`docs/research/async-io/glommio.md` and imitate its density, tone, and link
discipline.

Also read `docs/guidelines/research-docs.md` (the house rules) once.

---

## 1. The topic

**Autological artifacts** — files that describe, contain, and interrogate
themselves. The catalog studies the collapse of the boundaries between _program_,
_container_, _index_, _dependency graph_, and _state_ when all of them live in one
byte stream. Seed cases: **redbean/Cosmopolitan/APE** (a file whose own bytes are
its archive) and **SELF/selfdb** (a file whose own bytes are its schema).

The source outline this tree implements is `autological-artifacts.md` at the repo
root. Read it — it names the clusters, the seed entries, the open questions, and
the five cross-cutting theses. Your deep-dive is expected to _engage_ those
theses with evidence, not restate them.

## 2. The four axes (used everywhere)

Every subject is a point in this space; say where yours sits, explicitly.

1. **Multiplicity** — how many formats does one byte stream simultaneously satisfy?
2. **Reflexivity** — can the artifact be interrogated through a general query
   surface, and can it interrogate _itself while running_?
3. **Closure** — does it carry its transitive dependencies?
4. **Mutability** — is the artifact also its own state store, transactionally?

Two structural sub-questions recur: **where does the index live?**
(header-anchored / footer-anchored / stream-scanned / out-of-band) and **who
decides what the file is?** (kernel / shell / loader / consumer sniffing).

## 3. The fixed analysis spine

**Every deep-dive uses these five `##` sections, in this order, with these exact
titles.** This is what makes the catalog comparable. Where a dimension does not
apply to your subject, keep the section and say _why it does not apply_ — an
absence is a finding, and "not applicable" with a reason is a legitimate answer.

1. `## Format identity and multiplicity` — what the bytes are; how many parses
   they admit; what makes the format prefix-tolerant, suffix-tolerant, or neither.
2. `## Index anchoring and random access` — where the index lives; what a partial
   or ranged read costs; whether the format can be consumed without reading it all.
3. `## Reflexivity and query surface` — what can be asked of the artifact, in what
   language, by whom; self-inspection at runtime.
4. `## Closure, dedup, and size model` — what travels with the artifact; sharing
   or duplication; concrete numbers wherever the sources give them.
5. `## Mutability, dispatch, and trust` — self-modification; who dispatches on the
   bytes; `mmap`/page-sharing consequences; signing, verification, threat model.

## 4. The deep-dive skeleton (structure is mandatory)

```markdown
# <Subject> (<ecosystem / kind>)

<one-sentence positioning line>

| Field           | Value                                                            |
| --------------- | ---------------------------------------------------------------- |
| Kind            | <format / tool / system / kernel facility>                       |
| Language        | …                                                                |
| License         | …                                                                |
| Repository      | [org/repo][repo]                                                 |
| Documentation   | [official docs][docs]                                            |
| First release   | …                                                                |
| Axis profile    | Multiplicity <n>/ Reflexivity <n> / Closure <n> / Mutability <n> |
| Index anchoring | header / footer / stream-scanned / out-of-band                   |
| Dispatch owner  | kernel / shell / loader / consumer                               |

> **Latest release / revision surveyed:** … **Platform:** …

---

## Overview

### What it solves

### Design philosophy

<-- at least one VERBATIM quote from the source tree or official docs, cited to a
real file path or URL -->

## How it works

<real mechanics; identifiers in backticks; short labelled fenced excerpts>

## Format identity and multiplicity

## Index anchoring and random access

## Reflexivity and query surface

## Closure, dedup, and size model

## Mutability, dispatch, and trust

## Strengths

## Weaknesses

## Key design decisions and trade-offs

| Decision | Rationale | Trade-off |
| -------- | --------- | --------- |

## Sources

- bulleted primary sources, then the reference-link block

<!-- References -->

[repo]: …
```

The **Axis profile** row scores each of the four axes **0–3** (0 = absent,
1 = incidental, 2 = designed-in, 3 = defining). Be honest and be prepared to
justify the score in the corresponding spine section. These scores are collected
into the umbrella's master catalog, so they must be defensible.

## 5. Grounding — the hard requirements

> [!IMPORTANT]
> A claim without a primary source does not go in. If you could not verify it,
> either drop it or mark it explicitly as unverified with the reason.

- **Read real sources.** Clone upstreams (see §6), read the code and the official
  docs. Do not write from general impressions.
- **At least one verbatim, cited quote** per deep-dive in `### Design philosophy`,
  and quote liberally elsewhere where the exact wording carries weight.
- **Every `github.com` / `raw.githubusercontent.com` URL in markdown MUST be
  pinned to a full 40-character commit SHA.** A branch or tag in the ref position
  fails the `check-vcs-urls` pre-commit hook and CI. Get the SHA from your clone
  (`git rev-parse HEAD`) or `gh api`.
- **The path after the SHA must exist at that commit.** Verify with
  `git cat-file -e <sha>:<path>` in the clone. This is what
  `ci --check-blob-paths` re-checks later; a wrong path passes the SHA check and
  fails only the link checker.
- Prefer canonical non-GitHub docs where they exist (`sqlite.org`,
  `man7.org`, `docs.kernel.org`, `refspecs.linuxfoundation.org`, `pkg.go.dev`,
  `nix.dev`) — they are stable and need no SHA pinning.
- **Pin flaky hosts to a verified `web.archive.org` snapshot** (confirm HTTP 200).
- Mark forward-dated or uncertain entries explicitly.

## 6. Clones

Clone every upstream you cite into `$REPOS/autological/<org>/<repo>` (shallow is
fine: `git clone --filter=blob:none` or `--depth 1`; use a full-ish clone if you
need history). That path is what `ci --check-blob-paths` indexes. Record the SHA
you read at, and cite that SHA.

Kernel sources are already cloned at `$REPOS/linux` — use it for
`binfmt_misc`, ELF loading, `fs-verity`, IMA, and Landlock citations.

## 7. House style (non-negotiable)

- **Reference-style links only**, collected under a `<!-- References -->` HTML
  comment at the very bottom. Sibling subject: `./<other>.md`; from a deepened
  `<subject>/index.md` a sibling is `../<other>.md` and the umbrella is `../`.
  Another tree: `../<tree>/<file>.md`.
- **Backtick every identifier** — filenames, flags, config keys, type names,
  commands, struct fields (`EOCD`, `--assimilate`, `application_id`,
  `binfmt_misc`, `DT_NEEDED`).
- **Link every term to its definition** — a section in the same doc, another page
  under `docs/`, or the canonical external reference.
- GitHub alerts (`> [!NOTE]`, `> [!IMPORTANT]`, `> [!WARNING]`) for scope notes
  and caveats.
- Column-aligned markdown tables; dense, declarative, source-grounded prose.
  Never hand-wavy, never marketing voice, no bullet-point-only pages.
- Absolute dates everywhere.
- Cross-link neighbours: every deep-dive should link at least three sibling
  subjects in this tree where the argument genuinely touches them.

### VitePress gotchas (the build is the gate)

- A bare `<word>` in prose parses as an HTML tag → backtick it or rephrase.
- `{{ … }}` is a Vue interpolation even inside inline code → put it in a fenced
  block or wrap in `<span v-pre>`.
- An inline code span containing `<…>` must not break across a line.
- Unknown fence languages fall back to plain text with a harmless warning; do not
  invent language aliases.

## 8. Adjacent trees to cross-link, not duplicate

- `docs/research/application-packaging/` — AppImage, Flatpak, Snap, signing,
  notarization, SBOM publication. **Link to it** rather than re-surveying it;
  this tree cares about the _artifact's internal structure_, that one cares about
  the _distribution path_.
- `docs/research/serde/`, `docs/research/sql/`, `docs/research/parsing/`,
  `docs/research/async-io/`, `docs/research/sanitizers/`.

## 9. Explicitly out of scope

Kept out so the catalog does not become "interesting file formats":

- General single-binary packaging (PyInstaller, Deno/Bun compile, GraalVM
  `native-image`) **unless** the artifact is queryable or polyglot — otherwise it
  is just static linking.
- Container image formats generally, **except** where the index structure is the
  point (eStargz, `zstd:chunked`).
- Embedded interpreters as such.

If your subject brushes against these, say where the line is and why.

## 10. Output

Write exactly the file(s) you were assigned, at the paths given. Do not touch
`index.md`, `comparison.md`, or any sibling's file. Do not commit. Do not run
`git add`/`git commit`.

Return (as your final message, which is a data payload, not prose for a human):

1. The file(s) you wrote.
2. The subject's **axis profile** scores and **index anchoring** / **dispatch
   owner** values, so the umbrella's master catalog can be assembled.
3. Every clone you made: `org/repo` → SHA read at.
4. Up to five **findings that bear on the cross-cutting theses** (§4 of the source
   outline) — evidence for or against, with a citation each.
5. Anything you could not verify.

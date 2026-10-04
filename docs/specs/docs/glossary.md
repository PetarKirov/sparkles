---
status: accepted
owner: sparkles:docs
reviewed: 2026-10-04
---

# The Glossary — Data Format and Consistency Rules

## Abstract

The Sparkles documentation defines each project term once, in a glossary that
is data rather than prose. This page specifies that data: the fields of an
entry, the rules that keep entries unique, owned and safe to show out of
context, and how a documentation page links a term with an ordinary Markdown
link. One file feeds three consumers: the site renders it as the glossary page
and as per-library term lists, the site shows a term's one-sentence summary
when a reader hovers or focuses a link to it, and the repository's checker
fails a change that breaks an entry or links to a term that does not exist.

## Introduction

Specifications across Sparkles coin words
([capability row](../../glossary.md#capability-row),
[canonical witness](../../glossary.md#canonical-witness)) and narrow ordinary
ones ([slot](../../glossary.md#slot)). A reader meets such a
word on whatever page they opened first, often with no context, and an agent
restoring context reads the same page as plain text. Each term therefore
needs exactly one definition that every page can point at, and that pointer
has to work on GitHub, in an editor and on the site alike.

Prose definitions do not stay single. A term explained in two specifications
drifts until the two explanations disagree; a link to a renamed anchor fails
silently; and a definition written for the glossary page breaks when the same
text is shown somewhere else, because its relative links resolve against a
different page. A hover card adds a stricter reader still: it shows one
sentence with no surrounding page, so that sentence cannot lean on a link.

The glossary is therefore one JSON file with a schema in `sparkles:docs`, and
everything else is derived from it. Each entry names its _owner_: either the
whole project, for shared vocabulary, or the one package whose specification
coins the term. Each entry also carries two texts for two readers: a
plain-text summary with no links, which must stand alone, and a short
Markdown definition whose links are site-absolute or external, so they
resolve on every page that shows it. Pages link a term to its entry's anchor on
the glossary page, so the link is an ordinary one everywhere, and the site
recognises such links to add a summary card without any extra markup. A
checker in the repository's `ci` tool validates the file and every link into
it on each change.

This page covers the data format, its consistency rules, what counts as a
link into the glossary, and the guarantees the site's rendering makes. It does
not cover editorial judgement — when a term deserves an entry and how to
write a good summary — which belongs to [Writing Specification
Prose](../../guidelines/spec-prose.md#link-terms-to-the-glossary). The site's
visual design, and the VitePress build that hosts the components, are out of
scope, as the [library overview](./index.md) sets out for the whole site.

§1 defines an entry and its fields, §2 who may own one, §3 how a page links a
term, §4 the rules the checker enforces, and §5 what the site renders from
the data. §6 traces each requirement to the code that satisfies it.

## 1. The entry

The glossary lives in `docs/.vitepress/glossary.json`, a JSON array of entry
objects. An entry has these fields:

| Field        | Type                      | Required | Meaning                                                          |
| ------------ | ------------------------- | -------- | ---------------------------------------------------------------- |
| `id`         | string                    | yes      | The entry's anchor on the glossary page; its stable name.        |
| `term`       | string                    | yes      | The term as written in prose.                                    |
| `aliases`    | string array              | no       | Other spellings of the term: plurals, abbreviations.             |
| `summary`    | string                    | yes      | One self-contained sentence of plain text.                       |
| `definition` | string                    | yes      | One to three sentences of inline Markdown for the glossary page. |
| `authority`  | array of `{ text, link }` | no       | Labeled links to the defining sources, most authoritative first. |
| `owner`      | string                    | yes      | `global`, or the package that owns the term (§2).                |
| `seeAlso`    | string array              | no       | Ids of related entries.                                          |

An absent optional field means the same as an empty array.

**GLS1: One source.** Every consumer of the glossary — the glossary page, the
term lists, the hover cards and the checker — **must** read the entries from
`docs/.vitepress/glossary.json` and from no copy of it.

_Rationale:_ A second copy is a second definition, which is the drift the
glossary exists to prevent.

**GLS2: Required text.** An entry's `term`, `summary` and `definition`
**must** be non-empty.

**GLS3: Slug ids.** An `id` **must** consist of lowercase ASCII letters and
digits in groups separated by single hyphens, with no leading or trailing
hyphen (`sans-io`, `utf8`). Ids **must** be unique, and an id once published
**must not** be renamed or reused for another term.

_Rationale:_ The id is the anchor every page links to. A slug is a valid
anchor in every renderer, and a stable one keeps links from other pages,
other repositories and agents' notes resolving.

**GLS4: Plain-text summary.** A `summary` **must not** contain a Markdown
link (`](`) or a URL (`://`).

_Rationale:_ The summary is the only text besides the term that a hover card
shows, and the card renders it as plain text with no page around it; a link
would appear as raw syntax and point nowhere.

**GLS5: Portable links.** Every inline link target in a `definition`, and
every `authority` link, **must** be site-absolute (begin with `/`) or
external (begin with `http://` or `https://`). Every `authority` item
**must** have non-empty `text`.

_Rationale:_ An entry renders on the glossary page and inside other pages'
term lists, so a relative link would resolve differently on each.

## 2. Ownership

An entry's `owner` says who defines the term: `global` for vocabulary shared
across libraries, or the package whose specification coins it.

**GLS6: Known owners.** An `owner` **must** be `global`, the root package
name, a sub-package name of the form `sparkles:<name>` listed in the root
`dub.sdl`, or an owner declared in the front matter of a tracked page under
`docs/specs/`. A declared owner is the `owner:` line inside the block
delimited by `---` lines at the very start of the page, trimmed, with any
trailing `# comment` dropped.

_Rationale:_ A specification is how a library is proposed, often before its
package exists; counting its front-matter owner lets the draft own its terms
from the start, while an owner nobody declared is caught as a typo.

## 3. Linking a term

A page links a term with an ordinary Markdown link to its entry's anchor on
the glossary page, written relative to the page:
`[canonical witness](../../glossary.md#canonical-witness)`. The link needs no
markup beyond that, and it resolves on GitHub, in an editor and on the site.

**GLS7: Recognised references.** A link into the glossary is any inline link
target, or reference-style link definition, that names a file called
`glossary`, `glossary.md` or `glossary.html` followed by `#<id>`, and that
resolves to `docs/glossary`. A relative target **must** be resolved against
the linking page's directory and a site-absolute one (`/glossary#id`)
against `docs/`. Links to other files named `glossary`, and lines inside
code fences opened by ` ``` ` or `~~~`, **must not** count.

_Rationale:_ Recognising plain links, rather than a custom syntax, keeps the
source readable everywhere; resolving the path keeps another page that
happens to be called `glossary` from being checked against these ids.

## 4. Consistency

`ci --check-glossary` loads the entries, collects the references of §3 from
every tracked Markdown file under `docs/`, and applies the rules of §1–§3
together with those below. It fails on any violation. The check covers the
whole tree on every run, because deleting an entry breaks pages the change
never touched.

**GLS8: One entry per term.** Two entries **must not** claim the same term or
alias, compared case-insensitively.

_Rationale:_ A term has exactly one defining entry; two entries for one word
leave a page no way to say which it means.

**GLS9: See-also targets.** Every `seeAlso` id **must** name an existing
entry other than the entry itself.

**GLS10: Links resolve.** Every reference collected from the documentation
**must** name an existing id. An entry that no reference targets is reported,
not failed.

_Rationale:_ A dangling anchor fails silently in every renderer, so only a
check catches it. An unused entry is harmless, and an entry may precede the
page that will use it.

## 5. Rendering

The site derives three views from the same entries. Each definition is
rendered as inline Markdown by the site's own Markdown renderer, so code
spans and links look as they do in a page.

**GLS11: The glossary page.** The `/glossary` page **must** list every entry,
grouped by owner with `global` first under the heading "Shared terms" and the
other owners in alphabetical order, each group sorted by term without regard
to case. Each entry **must** carry its `id` as its heading anchor and show its
aliases, rendered definition, authority links and see-also links, the last
labeled with the target entries' terms.

**GLS12: Owner lists.** `<GlossaryList owner="…" />` on any page **must**
render only that owner's entries, in the same form and order as on the
glossary page, without a group heading. Their anchors are the same ids, so a
specification's Terminology section shows the glossary's entries rather than
a copy of them.

**GLS13: Summary cards.** On the site, hovering or focusing a same-origin
link whose path is the glossary page and whose fragment names an entry
**must** show a card holding that entry's term and summary, and nothing else.
The card **must** open at once on focus and after a short delay on hover,
close when the link loses focus or the pointer leaves it and the card, on
Escape and on navigation, and **must** be exposed as a tooltip describing the
link (`aria-describedby`). A link whose fragment names no entry shows no card.

_Rationale:_ The page's Markdown stays untouched: one listener recognises
links by their target, so a new page gains cards without markup, and keyboard
readers get the same summary as pointer readers.

## 6. Traceability

| ID    | Status | Traces to                                                                                                                              |
| ----- | ------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| GLS1  | full   | `sparkles.docs.glossary.glossaryDataPath`, `sparkles.docs.glossary.loadGlossary`; `docs/.vitepress/theme/glossary.data.mts`            |
| GLS2  | full   | `sparkles.docs.glossary.GlossaryEntry`, `sparkles.docs.glossary.checkGlossary`                                                         |
| GLS3  | full   | `sparkles.docs.glossary.isGlossaryId`; uniqueness in `sparkles.docs.glossary.checkGlossary`; stability is a review rule                |
| GLS4  | full   | `sparkles.docs.glossary.checkGlossary`                                                                                                 |
| GLS5  | full   | `sparkles.docs.glossary.GlossaryLink`, `sparkles.docs.glossary.checkGlossary`                                                          |
| GLS6  | full   | `sparkles.docs.glossary.frontMatterOwner`, `sparkles.docs.glossary.globalOwner`, `dub_deps.inTreePackageNames`, `app.runCheckGlossary` |
| GLS7  | full   | `sparkles.docs.glossary.glossaryReferences`, `sparkles.docs.glossary.GlossaryReference`                                                |
| GLS8  | full   | `sparkles.docs.glossary.checkGlossary`                                                                                                 |
| GLS9  | full   | `sparkles.docs.glossary.checkGlossary`                                                                                                 |
| GLS10 | full   | `sparkles.docs.glossary.GlossaryReport`, `app.runCheckGlossary`                                                                        |
| GLS11 | full   | `docs/.vitepress/theme/components/GlossaryList.vue`, `docs/glossary.md`                                                                |
| GLS12 | full   | `docs/.vitepress/theme/components/GlossaryList.vue`                                                                                    |
| GLS13 | full   | `docs/.vitepress/theme/components/GlossaryHover.vue`, mounted by `docs/.vitepress/theme/Layout.vue`                                    |

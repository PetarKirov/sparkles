# Writing Specification Prose

A specification is read far more often than it is written, and for longer than
its authors expect. Its first readers are the people and agents who agreed on
it; its later readers are an engineer evaluating the library, a contributor
resuming work a year on, and an agent restoring context from nothing but the
file. Those later readers decide whether the contract survives. They need the
document to explain itself.

This guide governs how a specification reads. [Writing Specification
Docs](./spec-docs.md) governs what it must contain — scope, falsifiable
requirements, oracles, evidence — and is not repeated here. Where the two
seem to conflict, precision wins; but most unreadable specifications are not
precise either, only dense.

The model is the opening of a good IETF RFC: formal enough to implement from,
yet the clearest account of the problem a newcomer can find. The rules below
concentrate on the opening, which every reader sees, and then state a few
principles for the body.

## Learn From Three Openings

Each of these documents does one thing worth imitating. Read the linked
sections whole; the excerpts show only the move.

**State the purpose and the boundary together.** [RFC 9293 §1](https://www.rfc-editor.org/rfc/rfc9293#section-1)
(TCP) says what the document is for, then immediately what it leaves alone
and why:

> Some companion documents are referenced for important algorithms that are
> used by TCP (e.g., for congestion control) but have not been completely
> included in this document. This is a conscious choice, as this base
> specification can be used with multiple additional algorithms that are
> developed and incorporated separately.

**Name the goal before the mechanism.** [RFC 8446 §1](https://www.rfc-editor.org/rfc/rfc8446#section-1)
(TLS 1.3) opens with the property the protocol must provide, and the
assumption it rests on, before naming any component:

> The primary goal of TLS is to provide a secure channel between two
> communicating peers; the only requirement from the underlying transport is
> a reliable, in-order data stream.

**Compress the whole system into an abstract.** [RFC 9000](https://www.rfc-editor.org/rfc/rfc9000)
(QUIC) needs a 150-page specification and five sentences to say what it is:

> This document defines the core of the QUIC transport protocol. QUIC
> provides applications with flow-controlled streams for structured
> communication, low-latency connection establishment, and network path
> migration.

Its [§1.1](https://www.rfc-editor.org/rfc/rfc9000#section-1.1) is equally
worth studying: a reading map that groups sections by the concept they
explain, not by the order they happen to appear in.

## Shape the Opening

A specification opens with four parts, in this order: front matter, an
abstract, an introduction, and a compact statement of the contract. Short
topic pages may merge the abstract into the introduction's first paragraph;
every page that carries requirements keeps the other jobs.

### Front Matter

Facts about the document — its acceptance state, owner, and review date — are
data, not prose. Put them in YAML front matter, where tools can read them and
the prose never has to repeat them:

```yaml
---
status: accepted # draft | accepted | superseded
owner: sparkles:fuzzy
reviewed: 2026-08-17
supersededBy: # a link, only when status is superseded
---
```

`status` is the state of the _contract_: whether readers may rely on it. It is
not implementation progress. Which milestones have landed belongs to
`PLAN.md`, the [one milestone tracker](./spec-docs.md#decisions-and-change-control),
and nowhere in the specification's prose. `reviewed` changes only when the
named scope was actually reviewed.

### Abstract

The abstract answers one question: _what is this, and what is it for?_ It is
a single paragraph of at most about 120 words under a `## Abstract` heading.
It names the package and otherwise avoids code identifiers. It states what the
library does for its consumer and the one or two properties that make it
distinctive. It does not describe the document, its milestones, or its
history.

Write the abstract so it can be quoted alone — in a sidebar, a package table,
a release note, or an agent's context — and still be true and complete.

### Introduction

The introduction is written for a capable engineer who has never seen this
part of Sparkles. It has five jobs:

1. **Context.** The situation in which the problem arises, in terms of the
   world rather than the code: who needs what, under which constraints.
2. **The gap.** What makes the problem hard, or what existing approaches
   leave unsettled. A reader who cannot say why this library exists after
   two paragraphs will not care how it works.
3. **The approach.** One paragraph on the central idea — the decision that
   everything else follows from — without API names, signatures, or tables.
4. **Scope and non-goals.** What this document deliberately leaves to other
   libraries, hosts, or future work, and why. This job is mandatory; it is
   the one writers most often skip and readers most often need.
5. **A reading map.** One sentence per sibling document or major section:
   where requirements, delivery order, evidence, and decisions live.

The order above is the natural one and usually the right one. Depart from it
when the argument demands, not to save a paragraph. Three to six paragraphs
are typical; an introduction that needs more is usually carrying contract
detail that belongs below it.

### The Contract at a Glance

After the introduction, implementers and resuming agents need the dense view:
the invariants, ownership rules, and boundaries they must not break. A short
numbered list of invariants serves well here. This is where precision begins
to outrank flow — but it comes _after_ the reader knows why each invariant
matters.

## Write for Years, Not for This Week

A specification outlives the conversation that produced it. Write each
sentence so that it is still true, and still makes sense, when that
conversation is forgotten.

- **Describe the system, not the project.** "Each search advances over an
  immutable snapshot" is timeless. "After the M4 rework, searches now advance
  over snapshots" ages the day it merges, and names a milestone the reader
  has no reason to know.
- **No relative time.** Avoid _currently_, _now_, _new_, _recently_, _for
  now_, _at the moment_, _no longer_. Where a statement is genuinely
  provisional, the requirement's status or an open question says so.
- **No session narration.** How the design was reached belongs in
  `decisions.md`; what it replaced belongs in a supersession link. The
  specification states the outcome.
- **Future work is scope, not prophecy.** "Remote snapshots are out of scope;
  open question Q3 tracks them" is a boundary. "Remote snapshots will be added
  later" is a promise nobody owns.

## Define What Is Ours, Link What Is Shared

A specification should be readable without replicating an encyclopedia.
Assume the reader knows what a strong engineer outside Sparkles knows: common
computer-science vocabulary, the D language, the operating systems and
standards the library targets. Do not define `io_uring`, NFC normalization, or
`@nogc`; link the first use of a niche term to its authoritative source.

Define everything that is ours:

- terms the project coined (_capability row_, _canonical witness_);
- ordinary words used in a narrowed sense (_Regular_, _tier_, _slot_); and
- project identifiers the opening relies on to make its argument.

The test is simple: **would a strong engineer from outside D and Sparkles
misread this word, or fail to parse it?** If so, define it at first use or
link it to the one place that defines it. A term has exactly one defining
entry, just as a contract has one owner; other pages link to it rather than
restating it.

## Principles for the Body

The body carries the contract, and precision governs it. These principles
keep precision from turning into density.

1. **Lead with the claim.** Each paragraph's first sentence says what the
   paragraph establishes; evidence, detail, and qualification follow.
2. **Choose the form by the content.** Prose carries arguments, causes, and
   conditions. Lists carry parallel, independent items. Tables carry finite
   matrices and comparisons. A paragraph never lives in a table cell.
3. **Give each requirement one shape.** A bold `**ID: Title.**`, the
   obligation in one or two sentences, and an optional rationale:

   > **QCAP1: Full-queue rejection.** For an open queue of capacity `C` holding
   > `C` items, `tryPut(item)` **must** return `full`, leave the queue
   > unchanged, and leave ownership of `item` with the caller.
   >
   > _Rationale:_ Returning ownership lets a producer retry or redirect the
   > item without copying it; a queue that consumed rejected items would make
   > every caller defensive.

   A rationale is labeled, at most three sentences, and never mixed into the
   obligation. A longer argument belongs in `decisions.md`, linked from here.
   Local rationale is not decoration: it is what stops a later reader from
   "simplifying" an invariant away.

4. **Write in the present tense about the system.** "The loop submits…", not
   "the loop will submit…" or "we submit…". Use _we_ only in rationale and
   decisions, where a choice was made by someone.
5. **Define before use.** A forward reference usually means the sections are
   in the wrong order. Reorder before reaching for "see below".
6. **One aside per sentence.** A sentence carries at most one parenthetical
   or dash-delimited aside. An aside that matters deserves its own sentence;
   one that does not can go.
7. **State outcomes, not history.** As in the opening: no milestone names,
   rework stories, or "previously" in normative text.

Normative keywords are bold and lowercase: **must**, **must not**, **should**,
**should not**, **may**. In requirement text they carry the meanings of
[BCP 14](https://www.rfc-editor.org/info/bcp14) ([RFC 2119](https://www.rfc-editor.org/rfc/rfc2119),
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174)); [Writing Specification
Docs](./spec-docs.md#write-falsifiable-contracts) adds that **should** needs an
explicit exception policy. Uppercase keywords read as shouting in running
prose, and bold already marks them.

## A Worked Example

The opening of the `sparkles:fuzzy` specification at the time this guide was
written is precise, verified, and hard to enter:

```markdown
# `sparkles:fuzzy` — Specification

_**Status:** F0 implemented and verified · **Date:** 2026-08-17_

_Normative at the contract level. Delivery order and gates live in
PLAN.md; hue's host-side lifecycle is specified in picker.md. The evidence
base is the fuzzy-matching research catalog._

## 1. Purpose and invariants

`sparkles:fuzzy` is the allocation-free compute core behind interactive
candidate pickers: it analyzes query and candidate text, parses constraints,
performs typo-tolerant fuzzy admission and scoring, ranks matches, keeps
bounded history models, and advances searches in deterministic chunks.

The library depends only on `sparkles:base` and `expected`. It reads no clock,
filesystem, git repository, global cancellation flag, or event loop.

The following invariants are normative:

1. All shipped fuzzy entry points and both built-in text profiles are
   `@safe pure nothrow @nogc`. …
```

The reader meets implementation progress and navigation before the subject.
The first sentence lists six operations without saying what problem they
solve together. "Admission", "profiles", and "deterministic chunks" are used
before anything explains them, and the first invariant is a compiler
attribute list. Everything here is correct; none of it tells a newcomer why
the library exists.

The same material, reshaped:

```markdown
---
status: accepted
owner: sparkles:fuzzy
reviewed: 2026-08-17
---

# `sparkles:fuzzy` — Specification

## Abstract

`sparkles:fuzzy` ranks short typed queries against large candidate lists —
file paths, symbols, commands — fast enough to answer on every keystroke.
It forgives a few mistyped query characters, understands a small constraint
language, and reports exactly which characters justified each match so a
picker can highlight them. Every operation is pure, bounded, and works in
caller-owned storage, so a host can run a search in slices between frames
and abandon it at any slice.

## 1. Introduction

An interactive picker asks the same question on every keystroke: which of
these hundreds of thousands of candidates resemble what the user has typed
so far, and in what order? The answer must arrive within a frame. It must
not reshuffle when nothing relevant changed, and it must explain itself by
marking the characters that matched.

Scoring alone does not settle these demands. A matcher must also decide
when a near miss counts as a match, whether the highlighted characters are
the ones that earned admission, whether ties break the same way on every
run and machine, and how a search too large for one frame can pause and
resume. Popular matchers answer these differently, and a host that leaves
them implicit inherits the differences as flicker and nondeterminism.

This library separates _admission_ from _ranking_. A candidate matches when
the query, after dropping at most a small budget of its characters, appears
in order within the candidate. A mistyped character is handled the same way:
it is one of the dropped ones. The canonical choice of the characters that
remain, the _witness_, is also exactly what the picker highlights. A
Smith–Waterman alignment then orders the admitted candidates, combined with
caller-supplied signals such as recent use and distance from the current
file; it changes the order, never which candidates match or what is
highlighted. All arithmetic is integer and every ordering is total, so the
results do not depend on how a host splits the work into slices or spreads
them across threads.

The library owns no clock and performs no I/O. Clocks, cancellation, worker
threads, and the file system belong to the host; hue's picker is the
reference host and is specified separately in [picker.md](../hue/picker.md).
The library does not index files, watch directories, or persist history; it
computes history scores from data the host supplies.

Sections 2–9 define the text model, query language, admission, ranking,
history, globbing, and incremental search; §10 lists the public surface and
§11 the performance and verification contract. Delivery order lives in
[PLAN.md](./PLAN.md), and the evidence for each design choice
in the [fuzzy-matching research catalog](../../research/fuzzy-matching/index.md).
```

Each paragraph does one of the introduction's jobs: context, gap, approach,
non-goals, reading map. The milestone moved to `PLAN.md` and the date to front
matter. The project terms _admission_ and _witness_ are explained in a clause
the first time they appear; in a real rewrite they would also link to their
defining entries. The invariants list follows unchanged, now as the contract
at a glance, and every invariant in it is one the reader can already
motivate.

The rewrite above is itself the product of a [cold read](#test-the-opening-with-a-cold-read).
Its first draft said the library "tolerates typos" while defining admission
only by dropped characters, promised results "under any thread schedule" for
a library that starts no threads, and left open whether the ranking
alignment could move the highlights. The reader flagged all three; each fix
is a clause, and each would otherwise have reached a newcomer as a
contradiction.

## Test the Opening With a Cold Read

The author of an introduction cannot judge whether it explains itself, because
the author already knows the answer. A cold read borrows a reader who does not.

Run one for every new specification and for any change to an abstract or
introduction. Give a fresh agent, with no repository context, only the front
matter, abstract, and introduction, and ask it to:

1. restate the problem, the approach, the scope, and the non-goals in its
   own words;
2. list every term it could not parse or had to guess; and
3. say what it would expect the specification to require.

Compare its answers with the actual contract. Each mismatch is a defect in the
introduction, not in the reader: fix the text and read again until the
restatement matches. Summarize the mismatches and how each was resolved in
the pull request description.

A cold read checks comprehension, not correctness. It does not replace the
semantic review and acceptance gates of [Writing Specification
Docs](./spec-docs.md#acceptance-review-and-closure).

## Checklist

- [ ] Front matter carries status, owner, and review date; the prose repeats
      none of them and names no milestone.
- [ ] The abstract, quoted alone, says what the library is and what it is
      for, in about 120 words or fewer.
- [ ] The introduction covers context, gap, approach, scope and non-goals,
      and a reading map.
- [ ] No sentence depends on when it was written.
- [ ] Every project-specific term is defined at first use or linked to its one
      defining entry; shared terms are linked, not re-explained.
- [ ] Requirements have one shape, and rationale is labeled and short.
- [ ] A cold read restated the problem and scope correctly.

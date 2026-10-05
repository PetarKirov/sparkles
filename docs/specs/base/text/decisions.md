---
status: draft
owner: sparkles:base
reviewed: 2026-10-05
---

# Owned text decisions

## Abstract

These decisions shape text handling in `sparkles:base`: one owned Unicode
foundation, implemented from pinned Unicode data rather than the compiler's tables,
distinct malformed-input policies, and Unicode correctness kept separate from
terminal or font layout policy. They explain why configured storage cannot change
text boundaries, why source maps are first-class data rather than inferred byte
counts, why terminal widths come from named width profiles, and how line wrapping
chooses its plans and objectives.

## Introduction

The decisions explain the [requirements](./SPEC.md); they do not restate them
normatively.
The [plan](./PLAN.md) owns progress and [testing](./testing.md) owns observations.
A proposed API or approved scope does not establish that a symbol exists or a corpus
has passed.

Each record names the choice, its state (`proposed`, `accepted`, or `superseded`),
who decided it where an owner decision settled it, the alternatives rejected, and the
condition under which it should be revisited.

## 1. Scope authorization and acceptance state

**D-TXT-01 — Complete owned foundation.**
_State:_ accepted (owner, 2026-10-04).
_Revisit when:_ a consumer needs a Unicode capability the foundation cannot host
without a second owning implementation.

The owner approved ambitious owned UTF/Unicode, wrapping, and text-layout/publication
foundations, with specifications before implementation. The approved scope covers
complete default Unicode algorithms, unbounded grapheme semantics, transactional
codecs, provenance and maps, generic base wrapping, and the base/font/text-layout
ownership split. Approval of scope is not approval of an implementation or reviewer
signoff; independent adversarial review is recorded in [testing](./testing.md#_9-independent-contract-review),
and implementation acceptance is a separate gate. The record prevents the scope from
being narrowed to fixing `cellsOf`, a bounded Phobos window, or a wrapper around the
compiler-derived semantics.

Rejected alternative: preserving compiler-dependent production behavior as a
compatibility mode. It leaves consumers with two authorities and requires every caller
to understand the implementation's Unicode-version split. A cutover migrates callers
and removes competing helpers instead.

## 2. Release and data ownership

**D-TXT-02 — Unicode 18.0.0 with explicit algorithm revisions.**
_State:_ accepted.
_Revisit when:_ a later Unicode release is final and a consumer needs it; the upgrade
follows TXT-DATA6.

A single release and content-hashed source manifest determine all production
properties. The [versioned release index](https://www.unicode.org/versions/Unicode18.0.0/)
lists the algorithm revisions used by SPEC. The
[UCD ReadMe](https://www.unicode.org/Public/18.0.0/ucd/ReadMe.txt) and the
[top-level ReadMe](https://www.unicode.org/Public/18.0.0/ReadMe.txt) identify final
Unicode 18.0.0 data and charts, and the [release announcement](https://blog.unicode.org/2026/09/announcing-unicode-standard-version-180.html)
announces the release. [UAX #29 revision 49](https://www.unicode.org/reports/tr29/tr29-49.html)
states approved stable publication for Unicode 18.0.0, dated 2026-09-01.

The release index carries a preliminary/beta status warning that contradicts the
versioned ReadMe files and the stable annex. That metadata inconsistency does not make
the final data unavailable. Delivery inspects and hashes every consumed artifact,
checks its version header and license, and pins those bytes; source availability does
not establish reproducibility or algorithm conformance, and no hash is recorded before
the bytes are fetched.

Rejected alternatives: selecting properties opportunistically from installed Phobos,
using moving `latest` URLs, or retaining separate width and segmentation release axes.
Those make compiler upgrades semantic changes and can combine categories that no
Unicode release defined. Generated data may be split across modules for size and
compile-time locality, but share one manifest identity.

**D-TXT-03 — Refactor the tooling, remove compiler probes.**
_State:_ accepted.
_Revisit when:_ the generator's reporting conventions cannot express a manifest
property family.

The Unicode generator, analysis tables, conformance harness, and UTF benchmark and
memory infrastructure are real assets. Their entry points and reporting conventions
are reused while compiler-semantic generation is replaced by an owned byte parser and
reproducible table emitter. Compiler-probed singleton grapheme tables and width
category CTFE construction have no place after the cutover. Independent foreign
libraries remain test oracles and competitive benchmarks, never production fallbacks.

A source import audit catches forbidden dependency edges but cannot establish semantic
ownership alone: an owned decoder must still match independently expected consumption,
and a raw-property oracle must not call the generated lookup it is meant to verify.

## 3. Decoding, streaming, and memory

**D-TXT-04 — Three malformed-input meanings.**
_State:_ accepted.
_Revisit when:_ a consumer needs surrogate-preserving or opaque UTF-16 input.

Strict rejection is appropriate at protocol boundaries; maximal-subpart replacement
produces interoperable display text; one-byte opaque preservation supports lossless
search and byte provenance. They cannot be aliases. The bounded analyzer's tagged
opaque units are a useful seam, but replacement conversion must not inherit that
per-byte policy accidentally.

Opaque tokens are outside the scalar domain. Only explicit raw byte reconstruction
emits them; cross-encoding conversion rejects them. Modified UTF-8/JNI, WTF-8, and
CESU-8 must not be treated as ordinary UTF-8 by a generic decoder. Native adapters
retain responsibility for their actual wire-format distinction.

**D-TXT-05 — Whole transactions and token-atomic streams.**
_State:_ accepted.
_Revisit when:_ a measured workload shows preflight validation as the dominant cost
of whole conversion.

Whole conversion uses preflight validation and measurement so a failed operation
leaves the destination untouched. Incremental conversion cannot promise rollback of
already delivered chunks, so it commits complete tokens and reports exact progress.
Prefix operations leave incomplete suffixes borrowed and unconsumed; streams own only
the bounded encoding carry and report its consumed units. End-of-input is explicit
because absence of bytes in a chunk is not evidence that a sequence is malformed.

Rejected alternative: capacity-first validation. It hides malformed hostile input
behind a tiny destination and makes error ordering depend on storage supplied by the
caller. Aliasing is checked before decoding because preflight does not make overlapping
emission safe. Even exact in-place conversion is unsupported; disjoint scratch is
simpler to reason about than a family of overlap-dependent traversal rules.

## 4. Complete algorithms without invented Unicode limits

**D-TXT-06 — Finite-state graphemes, not finite-size graphemes.**
_State:_ accepted.
_Revisit when:_ a pinned UAX #29 revision introduces a rule that needs unbounded
lookbehind.

UAX #29 permits arbitrarily long clusters. Forward rule context can be represented
without copying the entire cluster into a 16- or 32-code-point array. The source
remains borrowed; stream boundary events carry offsets and require caller source
retention if a contiguous slice is desired. An event output buffer can fill, but that
must not become a text boundary.

Rejected alternative: treating long clusters as rare and silently truncating or
splitting them. A TUI cell's 16-byte inline representation is storage policy, not a
Unicode limit; D-TXT-12 settles how a consumer keeps such a cluster whole. A
Unicode-correct scanner alone does not repair a renderer which discards the tail.

**D-TXT-07 — Complete default algorithms, explicit resource exhaustion.**
_State:_ accepted.
_Revisit when:_ a consumer requires dictionary segmentation or collation inside base.

Word and sentence segmentation, line opportunities, all four normalization forms,
default and explicit-locale casing, and the bidirectional algorithm belong in the same
base foundation. Analysis word rules cannot remain a second incomplete owner. Bidi's
standard depth/overflow handling is algorithm semantics; caller capacity for paragraph
state is a different failure. Normalization's unbounded nonstarter segment may exhaust
workspace but must not silently insert CGJ, truncate, or report an altered normalized
result as success.

Dictionary segmentation, collation, locale discovery, and language hyphenation are
not implicit extensions of these algorithms. Wrapping may consume explicit tailoring
and hyphenation resources; its owner specifies line choice separately from UAX #14's
opportunities. Fonts own safe-break/shaping facts; Unicode opportunities alone cannot
certify a contextual shaped break.

## 5. Maps, provenance, and terminal policy

**D-TXT-08 — Exact contributors and explicit affinity.**
_State:_ accepted.
_Revisit when:_ a consumer needs visual left/right selection inside base rather than
text-layout.

Normalization composition, fold expansion, canonical reordering, and deleted marks
invalidate arithmetic byte mapping. Exact contributing spans are retained; an
enclosing range is only a coarse projection. Before/after selects logical-source
endpoints when a scalar, grapheme, wide grid cell, deletion, or transformation makes a
boundary non-unique. Visual left/right caret choices remain text-layout policy,
especially under bidi.

Caches are keyed by source identity/revision and semantic profiles. A fixed lookbehind
window cannot certify RI parity, long combining context, or paragraph bidi. Consumers
may choose full rescan rather than an unproven incremental optimization. No document
resource identity or synchronization policy is smuggled into pure base operations.

**D-TXT-09 — Named `terminalKitty` local default, not universal width.**
_State:_ accepted.
_Revisit when:_ a consumer that cannot use an engine-owned grid needs a width profile
that matches a specific engine's tables.

The kitty-oriented width algorithm of the [cell-width reference](./index.md) becomes
the `terminalKitty` width profile, revision 1, with owned Unicode properties.

Rejected alternative: a Ghostty-defined global default. An independent engine oracle
and a Ghostty-backed consumer do not authorize changing the library's owning width
policy. Real kitty and Ghostty fixtures are pinned and disagreements classified;
neither installed engine supplies runtime production values. A Ghostty-backed grid
remains authoritative for its own grid cells.

A complete Unicode grapheme may occupy zero, one, or two grid cells under either
width profile, while shaping can yield other physical advances. Grid cells never become pixels or `LayoutUnit` implicitly. Font resources
and rendering cannot repair a wrong byte hit map by painting a nicer glyph. The
observed accent and flag table failures require real selection and copy evidence, not
only width tests.

**D-TXT-11 — Clustered layout, folded output for terminals that do not cluster.**
_State:_ accepted (owner, 2026-10-05; the fold's scope, only graphemes whose
per-scalar advance differs, on 2026-10-06); requirements TXT-CELL5, TXT-CELL12,
TXT-CELL13, and TXT-MIG3 are proposed operations.
_Revisit when:_ a terminal is found whose advance depends on the cluster rather than
on whether it clusters, the case D38 names as its own revisit condition; or a
consumer needs a grapheme drawn whole on such a terminal at the cost of a layout that
differs between terminals.

Base has two named width profiles with identical advances. `terminalKitty`, the
default, emits every grapheme unchanged. `terminalUnclustered` emits a grapheme whose
per-scalar advance differs from its advance as its leading scalar padded with spaces
to that advance, so a terminal that advances scalar by scalar moves its cursor
exactly as layout assumed: a ZWJ family of three people is emitted as its first
person, and a heart with VS16 as the heart and one space. When the leading scalar
alone is wider than the advance, as for an emoji-presentation base with VS15, a
one-cell replacement scalar is emitted instead, so the cursor never overruns. The
identities differ, because the emission rule is part of a width profile's identity;
measurement agrees and only emitted bytes differ.

The consumer is the design system: [GLY6](../../design-system/glyphs.md#typography-and-sizing)
and [D38](../../design-system/decisions.md) drive a terminal that reports neither mode
2027 nor a measured clustered test cluster under `terminalUnclustered`. The toolkit's
fold is that width profile's emission rule, not a separate toolkit policy.

The replacement scalar is U+003F QUESTION MARK, declared per width profile. U+FFFD was
rejected because it is East Asian Ambiguous: a terminal set to wide ambiguous
characters advances it two grid cells, reproducing the overrun. Graphemes whose
per-scalar advance already matches, such as a letter with combining marks or a flag,
are emitted unchanged, because folding them would discard text the terminal draws
correctly.

TXT-MIG1's rule of one width authority per caller still holds. The per-scalar path
survives as a named width profile with its own identity and evidence (TXT-MIG3), not
as a compatibility helper beside `terminalKitty`.

Rejected alternatives: per-scalar layout under `terminalUnclustered`, which makes a
document's layout depend on the terminal and reflow between them; a helper that
computes the per-scalar advance outside any width profile, which recreates the
competing authority TXT-MIG1 removes; and folding every cluster on every terminal,
which discards clusters that a clustering terminal draws correctly.

**D-TXT-12 — Long clusters live in overflow storage.**
_State:_ accepted (owner, 2026-10-05).
_Revisit when:_ a consumer's overflow storage cannot be bounded for its frame model.

A grapheme longer than a TUI cell's 16 inline bytes is kept whole in owned overflow
storage (TXT-CELL8, scenario X03). Exhausting that storage fails the render
explicitly and never truncates the grapheme. This supersedes the design system's rule
that a cluster over a cell's 16 bytes folds on every target; the
[design system's GLY6](../../design-system/glyphs.md#typography-and-sizing) row cites
this record.

Rejected alternative: folding a long cluster to its leading scalar on every target.
It loses text on terminals that would draw the cluster correctly, and copying from the
grid returns bytes that differ from the source.

**D-TXT-13 — The glyph channel measures one grid cell under every width profile.**
_State:_ accepted (owner, 2026-10-05); requirement TXT-CELL7 is proposed.
_Revisit when:_ the design system's glyph channel adopts a range outside the listed
set, or a supported terminal draws a listed range two cells wide regardless of its
ambiguous-width setting.

A width profile's ambiguous-wide choice applies to text. Box drawing, block elements
and the sub-cell ladder, braille and legacy-computing rasters, geometric shapes used as
status marks, and Private Use Area icons measure one grid cell under every width
profile, and base names that set by range so that measurement and painting agree.
[Design-system GLY3](../../design-system/glyphs.md#status-marks) cites it.

Rejected alternatives: letting the ambiguous-wide choice widen these ranges, which
doubles every border and misaligns meters; and an exemption by glyph name inside the
toolkit, which leaves base measurement disagreeing with what the toolkit paints. The
set is deliberately conservative: it lists ranges the design system draws, and stops
before the East Asian Wide emoji U+25FD and U+25FE.

**D-TXT-14 — Base owns scaled grid-cell footprints.**
_State:_ accepted (owner, 2026-10-05); requirements TXT-SIZE1–5 are proposed.
_Revisit when:_ the kitty text-sizing protocol changes its footprint rules, or a
second sizing protocol needs a different footprint model.

A run's integer scale and explicit width under the
[kitty text-sizing protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/)
are part of the grid-cell model: the footprint is `s` rows high and `s * w` grid
cells wide, or `s` times the run's plain measurement when `w` is zero. The fractional
scale changes only the drawn size inside the footprint. Measurement, fitting, and
hit testing use the footprint.
[Design-system GLY5 and CAP2](../../design-system/glyphs.md#typography-and-sizing)
consume this contract through the `textSizing` capability. Whether a terminal honours
the protocol stays a capability question in the design system. Text-layout's
cell/terminal sizing consumer contract points here.

Rejected alternative: leaving footprints to the design system or the terminal adapter.
Measurement, fitting, and hit testing would then each recompute the block, and a
sized heading could fit one way and select another.

## 6. Ownership above base and remaining prerequisites

**D-TXT-10 — Base mechanisms, font resources, text-layout composition.**
_State:_ accepted.
_Revisit when:_ font delivery shows that a base mechanism needs font facts to be
correct.

Base owns encoding, Unicode algorithms, logical source maps, grid-cell text, and pure
generic wrapping. [Wrapping](./wrapping.md) alone defines physical `LayoutUnit` and
solver policy. [Font](../../font/SPEC.md) owns actual resources, matching/fallback,
shaping and rasterization. [Text layout](../../text-layout/SPEC.md) depends on
base+font and owns contextual paragraphs, visual mappings, and mathematical
composition. Full page composition, frontends, and export remain above text-layout;
this work does not claim to replace TeX's complete publication system.

No `libs/font` implementation exists to stand behind an adapter. Font M4/M7 delivery
gates contextual text-layout integration. Base codecs, data, graphemes, other Unicode
algorithms, and grid-cell text remain executable without font.

### Acceptance work and dispositions

| Item                                            | Owner and gate                                                  | Required resolution                                                                                                                                                                                          |
| ----------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| R1: independent adversarial contract review     | Base contract owner; Stage 0                                    | Recorded with repaired-trace rechecks and dispositions in testing.md §9; not implementation acceptance. Scope approval alone does not satisfy this gate.                                                     |
| R2: manifest bytes and generator identity       | Base implementation; M1b                                        | Fetch actual final inputs, record SHA-256s, generator/schema revisions, and reproducibility evidence. External release availability is established.                                                          |
| R3: width profile and interoperability fixtures | Base terminal-policy implementation; M3 and adapter integration | Verify both width profiles from owned properties; pin real kitty/Ghostty/XTerm revisions and configuration and classify divergences for compatibility evidence. Pure width profiles and maps need no engine. |
| R4: executable font prerequisites               | Font implementation owner; contextual integration above base    | Deliver actual font M4/M7 contracts; no stub, scalar-width stand-in, or mock proves shaping.                                                                                                                 |
| R5: native/UI environment evidence              | Consumer integration owners; M5/M6                              | Exercise available real surfaces and native adapters, and name unavailable configurations explicitly. Pure maps are necessary but not sufficient.                                                            |
| R6: text-sizing engine evidence                 | Base terminal-policy implementation; M3s                        | Compare TXT-SIZE footprints with a pinned kitty revision's cursor reports at scales 1–7, with and without explicit width.                                                                                    |

These are acceptance prerequisites with owners, not permission to ship partial behavior
as complete. No external information blocks the first owned codec, data, or grapheme
slice.

## 7. Wrapping decisions

These records support the [wrapping contract](./wrapping.md). Its requirements state
the outcomes; the records explain the choices and the alternatives rejected. The
independent review that walked the worked failure traces and rechecked the repairs is
recorded in [testing](./testing.md#_9-independent-contract-review); it is
specification review, not executed solver or provider acceptance.

**WRAP-D1 — Plans before strings.**
_State:_ proposed.
_Revisit when:_ an allocation-free streaming contract can preserve the same
invariants without weakening transactional batch planning; such a contract is a
separately accepted operation, not a change to this one.

A source-preserving plan is the owning representation; strings and writer output are
projections. Direct emission would be simpler for a log line but loses tab,
transform, and source identity and makes callback failures partially visible.

**WRAP-D2 — Explicit local and global objectives.**
_State:_ proposed.
_Revisit when:_ a consumer needs output parity with a specific TeX engine; parity
would be a separately named mode with its own constants, not a change to the
existing modes.

Greedy, squared raggedness, and exact Knuth–Plass are separate named modes. Treating
balanced as "Knuth–Plass" without adjustment, fitness, and consecutive-discretionary
state would conceal a different objective. The local demerit and tie rules choose
reproducibility over undocumented parity with a particular TeX engine.

**WRAP-D3 — Capability-based optimization.**
_State:_ proposed.
_Revisit when:_ a measured workload shows whole-candidate measurement dominating
solve time for a provider that cannot declare an additivity or monotonicity
capability.

Whole-candidate measurement is the safe default, and providers opt into proved
optimizations. Universal prefix sums or "stop when too wide" are rejected because
shaping, tabs, and negative kerns falsify them. Optimization evidence must cover
contextual edges and the exact declared geometry, not only ASCII additive fixtures.

**WRAP-D4 — Physical fixed point, distinct grid cells.**
_State:_ proposed.
_Revisit when:_ a consumer needs a physical range or resolution the
1/65536-point tick cannot represent; a physical-scale or range change requires joint
review by the base, font, and text-layout owners.

Shared signed-64 physical units allow device-independent paragraph and page
composition. Floating-point costs and implicit grid-cell-to-pixel conversion are
rejected because they can change line choice across hosts. Checked overflow and
explicit unit conversion make the boundary observable.

**WRAP-D5 — No silent fallback.**
_State:_ proposed.
_Revisit when:_ callers repeatedly wrap exact requests in an identical approximate
retry, which would suggest a labeled combined mode.

Exact resource exhaustion is a failure; approximation is opt-in and labeled. An
emergency break is a policy-controlled candidate, not a fallback that bypasses
no-break constraints. This costs callers an explicit quality and budget decision but
prevents a "balanced" label from hiding a different algorithm on long or hostile
input.

---
status: draft
owner: sparkles:base
reviewed: 2026-10-04
---

# Owned text decisions

## Abstract

These decisions select one owned Unicode foundation, preserve distinct malformed
input policies, and separate Unicode correctness from terminal or font layout
policy. They explain why configured storage cannot change text boundaries and why
source maps are first-class data rather than inferred byte counts. Scope approval
is recorded independently from contract review or implementation acceptance.

## Introduction

The decisions support the [requirements](./SPEC.md), not a second normative copy.
The [plan](./PLAN.md) owns progress and [testing](./testing.md) owns observations.
A proposed API or approved scope does not establish that a symbol exists or a corpus
has passed. Records below identify alternatives and unresolved acceptance work.

## 1. Scope authorization and acceptance state

**D-TXT-01 — Complete owned foundation.** On 2026-10-04 the user explicitly approved
ambitious owned UTF/Unicode, wrapping, and text-layout/publication foundations and
asked for necessary specifications before implementation. This approves Stage 0
scope: complete default Unicode algorithms, unbounded grapheme semantics, transactional
codecs, provenance/maps, generic base wrapping, and the base/font/text-layout ownership
split. It is not approval of an unperformed implementation or reviewer signoff.

Independent adversarial sessions walked the success, failure and boundary scenarios;
their repaired-trace rechecks and dispositions are recorded in [testing](./testing.md).
The published target remains draft for PR review; publication validation and
implementation acceptance are separate. This record
prevents the broad scope from being silently narrowed to fixing `cellsOf`, a bounded
Phobos window, or a new wrapper around the old semantics.

Rejected alternative: preserving compiler-dependent production behavior as a
compatibility mode. It leaves consumers with two authorities and requires every caller
to understand the implementation's Unicode-version split. Clean cutover migrates
callers and removes competing helpers instead.

## 2. Release and data ownership

**D-TXT-02 — Unicode 18.0.0 with explicit algorithm revisions.** A single release
and content-hashed source manifest determine all production properties. The
[versioned release index](https://www.unicode.org/versions/Unicode18.0.0/)
lists the algorithm revisions used by SPEC. The
[UCD ReadMe](https://www.unicode.org/Public/18.0.0/ucd/ReadMe.txt) explicitly
identifies final Unicode 18.0.0 data. The
[top-level ReadMe](https://www.unicode.org/Public/18.0.0/ReadMe.txt) identifies final
data/charts, and the [official September 16 announcement](https://blog.unicode.org/2026/09/announcing-unicode-standard-version-180.html)
announces the release. [UAX #29 revision 49](https://www.unicode.org/reports/tr29/tr29-49.html)
states approved stable publication for Unicode 18.0.0, dated 2026-09-01.

The release index read on 2026-10-04 also contains a preliminary/beta status warning.
That is an observed metadata inconsistency, not a reason to claim the final data are
unavailable: the versioned ReadMe and stable annex establish the final-artifact
prerequisite. Delivery must still inspect and hash every actually consumed artifact,
check its version header and license, and pin those bytes. Source availability does
not establish reproducibility or algorithm conformance; no hashes are fabricated here.

Rejected alternatives: selecting properties opportunistically from installed Phobos,
using moving `latest` URLs, or retaining separate width and segmentation release axes.
Those make compiler upgrades semantic changes and can combine categories that no
Unicode release defined. Generated data may be split across modules for size and
compile-time locality, but share one manifest identity.

**D-TXT-03 — Refactor existing tooling, remove compiler probes.** The Unicode generator,
analysis tables, conformance harness, and UTF benchmark/memory infrastructure are real
assets. Reuse their entry points and reporting conventions while replacing compiler-
semantic generation with an owned byte parser and reproducible table emitter. Compiler
probed singleton grapheme tables and width category CTFE construction become obsolete.
Independent foreign libraries remain test oracles/competitive benchmarks, never
production fallbacks.

A source import audit catches forbidden dependency edges but cannot establish semantic
ownership alone: an owned decoder must still match independently expected consumption,
and a raw-property oracle must not call the generated lookup it is meant to verify.

## 3. Decoding, streaming, and memory

**D-TXT-04 — Three malformed-input meanings.** Strict rejection is appropriate at
protocol boundaries; maximal-subpart replacement produces interoperable display text;
one-byte opaque preservation supports lossless search and byte provenance. They cannot
be aliases. The existing bounded analyzer's tagged opaque units are a useful seam,
but replacement conversion must not inherit that per-byte policy accidentally.

Opaque tokens are outside the scalar domain. Only explicit raw byte reconstruction
emits them; cross-encoding conversion rejects them. Modified UTF-8/JNI, WTF-8, and
CESU-8 must not be treated as ordinary UTF-8 by a generic decoder. Native adapters
retain responsibility for their actual wire-format distinction.

**D-TXT-05 — Whole transactions and token-atomic streams.** Whole conversion uses
preflight validation/measurement so a failed operation leaves destination untouched.
Incremental conversion cannot promise rollback of already delivered chunks, so commits
complete tokens and reports exact progress. Prefix operations leave incomplete suffixes
borrowed/unconsumed; streams own only the bounded encoding carry and report its consumed
units. End-of-input is explicit because absence of bytes in a chunk is not evidence
that a sequence is malformed.

Rejected alternative: capacity-first validation. It hides malformed hostile input
behind a tiny destination and makes error ordering depend on storage supplied by the
caller. Aliasing is checked before decoding because preflight does not make overlapping
emission safe. Even exact in-place conversion is unsupported; disjoint scratch is
simpler to reason about than a family of overlap-dependent traversal rules.

## 4. Complete algorithms without invented Unicode limits

**D-TXT-06 — Finite-state graphemes, not finite-size graphemes.** UAX #29 permits
arbitrarily long clusters. Forward rule context can be represented without copying
the entire cluster into a 16/32-code-point array. The source remains borrowed; stream
boundary events carry offsets and require caller source retention if a contiguous
slice is desired. An event output buffer can fill, but that must not become a new
text boundary.

Rejected alternative: treating long clusters as rare and silently truncating or
splitting them. A TUI cell's 16-byte inline representation is storage policy, not a
Unicode limit. It needs owned overflow storage or explicit complete-render failure at
its integration boundary. A Unicode-correct scanner alone does not repair a renderer
which discards the tail.

**D-TXT-07 — Complete default algorithms, explicit resource exhaustion.** Word and
sentence segmentation, line opportunities, all four normalization forms, default and
explicit-locale casing, and the bidirectional algorithm belong in the same base
foundation. Analysis word rules cannot remain a second incomplete owner. Bidi's
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

**D-TXT-08 — Exact contributors and explicit affinity.** Normalization composition,
fold expansion, canonical reordering, and deleted marks invalidate arithmetic byte
mapping. Exact contributing spans are retained; an enclosing range is only a coarse
projection. Before/after selects logical-source endpoints when a scalar, grapheme,
wide cell, deletion, or transformation makes a boundary non-unique. Visual left/right
caret choices remain text-layout policy, especially under bidi.

Caches are keyed by source identity/revision and semantic profiles. A fixed lookbehind
window cannot certify RI parity, long combining context, or paragraph bidi. Consumers
may choose full rescan rather than an unproven incremental optimization. No document
resource identity or synchronization policy is smuggled into pure base operations.

**D-TXT-09 — Named terminalKitty local default, not universal width.** Preserve the
delivered kitty-oriented width algorithm as `terminalKitty` revision 1, with owned
Unicode properties. A switch to a Ghostty-defined global default was rejected during
integration review: an independent engine oracle and a Ghostty-backed consumer do
not authorize changing the library's owning policy. Pin real kitty/Ghostty fixtures
and classify disagreements explicitly; neither installed engine supplies runtime
production values. A Ghostty-backed grid remains authoritative for its own cells.

A complete Unicode grapheme may occupy zero, one, or two cells under the named terminal
policy, while shaping can yield other physical advances. Cells never become pixels
or `LayoutUnit` implicitly. Font resources and rendering cannot repair a wrong byte
hit map by painting a nicer glyph. The observed accent/flag table failures specifically
require real selection/copy evidence, not only width tests.

## 6. Ownership above base and remaining prerequisites

**D-TXT-10 — Base mechanisms, font resources, text-layout composition.** Base owns
encoding, Unicode algorithms, logical source maps, cells, and pure generic wrapping.
[Wrapping](./wrapping.md) alone defines physical `LayoutUnit` and solver policy.
[Font](../../font/SPEC.md) owns actual resources, matching/fallback, shaping and
rasterization. [Text layout](../../text-layout/SPEC.md) depends on base+font and owns
contextual paragraphs, visual mappings, and mathematical composition. Full page
composition/frontends/export remain above text-layout; this work does not claim to
replace TeX's complete publication system.

There is no `libs/font` implementation prerequisite available to fake with an adapter.
Actual font M4/M7 delivery gates contextual text-layout integration. Base codecs/data/
graphemes, other Unicode algorithms, and cell text remain executable without font.

### Acceptance work and dispositions

| Item                                                | Owner and gate                                                  | Required resolution                                                                                                                                                                                     |
| --------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R1: independent adversarial contract review         | Base contract owner; Stage 0                                    | Completed with repaired-trace rechecks and dispositions in testing.md; not implementation acceptance. Scope approval alone did not satisfy this gate.                                                   |
| R2: manifest bytes and generator identity           | Base implementation; M1b                                        | Fetch actual final inputs, record SHA-256s, generator/schema revisions, and reproducibility evidence. External release availability is established.                                                     |
| R3: terminalKitty profile/interoperability fixtures | Base terminal-policy implementation; M3 and adapter integration | Verify the local profile from owned properties; pin real kitty/Ghostty revisions/configuration and classify divergences for compatibility evidence. Pure profile/maps do not require a terminal engine. |
| R4: executable font prerequisites                   | Font implementation owner; contextual integration above base    | Deliver actual font M4/M7 contracts; no stub, scalar-width stand-in, or mock proves shaping.                                                                                                            |
| R5: native/UI environment evidence                  | Consumer integration owners; M5/M6                              | Exercise available real surfaces and native adapters, and name unavailable configurations explicitly. Pure maps are necessary but not sufficient.                                                       |

These are acceptance prerequisites with owners, not permission to ship partial behavior
as complete. No external information blocks the first owned codec/data/grapheme slice.

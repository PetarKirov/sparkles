# Text Sizing Wire and Display Units

**Owner:** `sparkles:base`, under `sparkles.base.text`.
**State:** accepted design policy for future implementation, not shipped behavior.
The explicitly proposed and unresolved decisions below remain acceptance gates.
No implementation, executed test, terminal support, or conformance is claimed here.

This page owns safe OSC 66 emission and semantic text measurement. The
[cross-stack UI specification][ui] owns resolved layout, capability selection,
painting, interaction, and fallback; its [delivery plan][plan] owns milestones.
Those companion documents define contracts and sequencing, not implementation evidence.
The [existing text contract][text] continues to own ordinary segmentation and
width. This extension must not silently replace its Unicode policy.

## Scope and Baseline

The first base slice is a validated writer plus shared display-unit semantics for
measurement, extraction, fitting, and wrapping. It is not a terminal emulator,
capability probe, font measurer, or UI typography profile.

Current source inspection establishes the integration points, not conformance:

- `ansi.d` owns `escapeLength` and `byAnsiToken`; OSC is opaque framing today.
- `grapheme.d` supplies `byGraphemeCluster` and `visibleWidth` over that framing.
- `width.d` supplies cluster widths and scalar-width fitting utilities.
- `wrap.d` wraps clusters and preserves surrounding SGR and OSC 8 state.
- `core-cli/term_unstyle.d` copies non-escape tokens, dropping OSC payloads today.

The [pinned Kitty protocol][protocol] is the interoperability authority for
metadata, allocation, and framing. [Research concepts][concepts] explain the
distinction between allocation, advance, ink, and source identity; the
[research proposal][proposal] is background, not a second accepted contract.
Receiver recovery quirks and typographical errors in upstream prose are not
requirements. In particular, OSC begins with bytes `1b 5d`, not `1b 5b`.
The command number is pinned separately by [`TEXT_SIZE_CODE 66`][control-codes];
the protocol's safe-payload reference resolves to [escape-code-safe UTF-8][safe-utf8].

## TSW1: Metadata and Canonical Encoding

Base must represent the protocol fields independently, with integer domains:

| Field    | Wire domain  | Default | Meaning                                                  |
| -------- | ------------ | ------- | -------------------------------------------------------- |
| `s`      | `1..7`       | `1`     | Integer scale and occupied height in base cells          |
| `w`      | `0..7`       | `0`     | Width in scaled cells; zero selects natural segmentation |
| `n`, `d` | each `0..15` | `0`     | Fractional ink scale numerator and denominator           |
| `h`      | `0..2`       | `0`     | Left, right, center placement of fractional ink          |
| `v`      | `0..2`       | `0`     | Top, bottom, center placement of fractional ink          |

These are wire domains, not permission to emit every combination. The strict
writer must accept a fraction only as absent or as `0 < n < d <= 15`.
An inactive internal zero pair must serialize as absent. A partial, equal,
reversed, or out-of-domain fraction must be rejected, not clamped or repaired.
Equivalent active ratios must reduce to lowest terms for canonical output.

The canonical packet must be `ESC ] 66 ; metadata ; payload ESC \`.
Metadata must be a colon-separated list of `key=value` pairs, for example
`s=2:w=2:n=1:d=2:h=2:v=1`. Values must use unsigned decimal integers without
leading zeroes, with no whitespace and at most one occurrence per key. Key order
must be `s:w:n:d:h:v`; this is intentional local policy, not an upstream ordering
requirement or a byte-for-byte golden oracle copied from Kitty output.
Default-valued fields must be omitted. When the fraction is absent, valid `h`/`v`
values are inert and must also be omitted; out-of-domain values still fail
validation. Alignment only places active fractional ink, not ordinary paragraphs.
Empty metadata is legal: the two semicolons remain.
The encoder must never emit unknown keys, BEL termination, or nested controls.

Canonicalization gives a fixed input one canonical form using only meaningful
fields and the normalized `n/d` ratio. It does not choose a unique geometry for
an ink ratio: different `s`, `w`, and fractional profiles can express the same
ink scale with different allocations.

With explicit width, one nonempty payload occupies `s*w` columns by `s` rows and
declares horizontal advance `s*w`. With natural width, each ordinary text cell
unit has its base advance multiplied by `s`. Fractional ink scale `s*n/d` must
not shrink either allocation or advance. Neither ink bounds nor glyph fit is
guaranteed by the declared allocation.

Explicit `w` on a single grapheme is a width declaration, not multi-grapheme
packing. Base must allow both single-grapheme declarations and multi-grapheme
explicit-width payloads without an author-opt-in requirement. Client width
authority and author-controlled packing policy belong to the [main UI contract][ui],
not to wire validation.

Base must not choose a UI ratio profile or translate percentages by truncation.
Selection of enabled UI ratios and packing profiles belongs to the main
specification's M0 feasibility spike. Full wire representation is not evidence
that a UI backend can render every represented request.

## TSW2: Safe Payload Validation

Before any output, the writer must validate metadata and the complete payload.
Payloads must be well-formed UTF-8 encoding Unicode scalar values and contain at
most **4096 bytes**, excluding metadata and framing. Ill-formed input must be
rejected, not replaced using the ordinary text scanner's recovery policy.

Under the pinned [safe UTF-8 definition][safe-utf8], every scalar in
`U+0000..U+001F`, `U+007F` (DEL), or `U+0080..U+009F` must be
rejected. This includes NUL, tab, newline, CR, BEL, ESC, and encoded C1 ST.
Validation must inspect decoded scalars, not reject UTF-8 continuation bytes
whose numeric byte values happen to lie in the C1 range. Embedded SGR, OSC 8,
and already ANSI-styled strings are not safe payloads. Styles belong outside.

Oversize input must not be truncated to the byte limit. The single-packet writer
must return a structured size error; permitted higher-level chunking is governed
by TSW5. Validation must not read beyond the slice or retain caller storage.
The caller must keep borrowed input alive and unchanged throughout the call.

**Proposed empty-payload policy, not yet accepted:** after validating metadata,
an empty payload succeeds as a no-op, with no writer calls and no allocated
object, even if `w` is nonzero. Rejecting empty payloads is the alternative.
The base owner must settle this before writer acceptance and pin tests to the
decision; neither behavior may be inferred from a receiver's empty-OSC handling.

## TSW3: Writer Effects and Failure

The emission primitive must accept a generic output writer. Template attributes
must infer from that writer; a capable sink must permit `@safe pure nothrow @nogc`
use without forcing those attributes on every instantiation. Pure validation
and metadata arithmetic must be independently usable with those attributes.
The primitive must not require a GC string, font resource, or terminal handle.

Emission must be explicit: no automatic capability probe, environment lookup,
brand inference, fallback, newline, cursor movement, or cursor save/restore.
The caller positions the cursor and reserves the full occupied rectangle before
calling. Raw output is anchored at that position; its declared advance is on
the original row, not below the occupied height. Near margins, actual receiver
wrapping, scrolling, or rejection is outside the writer's guarantee.

Validation failure must occur before the first sink call, leaving the sink
unchanged. This is **validation atomicity**, not transactional output. Once
emission starts, a failing generic sink may have accepted any prefix, including
an unterminated OSC. Base cannot roll it back, assume retry safety, or promise
cleanup writes to that failing sink. Sink failures retain the sink's own failure
mechanism; callers needing all-or-nothing storage must supply a transactional
sink or stage output themselves. Success means emission completed, not display.

## TSW4: Semantic Display Units

Base must distinguish escape framing from semantic content. `escapeLength`
remains a framing operation; recognition above it must classify valid OSC 66 as
text-bearing display units rather than treating every escape as zero-width text.
Raw escape stripping may remove the entire packet. Semantic plain-text
extraction must instead return its payload, without metadata or terminators.
These operations must be named and documented as different contracts.

For supported, valid packets, explicit `w` measures the whole payload once using
the declared advance `s*w`, even for a single grapheme; it must not be replaced
by a locally inferred width. Natural width (`w=0`) measures segmented units
under the existing text contract and multiplies their base advances by `s`.
This is a local measurement model, not a guarantee that a receiver's segmentation
or widths agree. Callers needing authoritative width can supply explicit `w`
per grapheme within its wire domain, rather than relying on that agreement.

Natural width remains a low-level protocol mode for all valid payloads. Upstream
recommends client width declarations to avoid disagreement and describes ASCII
as safe for efficient `w=0` transmission; that guidance is not a blanket normative
prohibition on non-ASCII `w=0` in base. Stronger client-authority policy belongs
to the main UI contract. Surrounding ordinary text and
SGR/OSC 8 must retain their existing meanings. Unknown OSC commands remain
controls, not visible labels. A payload must not be recursively parsed as ANSI.

This is an additive horizontal measurement model, not full VT interpretation.
It does not simulate cursor motion, erasure, tabs, backspaces, margins, scrolling,
or final screen extent. Existing ordinary-control policies remain separate;
scalar width must not be advertised as the final cursor position of arbitrary VT.

Display units must preserve original byte spans for the packet and payload.
Extraction, fitting, and permitted splitting must keep payload source identity;
headers, terminators, and synthetic ellipses have no source glyph identity.
Borrowed spans must not outlive the input. Nonzero explicit width does not imply
an internal per-grapheme column map: no consumer may invent one from `w`.

Decoder handling of unknown metadata keys and duplicate keys is **unresolved**.
The base owner must choose rejection or documented tolerance before semantic
decoder acceptance, including precedence and diagnostics for tolerated fields.
Malformed numeric fields, incomplete framing, and invalid payloads must yield an
error or structured invalid unit, never an assertion on untrusted bytes. A raw
framing scan may still identify their spans. Receiver accidents such as silently
overwriting duplicate keys must not become policy by copying upstream code.
This gate does not weaken the exact, strict encoder contract in TSW1.

## TSW5: Atomic Fitting and Wrapping

A nonzero-`w` packet must be one atomic display unit regardless of payload length
or grapheme count. This includes a single-grapheme width declaration as well as
a multi-grapheme packed object; base imposes no author-opt-in requirement on
either. Fitting and truncation must keep it whole or omit it whole.
Wrapping may break before or after it, never within it. Repeating fixed `w` on
fragments repeats the allocation and changes meaning; it is not legal chunking.
Adjacent explicit packets must not be merged merely because metadata matches.

Natural-width payloads may be chunked only at safe segmentation boundaries that
preserve the original sequence of text cell units and total advance. A UTF-8
scalar boundary alone is insufficient. This preservation is under the local
TSW4 model, not proof of matching receiver geometry or segmentation. Callers
needing authoritative widths may instead declare explicit per-grapheme widths;
those packets then follow the atomic rule above. Combining sequences, joined emoji, and
zero-width attachments must remain with their owning unit. Every emitted chunk
must independently satisfy TSW1 and TSW2; source spans must survive re-framing.
If one indivisible unit exceeds 4096 bytes, return a structured error rather
than split it or pretend replacement text has equivalent geometry.

A fitting API must never return a partial packet or a partial atomic object.
The usual width bound has explicit exceptions: wrapping may return an intact
overwide unit with structured overflow, or report that it cannot fit. It must
not silently claim success within the bound. Truncation must omit a non-fitting
unit; if even the requested ellipsis cannot fit, it must emit no ellipsis.
Ordinary long-word policy cannot authorize splitting an explicit-width object.

Scalar measurement reports horizontal advance, not height-aware placement.
Legacy one-row wrapping must report unsupported geometry for `s > 1`, or hand
off to a separately specified height-aware layout operation. It must not insert
ordinary one-row breaks and claim safe multirow layout. Raw pass-through with
wrapping disabled is emission only, not a placement guarantee.
All arithmetic must be checked; overflow, unsupported geometry, and invalid
external input must be errors or structured results, not assertions or wrapping
integer arithmetic. Concrete result type names remain implementation choices.

## TSW6: Ownership and Dependencies

Package arrows mean "depends on": `core-cli -> base`, `ui -> base`. Base must
not depend on UI, Ghostty, raylib, or shaping libraries for these facilities.
Wire alignment must use base-owned protocol values, not import UI `Alignment`.
Font selection, ratio profiles, clipping rectangles, probing, and retained
multicell ownership remain consumer responsibilities under the main UI contract.

The semantic decoder, safe writer, and display-unit measurement must each have
one base-owned implementation. `core-cli`'s `unstyle` and other plain-export,
width, truncation, and wrapping consumers must reuse that semantic layer when
promising visible-text behavior, not duplicate an OSC 66 grammar. Migration of
raw stripping callers must be explicit; retaining a raw operation is permitted.

## Acceptance and Evidence

All six requirements are **unverified**. The following are future acceptance
scenarios, not tests executed for this document or claims of delivered code.

- TSW1: hand-authored byte vectors cover defaults, extrema, canonical fractions,
  `key=value` syntax, local key order, omission of inert alignment, rejected
  combinations, and `s=2:w=2;ab` advancing four, height two. Equivalent active
  `n/d` ratios normalize identically; equal ink scales with different allocation
  profiles need not produce identical bytes or geometry.
- TSW2: test every forbidden scalar, malformed UTF-8, 4095/4096/4097-byte inputs,
  valid non-ASCII continuation bytes, and the accepted empty-payload decision.
- TSW3: counting sinks prove zero calls on invalid input; fault-injected sinks
  fail at each packet boundary without claiming rollback. Compile attribute cases.
- TSW4: manually derived extraction and source-span vectors distinguish raw
  stripping from visible text and declared widths from local natural-width
  estimates; decoder acceptance waits for its tolerance decision.
- TSW5: boundary fixtures cover combining marks, ZWJ, oversize atomic payloads,
  single-grapheme declarations versus multi-grapheme packed objects, repeated
  fixed-width traps, ellipsis fit, arithmetic limits, and tall-wrap rejection.
- TSW6: inspect imports and package closure; exercise core-cli through base-owned
  semantics rather than a test-local decoder. No backend is needed for these tests.

Encoder/decoder round trips alone are insufficient; expected bytes and advances
must be derived independently from the protocol and the accepted local policies.
Upstream packet order is not the canonical-byte oracle; natural-width fixtures
prove the local model only, not agreement with an external terminal.
M0 UI-profile evidence belongs in the testing companion linked from the main plan.
Publication checks cannot close semantic gates.

[text]: ./index.md
[ui]: ../../ui/text-sizing.md
[plan]: ../../ui/text-sizing-plan.md
[concepts]: ../../../research/tui-libraries/text-sizing/concepts.md
[proposal]: ../../../research/tui-libraries/text-sizing/sparkles-proposal.md
[protocol]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/text-sizing-protocol.rst
[control-codes]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/kitty/control-codes.h#L237
[safe-utf8]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/desktop-notifications.rst#L523-L533

# Ghostty (Zig / C Embedding)

Ghostty is the important parser-only counterexample: recognizing OSC 66 does not mean its terminal stream implements text sizing or exposes its parameters through C.

| Field                      | Value                                                                            |
| -------------------------- | -------------------------------------------------------------------------------- |
| Language                   | Zig terminal core; C embedding surface                                           |
| License                    | MIT, verified in [`LICENSE`][license]                                            |
| Repository                 | [ghostty-org/ghostty][repo]                                                      |
| Documentation              | [Official documentation][docs] and [pinned parser source][parser]                |
| Category                   | OSC 66 parser with unimplemented terminal-stream action                          |
| Inspected revision         | `0c2a290d3a3e2a599be3a43435d778a5896667ee`                                       |
| Revision date              | September 14, 2026                                                               |
| Previous research revision | `4749c4e93731067049bfbf2e4572061cef2bdd17`                                       |
| Evidence                   | Source inspection and parser-test inspection; tests not executed for this survey |

**Last reviewed:** September 14, 2026

## Overview

### What it solves

Ghostty provides both a terminal application and an embeddable terminal core.
That combination matters to Sparkles: a native UI can paint a terminal screen
without owning its input parser, and a binding can expose only part of the
underlying Zig implementation. Text sizing must therefore be investigated at
three boundaries: decoding, terminal-state mutation, and exported data
([README][readme], [parser][parser], [stream][stream]).

At the inspected revision, the first boundary exists for OSC 66 and the latter
two do not provide text-sizing support. This finding is intentionally narrower
than a statement about Ghostty's other graphics or font features. It concerns
this protocol's end-to-end path at this SHA, not the project's ambitions or a
future release.

### Design philosophy

The [README][readme] describes its scope with this verbatim positioning line:

> Fast, native, feature-rich terminal emulator pushing modern features.

Its embedding architecture makes the separation between recognizing a modern
protocol and implementing it particularly visible. The source-level statement
at the C conversion boundary is also explicit:

> We don't currently support encoding this to C in any way.

That comment immediately precedes `pub const C = void` in the OSC 66
[parser's `OSC` type][parser]. It is not a claim that all Ghostty OSCs lack a
C representation. It is a specific limit of this command.

## How it works

[`osc.zig`][osc] includes `kitty_text_sizing` in its command union and dispatches
OSC number 66 to the dedicated parser. The [parser][parser] obtains the capture
buffer, appends a NUL sentinel, locates the metadata/payload separator, validates
the payload, and initializes the command with default metadata.

It then processes metadata items independently. Successfully decoded fields
update the command; malformed or unknown fields log warnings and do not abort
an otherwise valid payload. The resulting Zig value contains the text and
the six protocol parameters.

The next layer is decisive: [`stream.zig`][stream] groups
`.kitty_text_sizing` with commands that only produce the diagnostic
`unimplemented OSC callback`. There is no sizing handler call in that branch.
Thus the payload is recognized but does not become ordinary or scaled text
through the inspected terminal stream.

The following is an analytical pipeline, not an executed trace:

```text
OSC 66 bytes
  -> osc.Command.kitty_text_sizing
  -> parsed metadata + validated text slice
  -> stream's unimplemented OSC callback branch
  -> no text-sizing screen update
```

## Protocol and API

The Zig [`OSC` structure][parser] has `scale: u3 = 1`, `width: u3 = 0`,
`numerator: u4 = 0`, and `denominator: u4 = 0`. Vertical and horizontal
alignment are enums defaulting to top and left. Text is a sentinel-terminated
`[:0]const u8` slice into the captured data.

The parser requires the semicolon separating metadata from text. Empty
metadata is accepted. Invalid payload encoding, a payload above 4096 bytes,
or failure to obtain or extend capture storage invalidates the command
([parser][parser]).

Metadata is deliberately tolerant:

- Keys whose length is not one byte are warned about and skipped.
- Missing values, unknown keys, and numeric conversion errors are skipped.
- `s=0` leaves the default scale of one, as an explicit upstream test asserts.
- `w=8`, `v=3`, and `n=16` leave their default fields unchanged in another test.
- Repeated valid keys overwrite earlier values through sequential assignment.

These rules differ from a strict canonical encoder. The implementation splits
an item at `=` and consumes the first key and value; it does not check for an
additional component after the value. Nor does `update` validate the relation
between numerator and denominator. Its integer widths constrain individual
fields, not every semantic relationship in the [protocol][spec].

The public C conversion type for this command is `void`, and `cval` returns
an empty value. A C consumer cannot infer availability of a structured
text-sizing payload merely from the presence of the Zig command tag
([parser][parser]). This is a concrete API gap, not just missing documentation.

## Measurement and geometry

The fields are capable of representing the protocol's small integer dimensions,
but the parser performs no layout. It does not calculate natural widths,
reserve `s * w` columns, move the cursor, or construct continuation cells.
Those operations belong downstream of parsing, where the current
[stream branch][stream] stops.

For comparison, the [protocol][spec] assigns explicit-width text a rectangle
of `(s * w, s)` base cells. Fractional scale changes the font inside that
rectangle, not its cell allocation. Those are requested semantics, not observed
Ghostty behavior at the inspected revision.

The **4096-byte** check is a payload-validation limit. It is not a measured
width, a grapheme count, a screen allocation, or evidence of lossless storage
in a future cell representation. The [Kitty study][kitty] separately documents
its 24-code-point storage cap; that implementation limit must not be attributed
to Ghostty's parser.

The architecture suggests three independent future tests: metadata parsing,
screen geometry after stream consumption, and geometry recoverable by a C
client. Passing the first cannot substitute for either of the others. The
[shared concepts][concepts] and [validation plan][validation] use that distinction
when classifying support.

## Capability and fallback

Classify this revision as **parser present; terminal behavior absent** for
OSC 66. Do not classify it as width-only, full scaling, or a usable C sizing
API ([parser][parser], [stream][stream]). A grep result for `kitty_text_sizing`
would produce a false positive if used as a capability test.

The [protocol's cursor-displacement probe][spec] is preferable to brand-based
assumptions because it asks whether the terminal changed state. The inspected
unimplemented branch provides no OSC-66-induced displacement. That is a source
deduction, not a claim that this survey ran the probe against a Ghostty window.

Sending the sequence and hoping for unscaled text is not a safe fallback:
the stream consumes a recognized OSC without printing its payload. An
application must choose ordinary text output before sending the sequence when
support is absent or unknown. A multiplexer or embedded host can introduce
another boundary, so probing and fallback belong to the actual output session.

For Sparkles, a custom painter above an embedded VT does not by itself fix this
gap. If the VT never inserts the payload and geometry into its screen, the
painter has nothing to recover. Bypassing the parser with a separate application
layout model would be a different architecture, not libghostty-vt protocol
support ([stream][stream], [proposal][proposal]).

## Layout and clipping

There is no OSC 66 layout or clipping implementation to evaluate in the
inspected stream path. In particular, no claims about tall-object wrapping,
lower-row skip behavior, intersection erasure, or resized object retention
follow from the presence of the parsed fields ([stream][stream]).

This absence matters when planning work. Adding a handler call would only
start the feature: the terminal would still need a representation for occupied
rectangles, mutation rules for existing editing controls, and a render/export
contract that does not lose scale. The [Kitty study][kitty] supplies behavioral
reference cases; it is not evidence that Ghostty already has those semantics.

A caller's clip rectangle also cannot make an unsupported OSC safe. Clipping
occurs after content exists in a layout or display list, whereas the present
gap is earlier: the text-sizing command does not create content. This is why
the [comparison][comparison] separates parser, screen, and painting capabilities.

## Retained state and interaction

The parsed text is borrowed captured data, not a newly retained multicell
object. The parser appends the sentinel before forming the slice. Consumers
should not reinterpret that NUL termination as a lifetime guarantee beyond
the parser's ownership or as an allocation of terminal cells ([parser][parser]).

No OSC 66 object reaches the inspected stream's screen mutation path, so there
is no sizing-specific selection, hit-testing, reflow, or copy behavior to
attribute to it. Existing terminal interaction features are outside this
narrow finding. A future implementation would need to make those features
agree with its sizing representation, rather than only draw larger glyphs.

The C boundary deserves an explicit gate in such work. Even after a Zig
handler and screen representation exist, an embedding consumer still needs
enough exported information to reconstruct geometry. The present `C = void`
definition prevents using this parser value as that exported contract
([parser][parser], [proposal][proposal]).

## Safety and evidence

[`isSafeUtf8`][encoding] first constructs a validated UTF-8 view, then rejects
Unicode code points in C0, DEL, and C1 control ranges. This is a code-point
check, not a blanket rejection of UTF-8 continuation bytes between `0x80`
and `0x9f`. Ordinary multibyte text remains valid.

The [parser tests][parser] cover empty metadata, a single scale, all metadata
fields together, zero scale, out-of-range values, multilingual UTF-8, unsafe
newline content, and a payload above the maximum length. The
[encoding tests][encoding] additionally include bells, escape sequences, and
an invalid raw high-byte escape attempt.

Those are useful parser oracles, but they do not demonstrate rendering,
erasure, reflow, or C export. Empty metadata is also not synonymous with empty
payload: the former has its own named test, while the invalid-parameter test
happens to use an empty payload. Test descriptions should retain that precision.

The previous research pin was
`4749c4e93731067049bfbf2e4572061cef2bdd17`. Comparing its
[parser][old-parser] with the current one shows a capture API update from
`cap.writer.writeByte(0)` to `cap.writeByte(0)`, not a sizing implementation.
The stream comparison does not change the `kitty_text_sizing` classification.
The full current SHA is therefore recorded rather than silently retaining the
old pin or implying that a newer checkout has completed the feature.

> [!NOTE]
> The cited upstream tests were source-inspected, not executed. No Ghostty GUI,
> PTY capability probe, sanitizer run, or C embedding experiment was performed
> for this page. Source evidence establishes the missing dispatch and export
> boundaries, not a runtime conformance score.

## Strengths

- A dedicated parser keeps OSC 66 syntax isolated and directly testable.
- Payload validation distinguishes safe UTF-8 from arbitrary OSC contents.
- Compact numeric fields and enums make individual parameter bounds explicit.
- The unimplemented stream branch and `C = void` make the missing layers auditable.
- MIT licensing permits reuse subject to its notice requirements ([license][license]).

## Weaknesses

- Parsed sizing requests do not alter the terminal screen at this revision.
- The C conversion does not carry the command's text or sizing parameters.
- Tolerant metadata parsing is not a canonical producer-side validation contract.
- Parser tests cannot establish geometry or rendering interoperability.
- An application that sends OSC 66 without probing can lose the enclosed text.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                     | Trade-off                                                            |
| ----------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------- |
| Parse before implementing the stream action     | Establish a recognizable command and testable syntax boundary | Recognition can be mistaken for end-to-end support                   |
| Validate safe UTF-8 and 4096-byte payload bound | Reject unsafe or oversized command text                       | Still requires separate semantic validation of metadata              |
| Ignore invalid metadata items                   | Preserve valid fields and payload where possible              | Accepted input is broader than canonical protocol output             |
| Use small integers and alignment enums          | Express individual parameter domains                          | Does not enforce cross-field constraints such as `n < d`             |
| Leave the C conversion as `void`                | Avoid pretending an export contract exists                    | Embedders cannot consume this command's structured fields through it |
| Stop at an unimplemented callback               | Make missing behavior explicit in the stream                  | No sizing, width override, or text fallback is performed             |

## Sources

- [README][readme] and [license][license]: project scope and verified licensing.
- [OSC command union and dispatch][osc]: command recognition.
- [OSC 66 parser and tests][parser]: parameter handling, payload validation, and C conversion.
- [Safe UTF-8 helper and tests][encoding]: control-code and encoding policy.
- [Terminal stream][stream]: decisive unimplemented action boundary.
- [Previous parser revision][old-parser]: comparison with the earlier research pin.

<!-- References -->

[repo]: https://github.com/ghostty-org/ghostty
[docs]: https://ghostty.org/docs
[license]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/LICENSE
[readme]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/README.md
[osc]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/terminal/osc.zig
[parser]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/terminal/osc/parsers/kitty_text_sizing.zig
[encoding]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/terminal/osc/encoding.zig
[stream]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/terminal/stream.zig
[old-parser]: https://github.com/ghostty-org/ghostty/blob/4749c4e93731067049bfbf2e4572061cef2bdd17/src/terminal/osc/parsers/kitty_text_sizing.zig
[spec]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/text-sizing-protocol.rst
[kitty]: ./kitty.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md

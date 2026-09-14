# Text-sizing concepts

The [Kitty protocol][protocol] controls text allocation and rendering, not merely
font size. Its [receiver implementation][screen] demonstrates why those dimensions
must remain separate in a library API.

**Last reviewed:** September 14, 2026

## Wire format

```text
ESC ] 66 ; metadata ; safe-UTF-8-text BEL
ESC ] 66 ; metadata ; safe-UTF-8-text ESC \
```

`ESC ]` is OSC; `ESC \\` denotes the two-byte string terminator when written as
an escaped string. The actual second byte is one backslash. The payload is part of
the command, not ordinary text following a style setter. An unsupported receiver
can discard the entire command, including its text. [Ghostty][ghostty] is an
inspected example.

| Field    | Domain                 | Meaning                                                           |
| -------- | ---------------------- | ----------------------------------------------------------------- |
| `s`      | 1 through 7; default 1 | Integer scale and occupied height                                 |
| `w`      | 0 through 7; default 0 | Explicit width in scaled cells; zero selects natural segmentation |
| `n`, `d` | 0 through 15           | Fractional ink scaling; canonical active form uses `0 < n < d`    |
| `v`      | 0, 1, 2                | Top, bottom, center alignment                                     |
| `h`      | 0, 1, 2                | Left, right, center alignment                                     |

Canonical writers should omit inactive fractions rather than use equal numerator
and denominator. Tolerant receivers differ in how they handle invalid, duplicate,
and unknown fields; see [Kitty][kitty], [Ghostty][ghostty], and [wcwidth][wcwidth].
Their recovery behavior is not a reason to leave a public writer unchecked.

## Safe payloads

The [safe UTF-8 definition][safe] excludes Unicode C0 controls, DEL, and C1
controls: U+0000 through U+001F and U+007F through U+009F. Validate decoded scalars,
not individual high bytes of UTF-8. The protocol bounds the text payload to
**4096 bytes**, excluding metadata and framing.

Consequences:

- BEL and ESC can terminate or disrupt framing; tabs and newlines are also invalid.
- Already ANSI-styled text is not a safe payload. SGR and OSC 8 surround text runs.
- Validate before emitting the prefix, so failure cannot leave an open OSC.
- A character-count bound is not a byte bound; a zero-width sequence can be long.
- A single unrepresentable atomic object needs a declared error/fallback policy.

The [validation page][validation] includes a portable executable byte-count
example. It is not a terminal conformance test.

## Allocation, advance, and ink

For explicit width, occupied width is `s * w`, occupied height is `s`, and the
cursor advances horizontally by `s * w` on the original row. Fractional ink scale
is `s * n / d` when active, without reducing allocation.

| Metadata and payload | Allocated geometry          | Interpretation                    |
| -------------------- | --------------------------- | --------------------------------- |
| `s=2;ab`             | Two separate 2-by-2 objects | Natural-width segmentation        |
| `s=2:w=2;ab`         | One 4-by-2 object           | Whole-payload explicit allocation |
| `n=1:d=2;ab`         | Two separate 1-by-1 objects | Smaller ink, unchanged allocation |
| `n=1:d=2:w=1;ab`     | One 1-by-1 object           | Intentionally packed text         |

The [implementation][screen] and [font renderer][fonts] distinguish at least four
quantities: source text, allocated cells, actual ink bounds, and cursor position.
A scalar width function cannot express all four. Maximum horizontal extent also
differs from final cursor position after backspaces or carriage returns.

## Atomicity and segmentation

With nonzero `w`, all payload text belongs to one object. Its columns do not
automatically correspond to its first `w` graphemes. Clipping that object by
inventing such a correspondence is not generally correct; see [wcwidth][wcwidth].

With natural width, segmentation determines independent objects. Splitting at a
UTF-8 boundary alone is insufficient: a combining sequence or joined emoji can
span that boundary. Metadata/style changes and payload-size chunking must preserve
the intended segmentation. Conversely, merging equal-looking explicit-width
commands changes ownership and overwrite semantics.

Three different units must not be conflated:

| Unit                      | Responsibility                          | Example                          |
| ------------------------- | --------------------------------------- | -------------------------------- |
| Unicode extended grapheme | User-facing text segmentation           | Combining marks and joined emoji |
| Shaping cluster           | Font shaping's source-to-glyph grouping | A ligature can combine graphemes |
| Terminal text object      | Allocation and editing identity         | One explicit-width OSC payload   |

[osc66][osc66] uses shaping clusters; [mdfried][mdfried] uses scalar-based native
chunking. Neither establishes a universal grapheme-safe emission algorithm.

## Capability and fallback

Support is not a terminal-brand boolean. [Foot][foot] implements width but not
scaling; [Ghostty][ghostty] parses without execution. [OpenTUI][opentui] detects
scale without implementing scale-aware widgets. Fractional behavior and other
extensions should only be claimed to the extent actually tested.

Separate observed capability, user policy, and requested typography. Unknown or
timed-out support is not a positive result. A plain-text fallback changes geometry
and must be chosen before wrapping and measurement, as [presenterm][presenterm]
does for integer sizes.

CPR is a cursor-position report, not an authenticated reply. Probe ownership,
expected coordinates, startup reports, ordinary keys, timeouts, and cleanup matter.
Modified F3 encodings can collide with CPR syntax. [OpenTUI's history][opentui]
shows failures from treating arbitrary cursor reports as evidence.

## Retained occupancy and damage

A multicell's covered cells refer to one owner. In [Kitty][kitty], ordinary text
written into a lower row can skip past the object rather than overwrite it. Erase
operations such as ECH destroy intersecting objects and can affect cells outside
the explicitly addressed span.

For a retained compositor, changed-cell comparison alone is insufficient. Damage
must expand over intersecting old and new owners, potentially to closure. Erase old
objects before painting replacements; restore every damaged cell and emit only
anchors. Object identities must survive unchanged frames without relying on a
redraw to reconstruct occupancy.

Scrolling, resize, and selection are ownership operations too. Copying each
covered cell duplicates text; treating continuation rows as blank loses text.
Viewport boundaries can cut an object whose origin remains in scrollback.

## Clipping and layout

Disabling automatic wrapping is not clipping. A receiver can move an oversized
object backward, scroll to make vertical room, or reject it. A producer must
preflight the whole occupied rectangle against its pane.

A conservative terminal policy is to omit partially clipped objects while keeping
layout geometry. Pixel renderers can scissor ink, but that is a distinct capability.
Avoid silently substituting a differently sized layout only at paint time.

## Shaping is separate

Basic integer enlargement needs segmentation and cell geometry, not HarfBuzz.
Explicit allocation can be caller-chosen. Font-derived proportional measurement
and faithful complex-script GPU rendering additionally need shaping, bidi/script
handling, fallback fonts, and a source mapping.

[osc66][osc66] measures one selected font but sends original text for a terminal
to render with potentially different fonts. [mdfried's image path][mdfried] renders
the measured font itself, trading native text interaction for pixels. Neither
approach should force a shaping dependency into a basic protocol writer.

## Sources

- [Pinned protocol text][protocol] and [safe payload definition][safe].
- [Kitty placement][screen] and [font rendering][fonts].
- [Comparison][comparison] and [Sparkles proposal][proposal].

<!-- References -->

[protocol]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/text-sizing-protocol.rst
[safe]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/desktop-notifications.rst
[screen]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/kitty/screen.c
[fonts]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/kitty/fonts.c
[kitty]: ./kitty.md
[ghostty]: ./ghostty.md
[foot]: ./foot.md
[wcwidth]: ./wcwidth.md
[opentui]: ./opentui.md
[presenterm]: ./presenterm.md
[osc66]: ./osc66.md
[mdfried]: ./mdfried.md
[validation]: ./validation.md
[comparison]: ./comparison.md
[proposal]: ./sparkles-proposal.md

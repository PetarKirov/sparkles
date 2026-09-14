# Text-sizing evidence and validation

This ledger separates demonstrated byte-level facts from source-derived behavior
and future terminal conformance work. It accompanies the [comparison][comparison]
and the unaccepted [Sparkles proposal][proposal].

**Last reviewed:** September 14, 2026

## Evidence levels

| Evidence                         | What it establishes                                   | What it does not establish                  |
| -------------------------------- | ----------------------------------------------------- | ------------------------------------------- |
| Pinned source and verified quote | Behavior of the inspected code path                   | Successful execution on every platform      |
| Inspected upstream test          | An upstream assertion and its intended coverage       | That this survey ran or passed that suite   |
| Executed library reproduction    | The exact observed library transformation             | Actual terminal rendering                   |
| Portable Markdown example        | Byte representation or arithmetic checked in CI       | Receiver execution, shaping or screen state |
| Independent VT replay            | Cursor, occupancy and editing state after real output | Font rasterization quality                  |
| Interactive image/selection test | Behavior on a recorded terminal/font/version          | Universal compatibility                     |

The [wcwidth study][wcwidth] records executed library reproductions. Other upstream
behavioral findings are source-derived unless explicitly labeled otherwise. No
upstream terminal suite was executed for this survey. The examples below are
portable D programs discovered by the repository's Markdown example verifier.

## Portable byte evidence

This program sends no terminal control sequence to stdout. It constructs a trusted
literal and prints its bytes. The assertions demonstrate framing, a two-byte ST,
the distinction between a byte limit and a scalar count, and why a zero-width
payload can exceed the protocol limit. This is not a general encoder or validator.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "text_sizing_wire_evidence"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writef, writeln;

void main() @safe
{
    immutable wire = "\x1b]66;s=2:w=1;A\x1b\\";
    assert(wire.length == 16);
    foreach (i, b; cast(const(ubyte)[]) wire)
        writef("%s%02X", i == 0 ? "" : " ", b);
    writeln();

    immutable emoji = "\U0001F600";
    assert(emoji.length == 4);
    assert(1024 * emoji.length == 4096);
    assert(1025 * emoji.length > 4096);
    immutable combining = "\u0301";
    assert(2049 * combining.length > 4096);
    writeln("1024 four-byte scalars: 4096 bytes; 1025: 4100 bytes");
    writeln("2049 combining acute accents: 4098 bytes");
}
```

```ansi
1B 5D 36 36 3B 73 3D 32 3A 77 3D 31 3B 41 1B 5C
1024 four-byte scalars: 4096 bytes; 1025: 4100 bytes
2049 combining acute accents: 4098 bytes
```

## Portable allocation counterexample

The [mdfried study][mdfried] derives a disagreement between its H2 prewrap budget
and per-wide-scalar emission plan. This program checks that arithmetic; it does not
invoke mdfried or prove an actual terminal overflow. Changing either implementation
formula requires reviewing the pinned source and updating the study, not treating
this local arithmetic as a substitute oracle.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "text_sizing_allocation_evidence"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

void main() @safe
{
    enum columns = 20;
    enum scale = 2;
    enum numerator = 5;
    enum denominator = 6;
    enum characters = 6;
    enum naturalWidth = 2;
    enum prewrapBudget = columns / scale * denominator / numerator;
    enum explicitWidth = (naturalWidth * numerator + denominator - 1) / denominator;
    enum occupiedWidth = characters * scale * explicitWidth;
    assert(characters * naturalWidth <= prewrapBudget);
    assert(occupiedWidth > columns);
    writeln("ordinary-cell prewrap budget: ", prewrapBudget);
    writeln("emitted occupied columns: ", occupiedWidth);
}
```

```ansi
ordinary-cell prewrap budget: 12
emitted occupied columns: 24
```

## Independent receiver oracles

[Kitty's in-memory screen tests][kitty] expose real parser input, cursor position,
cell ownership and text. A future D driver should replay the actual Sparkles output
through that receiver, rather than share the producer's footprint helper with its
expected-result model. Use Kitty as an external GPL-licensed oracle, not as code to
copy into differently licensed implementation files.

[Foot][foot] is a useful second oracle for explicit width, not for multirow scale.
[Ghostty][ghostty] is currently a negative support case. A serializer/decoder
round-trip through its ignored-command path does not validate sized text.

For retained output, compare incremental old-to-new painting against a fresh full
paint at the same dimensions. Inspect occupancy, text, neighbors and cursor, not
only the serialized bytes. Transport-fragment the input at every byte boundary.

## Required regression matrix

| Area          | Cases                                                           | Independent assertion                                                 |
| ------------- | --------------------------------------------------------------- | --------------------------------------------------------------------- |
| Framing       | BEL/ST, incomplete input, adjacent commands, recovery           | Payload boundaries and subsequent ordinary text survive               |
| Safe payload  | Every C0/C1 scalar, DEL, invalid UTF-8, 4095/4096/4097 bytes    | No partial prefix on writer failure; bounded receiver recovery        |
| Metadata      | Domains, overflow, duplicates, unknown keys, inactive fractions | Canonical writer policy distinct from tolerant parsing                |
| Atomicity     | Packed text, wide grapheme, style boundary, oversized cluster   | No invented explicit-block subdivision                                |
| Measurement   | Natural/explicit width; fractions; empty content                | Allocation agrees with emitted plan; height is separate               |
| Wrapping      | Spaces inside payloads, CJK, combining/ZWJ, tiny width          | Progress, grapheme integrity, no hidden over-budget run               |
| Capability    | Width-only/full/unknown/off, startup/late/fragmented CPR, F3    | Only owned expected replies update support; unrelated input preserved |
| Layout        | Mixed sizes, bold-only span inheritance, explicit size reset    | Plain/rich equivalent content gets consistent geometry                |
| Interaction   | Every covered row, synthetic spans, clip/z-order                | Correct source offset; copied text appears once                       |
| Retained diff | Scale-only, grow/shrink/move/remove, continuation overwrite     | Old/new ownership closure and full-paint equivalence                  |
| Clipping      | Four edges, negative origins, nested panes, popup intersection  | No terminal backtracking, wrapping or unintended scrolling            |
| Editing       | ECH/EL/ED/ICH/DCH/IL/DL, margins, DECAWM                        | Receiver applies whole-object semantics                               |
| Scroll/reflow | Origin in history, narrow resize, alternate screen              | No orphan continuations; selection identity preserved                 |
| Composition   | SGR, OSC 8, image placeholders and graphics                     | No embedded control payload; no image-placeholder corruption          |
| GPU           | DPI/base font changes, atlas warm-up, decorations, fractions    | Correct bounds/alignment without global per-widget font resize        |
| Consumers     | Gallery, hue GUI/TUI/ANSI/HTML, terminal pane, ANSI fence       | Real host path works, not a demo-only painter                         |

## Performance and release evidence

Benchmark ordinary text before introducing a larger cell representation. Record
cell bytes, allocation counts, unchanged-frame cost, diff bytes, scroll/churn CPU,
damage expansion, atlas memory, and resize/font-reload costs. Disable unsafe
scroll optimizations first; re-enable only after object-aware tests and measurement.

Real terminal checks must record terminal revision, environment/multiplexer, cell
and window dimensions, font configuration and capability policy. Pixel equality
across different fonts is not the same contract as cell-allocation equality.

## Verification commands

### Catalog validation on September 14, 2026

- Both portable Markdown programs compiled, ran, and matched their expected output.
- The repository sidebar consistency and pinned-GitHub-URL checks passed.
- The catalog-scoped offline blob check resolved every checked citation; foot's
  Codeberg source paths were also verified directly against its local Git tree.
- The full docs build completed with
  `NODE_OPTIONS=--max-old-space-size=12288 npm run docs:build`. The default Node
  heap had exhausted its 4 GiB limit on the full site.
- Source-listing generation reported an unrelated `twoslash-extract` failure for
  `libs/ui/src/sparkles/ui/layout.d` (status `-11`) and skipped that generated
  listing; the Markdown site itself built successfully.
- The repository-wide blob scan reported four failures outside this catalog in
  existing Dapr/Corkami research citations, plus unavailable upstream revisions.
  Those results are not presented as a clean whole-repository citation audit.

### Reproduction

Run from the repository root; the in-tree CI helper avoids a stale installed copy:

```bash
dub run :ci -- --verify --files docs/research/tui-libraries/text-sizing/validation.md
dub run :ci -- --check-docs-sidebar
dub run :ci -- --check-vcs-urls
dub run :ci -- --check-blob-paths
npm run docs:build
```

To restrict the blob audit to this catalog, append
`--files 'docs/research/tui-libraries/text-sizing/*.md'`.

Blob verification uses locally available upstream clones. An unchecked repository
is not a verified citation. Network issue/PR states are mutable, so studies retain
the September 14, 2026 observation date and distinguish merged from proposed work.

## Sources

- [Protocol vocabulary][concepts] and [Kitty oracle entry points][kitty].
- [Executed wcwidth reproductions][wcwidth] and [mdfried source arithmetic][mdfried].
- [Research writing and runnable-example conventions][guideline].

<!-- References -->

[comparison]: ./comparison.md
[proposal]: ./sparkles-proposal.md
[concepts]: ./concepts.md
[kitty]: ./kitty.md
[foot]: ./foot.md
[ghostty]: ./ghostty.md
[wcwidth]: ./wcwidth.md
[mdfried]: ./mdfried.md
[guideline]: ../../../guidelines/research-docs.md

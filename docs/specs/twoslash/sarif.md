# SARIF and the twoslash protocol — evaluation & decision

_**Status:** decided (rejected as the node model; accepted at the edges) ·
**Date:** 2026-08-05 · **Scope:** whether
[SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html)
should replace `libs/twoslash-protocol` (`sparkles.twoslash.protocol`) as the
twoslash node model, and where SARIF does belong in `hue`. Status and ID
conventions: the [hue spec](../hue/index.md#status-scheme)._

> [!IMPORTANT]
> **Decision.** SARIF does **not** replace the twoslash node model. `protocol.d`
> stays as it is. SARIF is adopted in two bounded places instead: as an **input**
> overlay kind ([`OVL3`](../hue/overlays.md)) and as a **lossy, one-way output**
> of the `error` channel for CI. The requirement rows are `SAR1`–`SAR6` (§5).

The proposal evaluated here was: adopt the SARIF object model as the wire format
`sparkles:twoslash-d` produces and `sparkles:twoslash` consumes, motivated by the
pluggable-overlay requirement in [hue/overlays.md](../hue/overlays.md). The
motivation is sound — a growing set of overlays wants a shared vocabulary for
"annotation anchored at a source range" — but SARIF is the wrong answer to it,
and the overlay spec already contains the right one.

## 1. What SARIF is, in the normative schema

Grounded in the OASIS specification and its normative JSON schema
([`sarif-schema-2.1.0.json`](https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json),
112 KB, 50 definitions):

| Schema fact                                                                                                                                 | Consequence for twoslash                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `result` requires only `message`; `kind` ∈ `notApplicable, pass, fail, review, open, informational`; `level` ∈ `none, note, warning, error` | The vocabulary is **findings**. There is no `hover`, `completion`, `highlight`, or `tag` concept.               |
| `region` requires one of `startLine` / `charOffset` / `byteOffset`; §3.30.4 forbids mixing text and binary properties in one region         | Text positions are **characters**. `byteOffset` is the binary-artifact channel and cannot co-exist with a line. |
| `run.columnKind` enum is exactly `utf16CodeUnits` and `unicodeCodePoints`; absent means `utf16CodeUnits`                                    | **SARIF has no UTF-8 offset mode.**                                                                             |
| `"additionalProperties": false` on every object (`result`, `location`, `region`, `message`, …)                                              | No twoslash field can live anywhere but a `properties` bag.                                                     |
| `propertyBag` is `additionalProperties: true`, values are any JSON, no validation                                                           | That bag is schema-exempt by construction.                                                                      |
| A `sarifLog` is `{version, runs[]}` with `results` as a completed array                                                                     | It is a **closed document**. There is no incremental or request/response shape.                                 |

## 2. Why not as the node model

Ranked by strength. The first two are individually decisive.

### 2.1 Five of six node kinds are not findings

`hover`, `query`, `completion`, `highlight` and `tag` are editor affordances, not
detected conditions. Encoding them as `result` objects means a fabricated
`ruleId` (`twoslash/hover`), `kind: "informational"`, `level: "none"`, and all
the actual content in a property bag. `01-hover.twoslash.json` becomes six
"informational findings" on a four-line file, whose signature, ddoc and
`SignatureLayout` are invisible to every SARIF consumer. The standards tax is
paid in full and the interop it buys applies to the `error` kind alone — one
sixth of one overlay.

### 2.2 It reimports the coordinate defect that `L2` was built to remove

The coordinate contract is settled and hard-won
([dmd-lsp/index.md](../dmd-lsp/index.md) § Coordinate contract): DMD reports
1-based line / 1-based UTF-8-code-unit column → `sparkles.base.text.lineindex`
converts → nodes carry **byte** `start`/`length` → `TwoslashReturn.offsetEncoding`
declares `"utf-8"` → `ingest.utf16ToUtf8Offsets` exists _solely_ to normalize the
TypeScript legacy. `sparkles:syntax`, the notation parser and all three renderers
index `code` as UTF-8 bytes.

SARIF offers two lawful encodings, both bad:

- **Conform** — emit `charOffset`/`startColumn` in UTF-16 code units or code
  points. Every producer transcodes on write and every renderer transcodes back
  on read, per node, per frame in the GUI. The legacy path becomes the only path
  and `offsetEncoding` becomes a lie.
- **Cheat** — put byte offsets in `byteOffset` of a text artifact. §3.30.4 then
  forbids `startLine`, so `line`/`character` are lost too — and non-conformant
  SARIF forfeits the only reason to adopt SARIF.

There is no third option: SARIF cannot express "byte offsets into a UTF-8 text
artifact, plus line and column". §4 below shows this is not hypothetical.

### 2.3 `additionalProperties: false` means the model survives, untyped

Every field but `start`/`length`/`text` has to move into a `properties` bag:
`docs`, `tags`, `completions`, `completionsPrefix`, `name`, `id`, and the whole
`SignatureLayout` tree (`BreakGroup`, `BreakPoint`, `Abbrev`, `Effects`,
`EffectSpan`, `Contract` — seven structs, ~40 fields). The result is the same
data model, now string-keyed and unvalidated, wrapped in five levels of SARIF
nesting that add nothing — trading `sparkles:wired`'s compile-time-reflected
typed decode and the exhaustive `final switch (node.type)` in three renderers for
`JSONValue` lookups. Adopting a schema in order to exempt the payload from it is
a negative trade.

### 2.4 The lazy / `--serve` protocol has no SARIF idiom

A _lazy span_ is a `Node` with empty `text`/`docs`/`tags` (a convention
documented in `protocol.d` itself), and `--serve`
([`EXT7`](../dmd-lsp/feature-requirements.md)) is a line-oriented oracle —
`{"tip": <nodeIndex>}` in, `{"node","text","docs","tags","signature"}` out, 0.6 ms
— driving hue's 33 ms tick ([`LIV1`–`LIV3`](../hue/twoslash.md)). SARIF has no
incremental fill, no request/response, and no addressable node handle short of
minting a `guid` per hover. The lazy protocol would be reinvented inside a
property bag, and the SARIF envelope shipped anyway.

### 2.5 It breaks the layering rule and the validation corpus

The coupling law is that the render side never imports `dmd-lsp` and `dmd-lsp`
never imports the protocol; `protocol.d` is 245 lines whose only import is
`sparkles.wired.policy`. SARIF puts an externally governed 50-definition schema
at the center of the render side. It also severs the hermeticity story in
[SPEC.md § 6](./SPEC.md): the committed fixtures come from the reference
TypeScript `twoslash` and `compare-shiki.mjs` checks class-vocabulary fidelity
against Shiki. The reference emits `twoslash-protocol` JSON — adopting SARIF
means owning a bidirectional converter forever, or losing the independent data
source that proves the renderer correct.

### 2.6 Change velocity against a frozen format

`L14`, `L16`, `L22`, `L24`, `L26`, `L28` and `TIP5`/`TIP6`/`SIG5`/`SIG7` all
added or reshaped protocol fields. SARIF 2.1.0 is frozen (2.2 is an OASIS
draft). A model that changes every milestone does not belong in a format governed
elsewhere, whose only extension point is explicitly unvalidated.

### 2.7 The argument that does **not** hold: payload size

Verbosity was expected to be decisive. It is not. All 36 committed fixtures were
re-encoded into SARIF-shaped output (throwaway D program; both sides minified via
the same serializer, so the comparison is like-for-like):

| Encoding                  | Raw       | gzip -9   |
| ------------------------- | --------- | --------- |
| twoslash (36 / 381 nodes) | 125 979 B | 33 491 B  |
| SARIF-shaped              | 208 675 B | 43 186 B  |
| ratio                     | **1.66×** | **1.29×** |

1.66× raw and 1.29× compressed is real but survivable; against the `L24` slim
encoding (10.1 MB eager / 6.7 MB lazy) it is not a blocker. The honest residue is
**decode**, not transfer: roughly four extra objects and five to six levels of
nesting per node on the path that feeds hue's live overlay. That is an argument,
not a verdict — do not lead with size.

## 3. Testing the stated driver against the overlay registry

The proposal was motivated by [hue/overlays.md](../hue/overlays.md). Run it
against the registry it cites:

| #   | Overlay             | Native SARIF fit                                                                                   |
| --- | ------------------- | -------------------------------------------------------------------------------------------------- |
| 1   | twoslash            | No — only the `error` kind maps (§2.1)                                                             |
| 2   | source map (`SMP`)  | No — Source Map v3 is its own format; SARIF models nothing about provenance mapping                |
| 3   | coverage (`COV`)    | No — no hit-count model; one `result` per source line is absurd                                    |
| 4   | tracing (`TRC`)     | No — `TRC1` wants the test-runner metric catalog (`Unit`/`Mode`); SARIF offers `rank`, a 0–1 float |
| 5   | tree-sitter (`TSI`) | No — `OVL3` states it needs **no external artifact**; a file format for something that has no file |
| 6   | code size (`CSZ`)   | No — property bags again                                                                           |

Zero of six. And [`OVL1`](../hue/overlays.md) does not ask for a wire format at
all: it specifies an **in-memory** `OverlayModel` with four channels — inline
span, line/gutter, below-line block, hover popup — none of which SARIF has a
concept for. The requirement decomposes into two things the proposal conflates:

- **`OVL1` — one internal decoration model.** Renderer-facing D structs, no
  serialization; generalize `overlay.planTwoslash`. SARIF is irrelevant.
- **`OVL3` — heterogeneous external artifacts.** `.map`, `.lst`/lcov, trace
  JSON, nm/bloaty, `.twoslash.json`. SARIF is _one more member of this list_.

## 4. Evidence: DMD's own SARIF emitter

DMD ships `-verror-style=sarif` (`compiler/src/dmd/cli.d`, `mars.d`), implemented
by `ErrorSinkSarif` in
[`compiler/src/dmd/sarif.d`](https://github.com/dlang/dmd/blob/001828f532f4aa91ea90e8a494dd08bad69c3ac6/compiler/src/dmd/sarif.d)
— 183 lines that emit one `results[]` entry per diagnostic to stdout at
`plugSink`. It is the reference implementation of "D diagnostics as SARIF", by
the compiler authors, and it covers the `error` kind and nothing else. Audited,
it demonstrates each objection above:

| Observed                                                                                  | Defect                                                                                                                                                                                                                                                                | Confirms |
| ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `"ruleId": "DMD-%s"` where `%s` is the **severity**                                       | The whole compiler has four "rules" and they are the levels restated. `rules[]` metadata, `partialFingerprints`, `baselineState`, `suppressions` and cross-run dedup are all inert.                                                                                   | §2.1     |
| `if (gagged \|\| supplemental) return;`                                                   | Supplemental notes are **dropped**, under a comment claiming they are folded into the primary entry. SARIF has `relatedLocations` for exactly this; it is unused. `dmd_lsp.diag.Diagnostic.notes` already keeps them, so this is strictly lossy against what we have. | §2.1, §5 |
| region is `startLine` + `startColumn` only                                                | A diagnostic is a **point**, not an extent — no `endColumn`, no `charLength`. The twoslash `error` node needs `(start, length)` for the wavy underline.                                                                                                               | §2.2     |
| `columnKind` never set, while `loc.charnum` is documented as a **UTF-8 code-unit** column | Consumers must assume `utf16CodeUnits`, so the column is wrong on any line with non-ASCII before the caret. `location.d` even has a transcoding `displayColumn` — the SARIF path does not use it.                                                                     | §2.2     |
| `kind` never emitted (defaults to `fail`)                                                 | Every `pragma(msg)` becomes a _failure_ with `level: "none"`.                                                                                                                                                                                                         | §2.1     |
| document assembled whole at `plugSink`, `fputs` to stdout                                 | No streaming, one closed document per process.                                                                                                                                                                                                                        | §2.4     |

The `ruleId` row is the deep one: SARIF's value proposition _is_ the rule
dimension, and D has no stable numeric error codes (an explicit non-goal of
[hue/twoslash.md](../hue/twoslash.md); `@errors:` matches message globs). The
compiler put the severity there because there was nothing
else to put. A format whose primary key cannot be populated is not our format.

## 5. Accepted work (`SAR`)

SARIF at the edges, never in the middle.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Status      | Traces to                                                             |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------- |
| SAR1 | SARIF is an **input** overlay kind, registered under [`OVL3`](../hue/overlays.md) as `--overlay sarif=<file.sarif>`: findings from any producer (dscanner, clang-tidy, semgrep, CodeQL, a code-scanning download, `dmd -verror-style=sarif`) painted over any source file. Degradation follows `OVL6`; channels follow `OVL1`/`OVL7`.                                                                                                                                                                 | not started | proposed `overlay/sarif.d`; `hue --overlay`                           |
| SAR2 | The reader must resolve the parts of the object model it consumes rather than assuming a shape: `artifactLocation.uri` **or** `index` into `run.artifacts`, `ruleIndex` into the driver's `rules[]`, `message.id` + `arguments` template substitution, and `columnKind` (absent ⇒ `utf16CodeUnits`) transcoded to byte offsets at ingest. A region carrying only `startLine`/`startColumn` yields a point marker, not a span.                                                                         | not started | `SAR1` producer                                                       |
| SAR3 | SARIF is a **one-way, deliberately lossy output of the `error` channel only**, emitted from `sparkles:dmd-lsp`'s own `DiagnosticSink` — not by reusing DMD's `ErrorSinkSarif`, which is poorer than what we already hold. It must emit `notes` as `relatedLocations`, extents from the identifier spans `twoslash-d` already resolves, and an explicit `columnKind`. Consumers: `apps/ci` (`L12`, the `@errors:` contract) and GitHub code scanning.                                                  | not started | `twoslash-extract --sarif`; `dmd_lsp.diag`                            |
| SAR4 | The node model keeps **byte offsets** and `offsetEncoding: "utf-8"`. Any SARIF boundary converts at the seam; a UTF-16 or code-point offset must never reach `protocol.d`. This is an invariant the `SAR1`/`SAR3` code is tested against, not a convention.                                                                                                                                                                                                                                           | full        | `protocol.TwoslashReturn.offsetEncoding`; `ingest.utf16ToUtf8Offsets` |
| SAR5 | Two SARIF **ideas** are borrowed without the format: (a) multi-location diagnostics — the node model has no `relatedLocations` analogue, so D's "declared here" / "instantiated from here" chains flatten today; (b) per-node **file identity** for `NOT6`, which currently concatenates files into one `code` with the `// @filename:` lines left as text (`07-multi-file.twoslash.json`). This is the one place SARIF's model is honestly better, and it costs one optional field, not a migration. | not started | `protocol.Node` (proposed fields)                                     |
| SAR6 | _(optional, upstream)_ Fix `dlang/dmd`'s `sarif.d` per §4: set `columnKind`, emit supplemental notes as `relatedLocations`, add `endColumn`, and stop encoding the severity in `ruleId`. Four small independent changes; the `columnKind` one is a genuine conformance bug.                                                                                                                                                                                                                           | not started | `dlang/dmd` `compiler/src/dmd/sarif.d`                                |

## 6. Non-goals

- **SARIF as the twoslash node model** — rejected here; `protocol.d` is the
  requirement of record.
- **A conformant general-purpose SARIF consumer.** `SAR1` reads the subset it
  renders (`results` → locations, regions, messages, levels) and ignores the
  rest — `codeFlows`, `graphs`, `webRequest`/`webResponse`, `fixes`,
  `externalPropertyFileReferences`, taxonomies, translations.
- **SARIF for the other overlay kinds** (§3). Coverage, tracing, source map and
  code size each keep their native artifact under `OVL3`.
- **Round-tripping twoslash through SARIF.** `SAR3` is lossy by design and has
  no inverse.

## 7. Falsification test

Before this decision is revisited, the counter-proposal must answer: **name one
SARIF consumer that will read the twoslash payload and do something a human
values with `kind: "informational"` results whose content lives entirely in a
property bag.** If no such consumer exists, the standard buys nothing but its own
constraints.

→ [Render-side spec](./SPEC.md) · [hue overlays](../hue/overlays.md) ·
[hue twoslash surface](../hue/twoslash.md) ·
[`sparkles:dmd-lsp`](../dmd-lsp/index.md)

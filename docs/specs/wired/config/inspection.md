---
status: draft
owner: sparkles:ui
reviewed: 2026-10-05
---

# Configuration inspection — Property, source, value

## Abstract

`sparkles:ui` presents application configuration as a property tree with adjacent
source and value columns. A command-line switch expands an option into every
retained definition, including overridden and conflicting ones. Typed value
formatting and terminal-aware table wrapping share existing library machinery.
Property labels link to their documentation when the output supports hyperlinks,
without requiring color, a window, or an interactive loop.

## Introduction

A user debugging configuration needs the setting's location in the schema, its
active value, and the source that explains it. Looking at a file alone cannot
answer that question when project files, environment variables, or explicit
arguments take precedence. An assembled list can have several contributing
sources; a conflicting setting has no effective value to print.

A flat last-writer listing omits definitions needed to explain overrides. A
settings editor is also insufficient: it can hide irrelevant or non-editable
properties, and its checkboxes and slider decorations are not configuration
values. Reporting must enumerate declared settings even when editor metadata hides
them, while redacting sensitive values without relaxing editor mutation rules or
inventing a second reflection walk.

The presentation consumes one
[resolution snapshot](../../../glossary.md#config-snapshot), which retains both
resolved options and unresolved conflicts, and uses canonical property addresses
with tree branches showing their ancestry. A typed formatter produces value cell
text; the table library handles width and wrapping. Definition rows are a report
projection, not additional configuration options. Combined values identify their
contributors; conflicts show an unresolved state rather than an effective value.
Documentation links decorate labels without changing option addresses or visible
text.

This page owns shared report behavior in `sparkles:ui`. The
[resolver specification](./SPEC.md) owns definition selection and provenance.
Applications own command parsing, source discovery, terminal capability probing,
and secret-field classification; the shared formatter enforces that classification
in every report mode. Editing, saving, graphical settings-pane redesign, and
machine-readable export formats are outside this report contract.

Sections 1–4 define the output, admission, formatting, and hyperlink contracts.
[PLAN.md](./PLAN.md) owns delivery; [testing.md](./testing.md) owns report scenarios
and evidence. Exact proposed symbol names are interface sketches, not shipped APIs.

## 1. Contract at a glance

1. Columns are property tree, active source, and active value, in that order.
2. Default and all-definitions views consume the same snapshot as startup.
3. Conflict and truncation states are visible, never successful substitute values.
4. Typed prettyprinting formats values; the shared table owns wrapping.
5. Documentation links follow output hyperlink capability, not color capability.
6. Inspection writes no configuration and starts no interactive resources.

Normative keywords follow [BCP 14](https://www.rfc-editor.org/info/bcp14).

## 2. Command and output contract

The shared writer's proposed home is `sparkles.ui.config_show`; it receives a
snapshot, report options, documentation metadata, and an output range. The apps
expose these command forms:

```console
<app> config show
<app> config show --definitions
<app> config show --definitions --option panes.viewer.tabWidth
<app> config show --changed
```

These are illustrative command shapes, not runnable examples. The exact option
path in the third line is schema-specific.

**WCI1: Three columns.** Reports **must** contain three columns headed `Property`,
`Active source`, and `Active value`, in that order. Structural section rows
**must** have empty source/value cells. An option assembled from several sources
**must** identify all contributors or a visible contributor summary with its full
list in definition mode; it **must not** claim one source supplied the whole value.

**WCI2: Definition mode.** `--definitions` **must** show every retained definition
beneath its option, including built-in, overridden, contributing, and conflicting
definitions. The source cell **must** identify its source, numerical priority,
order when ordering affects composition, and disposition; the value cell **must**
show its supplied typed value subject to explicit redaction.

Definition rows retain three columns. They **must not** be counted as option
addresses, edited, or confused with array elements. Rows use report-only identity
based on option and definition identity, not a fabricated valid property path.

**WCI3: Option selection.** `--option` **must** select an exact canonical option
address, with only the ancestor closure needed to locate it. Malformed paths,
unknown options, and structural-section addresses **must** produce a located
command diagnostic and nonzero exit status, not a successful empty report.
Expanded collection addresses that are not independently declared options
**must** identify their owning option in the diagnostic.

**WCI4: Changed filter.** `--changed` **must** include options whose selected
definitions include any non-built-in source, regardless of equality with the
compiled default, and **must** retain necessary ancestor rows. With
`--definitions`, it **must** show all definitions of those admitted options,
including overridden built-ins. An unresolved option with a non-built-in selected
definition **must** remain visible.

**WCI5: Failed resolution.** An unresolved option **must** display an explicit
conflict/error state rather than a fabricated effective value. Conflict reports
**must** remain available before startup, expose the competing definitions in
`--definitions` mode, and return a nonzero exit status even when the chosen filter
hides every conflict. Valid resolved options remain reportable.

**WCI6: Headless and read-only.** Dispatch **must** precede creation of windows,
PTYs, boards, and application event loops. Inspection **must not** write any
configuration file. Located load diagnostics **must** go to stderr; stdout
**must** contain only the report. Source discovery **must** occur once per command.

## 3. Property admission and formatting

**WCI7: Inspection admission.** The property-tree read walk **must** offer an
explicit configuration-inspection profile that includes configured properties
hidden by editor-only `@hidden` or false `@ShowIf` metadata. Ordinary editor
visibility and generated edit refusal rules **must** remain unchanged; host
redaction is distinct from editor visibility.

**WCI8: Hierarchy and order.** The report **must** expand admitted schema sections
in declaration order, arrays in effective element order, and maps in canonical
wire-key byte order. Canonical addresses **must** follow the shared
[property-tree grammar](../../ui/property-tree.md#paths-are-addresses-element-keys-are-identity),
including quoted keys; labels **must not** replace identity. Empty collections
**must** have a value readout rather than disappearing.

**WCI9: Typed formatting.** Value cells **must** use `sparkles.base.prettyprint`
through a typed formatting seam during property traversal, before type information
is erased into a badge string. String and character values **must** be quoted
and escaped; null and empty values **must** remain distinguishable. Enum values
**must** use the configuration wire spelling, not an incidental D type/member
spelling. Custom formatters **must** satisfy the same escaping and limit contract.

Prettyprint's existing source-code type hyperlinks are not option-documentation
links. The formatter requires a narrow enum-rendering policy extension; it
**must not** make `sparkles:base` depend on `sparkles:wired`. Structural sections
are not redundantly prettyprinted as whole aggregates. Actual merged keybindings
require the typed projection specified by [resolver Q2](./decisions.md#q2-keybinding-composition).

**WCI10: Table layout.** The shared `ui.components.table` text renderer **must**
solve column widths and wrap complete cell contents. The report adapter **must
not** pre-wrap cells or implement a second display-width calculator. Cells
**must** be top-aligned, with one header row and no rule between every property.
Known widths **must** be honored regardless of TTY or redirected sink, including
known zero, which cannot fit this report and returns `widthTooSmall`. Only unknown
width uses the deterministic 120-cell budget. ASCII and Unicode guide selection
follows the output's declared capabilities.

If the table cannot represent three readable columns at the supplied width, the
writer **must** return a `widthTooSmall` outcome rather than silently overflowing
or switching to a different report shape. Wrapped labels **must** preserve their
ancestor guide context without repeating the branch marker as another node.

**WCI11: Visible limits.** Property depth/node cuts and value item/depth cuts
**must** emit visible omission markers. A report that omits requested options or
definitions through resource limits **must** return an incomplete outcome and
nonzero exit status. Definition mode **must not** silently inherit prettyprint's
32-item/8-level defaults. Prettyprint's byte-count `softMaxWidth` is only an
inline/multiline heuristic; the table owns final terminal-cell width.

Source paths and source identities **must** be escaped as terminal text rather
than interpreted as styling. Configured values containing ESC, BEL, newline, or
other control bytes **must not** inject terminal control sequences through either
value cells or diagnostic text. Configured strings are not trusted style templates.

**WCI12: Redaction parity.** The host's explicit sensitive-option policy **must**
redact effective values, retained definitions, and conflict snippets alike. A
hidden-editor property **must not** automatically be classified as secret, and
redaction **must not** affect contributor selection or `--changed` admission.

## 4. Documentation hyperlinks

Documentation metadata associates each declared option with a stable absolute
HTTP(S) documentation URI. A schema-level page base and deterministic option
anchors can supply inherited locations; a field override can point elsewhere.
A shared metadata UDA or equivalent schema annotation carries this information,
without a hand-maintained path-to-URL table in every app.

**WCI13: Capability gating.** `useOscLinks` **must** be enabled when the report
output's `OutputCapabilities.hyperlinks` capability is true and disabled otherwise.
Color capability **must not** substitute for hyperlink capability. A redirected
sink **must not** inherit the terminal's hyperlink capability by accident.

**WCI14: Property documentation targets.** With hyperlinks enabled, every declared
option label **must** link to its documentation page and stable option anchor.
Collection elements and definition rows **must** inherit their owning option's
target; structural section headings **may** link to section documentation. The
label writer, not `PrettyPrintOptions.useOscLinks` alone, **must** emit these links.
Config value/type names **must not** acquire incidental source-code links.

**WCI15: Link integrity.** OSC 8 links **must** cover only the intended label,
close before padding/borders/adjacent cells, and reopen correctly on wrapped
continuations. Unsupported output **must** contain no OSC 8 sequences and **must**
have the same visible labels and values. Invalid URI schemes or embedded control
bytes **must** produce a metadata diagnostic, not an emitted control sequence.

App integration cannot satisfy this contract by linking to an absent page.
[Q4](./decisions.md#q4-option-documentation-pages) gates the documentation metadata
and page/anchor checks required before each app's report is accepted.

## 5. Proposed report interface

The interface below is **unimplemented**. It specifies the report seam, not
available D declarations. `ConfigSnapshot`, `OptionView`, `DefinitionView`, and
`SourceRef` denote the proposed resolver interfaces in
[scalar-resolution.md](./scalar-resolution.md#_3-input-and-operation-interface);
composition extends their typed payloads without changing the report's source of
truth. The writer borrows them for one synchronous call and retains no references.

```d
// Proposed, unimplemented symbols in sparkles.ui.config_show.
import sparkles.base.term_caps : OutputCapabilities; // existing type

struct ConfigReportOptions
{
    bool definitions;
    bool changed;
    string option;             // null/empty means no exact-option filter
    ConfigReportLimits limits;
}

struct ConfigReportLimits
{
    uint propertyDepth = 16;
    uint rows = 5_000;
    uint valueItems = 256;
    ushort valueDepth = 16;
    uint valueBytes = 65_536;
    uint sourceBytes = 4_096;
    uint labelBytes = 4_096;
}

struct ConfigReportOutput
{
    OutputCapabilities caps;   // existing value, supplied by host for this sink
    bool widthKnown;
    CellExtent columns;        // base-owned cell unit; ignored when !widthKnown
}

enum ReportIssue
{
    none, invalidOptions, unknownOption, metadata, valueFormatting,
    widthTooSmall, allocationFailure, writeFailure
}

struct ConfigReportResult
{
    ReportIssue issue;
    bool incomplete;
    bool resolutionFailed;    // snapshot-wide, before report filtering
    ReportCuts cuts;           // bit flags: propertyDepth, rows, valueItems,
                               // valueDepth, valueBytes, sourceBytes, labelBytes
    size_t rowsWritten;        // complete logical data rows, not physical lines
    ReportDiagnostic diagnostic; // located, terminal-safe; empty if issue == none
}

struct ConfigReportInput(T, Formatter, Sources, Docs, Redaction)
{
    const(ConfigSnapshot!T)* snapshot;
    Formatter formatter;
    Sources sources;
    Docs docs;
    Redaction redaction;
}

ConfigReportResult writeConfigReport(T, F, S, D, R, Writer)(
    scope ref ConfigReportInput!(T, F, S, D, R) input,
    in ConfigReportOptions options,
    in ConfigReportOutput output,
    scope ref Writer writer);
```

The output uses the existing `sparkles.base.term_caps.OutputCapabilities`:
`colorDepth` selects the color tier, its `colors` getter indicates whether colors
are enabled, `unicode` selects guides, and `hyperlinks` independently enables
label links. The report introduces no parallel capability vocabulary.

`CellExtent` denotes the proposed base-owned nonnegative integral cell extent
required by [WRAP-UNIT3](../../base/text/wrapping.md#layoutunit), not a report-owned
physical length or a shipped type name. A host marks an undetermined probe width
as `widthKnown = false`; a known zero remains a real zero capacity and cannot fit
this report. A report adapter converts to the shipped table's integer width only
through an explicit checked cell-count conversion.

Base owns line opportunities, source-preserving plans, and style snapshots under
the [wrapping contract](../../base/text/wrapping.md#ansi-and-styling-state).
The table owns its cell geometry and exclusion of generated guides/padding/
borders from label links. C3 follows that shared cutover rather than establishing
a competing wrapper or interpreting physical font units as terminal cells.

`Writer` accepts complete UTF-8 chunks through `put`; a host adapter translates an
output error into `writeFailure`. The input snapshot pointer is non-null and
borrows an initialized, live snapshot; all policies and slices borrow for the call.
Policy templates infer attributes from their implementations; this sketch makes
no `@nogc` or allocation-free claim. The bounded row projection and table layout
may allocate, but never copy the full configuration or retained payload set.

The policy capabilities are deliberately small:

- `formatter.format!V(ref cellWriter, in V value, in ValueFormatContext context)`
  returns `ValueFormatResult`, carrying cut flags or a formatting diagnostic.
  The context identifies the canonical active path and declared owning option
  pattern, original wire policy/key-or-value position, explicit value limits,
  borrowed typed supplied-member presence, and branch provenance. Provenance
  carries the parent `DefinitionRef` and original source branch locator; it is
  not reconstructed from an effective map/list position or badge. An effective
  value uses effective presence, while a retained definition uses its original
  submitted presence. The context contains no editor badge or source-code link.
- `sources.lookup(snapshot, SourceRef source, scope sink)` invokes the sink with
  the snapshot's borrowed `SourceView`. The standard adapter delegates to
  `visitSource`; wrong-owner/invalid handles are report diagnostics, never a
  fabricated source name. Definition priority/order/location and branch locators
  come from `DefinitionView` or typed snapshot branch views, not reparsed source
  text. A branch source cell joins the owning retained definition with its
  supplied branch locator and selected contributor handles.
- `docs.target(ownerOption)` returns a validated `DocTarget` or a located metadata
  diagnostic. Targets are compiled/generated from the schema metadata in §8;
  the writer does not discover pages or perform network requests.
- `redaction.isSensitive(declaredOptionPattern)` returns a metadata-only boolean.
  Before passing any payload to any formatter, the writer computes a cell's
  sensitivity closure over its owning pattern and all contained declared option
  patterns supplied by the shared schema descriptors. If any is sensitive, the
  entire cell is the literal `<redacted>`, with no value-dependent snippet.
  This closure uses declared metadata, not payload inspection, current effective
  children, or a sanitized copy of `T`. Definition cells use the original
  submitted branch's contained patterns, including absent/overridden descendants,
  not only active surviving branches. Independently rendered non-sensitive
  child rows remain available; redacting their ancestor cell does not change
  their own classification.

`ValueFormatResult`, `ValueFormatContext`, `ReportCuts`, `ReportDiagnostic`, and
`DocTarget` are also proposed, unimplemented types; their fields and outcomes are
defined by the contracts here. A diagnostic carries an issue kind, canonical
option when applicable, optional snapshot source location, and escaped detail.
It owns any text needed after the call; it contains no borrowed payload.

Supplied-member presence is a typed borrowed view, not a value-equality test.
The formatter prints only supplied members of a retained submodule definition,
including present fields equal to their defaults; absent native fields never
appear as submitted values. It consumes the snapshot's presence projection
rather than rediscovering presence by walking a source document. Root submitted
collection definitions retain their original payload and presence; their
definition rows do not serialize only the surviving effective branch.

**WCI16: One-snapshot typed input.** The report writer **must** obtain values,
statuses, definitions, and provenance from the one input snapshot through its
typed visits, and **must** apply the owning option's redaction before formatting.
It **must not** reload sources, materialize a fake successful configuration for a
failed snapshot, or prettyprint `PropertyNode.badge`/`propText` as a typed value.
Retained submodule definition rendering **must** honor supplied-member presence,
including supplied default-equal values, and **must not** print absent native
fields as definitions.
For aggregate/collection cells, that redaction **must** cover every contained
declared option pattern before the formatter receives the payload, even when the
root option itself is not sensitive. Sensitive options and redacted ancestor
cells **must** suppress value-dependent validation/conflict detail in both report
cells and diagnostics, preserving only terminal-safe status/code, option identity
and provenance as permitted by [WCFG24](./SPEC.md#_7-trust-and-publication-boundaries).
The writer **must not** traverse payloads to decide this closure or create a
sanitized full-configuration copy.

The report projection uses the property tree's existing traversal kernel and
address construction, with a read-only schema projection for section ancestry
and the inspection admission profile. A schema descriptor offers the original
member symbol/type and declared option pattern; snapshot typed option/branch
visits provide canonical active paths, presence, provenance and status/payload.
Direct, map-contained and list-contained submodule members repeat declared option
patterns at their runtime paths. They are selectable options under WCI3; plain
atomic/list elements remain data-only paths whose diagnostic identifies their
owning option.

A parent with failed descendants displays `unresolvedChildren` and has no native
effective `V` to format. Resolved children remain reportable through snapshot
branch visits; failed children show their actual failure and definitions, not
invented effective elements. Schema ancestry and these typed visits feed one
shared report projection, not a second UI reflection tree or app-local
`FieldNameTuple` recursion. Resolver storage/metadata budgets remain snapshot-owned
and are distinct from the report limits in §7.

This is an architectural requirement, not a claim that the shipped private walk
already accepts snapshots. The bounded feasibility question in §9 must establish
the shared read-only projection before implementation relies on it.

## 6. Typed formatter extension

The base library owns generic prettyprinting; wired owns configuration spelling.
The proposed extension is an optional value-policy template argument on
`PrettyPrintOptions`, in addition to its existing source-URI hook. With no value
policy, ordinary prettyprint output retains its existing behavior.

The **unimplemented** value-policy capability is
`policy.writeEnum!E(ref writer, in E value, bool colored)`: it writes the complete
enum leaf, replacing both the `E.` prefix and member spelling. A wired-aware
adapter in UI supplies the original field/format policy through
`ValueFormatContext`; it uses wired's resolved `wireNames` and representation
rules, not a second enum-name table. Name representation emits the quoted,
escaped wire token; value representation formats the underlying value through
the same typed leaf formatter. For example, an explicitly renamed member
`fastPath` with wire name `turbo` prints `"turbo"`, not `Mode.fastPath`.
An enum value with no valid named wire representation returns a located
`valueFormatting` diagnostic; it does not invent a spelling.

The optional **unimplemented** whole-value capability is
`policy.tryWriteValue!V(ref writer, in V value, in PrettyValueContext context)`,
returning `true` when it emits the complete value through the bounded writer.
It is called after depth admission but before prettyprint's generic type ladder;
returning `false` must emit nothing and change no cut state. The context carries
the current depth/policy and offers `writeChild(ref writer, in child)`, which
recurses through the same prettyprint implementation with the child policy and
depth increment. Both inline probes and final output use this interception.

The wired-aware report adapter uses it for supported nullable wrappers, which
otherwise reach prettyprint's generic aggregate branch. A null wrapper emits
`null`; a present wrapper with a null backing slice/string emits `value(null)`,
not the same `null`. Present non-null empty strings/collections remain `""`/`[]`;
other present values use `writeChild` and the original presence/wire policy.
The `value(null)` token is a report spelling distinguishing wrapper presence,
not a new configuration wire representation or a selected-value diagnostic.
This generic interception does not expose wired types or policies to base.

The same policy exposes `onLimit(PrettyLimit kind)` to record item/depth cuts.
The writer's bounded cell sink records a byte cut. No policy receives a raw
terminal-style template from a configured value.

For supplied-submodule rendering the same generic policy additionally offers
`includeMember!(Aggregate, member)()` and
`memberPolicy!(Aggregate, member)()`. Prettyprint calls the first before visiting
an aggregate field and propagates the returned child policy only for included
members; collection recursion similarly carries the typed branch policy.
The UI adapter translates snapshot presence and original wire-policy context
into these generic capabilities. Base learns neither `DefinitionRef` nor the
configuration presence representation, and an absent member incurs no formatting
work. Inline probes obey the identical admission and child-policy rules.

**WCI17: Recursive wire spelling.** The prettyprint extension **must** invoke the
supplied enum policy at every enum leaf, including nested collection keys and
values, and **must** preserve it in inline-size probes and recursive calls.
`sparkles:base` **must not** import wired or configuration metadata; the report's
typed adapter owns policy resolution and disables prettyprint source/type links.

The inline probe remains an internal prettyprint heuristic. It must use the same
spelling as emitted text, but its limit observer does not double-count a cut.
Its temporary work is bounded by the explicit value limits. The extension must
also expose cuts as structured state, since testing rendered text for `...` would
misclassify a literal value containing that text.

## 7. Width, continuation, and result policy

The report selects `border: true`, `columnSeparators: true`, `headerRows: 1`,
`rowSeparators: false`, left alignment and top alignment. For three extent-one
columns the existing table reserves ten cells: two outside borders, two interior
separators, and six gutter cells. Both ASCII and Unicode report guides occupy
two cells per tree level. A root label has no branch prefix; a row at depth `d`
greater than zero has a `2*d`-cell prefix. Definition rows are one level below
their owner. Depth here counts displayed ancestry, not prettyprint recursion.

The hard content floors are `[G + 12, 13, 12]`, where `G` is the maximum
guide-prefix width among admitted rows, including a reserved omission-marker row.
These leave twelve cells for a wrapped property label and keep the source/value
headers unbroken. The minimum total is their sum plus ten; for a flat report it
is 47 cells. The table may distribute remaining space by its existing solver.
These are report-specific readability floors, not a change to generic table
defaults.

**WCI18: Detectable hard floors.** The table-owned layout seam **must** report
`widthTooSmall` when the selected width cannot satisfy the report's hard floors,
and **must** expose the solved content widths or an equivalent fit result before
output is written. The report **must not** rely on `columnMinWidths` alone, since
the existing total-width shrink is allowed to override those soft floors.

The proposed table extension accepts hard floors distinct from
`columnMinWidths` and returns a checked layout/fit result. It belongs beside the
existing width solver and reuses it; the report must not duplicate shrinking,
measurement, or wrapping. A wide grapheme that cannot fit the label remainder
also produces `widthTooSmall`, not a line wider than the selected width. Known
widths are honored even for redirected sinks; known zero returns `widthTooSmall`.
Unknown width selects the fixed 120-cell budget. Capabilities alone select guides,
colors, and links.

**WCI19: Continuation guides.** The shared table text renderer **must** reserve
the property prefix before wrapping its label and **must** emit the ancestor
guide context on each continuation, including blank property continuations
caused by taller source/value cells. The branch marker **must** occur only on
the first physical line of a logical row, outside its documentation link.

The proposed, unimplemented table cell decoration is a first-line prefix and
continuation prefix, measured by the shared renderer. For each ancestor with a
later sibling the continuation uses `│ ` or `| `; otherwise it uses two spaces.
The current node's `├─`/`└─` or `+-`/`\\-` is replaced by `│ ` / `| ` when it has
a later sibling and by two spaces otherwise. Root continuations have no prefix.
Only label text wraps in the remaining field; source/value cells retain ordinary
table wrapping. This is a cell-decoration seam in the existing renderer, not
pre-wrapped rows or a second layout engine.

### Limits and observable completion

All seven limits are positive integers with the defaults in §5. Zero is invalid,
not unlimited; callers may raise limits explicitly within their field types.
Addition/multiplication is checked before allocation, and arithmetic or
allocation failure returns `allocationFailure`, not a wrapped-small budget.
The same limits apply in default and definition modes:

| Limit                 | Exact counting rule                                                                                                                                                                                      | At the boundary                                                                                    |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `propertyDepth = 16`  | Root rows have depth 0; admit rows with depth less than the limit, including definition/element rows.                                                                                                    | Mark the first excluded subtree visibly; set `propertyDepth`.                                      |
| `rows = 5_000`        | Count logical data rows after filters, including ancestors, elements and definitions, but not the header or omission markers.                                                                            | Stop before row 5,001; emit a terminal omission row; set `rows`.                                   |
| `valueItems = 256`    | Per container in each formatted value; keys and their paired map values count as one item.                                                                                                               | Print the first 256 entries and a count when known; set `valueItems` only if another entry exists. |
| `valueDepth = 16`     | The value root is level 0; levels through 16 are printable, matching prettyprint's `depth > maxDepth` convention.                                                                                        | Replace a deeper value with an omission token; set `valueDepth`.                                   |
| `valueBytes = 65_536` | Per value cell, escaped UTF-8 text before generated styling; independent for an effective value and each definition.                                                                                     | Stop before exceeding the budget at a complete token/escape and UTF-8 boundary; set `valueBytes`.  |
| `sourceBytes = 4_096` | Per source cell, all escaped UTF-8 source identities/details/locators/priority/order/disposition/contributor text combined, before styling. Also applies per rendered source-bearing diagnostic snippet. | Stop before exceeding the budget at a complete escape/UTF-8 boundary; set `sourceBytes`.           |
| `labelBytes = 4_096`  | Per property label, escaped UTF-8 before generated guides, links or styling; applies to structural, option, element and definition labels.                                                               | Stop before exceeding the budget at a complete escape/UTF-8 boundary; set `labelBytes`.            |

Omission markers are library-owned terminal-safe text outside the data budgets:
`… (omitted)` or ASCII `... (omitted)`, optionally with a known count and the
limit name. Each value, source and label cell reserves one such marker; a pruned
subtree reserves one marker row and a terminal row cut reserves one final marker
row. These markers need not format omitted payloads or calculate a full omitted
count. A cut-label marker lies outside the label's documentation link.
The byte sink must preserve balanced quotes/delimiters and close generated styles
before its marker; it must not merely slice prettyprint's output buffer.

**WCI20: Exact cap semantics.** Limits **must** admit content exactly at the
boundary without a cut and **must** mark an attempted excess with the corresponding
structured cut flag and a visible marker. Any value, source, label, property,
element, or definition cut **must** set `incomplete`; redaction and deliberate command filters
**must not** count as resource cuts.

Limits bound projection/formatting work, not merely the final output string.
Redacted payloads are never traversed to decide whether their hidden value would
have exceeded a limit. Default mode includes every admitted option, not only
changed values; definition mode has no implicit 32-item/8-level prettyprint cap.

Escaping source and label text writes directly into bounded cell sinks before
table measurement. The writer must not copy or escape an entire retained source
detail and slice it afterward, nor rescan its omitted suffix to calculate a
marker count. Snapshot provenance lookup borrows the original text; repeated
rows each perform at most their own cell budget plus bounded escape/marker work.
Identity, selection and documentation lookup use the full canonical
address/pattern, never a truncated display label. Snapshot storage budgets do
not substitute for these per-report bounds.

**WCI21: Status and exit precedence.** The writer **must** return diagnostic,
incomplete, and snapshot-failure facts independently, retaining cuts even if a
later diagnostic wins. The host **must** apply this exit precedence: operational
output/allocation failure `4`, command/metadata/formatting/width diagnostic `2`,
load or snapshot-resolution failure `1`, incomplete report `3`, complete report
`0`.

`issue != none` is diagnostic status; otherwise `incomplete` selects incomplete
status and its absence selects complete status. A complete report can still
describe failed resolution and exit `1`. Snapshot failure is measured before
filters, as required by WCI5. Load failure remains host-owned and joins the
precedence even when all successfully retained definitions can be reported.
Invalid options, selected-option lookup, documentation targets and width are
preflighted before stdout bytes. A formatting diagnostic stops before its row;
already emitted complete rows remain valid. A write failure may leave a partial
physical line and must not be disguised as a complete row. Located diagnostics
and an incomplete summary go to stderr, not a fourth report column.

## 8. Schema documentation metadata

The following **unimplemented** metadata is proposed for the shared schema
annotation vocabulary:

```d
struct ConfigDocPage { string uri; }     // absolute HTTP(S) page, no fragment
struct ConfigDocAnchor { string id; }    // nonempty stable anchor override
struct ConfigDocTarget { string uri; }   // absolute page + nonempty fragment
```

A schema type or section member may carry one `@ConfigDocPage`; the nearest
enclosing page wins. A declared option may carry `@ConfigDocAnchor` to override
its generated anchor or `@ConfigDocTarget` to replace both page and anchor.
Duplicate annotations and an anchor combined with a full target are metadata
errors. A complete target takes precedence over inherited pages. This metadata
describes documentation only; it does not change the wire name, canonical
address, property label, visibility, redaction, or precedence.

**WCI22: Stable generated targets.** For an option without an explicit target,
schema metadata **must** combine its inherited page with `option-` followed by
the lowercase two-digit hexadecimal encoding of every byte of its full canonical
declared option address or pattern, unless an explicit anchor overrides that
suffix. Every declared option **must** have exactly one target; elements and
definitions inherit it.

The canonical address is the resolver/property address, not `@Label` text or a
source document's renamed wire field. Hex encoding has no normalization or
separator collision. For example `mode` yields `#option-6d6f6465`. Renaming a
canonical member changes its generated target; a schema author preserves a
published anchor with `ConfigDocAnchor` rather than inventing an alias address.
Missing page metadata is a located metadata error, even when OSC is disabled.

Runtime repetitions of a declared submodule member link to that member pattern's
target, not a generated documentation page for each dynamic map key/list index.
The snapshot/schema descriptor supplies the owning pattern; the report does not
derive it by deleting indices from an address. Plain collection data elements
and root collection definition rows retain their owning declared option's target.
The [pattern contract](./composition.md#patterns-and-branch-locators) supplies
typed `[<index>]`/`[<key>]` segments in canonical declared-pattern text; the
anchor byte encoding uses that text unchanged. Quoted runtime keys are never
converted into pattern tokens by string replacement.

**WCI23: Actual page and anchor validation.** Before a fixture or application
report is accepted, its metadata **must** be checked against the actual published
or built page and exact fragment ID, including every inherited and overridden
target. A syntactically valid URL or a guessed page name **must not** pass this
gate.

The proposed docs-build adapter emits a checked target manifest keyed by schema
option and page/anchor; it validates same-site pages against built HTML IDs.
External overrides require a named documentation authority and evidence that the
retrieved page contains the requested anchor. Acceptance records the schema and
docs revisions used for that check. The runtime report consumes the validated
manifest; it performs no HTTP request and does not equate a host's HTTP `200`
response with an existing fragment. Q4 remains a per-application gate; this draft
creates neither application pages nor app-specific acceptance evidence.

**WCI24: Safe label-only URI emission.** Target validation **must** require a
well-formed absolute HTTP(S) URI of at most 506 encoded UTF-8 bytes, with a
nonempty authority, valid percent escapes, and no raw or percent-decoded C0/DEL
control bytes. The shared renderer **must** emit OSC 8 only around label text,
closing before tree guides, alignment padding, borders, source/value cells and
line endings, and reopening only around the label continuation.
This obligation includes mandatory cell breaks, not only soft wraps: the shared
table **must** preserve the active label-link state across explicit newlines and
**must** suspend it before emitting any generated non-label bytes. It **must not**
discard that state by splitting cell text before the shared wrapper observes the
mandatory break.

Anchor overrides are actual fragment IDs, percent-encoded when assembled into a
URI; a complete override already supplies URI encoding. Invalid metadata produces
`metadata` before report output regardless of capabilities. Metadata validation
does not grant values/source strings permission to emit ESC sequences. A
hyperlink-disabled sink emits identical visible content without any OSC bytes.
Color-disabled, hyperlink-enabled output still links labels; value/type links
remain disabled in either case.

The 506-byte limit includes the complete page URI, `#` and encoded fragment, not
only its path. Report opens use the no-parameter BEL-terminated sequence
`ESC ] 8 ; ; URI BEL`, whose six-byte envelope fits the existing
`sparkles.base.text.ansi.OscLinkState` 512-byte saved-open buffer exactly.
Targets longer than 506 bytes produce `metadata` before output even when links
are disabled; truncation and silently dropping continuation links are forbidden.
An extended saved-link capacity is outside this draft's assumed seam.
This bound is necessary for saved-link continuity, but does not by itself make
the table's mandatory-break handling safe. The shared table wrapping and
line-emission seam must satisfy the label-only contract independently.

## 9. Evidence and bounded feasibility questions

Source inspection establishes existing seams, not runtime conformance:

- [`PrettyPrintOptions` and `writePretty`](../../../libs/base/how-to/prettyprint-values.md)
  supply typed recursion, explicit item/depth limits and a source-URI hook.
  `libs/base/src/sparkles/base/prettyprint.d` emits `Type.member` for enums;
  its inline probes construct `PrettyPrintOptions!void`, so an enum-policy
  extension must preserve the new policy there as well.
- `libs/ui/src/sparkles/ui/property_tree.d` has one private visitor-driven
  `walkSubject`/`walkValue`/`walkChildren` kernel. `walkValue` calls `makeNode`
  before the visitor, and `makeNode` erases leaf text into `badge`.
  The aggregate branch filters `hidden` and `ShowIf` before visitor entry.
  There is no evidence here of a shipped inspection profile or schema-only
  typed snapshot projection.
- `libs/ui/src/sparkles/ui/components/table/layout.d` gives per-column soft
  floors, then total-width shrinking down to one cell per column. It stops
  when no column can shrink even if the total exceeds the requested cap.
  `render.d` exposes `drawTable`, while the solved layout and wrapped lines are
  package-visible; no public hard-floor fit outcome or continuation decoration
  is established by these declarations.
- `libs/base/src/sparkles/base/text/wrap.d` documents closing/reopening OSC 8
  across wraps. The executed table probe nevertheless demonstrates a known
  mandatory-break isolation failure: `render.d`'s `wrapCells` first uses
  `lineSplitter`, then creates a separate `byWrappedLine` range for each segment.
  Active link state from an opening in one segment is not preserved through
  that split. A soft-wrap continuation can leave its link open across the next
  hard cell break and generated padding/frame bytes.
- `libs/base/src/sparkles/base/text/ansi.d` stores the complete OSC opening token
  in `OscLinkState`'s 512-byte inline buffer. `apply` clears saved state when the
  sequence exceeds that capacity. WCI24 therefore limits the full encoded URI
  to 506 bytes with the specified six-byte opening envelope.

The real seam probe's ordinary URI and 506-byte URI both preserved visible text,
but linked a physical newline and table frame bytes. The 507-byte URI additionally
linked source/value cells when its over-capacity opening could not be saved.
These are observed failures of label isolation, not an unverified possibility;
visible-text parity and a saved opening within 512 bytes are insufficient oracles.
The existing enum baseline also emitted `Mode.fastPath` rather than wire token
`turbo`, and the 12-cell table exceeded its requested width. Exact commands,
outputs and execution scope belong to [testing.md](./testing.md); this draft
does not claim WCI15/WCI24 conformance or an application documentation gate.

The bounded questions below block reliance on the respective unimplemented
extensions. Negative outcomes change the shared seam design; they do not justify
an app-local walker or layout engine.

| Question                                                                                           | Small experiment                                                                                                                                                                                                                                                                                      | Decision criterion                                                                                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Can a schema-only inspection profile reuse the property kernel without requiring a successful `T`? | One scalar fixture with a nested section, `@hidden`, false `@ShowIf`, a renamed enum, and an unresolved option; expose typed descriptors before badge generation and visit the snapshot.                                                                                                              | Every declared option appears once in declaration order, failed options never borrow an effective payload, typed values reach the formatter, and ordinary editor visibility/refusals are unchanged.                                                                                                                                                                                                                     |
| Can a base value policy carry wire enum spelling and cuts through all recursion/probes?            | One renamed enum directly, in a list and as a map key; explicit field policy; run both inline and multiline paths with one over-limit container.                                                                                                                                                      | Exact quoted wire spelling and representation agree in both paths, cut state is observable once, and base's dependency list remains wired-free.                                                                                                                                                                                                                                                                         |
| Can nullable whole-value interception preserve every admitted state?                               | One supported nullable string and nullable list in null-wrapper, present-null-backing, present-empty and ordinary-present states, nested under a container; exercise inline and multiline paths.                                                                                                      | Output distinguishes null from value(null), empty strings/collections remain quoted/empty forms, and child enum/presence policies and cuts survive recursion without a base-to-wired dependency.                                                                                                                                                                                                                        |
| Can supplied-submodule formatting preserve absence and failed-child inspection?                    | One root map/list definition with an omitted native field, a supplied default-equal field, and a failed child beside a resolved child; exercise inline and multiline formatting with borrowed presence/branch provenance.                                                                             | Definition cells never print the omitted field, do print the supplied default-equal field, retain original root submission, and attach the parent's DefinitionRef/source locator. The parent shows unresolvedChildren without a native effective payload while the resolved child remains inspectable; base remains wired-free.                                                                                         |
| Does ancestor-cell redaction protect a sensitive child without hiding public child rows?           | A root map/submodule pattern is not sensitive; its token child is sensitive and its timeout child is public. Retain an overridden root definition containing the token plus an active definition where that token branch is absent; include a token validation/conflict message containing its value. | Every whole-root effective/retained-definition cell is redacted before any formatter receives its payload, including the original overridden definition. Token rows/snippets and value-dependent diagnostics reveal no token; timeout rows still show their typed value. Classification inspects schema metadata only, with no payload walk or sanitized T copy, and redaction creates no resource-cut/incomplete flag. |
| Can byte-limited prettyprinting stop safely without formatting an unbounded value first?           | Cut a quoted control-containing string and nested aggregate at byte budgets 1, exactly the escaped size, and one less; instrument the actual typed formatter's work.                                                                                                                                  | No partial UTF-8/escape or unbalanced delimiter/style escapes reach the table; structured cuts distinguish truncation from literal omission text, and work stops at the cap plus bounded closing/marker work. The extension remains inside prettyprint, not a second formatter.                                                                                                                                         |
| Are source and label work bounded before layout?                                                   | Borrow a retained 16 MiB source detail for two rows and an oversized label; use 4,096-byte and exact-boundary limits with escape-expanding controls near the cut.                                                                                                                                     | Each cell stops at its escaped-byte budget without copying/scanning the omitted suffix, markers are UTF-8/escape-safe and unlinked, and sourceBytes/labelBytes cuts set incomplete without changing lookup identity or snapshot budgets.                                                                                                                                                                                |
| Can the table enforce hard floors and reserve/repeat guides through its own layout?                | Three columns at flat minimum 47 and 46, a nested row with its computed minimum, and an asymmetric long source cell.                                                                                                                                                                                  | The checked layout exposes widths satisfying every floor or returns `widthTooSmall` before output; every continuation has the prescribed guides, one branch marker per row and no overflowing line.                                                                                                                                                                                                                     |
| Can the shared table isolate labels across both soft and mandatory breaks?                         | Reuse the observed failing linked label with spaces, a CJK grapheme, a combining sequence and an explicit newline; include label prefixes and taller adjacent source/value cells in the shared table seam experiment.                                                                                 | Stripped linked output equals plain output, but also every generated guide/padding/frame/source/value/newline byte is unlinked. Link state survives mandatory breaks and reopens only immediately around continuation label text. Fixing only the shared wrapper or accepting visible parity fails this criterion.                                                                                                      |
| Can the URI-cap adapter and mandatory-break repair satisfy separate obligations?                   | Retain real `OscLinkState.apply` and table cases with 506-byte and 507-byte URIs; add the proposed metadata adapter before the table call.                                                                                                                                                            | A 512-byte opening reopens verbatim but still needs mandatory-break isolation; the 513-byte opening exposes the known saved-state failure. The metadata adapter rejects 507-byte URIs before output, while the shared table repair isolates accepted 506-byte links across all generated bytes.                                                                                                                         |
| Can generated metadata prove page identity rather than URI syntax alone?                           | A single fixture manifest with a generated target, anchor override and external override; remove one real HTML ID and include one malformed URI.                                                                                                                                                      | The fixture gate rejects the missing ID and invalid URI independently; accepted targets have actual-page evidence. This does not discharge any application's Q4 gate.                                                                                                                                                                                                                                                   |

The throwaway single-file seam probe exercises the shipped `drawTable`,
`TableProps`, `visibleWidth`, `prettyPrint` and `OscLinkState` interfaces.
Its executed baseline establishes the spelling discrepancy, width overflow and
OSC failures above; it is not an implementation of the proposed report. Its
byte-state oracle detects linked newlines/frames/source/value, and its recorded
bytes require inspection to distinguish legitimate label spaces from generated
padding. Proposed hard floors, continuation guides, snapshot presence policies
and metadata rejection remain separate unimplemented seams with the bounded
criteria above. The probe is not a permanent conformance test.

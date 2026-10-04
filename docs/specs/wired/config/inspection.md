---
status: draft
owner: sparkles:ui
reviewed: 2026-10-04
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
TTY output uses the probed positive column width; redirected/unknown-width output
uses a deterministic 120-column budget. ASCII and Unicode guide selection follows
the output's declared capabilities.

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
output's `RenderCaps.hyperlinks` capability is true and disabled otherwise.
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

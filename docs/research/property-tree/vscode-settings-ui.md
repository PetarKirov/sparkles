# VS Code Settings editor (TypeScript / web)

The corpus's only **end-user settings editor** rather than developer inspector, and the one subject where a row is not `(label, value)` but a value **resolved through a scope chain, with provenance**.

|                        |                                                                          |
| ---------------------- | ------------------------------------------------------------------------ |
| **Language / toolkit** | TypeScript / DOM, `WorkbenchObjectTree`                                  |
| **License**            | MIT                                                                      |
| **Repository**         | [`microsoft/vscode`][repo], `src/vs/workbench/contrib/preferences/`      |
| **Revision read**      | [`474a349a`][rev]                                                        |
| **Category**           | Model-first: a settings tree model rendered by a virtualized list        |
| **Metadata source**    | runtime — the configuration registry's JSON-schema contributions         |
| **Undo**               | none in the editor; the underlying `settings.json` has the text editor's |

## Overview

### What it solves

Editing configuration, not objects. The differences from every Tier-1 subject follow from that
one change of purpose: settings are contributed by extensions rather than declared by a type,
a value exists at several **scopes** at once (default → user → workspace → folder → language),
and the audience is not a programmer holding a debugger.

### Design philosophy

Two structural choices state it. The editor is a **model over a virtualized tree**
(`SettingsTree extends WorkbenchObjectTree<SettingsTreeElement>`,
[`settingsTree.ts:2667`][tree]) — the presented rows are a windowed rendering of a model, not
widgets. And searching does not filter that model; it **replaces** it:

```ts
private get currentSettingsModel(): SettingsTreeModel | undefined {
    return this.searchResultModel || this.settingsTreeModel.value;
}
```

— [`settingsEditor2.ts:453`][currentmodel]

## Model & addressing

`SettingsTreeSettingElement` ([`settingsTreeModels.ts:113`][element]) is the row model, and its
id is a **stable string path** built from the parent group and the setting key:
`sanitizeId(parent.id + '_' + setting.key)` ([`:186`][id]).

What makes it the richest row model in the corpus is not the identity but the value fields:

| Field                                           | Meaning                                                                                                  |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `value`                                         | the effective value — "scopeValue \|\| defaultValue, for rendering convenience" ([`:122`][valuecomment]) |
| `scopeValue`                                    | the value **in the currently selected scope** ([`:129`][scopevalue])                                     |
| `defaultValue`, `defaultValueSource`            | the default and _who contributed it_                                                                     |
| `isConfigured`                                  | whether this scope sets it at all ([`:145`][configured]) — the "modified" dot                            |
| `hasPolicyValue`                                | the setting is locked by policy ([`:153`][policy])                                                       |
| `overriddenScopeList`, `languageOverrideValues` | where else it is set, and per-language overrides                                                         |
| `tags`, `isUntrusted`                           | filtering, and workspace-trust gating                                                                    |

A dev inspector shows a value; this shows a value **plus why it is that value**. Nothing in
Tier 1 models "unset but inherited" at all — the closest is [WinForms'][winforms]
`ShouldSerialize`/`[DefaultValue]` bolding, which is one bit rather than a chain.

## Metadata

The **configuration registry**: extensions contribute JSON-schema fragments, and the editor
derives `valueType` from the schema — `Boolean`, `Integer`, `Enum`, `MultilineString`, `Array`,
`Object`, `BooleanObject`, `Include`/`Exclude`, `NullableInteger`, `Complex`
([`settingsTreeModels.ts:234`][valuetype] onwards). So the type system driving the tree is a
document schema, exactly as in [`react-jsonschema-form`][rjsf], but contributed dynamically by
whatever extensions are installed.

## Recursion

Barely any — and that is the finding. The settings tree is **two levels of grouping over flat
rows**; nested structure inside a value is not descended into. A value the editor cannot
present inline is typed `Complex` and rendered as a link:

> `Edit in settings.json`
>
> — [`settingsTree.ts:1203`][editjson]

That is a deliberate boundary: the GUI handles the shapes it has widgets for (scalars, enums,
string arrays, string→string objects) and hands everything else to the text editor over the
underlying JSON. No Tier-1 subject has this escape — [WinForms][winforms] pushes to a modal
dialog, but the modal is still part of the grid's world; here the escape is _another editor
over the real serialization format_.

Cycles cannot occur: the domain is a flat key space with dotted names.

## Editing & mutation

- **Dispatch** — one renderer per `valueType` (`SettingBoolRenderer`, `SettingEnumRenderer`,
  `SettingComplexRenderer`, …), selected by template id. A closed set; extensions contribute
  _settings_, not renderers.
- **Mutation** — writes go to the configuration service at the **selected scope**, which
  rewrites the corresponding `settings.json`. The editor is therefore a front end over a text
  file whose own editor is always available — the two views coexist by construction.
- **Commit semantics** — per control (a toggle commits immediately; a text field on blur or
  Enter, debounced). There is no transaction.
- **Validation** — per row, rendered inline into a
  `.setting-item-validation-message` element ([`settingsTree.ts:1215`][validation]) — the
  corpus's only _inline, non-modal_ validation display. [WinForms][winforms] uses a modal
  dialog; everyone else has none.
- **Change notification** — the configuration service fires change events and the affected rows
  refresh; unlike the game-editor subjects there is no polling and no full rebuild.

## Type coverage

- **Collections** — string arrays and string→string objects have dedicated inline widgets
  (`settingsWidgets.ts`); anything richer becomes `Complex`.
- **Polymorphic values** — no type picker; a setting with several allowed shapes is `Complex`.
- **Optional / unset** — first-class and the point of the design: `isConfigured` distinguishes
  "not set here, inheriting" from "set here", and a per-row action resets to default.
- **Opaque types** — `Complex`, with the JSON escape.

## Presentation & control

- **Grouping** — categories and sub-categories from the contribution metadata
  (`settingsLayout.ts` pins a curated order for the common ones), two levels deep.
- **Conditional visibility** — tag filters (`@modified`, `@ext:`, `@feature:`), workspace-trust
  gating, and policy locking, all as row state rather than removal.
- **Search** — the model swap above, with a local fuzzy pass plus optional remote/AI-ranked
  results, and a `search-mode` class on the root ([`settingsEditor2.ts:464`][searchmode]).
  Because search yields a _different model_, expansion state of the grouped model is neither
  consulted nor disturbed — compare [Godot][godot], which disables folding while a filter is
  active, and `sparkles:ui`'s tree, whose filter asks the adapter to rebuild.
- **Multi-object editing** — not applicable; the analogue is the **scope selector**, which is
  the same shape of problem (one row, several underlying values) solved by picking one target
  rather than by merging.
- **Virtualization** — real, and inherited: `WorkbenchObjectTree` renders only visible rows
  with per-type templates that are recycled ([`settingsTree.ts:2667`][tree]).

## Strengths

- Row state models provenance (default source, scope, policy, language override), not just a value.
- Search as a model swap keeps filtering and expansion completely independent.
- Inline per-row validation messages.
- An honest escape hatch: whatever the GUI cannot express, the text format still can.
- Virtualized tree with recycled per-type templates — thousands of settings at no per-row cost.

## Weaknesses

- Almost no recursion: nested values are `Complex`, i.e. out of scope by design.
- Renderer set is closed; extensions contribute data, not presentation.
- No undo inside the editor.
- The row model is large and hand-maintained — the price of provenance.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                                      | Trade-off                                           |
| ------------------------------------------ | -------------------------------------------------------------- | --------------------------------------------------- |
| Row carries scope, default, source, policy | The user's question is "why is this value what it is?"         | A big, hand-maintained row model                    |
| Search swaps in a different model          | Filtering never interacts with grouping or expansion           | Two models to keep behaviourally consistent         |
| `Complex` → "Edit in settings.json"        | The GUI never has to represent arbitrary JSON                  | A visible capability cliff mid-list                 |
| Closed renderer set                        | Consistency across thousands of extension-contributed settings | No extension-supplied widgets                       |
| Scope selector instead of merging          | One target at a time is comprehensible                         | Cannot see or edit two scopes side by side          |
| Virtualized tree from the shared widget    | Free performance, familiar behaviour                           | Row heights and templates must be declared up front |

## Sources

All line numbers are at [`474a349a`][rev].

- [`settingsTreeModels.ts`][element] — `SettingsTreeSettingElement`, its value/scope/default/policy state, id construction, `valueType` derivation
- [`settingsTree.ts`][tree] — per-type renderers, the complex "edit in JSON" row, the virtualized tree
- [`settingsEditor2.ts`][currentmodel] — the model swap that implements search

<!-- References -->

[repo]: https://github.com/microsoft/vscode
[rev]: https://github.com/microsoft/vscode/tree/474a349ad5b745e512ef86b864d1c74f7264dd7a
[element]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTreeModels.ts#L113
[valuecomment]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTreeModels.ts#L122
[scopevalue]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTreeModels.ts#L129
[configured]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTreeModels.ts#L145
[policy]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTreeModels.ts#L153
[valuetype]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTreeModels.ts#L234
[id]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTreeModels.ts#L186
[tree]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTree.ts#L2667
[editjson]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTree.ts#L1203
[validation]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsTree.ts#L1215
[currentmodel]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsEditor2.ts#L453
[searchmode]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/workbench/contrib/preferences/browser/settingsEditor2.ts#L464
[winforms]: ./winforms-propertygrid.md
[godot]: ./godot-inspector.md
[rjsf]: ./react-jsonschema-form.md

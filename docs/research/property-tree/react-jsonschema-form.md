# `react-jsonschema-form` (TypeScript / React)

The schema-driven family: the tree comes from a **document**, not a type — which is why this is the only subject that both **shows a cycle as an affordance** and **carries data across a variant switch**.

|                        |                                                           |
| ---------------------- | --------------------------------------------------------- |
| **Language / toolkit** | TypeScript / React                                        |
| **License**            | Apache-2.0                                                |
| **Repository**         | [`rjsf-team/react-jsonschema-form`][repo]                 |
| **Revision read**      | [`c8723f5f`][rev]                                         |
| **Category**           | Function-first: fields recurse per render, state in React |
| **Metadata source**    | a JSON Schema document, plus a parallel `uiSchema`        |
| **Undo**               | none (the form owns `formData`; the host may)             |

## Overview

### What it solves

Rendering an editable form from a JSON Schema. Because the schema is data, everything the
type-driven subjects answer at compile time or through a type registry, this answers by
walking a document — and every hard case (recursion via `$ref`, `oneOf`, `additionalProperties`,
"the value may be absent") is explicit in the schema rather than implicit in a type system.

### Design philosophy

Presentation is separated from schema by a second document. The schema says what the data is;
the `uiSchema` says how to show it; `registry.fields` / `registry.widgets` say what component
renders each. A field is chosen by `SchemaField`, and every field is replaceable by name — the
most thoroughly parameterised presentation layer in the corpus.

## Model & addressing

No node model; fields recurse per render, like [bevy][bevy] and the [derive family][derive].
Identity comes in two flavours, and the second is the interesting one:

- **Path identity** — `fieldPathId` carries the dotted path through the form, used for DOM ids
  and for `onChange` targeting.
- **Row identity for arrays** — `ArrayField` keeps a **synthetic key per element**:

  ```ts
  function generateRowId() {
    return uniqueId('rjsf-array-item-');
  }
  ```

  — [`ArrayField.tsx:44`][rowid]

  The array is held in view state as `KeyedFormDataType[]` (`{ key, item }`) and converted back
  to plain data on the way out ([`:67`][keyed]). This is the corpus's **only stable element
  identity**: [Godot][godot], [bevy][bevy], [Unity][unity] and the [derive crates][derive] all
  key element state by index, so deleting element 0 shifts every later element's UI state.
  rjsf pays one allocation per row and keeps React's reconciliation — and each row's local
  state — attached to the right element.

## Metadata

The schema itself (`title`, `description`, `default`, `enum`, `const`, `readOnly`,
`additionalProperties`, `required`), plus `uiSchema` for presentation
(`ui:widget`, `ui:order`, `ui:options`, …). Two documents, both data, both replaceable at
runtime — the opposite end of the axis from D UDAs, and the reason the same form definition can
come from a server.

## Recursion

**The descent decision is the schema's `type`**: `object` and `array` recurse, everything else
is a widget. `$ref` is resolved first (`retrieveSchema` / `resolveAllReferences`), and that is
where the cycle problem appears — a schema may reference itself.

### Cycles — a cut with an affordance

`resolveAllReferences` keeps a `recurseList` of `$ref`s already on the path and, on a repeat,
**tags the sub-schema instead of expanding it**:

```ts
if (recurseList.includes($ref!)) {
  return markCycleOnDetection
    ? ({ ...resolvedSchema, [RJSF_REF_CYCLE_KEY]: true } as S)
    : resolvedSchema;
}
```

— [`retrieveSchema.ts:388`][cyclemark]

The tagged schema renders as `CyclicSchemaField` — a placeholder with an **Expand** button that,
when pressed, re-renders the same field with the flag cleared for that one level
([`CyclicSchemaField.tsx:25`][cyclicfield]). So an infinite structure is presented as a finite
one that the reader can extend by one level at a time, with the cut **visible**.

And the source states exactly when the guard is needed — a distinction no Tier-1 subject
articulates:

> Should only be `true` when called from an **object-property** context, because object
> properties are always rendered (creating an infinite loop), whereas array items and
> anyOf/oneOf branches are data-driven.
>
> — [`retrieveSchema.ts:366`][cyclecomment]

That is the same rule [Unity][unity] follows by putting its visited set in `SetExpandedRecurse`
and not in painting: **guard the walk that is not driven by data or by the user.** Two
independent subjects, same conclusion, stated in opposite directions.

## Editing & mutation

- **Dispatch** — `SchemaField` picks a field component by schema type; `uiSchema`'s `ui:field`
  or `ui:widget` overrides per node; `registry.fields`/`registry.widgets` overrides per form;
  a theme package overrides for a whole design system. Four nested override scopes, all data.
- **Mutation** — immutable: a change produces new `formData` and bubbles up through `onChange`
  with the field path. The form is a controlled component, so **the host owns the value** — the
  only subject besides [Qt][qt] where the component does not write into the subject at all.
- **Commit semantics** — per keystroke into `formData`; "commit" in the application sense is
  the form's submit.
- **Validation** — a first-class stage, not an afterthought: a pluggable validator (AJV by
  default) produces an `errorSchema` shaped like the data, so errors are addressed by the same
  path as values, and can be rendered inline per field or as a summary. This is the most
  developed validation story in the corpus.

## Type coverage

- **Collections** — `ArrayField` with add/remove/reorder and the synthetic row keys above;
  `additionalProperties` gives editable _key_ names, which no type-driven subject supports at
  all (a struct's field names are fixed).
- **Polymorphic values** — `oneOf`/`anyOf` render through `MultiSchemaField`, and this is the
  finding that refutes a Tier-1 claim. Switching options does **not** discard the old data:

  ```ts
  let newFormData = schemaUtils.sanitizeDataForNewSchema(
    newOption,
    oldOption,
    formData,
  );
  if (newOption) {
    newFormData = schemaUtils.getDefaultFormState(
      newOption,
      newFormData,
      'excludeObjectChildren',
    ) as T;
  }
  ```

  — [`MultiSchemaField.tsx:120`][optionchange]

  `sanitizeDataForNewSchema` keeps a key when the **name matches and the resolved type
  matches**, recursing into objects and arrays, replaces values that were at the old schema's
  `default`/`const` with the new one, and drops the rest
  ([`sanitizeDataForNewSchema.ts:117`][sanitize]). Tier 1 concluded that _nobody_ carries state
  across a variant switch; rjsf does, by name-and-type matching, and the retraction is recorded
  in [`comparison.md`][cmp].

  The selected option is also **derived from the data** rather than stored: when `formData`
  changes, the field re-matches which option fits ([`MultiSchemaField.tsx:73`][rematch]).

- **Optional / unset** — `OptionalDataControlsField` renders explicit add/remove-data controls
  for a field whose value may be absent ([`OptionalDataControlsField.tsx:46`][optional]),
  making "no value at all" a state the user can enter and leave — the clearest treatment of
  the axis in the corpus, next to [VS Code's][vscode] configured-vs-inherited.
- **Opaque types** — `FallbackField` renders what nothing else claimed, so an unknown schema
  degrades to a visible row rather than to nothing.

## Presentation & control

- **Grouping / ordering** — `ui:order`; `LayoutGridField` composes arbitrary layouts over the
  same data.
- **Conditional visibility** — expressed _in the schema_ (`if`/`then`/`else`, `dependencies`),
  so a value-dependent row set is a document feature rather than a hook — the exact capability
  [`uda-metadata.d`](./examples/uda-metadata.d) shows a compile-time channel cannot have.
- **Search / filter, multi-object editing** — neither.
- **Escape hatches** — `ui:field` per node → `ui:widget` per node → `registry.fields` per form →
  a theme package. All addressable by name from data.
- **Virtualization** — none; a large form is a large DOM.

## Strengths

- Cycles handled _and shown_, with a documented rule for when a guard is needed.
- Data survives a variant switch by name-and-type matching.
- Stable synthetic identity for array rows.
- Validation is a designed stage with errors addressed by data path.
- Optional data (present vs absent) is a first-class, user-controllable state.
- Every level of presentation is replaceable by name, from data.

## Weaknesses

- Everything is a document, so an error in the schema is a runtime surprise rather than a build error.
- No virtualization, no search, no multi-object editing, no undo.
- Wide surface: fields, templates, widgets, themes, `uiSchema` options — many places for one behaviour to live.
- Schema resolution (`$ref`, `allOf`, `dependencies`) is substantial work on every render pass.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                                   | Trade-off                                                                                                     |
| ---------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Tree from a schema document                    | Same form from server data; conditional logic is expressible                | No compile-time checking of anything                                                                          |
| Cycle tagged, rendered as an Expand affordance | Infinite structures become finite and legible                               | The cut is per level; a deep chain is many clicks                                                             |
| Guard only object-property recursion           | Array items and `oneOf` branches are data-driven and terminate on their own | The rule has to be passed down as a flag (`markCycleOnDetection`)                                             |
| `sanitizeDataForNewSchema` on option change    | A user switching variants keeps what still applies                          | Name-and-type matching is a heuristic; a same-named, same-typed field with different meaning survives wrongly |
| Synthetic array row keys                       | Element UI state follows the element, not the index                         | An extra view-state structure to keep in sync with the data                                                   |
| Controlled component; host owns `formData`     | Undo, persistence and submission are the host's                             | No in-place mutation, so every keystroke reallocates a path                                                   |

## Sources

All line numbers are at [`c8723f5f`][rev].

- [`packages/utils/src/schema/retrieveSchema.ts`][cyclemark] — `$ref` resolution, the `recurseList`, cycle tagging and the rule for when to tag
- [`packages/core/src/components/fields/CyclicSchemaField.tsx`][cyclicfield] — the expand-one-level affordance
- [`packages/core/src/components/fields/MultiSchemaField.tsx`][optionchange] — `oneOf`/`anyOf` switching and option re-matching
- [`packages/utils/src/schema/sanitizeDataForNewSchema.ts`][sanitize] — what survives a variant switch
- [`packages/core/src/components/fields/ArrayField.tsx`][rowid] — synthetic row identity
- [`packages/core/src/components/fields/OptionalDataControlsField.tsx`][optional] — present-vs-absent controls

<!-- References -->

[repo]: https://github.com/rjsf-team/react-jsonschema-form
[rev]: https://github.com/rjsf-team/react-jsonschema-form/tree/c8723f5f39d030776909667e74d217572757483c
[cyclemark]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/utils/src/schema/retrieveSchema.ts#L388
[cyclecomment]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/utils/src/schema/retrieveSchema.ts#L366
[cyclicfield]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/CyclicSchemaField.tsx#L25
[optionchange]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/MultiSchemaField.tsx#L120
[rematch]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/MultiSchemaField.tsx#L73
[sanitize]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/utils/src/schema/sanitizeDataForNewSchema.ts#L117
[rowid]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/ArrayField.tsx#L44
[keyed]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/ArrayField.tsx#L67
[optional]: https://github.com/rjsf-team/react-jsonschema-form/blob/c8723f5f39d030776909667e74d217572757483c/packages/core/src/components/fields/OptionalDataControlsField.tsx#L46
[bevy]: ./bevy-inspector-egui.md
[derive]: ./derive-macro-inspectors.md
[godot]: ./godot-inspector.md
[unity]: ./unity-serializedproperty.md
[qt]: ./qt-property-browser.md
[vscode]: ./vscode-settings-ui.md
[cmp]: ./comparison.md

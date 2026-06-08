# `sparkles:core-cli` prettyPrint — Specification

_Audience: developers and coding agents building against the pretty-printer.
This document is normative and self-contained — it states what `prettyPrint`
provides and how to extend it, not why. For the delivery plan and milestone
orchestration, see [PLAN.md](./PLAN.md). The extension model follows the
repo's [Design by Introspection guidelines](../../../guidelines/design-by-introspection-01-guidelines.md).
The implementation is [`libs/core-cli/src/sparkles/core_cli/prettyprint.d`](../../../../libs/core-cli/src/sparkles/core_cli/prettyprint.d)._

## 1. Overview

`prettyPrint` renders an arbitrary D value to any output range as colorized,
depth- and width-bounded text — a structured `toString` for debugging,
logging, and CLI output. Out of the box it dispatches on the value's D
**static type** (leaves, enums, pointers, tuples, arrays, associative arrays,
structs, classes) and bounds output by depth, item count, and a soft line
width.

Type-static dispatch is not enough for value types whose _meaning_ differs
from their _representation_: a `std.sumtype.SumType` is a struct whose private
storage should never be shown; a Nix `Value` is a handle into an external
evaluator; a `Money` is a `long` that should read `$5.00`; a secret should
read `***`. For these, `prettyPrint` exposes a **Design-by-Introspection
extension model** (§6): a value type renders itself (a `prettyPrintTo` method),
or a caller-supplied **hook** on the options takes over rendering of chosen
types — including overriding built-ins, carrying external state, and recursing
back through the same hook.

Core rules:

- **Backward compatibility is a contract.** With no hook (`Hook == void`) and
  no `prettyPrintTo` primitive in play, output is **byte-identical** to the
  type-static printer (the fallback). Every optional primitive is a
  compile-time-guarded `static if` that is dead code when absent (§6.4).
- **Optionality and zero-cost when unused.** Customization is opt-in: each
  optional primitive is detected with a named capability trait (`hasRenderHook`,
  `hasPrettyPrintTo`, …) following the repo's `__traits(compiles, …)` idiom; an
  absent primitive is never an error, it just falls back.
- **The shell owns layout; hooks own representation.** `prettyPrint` (the shell)
  provides the options, recursion, depth/width/item bounding, colors, and OSC 8
  links; a hook decides what a value of its chosen type _says_.
- **Attributes infer.** `prettyPrint` and every customization point are
  templates with inferred attributes. A pure/`@nogc`/`@safe` payload+hook stays
  `@safe pure nothrow @nogc`; an impure hook (e.g. Nix) infers impure **only**
  for that instantiation (§9).

A consumer who just wants to print a value touches one function:

```d
import sparkles.core_cli.prettyprint : prettyPrint;

struct Point { int x, y; }
assert(prettyPrint(Point(1, 2), PrettyPrintOptions!void(useColors: false))
       == "Point(x: 1, y: 2)");
```

## 2. Module and public API surface

| Identifier      | Value                                               |
| --------------- | --------------------------------------------------- |
| Dub sub-package | `sparkles:core-cli`                                 |
| Module          | `sparkles.core_cli.prettyprint`                     |
| Source          | `libs/core-cli/src/sparkles/core_cli/prettyprint.d` |

| Public symbol                                                       | Role                                                                |
| ------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `prettyPrint(value, ref writer, opt)`                               | Render into a caller-supplied output range; returns the writer      |
| `prettyPrint(value, opt) → string`                                  | Convenience overload returning a freshly-allocated string           |
| `prettyPrintNested(value, ref w, opt, depth)`                       | Public depth-aware re-entry — hooks/methods recurse through this    |
| `PrettyPrintOptions(Hook = void)`                                   | Rendering knobs + the stored hook instance (§3)                     |
| `SumTypeStyle`                                                      | `{ activeType, declaredType, valueOnly }` — sum-type rendering (§5) |
| `CombineRenderHooks(Hooks...)`                                      | Compose several render-hooks, first-wins (§6.6)                     |
| `hasRenderHook`, `hasPrettyPrintTo`, `hasRenderField`, `hasOnEnter` | Capability traits for the optional primitives (§6.9)                |

The two entry overloads:

```d
ref Writer prettyPrint(T, Writer, Hook = void)(
    in T value, return ref Writer writer,
    in PrettyPrintOptions!Hook opt = PrettyPrintOptions!Hook());

string prettyPrint(T, Hook = void)(
    in T value, in PrettyPrintOptions!Hook opt = PrettyPrintOptions!Hook());
```

`Writer` is any `std.range.primitives.put`-compatible output range
(`Appender!string`, `SmallBuffer!(char, N)`, a file sink, …). The string
overload allocates an `Appender!string`.

## 3. `PrettyPrintOptions`

```d
struct PrettyPrintOptions(Hook = void)
{
    ushort       indentStep   = 2;     // spaces per indent level
    ushort       maxDepth     = 8;     // recursion limit; deeper → "..."
    uint         maxItems     = 32;    // per array/range/attr-set; rest → "... N more"
    uint         softMaxWidth = 80;    // try single-line if it fits (0 = always multi-line)
    bool         useColors    = true;  // ANSI SGR styling
    bool         useOscLinks  = false; // OSC 8 hyperlinks on type names (§7)
    SumTypeStyle sumTypeStyle = SumTypeStyle.activeType; // §5

    static if (!is(Hook == void))
        Hook hook;                     // the extension hook instance (§6)
}
```

- The `Hook` type parameter selects the extension hook (§6). It defaults to
  `void` (no hook). When non-`void`, the hook **instance** is stored in `hook`
  and is available during rendering — this is what lets a hook carry external
  state (a Nix `EvalState`, a redaction policy, a cycle visited-set).
- One `Hook` type may provide several orthogonal capabilities at once: a render
  hook (§6.1), a source-URI writer (§7), a field hook (§6.7), and/or an event
  hook (§6.8). Each is detected independently.
- A stateless hook is a zero-byte struct; the stored instance costs nothing.

## 4. Built-in rendering (the default type dispatch)

With no applicable hook or `prettyPrintTo`, `prettyPrint` walks the value by
its D static type. The first guard is depth:

- **Depth limit:** at `depth > maxDepth`, render `"..."` (red when `useColors`)
  and stop. The root is depth 0; each level of nesting increments depth.

Then the type is dispatched, in this order, to a representation:

| Kind                                  | Representation (example, `useColors: false`)                          |
| ------------------------------------- | --------------------------------------------------------------------- |
| `null` (class/pointer/`typeof(null)`) | `null`                                                                |
| `enum`                                | `TypeName.memberName` (e.g. `Color.green`)                            |
| `bool`                                | `true` / `false`                                                      |
| character                             | quoted + escaped (`'a'`, `'\n'`)                                      |
| string                                | quoted + escaped (`"hello"`, `"a\tb"`)                                |
| numeric                               | decimal (`42`, `-7`, `3.14`, `nan`, `inf`)                            |
| pointer                               | `&` then the dereferenced value (`&42`)                               |
| `std.typecons.Tuple`                  | `(a, b)` or `(name: a, …)` when fields are named                      |
| associative array                     | `[k: v, …]` (inline) or multi-line; empty → `[]`-suffixed placeholder |
| static / dynamic array, length-range  | `[a, b, c]` (inline) or multi-line; empty → `[]`                      |
| `struct` / `class`                    | `TypeName(field: v, …)`; empty → `TypeName()`                         |

Cross-cutting rules:

- **Item limit:** arrays/ranges/associative arrays render at most `maxItems`
  elements, then a gray `... N more` (with `N` the remaining count when the
  length is known).
- **Inline vs multi-line:** collections and aggregates first attempt a
  single-line render; if it fits within `softMaxWidth` (and `≤ maxItems`) it is
  emitted inline, otherwise each element/field goes on its own
  `indentStep`-indented line. `softMaxWidth: 0` forces multi-line.
- **Colors:** when `useColors`, leaves are styled by kind (numbers blue;
  bool/`null` yellow; strings/chars/enum-members green; NaN/Inf red), type
  names magenta, field names bright-cyan, truncation markers gray. The leaf
  color policy is centralized in the private `PrettyLeafHook.styleOf`.
- **Type-name hyperlinks:** when `useOscLinks`, every rendered type name is
  wrapped in an OSC 8 hyperlink to its source location (§7).

## 5. Sum types, variants, and unions

`prettyPrint` renders the standard Phobos tagged-union types at the level of
their _active alternative_, not their internal storage. These are built-in
branches (no hook required), inserted before the generic struct/class branch
(both `SumType` and `Algebraic` are structs).

- **`std.sumtype.SumType` and bounded `std.variant.Algebraic`** render the
  active alternative, formatted by `opt.sumTypeStyle`:

  | `SumTypeStyle`         | `SumType!(int,string)` holding `42` | a struct alternative         |
  | ---------------------- | ----------------------------------- | ---------------------------- |
  | `activeType` (default) | `int(42)`                           | `SemVer(1.2.3)`              |
  | `declaredType`         | `SumType!(int, string)(42)`         | `SumType!(…)(SemVer(1.2.3))` |
  | `valueOnly`            | `42`                                | `1.2.3`                      |

  The payload is rendered by recursing through the printer, so depth, width,
  colors, and any active hook apply to it. An uninitialized `Algebraic`
  (`!hasValue`) renders `<empty>`.

- **Unbounded `std.variant.Variant`** is type-erased: best-effort rendering
  probes a small set of common scalar types and otherwise prints the dynamic
  type name. This is a documented limitation, not a guarantee.

- **Raw `union`** has no discriminant. `prettyPrint` **never reads a union
  member** (an inactive member with indirections would yield a garbage pointer
  that the printer could dereference). It renders the type name, a
  `/* union */` marker, and the member **names and declared types** from
  compile-time introspection only — e.g. `U /* union */ { i: int, f: float }`.
  This branch is `@safe pure nothrow @nogc`.

Detection uses import-free traits so `std.variant` is not pulled into module
scope for consumers that never use it.

## 6. The extension model

`prettyPrint` (the shell) exposes its customization as **optional primitives** —
some carried on a caller-supplied **hook** (a policy on the options), some on the
**value's own type**. Each is detected by a capability trait (§6.9) and
dispatched **before** the built-in fallback, so a hook can override even built-in
types. Precedence follows the DbI full-override → fallback order:
**render hook → `prettyPrintTo` primitive → built-in fallback** (§6.4).

### 6.1 The render hook (`canRender` / `render`)

A `Hook` type may provide a **full-override** hook (DbI §5.4):

```d
enum bool canRender(T) = /* compile-time: does this hook render type T? */;
void render(T, Writer, Opt)(in T value, ref Writer w, in Opt opt, ushort depth) const;
```

When `Hook.canRender!T` is `true`, `prettyPrint` calls `opt.hook.render(value, w,
opt, depth)` in place of the built-in dispatch. The hook:

- May opt into **any** type, including built-ins (`canRender!string` → redact).
- Recurses into sub-values via `prettyPrintNested` (§6.3), which re-dispatches
  through the same hook — so a runtime-tagged tree (Nix `Value`, `JSONValue`)
  renders fully.
- Owns its own layout; the built-in inline/multi-line collapser is not applied
  to hook-rendered values (§9).

`render` is a `const` method (the options are passed `in`); a stateful hook
reaches its mutable session through the idiom in §6.5.

### 6.2 The `prettyPrintTo` primitive

A value type the author owns may render itself with an optional primitive on the
type:

```d
struct Money {
    long cents;
    void prettyPrintTo(Writer, Hook)(ref Writer w, in PrettyPrintOptions!Hook opt, ushort depth) const
    { import std.format : formattedWrite; formattedWrite(w, "$%d.%02d", cents/100, cents%100); }
}
// prettyPrint(Money(500)) == "$5.00"
```

Detected when the exact call `value.prettyPrintTo(w, opt, depth)` compiles. The
method may itself call `prettyPrintNested` for nested fields. This primitive needs
no hook (works with `Hook == void`).

### 6.3 Recursion — `prettyPrintNested`

```d
void prettyPrintNested(T, Writer, Hook)(
    in T value, ref Writer w, in PrettyPrintOptions!Hook opt, ushort depth);
```

The public re-entry point. Hooks and `prettyPrintTo` methods recurse into
children with `prettyPrintNested(child, w, opt, cast(ushort)(depth + 1))`,
carrying the same options (hence the same hook). It is a **template**, not a
`scope delegate`, so it stays generic over heterogeneous child types and
preserves per-instantiation attribute inference. Callers increment `depth`
themselves; the same `opt` must be passed unchanged.

### 6.4 Dispatch precedence and the compatibility contract

`prettyPrintImpl` dispatches:

```
depth guard
  → render hook       (hasRenderHook!(Hook, T, Writer))     // full override; can override built-ins
  → prettyPrintTo     (hasPrettyPrintTo!(T, Writer, Hook))  // the type renders itself
  → built-in fallback (null/enum/leaf/pointer/Tuple/AA/array/struct|class)
  → static assert(false, "unsupported type")
```

When `Hook == void` (or a hook lacks `canRender`) and the value's type has no
`prettyPrintTo`, both capability traits are `false` and control falls through to
the unchanged built-in fallback. The new branches are dead `static if` code →
**the output is byte-identical to the pre-extension printer.** This contract is
enforced by a regression test that renders a representative value with
`Hook == void` and asserts the exact legacy output (the mandatory `void`-hook
baseline test, DbI §9.4).

### 6.5 Stateful hooks and the transitive-const idiom

`render` is called on `opt.hook` where `opt` is `in` (const), and D's `const`
is transitive — a stored `EvalState`/visited-set would itself be `const`,
unable to mutate (e.g. force a Nix thunk). A stateful hook therefore stores its
mutable session **by address** and reconstructs a mutable pointer through a
localized `@trusted` accessor:

```d
struct NixRenderHook {
    private size_t _es;                                       // address survives transitive const
    this(ref EvalState es) @trusted { _es = cast(size_t) &es; }
    private EvalState* es() const @trusted => cast(EvalState*) _es;
    void render(T, W, O)(in T v, ref W w, in O opt, ushort d) const { es.valueType(v); /* … */ }
}
```

This is sound provided the options value is not `immutable` (a stateful hook is
never `immutable`) and the referenced session outlives the `prettyPrint` call.
It is the standard pattern for any stateful render-hook (Nix evaluator, cycle
visited-set, label table).

### 6.6 Composition — `CombineRenderHooks`

```d
PrettyPrintOptions!(CombineRenderHooks!(NixRenderHook, RedactStringsHook))
```

`CombineRenderHooks!(Hooks...)` stores each sub-hook; `canRender!T` is the OR
over the sub-hooks; `render` dispatches to the **first** sub-hook whose
`canRender!T` is `true` (documented first-wins precedence); and it forwards a
`writeSourceUri` capability from the first sub-hook that provides one.

### 6.7 The field-override hook (advanced) — `canRenderField` / `renderField`

For per-field overrides (redact one field, format another as hex/units), a hook
may provide a field-granular full-override primitive consulted by the aggregate
walker:

```d
enum bool canRenderField(T, string member) = /* compile-time */;
void renderField(T, string member, FT, W, O)(in FT value, ref W w, in O opt, ushort depth) const;
```

When present for field `member` of aggregate `T`, the walker calls
`opt.hook.renderField!(T, member)(field, …)` instead of recursing normally.
Guarded → zero-cost when absent. Shipped wired (usable) but with no built-in
consumer; **advanced/unstable**.

### 6.8 Event hooks (advanced) — `onEnter` / `onLeave`

For decorate-and-fall-through over many types — cycle-aware graph rendering,
indentation tracing — a hook may provide **event hooks** (DbI §5.4: observe at a
critical point, then fall back):

```d
bool onEnter(T)(in T value, ref Writer w, ushort depth);  // return true ⇒ "handled, stop"
void onLeave(T)(in T value);
```

Consulted in the aggregate and pointer branches _before_ recursing: `onEnter`
returning `true` (e.g. a back-reference `<cycle #1>`) short-circuits the
built-in; otherwise the built-in proceeds and `onLeave` runs on exit. Guarded →
zero-cost when absent. **Advanced/unstable.**

### 6.9 Capability traits

The optional primitives are detected by public named capability traits mirroring
`hasWriteSourceUri`, usable by consumers in `static assert`s:

| Trait                                | True when…                                                  |
| ------------------------------------ | ----------------------------------------------------------- |
| `hasRenderHook!(Hook, T, Writer)`    | `Hook.canRender!T` and a matching `render` compile          |
| `hasPrettyPrintTo!(T, Writer, Hook)` | `value.prettyPrintTo(w, opt, depth)` compiles               |
| `hasRenderField!(Hook, T, member)`   | `Hook.canRenderField!(T, member)` and `renderField` compile |
| `hasOnEnter!(Hook, T, Writer)`       | `Hook.onEnter(value, w, depth)` compiles                    |

`hasRenderHook` is **staged** (it checks `canRender!T` _before_ probing
`render`) so `render`'s body is not semantically analyzed for types the hook
rejects — important under `-allinst` and to keep an impure `render` from
affecting unrelated instantiations.

## 7. OSC 8 hyperlinks and source URIs

When `useOscLinks`, type names are wrapped in OSC 8 terminal hyperlinks to
their definition site, obtained from `__traits(getLocation, T)`. The URI scheme
is itself a DbI hook on the options (`sparkles.core_cli.source_uri`):

```
static void writeSourceUri(string path, size_t line, size_t col, Writer)(ref Writer w);
```

- The fallback `FileUriHook` emits `file://path#Lline`. `SchemeHook!"code"`,
  `SchemeHook!"idea"`, etc. emit editor schemes (`vscode://…`,
  `jetbrains://…`); `EditorDetectHook` picks one from `$VISUAL`/`$EDITOR` at
  runtime. The scheme table lives in `source_uri.d`.
- The same `Hook` type may carry both `writeSourceUri` (a `static` method,
  CTFE — `path`/`line`/`col` are template arguments) and the render/field/event
  capabilities (instance methods). They are orthogonal.
- `writeSourceUri` is compile-time only. A consumer whose locations are
  **runtime** values (e.g. a Nix attribute's source position, §8.3) builds the
  link with a small runtime URI helper rather than this CTFE hook.

## 8. Consumers (normative examples)

The extension model is validated against these consumers. 8.1–8.2 ship as
in-tree tests; 8.3 ships in `sparkles:nix`; 8.4 is illustrative.

### 8.1 Owned value types (the `prettyPrintTo` primitive)

`Money` → `$5.00`, `Color` → `#ff0000` via `prettyPrintTo` (§6.2). No hook.

### 8.2 Redaction (a render hook overriding a built-in)

```d
struct RedactStringsHook {
    enum bool canRender(T) = is(immutable T == immutable string);
    void render(T, W, O)(in T, ref W w, in O, ushort) const { import std.range.primitives: put; put(w, "***"); }
}
```

Proves the render hook precedes the built-in leaf branch.

### 8.3 Nix values — `sparkles:nix` `NixRenderHook`

`libs/nix` provides a `NixRenderHook` (stateful, carries the `EvalState` by
§6.5) with `canRender!T = is(immutable T == immutable Value)`. Its `render`
walks a Nix value in `nix repl` surface syntax and is **normative** in these
respects:

- **Lazy / eagerness-bounded.** A node is forced only to WHNF to learn its kind.
  `maxDepth` and `maxItems` are evaluation-eagerness bounds: at `depth >
maxDepth` an unforced thunk renders `…` (never forced); a list/attr set forces
  at most `maxItems` children (via single-element access) and summarizes the
  rest as `... N more` (the tail is never forced). A small `maxDepth`/`maxItems`
  is a cheap "peek" at a huge tree.
- **Error-tolerant.** A per-node evaluation failure renders `«error: msg»`
  (red) inline and rendering **continues with siblings** — one failing
  attribute does not abort the whole value.
- **Surface syntax.** Strings quoted with Nix escaping (incl. `${` → `\${`),
  paths unquoted, lists `[ a b c ]` (space-separated), attribute sets
  `{ name = value; … }` (semicolon-separated, non-identifier names quoted),
  `«lambda»` / `«external»` for functions and external values.
- **OSC 8.** When `useOscLinks`, `ValueType.path` values (and exact
  `/nix/store/…` strings) link to `file://` URIs. When built against a Nix
  whose C API exposes positions (a `version(NixSourceLocations)` build),
  attribute names and lambdas additionally link to their **definition site**
  via a runtime `file://path#Lline` URI (§7). On stock Nix this is absent.

Convenience entries `prettyPrintNixValue(es, v, w, base)` and
`toPrettyString(es, v, base)` build the hook'd options and call `prettyPrint`.
This consumer is specified in full in `sparkles:nix`'s own docs.

### 8.4 `std.json.JSONValue` (illustrative)

A stateless render-hook with `canRender!T = is(immutable T == immutable
JSONValue)` whose `render` switches on `JSONType` and recurses via
`prettyPrintNested` — shows the mechanism handles a runtime-tagged tree with no
external context.

## 9. Safety attributes and conventions

- **Inference, not annotation.** `prettyPrint`, `prettyPrintImpl`,
  `prettyPrintNested`, and the capability traits are templates with inferred
  attributes. Following the repo rule, no `@safe`/`@trusted` is forced on them.
  A pure/`@nogc`/`@safe` payload+hook keeps the instantiation
  `@safe pure nothrow @nogc`; an impure hook (Nix) infers impure for _that_
  instantiation only.
- **Probes don't leak attributes.** The capability traits are
  `__traits(compiles, …)` computations; merely adding them cannot drag an
  impure/`@system` path into the common case.
- **The inline-layout guard.** The built-in single-line collapser builds a
  `PrettyPrintOptions!void` and would erase a stateful hook. Aggregates/
  collections therefore skip the inline attempt when any field/element type is
  hook-rendered (a hook owns its own layout). For `Hook == void` this guard is
  inert and the inline path is unchanged.
- **`@trusted` is localized.** The only unsafe operation is the stateful-hook
  address reconstruction (§6.5), wrapped in a `@trusted` accessor — never a
  whole-function or whole-template `@trusted`.

## 10. Non-goals (initial release)

- **Multi-render dispatch beyond first-wins.** `CombineRenderHooks` picks the
  first matching sub-hook; there is no priority negotiation or merging.
- **A UDA policy engine.** The field-override hook is a mechanism; a declarative
  "redact every `@sensitive` field" layer on top is out of scope.
- **Built-in JSON/Nix consumers in core-cli.** core-cli ships the _mechanism_
  and in-tree validation hooks; `JSONValue`/Nix renderers live with their data
  types (Nix in `sparkles:nix`), not in `prettyprint.d`.
- **Whole-graph deduplication** beyond what an `onEnter` visited-set hook
  implements.
- **Runtime editor-scheme source links.** Runtime source positions link via
  `file://` only; reusing the editor-scheme table (`vscode://`, …) for runtime
  positions is a later refinement.

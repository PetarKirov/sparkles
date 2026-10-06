# `sparkles:wired` — Serialization and retained configuration

`sparkles:wired` maps D values to and from serialized text by structural
introspection. The same declarations supply wire names, casing, representation,
and the typed schema; there is no parallel handwritten field declaration.

JSON serialization uses wired's native parser and writer, with
[`Expected`](../../guidelines/idioms/expected/index.md)-based results:
`toJSON` returns `Expected!(JsonString, JsonError)` and `fromJSON!T` returns
`Expected!(T, JsonError)`. Configuration resolution additionally retains
definitions, priorities, and provenance in move-only owners. Start with
[Resolve scalar configuration](./how-to/resolve-scalar-config.md); the same
builder also supports [collections and submodules](#collections-and-submodules).

## Installation

<InstallInstructions pkg="sparkles:wired" />

## Decode JSON — `fromJSON`

`fromJSON!T` parses JSON text with wired's native engine and reconstructs a
`T`, recursing through arrays, objects, and nested aggregates. It returns an
`Expected!(T, JsonError)`
whose `.value` holds the decoded result on success:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_from_json"
    dependency "sparkles:wired" version="*"
+/

import std.stdio : writeln;
import sparkles.wired : fromJSON;

struct Server
{
    string host;
    ushort port;
    string[] tags;
}

void main()
{
    Server server = fromJSON!Server(
        `{ "host": "localhost", "port": 8080, "tags": ["web", "edge"] }`).value;
    writeln(server);
}
```

```ansi
Server("localhost", 8080, ["web", "edge"])
```

## Encode values — `toJSON`

`toJSON` is the inverse: it walks a value and produces minified JSON text as
an `Expected!(JsonString, JsonError)` (struct fields in declaration order,
are emitted in sorted order):

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_to_json"
    dependency "sparkles:wired" version="*"
+/
import std.stdio : writeln;
import sparkles.wired : toJSON;

struct Server
{
    string host;
    ushort port;
    string[] tags;
}

void main()
{
    auto server = Server("localhost", 8080, ["web", "edge"]);
    writeln(server.toJSON.value[]);
}
```

```ansi
{"host":"localhost","port":8080,"tags":["web","edge"]}
```

## Deterministic, diff-friendly output

Generated JSON that lives in version control wants a layout that never moves
on its own. `JsonWriteOptions` carries that layout — indent unit, line
terminator, and key order — and `writeJSON` / `writeJSONFile` take it (plus an
optional key comparator) as compile-time arguments:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_layout"
    dependency "sparkles:wired" version="*"
+/
import std.array : appender;
import std.stdio : writeln;

import sparkles.wired : writeJSON;
import sparkles.wired.json.writer : JsonWriteOptions, KeyOrder;

/// Sorts numeric-looking keys numerically, and after any other key.
bool versionish(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    static bool numeric(scope const(char)[] s)
    {
        foreach (c; s)
            if (c < '0' || c > '9')
                return false;
        return s.length > 0;
    }

    if (numeric(a) != numeric(b))
        return !numeric(a);
    if (numeric(a) && a.length != b.length)
        return a.length < b.length; // 9 before 10
    return a < b;
}

void main()
{
    auto releases = ["10": "newest", "9": "older", "name": "widget"];

    // Four-space indent, keys through the custom comparator.
    enum layout = JsonWriteOptions(
        pretty: true,
        indent: "    ",
        keyOrder: KeyOrder.sorted,
    );

    auto buf = appender!string;
    writeJSON!(layout, versionish)(releases, buf);
    writeln(buf[]);
}
```

```ansi
{
    "name": "widget",
    "9": "older",
    "10": "newest"
}
```

One rule governs key order. Associative arrays and `JSONValue` objects have no
inherent order, so they are **always** sorted — output never depends on hash
order. Struct fields and parsed-document members do have one, so they follow
`keyOrder`: `declared` (the default) keeps declaration/source order, `sorted`
sorts by wire key. The comparator applies at every sorted position and must be
CTFE-callable, since struct field order is resolved at compile time.

`writeJSONFile!(layout)(value, path)` writes the same text atomically, with a
trailing newline. Pin `layout` at the call site for any file you check in: a
future change to wired's defaults then cannot silently reformat it.

## Errors as values

Because decoding never throws, malformed input surfaces as the `JsonError`
payload of the returned [`Expected!(T, JsonError)`](../../guidelines/idioms/expected/index.md) —
branch on `hasValue` / `hasError` and inspect the failure as data. Decode errors
carry a precise message, including, for enums, the set of names that _would_ have
matched:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_errors"
    dependency "sparkles:wired" version="*"
+/

import std.stdio : writeln;
import sparkles.wired : fromJSON;

enum Mode { off, on, automatic }

void main()
{
    // fromJSON never throws — it returns Expected!(T, JsonError).
    auto good = fromJSON!Mode(`"on"`);
    writeln("value: ", good.hasValue, " ", good.value);

    auto bad = fromJSON!Mode(`"sideways"`);
    writeln("error: ", bad.hasError);
    writeln("       ", bad.error);
}
```

```ansi
value: true on
error: true
       Cannot decode Mode at $ from JSON string "sideways": expected one of: off, on, automatic
```

## API

| Symbol                                                                      | Description                                                                                           |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `writeJSON(value, ref writer)` → `Expected!(void, JsonError)`               | Stream JSON into any output range — the primary encode form (never throws).                           |
| `toJSON(value)` → `Expected!(JsonString, JsonError)`                        | Encode a value to minified text; a failure is captured as the `JsonError` payload (never throws).     |
| `fromJSON!T(text)` → `Expected!(T, JsonError)`                              | Parse and decode JSON text; a failure is captured as the `JsonError` payload (never throws).          |
| `readJSONFile!T(string path)` → `Expected!(T, JsonError)`                   | Read, parse, and decode a file; the error identifies the failing stage (read, parse, decode).         |
| `writeJSONFile!(opts, keyLess)(value, path)` → `Expected!(void, JsonError)` | Encode and write to `path` atomically, creating parent directories; `opts` pins indent and key order. |
| `@WireName("…")`                                                            | Field / enum-member UDA overriding the JSON wire name.                                                |
| `@WireCase(CaseStyle.…)`                                                    | Recase field / member names (e.g. `snakeCase`, `kebabCase`).                                          |
| `@WireRepr(Repr.…)`                                                         | Serialize an enum by member `name` (default) or underlying `value`.                                   |

## Supported types

The same structural mapping covers a broad range of types, in both directions:

- **Scalars** — `bool`, `string`, `char`, integral and floating-point types
- **Enums** — by member name, or a `@WireName` / `@WireCase` / `@WireRepr` override
- **Arrays / slices** — of any supported element type
- **Associative arrays** — keyed by `string` or by an enum
- **Aggregates** (`struct`) — field by field, under their member names
- **`SumType`** — encoded as its active variant; decoding tries each variant in turn
- **`Nullable!T` / `Optional!T`** — JSON `null` ⇄ the empty value
- **`Ternary`** — JSON `null` / `true` / `false`
- **`SysTime`** — an ISO-8601 extended string
- **`JSONValue`** — passed through unchanged

Every entry below is encoded with `toJSON` and decoded back with `fromJSON`, and the
two agree — the mapping round-trips:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_showcase"
    dependency "sparkles:wired" version="*"
+/
import std.stdio : writefln;
import std.sumtype : SumType;
import std.typecons : Nullable, Ternary;
import sparkles.wired : fromJSON, toJSON;

enum Suit
{
    spades,
    hearts,
}

struct Card
{
    Suit suit;
    int rank;
}

alias Cell = SumType!(int, string);

void show(T)(string label, T value)
{
    auto json = value.toJSON.value;         // encode → minified text
    auto back = fromJSON!T(json[]).value;    // decode again → T
    writefln("%-12s %-28s round-trips=%s", label, json[], back == value);
}

void main()
{
    show("int",         42);
    show("double",      3.5);
    show("bool",        true);
    show("string",      "hi");
    show("enum",        Suit.hearts);
    show("enum[]",      [Suit.spades, Suit.hearts]);
    show("int[string]", ["a": 1, "b": 2]);
    show("int[Suit]",   [Suit.spades: 1, Suit.hearts: 2]);
    show("struct",      Card(Suit.hearts, 10));
    show("SumType",     Cell("text"));
    show("Nullable",    Nullable!int(7));
    show("Ternary",     Ternary.unknown);
}
```

```ansi
int          42                           round-trips=true
double       3.5                          round-trips=true
bool         true                         round-trips=true
string       "hi"                         round-trips=true
enum         "hearts"                     round-trips=true
enum[]       ["spades","hearts"]          round-trips=true
int[string]  {"a":1,"b":2}                round-trips=true
int[Suit]    {"hearts":2,"spades":1}      round-trips=true
struct       {"suit":"hearts","rank":10}  round-trips=true
SumType      "text"                       round-trips=true
Nullable     7                            round-trips=true
Ternary      null                         round-trips=true
```

## Enum wire names — `@WireName`

By default an enum member maps to its source name. Annotate it with `@WireName` to
decouple the JSON spelling from the D identifier — useful for kebab-case or
otherwise non-identifier wire names. (For a whole-enum recasing rule, reach for
`@WireCase` instead.)

Schema admission checks the resolved original field/type/key/value policy, not
unused case styles. For `Repr.name`, resolved member names must be unique,
including alias declarations. For `Repr.value`, member labels are schema metadata
and do not constrain the underlying wire values. A field-targeted case override
takes precedence over its enum type's case policy.

Both directions honour the override:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_enum_names"
    dependency "sparkles:wired" version="*"
+/
import std.json : parseJSON;
import std.stdio : writeln;
import sparkles.wired : fromJSON, toJSON, WireName;

enum Level
{
    @WireName("low") low,
    @WireName("high-priority") high,
}

void main()
{
    writeln(Level.high.toJSON.value[]);                                // custom wire name
    writeln(parseJSON(`"high-priority"`).fromJSON!Level.value == Level.high);
}
```

```ansi
"high-priority"
true
```

## Collections and submodules

Import the retained configuration interface from `sparkles.wired.config`.
`ConfigBuilder!T`, `ConfigInput!T`, `OwnedConfigInput!T`, and `ConfigSnapshot!T`
are shared by scalar and collection configurations; there is no separate
collection builder. They retain submitted intent and provenance rather than
folding layers destructively. The [scalar guide](./how-to/resolve-scalar-config.md)
explains source registration, owned submission, and the collecting-to-snapshot
transition.

The [concise typed example](../../../README.md#collection-configuration) shows
sparse collection input. The runnable
[collection example](../../../libs/wired/examples/collection-config.d) decodes two
JSON sources, composes a plugin list and a tool map, inspects original versus
effective locators, and demonstrates a member conflict without hiding a successful
sibling. These are library examples, not application source discovery, persistence,
or a `config show` renderer.

### Choose an explicit merge policy

Attach a typed policy to an original schema field, for example
`@(ConfigMerge!(ListOf!Submodule)()) Plugin[] plugins;`.
Unannotated fields are `Atomic`, except a struct marked `@WireSection`, which is
a `Submodule` at a configuration policy site. Duplicate or incompatible policy
annotations reject the schema at compilation.

`@(ConfigCheck!predicate())` attaches a selected-value check. The predicate accepts
the original native value type, is `@safe pure nothrow`, and returns
`ValidationResult` with acceptance plus optional diagnostic code/detail. Checks
run after selection/composition, not on overridden definitions or conflicting
atomic values.

| Policy      | Native shape                                                                   | Selected-definition behavior                                                                                                                     |
| ----------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Atomic`    | Supported scalar, nullable value, array, map, or finite plain struct           | One selected definition supplies the whole value; multiple selected definitions conflict, even if equal.                                         |
| `ListOf!P`  | Dynamic array of values compatible with `P`                                    | Concatenate selected roots in definition order; each element is a separate instance of `P`, never paired with another source's element by index. |
| `AttrsOf!P` | Map with string or supported integral-enum keys and values compatible with `P` | Union selected roots' keys and resolve each common key through `P`.                                                                              |
| `Lines`     | String                                                                         | Join selected strings verbatim with one newline between them.                                                                                    |
| `Submodule` | Finite plain struct with supported member policies                             | Resolve supplied member definitions independently, with priority inheritance and declared defaults.                                              |
| `NullOr!P`  | `Nullable!V`, where `V` is compatible with `P`                                 | A sole selected null resolves null. Multiple selections containing any null conflict; all non-null selections compose through `P`.               |

Smaller numerical priorities win. Root selection happens **before** composing
children: a stronger branch override cannot resurrect an excluded parent.
Selected lists and `Lines` follow the tuple of order, unsigned source identity
bytes, and unsigned local identity bytes after priority selection. Map branch
enumeration uses canonical original-policy key spelling, not native AA iteration.
The source kind is descriptive and does not supply hidden precedence.

Supported graphs consist of bools, supported integer types, `float`/`double`,
strings, declared integral-enum values, nullable wrappers, dynamic/static arrays,
maps, and finite plain structs. Typed floating-point payloads, including NaNs,
are retained rather than rejected by a finite-only rule. Fixed arrays are atomic,
not `ListOf` results. Pointers, classes, recursive graphs, immediate nested
nullable wrappers, custom copying/destruction/ownership, custom wire conversion,
and `onInvalid: useDefault` are unsupported. This matrix is narrower than general
`fromJSON` support above.

Structural capture of an atomic graph does not interpret nested configuration
UDAs as composition or checks. Use `Submodule` when its members are independent
options. Direct sections are flattened into member options; repeated submodules
under lists/maps/wrappers introduce concrete member instances. Newly introduced
instances obtain missing members from the underlying struct initializer, not an
excluded lower-priority container's entry. Selected built-in payloads already
represent those defaults and do not acquire duplicate equal-priority fallbacks.
A selected null wrapper introduces no children.

### Supply full or sparse typed input

Every non-section `DefinitionSlot!V` has `supplied`, original typed `value`, and
`ConfigPresence!V presence`. Direct sections instead contain nested `ConfigInput`
fields. Absence is never inferred by comparing a native value with its initializer.
Explicit false, zero, empty containers, and values equal to defaults remain supplied.

Use these three construction paths deliberately:

- **Full configuration:** `fullConfigInput!Settings(settings)` supplies every
  declared option and structural member. It creates presence but does not capture
  or deep-copy the borrowed native graph; submit or capture it while that graph
  remains valid.
- **Full slot:** `DefinitionSlot!V(true, value)` generates `fullPresence!V(value)`.
  This is appropriate when all members of the value are intended definitions.
- **Sparse slot:** `DefinitionSlot!V(true, value, presence)` accepts an explicit
  compatible shape. For a list of submodules, size `presence.elements` to the
  source list, mark each element supplied, and mark only the intended fields
  under each element's `.members`. Unmarked native submodule members are not
  copied, validated, or reported as source definitions.

`ConfigPresence!V` is generated from `V`, not a handwritten overlay type:

| Native value         | Presence children                                 |
| -------------------- | ------------------------------------------------- |
| Scalar/string/enum   | `supplied` only                                   |
| `Nullable!V`         | `hasValue` and `child`                            |
| Dynamic/static array | `elements`, indexed by original source position   |
| Map                  | `entries`, keyed by the exact original typed keys |
| Plain struct         | `members`, preserving original D member names     |

The slot's `supplied` controls root admission; its presence root bit is not a
second mandatory root switch. Child supplied bits are authoritative.
Presence arrays must match source positions exactly, maps must match typed keys
exactly, and nullable `hasValue` must match wrapper nullness. Equal-size maps with
different keys are not compatible shapes. Sparse struct members are supported
under `Submodule`; `Atomic` values remain full structural data.
Manually setting only a collection slot's `supplied` and `value` is not a
replacement for a compatible presence shape.

`decodeConfigInput!T` constructs owned sparse input directly from original-site
JSON. It preserves member absence inside collection submodules and the original
`WireName`, `WireCase`, enum representation, and strictness policy. Duplicate
known members and equal typed map keys are rejected before assignment can erase
their occurrences, even if the root would later lose priority. Explicit unknown
member ignore does not hide known duplicates. Plain JSON arrays/maps reject
JSON null; a nullable wrapper permits it. Missing, supplied null, and supplied
non-null remain distinct.

### Override branch metadata without changing identity

`DefinitionMetadata!T` retains root priority, order, local ID, and location.
Non-scalar slots use `CollectionDefinitionMetadata!V`: its `.root` contains the
usual `LeafDefinitionMetadata` controls (also forwarded directly), and `.branches`
is a `ConfigBranchMetadata!V`. Direct sections retain
`SectionDefinitionMetadata!S` with `.priority` and `.members`.

Branch metadata provides optional `.priority`, `.order`, and `.location`, plus
generated `.child`, `.elements`, `.entries`, or `.members` matching presence.
It has no source or local-ID override: each branch inherits its containing root
definition's identity. The default tree is inert. For explicit overrides, first
assign `fullBranchMetadata!V(value, presence)` to the slot metadata's `.branches`,
then set controls at the intended supplied branch. For example, a plugin label
override lives at `.branches.elements[0].members.label.priority`.

`.shaped` distinguishes an explicitly checked shape from the inert default tree.
Array positions, exact typed map keys, wrapper state, and supplied struct members
must match the source graph. An override on an absent member is invalid, except
an absent section's priority-only inheritance control is valid and inert.
Below an atomic option, branch priority/order cannot alter selection; source
locations can describe its structural data. Locations require nonzero line and
column. A rejected shape or metadata override leaves admission unchanged.

### Inspect effective branches and original projections

Use the free typed visitor templates with UFCS and selective imports:
`snapshot.visitBranch!sink(path)`, `snapshot.visitBranches!sink()`, and
`snapshot.visitBranchDefinitions!sink(path)`. A sink receives a scoped typed
`BranchView!V` or `BranchDefinitionView!V`.

| View                     | Important fields                                                                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `BranchView!V`           | `path`, `pattern`, `owningOption`, `declaredOption`, `status`, `selectedPriority`, `effective`, `definitions`, `contributors`, `failedChildren`, `diagnostic`            |
| `BranchDefinitionView!V` | `path`, `pattern`, `originalLocator`, `parent`, `ref_`/`reference`, source/local identity, priority/order/location, `disposition`, original `value`, original `presence` |
| `DefinitionView!V`       | Parent root `ref_`/`reference`, original `value` and `presence`, source and definition controls; never a replacement merged container                                    |

Patterns such as `plugins[<index>].enabled` describe declared repeated options,
not runtime lookup syntax. Concrete addresses use `plugins[0].enabled` or
`tools["build"].width`, with original D member names even when JSON names differ.
Plain collection elements and atomic data are inspection branches, not independent
declared options: `visitOption` on such data identifies its owning option.

A source projection is identified by its parent `DefinitionRef` and relative
`originalLocator`. Concatenation may move a source's `[0].label` to effective
`plugins[1].label`; an effective index is not source identity. Excluded projections
retain their original routes but have an empty active `path`. Inspect them with
`snapshot.visitBranchDefinitions!sink(parent, originalLocator)` or enumerate
every retained projection with `snapshot.visitBranchDefinitions!sink(parent)`.

Branch definition/contributor arrays contain opaque `ContributionRef` handles.
Pass one to `snapshot.visitBranchDefinition!sink(handle)` to inspect its projection.
Handles are owner-checked: another snapshot's handle yields `wrongOwner`; an
invalid handle yields `invalidHandle`. Save handles, not borrowed payloads, for
later lookup against the same live owner. Moving the owner preserves identity.

A selected non-atomic root has disposition `selected`; individual projections
can independently be contributing, conflicting, invalid, or overridden.
Failed descendants leave ancestors `unresolvedChildren`, with no effective
container, while successful siblings remain inspectable. An ancestor check is
suppressed until its children resolve. A completed merged candidate rejected by
its own `ConfigCheck` reports `invalidMergedValue` with its diagnostic and
contributors. Scalar selected-value checks retain `invalidSelectedValue`.
No losing definition silently repairs a conflict. `copyConfig` requires the
entire configuration to resolve.

### Ownership and callback lifetimes

`submitBorrowed` and `captureInput` recursively capture supplied arrays, maps,
keys, strings, plain structs, presence, and metadata; copying an outer slice or
AA alone is not capture. Creation also owns mutable initializer graphs.
Later caller mutation cannot change retained values. Successful `submitOwned`
transfers an input capsule without cloning its captured graph; rejected submission
preserves both owners. Resolution may synthesize an outer container without
deep-cloning already owned nested values. Builder, capsule, result, and snapshot
owners are move-only.

`copyConfig` is the explicit independent deep-copy operation. Its ordinary native
D graph, including nested arrays/maps and keys, remains valid after the snapshot
is destroyed. Typed null versus non-null-empty container backing is preserved
where applicable. Two or more selected lists/maps, or a sparse container requiring
normalization, produce a non-null normalized container even when empty. A sole
unchanged selected container preserves its backing state. Nullable wrapper
nullness is a separate state.

Visitor records and everything they borrow live only for the callback. Do not
move or destroy the owner during a visit. `ConfigValueView!V` has `.hasValue` and
scoped `.get`; collection payloads use `ConfigArrayValueView`,
`ConfigMapValueView`, and `ConfigStructValueView`, not escapable native mutable
containers. Arrays support length/index/iteration, maps support contains/index/
iteration, and structs expose original fields under `.members`.
`ConfigPresenceView!V` exposes the corresponding supplied shape. Borrowed string
values and keys read as `const(char)[]`, even when their source type is immutable
`string`; copy text explicitly to retain it. Native map-value-view iteration
does not promise the canonical order of branch enumeration.

### Limits and logical accounting

`ConfigLimits` fields must be positive. `ConfigUsage` exposes corresponding
`ulong` counters without the `max` prefix. Equality fits; overflow, limit, or
detectable allocation failure rolls back the whole operation, leaving a collecting
builder available for `setLimits`. Resolution publishes no partial snapshot on
operational failure; semantic conflicts instead belong to a complete snapshot.

| Limit                | Default    | Exact unit                                                                                                                                                                                                        |
| -------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `maxSources`         | 1024       | Registered source records, including `$builtin`.                                                                                                                                                                  |
| `maxDefinitions`     | 65,536     | Submitted/built-in root definitions plus per-instance generated fallback definitions, including overridden definitions.                                                                                           |
| `maxPayloadBytes`    | 16,777,216 | Logical value and retained text bytes under the rules below.                                                                                                                                                      |
| `maxOptions`         | 4096       | Declared non-section option patterns, including a collection root and each repeated submodule member pattern once, not runtime element/key count.                                                                 |
| `maxDepth`           | 32         | Maximum original member, map-key, or array-index hops from root; nullable unwrapping adds no hop. Finite potential depth is checked even for empty containers.                                                    |
| `maxValueNodes`      | 262,144    | Scalar, nullable-wrapper, container, and plain-struct occurrences in supplied retained graphs, generated defaults, and normalized candidates. Aliases count by occurrence; absent submodule members do not count. |
| `maxResolvedRecords` | 65,536     | Root option and materialized inspection/semantic branch records.                                                                                                                                                  |
| `maxContributions`   | 262,144    | Selected relationships between a resolved record and a source projection or generated fallback; not duplicated values.                                                                                            |

Value bytes are exact logical charges: primitive/enum `sizeof`, string byte
length, nullable tag byte plus non-null payload, and dynamic array/map tag byte
plus supplied contents. Fixed arrays have no tag; structs have no tag and charge
supplied submodule members or all atomic/normalized members. Map keys charge per
entry even when storage is interned. Explicit null and non-null-empty containers
each charge their tag byte.

Each source graph and each generated fallback graph charges separately.
A normalized candidate charges once per maximal normalized graph; nested branch
views do not charge it again. If an ancestor has no effective graph, successful
normalized child graphs charge independently. Candidates rejected by a merged
check still charge. Synthesized `Lines` text includes its newline bytes.

Each distinct canonical active/pattern path and key-spelling text charges once;
an already charged schema path is not charged again. Original source locator
indices/key references are metadata, not extra copied path text. Identity bytes
are interned and charged once per distinct identity, source detail once per
source, and retained validation code/detail once per failed option. Fixed-width
locations, handles, presence controls, padding, capacity, and allocator overhead
are not payload bytes. These limits are not a peak-memory or RSS guarantee.

Detached input capsules charge schema patterns/depth, supplied definitions/graphs,
canonical key text, and explicit local IDs, but no registered sources, built-in
definitions, omitted default IDs, or resolution records/contributions. On
successful transfer their usage clears; the builder's current limits govern
admission, with already retained canonical text/identities not charged twice.

The [scalar contract](../../specs/wired/config/scalar-resolution.md) and
[composition contract](../../specs/wired/config/composition.md) specify the full
policy, ownership, and accounting laws.

## Layered configuration — `Sparse` and `applyOverlay`

`sparkles.wired.overlay` is a separate last-writer overlay utility. It does not
retain the checked definition/projection graph described above, and its
`@WireCompose` ordering is not `ConfigMerge!(ListOf!P)` composition. Use
`sparkles.wired.config` when equal-priority conflicts, typed collection policies,
or retained provenance are required.

A configuration assembled from several sources — built-in defaults, a user file,
a project file, the command line — needs one distinction the schema type cannot
make: **unset** is not the same as **set to the default value**. Decoding a
document straight into `T` collapses them on the first field that happens to hold
its own default, and a lower-priority layer can then never turn off something
whose default is on.

`Sparse!T` is `T` with every leaf rewritten to `Nullable` and every field marked
`@WireOptional`, so a decoded layer says exactly what its document said and
nothing more. `applyOverlay` folds a stack of those onto a starting value —
`T.init`, so the compiled defaults stay the schema's own field initialisers, with
no second declaration anywhere.

Mark nested sections with `@WireSection` so the transform recurses into them
rather than treating the whole section as one leaf:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_overlay"
    dependency "sparkles:wired" version="*"
+/

import std.stdio : writeln;
import sparkles.wired : fromJSON;
import sparkles.wired.overlay : applyOverlay, Origins, Sparse, WireSection;

@WireSection
struct Pane
{
    bool lineNumbers = true;
    int tabWidth = 4;
}

struct Config
{
    string theme = "default";
    Pane pane;
}

/// What identifies a layer is yours to define; `Origins` is generic over it.
enum Layer { none, user, project }

void main()
{
    // Each layer is a partial document. `{}` is the empty layer.
    auto user = `{"theme":"dark","pane":{"lineNumbers":true}}`.fromJSON!(Sparse!Config).value;
    auto project = `{"pane":{"lineNumbers":false}}`.fromJSON!(Sparse!Config).value;

    Config resolved;                 // starts at the schema's defaults
    Origins!(Config, Layer) origins; // where each field's value came from

    resolved.applyOverlay(origins, user, Layer.user);
    resolved.applyOverlay(origins, project, Layer.project);

    // The project file turned OFF what the user file set to its own default —
    // which only works because "set to true" and "didn't say" stayed distinct.
    writeln(resolved.pane.lineNumbers);
    writeln(resolved.theme);
    writeln(origins.theme);                 // the user file won this one
    writeln(resolved.pane.tabWidth);        // nobody spoke: the schema default
}
```

```ansi
false
dark
user
4
```

Encoding is sparse too, so a layer round-trips without inventing the fields it
never mentioned — which is what lets an application write a user file back out
without baking in values that actually came from the environment or the command
line.

Two more pieces round it out:

- **`@WireCompose`** on a list field makes layers _compose_ rather than override:
  a higher layer's entries are prepended, so they are searched first and the
  lower layers' entries are still there behind them. Useful for search paths,
  where a user wants to shadow a bundled entry without restating the bundle.
- **`mergeSparse`** unions two sparse overlays — where the second speaks it wins,
  everywhere else the first stands — and the result is still sparse. That is the
  shape of "this session's changes applied to what the file already said".

This module has no opinion on where layers come from, what order they stack in,
or whether a malformed one is fatal. Those are policy, they differ per
application, and they belong at the call site that knows.

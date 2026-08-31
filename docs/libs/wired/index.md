# `sparkles:wired` — JSON serialization

`sparkles:wired` maps D values to and from JSON by **structural introspection** —
the mapping is derived from each type at compile time, with no schemas or code
generation, and optional `@Wire*` attributes to tune wire names, casing, and
representation.

Both directions are [`Expected`](../../guidelines/idioms/expected/index.md)-based and
**never throw**: `toJSON` returns an `Expected!(JsonString, JsonError)` and
`fromJSON!T` returns an `Expected!(T, JsonError)`, so a failure is a value you branch on rather
than an exception you catch. The library builds on `std.json` for parsing and
printing.

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
`@WireCase` instead.) Both directions honour the override:

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

## Layered configuration — `Sparse` and `applyOverlay`

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

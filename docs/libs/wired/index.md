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

| Symbol                                                                            | Description                                                                                         |
| --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `writeJSON(value, ref writer)` → `Expected!(void, JsonError)`                     | Stream JSON into any output range — the primary encode form (never throws).                         |
| `toJSON(value)` → `Expected!(JsonString, JsonError)`                              | Encode a value to minified text; a failure is captured as the `JsonError` payload (never throws).   |
| `fromJSON!T(text)` → `Expected!(T, JsonError)`                                    | Parse and decode JSON text; a failure is captured as the `JsonError` payload (never throws).        |
| `readJSONFile!T(string path)` → `Expected!(T, JsonError)`                         | Read, parse, and decode a file; the error identifies the failing stage (read, parse, decode).       |
| `writeJSONFile(value, path, bool compact = false)` → `Expected!(void, JsonError)` | Encode and write to `path` atomically, creating parent directories; `compact` writes a single line. |
| `@WireName("…")`                                                                  | Field / enum-member UDA overriding the JSON wire name.                                              |
| `@WireCase(CaseStyle.…)`                                                          | Recase field / member names (e.g. `snakeCase`, `kebabCase`).                                        |
| `@WireRepr(Repr.…)`                                                               | Serialize an enum by member `name` (default) or underlying `value`.                                 |

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

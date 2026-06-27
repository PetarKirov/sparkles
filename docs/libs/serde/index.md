# `sparkles:serde` — JSON serialization

`sparkles:serde` maps D values to and from JSON by **structural introspection** —
no annotations, schemas, or code generation. Point `fromJSON!T` / `toJSON` at any
supported type and the mapping is derived from the type at compile time.

Deserialization is [`Expected`](../../guidelines/idioms/expected/index.md)-based: a non-throwing
core (`tryFromJSON`) with a thin throwing convenience wrapper (`fromJSON`) on top.
The library builds on `std.json` for parsing and printing, and on `sparkles:base`'s
shared enum-name policy for `@StringRepresentation`.

## Installation

<InstallInstructions pkg="sparkles:serde" />

## Decode JSON — `fromJSON`

`fromJSON!T` reads a `std.json.JSONValue` and reconstructs a `T`, recursing through
arrays, objects, and nested aggregates:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "serde_from_json"
    dependency "sparkles:serde" version="*"
+/
import std.json : parseJSON;
import std.stdio : writeln;
import sparkles.serde : fromJSON;

struct Server
{
    string host;
    ushort port;
    string[] tags;
}

void main()
{
    auto json = parseJSON(`{ "host": "localhost", "port": 8080, "tags": ["web", "edge"] }`);
    Server server = json.fromJSON!Server;
    writeln(server);
}
```

```ansi
Server("localhost", 8080, ["web", "edge"])
```

## Encode values — `toJSON`

`toJSON` is the inverse: it walks a value and produces a `JSONValue`, which
`std.json` renders (object keys are emitted in sorted order):

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "serde_to_json"
    dependency "sparkles:serde" version="*"
+/
import std.stdio : writeln;
import sparkles.serde : toJSON;

struct Server
{
    string host;
    ushort port;
    string[] tags;
}

void main()
{
    auto server = Server("localhost", 8080, ["web", "edge"]);
    writeln(server.toJSON.toPrettyString);
}
```

```ansi
{
    "host": "localhost",
    "port": 8080,
    "tags": [
        "web",
        "edge"
    ]
}
```

## Errors as values — `tryFromJSON`

`fromJSON` throws on malformed input, which is convenient at an application
boundary. Underneath it sits `tryFromJSON`, which **never throws**: it returns an
[`Expected!(T, Exception)`](../../guidelines/idioms/expected/index.md) so you can branch on
success or inspect the failure as data. Decode errors carry a precise message —
including, for enums, the set of names that _would_ have matched:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "serde_errors"
    dependency "sparkles:serde" version="*"
+/
import std.json : parseJSON;
import std.stdio : writeln;
import sparkles.serde : tryFromJSON;

enum Mode { off, on, automatic }

void main()
{
    // tryFromJSON never throws — it returns Expected!(T, Exception).
    auto good = parseJSON(`"on"`).tryFromJSON!Mode;
    writeln("value: ", good.hasValue, " ", good.value);

    auto bad = parseJSON(`"sideways"`).tryFromJSON!Mode;
    writeln("error: ", bad.hasError);
    writeln("       ", bad.error.msg);
}
```

```ansi
value: true on
error: true
       Cannot deserialize Mode from JSON string "sideways" (expected one of: off, on, automatic)
```

## API

| Symbol                                                 | Description                                                                                                                |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `tryFromJSON!T(JSONValue)` → `Expected!(T, Exception)` | Decode without throwing; a failure is captured as the `Exception` payload. The non-throwing foundation of the decode side. |
| `fromJSON!T(JSONValue)` → `T`                          | Decode, rethrowing the captured `Exception` on failure. A thin wrapper over `tryFromJSON`.                                 |
| `toJSON(value)` → `JSONValue`                          | Encode a value into a `JSONValue` (the inverse of `fromJSON`).                                                             |
| `readJSONFile!T(string path)` → `T`                    | Read, parse, and decode a file; throws a styled, contextual `Exception` at the failing stage.                              |
| `writeJSONFile(value, path, bool compact = false)`     | Encode and write to `path`, creating parent directories; `compact` writes a single line instead of pretty JSON.            |
| `@StringRepresentation("…")`                           | Enum-member UDA overriding that member's JSON wire name (re-exported from `sparkles:base`).                                |

## Supported types

The same structural mapping covers a broad range of types, in both directions:

- **Scalars** — `bool`, `string`, `char`, integral and floating-point types
- **Enums** — by member name, or a `@StringRepresentation` override
- **Arrays / slices** — of any supported element type
- **Associative arrays** — keyed by `string` or by an enum
- **Aggregates** (`struct`) — field by field, under their member names
- **`SumType`** — encoded as its active variant; decoding tries each variant in turn
- **`Nullable!T`** — JSON `null` ⇄ the empty value
- **`Ternary`** — JSON `null` / `true` / `false`
- **`SysTime`** — an ISO-8601 extended string
- **`JSONValue`** — passed through unchanged

Every entry below is encoded with `toJSON` and decoded back with `fromJSON`, and the
two agree — the mapping round-trips:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "serde_showcase"
    dependency "sparkles:serde" version="*"
+/
import std.stdio : writefln;
import std.sumtype : SumType;
import std.typecons : Nullable, Ternary;
import sparkles.serde : fromJSON, toJSON;

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
    auto json = value.toJSON;     // encode
    auto back = json.fromJSON!T;  // decode again
    writefln("%-12s %-28s round-trips=%s", label, json.toString, back == value);
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
struct       {"rank":10,"suit":"hearts"}  round-trips=true
SumType      "text"                       round-trips=true
Nullable     7                            round-trips=true
Ternary      null                         round-trips=true
```

## Enum wire names — `@StringRepresentation`

By default an enum member maps to its source name. Annotate it with
`@StringRepresentation` (re-exported from `sparkles:base`) to decouple the JSON
spelling from the D identifier — useful for kebab-case or otherwise non-identifier
wire names. Both directions honour the override:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "serde_enum_names"
    dependency "sparkles:serde" version="*"
+/
import std.json : parseJSON;
import std.stdio : writeln;
import sparkles.serde : fromJSON, toJSON, StringRepresentation;

enum Level
{
    @StringRepresentation("low") low,
    @StringRepresentation("high-priority") high,
}

void main()
{
    writeln(Level.high.toJSON);                                   // custom wire name
    writeln(parseJSON(`"high-priority"`).fromJSON!Level == Level.high);
}
```

```ansi
"high-priority"
true
```

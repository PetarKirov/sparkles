# Read DUB recipes

`dub.sdl` files are SDL, but DUB's own parser has quirks that differ from
the SDL language: how a line continuation inside a string treats the next
line's indentation, how out-of-range clock fields roll over, which zone
spellings it accepts. When you read recipes, parse them the way DUB does.

## Pick a profile

A profile is a compile-time `SdlParserConfig` passed as a template
argument. Three are predefined:

| Profile        | Accepts                                                                   |
| -------------- | ------------------------------------------------------------------------- |
| `sdlFull`      | the full SDL language, deterministically; the default                     |
| `sdlDubCompat` | exactly what DUB's parser at the pinned revision accepts, quirks included |
| `sdlDubRecipe` | `sdlDubCompat`'s syntax, but only string and boolean scalars              |

`sdlDubCompat` is compared against DUB itself on every string literal in
DUB's SDL test code (see the [provenance manifest](../../../specs/wired/sdl/PROVENANCE.md)).
`sdlDubRecipe` suits a reader that knows the recipe schema: recipes only
use strings and booleans, so the numeric and temporal decoders are never
compiled in. A recipe extension carrying a number is then an error;
read with `sdlDubCompat` if you must accept such extensions.

## Decode only what you need, keep the rest

Declare the fields you care about, and give the struct one `@SdlExtra()`
field. It captures every tag, value, and attribute no other field claimed,
in source order, and the writer puts them back where they were. Use
`OwnedSdlExtras` when the result must outlive the parsed text (the text
overloads of `fromSDL` require it); `SdlExtras` borrows from a document you
keep alive.

## Example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "sdl_dub_recipes"
    dependency "sparkles:wired" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : write, writeln;

import sparkles.wired : WireName, WireOptional, WireSkip;
import sparkles.wired.sdl : OwnedSdlExtras, Sdl, SdlAttribute, SdlExtra,
    SdlTagValue, fromSDL, parseSdlDocument, sdlDubCompat, sdlDubRecipe, toSDL;

struct Dependency
{
    @SdlTagValue(0) string name;
    @WireOptional() @WireName!Sdl("version") @SdlAttribute() string version_;
    @WireOptional(WireSkip.whenDefault) @SdlAttribute() bool optional;
}

struct Recipe
{
    string name;
    @WireName!Sdl("dependency") Dependency[] dependencies;
    @SdlExtra() OwnedSdlExtras rest;
}

enum recipe = `name "demo"
description "A demo package"
dependency "vibe-d" version="~>0.10.0"
dependency "silly" version="~>1.1" optional=true
configuration "unittest" {
    targetType "executable"
}
`;

void main()
{
    auto parsed = fromSDL!(Recipe, sdlDubRecipe)(recipe, "dub.sdl");
    assert(parsed.hasValue, parsed.error.toString);
    foreach (dependency; parsed.value.dependencies)
        writeln(dependency.name, " ", dependency.version_,
            dependency.optional ? " (optional)" : "");
    write(toSDL(parsed.value).value[]);

    // A number is valid SDL, and DUB accepts it, but no recipe field uses one.
    writeln(parseSdlDocument!sdlDubCompat("x:build 3\n", "dub.sdl").hasValue);
    writeln(parseSdlDocument!sdlDubRecipe("x:build 3\n", "dub.sdl").error.toString);
}
```

```ansi
vibe-d ~>0.10.0
silly ~>1.1 (optional)
name "demo"
description "A demo package"
dependency "vibe-d" version="~>0.10.0"
dependency "silly" version="~>1.1" optional=true
configuration "unittest" {
    targetType "executable"
}
true
dub.sdl(1:9): Cannot parse SDL: scalar family is disabled by this SDL profile
```

`description` and the `configuration` block were never declared, yet the
written recipe still contains them, in their original positions.
`WireSkip.whenDefault` keeps `optional=false` out of the output, as a hand-written
recipe would.

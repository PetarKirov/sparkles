# Map fields to SDL roles

An SDL tag carries data in three places: positional values, named
attributes, and child tags. Every field of a struct you decode reads
exactly one of them. This page shows how to choose that place, its name,
and its shape. The normative rules are in
[SDL SPEC §5](../../../specs/wired/sdl/SPEC.md#_5-typed-sdl-roles).

| You want                                 | Annotate the field with               |
| ---------------------------------------- | ------------------------------------- |
| the first (or `n`th) value of the tag    | `@SdlTagValue(n)`                     |
| a `key=value` attribute                  | `@SdlAttribute()`                     |
| a child tag (the default when unmarked)  | `@SdlChild()` or nothing              |
| the tag's own name or namespace, as data | `@SdlTagName()`, `@SdlTagNamespace()` |
| everything no other field claimed        | `@SdlExtra()` (see the DUB how-to)    |

## Choose the shape

The field's D type decides how many occurrences it reads:

- **Positional values.** A scalar reads one position. A static array
  `T[n]` reads exactly `n` positions. A dynamic array reads every
  remaining value and must be the last positional field.
- **Attributes.** A scalar reads one attribute. An array reads every
  attribute with that name, in source order (`tag x=1 x=2`).
- **Children.** A scalar reads value 0 of one child. A struct reads one
  child's body. An array of scalars reads the values of every matching
  child (`authors "a" "b"` and a later `authors "c"` give three). An array
  of structs reads one element per matching child. An associative array
  with string or enum keys reads one child per entry, named by its key.

A singular field that appears twice is an error at the second occurrence;
the backend never keeps "the last one".

## Name and namespace

A field's SDL name is its D name, after the format's case policy.
`@WireName!Sdl` overrides it, and a `:` in the override sets the
namespace: `@WireName!Sdl("x:filter")` matches `x:filter`, not `filter`.
`@WireAlias!Sdl` adds names accepted on decode only, for renamed keys.

## Optional fields

Every field is required unless marked. `@WireOptional()` lets a field be
absent, keeping its declared initializer; `@WireDefault!Sdl(value)` does
the same with a value of its own. A `Nullable!T` or `Optional!T` field may
be absent or `null` without either. Any other missing field is an error at
the end of the containing tag.

## Example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "sdl_map_fields"
    dependency "sparkles:wired" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : write, writeln;

import sparkles.wired : WireName;
import sparkles.wired.sdl : Sdl, SdlAttribute, SdlChild, SdlTagName,
    SdlTagValue, fromSDL, toSDL;

struct Point
{
    @SdlTagName() string label;      // the tag's own name is data
    @SdlTagValue(0) int[2] xy;       // exactly two positional values
    @SdlAttribute() string[] tag;    // every `tag=` attribute, in order
}

struct Layer
{
    @SdlTagValue(0) string name;
    @SdlAttribute() @WireName!Sdl("ui:hidden") bool hidden;
    @SdlChild() int[string] limits;  // one child per entry, named by key
}

struct Drawing
{
    string[] authors;                // values of every `authors` tag
    Layer layer;
    @WireName!Sdl("point") Point[] points;
}

void main()
{
    auto drawing = fromSDL!Drawing(`authors "ana" "bo"
authors "cy"
layer "base" ui:hidden=true {
    width 640
    height 480
}
point 1 2 tag="corner"
point 3 4 tag="edge" tag="red"
`);
    assert(drawing.hasValue, drawing.error.toString);
    writeln(drawing.value.authors, " ", drawing.value.layer.limits["width"],
        " ", drawing.value.points[1].tag);
    write(toSDL(drawing.value).value[]);
}
```

```ansi
["ana", "bo", "cy"] 640 ["edge", "red"]
authors "ana" "bo" "cy"
layer "base" ui:hidden=true {
    height 480
    width 640
}
point 1 2 tag="corner"
point 3 4 tag="edge" tag="red"
```

Two details in the output are canonical rewrites, not data loss: the three
authors become one `authors` tag, and the map's children come out sorted by
key. `@SdlTagName` reads `point` back as the label, so the label is also
what the writer emits as each point's tag name.

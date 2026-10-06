# Open a face and map text

Add `sparkles:font` as a DUB dependency. Read the file yourself, by any means
that keeps the bytes alive, and open a face over them:

```d
import std.file : read;
import sparkles.font;

const bytes = cast(const(ubyte)[]) read("DejaVuSansMono.ttf");
auto opened = openFace(bytes);
if (opened.hasError)
    return; // opened.error says what is wrong, in which table and where
const face = opened.value;
assert(face.unitsPerEm == 2048);
```

The face borrows `bytes`: it holds a slice of them, and every slice it hands
back points into them. Keep the buffer alive and unchanged while the face, or
anything read from it, is in use. With `-preview=dip1000` the compiler checks
this in `@safe` code.

## Map characters to glyphs

Build the character map once, then look codepoints up as often as you like:

```d
const map = face.charMap.value;
const glyph = map.glyph('A'); // 0 when the face does not map it

foreach (range; map.ranges)
{
    // every codepoint in [range.first, range.last] maps to a glyph
}
```

`charMap` chooses a subtable the way HarfBuzz does and checks it; each lookup
is then a binary search with no further checking.

## Read names

`name` records decode into storage you provide, after a measuring call:

```d
const names = face.name.value;
foreach (record; names.records)
{
    if (record.hasError || record.value.nameID != 4)
        continue;
    char[256] buffer;
    const text = record.value.decode(buffer[]);
    if (text.hasValue)
    {
        // text.value is a slice of buffer: the full font name
    }
}
```

A record in an encoding the library does not decode returns
`unsupportedCapability`; its raw bytes stay available as `record.value.bytes`.

## Name glyphs

```d
const glyphName = face.glyphName(glyph);
if (glyphName.hasValue && glyphName.value.present)
{
    // glyphName.value.text, for example "A"
}
```

Names come from `post`, or from the `CFF` charset for a glyph `post` does not
name. To name every glyph, build an index first; see the
[reference](../reference/api.md#glyph-names).

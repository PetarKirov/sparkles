# Walk an SDL document without a schema

Sometimes there is no struct to decode into: a linter, a migration script,
or a tool that only looks at a few tags. `parseSdlDocument` gives you the
parsed document itself, in source order, with every value's exact kind and
source position.

## Parse

```d
auto parsed = parseSdlDocument(text, "config.sdl");
if (!parsed.hasValue)
    return writeln(parsed.error.toString);
auto root = parsed.document.root;
```

The document owns everything it parsed, so `text` can be released
afterwards. Every view you take from it (`root`, a child, a value) borrows
from the document and must not outlive it; under `-preview=dip1000` the
compiler enforces that.

## Visit tags, values, and attributes

A node has three ranges, each in source order:

- `byValue` yields `SdlScalar`s. Check `kind` before reading the payload
  (`stringValue`, `integer`, `boolean`, `date`, …): an `int` and a `long`
  are different kinds, as are `1F`, `1D`, and `1BD`.
- `byAttribute` yields views with `qualifiedName` and `value`. Repeated
  attributes are all there; nothing is collapsed.
- `byChild` yields child nodes. Repeated tags and tags from different
  namespaces stay separate and in order.

`byChild` and `byAttribute` also take a name. `byChild(SdlQualifiedName("",
"dependency"))` yields every `dependency` child, and
`byChild(SdlNameQuery.anyNamespace("filter"))` yields `filter` in any
namespace.

Each node, value, and attribute has a `span`, a byte range of the document's
own copy of the text (`parsed.document.source`). `parsed.document.position`
turns an offset into a line and column, so a tool can point at the exact
place it is talking about.

## Example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "sdl_walk"
    dependency "sparkles:wired" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

import sparkles.wired.sdl : SdlNameQuery, SdlQualifiedName, SdlScalarKind,
    parseSdlDocument;

enum text = `dependency "a" version="1.0"
x:filter "debug"
dependency "b" version="2.0" version="2.1"
filter "release"
`;

void main()
{
    auto parsed = parseSdlDocument(text, "dub.sdl");
    assert(parsed.hasValue, parsed.error.toString);
    auto root = parsed.document.root;

    foreach (dependency; root.byChild(SdlQualifiedName("", "dependency")))
    {
        const name = dependency.byValue.front;
        assert(name.kind == SdlScalarKind.string_);
        foreach (attribute; dependency.byAttribute)
            writeln(name.stringValue, " ", attribute.qualifiedName.localName,
                "=", attribute.value.stringValue, " at line ",
                parsed.document.position(attribute.span.startOffset).line);
    }
    foreach (filter; root.byChild(SdlNameQuery.anyNamespace("filter")))
        writeln("filter ", filter.byValue.front.stringValue, " in namespace '",
            filter.qualifiedName.namespace_, "'");
}
```

```ansi
a version=1.0 at line 1
b version=2.0 at line 3
b version=2.1 at line 3
filter debug in namespace 'x'
filter release in namespace ''
```

To write a document back, pass it to `writeSdlDocument` with any output
range; the result is the same canonical form `toSDL` produces.

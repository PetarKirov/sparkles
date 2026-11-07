# Select SDL nodes with a path

Nested `byChild` loops get long when a tool wants "every `dependency` inside
a `configuration` that pins a version". A selector says it in one line: a
[DQL path](../../../specs/dql/SPEC.md#_2-1-path-addressing-grammar) picks
the nodes, and an optional [DQL](../../../specs/dql/SPEC.md) filter keeps
the ones that match. The editor takes the result directly, so a lossless
edit of every match is one call.

Add `dependency "sparkles:wired-sdl-select"` and import
`sparkles.wired.sdl.select`; plain `sparkles:wired` does not build DQL.

## Select by path

`SdlPath.parse` checks a path and borrows it; `nodes(start)` walks the
selection lazily, in document order, without allocating:

```d
auto path = SdlPath.parse("configuration.dependency");
foreach (dependency; path.value.nodes(document.root))
    writeln(dependency.byValue.front.stringValue);
```

Each segment is a child step that keeps the children of that name; `ns:name`
names a namespaced tag. An index keeps only the k-th match, counted from
zero under each parent: `configuration[1].dependency` reads the second
configuration's dependencies.

SDL names may hold `.`, which a plain segment cannot spell. Quote such a
name as a JSON string in brackets: `build["my.tool"].dependency`, or
`["ns:my.tool"]` for a namespaced one. `writeDqlSegment` from
`sparkles.dql.path` prints a name that way when it needs to, so a path you
build from names always parses back.

`attributes(start)` reads the last segment as an attribute name instead:
`dependency.path` yields the `path` attribute of every root `dependency`.

A malformed path is an error with its byte offset, never a partial
selection.

## Filter with DQL

`SdlSelector.parse(path, filter)` adds a filter, evaluated with each
selected node as its subject. Inside the filter:

| Path in the filter              | Means                                           |
| ------------------------------- | ----------------------------------------------- |
| `version`                       | the node's first `version` attribute            |
| `values[0]`                     | its first value                                 |
| `targetType.values[0]`          | the first value of its first `targetType` child |
| `dependency[1].version`         | the `version` of its second `dependency` child  |
| `dflags` (alone, as a category) | whether it has a `dflags` child                 |
| `x == null`                     | `x` is absent or SDL `null`                     |
| `["dflags.ldc"] == null`        | it has no `dflags.ldc` attribute                |

Strings, booleans, integers and floats compare as themselves; `&&`, `||`,
`!`, parentheses, `globMatch`, `regexMatch` and `fuzzyMatch` work as in any
DQL query. A filter on an attribute selection tests the node that holds the
attributes.

A selector is a value: `SdlSelector.parse(…).value` binds to a variable,
and copies share the parsed filter. Its ranges borrow it, so keep the
selector in a variable while you iterate: a `foreach` over
`SdlSelector.parse(…).value.nodes(root)` outlives its temporary.

## Edit what you selected

`remove`, `removeAttribute`, `replaceAttribute` and `setAttribute` accept a
selection and apply the operation to each target, exactly as a loop of
single calls would.

A selection is an ordinary range, so a predicate the filter cannot state,
such as a byte range, narrows it with `filter`. In the repository,
`apps/ci/tools/standardize-build-settings.d` removes stale build types that
way:

```d
auto stale = SdlSelector.parse("buildType", `values[1] == null && values[0] == "checked"`).value;
editor.remove(stale.nodes(root).filter!(node => !inRegion(node)));
```

## Example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "sdl_select"
    dependency "sparkles:wired" version="*"
    dependency "sparkles:wired-sdl-select" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.experimental.allocator.mallocator : Mallocator;
import std.stdio : write, writeln;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.wired.sdl : parseSdlDocument, SdlQualifiedName, SdlScalar,
    sdlEditor;
import sparkles.wired.sdl.select : SdlPath, SdlSelector;

enum text = `name "app"
dependency "sparkles:base" version="*"
dependency "silly" version="~>1.1"
configuration "unittest" {
    dependency "sparkles:test-utils" version="*" // in-tree
}
`;

void main()
{
    auto parsed = parseSdlDocument(text, "dub.sdl");
    assert(parsed.hasValue, parsed.error.toString);
    auto root = parsed.document.root;

    foreach (node; SdlPath.parse("configuration.dependency").value.nodes(root))
        writeln("configuration dependency: ", node.byValue.front.stringValue);

    // Every in-tree dependency, at the root or in a configuration, points
    // at the checkout instead of the registry.
    auto editor = sdlEditor(parsed.document, text);
    foreach (path; ["dependency.version", "configuration.dependency.version"])
    {
        auto inTree = SdlSelector.parse(path,
            "globMatch(values[0], `sparkles:*`) && version == `*`").value;
        editor.replaceAttribute(inTree.attributes(root),
            SdlQualifiedName(null, "path"), SdlScalar("../.."));
    }
    UniqueBuffer!char output;
    Mallocator allocator;
    const written = editor.write(output, allocator);
    assert(!written.hasError, written.hasError ? written.error.toString : "");
    write(output[]);
}
```

```ansi
configuration dependency: sparkles:test-utils
name "app"
dependency "sparkles:base" path="../.."
dependency "silly" version="~>1.1"
configuration "unittest" {
    dependency "sparkles:test-utils" path="../.." // in-tree
}
```

The comment, the layout and the pinned `silly` survive; only the two
attributes the selectors named changed. See
[editing §3.2](../../../specs/wired/sdl/editing.md#3-2-path-selection) for
the full contract.

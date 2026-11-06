/** Path selection over a parsed SDL document (editing §3.2, SDS1–SDS5).

A path in the DQL path grammar (`configuration.dependency`,
`configuration[1].dependency`) selects nodes by name-and-index child steps;
read as an attribute selection, its last segment names attributes instead
(`dependency.path`). An optional DQL filter narrows the selection, evaluated
by DQL's own evaluator with each selected node as its subject through
$(LREF SdlNodeResolver):

---
auto selector = SdlSelector.parse("dependency.path", "path == `../..`").value;
foreach (attribute; selector.attributes(document.root))
    editor.replaceAttribute(attribute, name, SdlScalar(root));
---

$(LREF SdlPath) borrows a path and selects without a filter or any
allocation; $(LREF SdlSelector) owns its path, its DQL engine and its filter.
*/
module sparkles.wired.sdl.select;

import core.lifetime : move;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.expected : Expected, err, ok;
import sparkles.dql.engine : DqlEngine, DqlParseError;
import sparkles.dql.ast : DqlFilter;
import sparkles.dql.eval : evalDql;
import sparkles.dql.parser : parseDql;
import sparkles.dql.path : DqlPathStepKind, DqlPathSteps, dqlPathSteps, validateDqlPath;
import sparkles.wired.sdl.document : SdlAttributeRange, SdlAttributeView, SdlChildRange,
    SdlNode, SdlQualifiedName, SdlScalar, SdlScalarKind;

/// The most steps a selection path may have.
enum size_t sdlSelectorMaxSteps = 16;

/// One step of an SDL path: a qualified name and an optional index.
private struct SdlStep
{
    SdlQualifiedName name;
    bool indexed;
    size_t index;
}

/// `segment` as a qualified name: split at its first `:`.
private SdlQualifiedName qualifiedNameOf(return scope const(char)[] segment)
    @safe pure nothrow @nogc
{
    foreach (i, c; segment)
        if (c == ':')
            return SdlQualifiedName(segment[0 .. i], segment[i + 1 .. $]);
    return SdlQualifiedName(null, segment);
}

/// Reads the next step of non-empty `steps` — a member and the index after
/// it, if any. The path has passed $(LREF checkSdlPath).
private SdlStep nextStep(ref return scope DqlPathSteps steps) @safe pure nothrow @nogc
in (!steps.empty)
{
    SdlStep step;
    step.name = qualifiedNameOf(steps.front.name);
    steps.popFront();
    if (!steps.empty && steps.front.kind == DqlPathStepKind.index)
    {
        step.indexed = true;
        step.index = steps.front.index;
        steps.popFront();
    }
    return step;
}

/// Step `depth` of `path`.
private SdlStep stepAt(return scope const(char)[] path, size_t depth) @safe pure nothrow @nogc
{
    auto steps = dqlPathSteps(path);
    foreach (_; 0 .. depth)
        nextStep(steps);
    return nextStep(steps);
}

/** The number of SDL steps in `path` — a DQL path whose every index follows
a segment — or its first fault, at its byte offset. */
private Expected!(size_t, DqlParseError) checkSdlPath(scope const(char)[] path)
    @safe pure nothrow @nogc
{
    const valid = validateDqlPath(path);
    if (valid.hasError)
        return err!size_t(DqlParseError(valid.error.message, valid.error.offset,
            valid.error.length));
    size_t count;
    bool afterIndex;
    foreach (step; dqlPathSteps(path))
    {
        if (step.kind == DqlPathStepKind.index)
        {
            if (afterIndex)
                return err!size_t(DqlParseError("an SDL step takes one index", step.offset, 1));
            afterIndex = true;
            continue;
        }
        afterIndex = false;
        if (++count > sdlSelectorMaxSteps)
            return err!size_t(DqlParseError("a selection path has at most 16 steps",
                step.offset, step.name.length));
    }
    return ok!DqlParseError(count);
}

/** A validated selection path (SDS1) that borrows its text: it selects
nodes or attributes without a filter, allocating nothing (SDS4). */
struct SdlPath
{
    private const(char)[] _text;
    private size_t _steps;

    /// Validates `text`; the error's offset is a byte offset into it.
    static Expected!(SdlPath, DqlParseError) parse(return scope const(char)[] text)
        @safe pure nothrow @nogc
    {
        const steps = checkSdlPath(text);
        if (steps.hasError)
            return err!SdlPath(DqlParseError(steps.error.message, steps.error.offset,
                steps.error.length));
        SdlPath path;
        path._text = text;
        path._steps = steps.value;
        return ok!DqlParseError(path);
    }

    /// The path's text.
    const(char)[] text() const return scope @safe pure nothrow @nogc => _text;

    /// The number of name-and-index steps.
    size_t length() const scope @safe pure nothrow @nogc => _steps;

    /// The nodes the path selects below `start` (SDS2), in document order.
    SdlNodeSelection nodes(return scope SdlNode start) const return scope
        @safe pure nothrow @nogc
        => SdlNodeSelection(_text, _steps, start);

    /** The attributes the path selects below `start`: its last step names
    attributes of the nodes the others select (SDS2), in document order. */
    SdlAttributeSelection!SdlNodeSelection attributes(return scope SdlNode start) const
        return scope @safe pure nothrow @nogc
        => SdlAttributeSelection!SdlNodeSelection(SdlNodeSelection(_text, _steps - 1, start),
            stepAt(_text, _steps - 1));
}

/** Forward range over the nodes `steps` child steps of a path reach from a
start node, in document order (SDS2). With no steps, the start node itself. */
struct SdlNodeSelection
{
    private const(char)[] _path;
    private size_t _steps;
    private size_t _depth;
    private SdlChildRange[sdlSelectorMaxSteps] _levels;
    private size_t[sdlSelectorMaxSteps] _matched;
    private SdlNode _front;
    private bool _empty;

    private this(return scope const(char)[] path, size_t steps, return scope SdlNode start)
        @safe pure nothrow @nogc
    in (steps <= sdlSelectorMaxSteps)
    {
        _path = path;
        _steps = steps;
        if (steps == 0)
        {
            _front = start;
            return;
        }
        _levels[0] = start.byChild;
        _depth = 1;
        advance();
    }

    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _empty;
    /// ditto
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => _front;
    /// ditto
    void popFront() scope @safe pure nothrow @nogc
    in (!empty)
    {
        if (_steps == 0)
            _empty = true;
        else
            advance();
    }
    /// ditto
    SdlNodeSelection save() const return scope @safe pure nothrow @nogc => this;

    // Depth-first: each level keeps the children its step names, so the
    // nodes reached at the last level arrive in document order. The views
    // stored back into the levels refer to the document's core, which
    // outlives this selection; dip1000 sees only the scoped loop variable.
    private void advance() scope @safe pure nothrow @nogc
    {
        while (_depth > 0)
        {
            const level = _depth - 1;
            const step = stepAt(_path, level);
            bool descended;
            while (!_levels[level].empty)
            {
                const child = _levels[level].front;
                _levels[level].popFront();
                if (child.qualifiedName != step.name)
                    continue;
                const ordinal = _matched[level]++;
                if (step.indexed)
                {
                    if (ordinal != step.index)
                        continue;
                    _levels[level] = SdlChildRange.init; // no later match
                }
                if (_depth == _steps)
                {
                    () @trusted { _front = child; }();
                    return;
                }
                () @trusted { _levels[_depth] = child.byChild; }();
                _matched[_depth] = 0;
                _depth++;
                descended = true;
                break;
            }
            if (!descended)
                _depth--;
        }
        _empty = true;
    }
}

/** Forward range over the attributes a step names, of each node `Nodes`
yields (SDS2), in document order. */
struct SdlAttributeSelection(Nodes)
{
    private Nodes _nodes;
    private SdlStep _step;
    private SdlAttributeRange _attributes;
    private size_t _matched;
    private SdlAttributeView _front;
    private bool _empty;

    private this(Nodes nodes, SdlStep step)
    {
        _nodes = nodes;
        _step = step;
        advance();
    }

    /// Forward-range primitives.
    bool empty() const scope => _empty;
    /// ditto
    SdlAttributeView front() const return scope
    in (!empty) => _front;
    /// ditto
    void popFront() scope
    in (!empty) { advance(); }

    static if (is(typeof(Nodes.init.save)))
    {
        /// ditto
        typeof(this) save() => this;
    }

    // As in `SdlNodeSelection.advance`, the stored views refer to the
    // document's core, which outlives the selection.
    private void advance() scope
    {
        while (true)
        {
            while (!_attributes.empty)
            {
                const attribute = _attributes.front;
                _attributes.popFront();
                if (attribute.qualifiedName != _step.name)
                    continue;
                if (_step.indexed && _matched++ != _step.index)
                    continue;
                () @trusted { _front = attribute; }();
                return;
            }
            if (_nodes.empty)
            {
                _empty = true;
                return;
            }
            const node = _nodes.front;
            () @trusted { _attributes = node.byAttribute; }();
            _matched = 0;
            _nodes.popFront();
        }
    }
}

/// Which input of $(LREF SdlSelector.parse) a fault is in.
enum SdlSelectorPart : ubyte
{
    path,   /// The selection path.
    filter, /// The DQL filter expression.
}

/// A fault in a selector: the part, and DQL's error at an offset into it.
struct SdlSelectorError
{
    SdlSelectorPart part; /// The input that holds the fault.
    DqlParseError error;  /// The fault, at a byte offset into that input.
}

/** A selection path and an optional DQL filter (SDS3), owning both and the
DQL engine the filter lives in. The ranges it returns refer to it, so it
must stay in place while they are used. */
struct SdlSelector
{
    private UniqueBuffer!char _path;
    private size_t _steps;
    private DqlEngine _engine;
    private DqlFilter _filter;

    /** Validates `path` and parses `filter`, which may be empty to keep
    every node; a fault names its part and its offset there. */
    static Expected!(SdlSelector, SdlSelectorError) parse(scope const(char)[] path,
        scope const(char)[] filter = null) @safe
    {
        const steps = checkSdlPath(path);
        if (steps.hasError)
            return err!SdlSelector(SdlSelectorError(SdlSelectorPart.path, steps.error));
        SdlSelector selector;
        selector._path ~= path;
        selector._steps = steps.value;
        auto parsed = parseDql(selector._engine, filter);
        if (parsed.hasError)
            return err!SdlSelector(SdlSelectorError(SdlSelectorPart.filter, parsed.error));
        selector._filter = move(parsed.value);
        return ok!SdlSelectorError(move(selector));
    }

    /// The selection path, borrowed from this selector.
    SdlPath path() const return scope @safe pure nothrow @nogc
    {
        SdlPath result;
        result._text = _path[];
        result._steps = _steps;
        return result;
    }

    /// Whether `node` passes the filter (an empty filter passes everything).
    bool accepts(scope SdlNode node) @safe
        => evalDql(_engine, _filter, SdlNodeResolver(node));

    /// The nodes the path selects below `start` that pass the filter.
    SdlSelectedNodes nodes(return scope SdlNode start) return @safe
        => SdlSelectedNodes(&this, SdlNodeSelection(_path[], _steps, start));

    /** The attributes the path selects below `start`, of the nodes that
    pass the filter: the filter's subject is the node holding them. */
    SdlAttributeSelection!SdlSelectedNodes attributes(return scope SdlNode start)
        return @safe
        => SdlAttributeSelection!SdlSelectedNodes(
            SdlSelectedNodes(&this, SdlNodeSelection(_path[], _steps - 1, start)),
            stepAt(_path[], _steps - 1));
}

/// Input range over a selection's nodes that pass its selector's filter.
struct SdlSelectedNodes
{
    private SdlSelector* _selector;
    private SdlNodeSelection _nodes;

    private this(return scope SdlSelector* selector, return scope SdlNodeSelection nodes)
        @safe
    {
        _selector = selector;
        _nodes = nodes;
        skip();
    }

    /// Input-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _nodes.empty;
    /// ditto
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => _nodes.front;
    /// ditto
    void popFront() scope @safe
    in (!empty)
    {
        _nodes.popFront();
        skip();
    }

    private void skip() scope @safe
    {
        while (!_nodes.empty && !_selector.accepts(_nodes.front))
            _nodes.popFront();
    }
}

/** A DQL host resolver over one SDL node (SDS3). A path is zero or more
child steps, each taking the first child of its name or, with `[k]`, the
k-th, then a leaf: `values[i]`, the i-th value, or an attribute name, its
first attribute of that name. A category holds when a child exists at the
path. Strings resolve as text, booleans as `bool`, integers as `long`, floats
and decimals as `double`; an absent target or SDL `null` is null. */
struct SdlNodeResolver
{
    SdlNode node; /// The subject.

    /// The kind of target a path reaches.
    private enum Reach : ubyte { malformed, absent, scalar }

    private Reach reach(scope const(char)[] path, out SdlScalar scalar) const scope
        @safe pure nothrow @nogc
    {
        if (checkSdlPath(path).hasError)
            return Reach.malformed;
        auto steps = dqlPathSteps(path);
        SdlNode current = node;
        SdlStep step = nextStep(steps);
        while (!steps.empty)
        {
            if (!childAt(current, step, current))
                return Reach.absent;
            step = nextStep(steps);
        }
        // The scalars live in the document, which outlives the evaluation
        // that asked; dip1000 sees only the borrowed views.
        if (step.name == SdlQualifiedName(null, "values"))
        {
            if (!step.indexed)
                return Reach.malformed;
            if (step.index >= current.valueCount)
                return Reach.absent;
            () @trusted { scalar = current.valueAt(step.index); }();
            return Reach.scalar;
        }
        if (step.indexed)
            return Reach.malformed;
        foreach (attribute; current.byAttribute(step.name))
        {
            () @trusted { scalar = attribute.value; }();
            return Reach.scalar;
        }
        return Reach.absent;
    }

    // The child `step` names under `parent`: the first, or the indexed one.
    private static bool childAt(scope SdlNode parent, in SdlStep step, out SdlNode child)
        @safe pure nothrow @nogc
    {
        size_t ordinal;
        foreach (candidate; parent.byChild(step.name))
            if (ordinal++ == (step.indexed ? step.index : 0))
            {
                // The views refer to the document's core, which outlives
                // the resolver; dip1000 sees only the loop variable.
                () @trusted { child = candidate; }();
                return true;
            }
        return false;
    }

    /// Whether a child exists at `path` (a DQL category).
    bool resolveCategory(scope const(char)[] path) const scope @safe pure nothrow @nogc
    {
        if (checkSdlPath(path).hasError)
            return false;
        auto steps = dqlPathSteps(path);
        SdlNode current = node;
        while (!steps.empty)
            if (!childAt(current, nextStep(steps), current))
                return false;
        return true;
    }

    /// Whether `path` is well formed; `isNull` when it reaches nothing or
    /// SDL `null`.
    bool resolveIsNull(scope const(char)[] path, out bool isNull) const scope
        @safe pure nothrow @nogc
    {
        SdlScalar scalar;
        final switch (reach(path, scalar))
        {
            case Reach.malformed: return false;
            case Reach.absent: isNull = true; return true;
            case Reach.scalar: isNull = scalar.kind == SdlScalarKind.null_; return true;
        }
    }

    /// A string value at `path`.
    bool resolveString(scope const(char)[] path, out const(char)[] value) const scope
        @safe pure nothrow @nogc
    {
        SdlScalar scalar;
        if (reach(path, scalar) != Reach.scalar || scalar.kind != SdlScalarKind.string_)
            return false;
        // The text lives in the document, which outlives the evaluation.
        () @trusted { value = scalar.stringValue; }();
        return true;
    }

    /// An integer value at `path`.
    bool resolveInt(scope const(char)[] path, out long value) const scope
        @safe pure nothrow @nogc
    {
        SdlScalar scalar;
        if (reach(path, scalar) != Reach.scalar)
            return false;
        if (scalar.kind == SdlScalarKind.integer)
            value = scalar.integer;
        else if (scalar.kind == SdlScalarKind.longInteger)
            value = scalar.longInteger;
        else
            return false;
        return true;
    }

    /// A float or decimal value at `path`.
    bool resolveNumber(scope const(char)[] path, out double value) const scope
        @safe pure nothrow @nogc
    {
        SdlScalar scalar;
        if (reach(path, scalar) != Reach.scalar)
            return false;
        if (scalar.kind == SdlScalarKind.float_)
            value = scalar.floatValue;
        else if (scalar.kind == SdlScalarKind.double_)
            value = scalar.doubleValue;
        else if (scalar.kind == SdlScalarKind.decimal)
            value = cast(double) scalar.decimalValue;
        else
            return false;
        return true;
    }

    /// A boolean value at `path`.
    bool resolveBool(scope const(char)[] path, out bool value) const scope
        @safe pure nothrow @nogc
    {
        SdlScalar scalar;
        if (reach(path, scalar) != Reach.scalar || scalar.kind != SdlScalarKind.boolean)
            return false;
        value = scalar.boolean;
        return true;
    }
}

version (unittest)
{
    import sparkles.wired.sdl.config : sdlFull;
    import sparkles.wired.sdl.reader : parseSdlDocument;

    private enum recipe = `name "app"
dependency "sparkles:base" path="../.."
dependency "optional" version="~>1.3.0"
configuration "library" {
    targetType "library"
}
configuration "unittest" {
    dependency "sparkles:test-utils" path="../.."
    dependency "silly" version="*" optional=true
    dflags "-checkaction=context"
}
x:note 3 enabled=false
`;
}

///
@("sdl.select.SdlPath.parse.faults")
@safe nothrow @nogc
unittest
{
    assert(SdlPath.parse("configuration[1].dependency").value.length == 2);
    assert(SdlPath.parse("x:note").value.length == 1);
    assert(SdlPath.parse("a..b").error.offset == 2);
    assert(SdlPath.parse("a[0][1]").error.offset == 4);
    assert(SdlPath.parse("[0]").error.offset == 0);
    assert(SdlPath.parse("").hasError);
    assert(SdlPath.parse("a.a.a.a.a.a.a.a.a.a.a.a.a.a.a.a.a").hasError);
}

///
@("sdl.select.SdlPath.nodes.steps")
@safe unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : map;

    auto parsed = parseSdlDocument!sdlFull(recipe);
    const root = parsed.document.root;
    auto names(string path)
        => SdlPath.parse(path).value.nodes(root).map!(n => n.byValue.front.stringValue);

    assert(names("dependency").equal(["sparkles:base", "optional"]));
    assert(names("dependency[1]").equal(["optional"]));
    assert(names("dependency[2]").empty);
    assert(names("configuration.dependency").equal(["sparkles:test-utils", "silly"]));
    assert(names("configuration[1].dependency[0]").equal(["sparkles:test-utils"]));
    assert(names("configuration[0].dependency").empty);
    assert(SdlPath.parse("x:note").value.nodes(root).front.byValue.front.integer == 3);
    assert(SdlPath.parse("note").value.nodes(root).empty);
}

///
@("sdl.select.SdlPath.attributes.steps")
@safe unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : map;

    auto parsed = parseSdlDocument!sdlFull(recipe);
    const root = parsed.document.root;
    auto values(string path)
        => SdlPath.parse(path).value.attributes(root).map!(a => a.value.stringValue);

    assert(values("dependency.path").equal(["../.."]));
    assert(values("configuration.dependency.version").equal(["*"]));
    assert(values("configuration.dependency.path[0]").equal(["../.."]));
    assert(SdlPath.parse("x:note.enabled").value.attributes(root).front.value.boolean == false);
}

///
@("sdl.select.SdlPath.nodes.nogc")
@safe pure nothrow @nogc
unittest
{
    auto parsed = parseSdlDocument!sdlFull(recipe);
    const path = SdlPath.parse("configuration.dependency");
    size_t count;
    foreach (node; path.value.nodes(parsed.document.root))
        count += node.attributeCount;
    assert(count == 3);
}

///
@("sdl.select.SdlSelector.filter")
@safe unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : map;

    auto parsed = parseSdlDocument!sdlFull(recipe);
    const root = parsed.document.root;
    auto names(string path, string filter)
    {
        auto selector = SdlSelector.parse(path, filter);
        assert(selector.hasValue, filter);
        string[] result;
        foreach (node; selector.value.nodes(root))
            result ~= node.byValue.front.stringValue.idup;
        return result;
    }

    assert(names("dependency", "path != null") == ["sparkles:base"]);
    assert(names("dependency", "version == `~>1.3.0`") == ["optional"]);
    assert(names("configuration.dependency", "optional == true") == ["silly"]);
    assert(names("configuration.dependency", "!optional == true") == ["sparkles:test-utils"]);
    assert(names("dependency", "values[0] == optional || path == `../..`")
        == ["sparkles:base", "optional"]);
    assert(names("configuration", "dependency") == ["unittest"]);
    assert(names("configuration", "targetType.values[0] == library") == ["library"]);
    assert(names("configuration", "dependency[1].version == null") == ["library"]);
    assert(names("dependency", "globMatch(values[0], `sparkles:*`)") == ["sparkles:base"]);
    assert(names("dependency", "values == null").length == 0); // malformed leaf
    auto note = SdlSelector.parse("x:note", "values[0] > 2 && enabled == false");
    assert(!note.value.nodes(root).empty);
    auto big = SdlSelector.parse("x:note", "values[0] > 3");
    assert(big.value.nodes(root).empty);

    auto attributes = SdlSelector.parse("configuration.dependency.version", "optional == true");
    assert(attributes.value.attributes(root).map!(a => a.value.stringValue).equal(["*"]));

    const bad = SdlSelector.parse("dependency", "path ==");
    assert(bad.hasError && bad.error.part == SdlSelectorPart.filter);
    assert(SdlSelector.parse("a.", "").error.part == SdlSelectorPart.path);
}

///
@("sdl.select.editor.rangeOverloads")
@safe unittest
{
    import std.experimental.allocator.mallocator : Mallocator;
    import sparkles.base.buffer : UniqueBuffer;
    import sparkles.wired.sdl.editor : sdlEditor;
    import sparkles.wired.sdl.error : SdlErrorCode;

    auto parsed = parseSdlDocument!sdlFull(recipe);
    const root = parsed.document.root;
    Mallocator allocator;
    const name = SdlQualifiedName(null, "path");

    // Each operation over a selection writes what the loop of single calls
    // writes (SDS5).
    string written(E)(ref E editor)
    {
        UniqueBuffer!char output;
        const result = editor.write(output, allocator);
        assert(!result.hasError);
        return output[].idup;
    }
    auto byRange = sdlEditor(parsed.document, recipe);
    auto byLoop = sdlEditor(parsed.document, recipe);
    auto dependencies = SdlSelector.parse("configuration.dependency", "version != null");
    byRange.remove(dependencies.value.nodes(root));
    foreach (node; dependencies.value.nodes(root))
        byLoop.remove(node);
    const paths = SdlPath.parse("dependency.path").value;
    byRange.replaceAttribute(paths.attributes(root), name, SdlScalar("../../.."));
    foreach (attribute; paths.attributes(root))
        byLoop.replaceAttribute(attribute, name, SdlScalar("../../.."));
    const configurations = SdlPath.parse("configuration").value;
    byRange.setAttribute(configurations.nodes(root), name, SdlScalar("x"));
    foreach (node; configurations.nodes(root))
        byLoop.setAttribute(node, name, SdlScalar("x"));
    const enabled = SdlPath.parse("x:note.enabled").value;
    byRange.removeAttribute(enabled.attributes(root));
    foreach (attribute; enabled.attributes(root))
        byLoop.removeAttribute(attribute);
    const expected = written(byLoop);
    assert(written(byRange) == expected);
    assert(expected != recipe);

    // A node inside a removed one overlaps it.
    auto nested = sdlEditor(parsed.document, recipe);
    nested.remove(SdlPath.parse("configuration").value.nodes(root));
    nested.remove(SdlPath.parse("configuration.dependency").value.nodes(root));
    UniqueBuffer!char output;
    const conflict = nested.write(output, allocator);
    assert(conflict.hasError && conflict.error.code == SdlErrorCode.editConflict);
}

version (unittest)
{
    // The segment spelling of `name`, or null when a step cannot spell it.
    private string segmentOf(SdlQualifiedName name)
    {
        import sparkles.dql.path : isDqlSegmentByte;

        const text = name.namespace_.length
            ? (name.namespace_ ~ ":" ~ name.localName).idup : name.localName.idup;
        foreach (char c; text)
            if (!isDqlSegmentByte(c))
                return null;
        return text.length ? text : null;
    }

    // Every name path below `node` to `depth` steps, in first-seen order.
    private void namePaths(SdlNode node, string prefix, size_t depth, ref string[] paths)
    {
        import std.algorithm.searching : canFind;

        if (depth == 0)
            return;
        foreach (child; node.byChild)
        {
            const segment = segmentOf(child.qualifiedName);
            if (segment is null)
                continue;
            const path = prefix.length ? prefix ~ "." ~ segment : segment;
            if (!paths.canFind(path))
                paths ~= path;
            namePaths(child, path, depth - 1, paths);
        }
    }

    // The reference selection: nested loops over the children, one per step.
    private void referenceNodes(SdlNode node, const(SdlStep)[] steps, ref size_t[] cells)
    {
        if (steps.length == 0)
        {
            cells ~= node.cellIndex;
            return;
        }
        size_t ordinal;
        foreach (child; node.byChild(steps[0].name))
            if (!steps[0].indexed || ordinal++ == steps[0].index)
                referenceNodes(child, steps[1 .. $], cells);
    }

    private SdlStep[] stepsOf(string path)
    {
        SdlStep[] steps;
        auto reader = dqlPathSteps(path);
        while (!reader.empty)
            steps ~= nextStep(reader);
        return steps;
    }

    // `path` with `[index]` after its step `at`.
    private string indexed(string path, size_t at, size_t index)
    {
        import std.array : join, split;
        import std.conv : to;

        auto parts = path.split(".");
        parts[at] ~= "[" ~ index.to!string ~ "]";
        return parts.join(".");
    }
}

@("sdl.select.properties.repositoryRecipes.paths")
@system unittest
{
    import std.file : readText;
    import sparkles.wired.sdl.test_corpus : parseRecipe, repositoryRecipes;

    const files = repositoryRecipes();
    assert(files.length > 100, "the repository walk found too few recipes");
    size_t nodePaths, attributePaths;
    foreach (file; files)
    {
        const host = readText(file);
        auto parsed = parseRecipe(host, file);
        if (!parsed.hasValue)
            continue;
        auto root = parsed.document.root;
        string[] paths;
        namePaths(root, null, 3, paths);
        foreach (base; paths)
        {
            const steps = stepsOf(base).length;
            string[] variants = [base, indexed(base, steps - 1, 0), indexed(base, steps - 1, 1)];
            if (steps > 1)
                variants ~= indexed(base, 0, 1);
            foreach (path; variants)
            {
                size_t[] expected, actual;
                referenceNodes(root, stepsOf(path), expected);
                foreach (node; SdlPath.parse(path).value.nodes(root))
                    actual ~= node.cellIndex;
                assert(actual == expected, file ~ ": " ~ path);
                nodePaths++;
            }

            // Attribute selections: every attribute name on the nodes `base`
            // selects, plain and with an index, against nested loops.
            if (steps >= 3)
                continue;
            foreach (node; SdlPath.parse(base).value.nodes(root))
                foreach (attribute; node.byAttribute)
                {
                    const segment = segmentOf(attribute.qualifiedName);
                    if (segment is null)
                        continue;
                    foreach (path; [base ~ "." ~ segment, base ~ "." ~ segment ~ "[0]"])
                    {
                        const leaf = stepsOf(path)[$ - 1];
                        size_t[] expected, actual;
                        foreach (owner; SdlPath.parse(base).value.nodes(root))
                        {
                            size_t ordinal;
                            foreach (candidate; owner.byAttribute(leaf.name))
                                if (!leaf.indexed || ordinal++ == leaf.index)
                                    expected ~= candidate.cellIndex;
                        }
                        foreach (selected; SdlPath.parse(path).value.attributes(root))
                            actual ~= selected.cellIndex;
                        assert(actual == expected, file ~ ": " ~ path);
                        attributePaths++;
                    }
                }
        }
    }
    assert(nodePaths > 1000 && attributePaths > 1000, "too few selections were compared");
}

@("sdl.select.properties.repositoryRecipes.filters")
@system unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.file : readText;
    import sparkles.wired.sdl.test_corpus : parseRecipe, repositoryRecipes;

    static bool isText(SdlScalar scalar, string text)
        => scalar.kind == SdlScalarKind.string_ && scalar.stringValue == text;
    static SdlScalar firstAttribute(SdlNode node, string name)
    {
        foreach (attribute; node.byAttribute(SdlQualifiedName(null, name)))
            return attribute.value;
        return SdlScalar.init;
    }
    static bool hasAttribute(SdlNode node, string name)
        => !node.byAttribute(SdlQualifiedName(null, name)).empty;
    static bool valueIsNull(SdlNode node, size_t index)
        => index >= node.valueCount || node.valueAt(index).kind == SdlScalarKind.null_;
    static bool sparklesPackage(SdlNode node)
    {
        if (node.valueCount == 0 || node.valueAt(0).kind != SdlScalarKind.string_)
            return false;
        const text = node.valueAt(0).stringValue;
        return text.startsWith("sparkles:") && !text.canFind('/');
    }

    // Each filter and the hand-written predicate it spells.
    static struct Case { string filter; bool function(SdlNode) predicate; }
    static immutable Case[] cases = [
        Case("path != null", n => hasAttribute(n, "path")),
        Case("version == `*`", n => isText(firstAttribute(n, "version"), "*")),
        Case("values[0] == null", n => valueIsNull(n, 0)),
        Case("path != null && version == null",
            n => hasAttribute(n, "path") && !hasAttribute(n, "version")),
        Case("globMatch(values[0], `sparkles:*`)", &sparklesPackage),
        Case("dflags", n => !n.byChild(SdlQualifiedName(null, "dflags")).empty),
        Case("!(values[1] != null || platform == linux)",
            n => !(!valueIsNull(n, 1) || isText(firstAttribute(n, "platform"), "linux"))),
    ];

    size_t compared;
    foreach (file; repositoryRecipes())
    {
        const host = readText(file);
        auto parsed = parseRecipe(host, file);
        if (!parsed.hasValue)
            continue;
        auto root = parsed.document.root;
        foreach (path; ["dependency", "configuration", "configuration.dependency",
            "dflags", "configuration.dflags", "buildType", "subPackage"])
            foreach (c; cases)
            {
                auto selector = SdlSelector.parse(path, c.filter);
                assert(selector.hasValue, selector.hasError ? selector.error.error.message : "");
                size_t[] expected, actual;
                foreach (node; SdlPath.parse(path).value.nodes(root))
                    if (c.predicate(node))
                        expected ~= node.cellIndex;
                foreach (node; selector.value.nodes(root))
                    actual ~= node.cellIndex;
                assert(actual == expected, file ~ ": " ~ path ~ " / " ~ c.filter);
                compared += expected.length;
            }
    }
    assert(compared > 1000, "too few filtered nodes were compared");
}

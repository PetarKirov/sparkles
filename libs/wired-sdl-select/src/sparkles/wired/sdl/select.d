/** Path selection over a parsed SDL document (editing §3.2, SDS1–SDS6).

A path in the DQL path grammar (`configuration.dependency`,
`configuration[1].dependency`) selects nodes by name-and-index child steps;
read as an attribute selection, its last segment names attributes instead
(`dependency.path`). A leading `..` lets the first step match at any depth
(`..dependency`). An optional DQL filter narrows the selection, evaluated
by DQL's own evaluator with each selected node as its subject through
$(LREF SdlNodeResolver):

---
auto selector = SdlSelector.parse("dependency.path", "path == `../..`").value;
foreach (attribute; selector.attributes(document.root))
    editor.replaceAttribute(attribute, name, SdlScalar(root));
---

$(LREF SdlPath) borrows a path and selects without a filter or any
allocation; $(LREF SdlSelector) shares one parsed path, DQL engine and filter
among its copies, reference-counted off the collected heap.
*/
module sparkles.wired.sdl.select;

import core.lifetime : move;

import sparkles.base.expected : Expected, err, ok;
import sparkles.dql.engine : DqlEngine, DqlParseError;
import sparkles.dql.ast : DqlFilter;
import sparkles.dql.eval : evalDql;
import sparkles.dql.parser : parseDql;
import sparkles.dql.path : DqlPathStep, DqlPathStepKind, DqlPathSteps, dqlPathSteps,
    validateDqlPath;
import sparkles.wired.sdl.document : SdlAttributeRange, SdlAttributeView, SdlChildRange,
    SdlCore, SdlNode, SdlQualifiedName, SdlScalar, SdlScalarKind;

/// The most steps a selection path may have.
enum size_t sdlSelectorMaxSteps = 16;

/// One step of an SDL path: a segment, identifier or quoted, and an
/// optional index.
private struct SdlStep
{
    DqlPathStep member;
    bool indexed;
    size_t index;

    /** Whether the segment names `name`. A segment's decoded text is the
    name split at its first `:`; SDL names hold no other `:`, so it names
    exactly the name whose full spelling it is. */
    bool matches(scope const SdlQualifiedName name) const scope @safe pure nothrow @nogc
        => name.namespace_.length
            ? member.nameEquals(name.namespace_, ":", name.localName)
            : member.nameEquals(name.localName);
}

/// Reads the next step of non-empty `steps` — a member and the index after
/// it, if any. The path has passed $(LREF checkSdlPath).
private SdlStep nextStep(ref return scope DqlPathSteps steps) @safe pure nothrow @nogc
in (!steps.empty)
{
    SdlStep step;
    step.member = steps.front;
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

/** The shape of a selection path: its SDL steps, and whether a leading `..`
lets its first step match at any depth (SDS6). */
private struct SdlPathShape
{
    size_t steps;
    bool anyDepth;
}

/** The shape of `path` — an SDL path, after an optional leading `..` — or
its first fault, at its byte offset in `path`. */
private Expected!(SdlPathShape, DqlParseError) checkSelectionPath(scope const(char)[] path)
    @safe pure nothrow @nogc
{
    const anyDepth = path.length >= 2 && path[0 .. 2] == "..";
    const skip = anyDepth ? 2 : 0;
    const steps = checkSdlPath(path[skip .. $]);
    if (steps.hasError)
        return err!SdlPathShape(DqlParseError(steps.error.message,
            steps.error.offset + skip, steps.error.length));
    return ok!DqlParseError(SdlPathShape(steps.value, anyDepth));
}

// The SDL path after a selection path's leading `..`, if any.
private const(char)[] stepsOf(return scope const(char)[] path, bool anyDepth)
    @safe pure nothrow @nogc
    => anyDepth ? path[2 .. $] : path;

/** A validated selection path (SDS1, SDS6) that borrows its text: it selects
nodes or attributes without a filter, allocating nothing (SDS4). */
struct SdlPath
{
    private const(char)[] _text;
    private size_t _steps;
    private bool _anyDepth;

    /// Validates `text`; the error's offset is a byte offset into it.
    static Expected!(SdlPath, DqlParseError) parse(return scope const(char)[] text)
        @safe pure nothrow @nogc
    {
        const shape = checkSelectionPath(text);
        if (shape.hasError)
            return err!SdlPath(DqlParseError(shape.error.message, shape.error.offset,
                shape.error.length));
        SdlPath path;
        path._text = text;
        path._steps = shape.value.steps;
        path._anyDepth = shape.value.anyDepth;
        return ok!DqlParseError(path);
    }

    /// The path's text.
    const(char)[] text() const return scope @safe pure nothrow @nogc => _text;

    /// The number of name-and-index steps.
    size_t length() const scope @safe pure nothrow @nogc => _steps;

    /// Whether the path begins with `..`, so its first step matches at any depth.
    bool anyDepth() const scope @safe pure nothrow @nogc => _anyDepth;

    /// The nodes the path selects below `start` (SDS2), in document order.
    SdlNodeSelection nodes(return scope SdlNode start) const return scope
        @safe pure nothrow @nogc
        => SdlNodeSelection(stepsOf(_text, _anyDepth), _steps, _anyDepth, start);

    /** The attributes the path selects below `start`: its last step names
    attributes of the nodes the others select (SDS2), in document order. */
    SdlAttributeSelection!SdlNodeSelection attributes(return scope SdlNode start) const
        return scope @safe pure nothrow @nogc
        => SdlAttributeSelection!SdlNodeSelection(
            SdlNodeSelection(stepsOf(_text, _anyDepth), _steps - 1, _anyDepth, start),
            stepAt(stepsOf(_text, _anyDepth), _steps - 1));
}

/** Forward range over the nodes `steps` child steps of a path reach from a
start node, in document order (SDS2). With no steps, the start node itself.
At any depth (SDS6), the steps may begin at the start node or at any node
below it: with no steps, that is the start node and every node below it. */
struct SdlNodeSelection
{
    private const(char)[] _path;
    private size_t _steps;
    private size_t _depth;
    private SdlChildRange[sdlSelectorMaxSteps] _levels;
    private size_t[sdlSelectorMaxSteps] _matched;
    private SdlNode _front;
    private bool _empty;

    // At any depth: the cells of the start node's subtree, scanned in
    // document order, and the last cell seen at each level, modulo the ring.
    private bool _anyDepth;
    private const(SdlCore)* _core;
    private size_t _cell, _end;
    private uint _base;
    private size_t[sdlSelectorMaxSteps + 1] _ring;

    private this(return scope const(char)[] path, size_t steps, bool anyDepth,
        return scope SdlNode start) @safe pure nothrow @nogc
    in (steps <= sdlSelectorMaxSteps)
    {
        _path = path;
        _steps = steps;
        _anyDepth = anyDepth;
        if (anyDepth)
        {
            _core = start.core;
            _cell = start.cellIndex;
            _base = level(_cell);
            _end = _cell + _core.subtreeSizeAt(_cell);
            scan();
            return;
        }
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
        if (_anyDepth)
            scan();
        else if (_steps == 0)
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
                if (!step.matches(child.qualifiedName))
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

    // The document stores its nodes in document order, each cell with its
    // depth and subtree size, so a subtree is the run of cells after its root. A cell
    // matches when its last `_steps` ancestors-or-self spell the path and
    // the highest of them is a child of the start node or of a node below
    // it. That anchor is unique, so no node is yielded twice.
    private void scan() scope @safe pure nothrow @nogc
    {
        while (_cell < _end)
        {
            const cell = _cell++;
            const at = level(cell);
            _ring[at % _ring.length] = cell;
            if (at >= _base + _steps && matchesUpward(cell))
            {
                () @trusted { _front = SdlNode(_core, cell); }();
                return;
            }
        }
        _empty = true;
    }

    private bool matchesUpward(size_t cell) const scope @safe pure nothrow @nogc
    {
        foreach_reverse (k; 0 .. _steps)
        {
            const step = stepAt(_path, k);
            if (!step.matches(nodeAt(cell).qualifiedName))
                return false;
            const parent = parentOf(cell);
            if (step.indexed && ordinalOf(parent, cell, step) != step.index)
                return false;
            cell = parent;
        }
        return true;
    }

    // The parent of a cell the scan has reached: the nearest earlier cell
    // whose subtree holds it, which is the last cell the scan saw one level
    // up, unless a deeper subtree has since taken that ring slot; then the
    // scan walks back to it.
    private size_t parentOf(size_t cell) const scope @safe pure nothrow @nogc
    {
        const remembered = _ring[(level(cell) - 1) % _ring.length];
        if (holds(remembered, cell))
            return remembered;
        size_t parent = cell - 1;
        while (!holds(parent, cell))
            parent--;
        return parent;
    }

    // Whether `cell` lies in `ancestor`'s subtree, below it.
    private bool holds(size_t ancestor, size_t cell) const scope @safe pure nothrow @nogc
        => ancestor < cell && cell < ancestor + _core.subtreeSizeAt(ancestor);

    // How many of `parent`'s children before `cell` the step names.
    private size_t ordinalOf(size_t parent, size_t cell, in SdlStep step) const scope
        @safe pure nothrow @nogc
    {
        size_t ordinal;
        foreach (child; SdlNode(_core, parent).byChild)
        {
            if (child.cellIndex == cell)
                break;
            ordinal += step.matches(child.qualifiedName);
        }
        return ordinal;
    }

    private SdlNode nodeAt(size_t cell) const return scope @safe pure nothrow @nogc
        => SdlNode(_core, cell);

    // A cell's depth below the root, which is level 0 (its stored depth,
    // `uint.max`, wraps to it).
    private uint level(size_t cell) const scope @safe pure nothrow @nogc
        => cast(uint)(_core.nodeAt(cell).depth + 1);
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
                if (!_step.matches(attribute.qualifiedName))
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

/** A selection path and an optional DQL filter (SDS3). Its state, the path,
the DQL engine and the filter that lives in it, is parsed once into one
reference-counted block off the collected heap: copies of a selector are
owners of the same block, freed with the last of them, so a selector binds
like any value (`auto s = SdlSelector.parse(…).value;`). The count is not
atomic, so copies are for one thread. The ranges it returns borrow the
selector, so keep it in a variable while they are used: dip1000 rejects a
range declared from a temporary selector, but not a `foreach` over
`SdlSelector.parse(…).value.nodes(root)`, whose temporary dies before the
loop runs (a range checks, as far as it can, that its selector is alive).
(An owning range would need a destructor, and dip1000 infers no `scope`
for a parameter of such a type, so Phobos adaptors such as `map` would
refuse it a borrowed start node.) */
struct SdlSelector
{
    private static struct State
    {
        size_t owners;
        const(char)[] text; // the path's own bytes, freed with the state
        SdlPath path;       // over `text`
        DqlEngine engine;
        DqlFilter filter;
    }

    private State* _state;

    /** Validates `path` and parses `filter`, which may be empty to keep
    every node; a fault names its part and its offset there. */
    static Expected!(SdlSelector, SdlSelectorError) parse(scope const(char)[] path,
        scope const(char)[] filter = null) @safe
    {
        const checked = SdlPath.parse(path);
        if (checked.hasError)
            return err!SdlSelector(SdlSelectorError(SdlSelectorPart.path, checked.error));
        auto selector = SdlSelector(allocate(path));
        auto parsed = parseDql(selector._state.engine, filter);
        if (parsed.hasError)
            return err!SdlSelector(SdlSelectorError(SdlSelectorPart.filter, parsed.error));
        selector._state.filter = move(parsed.value);
        return ok!SdlSelectorError(selector);
    }

    // A copy is one more owner.
    this(this) scope @safe pure nothrow @nogc
    {
        if (_state !is null)
            _state.owners++;
    }

    // The last owner frees the state.
    ~this() scope @safe nothrow @nogc
    {
        if (_state is null || --_state.owners)
            return;
        () @trusted { release(_state); }();
        _state = null;
    }

    /** A state over a copy of `path`, which has validated, with the caller
    its one owner. The collector scans it: the DQL engine keeps compiled
    regular expressions on the collected heap. */
    private static State* allocate(scope const(char)[] path) @trusted nothrow @nogc
    {
        import core.exception : onOutOfMemoryError;
        import core.lifetime : emplace;
        import core.memory : GC, pureMalloc;

        auto state = cast(State*) pureMalloc(State.sizeof);
        auto text = cast(char*) pureMalloc(path.length);
        if (state is null || text is null)
            onOutOfMemoryError();
        emplace(state);
        GC.addRange(state, State.sizeof, typeid(State));
        text[0 .. path.length] = path[];
        state.owners = 1;
        state.text = text[0 .. path.length];
        state.path = SdlPath.parse(state.text).value;
        return state;
    }

    // Destroys and frees `state`, whose last owner is gone.
    private static void release(State* state) @system nothrow @nogc
    {
        import core.memory : GC, pureFree;

        auto text = state.text;
        destroy!false(*state);
        GC.removeRange(state);
        pureFree(state);
        pureFree(cast(void*) text.ptr);
    }

    /// The selection path.
    SdlPath path() const @safe pure nothrow @nogc
    in (_state !is null, "a selector from `parse`")
        => _state.path;

    /// Whether `node` passes the filter (an empty filter passes everything).
    bool accepts(scope SdlNode node) scope @safe
    in (_state !is null, "a selector from `parse`")
        => evalDql(_state.engine, _state.filter, SdlNodeResolver(node));

    /// The nodes the path selects below `start` that pass the filter.
    SdlSelectedNodes nodes(return scope SdlNode start) return @safe
    in (_state !is null, "a selector from `parse`")
        => SdlSelectedNodes(&this, _state.path.nodes(start));

    /** The attributes the path selects below `start`, of the nodes that
    pass the filter: the filter's subject is the node holding them. */
    SdlAttributeSelection!SdlSelectedNodes attributes(return scope SdlNode start) return
        @safe
    in (_state !is null, "a selector from `parse`")
    {
        const path = _state.path;
        const steps = stepsOf(path._text, path._anyDepth);
        return SdlAttributeSelection!SdlSelectedNodes(SdlSelectedNodes(&this,
            SdlNodeSelection(steps, path._steps - 1, path._anyDepth, start)),
            stepAt(steps, path._steps - 1));
    }
}

/// Forward range over a selection's nodes that pass its selector's filter; it
/// borrows the selector, which must outlive it.
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

    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _nodes.empty;
    /// ditto
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => _nodes.front;
    /// ditto
    void popFront() scope @safe
    in (!empty)
    in (_selector._state !is null, "the selector this range borrows is gone")
    {
        _nodes.popFront();
        skip();
    }
    /// ditto
    SdlSelectedNodes save() return scope @safe => this;

    private void skip() scope @safe
    {
        while (!_nodes.empty && !_selector.accepts(_nodes.front))
            _nodes.popFront();
    }
}

/** A DQL host resolver over one SDL node (SDS3). A path is zero or more
child steps, each taking the first child of its name or, with `[k]`, the
k-th, then a leaf: `values[i]`, the i-th value, `attributes[i]`, the value of
the i-th attribute whatever its name, or an attribute name, its first
attribute of that name; so `attributes[1] == null` holds when the node has at
most one attribute. A category holds when a child exists at the
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
        if (step.member.nameEquals("values"))
        {
            if (!step.indexed)
                return Reach.malformed;
            if (step.index >= current.valueCount)
                return Reach.absent;
            () @trusted { scalar = current.valueAt(step.index); }();
            return Reach.scalar;
        }
        if (step.member.nameEquals("attributes") && step.indexed)
        {
            size_t ordinal;
            foreach (attribute; current.byAttribute)
                if (ordinal++ == step.index)
                {
                    () @trusted { scalar = attribute.value; }();
                    return Reach.scalar;
                }
            return Reach.absent;
        }
        if (step.indexed)
            return Reach.malformed;
        foreach (attribute; current.byAttribute)
            if (step.matches(attribute.qualifiedName))
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
        foreach (candidate; parent.byChild)
            if (step.matches(candidate.qualifiedName)
                && ordinal++ == (step.indexed ? step.index : 0))
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
    import std.range.primitives : walkLength;

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

    // `attributes[i]` reads the i-th attribute, whatever its name, so it
    // counts them; a bare `attributes` is still an attribute's name.
    auto lone = SdlSelector.parse("configuration.dependency", "attributes[1] == null").value;
    assert(lone.nodes(root).map!(n => n.byValue.front.stringValue).equal(["sparkles:test-utils"]));
    auto second = SdlSelector.parse("..dependency", "attributes[1] == true").value;
    assert(second.nodes(root).map!(n => n.byValue.front.stringValue).equal(["silly"]));
    assert(SdlSelector.parse("..dependency", "attributes[0] == `*`").value.nodes(root)
        .map!(n => n.byValue.front.stringValue).equal(["silly"]));
    assert(SdlSelector.parse("..dependency", "attributes == null").value.nodes(root)
        .walkLength == 4);
}

/// A selector binds like a value: copies count as owners of one parsed
/// state, freed with the last of them; a range borrows its selector.
@("sdl.select.SdlSelector.binds")
@safe unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : map;

    auto parsed = parseSdlDocument!sdlFull(recipe);
    auto root = parsed.document.root;
    auto selector = SdlSelector.parse("configuration.dependency", "version != null").value;
    assert(selector._state.owners == 1);
    {
        auto copy = selector;
        assert(selector._state.owners == 2);
        assert(copy.nodes(root).map!(n => n.byValue.front.stringValue).equal(["silly"]));
    }
    assert(selector._state.owners == 1);
    assert(selector.path.text == "configuration.dependency");

    auto optional = SdlSelector.parse("configuration.dependency", "optional == true").value;
    auto silly = optional.nodes(root);
    auto saved = silly.save;
    assert(silly.front.byValue.front.stringValue == "silly");
    silly.popFront();
    assert(silly.empty && !saved.empty);
}

/// Copies held in collected arrays, built from a literal and grown by
/// appending, each count as an owner (AGENTS.md: druntime fills such arrays
/// by blitting; the postblit, unlike a copy constructor, still runs).
@("sdl.select.SdlSelector.ownersInArrays")
@safe unittest
{
    auto selector = SdlSelector.parse("dependency", "version == `*`").value;
    SdlSelector[] copies = [selector, selector];
    assert(selector._state.owners == 3);
    copies ~= selector;
    copies ~= copies;
    // Seven live copies at least: a grown array leaves its old block's
    // counted copies for the collector to destroy, never an uncounted one.
    assert(selector._state.owners >= 7);
}

/// A leading `..` lets the first step match at any depth (SDS6): below the
/// start node, in document order, each node once.
@("sdl.select.SdlPath.anyDepth")
@safe unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : map;

    auto parsed = parseSdlDocument!sdlFull(recipe);
    auto root = parsed.document.root;
    auto names(string path)
        => SdlPath.parse(path).value.nodes(root).map!(n => n.byValue.front.stringValue);
    assert(names("..dependency").equal(["sparkles:base", "optional", "sparkles:test-utils",
        "silly"]));
    assert(names("..configuration[1].dependency").equal(["sparkles:test-utils", "silly"]));
    assert(names("..dependency[1]").equal(["optional", "silly"]));
    assert(SdlPath.parse("..dependency.version").value.attributes(root)
        .map!(a => a.value.stringValue).equal(["~>1.3.0", "*"]));
    assert(SdlPath.parse("..optional").value.attributes(root).map!(a => a.value.boolean)
        .equal([true]));
    assert(SdlPath.parse("..dependency").value.anyDepth);

    // From a node below the root, only its own subtree counts.
    auto unittest_ = SdlPath.parse("configuration[1]").value.nodes(root).front;
    assert(SdlPath.parse("..dependency").value.nodes(unittest_)
        .map!(n => n.byValue.front.stringValue).equal(["sparkles:test-utils", "silly"]));

    // `..` begins a path and nowhere else.
    assert(SdlPath.parse("..").error.offset == 2);
    assert(SdlPath.parse("...a").error.offset == 2);
    assert(SdlPath.parse("..[0]").error.offset == 2);
    assert(SdlPath.parse("a..b").error.offset == 2);
    assert(SdlSelector.parse("..dependency", "version == `*`").value.nodes(root)
        .map!(n => n.byValue.front.stringValue).equal(["silly"]));
}

/// Nesting deeper than the path's steps, and deeper than its ancestor ring,
/// still finds each node's parent.
@("sdl.select.SdlPath.anyDepth.deep")
@safe unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : map;
    import std.range : repeat;
    import std.array : join;

    enum chain = "c {\n".repeat(40).join ~ "}\n".repeat(40).join;
    enum text = "p 1 {\n" ~ chain ~ "q 1\n p 2 {\n q 2\n}\n}\nq 3\np 3 {\n" ~ chain ~ "q 4\n}\n";
    auto parsed = parseSdlDocument!sdlFull(text);
    assert(parsed.hasValue, parsed.hasError ? parsed.error.toString : "");
    auto root = parsed.document.root;
    auto values(string path)
        => SdlPath.parse(path).value.nodes(root).map!(n => n.byValue.front.integer);
    assert(values("..p.q").equal([1, 2, 4]));
    assert(values("..q").equal([1, 2, 3, 4]));
    assert(values("..p[1].q").equal([4])); // p 2 is the first p of its parent
    size_t chains;
    foreach (_; SdlPath.parse("..c.c").value.nodes(root))
        chains++;
    assert(chains == 2 * 39);
}

/// Any-depth selection allocates nothing either (SDS4).
@("sdl.select.SdlPath.anyDepth.nogc")
@safe pure nothrow @nogc
unittest
{
    auto parsed = parseSdlDocument!sdlFull(recipe);
    size_t count;
    foreach (node; SdlPath.parse("..dependency").value.nodes(parsed.document.root))
        count++;
    assert(count == 4);
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
    // A name's full spelling: `ns:local`, or `local`.
    private string spelling(SdlQualifiedName name)
        => name.namespace_.length
            ? (name.namespace_ ~ ":" ~ name.localName).idup : name.localName.idup;

    // One reference step: a full spelling and an optional index.
    private struct NameStep
    {
        string name;
        bool indexed;
        size_t index;
    }

    // `steps` as DQL prints a path: identifiers bare, other names quoted.
    private string printed(const(NameStep)[] steps)
    {
        import std.conv : to;
        import sparkles.dql.path : writeDqlSegment;

        static struct Text
        {
            string text;
            void put(scope const(char)[] part) { text ~= part; }
        }

        Text path;
        foreach (i, step; steps)
        {
            writeDqlSegment(path, step.name, i == 0);
            if (step.indexed)
                path.text ~= "[" ~ step.index.to!string ~ "]";
        }
        return path.text;
    }

    // Every name path below `node` to `depth` steps, in first-seen order.
    private void namePaths(SdlNode node, NameStep[] prefix, size_t depth, ref NameStep[][] paths)
    {
        import std.algorithm.searching : canFind;

        if (depth == 0)
            return;
        foreach (child; node.byChild)
        {
            auto path = prefix ~ NameStep(spelling(child.qualifiedName));
            if (!paths.canFind(path))
                paths ~= path;
            namePaths(child, path, depth - 1, paths);
        }
    }

    // The reference selection: nested loops over the children, one per
    // step, comparing full spellings.
    private void referenceNodes(SdlNode node, const(NameStep)[] steps, ref size_t[] cells)
    {
        if (steps.length == 0)
        {
            cells ~= node.cellIndex;
            return;
        }
        size_t ordinal;
        foreach (child; node.byChild)
            if (spelling(child.qualifiedName) == steps[0].name
                && (!steps[0].indexed || ordinal++ == steps[0].index))
                referenceNodes(child, steps[1 .. $], cells);
    }

    // `steps` with step `at` indexed by `index`.
    private NameStep[] withIndex(const(NameStep)[] steps, size_t at, size_t index)
    {
        auto copy = steps.dup;
        copy[at].indexed = true;
        copy[at].index = index;
        return copy;
    }

    /* SDS2's oracle over one document: every name path to depth three,
    printed as DQL prints it and with and without an index, selects what the
    nested loops select; attribute selections likewise. */
    private void checkPathOracle(SdlNode root, string label, ref size_t nodePaths,
        ref size_t attributePaths)
    {
        NameStep[][] paths;
        namePaths(root, null, 3, paths);
        foreach (base; paths)
        {
            auto variants = [base, withIndex(base, base.length - 1, 0),
                withIndex(base, base.length - 1, 1)];
            if (base.length > 1)
                variants ~= withIndex(base, 0, 1);
            foreach (steps; variants)
            {
                const path = printed(steps);
                size_t[] expected, actual;
                referenceNodes(root, steps, expected);
                auto parsed = SdlPath.parse(path);
                assert(parsed.hasValue, label ~ ": " ~ path);
                foreach (node; parsed.value.nodes(root))
                    actual ~= node.cellIndex;
                assert(actual == expected, label ~ ": " ~ path);
                nodePaths++;
            }

            // Attribute selections: every attribute name on the nodes `base`
            // selects, plain and with an index, against nested loops.
            if (base.length >= 3)
                continue;
            size_t[] owners;
            referenceNodes(root, base, owners);
            foreach (node; SdlPath.parse(printed(base)).value.nodes(root))
                foreach (attribute; node.byAttribute)
                {
                    const name = spelling(attribute.qualifiedName);
                    foreach (leaf; [NameStep(name), NameStep(name, true, 0)])
                    {
                        const path = printed(base ~ leaf);
                        size_t[] expected, actual;
                        foreach (owner; SdlPath.parse(printed(base)).value.nodes(root))
                        {
                            size_t ordinal;
                            foreach (candidate; owner.byAttribute)
                                if (spelling(candidate.qualifiedName) == name
                                    && (!leaf.indexed || ordinal++ == leaf.index))
                                    expected ~= candidate.cellIndex;
                        }
                        foreach (selected; SdlPath.parse(path).value.attributes(root))
                            actual ~= selected.cellIndex;
                        assert(actual == expected, label ~ ": " ~ path);
                        attributePaths++;
                    }
                }
        }
    }

    // The start node and every node below it.
    private void subtree(SdlNode node, ref SdlNode[] nodes)
    {
        nodes ~= node;
        foreach (child; node.byChild)
            subtree(child, nodes);
    }

    /* SDS6's oracle over one document: every name path to depth two below
    any node, read at any depth from the root, selects the union of what the
    nested loops select from each node, ordered by source offset; and `..x`
    selects the `x` attributes of every node. */
    private void checkAnyDepthOracle(SdlNode root, string label, ref size_t nodePaths,
        ref size_t attributePaths)
    {
        import std.algorithm.searching : canFind;
        import std.algorithm.sorting : sort;
        import std.algorithm.iteration : map;
        import std.array : array;
        import std.typecons : tuple;

        SdlNode[] anchors;
        subtree(root, anchors);
        NameStep[][] paths;
        string[] attributeNames;
        foreach (anchor; anchors)
        {
            namePaths(anchor, null, 2, paths);
            foreach (attribute; anchor.byAttribute)
                if (!attributeNames.canFind(spelling(attribute.qualifiedName)))
                    attributeNames ~= spelling(attribute.qualifiedName);
        }
        size_t offsetOf(size_t cell)
        {
            foreach (node; anchors)
                if (node.cellIndex == cell)
                    return node.span.startOffset;
            assert(0);
        }
        foreach (base; paths)
            foreach (steps; [base, withIndex(base, 0, 1), withIndex(base, base.length - 1, 0)])
            {
                const path = ".." ~ printed(steps);
                size_t[] cells, actual;
                foreach (anchor; anchors)
                    referenceNodes(anchor, steps, cells);
                auto ordered = cells.map!(c => tuple(offsetOf(c), c)).array;
                ordered.sort();
                foreach (node; SdlPath.parse(path).value.nodes(root))
                    actual ~= node.cellIndex;
                assert(actual == ordered.map!(t => t[1]).array, label ~ ": " ~ path);
                nodePaths++;
            }
        foreach (name; attributeNames)
        {
            size_t[] expected, actual;
            foreach (anchor; anchors)
                foreach (attribute; anchor.byAttribute)
                    if (spelling(attribute.qualifiedName) == name)
                        expected ~= attribute.cellIndex;
            foreach (attribute; SdlPath.parse(".." ~ printed([NameStep(name)])).value
                .attributes(root))
                actual ~= attribute.cellIndex;
            assert(actual == expected, label ~ ": .." ~ name);
            attributePaths++;
        }
    }

    // Tags and attributes whose names are not DQL identifiers.
    private enum dottedRecipe = `name "dotted"
my.tool "a" opt.level=3 x:my.flag=true
my.tool "b" {
    dep.name "inner" dflags.ldc="-O"
    dep.name "second"
}
x:my.tool "c" {
    a.b.c 1
}
plain "d" weird$name=1
`;
}

@("sdl.select.properties.repositoryRecipes.paths")
@system unittest
{
    import std.file : readText;
    import sparkles.wired.sdl.test_corpus : parseRecipe, repositoryRecipes;

    const files = repositoryRecipes();
    assert(files.length > 100, "the repository walk found too few recipes");
    size_t nodePaths, attributePaths, deepPaths, deepAttributes;
    foreach (file; files)
    {
        const host = readText(file);
        auto parsed = parseRecipe(host, file);
        if (!parsed.hasValue)
            continue;
        checkPathOracle(parsed.document.root, file, nodePaths, attributePaths);
        checkAnyDepthOracle(parsed.document.root, file, deepPaths, deepAttributes);
    }
    assert(nodePaths > 1000 && attributePaths > 1000, "too few selections were compared");
    assert(deepPaths > 1000 && deepAttributes > 300, "too few any-depth selections were compared");
}

@("sdl.select.properties.editedRecipes.anyDepth")
@system unittest
{
    import std.file : readText;
    import sparkles.wired.sdl.config : sdlDubRecipe;
    import sparkles.wired.sdl.open_document : SdlOpenDocument;
    import sparkles.wired.sdl.test_corpus : repositoryRecipes;

    // After an incremental re-parse the document shares the unchanged cells
    // with the one before; selections at any depth read it the same way.
    size_t shared_, nodePaths, attributePaths;
    foreach (file; repositoryRecipes())
    {
        SdlOpenDocument!sdlDubRecipe open;
        if (open.open(readText(file), file).hasError)
            continue;
        auto last = SdlPath.parse("..dependency").value.nodes(open.document.root);
        if (last.empty)
            continue;
        SdlNode target;
        foreach (node; last)
            target = node;
        auto editor = open.editor;
        editor.replaceValue(target, 0, SdlScalar("sparkles:edited"));
        assert(!open.commit(editor).hasError, file);
        shared_ += !open.document.core.flat;
        checkAnyDepthOracle(open.document.root, file, nodePaths, attributePaths);
    }
    assert(shared_ > 50, "too few re-parses shared their cells");
    assert(nodePaths > 1000);
}

@("sdl.select.properties.dottedNames.paths")
@system unittest
{
    auto parsed = parseSdlDocument!sdlFull(dottedRecipe);
    assert(parsed.hasValue, parsed.hasError ? parsed.error.toString : "");
    size_t nodePaths, attributePaths;
    checkPathOracle(parsed.document.root, "dotted", nodePaths, attributePaths);
    size_t deepPaths, deepAttributes;
    checkAnyDepthOracle(parsed.document.root, "dotted", deepPaths, deepAttributes);
    assert(deepPaths >= 15 && deepAttributes >= 4);
    assert(nodePaths >= 20 && attributePaths >= 8);

    // The quoted spellings select what they name, namespaces included.
    const root = parsed.document.root;
    size_t count(string path)
    {
        size_t n;
        foreach (_; SdlPath.parse(path).value.nodes(root))
            n++;
        return n;
    }
    assert(count(`["my.tool"]`) == 2);
    assert(count(`["my.tool"][1]["dep.name"]`) == 2);
    assert(count(`["x:my.tool"].["a.b.c"]`) == 1);
    assert(count("my") == 0);
    assert(SdlPath.parse(`["my.tool"]["opt.level"]`).value.attributes(root).front
        .value.integer == 3);
    assert(SdlPath.parse(`["my.tool"]["x:my.flag"]`).value.attributes(root).front
        .value.boolean);

    // Filters reach the same names.
    auto ldc = SdlSelector.parse(`["my.tool"]["dep.name"]`, `["dflags.ldc"] == null`);
    size_t kept;
    foreach (node; ldc.value.nodes(root))
    {
        assert(node.byValue.front.stringValue == "second");
        kept++;
    }
    assert(kept == 1);
    auto level = SdlSelector.parse(`["my.tool"]`,
        `["opt.level"] > 2 && ["x:my.flag"] == true`);
    assert(!level.value.nodes(root).empty);
    auto inner = SdlSelector.parse(`["my.tool"]`, `["dep.name"][1].values[0] == second`);
    assert(inner.value.nodes(root).front.byValue.front.stringValue == "b");
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
        Case("attributes[1] == null", n => n.attributeCount <= 1),
        Case("attributes[0] == `../..` && attributes[1] == null",
            n => n.attributeCount == 1 && isText(n.byAttribute.front.value, "../..")),
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

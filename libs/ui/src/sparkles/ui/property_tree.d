/**
The reflective property tree (`PRT1`–`PRT12`, `PRT14`–`PRT27`): one D value
presented as an interactive, filterable tree of property rows.

$(LIST
    * $(B metadata) — the compile-time UDA vocabulary (`@Label`, `@Doc`,
        `@Range`, `@hidden`, `@readOnly`, `@Editor!symbol`, `@ShowIf`, and the
        type-level `@opaqueValue`), validated where the walk instantiates, so
        an invalid combination is a build error (`PRT9`).
    * $(B paths) — every row has one readable, persistable address
        (`style.opacity`, `stops[2]`, keyed `items[#7]`, quoted `["любой"]`).
        $(LREF at) is the compile-time-checked direct access for the base
        grammar; $(LREF resolve) implements every segment form at run time and
        refuses rather than faults (`PRT6`, `PRT7`).
    * $(B the walk) — one $(B type-only) template walk ($(LREF PropertyTree))
        that materialises only opened children, terminates on cyclic subjects
        under `PropertyTreePolicy` caps with visible `⋯ (capped)` rows, and
        crosses into statically typed erased subjects by capability presence
        (`propChildren` / `propExpandable` / `propText`) (`PRT3`–`PRT5`).
    * $(B edits) — `Edit`/`EditValue`/`Refusal`/`Applied` as owned Regular
        values, applied through one generated dispatch that enforces
        `@readOnly`, the read-only policy, type/width/range checks $(B before)
        mutation, and returns the inverse (`PRT14`–`PRT16`).
    * $(B history) — $(LREF PropertyEditState), the per-logical-subject
        undo/redo + pending-preview-group + inline-refusal value the host
        stores beside the subject (`PRT17`–`PRT21`).
)

The adapter never retains `T*`: it receives `ref T` per rebuild and edit
(`PRT2`), and presents the result through the shipped tree components —
`TreeData!PropertyNode`, `TreeViewState!string`, `flatten`, and the
`nodeExpandable` projection. Consumers that use the fuzzy search projection
link `sparkles:fuzzy` (this package reaches it import-only, like
`sparkles:math`, to keep the dub graph acyclic).

Spec: `docs/specs/ui/property-tree.md`.
*/
module sparkles.ui.property_tree;

import std.conv : text, to;
import std.traits : EnumMembers, FieldNameTuple, getUDAs, hasUDA,
    isAggregateType, isArray, isBoolean, isFloatingPoint, isIntegral,
    isSomeString;

import sparkles.ui.components.tree_view : TreeViewState;
import sparkles.ui.components.tree_widget : flatten, TreeData;
import sparkles.ui.state : DisclosureState;

// Templates infer their attributes (a caller-supplied sink or subject decides
// them); the non-template path helpers are explicitly `@safe`.

// ─────────────────────────────────────────────────────────────────────────────
// The metadata vocabulary (PRT9–PRT11).
// ─────────────────────────────────────────────────────────────────────────────

/// Display-name override for one member.
struct Label { string text; }

/// Documentation shown in details chrome and searched by the filter.
struct Doc { string text; }

/// Numeric bounds; enforced inside the generated dispatch before mutation.
struct Range { double lo; double hi; double step = 0; }

/// Never presented, never searched, never addressable through the view.
enum hidden;

/// Presented, never editable; refused inside the generated dispatch.
enum readOnly;

/**
Per-field editor override: a $(B symbol), not a registry key (`PRT9`). The
symbol must accept and emit the field's concrete leaf type — validated where
the walk instantiates, so a mismatch is a build error — and it can never make
an opaque value assignable.
*/
struct Editor(alias fn) {}

/// A value-dependent visibility condition over the $(B enclosing) value,
/// compiled into a typed `@safe` predicate and evaluated per rebuild (`PRT10`).
struct ShowIf { string cond; }

/// A type that marks itself as a leaf presented via its own `toString` —
/// VS Code's `Complex` posture. Read-only in v1 (`PRT11`).
enum opaqueValue;

// ─────────────────────────────────────────────────────────────────────────────
// Leaf classification (PRT11).
// ─────────────────────────────────────────────────────────────────────────────

/// The closed leaf vocabulary every view dispatches on.
enum LeafKind : ubyte
{
    none,        /// not a leaf (a composite row)
    boolean,     ///
    integral,    ///
    floating,    ///
    text,        ///
    enumeration, ///
    opaque,      /// presented via `toString`; never editable in v1
}

/// The closed `static if` ladder from a D type to its `LeafKind`.
template leafKindOf(T)
{
    static if (is(T == enum))
        enum leafKindOf = LeafKind.enumeration;
    else static if (isBoolean!T)
        enum leafKindOf = LeafKind.boolean;
    else static if (isIntegral!T)
        enum leafKindOf = LeafKind.integral;
    else static if (isFloatingPoint!T)
        enum leafKindOf = LeafKind.floating;
    else static if (isSomeString!T)
        enum leafKindOf = LeafKind.text;
    else
        enum leafKindOf = LeafKind.opaque;
}

/// `true` when the walk descends into `T` rather than presenting a leaf.
private enum bool descends(T) = !hasUDA!(T, opaqueValue)
    && (hasPropChildren!T
        || (isAggregateType!T && !isSomeString!T)
        || (isArray!T && !isSomeString!T)
        || is(T == U*, U));

/// The erased-subject capability (`PRT5`): a type enumerating its own
/// children as `(index, name, ref child)`; `name` is `null` for an element.
enum bool hasPropChildren(T) = __traits(compiles,
    (ref T t) { foreach (i, name, ref child; t.propChildren) {} });

/// Stable element identity (`PRT7`): a collection element opting in.
enum bool hasElementKey(T) = __traits(compiles,
    (ref const T t) { ulong k = t.propElementKey; });

// ─────────────────────────────────────────────────────────────────────────────
// Paths (PRT6–PRT7): the address grammar, both directions.
// ─────────────────────────────────────────────────────────────────────────────

/// One parsed path segment.
struct PathSeg
{
    string name;   /// member / erased-child name (bare or quoted form)
    size_t index;  /// positional element
    ulong key;     /// `[#key]` stable element identity
    bool isIndex;  ///
    bool isKey;    ///
}

/**
Parses `name ( "." name | "[" digits "]" | "[#" digits "]" | "[\"…\"]" )*`.
Returns `false` (and an empty result) for malformed text — an unterminated
bracket or quote, a non-numeric index, an empty segment — rather than
guessing.
*/
bool parsePath(scope const(char)[] path, out PathSeg[] segs)
    @safe pure nothrow
{
    segs = null;
    size_t i;
    bool expectName = true;
    while (i < path.length)
    {
        const c = path[i];
        if (c == '.')
        {
            if (expectName)
                return false; // ".." / leading "."
            i++;
            expectName = true;
            continue;
        }
        if (c == '[')
        {
            if (expectName && segs.length)
                return false; // ".["
            if (i + 1 >= path.length)
                return false;
            if (path[i + 1] == '#')
            {
                size_t j = i + 2;
                ulong key;
                bool any;
                while (j < path.length && path[j] >= '0' && path[j] <= '9')
                {
                    key = key * 10 + (path[j] - '0');
                    j++;
                    any = true;
                }
                if (!any || j >= path.length || path[j] != ']')
                    return false;
                PathSeg s = { isKey: true, key: key };
                segs ~= s;
                i = j + 1;
            }
            else if (path[i + 1] == '"')
            {
                size_t j = i + 2;
                string name;
                while (j < path.length && path[j] != '"')
                {
                    if (path[j] == '\\')
                    {
                        j++;
                        if (j >= path.length)
                            return false;
                    }
                    name ~= path[j];
                    j++;
                }
                if (j + 1 >= path.length || path[j] != '"' || path[j + 1] != ']')
                    return false;
                segs ~= PathSeg(name);
                i = j + 2;
            }
            else
            {
                size_t j = i + 1;
                size_t index;
                bool any;
                while (j < path.length && path[j] >= '0' && path[j] <= '9')
                {
                    index = index * 10 + (path[j] - '0');
                    j++;
                    any = true;
                }
                if (!any || j >= path.length || path[j] != ']')
                    return false;
                PathSeg s = { isIndex: true, index: index };
                segs ~= s;
                i = j + 1;
            }
            expectName = false;
        }
        else
        {
            size_t j = i;
            while (j < path.length && path[j] != '.' && path[j] != '[')
                j++;
            segs ~= PathSeg(path[i .. j].idup);
            i = j;
            expectName = false;
        }
    }
    return !expectName || segs.length == 0;
}

/// `true` iff `name` needs no quoting: an identifier-shaped ASCII name.
private bool bareName(scope const(char)[] name) @safe pure nothrow @nogc
{
    if (name.length == 0 || (name[0] >= '0' && name[0] <= '9'))
        return false;
    foreach (c; name)
        if (!(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9')))
            return false;
    return true;
}

/**
How the walk mints a member/erased-child path. A name outside the bare
identifier subset is emitted as a quoted segment with `\"`/`\\` escapes, so
every emitted path re-parses to the same segments (`PRT6`).
*/
string childPath(string parent, scope const(char)[] member) @safe pure nothrow
{
    if (bareName(member))
        return parent.length ? parent ~ "." ~ member.idup : member.idup;
    string q = `["`;
    foreach (c; member)
    {
        if (c == '"' || c == '\\')
            q ~= '\\';
        q ~= c;
    }
    return parent ~ q ~ `"]`;
}

/// ditto — a positional element.
string elementPath(string parent, size_t i) @safe pure
    => parent ~ "[" ~ i.to!string ~ "]";

/// ditto — a keyed element (`PRT7`).
string keyedPath(string parent, ulong key) @safe pure
    => parent ~ "[#" ~ key.to!string ~ "]";

/// The inverse of `parsePath` for one segment appended to `parent`.
private string appendSeg(string parent, in PathSeg s) @safe pure
{
    if (s.isKey)
        return keyedPath(parent, s.key);
    if (s.isIndex)
        return elementPath(parent, s.index);
    return childPath(parent, s.name);
}

/// The parent address, or `""` for a root segment. Malformed input answers `""`.
string parentPath(string path) @safe pure nothrow
{
    PathSeg[] segs;
    if (!parsePath(path, segs) || segs.length < 2)
        return "";
    string p;
    // Emitting can only throw on allocation failure (an Error).
    scope (failure) assert(0, "path emit cannot fail");
    foreach (ref const s; segs[0 .. $ - 1])
        p = appendSeg(p, s);
    return p;
}

/**
Compile-time path resolution (`PRT6`): a direct, `ref`-returning field access
for the base positional grammar. A typo is a build error at the use site;
quoted and keyed segments are runtime-only.
*/
ref auto at(string P, T)(return ref T subject)
    => mixin("subject." ~ P);

/**
Runtime path resolution: walks `segs` against `subject` and calls
`sink(leafRef)` on the addressed value. `sink` is an alias parameter, so it is
instantiated per addressed type — no `void*`, no registry. Returns `false`
(never faults) for a missing member, an out-of-range index, a null pointer
hop, an absent or duplicate element key, or `[#…]` on a collection that never
opted into keys.

Explicitly `@safe` (with the whole walk): the erased seam's enumeration
passes a closure that recurses into the function being inferred, a cycle
attribute inference cannot settle — so the safety contract is stated rather
than inferred, and every subject capability (`propChildren`, `propText`,
`toString`, `@ShowIf` predicates) must be `@safe`, which is the spec's own
posture (`PRT10`, `PRT24`).
*/
bool resolve(alias sink, T)(ref T subject, in PathSeg[] segs, size_t at_ = 0)
    @safe
{
    static if (hasPropChildren!T)
    {
        if (at_ == segs.length)
        {
            sink(subject);
            return true;
        }
        bool found;
        bool result;
        foreach (i, name, ref child; subject.propChildren)
        {
            const hit = segs[at_].isIndex ? i == segs[at_].index
                : (!segs[at_].isKey && name !is null && name == segs[at_].name);
            if (hit)
            {
                found = true;
                result = resolve!sink(child, segs, at_ + 1);
                break;
            }
        }
        return found && result;
    }
    else static if (is(T == U*, U))
    {
        // A null pointer is "no such path", never a fault; the deref consumes
        // no segment, matching the compile-time form's implicit deref.
        if (subject is null)
            return false;
        return resolve!sink(*subject, segs, at_);
    }
    else static if (isArray!T && !isSomeString!T)
    {
        if (at_ == segs.length)
        {
            sink(subject);
            return true;
        }
        static if (hasElementKey!(typeof(subject[0])))
        {
            if (segs[at_].isKey)
            {
                size_t found, hits;
                foreach (idx; 0 .. subject.length)
                    if (subject[idx].propElementKey == segs[at_].key)
                    {
                        found = idx;
                        hits++;
                    }
                if (hits != 1) // absent or duplicate: refused, never positional
                    return false;
                return resolve!sink(subject[found], segs, at_ + 1);
            }
        }
        if (!segs[at_].isIndex || segs[at_].index >= subject.length)
            return false;
        return resolve!sink(subject[segs[at_].index], segs, at_ + 1);
    }
    else static if (isAggregateType!T && !isSomeString!T)
    {
        if (at_ == segs.length)
        {
            sink(subject);
            return true;
        }
        if (segs[at_].isIndex || segs[at_].isKey)
            return false;
        switch (segs[at_].name)
        {
            static foreach (name; FieldNameTuple!T)
            {
            case name:
                return resolve!sink(__traits(getMember, subject, name),
                    segs, at_ + 1);
            }
            default:
                return false;
        }
    }
    else
    {
        if (at_ != segs.length)
            return false;
        sink(subject);
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The row model (PRT1).
// ─────────────────────────────────────────────────────────────────────────────

/// A half-open byte range into a row's label or badge text.
struct ByteSpan
{
    size_t start; ///
    size_t end;   ///
}

/// What a row is inside a search projection (`PRT33`).
enum SearchRole : ubyte
{
    none,    /// disclosure projection — no query
    direct,  /// a direct match
    context, /// an ancestor kept to explain a match's path
    status,  /// synthetic: capped / omitted / incomplete / no-match rows
}

/// Which record fields a query matched, as flags (`PRT30`).
enum MatchedField : ubyte
{
    none = 0,     ///
    label = 1,    ///
    path = 2,     ///
    value = 4,    ///
    doc = 8,      ///
}

/**
One row of the property tree: the flat, per-rebuild value snapshot the tree
components render. Carries exactly the capabilities the shared views probe
(`label`, `badge`, `expandable`) plus everything the property view needs —
the stable path, leaf kind, editability, metadata, and search decoration.
*/
struct PropertyNode
{
    string path;        /// stable address (`PRT6`); "" only for status rows
    string label;       /// display name (`@Label` override or the member name)
    string badge;       /// rendered value; "" for composites
    string doc;         /// `@Doc`
    string typeName;    ///
    string editor;      /// `@Editor` symbol identifier; "" = the kind's default
    LeafKind kind;      /// `LeafKind.none` for composites
    bool composite;     /// descends (aggregate / collection / erased / pointer)
    bool expandable;    /// the shared `nodeExpandable` capability
    bool editable;      /// an edit through the dispatch could succeed
    bool synthetic;     /// a status row: never editable, never addressable
    bool capped;        /// `⋯ (capped)` (`PRT4`)
    bool diagnostic;    /// e.g. duplicate element keys (`PRT7`)
    bool hasRange;      /// `@Range`
    double lo = 0;      /// ditto
    double hi = 0;      /// ditto
    double step = 0;    /// ditto
    string[] choices;   /// enumeration member names
    int depth;          ///
    SearchRole role;    /// search decoration (`PRT33`)
    long score;         /// ditto
    MatchedField matched; /// ditto
    ByteSpan[] labelSpans; /// canonical witness ranges in `label`
    ByteSpan[] badgeSpans; /// ditto in `badge`
    string snippet;     /// bounded secondary snippet for path/doc-only hits
}

/// Automatic-walk budgets and the component-wide write gate (`PRT4`, `PRT16`).
struct PropertyTreePolicy
{
    int maxDepth = 16;      /// levels below the roots before `⋯ (capped)`
    int maxNodes = 5_000;   /// flat nodes per rebuild before `⋯ (capped)`
    bool readOnly;          /// refuse every edit before the walk
}

// ─────────────────────────────────────────────────────────────────────────────
// The adapter (PRT1–PRT5): one type-only walk, driven by disclosure.
// ─────────────────────────────────────────────────────────────────────────────

/// Compile-time member metadata, resolved once per member site.
private struct MemberMeta
{
    string label;
    string doc;
    string editor;
    bool readOnly;
    bool hasRange;
    double lo = 0, hi = 0, step = 0;
}

/**
The reflective adapter (`PRT1`): rebuilds one `TreeData!PropertyNode` from
`ref T` and the host's `TreeViewState!string`, restoring selection by path
(`PRT8`). It retains no pointer to the subject (`PRT2`) — the subject is
whatever the host owns this frame.
*/
struct PropertyTree(T)
{
    /// The per-rebuild flat snapshot the tree components render.
    TreeData!PropertyNode data;
    /// Automatic-walk budgets + the read-only gate; host-configurable data.
    PropertyTreePolicy policy;

    private DisclosureState!string _open;
    private int _count;
    private bool _capped;

    /// Whether the last rebuild hit `maxDepth`/`maxNodes` (`PRT4`).
    bool wasCapped() const @safe pure nothrow @nogc => _capped;

    /**
    Rebuilds rows from the subject and the host's disclosure, restoring the
    selection to its previous path (else its nearest visible ancestor, else
    the ordinary clamp) and remeasuring content (`PRT8`, `PRT25`).
    */
    void rebuild(ref T subject, ref TreeViewState!string tv) @safe
    {
        import sparkles.ui.components.tree_view : measureContent;

        const prev = pathAt(tv, tv.sel);
        _open = tv.open;
        buildRows(subject);
        auto self = &this;
        tv.rows = flatten(data,
            (uint n) => self._open.isOpen(self.data.nodes[n].value.path));
        tv.measureContent(data);
        restoreSelection(tv, prev);
    }

    /// The selected row's stable path, or `""`.
    string selectedPath(in TreeViewState!string tv) const @safe pure nothrow @nogc
        => pathAt(tv, tv.sel);

    /// The disclosure key for a node — what the shared verbs need (`PRT1`).
    string keyOf(uint node) const @safe pure nothrow @nogc
        => data.nodes[node].value.path;

    /// The row's path at a visible-row index, or `""`.
    string pathAt(in TreeViewState!string tv, long row) const @safe pure nothrow @nogc
        => row >= 0 && row < cast(long) tv.rows.length
            && tv.rows[cast(size_t) row].node < data.nodes.length
            ? data.nodes[tv.rows[cast(size_t) row].node].value.path : "";

    /// Selects `path`'s row when present, else its nearest visible ancestor,
    /// else leaves the clamped cursor where it was (`PRT8`).
    void restoreSelection(ref TreeViewState!string tv, string path) @safe
    {
        auto want = path;
        while (want.length)
        {
            foreach (i, ref const r; tv.rows)
                if (data.nodes[r.node].value.path == want)
                {
                    tv.sel = cast(long) i;
                    tv.clamp();
                    return;
                }
            want = parentPath(want);
        }
        tv.clampBounds();
    }

    // ── the walk ────────────────────────────────────────────────────────────

    private void buildRows(ref T subject) @safe
    {
        data = TreeData!PropertyNode.init;
        _count = 0;
        _capped = false;
        addChildrenOf(subject, uint.max, "", -1, policy.readOnly);
    }

    private void addCappedRow(uint parent, int depth) @safe
    {
        if (_capped)
            return;
        _capped = true;
        PropertyNode n = {
            label: "⋯ (capped)",
            synthetic: true,
            capped: true,
            role: SearchRole.none,
            depth: depth,
        };
        data.add(n, parent);
    }

    /// Children of one already-added composite value.
    private void addChildrenOf(U)(ref U v, uint node, string path, int depth,
        bool inheritedRO) @safe
    {
        if (_capped)
            return;
        static if (hasPropChildren!U)
        {
            // The v1 erased seam is a read seam (`PRT5`).
            foreach (i, name, ref child; v.propChildren)
            {
                const p = name is null ? elementPath(path, i)
                    : childPath(path, name);
                const lbl = name is null
                    ? "[" ~ i.to!string ~ "]" : name.idup;
                addValueNode(child, node, p, lbl, depth + 1,
                    MemberMeta(label: lbl, readOnly: true));
                if (_capped)
                    return;
            }
        }
        else static if (is(U == P*, P))
        {
            if (v !is null)
                addChildrenOf(*v, node, path, depth, inheritedRO);
        }
        else static if (isArray!U && !isSomeString!U)
        {
            static if (hasElementKey!(typeof(v[0])))
            {
                // Duplicate keys: a visible diagnostic row, and addressing
                // refuses — it never falls back to an index (`PRT7`).
                bool dup;
                foreach (a; 0 .. v.length)
                    foreach (bIdx; a + 1 .. v.length)
                        if (v[a].propElementKey == v[bIdx].propElementKey)
                            dup = true;
                if (dup)
                {
                    PropertyNode d = {
                        label: "⚠ duplicate element key",
                        doc: "addressing refused; keys must be unique",
                        synthetic: true,
                        diagnostic: true,
                        depth: depth + 1,
                    };
                    data.add(d, node);
                    _count++;
                }
                foreach (i, ref e; v)
                {
                    const p = keyedPath(path, e.propElementKey);
                    addValueNode(e, node, p, "[#"
                        ~ e.propElementKey.to!string ~ "]", depth + 1,
                        MemberMeta(readOnly: inheritedRO));
                    if (_capped)
                        return;
                }
            }
            else
            {
                foreach (i, ref e; v)
                {
                    addValueNode(e, node, elementPath(path, i),
                        "[" ~ i.to!string ~ "]", depth + 1,
                        MemberMeta(readOnly: inheritedRO));
                    if (_capped)
                        return;
                }
            }
        }
        else static if (isAggregateType!U && !isSomeString!U)
        {
            static foreach (name; FieldNameTuple!U)
            {{
                alias M = __traits(getMember, U, name);
                static if (!hasUDA!(M, hidden))
                {{
                    alias F = typeof(__traits(getMember, U, name));
                    bool visible = true;
                    static if (hasUDA!(M, ShowIf))
                    {
                        // The condition is a compile-time-checked expression
                        // over the enclosing value — a typed predicate, no
                        // cast, no callback (`PRT10`).
                        enum cond = getUDAs!(M, ShowIf)[0].cond;
                        visible = mixin("v." ~ cond);
                    }
                    if (visible && !_capped)
                    {
                        MemberMeta meta;
                        meta.label = name;
                        meta.readOnly = inheritedRO || hasUDA!(M, readOnly);
                        static if (hasUDA!(M, Label))
                            meta.label = getUDAs!(M, Label)[0].text;
                        static if (hasUDA!(M, Doc))
                            meta.doc = getUDAs!(M, Doc)[0].text;
                        static if (hasUDA!(M, Range))
                        {
                            meta.hasRange = true;
                            meta.lo = getUDAs!(M, Range)[0].lo;
                            meta.hi = getUDAs!(M, Range)[0].hi;
                            meta.step = getUDAs!(M, Range)[0].step;
                        }
                        static foreach (uda; __traits(getAttributes, M))
                        {{
                            static if (is(uda == Editor!fn, alias fn))
                            {
                                // `@Editor` names a symbol; validated HERE, so
                                // an invalid combination fails the build
                                // (`PRT9`, `PRT11`).
                                static assert(leafKindOf!F != LeafKind.opaque
                                    && !descends!F,
                                    name ~ ": @Editor cannot make an opaque "
                                    ~ "or composite value assignable");
                                static assert(is(typeof(fn(F.init)) : F),
                                    name ~ ": @Editor symbol must accept and "
                                    ~ "emit " ~ F.stringof);
                                meta.editor = __traits(identifier, fn);
                            }
                        }}
                        addValueNode(__traits(getMember, v, name), node,
                            childPath(path, name), meta.label, depth + 1, meta);
                    }
                }}
            }}
        }
        else
        {
            // A leaf has no children; nothing to add.
        }
    }

    /// One value's row, and — when its path is open — its children (`PRT4`).
    private uint addValueNode(U)(ref U v, uint parent, string path,
        string label, int depth, MemberMeta meta) @safe
    {
        if (_capped)
            return uint.max;
        if (_count >= policy.maxNodes)
        {
            addCappedRow(parent, depth);
            return uint.max;
        }

        PropertyNode n = {
            path: path,
            label: label,
            doc: meta.doc,
            editor: meta.editor,
            typeName: U.stringof,
            depth: depth,
            hasRange: meta.hasRange,
            lo: meta.lo,
            hi: meta.hi,
            step: meta.step,
        };

        static if (descends!U)
        {
            n.composite = true;
            n.kind = LeafKind.none;
            static if (hasPropChildren!U)
            {
                static if (__traits(compiles, { bool e = v.propExpandable; }))
                    n.expandable = v.propExpandable;
                else
                    n.expandable = true;
                static if (__traits(compiles, { string s = v.propText; }))
                    n.badge = v.propText;
                n.editable = false; // the erased seam is read-only in v1
            }
            else static if (is(U == P*, P))
            {
                if (v is null)
                {
                    n.composite = false;
                    n.expandable = false;
                    n.badge = "null";
                    n.kind = LeafKind.opaque;
                }
                else
                    n.expandable = true;
                n.editable = false;
            }
            else static if (isArray!U && !isSomeString!U)
            {
                n.badge = "[" ~ v.length.to!string ~ "]";
                n.expandable = v.length > 0;
                n.editable = false;
            }
            else
            {
                n.expandable = true;
                n.editable = false;
            }
        }
        else
        {
            n.kind = leafKindOf!U;
            n.expandable = false;
            n.badge = renderLeaf(v);
            n.editable = !meta.readOnly && !policy.readOnly
                && n.kind != LeafKind.opaque;
            static if (is(U == enum))
                static foreach (m; __traits(allMembers, U))
                    n.choices ~= m;
        }

        const idx = data.add(n, parent);
        _count++;

        static if (descends!U)
            if (n.composite && n.expandable && _open.isOpen(path))
            {
                if (depth + 1 >= policy.maxDepth)
                    addCappedRow(idx, depth + 1);
                else
                    addChildrenOf(v, idx, path, depth, meta.readOnly);
            }
        return idx;
    }
}

/// The presented text of one leaf value.
private string renderLeaf(U)(ref U v) @safe
{
    static if (isBoolean!U)
        return v ? "true" : "false";
    else static if (isSomeString!U)
        return text('"', v, '"');
    else
        return text(v);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — the read core.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private enum FillKind : ubyte { solid, gradient, texture }

    @opaqueValue private struct Handle
    {
        ulong bits;
        string toString() const @safe pure => text("Handle(", bits, ")");
    }

    private uint tintSwatch(uint v) @safe pure nothrow @nogc => v;

    private struct KStop
    {
        ulong id;
        string name;
        double offset = 0;
        ulong propElementKey() const @safe pure nothrow @nogc => id;
    }

    private struct Fill
    {
        FillKind kind;
        @Range(0, 1, 0.05) double opacity = 1;
        @ShowIf("kind == FillKind.gradient") @Label("stop count") int stops = 2;
        KStop[] stopList;
    }

    private struct Dyn
    {
        enum Kind : ubyte { nil, number, str, object }

        Kind kind;
        double num;
        string s;
        Pair[] fields;

        static struct Pair { string key; Dyn value; }

        static Dyn of(double v) @safe pure nothrow
        {
            Dyn d;
            d.kind = Kind.number;
            d.num = v;
            return d;
        }

        static Dyn of(string v) @safe pure nothrow
        {
            Dyn d;
            d.kind = Kind.str;
            d.s = v;
            return d;
        }

        static Dyn obj(Pair[] v) @safe pure nothrow
        {
            Dyn d;
            d.kind = Kind.object;
            d.fields = v;
            return d;
        }

        auto propChildren() return @safe
        {
            static struct R
            {
                Dyn* self;
                // The seam's delegate is fixed `@safe` (the walk is
                // explicitly `@safe`, so the closure it passes checks
                // against this signature; a templated opApply would defeat
                // foreach parameter inference instead).
                int opApply(
                    scope int delegate(size_t, const(char)[], ref Dyn) @safe dg)
                    @safe
                {
                    if (self.kind == Kind.object)
                        foreach (i, ref f; self.fields)
                            if (auto r = dg(i, f.key, f.value))
                                return r;
                    return 0;
                }
            }
            return (() @trusted => R(&this))();
        }

        bool propExpandable() const @safe pure nothrow @nogc
            => kind == Kind.object;

        string propText() const @safe pure
        {
            final switch (kind)
            {
                case Kind.nil: return "null";
                case Kind.number: return num.to!string;
                case Kind.str: return `"` ~ s ~ `"`;
                case Kind.object:
                    return text("{", fields.length, " keys}");
            }
        }
    }

    private struct Layer
    {
        @Label("name") @Doc("shown in the layer list") string name = "layer";
        bool visible = true;
        Fill fill;
        int[] dashes;
        @readOnly ulong id = 42;
        @hidden uint revision;
        @Editor!tintSwatch uint tint = 0xff00ff;
        Handle handle;
        Dyn extra;
        Layer* linked; // cyclic under allOpen — the caps' reason to exist
    }

    private Layer sampleLayer() @safe
    {
        Layer l;
        l.dashes = [4, 2];
        l.fill.stopList = [KStop(7, "a", 0), KStop(9, "b", 1)];
        l.extra = Dyn.obj([
            Dyn.Pair("retries", Dyn.of(3.0)),
            Dyn.Pair("weird.key [0]", Dyn.of("hi")),
        ]);
        return l;
    }

    private TreeViewState!string freshView(int height = 40) @safe
    {
        TreeViewState!string tv;
        tv.width = 60;
        tv.height = height;
        return tv;
    }
}

@("ui.property_tree.pathGrammarRoundTrips")
@safe pure unittest
{
    PathSeg[] segs;
    assert(parsePath("style.opacity", segs) && segs.length == 2);
    assert(segs[1].name == "opacity");
    assert(parsePath("stops[2]", segs) && segs[1].isIndex && segs[1].index == 2);
    assert(parsePath("items[#7]", segs) && segs[1].isKey && segs[1].key == 7);
    assert(parsePath(`["weird.key [0]"]`, segs) && segs.length == 1);
    assert(segs[0].name == "weird.key [0]");

    // The emitter picks bare exactly when identifier-shaped, and every
    // emitted path re-parses to the same segments (PRT6).
    assert(childPath("fill", "tint") == "fill.tint");
    const quoted = childPath("extra", `say "hi"`);
    assert(parsePath(quoted, segs) && segs[$ - 1].name == `say "hi"`);
    assert(parentPath("a.b[2].c") == "a.b[2]");
    assert(parentPath(quoted) == "extra");
    assert(parentPath("a") == "");

    // Malformed text is refused, not guessed.
    PathSeg[] bad;
    assert(!parsePath("a..b", bad));
    assert(!parsePath("a[", bad));
    assert(!parsePath("a[x]", bad));
    assert(!parsePath(`a["unterminated`, bad));
    assert(!parsePath("a[#]", bad));
}

@("ui.property_tree.atAndResolveAgree")
@safe unittest
{
    auto l = sampleLayer();

    // Compile-time: a direct ref-returning access; a typo is a build error.
    assert(at!"fill.opacity"(l) == 1.0);
    at!"fill.opacity"(l) = 0.5;
    assert(l.fill.opacity == 0.5);
    static assert(!__traits(compiles, at!"fill.opacty"(l)));

    // Runtime: the same segments, refusals instead of faults.
    static string read(T)(ref T subject, string path) @safe
    {
        PathSeg[] segs;
        if (!parsePath(path, segs))
            return "<malformed>";
        string got = "<no such path>";
        const ok = resolve!((ref v) {
            static if (__traits(compiles, { string s2 = v.propText; }))
                got = v.propText;
            else static if (!descends!(typeof(v)))
                got = text(v);
        })(subject, segs);
        return ok ? got : "<no such path>";
    }

    assert(read(l, "fill.opacity") == "0.5");
    assert(read(l, "dashes[1]") == "2");
    assert(read(l, "fill.stopList[#9].name") == "b");
    assert(read(l, `extra.retries`) == "3");
    assert(read(l, `extra["weird.key [0]"]`) == `"hi"`);

    assert(read(l, "fill.nope") == "<no such path>");
    assert(read(l, "dashes[9]") == "<no such path>");
    assert(read(l, "fill.stopList[#3].name") == "<no such path>");
    assert(read(l, "dashes[#7]") == "<no such path>",
        "[#…] on an unkeyed collection is refused");
    assert(read(l, "linked.name") == "<no such path>",
        "a null pointer hop refuses, never faults");
    assert(read(l, "a..b") == "<malformed>");

    // Duplicate keys are refused, never resolved positionally (PRT7).
    l.fill.stopList = [KStop(7, "x"), KStop(7, "y")];
    assert(read(l, "fill.stopList[#7].name") == "<no such path>");
}

@("ui.property_tree.disclosureDrivesMaterialisation")
@safe unittest
{
    auto l = sampleLayer();
    PropertyTree!Layer pt;
    auto tv = freshView();

    // Everything closed: only the roots exist; `revision` is @hidden.
    pt.rebuild(l, tv);
    const rootCount = tv.rows.length;
    assert(rootCount > 0);
    foreach (ref const r; tv.rows)
        assert(pt.data.nodes[r.node].value.depth == 0);
    foreach (ref const nd; pt.data.nodes)
        assert(nd.value.label != "revision", "@hidden rows never exist");

    // A closed composite is expandable without materialised children.
    uint fillNode = uint.max;
    foreach (ref const r; tv.rows)
        if (pt.data.nodes[r.node].value.path == "fill")
            fillNode = r.node;
    assert(fillNode != uint.max);
    assert(pt.data.nodes[fillNode].value.expandable);
    assert(!pt.data.hasChildren(fillNode));

    // Opening one path admits exactly one more finite level.
    tv.open = tv.open.opened("fill");
    pt.rebuild(l, tv);
    assert(tv.rows.length > rootCount);
    bool sawOpacity;
    foreach (ref const r; tv.rows)
        sawOpacity |= pt.data.nodes[r.node].value.path == "fill.opacity";
    assert(sawOpacity);
    assert(!pt.wasCapped);
}

@("ui.property_tree.metadataShapesRows")
@safe unittest
{
    auto l = sampleLayer();
    PropertyTree!Layer pt;
    auto tv = freshView();
    tv.open = tv.open.opened("fill");
    pt.rebuild(l, tv);

    const(PropertyNode)* byPath(string p) @safe
    {
        foreach (ref const nd; pt.data.nodes)
            if (nd.value.path == p)
                return (() @trusted => &nd.value)();
        return null;
    }

    // @Label + @Doc.
    assert(byPath("name").label == "name" && byPath("name").doc.length);
    // @Range rides the row for the view's slider/stepper.
    assert(byPath("fill.opacity").hasRange && byPath("fill.opacity").hi == 1);
    // @readOnly refuses editability at the row level too.
    assert(!byPath("id").editable);
    // @Editor names a symbol; the row carries its identifier.
    assert(byPath("tint").editor == "tintSwatch");
    // @opaqueValue: a leaf via its own toString, never editable (PRT11).
    assert(byPath("handle").kind == LeafKind.opaque);
    assert(byPath("handle").badge == "Handle(0)");
    assert(!byPath("handle").editable);
    // Enum leaves carry their choices.
    assert(byPath("fill.kind").choices.length == 3);
    // Strings render quoted.
    assert(byPath("name").badge == `"layer"`);

    // @ShowIf: value-dependent visibility, re-evaluated per rebuild (PRT10).
    assert(byPath("fill.stops") is null, "solid hides the stop count");
    l.fill.kind = FillKind.gradient;
    pt.rebuild(l, tv);
    assert(byPath("fill.stops") !is null);
    assert(byPath("fill.stops").label == "stop count");
}

@("ui.property_tree.erasedSeamCrossesByCapability")
@safe unittest
{
    auto l = sampleLayer();
    PropertyTree!Layer pt;
    auto tv = freshView();
    tv.open = tv.open.opened("extra");
    pt.rebuild(l, tv);

    bool sawRetries, sawQuoted;
    foreach (ref const nd; pt.data.nodes)
    {
        if (nd.value.path == "extra.retries")
        {
            sawRetries = true;
            assert(nd.value.badge == "3");
            assert(!nd.value.editable, "the v1 erased seam is a read seam");
        }
        if (nd.value.path == `extra["weird.key [0]"]`)
            sawQuoted = true;
    }
    assert(sawRetries && sawQuoted);
}

@("ui.property_tree.allOpenTerminatesUnderCaps")
@safe unittest
{
    auto l = sampleLayer();
    (() @trusted { l.linked = &l; })(); // a genuine cycle
    PropertyTree!Layer pt;
    pt.policy.maxDepth = 6;
    pt.policy.maxNodes = 200;
    auto tv = freshView();
    tv.open = DisclosureState!string.allOpen;

    pt.rebuild(l, tv); // must terminate
    assert(pt.wasCapped);
    bool sawCapped;
    foreach (ref const nd; pt.data.nodes)
        if (nd.value.capped)
        {
            sawCapped = true;
            assert(nd.value.synthetic && !nd.value.editable);
            assert(nd.value.label == "⋯ (capped)");
        }
    assert(sawCapped, "a cut is visible, never silent");
    assert(pt.data.nodes.length <= 201 + 1);

    // A user-driven walk needs no caps: each click admits one finite level.
    auto tv2 = freshView();
    tv2.open = tv2.open.opened("linked").opened("linked.linked");
    PropertyTree!Layer pt2;
    pt2.rebuild(l, tv2);
    assert(!pt2.wasCapped);
    bool sawDeep;
    foreach (ref const nd; pt2.data.nodes)
        sawDeep |= nd.value.path == "linked.linked.linked";
    assert(sawDeep, "the cycle unrolls exactly as far as disclosure asks");
}

@("ui.property_tree.duplicateKeysDiagnoseVisibly")
@safe unittest
{
    auto l = sampleLayer();
    l.fill.stopList = [KStop(7, "x"), KStop(7, "y")];
    PropertyTree!Layer pt;
    auto tv = freshView();
    tv.open = tv.open.opened("fill").opened("fill.stopList");
    pt.rebuild(l, tv);

    bool sawDiagnostic;
    foreach (ref const nd; pt.data.nodes)
        sawDiagnostic |= nd.value.diagnostic;
    assert(sawDiagnostic, "duplicate keys produce a visible diagnostic row");
}

@("ui.property_tree.selectionRestoresByPathThenAncestor")
@safe unittest
{
    auto l = sampleLayer();
    PropertyTree!Layer pt;
    auto tv = freshView();
    tv.open = tv.open.opened("fill").opened("fill.stopList");
    pt.rebuild(l, tv);

    // Select the keyed element [#9], then reorder: the path follows it.
    foreach (i, ref const r; tv.rows)
        if (pt.data.nodes[r.node].value.path == "fill.stopList[#9]")
            tv.sel = cast(long) i;
    assert(pt.selectedPath(tv) == "fill.stopList[#9]");

    l.fill.stopList = [KStop(9, "b", 1), KStop(7, "a", 0)]; // reordered
    pt.rebuild(l, tv);
    assert(pt.selectedPath(tv) == "fill.stopList[#9]",
        "stable keys preserve selection through reorder (PRT8)");

    // Remove it: selection degrades to the nearest visible ancestor.
    l.fill.stopList = [KStop(7, "a", 0)];
    pt.rebuild(l, tv);
    assert(pt.selectedPath(tv) == "fill.stopList");
}

@("ui.property_tree.invalidMetadataFailsTheBuild")
@safe unittest
{
    // Negative probes (PRT9): a mistyped @Editor symbol, an @Editor on an
    // opaque leaf, and a bad @ShowIf member each refuse to compile.
    static string wrongType(string s) pure nothrow => s;
    static struct BadEditorType { @Editor!wrongType uint tint; }
    static Handle handleEditor(Handle h) pure nothrow => h;
    static struct BadEditorOpaque { @Editor!handleEditor Handle handle; }
    static struct BadShowIf { int kind; @ShowIf("knid == 1") int stops; }

    static bool builds(S)() => __traits(compiles, {
        S s;
        PropertyTree!S pt;
        TreeViewState!string tv;
        pt.rebuild(s, tv);
    });

    static assert(builds!Fill());
    static assert(!builds!BadEditorType());
    static assert(!builds!BadEditorOpaque());
    static assert(!builds!BadShowIf());
}

// ─────────────────────────────────────────────────────────────────────────────
// Edits and refusals are values (PRT14–PRT16).
// ─────────────────────────────────────────────────────────────────────────────

/// Whether an edit is part of a live interaction or completes one (`PRT19`).
enum EditPhase : ubyte
{
    preview, /// mutates the subject; adds no history entry
    commit,  /// completes the interaction; records exactly one entry
}

/**
The closed leaf-value vocabulary an edit carries (`PRT14`). A Regular value:
equality is total — floating payloads compare by stored representation, so a
NaN-valued edit cannot be stale relative to itself (`PRT15`).
*/
struct EditValue
{
    /// ditto
    enum Kind : ubyte { none, boolean, integral, floating, text, enumeration }

    Kind kind;  ///
    bool b;     ///
    long i;     ///
    double f;   ///
    string s;   /// text payload / enumeration member name

    ///
    static EditValue of(bool v) @safe pure nothrow @nogc
        => EditValue(Kind.boolean, v);
    /// ditto
    static EditValue of(long v) @safe pure nothrow @nogc
        => EditValue(Kind.integral, false, v);
    /// ditto
    static EditValue of(double v) @safe pure nothrow @nogc
        => EditValue(Kind.floating, false, 0, v);
    /// ditto
    static EditValue ofText(string v) @safe pure nothrow @nogc
        => EditValue(Kind.text, false, 0, 0, v);
    /// ditto
    static EditValue ofEnum(string member) @safe pure nothrow @nogc
        => EditValue(Kind.enumeration, false, 0, 0, member);

    /// Total equality: doubles compare bitwise, so `NaN == NaN` here.
    bool opEquals(in EditValue o) const @safe pure nothrow @nogc
        => kind == o.kind && b == o.b && i == o.i
            && doubleBits(f) == doubleBits(o.f) && s == o.s;

    /// The presented text of this value.
    string toText() const @safe pure
    {
        final switch (kind)
        {
            case Kind.none: return "∅";
            case Kind.boolean: return b ? "true" : "false";
            case Kind.integral: return i.to!string;
            case Kind.floating: return f.to!string;
            case Kind.text: return text('"', s, '"');
            case Kind.enumeration: return s;
        }
    }

    /// This value with its text payload owned (an `in Edit`'s text is scope
    /// and must be copied before it can be stored — `PRT14`).
    EditValue owned() const scope @safe pure nothrow
        => EditValue(kind, b, i, f, s.length ? s.idup : null);
}

/// The one deliberate reinterpretation total floating equality needs.
private ulong doubleBits(double v) @trusted pure nothrow @nogc
    => *cast(const ulong*) &v;

/// Why a write (or history operation) was refused. Rendered inline at the
/// addressed row (`PRT21`); never an exception (`PRT14`).
enum RefusalKind : ubyte
{
    none,             ///
    malformedPath,    ///
    noSuchPath,       ///
    nullTraversal,    ///
    readOnlyField,    /// `@readOnly`, an opaque leaf, or the erased read seam
    readOnlyPolicy,   /// `PropertyTreePolicy(readOnly: true)`
    typeMismatch,     /// wrong `EditValue` kind / unknown enum member
    outOfRange,       /// width, signedness, lossy narrowing, or `@Range`
    staleHistory,     /// undo/redo precondition failed (`PRT18`)
    staleInteraction, /// the subject changed under a pending group (`PRT19`)
    editInProgress,   /// a different-path operation during a pending group
    duplicateKey,     /// `[#k]` matched more than one element (`PRT7`)
    emptyHistory,     /// undo/redo with nothing to replay
}

/// A path-addressed refusal value.
struct Refusal
{
    RefusalKind kind;  ///
    string path;       ///
    string detail;     ///

    /// ditto
    bool refused() const @safe pure nothrow @nogc
        => kind != RefusalKind.none;
}

/// An edit is an owned value; applying it never throws for user input.
struct Edit
{
    string path;                        ///
    EditValue value;                    ///
    EditPhase phase = EditPhase.commit; ///
}

/// What applying an edit produced: the inverse, or a refusal (`PRT14`).
struct Applied
{
    Refusal refusal; ///
    Edit inverse;    /// valid when `ok`

    /// ditto
    bool ok() const @safe pure nothrow @nogc => !refusal.refused;
}

/**
The raw generated dispatch (`PRT14`–`PRT16`): parses the path, walks the
subject, checks `@readOnly`, the policy, `EditValue` kind, signedness/width,
exact floating representability, enum membership and `@Range` $(B before)
mutating, and returns the inverse. History-free — hosts normally go through
$(LREF editProperty), which adds the transaction rules.
*/
Applied applyEdit(T)(ref T subject, in Edit e,
    in PropertyTreePolicy policy = PropertyTreePolicy.init) @safe
{
    static Applied refuse(RefusalKind k, in Edit e, string detail = null) @safe
        => Applied(Refusal(k, e.path.idup, detail));

    if (policy.readOnly)
        return refuse(RefusalKind.readOnlyPolicy, e,
            "the whole component is read-only");
    PathSeg[] segs;
    if (!parsePath(e.path, segs))
        return refuse(RefusalKind.malformedPath, e);
    if (segs.length == 0)
        return refuse(RefusalKind.noSuchPath, e);
    EditValue old;
    const k = applyAt(subject, segs, 0, e.value, false, false,
        double.nan, double.nan, old);
    if (k != RefusalKind.none)
        return refuse(k, e);
    return Applied(Refusal.init, Edit(e.path.idup, old, EditPhase.commit));
}

private RefusalKind applyAt(T)(ref T subject, in PathSeg[] segs, size_t at_,
    in EditValue val, bool ro, bool hasRange, double lo, double hi,
    out EditValue old) @safe
{
    static if (hasPropChildren!T)
        return RefusalKind.readOnlyField; // the v1 erased seam is a read seam
    else static if (is(T == U*, U))
    {
        if (subject is null)
            return RefusalKind.nullTraversal;
        return applyAt(*subject, segs, at_, val, ro, hasRange, lo, hi, old);
    }
    else static if (isArray!T && !isSomeString!T)
    {
        if (at_ >= segs.length)
            return RefusalKind.typeMismatch; // structural edits: not in v1
        static if (hasElementKey!(typeof(subject[0])))
        {
            if (segs[at_].isKey)
            {
                size_t found, hits;
                foreach (idx; 0 .. subject.length)
                    if (subject[idx].propElementKey == segs[at_].key)
                    {
                        found = idx;
                        hits++;
                    }
                if (hits > 1)
                    return RefusalKind.duplicateKey;
                if (hits == 0)
                    return RefusalKind.noSuchPath;
                return applyAt(subject[found], segs, at_ + 1, val, ro,
                    hasRange, lo, hi, old);
            }
        }
        if (!segs[at_].isIndex || segs[at_].index >= subject.length)
            return RefusalKind.noSuchPath;
        return applyAt(subject[segs[at_].index], segs, at_ + 1, val, ro,
            hasRange, lo, hi, old);
    }
    else static if (isAggregateType!T && !isSomeString!T
        && !hasUDA!(T, opaqueValue))
    {
        if (at_ >= segs.length)
            return RefusalKind.typeMismatch; // a composite is not assignable
        if (segs[at_].isIndex || segs[at_].isKey)
            return RefusalKind.noSuchPath;
        switch (segs[at_].name)
        {
            static foreach (name; FieldNameTuple!T)
            {{
            case name:
                alias M = __traits(getMember, T, name);
                // `@readOnly` refuses the whole subtree, HERE, inside the
                // generated dispatch — no view can route around it (PRT16).
                enum mro = hasUDA!(M, readOnly);
                enum mHasRange = hasUDA!(M, Range);
                static if (mHasRange)
                {
                    enum mLo = getUDAs!(M, Range)[0].lo;
                    enum mHi = getUDAs!(M, Range)[0].hi;
                }
                else
                {
                    enum mLo = double.nan;
                    enum mHi = double.nan;
                }
                if (at_ + 1 == segs.length)
                {
                    if (ro || mro)
                        return RefusalKind.readOnlyField;
                    static if (descends!(typeof(__traits(getMember, T, name))))
                        return RefusalKind.typeMismatch; // structural (PRT22)
                    else
                        return assignLeaf(__traits(getMember, subject, name),
                            val, mHasRange || hasRange,
                            mHasRange ? mLo : lo, mHasRange ? mHi : hi, old);
                }
                return applyAt(__traits(getMember, subject, name), segs,
                    at_ + 1, val, ro || mro, mHasRange || hasRange,
                    mHasRange ? mLo : lo, mHasRange ? mHi : hi, old);
            }}
            default:
                return RefusalKind.noSuchPath;
        }
    }
    else
    {
        // A leaf with segments left over, or an addressed leaf whose parent
        // arm did not consume it (an opaque aggregate).
        if (at_ < segs.length)
            return RefusalKind.noSuchPath;
        if (ro)
            return RefusalKind.readOnlyField;
        return assignLeaf(subject, val, hasRange, lo, hi, old);
    }
}

/// Lossless, total assignment over the supported leaves (`PRT15`).
private RefusalKind assignLeaf(V)(ref V v, in EditValue e, bool hasRange,
    double lo, double hi, out EditValue old) @safe
{
    static if (is(V == bool))
    {
        if (e.kind != EditValue.Kind.boolean)
            return RefusalKind.typeMismatch;
        old = EditValue.of(v);
        v = e.b;
        return RefusalKind.none;
    }
    else static if (is(V == enum))
    {
        if (e.kind != EditValue.Kind.enumeration)
            return RefusalKind.typeMismatch;
        old = EditValue.ofEnum(text(v));
        switch (e.s)
        {
            static foreach (m; __traits(allMembers, V))
            {
            case m:
                v = __traits(getMember, V, m);
                return RefusalKind.none;
            }
            default:
                return RefusalKind.typeMismatch; // the member must exist
        }
    }
    else static if (isIntegral!V)
    {
        if (e.kind != EditValue.Kind.integral)
            return RefusalKind.typeMismatch;
        // Signedness and width, checked before mutation.
        static if (__traits(isUnsigned, V))
        {
            if (e.i < 0 || cast(ulong) e.i > cast(ulong) V.max)
                return RefusalKind.outOfRange;
        }
        else
        {
            if (e.i < cast(long) V.min || e.i > cast(long) V.max)
                return RefusalKind.outOfRange;
        }
        if (hasRange && (e.i < cast(long) lo || e.i > cast(long) hi))
            return RefusalKind.outOfRange;
        old = EditValue.of(cast(long) v);
        v = cast(V) e.i;
        return RefusalKind.none;
    }
    else static if (isFloatingPoint!V)
    {
        if (e.kind != EditValue.Kind.floating)
            return RefusalKind.typeMismatch;
        // The payload must round-trip exactly through the target width.
        const narrowed = cast(double) cast(V) e.f;
        if (doubleBits(narrowed) != doubleBits(e.f))
            return RefusalKind.outOfRange;
        if (hasRange && !(e.f >= lo && e.f <= hi))
            return RefusalKind.outOfRange; // NaN fails a ranged leaf
        old = EditValue.of(cast(double) v);
        v = cast(V) e.f;
        return RefusalKind.none;
    }
    else static if (isSomeString!V)
    {
        if (e.kind != EditValue.Kind.text)
            return RefusalKind.typeMismatch;
        // dip1000 earns its keep: an `in Edit`'s text is scope, so it cannot
        // enter the subject or history without this copy (PRT14).
        old = EditValue.ofText(v.idup);
        v = e.s.idup;
        return RefusalKind.none;
    }
    else
        return RefusalKind.readOnlyField; // opaque: never assignable in v1
}

/**
Reads the leaf value at `path` as an `EditValue` — the precondition probe
undo/redo and pending groups use (`PRT18`, `PRT19`). Answers `false` for a
missing path or a non-leaf target.
*/
bool readValueAt(T)(ref T subject, scope const(char)[] path,
    out EditValue val) @safe
{
    PathSeg[] segs;
    if (!parsePath(path, segs))
        return false;
    bool got;
    EditValue tmp;
    resolve!((ref v) {
        alias V = typeof(v);
        static if (is(V == bool))
        {
            tmp = EditValue.of(v);
            got = true;
        }
        else static if (is(V == enum))
        {
            tmp = EditValue.ofEnum(text(v));
            got = true;
        }
        else static if (isIntegral!V)
        {
            tmp = EditValue.of(cast(long) v);
            got = true;
        }
        else static if (isFloatingPoint!V)
        {
            tmp = EditValue.of(cast(double) v);
            got = true;
        }
        else static if (isSomeString!V)
        {
            tmp = EditValue.ofText(v.idup);
            got = true;
        }
    })(subject, segs);
    val = tmp;
    return got;
}

// ─────────────────────────────────────────────────────────────────────────────
// Undo/redo belongs to the component; the state belongs to the host
// (PRT17–PRT21).
// ─────────────────────────────────────────────────────────────────────────────

/// One committed interaction: the path and the exact before/after values.
struct HistoryEntry
{
    string path;      ///
    EditValue before; ///
    EditValue after;  ///
}

/**
The per-logical-subject edit state (`PRT17`): undo, redo, the pending preview
group, and the path-addressed refusal display, as one serialisable value the
host stores $(B beside the subject) — two panes over one subject share it, and
rebinding to a replacement subject means resetting it.
*/
struct PropertyEditState
{
    HistoryEntry[] undo; ///
    HistoryEntry[] redo; ///

    /// The pending preview group (`PRT19`): live from the first successful
    /// preview until the next commit on the same path.
    bool pendingActive;      ///
    string pendingPath;      /// ditto
    EditValue pendingBefore; /// the value before the interaction began
    EditValue pendingLast;   /// the last value the group wrote

    /// Path-addressed refusals, latest per path; a path's next success
    /// clears its entry (`PRT21`).
    Refusal[] refusals;

    /// History bounds (`PRT20`): entries across both stacks, and logical
    /// payload bytes. Eviction removes oldest undo entries whole after a
    /// commit; the just-committed entry is always retained.
    size_t maxHistoryEntries = 256;
    /// ditto
    size_t maxHistoryBytes = 1_048_576;

    /// Availability queries for the host's binding table (`PRT23`).
    bool canUndo() const @safe pure nothrow @nogc
        => !pendingActive && undo.length > 0;
    /// ditto
    bool canRedo() const @safe pure nothrow @nogc
        => !pendingActive && redo.length > 0;

    /// The current refusal addressed to `path`, or an empty value.
    Refusal refusalFor(scope const(char)[] path) const @safe pure nothrow @nogc
    {
        foreach (ref const r; refusals)
            if (r.path == path)
                return r;
        return Refusal.init;
    }

    private void note(in Refusal r) @safe pure nothrow
    {
        foreach (ref slot; refusals)
            if (slot.path == r.path)
            {
                slot = Refusal(r.kind, r.path.idup, r.detail.idup);
                return;
            }
        refusals ~= Refusal(r.kind, r.path.idup, r.detail.idup);
    }

    private void clearFor(scope const(char)[] path) @safe pure nothrow
    {
        foreach (i, ref const r; refusals)
            if (r.path == path)
            {
                refusals = refusals[0 .. i] ~ refusals[i + 1 .. $];
                return;
            }
    }

    /// Logical payload bytes of one entry, as the byte bound counts them.
    private static size_t entryBytes(in HistoryEntry e) @safe pure nothrow @nogc
        => e.path.length + e.before.s.length + e.after.s.length
            + 2 * EditValue.sizeof;

    private size_t historyBytes() const @safe pure nothrow @nogc
    {
        size_t total;
        foreach (ref const e; undo)
            total += entryBytes(e);
        foreach (ref const e; redo)
            total += entryBytes(e);
        return total;
    }

    /// Evicts oldest undo entries whole until both bounds hold; the newest
    /// undo entry is always retained, even when it alone exceeds the byte
    /// bound (`PRT20`).
    private void evict() @safe pure nothrow
    {
        while (undo.length > 1
            && (undo.length + redo.length > maxHistoryEntries
                || historyBytes() > maxHistoryBytes))
            undo = undo[1 .. $];
    }
}

/**
The transactional edit verb (`PRT18`–`PRT21`): $(LREF applyEdit) plus the
interaction-scoped grouping rules. The subject arrives by `ref` per call; the
state is the host's per-subject value.
*/
Applied editProperty(T)(ref T subject, in Edit e, ref PropertyEditState es,
    in PropertyTreePolicy policy = PropertyTreePolicy.init) @safe
{
    // A different path cannot join a pending group (PRT19 rule 5).
    if (es.pendingActive && e.path != es.pendingPath)
    {
        auto r = Applied(Refusal(RefusalKind.editInProgress, e.path.idup,
            "an interaction is pending on " ~ es.pendingPath));
        es.note(r.refusal);
        return r;
    }

    // Each later step requires the current value to equal the last value the
    // group wrote; an external change makes the interaction stale and
    // discards the group WITHOUT overwriting that change (PRT19 rule 5).
    if (es.pendingActive)
    {
        EditValue current;
        if (!readValueAt(subject, es.pendingPath, current)
            || current != es.pendingLast)
        {
            es.pendingActive = false;
            auto r = Applied(Refusal(RefusalKind.staleInteraction,
                e.path.idup, "the subject changed under the interaction"));
            es.note(r.refusal);
            return r;
        }
    }

    auto applied = applyEdit(subject, e, policy);
    if (!applied.ok)
    {
        es.note(applied.refusal); // refusals never change history (PRT20)
        return applied;
    }
    es.clearFor(e.path);

    final switch (e.phase)
    {
        case EditPhase.preview:
            if (!es.pendingActive)
            {
                // The first successful edit of a new interaction (PRT20).
                es.pendingActive = true;
                es.pendingPath = e.path.idup;
                es.pendingBefore = applied.inverse.value;
                es.redo = null;
            }
            es.pendingLast = e.value.owned;
            break;
        case EditPhase.commit:
            EditValue before;
            if (es.pendingActive)
            {
                before = es.pendingBefore; // one entry per interaction
                es.pendingActive = false;
            }
            else
            {
                before = applied.inverse.value;
                es.redo = null; // a lone commit is its own new interaction
            }
            es.undo ~= HistoryEntry(e.path.idup, before, e.value.owned);
            es.evict();
            applied.inverse.value = before;
            break;
    }
    return applied;
}

/**
The commit boundary (`PRT19`): pointer release, pointer cancellation and
focus loss must finish a pending group with its last previewed value before
routing the event onward. A no-op without a pending group.
*/
Applied finishPending(T)(ref T subject, ref PropertyEditState es,
    in PropertyTreePolicy policy = PropertyTreePolicy.init) @safe
{
    if (!es.pendingActive)
        return Applied.init;
    return editProperty(subject,
        Edit(es.pendingPath, es.pendingLast, EditPhase.commit), es, policy);
}

/**
Undo (`PRT18`): applies only when the addressed value still equals the
entry's `after`; a stale or missing path refuses and leaves the subject and
both stacks unchanged.
*/
Applied undoProperty(T)(ref T subject, ref PropertyEditState es,
    in PropertyTreePolicy policy = PropertyTreePolicy.init) @safe
    => replayHistory!(false)(subject, es, policy);

/// Redo: symmetric — the value must equal the entry's `before`.
Applied redoProperty(T)(ref T subject, ref PropertyEditState es,
    in PropertyTreePolicy policy = PropertyTreePolicy.init) @safe
    => replayHistory!(true)(subject, es, policy);

private Applied replayHistory(bool redoDir, T)(ref T subject,
    ref PropertyEditState es, in PropertyTreePolicy policy) @safe
{
    // While a group is pending, history operations refuse without mutation.
    if (es.pendingActive)
        return Applied(Refusal(RefusalKind.editInProgress, es.pendingPath,
            "an interaction is pending"));
    auto stack = redoDir ? &es.redo : &es.undo;
    if ((*stack).length == 0)
        return Applied(Refusal(RefusalKind.emptyHistory, ""));

    auto entry = (*stack)[$ - 1];
    const expect = redoDir ? entry.before : entry.after;
    const write = redoDir ? entry.after : entry.before;

    EditValue current;
    if (!readValueAt(subject, entry.path, current) || current != expect)
        return Applied(Refusal(RefusalKind.staleHistory, entry.path,
            "the subject no longer holds the value this entry recorded"));

    auto applied = applyEdit(subject, Edit(entry.path, write), policy);
    if (!applied.ok)
        return applied;
    // Moving an entry between stacks never changes the combined budget.
    *stack = (*stack)[0 .. $ - 1];
    static if (redoDir)
        es.undo ~= entry;
    else
        es.redo ~= entry;
    es.clearFor(entry.path);
    return applied;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — the edit path.
// ─────────────────────────────────────────────────────────────────────────────

@("ui.property_tree.editValueEqualityIsTotal")
@safe pure nothrow @nogc unittest
{
    // NaN payloads compare by stored representation, so a value cannot be
    // stale relative to itself (PRT15).
    assert(EditValue.of(double.nan) == EditValue.of(double.nan));
    assert(EditValue.of(1.5) == EditValue.of(1.5));
    assert(EditValue.of(1.5) != EditValue.of(2.5));
    assert(EditValue.of(0.0) != EditValue.of(-0.0), "bitwise: -0 is not 0");
    assert(EditValue.of(true) != EditValue.of(1L), "kinds never cross-equal");
}

@("ui.property_tree.applyReturnsInverseAndRefusals")
@safe unittest
{
    auto l = sampleLayer();

    // A successful edit returns its exact inverse (PRT14).
    auto r = applyEdit(l, Edit("fill.opacity", EditValue.of(0.25)));
    assert(r.ok && l.fill.opacity == 0.25);
    assert(r.inverse.value == EditValue.of(1.0));
    assert(applyEdit(l, r.inverse).ok && l.fill.opacity == 1.0);

    // Every leaf kind assigns losslessly.
    assert(applyEdit(l, Edit("visible", EditValue.of(false))).ok);
    assert(l.visible == false);
    assert(applyEdit(l, Edit("fill.kind", EditValue.ofEnum("gradient"))).ok);
    assert(l.fill.kind == FillKind.gradient);
    assert(applyEdit(l, Edit("name", EditValue.ofText("bg"))).ok);
    assert(l.name == "bg");
    assert(applyEdit(l, Edit("dashes[1]", EditValue.of(8L))).ok);
    assert(l.dashes[1] == 8);
    assert(applyEdit(l, Edit("fill.stopList[#9].offset",
        EditValue.of(0.75))).ok);
    assert(l.fill.stopList[1].offset == 0.75);

    // Refusals are values, addressed to their path (PRT14, PRT21).
    static RefusalKind kindOf(Applied a) @safe => a.refusal.kind;

    assert(kindOf(applyEdit(l, Edit("id", EditValue.of(7L))))
        == RefusalKind.readOnlyField);
    assert(kindOf(applyEdit(l, Edit("name", EditValue.of(1L))))
        == RefusalKind.typeMismatch);
    assert(kindOf(applyEdit(l, Edit("fill.kind", EditValue.ofEnum("nope"))))
        == RefusalKind.typeMismatch, "the enum member must exist");
    assert(kindOf(applyEdit(l, Edit("fill.opacity", EditValue.of(1.5))))
        == RefusalKind.outOfRange, "@Range is enforced before mutation");
    assert(l.fill.opacity == 1.0, "a refused edit never mutates");
    assert(kindOf(applyEdit(l, Edit("nope", EditValue.of(1L))))
        == RefusalKind.noSuchPath);
    assert(kindOf(applyEdit(l, Edit("a..b", EditValue.of(1L))))
        == RefusalKind.malformedPath);
    assert(kindOf(applyEdit(l, Edit("linked.name", EditValue.ofText("x"))))
        == RefusalKind.nullTraversal);
    assert(kindOf(applyEdit(l, Edit("handle", EditValue.of(1L))))
        == RefusalKind.readOnlyField, "opaque is never assignable");
    assert(kindOf(applyEdit(l, Edit("extra.retries", EditValue.of(1.0))))
        == RefusalKind.readOnlyField, "the erased seam is a read seam");
    assert(kindOf(applyEdit(l, Edit("fill", EditValue.of(1L))))
        == RefusalKind.typeMismatch, "a composite is not assignable (PRT22)");
    assert(kindOf(applyEdit(l, Edit("name", EditValue.ofText("x")),
        PropertyTreePolicy(readOnly: true))) == RefusalKind.readOnlyPolicy);

    l.fill.stopList = [KStop(7, "x"), KStop(7, "y")];
    assert(kindOf(applyEdit(l, Edit("fill.stopList[#7].offset",
        EditValue.of(0.1)))) == RefusalKind.duplicateKey);
}

@("ui.property_tree.assignmentIsLosslessOverWidths")
@safe unittest
{
    static struct Widths
    {
        byte b;
        ubyte ub;
        float f;
    }

    Widths w;
    assert(applyEdit(w, Edit("b", EditValue.of(-128L))).ok);
    assert(applyEdit(w, Edit("b", EditValue.of(128L))).refusal.kind
        == RefusalKind.outOfRange, "width is checked before mutation");
    assert(applyEdit(w, Edit("ub", EditValue.of(-1L))).refusal.kind
        == RefusalKind.outOfRange, "signedness too");
    assert(applyEdit(w, Edit("ub", EditValue.of(255L))).ok);

    // A float leaf accepts only payloads that round-trip exactly.
    assert(applyEdit(w, Edit("f", EditValue.of(0.5))).ok);
    assert(applyEdit(w, Edit("f", EditValue.of(0.1))).refusal.kind
        == RefusalKind.outOfRange, "0.1 is not representable as float");
    assert(w.f == 0.5f);
}

@("ui.property_tree.previewGroupingIsInteractionScoped")
@safe unittest
{
    auto l = sampleLayer();
    PropertyEditState es;

    // Previews mutate the subject but add no history (PRT19 rules 1–2).
    foreach (v; [0.8, 0.6, 0.4])
        assert(editProperty(l, Edit("fill.opacity", EditValue.of(v),
            EditPhase.preview), es).ok);
    assert(l.fill.opacity == 0.4);
    assert(es.undo.length == 0 && es.pendingActive);

    // A different path cannot join the group; history refuses too (rule 5).
    assert(editProperty(l, Edit("visible", EditValue.of(false), ), es)
        .refusal.kind == RefusalKind.editInProgress);
    assert(l.visible == true, "refused without mutation");
    assert(undoProperty(l, es).refusal.kind == RefusalKind.editInProgress);

    // The commit records ONE entry, from the pre-preview value (rule 3).
    assert(editProperty(l, Edit("fill.opacity", EditValue.of(0.4)), es).ok);
    assert(!es.pendingActive);
    assert(es.undo.length == 1);
    assert(es.undo[0].before == EditValue.of(1.0));
    assert(es.undo[0].after == EditValue.of(0.4));

    // Undo restores the pre-interaction value in one step.
    assert(undoProperty(l, es).ok);
    assert(l.fill.opacity == 1.0);

    // A commit without a preview is one entry; two completed commits never
    // merge (rule 4).
    assert(editProperty(l, Edit("visible", EditValue.of(false)), es).ok);
    assert(editProperty(l, Edit("visible", EditValue.of(true)), es).ok);
    assert(es.undo.length == 2);
}

@("ui.property_tree.staleInteractionDiscardsWithoutOverwrite")
@safe unittest
{
    auto l = sampleLayer();
    PropertyEditState es;

    assert(editProperty(l, Edit("fill.opacity", EditValue.of(0.5),
        EditPhase.preview), es).ok);
    l.fill.opacity = 0.9; // an external write under the drag

    const r = editProperty(l, Edit("fill.opacity", EditValue.of(0.3),
        EditPhase.preview), es);
    assert(r.refusal.kind == RefusalKind.staleInteraction);
    assert(l.fill.opacity == 0.9, "the external change is not overwritten");
    assert(!es.pendingActive, "the pending group is discarded");
    assert(es.undo.length == 0);
}

@("ui.property_tree.finishPendingIsTheCommitBoundary")
@safe unittest
{
    auto l = sampleLayer();
    PropertyEditState es;

    assert(editProperty(l, Edit("fill.opacity", EditValue.of(0.7),
        EditPhase.preview), es).ok);
    // Pointer release / cancellation / focus loss: the input owner finishes
    // the group with its last previewed value (PRT19).
    assert(finishPending(l, es).ok);
    assert(!es.pendingActive && es.undo.length == 1);
    assert(es.undo[0].before == EditValue.of(1.0));
    assert(es.undo[0].after == EditValue.of(0.7));
    assert(finishPending(l, es).refusal.kind == RefusalKind.none,
        "a no-op without a pending group");
    assert(es.undo.length == 1);
}

@("ui.property_tree.undoRedoPreconditionsCatchExternalWrites")
@safe unittest
{
    auto l = sampleLayer();
    PropertyEditState es;

    assert(editProperty(l, Edit("name", EditValue.ofText("bg")), es).ok);
    assert(editProperty(l, Edit("name", EditValue.ofText("fg")), es).ok);
    assert(es.undo.length == 2);

    // Undo requires the addressed value to equal `after` (PRT18).
    l.name = "external";
    const r = undoProperty(l, es);
    assert(r.refusal.kind == RefusalKind.staleHistory);
    assert(l.name == "external" && es.undo.length == 2 && es.redo.length == 0,
        "a failed precondition leaves the subject and both stacks unchanged");

    l.name = "fg"; // the recorded state returns
    assert(undoProperty(l, es).ok && l.name == "bg");
    assert(es.undo.length == 1 && es.redo.length == 1);

    // Redo requires `before`.
    l.name = "poked";
    assert(redoProperty(l, es).refusal.kind == RefusalKind.staleHistory);
    l.name = "bg";
    assert(redoProperty(l, es).ok && l.name == "fg");

    // The first successful edit of a new interaction clears redo; refused
    // edits do not (PRT20).
    assert(undoProperty(l, es).ok);
    assert(es.redo.length == 1);
    assert(!editProperty(l, Edit("id", EditValue.of(1L)), es).ok);
    assert(es.redo.length == 1, "a refusal never clears redo");
    assert(editProperty(l, Edit("visible", EditValue.of(false)), es).ok);
    assert(es.redo.length == 0);

    assert(undoProperty(l, es).ok, "visible returns");
    assert(undoProperty(l, es).ok, "…then the first name edit");
    assert(l.name == "layer");
    assert(undoProperty(l, es).refusal.kind == RefusalKind.emptyHistory);
}

@("ui.property_tree.historyEvictsOldestWholeAndKeepsTheNewest")
@safe unittest
{
    auto l = sampleLayer();
    PropertyEditState es;
    es.maxHistoryEntries = 3;

    foreach (i; 0 .. 5)
        assert(editProperty(l, Edit("dashes[0]",
            EditValue.of(cast(long) i)), es).ok);
    assert(es.undo.length == 3, "oldest entries evicted whole");
    assert(es.undo[0].before == EditValue.of(1L),
        "the surviving prefix is the newest");

    // The byte bound: the just-committed entry survives even alone over it.
    PropertyEditState tiny;
    tiny.maxHistoryBytes = 8;
    assert(editProperty(l, Edit("name",
        EditValue.ofText("a very long value that exceeds eight bytes")),
        tiny).ok);
    assert(tiny.undo.length == 1, "the newest entry is always retained");
    assert(editProperty(l, Edit("name", EditValue.ofText("second")),
        tiny).ok);
    assert(tiny.undo.length == 1, "…and evicts everything older");
    assert(tiny.undo[0].after == EditValue.ofText("second"));
}

@("ui.property_tree.refusalsRenderInlineAndClearOnSuccess")
@safe unittest
{
    auto l = sampleLayer();
    PropertyEditState es;

    assert(!editProperty(l, Edit("fill.opacity", EditValue.of(9.0)), es).ok);
    assert(es.refusalFor("fill.opacity").kind == RefusalKind.outOfRange,
        "the refusal is addressed to its row (PRT21)");
    assert(es.refusalFor("name").kind == RefusalKind.none);

    assert(editProperty(l, Edit("fill.opacity", EditValue.of(0.5)), es).ok);
    assert(es.refusalFor("fill.opacity").kind == RefusalKind.none,
        "that path's next success clears it");
}

@("ui.property_tree.editThenRebuildRefreshesAndPreserves")
@safe unittest
{
    // PRT25: a successful edit followed by rebuild refreshes values and
    // conditional visibility while preserving disclosure and selection.
    auto l = sampleLayer();
    PropertyTree!Layer pt;
    PropertyEditState es;
    auto tv = freshView();
    tv.open = tv.open.opened("fill");
    pt.rebuild(l, tv);

    foreach (i, ref const r; tv.rows)
        if (pt.data.nodes[r.node].value.path == "fill.opacity")
            tv.sel = cast(long) i;

    assert(editProperty(l, Edit("fill.kind", EditValue.ofEnum("gradient")),
        es).ok);
    pt.rebuild(l, tv);

    bool sawStops, sawNewKind;
    foreach (ref const nd; pt.data.nodes)
    {
        sawStops |= nd.value.path == "fill.stops";
        sawNewKind |= nd.value.path == "fill.kind"
            && nd.value.badge == "gradient";
    }
    assert(sawStops, "@ShowIf re-evaluated: the gradient row appeared");
    assert(sawNewKind, "the badge refreshed");
    assert(pt.selectedPath(tv) == "fill.opacity", "selection preserved");
    assert(tv.open.isOpen("fill"), "disclosure preserved");
}

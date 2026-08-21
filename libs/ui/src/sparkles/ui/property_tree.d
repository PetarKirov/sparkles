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

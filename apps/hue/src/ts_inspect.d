/**
The tree-sitter inspector's CST adapter (`TSI` / `TVU2` / `INS`): the
document's retained parse layers as the generic inspector component's tree.

The mapping follows neovim's `:InspectTree`, exceeding it where our widget
rows can (spec `TSI2`):

$(LIST
    * a named node's label is `field: type` (the field it occupies in its
        parent, when any); an anonymous node renders quoted (`"("`, `";"`)
        with newlines escaped, in a muted slot;
    * `MISSING` nodes label as `MISSING type` and `ERROR` nodes keep their
        name — both in the error slot, which is more than the reference does
        (neovim special-cases only MISSING);
    * the node's `[row, col]–[row, col]` extent rides as a trailing badge;
    * $(B injections) appear inline: an injected layer's root becomes an
        extra first child of the covering node in its parent layer, carrying
        the injected language (the per-node language a host can toggle);
    * the anonymous toggle is a $(B rebuild) — flat storage makes rebuilding
        the arena per toggle cheap, and $(LREF nearestNamed) is what lets a
        host keep the cursor on the same (named) node across it.
)

$(LREF writeQueryText) is the plain-text target (`INS5`): the tree as
neovim-compatible $(B query syntax) — `(type` lines, `field:` prefixes,
`; [r, c] - [r, c]` range comments, closing parens by visible-lookahead — so
a dump is diffable against the reference ecosystem and highlightable with a
`query` grammar.
*/
module ts_inspect;

import std.conv : text;

import sparkles.syntax.ts.highlighter : ParsedLayer;
import sparkles.tree_sitter : nodeChild, nodeChildCount,
    nodeFieldNameForChild, nodeIsError, nodeIsExtra, nodeIsMissing,
    nodeIsNamed, nodeRange, TSNode, writeSExpression;
import sparkles.ui.components.inspector : DetailRow;
import sparkles.ui.components.tree_widget : FlatTreeRow, TreeData;
import sparkles.ui.style : Slot;

@safe:

/// One CST row as the tree view sees it (DbI capabilities: `label`, `slot`,
/// `badge`) plus what the inspector's contracts need (extent, classification).
struct CstNode
{
    string label;      /// `field: type` / quoted anonymous — the row text
    string type;       /// the grammar type name alone
    string field;      /// the field this node occupies in its parent ("" = none)
    string badge;      /// `[row, col]–[row, col]`, 0-based, end-exclusive
    Slot slot = Slot.code; ///
    uint startByte;    /// the selection contract's extent (`INS2`)
    uint endByte;      /// ditto
    bool named;        ///
    bool missing;      ///
    bool isError;      ///
    ushort layer;      /// index into the layer set (the language column)
}

/// The adapter's product: the tree data plus the contract answerers.
struct CstInspect
{
    TreeData!CstNode data;       ///
    const(string)[] layerLanguages; /// per-layer language names
    private const(char)[] source;

    /// The details rows for a tree node (`uint.max` → none).
    DetailRow[] details(uint node) scope const
    {
        if (node == uint.max || node >= data.nodes.length)
            return null;
        ref const v = data.nodes[node].value;
        DetailRow[] rows = [
            DetailRow("node", v.label),
            DetailRow("range", v.badge),
            DetailRow("bytes", text(v.startByte, "–", v.endByte,
                " (", v.endByte - v.startByte, ")")),
            DetailRow("named", v.named ? "yes" : "no"),
        ];
        if (v.missing)
            rows ~= DetailRow("missing", "yes", Slot.error);
        if (v.isError)
            rows ~= DetailRow("error", "yes", Slot.error);
        if (v.layer < layerLanguages.length)
            rows ~= DetailRow("language", layerLanguages[v.layer], Slot.info);
        // A short source excerpt: enough to orient, never a wall.
        if (v.endByte > v.startByte && v.endByte <= source.length)
        {
            auto excerpt = source[v.startByte .. v.endByte];
            enum cap = 60;
            rows ~= DetailRow("text", excerpt.length > cap
                ? text(excerpt[0 .. cap], "…") : excerpt.idup, Slot.docs);
        }
        return rows;
    }

    /// The selection contract (`INS2`): the byte extent of a tree node.
    void extentOf(uint node, out size_t start, out size_t end) scope const
        @nogc nothrow pure
    {
        if (node == uint.max || node >= data.nodes.length)
            return;
        start = data.nodes[node].value.startByte;
        end = data.nodes[node].value.endByte;
    }

    /// The deepest tree node whose extent contains `offset` — the
    /// position → node half of the sync contract. Prefers the smallest
    /// containing span; `uint.max` when none contains it.
    uint nodeAt(size_t offset) scope const @nogc nothrow pure
    {
        uint best = uint.max;
        size_t bestLen = size_t.max;
        foreach (i, ref const n; data.nodes)
        {
            const v = &n.value;
            if (offset < v.startByte || offset >= v.endByte)
                continue;
            const len = v.endByte - v.startByte;
            if (len < bestLen || (len == bestLen && i > best))
            {
                best = cast(uint) i;
                bestLen = len;
            }
        }
        return best;
    }

    /// The node itself when named, else its nearest named ancestor — what a
    /// host re-finds after the anonymous toggle rebuilds the arena.
    uint nearestNamed(uint node) scope const @nogc nothrow pure
    {
        for (auto at = node; at != uint.max; at = data.nodes[at].parent)
            if (data.nodes[at].value.named)
                return at;
        return uint.max;
    }
}

/**
Builds the inspector's tree from the retained layers. `showAnonymous` folds
anonymous token nodes in or out (a rebuild, not a filter — the arena is a
function of the toggle). Injected layers attach under the covering node of
their parent layer, before its own children (the reference's order).
*/
CstInspect inspectCst(scope ParsedLayer*[] layers,
    const(char)[] source, bool showAnonymous = false) @trusted
{
    CstInspect ci;
    ci.source = source;
    auto langs = new string[](layers.length);
    foreach (i, l; layers)
        langs[i] = l.language;
    ci.layerLanguages = langs;

    if (layers.length == 0)
        return ci;

    // For each injected layer: the id of the covering node in its parent
    // layer (the narrowest named node spanning the layer's first range).
    static struct Pending
    {
        const(void)* coveringId;
        size_t childLayer;
    }

    Pending[] pending;
    foreach (i, l; layers)
    {
        if (l.parent == size_t.max || !l.tree.valid || l.ranges.length == 0)
            continue;
        import sparkles.tree_sitter : nodeIsNull, nodeNamedDescendantForByteRange;

        auto cover = nodeNamedDescendantForByteRange(
            layers[l.parent].tree.rootNode,
            l.ranges[0].start_byte, l.ranges[0].end_byte);
        if (!nodeIsNull(cover))
            pending ~= Pending(cover.id, i);
    }

    void walk(size_t layerIdx, TSNode n, const(char)[] field, uint parent)
    {
        const named = nodeIsNamed(n);
        if (!named && !showAnonymous)
            return;

        const missing = nodeIsMissing(n);
        const r = nodeRange(n);
        import sparkles.tree_sitter : nodeType;

        const type = nodeType(n);
        CstNode v;
        v.named = named;
        v.missing = missing;
        v.isError = nodeIsError(n);
        v.startByte = r.start_byte;
        v.endByte = r.end_byte;
        v.layer = cast(ushort) layerIdx;
        v.badge = text("[", r.start_point.row, ",", r.start_point.column,
            "]–[", r.end_point.row, ",", r.end_point.column, "]");

        v.type = type.idup;
        v.field = field.idup;
        string label;
        if (field.length)
            label = text(field, ": ");
        if (named)
        {
            if (missing)
                label ~= text("MISSING ", type);
            else
                label ~= type;
            v.slot = (v.isError || missing) ? Slot.error : Slot.code;
        }
        else
        {
            label ~= text('"', escaped(type), '"');
            v.slot = missing ? Slot.error : Slot.muted;
        }
        v.label = label;

        const idx = ci.data.add(v, parent);

        // Injections first (the reference's order), then the node's own
        // children.
        foreach (ref const p; pending)
            if (p.coveringId is n.id)
                walk(p.childLayer, layers[p.childLayer].tree.rootNode,
                    null, idx);

        foreach (i; 0 .. nodeChildCount(n))
            walk(layerIdx, nodeChild(n, i), nodeFieldNameForChild(n, i), idx);
    }

    if (layers[0].tree.valid)
        walk(0, layers[0].tree.rootNode, null, uint.max);
    return ci;
}

/// A type name with real newlines escaped for a one-line label (`"\n"`).
private string escaped(const(char)[] s) pure
{
    string r;
    foreach (c; s)
        if (c == '\n')
            r ~= `\n`;
        else
            r ~= c;
    return r;
}

/**
The plain-text target (`INS5`): the built tree as neovim-compatible query
syntax — one line per row, e.g. `(document ; [0, 0] - [5, 0]` with each child
two spaces deeper and the closers gathered on the last line of a subtree —
with anonymous nodes quoted, `MISSING` spelled out, `field:` prefixes, and
closing parens computed by lookahead over the $(B visible) rows (toggling
anonymous nodes moves where the parens land, as in the reference).
*/
void writeQueryText(Writer)(ref Writer w, in CstInspect ci,
    in FlatTreeRow[] rows)
{
    import std.range.primitives : put;

    foreach (i, ref const row; rows)
    {
        ref const v = ci.data.nodes[row.node].value;
        foreach (_; 0 .. row.depth * 2)
            put(w, ' ');
        if (v.field.length)
        {
            put(w, v.field);
            put(w, ": ");
        }
        if (v.named)
        {
            put(w, '(');
            if (v.missing)
                put(w, "MISSING ");
            put(w, v.type);
        }
        else
        {
            put(w, '"');
            put(w, escaped(v.type));
            put(w, '"');
        }
        put(w, " ; [");
        putNum(w, byteRow(v, true));
        put(w, ", ");
        putNum(w, byteCol(v, true));
        put(w, "] - [");
        putNum(w, byteRow(v, false));
        put(w, ", ");
        putNum(w, byteCol(v, false));
        put(w, "]");
        // Closing parens: one per level this row closes relative to the next
        // visible row, plus its own when named.
        const nextDepth = i + 1 < rows.length ? rows[i + 1].depth : 0;
        int closers = row.depth - nextDepth + (v.named ? 1 : 0);
        // Only named ancestors opened a paren; anonymous rows close none of
        // their own. Walk up to count named levels being closed.
        if (closers > 0)
        {
            // The row itself (named) closes one; each ancestor between this
            // depth and the next row's depth closes one if named.
            if (v.named)
                put(w, ')');
            uint p = ci.data.nodes[row.node].parent;
            for (int d = row.depth - 1; d >= nextDepth && p != uint.max;
                --d, p = ci.data.nodes[p].parent)
                if (ci.data.nodes[p].value.named)
                    put(w, ')');
        }
        put(w, '\n');
    }
}

/// ditto — as one `string`.
string queryText(in CstInspect ci, in FlatTreeRow[] rows)
{
    import std.array : appender;

    auto w = appender!string;
    writeQueryText(w, ci, rows);
    return w[];
}

// The badge is authoritative for points; re-deriving rows/cols from bytes
// would need the source. Parse them back out of the stored badge instead of
// carrying four more fields per node.
private uint byteRow(ref const CstNode v, bool start) @safe pure
    => pointOf(v, start)[0];
private uint byteCol(ref const CstNode v, bool start) @safe pure
    => pointOf(v, start)[1];

private uint[2] pointOf(ref const CstNode v, bool start) @safe pure
{
    // badge: "[r,c]–[r,c]"
    uint[4] nums;
    size_t at;
    uint cur;
    bool inNum;
    foreach (ch; v.badge)
    {
        if (ch >= '0' && ch <= '9')
        {
            cur = cur * 10 + (ch - '0');
            inNum = true;
        }
        else if (inNum)
        {
            if (at < 4)
                nums[at++] = cur;
            cur = 0;
            inNum = false;
        }
    }
    if (inNum && at < 4)
        nums[at++] = cur;
    return start ? [nums[0], nums[1]] : [nums[2], nums[3]];
}

private void putNum(Writer)(ref Writer w, uint n)
{
    import std.range.primitives : put;

    char[10] buf;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n);
    put(w, buf[i .. $]);
}

// ---------------------------------------------------------------------------
// Tests (grammar-gated, like the engine's own).
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.ts.highlighter : parseLayers;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.syntax.ts.registry : GrammarRegistry;

    private ParsedLayer*[] layersForTest(string lang, string source) @system
    {
        import std.process : environment;
        import sparkles.test_runner.skip : skipTest;

        if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
            skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

        static GrammarRegistry registry;
        registry = GrammarRegistry.fromEnvironment();
        static TsConfigCache* cache;
        cache = new TsConfigCache;
        *cache = TsConfigCache.create(&registry, LabelSet.standard());
        ParsedLayer*[] layers;
        auto r = parseLayers(*cache, lang, source, layers);
        assert(!r.hasError);
        return layers;
    }
}

@("ts_inspect.namedTreeWithFieldsAndExtents")
@system unittest
{
    const source = `{"a": [1, true]}`;
    auto layers = layersForTest("json", source);
    auto ci = inspectCst(layers, source);

    // Named-only by default: document → object → pair → …, fields labelled.
    assert(ci.data.nodes.length >= 5);
    assert(ci.data.nodes[0].value.label == "document");
    assert(ci.data.nodes[1].value.label == "object");
    assert(ci.data.nodes[2].value.label == "pair");
    bool sawKey, sawValue;
    foreach (ref n; ci.data.nodes)
    {
        sawKey |= n.value.label == "key: string";
        sawValue |= n.value.label == "value: array";
    }
    assert(sawKey && sawValue, "field names prefix the labels");

    // Extents are byte-true against the source.
    const arr = ci.nodeAt(source.length - 3); // inside `true`
    assert(arr != uint.max);
    assert(ci.data.nodes[arr].value.label == "true");
    size_t s, e;
    ci.extentOf(arr, s, e);
    assert(source[s .. e] == "true");

    // No anonymous rows in the default build.
    foreach (ref n; ci.data.nodes)
        assert(n.value.named);
}

@("ts_inspect.anonymousToggleAndNearestNamed")
@system unittest
{
    const source = `{"a": 1}`;
    auto layers = layersForTest("json", source);
    auto ci = inspectCst(layers, source, showAnonymous: true);

    // The braces and the colon appear, quoted and muted.
    bool sawBrace, sawColon;
    uint colonIdx = uint.max;
    foreach (i, ref n; ci.data.nodes)
    {
        sawBrace |= n.value.label == `"{"`;
        if (n.value.label == `":"`)
        {
            sawColon = true;
            colonIdx = cast(uint) i;
        }
    }
    assert(sawBrace && sawColon);
    assert(!ci.data.nodes[colonIdx].value.named);
    assert(ci.data.nodes[colonIdx].value.slot == Slot.muted);

    // The cursor-preservation helper: the colon's nearest named ancestor is
    // the pair.
    const anchor = ci.nearestNamed(colonIdx);
    assert(ci.data.nodes[anchor].value.label == "pair");
}

@("ts_inspect.errorAndMissingClassify")
@system unittest
{
    const source = `{"a" 1}`;
    auto layers = layersForTest("json", source);
    auto ci = inspectCst(layers, source, showAnonymous: true);

    bool sawTrouble;
    foreach (ref n; ci.data.nodes)
        if (n.value.isError || n.value.missing)
        {
            sawTrouble = true;
            assert(n.value.slot == Slot.error, n.value.label);
        }
    assert(sawTrouble, "the broken parse surfaces error/missing rows");
}

@("ts_inspect.injectionsAttachInline")
@system unittest
{
    const source = "# T\n\n```json\n{\"k\": 1}\n```\n";
    auto layers = layersForTest("markdown", source);
    auto ci = inspectCst(layers, source);

    // The injected json document appears as a descendant of the markdown
    // tree, carrying its layer's language.
    uint jsonRoot = uint.max;
    foreach (i, ref n; ci.data.nodes)
        if (n.value.label == "document" && n.value.layer != 0)
            jsonRoot = cast(uint) i;
    assert(jsonRoot != uint.max, "the injected layer is in the tree");
    assert(ci.data.nodes[jsonRoot].parent != uint.max,
        "…attached under a covering markdown node");
    assert(ci.layerLanguages[ci.data.nodes[jsonRoot].value.layer] == "json");

    const det = ci.details(jsonRoot);
    bool lang;
    foreach (ref d; det)
        lang |= d.key == "language" && d.value == "json";
    assert(lang, "the details name the injected language");
}

@("ts_inspect.queryTextMatchesTheReferenceShape")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.components.tree_widget : flatten;

    const source = `{"a": 1}`;
    auto layers = layersForTest("json", source);
    auto ci = inspectCst(layers, source);
    auto rows = flatten(ci.data, (uint) => true);

    const dump = queryText(ci, rows);
    // The reference line shape: parens, field prefixes, range comments.
    assert(dump.canFind("(document ; [0, 0] - [0, 8]"), dump);
    assert(dump.canFind("key: (string ; "), dump);
    assert(dump[$ - 1] == '\n');
    // Balanced parens over the whole dump.
    int depth;
    foreach (ch; dump)
    {
        if (ch == '(')
            ++depth;
        if (ch == ')')
            --depth;
        assert(depth >= 0);
    }
    assert(depth == 0, text("unbalanced: ", depth, "\n", dump));
}

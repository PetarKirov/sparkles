/**
Fitting a tree into a height (`WGT12` data layer): which rows a live tree
keeps when it is taller than the room it has.

The order follows bootvine's boot tree, after nix-output-monitor's:

$(OL
    $(LI the whole tree, when it fits;)
    $(LI else the tree with its straight chains folded: a node waiting on
        exactly one other, which waits on exactly one other, becomes one row
        naming both (`a ─ b`);)
    $(LI else only the paths to the nodes that matter — a node's `anchor`, a
        running or failed one — plus as many other nodes as the rows left
        allow, in tree order, with one row kept for the count of the rest.)
)

It is a pure function of a $(REF TreeData, sparkles,ui,components,tree_widget)
and a row budget, so a view rebuilds it every frame. The node type says what
matters by introspection: `anchor` keeps a node's path, `chainLink` lets it
fold into its parent's row, `label` names it there and `chain` receives the
labels folded into it.
*/
module sparkles.ui.components.tree_fit;

import sparkles.ui.components.tree_widget : TreeData;

@safe:

/// Whether `T` can be fitted: it names its anchors and chain links, and has
/// a label and a chain to fold labels into.
enum bool isFittable(T) = __traits(compiles, (ref T v) {
    bool a = v.anchor;
    bool l = v.chainLink;
    const(char)[] s = v.label;
    v.chain ~= s;
});

/// What fitting keeps: the rows to show, and how many nodes were left out
/// (folded nodes are shown, in their row's chain).
struct FittedTree(T)
{
    TreeData!T data; ///
    size_t hidden;   ///
}

/**
Fits `data` into `budget` rows; see the module documentation. A chain folds
once it has `minLinks` links below its first node. When even the anchored
paths overflow, the rows past the budget are cut in tree order and counted.
*/
FittedTree!T fitTree(T)(TreeData!T data, size_t budget, size_t minLinks = 1)
if (isFittable!T)
{
    auto forest = toForest(data);
    const total = units(forest);
    if (rowCount(forest) <= budget)
        return FittedTree!T(fromForest(forest), 0);
    forest = forest.fold(minLinks);
    if (rowCount(forest) <= budget)
        return FittedTree!T(fromForest(forest), total - units(forest));
    // One row for the count of what is left out.
    const room = budget == 0 ? 0 : budget - 1;
    size_t essential;
    foreach (ref n; forest)
        essential += n.essentialRows();
    size_t spare = room > essential ? room - essential : 0;
    Node!T[] kept;
    foreach (ref n; forest)
        if (n.keep(spare))
            kept ~= n.pruned(spare);
    kept = cut(kept, room);
    return FittedTree!T(fromForest(kept), total - units(kept));
}

private:

struct Node(T)
{
    T value;
    Node[] children;

    bool leadsToAnchor() const
    {
        if (value.anchor)
            return true;
        foreach (ref c; children)
            if (c.leadsToAnchor())
                return true;
        return false;
    }

    size_t essentialRows() const
    {
        if (!leadsToAnchor())
            return 0;
        size_t n = 1;
        foreach (ref c; children)
            n += c.essentialRows();
        return n;
    }

    // Whether this node stays: on a path to an anchor, or paid for from
    // `spare`.
    bool keep(ref size_t spare) const
    {
        if (leadsToAnchor())
            return true;
        if (spare == 0)
            return false;
        --spare;
        return true;
    }

    Node pruned(ref size_t spare)
    {
        Node n = Node(value);
        foreach (ref c; children)
            if (c.keep(spare))
                n.children ~= c.pruned(spare);
        return n;
    }

    bool isLink() const => value.chainLink && children.length == 1;

    Node[] fold(size_t minLinks)
    {
        Node n = Node(value);
        n.value.chain = value.chain.dup;
        // The links below this node, each waiting on exactly one other.
        size_t links;
        for (Node at = this; at.isLink && at.children[0].isLink; at = at.children[0])
            ++links;
        Node[] below = children;
        if (links >= minLinks)
        {
            Node at = this;
            foreach (_; 0 .. links)
            {
                at = at.children[0];
                n.value.chain ~= at.value.label;
            }
            below = at.children;
        }
        foreach (ref c; below)
            n.children ~= c.fold(minLinks);
        return [n];
    }
}

Node!T[] fold(T)(Node!T[] forest, size_t minLinks)
{
    Node!T[] folded;
    foreach (ref n; forest)
        folded ~= n.fold(minLinks);
    return folded;
}

Node!T[] toForest(T)(TreeData!T data)
{
    Node!T[] walk(uint at)
    {
        Node!T[] nodes;
        for (; at != uint.max; at = data.nodes[at].nextSibling)
        {
            T v = data.nodes[at].value;
            nodes ~= Node!T(v, walk(data.nodes[at].firstChild));
        }
        return nodes;
    }

    return walk(data.firstRoot);
}

TreeData!T fromForest(T)(Node!T[] forest)
{
    TreeData!T data;
    void walk(Node!T[] nodes, uint parent)
    {
        foreach (ref n; nodes)
        {
            T v = n.value;
            walk(n.children, data.add(v, parent));
        }
    }

    walk(forest, uint.max);
    return data;
}

size_t rowCount(T)(in Node!T[] forest)
{
    size_t n;
    foreach (ref f; forest)
        n += 1 + rowCount(f.children);
    return n;
}

size_t units(T)(in Node!T[] forest)
{
    size_t n;
    foreach (ref f; forest)
        n += 1 + f.value.chain.length + units(f.children);
    return n;
}

// The first `room` rows of `forest` in tree order.
Node!T[] cut(T)(Node!T[] forest, ref size_t room)
{
    Node!T[] kept;
    foreach (ref n; forest)
    {
        if (room == 0)
            break;
        --room;
        kept ~= Node!T(n.value, cut(n.children, room));
    }
    return kept;
}

Node!T[] cut(T)(Node!T[] forest, size_t room)
{
    size_t left = room;
    return cut(forest, left);
}

// The tests' node. Outside `version (unittest)`, so this module's own build
// emits its members: dmd's separate compilation leaves a consumer's
// `-unittest -allinst` root build, which sees this module's tests, expecting
// `Unit.__xtoHash`, `Unit.__xopEquals` and `TreeData!Unit.Node.__init` from the
// library, which a plain build would not instantiate (as `tree_widget`'s
// anchor explains).
private struct Unit
{
    string label;
    bool anchor;
    bool chainLink;
    const(char)[][] chain;
}

private immutable TreeData!Unit.Node _dmdEmissionAnchor;

version (unittest)
{
    // `name` is a running unit when it ends in `!`, a waiting link when it
    // ends in `~`.
    Unit unit(string name)
    {
        if (name.length && name[$ - 1] == '!')
            return Unit(name[0 .. $ - 1], anchor: true);
        if (name.length && name[$ - 1] == '~')
            return Unit(name[0 .. $ - 1], chainLink: true);
        return Unit(name);
    }

    // The fitted rows as `depth label[ ─ chain]` lines.
    string outline(in TreeData!Unit data)
    {
        import std.array : join;

        string text;
        void walk(uint at, size_t depth)
        {
            for (; at != uint.max; at = data.nodes[at].nextSibling)
            {
                foreach (_; 0 .. depth)
                    text ~= "  ";
                text ~= ([data.nodes[at].value.label] ~ data.nodes[at].value.chain).join(" ─ ") ~ "\n";
                walk(data.nodes[at].firstChild, depth + 1);
            }
        }

        walk(data.firstRoot, 0);
        return text;
    }
}

/// A tree that fits is kept whole, and nothing is hidden.
@("ui.tree_fit.fitTree.keepsATreeThatFits")
@safe unittest
{
    TreeData!Unit t;
    const r = t.add(unit("test"));
    t.add(unit("link~"), r);
    t.add(unit("doc!"), r);
    auto fitted = fitTree(t, 3);
    assert(fitted.hidden == 0);
    assert(outline(fitted.data) == "test\n  link\n  doc\n");
}

/// Straight chains of waiting nodes fold into one row before anything is
/// left out.
@("ui.tree_fit.fitTree.foldsChainsBeforePruning")
@safe unittest
{
    TreeData!Unit t;
    const test = t.add(unit("test~"));
    const link = t.add(unit("link~"), test);
    t.add(unit("compile!"), link);
    t.add(unit("other"));
    auto fitted = fitTree(t, 3);
    assert(fitted.hidden == 0, "a folded node is shown in its row");
    assert(outline(fitted.data) == "test ─ link\n  compile\nother\n", outline(fitted.data));
}

/// Over budget, the paths to anchors stay, other nodes fill the rows left in
/// tree order, and one row is kept for the count of the rest.
@("ui.tree_fit.fitTree.keepsThePathsToAnchors")
@safe unittest
{
    TreeData!Unit t;
    foreach (name; ["a", "b", "c"])
        t.add(unit(name));
    const d = t.add(unit("d"));
    t.add(unit("run!"), d);
    t.add(unit("e"));
    auto fitted = fitTree(t, 4);
    assert(outline(fitted.data) == "a\nd\n  run\n", outline(fitted.data));
    assert(fitted.hidden == 3);
}

/// When the anchored paths alone overflow, the rows past the budget are cut
/// in tree order.
@("ui.tree_fit.fitTree.cutsAnOverflowingAnchorSet")
@safe unittest
{
    TreeData!Unit t;
    foreach (name; ["a!", "b!", "c!", "d!"])
        t.add(unit(name));
    auto fitted = fitTree(t, 3);
    assert(outline(fitted.data) == "a\nb\n", outline(fitted.data));
    assert(fitted.hidden == 2);
}

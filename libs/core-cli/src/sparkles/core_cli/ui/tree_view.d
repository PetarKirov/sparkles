/**
 * Generic tree-view renderer for hierarchical data.
 *
 * Renders any tree-shaped data as indented text with Unicode guide characters
 * (`├──`, `└──`, `│`). Uses Design by Introspection: node types provide
 * capabilities (`.label`, `.children`, `.isLeaf`) optionally; hooks can
 * override or supplement.
 *
 * Two APIs mirror the `drawBox`/`prettyPrint` pattern:
 * $(UL
 *   $(LI `writeTree` — writes to any output range (including @nogc `SmallBuffer`))
 *   $(LI `drawTree` — convenience overload returning `string`)
 * )
 */
module sparkles.core_cli.ui.tree_view;

import sparkles.core_cli.term_style : Style;
import sparkles.core_cli.text_writers : writeStylized, writeValue;

// ─────────────────────────────────────────────────────────────────────────────
// Capability Traits
// ─────────────────────────────────────────────────────────────────────────────

/// Node has a `.label` property returning string-like data.
enum bool hasTreeLabel(T) = is(typeof(T.init.label) : const(char)[]);

/// Node has `.children` returning an iterable of child nodes.
enum bool hasTreeChildren(T) = is(typeof({
    T n = T.init;
    foreach (ref c; n.children) {}
}));

/// Node has `.isLeaf` property (distinguishes empty-but-expandable from leaf).
enum bool hasTreeIsLeaf(T) = is(typeof(T.init.isLeaf) : bool);

/// Hook provides `children(node)` for types lacking `.children`.
enum bool hookProvidesChildren(Hook, T) = is(typeof({
    Hook h = Hook.init;
    T n = T.init;
    foreach (ref c; h.children(n)) {}
}));

/// Hook provides `label(node)` for types lacking `.label`.
enum bool hookProvidesLabel(Hook, T) = is(typeof(Hook.init.label(T.init)) : const(char)[]);

/// True if `T` is a recognized tree node (has label, children, or hook support).
private enum bool isTreeNode(T, Hook = void) = hasTreeLabel!T || hasTreeChildren!T
    || (!is(Hook == void) && (hookProvidesChildren!(Hook, T) || hookProvidesLabel!(Hook, T)));

// ─────────────────────────────────────────────────────────────────────────────
// Guide Character Types
// ─────────────────────────────────────────────────────────────────────────────

/// Guide character state for tree rendering (Rich's four-state model).
enum Guide : ubyte { space, continue_, fork, end }

/// Unicode strings for each guide state.
struct GuideSet
{
    string space    = "    ";
    string continue_ = "│   ";
    string fork     = "├── ";
    string end      = "└── ";
}

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for tree rendering, following `PrettyPrintOptions` pattern.
struct TreeViewProps(Hook = void)
{
    GuideSet guides;
    ushort maxDepth = 32;
    bool useColors = true;
    Style guideStyle = Style.dim;
    bool showRoot = true;

    // Zero-state optimization (DbI §5.3)
    static if (!is(Hook == void))
        Hook hook;
}

// ─────────────────────────────────────────────────────────────────────────────
// Core Algorithm — writeTree (output range)
// ─────────────────────────────────────────────────────────────────────────────

/// Writes a tree rooted at `root` to an output range.
ref Writer writeTree(Writer, Hook = void, Node)(
    auto ref const Node root,
    return ref Writer writer,
    TreeViewProps!Hook props = TreeViewProps!Hook.init,
) @trusted
if (isTreeNode!(Node, Hook) && !is(Node : E[], E))
{
    import std.range.primitives : put;
    Guide[32] guideState = Guide.space;
    if (props.showRoot)
    {
        // Write root label (no connector, no guides)
        writeNodeLabel(root, writer, props);
        put(writer, "\n");
        if (0 < props.maxDepth)
            writeChildrenAsRoots(root, writer, props, guideState, 1);
    }
    else
    {
        // Hide root, show children as multi-root items
        writeChildrenAsRoots(root, writer, props, guideState, 0);
    }
    return writer;
}

/// Writes multiple roots to an output range.
ref Writer writeTree(Writer, Hook = void, E)(
    const E[] roots,
    return ref Writer writer,
    TreeViewProps!Hook props = TreeViewProps!Hook.init,
) @trusted
if (isTreeNode!(E, Hook))
{
    Guide[32] guideState = Guide.space;
    foreach (i, ref root; roots)
    {
        const isLast = (i == roots.length - 1);
        writeTreeNode(root, writer, props, guideState, 0, isLast, true);
    }
    return writer;
}

// ─────────────────────────────────────────────────────────────────────────────
// Convenience — drawTree (string return)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a tree rendering as a string. Matches `drawBox`/`drawTable` pattern.
/// The trailing newline is stripped for consistency with other draw* functions.
string drawTree(Hook = void, Node)(
    auto ref const Node root,
    TreeViewProps!Hook props = TreeViewProps!Hook.init,
)
if (isTreeNode!(Node, Hook) && !is(Node : E[], E))
{
    import std.array : appender;
    auto w = appender!string;
    writeTree(root, w, props);
    return stripTrailingNewline(w[]);
}

/// Returns a tree rendering of multiple roots as a string.
string drawTree(Hook = void, E)(
    const E[] roots,
    TreeViewProps!Hook props = TreeViewProps!Hook.init,
)
if (isTreeNode!(E, Hook))
{
    import std.array : appender;
    auto w = appender!string;
    writeTree(roots, w, props);
    return stripTrailingNewline(w[]);
}

private string stripTrailingNewline(string s) @safe pure nothrow @nogc
{
    if (s.length > 0 && s[$ - 1] == '\n')
        return s[0 .. $ - 1];
    return s;
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal Implementation
// ─────────────────────────────────────────────────────────────────────────────

/// Writes a single tree node. `showConnector` controls whether fork/end guides
/// are written (false for a lone root, true for multi-root items and all children).
private void writeTreeNode(Node, Writer, Hook)(
    auto ref const Node node,
    ref Writer writer,
    TreeViewProps!Hook props,
    ref Guide[32] guideState,
    ushort depth,
    bool isLast,
    bool showConnector,
) @trusted
{
    import std.range.primitives : put;

    // Write guide prefix for each ancestor depth
    foreach (d; 0 .. depth)
    {
        writeGuide(writer, props, guideState[d]);
    }

    // Write this node's connector (fork or end)
    if (showConnector)
    {
        const connector = isLast ? props.guides.end : props.guides.fork;
        if (props.useColors)
            writeStylized(writer, connector, props.guideStyle);
        else
            put(writer, connector);
    }

    // Write node label
    writeNodeLabel(node, writer, props);

    // Write newline
    put(writer, "\n");

    // Check depth limit
    if (depth >= props.maxDepth)
        return;

    // Recurse into children if node has any
    if (nodeHasChildren(node, props))
    {
        // Set guide state for this depth before recursing
        guideState[depth] = isLast ? Guide.space : Guide.continue_;
        writeChildrenOf(node, writer, props, guideState, depth);
    }
}

/// Writes a guide character with optional styling.
private void writeGuide(Writer, Hook)(ref Writer writer, TreeViewProps!Hook props, Guide g) @trusted
{
    import std.range.primitives : put;
    const guideStr = guideString(props.guides, g);
    if (props.useColors)
        writeStylized(writer, guideStr, props.guideStyle);
    else
        put(writer, guideStr);
}

/// Writes children of a node. Dispatches via DbI to find children.
private void writeChildrenOf(Node, Writer, Hook)(
    auto ref const Node node,
    ref Writer writer,
    TreeViewProps!Hook props,
    ref Guide[32] guideState,
    ushort depth,
) @trusted
{
    static if (!is(Hook == void) && hookProvidesChildren!(Hook, Node))
    {
        auto children = props.hook.children(node);
        writeChildRange(children, writer, props, guideState, cast(ushort)(depth + 1));
    }
    else static if (hasTreeChildren!Node)
    {
        auto children = node.children;
        writeChildRange(children, writer, props, guideState, cast(ushort)(depth + 1));
    }
}

/// Writes children of a node as top-level roots (visual depth 0, with connectors).
/// `logicalDepth` is used for maxDepth accounting.
private void writeChildrenAsRoots(Node, Writer, Hook)(
    auto ref const Node node,
    ref Writer writer,
    TreeViewProps!Hook props,
    ref Guide[32] guideState,
    ushort logicalDepth = 0,
) @trusted
{
    static if (!is(Hook == void) && hookProvidesChildren!(Hook, Node))
    {
        auto children = props.hook.children(node);
        writeChildRangeAsRoots(children, writer, props, guideState, logicalDepth);
    }
    else static if (hasTreeChildren!Node)
    {
        auto children = node.children;
        writeChildRangeAsRoots(children, writer, props, guideState, logicalDepth);
    }
}

/// Iterates children as top-level roots — visual depth 0, logical depth tracked for maxDepth.
private void writeChildRangeAsRoots(Children, Writer, Hook)(
    Children children,
    ref Writer writer,
    TreeViewProps!Hook props,
    ref Guide[32] guideState,
    ushort logicalDepth,
) @trusted
{
    import std.range.primitives : hasLength;

    static if (hasLength!Children)
    {
        const len = children.length;
        size_t idx = 0;
        foreach (ref child; children)
        {
            const isLast = (idx == len - 1);
            writeTreeNodeAsRoot(child, writer, props, guideState, isLast, logicalDepth);
            idx++;
        }
    }
    else
    {
        import std.range.primitives : empty, front, popFront;

        while (!children.empty)
        {
            auto child = children.front;
            children.popFront();
            const isLast = children.empty;
            writeTreeNodeAsRoot(child, writer, props, guideState, isLast, logicalDepth);
        }
    }
}

/// Writes a node as a top-level root (connector at visual depth 0, logical depth for maxDepth).
private void writeTreeNodeAsRoot(Node, Writer, Hook)(
    auto ref const Node node,
    ref Writer writer,
    TreeViewProps!Hook props,
    ref Guide[32] guideState,
    bool isLast,
    ushort logicalDepth,
) @trusted
{
    import std.range.primitives : put;

    // Write connector (always shown for root items)
    const connector = isLast ? props.guides.end : props.guides.fork;
    if (props.useColors)
        writeStylized(writer, connector, props.guideStyle);
    else
        put(writer, connector);

    // Write label
    writeNodeLabel(node, writer, props);
    put(writer, "\n");

    // Check depth limit using logical depth
    if (logicalDepth >= props.maxDepth)
        return;

    // Recurse into children
    if (nodeHasChildren(node, props))
    {
        guideState[0] = isLast ? Guide.space : Guide.continue_;
        writeChildrenOf(node, writer, props, guideState, 0);
    }
}

/// Iterates a range of children, writing each with writeTreeNode.
private void writeChildRange(Children, Writer, Hook)(
    Children children,
    ref Writer writer,
    TreeViewProps!Hook props,
    ref Guide[32] guideState,
    ushort childDepth,
) @trusted
{
    import std.range.primitives : hasLength;

    static if (hasLength!Children)
    {
        const len = children.length;
        size_t idx = 0;
        foreach (ref child; children)
        {
            const isLast = (idx == len - 1);
            writeTreeNode(child, writer, props, guideState, childDepth, isLast, true);
            idx++;
        }
    }
    else
    {
        import std.range.primitives : empty, front, popFront;

        while (!children.empty)
        {
            auto child = children.front;
            children.popFront();
            const isLast = children.empty;
            writeTreeNode(child, writer, props, guideState, childDepth, isLast, true);
        }
    }
}

/// Returns the guide string for a given guide state.
private string guideString(GuideSet guides, Guide g) @safe pure nothrow @nogc
{
    final switch (g)
    {
        case Guide.space:     return guides.space;
        case Guide.continue_: return guides.continue_;
        case Guide.fork:      return guides.fork;
        case Guide.end:       return guides.end;
    }
}

/// Determines if a node has non-empty children.
private bool nodeHasChildren(Node, Hook)(auto ref const Node node, TreeViewProps!Hook props) @trusted
{
    static if (!is(Hook == void) && hookProvidesChildren!(Hook, Node))
    {
        auto children = props.hook.children(node);
        foreach (ref c; children)
            return true;
        return false;
    }
    else static if (hasTreeChildren!Node)
    {
        // Check isLeaf first if available
        static if (hasTreeIsLeaf!Node)
        {
            if (node.isLeaf)
                return false;
        }
        auto children = node.children;
        foreach (ref c; children)
            return true;
        return false;
    }
    else
    {
        return false;
    }
}

/// Writes a node's label via DbI dispatch chain.
private void writeNodeLabel(Node, Writer, Hook)(auto ref const Node node, ref Writer writer, TreeViewProps!Hook props) @trusted
{
    import std.range.primitives : put;

    // 1. Hook provides label
    static if (!is(Hook == void) && hookProvidesLabel!(Hook, Node))
    {
        put(writer, props.hook.label(node));
    }
    // 2. Node has .label
    else static if (hasTreeLabel!Node)
    {
        put(writer, node.label);
    }
    // 3. Fallback: writeValue handles any type
    else
    {
        writeValue(writer, node);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private struct TestNode
    {
        string label;
        const(TestNode)[] children;
    }

    private struct TestDir
    {
        string label;
        const(TestFile)[] children;
    }

    private struct TestFile
    {
        string label;
        // No .children → always leaf
    }

    private enum noColor = TreeViewProps!void(useColors: false);
}

@("treeView.traits.hasTreeLabel")
@safe pure nothrow @nogc
unittest
{
    static assert(hasTreeLabel!TestNode);
    static assert(hasTreeLabel!TestFile);
    static assert(!hasTreeLabel!int);
    static assert(!hasTreeLabel!string);
}

@("treeView.traits.hasTreeChildren")
@safe pure nothrow @nogc
unittest
{
    static assert(hasTreeChildren!TestNode);
    static assert(hasTreeChildren!TestDir);
    static assert(!hasTreeChildren!TestFile);
    static assert(!hasTreeChildren!int);
}

@("treeView.traits.hasTreeIsLeaf")
@safe pure nothrow @nogc
unittest
{
    struct LeafNode
    {
        string label;
        bool isLeaf;
        const(LeafNode)[] children;
    }

    static assert(hasTreeIsLeaf!LeafNode);
    static assert(!hasTreeIsLeaf!TestNode);
    static assert(!hasTreeIsLeaf!int);
}

@("treeView.basic.flatList")
@system unittest
{
    const nodes = [
        TestNode("alpha"),
        TestNode("beta"),
        TestNode("gamma"),
    ];

    assert(drawTree(nodes, noColor) ==
        "├── alpha\n" ~
        "├── beta\n" ~
        "└── gamma");
}

@("treeView.basic.nested")
@system unittest
{
    const nodes = [
        TestNode("root1", [
            TestNode("child1", [
                TestNode("grandchild"),
            ]),
            TestNode("child2"),
        ]),
        TestNode("root2"),
    ];

    assert(drawTree(nodes, noColor) ==
        "├── root1\n" ~
        "│   ├── child1\n" ~
        "│   │   └── grandchild\n" ~
        "│   └── child2\n" ~
        "└── root2");
}

@("treeView.basic.deepNesting")
@system unittest
{
    const tree = [
        TestNode("a", [
            TestNode("b", [
                TestNode("c", [
                    TestNode("d"),
                ]),
            ]),
        ]),
    ];

    assert(drawTree(tree, noColor) ==
        "└── a\n" ~
        "    └── b\n" ~
        "        └── c\n" ~
        "            └── d");
}

@("treeView.basic.singleRoot")
@system unittest
{
    const root = TestNode("root", [
        TestNode("child1"),
        TestNode("child2"),
    ]);

    assert(drawTree(root, noColor) ==
        "root\n" ~
        "├── child1\n" ~
        "└── child2");
}

@("treeView.basic.empty")
@system unittest
{
    const(TestNode)[] empty;
    assert(drawTree(empty, noColor) == "");
}

@("treeView.basic.leafAndBranch")
@system unittest
{
    const nodes = [
        TestNode("branch", [
            TestNode("leaf1"),
            TestNode("leaf2"),
        ]),
        TestNode("leaf3"),
    ];

    assert(drawTree(nodes, noColor) ==
        "├── branch\n" ~
        "│   ├── leaf1\n" ~
        "│   └── leaf2\n" ~
        "└── leaf3");
}

@("treeView.guides.lastChild")
@system unittest
{
    const nodes = [
        TestNode("a", [
            TestNode("a1"),
            TestNode("a2"),
        ]),
        TestNode("b", [
            TestNode("b1"),
        ]),
    ];

    assert(drawTree(nodes, noColor) ==
        "├── a\n" ~
        "│   ├── a1\n" ~
        "│   └── a2\n" ~
        "└── b\n" ~
        "    └── b1");
}

@("treeView.guides.continuation")
@system unittest
{
    const nodes = [
        TestNode("first", [
            TestNode("deep", [
                TestNode("deeper"),
            ]),
        ]),
        TestNode("second"),
    ];

    assert(drawTree(nodes, noColor) ==
        "├── first\n" ~
        "│   └── deep\n" ~
        "│       └── deeper\n" ~
        "└── second");
}

@("treeView.heterogeneous.types")
@system unittest
{
    const dir = TestDir("src", [
        TestFile("main.d"),
        TestFile("util.d"),
    ]);

    assert(drawTree(dir, noColor) ==
        "src\n" ~
        "├── main.d\n" ~
        "└── util.d");
}

@("treeView.hook.customChildren")
@system unittest
{
    struct Pair
    {
        string label;
        int left;
        int right;
    }

    struct PairHook
    {
        int[] children(in Pair p) const
        {
            return [p.left, p.right];
        }
    }

    auto tree = Pair("root", 1, 2);
    auto props = TreeViewProps!PairHook(useColors: false);

    assert(drawTree(tree, props) ==
        "root\n" ~
        "├── 1\n" ~
        "└── 2");
}

@("treeView.hook.customLabel")
@system unittest
{
    struct NumNode
    {
        int value;
        const(NumNode)[] children;
    }

    struct NumHook
    {
        string label(in NumNode n) const
        {
            import std.conv : text;
            return text("node-", n.value);
        }
    }

    const tree = [
        NumNode(1, [NumNode(2), NumNode(3)]),
    ];

    auto props = TreeViewProps!NumHook(useColors: false);

    assert(drawTree(tree, props) ==
        "└── node-1\n" ~
        "    ├── node-2\n" ~
        "    └── node-3");
}

@("treeView.hook.voidBaseline")
@safe pure nothrow @nogc
unittest
{
    // TreeViewProps!void compiles (DbI §7.3 — zero-state hook)
    auto props = TreeViewProps!void.init;
    static assert(!is(typeof(props.hook)));
}

@("treeView.nogc.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 256) buf;

    // Use TestDir/TestFile to avoid self-referential type cycle
    // that prevents @nogc inference in recursive templates.
    static immutable fileA = TestFile("main.d");
    static immutable fileB = TestFile("util.d");
    static immutable files = [fileA, fileB];
    static immutable root = TestDir("src", files);

    writeTree(root, buf, noColor);
    assert(buf[] == "src\n├── main.d\n└── util.d\n");
}

@("treeView.props.maxDepth")
@system unittest
{
    const tree = TestNode("L0", [
        TestNode("L1", [
            TestNode("L2", [
                TestNode("L3"),
            ]),
        ]),
    ]);

    auto props = TreeViewProps!void(useColors: false, maxDepth: 1);

    // maxDepth: 1 means we render depth 0 (root) and depth 1 (children),
    // but don't recurse into depth 2+
    assert(drawTree(tree, props) ==
        "L0\n" ~
        "└── L1");
}

@("treeView.props.showRootFalse")
@system unittest
{
    const root = TestNode("hidden_root", [
        TestNode("child1", [
            TestNode("grandchild"),
        ]),
        TestNode("child2"),
    ]);

    auto props = TreeViewProps!void(useColors: false, showRoot: false);

    assert(drawTree(root, props) ==
        "├── child1\n" ~
        "│   └── grandchild\n" ~
        "└── child2");
}

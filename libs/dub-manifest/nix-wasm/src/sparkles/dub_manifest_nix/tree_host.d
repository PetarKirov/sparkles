/++
A host of $(MREF sparkles, dub_manifest_nix, convert) that keeps its values
in memory: the module's conversion run natively, in tests and in the oracle
the Nix check compares the module with (WW10). `json` renders a value with
its attribute names sorted, as `builtins.toJSON` does.
+/
module sparkles.dub_manifest_nix.tree_host;

import sparkles.dub_manifest_nix.convert : NixKind;

/// Nix values as an array of nodes; a value is its node's index, and `0` is
/// "no value".
struct TreeHost
{
    alias Value = uint;

    private static struct Node
    {
        NixKind kind;
        long integer;
        bool boolean;
        string text;
        string[] names;
        Value[] items;
    }

    private Node[] nodes = [Node.init];

    private Value add(Node node) @safe pure nothrow
    {
        nodes ~= node;
        return cast(Value)(nodes.length - 1);
    }

    /// The value's kind.
    NixKind kindOf(Value v) const @safe pure nothrow @nogc => nodes[v].kind;

    /// A string's bytes.
    const(char)[] stringOf(Value v) const @safe pure nothrow @nogc => nodes[v].text;

    /// The attribute `name` of the set `set`, or `0`.
    Value attrOf(Value set, scope const(char)[] name) const @safe pure nothrow @nogc
    {
        foreach (i, n; nodes[set].names)
            if (n == name)
                return nodes[set].items[i];
        return 0;
    }

    Value string_(scope const(char)[] s) @safe pure nothrow
        => add(Node(NixKind.string_, 0, false, s.idup)); ///
    Value bool_(bool b) @safe pure nothrow => add(Node(NixKind.bool_, 0, b)); ///
    Value int_(long i) @safe pure nothrow => add(Node(NixKind.int_, i)); ///
    Value list(scope const(Value)[] items) @safe pure nothrow
        => add(Node(NixKind.list, 0, false, null, null, items.dup)); ///

    /// An attribute set; `names` must be distinct.
    Value attrs(scope const(char)[][] names, scope const(Value)[] values) @safe pure nothrow
    {
        auto copied = new string[names.length];
        foreach (i, n; names)
            copied[i] = n.idup;
        return add(Node(NixKind.attrs, 0, false, null, copied, values.dup));
    }

    /// `v` as JSON, attribute names in byte order.
    string json(Value v) const @safe pure
    {
        import std.array : appender;

        auto w = appender!string;
        writeJson(w, v);
        return w[];
    }

    private void writeJson(W)(ref W w, Value v) const
    {
        import std.algorithm.sorting : sort;
        import std.conv : to;
        import std.range : iota;

        const node = nodes[v];
        final switch (node.kind)
        {
        case NixKind.int_:
            w.put(node.integer.to!string);
            break;
        case NixKind.bool_:
            w.put(node.boolean ? "true" : "false");
            break;
        case NixKind.string_:
            writeString(w, node.text);
            break;
        case NixKind.list:
            w.put('[');
            foreach (i, item; node.items)
            {
                if (i)
                    w.put(',');
                writeJson(w, item);
            }
            w.put(']');
            break;
        case NixKind.attrs:
            auto order = iota(node.names.length).array_;
            order.sort!((a, b) => node.names[a] < node.names[b]);
            w.put('{');
            foreach (k, i; order)
            {
                if (k)
                    w.put(',');
                writeString(w, node.names[i]);
                w.put(':');
                writeJson(w, node.items[i]);
            }
            w.put('}');
            break;
        case NixKind.float_, NixKind.path, NixKind.null_, NixKind.function_:
            assert(0, "the conversion makes no such value");
        }
    }

    private static void writeString(W)(ref W w, string s)
    {
        import std.format : formattedWrite;

        w.put('"');
        foreach (char c; s)
        {
            if (c == '"' || c == '\\')
            {
                w.put('\\');
                w.put(c);
            }
            else if (c < 0x20)
                w.formattedWrite!"\\u%04x"(c);
            else
                w.put(c);
        }
        w.put('"');
    }
}

private size_t[] array_(R)(R r)
{
    import std.array : array;

    return r.array;
}

@("dub_manifest_nix.TreeHost.json")
@safe unittest
{
    TreeHost host;
    const(char)[][2] names = ["b", "a"];
    TreeHost.Value[2] values = [host.list([host.int_(1), host.bool_(true)]),
        host.string_("q\"\n")];
    assert(host.json(host.attrs(names[], values[])) == `{"a":"q\"\u000a","b":[1,true]}`);
    assert(host.attrOf(host.attrs(names[], values[]), "a") == values[1]);
    assert(host.attrOf(host.attrs(names[], values[]), "c") == 0);
}

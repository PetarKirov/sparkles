/**
Tree literals: a declared file tree, built into a `MemVfs` (FSD2).

The in-memory driver answers a resolution from a tree literal with no file
system at all, so the whole fileset contract is testable `@nogc`,
deterministically, on every platform. A literal is one entry per line, its
path relative to the tree's root:

$(TABLE
$(TR $(TH Line) $(TH Entry))
$(TR $(TD `src/`) $(TD a directory; missing parents are created))
$(TR $(TD `src/a.d`) $(TD an empty regular file))
$(TR $(TD `src/a.d = text`) $(TD a regular file holding `text`, in which `\n`
    is a newline and `\\` a backslash))
$(TR $(TD `bin/run +x`) $(TD an executable regular file; `= text` may follow))
$(TR $(TD `lib -> ../x`) $(TD a symbolic link, its target stored verbatim))
$(TR $(TD `# note`) $(TD a comment; blank lines are skipped too))
)

Leading and trailing blanks of a line are ignored, so a literal may be
indented. A name may not contain ` -> `, ` = ` or end in ` +x`. Modification
times are set with `MemTree.vfs.setMtime` when a fixture needs them.
*/
module sparkles.build_primitives.fileset.tree_literal;

import core.lifetime : move;
import core.memory : pureFree, pureMalloc;

import sparkles.base.unique : Unique, makeUnique;
import sparkles.base.vfs.mem : MemNode, MemVfs;

import sparkles.build_primitives.fileset.pattern : FilesetErrorCode, FilesetExpected,
    filesetErr, filesetOk;

/**
A `MemVfs` and the arenas it lives in, built from a tree literal. Its address
must not change while the backend is in use, so `memTree` returns it
heap-owned.
*/
struct MemTree
{
    @disable this(this);

    /// The backend; open the tree's root with `openRoot(&tree.vfs, "", …)`.
    MemVfs vfs;

    private MemNode[] nodes;
    private ubyte[] bytes;

    ~this() @trusted nothrow @nogc
    {
        if (nodes.ptr !is null)
            pureFree(nodes.ptr);
        if (bytes.ptr !is null)
            pureFree(bytes.ptr);
    }
}

/**
Builds a `MemTree` from `literal`, with room for `spareNodes` more entries
and `spareBytes` more bytes of contents, for fixtures that change the tree
while it is resolved. Errors name the offending line (1-based) in `offset`.
*/
FilesetExpected!(Unique!MemTree) memTree(scope const(char)[] literal, size_t spareNodes = 64,
    size_t spareBytes = 4096) @safe nothrow @nogc
{
    alias R = Unique!MemTree;
    size_t entries = 1, contentBytes;
    foreach (line; Lines(literal))
    {
        foreach (c; line)
            if (c == '/')
                ++entries;
        ++entries;
        contentBytes += line.length;
    }
    entries += spareNodes;
    contentBytes += spareBytes;

    auto tree = makeUnique!MemTree();
    if (tree.empty)
        return filesetErr!R(FilesetErrorCode.treeLiteralTooLarge, 0, "no memory for the tree");
    const ok = () @trusted {
        auto n = cast(MemNode*) pureMalloc(entries * MemNode.sizeof);
        auto b = cast(ubyte*) pureMalloc(contentBytes);
        if (n is null || b is null)
        {
            pureFree(n);
            pureFree(b);
            return false;
        }
        tree.get.nodes = n[0 .. entries];
        tree.get.bytes = b[0 .. contentBytes];
        tree.get.vfs = MemVfs(tree.get.nodes, tree.get.bytes);
        return true;
    }();
    if (!ok)
        return filesetErr!R(FilesetErrorCode.treeLiteralTooLarge, 0, "no memory for the tree");
    auto loaded = loadTreeLiteral(tree.get.vfs, literal);
    if (loaded.hasError)
        return filesetErr!R(loaded.error.code, loaded.error.offset, loaded.error.context);
    return filesetOk(move(tree));
}

/// The most bytes one file of a tree literal may hold.
enum size_t treeLiteralContentRoom = 4096;

/// Adds the entries of `literal` to `vfs`, beneath its root.
FilesetExpected!void loadTreeLiteral(ref MemVfs vfs, scope const(char)[] literal)
    @safe nothrow @nogc
{
    size_t number;
    foreach (raw; Lines(literal))
    {
        ++number;
        auto line = trim(raw);
        if (line.length == 0 || line[0] == '#')
            continue;
        bool done;
        if (line.length >= 3 && line[$ - 3 .. $] == " ->")
            return filesetErr!void(FilesetErrorCode.malformedTreeLiteral, number,
                "a link needs a target");
        const arrow = find(line, " -> ");
        if (arrow != size_t.max)
        {
            const path = line[0 .. arrow], target = line[arrow + 4 .. $];
            if (path.length == 0 || target.length == 0)
                return filesetErr!void(FilesetErrorCode.malformedTreeLiteral, number,
                    "a link needs a path and a target");
            done = vfs.symlink(path, target);
        }
        else if (line[$ - 1] == '/' && find(line, " = ") == size_t.max)
            done = vfs.mkdirs(line);
        else
        {
            const(char)[] content;
            const eq = find(line, " = ");
            auto path = line;
            if (eq != size_t.max)
            {
                content = line[eq + 3 .. $];
                path = line[0 .. eq];
            }
            else if (line.length >= 3 && line[$ - 3 .. $] == " =")
                path = line[0 .. $ - 2];
            bool executable;
            if (path.length > 3 && path[$ - 3 .. $] == " +x")
            {
                executable = true;
                path = path[0 .. $ - 3];
            }
            if (path.length == 0)
                return filesetErr!void(FilesetErrorCode.malformedTreeLiteral, number,
                    "a file needs a path");
            char[treeLiteralContentRoom] decoded = void;
            size_t n;
            for (size_t i = 0; i < content.length; ++i)
            {
                if (n == decoded.length)
                    return filesetErr!void(FilesetErrorCode.treeLiteralTooLarge, number,
                        "a file's text exceeds treeLiteralContentRoom");
                char c = content[i];
                if (c == '\\' && i + 1 < content.length
                    && (content[i + 1] == 'n' || content[i + 1] == '\\'))
                    c = content[++i] == 'n' ? '\n' : '\\';
                decoded[n++] = c;
            }
            done = vfs.writeFile(path, cast(const(ubyte)[]) decoded[0 .. n], executable);
        }
        if (!done)
            return filesetErr!void(FilesetErrorCode.treeLiteralTooLarge, number,
                "the entry conflicts with an earlier one, or the arena is full");
    }
    return filesetOk();
}

///
@("fileset.treeLiteral.build")
@safe nothrow @nogc unittest
{
    import sparkles.base.vfs.types : EntryKind;

    auto made = memTree(`
        # a small project
        src/a.d = module a;
        src/b.d
        bin/run +x = #!/bin/sh
        docs/
        lib -> src
    `);
    assert(!made.hasError);
    auto tree = &made.value.get();
    assert(tree.vfs.kindOf("src/a.d") == EntryKind.regular);
    assert(tree.vfs.contents("src/a.d") == "module a;");
    assert(tree.vfs.contents("bin/run") == "#!/bin/sh");
    assert(tree.vfs.kindOf("docs") == EntryKind.directory);
    assert(tree.vfs.kindOf("lib") == EntryKind.symlink);
    assert(tree.vfs.contents("lib") == "src");
}

/// A file's text may hold newlines, escaped.
@("fileset.treeLiteral.escapes")
@safe nothrow @nogc unittest
{
    auto made = memTree(`.gitignore = *.o\n!keep.o\nback\\slash`);
    assert(!made.hasError);
    assert(made.value.get().vfs.contents(".gitignore") == "*.o\n!keep.o\nback\\slash");
}

@("fileset.treeLiteral.errors")
@safe nothrow @nogc unittest
{
    assert(memTree("a -> ").error.code == FilesetErrorCode.malformedTreeLiteral);
    const clash = memTree("a\nok/\na/b");
    assert(clash.error.code == FilesetErrorCode.treeLiteralTooLarge);
    assert(clash.error.offset == 3, "the error names its line");
}

private struct Lines
{
    const(char)[] rest;
    const(char)[] front;
    bool empty;

    this(return scope const(char)[] text) @safe pure nothrow @nogc
    {
        rest = text;
        empty = false;
        popFront();
        // An empty text still has no lines.
        if (text.length == 0)
            empty = true;
    }

    void popFront() scope @safe pure nothrow @nogc
    {
        if (rest is null)
        {
            empty = true;
            return;
        }
        size_t i;
        while (i < rest.length && rest[i] != '\n')
            ++i;
        front = rest[0 .. i];
        rest = i < rest.length ? rest[i + 1 .. $] : null;
    }
}

private const(char)[] trim(return scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t b, e = s.length;
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r'))
        ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r'))
        --e;
    return s[b .. e];
}

private size_t find(scope const(char)[] s, scope const(char)[] needle) @safe pure nothrow @nogc
{
    if (needle.length > s.length)
        return size_t.max;
    foreach (i; 0 .. s.length - needle.length + 1)
        if (s[i .. i + needle.length] == needle)
            return i;
    return size_t.max;
}

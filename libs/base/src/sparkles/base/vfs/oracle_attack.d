/**
Oracle 1 of `docs/specs/base/vfs/testing.md`: the attack table, on `MemVfs`.

Every row builds its tree from a literal, runs one operation on a root under
each of the eight policies, and compares the outcome with an expectation
derived by hand from SPEC.md, not computed by production code. A sentinel
directory `outside/secret` sits beside the root; every refusal must leave it
untouched by any backend call, and a lexical refusal must make no backend
call at all.
*/
module sparkles.base.vfs.oracle_attack;

version (unittest):

import sparkles.base.vfs;
import sparkles.base.vfs.mem : testVfs;

private:

// Tree literal entries: "d:path" directory, "f:path" file, "l:path>target"
// link, "m:path" directory mounted on its own device.
struct Row
{
    int no;
    string[] tree;
    string op;      // "walk:<path>", "walkAll:<path>", "openDir:<name>",
                    // "openFile:<name>", "removeTree:<name>",
                    // "symlinkAt:<dir>:<name>:<target>"
    string[4] want; // N, NI, B, BI: an ErrorKind name, or "ok:<path>"
}

string itoa(int i)
{
    import std.conv : to;

    return i.to!string;
}

string[] chainOf41()
{
    string[] t = ["d:a"];
    foreach (i; 1 .. 41)
        t ~= "l:s" ~ itoa(i) ~ ">s" ~ itoa(i + 1);
    t ~= "l:s41>a";
    return t;
}

string nested65()
{
    string p;
    foreach (i; 0 .. 65)
        p ~= (i ? "/" : "") ~ "d";
    return p;
}

Row[] rows()
{
    const nameOf256 = () { char[256] n = 'x'; return n.idup; }();
    return [
        Row(1, ["f:a/b/f"], "walk:a/b", ["ok:a/b", "ok:a/b", "ok:a/b", "ok:a/b"]),
        Row(2, ["f:a/b/f"], "walk:./a//b/.", ["ok:a/b", "ok:a/b", "ok:a/b", "ok:a/b"]),
        Row(3, [], "walk:/etc", ["escapesRoot", "escapesRoot", "escapesRoot", "escapesRoot"]),
        Row(4, [], "walk:..", ["dotDotRefused", "escapesRoot", "dotDotRefused", "escapesRoot"]),
        Row(5, ["d:a", "d:c"], "walk:a/../c", ["dotDotRefused", "ok:c", "dotDotRefused", "ok:c"]),
        Row(6, ["d:a"], "walk:a/../../x",
            ["dotDotRefused", "escapesRoot", "dotDotRefused", "escapesRoot"]),
        Row(7, ["d:a/b", "l:s>a"], "walk:s/b",
            ["symlinkRefused", "symlinkRefused", "ok:a/b", "ok:a/b"]),
        Row(8, ["l:s>/"], "walk:s",
            ["symlinkRefused", "symlinkRefused", "escapesRoot", "escapesRoot"]),
        Row(9, ["l:s>../outside"], "walk:s",
            ["symlinkRefused", "symlinkRefused", "escapesRoot", "escapesRoot"]),
        Row(10, ["l:s1>a/s2", "d:a", "l:a/s2>../b", "d:b"], "walk:s1",
            ["symlinkRefused", "symlinkRefused", "ok:b", "ok:b"]),
        Row(11, ["l:s1>a/s2", "d:a", "l:a/s2>../../outside", "d:b"], "walk:s1",
            ["symlinkRefused", "symlinkRefused", "escapesRoot", "escapesRoot"]),
        Row(12, ["l:s1>s2", "l:s2>s1"], "walk:s1",
            ["symlinkRefused", "symlinkRefused", "symlinkLoop", "symlinkLoop"]),
        Row(13, ["d:a/b", "d:a/f", "l:s>a/b"], "walk:s/../f",
            ["dotDotRefused", "symlinkRefused", "dotDotRefused", "ok:a/f"]),
        Row(14, ["d:d", "l:d/d>.."], "walk:d/d",
            ["symlinkRefused", "symlinkRefused", "ok:", "ok:"]),
        Row(15, ["f:f"], "walk:f/x",
            ["notADirectory", "notADirectory", "notADirectory", "notADirectory"]),
        Row(16, ["d:a"], "walk:a/missing", ["notFound", "notFound", "notFound", "notFound"]),
        Row(17, ["m:m"], "walk:m", ["crossesMount", "crossesMount", "crossesMount", "crossesMount"]),
        Row(18, ["m:m"], "walk:m", ["ok:m", "ok:m", "ok:m", "ok:m"]),
        Row(19, chainOf41(), "walk:s1",
            ["symlinkRefused", "symlinkRefused", "symlinkLoop", "symlinkLoop"]),
        Row(20, [], "walkAll:" ~ nested65(),
            ["depthExceeded", "depthExceeded", "depthExceeded", "depthExceeded"]),
        Row(21, [], "openDir:a\0b", ["invalidName", "invalidName", "invalidName", "invalidName"]),
        Row(22, [], "openDir:" ~ nameOf256,
            ["nameTooLong", "nameTooLong", "nameTooLong", "nameTooLong"]),
        Row(23, ["l:s>../outside/secret"], "openFile:s",
            ["symlinkRefused", "symlinkRefused", "symlinkRefused", "symlinkRefused"]),
        Row(24, ["l:s>../outside"], "removeTree:s", ["ok:-s", "ok:-s", "ok:-s", "ok:-s"]),
        Row(25, [], "symlinkAt::s:/etc", ["escapesRoot", "escapesRoot", "escapesRoot", "escapesRoot"]),
        Row(26, ["d:a"], "symlinkAt:a:s:../../outside",
            ["ok:=a/s", "ok:=a/s", "ok:=a/s", "ok:=a/s"]),
    ];
}

void build(MemVfs* v, string[] tree)
{
    v.writeFile("outside/secret", cast(const(ubyte)[]) "secret");
    v.mkdirs("r");
    foreach (e; tree)
    {
        const kind = e[0];
        const spec = e[2 .. $];
        final switch (kind)
        {
            case 'd': assert(v.mkdirs("r/" ~ spec)); break;
            case 'f': assert(v.writeFile("r/" ~ spec, null)); break;
            case 'm': assert(v.mkdirs("r/" ~ spec) && v.mount("r/" ~ spec)); break;
            case 'l':
                import std.string : indexOf;

                const gt = spec.indexOf('>');
                assert(v.symlink("r/" ~ spec[0 .. gt], spec[gt + 1 .. $]));
                break;
        }
    }
    v.clearTouched();
    v.resetCounts();
}

enum lexical = [ErrorKind.escapesRoot, ErrorKind.dotDotRefused, ErrorKind.invalidName,
    ErrorKind.nameTooLong];

// Runs one row under one policy; returns a description of a mismatch, or null.
string check(in Row row, size_t column, bool crossMounts)
{
    import std.conv : to;
    import std.string : indexOf, split, startsWith;

    auto v = testVfs(512);
    build(v, cast(string[]) row.tree);

    ResolvePolicy policy;
    policy.symlinks = column >= 2 ? SymlinkPolicy.beneath : SymlinkPolicy.none;
    policy.dotDot = column % 2 ? DotDotPolicy.inScope : DotDotPolicy.reject;
    policy.crossMounts = crossMounts || row.no == 18;

    string want = row.want[column];
    if (row.no == 17 && crossMounts)
        want = "ok:m";

    auto root = openRoot!(Rights.all)(v, "r", ambientAuthority(), policy);
    assert(!root.hasError);
    v.clearTouched();
    v.resetCounts();

    IoError error;
    bool failed;
    string landed; // the path a successful walk or open reached
    const colon = row.op.indexOf(':');
    const op = row.op[0 .. colon];
    const arg = row.op[colon + 1 .. $];
    char[4096] pathBuf;
    switch (op)
    {
        case "walk", "walkAll":
            auto d = op == "walk" ? root.value.walk(arg) : root.value.walkAll(arg);
            if (d.hasError)
                (error = d.error), failed = true;
            else
                landed = v.pathOf(d.value.core.handle, pathBuf).idup;
            break;
        case "openDir":
            auto d = root.value.openDir(arg);
            if (d.hasError)
                (error = d.error), failed = true;
            break;
        case "openFile":
            auto f = root.value.openFile!(OpenMode.read)(arg);
            if (f.hasError)
                (error = f.error), failed = true;
            break;
        case "removeTree":
            auto r = root.value.removeTree(arg);
            if (r.hasError)
                (error = r.error), failed = true;
            break;
        case "symlinkAt":
            const parts = arg.split(':');
            IoResult!void r;
            if (parts[0].length)
            {
                auto d = root.value.walk(parts[0]);
                r = d.value.symlinkAt(parts[1], parts[2]);
            }
            else
                r = root.value.symlinkAt(parts[1], parts[2]);
            if (r.hasError)
                (error = r.error), failed = true;
            break;
        default:
            assert(0, op);
    }

    const where = "row " ~ row.no.to!string ~ " column " ~ "N NIB BI"[column * 2 .. column * 2 + 2]
        ~ (crossMounts ? " crossMounts" : "") ~ ": ";
    if (want.startsWith("ok:"))
    {
        if (failed)
            return where ~ "expected success, got " ~ error.kind.to!string;
        const target = want[3 .. $];
        if (target.startsWith("-"))
        {
            if (v.exists("r/" ~ target[1 .. $]))
                return where ~ "entry not removed";
        }
        else if (target.startsWith("="))
        {
            if (v.contents("r/" ~ target[1 .. $]) != cast(const(ubyte)[]) "../../outside")
                return where ~ "link target not stored verbatim";
        }
        else if (landed != ("r" ~ (target.length ? "/" ~ target : "")))
            return where ~ "landed on " ~ landed ~ ", expected r/" ~ target;
    }
    else
    {
        if (!failed)
            return where ~ "expected " ~ want ~ ", got success";
        if (error.kind.to!string != want)
            return where ~ "expected " ~ want ~ ", got " ~ error.kind.to!string;
        foreach (k; lexical)
            if (error.kind == k && error.context.length && v.totalCalls != 0)
                return where ~ "a lexical refusal made backend calls";
    }
    if (v.touched("outside"))
        return where ~ "a backend call touched the sentinel";
    if (v.contents("outside/secret") != cast(const(ubyte)[]) "secret")
        return where ~ "the sentinel changed";
    return null;
}

@("vfs.oracle1.attackTable")
@system unittest
{
    string[] failures;
    foreach (row; rows())
        foreach (column; 0 .. 4)
            foreach (crossMounts; [false, true])
                if (auto f = check(row, column, crossMounts))
                    failures ~= f;
    if (failures.length)
    {
        import std.array : join;

        assert(0, "\n" ~ failures.join("\n"));
    }
}

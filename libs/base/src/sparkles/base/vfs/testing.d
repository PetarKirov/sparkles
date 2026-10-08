/**
Test kit for capability VFS backends: oracle 1 of
`docs/specs/base/vfs/testing.md`, the attack table, runnable on any backend
through a fixture.

A fixture builds a tree in its backend and answers questions about it from
outside the capability API. It provides:

$(TABLE
$(TR $(TH Member) $(TH Meaning))
$(TR $(TD `alias Backend`) $(TD the backend type))
$(TR $(TD `Backend* vfs()`) $(TD the backend instance))
$(TR $(TD `string rootPath()`) $(TD the path `openRoot` opens: the tree's `r`))
$(TR $(TD `bool build(in string[] tree)`) $(TD creates `r`, the sentinel `outside/secret`, and
    `tree` (entries relative to `r`); `false` if an entry is not supported))
$(TR $(TD `bool isAt(Backend.Handle h, string path)`) $(TD whether `h` is the directory at `path`))
$(TR $(TD `bool exists(string path)`, `const(ubyte)[] contents(string path)`) $(TD paths from the
    tree's top, so `r/…` or `outside/secret`))
$(TR $(TD `string linkTarget(string path)`) $(TD a link's stored target))
$(TR $(TD optional `bool touched(string path)`, `void clearTouched()`) $(TD whether a backend call
    reached `path`; only an in-memory backend can tell))
$(TR $(TD optional `ulong backendCalls()`) $(TD calls made since `clearTouched`))
$(TR $(TD optional `bool canSymlink()`) $(TD false where the backend cannot create links; rows that create one are skipped))
)

Tree entries: `d:path` a directory, `f:path` a file, `l:path>target` a
symbolic link, `m:path` a directory on its own device (skipped where the
fixture cannot mount).
*/
module sparkles.base.vfs.testing;

import std.conv : to;
import std.string : indexOf, split, startsWith;

import sparkles.base.vfs.handles;
import sparkles.base.vfs.types;
import sparkles.base.io.errors : ErrorKind, IoError, IoResult;

/// One row of the attack table.
struct AttackRow
{
    int no; ///
    string[] tree; /// entries relative to `r`
    /// `walk:<path>`, `walkAll:<path>`, `openDir:<name>`, `openFile:<name>`,
    /// `removeTree:<name>` or `symlinkAt:<dir>:<name>:<target>`
    string op;
    /// For N, NI, B and BI: an `ErrorKind` name, `ok:<path>`, `ok:-<removed>`
    /// or `ok:=<link>`.
    string[4] want;
}

/// The rows of testing.md's table, as literal expectations.
AttackRow[] attackRows() @safe
{
    string[] chain = ["d:a"];
    foreach (i; 1 .. 41)
        chain ~= "l:s" ~ i.to!string ~ ">s" ~ (i + 1).to!string;
    chain ~= "l:s41>a";
    string nested;
    foreach (i; 0 .. 65)
        nested ~= (i ? "/" : "") ~ "d";
    char[256] longName = 'x';

    return [
        AttackRow(1, ["f:a/b/f"], "walk:a/b", ["ok:a/b", "ok:a/b", "ok:a/b", "ok:a/b"]),
        AttackRow(2, ["f:a/b/f"], "walk:./a//b/.", ["ok:a/b", "ok:a/b", "ok:a/b", "ok:a/b"]),
        AttackRow(3, [], "walk:/etc", ["escapesRoot", "escapesRoot", "escapesRoot", "escapesRoot"]),
        AttackRow(4, [], "walk:..", ["dotDotRefused", "escapesRoot", "dotDotRefused", "escapesRoot"]),
        AttackRow(5, ["d:a", "d:c"], "walk:a/../c", ["dotDotRefused", "ok:c", "dotDotRefused", "ok:c"]),
        AttackRow(6, ["d:a"], "walk:a/../../x",
            ["dotDotRefused", "escapesRoot", "dotDotRefused", "escapesRoot"]),
        AttackRow(7, ["d:a/b", "l:s>a"], "walk:s/b",
            ["symlinkRefused", "symlinkRefused", "ok:a/b", "ok:a/b"]),
        AttackRow(8, ["l:s>/"], "walk:s",
            ["symlinkRefused", "symlinkRefused", "escapesRoot", "escapesRoot"]),
        AttackRow(9, ["l:s>../outside"], "walk:s",
            ["symlinkRefused", "symlinkRefused", "escapesRoot", "escapesRoot"]),
        AttackRow(10, ["l:s1>a/s2", "d:a", "l:a/s2>../b", "d:b"], "walk:s1",
            ["symlinkRefused", "symlinkRefused", "ok:b", "ok:b"]),
        AttackRow(11, ["l:s1>a/s2", "d:a", "l:a/s2>../../outside", "d:b"], "walk:s1",
            ["symlinkRefused", "symlinkRefused", "escapesRoot", "escapesRoot"]),
        AttackRow(12, ["l:s1>s2", "l:s2>s1"], "walk:s1",
            ["symlinkRefused", "symlinkRefused", "symlinkLoop", "symlinkLoop"]),
        AttackRow(13, ["d:a/b", "d:a/f", "l:s>a/b"], "walk:s/../f",
            ["dotDotRefused", "symlinkRefused", "dotDotRefused", "ok:a/f"]),
        AttackRow(14, ["d:d", "l:d/d>.."], "walk:d/d",
            ["symlinkRefused", "symlinkRefused", "ok:", "ok:"]),
        AttackRow(15, ["f:f"], "walk:f/x",
            ["notADirectory", "notADirectory", "notADirectory", "notADirectory"]),
        AttackRow(16, ["d:a"], "walk:a/missing", ["notFound", "notFound", "notFound", "notFound"]),
        AttackRow(17, ["m:m"], "walk:m",
            ["crossesMount", "crossesMount", "crossesMount", "crossesMount"]),
        AttackRow(18, ["m:m"], "walk:m", ["ok:m", "ok:m", "ok:m", "ok:m"]),
        AttackRow(19, chain, "walk:s1",
            ["symlinkRefused", "symlinkRefused", "symlinkLoop", "symlinkLoop"]),
        AttackRow(20, [], "walkAll:" ~ nested,
            ["depthExceeded", "depthExceeded", "depthExceeded", "depthExceeded"]),
        AttackRow(21, [], "openDir:a\0b", ["invalidName", "invalidName", "invalidName", "invalidName"]),
        AttackRow(22, [], "openDir:" ~ longName.idup,
            ["nameTooLong", "nameTooLong", "nameTooLong", "nameTooLong"]),
        AttackRow(23, ["l:s>../outside/secret"], "openFile:s",
            ["symlinkRefused", "symlinkRefused", "symlinkRefused", "symlinkRefused"]),
        AttackRow(24, ["l:s>../outside"], "removeTree:s", ["ok:-s", "ok:-s", "ok:-s", "ok:-s"]),
        AttackRow(25, [], "symlinkAt::s:/etc",
            ["escapesRoot", "escapesRoot", "escapesRoot", "escapesRoot"]),
        AttackRow(26, ["d:a"], "symlinkAt:a:s:../../outside",
            ["ok:=a/s", "ok:=a/s", "ok:=a/s", "ok:=a/s"]),
    ];
}

/// The policy of column `column` (N, NI, B, BI), with or without crossings.
ResolvePolicy columnPolicy(size_t column, bool crossMounts) @safe pure nothrow @nogc
{
    ResolvePolicy p;
    p.symlinks = column >= 2 ? SymlinkPolicy.beneath : SymlinkPolicy.none;
    p.dotDot = column % 2 ? DotDotPolicy.inScope : DotDotPolicy.reject;
    p.crossMounts = crossMounts;
    return p;
}

/**
Runs every row under every policy, each on a fresh fixture from `make`, and
returns a description of each mismatch. Rows whose tree the fixture cannot
build are counted in `skipped`. `configure`, if given, runs on each opened
root's backend before the operation, for example to force the component walk.
*/
string[] runAttackTable(F)(scope F delegate() @safe make, out size_t skipped,
    scope void delegate(F.Backend* vfs) @safe configure = null) @safe
{
    string[] failures;
    foreach (row; attackRows())
        foreach (column; 0 .. 4)
            foreach (crossMounts; [false, true])
            {
                auto f = make();
                static if (__traits(hasMember, F, "canSymlink"))
                    if (row.op.startsWith("symlinkAt") && !f.canSymlink)
                    {
                        ++skipped;
                        continue;
                    }
                if (!f.build(row.tree))
                {
                    ++skipped;
                    continue;
                }
                if (configure !is null)
                    configure(f.vfs);
                if (auto problem = checkRow(f, row, column, crossMounts))
                    failures ~= problem;
            }
    return failures;
}

private enum lexicalKinds = [ErrorKind.escapesRoot, ErrorKind.dotDotRefused,
    ErrorKind.invalidName, ErrorKind.nameTooLong];

private string checkRow(F)(ref F f, const AttackRow row, size_t column, bool crossMounts) @safe
{
    const policy = columnPolicy(column, crossMounts || row.no == 18);
    string want = row.want[column];
    if (row.no == 17 && crossMounts)
        want = "ok:m";

    auto root = openRoot!(Rights.all)(f.vfs, f.rootPath, ambientAuthority(), policy);
    if (root.hasError)
        return "row " ~ row.no.to!string ~ ": openRoot failed: " ~ root.error.kind.to!string;
    static if (__traits(hasMember, F, "clearTouched"))
        f.clearTouched();

    IoError error;
    bool failed, landedRight = true;
    string landedTarget;
    const colon = row.op.indexOf(':');
    const op = row.op[0 .. colon];
    const arg = row.op[colon + 1 .. $];
    switch (op)
    {
        case "walk", "walkAll":
            auto d = op == "walk" ? root.value.walk(arg) : root.value.walkAll(arg);
            if (d.hasError)
                (error = d.error), failed = true;
            else if (want.startsWith("ok:") && !want.startsWith("ok:-") && !want.startsWith("ok:="))
            {
                landedTarget = want[3 .. $];
                landedRight = f.isAt(d.value.core.handle,
                    "r" ~ (landedTarget.length ? "/" ~ landedTarget : ""));
            }
            break;
        case "openDir":
            auto d = root.value.openDir(arg);
            if (d.hasError)
                (error = d.error), failed = true;
            break;
        case "openFile":
            auto file = root.value.openFile!(OpenMode.read)(arg);
            if (file.hasError)
                (error = file.error), failed = true;
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
                r = root.value.walk(parts[0]).value.symlinkAt(parts[1], parts[2]);
            else
                r = root.value.symlinkAt(parts[1], parts[2]);
            if (r.hasError)
                (error = r.error), failed = true;
            break;
        default:
            assert(0, op);
    }

    const where = "row " ~ row.no.to!string ~ " " ~ ["N", "NI", "B", "BI"][column]
        ~ (crossMounts ? " crossMounts" : "") ~ ": ";
    if (want.startsWith("ok:"))
    {
        if (failed)
            return where ~ "expected success, got " ~ error.kind.to!string;
        const target = want[3 .. $];
        if (target.startsWith("-"))
        {
            if (f.exists("r/" ~ target[1 .. $]))
                return where ~ "entry not removed";
        }
        else if (target.startsWith("="))
        {
            if (f.linkTarget("r/" ~ target[1 .. $]) != "../../outside")
                return where ~ "link target not stored verbatim";
        }
        else if (!landedRight)
            return where ~ "did not land on r/" ~ landedTarget;
    }
    else
    {
        if (!failed)
            return where ~ "expected " ~ want ~ ", got success";
        if (error.kind.to!string != want)
            return where ~ "expected " ~ want ~ ", got " ~ error.kind.to!string;
        static if (__traits(hasMember, F, "backendCalls"))
            foreach (k; lexicalKinds)
                if (error.kind == k && error.context.length && f.backendCalls != 0)
                    return where ~ "a lexical refusal made backend calls";
    }
    static if (__traits(hasMember, F, "touched"))
        if (f.touched("outside"))
            return where ~ "a backend call touched the sentinel";
    if (f.contents("outside/secret") != cast(const(ubyte)[]) "secret")
        return where ~ "the sentinel changed";
    return null;
}

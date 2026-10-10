/**
Oracle 1 of `docs/specs/base/vfs/testing.md`, the attack table, on `MemVfs`.

The table and its checker live in `sparkles.base.vfs.testing`, so native
backends run the same rows. `MemVfs` adds what only an in-memory backend can
tell: that no backend call touched the sentinel, and that a lexical refusal
made no backend call at all.
*/
module sparkles.base.vfs.oracle_attack;

version (unittest):

import sparkles.base.vfs;
import sparkles.base.vfs.mem : testVfs;
import sparkles.base.vfs.testing : runAttackTable;

/// The `MemVfs` fixture for the attack table.
struct MemFixture
{
    alias Backend = MemVfs;
    MemVfs* backend;

    MemVfs* vfs() @safe => backend;
    string rootPath() @safe => "r";

    bool build(in string[] tree) @safe
    {
        import std.string : indexOf;

        backend.writeFile("outside/secret", cast(const(ubyte)[]) "secret");
        backend.mkdirs("r");
        foreach (e; tree)
        {
            const spec = e[2 .. $];
            final switch (e[0])
            {
                case 'd': assert(backend.mkdirs("r/" ~ spec)); break;
                case 'f': assert(backend.writeFile("r/" ~ spec, null)); break;
                case 'm': assert(backend.mkdirs("r/" ~ spec) && backend.mount("r/" ~ spec)); break;
                case 'l':
                    const gt = spec.indexOf('>');
                    assert(backend.symlink("r/" ~ spec[0 .. gt], spec[gt + 1 .. $]));
                    break;
            }
        }
        return true;
    }

    bool isAt(MemVfs.Handle h, string path) @safe
    {
        char[4096] buf;
        return backend.pathOf(h, buf) == path;
    }

    bool exists(string path) @safe => backend.exists(path);
    const(ubyte)[] contents(string path) @safe => backend.contents(path);
    string linkTarget(string path) @safe => cast(string) backend.contents(path).idup;
    bool touched(string path) @safe => backend.touched(path);

    void clearTouched() @safe
    {
        backend.clearTouched();
        backend.resetCounts();
    }

    ulong backendCalls() @safe => backend.totalCalls;
}

@("vfs.oracle1.attackTable")
@safe unittest
{
    size_t skipped;
    const failures = runAttackTable!MemFixture(() => MemFixture(testVfs(512)), skipped);
    assert(skipped == 0, "MemVfs builds every row");
    if (failures.length)
    {
        import std.array : join;

        assert(0, "\n" ~ failures.join("\n"));
    }
}

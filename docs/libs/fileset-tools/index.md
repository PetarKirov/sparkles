# sparkles:fileset-tools

The members a fileset selects from a tree, the names that identify them, and
copying them elsewhere: the engine of `fsx` and of the fileset explorer
([specification](../../specs/fsx/SPEC.md)).

A query in the fileset query language is resolved over a source with
`evaluate`, which returns the members, each a regular file or a symbolic
link at a path from the root, with the castore, NAR, git and iroh names of
their tree. `copyMembers` writes them to a destination through the
capability VFS, over the blocking backend or the ring one, and `statsRows`
is the report the explorer's Stats tab shows. Nothing here depends on the
toolkit's UI packages, so a command-line program can link it alone.

```d
import sparkles.fileset_tools;

void show(string dir)
{
    import std.stdio : write;

    auto o = evaluate(Root(dir: dir), "src/** - **/*_test.d", withIds: true);
    if (o.failed)
        return write(o.error.message, "\n");
    write(formatStats(o));
}
```

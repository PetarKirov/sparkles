#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_file_read"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.lifetime : move;
import core.sys.posix.stdlib : mkdtemp;
import std.file : remove, rmdir, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.vfs : ErrorKind, OpenMode, Rights, ambientAuthority, openRoot;
import sparkles.event_horizon;

void main()
{
    auto template_ = (buildPath(tempDir(), "eh-file-XXXXXX") ~ '\0').dup;
    assert(mkdtemp(template_.ptr) !is null);
    const dir = template_[0 .. $ - 1].idup;
    scope (exit) rmdir(dir);
    const path = buildPath(dir, "input.txt");
    write(path, "hello from a file\n");
    scope (exit) remove(path);

    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        assert(false, "no completion backend");
    scope (exit) group.shutdown();

    auto run = group.run((ref RootScope sc, ref Env env) {
        // Files are reached through a directory capability, and close
        // themselves; `read` borrows the file's descriptor.
        auto root = openRoot!(Rights.readOnly)(&env.fs(), dir, ambientAuthority());
        assert(root.hasValue);
        auto missing = root.value.openFile!(OpenMode.read)("missing");
        assert(missing.hasError && missing.error.kind == ErrorKind.notFound);
        auto opened = root.value.openFile!(OpenMode.read)("input.txt");
        assert(opened.hasValue);
        auto f = move(opened.value);
        UniqueBuffer!(ubyte, 128) buf;
        string contents;
        for (;;)
        {
            buf.length = 128;
            auto got = read(f, move(buf), contents.length);
            buf = move(got.buf);
            assert(got.res.hasValue);
            if (got.res.value == 0)
                break;
            contents ~= cast(const(char)[]) buf[][0 .. got.res.value];
        }
        assert(contents == "hello from a file\n");
        writeln("read ", contents.length, " bytes: ", contents);
        return 0;
    });
    assert(run.hasValue);
}

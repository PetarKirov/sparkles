#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_file_read"
    dependency "photon" version="0.19.3"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.fcntl : open, O_RDONLY;
import core.sys.posix.unistd : close, read;
import std.file : remove, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : toStringz;
import photon;

void main()
{
    const directory = fixtureDirectory();
    scope(exit) { import std.file : rmdir; rmdir(directory); }
    const path = buildPath(directory, "input");
    write(path, "hello from a file\n");
    scope (exit) remove(path);

    initPhoton();

    go({
        // Photon intercepts open() and read(). Because regular files return EPERM
        // on epoll_ctl, Photon marks the FD as THREADPOOL and offloads blocking
        // libc read() calls to an internal background worker thread pool.
        int fd = open(path.toStringz, O_RDONLY);
        assert(fd >= 0);
        scope (exit) close(fd);

        ubyte[128] buf;
        ssize_t n = read(fd, buf.ptr, buf.length);
        assert(n == 18);
        assert(cast(const(char)[]) buf[0 .. n] == "hello from a file\n");

        writeln("read ", n, " bytes: ", cast(const(char)[]) buf[0 .. n]);
    });

    runScheduler();
}

// A fresh directory prevents interference between parallel tutorial runs.
string fixtureDirectory() @trusted
{
    import core.sys.posix.stdlib : mkdtemp;
    import std.string : fromStringz;
    auto pattern = (buildPath(tempDir(), "eh-comparison-XXXXXX") ~ '\0').dup;
    auto created = mkdtemp(pattern.ptr);
    assert(created !is null);
    return fromStringz(created).idup;
}

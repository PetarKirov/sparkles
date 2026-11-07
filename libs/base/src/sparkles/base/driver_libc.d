/**
The glibc a process's GPU drivers need, and the re-execution that gives it to
them.

A process has one C library, and the drivers that the Vulkan loader and
libglvnd open share it. A Nix-built program carries its own glibc, while on
NixOS the drivers come from the system's nixpkgs: when that is newer, every
driver that needs a newer glibc fails to load. Mesa's RADV, lavapipe and
radeonsi link LLVM, which does, and the loader skips them with "version
`GLIBC_2.44' not found". Static linking cannot help, because the drivers are
shared objects that bring `libc.so.6` with them.

$(LREF reexecOntoDriverGlibc), called first thing in `main`, finds the newest
glibc any driver manifest leads to. When it is newer than the one running, the
program runs itself again, once, through that glibc's dynamic linker with the
glibc's directory searched first; glibc runs programs built against older
releases, so the whole process then shares the drivers' C library.
$(LREF forEachDriverLibc) is the scan on its own, and $(LREF thisProgramPath)
is the program's own path either way: after a re-execution `/proc/self/exe`,
and Phobos' `thisExePath`, name the dynamic linker.

Only Linux with glibc has anything to find; elsewhere the scan visits nothing
and nothing re-executes.
*/
module sparkles.base.driver_libc;

import sparkles.base.text.cstring : CString, tryToCString;
import sparkles.base.text.readers : readInteger, tryConsume;
import sparkles.test_runner.attributes : serial;

version (linux)
    version (CRuntime_Glibc)
        version = DriverLibc;

/// A glibc release, `major.minor`; `.init` is unknown and sorts first.
struct GlibcRelease
{
    uint major; ///
    uint minor; ///

    /// Writes `2.44`. A template, so it infers the writer's attributes.
    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text.writers : writeInteger;

        writeInteger(w, major);
        put(w, '.');
        writeInteger(w, minor);
    }

@safe pure nothrow @nogc:

    /// Whether this names a release.
    bool known() const => major != 0;

    ///
    int opCmp(in GlibcRelease o) const
        => major != o.major ? (major < o.major ? -1 : 1)
        : minor != o.minor ? (minor < o.minor ? -1 : 1)
        : 0;

    /// `2.44`, from text that starts so; `.init` from anything else.
    static GlibcRelease parse(scope const(char)[] s)
    {
        const major = readInteger!uint(s);
        if (major.hasError || !s.tryConsume('.'))
            return GlibcRelease.init;
        const minor = readInteger!uint(s);
        return minor.hasError ? GlibcRelease.init : GlibcRelease(major.value, minor.value);
    }
}

///
@("driver_libc.GlibcRelease.parseAndOrder")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkToString;

    assert(GlibcRelease.parse("2.44") == GlibcRelease(2, 44));
    assert(GlibcRelease.parse("2.39-0ubuntu8") == GlibcRelease(2, 39));
    assert(!GlibcRelease.parse("glibc").known);
    assert(GlibcRelease(2, 44) > GlibcRelease(2, 9));
    assert(GlibcRelease.init < GlibcRelease(2, 17));
    checkToString(GlibcRelease(2, 44), "2.44");
}

/// The driver interfaces whose manifests the scan reads.
enum DriverApi
{
    vulkan, /// Vulkan installable client drivers (`vulkan/icd.d`)
    egl,    /// libglvnd's EGL vendor libraries (`glvnd/egl_vendor.d`)
}

/**
One driver manifest and the glibc its library loads. The slices are borrowed
for the duration of the visit only.
*/
struct DriverLibc
{
    DriverApi api;          /// which loader reads the manifest
    const(char)[] manifest; /// the JSON file
    const(char)[] library;  /// its `library_path`, resolved; empty when not found
    const(char)[] libcDir;  /// the directory of the `libc.so.6` the library loads; empty when none was found
    GlibcRelease release;   /// that glibc's release; unknown when none was found
}

/// What $(LREF reexecOntoDriverGlibc) did.
enum ReexecStatus
{
    unsupported, /// not Linux with glibc
    current,     /// the running glibc is at least as new as every driver's
    reexecuted,  /// this process is the re-executed one, on the drivers' glibc
    declined,    /// a driver needs a newer glibc, and the caller kept this one
    failed,      /// a driver needs a newer glibc, and running on it failed
}

/// The outcome of $(LREF reexecOntoDriverGlibc).
struct ReexecOutcome
{
    ReexecStatus status;    ///
    GlibcRelease running;   /// the glibc this process runs on
    GlibcRelease startedOn; /// `reexecuted`: the glibc the program started on
    GlibcRelease drivers;   /// the newest glibc a driver loads; unknown after a re-execution
    int error;              /// `failed`: the `errno` of `execv`, or 0 when it never ran
}

/// Set in a re-executed program's environment, and cleared again at its start,
/// so that its own children do not inherit them.
private enum fromVariable = "SPARKLES_LIBC_REEXEC_FROM";
/// ditto
private enum exeVariable = "SPARKLES_LIBC_REEXEC_EXE";

/// Paths here are bounded like the kernel's.
private enum pathMax = 4096;

// Written once, by the re-execution step at the start of `main`, before the
// program starts a thread; read-only afterwards.
private __gshared CString!pathMax originalExe;
private __gshared bool originalExeKnown;

/**
Run this program on the newest glibc a GPU driver loads, when that is newer
than the one running: the step to call first in `main`, before any thread
starts and before the Vulkan loader or libglvnd is opened.

On success the program starts again from the beginning, as the same
executable with the same arguments and environment, and this call does not
return; in the new process it returns `reexecuted`. `allow` false only
reports the mismatch (`declined`), and a failed attempt returns `failed` with
the program unchanged.
*/
ReexecOutcome reexecOntoDriverGlibc(bool allow = true) @system nothrow @nogc
{
    ReexecOutcome outcome;
    version (DriverLibc)
    {
        import core.stdc.errno : errno;
        import core.stdc.stdlib : getenv;
        import core.sys.posix.stdlib : setenv, unsetenv;
        import core.sys.posix.unistd : execv;

        outcome.running = runningGlibc();
        if (const from = getenv(fromVariable))
        {
            outcome.status = ReexecStatus.reexecuted;
            outcome.startedOn = GlibcRelease.parse(fromStringz(from));
            if (const exe = getenv(exeVariable))
                originalExeKnown = tryToCString(originalExe, [fromStringz(exe)]);
            unsetenv(fromVariable);
            unsetenv(exeVariable);
            return outcome;
        }

        CString!pathMax newestDir;
        forEachDriverLibc((in DriverLibc d) {
            if (d.release > outcome.drivers && tryToCString(newestDir, [d.libcDir]))
                outcome.drivers = d.release;
        });
        if (outcome.drivers <= outcome.running)
        {
            outcome.status = ReexecStatus.current;
            return outcome;
        }
        outcome.status = allow ? ReexecStatus.failed : ReexecStatus.declined;
        if (!allow)
            return outcome;

        CString!pathMax self, linker;
        char[32] fromText = void;
        if (!readSelfExe(self) || !tryToCString(linker, [newestDir[], "/", dynamicLinker]))
            return outcome;
        auto from = formatRelease(fromText, outcome.running);
        CString!32 fromZ;
        if (!tryToCString(fromZ, [from]) || setenv(fromVariable, fromZ.ptr, 1) != 0
            || setenv(exeVariable, self.ptr, 1) != 0)
            return outcome;

        // `ld.so --argv0 ARGV0 --library-path DIR PROGRAM ARGS…`, from the
        // C arguments, which are what the program started with.
        const args = rt_cArgs();
        enum prefix = 6;
        auto argv = cast(const(char)**) pureMallocArray(args.argc + prefix + 1);
        if (argv is null)
            return outcome;
        argv[0] = linker.ptr;
        argv[1] = "--argv0";
        argv[2] = args.argc ? args.argv[0] : self.ptr;
        argv[3] = "--library-path";
        CString!pathMax dirZ;
        if (!tryToCString(dirZ, [newestDir[]]))
            return outcome;
        argv[4] = dirZ.ptr;
        argv[5] = self.ptr;
        foreach (i; 1 .. args.argc)
            argv[prefix + i - 1] = args.argv[i];
        argv[prefix + (args.argc ? args.argc - 1 : 0)] = null;

        execv(linker.ptr, cast(char**) argv);
        outcome.error = errno;
        unsetenv(fromVariable);
        unsetenv(exeVariable);
        pureFreeArray(argv);
    }
    return outcome;
}

/**
The path of this program's executable when $(LREF reexecOntoDriverGlibc)
re-executed it, else empty. A re-executed program's `/proc/self/exe`, and
Phobos' `thisExePath`, name the dynamic linker; $(LREF thisProgramPath) is the
path either way.
*/
const(char)[] reexecutedExecutable() @system nothrow @nogc
    => originalExeKnown ? originalExe[] : null;

/**
This program's executable, whether or not $(LREF reexecOntoDriverGlibc)
re-executed it: use it in place of `thisExePath` wherever a program finds
its own files or reads its own build information.
*/
string thisProgramPath() @system
{
    import std.file : thisExePath;

    const reexecuted = reexecutedExecutable;
    return reexecuted.length ? reexecuted.idup : thisExePath;
}

/**
Visit every driver manifest the Vulkan loader and libglvnd read, with the glibc
each driver library loads: `sink(in DriverLibc)`, whose attributes the scan
takes. Linux with glibc only; elsewhere nothing is visited.

The manifests are found the way the loaders find them: the files and
directories `VK_DRIVER_FILES` (or the older `VK_ICD_FILENAMES`) and
`__EGL_VENDOR_LIBRARY_FILENAMES` (or `__EGL_VENDOR_LIBRARY_DIRS`) name when
set, else the XDG search path, `/etc` and NixOS's `/run/opengl-driver/share`.
A driver's glibc is the first directory with `libc.so.6` and glibc's dynamic
linker in its run path, its own directory, or the system's library directories.
*/
void forEachDriverLibc(Sink)(scope Sink sink)
{
    version (DriverLibc)
    {
        LibcCache cache;
        scanManifests(DriverApi.vulkan, "VK_DRIVER_FILES", "VK_ICD_FILENAMES", null,
            "vulkan/icd.d", cache, sink);
        scanManifests(DriverApi.egl, "__EGL_VENDOR_LIBRARY_FILENAMES", null,
            "__EGL_VENDOR_LIBRARY_DIRS", "glvnd/egl_vendor.d", cache, sink);
    }
}

version (DriverLibc):

import core.stdc.stdlib : getenv;
import core.sys.posix.unistd : access, F_OK;

extern (C) private const(char)* gnu_get_libc_version() nothrow @nogc;

// `Runtime.cArgs` without its missing `nothrow`, and without importing
// `core.runtime`, whose import closure leaves this test build referring to
// the `ModuleInfo` of `ldc.simd` and `ldc.llvmasm`: druntime returns the arguments
// `main` was called with, which cannot fail.
private struct CArgs { int argc; char** argv; } // `core.runtime.CArgs`
extern (C) private CArgs rt_cArgs() nothrow @nogc;

version (X86_64)
{
    private enum dynamicLinker = "ld-linux-x86-64.so.2";
    private enum multiarch = "x86_64-linux-gnu";
}
else version (AArch64)
{
    private enum dynamicLinker = "ld-linux-aarch64.so.1";
    private enum multiarch = "aarch64-linux-gnu";
}
else
{
    private enum dynamicLinker = "ld-linux.so.2";
    private enum multiarch = "";
}

/// Where distributions keep glibc: Debian's multiarch, Fedora's `lib64`, Arch's `lib`.
private immutable string[] systemLibDirs = [
    "/lib/" ~ multiarch, "/usr/lib/" ~ multiarch, "/lib64", "/usr/lib64", "/lib", "/usr/lib",
];

/// Where a manifest's bare library name is found: NixOS's driver directory, then the system's.
private immutable string[] driverLibDirs = ["/run/opengl-driver/lib"] ~ systemLibDirs;

private GlibcRelease runningGlibc() @system nothrow @nogc
    => GlibcRelease.parse(fromStringz(gnu_get_libc_version()));

private const(char)[] fromStringz(const(char)* p) @system pure nothrow @nogc
{
    import core.stdc.string : strlen;

    return p ? p[0 .. strlen(p)] : null;
}

private const(char)[] formatRelease(return ref char[32] buf, GlibcRelease r) @safe pure nothrow @nogc
{
    import sparkles.base.buffer : InlineBuffer;

    InlineBuffer!(char, 32) b;
    b.tryWrite((scope ref w) { r.toString(w); });
    buf[0 .. b.length] = b[];
    return buf[0 .. b.length];
}

private void* pureMallocArray(size_t n) @trusted pure nothrow @nogc
{
    import core.memory : pureMalloc;

    return pureMalloc(n * (void*).sizeof);
}

private void pureFreeArray(const(char)** p) @system pure nothrow @nogc
{
    import core.memory : pureFree;

    pureFree(cast(void*) p);
}

private bool readSelfExe(out CString!pathMax dest) @system nothrow @nogc
{
    import core.sys.posix.unistd : readlink;

    char[pathMax] buf = void;
    const n = readlink("/proc/self/exe", buf.ptr, buf.length);
    return n > 0 && n < buf.length && tryToCString(dest, [buf[0 .. n]]);
}

private bool exists(scope const(char)[] dir, scope const(char)[] name) @system nothrow @nogc
{
    CString!pathMax p;
    return tryToCString(p, [dir, "/", name]) && access(p.ptr, F_OK) == 0;
}

/// The release of the last glibc directory read: the drivers of one system
/// almost always share one, and each banner read maps a 2 MiB file.
private struct LibcCache
{
    CString!pathMax dir;
    GlibcRelease release;
}

/// The variables are C strings, `null` for one a loader does not read.
private void scanManifests(Sink)(DriverApi api, const(char)* filesVariable, const(char)* legacyFilesVariable,
    const(char)* dirsVariable, string subdir, ref LibcCache cache,
    scope Sink sink)
{
    const(char)* files = getenv(filesVariable);
    if (!files && legacyFilesVariable)
        files = getenv(legacyFilesVariable);
    if (files)
    {
        foreach (entry; PathList(fromStringz(files)))
            if (entry.length > 5 && entry[$ - 5 .. $] == ".json")
                visitManifest(api, entry, cache, sink);
            else
                visitDir(api, entry, cache, sink);
        return;
    }
    if (dirsVariable)
        if (const dirs = getenv(dirsVariable))
        {
            foreach (dir; PathList(fromStringz(dirs)))
                visitDir(api, dir, cache, sink);
            return;
        }

    // The loaders' own order: user configuration, system configuration, then data.
    const home = fromStringz(getenv("HOME"));
    void base(scope const(char)[] dir)
    {
        CString!pathMax d;
        if (dir.length && tryToCString(d, [dir, "/", subdir]))
            visitDir(api, d[], cache, sink);
    }
    void homeBase(const(char)* variable, string fallback)
    {
        if (const v = getenv(variable))
            base(fromStringz(v));
        else if (home.length)
        {
            CString!pathMax d;
            if (tryToCString(d, [home, fallback]))
                base(d[]);
        }
    }
    void bases(const(char)* variable, string fallback)
    {
        const v = getenv(variable);
        foreach (dir; PathList(v ? fromStringz(v) : fallback))
            base(dir);
    }
    homeBase("XDG_CONFIG_HOME", "/.config");
    bases("XDG_CONFIG_DIRS", "/etc/xdg");
    base("/etc");
    base("/run/opengl-driver/share");
    homeBase("XDG_DATA_HOME", "/.local/share");
    bases("XDG_DATA_DIRS", "/usr/local/share:/usr/share");
}

/// The non-empty entries of a `:`-separated list, as an input range.
private struct PathList
{
    private const(char)[] rest;
    const(char)[] front;

@safe pure nothrow @nogc:
    this(const(char)[] list)
    {
        rest = list;
        popFront();
    }

    bool empty() const => front is null;

    void popFront()
    {
        front = null;
        while (rest.length && front is null)
        {
            size_t i;
            while (i < rest.length && rest[i] != ':')
                ++i;
            if (i)
                front = rest[0 .. i];
            rest = i < rest.length ? rest[i + 1 .. $] : null;
        }
    }
}

private void visitDir(Sink)(DriverApi api, scope const(char)[] dir, ref LibcCache cache,
    scope Sink sink)
{
    import core.sys.posix.dirent : closedir, opendir, readdir;

    CString!pathMax dirZ;
    if (!tryToCString(dirZ, [dir]))
        return;
    auto d = opendir(dirZ.ptr);
    if (!d)
        return;
    scope (exit)
        closedir(d);
    while (auto e = readdir(d))
    {
        const name = fromStringz(e.d_name.ptr);
        if (name.length <= 5 || name[$ - 5 .. $] != ".json")
            continue;
        CString!pathMax file;
        if (tryToCString(file, [dir, "/", name]))
            visitManifest(api, file[], cache, sink);
    }
}

private void visitManifest(Sink)(DriverApi api, scope const(char)[] manifest, ref LibcCache cache,
    scope Sink sink)
{
    DriverLibc d = { api: api, manifest: manifest };
    CString!pathMax libraryPath, library, libcDir;
    char[16 * 1024] text = void;
    if (readLibraryPath(manifest, text, libraryPath)
        && resolveLibrary(libraryPath[], dirOf(manifest), library))
    {
        d.library = library[];
        if (libcDirOf(library[], libcDir))
        {
            d.libcDir = libcDir[];
            if (cache.dir[] != libcDir[])
            {
                cache.release = glibcReleaseIn(libcDir[]);
                cache.dir = libcDir;
            }
            d.release = cache.release;
        }
    }
    sink(d);
}

private const(char)[] dirOf(return scope const(char)[] path) @safe pure nothrow @nogc
{
    size_t i = path.length;
    while (i > 0 && path[i - 1] != '/')
        --i;
    return i > 1 ? path[0 .. i - 1] : i == 1 ? "/" : ".";
}

/// Read `manifest` and copy its `"library_path"` string into `dest`: the one
/// key both manifest formats share, under their `ICD` object.
private bool readLibraryPath(scope const(char)[] manifest, ref char[16 * 1024] text,
    out CString!pathMax dest) @system nothrow @nogc
{
    import core.sys.posix.fcntl : O_CLOEXEC, O_RDONLY, open;
    import core.sys.posix.unistd : close, read;

    CString!pathMax z;
    if (!tryToCString(z, [manifest]))
        return false;
    const fd = open(z.ptr, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    scope (exit)
        close(fd);
    size_t n;
    while (n < text.length)
    {
        const got = read(fd, text.ptr + n, text.length - n);
        if (got <= 0)
            break;
        n += got;
    }
    return jsonStringValue(text[0 .. n], `"library_path"`, dest);
}

/// The string value of the first `key` in `json`, unescaped; `false` when
/// there is none or it uses an escape a path does not need.
private bool jsonStringValue(scope const(char)[] json, scope const(char)[] key,
    out CString!pathMax dest) @safe nothrow @nogc
{
    size_t i;
    for (;; ++i)
    {
        if (i + key.length > json.length)
            return false;
        if (json[i .. i + key.length] == key)
            break;
    }
    i += key.length;
    static bool space(char c) @safe pure nothrow @nogc => c == ' ' || c == '\t' || c == '\n' || c == '\r';
    while (i < json.length && space(json[i]))
        ++i;
    if (i >= json.length || json[i++] != ':')
        return false;
    while (i < json.length && space(json[i]))
        ++i;
    if (i >= json.length || json[i++] != '"')
        return false;

    char[pathMax] value = void;
    size_t n;
    for (; i < json.length && json[i] != '"'; ++i)
    {
        char c = json[i];
        if (c == '\\')
        {
            if (++i >= json.length || !(json[i] == '\\' || json[i] == '/' || json[i] == '"'))
                return false;
            c = json[i];
        }
        if (n == value.length)
            return false;
        value[n++] = c;
    }
    return i < json.length && n > 0 && tryToCString(dest, [value[0 .. n]]);
}

private bool resolveLibrary(scope const(char)[] libraryPath, scope const(char)[] manifestDir,
    out CString!pathMax dest) @system nothrow @nogc
{
    if (libraryPath[0] == '/')
        return tryToCString(dest, [libraryPath]);
    foreach (c; libraryPath)
        if (c == '/')
            return tryToCString(dest, [manifestDir, "/", libraryPath]);
    foreach (dir; driverLibDirs)
        if (exists(dir, libraryPath))
            return tryToCString(dest, [dir, "/", libraryPath]);
    return false;
}

/// The first of `library`'s run path, its own directory and the system's
/// library directories that holds `libc.so.6` and glibc's dynamic linker.
private bool libcDirOf(scope const(char)[] library, out CString!pathMax dest) @system nothrow @nogc
{
    const origin = dirOf(library);
    CString!pathMax runpath;
    if (elfRunPath(library, runpath))
        foreach (entry; PathList(runpath[]))
        {
            CString!pathMax dir;
            const(char)[] rest = entry;
            const expanded = rest.tryConsume("${ORIGIN}") || rest.tryConsume("$ORIGIN")
                ? tryToCString(dir, [origin, rest]) : tryToCString(dir, [entry]);
            if (expanded && isLibcDir(dir[]))
                return tryToCString(dest, [dir[]]);
        }
    if (isLibcDir(origin))
        return tryToCString(dest, [origin]);
    foreach (dir; systemLibDirs)
        if (isLibcDir(dir))
            return tryToCString(dest, [dir]);
    return false;
}

private bool isLibcDir(scope const(char)[] dir) @system nothrow @nogc
    => exists(dir, "libc.so.6") && exists(dir, dynamicLinker);

/// A read-only private mapping of a whole file, unmapped on destruction.
private struct Mapping
{
    const(ubyte)[] bytes;

    @disable this(this);

    this(scope const(char)[] path) @system nothrow @nogc
    {
        import core.sys.posix.fcntl : O_CLOEXEC, O_RDONLY, open;
        import core.sys.posix.sys.mman : MAP_FAILED, MAP_PRIVATE, mmap, PROT_READ;
        import core.sys.posix.sys.stat : fstat, stat_t;
        import core.sys.posix.unistd : close;

        CString!pathMax z;
        if (!tryToCString(z, [path]))
            return;
        const fd = open(z.ptr, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            return;
        scope (exit)
            close(fd);
        stat_t st;
        if (fstat(fd, &st) != 0 || st.st_size <= 0)
            return;
        auto p = mmap(null, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (p != MAP_FAILED)
            bytes = (cast(const(ubyte)*) p)[0 .. st.st_size];
    }

    ~this() @system nothrow @nogc
    {
        import core.sys.posix.sys.mman : munmap;

        if (bytes.length)
            munmap(cast(void*) bytes.ptr, bytes.length);
    }
}

/// The `DT_RUNPATH` of a little-endian ELF64 object, else its `DT_RPATH`;
/// `false` when it has neither or is not one.
private bool elfRunPath(scope const(char)[] path, out CString!pathMax dest) @system nothrow @nogc
{
    enum uint shtDynamic = 6;
    enum long dtNull = 0, dtRpath = 15, dtRunpath = 29;

    auto file = Mapping(path);
    const b = file.bytes;
    T at(T)(ulong off) => off + T.sizeof <= b.length ? *cast(const(T)*) (b.ptr + off) : T.init;
    const(char)[] stringAt(ulong off)
    {
        if (off >= b.length)
            return null;
        auto end = off;
        while (end < b.length && b[end])
            ++end;
        return cast(const(char)[]) b[off .. end];
    }

    static immutable ubyte[4] elfMagic = [0x7f, 'E', 'L', 'F'];
    if (b.length < 64 || b[0 .. 4] != elfMagic[] || b[4] != 2 || b[5] != 1)
        return false;
    const shoff = at!ulong(0x28), shentsize = at!ushort(0x3A), shnum = at!ushort(0x3C);
    foreach (i; 0 .. shnum)
    {
        const sh = shoff + i * shentsize;
        if (at!uint(sh + 4) != shtDynamic)
            continue;
        const strtab = at!ulong(shoff + at!uint(sh + 0x28) * shentsize + 0x18);
        const off = at!ulong(sh + 0x18), end = off + at!ulong(sh + 0x20);
        const(char)[] runpath, rpath;
        for (ulong e = off; e + 16 <= end; e += 16)
        {
            const tag = at!long(e);
            if (tag == dtNull)
                break;
            if (tag == dtRunpath)
                runpath = stringAt(strtab + at!ulong(e + 8));
            else if (tag == dtRpath)
                rpath = stringAt(strtab + at!ulong(e + 8));
        }
        const chosen = runpath.length ? runpath : rpath;
        return chosen.length && tryToCString(dest, [chosen]);
    }
    return false;
}

/// The release in the banner of `dir`'s `libc.so.6` (`… release version 2.44.`).
private GlibcRelease glibcReleaseIn(scope const(char)[] dir) @system nothrow @nogc
{
    enum marker = "release version ";
    CString!pathMax libc;
    if (!tryToCString(libc, [dir, "/libc.so.6"]))
        return GlibcRelease.init;
    import core.sys.linux.string : memmem;

    auto file = Mapping(libc[]);
    const text = cast(const(char)[]) file.bytes;
    // glibc's own `memmem`: a byte loop over the 2 MiB file cost most of a
    // program's start-up scan.
    const at = cast(const(char)*) memmem(text.ptr, text.length, marker.ptr, marker.length);
    return at ? GlibcRelease.parse(text[at - text.ptr + marker.length .. $]) : GlibcRelease.init;
}

@("driver_libc.jsonStringValue")
@safe nothrow @nogc
unittest
{
    CString!pathMax v;
    assert(jsonStringValue(`{"ICD": {"library_path" : "\/nix\/store\/x\/libvulkan_radeon.so"}}`,
        `"library_path"`, v));
    assert(v[] == "/nix/store/x/libvulkan_radeon.so");
    assert(!jsonStringValue(`{"ICD": {"api_version": "1.4"}}`, `"library_path"`, v));
    // A `\u` escape is rejected rather than misread; no driver path needs one.
    assert(!jsonStringValue("{\"library_path\": \"a\\u0041\"}", `"library_path"`, v));
}

@("driver_libc.dirOfAndPathList")
@safe nothrow @nogc
unittest
{
    assert(dirOf("/etc/vulkan/icd.d/x.json") == "/etc/vulkan/icd.d");
    assert(dirOf("/x.json") == "/");
    assert(dirOf("x.json") == ".");
    size_t n;
    foreach (e; PathList("::/a::/b:"))
        assert(e == (n++ ? "/b" : "/a"));
    assert(n == 2);
}

@("driver_libc.glibcReleaseIn.matchesTheRunningLibc")
@system nothrow @nogc
unittest
{
    import sparkles.test_runner.skip : skipTest;

    // The test binary's run path (or the system) leads to the glibc it runs
    // on, and that glibc's banner names the release it reports.
    CString!pathMax self, dir;
    assert(readSelfExe(self));
    if (!libcDirOf(self[], dir))
        skipTest("no glibc directory on the test binary's run path or the system's");
    assert(glibcReleaseIn(dir[]) == runningGlibc());
}

@("driver_libc.forEachDriverLibc.listedManifest")
@serial // sets the loaders' environment variables
@system nothrow @nogc
unittest
{
    import core.sys.posix.stdlib : setenv, unsetenv;
    import sparkles.test_runner.skip : skipTest;

    // A manifest naming the test binary itself as its "driver": the scan
    // resolves it and finds the glibc the binary runs on.
    import core.stdc.stdio : fclose, fopen, fputs;
    import core.sys.posix.unistd : getpid, unlink;

    CString!pathMax self, dir;
    assert(readSelfExe(self));
    if (!libcDirOf(self[], dir))
        skipTest("no glibc directory on the test binary's run path or the system's");
    char[64] name = void;
    import core.stdc.stdio : snprintf;
    snprintf(name.ptr, name.length, "/tmp/driver-libc-test-%d.json", getpid());
    auto f = fopen(name.ptr, "w");
    assert(f);
    fputs(`{"ICD": {"library_path": "`, f);
    fputs(self.ptr, f);
    fputs(`"}}`, f);
    fclose(f);
    scope (exit)
        unlink(name.ptr);

    setenv("VK_DRIVER_FILES", name.ptr, 1);
    setenv("__EGL_VENDOR_LIBRARY_FILENAMES", "/nonexistent.json", 1);
    scope (exit)
    {
        unsetenv("VK_DRIVER_FILES");
        unsetenv("__EGL_VENDOR_LIBRARY_FILENAMES");
    }
    size_t visits;
    GlibcRelease found;
    bool sameLibrary;
    forEachDriverLibc((in DriverLibc d) {
        ++visits;
        if (d.api == DriverApi.vulkan)
        {
            found = d.release;
            sameLibrary = d.library == self[];
        }
    });
    assert(visits == 2); // the Vulkan manifest, and the missing EGL one
    assert(sameLibrary);
    assert(found == runningGlibc());
}

@("driver_libc.thisProgramPath.isThisProgram")
@system
unittest
{
    import std.file : thisExePath;

    // Not re-executed, so the path is the program's own.
    assert(reexecutedExecutable() is null);
    assert(thisProgramPath() == thisExePath);
}

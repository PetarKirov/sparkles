#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-exec-route"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Model of the exec routes open to an app that targets API >= 29, where the
 * kernel refuses execve() of files in the app's writable data directory.
 * Evidence for ../index.md#how-it-works and ../index.md#extent-of-the-workaround.
 *
 * `rewrite` mirrors termux-exec's decision (termux-play-store/termux-exec
 * 47633d5df2db3dfea34cef568c6c82a7ba8dcc2e, src/termux-exec.c `execve`): an
 * ELF or shebang target under the app's data directory becomes
 * `/system/bin/linker64 <target> …`. `route` adds what the rewrite cannot
 * express: Bionic's linker loads only Bionic-dynamic ELFs, so static and
 * glibc executables need a loader shipped as an APK native library (the Play
 * build's `libproot-loader.so`).
 *
 * The cases are synthetic headers, so the output is the same on every host.
 * Pass a file path to classify a real ELF or script instead.
 */
module exec_route;

import std.algorithm : canFind, startsWith;
import std.array : join;
import std.file : read;
import std.stdio : writefln, writeln;
import std.string : indexOf, strip;

enum dataDir = "/data/data/com.termux/files";
enum prefix = dataDir ~ "/usr";
enum nativeLibDir = "/data/app/~~x/com.termux-y/lib/arm64";
enum linker = "/system/bin/linker64";

enum Kind { bionicDynamic, glibcDynamic, staticElf, shebang, other }

struct Header
{
    Kind kind;
    string interpreter; /// PT_INTERP, or the shebang interpreter
    string interpreterArg; /// the optional single shebang argument
}

Header inspect(const(ubyte)[] bytes)
{
    if (bytes.length >= 64 && bytes[0 .. 4] == [0x7f, 'E', 'L', 'F'])
    {
        const interp = ptInterp(bytes);
        if (interp is null)
            return Header(Kind.staticElf);
        return Header(interp.startsWith("/system/bin/linker") ? Kind.bionicDynamic : Kind.glibcDynamic, interp);
    }
    if (bytes.length > 2 && bytes[0 .. 2] == "#!")
    {
        auto line = cast(const(char)[]) bytes[2 .. $];
        const nl = line.indexOf('\n');
        if (nl < 0)
            return Header(Kind.other);
        line = line[0 .. nl].strip;
        const space = line.indexOf(' ');
        if (space < 0)
            return Header(Kind.shebang, line.idup);
        return Header(Kind.shebang, line[0 .. space].idup, line[space + 1 .. $].strip.idup);
    }
    return Header(Kind.other);
}

/// The PT_INTERP of a 64-bit little-endian ELF, or null when there is none.
string ptInterp(const(ubyte)[] b)
{
    ulong at(size_t off, size_t n)
    {
        ulong v;
        foreach (i; 0 .. n)
            v |= cast(ulong) b[off + i] << (8 * i);
        return v;
    }

    const table = cast(size_t) at(32, 8);
    const stride = cast(size_t) at(54, 2);
    foreach (i; 0 .. at(56, 2))
    {
        const entry = table + cast(size_t) i * stride;
        if (entry + 56 > b.length || at(entry, 4) != 3) // PT_INTERP
            continue;
        const off = cast(size_t) at(entry + 8, 8);
        const len = cast(size_t) at(entry + 32, 8);
        return cast(string) b[off .. off + len - 1].idup;
    }
    return null;
}

/// termux-exec's `/bin/x` and `/usr/bin/x` → `$PREFIX/bin/x` shebang rewrite.
string rewriteBin(string path)
{
    foreach (head; ["/bin/", "/usr/bin/"])
        if (path.startsWith(head))
            return prefix ~ "/bin/" ~ path[head.length .. $];
    return path;
}

/// The execve() termux-exec issues for `path` with `argv`.
string[] rewrite(string path, Header h, string[] argv)
{
    const target = h.kind == Kind.shebang ? rewriteBin(h.interpreter) : path;
    if (!target.startsWith(dataDir))
        return [target] ~ argv; // outside the data dir: exec as-is, LD_PRELOAD stripped
    string[] result = [linker, argv[0], target];
    if (h.kind == Kind.shebang)
        result ~= (h.interpreterArg.length ? [h.interpreterArg] : []) ~ path;
    return result ~ argv[1 .. $];
}

/// What actually runs once the kernel executes the rewritten command.
string route(string path, Header h)
{
    if (path.startsWith(nativeLibDir))
        return "direct execve: APK native library (apk_data_file), allowed";
    if (!path.startsWith(dataDir) && h.kind != Kind.shebang)
        return "direct execve: system file, allowed";
    final switch (h.kind)
    {
    case Kind.bionicDynamic:
        return "linker64 maps it with mmap(PROT_EXEC): works";
    case Kind.shebang:
        return "linker64 runs the rewritten interpreter: works if it is Bionic-dynamic";
    case Kind.staticElf:
        return "linker64 cannot load it: needs a loader in the APK (PRoot) or nativeLibraryDir";
    case Kind.glibcDynamic:
        return "linker64 cannot link glibc: needs PRoot's APK loader to map " ~ h.interpreter;
    case Kind.other:
        return "ENOEXEC";
    }
}

/// A minimal 64-bit AArch64 ELF header, with a PT_INTERP when `interp` is set.
ubyte[] elf(string interp)
{
    auto b = new ubyte[](64 + 56 + interp.length + 1);
    b[0 .. 4] = [0x7f, 'E', 'L', 'F'];
    b[4] = 2; // ELFCLASS64
    b[5] = 1; // little-endian
    b[16] = interp.length ? 3 : 2; // ET_DYN : ET_EXEC
    b[18] = 183; // EM_AARCH64
    b[32] = 64; // e_phoff
    b[54] = 56; // e_phentsize
    b[56] = interp.length ? 1 : 0; // e_phnum
    if (interp.length)
    {
        b[64] = 3; // PT_INTERP
        b[72] = 120; // p_offset
        b[96] = cast(ubyte)(interp.length + 1); // p_filesz
        b[120 .. 120 + interp.length] = cast(const(ubyte)[]) interp;
    }
    return b;
}

void show(string path, const(ubyte)[] bytes, string[] argv)
{
    const h = inspect(bytes);
    writefln("%s (%s)", path, h.kind);
    writefln("  execve: %s", rewrite(path, h, argv).join(" "));
    writefln("  result: %s", route(path, h));
}

void main(string[] args)
{
    if (args.length > 1)
        return show(args[1], cast(ubyte[]) read(args[1]), [args[1]]);

    const glibcLd = "/nix/store/00000000000000000000000000000000-glibc-2.40/lib/ld-linux-aarch64.so.1";
    show(prefix ~ "/bin/ls", elf(linker), ["ls", "-l"]);
    show(dataDir ~ "/home/hello.py", cast(const(ubyte)[]) "#!/usr/bin/env python3\n", ["./hello.py"]);
    show("/system/bin/toybox", elf(linker), ["toybox", "uname"]);
    show(dataDir ~ "/home/zig-out/bin/app", elf(""), ["app"]);
    show(dataDir ~ "/nix/store/0-hello/bin/hello", elf(glibcLd), ["hello"]);
    show(nativeLibDir ~ "/libproot-loader.so", elf(""), ["loader"]);

    // The rewrite is self-consistent: the kernel only ever sees linker64 for
    // data-dir targets, and the target path survives as linker64's argv[1].
    const ls = rewrite(prefix ~ "/bin/ls", inspect(elf(linker)), ["ls"]);
    assert(ls == [linker, "ls", prefix ~ "/bin/ls"]);
    // termux-exec does not inspect PT_INTERP: a static target is still handed
    // to linker64, which is why static binaries fail rather than run directly.
    const zig = rewrite(dataDir ~ "/x", inspect(elf("")), ["x"]);
    assert(zig[0] == linker && zig.canFind(dataDir ~ "/x"));
    writeln("Only the APK's native-library directory is directly executable from the app.");
}

/**
The C preprocessor pass for ImportC modules (spec `COR7`).

DMD reads a `.c`/`.h` module through `global.preprocess`, a function pointer
its own driver assigns and `initDMD` leaves null. Left null, `dmodule.d` hands
the unexpanded text straight to the ImportC parser, which rejects the first
`#include` and then reports every declaration behind that header as undefined
— for a binding like `sparkles:vulkan`, several hundred of them, every one
reading as a defect in the user's code.

The frontend ships an implementation (`dmd.cpreprocess.preprocess`) and we
cannot use it: it delegates to `dmd.link.runPreprocessor`, and `dmd.link` is
one of the modules the `dmd:frontend` package excludes, so linking it in
fails on an undefined reference. The child-process invocation it would build
is small — this module rebuilds exactly it, with two deliberate differences:

$(LIST
    * $(B No `fatal()`.) The frontend's version exits the process when the
        preprocessor is missing or fails. Under a collecting diagnostic sink
        that is a silent `exit(1)`. Here a failure is a diagnostic, and the
        raw file text is handed back so the analysis continues degraded
        rather than dying.
    * $(B No `importc.h` search failure.) `sparkles.dmd_lsp.init_` checks for
        it before installing the hook at all.
)
*/
module sparkles.dmd_lsp.cpreprocess;

import dmd.astenums : DArray;
import dmd.common.outbuffer : OutBuffer;
import dmd.location : Loc;
import dmd.root.filename : FileName;

/**
The `global.preprocess` hook: preprocesses `csrcfile` and returns its text.

`defines` is untouched, matching the frontend's own POSIX path — `-dD` keeps
the `#define` lines inline in the output, and the separate buffer exists only
for the MSVC branch, which cannot.
*/
extern (C++) DArray!ubyte preprocessCFile(FileName csrcfile, Loc loc,
    ref OutBuffer defines) @system
{
    import std.process : Config, execute;

    import dmd.errors : error;
    import dmd.globals : global;

    const path = csrcfile.toString().idup;

    try
    {
        const res = execute(preprocessorArgv(path), null, Config.stderrPassThrough);
        if (res.status == 0)
            return terminated(cast(const(ubyte)[]) res.output);

        error(loc, "C preprocess command `%.*s` failed for file `%.*s`, exit status %d",
            cast(int) commandName.length, commandName.ptr,
            cast(int) path.length, path.ptr, res.status);
    }
    catch (Exception e)
        error(loc, "cannot run the C preprocessor for file `%.*s`: %.*s",
            cast(int) path.length, path.ptr,
            cast(int) e.msg.length, e.msg.ptr);

    // Degrade to the unexpanded text: the ImportC parser will complain about
    // the directives it cannot handle, which is strictly more information
    // than an empty module (and exactly the behaviour before the hook).
    return terminated(global.fileManager.getFileContents(csrcfile));
}

/**
The child command line, byte-for-byte the one `dmd.link.runPreprocessor`
builds for this platform.

`-dD` keeps macro definitions in the output (ImportC turns them into manifest
constants), and `-Wno-builtin-macro-redefined` is needed because `importc.h`
redefines several builtins.
*/
private string[] preprocessorArgv(string path) @system
{
    import dmd.globals : global;
    import dmd.target : target;
    import std.string : fromStringz;

    auto argv = [commandName, "-std=c11"];
    foreach (sw; global.params.cppswitches)
        if (sw && *sw)
            argv ~= (() @trusted => sw.fromStringz.idup)();
    argv ~= target.isX86_64 ? "-m64" : "-m32";
    argv ~= ["-dD", "-Wno-builtin-macro-redefined"];

    // Order matters, and differs: Apple's clang is switch-order dependent, and
    // needs `-E` because it is the compiler driver rather than `cpp`.
    version (OSX)
        return argv ~ ["-fno-blocks", "-E", "-include", importcHeader, path];
    else
        return argv ~ [path, "-include", importcHeader];
}

/// The preprocessed text plus the terminating NUL the lexer expects past the
/// end of the slice (the frontend's `extractSlice(nullTerminate: true)`).
private DArray!ubyte terminated(scope const(ubyte)[] text) @safe pure nothrow
{
    auto buffer = new ubyte[](text.length + 1);
    buffer[0 .. text.length] = text;
    buffer[text.length] = 0;
    return DArray!ubyte(buffer[0 .. text.length]);
}

/**
The command and header `sparkles.dmd_lsp.init_` probed for and committed to.

They are set once, before the hook is installed, rather than re-derived per
file: the probe is what decides the hook is safe to install at all, so the two
must not be able to disagree.
*/
package(sparkles.dmd_lsp) void setPreprocessor(string command, string importcH) @system
in (command.length && importcH.length)
{
    commandName = command;
    importcHeader = importcH;
}

// __gshared, not TLS: the frontend may run the analysis on a thread other than
// the one that initialized it (`dmdGlobalsLock` is what keeps that safe).
private __gshared string commandName;
private __gshared string importcHeader;

// No unittest here reaches `Analyzer`: `init_` imports this module, so an
// `api`/`testing` import would close the `init_` → `cpreprocess` → `api` →
// `init_` module-constructor cycle the runtime rejects at startup (the same
// cycle `dmdGlobalsLock`'s placement avoids). The end-to-end test lives in
// `sparkles.dmd_lsp.testing`.

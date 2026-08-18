/**
The platform Vulkan loader, as a function pointer.

The binding never links a `vk*` symbol (`VK_NO_PROTOTYPES` in
$(MREF sparkles,vulkan,c)). A caller that is not going through SDL therefore
has to find `vkGetInstanceProcAddr` itself. This module is that lookup:
already-loaded images first (so a binary that linked `libvulkan` does not have
to guess the soname), then the platform's library names — including MoltenVK on
Darwin, which is the ICD the Khronos loader dispatches to.
*/
module sparkles.vulkan.loader;

import std.array : join;

import expected : Expected, err, ok;

import sparkles.vulkan.vulkan_c;

/**
Library names tried, in order, after the already-loaded-image search.

On Darwin the Khronos loader (`libvulkan.1.dylib`) is preferred; MoltenVK is
the fallback for hosts that ship the ICD without the loader.

Each entry carries its own terminating NUL, so `entry.ptr` is a valid C string
with no copy and no `toStringz`. Leaning on a string literal's implicit
terminator would work today and break silently the first time a name is
computed rather than written out, so the NUL is part of the data instead.
$(LREF loaderLibraryNames) is the same list without it.
*/
private immutable string[] loaderLibraryNamesZ = () {
    version (Windows)
        return ["vulkan-1.dll\0"];
    else version (OSX)
        return ["libvulkan.1.dylib\0", "libvulkan.dylib\0", "libMoltenVK.dylib\0"];
    else
        return ["libvulkan.so.1\0", "libvulkan.so\0"];
}();

static foreach (name; loaderLibraryNamesZ)
    static assert(name.length > 1 && name[$ - 1] == '\0',
        "`" ~ name ~ "` must carry its terminating NUL; `.ptr` is passed to the loader");

/// The names tried, without their terminators — for diagnostics and tests.
immutable string[] loaderLibraryNames = () {
    string[] r;
    foreach (name; loaderLibraryNamesZ)
        r ~= name[0 .. $ - 1];
    return r;
}();

/// Comma-separated $(LREF loaderLibraryNames), for the error that lists what was tried.
private enum loaderNamesForError = loaderLibraryNames.join(", ");

/**
Resolve `vkGetInstanceProcAddr` from the platform loader.

Looks in the process's already-loaded images first — on Darwin `libs "vulkan"`
records an absolute `LC_LOAD_DYLIB` to `libvulkan.1.dylib`, so the symbol is
already resident and a bare `dlopen("libvulkan.1.dylib")` would miss it (nix
does not put the store path on `DYLD_LIBRARY_PATH`). Then each name in
$(LREF loaderLibraryNames).

A successfully opened loader is deliberately never closed: its lifetime is the
process's, and every `PFN_vk*` in $(MREF sparkles,vulkan,dispatch) points into
it. Only the images that failed to yield the symbol are released.
*/
Expected!(PFN_vkGetInstanceProcAddr, string) loadGetInstanceProcAddr() @system nothrow
{
    version (Windows)
    {
        import core.sys.windows.winbase : FreeLibrary, GetModuleHandleA,
            GetProcAddress, LoadLibraryA;

        foreach (i, name; loaderLibraryNamesZ)
        {
            // Already mapped — the counterpart of the `dlopen(null)` probe
            // below. `GetModuleHandleA` does not take a reference, so the
            // handle must not be freed.
            if (auto resident = lookup(GetModuleHandleA(name.ptr)))
                return ok(resident);

            auto lib = LoadLibraryA(name.ptr);
            if (lib is null)
                continue;
            if (auto getProc = lookup(lib))
                return ok(getProc);
            FreeLibrary(lib);
        }
    }
    else version (Posix)
    {
        import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_NOW;

        // The global symbol table: finds a loader this binary already links,
        // whatever path it was linked from.
        if (auto resident = lookup(dlopen(null, RTLD_NOW)))
            return ok(resident);

        foreach (name; loaderLibraryNamesZ)
        {
            auto lib = dlopen(name.ptr, RTLD_NOW);
            if (lib is null)
                continue;
            if (auto getProc = lookup(lib))
                return ok(getProc);
            dlclose(lib);
        }
    }
    else
        static assert(0, "no Vulkan loader lookup on this platform");

    return err!(PFN_vkGetInstanceProcAddr)(
        "Unable to load the Vulkan loader (tried the linked image, then "
            ~ loaderNamesForError ~ ")");
}

/// `vkGetInstanceProcAddr` out of an open image, or `null` if it is not there.
private PFN_vkGetInstanceProcAddr lookup(Handle)(Handle lib) @system nothrow @nogc
{
    version (Windows)
        import core.sys.windows.winbase : symbol = GetProcAddress;
    else
        import core.sys.posix.dlfcn : symbol = dlsym;

    if (lib is null)
        return null;
    return cast(PFN_vkGetInstanceProcAddr) symbol(lib, "vkGetInstanceProcAddr");
}

@("vulkan.loader.namesAreTerminatedAndPlatformShaped")
@safe pure nothrow unittest
{
    // The public list is derived from the terminated one rather than written
    // twice, so the two cannot drift; the NUL itself is a `static assert`
    // above, where a bad entry is a compile error rather than a test failure.
    assert(loaderLibraryNames.length == loaderLibraryNamesZ.length);
    foreach (i, name; loaderLibraryNames)
        assert(name == loaderLibraryNamesZ[i][0 .. $ - 1]);

    // What a hand-written literal actually gets wrong: an soname pasted into
    // the wrong platform's branch. Every name must be loadable *here*.
    version (Windows)
        enum suffix = ".dll";
    else version (OSX)
        enum suffix = ".dylib";
    else
        enum suffix = ".so";

    assert(loaderLibraryNames.length >= 1);
    foreach (name; loaderLibraryNames)
    {
        version (Posix)
        {
            // `libvulkan.so.1` carries its ABI version after the suffix.
            import std.algorithm : canFind;
            assert(name.canFind(suffix), name ~ " is not a " ~ suffix ~ " name");
        }
        else
            assert(name.length > suffix.length && name[$ - suffix.length .. $] == suffix);
    }
}

// Needs the platform loader on the link line (`libs "vulkan"`). An ICD is not
// required — this only resolves `vkGetInstanceProcAddr` — so a machine with no
// GPU driver still runs it, but one with no loader at all is a degraded
// environment rather than a failure.
@("vulkan.loader.resolvesGetInstanceProcAddrWhenLoaderIsLinked")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    auto loaded = loadGetInstanceProcAddr();
    if (loaded.hasError)
        skipTest(loaded.error);

    assert(loaded.value !is null);

    // Idempotent: a second call must find the same entry point rather than
    // depend on which image happened to be opened first.
    auto again = loadGetInstanceProcAddr();
    assert(again.hasValue && again.value is loaded.value);
}

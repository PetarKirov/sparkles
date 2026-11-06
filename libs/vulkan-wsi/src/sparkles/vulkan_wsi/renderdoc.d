/**
RenderDoc's in-application API, where RenderDoc's layer is in the process:
a capture of the next frame on request (`PRF12`), so a scripted run captures
without the capture key or a connected UI.

Nothing is loaded: the API is found only if RenderDoc injected its library
(`renderdoccmd capture`, or the layer enabled by `ENABLE_VULKAN_RENDERDOC_CAPTURE`).
*/
module sparkles.vulkan_wsi.renderdoc;

/// RenderDoc's API, if its library is in the process.
struct RenderDoc
{
    private const(Api)* api;

    /// Finds the API; `false` without RenderDoc.
    bool find() @trusted nothrow @nogc
    {
        version (Posix)
        {
            import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOLOAD, RTLD_NOW;

            version (Android)
                enum name = "libVkLayer_GLES_RenderDoc.so";
            else
                enum name = "librenderdoc.so";
            auto lib = dlopen(name, RTLD_NOW | RTLD_NOLOAD);
            if (lib is null)
                return false;
            auto get = cast(GetApi) dlsym(lib, "RENDERDOC_GetAPI");
            const(Api)* found;
            if (get is null || get(apiVersion, cast(void**) &found) != 1 || found is null)
                return false;
            api = found;
            return true;
        }
        else
            return false;
    }

    /// Whether the API was found.
    bool present() const @safe pure nothrow @nogc => api !is null;

    /// Captures the next frame presented.
    void triggerCapture() @trusted nothrow @nogc
    {
        if (api !is null)
            api.triggerCapture();
    }

    /// How many captures this process has made.
    uint captures() @trusted nothrow @nogc
        => api !is null ? api.getNumCaptures() : 0;
}

private:

// `eRENDERDOC_API_Version_1_1_2`: the oldest version with every entry used
// here; later versions extend the table at its end.
enum int apiVersion = 1_01_02;

alias GetApi = extern (C) int function(int version_, void** api) nothrow @nogc;

// The leading entries of `RENDERDOC_API_1_1_2` (renderdoc_app.h), in order.
struct Api
{
    extern (C) nothrow @nogc:
    void function(int*, int*, int*) getAPIVersion;
    void* setCaptureOptionU32, setCaptureOptionF32, getCaptureOptionU32, getCaptureOptionF32;
    void* setFocusToggleKeys, setCaptureKeys, getOverlayBits, maskOverlayBits;
    void* removeHooks, unloadCrashHandler;
    void* setCaptureFilePathTemplate, getCaptureFilePathTemplate;
    uint function() getNumCaptures;
    void* getCapture;
    void function() triggerCapture;
}

static assert(Api.triggerCapture.offsetof == 15 * (void*).sizeof, "renderdoc_app.h's layout");

@("vulkan_wsi.renderdoc.absentWithoutTheLayer")
@safe nothrow @nogc unittest
{
    RenderDoc rd;
    if (rd.find()) // under `renderdoccmd capture`, the API is there
        return assert(rd.present);
    assert(!rd.present && rd.captures == 0);
    rd.triggerCapture(); // does nothing
}

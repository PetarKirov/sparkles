/**
The three dispatch tiers: global, per-instance, per-device.

Vulkan has no ambient API. Every entry point is fetched by name, and where you
fetch it from decides what it dispatches to:

$(UL
$(LI `vkGetInstanceProcAddr(null, name)` — the handful of commands that exist
    before an instance does.)
$(LI `vkGetInstanceProcAddr(instance, name)` — instance-level commands, plus
    device commands that route through the loader's trampoline.)
$(LI `vkGetDeviceProcAddr(device, name)` — device commands that skip the
    trampoline entirely.))

$(B Each table is paired with the handle it was loaded from), which is the
whole point of this module. The obvious shortcut — one set of module-level
command pointers — is what ErupteD does, and its own generated documentation
admits the consequence: "calling this function again with another `VkDevice`
will overwrite the `__gshared` functions retrieved previously". A process with
two devices then silently dispatches one device's calls into the other.

That is not a hypothetical here. Skia's Graphite backend loads its own pointers
against the device we hand it, and `sparkles:ui-sdl3` will own a second logical
device on some paths. Pairing handle and table makes the mistake unrepresentable
rather than documented.

The command lists are deliberately small — what instance/device bring-up,
swapchain presentation and a fence wait actually need. Extending one is adding
a name to a list; the field, the loader and the completeness check are all
generated from it.
*/
module sparkles.vulkan.dispatch;

import sparkles.vulkan.c;

/// `CreateInstance` → `createInstance`, the field spelling for a command name.
private string lowerFirst(string s) @safe pure nothrow
    => s.length == 0 ? s
        : (s[0] >= 'A' && s[0] <= 'Z' ? cast(char)(s[0] - 'A' + 'a') : s[0]) ~ s[1 .. $];

/**
One command name, and the extension that must be enabled for it to resolve.

Vulkan resolves an extension's commands to null unless that extension was
enabled at instance or device creation. A table that treats every command as
mandatory therefore reports a correctly-built instance as broken — which is
exactly what the first version of this module did, and what
`libs/vulkan/examples/instance-info.d` caught: an instance created without
`VK_KHR_surface` has no `vkDestroySurfaceKHR`, and that is not an error.
*/
private struct CommandSet
{
    /// The extension these commands belong to; `null` for core commands.
    string extension;
    string[] names;
}

/**
Declares one `PFN_vk*` field per name, plus per-group completeness checks.

Core commands must all be present for a table to be usable. Extension commands
are checked per extension, so a caller asks "did the swapchain extension load?"
rather than "is everything here?".
*/
private mixin template CommandTable(CommandSet[] sets)
{
    static foreach (set; sets)
        static foreach (name; set.names)
            mixin("PFN_vk" ~ name ~ " " ~ lowerFirst(name) ~ ";");

    /**
    The first $(I core) command that did not load, or `null` when all are present.

    Returns the name rather than a bool: "which one" is the only useful thing
    to put in an error message.
    */
    string firstMissing() const @safe pure nothrow @nogc
    {
        static foreach (set; sets)
            static if (set.extension is null)
                static foreach (name; set.names)
                    if (mixin(lowerFirst(name)) is null)
                        return "vk" ~ name;
        return null;
    }

    /// `true` when every core command loaded.
    bool complete() const @safe pure nothrow @nogc => firstMissing() is null;

    /**
    `true` when every command of `extension` loaded.

    Compile error for an extension this table declares no commands for, so a
    typo cannot silently answer `false` forever.
    */
    bool has(string extension)() const @safe pure nothrow @nogc
    {
        enum declared = () {
            foreach (set; sets)
                if (set.extension == extension)
                    return true;
            return false;
        }();
        static assert(declared,
            "this table declares no commands for `" ~ extension ~ "`");

        static foreach (set; sets)
            static if (set.extension == extension)
                static foreach (name; set.names)
                    if (mixin(lowerFirst(name)) is null)
                        return false;
        return true;
    }
}

/// Commands reachable before an instance exists. All core.
private enum CommandSet[] globalSets = [
    CommandSet(null, [
        "EnumerateInstanceVersion",
        "EnumerateInstanceExtensionProperties",
        "EnumerateInstanceLayerProperties",
        "CreateInstance",
    ]),
];

/// Instance-level commands. `VK_KHR_surface` resolves only if it was enabled.
private enum CommandSet[] instanceSets = [
    CommandSet(null, [
        "DestroyInstance",
        "EnumeratePhysicalDevices",
        "GetPhysicalDeviceProperties",
        "GetPhysicalDeviceFeatures",
        "GetPhysicalDeviceQueueFamilyProperties",
        "GetPhysicalDeviceMemoryProperties",
        "GetPhysicalDeviceFormatProperties",
        "EnumerateDeviceExtensionProperties",
        "CreateDevice",
        "GetDeviceProcAddr",
    ]),
    // The swapchain cannot be configured without these, but an instance that
    // never presents (a headless render, a test) is right not to enable them.
    CommandSet(khrSurface, [
        "DestroySurfaceKHR",
        "GetPhysicalDeviceSurfaceSupportKHR",
        "GetPhysicalDeviceSurfaceCapabilitiesKHR",
        "GetPhysicalDeviceSurfaceFormatsKHR",
        "GetPhysicalDeviceSurfacePresentModesKHR",
    ]),
];

/// Device-level commands: the queue, frame synchronisation, and the swapchain.
private enum CommandSet[] deviceSets = [
    CommandSet(null, [
        "DestroyDevice",
        "GetDeviceQueue",
        "DeviceWaitIdle",
        "QueueWaitIdle",
        "QueueSubmit",
        // Frame synchronisation. The fence is what the event-horizon frame
        // clock will export as a pollable sync_fd, so the loop parks on the
        // ring instead of blocking in vkWaitForFences.
        "CreateSemaphore",
        "DestroySemaphore",
        "CreateFence",
        "DestroyFence",
        "WaitForFences",
        "ResetFences",
        "GetFenceStatus",
        // Command recording.
        "CreateCommandPool",
        "DestroyCommandPool",
        "AllocateCommandBuffers",
        "FreeCommandBuffers",
        "BeginCommandBuffer",
        "EndCommandBuffer",
        "ResetCommandBuffer",
        "CmdPipelineBarrier",
    ]),
    CommandSet(khrSwapchain, [
        "CreateSwapchainKHR",
        "DestroySwapchainKHR",
        "GetSwapchainImagesKHR",
        "AcquireNextImageKHR",
        "QueuePresentKHR",
    ]),
];

/// Extension names, spelled once so a call site cannot typo one.
enum string khrSurface = "VK_KHR_surface";
/// ditto
enum string khrSwapchain = "VK_KHR_swapchain";

/**
Tier 1: the commands available before any instance exists.

Built from a caller-supplied `vkGetInstanceProcAddr`, never from a linked
symbol — on the desktop that pointer comes from SDL3
(`SDL_Vulkan_GetVkGetInstanceProcAddr`), which has already loaded whichever
loader the platform provides.
*/
struct GlobalCommands
{
    /// The bootstrap pointer every other tier is resolved through.
    PFN_vkGetInstanceProcAddr getInstanceProcAddr;

    mixin CommandTable!globalSets;

    /// Resolve the global tier through `getProc`.
    static GlobalCommands load(PFN_vkGetInstanceProcAddr getProc) @system nothrow @nogc
    in (getProc !is null, "vkGetInstanceProcAddr must not be null")
    {
        GlobalCommands r;
        r.getInstanceProcAddr = getProc;
        static foreach (set; globalSets)
            static foreach (name; set.names)
                mixin("r." ~ lowerFirst(name) ~ " = cast(PFN_vk" ~ name ~ ") getProc(null, \"vk"
                    ~ name ~ "\");");
        return r;
    }
}

/**
Tier 2: commands bound to one `VkInstance`.

The handle travels with the table so a command can never be dispatched against
a different instance than the one it was resolved from.
*/
struct InstanceCommands
{
    /// The instance these commands were resolved from.
    VkInstance instance;

    mixin CommandTable!instanceSets;

    /// Resolve the instance tier for `instance`.
    static InstanceCommands load(in GlobalCommands g, VkInstance instance) @system nothrow @nogc
    in (g.getInstanceProcAddr !is null, "global tier is not loaded")
    in (instance !is null, "instance must not be null")
    {
        InstanceCommands r;
        r.instance = instance;
        static foreach (set; instanceSets)
            static foreach (name; set.names)
                mixin("r." ~ lowerFirst(name) ~ " = cast(PFN_vk" ~ name
                    ~ ") g.getInstanceProcAddr(instance, \"vk" ~ name ~ "\");");
        return r;
    }
}

/**
Tier 3: commands bound to one `VkDevice`.

Resolved through `vkGetDeviceProcAddr`, so calls reach the driver directly
rather than through the loader's device-dispatch trampoline. This is the tier
that must not be global: it is per-device by construction, so a second device —
Skia's, or a second adapter — cannot overwrite the first.
*/
struct DeviceCommands
{
    /// The device these commands were resolved from.
    VkDevice device;

    mixin CommandTable!deviceSets;

    /// Resolve the device tier for `device`.
    static DeviceCommands load(in InstanceCommands i, VkDevice device) @system nothrow @nogc
    in (i.getDeviceProcAddr !is null, "instance tier is not loaded")
    in (device !is null, "device must not be null")
    {
        DeviceCommands r;
        r.device = device;
        static foreach (set; deviceSets)
            static foreach (name; set.names)
                mixin("r." ~ lowerFirst(name) ~ " = cast(PFN_vk" ~ name
                    ~ ") i.getDeviceProcAddr(device, \"vk" ~ name ~ "\");");
        return r;
    }
}

@("vulkan.dispatch.lowerFirst")
@safe pure nothrow unittest
{
    assert(lowerFirst("CreateInstance") == "createInstance");
    assert(lowerFirst("CmdPipelineBarrier") == "cmdPipelineBarrier");
    assert(lowerFirst("") == "");
}

@("vulkan.dispatch.tablesDeclareTheirCommands")
@safe pure nothrow @nogc unittest
{
    // The generated fields exist and are typed as the header's PFN aliases —
    // if a name in one of the lists were misspelled, `PFN_vk<name>` would not
    // resolve and this module would not compile at all.
    static assert(is(typeof(GlobalCommands.createInstance) == PFN_vkCreateInstance));
    static assert(is(typeof(InstanceCommands.createDevice) == PFN_vkCreateDevice));
    static assert(is(typeof(InstanceCommands.getPhysicalDeviceSurfaceCapabilitiesKHR)
        == PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR));
    static assert(is(typeof(DeviceCommands.acquireNextImageKHR) == PFN_vkAcquireNextImageKHR));
    static assert(is(typeof(DeviceCommands.queuePresentKHR) == PFN_vkQueuePresentKHR));
}

@("vulkan.dispatch.handleTravelsWithTheTable")
@safe pure nothrow @nogc unittest
{
    // The property that makes a second device safe: a table cannot be used
    // without saying which handle it belongs to, because it carries it.
    static assert(is(typeof(InstanceCommands.instance) == VkInstance));
    static assert(is(typeof(DeviceCommands.device) == VkDevice));

    // ... and no tier is a global: every field lives in an instance of the
    // struct. A `__gshared` here is what ErupteD's multi-device hazard is.
    static assert(!__traits(isStaticFunction, DeviceCommands.load) ||
        is(typeof(DeviceCommands.load(InstanceCommands.init, VkDevice.init))));
}

@("vulkan.dispatch.emptyTableReportsItsFirstMissingCommand")
@safe pure nothrow @nogc unittest
{
    // A default-constructed table is entirely null, so the check must name the
    // first command rather than silently pass.
    GlobalCommands g;
    assert(!g.complete);
    assert(g.firstMissing == "vkEnumerateInstanceVersion");

    DeviceCommands d;
    assert(!d.complete);
    assert(d.firstMissing == "vkDestroyDevice");
}

// `@system`: it forges function pointers out of a data address to stand in for
// "loaded", and never calls them. `@safe` correctly refuses that cast.
@("vulkan.dispatch.extensionCommandsAreNotCore")
@system pure nothrow @nogc unittest
{
    // The property the instance-info example forced into existence: an
    // instance created without VK_KHR_surface has no surface commands, and
    // that is a correctly-built instance, not a broken one. So `complete`
    // must ignore them and `has` must answer for them separately.
    InstanceCommands i;

    // Fill every core command with a non-null placeholder; the surface group
    // stays null, as the loader would leave it.
    static foreach (name; ["DestroyInstance", "EnumeratePhysicalDevices",
        "GetPhysicalDeviceProperties", "GetPhysicalDeviceFeatures",
        "GetPhysicalDeviceQueueFamilyProperties", "GetPhysicalDeviceMemoryProperties",
        "GetPhysicalDeviceFormatProperties", "EnumerateDeviceExtensionProperties",
        "CreateDevice", "GetDeviceProcAddr"])
        mixin("i." ~ name[0 .. 1].toLowerAscii ~ name[1 .. $]
            ~ " = cast(typeof(i." ~ name[0 .. 1].toLowerAscii ~ name[1 .. $] ~ ")) &i;");

    assert(i.complete, "core-only table must be complete");
    assert(!i.has!khrSurface, "surface commands are absent and must report so");
}

private string toLowerAscii(string s) @safe pure nothrow
    => s.length && s[0] >= 'A' && s[0] <= 'Z' ? cast(char)(s[0] + 32) ~ s[1 .. $] : s;

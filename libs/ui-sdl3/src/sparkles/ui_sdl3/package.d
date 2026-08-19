/**
The SDL3 window system: a window, an input source, and a Vulkan surface.

`sparkles:ui-skia` renders; this package owns everything around that. The split
follows the plan's decision that presentation is the window's business — the
Vulkan instance, device, swapchain and present loop are created from the
surface, resized with the window, and presented on the window's vsync, so
putting them behind the canvas would make the canvas own the frame loop.

What SDL3 actually gives us for Vulkan is narrow, and worth stating because it
sets the scope of everything else here: `SDL_Vulkan_GetVkGetInstanceProcAddr`,
`SDL_Vulkan_GetInstanceExtensions`, `SDL_Vulkan_CreateSurface` and their
teardown. There is no device creation, no swapchain and no present — all of
that is ours, built on $(MREF sparkles,vulkan).
$(B Importing this alongside $(MREF sparkles,vulkan) makes C's own typedefs
ambiguous.) Both packages publicly re-export an ImportC module, and each C
surface carries its own `size_t`, `ptrdiff_t` and `wchar_t`. On glibc the two
come from the same `stddef.h` and collapse into one symbol; on darwin they do
not, so a bare `size_t` in a module that imports both is a compile error —
`size_t matches conflicting symbols`, and only on macOS. Write `object.size_t`,
or use the fixed-width type the API actually wants (Vulkan counts in `uint`).

*/
module sparkles.ui_sdl3;

public import sparkles.ui_sdl3.sdl3_c;
public import sparkles.ui_sdl3.commands;
public import sparkles.ui_sdl3.error;
public import sparkles.ui_sdl3.frame;
public import sparkles.ui_sdl3.swapchain;
public import sparkles.ui_sdl3.vulkan_context;
public import sparkles.ui_sdl3.window;

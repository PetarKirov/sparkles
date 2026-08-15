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
*/
module sparkles.ui_sdl3;

public import sparkles.ui_sdl3.sdl3_c;
public import sparkles.ui_sdl3.error;
public import sparkles.ui_sdl3.vulkan_context;
public import sparkles.ui_sdl3.window;

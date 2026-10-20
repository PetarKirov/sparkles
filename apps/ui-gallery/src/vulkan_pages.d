/**
The gallery's pages through the Vulkan canvas on a real driver — canvas
scenario 18 of `docs/specs/ui-vulkan/testing.md` (`UVK27`, `UVK28`): over a
whole frame of every page, every device allocation the driver sees comes from
`sparkles:vulkan`'s sub-allocator, none from the canvas itself.

The oracle is the driver's own count: spies over the device's commands count
the allocations it made and the ones it freed, and after each frame the
difference must be exactly the allocations the sub-allocator holds. A canvas
that allocated for itself would leave one the sub-allocator does not know.

Opt-in (`SPARKLES_VULKAN_READBACK=1`): it needs lavapipe and the validation
layer, which also reports any misuse the frames make.
*/
module vulkan_pages;

version (unittest):

import sparkles.base.term_color : RgbColor;
import sparkles.test_runner.skip : skipTest;
import sparkles.ui.geometry : Size;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;
import sparkles.ui_vulkan.painter : FrameMetrics, FrameReport;
import sparkles.ui_vulkan.testing : Canvas, readbackEnabled, readbackSkipReason, Rig,
    RigOptions, spyLog;
import sparkles.vulkan : VK_MAX_MEMORY_TYPES;

import gallery : Gallery;
import registry : pages;
import state : GalleryState;

@("ui_gallery.vulkan.everyPageAllocatesOnlyThroughTheSubAllocator")
@system unittest
{
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-gallery-pages", 960, 640, RigOptions(spy: true));
    scope (success)
        rig.close();

    size_t drawn;
    foreach (i, page; pages)
    {
        // The Terminal page spawns shells; its paint is the terminal's own
        // until plan slice V6.
        if (page.title == "Terminal")
            continue;
        auto app = Gallery(GalleryState(page: i));
        auto rec = runAppRecorded(app, RunConfig.init, null, (ref RecordingHost h) {
            h.size = Size(96, 32);
            h.frameSeconds = 0;
        });
        rig.canvas.images(rec.imageRegistry);
        FrameReport report;
        rig.draw((ref Canvas c) { paint(c, rec.lastOps); }, FrameMetrics(cellW: 10, cellH: 20),
            RgbColor(0, 0, 0), report);

        uint held;
        foreach (type; 0 .. VK_MAX_MEMORY_TYPES)
            held += rig.memory.stats(type).allocations;
        const live = spyLog.allocations - spyLog.frees;
        assert(live == held, page.title);
        ++drawn;
    }
    assert(drawn + 1 == pages.length, "every page but the terminal's drew");
}

#!/usr/bin/env dub
/+ dub.sdl:
    name "imgshot"
    dependency "sparkles:ui-app" path="../../../.."
    subConfiguration "sparkles:ui-app" "gui"
    dflags "-preview=in" "-preview=dip1000"
+/
// Verifies the IMG1 GPU path end to end: register RGBA, bind the registry to
// the host, draw an `image` widget, capture the swapped frame.
import std.process : environment;
import std.stdio;

import sparkles.ui.geometry : Insets, Size, SizeSpec;
import sparkles.ui.image : ImageFit, ImageHandle, ImageRegistry;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui_app.backend : BackendPolicy;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run : RunOutcome;
import sparkles.ui_app.run_app : runApp;
import sparkles.input.events : Event;

ubyte[] swatch(int w, int h)
{
    auto px = new ubyte[](cast(size_t) w * h * 4);
    foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            const i = (cast(size_t) y * w + x) * 4;
            const dark = ((x / 8) + (y / 8)) % 2 == 0;
            px[i + 0] = cast(ubyte)(x * 255 / (w - 1));
            px[i + 1] = cast(ubyte)(y * 255 / (h - 1));
            px[i + 2] = dark ? 0x30 : 0xc0;
            px[i + 3] = 0xFF;
        }
    return px;
}

struct App
{
    ImageRegistry images;
    ImageHandle h;
    ubyte[] pixels;
    int frame;
    bool quitNow;
    string shot;

    WidgetTree view(H)(ref H host)
    {
        if (!h.valid)
        {
            pixels = swatch(64, 32);
            h = images.register(pixels, Size(64, 32), "a colour swatch");
        }
        auto p = (() @trusted => &images)();
        static if (__traits(compiles, host.images(p)))
            host.images(p);

        ++frame;
        static if (__traits(hasMember, H, "screenshot"))
            if (frame == 20)
                host.screenshot(shot);
        if (frame == 30)
            host.quit();

        auto b = Builder();
        const img = b.add(Widget(
            kind: WidgetKind.image, image: h, imagePixels: Size(64, 32),
            imageFit: ImageFit.contain, text: "a colour swatch"));
        const big = b.add(Widget(
            kind: WidgetKind.image, image: h, imagePixels: Size(64, 32),
            imageFit: ImageFit.contain, text: "a colour swatch",
            width: SizeSpec.fixed(40), height: SizeSpec.fixed(12)));
        const missing = b.add(Widget(
            kind: WidgetKind.image, imagePixels: Size(64, 32),
            text: "not registered"));
        const col = b.container(WidgetKind.column, [img, big, missing],
            padding: Insets.all(2), gap: 1);
        return b.finish(col);
    }

    void handle(H)(ref H host, in Event e) {}
}

int main(string[] args)
{
    auto app = App();
    app.shot = environment.get("IMGSHOT", "imgshot.png");
    RunConfig cfg;
    cfg.title = "imgshot";
    cfg.gui.windowWidth = 90;
    cfg.gui.windowHeight = 30;
    auto policy = BackendPolicy(forceGui: true, displayPresent: true);
    const r = runApp(app, cfg, policy);
    writeln("outcome: ", r);
    return r == RunOutcome.ok ? 0 : 1;
}

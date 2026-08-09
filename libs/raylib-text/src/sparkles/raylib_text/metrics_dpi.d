/**
Point size → pixel size, against a display's actual density (`IXB11`).

This lives beside the cell metrics it feeds — `FontSet` already owns `cellW`
and `cellH`, and the pixel size is what determines them — and it is pure, so
it is testable with no window.

The $(I query) for the panel's scale belongs to the backend adapter
(`sparkles.ui_raylib.window.displayMetrics`); only the arithmetic is here.
That split is why this module needs no raylib.
*/
module sparkles.raylib_text.metrics_dpi;

/**
The display a point size is being resolved against.

`scale` is the panel's content scale, `1.0` meaning "the nominal DPI". It is
clamped by $(LREF maxScale) because the failure it prevents is not subtle: a
5× phone panel with a 20 pt font asks for a 100 px atlas per face, which
exhausts the texture budget. Stating the cap once here is better than each app
rediscovering it — which is how the Android build arrived at a hardcoded 4.
*/
struct DisplayMetrics
{
    float scale = 1.0f; /// panel content scale (1.0 = the nominal DPI)
    int dpi = 96;       /// the DPI `points` are interpreted against
    float maxScale = 4.0f; /// ceiling on `scale`, to bound atlas growth

    /**
    How many device pixels the backend puts behind one coordinate unit.

    $(B Not the same question as `scale`, and conflating them is a bug in
    both directions.) `scale` asks "how much bigger should the UI be?" and
    multiplies the point size; this asks "how dense is the framebuffer?" and
    multiplies only the $(I rasterization) size, leaving layout alone.

    A Retina Mac wants `scale` 1 and `renderScale` 2: same physical text size,
    twice the pixels. An Android phone wants the reverse — its coordinate
    space already IS device pixels, so density belongs in `scale` and this
    stays 1. Feeding a Retina panel's 2 into `scale` would render everything
    at double size; feeding a phone's density in here would render it at half.
    */
    float renderScale = 1.0f;
}

/**
`points` in pixels on `m`'s display, rounded to nearest and never below 1.

The conversion two apps had each written inline, one of them without the scale
factor at all — so `apps/terminal` rendered unreadably on the same panel where
hue was legible (`IXR28`).
*/
int pixelsForPoints(double points, in DisplayMetrics m) @safe pure nothrow @nogc
{
    const s = m.scale < 1.0f ? 1.0f : (m.scale > m.maxScale ? m.maxScale : m.scale);
    const px = points * m.dpi / 72.0 * s + 0.5;
    return px < 1 ? 1 : cast(int) px;
}

@("raylib_text.pixelsForPoints.scaleAndClamp")
@safe pure nothrow @nogc
unittest
{
    // The desktop default: 14 pt at 96 dpi, unscaled — the value both apps
    // computed inline before this existed.
    assert(pixelsForPoints(14, DisplayMetrics.init) == 19);

    // A 2.625× panel (≈420 dpi, a common phone): the same request lands at a
    // readable size instead of a 19 px one.
    assert(pixelsForPoints(14, DisplayMetrics(scale: 2.625f)) == 49);

    // Below 1.0 is ignored — a scale under the nominal DPI would shrink text
    // that is already at its intended size.
    assert(pixelsForPoints(14, DisplayMetrics(scale: 0.5f)) == 19);

    // And the ceiling bounds atlas growth rather than honouring an extreme.
    assert(pixelsForPoints(20, DisplayMetrics(scale: 50f))
        == pixelsForPoints(20, DisplayMetrics(scale: 4f)));

    // Never zero: a degenerate request still yields a loadable face.
    assert(pixelsForPoints(0, DisplayMetrics.init) == 1);
    assert(pixelsForPoints(-5, DisplayMetrics.init) == 1);
}

@("raylib_text.pixelsForPoints.renderScaleDoesNotMagnify")
@safe pure nothrow @nogc
unittest
{
    // The distinction the two fields exist to keep. A Retina panel reports
    // `renderScale: 2` and must NOT change the point size — same physical
    // text, oversampled atlas. Feeding that 2 into `scale` instead is the bug
    // this pins: it renders everything at double size.
    assert(pixelsForPoints(14, DisplayMetrics(renderScale: 2.0f))
        == pixelsForPoints(14, DisplayMetrics.init));

    // And they compose independently: a dense phone panel magnifies (scale)
    // while its coordinate space stays device pixels (renderScale 1).
    assert(pixelsForPoints(14, DisplayMetrics(scale: 2.0f, renderScale: 2.0f))
        == pixelsForPoints(14, DisplayMetrics(scale: 2.0f)));
}

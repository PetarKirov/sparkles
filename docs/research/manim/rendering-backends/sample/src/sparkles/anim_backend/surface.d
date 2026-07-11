/// A minimal RAII wrapper over a Cairo image surface + context, showing the
/// CPU-vector backend shape the `rendering-backends` cluster describes: submit
/// cubic Béziers, fill by the nonzero winding rule, then read back the
/// premultiplied-ARGB32 pixel buffer for the video encoder.
///
/// Source-only illustrative fixture — it mirrors the `libs/ghostty` ImportC
/// binding pattern but is NOT compiled by CI (Cairo is not in the dev shell by
/// default). Its job is to be correct and concrete, not to run.
module sparkles.anim_backend.surface;

import sparkles.anim_backend.cairo_c;

/// Owns a Cairo image surface and its drawing context; frees both on scope
/// exit. Non-copyable: it holds unique ownership of the two C handles.
struct CairoCanvas
{
    private cairo_surface_t* _surface;
    private cairo_t* _cr;

    @disable this(this);

    this(int width, int height) @nogc nothrow
    {
        // ImportC exposes C enum members unscoped, C-style.
        _surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
        _cr = cairo_create(_surface);
    }

    ~this() @nogc nothrow
    {
        if (_cr !is null)
            cairo_destroy(_cr);
        if (_surface !is null)
            cairo_surface_destroy(_surface);
    }

    /// Fill one cubic-Bézier subpath — points laid out as
    /// `anchor, handle, handle, anchor, handle, handle, anchor, …` — with an
    /// RGBA colour under the nonzero winding rule. This is the exact primitive
    /// a `VMobject` fill lowers to on the Cairo backend (no triangulation).
    void fillCubicPath(scope const double[2][] pts, double r, double g, double b, double a) @nogc nothrow
    in (pts.length >= 4 && (pts.length - 1) % 3 == 0)
    {
        cairo_set_fill_rule(_cr, CAIRO_FILL_RULE_WINDING);
        cairo_move_to(_cr, pts[0][0], pts[0][1]);
        for (size_t i = 1; i + 2 < pts.length; i += 3)
            cairo_curve_to(_cr, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1],
                pts[i + 2][0], pts[i + 2][1]);
        cairo_close_path(_cr);
        cairo_set_source_rgba(_cr, r, g, b, a);
        cairo_fill(_cr);
    }

    /// The readback pointer an encoder is handed: premultiplied ARGB32, with
    /// `stride` bytes per row. `cairo_surface_flush` makes pending draws visible
    /// to the direct buffer read.
    const(ubyte)* pixels() @nogc nothrow
    {
        cairo_surface_flush(_surface);
        return cast(const(ubyte)*) cairo_image_surface_get_data(_surface);
    }

    int stride() @nogc nothrow => cairo_image_surface_get_stride(_surface);
}

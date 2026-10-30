/**
The window frame an application draws itself (`F13`, `WSI-O4`): a title bar
and resize borders, for a window system that leaves the frame to the client —
GNOME's compositor, which declines every request for server decorations.

The frame is the host's, not the application's. It is an inset the native arm
reserves above the application's cells, so the application sees a smaller
surface and never learns it is there; it paints through the same canvas as the
content, and it answers the pointer before the application does. The window
system supplies what the frame is (`WindowState`) and performs what it asks
for (`startInteractiveMove`, `startInteractiveResize`, `setMaximized`,
`setMinimized`, `showWindowMenu`); this module decides layout, hit testing and
drawing, and is pure, so all of it is tested without a window.

The frame looks like the desktop's own. Where that desktop is GNOME, which is
the one that leaves the frame to the client, its metrics are libadwaita 1.8's
header bar, in CSS pixels at the frame's density, snapped to whole device
pixels: a 46 px bar; 34 px buttons 3 px apart, 7 px from the edge, each a
24 px disc always tinted with the foreground (10 %, 15 % hovered, 30 %
pressed — close too, which Adwaita does not paint red) around Adwaita's
16 px symbolic icon, its strokes a pixel wide as GTK 4.20 draws them; a
bold title in the desktop's title face (`sparkles.ui_app.frame_title`); a
one-pixel shade under the bar and a one-pixel light outline inside the
window's edge. An inactive window's bar
draws its controls and title at half strength. The colours are the
application's (`chrome` in the palette it gives the host — theme data, never
a choice), Adwaita's header bar colours where it gives none.

Where the surface's alpha reaches the compositor, the window sits in a
transparent margin, as GTK's does (`FrameExtents`, 20 px): its corners are
rounded at Adwaita's 15 px, Adwaita's shadow is cast into the margin, and the
outer 12 px of it resize the window, a corner reaching 24 px along each edge
— GTK's resize border, outside the window. Maximized or fullscreen there is
no margin; tiled, the margin stays but the window is square, unshadowed but
for a one-pixel ring, and is not resized from it. Without alpha the frame
keeps to the window: square, and resized from a 6 px grip inside its edge.
*/
module sparkles.ui_app.client_frame;

// The native arm's alone: only it links `sparkles:wsi`.
version (UiAppGuiVulkan):

import core.time : Duration, MonoTime, msecs;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.pixel_geometry : densityPx;
import sparkles.ui.style : Palette, Slot;
import sparkles.wsi.types : DecorationMode, FrameExtents, ResizeEdge, ToplevelState,
    WindowCapability, WindowState;

/// A part of the frame, or the content it surrounds.
enum FramePart : ubyte
{
    content,
    title,
    minimize,
    maximize,
    close,
    resize,
    outside, /// the margin beyond the resize border: a press there does nothing
}

/// What a position lands on: a part, and for `resize` the edge.
struct FrameHit
{
    FramePart part;
    ResizeEdge edge;
}

/// What a pointer press or release asks the window system for.
enum FrameAction : ubyte
{
    none,
    move,        /// `startInteractiveMove`
    resize,      /// `startInteractiveResize` from `FrameHit.edge`
    toggleMaximized,
    minimize,
    close,       /// the application's own close path, as a close request
    windowMenu,  /// `showWindowMenu` at the press
}

/// Where the frame's pieces fall, in device pixels from the surface's corner.
struct FrameGeometry
{
    int surfaceW, surfaceH; /// the whole surface
    int top;                /// where the bar starts: the margin and the safe-area top inset
    int cellW, cellH;       /// one cell of the font the title is drawn in
    float density = 1;      /// device pixels per CSS pixel
    /// The transparent margin round the window, each side (`F13`): the
    /// window is the surface inside it.
    int margin;

@safe pure nothrow @nogc:

    /// The window's edges and width, inside the margin.
    int left() const => margin;
    /// ditto
    int right() const => surfaceW - margin;
    /// ditto
    int bottom() const => surfaceH - margin;
    /// ditto
    int width() const => surfaceW - 2 * margin;
}

/// The frame's colours: the bar's ground and what is drawn on it.
struct FrameColours
{
    RgbColor bg = RgbColor(0x2e, 0x2e, 0x32); /// the bar; Adwaita's dark header bar
    RgbColor fg = RgbColor(0xff, 0xff, 0xff); /// title, icons and the discs' tint
    bool dark = true;                         /// the shade and outline follow it

    /**
    The application's `chrome` colours where its palette sets them, and
    otherwise Adwaita's header bar in the scheme `ground`, the window's
    background, implies.
    */
    static FrameColours of(in Palette palette, RgbColor ground) @safe pure nothrow @nogc
    {
        FrameColours c;
        const darkGround = luma(ground) < 128;
        const bg = palette.bg[Slot.chrome];
        c.bg = bg.kind == bg.Kind.rgb ? bg.rgb
            : darkGround ? RgbColor(0x2e, 0x2e, 0x32) : RgbColor(0xff, 0xff, 0xff);
        c.dark = luma(c.bg) < 128;
        const fg = palette.fg[Slot.chrome];
        // Adwaita's light foreground is rgb(0 0 6 / 80%), here over white.
        c.fg = fg.kind == fg.Kind.rgb ? fg.rgb
            : c.dark ? RgbColor(0xff, 0xff, 0xff) : RgbColor(0x33, 0x33, 0x38);
        return c;
    }
}

/// One piece of the frame, in device pixels from the surface's corner.
struct FrameShape
{
    /// What the piece is.
    enum Kind : ubyte
    {
        fill,    /// a rectangle
        disc,    /// a circle filling the square `w` × `h`
        cross,   /// close's cross in the `w` × `h` icon box: see $(LREF crossCoverage)
        /// the box's drop shadow, outside it only (ui-vulkan `UVK40`); with
        /// no blur, a ring `spread` wide round it
        shadow,
        /// what lies outside the box's rounded corners, erased (`UVK41`)
        erase,
    }

    Kind kind;          ///
    int x, y, w, h;     ///
    RgbColor colour;    ///
    ubyte alpha = 255;  /// blended over what is beneath
    /// A `shadow`'s or an `erase`'s box corner radius, and a shadow's blur
    /// radius and spread, in device pixels: CSS's `box-shadow`.
    float radius = 0, blur = 0, spread = 0;
}

/// Where the title is drawn from, and in what.
struct FrameTitle
{
    int x, y;              /// the title's top left, in device pixels
    RgbColor colour;       ///
    ubyte alpha = 255;     ///
}

/// The client-drawn frame's state: what the window system reported and what
/// the pointer is doing over it.
struct ClientFrame
{
    /// libadwaita's header bar, in CSS pixels: the bar's height and its
    /// padding above and beside the buttons.
    enum int barCss = 46, padTopCss = 6, padSideCss = 7;
    /// A button, the space between two, the disc in it and the icon on the
    /// disc, in CSS pixels.
    enum int buttonCss = 34, spacingCss = 3, discCss = 24, iconCss = 16;
    /// The space the title keeps from the buttons, in CSS pixels.
    enum int titleGapCss = 6;
    /// The resize border inside the window's edges, in CSS pixels, where the
    /// window has no margin to resize it from.
    enum int gripCss = 6;
    /**
    What the frame draws outside the window where the surface can show it,
    in CSS pixels (`FrameExtents`): GTK's margin (Adwaita's shadow reaches
    19 of its 20 pixels), its resize border round the window and
    Adwaita's window radius.
    */
    enum FrameExtents extents = FrameExtents(margin: 20, resize: 12, radius: 15);
    /// How far along an edge from a corner a press resizes from the corner,
    /// in CSS pixels: GTK's `RESIZE_HANDLE_CORNER_SIZE`.
    enum int cornerCss = 24;
    /// The most shapes $(LREF build) emits: the bar and its shade, a disc and
    /// up to four pieces of icon per button, the outline's four sides, the
    /// corners' erase and three shadows.
    enum size_t maxShapes = 2 + 3 * 5 + 4 + 1 + 3;
    /// Two title presses closer than this are a double click.
    enum Duration doubleClick = 400.msecs;
    /// How far a title press travels before it becomes a move, in CSS pixels.
    enum int dragThresholdCss = 4;

    WindowState state;      /// as the window system last reported it
    FramePart hover;        /// the part under the pointer
    FramePart pressed;      /// the button a press began on, until its release
    private MonoTime lastTitlePress;
    // A title press waiting to become a move: GTK's rule. A move started on
    // the press hands the pointer to the compositor's grab, which swallowed
    // a double click's second press — on GNOME a maximized window could not
    // be restored from its title.
    private bool moveArmed;
    private int pressX, pressY;
    // The buttons pressed in the content and not yet released, as bits.
    private uint contentPresses;

@safe pure nothrow @nogc:

    /// Whether the frame is drawn at all: the window system left it to the
    /// client, and the window is not fullscreen.
    bool active() const
        => state.decorations == DecorationMode.client && !state.has(ToplevelState.fullscreen);

    /// The bar's height in device pixels: the inset the content moves down by.
    int barPx(float density) const => active ? densityPx(barCss, density) : 0;

    /// The resize border's width inside the window in device pixels; none
    /// while an edge is held (maximized, tiled), where the window cannot be
    /// resized from it, and none where a margin round the window has one.
    int gripPx(float density, int margin = 0) const
        => active && !state.edgesHeld && margin == 0 ? densityPx(gripCss, density) : 0;

    /// The window's corner radius in device pixels: rounded only where a
    /// margin can show what lies beyond its corners, and square where an
    /// edge is held.
    float radiusPx(in FrameGeometry g) const
        => active && g.margin > 0 && !state.edgesHeld ? densityPx(extents.radius, g.density) : 0;

    /**
    The smallest surface a framed window keeps, in device pixels: every
    button twice over, for a title between them, and three rows of cells
    under the bar, so a resize cannot shrink it past its own frame.
    */
    Size2 minimumPx(int cellH, float density) const
    {
        if (!active)
            return Size2.init;
        return Size2(2 * (densityPx(padSideCss + titleGapCss + 3 * buttonCss + 2 * spacingCss,
            density)), barPx(density) + 3 * cellH);
    }

    /// The buttons the window manager offers, right to left: close first.
    private FramePart[3] buttons(out size_t count) const
    {
        FramePart[3] b;
        b[count++] = FramePart.close;
        if (state.offers(WindowCapability.maximize))
            b[count++] = FramePart.maximize;
        if (state.offers(WindowCapability.minimize))
            b[count++] = FramePart.minimize;
        return b;
    }

    // The `i`th button from the right: its box's left edge and top, and its
    // side, in device pixels.
    private static void buttonBox(size_t i, in FrameGeometry g, out int x, out int y, out int side)
    {
        side = densityPx(buttonCss, g.density);
        const step = side + densityPx(spacingCss, g.density);
        x = g.right - densityPx(padSideCss, g.density) - side - cast(int) i * step;
        y = g.top + densityPx(padTopCss, g.density);
    }

    /// What `(x, y)`, device pixels from the surface's corner, lands on.
    FrameHit hitTest(int x, int y, in FrameGeometry g) const
    {
        if (!active)
            return FrameHit(FramePart.content);
        // Beyond the window, in its margin: GTK's resize border round it,
        // a corner reaching `cornerCss` along each edge from it; past the
        // border the shadow takes no press.
        const m = g.margin;
        if (m > 0 && (x < g.left || x >= g.right || y < m || y >= g.bottom))
        {
            const reach = state.edgesHeld ? 0 : densityPx(extents.resize, g.density);
            if (x < g.left - reach || x >= g.right + reach || y < m - reach
                || y >= g.bottom + reach)
                return FrameHit(FramePart.outside);
            // GTK's `get_edge_for_coordinates`: beside the window, its side,
            // or a corner within `cornerCss` of one; above or below it, its
            // top or bottom, or a corner within `cornerCss` of one.
            const corner = densityPx(cornerCss, g.density);
            uint edge;
            if (x < g.left || x >= g.right)
            {
                edge = x < g.left ? ResizeEdge.left : ResizeEdge.right;
                if (y < m + corner) edge |= ResizeEdge.top;
                else if (y >= g.bottom - corner) edge |= ResizeEdge.bottom;
            }
            else
            {
                edge = y < m ? ResizeEdge.top : ResizeEdge.bottom;
                if (x < g.left + corner) edge |= ResizeEdge.left;
                else if (x >= g.right - corner) edge |= ResizeEdge.right;
            }
            return FrameHit(FramePart.resize, cast(ResizeEdge) edge);
        }
        const grip = gripPx(g.density, m);
        if (grip > 0)
        {
            uint edge;
            if (y < g.top + grip) edge |= ResizeEdge.top;
            else if (y >= g.bottom - grip) edge |= ResizeEdge.bottom;
            if (x < g.left + grip) edge |= ResizeEdge.left;
            else if (x >= g.right - grip) edge |= ResizeEdge.right;
            if (edge)
                return FrameHit(FramePart.resize, cast(ResizeEdge) edge);
        }
        if (y < g.top || y >= g.top + barPx(g.density))
            return FrameHit(FramePart.content);
        size_t count;
        const b = buttons(count);
        foreach (i; 0 .. count)
        {
            int bx, by, side;
            buttonBox(i, g, bx, by, side);
            // One that `build` does not draw, past the left edge, is not hit.
            if (bx < g.left)
                break;
            if (x >= bx && x < bx + side && y >= by && y < by + side)
                return FrameHit(b[i]);
        }
        return FrameHit(FramePart.title);
    }

    /**
    A primary press at `hit`, at (`x`, `y`): a title press arms a move that
    starts once the pointer travels (two quick ones toggle maximized), a
    border press resizes, and a button press is held until its release
    decides. A secondary press on the title opens the window manager's menu.
    */
    FrameAction press(in FrameHit hit, bool secondary, MonoTime now, int x = 0, int y = 0)
    {
        final switch (hit.part)
        {
            case FramePart.content:
            case FramePart.outside:
                return FrameAction.none;
            case FramePart.resize:
                return secondary ? FrameAction.none : FrameAction.resize;
            case FramePart.title:
                if (secondary)
                    return state.offers(WindowCapability.windowMenu)
                        ? FrameAction.windowMenu : FrameAction.none;
                if (lastTitlePress != MonoTime.init && now - lastTitlePress < doubleClick)
                {
                    lastTitlePress = MonoTime.init;
                    moveArmed = false;
                    return state.offers(WindowCapability.maximize)
                        ? FrameAction.toggleMaximized : FrameAction.none;
                }
                lastTitlePress = now;
                moveArmed = true;
                pressX = x;
                pressY = y;
                return FrameAction.none;
            case FramePart.minimize:
            case FramePart.maximize:
            case FramePart.close:
                if (!secondary)
                    pressed = hit.part;
                return FrameAction.none;
        }
    }

    /// The pointer at (`x`, `y`) with the button down: an armed title press
    /// that has travelled `dragThresholdCss` becomes a move.
    FrameAction motion(int x, int y, float density)
    {
        if (!moveArmed)
            return FrameAction.none;
        const t = densityPx(dragThresholdCss, density);
        if (x - pressX > t || pressX - x > t || y - pressY > t || pressY - y > t)
        {
            moveArmed = false;
            return FrameAction.move;
        }
        return FrameAction.none;
    }

    /// A primary release at `hit`: a button acts when the press began on it.
    FrameAction release(in FrameHit hit)
    {
        moveArmed = false;
        const was = pressed;
        pressed = FramePart.content;
        if (was == FramePart.content || was != hit.part)
            return FrameAction.none;
        switch (was)
        {
            case FramePart.close: return FrameAction.close;
            case FramePart.maximize: return FrameAction.toggleMaximized;
            case FramePart.minimize: return FrameAction.minimize;
            default: return FrameAction.none;
        }
    }

    /// Whether a press began on a button and its release still belongs to
    /// the frame, wherever the pointer has gone since.
    bool holding() const => pressed != FramePart.content || moveArmed;

    /**
    Whether a pointer event belongs to the application because a press the
    application took — one that began in the content — is still down: its
    moves and its release are the application's even over the frame, so a
    selection dragged up into the title bar still ends. `button` is the
    event's, `pressedOn` what a press lands on; a press while one is down
    is the application's too.
    */
    bool applicationOwns(Phase phase, uint button, FramePart pressedOn)
    {
        const bit = 1u << (button & 31);
        final switch (phase)
        {
            case Phase.moved:
                return contentPresses != 0;
            case Phase.pressed:
                if (pressedOn != FramePart.content && contentPresses == 0)
                    return false;
                contentPresses |= bit;
                return true;
            case Phase.released:
                if (!(contentPresses & bit))
                    return false;
                contentPresses &= ~bit;
                return true;
        }
    }

    /// The pointer left the surface: a press whose release went with it (a
    /// grab the compositor broke) is forgotten, so the frame answers again.
    void pointerLeft() { contentPresses = 0; }

    /// What a pointer event does, as $(LREF applicationOwns) tells them apart.
    enum Phase : ubyte
    {
        moved,
        pressed,
        released,
    }

    /**
    The frame's shapes, in device pixels from the surface's corner, in the
    order they are drawn; the title is $(LREF title)'s, drawn after them.

    Every piece is snapped to whole device pixels, and each icon box is
    centred on its disc exactly: the disc and the icon box differ by an even
    number of pixels at any density, the icon giving up a pixel where they
    would not.
    */
    size_t build(scope FrameShape[] shapes, in FrameGeometry g, in FrameColours c) const
    {
        if (!active || shapes.length < maxShapes || g.width <= 0)
            return 0;
        size_t n;
        void put(FrameShape.Kind kind, int x, int y, int w, int h, RgbColor colour, ubyte alpha,
            float radius = 0, float blur = 0, float spread = 0)
        {
            if (w > 0 && h > 0 && (alpha > 0 || kind == FrameShape.Kind.erase))
                shapes[n++] = FrameShape(kind, x, y, w, h, colour, alpha, radius, blur, spread);
        }
        const backdrop = !state.has(ToplevelState.activated);
        // Adwaita dims an inactive bar's contents with opacity 0.5.
        ubyte dimmed(int alpha) => cast(ubyte)(backdrop ? alpha / 2 : alpha);

        const bar = barPx(g.density);
        put(FrameShape.Kind.fill, g.left, g.top, g.width, bar, c.bg, 255);
        // The shade along the bar's foot: rgb(0 0 6 / 36%) dark, 12% light.
        put(FrameShape.Kind.fill, g.left, g.top + bar - 1, g.width, 1, RgbColor(0, 0, 6),
            c.dark ? 92 : 31);

        const disc = densityPx(discCss, g.density);
        int icon = densityPx(iconCss, g.density);
        if ((disc - icon) % 2)
            --icon;
        // A piece of the 16-unit icon grid, symmetric about the icon's centre.
        int near(int units) => cast(int)(units * icon / 16.0f + 0.5f);
        // Past the centre, measured from the far side, so a piece and its
        // mirror image round alike.
        int at(int units) => units > 8 ? icon - near(16 - units) : near(units);
        // One unit: GTK 4.20 draws these icons' strokes a pixel wide at
        // scale 1 (measured beside Ghostty's header bar), half the 2-unit
        // strokes of the icon theme's SVGs.
        const stroke = near(1) > 0 ? near(1) : 1;

        size_t count;
        const b = buttons(count);
        foreach (i; 0 .. count)
        {
            const part = b[i];
            int bx, by, side;
            buttonBox(i, g, bx, by, side);
            if (bx < g.left)
                continue;
            const dx = bx + (side - disc) / 2, dy = by + (side - disc) / 2;
            // 10% of the foreground, 15% hovered, 30% pressed.
            const tint = pressed == part ? 77 : hover == part ? 38 : 26;
            put(FrameShape.Kind.disc, dx, dy, disc, disc, c.fg, dimmed(tint));
            const ix = dx + (disc - icon) / 2, iy = dy + (disc - icon) / 2;
            const ink = dimmed(255);
            // A square outline from unit (x, y) to (x + side, y + side).
            void ring(int x, int y, int side)
            {
                const x0 = ix + at(x), y0 = iy + at(y);
                const w = at(x + side) - at(x), h = at(y + side) - at(y);
                put(FrameShape.Kind.fill, x0, y0, w, stroke, c.fg, ink);
                put(FrameShape.Kind.fill, x0, y0 + h - stroke, w, stroke, c.fg, ink);
                put(FrameShape.Kind.fill, x0, y0 + stroke, stroke, h - 2 * stroke, c.fg, ink);
                put(FrameShape.Kind.fill, x0 + w - stroke, y0 + stroke, stroke, h - 2 * stroke,
                    c.fg, ink);
            }
            final switch (part)
            {
                case FramePart.minimize:
                    // window-minimize-symbolic: an 8-unit bar, 10 units down.
                    put(FrameShape.Kind.fill, ix + at(4), iy + near(10), icon - 2 * at(4), stroke,
                        c.fg, ink);
                    break;
                case FramePart.maximize:
                    // window-maximize-symbolic: an 8 × 8 square outline.
                    if (!state.has(ToplevelState.maximized))
                    {
                        ring(4, 4, 8);
                        break;
                    }
                    // Restore: Adwaita 49's window-restore-symbolic is just
                    // a smaller square, too easily read as maximize, so
                    // this draws two overlapping windows — a 6 × 6 square
                    // in the box's lower left, and the top and right edges
                    // of one behind it, 2 units up and right, in half the
                    // ink.
                    ring(4, 6, 6);
                    const back = dimmed(128);
                    const bx0 = ix + at(6), by0 = iy + at(4), bw = at(12) - at(6);
                    put(FrameShape.Kind.fill, bx0, by0, bw, stroke, c.fg, back);
                    put(FrameShape.Kind.fill, bx0 + bw - stroke, by0 + stroke, stroke,
                        at(10) - at(4) - stroke, c.fg, back);
                    break;
                case FramePart.close:
                    put(FrameShape.Kind.cross, ix, iy, icon, icon, c.fg, ink);
                    break;
                case FramePart.content:
                case FramePart.title:
                case FramePart.resize:
                case FramePart.outside:
                    break;
            }
        }

        const x0 = g.left, y0 = g.margin, w = g.width, h = g.bottom - g.margin;
        const radius = radiusPx(g);
        enum white = RgbColor(0xff, 0xff, 0xff), black = RgbColor(0, 0, 0);
        // What the content and the bar drew beyond the window's rounded
        // corners goes, so the desktop shows there.
        if (radius > 0)
            put(FrameShape.Kind.erase, x0, y0, w, h, black, 0, radius);
        // The window's outline, a light pixel inside its edge, while it
        // floats: rgb(255 255 255 / 7%). A maximized or tiled window has none.
        enum ubyte outline = 18;
        if (!state.edgesHeld && g.margin > 0)
            put(FrameShape.Kind.shadow, x0 + 1, y0 + 1, w - 2, h - 2, white, outline,
                radius > 1 ? radius - 1 : 0, 0, 1);
        else if (!state.edgesHeld)
        {
            put(FrameShape.Kind.fill, x0, y0, w, 1, white, outline);
            put(FrameShape.Kind.fill, x0, y0 + h - 1, w, 1, white, outline);
            put(FrameShape.Kind.fill, x0, y0 + 1, 1, h - 2, white, outline);
            put(FrameShape.Kind.fill, x0 + w - 1, y0 + 1, 1, h - 2, white, outline);
        }
        // Adwaita's window shadow, in the margin: `box-shadow: 0 0 14px 5px
        // rgb(0 0 0 / 15%), 0 0 5px 2px rgb(0 0 0 / 10%), 0 0 0 1px
        // rgb(0 0 0 / 5%)`; inactive, `0 0 10px 5px rgb(0 0 0 / 8%)` and the
        // ring. Tiled, a ring of the foreground at 15% (`$border_color`).
        if (g.margin > 0)
        {
            float px(float css) => css * g.density;
            if (state.edgesHeld)
                put(FrameShape.Kind.shadow, x0, y0, w, h, c.fg, 38, 0, 0, px(1));
            else
            {
                if (backdrop)
                    put(FrameShape.Kind.shadow, x0, y0, w, h, black, 20, radius, px(10), px(5));
                else
                {
                    put(FrameShape.Kind.shadow, x0, y0, w, h, black, 38, radius, px(14), px(5));
                    put(FrameShape.Kind.shadow, x0, y0, w, h, black, 26, radius, px(5), px(2));
                }
                put(FrameShape.Kind.shadow, x0, y0, w, h, black, 13, radius, 0, px(1));
            }
        }
        return n;
    }

    /// The window inside its margin, in device pixels from the surface's
    /// corner: what the host fills with the window's ground before the
    /// content, on a surface that starts transparent.
    void windowBox(in FrameGeometry g, out int x, out int y, out int w, out int h) const
    {
        x = g.left;
        y = g.margin;
        w = g.width;
        h = g.bottom - g.margin;
    }

    /// The widest title the bar holds, in device pixels: centred, and clear
    /// of the buttons by `titleGapCss` on either side.
    int titleRoom(in FrameGeometry g) const
    {
        if (!active)
            return 0;
        size_t count;
        cast(void) buttons(count);
        int bx, by, side;
        buttonBox(count - 1, g, bx, by, side);
        const keep = g.right - bx + densityPx(titleGapCss, g.density);
        const room = g.width - 2 * keep;
        return room > 0 ? room : 0;
    }

    /// Where a title `width` × `height` device pixels is drawn: centred on
    /// the bar, at half strength while the window is inactive.
    FrameTitle titleAt(int width, int height, in FrameGeometry g, in FrameColours c) const
    {
        const backdrop = !state.has(ToplevelState.activated);
        return FrameTitle(g.left + (g.width - width) / 2, g.top + (barPx(g.density) - height) / 2,
            c.fg, backdrop ? 128 : 255);
    }
}

/// A width and a height, in device pixels.
struct Size2
{
    int width, height; ///
}

/**
How much of the pixel at (`x`, `y`) of a `size`-pixel icon box close's cross
covers, 0 to 255: Adwaita's window-close-symbolic, two strokes of one unit
either side of the diagonals of the box's middle 8 × 8 units, sampled 4 × 4
per pixel. Symmetric under every flip of the box, so the cross is centred
wherever the box is.
*/
ubyte crossCoverage(int size, int x, int y) @safe pure nothrow @nogc
{
    if (size <= 0 || x < 0 || y < 0 || x >= size || y >= size)
        return 0;
    int hits;
    foreach (sy; 0 .. 4)
        foreach (sx; 0 .. 4)
        {
            const u = (x + (sx + 0.5f) / 4) * 16 / size, v = (y + (sy + 0.5f) / 4) * 16 / size;
            if (u < 4 || u > 12 || v < 4 || v > 12)
                continue;
            const d1 = u - v, d2 = u + v - 16;
            if ((d1 >= -1 && d1 <= 1) || (d2 >= -1 && d2 <= 1))
                ++hits;
        }
    return cast(ubyte)(hits * 255 / 16);
}

private int luma(RgbColor c) @safe pure nothrow @nogc
    => (c.r * 299 + c.g * 587 + c.b * 114) / 1000;

version (unittest)
{
    // A 800×600 surface at density 1, of 10×20 cells.
    private enum FrameGeometry geometry = FrameGeometry(surfaceW: 800, surfaceH: 600,
        top: 0, cellW: 10, cellH: 20, density: 1);

    private ClientFrame clientFrame(ubyte capabilities = WindowCapability.all, ushort flags = 0)
        @safe pure nothrow @nogc
    {
        ClientFrame f;
        f.state = WindowState(decorations: DecorationMode.client,
            capabilities: capabilities, flags: flags);
        return f;
    }
}

@("ui_app.client_frame.serverFramesAreNotDrawn")
@safe pure nothrow @nogc
unittest
{
    ClientFrame f;
    assert(!f.active && f.barPx(1) == 0 && f.minimumPx(20, 1) == Size2.init);
    assert(f.hitTest(400, 5, geometry).part == FramePart.content);
    FrameShape[ClientFrame.maxShapes] shapes;
    assert(f.build(shapes[], geometry, FrameColours.init) == 0);
    f = clientFrame(flags: ToplevelState.fullscreen);
    assert(!f.active, "a fullscreen window has no frame");
}

@("ui_app.client_frame.hitTestFindsEdgesButtonsAndTitle")
@safe pure nothrow @nogc
unittest
{
    auto f = clientFrame();
    assert(f.barPx(1) == 46 && f.barPx(2) == 92);
    assert(f.hitTest(2, 2, geometry) == FrameHit(FramePart.resize, ResizeEdge.topLeft));
    assert(f.hitTest(797, 597, geometry) == FrameHit(FramePart.resize, ResizeEdge.bottomRight));
    assert(f.hitTest(400, 3, geometry) == FrameHit(FramePart.resize, ResizeEdge.top));
    assert(f.hitTest(400, 20, geometry).part == FramePart.title);
    // Right to left, 34 px each, 3 apart, 7 from the edge, 6 down:
    // close 759–792, maximize 722–755, minimize 685–718.
    assert(f.hitTest(776, 23, geometry).part == FramePart.close);
    assert(f.hitTest(759, 6, geometry).part == FramePart.close);
    assert(f.hitTest(793, 23, geometry).part == FramePart.title, "the padding is the title's");
    assert(f.hitTest(757, 23, geometry).part == FramePart.title, "and so is the spacing");
    assert(f.hitTest(740, 23, geometry).part == FramePart.maximize);
    assert(f.hitTest(700, 23, geometry).part == FramePart.minimize);
    assert(f.hitTest(684, 23, geometry).part == FramePart.title);
    assert(f.hitTest(400, 46, geometry).part == FramePart.content, "below the bar");
}

@("ui_app.client_frame.buttonsFollowTheOfferedControls")
@safe pure nothrow @nogc
unittest
{
    auto f = clientFrame(capabilities: WindowCapability.minimize);
    assert(f.hitTest(776, 23, geometry).part == FramePart.close);
    assert(f.hitTest(740, 23, geometry).part == FramePart.minimize, "no maximize offered");
    assert(f.hitTest(700, 23, geometry).part == FramePart.title);
}

@("ui_app.client_frame.heldEdgesHaveNoGrips")
@safe pure nothrow @nogc
unittest
{
    auto f = clientFrame(flags: ToplevelState.maximized);
    assert(f.gripPx(1) == 0);
    assert(f.hitTest(2, 2, geometry).part == FramePart.title);
    f = clientFrame(flags: ToplevelState.tiledLeft);
    assert(f.hitTest(2, 300, geometry).part == FramePart.content);
}

@("ui_app.client_frame.titlePressesMoveAndDoubleClickMaximizes")
@safe pure nothrow @nogc
unittest
{
    auto f = clientFrame();
    const title = FrameHit(FramePart.title);
    const t0 = MonoTime.zero + 10_000.msecs;
    // A press only arms the move; travel starts it, and a still pointer never does.
    assert(f.press(title, false, t0, 100, 10) == FrameAction.none);
    assert(f.holding);
    assert(f.motion(103, 12, 1) == FrameAction.none, "within the threshold");
    assert(f.motion(110, 12, 1) == FrameAction.move);
    assert(!f.holding && f.motion(130, 12, 1) == FrameAction.none, "one move per press");
    f.release(title);
    // Two quick presses toggle maximized, with no move in between to take
    // the pointer away from the second.
    assert(f.press(title, false, t0 + 1_000.msecs, 100, 10) == FrameAction.none);
    f.release(title);
    assert(f.press(title, false, t0 + 1_200.msecs, 100, 10) == FrameAction.toggleMaximized);
    assert(!f.holding, "the second press arms nothing");
    assert(f.press(title, false, t0 + 1_300.msecs) == FrameAction.none, "a third press starts again");
    assert(f.press(title, true, t0) == FrameAction.windowMenu);
    f = clientFrame(capabilities: WindowCapability.maximize);
    assert(f.press(title, true, t0) == FrameAction.none, "no window menu offered");
    assert(f.press(FrameHit(FramePart.resize, ResizeEdge.left), false, t0) == FrameAction.resize);
}

@("ui_app.client_frame.buttonsActOnTheirOwnRelease")
@safe pure nothrow @nogc
unittest
{
    auto f = clientFrame();
    const now = MonoTime.zero + 1.msecs;
    assert(f.press(FrameHit(FramePart.close), false, now) == FrameAction.none);
    assert(f.holding);
    assert(f.release(FrameHit(FramePart.close)) == FrameAction.close);
    assert(!f.holding);
    f.press(FrameHit(FramePart.maximize), false, now);
    assert(f.release(FrameHit(FramePart.title)) == FrameAction.none, "released elsewhere");
    f.press(FrameHit(FramePart.minimize), false, now);
    assert(f.release(FrameHit(FramePart.minimize)) == FrameAction.minimize);
}

@("ui_app.client_frame.everyIconIsCentredOnItsDisc")
@safe pure nothrow @nogc
unittest
{
    // The bug this replaced: a glyph cross a pixel right of its disc, and a
    // one-pixel minimize bar half a pixel above. Every density's discs and
    // icon pieces share a centre to the pixel.
    foreach (density; [1.0f, 1.25f, 1.5f, 1.75f, 2.0f, 2.5f, 3.0f])
    {
        foreach (flags; [ToplevelState.activated, ToplevelState.maximized])
        {
            auto f = clientFrame(flags: cast(ushort) flags);
            FrameShape[ClientFrame.maxShapes] shapes;
            FrameGeometry g = geometry;
            g.density = density;
            g.surfaceW = 1200;
            const n = f.build(shapes[], g, FrameColours.init);
            FrameShape disc;
            int[2] lo = [int.max, int.max], hi = [int.min, int.min];
            void check()
            {
                if (disc.kind != FrameShape.Kind.disc || lo[0] == int.max)
                    return; // none yet, or close's cross, checked as it comes
                assert(lo[0] - disc.x == disc.x + disc.w - hi[0], "centred across");
                if (hi[1] - lo[1] > 2 * densityPx(2, density))
                    assert(lo[1] - disc.y == disc.y + disc.h - hi[1], "centred down");
            }
            foreach (ref s; shapes[0 .. n])
            {
                if (s.kind == FrameShape.Kind.disc)
                {
                    check();
                    disc = s;
                    lo = [int.max, int.max];
                    hi = [int.min, int.min];
                    continue;
                }
                if (disc.kind != FrameShape.Kind.disc || s.x < disc.x || s.x >= disc.x + disc.w)
                    continue;
                if (s.kind == FrameShape.Kind.cross)
                {
                    assert(s.x - disc.x == disc.x + disc.w - (s.x + s.w), "the cross's box");
                    assert(s.y - disc.y == disc.y + disc.h - (s.y + s.h));
                    continue;
                }
                lo = [s.x < lo[0] ? s.x : lo[0], s.y < lo[1] ? s.y : lo[1]];
                hi = [s.x + s.w > hi[0] ? s.x + s.w : hi[0], s.y + s.h > hi[1] ? s.y + s.h : hi[1]];
            }
            check();
        }
    }
}

@("ui_app.client_frame.theCrossIsSymmetric")
@safe pure nothrow @nogc
unittest
{
    foreach (size; [15, 16, 20, 24, 32])
        foreach (y; 0 .. size)
            foreach (x; 0 .. size)
            {
                const c = crossCoverage(size, x, y);
                assert(c == crossCoverage(size, size - 1 - x, y));
                assert(c == crossCoverage(size, x, size - 1 - y));
                assert(c == crossCoverage(size, y, x));
            }
    // At 16 px the diagonals run through whole pixels, and the corners of
    // the box stay empty.
    assert(crossCoverage(16, 4, 4) == 255 && crossCoverage(16, 11, 4) == 255);
    assert(crossCoverage(16, 0, 0) == 0 && crossCoverage(16, 8, 3) == 0);
}

@("ui_app.client_frame.buttonsTintAndDimLikeAdwaita")
@safe pure nothrow @nogc
unittest
{
    FrameShape[ClientFrame.maxShapes] shapes;
    ubyte discAlpha(ref ClientFrame f, FramePart part)
    {
        const n = f.build(shapes[], geometry, FrameColours.init);
        // Discs right to left: close, maximize, minimize.
        size_t seen;
        const want = part == FramePart.close ? 0 : part == FramePart.maximize ? 1 : 2;
        foreach (ref s; shapes[0 .. n])
            if (s.kind == FrameShape.Kind.disc && seen++ == want)
                return s.alpha;
        assert(0);
    }
    auto f = clientFrame(flags: ToplevelState.activated);
    assert(discAlpha(f, FramePart.minimize) == 26, "10% at rest");
    f.hover = FramePart.close;
    assert(discAlpha(f, FramePart.close) == 38, "15% hovered, close too");
    f.pressed = FramePart.maximize;
    assert(discAlpha(f, FramePart.maximize) == 77, "30% pressed");
    f = clientFrame();
    assert(discAlpha(f, FramePart.minimize) == 13, "an inactive window's at half");
    const t = f.titleAt(120, 18, geometry, FrameColours.init);
    assert(t.alpha == 128 && t.x == (800 - 120) / 2 && t.y == 14);
}

@("ui_app.client_frame.restoreLooksUnlikeMaximize")
@safe pure nothrow @nogc
unittest
{
    FrameShape[ClientFrame.maxShapes] shapes;
    // The maximize button's icon strokes, in its 34 px box at 722–755.
    size_t strokes(ref ClientFrame f, ubyte alpha)
    {
        const n = f.build(shapes[], geometry, FrameColours.init);
        size_t count;
        foreach (ref s; shapes[0 .. n])
            if (s.kind == FrameShape.Kind.fill && s.x >= 722 && s.x + s.w <= 756 &&
                s.alpha == alpha)
                ++count;
        return count;
    }
    auto f = clientFrame(flags: ToplevelState.activated);
    assert(strokes(f, 255) == 4 && strokes(f, 128) == 0, "one square");
    f = clientFrame(flags: ToplevelState.activated | ToplevelState.maximized);
    assert(strokes(f, 255) == 4, "the front square");
    assert(strokes(f, 128) == 2, "the top and right edges of the one behind, dimmer");
}

@("ui_app.client_frame.theTitleKeepsClearOfTheButtons")
@safe pure nothrow @nogc
unittest
{
    auto f = clientFrame(flags: ToplevelState.activated);
    FrameGeometry g = geometry;
    g.surfaceW = 300;
    // 3 buttons: 7 + 3 × 34 + 2 × 3 + 6 = 121 px each side, 58 px between.
    assert(f.titleRoom(g) == 58);
    g.surfaceW = 240;
    assert(f.titleRoom(g) == 0);
    g.density = 2;
    g.surfaceW = 800;
    assert(f.titleRoom(g) == 800 - 2 * 242, "the room scales with the density");
    assert(f.minimumPx(20, 1) == Size2(242, 46 + 60));
    assert(!ClientFrame.init.titleRoom(g), "no frame, no title");
}

@("ui_app.client_frame.coloursAreTheApplicationsOrAdwaitas")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.term_color : Color;

    Palette none;
    auto c = FrameColours.of(none, RgbColor(0x11, 0x11, 0x1b));
    assert(c.bg == RgbColor(0x2e, 0x2e, 0x32) && c.fg == RgbColor(0xff, 0xff, 0xff) && c.dark);
    c = FrameColours.of(none, RgbColor(0xfa, 0xfa, 0xfb));
    assert(c.bg == RgbColor(0xff, 0xff, 0xff) && !c.dark, "a light window's light bar");
    Palette app;
    app.bg[Slot.chrome] = Color.fromRgb(RgbColor(0x18, 0x18, 0x25));
    app.fg[Slot.chrome] = Color.fromRgb(RgbColor(0xcd, 0xd6, 0xf4));
    c = FrameColours.of(app, RgbColor(0xfa, 0xfa, 0xfb));
    assert(c.bg == RgbColor(0x18, 0x18, 0x25) && c.fg == RgbColor(0xcd, 0xd6, 0xf4) && c.dark);
}

@("ui_app.client_frame.aButtonNotDrawnIsNotHit")
@safe pure nothrow @nogc unittest
{
    // A window narrower than its minimum (a tiled or small output may
    // configure one): minimize's box starts past the left edge, so it is not
    // drawn, and a press there is on the title, not on minimize.
    auto f = clientFrame();
    const g = FrameGeometry(surfaceW: 110, surfaceH: 200, cellW: 8, cellH: 16);
    FrameShape[ClientFrame.maxShapes] shapes;
    const n = f.build(shapes[], g, FrameColours.init);
    size_t discs;
    foreach (ref s; shapes[0 .. n])
        discs += s.kind == FrameShape.Kind.disc;
    assert(discs == 2, "close and maximize only");
    assert(f.hitTest(10, 23, g).part == FramePart.title);
    assert(f.hitTest(55, 23, g).part == FramePart.maximize);
}

@("ui_app.client_frame.aContentPressKeepsItsDragAndRelease")
@safe pure nothrow @nogc unittest
{
    // A selection started in the content and dragged up into the title bar:
    // its moves and its release are the application's, so it ends there.
    alias Phase = ClientFrame.Phase;
    auto f = clientFrame();
    assert(f.applicationOwns(Phase.pressed, 0, FramePart.content));
    assert(f.applicationOwns(Phase.moved, 0, FramePart.title));
    assert(f.applicationOwns(Phase.released, 0, FramePart.title));
    // Afterwards the frame has its events again.
    assert(!f.applicationOwns(Phase.moved, 0, FramePart.title));
    assert(!f.applicationOwns(Phase.pressed, 0, FramePart.close));
    // A second button pressed while one is down is the application's too,
    // and each release ends only its own press.
    assert(f.applicationOwns(Phase.pressed, 0, FramePart.content));
    assert(f.applicationOwns(Phase.pressed, 2, FramePart.title));
    assert(f.applicationOwns(Phase.released, 2, FramePart.title));
    assert(f.applicationOwns(Phase.moved, 0, FramePart.title));
    assert(f.applicationOwns(Phase.released, 0, FramePart.title));
    // A release whose press the frame took is not the application's.
    assert(!f.applicationOwns(Phase.released, 0, FramePart.close));
    // A release lost with the pointer (a broken grab) does not keep the
    // frame from answering.
    assert(f.applicationOwns(Phase.pressed, 0, FramePart.content));
    f.pointerLeft();
    assert(!f.applicationOwns(Phase.pressed, 0, FramePart.close));
}

@("ui_app.client_frame.theMarginResizesLikeGtk")
@safe pure nothrow @nogc unittest
{
    // A 760 × 560 window in a 20-pixel margin (an 800 × 600 surface) at
    // density 1: the 12 pixels round the window resize it, a corner reaching
    // 24 along each edge; the 8 beyond take no press; inside, there is no
    // grip, and the bar and buttons sit in the window, not the surface.
    auto f = clientFrame();
    const g = FrameGeometry(surfaceW: 800, surfaceH: 600, top: 20, cellW: 8, cellH: 16,
        margin: 20);
    alias Hit = FrameHit;
    assert(f.hitTest(5, 300, g) == Hit(FramePart.outside));
    assert(f.hitTest(10, 300, g) == Hit(FramePart.resize, ResizeEdge.left));
    assert(f.hitTest(19, 300, g) == Hit(FramePart.resize, ResizeEdge.left));
    assert(f.hitTest(785, 300, g) == Hit(FramePart.resize, ResizeEdge.right));
    assert(f.hitTest(400, 12, g) == Hit(FramePart.resize, ResizeEdge.top));
    assert(f.hitTest(400, 585, g) == Hit(FramePart.resize, ResizeEdge.bottom));
    // Corners: beside the window near its top, and above it near its side.
    assert(f.hitTest(12, 40, g) == Hit(FramePart.resize, ResizeEdge.topLeft));
    assert(f.hitTest(30, 12, g) == Hit(FramePart.resize, ResizeEdge.topLeft));
    assert(f.hitTest(770, 590, g) == Hit(FramePart.resize, ResizeEdge.bottomRight));
    assert(f.hitTest(50, 12, g) == Hit(FramePart.resize, ResizeEdge.top), "past the corner's reach");
    // Inside: the title from its very edge, and close inside the window's
    // right edge.
    assert(f.hitTest(21, 40, g) == Hit(FramePart.title));
    assert(f.hitTest(780 - 7 - 17, 20 + 6 + 17, g) == Hit(FramePart.close));
    assert(f.hitTest(400, 579, g) == Hit(FramePart.content), "no grip inside the window");
    // Tiled, the window cannot be resized from its margin.
    auto tiled = clientFrame(WindowCapability.all, ToplevelState.tiledLeft);
    assert(tiled.hitTest(10, 300, g) == Hit(FramePart.outside));

    // At density 2 every length doubles: a 40-pixel margin, 24 of it resizing,
    // corners 48 along each edge, and close 14 pixels inside the right edge.
    const g2 = FrameGeometry(surfaceW: 1600, surfaceH: 1200, top: 40, cellW: 16, cellH: 32,
        density: 2, margin: 40);
    assert(f.hitTest(10, 600, g2) == Hit(FramePart.outside));
    assert(f.hitTest(20, 600, g2) == Hit(FramePart.resize, ResizeEdge.left));
    assert(f.hitTest(20, 80, g2) == Hit(FramePart.resize, ResizeEdge.topLeft));
    assert(f.hitTest(100, 20, g2) == Hit(FramePart.resize, ResizeEdge.top));
    assert(f.hitTest(1560 - 14 - 34, 40 + 12 + 34, g2) == Hit(FramePart.close));
}

@("ui_app.client_frame.theMarginCastsAdwaitasShadow")
@safe pure nothrow @nogc unittest
{
    // Floating in a margin: the corners erased at the window's radius, the
    // outline a ring inside the window, and Adwaita's three shadows outside
    // it. Tiled: square, a ring of the foreground. Without a margin
    // (maximized, or no alpha): none of them.
    FrameShape[ClientFrame.maxShapes] shapes;
    size_t count(in FrameShape[] all, FrameShape.Kind kind)
    {
        size_t n;
        foreach (ref s; all)
            n += s.kind == kind;
        return n;
    }
    const g = FrameGeometry(surfaceW: 800, surfaceH: 600, top: 20, cellW: 8, cellH: 16,
        margin: 20);
    auto f = clientFrame(WindowCapability.all, ToplevelState.activated);
    auto n = f.build(shapes[], g, FrameColours.init);
    assert(count(shapes[0 .. n], FrameShape.Kind.erase) == 1);
    assert(count(shapes[0 .. n], FrameShape.Kind.shadow) == 1 + 3, "outline and three shadows");
    foreach (ref s; shapes[0 .. n])
    {
        if (s.kind == FrameShape.Kind.erase)
            assert(s.x == 20 && s.y == 20 && s.w == 760 && s.h == 560 && s.radius == 15);
        if (s.kind == FrameShape.Kind.shadow && s.blur == 14)
            assert(s.spread == 5 && s.alpha == 38 && s.radius == 15);
    }
    // Inactive: the wide shadow lightens and the second goes.
    f.state.flags = 0;
    n = f.build(shapes[], g, FrameColours.init);
    assert(count(shapes[0 .. n], FrameShape.Kind.shadow) == 1 + 2);
    // Tiled: square, a ring and no shadow.
    f.state.flags = ToplevelState.tiledRight | ToplevelState.activated;
    n = f.build(shapes[], g, FrameColours.init);
    assert(count(shapes[0 .. n], FrameShape.Kind.erase) == 0);
    assert(count(shapes[0 .. n], FrameShape.Kind.shadow) == 1);
    // No margin: the old square frame and its outline of fills.
    f.state.flags = ToplevelState.activated;
    n = f.build(shapes[], FrameGeometry(surfaceW: 800, surfaceH: 600, cellW: 8, cellH: 16),
        FrameColours.init);
    assert(count(shapes[0 .. n], FrameShape.Kind.erase) == 0
        && count(shapes[0 .. n], FrameShape.Kind.shadow) == 0);
    // The bar spans the window, not the surface.
    n = f.build(shapes[], g, FrameColours.init);
    assert(shapes[0].kind == FrameShape.Kind.fill && shapes[0].x == 20 && shapes[0].w == 760);
}

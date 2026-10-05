// The raylib adapter for `sparkles:ui` (`TGT6`).
//
// `RaylibCanvas` satisfies the `sparkles.ui.canvas.isCanvas` capability concept
// (fillRect / textRun / glyph / line / measure) by folding each primitive into a
// raylib draw call over the shared `FontSet`. It is the GPU backend of the
// `view() -> layout() -> buildDisplayList() -> paint(canvas)` pipeline: the pure
// model emits a cell-space `DrawOp[]`, and this canvas scales cells to pixels.
//
// Cell space -> pixels: a cell `(x, y)` maps to `(originX + x*cellW,
// originY + y*cellH)`. A caller renders a laid-out subtree (positioned from the
// origin) at an arbitrary screen position by setting `originX`/`originY` before
// `paint`. Colors come already-resolved on each `Visual` (fg/bg + alpha), so the
// canvas never consults a palette or theme — it only paints.
//
module sparkles.ui_raylib.raylib_canvas;

import raylib;

import sparkles.raylib_text : TextStyle, FontSet, drawText, uiCentreOffset, UiFonts;
import sparkles.base.buffer : SharedBuffer;
import sparkles.base.text.cstring : writeStringz;
import sparkles.base.term_style : TextAttr, UnderlineStyle;

import sparkles.ui.canvas : DrawOp, isCanvas, LineStyle, RuleEdge, Scrollbar,
    visualOf;
import sparkles.base.text.grapheme : visibleWidth;
import sparkles.ui.geometry : Insets, Point, Rect, Size;
import sparkles.base.term_color : RgbColor;
import sparkles.ui.image : fitRect, ImageFit, ImageHandle;
import sparkles.ui.image_raster : ImageRung, imageRungOf, paintImageRaster;
import sparkles.ui.interp.immediate : paintImagePlaceholder;
import sparkles.ui.effect : EffectId;
import sparkles.ui_raylib.effect_gpu : EffectGpu, scissorInTarget;
import sparkles.ui_raylib.image_textures : ImageTextures;
import sparkles.ui.state : scrollbarThumb;
import sparkles.ui.degradation : projectColor;
import sparkles.ui.glyphs : admits, projectGlyph;
import sparkles.ui.style : BorderStyle, FontRole, Shadow, Visual;
import sparkles.ui.style : UiTextStyle = TextStyle, TypeStep;
import sparkles.ui.tokens : TargetCapabilities;

/// The idle scrollbar rail thickness for a cell extent, in device pixels.
int railIdlePx(int cellExtent) @safe pure nothrow @nogc
{
    const third = cellExtent / 3;
    return third < 2 ? 2 : third;
}

/// The fully-expanded scrollbar rail thickness: exactly 1.5 glyph-cell widths,
/// including odd widths (integer multiply before divide is normative). Both
/// axes use the width so horizontal rails retain their compact GUI height.
int railExpandedPx(int cellWidth) @safe pure nothrow @nogc
    => cellWidth * 3 / 2;

/// The pixel backend's minimum grabbable scrollbar-handle length.
enum int scrollbarMinExtentPx = 24;

/// Pure, window-free resolved pixel geometry for one semantic scrollbar op.
struct ScrollbarRail
{
    Rect track;
    Rect thumb;
    bool live;
}

/**
Resolves a semantic scrollbar operation into pixel track/thumb geometry. The
op keeps content units and an expansion percentage; this backend alone chooses
pixel rail thickness and the 24px minimum grabbable thumb.
*/
ScrollbarRail scrollbarRail(in Scrollbar op, int cellW, int cellH,
    int originX = 0, int originY = 0,
    int minExtent = scrollbarMinExtentPx)
    @safe pure nothrow @nogc
{
    ScrollbarRail r;
    if (op.content <= op.viewport || op.content <= 0)
        return r;

    bool vertical;
    final switch (op.edge) with (RuleEdge)
    {
        case left: case right: case centerX:
            vertical = true;
            break;
        case top: case bottom: case centerY:
            vertical = false;
            break;
    }

    const x = originX + op.rect.x * cellW;
    const y = originY + op.rect.y * cellH;
    const w = op.rect.width * cellW;
    const h = op.rect.height * cellH;
    const idle = railIdlePx(vertical ? cellW : cellH);
    const expanded = railExpandedPx(cellW);
    const thickness = idle
        + (expanded - idle) * cast(int) op.expandPercent / 100;

    final switch (op.edge) with (RuleEdge)
    {
        case left:
            r.track = Rect(x, y, thickness, h);
            break;
        case right:
            r.track = Rect(x + w - thickness, y, thickness, h);
            break;
        case centerX:
            r.track = Rect(x + w / 2 - thickness / 2, y, thickness, h);
            break;
        case top:
            r.track = Rect(x, y, w, thickness);
            break;
        case bottom:
            r.track = Rect(x, y + h - thickness, w, thickness);
            break;
        case centerY:
            r.track = Rect(x, y + h / 2 - thickness / 2, w, thickness);
            break;
    }

    const track = vertical ? h : w;
    if (track <= 0 || thickness <= 0)
        return ScrollbarRail.init;
    const thumb = scrollbarThumb(op.content, op.viewport,
        op.offset, track, minExtent);
    r.thumb = vertical
        ? Rect(r.track.x, y + thumb.start, thickness, thumb.extent)
        : Rect(x + thumb.start, r.track.y, thumb.extent, thickness);
    r.live = true;
    return r;
}

/// A resolved `Visual`'s foreground as a raylib `Color` (with its alpha).
Color rlFg(in Visual v) pure nothrow @nogc @trusted
    => Color(v.fg.r, v.fg.g, v.fg.b, v.fgAlpha);

/// A resolved `Visual`'s background as a raylib `Color` (with its alpha).
Color rlBg(in Visual v) pure nothrow @nogc @trusted
    => Color(v.bg.r, v.bg.g, v.bg.b, v.bgAlpha);

/// The resolved box border as a raylib `Color` (edge color + fade alpha).
private Color rlBorder(in Visual v) pure nothrow @nogc @trusted
    => Color(v.border.color.r, v.border.color.g, v.border.color.b, v.border.alpha);

/// Maps a `Visual`'s packed `TextAttr` bits + underline into the raylib-text
/// `TextStyle` (real bold/italic faces, strike, underline). `FontRole`/`fontScale`
/// are HTML-honored; the fixed-size cell grid keeps mono at 1em (documented).
TextStyle rlTextStyle(in Visual v) pure nothrow @nogc @safe
{
    TextStyle t;
    if (v.styleBits & TextAttr.bold.bits)
        t.bits |= TextStyle.bold;
    if (v.styleBits & TextAttr.italic.bits)
        t.bits |= TextStyle.italic;
    if (v.styleBits & TextAttr.strikethrough.bits)
        t.bits |= TextStyle.strikethrough;
    if (v.underline != UnderlineStyle.none)
        t.bits |= TextStyle.underline;
    return t;
}

/**
What the raylib window declares (`CAP1`) — constants, because a window needs
no probing for what this canvas draws: every color, procedural box drawing and
the bundled font's block elements, the bundled Nerd Font's icons, and the chrome
a pixel target honours rather than projects — rounded rects, drop shadows,
alpha. What it does not draw yet stays off: link targets, styled underlines (a
`TextStyle` underline is straight), a scaled run (the grid keeps mono at 1em),
and sub-cell scrolling (design-system M9 turns those on). A proportional face
(`proportionalText`) is the host's: one that loads the interface faces into
`RaylibCanvas.uiFonts` turns it on (`GLY7`, `GLY10`).
Input is the mouse `RaylibEvents` synthesizes.
*/
enum TargetCapabilities raylibCapabilities = () {
    import sparkles.base.term_caps : BlockTier, ImageProtocol;
    import sparkles.base.term_color : ColorDepth;
    import sparkles.input.capability : mousePointer;

    TargetCapabilities c;
    c.colorDepth = ColorDepth.trueColor;
    c.unicode = true;
    c.blocks = BlockTier.half;
    c.nerdFont = true;
    c.radius = true;
    c.shadow = true;
    c.alpha = true;
    // A window draws the decoded pixels itself (`IMG`): the top of the
    // image order, so narrowing it to a protocol profile keeps real images
    // and narrowing it below one sends them down the cell ladder (`GLY9`).
    c.images = ImageProtocol.pixels;
    // The window system's own errands: the clipboard everywhere (a JNI
    // bridge on Android), the pointer shape where there is a pointer.
    c.clipboard = true;
    version (Android) {}
    else
        c.pointerShape = true;
    c.input = mousePointer;
    return c;
}();

/**
The raylib canvas: a `sparkles:ui` drawing backend over a `FontSet`. Cell
coordinates are scaled to pixels through `cellW`/`cellH` and offset by
`originX`/`originY` (move the origin between `paint` calls to place laid-out
subtrees anywhere on screen). Every method is `@system` (raylib is), so the
`sparkles:ui` interpreter instantiated against it infers `@system` — exactly the
attribute-by-canvas design the concept exists for.
*/
struct RaylibCanvas
{
    FontSet* fonts;            /// the glyph atlas + metrics (borrowed)
    SharedBuffer!(char, 4096)* buf; /// scratch for NUL-terminated draw strings
    int cellW;                 /// one cell's pixel width
    int cellH;                 /// one cell's pixel height
    float originX = 0;         /// pixel x of cell column 0
    float originY = 0;         /// pixel y of cell row 0
    /// The interface faces (design-system `GLY10`): `FontRole.ui` runs draw in
    /// them at their type step. Null or not `present`: they draw in the cell font.
    UiFonts* uiFonts;
    /// Device pixels per density-independent pixel. Corner radii, rounded
    /// outlines and shadows are CSS px (`TOK7`) and scale by it.
    float density = 1;

    /**
    What this canvas paints for (`CAP1`): $(LREF raylibCapabilities) unless a
    host narrowed it (`HostState.narrowTarget`) to preview a smaller target.
    Narrowed, it folds colors to the depth, squares corners and drops shadows
    the declaration lacks, and projects every glyph down its ladder (`GLY1`).
    Border strokes stay vector: a window has no box glyphs to fold.
    */
    TargetCapabilities capabilities = raylibCapabilities;

    // The visual as this target can show it.
    private Visual narrowed(in Visual v) const @safe pure nothrow @nogc
    {
        Visual n = v;
        const d = capabilities.colorDepth;
        n.fg = projectColor(v.fg, d, false);
        n.bg = projectColor(v.bg, d, true);
        n.border.color = projectColor(v.border.color, d, false);
        if (!capabilities.radius)
            n.borderRadius = 0;
        if (!capabilities.shadow)
            n.shadow = Shadow.init;
        return n;
    }

    // `text` as this target can show it: itself when every glyph is
    // admitted, else a copy with each glyph projected — a wide one that
    // folds fills both of its cells, as on the grid.
    private const(char)[] projected(return scope const(char)[] text) const
    {
        import sparkles.base.text.tokens : byUtfToken;
        import sparkles.base.text.utf : encodeScalar, UtfMode, UtfStatus;
        import sparkles.base.text.width : codepointWidth;

        bool all = true;
        foreach (token; byUtfToken(text, UtfMode.replacement))
            if (!admits(capabilities, token.scalar))
            {
                all = false;
                break;
            }
        if (all)
            return text;
        char[] r;
        foreach (token; byUtfToken(text, UtfMode.replacement))
        {
            const g = token.scalar;
            const p = projectGlyph(g, capabilities);
            char[4] enc;
            const encoded = encodeScalar(p, enc[]);
            if (encoded.status != UtfStatus.ok)
                throw new Exception("Invalid Unicode projected glyph");
            foreach (_; 0 .. (p != g && codepointWidth(g) == 2) ? 2 : 1)
                r ~= enc[0 .. encoded.written];
        }
        return r;
    }

    /// Uploaded images (borrowed), or `null`. Last, and defaulted, so the
    /// canvas's many positional construction sites are unaffected — and so a
    /// host that has not wired images up gets `IMG4`'s placeholder rather
    /// than a null dereference.
    ImageTextures* images;

    /// Compiled effect shaders and the per-bracket texture pool (borrowed), or
    /// `null`. Absent means every effect bracket degrades to unaffected —
    /// `EFX3`, the same answer a canvas with no primitive at all gives.
    EffectGpu* fx;

    private float px(int cx) const @safe pure nothrow @nogc => originX + cx * cellW;
    private float py(int cy) const @safe pure nothrow @nogc => originY + cy * cellH;

    /// The optional clipping pair of the canvas concept: a GL scissor per
    /// pushed rect (cell coordinates → pixels), stacked so nested viewports
    /// restore the enclosing one — widget content never bleeds past its rect.
    private Rect[] clips;

    void pushClip(in Rect r) scope @system
    {
        clips ~= r;
        applyScissor();
    }

    /// ditto
    void popClip() scope @system
    {
        if (clips.length)
            clips = clips[0 .. $ - 1];
        applyScissor();
    }

    /// Returns the accumulated geometric intersection of all active clips on the stack.
    package static Rect effectiveClip(scope const(Rect)[] clips) pure nothrow @nogc @safe
    {
        if (!clips.length)
            return Rect.init;
        Rect eff = clips[0];
        foreach (ref const c; clips[1 .. $])
        {
            eff = eff.intersection(c);
            if (eff.empty)
                break;
        }
        return eff;
    }

    private Rect effectiveClip() const pure nothrow @nogc @safe
        => effectiveClip(clips);

    private void applyScissor() scope @system
    {
        EndScissorMode();
        if (!clips.length)
            return;
        // Intersect across the clip stack so nested child clips (e.g. wide tables
        // or code blocks) stay strictly bounded by their enclosing viewports.
        const r = effectiveClip();
        // Inside an effect bracket the render target is not the screen, so its
        // size is what bounds the box and what Y is flipped against.
        const inTarget = fx !is null && fx.depth > 0
            ? fx.currentTargetHeight : 0;
        const boundW = inTarget > 0 ? fx.currentTargetWidth : GetScreenWidth();
        const boundH = inTarget > 0 ? inTarget : GetScreenHeight();

        ScissorBox box;
        if (!scissorBoxOf(r, originX, originY, cellW, cellH, boundW, boundH, box))
        {
            BeginScissorMode(0, 0, 0, 0);
            return;
        }
        if (inTarget > 0)
            scissorInTarget(box.x, box.y, box.w, box.h, inTarget);
        else
            BeginScissorMode(box.x, box.y, box.w, box.h);
    }

    /**
    Opens an effect bracket, rendering the subtree into its own texture
    (`EFX11`).

    Drawing continues in the same cell coordinates: the origin is shifted so
    the bracket's top-left cell lands at the texture's `(0, 0)`, and restored
    on `popEffect`. Everything the subtree emits — including its clips, which
    are in cell space — therefore needs no knowledge that it is being
    redirected.
    */
    void pushEffect(in Rect r, EffectId id) scope @system
    {
        if (fx is null)
            return; // `EFX3`: unaffected, and `popEffect` is a no-op to match

        const x = cast(int) px(r.x), y = cast(int) py(r.y);
        // Never larger than the surface it is drawn on. Nothing past the edge
        // is visible, and a bracket over a whole window — the CRT's, on the
        // root — then gets a texture EXACTLY the window's size even though
        // the window is rarely a whole number of cells: the partial cell at
        // the edge belongs to the bracket that reaches it. A canvas that
        // flips its scissor against the screen's height is right inside such
        // a bracket for the same reason.
        const surfaceW = fx.depth ? fx.currentTargetWidth : GetScreenWidth();
        const surfaceH = fx.depth ? fx.currentTargetHeight : GetScreenHeight();
        int w = r.width * cellW, h = r.height * cellH;
        if (surfaceW > 0 && x + w > surfaceW)
            w = surfaceW - x;
        if (surfaceH > 0 && y + h > surfaceH)
            h = surfaceH - y;
        if (fx.open(id, r, x, y, w, h))
        {
            savedOrigins ~= [originX, originY];
            originX = cast(float)(-r.x * cellW);
            originY = cast(float)(-r.y * cellH);
            applyScissor();
        }
    }

    /// ditto — composites the bracket back through its shader.
    void popEffect() scope @system
    {
        if (fx is null)
            return;
        // The position to composite at must be computed in the ENCLOSING
        // target's coordinates, so the origin is restored first.
        Rect r;
        const redirected = fx.peek(r);
        if (redirected && savedOrigins.length)
        {
            originX = savedOrigins[$ - 1][0];
            originY = savedOrigins[$ - 1][1];
            savedOrigins = savedOrigins[0 .. $ - 1];
        }
        fx.close(cast(int) px(r.x), cast(int) py(r.y));
        applyScissor();
    }

    private float[2][] savedOrigins;

    /**
    A flat fill in $(B pixels), for chrome that is genuinely not cell-aligned
    (`UIA7`).

    The rest of this canvas speaks cells, and that is the right unit for
    anything the layout engine positions. Some application chrome is not:
    a one-pixel pane divider, a hairline under a header bar, a band whose
    height is `cellH - 1`. Quantising those to cells would move them.

    So this exists to let an application stop naming raylib without changing
    what it paints — the `UIA7` boundary, not the `UIA2` one. Chrome that CAN
    be a widget should be: it then gets layout, hit-testing and theming for
    free, and this method is not involved. Treat a growing number of callers
    as a signal that a widget is missing.

    Coordinates are absolute window pixels; `originX`/`originY` do not apply,
    because a caller reaching for pixels already knows where it is.
    */
    void fillPixels(int x, int y, int w, int h, RgbColor c, ubyte a = 0xFF) @system
    {
        if (w <= 0 || h <= 0)
            return;
        DrawRectangle(x, y, w, h, Color(c.r, c.g, c.b, a));
    }

    /// Paints a box: drop shadow (behind), background fill (rounded when
    /// `borderRadius`), border (per-side, dotted/solid), and a popup arrow —
    /// each gated on the resolved `Visual`. A plain filled cell is the common
    /// fast path (no chrome ⇒ one `DrawRectangle`).
    void fillRect(in Rect r, in Visual visual) @system
    {
        const v = densityScaled(narrowed(visual));
        const x = px(r.x), y = py(r.y);
        const w = cast(float)(r.width * cellW), h = cast(float)(r.height * cellH);

        // Drop shadow first, behind the surface: an offset translucent rect.
        if (v.shadow.any)
        {
            const s = v.shadow;
            const sc = Color(s.color.r, s.color.g, s.color.b, s.alpha);
            const sr = Rectangle(x + s.dx - s.blur / 2.0f, y + s.dy,
                w + s.blur, h + s.blur / 2.0f);
            if (v.borderRadius > 0)
                DrawRectangleRounded(sr, roundnessOf(v.borderRadius, sr.width, sr.height), 8, sc);
            else
                DrawRectangleRec(sr, sc);
        }

        // Background fill.
        if (v.hasBg)
        {
            if (v.borderRadius > 0)
                DrawRectangleRounded(Rectangle(x, y, w, h),
                    roundnessOf(v.borderRadius, w, h), 8, rlBg(v));
            else
                DrawRectangle(cast(int) x, cast(int) y, r.width * cellW, r.height * cellH, rlBg(v));
        }

        // Border and popup arrow.
        if (v.border.any)
            drawBorder(x, y, w, h, v);
        if (v.arrow)
            drawArrow(x, y, v);
    }

    /**
    Draws the registered image `handle` into `r` under `fit` (`IMG1`).

    The optional raster primitive. Geometry is resolved in $(B pixels), not
    cells: the destination is the cell rect scaled up, and `fitRect` places the
    image inside it — so a `contain` letterbox lands on the pixel rather than
    snapping to a cell boundary. The arithmetic is the toolkit's, shared with
    every other target, because "contain" meaning two different things in the
    window and the terminal is the sort of difference nothing catches.

    With no cache attached, an unregistered handle, or an image with no pixels,
    this falls through to the same `IMG4` placeholder a canvas without the
    primitive would get. Degrading identically is the point; a GPU backend
    silently drawing nothing would be the one case `IMG4` does not cover.

    Narrowed below its own pixels — previewing `enhanced`, or a terminal
    preset — the window draws what that target would (`GLY9`): the picture
    rastered in cells by the same routine the terminal uses, at this window's
    real cell size, or the alt text where the target has no cell rung.
    */
    void image(in Rect r, ImageHandle handle, ImageFit fit,
        scope const(char)[] alt, in Visual v) @system
    {
        const rung = imageRungOf(capabilities);
        if (rung != ImageRung.native)
        {
            const data = images is null ? null : images.lookup(handle);
            if (rung == ImageRung.alt || data is null || data.rgba.length == 0)
                paintImagePlaceholder(this, r, alt, v);
            else
                paintImageRaster(this, r, *data, fit, rung, Size(cellW, cellH),
                    v.hasBg ? v.bg : RgbColor(0, 0, 0));
            return;
        }

        Texture2D* tex = images is null ? null : images.resolve(handle);
        if (tex is null)
        {
            paintImagePlaceholder(this, r, alt, v);
            return;
        }

        const dest = Rect(cast(int) px(r.x), cast(int) py(r.y),
            r.width * cellW, r.height * cellH);
        const placed = fitRect(dest, Size(tex.width, tex.height), fit);

        // `cover` overflows its box by design, so it is clipped to it —
        // through the clip STACK rather than a bare scissor, so an image
        // inside a scrolled viewport stays inside that viewport too.
        const clipped = fit == ImageFit.cover;
        if (clipped)
            pushClip(r);
        DrawTexturePro(*tex,
            Rectangle(0, 0, cast(float) tex.width, cast(float) tex.height),
            Rectangle(cast(float) placed.x, cast(float) placed.y,
                cast(float) placed.width, cast(float) placed.height),
            Vector2(0, 0), 0.0f, Color(255, 255, 255, v.fgAlpha));
        if (clipped)
            popClip();
    }

    /// Draws `text` at `at`, selecting the real bold/italic/strike/underline face
    /// from the resolved `Visual`.
    void textRun(in Point at, scope const(char)[] text, in Visual visual) @system
    {
        const v = narrowed(visual);
        drawText(*fonts, cstr(projected(text)), px(at.x), py(at.y), rlTextStyle(v), rlFg(v));
    }

    /**
    Draws `text` in its cell rect `r`. An interface run (`FontRole.ui`) draws in
    the interface face at its type step, centred down the rows the layout gave
    it (design-system `GLY10`); the layout measured it with $(LREF GuiMeasure),
    so it fits the rect's width. Any other run is `textRun` at the rect's origin.
    */
    void textRunIn(in Rect r, scope const(char)[] text, in Visual visual) @system
    {
        if (!drawsUiFace(visual))
            return textRun(r.origin, text, visual);
        const v = narrowed(visual);
        const step = cast(size_t) uiStepOf(v.fontRole, v.typeStep, v.fontScale);
        const bold = (v.styleBits & TextAttr.bold.bits) != 0;
        const dy = uiCentreOffset(uiFonts.lineHeight(step), r.height, cellH);
        uiFonts.draw(step, bold, projected(text), px(r.x), py(r.y) + dy, rlFg(v));
    }

    /// `v` with its corner radius and shadow in device pixels: they are CSS px
    /// (`TOK7`), so a 16 px pill radius is 16 dp — 44 device pixels on a
    /// 440 dpi phone, not the 6 dp a raw 16 would be there.
    private Visual densityScaled(in Visual v) const @safe pure nothrow @nogc
    {
        static int dp(int px, float density) @safe pure nothrow @nogc
            => cast(int)(px * density + (px >= 0 ? 0.5f : -0.5f));

        Visual s = v;
        if (density == 1)
            return s;
        s.borderRadius = dp(v.borderRadius, density);
        s.shadow.dx = dp(v.shadow.dx, density);
        s.shadow.dy = dp(v.shadow.dy, density);
        s.shadow.blur = dp(v.shadow.blur, density);
        return s;
    }

    /// Whether `v` is an interface run this canvas draws in the interface face.
    private bool drawsUiFace(in Visual v) const @safe pure nothrow @nogc
        => uiStepOf(v.fontRole, v.typeStep, v.fontScale) >= 0
            && uiFonts !is null && uiFonts.present && capabilities.proportionalText;

    /// Draws a single glyph `g` at `at` in `v.fg` (with its face).
    void glyph(in Point at, dchar glyph, in Visual visual) @system
    {
        import sparkles.base.text.utf : encodeScalar, UtfStatus;

        const v = narrowed(visual);
        char[4] enc;
        const encoded = encodeScalar(projectGlyph(glyph, capabilities), enc[]);
        if (encoded.status != UtfStatus.ok)
            throw new Exception("Invalid Unicode projected glyph");
        const n = encoded.written;
        drawText(*fonts, cstr(enc[0 .. n]), px(at.x), py(at.y), rlTextStyle(v), rlFg(v));
    }

    /// Strokes `from` -> `to` in `v.fg`. A `wavy` line is the twoslash error
    /// squiggle along the cell's baseline; a `solid` line is a 1px rule.
    /**
    A sub-cell hairline along an edge of `rect` (`UIA2`).

    The optional canvas primitive a pixel target can honour exactly: the
    toolkit names an edge, and this draws the thinnest rule the display
    has there — one device pixel — instead of quantising to a whole cell,
    which for a pane divider or a header underline is the difference
    between chrome and a stripe. Canvases without this get the cell-aligned
    line along the same edge.
    */
    void rule(in Rect rect, RuleEdge edge, in Visual visual) @system
    {
        const v = narrowed(visual);
        const x0 = cast(int) px(rect.x);
        const y0 = cast(int) py(rect.y);
        const w = cast(int)(rect.width * cellW);
        const h = cast(int)(rect.height * cellH);
        const c = v.fg;
        const a = v.fgAlpha;
        final switch (edge) with (RuleEdge)
        {
            case top:     fillPixels(x0, y0, w, 1, c, a); break;
            case bottom:  fillPixels(x0, y0 + h - 1, w, 1, c, a); break;
            case left:    fillPixels(x0, y0, 1, h, c, a); break;
            case right:   fillPixels(x0 + w - 1, y0, 1, h, c, a); break;
            case centerX: fillPixels(x0 + w / 2, y0, 1, h, c, a); break;
            case centerY: fillPixels(x0, y0 + h / 2, w, 1, c, a); break;
        }
    }

    /// The hairline an owned track shows while idle — `rule`'s geometry, in
    /// the track's own colour, so a bar mounted on a border is indistinguishable
    /// from the border when nothing is hovering it.
    private void idleRule(in Scrollbar op) @system
    {
        const x0 = cast(int) px(op.rect.x);
        const y0 = cast(int) py(op.rect.y);
        const w = cast(int)(op.rect.width * cellW);
        const h = cast(int)(op.rect.height * cellH);
        const c = op.trackColor;
        const a = op.trackAlpha;
        final switch (op.edge) with (RuleEdge)
        {
            case top:     fillPixels(x0, y0, w, 1, c, a); break;
            case bottom:  fillPixels(x0, y0 + h - 1, w, 1, c, a); break;
            case left:    fillPixels(x0, y0, 1, h, c, a); break;
            case right:   fillPixels(x0 + w - 1, y0, 1, h, c, a); break;
            case centerX: fillPixels(x0 + w / 2, y0, 1, h, c, a); break;
            case centerY: fillPixels(x0, y0 + h / 2, w, 1, c, a); break;
        }
    }

    /// Draws the semantic scrollbar op with the backend's continuous px rail.
    void scrollbar(in Scrollbar original) @system
    {
        Scrollbar op = original;
        op.fg = projectColor(original.fg, capabilities.colorDepth, false);
        op.trackColor = projectColor(original.trackColor, capabilities.colorDepth, false);
        const r = scrollbarRail(op, cellW, cellH,
            cast(int) originX, cast(int) originY);
        if (!r.live)
            return;
        if (op.trackLit)
            DrawRectangle(r.track.x, r.track.y, r.track.width, r.track.height,
                Color(op.trackColor.r, op.trackColor.g, op.trackColor.b,
                    op.trackAlpha));
        else if (op.paintsIdleTrack)
            // A bar that owns its rule IS the border it sits on, so idle it
            // must look like one — a hairline on the same edge, at the weight
            // `drawBox` gives a light box-drawing arm (`BOX1`), which is what
            // `OpKind.rule` already paints. Filling the hover rail here
            // instead thickened every overflowing fence's bottom border from
            // 1px to cellH/3; the window A/B oracle caught it.
            idleRule(op);
        DrawRectangle(r.thumb.x, r.thumb.y, r.thumb.width, r.thumb.height,
            rlFg(visualOf(op)));
    }

    void line(in Point from, in Point to, in Visual visual, LineStyle style) @system
    {
        const v = narrowed(visual);
        const y0 = cast(int) py(from.y);
        const x0 = cast(int) px(from.x);
        const x1 = cast(int) px(to.x);
        const w = x1 - x0;
        if (style == LineStyle.wavy)
        {
            // Alternating 2px segments, one row above the cell bottom.
            const baseY = y0 + cellH - 2;
            for (int i = 0; i < w; i += 4)
            {
                const seg = i + 2 <= w ? 2 : w - i;
                DrawRectangle(x0 + i, baseY + (i / 2 % 2), seg, 1, rlFg(v));
            }
        }
        else
            DrawRectangle(x0, y0, w, 1, rlFg(v));
    }

    /// raylib's rounded-rect `roundness` (0..1 of the shorter half-side) for a
    /// px corner radius on a `w × h` box.
    private static float roundnessOf(int radiusPx, float w, float h) pure nothrow @nogc @safe
    {
        const half = (w < h ? w : h) / 2.0f;
        if (half <= 0)
            return 0;
        const rr = radiusPx / half;
        return rr > 1 ? 1 : rr;
    }

    /// Strokes the box border. A rounded box (`borderRadius > 0`) gets a uniform
    /// rounded outline; a square box strokes each present side, honoring the
    /// dotted/dashed style (the `.twoslash-hover` bottom underline is dotted).
    private void drawBorder(float x, float y, float w, float h, in Visual v) @system
    {
        const b = v.border;
        const c = rlBorder(v);
        if (v.borderRadius > 0)
        {
            const thick = maxSide(b.width) * density;
            DrawRectangleRoundedLinesEx(Rectangle(x, y, w, h),
                roundnessOf(v.borderRadius, w, h), 8, thick, c);
            return;
        }
        // Border widths are CELL-space weights; stroke thickness scales by
        // the same unit the procedural box glyphs use for their arms
        // (`drawBox`'s light stroke), so "1 wide" here matches a `│` and
        // "2 wide" a `┃` at any cell size. A solid vertical side centers in
        // its border COLUMN, where the cell backends put their `│` — and
        // where a glyph-composed corner row's `╭`/`╰` stems are, so the
        // fence chrome's edges meet (the quote bar gains the same parity).
        // Dotted/dashed accents straddle the rect edge instead.
        const md = cellW < cellH ? cellW : cellH;
        const unit = md / 14 < 1 ? 1.0f : cast(float)(md / 14);
        const boxed = b.style == BorderStyle.solid
            || b.style == BorderStyle.double_;
        const inset = boxed ? cellW / 2.0f : 0;
        // A solid box with a side the terminal draws as `│` is drawn as the
        // terminal draws it, horizontals too: `─` centred in its row, meeting
        // the `│`s at `┌┐└┘` (`┏┓┗┛` heavy) rather than overshooting them.
        // Without a vertical side there is no corner, and a bottom-only rule
        // keeps the edge the terminal's underline uses.
        const insetY = boxed
            && (b.width.left || b.width.right) ? cellH / 2.0f : 0;
        // The four rectangles come from `borderEdges`, which is pure and
        // tested. Computing them here is how the vertical pair ended up
        // passing the horizontal argument order — `len` and `thick` swap
        // meaning between the two axes, and a box whose left border drew as
        // a stripe across the box was invisible to every test in the
        // repository.
        if (b.style == BorderStyle.double_)
        {
            // `═║╔╗╚╝`: two nested boxes, each stroked like a solid one.
            foreach (e; doubleBorderEdges(x, y, w, h, b.width, unit, inset,
                    insetY))
                strokeEdge(e, BorderStyle.solid, c);
            return;
        }
        foreach (e; borderEdges(x, y, w, h, b.width, unit, inset, insetY))
            strokeEdge(e, b.style, c);
    }

    /// Strokes one edge, dashed for a dotted/dashed style, solid otherwise.
    /// Dashes run along the edge's own long axis, whichever that is.
    private void strokeEdge(in BorderEdge e, BorderStyle style, Color c) @system
    {
        if (e.empty)
            return;
        if (style != BorderStyle.dotted && style != BorderStyle.dashed)
            return DrawRectangle(cast(int) e.x, cast(int) e.y,
                cast(int) e.w, cast(int) e.h, c);

        const thick = e.horizontal ? e.h : e.w;
        const len = e.horizontal ? e.w : e.h;
        const dash = style == BorderStyle.dotted ? thick : thick * 3;
        const gap = style == BorderStyle.dotted ? thick : thick * 2;
        for (float p = 0; p < len; p += dash + gap)
        {
            const seg = (p + dash <= len) ? dash : (len - p);
            if (e.horizontal)
                DrawRectangle(cast(int)(e.x + p), cast(int) e.y,
                    cast(int) seg, cast(int) thick, c);
            else
                DrawRectangle(cast(int) e.x, cast(int)(e.y + p),
                    cast(int) thick, cast(int) seg, c);
        }
    }

    /// Draws the popup arrow/tail: a small upward triangle off the box's top edge
    /// at `arrowOffset` cells, filled with the surface color and outlined in the
    /// border color (approximating the CSS 6×6 rotated-square notch).
    private void drawArrow(float boxX, float boxY, in Visual v) @system
    {
        const asz = cellH / 3 < 4 ? 4.0f : cast(float)(cellH / 3);
        const cx = boxX + v.arrowOffset * cellW + cellW * 0.5f;
        const apex = Vector2(cx, boxY - asz);
        const left = Vector2(cx - asz, boxY + 1); // +1: overlap the border so the
        const right = Vector2(cx + asz, boxY + 1); // notch merges into the surface
        // Screen space is y-down, so apex→left→right is the counter-clockwise
        // winding raylib needs (apex→right→left is culled as a back face).
        if (v.hasBg)
            DrawTriangle(apex, left, right, rlBg(v));
        if (v.border.any)
        {
            const c = rlBorder(v);
            DrawLineEx(left, apex, 1, c);
            DrawLineEx(apex, right, 1, c);
        }
    }

    /// The greatest of an `Insets`' four sides (border outline thickness).
    private static float maxSide(in Insets i) pure nothrow @nogc @safe
    {
        int m = i.top;
        if (i.right > m)
            m = i.right;
        if (i.bottom > m)
            m = i.bottom;
        if (i.left > m)
            m = i.left;
        return m <= 0 ? 1 : cast(float) m;
    }

    /// The cell extent of a text run (height 1), from the owned terminalKitty
    /// `visibleWidth` profile shared with layout and clipping.
    Size measure(scope const(char)[] text) @system
        => Size(cast(int) visibleWidth(text), 1);

    /// NUL-terminates `s` in the scratch buffer for a raylib string draw.
    private const(char)[] cstr(scope const(char)[] s) @system
    {
        buf.clear();
        (*buf).writeStringz(s);
        return (*buf)[0 .. $ - 1];
    }
}

/**
The text measurer for a raylib window (`LAY5`, design-system `GLY10`): cell font
runs measure owned whole-grapheme cell advances, and an interface run (`FontRole.ui`)
measures in the interface face at its type step — its pixel width rounded up to
whole cells, and as many rows as one line of that step needs. Pass it to
`layout` and `buildDisplayList` so the layout, the display list and
`RaylibCanvas.textRunIn` agree on every run's extent.
*/
struct GuiMeasure
{
    UiFonts* uiFonts; /// the interface faces; null or absent: cell metrics only
    int cellW = 1;    /// one cell's width, in the faces' drawing units
    int cellH = 1;    /// one cell's height, in the same units
    /// Owned whole-cluster cell widths and additive glyph advances have
    /// non-decreasing prefixes. Arbitrary measurers must not inherit this.
    enum bool monotonePrefixes = true;

    /// Incremental complete-brush metrics: one glyph traversal, with the same
    /// floating-point addition order and final rounding as `width`.
    BrushMetrics brushMetrics(in UiTextStyle style) @safe nothrow @nogc
    {
        return BrushMetrics(usesUiFace(style) ? uiFonts : null,
            uiStepOf(style.fontRole, style.typeStep, style.fontScale), style.bold, cellW);
    }

    struct BrushMetrics
    {
        private UiFonts* fonts;
        private int step;
        private bool bold;
        private int cellWidth;
        private float pixels = 0;
        private int cells;

        /// Append exactly one or more complete owned graphemes, never a
        /// fragment of one; the cursor belongs to a single unchanged brush.
        int append(scope const(char)[] text) @safe nothrow @nogc
        {
            if (fonts is null)
            {
                cells += cast(int) visibleWidth(text);
                return cells;
            }
            () @trusted {
                fonts.appendWidth(cast(size_t) step, bold, text, pixels);
            }();
            return cellsCeil(pixels, cellWidth);
        }
    }

    /// The cell font's width of `s`.
    int width(scope const(char)[] s) const @safe pure nothrow @nogc
        => cast(int) visibleWidth(s);

    /// The width of `s` in `style`, in whole cells.
    int width(scope const(char)[] s, in UiTextStyle style) @safe nothrow @nogc
    {
        if (!usesUiFace(style))
            return cast(int) visibleWidth(s);
        const step = uiStepOf(style.fontRole, style.typeStep, style.fontScale);
        // The faces' advances live in raylib's glyph tables, which `UiFonts`
        // indexes through raw pointers; reading them changes nothing.
        const px = () @trusted {
            return uiFonts.width(cast(size_t) step, style.bold, s);
        }();
        return cellsCeil(px, cellW);
    }

    /// The rows one line in `style` occupies.
    int rows(in UiTextStyle style) const @safe pure nothrow @nogc
        => usesUiFace(style) ? cellsCeil(uiFonts.lineHeight(cast(size_t)
                uiStepOf(style.fontRole, style.typeStep, style.fontScale)), cellH) : 1;

    /// The image cell size, so `IMG2` images lay out as on the canvas.
    Size cellPixels() const @safe pure nothrow @nogc => Size(cellW, cellH);

    private bool usesUiFace(in UiTextStyle style) const @safe pure nothrow @nogc
        => uiStepOf(style.fontRole, style.typeStep, style.fontScale) >= 0
            && uiFonts !is null && uiFonts.present;
}

/**
The interface-face step a run draws at, or -1 for the cell font: an interface
run (`FontRole.ui`, `GLY10`) at its own step, and a docs run (`GLY7`) at body
size, or caption when it asks for less than 90 % of the cell font.
*/
int uiStepOf(FontRole role, TypeStep step, ushort fontScale) @safe pure nothrow @nogc
{
    switch (role)
    {
        case FontRole.ui:
            return step;
        case FontRole.docs:
            return fontScale < 90 ? TypeStep.caption : TypeStep.body;
        default:
            return -1;
    }
}

@("uiRaylib.uiStepOf")
@safe pure nothrow @nogc
unittest
{
    assert(uiStepOf(FontRole.ui, TypeStep.title, 100) == TypeStep.title);
    assert(uiStepOf(FontRole.docs, TypeStep.body, 80) == TypeStep.caption);
    assert(uiStepOf(FontRole.docs, TypeStep.body, 100) == TypeStep.body);
    assert(uiStepOf(FontRole.code, TypeStep.title, 100) == -1);
    assert(uiStepOf(FontRole.inherit, TypeStep.body, 100) == -1);
}

/// `px` in whole cells of `cell`, rounded up; at least one cell for any ink.
int cellsCeil(float px, int cell) @safe pure nothrow @nogc
{
    if (px <= 0 || cell <= 0)
        return 0;
    const n = cast(int)(px / cell);
    return n * cell < px ? n + 1 : n;
}

@("uiRaylib.guiMeasure.cellsCeil")
@safe pure nothrow @nogc
unittest
{
    assert(cellsCeil(0, 8) == 0);
    assert(cellsCeil(8, 8) == 1);
    assert(cellsCeil(8.01f, 8) == 2);
    assert(cellsCeil(23, 17) == 2);
    assert(cellsCeil(5, 0) == 0);
}

@("uiRaylib.guiMeasure.withoutFacesIsTheCellMeasure")
@system unittest
{
    import sparkles.ui.layout : isStyledTextMeasure;
    import sparkles.ui.style : TypeStep;

    static assert(isStyledTextMeasure!GuiMeasure);
    GuiMeasure m = { cellW: 8, cellH: 17 };
    const title = UiTextStyle(fontRole: FontRole.ui, typeStep: TypeStep.title);
    assert(m.width("Logs", title) == 4 && m.rows(title) == 1,
        "no interface face loaded: the run keeps the cell font's extent");

    // And it drives the layout and the display list end to end.
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : Palette;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "Logs", textStyle: title));
    auto tree = b.finish(t);
    const frames = layout(tree, Constraints.init, m);
    assert(frames[t].rect.width == 4 && frames[t].lineRows == 1);
    auto ops = buildDisplayList(tree, frames, Palette.init, RgbColor.init,
        RgbColor.init, m);
    assert(ops.length == 1);
}

@("uiRaylib.densityScaled.chromeInDeviceMetrics")
@system unittest
{
    Visual v;
    v.borderRadius = 16;
    v.shadow.dx = 0;
    v.shadow.dy = 4;
    v.shadow.blur = 12;
    RaylibCanvas c;
    assert(c.densityScaled(v) == v, "density 1: as authored");
    c.density = 2.75f; // 440 dpi
    const s = c.densityScaled(v);
    assert(s.borderRadius == 44 && s.shadow.dy == 11 && s.shadow.blur == 33);
}

@("uiRaylib.scrollbarRail.metricsAndOddCells")
@safe pure nothrow @nogc
unittest
{
    assert(railIdlePx(5) == 2);
    assert(railIdlePx(21) == 7);
    assert(railExpandedPx(5) == 7);  // not cast(int)(5 * 1.5f) by accident
    assert(railExpandedPx(21) == 31);

    Scrollbar op = {
        rect: Rect(2, 1, 10, 20),
        content: 400,
        viewport: 100,
        expandPercent: 0,
        edge: RuleEdge.right,
    };
    const idle = scrollbarRail(op, 5, 7);
    assert(idle.live && idle.track == Rect(58, 7, 2, 140));
    assert(idle.thumb == Rect(58, 7, 2, 35));

    op.expandPercent = 100;
    const expanded = scrollbarRail(op, 5, 7);
    assert(expanded.track == Rect(53, 7, 7, 140));
    op.expandPercent = 50;
    const middle = scrollbarRail(op, 5, 7);
    assert(middle.track.width >= idle.track.width);
    assert(middle.track.width <= expanded.track.width);

    op.offset = 300;
    const bottom = scrollbarRail(op, 5, 7);
    assert(bottom.thumb.y + bottom.thumb.height
        == bottom.track.y + bottom.track.height);

    op.edge = RuleEdge.bottom;
    op.rect = Rect(1, 2, 20, 3);
    op.content = 200;
    op.viewport = 100;
    op.offset = 100;
    op.expandPercent = 100;
    const horizontal = scrollbarRail(op, 5, 7);
    assert(horizontal.track.height == railExpandedPx(5));
    assert(horizontal.thumb.x + horizontal.thumb.width
        == horizontal.track.x + horizontal.track.width);

    // Horizontal bars historically expand to 1.5 glyph widths, not 1.5 row
    // heights. The distinction is substantial for a typical tall font cell.
    const compactHorizontal = scrollbarRail(op, 9, 21);
    assert(compactHorizontal.track.height == 13);
}

// The raylib canvas must satisfy the ui capability concept, or the shared
// `paint` interpreter won't accept it.
static assert(isCanvas!RaylibCanvas);

// ---------------------------------------------------------------------------
// Border geometry — pure, so it is testable without a GL context.
// ---------------------------------------------------------------------------

/// One stroked edge of a box border, as a device-pixel rectangle.
struct BorderEdge
{
    float x; ///
    float y; ///
    float w; ///
    float h; ///

@safe pure nothrow @nogc:

    /// `true` iff the edge covers no pixels — a side of zero width.
    bool empty() const => w <= 0 || h <= 0;

    /// `true` for the top and bottom edges: the ones whose long axis is x.
    /// Dashes run along the long axis, so this is what tells them which way.
    bool horizontal() const => w >= h;
}

/**
The four edges of a square border, in device pixels.

$(B Extracted because it was wrong.) Inline, the two axes' rectangles were
written by hand from a `(length, thickness)` pair whose meaning swaps between
them — and the vertical pair was written in the horizontal order, so a box's
left border drew as a bar $(I across) the box and its right border as a bar
poking out to the right of it. Every backend-neutral test passed: the display
list was correct, the cell grid drew the box correctly, and the defect existed
only inside a `@system` function that needs a window to run.

Pure arithmetic in, four rectangles out, and the arithmetic has tests.

`unit` scales a side's cell-space weight into pixels of stroke thickness.
`inset` centres a vertical stroke that many pixels into its border column —
half a cell for a solid border, so the stroke lands where the cell backends
put their `│` and a glyph-composed corner's stem meets it; zero makes a
vertical stroke straddle the rect edge (the dotted/dashed accents).
*/
BorderEdge[4] borderEdges(float x, float y, float w, float h, in Insets width,
    float unit = 1, float inset = 0, float insetY = 0) @safe pure nothrow @nogc
{
    const t = width.top * unit;
    const b = width.bottom * unit;
    const l = width.left * unit;
    const r = width.right * unit;
    // Centre lines of the four strokes. With `insetY` the horizontals sit
    // in the middle of their rows, and every stroke runs between the centre
    // lines of the two it meets — so each corner is a `┌`, not a `┼` with
    // half a cell of overshoot on one arm.
    const cxL = x + inset;
    const cxR = x + w - inset;
    const cyT = y + insetY;
    const cyB = y + h - insetY;
    // A horizontal spans to a present vertical's outer face, else the rect.
    const hx0 = insetY > 0 && width.left ? cxL - l / 2 : x;
    const hx1 = insetY > 0 && width.right ? cxR + r / 2 : x + w;
    // A vertical spans to a present horizontal's outer face, else the rect.
    const vy0 = insetY > 0 && width.top ? cyT - t / 2 : y;
    const vy1 = insetY > 0 && width.bottom ? cyB + b / 2 : y + h;
    return [
        BorderEdge(hx0, insetY > 0 ? cyT - t / 2 : y, hx1 - hx0, t),      // top
        BorderEdge(hx0, insetY > 0 ? cyB - b / 2 : y + h - b, hx1 - hx0,
            b),                                                           // bottom
        BorderEdge(width.left ? cxL - l / 2 : x, vy0, l, vy1 - vy0),      // left
        BorderEdge(width.right ? cxR - r / 2 : x + w - r, vy0,
            r, vy1 - vy0),                                                // right
    ];
}

/**
The eight edges of a double border (`═║╔╗╚╝`), in device pixels: an outer and
an inner box, each laid out by `borderEdges`, so every corner is two nested
`┌`s — the outer stroke meeting the outer, the inner the inner.

Each stroke is as thick as a single border's, and the two sit `3t` apart
centre to centre (a gap of `2t`, where `t` is the thickest side), so they
stay distinct at every cell size and keep whole-pixel edges wherever a
single stroke has them.

In corner mode (`insetY > 0`, a vertical side present) the pair straddles
the single border's centre lines. Without a vertical side there is no
centre to straddle: the rules keep their edges and the second stroke steps
inward, as a double underline does.
*/
BorderEdge[8] doubleBorderEdges(float x, float y, float w, float h,
    in Insets width, float unit = 1, float inset = 0, float insetY = 0)
    @safe pure nothrow @nogc
{
    const m = width.top > width.bottom ? width.top : width.bottom;
    const n = width.left > width.right ? width.left : width.right;
    const t = (m > n ? m : n) * unit;
    BorderEdge[8] e;
    if (insetY > 0)
    {
        const s = 1.5f * t;
        e[0 .. 4] = borderEdges(x - s, y - s, w + 2 * s, h + 2 * s, width,
            unit, inset, insetY);
        e[4 .. 8] = borderEdges(x + s, y + s, w - 2 * s, h - 2 * s, width,
            unit, inset, insetY);
    }
    else
    {
        const g = 2 * t;
        e[0 .. 4] = borderEdges(x, y, w, h, width, unit, inset);
        e[4 .. 8] = borderEdges(x, y + g, w, h - 2 * g, width, unit, inset);
    }
    return e;
}

@("ui_raylib.raylib_canvas.doubleBorderEdgesNestTwoBoxes")
@safe pure nothrow @nogc
unittest
{
    // A double box in a window reads `╔═╗ ║ ╚═╝`, as it does in a terminal:
    // two strokes per side straddling the single border's centre line, and
    // each corner an outer `┌` around an inner one.
    enum x = 0.0f, y = 0.0f, w = 130.0f, h = 60.0f; // 13 x 3 cells of 10 x 20
    const e = doubleBorderEdges(x, y, w, h, Insets.all(1), unit: 1, inset: 5,
        insetY: 10);
    const outer = e[0 .. 4], inner = e[4 .. 8];

    // Top: the outer stroke above the row's centre, the inner below it, the
    // two a stroke-width gap apart (here 2px) and equally far from it.
    assert(outer[0] == BorderEdge(3, 8, 124, 1));
    assert(inner[0] == BorderEdge(6, 11, 118, 1));
    assert(inner[0].y - (outer[0].y + outer[0].h) == 2, "a visible gap");
    assert(10 - (outer[0].y + 0.5f) == (inner[0].y + 0.5f) - 10, "centred");
    // Left, the same across the column's centre.
    assert(outer[2] == BorderEdge(3, 8, 1, 44));
    assert(inner[2] == BorderEdge(6, 11, 1, 38));

    // Each box closes on itself: the arms meet at their outer faces.
    foreach (box; [outer, inner])
    {
        assert(box[0].x == box[2].x);
        assert(box[0].x + box[0].w == box[3].x + box[3].w);
        assert(box[2].y == box[0].y);
        assert(box[2].y + box[2].h == box[1].y + box[1].h);
    }
    // And the inner box lies wholly inside the outer one.
    assert(inner[0].x > outer[0].x && inner[1].y < outer[1].y);
    assert(inner[3].x < outer[3].x);
}

@("ui_raylib.raylib_canvas.doubleBorderEdgesWithoutASideStackInward")
@safe pure nothrow @nogc
unittest
{
    // A bottom-only double rule has no vertical to centre on: it keeps the
    // edge a single rule uses, and its second stroke sits above it.
    const e = doubleBorderEdges(0, 0, 40, 20, Insets(0, 0, 1, 0), unit: 1,
        inset: 5);
    assert(e[1] == BorderEdge(0, 19, 40, 1), "the rule keeps its edge");
    assert(e[5] == BorderEdge(0, 17, 40, 1), "and doubles inward");
    foreach (i; [0, 2, 3, 4, 6, 7])
        assert(e[i].empty, "absent sides stay absent in both boxes");
}

@("ui_raylib.raylib_canvas.borderEdgesMeetAtBoxDrawingCorners")
@safe pure nothrow @nogc
unittest
{
    // A solid box in a window must read as `┌─┐ │ └─┘`, as it does in a
    // terminal: each stroke centred in its cell row or column, and each
    // corner a meeting of two arms, with neither running past the other.
    enum x = 0.0f, y = 0.0f, w = 130.0f, h = 60.0f; // 13 x 3 cells of 10 x 20
    foreach (unit; [1.0f, 2.0f]) // light, then heavy
    {
        const e = borderEdges(x, y, w, h, Insets.all(1), unit, inset: 5,
            insetY: 10);
        // Centred: in the middle of the top/bottom rows, left/right columns.
        assert(e[0].y + e[0].h / 2 == 10 && e[1].y + e[1].h / 2 == 50);
        assert(e[2].x + e[2].w / 2 == 5 && e[3].x + e[3].w / 2 == 125);
        // Meeting: the horizontals end at the verticals' outer faces, and
        // the verticals at the horizontals' — no arm crosses a corner.
        assert(e[0].x == e[2].x && e[0].x + e[0].w == e[3].x + e[3].w);
        assert(e[2].y == e[0].y && e[2].y + e[2].h == e[1].y + e[1].h);
        assert(e[3].y == e[2].y && e[3].h == e[2].h);
    }

    // No vertical side (a bottom-only underline) keeps its edge placement.
    const u = borderEdges(x, y, w, h, Insets(0, 0, 1, 0), 1, inset: 5);
    assert(u[1] == BorderEdge(0, 59, 130, 1));
}

@("ui_raylib.raylib_canvas.borderEdgesStayNearTheBoxTheyBorder")
@safe pure nothrow @nogc
unittest
{
    // The bug, stated as a property: an edge never extends a box-length past
    // the box. The old vertical pair drew `h` pixels WIDE, so the right edge
    // started at the box's right and ran another box-height past it — which is
    // what a reader saw as stray horizontal lines beside every square-cornered
    // panel. (A vertical stroke MAY straddle the rect edge by half its own
    // thickness — that is the inset-0 accent geometry — so the bound is the
    // thickness, not zero.)
    enum x = 100.0f, y = 40.0f, w = 130.0f, h = 78.0f;
    foreach (e; borderEdges(x, y, w, h, Insets.all(1)))
    {
        assert(e.x >= x - e.w && e.x + e.w <= x + w + e.w,
            "an edge escaped sideways");
        assert(e.y >= y && e.y + e.h <= y + h, "an edge escaped vertically");
    }
}

@("ui_raylib.raylib_canvas.borderEdgesScaleAndCentreInTheirColumn")
@safe pure nothrow @nogc
unittest
{
    // The GPU border's two cell-parity rules, as arithmetic: `unit` scales a
    // side's cell weight into stroke pixels, and a solid vertical stroke
    // centres `inset` pixels into its border column — where the cell
    // backends put their `│` and where a glyph-composed corner's stem is.
    enum x = 0.0f, y = 0.0f, w = 40.0f, h = 20.0f;
    const e = borderEdges(x, y, w, h, Insets.all(1), unit: 2, inset: 5);

    assert(e[0].h == 2 && e[1].h == 2, "horizontal thickness scales by unit");
    assert(e[2].w == 2 && e[3].w == 2, "vertical thickness scales by unit");
    assert(e[2].x + e[2].w / 2 == x + 5, "left centres in its column");
    assert(e[3].x + e[3].w / 2 == x + w - 5, "right centres in its column");

    // Inset 0 — the dotted/dashed accents — straddles the rect edge instead.
    const a = borderEdges(x, y, w, h, Insets.all(1), unit: 2);
    assert(a[2].x + a[2].w / 2 == x && a[3].x + a[3].w / 2 == x + w);
}

@("ui_raylib.raylib_canvas.borderEdgesRunAlongTheirOwnAxis")
@safe pure nothrow @nogc
unittest
{
    enum x = 0.0f, y = 0.0f, w = 40.0f, h = 20.0f;
    const e = borderEdges(x, y, w, h, Insets(1, 2, 3, 4)); // top right bottom left

    // Horizontal edges span the width and are as thick as their own side.
    assert(e[0] == BorderEdge(0, 0, 40, 1), "top");
    assert(e[1] == BorderEdge(0, 17, 40, 3), "bottom");
    // Vertical edges span the HEIGHT and are as thick as their own side. This
    // is the assertion the swap failed: it produced (0, 0, 20, 4) — a bar four
    // pixels tall lying across the top of the box. (At inset 0 a vertical
    // stroke centres ON the rect edge, hence the half-thickness x shift.)
    assert(e[2] == BorderEdge(-2, 0, 4, 20), "left");
    assert(e[3] == BorderEdge(39, 0, 2, 20), "right");

    assert(e[0].horizontal && e[1].horizontal);
    assert(!e[2].horizontal && !e[3].horizontal);
}

@("ui_raylib.raylib_canvas.borderEdgesDropAbsentSides")
@safe pure nothrow @nogc
unittest
{
    // A bottom-only rule and a left accent bar are both real decorations
    // (`hoverUnderline`, the error accent). The sides they do not ask for must
    // draw nothing rather than a zero-thickness smear.
    const bottom = borderEdges(0, 0, 40, 20, Insets(0, 0, 1, 0));
    assert(bottom[0].empty && bottom[2].empty && bottom[3].empty);
    assert(!bottom[1].empty && bottom[1].horizontal);

    const accent = borderEdges(0, 0, 40, 20, Insets(0, 0, 0, 3));
    assert(accent[0].empty && accent[1].empty && accent[3].empty);
    assert(!accent[2].empty && !accent[2].horizontal,
        "a left accent is a vertical bar, not a horizontal one");
}

@("ui_raylib.raylib_canvas.borderEdgesOfADegenerateBox")
@safe pure nothrow @nogc
unittest
{
    // A one-pixel-tall box: no edge strays past its own thickness, and the
    // verticals are not mistaken for horizontals just because they are short.
    foreach (e; borderEdges(0, 0, 10, 1, Insets.all(1)))
    {
        assert(e.x >= -e.w && e.x + e.w <= 10 + e.w);
        assert(e.y >= 0 && e.y + e.h <= 1);
    }

    // Borders wider than the box do not invert it into negative geometry.
    foreach (e; borderEdges(0, 0, 2, 2, Insets.all(5)))
        assert(!e.empty || e.w <= 0 || e.h <= 0);
}

@("uiRaylib.capabilities.aWindowHonoursBoxChrome")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.tokens : capabilitiesOf, declaredCapabilities, Profile,
        subsetOf;

    // `CAP1`: the canvas declares, and the toolkit reads it by introspection.
    static assert(declaredCapabilities(RaylibCanvas.init) == raylibCapabilities);
    const c = raylibCapabilities;
    assert(c.radius && c.shadow && c.alpha, "the chrome a pixel target honours");
    assert(c.nerdFont, "the bundle ships FiraCode Nerd Font Mono");
    // Not a terminal profile: it draws what no terminal can, and lacks OSC 8.
    assert(!subsetOf(c, capabilitiesOf(Profile.full)));
    assert(!c.hyperlinks && !c.subCellScroll, "M9's, not yet honoured");
    // The window carries a copy and a pointer shape itself (`HST8`), so an
    // application asking the target whether a copy landed is told yes.
    assert(c.clipboard && c.pointerShape && !c.notifications);
}

@("uiRaylib.capabilities.narrowedPaintsLess")
@system unittest
{
    import sparkles.base.term_color : xterm256ToRgb;
    import sparkles.ui.tokens : capabilitiesOf, meet, Profile;

    // A window narrowed to a terminal profile previews what that terminal
    // would show: its colors, its corners, its glyphs.
    RaylibCanvas c;
    const v = Visual(fg: RgbColor(0x12, 0x34, 0x56), bg: RgbColor(0x20, 0x20, 0x30),
        hasBg: true, borderRadius: 6, shadow: Shadow(dy: 2, alpha: 0x80));
    assert(c.narrowed(v) == v, "undeclared-narrow: as authored");
    assert(c.projected("✔ ⣿") == "✔ ⣿" || !c.capabilities.braille);

    c.capabilities = meet(raylibCapabilities, capabilitiesOf(Profile.baseline));
    const b = c.narrowed(v);
    assert(b.fg == xterm256ToRgb(7) && b.bg == xterm256ToRgb(0), "no color at all");
    assert(b.borderRadius == 0 && !b.shadow.any, "square, and flat");
    assert(c.projected("✔ 日") == "+ ??", "ASCII only, wide glyphs keep their cells");

    c.capabilities = meet(raylibCapabilities, capabilitiesOf(Profile.enhanced));
    assert(c.projected(" ▏") == "✔ ▏", "the icon's Unicode mark; blocks stay");
}

@("ui_raylib.raylib_canvas.effectiveClipIntersectsStack")
@safe pure nothrow @nogc
unittest
{
    // A single clip passes through as-is.
    const Rect[1] c1 = [Rect(10, 5, 20, 30)];
    assert(RaylibCanvas.effectiveClip(c1[]) == Rect(10, 5, 20, 30));

    // Nested child clip is constrained within the parent's boundaries.
    // e.g. Pass 1 of document horizontal scroll: parent clip covers gutter [0, 8),
    // and an inner table op tries to push clip [0, 80). The effective clip MUST stay [0, 8).
    const Rect[2] c2 = [Rect(0, 0, 8, 40), Rect(0, 5, 80, 20)];
    assert(RaylibCanvas.effectiveClip(c2[]) == Rect(0, 5, 8, 20));

    // Pass 2: parent clip covers scrolled content [10, 50). An inner table clip [0, 80)
    // must be clamped to [10, 50).
    const Rect[2] c3 = [Rect(10, 0, 40, 40), Rect(0, 5, 80, 20)];
    assert(RaylibCanvas.effectiveClip(c3[]) == Rect(10, 5, 40, 20));

    // Disjoint clips result in an empty rect.
    const Rect[2] c4 = [Rect(0, 0, 10, 10), Rect(20, 20, 10, 10)];
    assert(RaylibCanvas.effectiveClip(c4[]).empty);

    // Empty stack returns empty rect.
    assert(RaylibCanvas.effectiveClip(null).empty);
}

/// The device-pixel scissor rectangle a clip resolves to.
struct ScissorBox
{
    int x, y, w, h;
}

/**
Turns a clip rect in cells into a device-pixel scissor box, clamped to a
target `boundW` x `boundH`. Returns `false` when nothing survives.

$(B Extracted because the clamp is where this went wrong.) An axis-only
viewport (`clipX` without `clipY`) leaves the other axis spanning the whole
`int` range, so the bound is doing real work rather than tidying edges — and
the bound must be the size of the target actually being drawn into, which
inside an `EFX11` bracket is a texture rather than the screen.

The previous version reached for `cast(float) int.max` as an "unbounded"
sentinel on the axis a render target did not constrain. That value rounds UP
to 2147483648.0f, and casting it back to `int` on x86 yields `int.min`, so the
width handed to `glScissor` was negative: `GL_INVALID_VALUE`, no state change,
and the PREVIOUS scissor — belonging to a different coordinate space — left
quietly in force. The visible symptom was a bracketed subtree missing a row.
Integer throughout, and a real bound, is the fix; the tests below are the
guard.
*/
bool scissorBoxOf(in Rect clip, float originX, float originY,
    int cellW, int cellH, int boundW, int boundH, out ScissorBox box)
    @safe pure nothrow @nogc
{
    if (clip.empty || boundW <= 0 || boundH <= 0)
        return false;

    static long cl(long v, long lo, long hi)
        => v < lo ? lo : (v > hi ? hi : v);

    // `long` throughout: a sentinel cell coordinate times a cell size
    // overflows `int` long before it reaches the clamp.
    const ox = cast(long) originX, oy = cast(long) originY;
    const x0 = cl(ox + cast(long) clip.x * cellW, 0, boundW);
    const y0 = cl(oy + cast(long) clip.y * cellH, 0, boundH);
    const x1 = cl(ox + (cast(long) clip.x + clip.width) * cellW, 0, boundW);
    const y1 = cl(oy + (cast(long) clip.y + clip.height) * cellH, 0, boundH);
    if (x1 <= x0 || y1 <= y0)
        return false;

    box = ScissorBox(cast(int) x0, cast(int) y0,
        cast(int)(x1 - x0), cast(int)(y1 - y0));
    return true;
}

@("ui_raylib.raylib_canvas.scissorBoxClampsToTheTargetNotToASentinel")
@safe pure nothrow @nogc
unittest
{
    ScissorBox box;

    // The ordinary case: a viewport well inside the target.
    assert(scissorBoxOf(Rect(2, 1, 10, 4), 0, 0, 10, 24, 800, 600, box));
    assert(box == ScissorBox(20, 24, 100, 96));

    // `LAY7`'s axis-only viewport: one axis spans the whole int range, and
    // the bound is what makes that expressible at all. The regression this
    // guards produced a NEGATIVE width here.
    const wide = Rect(-1_073_741_824, 1, 2_147_483_647, 31);
    assert(scissorBoxOf(wide, -250, -408, 10, 24, 340, 96, box));
    assert(box.x >= 0 && box.y >= 0);
    assert(box.w > 0 && box.h > 0, "a negative extent is GL_INVALID_VALUE");
    assert(box.x + box.w <= 340 && box.y + box.h <= 96,
        "never larger than the target being drawn into");
    assert(box == ScissorBox(0, 0, 340, 96), "the bracket is fully visible");

    // Inside an effect bracket the origin is shifted so the bracket's own
    // cell lands at the target's (0, 0); a clip that starts above it clamps
    // rather than going negative.
    assert(scissorBoxOf(Rect(0, 0, 100, 100), -250, -408, 10, 24, 340, 96, box));
    assert(box == ScissorBox(0, 0, 340, 96));

    // Fully off the target, and degenerate inputs, report nothing rather
    // than a box GL would reject.
    assert(!scissorBoxOf(Rect(100, 100, 2, 2), 0, 0, 10, 24, 340, 96, box));
    assert(!scissorBoxOf(Rect(0, 0, 0, 0), 0, 0, 10, 24, 340, 96, box));
    assert(!scissorBoxOf(Rect(0, 0, 4, 4), 0, 0, 10, 24, 0, 0, box));
}

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
import sparkles.ui.pixel_geometry : arrowTriangle, borderRects, centredSpan, ClipEntry,
    cornerRadiusPx, densityPx, lineRects, railExpandedPx, railIdlePx, roundedBorderPx,
    ruleRect, ScissorBox, scissorBoxOfStack, scrollbarMinExtentPx, ScrollbarRail,
    scrollbarRail, scrollbarRailPx, shadowRect, shiftPx;
import sparkles.ui.degradation : projectColor;
import sparkles.ui.glyphs : admits, projectGlyph;
import sparkles.ui.style : BorderStyle, FontRole, Shadow, Visual;
import sparkles.ui.style : UiTextStyle = TextStyle, TypeStep;
import sparkles.ui.tokens : TargetCapabilities;

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
alpha — and a viewport scrolled by a fraction of a cell (`subCellScroll`).
What it does not draw yet stays off: link targets, styled underlines (a
`TextStyle` underline is straight), a scaled run (the grid keeps mono at 1em)
(design-system M9 turns those on). A proportional face
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
    // A viewport's sub-cell scroll offset is painted (`LAY7`, `pushShift`).
    c.subCellScroll = true;
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
    /// The shortest a scrollbar's thumb is drawn, in device pixels, on
    /// either axis (`SCV13`): a mouse's 24 px, or a finger's 48 dp on a
    /// touch screen — set by the host, which knows which it has.
    int minThumbPx = scrollbarMinExtentPx;

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
    /// Each clip remembers the sub-cell shift in force when it was pushed
    /// (`LAY7`), so a viewport's own clip stays put while its content moves.
    private ClipEntry[] clips;

    void pushClip(in Rect r) scope @system
    {
        clips ~= ClipEntry(r, shiftX, shiftY);
        applyScissor();
    }

    /// ditto
    void popClip() scope @system
    {
        if (clips.length)
            clips = clips[0 .. $ - 1];
        applyScissor();
    }

    /**
    The optional shift pair (`LAY7`): what follows draws (`dx`, `dy`) cells
    further, rounded to whole device pixels so a glyph rasterises the same at
    every offset. Clips pushed before it stay where they were.
    */
    void pushShift(float dx, float dy) scope @system
    {
        const x = shiftPx(dx, cellW), y = shiftPx(dy, cellH);
        shifts ~= [x, y];
        originX += x;
        originY += y;
        shiftX += x;
        shiftY += y;
    }

    /// ditto
    void popShift() scope @system
    {
        if (!shifts.length)
            return;
        const s = shifts[$ - 1];
        shifts = shifts[0 .. $ - 1];
        originX -= s[0];
        originY -= s[1];
        shiftX -= s[0];
        shiftY -= s[1];
    }

    private int[2][] shifts;
    private int shiftX, shiftY; // the open shifts' sum, in pixels

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

    private void applyScissor() scope @system
    {
        EndScissorMode();
        if (!clips.length)
            return;
        // Inside an effect bracket the render target is not the screen, so its
        // size is what bounds the box and what Y is flipped against.
        const inTarget = fx !is null && fx.depth > 0
            ? fx.currentTargetHeight : 0;
        const boundW = inTarget > 0 ? fx.currentTargetWidth : GetScreenWidth();
        const boundH = inTarget > 0 ? inTarget : GetScreenHeight();

        // Intersect across the clip stack so nested child clips (e.g. wide
        // tables or code blocks) stay strictly bounded by their enclosing
        // viewports — in pixels, each clip at the origin it was pushed under.
        ScissorBox box;
        if (!scissorBoxOfStack(clips, cast(int)(originX - shiftX), cast(int)(originY - shiftY),
                cellW, cellH, boundW, boundH, box))
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
        // A box drawn smaller than its rect (`TOK11`) is centred in it: the
        // control keeps its whole touch target and draws a compact chip —
        // or, drawn narrower too, a switch's round knob.
        int x = cast(int) px(r.x), w = r.width * cellW;
        centredSpan(x, w, v.drawWidth);
        int y = cast(int) py(r.y), h = r.height * cellH;
        centredSpan(y, h, v.drawHeight);
        const box = Rect(x, y, w, h);

        // Drop shadow first, behind the surface: an offset translucent rect.
        if (v.shadow.any)
        {
            const s = v.shadow;
            const sc = Color(s.color.r, s.color.g, s.color.b, s.alpha);
            const sr = shadowRect(box, s);
            if (v.borderRadius > 0)
                DrawRectangleRounded(rectangleOf(sr),
                    roundnessOf(v.borderRadius, sr.width, sr.height), 8, sc);
            else
                fillExact(sr, sc);
        }

        // Background fill.
        if (v.hasBg)
        {
            if (v.borderRadius > 0)
                DrawRectangleRounded(rectangleOf(box), roundnessOf(v.borderRadius, w, h), 8,
                    rlBg(v));
            else
                fillExact(box, rlBg(v));
        }

        // Border and popup arrow.
        if (v.border.any)
            drawBorder(box, v);
        if (v.arrow)
            drawArrow(x, y, v);
    }

    // One pixel rectangle of the shared geometry, exactly as it names it.
    private static void fillExact(in Rect r, Color c) @system
    {
        if (!r.empty)
            DrawRectangle(r.x, r.y, r.width, r.height, c);
    }

    private static Rectangle rectangleOf(in Rect r) pure nothrow @nogc @safe
        => Rectangle(r.x, r.y, r.width, r.height);

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
        if (!drawsUiFace(visual) || !uiFonts.covers(projected(text),
                mono: visual.fontRole == FontRole.uiMono))
            return textRun(r.origin, text, visual);
        const v = narrowed(visual);
        const step = cast(size_t) uiStepOf(v.fontRole, v.typeStep, v.fontScale);
        const bold = (v.styleBits & TextAttr.bold.bits) != 0;
        // The glyph box centred in the rows the run was given, and the run
        // placed across its cells as its widget aligns it.
        const mono = v.fontRole == FontRole.uiMono;
        const dy = uiCentreOffset(uiFonts.size(step), r.height, cellH);
        const dx = alignOffsetPx(v.textAlign, r.width * cellW,
            uiFonts.width(step, bold, projected(text), mono));
        uiFonts.draw(step, bold, projected(text), px(r.x) + dx, py(r.y) + dy, rlFg(v),
            mono: mono);
    }

    /// `v` with its corner radius and shadow in device pixels: they are CSS px
    /// (`TOK7`), so a 16 px pill radius is 16 dp — 44 device pixels on a
    /// 440 dpi phone, not the 6 dp a raw 16 would be there.
    private Visual densityScaled(in Visual v) const @safe pure nothrow @nogc
    {
        Visual s = v;
        if (density == 1)
            return s;
        s.borderRadius = densityPx(v.borderRadius, density);
        s.shadow.dx = densityPx(v.shadow.dx, density);
        s.shadow.dy = densityPx(v.shadow.dy, density);
        s.shadow.blur = densityPx(v.shadow.blur, density);
        s.drawHeight = densityPx(v.drawHeight, density);
        s.drawWidth = densityPx(v.drawWidth, density);
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
        fillExact(ruleRect(pixelsOf(rect), edge), rlFg(v));
    }

    /// The hairline an owned track shows while idle — `rule`'s geometry, in
    /// the track's own colour, so a bar mounted on a border is indistinguishable
    /// from the border when nothing is hovering it.
    private void idleRule(in Scrollbar op) @system
    {
        const c = op.trackColor;
        fillExact(ruleRect(pixelsOf(op.rect), op.edge), Color(c.r, c.g, c.b, op.trackAlpha));
    }

    // A cell rect in device pixels.
    private Rect pixelsOf(in Rect r) const @safe pure nothrow @nogc
        => Rect(cast(int) px(r.x), cast(int) py(r.y), r.width * cellW, r.height * cellH);

    /// Draws the semantic scrollbar op with the backend's continuous px rail.
    /**
    The overlay bar (`SCV13`) in a band given in window pixels — a pane's
    right padding, which no cell rect describes — resolved through the same
    geometry as $(LREF scrollbar), so what a pointer grabs is what is drawn.
    Returns the rail it drew (`live` false: nothing to draw).
    */
    ScrollbarRail scrollbarPx(in Rect band, in Scrollbar op) @system
    {
        const idle = railIdlePx(cellW);
        const thickness = idle + (railExpandedPx(cellW) - idle) * op.expandPercent / 100;
        const r = op.fadePercent == 0 ? ScrollbarRail.init
            : scrollbarRailPx(band, op.edge, op.content, op.viewport, op.offset,
                op.offsetFrac, thickness, minThumbPx);
        if (!r.live)
            return r;
        const fg = projectColor(op.fg, capabilities.colorDepth, false);
        if (op.trackLit)
        {
            const tc = projectColor(op.trackColor, capabilities.colorDepth, false);
            DrawRectangle(r.track.x, r.track.y, r.track.width, r.track.height,
                Color(tc.r, tc.g, tc.b, cast(ubyte)(op.trackAlpha * op.fadePercent / 100)));
        }
        DrawRectangle(r.thumb.x, r.thumb.y, r.thumb.width, r.thumb.height,
            Color(fg.r, fg.g, fg.b, cast(ubyte)(op.fgAlpha * op.fadePercent / 100)));
        return r;
    }

    void scrollbar(in Scrollbar original) @system
    {
        Scrollbar op = original;
        op.fg = projectColor(original.fg, capabilities.colorDepth, false);
        op.trackColor = projectColor(original.trackColor, capabilities.colorDepth, false);
        const r = scrollbarRail(op, cellW, cellH,
            cast(int) originX, cast(int) originY, minThumbPx);
        if (!r.live)
            return;
        if (op.trackLit)
            DrawRectangle(r.track.x, r.track.y, r.track.width, r.track.height,
                Color(op.trackColor.r, op.trackColor.g, op.trackColor.b,
                    cast(ubyte)(op.trackAlpha * op.fadePercent / 100)));
        else if (op.paintsIdleTrack)
            // A bar that owns its rule IS the border it sits on, so idle it
            // must look like one — a hairline on the same edge, at the weight
            // `drawBox` gives a light box-drawing arm (`BOX1`), which is what
            // `OpKind.rule` already paints. Filling the hover rail here
            // instead thickened every overflowing fence's bottom border from
            // 1px to cellH/3; the window A/B oracle caught it.
            idleRule(op);
        // A fading bar (`SCV13`) fades as a whole: thumb and track together.
        auto thumb = rlFg(visualOf(op));
        thumb.a = cast(ubyte)(thumb.a * op.fadePercent / 100);
        DrawRectangle(r.thumb.x, r.thumb.y, r.thumb.width, r.thumb.height, thumb);
    }

    void line(in Point from, in Point to, in Visual visual, LineStyle style) @system
    {
        const v = narrowed(visual);
        const c = rlFg(v);
        lineRects(cast(int) px(from.x), cast(int) py(from.y), cast(int) px(to.x),
            style == LineStyle.wavy, cellH, (Rect r) { fillExact(r, c); });
    }

    /// raylib's rounded-rect `roundness` (0..1 of the shorter half-side) for a
    /// px corner radius on a `w × h` box.
    private static float roundnessOf(int radiusPx, float w, float h) pure nothrow @nogc @safe
    {
        const half = (w < h ? w : h) / 2.0f;
        if (half <= 0)
            return 0;
        return cornerRadiusPx(radiusPx, w, h) / half;
    }

    /// Strokes the box border. A rounded box (`borderRadius > 0`) gets a uniform
    /// rounded outline; a square box strokes each present side, honoring the
    /// dotted/dashed style (the `.twoslash-hover` bottom underline is dotted),
    /// with the pixels `borderRects` names: the strokes of the box-drawing
    /// glyphs a terminal draws for the same box.
    private void drawBorder(in Rect box, in Visual v) @system
    {
        const b = v.border;
        const c = rlBorder(v);
        if (v.borderRadius > 0)
        {
            DrawRectangleRoundedLinesEx(rectangleOf(box),
                roundnessOf(v.borderRadius, box.width, box.height), 8,
                roundedBorderPx(b.width, density), c);
            return;
        }
        borderRects(box, b.width, b.style, cellW, cellH, (Rect r) { fillExact(r, c); });
    }

    /// Draws the popup arrow/tail: a small upward triangle off the box's top edge
    /// at `arrowOffset` cells, filled with the surface color and outlined in the
    /// border color (approximating the CSS 6×6 rotated-square notch).
    private void drawArrow(int boxX, int boxY, in Visual v) @system
    {
        const t = arrowTriangle(boxX, boxY, v.arrowOffset, cellW, cellH);
        const apex = Vector2(t.apex[0], t.apex[1]);
        const left = Vector2(t.left[0], t.left[1]);
        const right = Vector2(t.right[0], t.right[1]);
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
            uiStepOf(style.fontRole, style.typeStep, style.fontScale), style.bold, cellW,
            style.fontRole == FontRole.uiMono);
    }

    struct BrushMetrics
    {
        private UiFonts* fonts;
        private int step;
        private bool bold;
        private int cellWidth;
        private bool mono; // a monospace run (`FontRole.uiMono`)
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
                fonts.appendWidth(cast(size_t) step, bold, text, pixels, mono);
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
        // A run the faces cannot cover draws through the cell font, so it is
        // as wide as its cells (`RaylibCanvas.textRunIn`).
        const covered = () @trusted {
            return uiFonts.covers(s, mono: style.fontRole == FontRole.uiMono);
        }();
        if (!covered)
            return cast(int) visibleWidth(s);
        const step = uiStepOf(style.fontRole, style.typeStep, style.fontScale);
        // The faces' advances live in raylib's glyph tables, which `UiFonts`
        // indexes through raw pointers; reading them changes nothing.
        const px = () @trusted {
            return uiFonts.width(cast(size_t) step, style.bold, s,
                mono: style.fontRole == FontRole.uiMono);
        }();
        return cellsCeil(px, cellW);
    }

    /// The rows one line in `style` occupies: as many as its glyph box needs.
    /// Leading is the rows' own, so a 14 px line on a 17 px cell takes one row,
    /// as the cell font beside it does.
    int rows(in UiTextStyle style) const @safe pure nothrow @nogc
        => usesUiFace(style) ? cellsCeil(uiFonts.size(cast(size_t)
                uiStepOf(style.fontRole, style.typeStep, style.fontScale)), cellH) : 1;

    /// The image cell size, so `IMG2` images lay out as on the canvas.
    Size cellPixels() const @safe pure nothrow @nogc => Size(cellW, cellH);

    private bool usesUiFace(in UiTextStyle style) const @safe pure nothrow @nogc
        => uiStepOf(style.fontRole, style.typeStep, style.fontScale) >= 0
            && uiFonts !is null && uiFonts.present;
}

/// How far into a `rectPx`-wide rect a `runPx`-wide run starts, aligned
/// `align` (0 start, 1 centre, 2 end); never before the rect's start.
float alignOffsetPx(ubyte align_, int rectPx, float runPx) @safe pure nothrow @nogc
{
    const slack = rectPx - runPx;
    if (slack <= 0 || align_ == 0)
        return 0;
    return cast(float) cast(int)(align_ == 1 ? slack / 2 : slack);
}

@("uiRaylib.alignOffsetPx")
@safe pure nothrow @nogc unittest
{
    assert(alignOffsetPx(0, 100, 60) == 0, "start");
    assert(alignOffsetPx(1, 100, 60) == 20, "centre, on a whole pixel");
    assert(alignOffsetPx(2, 100, 60) == 40, "end");
    assert(alignOffsetPx(1, 50, 60) == 0, "a run wider than its rect starts at it");
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
        case FontRole.uiMono:
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
    assert(uiStepOf(FontRole.uiMono, TypeStep.caption, 100) == TypeStep.caption,
        "interface data: the cell font at a step");
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

// The raylib canvas must satisfy the ui capability concept, or the shared
// `paint` interpreter won't accept it.
static assert(isCanvas!RaylibCanvas);

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
    assert(!c.hyperlinks, "no OSC 8 target in a window");
    assert(c.subCellScroll, "a viewport's fraction is painted (M9)");
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

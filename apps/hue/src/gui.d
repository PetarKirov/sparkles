// `hue --gui` — the raylib GPU rendering backend.
//
// A third consumer of hue's (source, events, theme) triple: instead of folding
// the highlight-event stream into ANSI escapes or HTML markup, it folds it into
// raylib draw calls — "styled runs as data", the GPU backend sparkles:syntax was
// designed for (docs/specs/syntax §2). A read-only, windowed, syntax-highlighted
// view with a live theme previewer, mirroring hue's terminal Previewer on the GPU.
//
// Compiled only by the `gui` build configuration (version(HueGui)); the default
// terminal build never references raylib. Build: dub build :hue -c gui.
//
// The raylib scaffolding here (FontSet, glyph fallback, the draw primitive) is a
// deliberate COPY of apps/terminal's text-rendering core, authored in the shape
// the shared sparkles:raylib-text library will own (issue #121 M5) so the
// extraction is a move, not a redesign. The pure text-layout logic lives in the
// raylib-free `gui_text` module (unit-tested by `dub test :hue`).
module gui;

version (HueGui):

import raylib;

import gui_text : TextStyle, GlyphDrawOps, drawOps, guardCell, getRequiredCodepoints,
    columnWidth, FontSlot;

// Selective import avoids sparkles.syntax.Color clashing with raylib.Color:
// bare `Color` is unambiguously raylib's; the theme color type is reached only
// through StyleSpec.fg/bg (never named here).
import sparkles.syntax : HighlightEvent, LabelSet, Theme, StyleSpec, TextAttr, UnderlineStyle,
    ResolvedTheme, resolveTheme, byStyledLine, RgbColor, toRgb;
import sparkles.base.smallbuffer : SmallBuffer;

/// The window's default font size in pixels (Ctrl-±/theme cycling arrive in M3).
private enum defaultFontSize = 18;

/// Sane concrete fallbacks when a theme leaves the page fore-/background unset
/// (the GPU has no "terminal default" to defer to, unlike the ANSI backend).
private enum RgbColor hardFallbackFg = RgbColor(0xcd, 0xd6, 0xf4);
private enum RgbColor hardFallbackBg = RgbColor(0x1e, 0x1e, 0x2e);

/**
Opens the raylib window and paints the highlighted file. M1 draws the whole
file with the initially selected theme; scrolling/gutter (M2), sizing/resize
and live theme cycling (M3), and search (M4) build on top.

`names`/`themes` are the sorted, parallel built-in theme arrays; `startIdx` is
the initially selected theme. Returns a process exit code.
*/
int runGui(
    string title,
    const(char)[] source,
    const(HighlightEvent)[] events,
    LabelSet labels,
    const(string)[] names,
    immutable(Theme)[] themes,
    size_t startIdx,
) @system
{
    import std.stdio : stderr;
    import std.string : toStringz;
    import std.process : environment;

    // Debug/CI capture: HUE_GUI_SCREENSHOT=<path> renders a few frames, writes a
    // PNG, and exits — the golden-frame harness the syntax spec's totality and
    // M5's byte-identical-render checks rely on (skipTest-gated when headless).
    const shotPath = environment.get("HUE_GUI_SCREENSHOT", "");

    InitWindow(800, 600, ("hue — " ~ title).toStringz);
    scope (exit) CloseWindow();
    SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    SetTargetFPS(60);
    SetExitKey(KeyboardKey.KEY_NULL); // arrow/close-button handling only (M3 adds keys)

    // LoadFontEx uploads a GPU texture, so the FontSet must load after InitWindow.
    FontSet fonts;
    if (!FontSet.tryLoad("monospace", defaultFontSize, fonts))
    {
        stderr.writeln("hue --gui: could not load a monospace font (is fontconfig available?)");
        return 1;
    }
    scope (exit) fonts.unload();

    // M1: a single resolved theme. M3 re-resolves on ↑/↓ over `themes`.
    const current = resolveTheme(themes[startIdx], labels);
    const pageFg = toRgb(current.defaults.fg, hardFallbackFg);
    const pageBg = toRgb(current.defaults.bg, hardFallbackBg);

    SmallBuffer!(char, 4096) runBuf; // reused per run; NUL-terminated for raylib

    int frame = 0;
    while (!WindowShouldClose())
    {
        BeginDrawing();
        ClearBackground(rl(pageBg));

        size_t curLine = size_t.max;
        float x = 0;
        float y = 0;
        foreach (ls; byStyledLine(source, events))
        {
            if (ls.line != curLine)
            {
                curLine = ls.line;
                x = 0;
                y = ls.line * cast(float) fonts.cellH(); // no scroll offset yet (M2)
            }

            const run = source[ls.span.start .. ls.span.end];
            if (run.length == 0)
                continue;

            // Copy the run into a NUL-terminated buffer raylib can read directly.
            runBuf.clear();
            runBuf ~= run;
            runBuf ~= '\0';
            const cstr = runBuf[][0 .. $ - 1];

            const spec = current[ls.span.label];
            // Fixed monospace advance: one cell per codepoint keeps runs on a
            // perfect grid (no MeasureTextEx drift, no per-run GL measure).
            const wpx = cast(int)(columnWidth(run) * fonts.cellW());
            if (spec.bg.isSet)
                DrawRectangle(cast(int) x, cast(int) y, wpx,
                    fonts.cellH(), rl(toRgb(spec.bg, pageBg)));
            drawText(fonts, cstr, x, y, mapStyle(spec), rl(toRgb(spec.fg, pageFg)));
            x += wpx;
        }

        EndDrawing();

        if (shotPath.length)
        {
            // Warm up for a number of frames before capturing: the glyph atlas
            // uploads over the first frames, and under a headless GL context the
            // framebuffer swap lags the draw, so an early TakeScreenshot grabs a
            // black frame. ~20 frames is reliably past both.
            if (++frame == 20)
                TakeScreenshot(shotPath.toStringz);
            if (frame >= 21)
                break;
        }
    }

    return 0;
}

/// Translates sparkles:syntax's backend-neutral `TermStyle` attributes into the
/// renderer's `TextStyle`. On the shaped `TermStyle`, underline is a first-class
/// `UnderlineStyle` field (bit-3 of `attrs` is strikethrough). The terminal will
/// translate `GhosttyStyle` the same way onto the shared library type in M5.
TextStyle mapStyle(in StyleSpec spec) pure nothrow @nogc @safe
{
    TextStyle t;
    if (spec.attrs.has(TextAttr.bold))
        t.bits |= TextStyle.bold;
    if (spec.attrs.has(TextAttr.italic))
        t.bits |= TextStyle.italic;
    if (spec.attrs.has(TextAttr.strikethrough))
        t.bits |= TextStyle.strikethrough;
    if (spec.underline != UnderlineStyle.none)
        t.bits |= TextStyle.underline;
    return t;
}

/// An RGB triple as a raylib color (fully opaque).
Color rl(RgbColor c) pure nothrow @nogc @trusted => Color(c.r, c.g, c.b, 255);

/**
A primary monospace font plus a regular and a Nerd-Font fallback, over a shared
codepoint atlas — the app-agnostic font resource the shared library will own.
`glyphCache` is a per-instance presence map (keyed by GPU texture id) so two
FontSets (the terminal's and hue's) never collide.
*/
struct FontSet
{
    private Font primary;
    private Font regularFallback;
    private Font nerdFallback;
    private bool hasRegular;
    private bool hasNerd;
    private string primaryPath;
    private string regularPath;
    private string nerdPath;
    private int[] codepoints; // retained for reload
    private int fontSize_;
    private int cellW_ = 1;
    private int cellH_ = 1;
    private bool[int][uint] glyphCache;

    int cellW() const pure nothrow @nogc @safe => cellW_;
    int cellH() const pure nothrow @nogc @safe => cellH_;
    int size() const pure nothrow @nogc @safe => fontSize_;

    /**
    Resolves `nameOrPath` via fc-match (unless it is already a file), loads the
    primary face, then resolves one regular and one Nerd-Font fallback from
    `fc-match monospace -s`, and measures the cell. Verbatim from apps/terminal.
    Returns `false` (leaving the caller to error out) if the primary font can't
    be resolved or loaded.
    */
    static bool tryLoad(string nameOrPath, int fontSize, out FontSet fonts) @system
    {
        import std.file : exists;
        import std.process : execute;
        import std.string : strip, splitLines, toStringz;
        import std.algorithm.searching : canFind;

        string fontPath = nameOrPath;
        if (!fontPath.exists)
        {
            auto res = execute(["fc-match", "-f", "%{file}", nameOrPath]);
            if (res.status == 0 && res.output.strip.length > 0)
                fontPath = res.output.strip.idup;
        }
        if (!fontPath.exists)
            return false;

        fonts.fontSize_ = fontSize;
        fonts.codepoints = getRequiredCodepoints();
        fonts.primaryPath = fontPath;
        fonts.primary = LoadFontEx(fontPath.toStringz, fontSize,
            fonts.codepoints.ptr, cast(int) fonts.codepoints.length);
        if (fonts.primary.texture.id == 0)
            return false;

        auto fb = execute(["fc-match", "-f", "%{file}\n", "monospace", "-s"]);
        if (fb.status == 0)
        {
            foreach (line; fb.output.splitLines)
            {
                string path = line.strip.idup;
                if (path.length == 0 || path == fontPath)
                    continue;

                const isNerd = path.canFind("NerdFont") || path.canFind("Nerd Font");
                if (isNerd && !fonts.hasNerd)
                {
                    fonts.nerdPath = path;
                    fonts.nerdFallback = LoadFontEx(path.toStringz, fontSize,
                        fonts.codepoints.ptr, cast(int) fonts.codepoints.length);
                    if (fonts.nerdFallback.texture.id != 0)
                        fonts.hasNerd = true;
                }
                else if (!isNerd && !fonts.hasRegular
                    && (path.canFind("DejaVu") || path.canFind("FreeMono")
                        || path.canFind("LiberationMono")))
                {
                    fonts.regularPath = path;
                    fonts.regularFallback = LoadFontEx(path.toStringz, fontSize,
                        fonts.codepoints.ptr, cast(int) fonts.codepoints.length);
                    if (fonts.regularFallback.texture.id != 0)
                        fonts.hasRegular = true;
                }

                if (fonts.hasNerd && fonts.hasRegular)
                    break;
            }
        }

        fonts.measure();
        return true;
    }

    /// Reloads all faces at `newSize`, invalidates the glyph cache (GPU texture
    /// ids may be reused after unload), and re-measures. Used by M3 font sizing.
    void reload(int newSize) @system
    {
        import std.string : toStringz;

        glyphCache.clear();
        UnloadFont(primary);
        if (hasRegular)
            UnloadFont(regularFallback);
        if (hasNerd)
            UnloadFont(nerdFallback);

        fontSize_ = newSize;
        primary = LoadFontEx(primaryPath.toStringz, newSize,
            codepoints.ptr, cast(int) codepoints.length);
        if (hasRegular)
            regularFallback = LoadFontEx(regularPath.toStringz, newSize,
                codepoints.ptr, cast(int) codepoints.length);
        if (hasNerd)
            nerdFallback = LoadFontEx(nerdPath.toStringz, newSize,
                codepoints.ptr, cast(int) codepoints.length);
        measure();
    }

    /// The font a codepoint draws from — the lazy runtime counterpart of the
    /// pure `gui_text.chooseFontSlot`: ASCII → primary; otherwise probe primary,
    /// then the regular fallback, then the Nerd fallback, first that has the
    /// glyph (fallbacks probed only on a miss); tofu from the primary otherwise.
    ref Font pickFont(int codepoint) return @trusted
    {
        if (codepoint < 128)
            return primary;
        if (fontHasGlyph(primary, codepoint))
            return primary;
        if (hasRegular && fontHasGlyph(regularFallback, codepoint))
            return regularFallback;
        if (hasNerd && fontHasGlyph(nerdFallback, codepoint))
            return nerdFallback;
        return primary;
    }

    /// Unloads every loaded face.
    void unload() @system
    {
        UnloadFont(primary);
        if (hasRegular)
            UnloadFont(regularFallback);
        if (hasNerd)
            UnloadFont(nerdFallback);
    }

    private void measure() @system
    {
        const m = MeasureTextEx(primary, "M".ptr, fontSize_, 0);
        cellW_ = guardCell(m.x);
        cellH_ = guardCell(m.y);
    }

    /// O(1) glyph-presence test, memoized per GPU texture id (lazily built on
    /// the first lookup for a font). Instance state, cleared on `reload`.
    private bool fontHasGlyph(ref Font font, int codepoint) @trusted
    {
        if (font.glyphs is null)
            return false;
        auto set = font.texture.id in glyphCache;
        if (set is null)
        {
            bool[int] built;
            foreach (i; 0 .. font.glyphCount)
                built[font.glyphs[i].value] = true;
            glyphCache[font.texture.id] = built;
            set = font.texture.id in glyphCache;
        }
        return (codepoint in *set) !is null;
    }
}

/// The first codepoint of a UTF-8 slice (U+FFFD on invalid) — used to pick the
/// run's font. `str` need not be NUL-terminated.
private int firstCodepoint(scope const(char)[] str) @trusted
{
    import std.utf : decode;
    import std.typecons : Yes;

    if (str.length == 0)
        return 0;
    size_t i = 0;
    return cast(int) decode!(Yes.useReplacementDchar)(str, i);
}

/**
The draw primitive: one styled run (`cstr` must be NUL-terminated so raylib
reads it with no copy) at `(x, y)` in the font its first codepoint selects,
with fake-bold (redraw +1px), italic slant (x-shift), and underline /
strikethrough rectangles. Draws no background — the caller owns layout and
fills, matching apps/terminal. Mirrors the terminal's per-cell draw at per-run
granularity; the shape the shared library will own in M5.
*/
private void drawText(ref FontSet fonts, scope const(char)[] cstr, float x, float y,
    TextStyle style, Color fg) @system
{
    if (cstr.length == 0)
        return;

    Font f = fonts.pickFont(firstCodepoint(cstr));
    const size = fonts.size();
    const ops = drawOps(style, size);

    DrawTextEx(f, cstr.ptr, Vector2(x + ops.italicOffset, y), size, 0, fg);
    if (ops.fakeBold)
        DrawTextEx(f, cstr.ptr, Vector2(x + ops.italicOffset + 1, y), size, 0, fg);

    if (ops.underline || ops.strikethrough)
    {
        const wpx = cast(int)(columnWidth(cstr) * fonts.cellW());
        if (ops.underline)
            DrawRectangle(cast(int) x, cast(int)(y + fonts.cellH() - 2), wpx, 1, fg);
        if (ops.strikethrough)
            DrawRectangle(cast(int) x, cast(int)(y + fonts.cellH() / 2), wpx, 1, fg);
    }
}

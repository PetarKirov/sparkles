/**
The interface face: a proportional sans drawn at its own pixel sizes, beside the
monospace `FontSet` that draws terminal text (design-system `GLY10`).

An application's own chrome — page titles, rows, chips, buttons — reads better
in a proportional face at a type scale than in the terminal's cell font. A
`UiFonts` holds one regular and one bold face per step of that scale, each
rasterized at its size. Text advances by each glyph's real advance, with the
face's kerning pairs applied (shaped by HarfBuzz with ligatures off, so every
code point keeps its own atlas glyph); a code point the sans face lacks (an icon, a check mark, a script it does not cover)
is drawn from the `FontSet`'s face for it, scaled to the step's size, so icons
keep working. Loading needs an active raylib GL context.
*/
module sparkles.raylib_text.ui_font;

import raylib;

import sparkles.raylib_text.font : fontHasGlyph, glyphIndexFor, loadFontInto, loadVariantFile,
    LoadedFont;
import sparkles.raylib_text.font_discovery : FontSources;
import sparkles.raylib_text.font_set : FontSet;
import sparkles.raylib_text.shaping_api : st_face_close, st_face_open, st_kern_advances,
    st_library_create, st_library_destroy, STFace, STLibrary;

/// The number of steps on the type scale (`sparkles:ui`'s `TypeStep`).
enum uiTypeSteps = 4;

// `TypeStep.body`'s index: the step the cell font's x-height is matched at.
private enum TypeStepBody = 0;

/// One step's faces and metrics, in the backend's drawing units.
struct UiFace
{
    LoadedFont regular; /// the regular face at `size`
    LoadedFont bold;    /// the bold face at `size`; absent means a doubled stroke
    int size;           /// the drawn size, in drawing units
    int lineHeight;     /// the height one line of this step occupies
    STFace* kernRegular; /// `regular` opened for kerning; null: none
    STFace* kernBold;    /// ditto for `bold`
    LoadedFont mono;     /// the cell font's regular face at `monoSize`; absent: the `FontSet`'s, scaled
    LoadedFont monoBold; /// ditto, bold
    int monoSize;        /// the size a monospace run of this step draws at
    bool monoLoaded, monoBoldLoaded; /// whether `mono`/`monoBold` were rasterized yet

    @disable this(this); // the LoadedFonts own move-only buffers
}

/**
The code points every interface face is rasterized with: printable ASCII, Latin-1
and Latin Extended-A letters, and the punctuation chrome text uses (dashes,
quotes, the bullet, the ellipsis, the middle dot). Everything else falls back to
the `FontSet`.
*/
immutable int[] uiCodepoints = () {
    int[] cps;
    foreach (cp; 0x20 .. 0x7F)
        cps ~= cp;
    foreach (cp; 0xA0 .. 0x180)
        cps ~= cp;
    foreach (cp; 0x2010 .. 0x2028)
        cps ~= cp;
    foreach (cp; [0x2030, 0x2032, 0x2033, 0x2039, 0x203A, 0x20AC, 0x2122])
        cps ~= cp;
    return cps;
}();

/// The largest body glyph box, as a share of the cell font's size, when the
/// interface steps follow the cell font: the rest of the cell is the line's
/// leading.
enum float uiBodyOfCell = 0.85f;

/// The line height for a face drawn at `size`: the size plus a third, the
/// leading the mockups use (17 px titles on 22–24 px lines, 14 px body on 19).
int uiLineHeight(int size) @safe pure nothrow @nogc
    => size + (size + 2) / 3;

/// How far down a line of height `lineHeight` sits so it is centred in `rows`
/// cells of `cellH` — the cell rectangle the layout gave the run.
float uiCentreOffset(int lineHeight, int rows, int cellH) @safe pure nothrow @nogc
{
    const room = rows * cellH;
    return room > lineHeight ? (room - lineHeight) / 2.0f : 0.0f;
}

@("raylib_text.ui_font.metrics")
@safe pure nothrow @nogc
unittest
{
    assert(uiLineHeight(14) == 19 && uiLineHeight(17) == 23 && uiLineHeight(12) == 16);
    assert(uiCentreOffset(19, 1, 17) == 0, "a line taller than its cell starts at the top");
    assert(uiCentreOffset(23, 2, 17) == 5.5f);
    assert(uiCentreOffset(16, 1, 20) == 2);
}

@("raylib_text.ui_font.codepointsAreSortedAndCoverLatin")
@safe pure nothrow
unittest
{
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : isStrictlyMonotonic;

    assert(uiCodepoints.isStrictlyMonotonic);
    foreach (cp; [cast(int) 'A', 'z', 0xE9 /* é */, 0x161 /* š */, 0x2014 /* — */,
            0x2022 /* • */, 0x2026 /* … */])
        assert(uiCodepoints.canFind(cp));
}

/**
Resolves the interface family `family` to its regular and bold files, the way
`FontSet` resolves the cell font: through the system font database when
`sources` uses one (fontconfig, or CoreText on macOS, so `"sans-serif"` names
the desktop's own interface face), otherwise from `sources.dirs` (the bundled
fonts on Android). `bold` is `""` when the family has no bold file. Returns
whether a regular face was found.
*/
bool resolveUiFace(string family, in FontSources sources, out string regular,
    out string bold) @trusted
{
    import std.file : exists;
    import std.string : strip;
    import sparkles.raylib_text.font_discovery : fontVariantPaths, resolveFontInDirs;

    if (sources.useSystemFontDb)
    {
        version (OSX)
        {
            import sparkles.raylib_text.font_coretext : resolveFamilyList;

            regular = resolveFamilyList(family);
            bold = resolveFamilyList(family ~ " Bold");
        }
        else
        {
            import sparkles.raylib_text.font_fontconfig : fcRun;

            auto r = fcRun(["fc-match", "-f", "%{file}", family]);
            if (r.status == 0)
                regular = r.output.strip.idup;
            auto b = fcRun(["fc-match", "-f", "%{file}", family ~ ":bold"]);
            if (b.status == 0)
                bold = b.output.strip.idup;
        }
        if (bold == regular)
            bold = "";
    }
    else
    {
        regular = resolveFontInDirs(family, sources.dirs);
        if (regular.length)
        {
            string italic, boldItalic;
            fontVariantPaths(regular, bold, italic, boldItalic);
        }
    }
    if (regular.length == 0 || !regular.exists)
    {
        regular = bold = "";
        return false;
    }
    return true;
}

/**
The interface faces, one per type step. Load once a GL context exists; reload
on a density change. A `UiFonts` that failed to load (`present` false) asks the
caller to fall back to the cell font, which every backend can.
*/
struct UiFonts
{
    @disable this(this);

    private UiFace[uiTypeSteps] steps;
    private FontSet* fallback;
    private float atlasScale = 1.0f;
    private STLibrary* kernLibrary;
    // The cell font's size relative to a step's: what makes its x-height the
    // interface face's, so a monospace value reads at the size of its label.
    private float monoScale = 1.0f;

    /// `true` once a regular face loaded for every step.
    bool present;

    /**
    Loads `regularPath` and `boldPath` at `sizes` (one per step, in drawing
    units; the atlas is rasterized `atlasScale` times denser, as `FontSet`'s
    is) and routes missing code points to `fallback`. A missing bold file
    leaves bold drawn as a doubled stroke.

    `matchCellPx` non-zero says `sizes` follow the cell font drawn at that size
    (`GLY10`): every step shrinks by the interface face's x-height over the
    cell font's, so body text reads at the terminal's size, and at least to
    $(LREF uiBodyOfCell) of it, so a body line keeps leading inside its cell
    instead of touching the rules and boxes around it.
    */
    void load(string regularPath, string boldPath, const int[uiTypeSteps] sizes,
        FontSet* fallback, float atlasScale = 1.0f, int matchCellPx = 0) @system
    {
        unload();
        this.fallback = fallback;
        this.atlasScale = atlasScale;
        int[uiTypeSteps] at = sizes;
        if (matchCellPx > 0)
        {
            const xh = probeXHeightRatio(regularPath, sizes[TypeStepBody]);
            const shrink = xh * uiBodyOfCell < 1 ? 1 / uiBodyOfCell : xh;
            foreach (i, ref s; at)
            {
                const v = cast(int)(sizes[i] / shrink + 0.5f);
                s = v < 1 ? 1 : v;
            }
        }
        present = true;
        foreach (i, ref face; steps)
        {
            face.size = at[i];
            face.lineHeight = uiLineHeight(at[i]);
            const px = cast(int)(at[i] * atlasScale + 0.5f);
            loadVariantFile(face.regular, regularPath, px, uiCodepoints);
            loadVariantFile(face.bold, boldPath, px, uiCodepoints);
            face.kernRegular = openKern(regularPath, px);
            if (face.bold.present)
                face.kernBold = openKern(boldPath, px);
            present = present && face.regular.present;
        }
        if (!present)
            return;
        monoScale = xHeightRatio(steps[TypeStepBody].regular);
        loadMonoFaces();
    }

    // Each step's monospace faces, rasterized at the step's monospace size so a
    // value is as crisp as its label (a face stretched off its raster blurs).
    private void loadMonoFaces() @system
    {
        if (fallback is null)
            return;
        foreach (ref face; steps)
        {
            const v = cast(int)(face.size * monoScale + 0.5f);
            face.monoSize = v < 1 ? 1 : v;
            face.mono.pathZ = fallback.facePathZ(false);
            face.monoBold.pathZ = fallback.facePathZ(true);
            face.monoLoaded = face.monoBoldLoaded = false;
        }
    }

    // A step's monospace face, rasterized the first time a run needs it:
    // eight atlases up front cost a phone a quarter of a second at startup,
    // for steps and weights a screen may never show.
    private LoadedFont* monoFace(ref UiFace face, bool bold) @system nothrow @nogc
    {
        const px = cast(int)(face.monoSize * atlasScale + 0.5f);
        if (bold)
        {
            if (!face.monoBoldLoaded && face.monoBold.pathZ !is null)
                loadFontInto(face.monoBold, px, uiCodepoints);
            face.monoBoldLoaded = true;
            if (face.monoBold.present)
                return &face.monoBold;
        }
        if (!face.monoLoaded && face.mono.pathZ !is null)
            loadFontInto(face.mono, px, uiCodepoints);
        face.monoLoaded = true;
        return &face.mono;
    }

    // The x-height ratio of the face at `path` (loaded once at `size` to
    // measure), clamped so a face with a smaller x-height never grows past the
    // cell. 1 when either face cannot be measured.
    private float probeXHeightRatio(string path, int size) @system
    {
        LoadedFont probe;
        loadVariantFile(probe, path, cast(int)(size * atlasScale + 0.5f), uiCodepoints);
        scope (exit)
            if (probe.present)
                UnloadFont(probe.font);
        const r = xHeightRatio(probe);
        return r < 1.0f ? 1.0f : r;
    }

    // `ui`'s x-height over the cell font's, each per unit of size.
    private float xHeightRatio(ref LoadedFont ui) @system
    {
        if (fallback is null)
            return 1.0f;
        bool fakeBold, fakeItalic;
        auto mono = fallback.resolveFace('x', false, false, fakeBold, fakeItalic);
        const u = xHeight(ui), cell = mono is null ? 0 : xHeight(*mono);
        if (u <= 0 || cell <= 0)
            return 1.0f;
        const r = u / cell;
        return r < 0.7f ? 0.7f : r > 1.3f ? 1.3f : r;
    }

    private static float xHeight(ref LoadedFont lf) @system
    {
        if (!lf.present || lf.font.baseSize <= 0 || !fontHasGlyph(lf, 'x'))
            return 0;
        return lf.font.recs[glyphIndexFor(lf, 'x')].height / cast(float) lf.font.baseSize;
    }

    // Where `lf`'s baseline sits below the top of its glyph box, per unit of
    // size: the bottom of its 'x'. 0.8 (a typical ascent) when it has none.
    private static float baseline(ref LoadedFont lf) @system
    {
        if (!lf.present || lf.font.baseSize <= 0 || !fontHasGlyph(lf, 'x'))
            return 0.8f;
        const i = glyphIndexFor(lf, 'x');
        return (lf.font.glyphs[i].offsetY + lf.font.recs[i].height) / cast(float) lf.font.baseSize;
    }

    // The face at `path` opened for kerning at `px`, or null (kerning is then
    // skipped and glyphs advance by their own widths).
    private STFace* openKern(string path, int px) @system
    {
        import std.string : toStringz;

        if (kernLibrary is null)
            kernLibrary = st_library_create();
        return kernLibrary is null ? null : st_face_open(kernLibrary, path.toStringz, 0, px);
    }

    /// Releases every face.
    void unload() @system nothrow @nogc
    {
        foreach (ref face; steps)
        {
            st_face_close(face.kernRegular);
            st_face_close(face.kernBold);
            face.kernRegular = face.kernBold = null;
            if (face.regular.present)
                UnloadFont(face.regular.font);
            if (face.bold.present)
                UnloadFont(face.bold.font);
            if (face.mono.present)
                UnloadFont(face.mono.font);
            if (face.monoBold.present)
                UnloadFont(face.monoBold.font);
            face.regular = LoadedFont.init;
            face.bold = LoadedFont.init;
            face.mono = LoadedFont.init;
            face.monoBold = LoadedFont.init;
        }
        if (kernLibrary !is null)
            st_library_destroy(kernLibrary);
        kernLibrary = null;
        present = false;
    }

    ~this() @system
    {
        unload();
    }

    /// The size `step` is drawn at — its glyph box, ascender to descender —
    /// in drawing units.
    int size(size_t step) const @safe pure nothrow @nogc
        => steps[step].size;

    /// The height one line of `step` occupies, in drawing units.
    int lineHeight(size_t step) const @safe pure nothrow @nogc
        => steps[step].lineHeight;

    /**
    Whether every code point of `text` has a glyph in the faces this draws
    from — the interface face (unless `mono`) or the `FontSet`'s loaded faces.
    A symbol only the cell font's system fallback has (an icon from another
    font) does not, and the caller draws such a run through the cell font.
    */
    bool covers(scope const(char)[] text, bool mono) @system nothrow @nogc
    {
        import sparkles.base.text.ansi : byAnsiToken;
        import sparkles.base.text.tokens : byUtfToken;
        import sparkles.base.text.utf : UtfMode;

        foreach (part; byAnsiToken(text))
        {
            if (part.isEscape) continue;
            foreach (token; byUtfToken(part.slice, UtfMode.replacement))
            {
                const cp = cast(int) token.scalar;
                if (cp < 0x20 || cp == 0x7F || (!mono && fontHasGlyph(steps[0].regular, cp)))
                    continue;
                if (fallback is null)
                    return false;
                bool fakeBold, fakeItalic;
                auto lf = fallback.resolveFace(cp, false, false, fakeBold, fakeItalic);
                if (lf is null || !fontHasGlyph(*lf, cp))
                    return false;
            }
        }
        return true;
    }

    /// The width of `text` drawn in `step`, in drawing units.
    float width(size_t step, bool bold, scope const(char)[] text, bool mono = false)
        @system nothrow @nogc
    {
        float w = 0;
        appendWidth(step, bold, text, w, mono);
        return w;
    }

    /// Adds a whole-cluster chunk to a run's unrounded pixel extent. Keep the
    /// accumulator across chunks: rounding each chunk would change the run.
    void appendWidth(size_t step, bool bold, scope const(char)[] text,
        ref float width, bool mono = false) @system nothrow @nogc
    {
        eachGlyph(step, bold, mono, text, (ref LoadedFont lf, int cp, int size, float adv) {
            width += adv;
        });
    }

    /**
    Draws `text` in `step` with its top-left at `(x, y)`, in `fg`. Code points
    the face lacks come from the `FontSet` at the same size. `mono` draws the
    whole run in the cell font, rasterized at the step's monospace size (its
    x-height the interface face's) and set on the step's baseline, so a value
    sits beside its label at one size, as crisp as it.
    */
    void draw(size_t step, bool bold, scope const(char)[] text, float x, float y,
        Color fg, bool mono = false) @system
    {
        import sparkles.raylib_text.draw : drawGrapheme;

        // Each glyph starts on a whole pixel: the pen accumulates the exact
        // advances, but a glyph sampled at a fractional offset is filtered
        // across two pixel columns and reads as blurred, unevenly spaced text.
        const fake = bold && !steps[step].bold.present;
        const top = cast(float) cast(int)(y + 0.5f);
        float pen = x;
        const box = steps[step].size;
        const base = baseline(steps[step].regular) * box;
        eachGlyph(step, bold, mono, text, (ref LoadedFont lf, int cp, int size, float adv) {
            const uint[1] one = [cast(uint) cp];
            const left = cast(float) cast(int)(pen + 0.5f);
            // A monospace run sits on the step's baseline, on a whole pixel;
            // a glyph of the step's own size shares its box.
            const t = size == box ? top
                : cast(float) cast(int)(top + base - baseline(lf) * size + 0.5f);
            drawGrapheme(lf, one[], left, t, size, fg);
            if (fake)
                drawGrapheme(lf, one[], left + 1, t, size, fg);
            pen += adv;
        });
    }

    // Each code point of `text` with the face it draws in, the size to draw it
    // at, and its advance in drawing units.
    private void eachGlyph(Visit)(size_t step, bool bold, bool mono, scope const(char)[] text,
        scope Visit visit)
    {
        import sparkles.base.text.ansi : byAnsiToken;
        import sparkles.base.text.tokens : byUtfToken;
        import sparkles.base.text.utf : UtfMode;

        auto face = &steps[step];
        if (mono && fallback !is null)
        {
            const size = face.monoSize;
            LoadedFont* own = monoFace(*face, bold);
            foreach (part; byAnsiToken(text))
            {
                if (part.isEscape) continue;
                foreach (token; byUtfToken(part.slice, UtfMode.replacement))
                {
                    const cp = cast(int) token.scalar;
                    if (cp < 0x20 || cp == 0x7F)
                        continue;
                    bool fakeBold, fakeItalic;
                    auto lf = own.present && fontHasGlyph(*own, cp) ? own
                        : fallback.resolveFace(cp, bold, false, fakeBold, fakeItalic);
                    const idx = glyphIndexFor(*lf, cp);
                    const base = lf.font.baseSize > 0 ? lf.font.baseSize : size;
                    visit(*lf, cp, size, lf.font.glyphs[idx].advanceX * cast(float) size / base);
                }
            }
            return;
        }
        const useBold = bold && face.bold.present;
        LoadedFont* own = useBold ? &face.bold : &face.regular;

        // The run's code points (escapes and controls dropped), then its
        // kerned advances where the face can shape the whole run one glyph
        // per code point. A run longer than the buffer advances unkerned:
        // the walk stays `@nogc`.
        uint[128] cps;
        float[128] kerned;
        size_t n;
        bool fits = true;
        foreach (part; byAnsiToken(text))
        {
            if (part.isEscape) continue;
            foreach (token; byUtfToken(part.slice, UtfMode.replacement))
            {
                const cp = cast(uint) token.scalar;
                if (cp < 0x20 || cp == 0x7F)
                    continue;
                if (n < cps.length)
                    cps[n] = cp;
                else
                    fits = false;
                n++;
            }
        }
        STFace* kf = useBold ? face.kernBold : face.kernRegular;
        const haveKern = fits && n > 1 && kf !is null
            && st_kern_advances(kf, cps.ptr, cast(uint) n, kerned.ptr) != 0;

        size_t k;
        foreach (part; byAnsiToken(text))
        {
            if (part.isEscape) continue;
            foreach (token; byUtfToken(part.slice, UtfMode.replacement))
            {
                const cp = cast(int) token.scalar;
                if (cp < 0x20 || cp == 0x7F)
                    continue;
                LoadedFont* lf = own;
                if (!fontHasGlyph(*own, cp) && fallback !is null)
                {
                    bool fakeBold, fakeItalic;
                    lf = fallback.resolveFace(cp, bold, false, fakeBold, fakeItalic);
                }
                const idx = glyphIndexFor(*lf, cp);
                const base = lf.font.baseSize > 0 ? lf.font.baseSize : face.size;
                const adv = haveKern && lf is own
                    ? kerned[k] * face.size / own.font.baseSize
                    : lf.font.glyphs[idx].advanceX * cast(float) face.size / base;
                visit(*lf, cp, face.size, adv);
                k++;
            }
        }
    }
}

version (RaylibTextTests)
@("raylib_text.ui_font.resolveUiFace.bundledFamily")
@system unittest
{
    import std.path : baseName;
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create("sparkles-ui-face-test");
    foreach (f; ["Roboto-Regular.ttf", "Roboto-Bold.ttf", "FiraCodeNerdFontMono-Regular.ttf"])
        tmp.writeFileAt(f, "x");
    const sources = FontSources([tmp.dir], useSystemFontDb: false);

    string regular, bold;
    assert(resolveUiFace("Roboto", sources, regular, bold));
    assert(regular.baseName == "Roboto-Regular.ttf" && bold.baseName == "Roboto-Bold.ttf");

    assert(!resolveUiFace("Inter", sources, regular, bold), "a family the dirs lack");
    assert(regular == "" && bold == "");
}

version (RaylibTextTests)
@("raylib_text.ui_font.kernAdvances.pairTightens")
@system unittest
{
    import std.string : toStringz;
    import sparkles.test_runner.skip : skipTest;

    string regular, bold;
    if (!resolveUiFace("sans-serif", FontSources(null, useSystemFontDb: true), regular, bold))
        return skipTest("no system sans-serif face");
    auto lib = st_library_create();
    scope (exit) st_library_destroy(lib);
    auto face = st_face_open(lib, regular.toStringz, 0, 32);
    scope (exit) st_face_close(face);
    assert(face !is null);

    float[2] av, aa;
    const uint[2] pairAV = ['A', 'V'], pairAA = ['A', 'A'];
    assert(st_kern_advances(face, pairAV.ptr, 2, av.ptr));
    assert(st_kern_advances(face, pairAA.ptr, 2, aa.ptr));
    assert(av[0] < aa[0], "the A–V pair is kerned tighter than A–A");

    const uint[2] fi = ['f', 'i'];
    float[2] fiAdv;
    assert(st_kern_advances(face, fi.ptr, 2, fiAdv.ptr), "no ligature: one glyph per code point");
}

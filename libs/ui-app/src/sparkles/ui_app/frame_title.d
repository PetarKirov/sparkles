/**
The client frame's title, set in the desktop's title-bar face at a fixed
size (`F13`): GNOME's is Adwaita Sans Bold at 11 pt, and a title that grew
with the application's cell font — which an application may size to its
window — looked like no other window's.

The face is found once, through the system font database, by preference:
Adwaita Sans, then Cantarell (GNOME's before it), then the database's bold
sans. A variable face is instanced at weight 700. The title is set into a
coverage strip — advances from `hmtx` (and `HVAR`), no kerning — and set
again only when its text, its room or the density changes; one that does
not fit ends in an ellipsis, as GTK's labels do. The frame draws the strip
centred in its bar.
*/
module sparkles.ui_app.frame_title;

// The native arm's alone, like the frame it titles.
version (UiAppGuiVulkan):

import sparkles.base.text.utf : decodeToken, UtfMode, UtfStatus, UtfTokenKind;
import sparkles.font : advance, charMap, Face, FlattenPolicy, FontErrorKind, FontLimit,
    instance, Instance, InstanceSize, lineMetrics, OutlinePoint, OutlineSegment, OverlapMode,
    PointWorkspace, Ppem, RasterRegion, RasterWorkspace, rasterizeGlyph, rasterMeasure, Tag,
    UserCoordinate, openFace;

/**
`text` as a window title: well-formed UTF-8 — each ill-formed sequence
replaced by U+FFFD — of at most `limit` bytes, cut before the scalar that
would pass it, never inside one. A window system rejects a title that is
not UTF-8, and one cut mid-sequence is not.
*/
string fitTitle(scope const(char)[] text, size_t limit) @safe pure nothrow
{
    import sparkles.base.text.utf : decodeToken, encodeScalar, UtfMode, UtfStatus, UtfTokenKind;
    import sparkles.base.text.utf8 : validateUtf8;

    if (text.length <= limit && !validateUtf8(text).hasError)
        return text.idup;
    char[] fitted;
    size_t at;
    while (at < text.length)
    {
        const d = decodeToken(text[at .. $], UtfMode.replacement);
        if (d.result.status != UtfStatus.ok || d.result.consumed == 0)
            break;
        at += d.result.consumed;
        const scalar = d.token.kind == UtfTokenKind.scalar ? d.token.scalar : dchar(0xFFFD);
        char[4] units;
        const e = encodeScalar(scalar, units[], UtfMode.replacement);
        if (fitted.length + e.written > limit)
            break;
        fitted ~= units[0 .. e.written];
    }
    return (() @trusted => cast(string) fitted)();
}

///
@("ui_app.frame_title.fitTitle.cutsOnAScalarAndRepairs")
@safe pure nothrow unittest
{
    assert(fitTitle("Sparkles", 255) == "Sparkles");
    // "é" is two bytes: a limit between them keeps neither half.
    assert(fitTitle("caf\u00e9", 4) == "caf");
    assert(fitTitle("caf\u00e9", 5) == "caf\u00e9");
    // An ill-formed byte becomes U+FFFD, and the result is well-formed.
    assert(fitTitle("a\xffb", 255) == "a\uFFFDb");
}

/// The title-bar face's size: GNOME's 11 pt at 96 dpi, in CSS pixels.
enum float titleCssPx = 11 * 96 / 72.0f;

/// The fontconfig pattern the title face is matched by.
enum string titleFacePattern = "Adwaita Sans,Cantarell,sans-serif:bold";

/// A title set into coverage: `width` × `height` bytes, the baseline at
/// `baseline` pixels from the top.
struct TitleStrip
{
    ubyte[] coverage;       ///
    int width, height;      ///
    int baseline;           ///

    // What it was set from: set again when any of it changes.
    private string text_;
    private int room_, ppem_;
    // Whether it was cut to its room: one that was not stays as it is while
    // the room only grows or shrinks to its width, as a resize does.
    private bool cut_;
}

/// The title face and what setting a title in it needs, kept for the window's
/// life. `ready` is false when no face resolved or it could not be read.
struct TitleFace
{
    private const(ubyte)[] bytes_;
    private bool tried_;
    private Storage storage_;
    // The lookup `prepare` started, until `load` takes its result.
    private Lookup lookup_;

    /// Whether a face is loaded.
    bool ready() const @safe pure nothrow @nogc => bytes_.length > 0;

    /// Loads the face the font database matches `pattern` to, the first time
    /// only; a later call does nothing.
    void load(string pattern = titleFacePattern) @system
    {
        if (tried_)
            return;
        tried_ = true;
        if (lookup_ is null)
        {
            // Not prepared (a window that drew no frame of its own at
            // first), or its thread could not start: looked up here.
            bytes_ = lookUp(pattern);
            return;
        }
        lookup_.thread.join(false);
        bytes_ = lookup_.bytes;
        lookup_ = null;
    }

    /**
    Starts looking the face up on a thread of its own, for $(LREF load) to
    take. The font database is asked through `fc-match`, a process that
    took 25 ms: started with the window, it is done before the first frame
    wants the face.
    */
    void prepare(string pattern = titleFacePattern) @system
    {
        import core.thread : Thread;

        if (tried_ || lookup_ !is null)
            return;
        auto lookup = new Lookup;
        try
        {
            lookup.thread = new Thread(() { lookup.bytes = lookUp(pattern); });
            lookup.thread.isDaemon = true;
            lookup.thread.start();
        }
        catch (Exception)
            return; // no thread to spare: `load` looks the face up itself
        lookup_ = lookup;
    }

    // The bytes of the face the font database matches `pattern` to; empty
    // where none matches or it cannot be read.
    private static const(ubyte)[] lookUp(string pattern) @system nothrow
    {
        import std.file : read;
        import sparkles.raylib_text.font_resolve : resolveFontPath;

        try
        {
            const path = resolveFontPath(pattern);
            if (path.length)
                return cast(const(ubyte)[]) read(path);
        }
        catch (Exception)
        {
        }
        return null;
    }

    private static final class Lookup
    {
        import core.thread : Thread;

        Thread thread;
        const(ubyte)[] bytes;
    }

    /// Uses `bytes` as the face: for a test, or a face the host found itself.
    void use(const(ubyte)[] bytes) @safe pure nothrow @nogc
    {
        bytes_ = bytes;
        tried_ = true;
    }

    /**
    Sets `text` at `ppem` pixels per em into `strip`, at most `room` pixels
    wide: cut before the glyph that would pass it, with an ellipsis, and
    empty when not even that fits. Nothing is set when `strip` already
    holds the same text at the same room and size. `false` when the face
    cannot set it.
    */
    bool set(ref TitleStrip strip, const(char)[] text, int room, int ppem) @system
    {
        if (strip.text_ == text && strip.ppem_ == ppem
            && (strip.room_ == room || (!strip.cut_ && strip.width > 0 && room >= strip.width)))
            return true;
        strip.text_ = text.idup;
        strip.room_ = room;
        strip.ppem_ = ppem;
        strip.cut_ = false;
        strip.width = strip.height = 0;
        if (!ready || room <= 0 || ppem <= 0)
            return ready;

        auto face = openFace(bytes_);
        if (face.hasError)
            return false;
        auto cmap = charMap(face.value);
        if (cmap.hasError)
            return false;
        const size = Ppem.fromInteger(ppem);
        if (size.hasError)
            return false;
        // Bold on the weight axis where the face has one; a static face is
        // already the bold the pattern asked for.
        const bold = [UserCoordinate(Tag("wght"), 700 << 16)];
        auto inst = instance(face.value, InstanceSize.pixels(size.value), bold);
        if (inst.hasError)
            inst = instance(face.value, InstanceSize.pixels(size.value), null);
        if (inst.hasError)
            return false;
        auto points = new PointWorkspace;

        // The pen position after each glyph, in pixels, rounded once.
        static double pixels(long raw, ushort upem, int ppem)
            => raw / 65_536.0 / upem * ppem;
        uint[] glyphs;
        int[] pens;
        long design;
        int widthOf(uint gid, out bool ok)
        {
            const a = advance(inst.value, gid, *points);
            ok = a.hasValue;
            return ok ? cast(int)(pixels(design + a.value.design.raw, a.value.design.unitsPerEm, ppem)
                + 0.5) : 0;
        }
        bool ok;
        const ellipsis = cmap.value.glyph('…');
        const ellipsisWidth = ellipsis ? widthOf(ellipsis, ok) : 0;
        // Decoded with replacement: a title is set as given, and one that
        // is not UTF-8 shows U+FFFD rather than ending the frame.
        for (size_t read = 0; read < text.length;)
        {
            const d = decodeToken(text[read .. $], UtfMode.replacement);
            if (d.result.status != UtfStatus.ok || d.result.consumed == 0)
                break;
            read += d.result.consumed;
            const c = d.token.kind == UtfTokenKind.scalar ? d.token.scalar : dchar(0xFFFD);
            const gid = cmap.value.glyph(c);
            const m = advance(inst.value, gid, *points);
            if (m.hasError)
                return false;
            const a = m.value.design;
            const end = cast(int)(pixels(design + a.raw, a.unitsPerEm, ppem) + 0.5);
            if (end > room)
            {
                strip.cut_ = true;
                // Cut back until the ellipsis fits after what is kept.
                while (glyphs.length && pens[$ - 1] + ellipsisWidth > room)
                {
                    glyphs = glyphs[0 .. $ - 1];
                    pens = pens[0 .. $ - 1];
                }
                const at = pens.length ? pens[$ - 1] : 0;
                if (!ellipsis || at + ellipsisWidth > room)
                    return true;
                glyphs ~= ellipsis;
                pens ~= at + ellipsisWidth;
                break;
            }
            glyphs ~= gid;
            design += a.raw;
            pens ~= end;
        }
        if (!glyphs.length)
            return true;

        const lines = lineMetrics(inst.value);
        int ascent = ppem, descent = ppem / 4;
        if (lines.hasValue && lines.value.present)
        {
            const asc = lines.value.ascender.design, desc = lines.value.descender.design;
            ascent = cast(int)(pixels(asc.raw, asc.unitsPerEm, ppem) + 0.5);
            descent = cast(int)(-pixels(desc.raw, desc.unitsPerEm, ppem) + 0.5);
        }
        strip.width = pens[$ - 1];
        strip.height = ascent + descent;
        strip.baseline = ascent;
        strip.coverage.length = size_t(strip.width) * strip.height;
        strip.coverage[] = 0;

        ubyte[] scratch;
        foreach (i, gid; glyphs)
        {
            const pen = i ? pens[i - 1] : 0;
            auto measured = measure(inst.value, gid, size.value);
            if (measured.hasError || measured.value.empty)
                continue;
            const m = measured.value;
            if (scratch.length < size_t(m.width) * m.height)
                scratch.length = size_t(m.width) * m.height;
            scratch[0 .. size_t(m.width) * m.height] = 0;
            auto ws = storage_.workspace;
            auto drawn = rasterizeGlyph(inst.value, gid, size.value,
                RasterRegion(scratch, m.width, m.width, m.height), ws, FlattenPolicy.standard,
                OverlapMode.perGlyphFlag);
            if (drawn.hasError)
                continue;
            // Added into the strip, so overlapping neighbours keep both.
            foreach (y; 0 .. m.height)
            {
                const sy = ascent - drawn.value.bearingY + y;
                if (sy < 0 || sy >= strip.height)
                    continue;
                foreach (x; 0 .. m.width)
                {
                    const sx = pen + drawn.value.bearingX + x;
                    if (sx < 0 || sx >= strip.width)
                        continue;
                    ref cell = strip.coverage[size_t(sy) * strip.width + sx];
                    const sum = cell + scratch[size_t(y) * m.width + x];
                    cell = cast(ubyte)(sum > 255 ? 255 : sum);
                }
            }
        }
        return true;
    }

    // A glyph's box, growing the workspace when its outline needs more.
    private auto measure(in Instance inst, uint gid, Ppem ppem) @safe
    {
        foreach (attempt; 0 .. 6)
        {
            auto ws = storage_.workspace;
            auto r = rasterMeasure(inst, gid, ppem, ws, OverlapMode.perGlyphFlag);
            if (r.hasError && r.error.kind == FontErrorKind.limitExceeded
                && r.error.limit == FontLimit.callerStorage)
            {
                storage_.grow();
                continue;
            }
            if (r.hasValue)
                storage_.reserve(r.value.accumulationNeeded, r.value.supersampleNeeded);
            return r;
        }
        auto ws = storage_.workspace;
        return rasterMeasure(inst, gid, ppem, ws, OverlapMode.perGlyphFlag);
    }
}

// The rasterizer's caller-owned arrays, as the glyph atlas keeps them.
private struct Storage
{
    OutlineSegment[] segments;
    OutlinePoint[] points;
    bool[] onCurve;
    ushort[] contourEnds;
    float[] accumulation;
    ubyte[] supersample;
    uint[] pointNumbers;
    int[] deltaX, deltaY;
    int[2][] referenced;

    RasterWorkspace workspace() return @safe pure nothrow
    {
        if (!points.length)
            grow();
        return RasterWorkspace(segments, points, onCurve, contourEnds, accumulation, supersample,
            pointNumbers, deltaX, deltaY, referenced);
    }

    void grow() @safe pure nothrow
    {
        const n = points.length ? points.length * 2 : 1024;
        segments.length = 2 * n;
        points.length = n;
        onCurve.length = n;
        contourEnds.length = n / 4;
        pointNumbers.length = n;
        deltaX.length = n;
        deltaY.length = n;
        referenced.length = n;
    }

    void reserve(size_t accumulationNeeded, size_t supersampleNeeded) @safe pure nothrow
    {
        if (accumulation.length < accumulationNeeded)
            accumulation.length = accumulationNeeded;
        if (supersample.length < supersampleNeeded)
            supersample.length = supersampleNeeded;
    }
}

version (unittest)
{
    // A sans face the tests can rely on: DejaVu Sans, beside the cell fonts.
    private const(ubyte)[] testFace() @system
    {
        import std.file : exists, read;
        import std.path : buildPath;
        import std.process : environment;

        const dir = environment.get("SPARKLES_FONTS_PATH");
        assert(dir.length, "SPARKLES_FONTS_PATH names the bundled fonts");
        foreach (name; ["DejaVuSans-Bold.ttf", "DejaVuSans.ttf", "DejaVuSansMono.ttf"])
            if (dir.buildPath(name).exists)
                return cast(const(ubyte)[]) read(dir.buildPath(name));
        assert(0, "no DejaVu face in SPARKLES_FONTS_PATH");
    }
}

@("ui_app.frame_title.aTitleIsSetAtItsSizeNotTheWindows")
@system unittest
{
    TitleFace face;
    face.use(testFace());
    TitleStrip strip;
    assert(face.set(strip, "Sparkles Text Lab", 1000, 15));
    const w15 = strip.width, h15 = strip.height;
    assert(w15 > 100 && w15 < 200 && h15 >= 15 && h15 <= 22 && strip.baseline < h15);
    size_t inked;
    foreach (c; strip.coverage)
        inked += c > 128;
    assert(inked > 200, "the glyphs are drawn");
    // The room does not size the text: a wider window keeps the same strip,
    // set once — a resize does not set it again.
    strip.coverage[0] = 77; // a mark a second setting would clear
    assert(face.set(strip, "Sparkles Text Lab", 4000, 15) && strip.width == w15 && strip.height == h15);
    assert(face.set(strip, "Sparkles Text Lab", w15, 15) && strip.width == w15);
    assert(strip.coverage[0] == 77, "not set again");
    // Narrower than the title, it is cut; widened again, set whole again.
    assert(face.set(strip, "Sparkles Text Lab", w15 - 1, 15) && strip.width < w15);
    assert(face.set(strip, "Sparkles Text Lab", 4000, 15) && strip.width == w15);
    // Twice the pixels per em, about twice the width (a higher density).
    assert(face.set(strip, "Sparkles Text Lab", 4000, 30));
    assert(strip.width > 2 * w15 - 8 && strip.width < 2 * w15 + 8);
}

@("ui_app.frame_title.aLongTitleEndsInAnEllipsis")
@system unittest
{
    TitleFace face;
    face.use(testFace());
    TitleStrip full, cut;
    assert(face.set(full, "Sparkles Text Lab", 1000, 15));
    assert(face.set(cut, "Sparkles Text Lab", full.width / 2, 15));
    assert(cut.width > 0 && cut.width <= full.width / 2, "cut to the room, the ellipsis included");
    // And it ends in the ellipsis: the strip's last columns carry the ink an
    // ellipsis set alone does — a plain cut would end in a letter's.
    TitleStrip dots;
    assert(face.set(dots, "\u2026", 1000, 15) && dots.width > 0 && dots.height == cut.height);
    ulong tail, alone;
    foreach (y; 0 .. dots.height)
        foreach (x; 0 .. dots.width)
        {
            tail += cut.coverage[size_t(y) * cut.width + cut.width - dots.width + x];
            alone += dots.coverage[size_t(y) * dots.width + x];
        }
    assert(alone > 0 && tail >= alone * 9 / 10 && tail <= alone * 11 / 10);
    // A title that is not UTF-8 is set, U+FFFD for what is ill-formed.
    TitleStrip broken;
    assert(face.set(broken, "Lab \xff", 1000, 15) && broken.width > 0);
    TitleStrip none;
    assert(face.set(none, "Sparkles Text Lab", 3, 15) && none.width == 0, "no room, no title");
    TitleFace missing;
    assert(!missing.ready && !missing.set(none, "x", 100, 15));
}

@("ui_app.frame_title.loadWithoutPrepareLooksTheFaceUpItself")
@system unittest
{
    // A window that starts without a frame of its own never prepares; its
    // first framed draw loads, and finds what a prepared lookup finds (the
    // font database's fallback, for a pattern nothing matches).
    TitleFace f;
    f.load("/nonexistent/face.ttf");
    TitleFace g;
    g.prepare("/nonexistent/face.ttf");
    g.load();
    assert(f.ready == g.ready);
    const first = f.bytes_;
    f.load("Adwaita Sans");
    assert(f.bytes_ is first, "once only");
}

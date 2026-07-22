/// `FontSet` — the multi-face, on-demand raylib font resource shared by
/// `apps/terminal` and `hue --gui`. Extracted from the terminal's PR-#63 font
/// pipeline: a primary face plus real bold / italic / bold-italic variants, a
/// regular Unicode fallback, a Nerd-Font fallback, and up to 8 per-codepoint-map
/// faces; a base atlas grown lazily as new codepoints appear; and per-face
/// O(log n) glyph maps. All loading needs an active raylib GL context (call after
/// `InitWindow`). Holds move-only `SmallBuffer`s, so it is non-copyable — declare
/// one instance and pass it by `ref`.
module sparkles.raylib_text.font_set;

import raylib;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.raylib_text.atlas : baseCodepoints;
import sparkles.raylib_text.font : LoadedFont, loadFontInto, loadVariantFile,
    fontHasGlyph, glyphIndexFor, rangesContain;

/// The face chosen for a cell's bold/italic attributes, plus whether the missing
/// axis must still be faked (a synthetic slant / a double-strike thickening)
/// because no dedicated face was loaded for it.
struct StyledFace
{
    LoadedFont* font;
    bool fakeBold;
    bool fakeItalic;
}

/// A `--font-codepoint-map` entry: a sorted set of codepoints rendered from a
/// specific font, overriding the primary/styled faces for those codepoints
/// (mirrors Ghostty's font-codepoint-map).
struct CodepointMap
{
    SmallBuffer!(int, 256, true) cps; /// sorted codepoints this entry claims
    LoadedFont font;                  /// the mapped face (loaded with exactly `cps`)
}

/// Maximum number of `--font-codepoint-map` entries.
enum MAX_CODEPOINT_MAPS = 8;

/// The multi-face font resource. See the module header.
struct FontSet
{
    @disable this(this); // holds move-only SmallBuffers

    // Static base codepoint set (used to reload the fallback fonts).
    private immutable(int)[] codepoints;

    // Codepoints requested from the PRIMARY atlas: seeded with the base set and
    // grown on demand as new codepoints appear (e.g. Material Design Icons in the
    // U+F0000+ plane), keeping the atlas bounded to glyphs the session touches.
    private SmallBuffer!(int, 8192, true) requestedCps;

    // Sorted codepoint coverage of the primary FACE, parsed from fc-query
    // (ascending lo/hi range bounds). A missing glyph is re-requested from the
    // primary only when the face actually covers it; else it falls through to the
    // fallback chain (and ultimately '?').
    private SmallBuffer!(int, 256, true) faceLo;
    private SmallBuffer!(int, 256, true) faceHi;

    // Per-frame on-demand request set (owned here so both consumers just call
    // requestGlyph / flushPending; de-duped within a frame).
    private SmallBuffer!(int, 64, true) pending;

    private int fontSize_ = 20;
    private int cellW_ = 1;
    private int cellH_ = 1;

    private LoadedFont primary;        // primary (regular) face
    private LoadedFont fontBold;       // same family, bold        — empty if unavailable
    private LoadedFont fontItalic;     // same family, italic       — empty if unavailable
    private LoadedFont fontBoldItalic; // same family, bold+italic — empty if unavailable
    private LoadedFont regularFallback;
    private LoadedFont nerdFallback;

    private CodepointMap[MAX_CODEPOINT_MAPS] codepointMaps;
    private int codepointMapCount;

    // ── accessors ────────────────────────────────────────────────────────────

    int cellW() const @safe pure nothrow @nogc => cellW_;
    int cellH() const @safe pure nothrow @nogc => cellH_;
    int size() const @safe pure nothrow @nogc => fontSize_;

    /// Direct access to the primary raylib `Font`, for callers that measure/draw
    /// with it outside the run/cell path (e.g. an overlay banner).
    ref inout(Font) primaryFont() inout return @safe pure nothrow @nogc => primary.font;

    // ── loading ──────────────────────────────────────────────────────────────

    /**
    Resolve `nameOrPath` (a font file, family name, or fontconfig preference
    list) and load the whole face set at `fontSizePx`: the primary + real
    bold/italic/bold-italic variants (found by scanning the primary's directory),
    a regular and a Nerd-Font fallback, and any `--font-codepoint-map` entries.
    Returns `false` (leaving the caller to error out) only if the primary can't be
    resolved or loaded. Must run after `InitWindow`. `@system`, GC-allocating.
    */
    static bool tryLoad(string nameOrPath, int fontSizePx, out FontSet fs,
        string[] codepointMapOpt = null) @system
    {
        import std.file : exists;
        import std.process : execute;
        import std.string : strip, toStringz, splitLines;
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

        fs.fontSize_ = fontSizePx < 1 ? 1 : fontSizePx;
        fs.codepoints = baseCodepoints;
        foreach (cp; baseCodepoints)
            fs.requestedCps ~= cp;
        fs.loadFaceCharset(fontPath);

        fs.primary.pathZ = fontPath.toStringz;
        loadFontInto(fs.primary, fs.fontSize_, fs.requestedCps[]);
        if (!fs.primary.present)
            return false;

        // Real bold/italic/bold-italic faces of the same family.
        fs.loadStyleVariants(fontPath);
        // Optional --font-codepoint-map fonts.
        fs.parseCodepointMaps(codepointMapOpt);

        // Fallbacks: the first Nerd Font and first common regular monospace.
        auto fbRes = execute(["fc-match", "-f", "%{file}\\n", "monospace", "-s"]);
        if (fbRes.status == 0)
        {
            foreach (line; fbRes.output.splitLines)
            {
                string path = line.strip.idup;
                if (path.length == 0 || path == fontPath)
                    continue;
                const isNerd = path.canFind("NerdFont") || path.canFind("Nerd Font");
                if (isNerd && !fs.nerdFallback.present)
                {
                    fs.nerdFallback.pathZ = path.toStringz;
                    loadFontInto(fs.nerdFallback, fs.fontSize_, fs.codepoints);
                }
                else if (!isNerd && !fs.regularFallback.present
                    && (path.canFind("DejaVu") || path.canFind("FreeMono")
                        || path.canFind("LiberationMono")))
                {
                    fs.regularFallback.pathZ = path.toStringz;
                    loadFontInto(fs.regularFallback, fs.fontSize_, fs.codepoints);
                }
                if (fs.nerdFallback.present && fs.regularFallback.present)
                    break;
            }
        }

        fs.measure();
        return true;
    }

    /// Reload every loaded face at `newSizePx` (Ctrl-±): primary + styled with the
    /// grown request set, fallbacks with the base set, codepoint maps with their
    /// own sets; then re-measure the cell.
    void reload(int newSizePx) @system nothrow @nogc
    {
        fontSize_ = newSizePx < 1 ? 1 : newSizePx;
        loadFontInto(primary, fontSize_, requestedCps[]);
        if (fontBold.pathZ !is null) loadFontInto(fontBold, fontSize_, requestedCps[]);
        if (fontItalic.pathZ !is null) loadFontInto(fontItalic, fontSize_, requestedCps[]);
        if (fontBoldItalic.pathZ !is null) loadFontInto(fontBoldItalic, fontSize_, requestedCps[]);
        if (regularFallback.pathZ !is null) loadFontInto(regularFallback, fontSize_, codepoints);
        if (nerdFallback.pathZ !is null) loadFontInto(nerdFallback, fontSize_, codepoints);
        foreach (i; 0 .. codepointMapCount)
            loadFontInto(codepointMaps[i].font, fontSize_, codepointMaps[i].cps[]);
        measure();
    }

    /// Unload every loaded face.
    void unload() @system nothrow @nogc
    {
        if (primary.present) { UnloadFont(primary.font); primary.present = false; }
        if (fontBold.present) { UnloadFont(fontBold.font); fontBold.present = false; }
        if (fontItalic.present) { UnloadFont(fontItalic.font); fontItalic.present = false; }
        if (fontBoldItalic.present) { UnloadFont(fontBoldItalic.font); fontBoldItalic.present = false; }
        if (regularFallback.present) { UnloadFont(regularFallback.font); regularFallback.present = false; }
        if (nerdFallback.present) { UnloadFont(nerdFallback.font); nerdFallback.present = false; }
        foreach (i; 0 .. codepointMapCount)
            if (codepointMaps[i].font.present)
            {
                UnloadFont(codepointMaps[i].font.font);
                codepointMaps[i].font.present = false;
            }
    }

    // ── render path ──────────────────────────────────────────────────────────

    /// Queue `cp` for inclusion in the primary atlas on the next `flushPending`,
    /// de-duping within the frame (many cells share the same icon).
    void requestGlyph(int cp) @safe nothrow @nogc
    {
        foreach (existing; pending[])
            if (existing == cp)
                return;
        pending ~= cp;
    }

    /// After `EndDrawing`, grow the atlas with any codepoints requested this frame
    /// and reload the primary + styled faces in lockstep. Returns `true` if a
    /// reload happened (the caller should repaint next frame). Never call
    /// mid-frame — reloading the atlas texture there would drop the frame.
    bool flushPending() @system nothrow @nogc
    {
        if (pending.length == 0)
            return false;
        foreach (cp; pending[])
            requestedCps ~= cp;
        pending.clear();
        loadFontInto(primary, fontSize_, requestedCps[]);
        if (fontBold.pathZ !is null) loadFontInto(fontBold, fontSize_, requestedCps[]);
        if (fontItalic.pathZ !is null) loadFontInto(fontItalic, fontSize_, requestedCps[]);
        if (fontBoldItalic.pathZ !is null) loadFontInto(fontBoldItalic, fontSize_, requestedCps[]);
        return true;
    }

    /**
    Resolve the face to draw codepoint `cp` with, for the given bold/italic
    attributes — the exact routing the terminal's glyph pass uses:
    font-codepoint-map override → real styled face (faking the missing axis) →
    regular/Nerd fallback → on-demand request from the primary if the face covers
    it. `fakeBold`/`fakeItalic` report whether the caller must synthesize that
    axis (no dedicated face). Returns a pointer into this `FontSet` (valid until
    the next reload).
    */
    LoadedFont* resolveFace(int cp, bool bold, bool italic,
        out bool fakeBold, out bool fakeItalic) @system nothrow @nogc
    {
        fakeBold = false;
        fakeItalic = false;

        // font-codepoint-map overrides everything for its codepoints; mapped fonts
        // carry no styled variants, so bold/italic on them is faked.
        if (auto mapped = lookupCodepointMap(cp))
        {
            fakeBold = bold;
            fakeItalic = italic;
            return mapped;
        }

        auto sf = pickStyledFace(bold, italic);
        LoadedFont* active = sf.font;
        fakeBold = sf.fakeBold;
        fakeItalic = sf.fakeItalic;

        if (cp >= 128 && !fontHasGlyph(*active, cp))
        {
            if (regularFallback.present && fontHasGlyph(regularFallback, cp))
                active = &regularFallback;
            else if (nerdFallback.present && fontHasGlyph(nerdFallback, cp))
                active = &nerdFallback;
            else if (faceHasCodepoint(cp))
                requestGlyph(cp); // primary face has it; load it on demand
        }
        return active;
    }

    /// The white-texel face for `drawSolid` batching (the primary).
    ref LoadedFont whiteFace() return @safe pure nothrow @nogc => primary;

    // ── private helpers (rehomed from apps/terminal's ref CoreState) ──────────

    private StyledFace pickStyledFace(bool bold, bool italic) @system nothrow @nogc
    {
        if (bold && italic)
        {
            if (fontBoldItalic.present) return StyledFace(&fontBoldItalic, false, false);
            if (fontItalic.present)     return StyledFace(&fontItalic, true, false);  // real italic, fake bold
            if (fontBold.present)       return StyledFace(&fontBold, false, true);    // real bold, fake italic
            return StyledFace(&primary, true, true);
        }
        if (italic)
            return fontItalic.present ? StyledFace(&fontItalic, false, false)
                : StyledFace(&primary, false, true);
        if (bold)
            return fontBold.present ? StyledFace(&fontBold, false, false)
                : StyledFace(&primary, true, false);
        return StyledFace(&primary, false, false);
    }

    private LoadedFont* lookupCodepointMap(int cp) @system nothrow @nogc
    {
        import std.range : assumeSorted;
        foreach (i; 0 .. codepointMapCount)
        {
            auto m = &codepointMaps[i];
            if (m.font.present && m.cps[].assumeSorted.contains(cp))
                return &m.font;
        }
        return null;
    }

    private bool faceHasCodepoint(int cp) @safe nothrow @nogc
        => rangesContain(faceLo[], faceHi[], cp);

    private void measure() @system nothrow @nogc
    {
        const m = MeasureTextEx(primary.font, "M".ptr, fontSize_, 0);
        cellW_ = cast(int) m.x < 1 ? 1 : cast(int) m.x;
        cellH_ = cast(int) m.y < 1 ? 1 : cast(int) m.y;
    }

    // Parse the primary FACE's coverage from fc-query into the sorted lo/hi
    // buffers. Best-effort: on failure the buffers stay empty (on-demand requesting
    // simply disabled).
    private void loadFaceCharset(string fontPath) @system
    {
        import std.process : execute;
        import std.string : strip, split, indexOf;
        import std.conv : to;

        auto res = execute(["fc-query", "--format=%{charset}", fontPath]);
        if (res.status != 0)
            return;
        foreach (tok; res.output.strip.split)
        {
            if (tok.length == 0)
                continue;
            const dash = tok.indexOf('-');
            try
            {
                if (dash < 0)
                {
                    const v = tok.to!int(16);
                    faceLo ~= v;
                    faceHi ~= v;
                }
                else
                {
                    faceLo ~= tok[0 .. dash].to!int(16);
                    faceHi ~= tok[dash + 1 .. $].to!int(16);
                }
            }
            catch (Exception) { /* skip a malformed token, keep the rest */ }
        }
    }

    // Resolve/load the bold/italic/bold-italic faces of the SAME family as the
    // primary by scanning the primary's directory with fc-scan and matching on
    // family + weight + slant (works even for fonts fontconfig hasn't registered).
    private void loadStyleVariants(string fontPath) @system
    {
        import std.process : execute;
        import std.string : strip, splitLines, split, join;
        import std.conv : to;
        import std.path : dirName;

        string pFamily;
        int pWeight, pSlant;
        {
            auto q = execute(["fc-query", "--format=%{family[0]}\n%{weight}\n%{slant}", fontPath]);
            if (q.status != 0) return;
            auto lines = q.output.splitLines;
            if (lines.length < 3) return;
            pFamily = lines[0].strip.idup;
            try { pWeight = lines[1].strip.to!int; pSlant = lines[2].strip.to!int; }
            catch (Exception) return;
        }
        if (pFamily.length == 0) return;

        auto sc = execute(["fc-scan", "--format=%{file}:%{family[0]}:%{weight}:%{slant}\n", fontPath.dirName]);
        if (sc.status != 0) return;

        // fontconfig bold is weight 200; italic/oblique is any non-zero slant.
        string boldPath, italicPath, boldItalicPath;
        foreach (line; sc.output.splitLines)
        {
            auto parts = line.split(':');
            if (parts.length < 4) continue;
            const file = parts[0];
            if (file == fontPath) continue; // the regular face, already loaded
            const fam = parts[1 .. $ - 2].join(':').strip;
            if (fam != pFamily) continue;
            int w, sl;
            try { w = parts[$ - 2].strip.to!int; sl = parts[$ - 1].strip.to!int; }
            catch (Exception) continue;

            if (w == 200 && sl == pSlant) { if (boldPath.length == 0) boldPath = file.idup; }
            else if (w == pWeight && sl != pSlant) { if (italicPath.length == 0) italicPath = file.idup; }
            else if (w == 200 && sl != pSlant) { if (boldItalicPath.length == 0) boldItalicPath = file.idup; }
        }

        loadVariantFile(fontBold, boldPath, fontSize_, requestedCps[]);
        loadVariantFile(fontItalic, italicPath, fontSize_, requestedCps[]);
        loadVariantFile(fontBoldItalic, boldItalicPath, fontSize_, requestedCps[]);
    }

    // Parse `--font-codepoint-map` entries (`<ranges>=<family>`) and load each
    // mapped font, accepting only families fontconfig actually has installed.
    private void parseCodepointMaps(string[] entries) @system
    {
        import std.process : execute;
        import std.string : strip, split, indexOf, lastIndexOf, startsWith, toLower, toStringz;
        import std.conv : to;
        import std.algorithm : sort, uniq, canFind;
        import std.array : array;
        import std.file : exists;

        foreach (entry; entries)
        {
            if (codepointMapCount >= MAX_CODEPOINT_MAPS)
                break;
            const eq = entry.lastIndexOf('=');
            if (eq <= 0)
                continue;
            const family = entry[eq + 1 .. $].strip;
            if (family.length == 0)
                continue;

            int[] cps;
            foreach (rawTok; entry[0 .. eq].split(','))
            {
                auto tok = rawTok.strip;
                if (!tok.startsWith("U+") && !tok.startsWith("u+"))
                    continue;
                tok = tok[2 .. $];
                const dash = tok.indexOf('-');
                try
                {
                    if (dash < 0)
                        cps ~= tok.to!int(16);
                    else
                    {
                        auto hiTok = tok[dash + 1 .. $].strip;
                        if (hiTok.startsWith("U+") || hiTok.startsWith("u+"))
                            hiTok = hiTok[2 .. $];
                        immutable a = tok[0 .. dash].to!int(16);
                        immutable b = hiTok.to!int(16);
                        for (int c = a; c <= b; c++)
                            cps ~= c;
                    }
                }
                catch (Exception) { /* skip malformed token */ }
            }
            if (cps.length == 0)
                continue;
            cps = cps.sort.uniq.array;

            auto res = execute(["fc-match", "-f", "%{file}\t%{family}", family]);
            if (res.status != 0)
                continue;
            auto fields = res.output.strip.split("\t");
            if (fields.length < 2)
                continue;
            const path = fields[0];
            if (path.length == 0 || !path.exists)
                continue;
            if (!fields[1].toLower.canFind(family.toLower))
                continue; // fontconfig substituted a different family → not installed

            auto m = &codepointMaps[codepointMapCount];
            foreach (c; cps)
                m.cps ~= c;
            m.font.pathZ = path.idup.toStringz;
            loadFontInto(m.font, fontSize_, m.cps[]);
            if (!m.font.present)
            {
                m.font.pathZ = null;
                m.cps.clear();
                continue;
            }
            codepointMapCount++;
        }
    }
}

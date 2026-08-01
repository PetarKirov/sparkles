/// `FontSet` — the multi-face, on-demand raylib font resource shared by
/// `apps/terminal` and `hue --gui`. Extracted from the terminal's PR-#63 font
/// pipeline: a primary face plus real bold / italic / bold-italic variants, a
/// regular Unicode fallback, a Nerd-Font fallback, and up to 8 per-codepoint-map
/// faces; a base atlas grown lazily as new codepoints appear; and per-face
/// O(log n) glyph maps. All loading needs an active raylib GL context (call after
/// `InitWindow`). Holds move-only `SmallBuffer`s, so it is non-copyable — declare
/// one instance and pass it by `ref`.
///
/// Face $(I resolution) (name → file path) has two strategies, selected by
/// `FontSet.FontSources`: the desktop default shells out to fontconfig
/// (`fc-match`/`fc-query`/`fc-scan`), while `useFontconfig: false` (Android:
/// no fontconfig, no subprocesses) scans plain font directories —
/// `resolveFontInDirs` for names, `fontVariantPaths` for styled siblings,
/// `<font>.charset` sidecar files for coverage. Face $(I loading) is the same
/// on both: real file paths into `LoadFontEx`.
module sparkles.raylib_text.font_set;

import raylib;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, endsWith;
import std.string : indexOf, strip, split, toLower;

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
    /// Explicit per-style face selection (ghostty's `font-family-bold` /
    /// `-italic` / `-bold-italic`): a family name, fontconfig pattern, or
    /// file path per styled face; empty = auto-detect from the primary.
    static struct FaceOverrides
    {
        string bold, italic, boldItalic;
    }

    /// Where face resolution looks for font files. The default — no dirs,
    /// `useFontconfig: true` — preserves the desktop behavior exactly
    /// (fc-match/fc-query/fc-scan subprocesses). With `useFontconfig: false`
    /// (Android: no fontconfig, and subprocesses are unavailable) names
    /// resolve by scanning `dirs` in order (`resolveFontInDirs`), styled
    /// variants by the sibling-file naming convention (`fontVariantPaths`),
    /// and the primary's coverage from a `<font>.charset` sidecar (written at
    /// build time from `fc-query --format=%{charset}`; without one, on-demand
    /// atlas growth is simply disabled).
    static struct FontSources
    {
        string[] dirs;
        bool useFontconfig = true;
    }

    static bool tryLoad(string nameOrPath, int fontSizePx, out FontSet fs,
        string[] codepointMapOpt = null,
        FaceOverrides faces = FaceOverrides.init,
        FontSources sources = FontSources.init) @system
    {
        import std.file : exists;
        import std.process : execute;
        import std.string : toStringz, splitLines;

        string fontPath = nameOrPath;
        if (!fontPath.exists)
        {
            if (sources.useFontconfig)
            {
                auto res = execute(["fc-match", "-f", "%{file}", nameOrPath]);
                if (res.status == 0 && res.output.strip.length > 0)
                    fontPath = res.output.strip.idup;
            }
            else
                fontPath = resolveFontInDirs(nameOrPath, sources.dirs);
        }
        if (fontPath.length == 0 || !fontPath.exists)
            return false;

        fs.fontSize_ = fontSizePx < 1 ? 1 : fontSizePx;
        fs.codepoints = baseCodepoints;
        foreach (cp; baseCodepoints)
            fs.requestedCps ~= cp;
        fs.loadFaceCharset(fontPath, sources.useFontconfig);

        fs.primary.pathZ = fontPath.toStringz;
        loadFontInto(fs.primary, fs.fontSize_, fs.requestedCps[]);
        if (!fs.primary.present)
            return false;

        // Explicit per-style faces first (they win); the same-family scan
        // then fills only the still-empty slots.
        fs.loadFaceOverride(fs.fontBold, faces.bold, "bold", sources);
        fs.loadFaceOverride(fs.fontItalic, faces.italic, "italic", sources);
        fs.loadFaceOverride(fs.fontBoldItalic, faces.boldItalic, "bold:italic", sources);
        // Real bold/italic/bold-italic faces of the same family.
        fs.loadStyleVariants(fontPath, sources);
        // Optional --font-codepoint-map fonts.
        fs.parseCodepointMaps(codepointMapOpt, sources);

        if (sources.useFontconfig)
        {
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
        }
        else
            fs.loadFallbacksFromDirs(fontPath, sources.dirs);

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

        // font-codepoint-map overrides everything for its codepoints; mapped
        // fonts carry no styled variants — bold double-strikes, italic
        // renders upright (a synthetic slant/shift breaks the grid).
        if (auto mapped = lookupCodepointMap(cp))
        {
            fakeBold = bold;
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
        // No fake italic anywhere: a missing italic face renders the upright
        // regular (a synthetic slant/shift breaks grid alignment and made
        // tokens appear to move between themes). Bold still double-strikes.
        if (bold && italic)
        {
            if (fontBoldItalic.present) return StyledFace(&fontBoldItalic, false, false);
            if (fontItalic.present)     return StyledFace(&fontItalic, true, false); // real italic, fake bold
            if (fontBold.present)       return StyledFace(&fontBold, false, false);  // real bold, upright
            return StyledFace(&primary, true, false);
        }
        if (italic)
            return fontItalic.present ? StyledFace(&fontItalic, false, false)
                : StyledFace(&primary, false, false);
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

    // Parse the primary FACE's coverage into the sorted lo/hi buffers — from
    // fc-query, or (no fontconfig) from a `<fontPath>.charset` sidecar written
    // at build time. Best-effort: on failure the buffers stay empty (on-demand
    // requesting simply disabled).
    private void loadFaceCharset(string fontPath, bool useFontconfig) @system
    {
        import std.process : execute;

        if (!useFontconfig)
        {
            import std.file : exists, readText;

            const sidecar = fontPath ~ ".charset";
            if (!sidecar.exists)
                return;
            try
                parseCharsetTokens(readText(sidecar), faceLo, faceHi);
            catch (Exception) { /* unreadable sidecar → growth disabled */ }
            return;
        }

        auto res = execute(["fc-query", "--format=%{charset}", fontPath]);
        if (res.status != 0)
            return;
        parseCharsetTokens(res.output, faceLo, faceHi);
    }

    // Load one explicitly-selected styled face: a file path directly, else a
    // fontconfig pattern (`<spec>:style` when the spec names no style) — or,
    // without fontconfig, a directory-scan resolution of the bare spec.
    private void loadFaceOverride(ref LoadedFont target, string spec,
        string style, in FontSources sources) @system
    {
        import std.file : exists;
        import std.process : execute;

        if (spec.length == 0)
            return;
        string path = spec;
        if (!path.exists)
        {
            if (sources.useFontconfig)
            {
                const pattern = spec.canFind(':') ? spec : spec ~ ":" ~ style;
                auto res = execute(["fc-match", "-f", "%{file}", pattern]);
                if (res.status != 0 || res.output.strip.length == 0)
                    return;
                path = res.output.strip.idup;
            }
            else
            {
                // Directory scan: resolve the family, then the STYLED sibling
                // (fontVariantPaths) — a bare family override would otherwise
                // land every style on the Regular file. No sibling → no
                // override; the fake-bold/upright-italic fallbacks apply.
                const base = resolveFontInDirs(spec, sources.dirs);
                if (base.length == 0)
                    return;
                string b, i, bi;
                fontVariantPaths(base, b, i, bi);
                path = style == "bold" ? b : style == "italic" ? i : bi;
            }
        }
        if (path.length == 0)
            return;
        loadVariantFile(target, path, fontSize_, requestedCps[]);
    }

    // Resolve/load the bold/italic/bold-italic faces of the SAME family as the
    // primary: with fontconfig by scanning the primary's directory with fc-scan
    // and matching on family + weight + slant (works even for fonts fontconfig
    // hasn't registered); without it by the sibling-file naming convention
    // (`fontVariantPaths`).
    private void loadStyleVariants(string fontPath, in FontSources sources) @system
    {
        import std.process : execute;
        import std.string : splitLines, join;
        import std.conv : to;
        import std.path : dirName;

        if (!sources.useFontconfig)
        {
            string boldPath, italicPath, boldItalicPath;
            fontVariantPaths(fontPath, boldPath, italicPath, boldItalicPath);
            if (!fontBold.present)
                loadVariantFile(fontBold, boldPath, fontSize_, requestedCps[]);
            if (!fontItalic.present)
                loadVariantFile(fontItalic, italicPath, fontSize_, requestedCps[]);
            if (!fontBoldItalic.present)
                loadVariantFile(fontBoldItalic, boldItalicPath, fontSize_, requestedCps[]);
            return;
        }

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

        if (!fontBold.present)
            loadVariantFile(fontBold, boldPath, fontSize_, requestedCps[]);
        if (!fontItalic.present)
            loadVariantFile(fontItalic, italicPath, fontSize_, requestedCps[]);
        if (!fontBoldItalic.present)
            loadVariantFile(fontBoldItalic, boldItalicPath, fontSize_, requestedCps[]);
    }

    // Fallback faces without fontconfig: the best-ranked Nerd-Font file in
    // `dirs` that is not the primary, and the first family of a fixed
    // common-mono preference list (the stand-in for `fc-match monospace -s`).
    private void loadFallbacksFromDirs(string fontPath, const(string)[] dirs) @system
    {
        import std.string : toStringz;

        // RANKED, not first-hit. `fontFilesInDirs` sorts within a directory,
        // so taking the first Nerd-named file picked whatever sorted first —
        // and with `FiraCodeNerdFontMono-{Bold,Regular}.ttf` both shipped,
        // 'B' < 'R' meant every fallback icon glyph rendered BOLD. The
        // fontconfig path cannot do this: `fc-match monospace -s` returns
        // regular faces in preference order.
        string bestNerd;
        int bestNerdRank = int.max;
        foreach (path; fontFilesInDirs(dirs))
        {
            if (path == fontPath)
                continue;
            if (!path.canFind("NerdFont") && !path.canFind("Nerd Font"))
                continue;
            // A fallback supplies glyphs the primary lacks, so it wants the
            // plainest face available: an explicit Regular, else anything
            // undecorated, else a styled face as a last resort.
            const rank = isRegularFace(path) ? 0 : (isUndecoratedFace(path) ? 1 : 2);
            if (rank < bestNerdRank)
            {
                bestNerd = path;
                bestNerdRank = rank;
            }
        }
        // Keep trying on a failed load rather than giving up on the fallback
        // entirely — the fontconfig loop re-tests `present` for this reason.
        if (bestNerd.length != 0 && !nerdFallback.present)
        {
            nerdFallback.pathZ = bestNerd.toStringz;
            loadFontInto(nerdFallback, fontSize_, codepoints);
        }
        const regular = resolveFontInDirs(
            "DejaVu Sans Mono,Roboto Mono,Droid Sans Mono,Liberation Mono,Cousine",
            dirs);
        if (regular.length != 0 && regular != fontPath && !regularFallback.present)
        {
            regularFallback.pathZ = regular.toStringz;
            loadFontInto(regularFallback, fontSize_, codepoints);
        }
    }

    // Parse `--font-codepoint-map` entries (`<ranges>=<family>`) and load each
    // mapped font, accepting only families fontconfig actually has installed
    // (without fontconfig: only families the directory scan resolves).
    private void parseCodepointMaps(string[] entries, in FontSources sources) @system
    {
        import std.process : execute;
        import std.string : lastIndexOf, startsWith, toStringz;
        import std.conv : to;
        import std.algorithm : sort, uniq;
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

            string path;
            if (sources.useFontconfig)
            {
                auto res = execute(["fc-match", "-f", "%{file}\t%{family}", family]);
                if (res.status != 0)
                    continue;
                auto fields = res.output.strip.split("\t");
                if (fields.length < 2)
                    continue;
                path = fields[0].idup;
                if (!fields[1].toLower.canFind(family.toLower))
                    continue; // fontconfig substituted a different family → not installed
            }
            else
                path = resolveFontInDirs(family, sources.dirs);
            if (path.length == 0 || !path.exists)
                continue;

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

// ── fontconfig-free resolution helpers (pure directory/name logic) ───────────

/// Lowercase with spaces and dashes stripped — the normalization under which a
/// family name ("FiraCode Nerd Font Mono") matches a font file's basename
/// ("FiraCodeNerdFontMono-Regular").
private string normalizeFontName(scope const(char)[] s) @safe pure
{
    import std.ascii : toLower;
    import std.array : array;
    import std.utf : byChar;

    return s.byChar.filter!(c => c != ' ' && c != '-').map!(c => c.toLower).array.idup;
}

/// The `.ttf`/`.otf` files under `dirs` (shallow, sorted per dir for
/// determinism), scanned in order — earlier dirs win.
///
/// An unreadable or vanishing directory is skipped, not propagated:
/// `dirEntries` throws on a directory it cannot open, and `exists`/`isDir`
/// can race with it, so without the catch a font directory with the wrong
/// permissions would turn `FontSet.tryLoad` — documented to return `false`
/// when it cannot resolve a font — into a startup exception. (Collections,
/// `.ttc`, are excluded because raylib's `LoadFontEx` cannot load them.)
private string[] fontFilesInDirs(const(string)[] dirs) @safe
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : dirEntries, exists, isDir, SpanMode;
    import std.path : extension;

    string[] result;
    foreach (dir; dirs)
    {
        try
        {
            if (!dir.exists || !dir.isDir)
                continue;
            auto files = dirEntries(dir, SpanMode.shallow)
                .map!(e => e.name)
                .filter!((string p) {
                    const ext = p.extension.toLower;
                    return ext == ".ttf" || ext == ".otf";
                })
                .array;
            sort(files);
            result ~= files;
        }
        catch (Exception) { /* unreadable dir → skip it, keep the rest */ }
    }
    return result;
}

/**
Resolve a font family name — or a fontconfig-style comma-separated preference
list ("FiraCode Nerd Font Mono,JetBrains Mono,monospace") — against plain
directories of font files, without fontconfig. For each name in order, the
candidates are files whose normalized basename contains the normalized name;
among them the best-ranked wins ($(LREF faceRank)). Returns the first name's
winner, or `""` when nothing matches (generic aliases like "monospace" match
no file and simply fall through to the next name).

Ties keep the earlier candidate, so the caller's directory order is the
tie-breaker — `fontFilesInDirs` yields earlier directories first, which is
the precedence it documents. (Comparing paths lexicographically instead, as
this once did, silently handed the decision to whichever absolute path sorted
first: hue's `[<dataDir>/fonts, /system/fonts]` only worked because `/data`
happens to precede `/system`.)
*/
/// (Public deliberately: `apps/terminal --font-dir` resolves through it, so
/// this is API, not an implementation detail. Its siblings —
/// `fontVariantPaths`, `parseCharsetTokens` — stay private until something
/// outside the module asks for them.)
string resolveFontInDirs(const(char)[] nameOrList, const(string)[] dirs) @safe
{
    import std.path : baseName, stripExtension;

    const files = fontFilesInDirs(dirs);
    foreach (rawName; nameOrList.split(','))
    {
        const name = normalizeFontName(rawName.strip);
        if (name.length == 0)
            continue;

        string best;
        int bestRank = int.max;
        foreach (path; files)
        {
            const rank = faceRank(path, name);
            if (rank < bestRank)
            {
                best = path;
                bestRank = rank;
            }
        }
        if (best.length != 0)
            return best;
    }
    return "";
}

/// How well the font file at `path` answers to the normalized family
/// `name` — lower is better, `int.max` for "not a candidate at all":
/// an exact stem match, then an explicit `…-Regular` face, then a stem that
/// merely *starts* with the name, then any undecorated stem, then anything
/// containing it. `int.max` when the name does not appear.
///
/// The `startsWith` tier matters against a system font directory: plain
/// containment lets a short family name match a superset family (`"Mono"`
/// inside `MapleMono-Regular`), and with ~200 `Noto*` files on Android an
/// absent family would otherwise resolve to an arbitrary unrelated one.
private int faceRank(scope const(char)[] path, scope const(char)[] name) @safe
{
    import std.algorithm.searching : startsWith;
    import std.path : baseName, stripExtension;

    const stem = normalizeFontName(path.baseName.stripExtension);
    if (!stem.canFind(name))
        return int.max;
    if (stem == name)
        return 0;
    if (stem == name ~ "regular")
        return 1;
    const undecorated = isUndecoratedFace(path);
    if (stem.startsWith(name))
        return undecorated ? 2 : 4;
    return undecorated ? 3 : 5;
}

/// `true` when the file's stem names an explicit `Regular` face.
private bool isRegularFace(scope const(char)[] path) @safe
{
    import std.algorithm.searching : endsWith;
    import std.path : baseName, stripExtension;

    return normalizeFontName(path.baseName.stripExtension).endsWith("regular");
}

/// `true` when the file's stem carries no weight/slant decoration — the
/// closest thing to "the plain face" when no explicit Regular exists.
private bool isUndecoratedFace(scope const(char)[] path) @safe
{
    import std.path : baseName, stripExtension;

    const stem = normalizeFontName(path.baseName.stripExtension);
    return !stem.canFind("bold") && !stem.canFind("italic")
        && !stem.canFind("oblique");
}

// A collision-free scratch directory. The runner executes tests in parallel
// *threads*, which a fixed name survives — but two concurrent test
// *processes* (a CI matrix leg beside a local `dub test`, or a retried job)
// would share it, and one run's `rmdirRecurse` would delete the other's
// fixture mid-assert.
version (unittest)
private string uniqueTestDir(string stem) @safe
{
    import std.file : tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    return buildPath(tempDir, stem ~ "-" ~ randomUUID().toString());
}

@("resolveFontInDirs.preferenceListAndRanking")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    const dir = uniqueTestDir("sparkles-font-resolve-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    foreach (f; ["FiraCodeNerdFontMono-Regular.ttf", "FiraCodeNerdFontMono-Bold.ttf",
        "FiraCodeNerdFontMono-Italic.ttf", "DejaVuSansMono.ttf", "notafont.txt"])
        write(buildPath(dir, f), "x");

    // Preference list: first resolvable name wins; the -Regular face beats
    // the styled siblings; generic "monospace" matches nothing and falls
    // through.
    assert(resolveFontInDirs("monospace,FiraCode Nerd Font Mono", [dir])
        == buildPath(dir, "FiraCodeNerdFontMono-Regular.ttf"));
    // Exact stem match (no -Regular suffix on the file).
    assert(resolveFontInDirs("DejaVu Sans Mono", [dir])
        == buildPath(dir, "DejaVuSansMono.ttf"));
    // Unresolvable everything → "".
    assert(resolveFontInDirs("Comic Sans,monospace", [dir]) == "");
    // Non-font files are never candidates.
    assert(resolveFontInDirs("notafont", [dir]) == "");
    // Missing dirs are skipped, not errors.
    assert(resolveFontInDirs("DejaVu Sans Mono", [buildPath(dir, "absent"), dir])
        == buildPath(dir, "DejaVuSansMono.ttf"));
}

@("resolveFontInDirs.dirPrecedenceBeatsPathOrder")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    // Two directories holding the SAME family at the same rank. The caller's
    // order must decide — not which absolute path sorts first, which is what
    // a lexicographic tie-break did (hue passes [<dataDir>/fonts,
    // /system/fonts] and only worked because "/data" precedes "/system").
    const root = uniqueTestDir("sparkles-font-precedence-test");
    const zFirst = buildPath(root, "zzz");
    const aSecond = buildPath(root, "aaa");
    mkdirRecurse(zFirst);
    mkdirRecurse(aSecond);
    scope (exit) rmdirRecurse(root);
    write(buildPath(zFirst, "SomeMono-Regular.ttf"), "x");
    write(buildPath(aSecond, "SomeMono-Regular.ttf"), "x");

    // Listed first wins, despite sorting later.
    assert(resolveFontInDirs("SomeMono", [zFirst, aSecond])
        == buildPath(zFirst, "SomeMono-Regular.ttf"));
    // …and symmetrically.
    assert(resolveFontInDirs("SomeMono", [aSecond, zFirst])
        == buildPath(aSecond, "SomeMono-Regular.ttf"));
}

@("resolveFontInDirs.prefixBeatsInteriorMatch")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    const dir = uniqueTestDir("sparkles-font-prefix-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    // "Mono" appears inside MapleMono but at the START of MonoLisa.
    write(buildPath(dir, "MapleMono-Regular.ttf"), "x");
    write(buildPath(dir, "MonoLisa-Regular.ttf"), "x");

    // Without a startsWith tier both are rank-1 and the tie went to whichever
    // came first — an arbitrary family. This matters against /system/fonts,
    // where ~200 Noto* files make interior matches abundant.
    assert(resolveFontInDirs("Mono", [dir]) == buildPath(dir, "MonoLisa-Regular.ttf"));
    // An exact family still wins outright.
    assert(resolveFontInDirs("Maple Mono", [dir]) == buildPath(dir, "MapleMono-Regular.ttf"));
}

/**
The sibling-file naming convention that stands in for fc-scan: given the
primary face's path, the styled variants are `<Base>-Bold`, `-Italic` (or
`-Oblique`), and `-BoldItalic` (or `-BoldOblique`) next to it, where `<Base>`
is the primary's stem minus a trailing `-Regular`. Nerd-Font and DejaVu
releases both follow it. Out-params are `""` when the file does not exist.
*/
private void fontVariantPaths(string primaryPath,
    out string bold, out string italic, out string boldItalic) @safe
{
    import std.file : exists;
    import std.path : baseName, buildPath, dirName, extension, stripExtension;

    const dir = primaryPath.dirName;
    const ext = primaryPath.extension;
    string stem = primaryPath.baseName.stripExtension;
    if (stem.toLower.endsWith("-regular"))
        stem = stem[0 .. $ - "-Regular".length];

    string pick(scope string[] suffixes...) @safe
    {
        foreach (s; suffixes)
        {
            const p = buildPath(dir, stem ~ s ~ ext);
            if (p.exists)
                return p;
        }
        return "";
    }

    bold = pick("-Bold");
    italic = pick("-Italic", "-Oblique");
    boldItalic = pick("-BoldItalic", "-BoldOblique");
}

@("fontVariantPaths.namingConvention")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    const dir = uniqueTestDir("sparkles-font-variant-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    foreach (f; ["Mono-Regular.ttf", "Mono-Bold.ttf", "Mono-BoldOblique.ttf",
        "Solo.otf", "Solo-Italic.otf"])
        write(buildPath(dir, f), "x");

    string b, i, bi;
    // -Regular stem: bold present, italic absent, bold-italic via -BoldOblique.
    fontVariantPaths(buildPath(dir, "Mono-Regular.ttf"), b, i, bi);
    assert(b == buildPath(dir, "Mono-Bold.ttf"));
    assert(i == "");
    assert(bi == buildPath(dir, "Mono-BoldOblique.ttf"));
    // Bare stem (no -Regular), .otf, only italic present.
    fontVariantPaths(buildPath(dir, "Solo.otf"), b, i, bi);
    assert(b == "");
    assert(i == buildPath(dir, "Solo-Italic.otf"));
    assert(bi == "");
}

/// Parse fontconfig charset syntax (space-separated `lo-hi` hex ranges and
/// bare hex singletons — `fc-query --format=%{charset}` output, also the
/// `<font>.charset` sidecar format) into the sorted lo/hi bound buffers.
/// Malformed tokens are skipped, the rest kept.
private void parseCharsetTokens(const(char)[] text,
    ref SmallBuffer!(int, 256, true) lo, ref SmallBuffer!(int, 256, true) hi) @safe
{
    import std.conv : to;

    foreach (tok; text.strip.split)
    {
        if (tok.length == 0)
            continue;
        const dash = tok.indexOf('-');
        try
        {
            if (dash < 0)
            {
                const v = tok.to!int(16);
                lo ~= v;
                hi ~= v;
            }
            else
            {
                lo ~= tok[0 .. dash].to!int(16);
                hi ~= tok[dash + 1 .. $].to!int(16);
            }
        }
        catch (Exception) { /* skip a malformed token, keep the rest */ }
    }
}

@("parseCharsetTokens.rangesSingletonsMalformed")
@safe unittest
{
    SmallBuffer!(int, 256, true) lo, hi;
    parseCharsetTokens("20-7e a0 100-17f zz 1f600-1f64f", lo, hi);
    assert(lo[] == [0x20, 0xa0, 0x100, 0x1f600]);
    assert(hi[] == [0x7e, 0xa0, 0x17f, 0x1f64f]);

    SmallBuffer!(int, 256, true) lo2, hi2;
    parseCharsetTokens("", lo2, hi2);
    assert(lo2.length == 0 && hi2.length == 0);
}

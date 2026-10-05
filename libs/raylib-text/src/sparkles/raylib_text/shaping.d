/// Cached HarfBuzz clusters and FreeType color/outline glyphs. File discovery is
/// startup-only; misses are queued during drawing and realized after EndDrawing.
/// Complete spans retain HarfBuzz's zero-advance default-ignorable placeholders
/// so subsequent combining marks keep their shaped positions even in long clusters.
module sparkles.raylib_text.shaping;

import raylib;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.raylib_text.font_discovery : FontSources;
import sparkles.raylib_text.shaping_api;

/// Explicit text presentation wins over the default emoji presentation. Bare
/// text-default symbols stay in the user's face until VS16 requests emoji.
package bool emojiPresentation(scope const(uint)[] cps) @safe pure nothrow @nogc
{
    import sparkles.base.text.unicode_tables : isEmojiVsBase, isEastAsianWide;
    if (!cps.length) return false;
    bool emoji = (cps[0] >= 0x1f000 && cps[0] <= 0x1faff
        && isEastAsianWide(cast(dchar) cps[0]))
        || (isEmojiVsBase(cast(dchar) cps[0]) && isEastAsianWide(cast(dchar) cps[0]))
        || (cps[0] >= 0x1f1e6 && cps[0] <= 0x1f1ff);
    foreach (cp; cps)
    {
        if (cp == 0xfe0e) emoji = false;
        if (cp == 0xfe0f && isEmojiVsBase(cast(dchar) cps[0])) emoji = true;
        if (cp == 0x20e3 && (cps[0] == '#' || cps[0] == '*' ||
            (cps[0] >= '0' && cps[0] <= '9'))) emoji = true;
    }
    return emoji;
}

@("shaping.presentation.selectorsAndSequences")
@safe pure nothrow @nogc unittest
{
    assert(!emojiPresentation([0x2764u]));
    assert(emojiPresentation([0x2764u, 0xfe0f]));
    assert(!emojiPresentation([0x2764u, 0xfe0f, 0xfe0e]));
    assert(!emojiPresentation([cast(uint) 'A', 0xfe0f]));
    assert(emojiPresentation([0x1f1fau, 0x1f1f8]));
    assert(emojiPresentation([0x1f469u, 0x200d, 0x1f4bb]));
    assert(emojiPresentation([cast(uint) '1', 0xfe0f, 0x20e3]));
    assert(!emojiPresentation([cast(uint) 'e', 0x301]));
}

package struct ClusterCache
{
    @disable this(this);

    private struct Candidate
    {
        const(char)* path;
        int index;
        STFace* face;
        bool attempted;
        bool emoji;
    }
    private struct Entry
    {
        ulong hash;
        size_t next, start, count;
        const(char)* preferred;
        Texture2D texture;
        Rectangle source;
        float ascent;
        int left, top;
        bool ready, valid, color;
    }
    private struct Page
    {
        Texture2D texture;
        int x = 1, y = 1, rowHeight;
    }
    private UniqueBuffer!(Page, 8) pages;
    private Candidate[] candidates;
    private STLibrary* library;
    private int pixels;
    private UniqueBuffer!(Entry, 128) entries;
    private UniqueBuffer!(uint, 1024) points;
    private UniqueBuffer!(size_t, 256) buckets;
    private size_t realized;

    /// Catalog every installed file, not just fc-match's coverage-pruned list:
    /// sequence coverage and ligatures cannot be inferred from scalar coverage.
    void initialize(scope const(char)*[] preferred, FontSources sources, int px) @system
    {
        import std.string : toStringz, splitLines, strip;
        import sparkles.base.text.case_text : asciiLower, unicodeLower;
        import std.algorithm.searching : canFind;
        import std.file : dirEntries, SpanMode;
        import std.path : extension;
        import std.conv : to;
        import sparkles.raylib_text.font_fontconfig : fcRun;

        pixels = px;
        library = st_library_create();
        if (library is null) return;
        string[] paths;
        void append(string path)
        {
            if (path.length && !paths.canFind(path)) paths ~= path;
        }
        foreach (path; preferred)
            if (path !is null) append(to!string(path));
        string[] dirs = sources.dirs.dup;
        if (sources.useSystemFontDb)
        {
            version (OSX)
            {
                import std.process : environment;
                dirs ~= ["/System/Library/Fonts", "/Library/Fonts",
                    environment.get("HOME", "") ~ "/Library/Fonts"];
            }
            else
            {
                auto res = fcRun(["fc-list", "-f", "%{file}\\n"]);
                if (res.status == 0)
                    foreach (line; res.output.splitLines) append(line.strip.idup);
            }
        }
        foreach (dir; dirs)
        {
            try
                foreach (entry; dirEntries(dir, SpanMode.breadth))
                {
                    const ext = entry.name.extension.asciiLower;
                    if (ext == ".ttf" || ext == ".otf" || ext == ".ttc"
                        || ext == ".otc" || ext == ".dfont") append(entry.name);
                }
            catch (Exception) { /* optional font directories may not exist */ }
        }
        foreach (path; paths)
        {
            const z = path.toStringz;
            const ext = path.extension.asciiLower;
            const count = ext == ".ttc" || ext == ".otc" || ext == ".dfont"
                ? st_face_count(library, z) : 1;
            foreach (index; 0 .. count)
                candidates ~= Candidate(z, index, null, false,
                    path.unicodeLower.canFind("emoji"));
        }
        buckets.length = 256;
        auto slots = buckets[];
        slots[] = 0;
    }

    /// True for a queued or drawn cluster, false only if no installed face can
    /// render it. Cache hits neither allocate nor copy codepoints.
    bool draw(scope const(uint)[] cps, const(char)* preferred,
        float x, float y, int width, int height, float scale, Color tint)
        @system nothrow @nogc
    {
        if (library is null || cps.length == 0) return false;
        ulong hash = 14695981039346656037UL ^ cast(size_t) preferred;
        foreach (cp; cps) hash = (hash ^ cp) * 1099511628211UL;
        auto slot = cast(size_t) hash & (buckets.length - 1);
        for (auto link = buckets[slot]; link; link = entries[link - 1].next)
        {
            auto entry = &entries[link - 1];
            if (entry.hash != hash || entry.preferred != preferred || entry.count != cps.length
                || points[entry.start .. entry.start + entry.count] != cps) continue;
            if (!entry.ready) return true;
            if (!entry.valid) return false;
            if (!entry.texture.id) return true;
            float drawScale = scale;
            // Fit wide emoji/CJK into the terminal-assigned cell span, never
            // manufacture advances by summing the members of a cluster.
            const right = entry.left + entry.source.width;
            if (right * drawScale > width && right > 0)
                drawScale = cast(float) width / right;
            if (entry.color && entry.source.height * drawScale > height)
                drawScale = cast(float) height / entry.source.height;
            const dx = x + entry.left * drawScale;
            const dy = entry.color
                ? y + (height - entry.source.height * drawScale) * 0.5f
                : y + entry.ascent * scale - entry.top * drawScale;
            const color = entry.color ? Color(255, 255, 255, tint.a) : tint;
            DrawTexturePro(entry.texture,
                entry.source,
                Rectangle(dx, dy, entry.source.width * drawScale, entry.source.height * drawScale),
                Vector2(0, 0), 0, color);
            return true;
        }
        Entry entry;
        entry.hash = hash;
        entry.preferred = preferred;
        entry.start = points.length;
        entry.count = cps.length;
        entry.next = buckets[slot];
        points ~= cps;
        entries ~= entry;
        buckets[slot] = entries.length;
        if (entries.length > buckets.length * 2)
        {
            buckets.length = buckets.length * 2;
            auto slots = buckets[];
            slots[] = 0;
            foreach (i, ref e; entries[])
            {
                slot = cast(size_t) e.hash & (buckets.length - 1);
                e.next = buckets[slot];
                buckets[slot] = i + 1;
            }
        }
        return true;
    }

    private STFace* face(ref Candidate candidate) @system nothrow @nogc
    {
        if (!candidate.attempted)
        {
            candidate.face = st_face_open(library, candidate.path, candidate.index, pixels);
            candidate.attempted = true;
        }
        return candidate.face;
    }

    private bool render(ref Entry entry, ref Candidate candidate,
        scope const(uint)[] cps) @system nothrow @nogc
    {
        auto f = face(candidate);
        if (f is null) return false;
        auto bitmap = st_shape(f, cps.ptr, cps.length);
        scope (exit) st_bitmap_free(&bitmap);
        if (!bitmap.valid) return false;
        if (bitmap.rgba !is null && bitmap.width > 0 && bitmap.height > 0)
        {
            if (!upload(entry, bitmap)) return false;
        }
        entry.left = bitmap.left;
        entry.top = bitmap.top;
        entry.ascent = st_face_ascent(f);
        entry.color = bitmap.color != 0;
        entry.valid = true;
        return true;
    }

    // Shelf-packed pages keep a Unicode sweep in a handful of textures, so
    // adjacent clusters batch together. Uploads happen only after EndDrawing.
    // A transparent pixel on every side isolates bilinear-filtered glyphs.
    private bool upload(ref Entry entry, ref const STBitmap bitmap)
        @system nothrow @nogc
    {
        if (!pages.empty)
        {
            auto page = &pages[$ - 1];
            if (page.x + bitmap.width + 1 > page.texture.width)
            {
                page.x = 1;
                page.y += page.rowHeight;
                page.rowHeight = 0;
            }
        }
        if (pages.empty || pages[$ - 1].y + bitmap.height + 1 > pages[$ - 1].texture.height
            || bitmap.width + 2 > pages[$ - 1].texture.width)
        {
            import std.algorithm.comparison : max;
            const width = max(1024, bitmap.width + 2);
            const height = max(1024, bitmap.height + 2);
            Image image = GenImageColor(width, height, Color(0, 0, 0, 0));
            if (image.data is null) return false;
            scope (exit) UnloadImage(image);
            auto texture = LoadTextureFromImage(image);
            if (!texture.id) return false;
            SetTextureFilter(texture, TextureFilter.TEXTURE_FILTER_BILINEAR);
            pages ~= Page(texture);
        }
        auto page = &pages[$ - 1];
        entry.texture = page.texture;
        entry.source = Rectangle(page.x, page.y, bitmap.width, bitmap.height);
        UpdateTextureRec(page.texture, entry.source, bitmap.rgba);
        page.x += bitmap.width + 2;
        if (page.rowHeight < bitmap.height + 2)
            page.rowHeight = bitmap.height + 2;
        return true;
    }

    bool flush() @system nothrow @nogc
    {
        import core.stdc.string : strcmp;
        const changed = realized != entries.length;
        while (realized < entries.length)
        {
            auto entry = &entries[realized++];
            const cps = points[entry.start .. entry.start + entry.count];
            const emoji = emojiPresentation(cps);
            // Emoji sequences must reach a color face before a monochrome face
            // that contains the individual scalars but no sequence ligature.
            if (emoji)
                foreach (ref candidate; candidates)
                    if (candidate.emoji && render(*entry, candidate, cps)) break;
            if (!entry.valid && entry.preferred !is null)
                foreach (ref candidate; candidates)
                    if (strcmp(candidate.path, entry.preferred) == 0
                        && render(*entry, candidate, cps)) break;
            // Prefer explicit scalar coverage among fallback faces. Complex
            // script shapers may synthesize missing characters, so retain a
            // second pass for those rather than rejecting them by cmap alone.
            if (!entry.valid && cps.length == 1)
                foreach (ref candidate; candidates)
                    if (st_face_has(face(candidate), cps[0])
                        && render(*entry, candidate, cps)) break;
            if (!entry.valid)
                foreach (ref candidate; candidates)
                    if ((cps.length != 1 || !st_face_has(face(candidate), cps[0]))
                        && render(*entry, candidate, cps)) break;
            entry.ready = true;
        }
        return changed;
    }

    void reload(int px) @system nothrow @nogc
    {
        clearResources();
        pixels = px;
    }

    private void clearResources() @system nothrow @nogc
    {
        foreach (ref page; pages[])
            UnloadTexture(page.texture);
        pages.clear();
        foreach (ref candidate; candidates)
        {
            if (candidate.face !is null) st_face_close(candidate.face);
            candidate.face = null;
            candidate.attempted = false;
        }
        entries.clear();
        points.clear();
        auto slots = buckets[];
        slots[] = 0;
        realized = 0;
    }

    void unload() @system nothrow @nogc
    {
        clearResources();
        if (library !is null) st_library_destroy(library);
        library = null;
        candidates = null;
    }
}

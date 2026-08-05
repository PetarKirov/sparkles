// The composition core's Whole (`PIP2`/`D11`): one `Document` value every sink
// agrees on, produced by one loader — replacing the four copies of the
// read → detect → highlight → parse pipeline that `app.main`, its GUI
// `loadDoc` closure, the twoslash mode and the gallery each carried, and the
// scattered mode flags (`isMarkdownPreview`, `--twoslash`, `--raw`) that stood
// in for "what kind of content is this".
//
// A document's `kind` is detected from the content itself (a `*.twoslash.json`
// payload IS a twoslash document; a `.md` file IS markdown), with the CLI
// flags reduced to detection inputs. Backends then differ only in how they
// paint the same value — the backend is a sink choice, not a pipeline.
module document;

import std.algorithm.searching : endsWith, startsWith;
import std.conv : text;
import std.file : readText;
import std.path : baseName, extension;
import std.string : chompPrefix;

import sparkles.base.logger : warning;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.diff : DiffDoc, diffText, emitPatch, parsePatch;
import sparkles.syntax : canonicalLanguage, GrammarRegistry, HighlightEvent,
    highlightInjected, MdBlock, ResolvedTheme, RgbColor, TsConfigCache;
import sparkles.twoslash : loadTwoslashFile, TwoslashReturn;

import gui_preview : PreviewModel;

/// What a document *is* — detected from the content, not selected by a mode
/// switch. Kinds compose the way tree-sitter injections do (markdown embeds
/// twoslash fences embeds markdown docs); this is the top-level kind.
enum ContentKind : ubyte
{
    code,     /// syntax-highlighted source
    markdown, /// the decorated markdown preview (a `.md` file's default)
    twoslash, /// a TypeScript twoslash payload rendered as a type overlay
    diff,     /// a computed or parsed diff rendered as the diff view (`MOD9`)
}

/// One loaded document: the Whole that owns everything the old pipelines kept
/// in loose parallel locals (source ‖ events ‖ model ‖ payload).
struct Document
{
    string path;             /// on-disk origin ("" for embedded sources)
    string title;            /// display name (the base name)
    ContentKind kind;
    string source;           /// the display text (a twoslash payload's `code`)
    string lang;             /// canonical language of `source`
    HighlightEvent[] events; /// highlight stream over `source`
    TwoslashReturn twoslash; /// `kind == twoslash`: the node payload
    PreviewModel preview;    /// `kind == markdown`: the structural model
    /// `kind == diff`: the diff model; `source` holds the patch text (the
    /// raw / fallback view)
    DiffDoc diffDoc;
}

/**
The one loader. Owns the policy inputs (`--markdown` forces the markdown kind,
`--raw` suppresses it) and borrows the grammar registry/cache, so every
consumer — the up-front document, set navigation, the gallery — runs the same
pipeline. Load failures throw; the CLI shell reports them once.
*/
struct DocumentPipeline
{
    GrammarRegistry* registry;
    TsConfigCache* cache;
    bool forceMarkdown; /// `--markdown`
    bool raw;           /// `--raw` (wins over `forceMarkdown`/`forcePatch`)
    bool forcePatch;    /// `--patch`: the input is a unified diff

@system:

    /// The kind `path` will load as. `forceTwoslash` is the `--twoslash`
    /// compatibility flag; the payload extension needs no flag.
    ContentKind detect(string path, bool forceTwoslash = false) const
    {
        if (forceTwoslash || path.endsWith(".twoslash.json"))
            return ContentKind.twoslash;
        if (!raw)
        {
            const ext = path.extension.chompPrefix(".");
            if (forcePatch || ext == "patch" || ext == "diff")
                return ContentKind.diff;
            if (forceMarkdown || canonicalLanguage(ext) == "markdown")
                return ContentKind.markdown;
        }
        return ContentKind.code;
    }

    /// Loads `path`: read → detect → highlight → parse the kind's artifacts.
    Document load(string path, bool forceTwoslash = false)
    {
        final switch (detect(path, forceTwoslash)) with (ContentKind)
        {
            case twoslash:
                auto twRes = loadTwoslashFile(path);
                if (twRes.hasError)
                    throw new Exception(twRes.error.toString);
                Document doc = {
                    path: path, title: baseName(path), kind: twoslash,
                    source: twRes.value.code, lang: twRes.value.effectiveLanguage,
                    twoslash: twRes.value,
                };
                doc.events = highlight(doc.lang, doc.source);
                return doc;
            case diff:
                return fromPatchSource(path, baseName(path), readText(path));
            case markdown:
            case code:
                return fromSource(path, baseName(path), readText(path),
                    canonicalLanguage(path.extension.chompPrefix(".")));
        }
    }

    /// A diff document from unified-patch text (`DVS2`: a `.patch`/`.diff`
    /// file, `--patch`, or sniffed stdin). `source` keeps the raw patch — the
    /// `--raw` view and the not-yet-diff-aware interactive panes show it.
    Document fromPatchSource(string path, string title, string patchText)
    {
        auto res = parsePatch(patchText);
        if (res.hasError)
            throw new Exception(text("invalid patch at byte ", res.error.offset,
                res.error.context.length ? ": " ~ res.error.context : ""));
        Document doc = {
            path: path, title: title, kind: ContentKind.diff,
            source: patchText, lang: "diff", diffDoc: res.value,
        };
        doc.events = highlight(doc.lang, doc.source, quietFallback: true);
        return doc;
    }

    /// A diff document from two files, computed in-process (`DVS1`) — no VCS
    /// involved. `source` carries the equivalent emitted patch so raw views,
    /// selection and `--diff-copy=patch` all have a textual identity — and,
    /// since the `@nogc` model **borrows** its backing text (`DVM8`), the
    /// document re-parses that owned patch so `diffDoc` references `source`
    /// (which this `Document` keeps alive) rather than transient file reads.
    Document loadDiffPair(string oldPath, string newPath)
    {
        const oldText = readText(oldPath);
        const newText = readText(newPath);
        auto computed = diffText(oldText, newText, oldPath, newPath);
        SmallBuffer!char patchBuf;
        emitPatch(computed, patchBuf);
        string source = patchBuf[].idup;

        auto res = parsePatch(source);
        if (res.hasError) // emitter output always parses; stay total anyway
            throw new Exception(text("internal: emitted patch failed to parse at byte ",
                res.error.offset));
        Document doc = {
            path: newPath, title: text(oldPath, " → ", newPath),
            kind: ContentKind.diff, source: source, lang: "diff",
            diffDoc: res.value,
        };
        doc.events = highlight(doc.lang, doc.source, quietFallback: true);
        return doc;
    }

    /// A document from in-memory source (the embedded self-view). Detection
    /// runs on the language, not a path.
    Document fromSource(string path, string title, string source, string lang)
    {
        Document doc = {
            path: path, title: title, source: source, lang: lang,
            kind: !raw && (forceMarkdown || lang == "markdown")
                ? ContentKind.markdown : ContentKind.code,
        };
        doc.events = highlight(lang, source);
        if (doc.kind == ContentKind.markdown)
        {
            doc.preview = buildMdPreview(source);
            // A degenerate preview — e.g. a pure VitePress YAML front-matter
            // page, which the model does not model (MDP17) — renders as
            // nothing in every sink. Fall back to the raw highlighted view
            // rather than showing an empty document (totality: RND5).
            if (!hasRenderableContent(doc.preview.doc.root))
            {
                doc.kind = ContentKind.code;
                doc.preview = PreviewModel.init;
            }
        }
        return doc;
    }

    /// `true` iff the block tree yields any visible preview content — an
    /// inline span, a fence body, or a table (a lone thematic break or
    /// consumed front-matter does not count).
    private static bool hasRenderableContent(in MdBlock b) @safe pure nothrow @nogc
    {
        if (b.inlines.length || b.codeBody.end > b.codeBody.start)
            return true;
        foreach (ref const c; b.children)
            if (hasRenderableContent(c))
                return true;
        return false;
    }

    private HighlightEvent[] highlight(string lang, scope const(char)[] source,
        bool quietFallback = false)
    {
        SmallBuffer!HighlightEvent ev;
        if (highlightInjected(*cache, lang, source, ev).hasError)
        {
            // A synthesized language (the diff documents' "diff") degrades
            // silently — the miss is the expected default, not a user's
            // grammar gap (`DEG2`).
            if (!quietFallback)
                warning(i"no grammar for '$(lang)' — rendering as plain text");
            ev ~= HighlightEvent.sourceSpan(0, source.length);
        }
        return ev[].dup;
    }

    /// Build the markdown preview model, supplying the off-screen-VT
    /// ansi-fence decoder only on a GUI-enabled build (`gui_ansi.decodeAnsi`
    /// pulls sparkles:ghostty). Without it, ` ```ansi ` fences degrade to
    /// stripped plain text (see gui_preview).
    PreviewModel buildMdPreview(scope const(char)[] source)
    {
        import gui_preview : buildPreviewModel;

        version (HueGui)
        {
            import gui_ansi : decodeAnsi;

            return buildPreviewModel(*registry, *cache, source, &decodeAnsi);
        }
        else
            return buildPreviewModel(*registry, *cache, source);
    }
}

/**
`DVS2`'s stdin content sniff: does this text look like a unified diff?
Line-anchored within the first 64 lines — a `diff --git` header, a hunk
header, or a `--- ` line later followed by `+++ `.
*/
bool looksLikePatch(scope const(char)[] content) @safe pure nothrow @nogc
{
    bool sawOldHeader = false;
    size_t lineStart = 0, lines = 0;
    foreach (i; 0 .. content.length + 1)
    {
        if (i != content.length && content[i] != '\n')
            continue;
        auto line = content[lineStart .. i];
        lineStart = i + 1;
        if (++lines > 64)
            return false;
        if (line.startsWith("diff --git ") || line.startsWith("@@ -"))
            return true;
        if (line.startsWith("--- "))
            sawOldHeader = true;
        else if (sawOldHeader && line.startsWith("+++ "))
            return true;
        else if (!line.startsWith("--- "))
            sawOldHeader = false;
    }
    return false;
}

@("document.looksLikePatch.sniff")
@safe pure nothrow @nogc
unittest
{
    assert(looksLikePatch("diff --git a/x b/x\n--- a/x\n"));
    assert(looksLikePatch("--- a/x\n+++ b/x\n@@ -1 +1 @@\n"));
    assert(looksLikePatch("@@ -1,2 +1,2 @@\n x\n"));
    assert(!looksLikePatch("just some text\nwith --- dashes inline\n"));
    assert(!looksLikePatch("# markdown\n\n--- \n")); // separator, no +++ after
    assert(!looksLikePatch(""));
}

@("document.detect.kindFromContentNotFlags")
@system unittest
{
    // Detection is pure policy — no I/O needed to test it.
    DocumentPipeline p;
    assert(p.detect("x.twoslash.json") == ContentKind.twoslash);
    assert(p.detect("x.json") == ContentKind.code);
    assert(p.detect("notes.md") == ContentKind.markdown);
    assert(p.detect("app.d") == ContentKind.code);
    // The compatibility flag forces the twoslash kind for any path.
    assert(p.detect("payload.json", forceTwoslash: true) == ContentKind.twoslash);

    // A `.patch`/`.diff` extension is a diff document; `--patch` forces it.
    assert(p.detect("fix.patch") == ContentKind.diff);
    assert(p.detect("changes.diff") == ContentKind.diff);
    DocumentPipeline patchP = { forcePatch: true };
    assert(patchP.detect("captured.txt") == ContentKind.diff);

    // `--raw` wins over the extension; `--markdown` forces the preview.
    DocumentPipeline rawP = { raw: true };
    assert(rawP.detect("notes.md") == ContentKind.code);
    assert(rawP.detect("fix.patch") == ContentKind.code);
    DocumentPipeline mdP = { forceMarkdown: true };
    assert(mdP.detect("README") == ContentKind.markdown);
}

/**
The fence renderer for hue's markdown widget view: ` ```ansi ` fences carry
pre-styled terminal output — without an off-screen VT (the `no-gui` build and
these static sinks) their SGR is stripped to plain text; every other language
goes through the shared injection-aware highlighter.
*/
auto hueFenceRenderer(TsConfigCache* cache, const(ResolvedTheme)* theme,
    RgbColor pageFg) @system
{
    import gui_preview : stripSgr;
    import sparkles.syntax.md.render_widgets : highlightedFenceRenderer;
    import sparkles.ui.widget : TextSpan;

    auto highlight = highlightedFenceRenderer(cache, theme, pageFg);
    return delegate TextSpan[][] (const(char)[] lang, const(char)[] body_) @trusted {
        if (lang != "ansi")
            return highlight(lang, body_);
        // Strip SGR, one plain span per line.
        const plain = stripSgr(body_);
        TextSpan[][] lines;
        size_t start = 0;
        foreach (i, char c; plain)
            if (c == '\n')
            {
                lines ~= [TextSpan(plain[start .. i], fg: pageFg, hasFg: true)];
                start = i + 1;
            }
        if (start < plain.length)
            lines ~= [TextSpan(plain[start .. $], fg: pageFg, hasFg: true)];
        return lines;
    };
}

@("document.frontmatterOnlyFallsBackToRaw")
@system unittest
{
    // A pure VitePress front-matter page yields no renderable markdown
    // content — the pipeline degrades it to the raw highlighted view
    // instead of an empty preview (MDP17 records front-matter as unmodeled).
    import sparkles.syntax : LabelSet;

    DocumentPipeline p;
    auto reg = GrammarRegistry.fromEnvironment();
    const labels = LabelSet.standard();
    auto cache = TsConfigCache.create(&reg, labels);
    p.registry = &reg;
    p.cache = &cache;

    auto doc = p.fromSource("x.md", "x.md",
        "---\nlayout: home\nhero:\n  name: Sparkles\n---\n", "markdown");
    assert(doc.kind == ContentKind.code, "degenerate preview falls back to raw");

    auto real_ = p.fromSource("y.md", "y.md", "# Title\n\nbody\n", "markdown");
    assert(real_.kind == ContentKind.markdown);
}

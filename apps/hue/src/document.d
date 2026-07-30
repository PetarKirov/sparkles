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

import std.algorithm.searching : endsWith;
import std.file : readText;
import std.path : baseName, extension;
import std.string : chompPrefix;

import sparkles.base.logger : warning;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.syntax : canonicalLanguage, GrammarRegistry, HighlightEvent,
    highlightInjected, ResolvedTheme, RgbColor, TsConfigCache;
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
    bool raw;           /// `--raw` (wins over `forceMarkdown`)

@system:

    /// The kind `path` will load as. `forceTwoslash` is the `--twoslash`
    /// compatibility flag; the payload extension needs no flag.
    ContentKind detect(string path, bool forceTwoslash = false) const
    {
        if (forceTwoslash || path.endsWith(".twoslash.json"))
            return ContentKind.twoslash;
        if (!raw && (forceMarkdown
                || canonicalLanguage(path.extension.chompPrefix(".")) == "markdown"))
            return ContentKind.markdown;
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
                    throw new Exception(twRes.error.msg);
                Document doc = {
                    path: path, title: baseName(path), kind: twoslash,
                    source: twRes.value.code, lang: "typescript",
                    twoslash: twRes.value,
                };
                doc.events = highlight(doc.lang, doc.source);
                return doc;
            case markdown:
            case code:
                return fromSource(path, baseName(path), readText(path),
                    canonicalLanguage(path.extension.chompPrefix(".")));
        }
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
            doc.preview = buildMdPreview(source);
        return doc;
    }

    private HighlightEvent[] highlight(string lang, scope const(char)[] source)
    {
        SmallBuffer!HighlightEvent ev;
        if (highlightInjected(*cache, lang, source, ev).hasError)
        {
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

    // `--raw` wins over the extension; `--markdown` forces the preview.
    DocumentPipeline rawP = { raw: true };
    assert(rawP.detect("notes.md") == ContentKind.code);
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

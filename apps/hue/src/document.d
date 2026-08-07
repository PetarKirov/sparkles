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
import diff_session : buildDiffSession, DiffSession;
import diff_commutative : CommutativeKind, defaultCommutativeKinds;
import diff_structural : StructuralPolicy;
import sparkles.diff : DiffDoc, DiffOptions, diffText, emitPatch, FileEntry,
    parsePatch, RowKind, WhitespaceMode;
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
    /// `kind == diff`: per-file side texts for `DVM5` composition,
    /// parallel to `diffDoc.files` (an empty entry renders plain rows).
    DiffSides[] diffSides;
    /// `kind == diff`: the changed-file session (`DVS4`) — status, counts,
    /// fold state and per-file errors, parallel to `diffDoc.files`.
    DiffSession diffSession;
    /// `kind == diff`: `DVN3`'s word- and token-level emphasis variants, so
    /// the structural view toggles without re-parsing.
    DiffEmphasis diffEmphasis;
}

/**
`DVN3`'s two readings of the same rows: word-level emphasis (the engine's
`DVM4` refinement) and token-level emphasis (boundaries from the grammar).

Both variants live in the document's one `emph` arena — appending never
invalidates what is already there — so a variant is just each row's
`(emphStart, emphCount)` pair, and switching between them is a swap rather
than a re-parse. That is what lets `zs` toggle the structural view at a
keystroke on a diff whose parses happened once, at load.
*/
struct DiffEmphasis
{
    private uint[] wordStart, wordCount;
    private uint[] tokenStart, tokenCount;
    /// The token variant was computed (a grammar was available and at least
    /// one row pair re-emphasized).
    bool available;
    /// The token variant is the one currently on the rows.
    bool showing;

    /// Snapshots the emphasis currently on `doc`'s rows as the word variant.
    void captureWord(in DiffDoc doc) @safe
    {
        capture(doc, wordStart, wordCount);
    }

    /// ditto, as the token variant.
    void captureToken(in DiffDoc doc) @safe
    {
        capture(doc, tokenStart, tokenCount);
    }

    /// Puts one variant back on the rows. A no-op when the token variant was
    /// never computed and it is the one asked for.
    void show(ref DiffDoc doc, bool token) @safe
    {
        if (token && !available)
            return;
        const starts = token ? tokenStart : wordStart;
        const counts = token ? tokenCount : wordCount;
        if (starts.length != doc.rows.length)
            return;
        foreach (i; 0 .. doc.rows.length)
        {
            auto row = doc.rows[i];
            row.emphStart = starts[i];
            row.emphCount = counts[i];
            doc.rows[i] = row;
        }
        showing = token;
    }

    private static void capture(in DiffDoc doc, ref uint[] starts,
        ref uint[] counts) @safe
    {
        starts.length = doc.rows.length;
        counts.length = doc.rows.length;
        foreach (i; 0 .. doc.rows.length)
        {
            starts[i] = doc.rows[i].emphStart;
            counts[i] = doc.rows[i].emphCount;
        }
    }
}

/// The per-side full texts of a diff document (`DVM5` syntax composition):
/// the renderers re-highlight each side with `lang` and layer the diff tints
/// on top. Empty when the sides are unavailable (a patch without readable
/// sources — the `DVS2` worktree re-highlight is pending).
struct DiffSides
{
    string lang;    /// canonical language of the diffed file pair
    string oldText;
    string newText;
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
    /// `DVN1`: the whitespace policy computed diffs run under.
    WhitespaceMode ignoreWhitespace = WhitespaceMode.exact;
    /// `DVN3`: whether the grammar gets consulted (`--diff-structural`).
    StructuralPolicy structural = StructuralPolicy.automatic;
    /// `DVN7`: the containers whose child order carries no meaning
    /// (`--diff-commutative`). Empty means no permutation is ever claimed.
    const(CommutativeKind)[] commutative = defaultCommutativeKinds;

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
        doc.diffSides = sidesFromWorktree(doc.diffDoc);
        classifyStructural(doc);
        attachSession(doc);
        doc.events = highlight(doc.lang, doc.source, quietFallback: true);
        return doc;
    }

    /// The engine options this pipeline's policy implies (`DVN1`).
    private DiffOptions diffOptions() const @safe pure nothrow @nogc
    {
        DiffOptions opt;
        opt.ignoreWhitespace = ignoreWhitespace;
        return opt;
    }

    /// `DVS3`: a git-revision diff — `hue --diff [<rev>[..<rev>]]`, plus
    /// `--staged` and trailing path filters — via `git diff` porcelain with
    /// pinned flags (no libgit2). The patch flows through the same model as
    /// every other diff; the sides come from `git show <rev>:<path>` (index
    /// spellings included) or the worktree, so revision diffs compose syntax
    /// exactly (`DVM5`) instead of reverse-applying.
    Document loadGitDiff(string revspec, bool staged, string[] paths)
    {
        import std.process : execute;
        import std.string : strip;

        auto argv = ["git", "diff", "--no-color", "--no-ext-diff"];
        if (staged)
            argv ~= "--cached";
        if (revspec.length)
            argv ~= revspec;
        if (paths.length)
            argv ~= "--" ~ paths;
        const res = execute(argv);
        if (res.status != 0)
            throw new Exception(text("git diff failed: ", res.output.strip));

        auto parsed = parsePatch(res.output);
        if (parsed.hasError)
            throw new Exception(text("git produced an unparseable patch at byte ",
                parsed.error.offset));

        const label = revspec.length ? revspec : (staged ? "--staged" : "worktree");
        Document doc = {
            title: text("diff ", label), kind: ContentKind.diff,
            source: res.output, lang: "diff", diffDoc: parsed.value,
        };
        doc.diffSides = sidesFromGit(doc.diffDoc, revspec, staged);
        classifyStructural(doc);
        attachSession(doc);
        doc.events = highlight(doc.lang, doc.source, quietFallback: true);
        return doc;
    }

    /// The `(old, new)` `git show` specs for a `git diff` invocation's two
    /// sides. `null` means "read the worktree file"; `":"` is the index.
    package static void gitDiffSideSpecs(string revspec, bool staged,
        out string oldSpec, out string newSpec) @safe pure nothrow
    {
        import std.string : indexOf;

        if (staged)
        {
            // Index vs a base: `git diff --staged [rev]`.
            oldSpec = revspec.length ? revspec : "HEAD";
            newSpec = ":";
            return;
        }
        auto i = revspec.indexOf("...");
        if (i >= 0)
        {
            // Symmetric range: old = merge-base(a, b) — resolved by the
            // caller (needs a git call); mark with the raw spelling.
            oldSpec = revspec; // resolved in sidesFromGit
            newSpec = revspec[i + 3 .. $].length ? revspec[i + 3 .. $] : "HEAD";
            return;
        }
        i = revspec.indexOf("..");
        if (i >= 0)
        {
            oldSpec = revspec[0 .. i].length ? revspec[0 .. i] : "HEAD";
            newSpec = revspec[i + 2 .. $].length ? revspec[i + 2 .. $] : "HEAD";
            return;
        }
        // `git diff` (worktree vs index) or `git diff <rev>` (worktree vs rev).
        oldSpec = revspec.length ? revspec : ":";
        newSpec = null;
    }

    /// Per-file sides for a git-sourced diff: exact contents from
    /// `git show <spec>:<path>` (or the worktree for the unnamed new side).
    /// Any lookup failure leaves that file's entry empty (plain rows).
    private static DiffSides[] sidesFromGit(in DiffDoc dd, string revspec,
        bool staged)
    {
        import std.file : exists, isFile;
        import std.process : execute;
        import std.string : indexOf, strip;

        string oldSpec, newSpec;
        gitDiffSideSpecs(revspec, staged, oldSpec, newSpec);
        if (oldSpec.indexOf("...") >= 0)
        {
            // Symmetric range: the old side is the merge base.
            const i = oldSpec.indexOf("...");
            const a = oldSpec[0 .. i].length ? oldSpec[0 .. i] : "HEAD";
            const b = oldSpec[i + 3 .. $].length ? oldSpec[i + 3 .. $] : "HEAD";
            const mb = execute(["git", "merge-base", a, b]);
            if (mb.status != 0)
                return new DiffSides[](dd.files.length);
            oldSpec = mb.output.strip;
        }

        // Paths in a git patch are repo-root-relative; worktree reads must
        // resolve against the root, not the invocation directory.
        string root;
        if (newSpec is null)
        {
            const top = execute(["git", "rev-parse", "--show-toplevel"]);
            if (top.status != 0)
                return new DiffSides[](dd.files.length);
            root = top.output.strip;
        }

        static string show(string spec, string path)
        {
            const r = execute(["git", "show",
                spec == ":" ? ":" ~ path : spec ~ ":" ~ path]);
            return r.status == 0 ? r.output : null;
        }

        auto sides = new DiffSides[](dd.files.length);
        foreach (fi; 0 .. dd.files.length)
        {
            const file = dd.files[fi];
            if (file.binary || file.hunksCount == 0)
                continue;
            const oldPath = dd.pathText(file.oldPath).idup;
            const newPath = dd.pathText(file.newPath).idup;

            string oldText = oldPath == "/dev/null" ? "" : show(oldSpec, oldPath);
            if (oldText is null)
                continue;
            string newText;
            if (newPath == "/dev/null")
                newText = "";
            else if (newSpec is null)
            {
                import std.path : buildPath;

                const full = buildPath(root, newPath);
                if (!full.exists || !full.isFile)
                    continue;
                try
                    newText = readText(full);
                catch (Exception)
                    continue;
            }
            else
            {
                newText = show(newSpec, newPath);
                if (newText is null)
                    continue;
            }
            sides[fi] = DiffSides(
                canonicalLanguage(newPath.extension.chompPrefix(".")),
                oldText, newText);
        }
        return sides;
    }

    /**
    Builds the document's changed-file session (`DVS4`) and annotates the
    entries whose sources could not be fetched (`DVS5`).

    "Could not be fetched" is *both* sides empty on a file that has hunks: an
    added file legitimately has no old side, so testing one side alone would
    label every new file an error. Such a file still renders — from the patch
    text, without syntax composition — which is why the notice says so rather
    than claiming a failure.
    */
    /**
    `DVN3`: ask the grammar whether anything changed, and stamp what it says
    did not as formatting-only.

    Two granularities from one pair of parses. The whole file covers the case
    someone ran the formatter over it; the per-hunk verdict covers the
    narrower and more common one, where a function was reflowed in the same
    commit that edited another. The oracle is conservative (`unknown` means
    "no claim"), so this can only ever DEMOTE a change the parser proves the
    language cannot see; it never promotes one, and it never hides rows —
    `DVN2`'s fold is what renders the verdict, and `zn` still expands it.

    Costs one parse per side of each changed file. Skipped above a size where
    that stops being cheap (unless `--diff-structural=on` waives the ceiling),
    and skipped entirely without a grammar cache.
    */
    private void classifyStructural(ref Document doc) @system
    {
        import diff_structural : analyze, HunkSpan, parses, StructuralPolicy,
            StructuralVerdict, waivesCeiling;
        import diff_token_view : applyTokenEmphasis;

        // Half a megabyte a side: past this the parse stops being free, and a
        // file that large is not what a formatter-noise verdict is for.
        enum size_t maxSideBytes = 512 * 1024;

        if (cache is null || !structural.parses)
            return;
        const ceiling = structural.waivesCeiling ? size_t.max : maxSideBytes;

        // The word-level emphasis the engine just produced, kept so the
        // structural view is a swap at runtime rather than a re-parse.
        doc.diffEmphasis.captureWord(doc.diffDoc);

        foreach (fi; 0 .. doc.diffDoc.files.length)
        {
            if (fi >= doc.diffSides.length)
                continue;
            const sides = doc.diffSides[fi];
            if (sides.lang.length == 0
                || sides.oldText.length == 0 || sides.newText.length == 0
                || sides.oldText.length > ceiling
                || sides.newText.length > ceiling)
                continue;
            const file = doc.diffDoc.files[fi];
            if (file.hunksCount == 0)
                continue;

            auto spans = new HunkSpan[](file.hunksCount);
            foreach (i, ref s; spans)
            {
                const h = doc.diffDoc.hunks[file.hunksStart + i];
                s = HunkSpan(h.oldStart, h.oldCount, h.newStart, h.newCount);
            }

            const seen = analyze(*cache, sides.lang, sides.oldText,
                sides.newText, spans, commutative);
            if (seen.file == StructuralVerdict.unknown)
                continue;

            foreach (i; 0 .. file.hunksCount)
            {
                const equivalent = seen.verdicts[i] == StructuralVerdict.equivalent;
                if (!equivalent && !seen.reordered[i])
                    continue;
                auto h = doc.diffDoc.hunks[file.hunksStart + i];
                h.formattingOnly = equivalent;
                h.reordered = seen.reordered[i];
                doc.diffDoc.hunks[file.hunksStart + i] = h;
            }

            // The same parse pays for the view (`DVN3`'s second half).
            if (applyTokenEmphasis(doc.diffDoc, file, sides.oldText,
                    sides.newText, seen.oldTokens, seen.newTokens,
                    diffOptions()) != 0)
                doc.diffEmphasis.available = true;
        }

        if (doc.diffEmphasis.available)
        {
            doc.diffEmphasis.captureToken(doc.diffDoc);
            doc.diffEmphasis.show(doc.diffDoc,
                token: structural == StructuralPolicy.view);
        }
    }

    package static void attachSession(ref Document doc) @safe
    {
        doc.diffSession = buildDiffSession(doc.diffDoc);
        foreach (i, ref e; doc.diffSession.entries)
            if (i < doc.diffSides.length && !e.binary && e.hunks != 0
                && doc.diffSides[i].oldText.length == 0
                && doc.diffSides[i].newText.length == 0)
                e.error = "(sources unavailable — showing the patch text)";
    }

    /// `DVS2`'s re-highlight half: for each file of a parsed patch whose
    /// new side is readable from the worktree, read it and reconstruct the
    /// old side by reverse-applying the hunks — validated against the
    /// worktree, so a stale checkout degrades that file to plain rows
    /// (an empty entry) rather than mislabeled colors.
    private static DiffSides[] sidesFromWorktree(in DiffDoc dd)
    {
        import std.file : exists, isFile;

        auto sides = new DiffSides[](dd.files.length);
        foreach (fi; 0 .. dd.files.length)
        {
            const file = dd.files[fi];
            if (file.binary || file.hunksCount == 0)
                continue;
            const newPath = dd.pathText(file.newPath).idup;
            if (newPath == "/dev/null" || !newPath.exists || !newPath.isFile)
                continue;
            string newText;
            try
                newText = readText(newPath);
            catch (Exception)
                continue;
            const oldText = reconstructOldText(dd, file, newText);
            if (oldText is null)
                continue; // patch does not match the worktree
            sides[fi] = DiffSides(
                canonicalLanguage(newPath.extension.chompPrefix(".")),
                oldText, newText);
        }
        return sides;
    }

    /// Reconstructs the old side of `file` from the new side's full text by
    /// reverse-applying its hunks. Context and added rows are validated
    /// against `newText`; any mismatch returns `null`.
    package static string reconstructOldText(in DiffDoc dd, in FileEntry file,
        string newText) @safe
    {
        bool newMissing;
        auto newLines = splitTextLines(newText, newMissing);

        char[] outp;
        size_t j = 1; // 1-based cursor into newLines

        foreach (ref hunk; dd.fileHunks(file))
        {
            // The hunk's first line on the new side (for a pure-removal hunk
            // the unified header names the line BEFORE the removal point).
            uint anchor = 0;
            foreach (ref row; dd.hunkRows(hunk))
                if (row.newLine != 0)
                {
                    anchor = row.newLine;
                    break;
                }
            if (anchor == 0)
                anchor = hunk.newStart + 1;
            if (anchor > newLines.length + 1)
                return null;
            while (j < anchor)
            {
                if (j > newLines.length)
                    return null;
                outp ~= newLines[j - 1];
                outp ~= '\n';
                j++;
            }
            foreach (ref row; dd.hunkRows(hunk))
            {
                const rowText = dd.rowText(row);
                final switch (row.kind)
                {
                case RowKind.context:
                    if (j > newLines.length || newLines[j - 1] != rowText)
                        return null;
                    outp ~= rowText;
                    outp ~= '\n';
                    j++;
                    break;
                case RowKind.added:
                    if (j > newLines.length || newLines[j - 1] != rowText)
                        return null;
                    j++; // present on the new side only
                    break;
                case RowKind.removed:
                    outp ~= rowText;
                    outp ~= '\n';
                    break;
                }
            }
        }
        while (j <= newLines.length)
        {
            outp ~= newLines[j - 1];
            outp ~= '\n';
            j++;
        }
        // The old side's trailing newline is governed by its own flag; when
        // the file tail is shared (no hunk touches it), the new side's
        // missing final newline is that shared tail's, so it applies too.
        if (outp.length && (file.oldMissingNewline || newMissing))
            outp = outp[0 .. $ - 1];
        return (() @trusted => cast(string) outp)();
    }

    /// Line split retaining the final-newline fact (GC twin of the engine's
    /// span-based splitter, for app-side reconstruction).
    private static const(char)[][] splitTextLines(const(char)[] text,
        out bool missingNewline) @safe pure nothrow
    {
        missingNewline = false;
        const(char)[][] lines;
        if (text.length == 0)
            return lines;
        size_t start = 0;
        foreach (i, c; text)
            if (c == '\n')
            {
                lines ~= text[start .. i];
                start = i + 1;
            }
        if (start < text.length)
        {
            lines ~= text[start .. $];
            missingNewline = true;
        }
        return lines;
    }

    /// A diff document from two files, computed in-process (`DVS1`) — no VCS
    /// involved. `source` carries the equivalent emitted patch so raw views,
    /// selection and `--diff-copy=patch` all have a textual identity — and,
    /// since the `@nogc` model **borrows** its backing text (`DVM8`), the
    /// document re-parses that owned patch so `diffDoc` references `source`
    /// (which this `Document` keeps alive) rather than transient file reads.
    Document loadDiffPair(string oldPath, string newPath)
    {
        // The sides are Document-owned strings, so the @nogc model (`DVM8`)
        // can borrow them directly — no emit-and-reparse detour.
        DiffSides sides = {
            lang: canonicalLanguage(newPath.extension.chompPrefix(".")),
            oldText: readText(oldPath),
            newText: readText(newPath),
        };
        Document doc = {
            path: newPath, title: text(oldPath, " → ", newPath),
            kind: ContentKind.diff, lang: "diff", diffSides: [sides],
            diffDoc: diffText(sides.oldText, sides.newText, oldPath, newPath,
                diffOptions()),
        };
        classifyStructural(doc);
        attachSession(doc);
        SmallBuffer!char patchBuf;
        emitPatch(doc.diffDoc, patchBuf);
        doc.source = patchBuf[].idup;
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


@("document.reconstructOldText.reverse-apply")
@safe unittest
{
    import sparkles.diff : parsePatch;

    // The worktree's new side + the patch reconstruct the old side.
    enum patch = "--- a/f.txt\n+++ b/f.txt\n@@ -1,4 +1,4 @@\n one\n-two\n+2\n three\n-four\n+4\n";
    enum newText = "one\n2\nthree\n4\ntail\n";
    const dd = parsePatch(patch).value;
    const old_ = DocumentPipeline.reconstructOldText(dd, dd.files[0], newText);
    assert(old_ == "one\ntwo\nthree\nfour\ntail\n");

    // A stale worktree (context mismatch) yields null, never wrong colors.
    assert(DocumentPipeline.reconstructOldText(dd, dd.files[0],
        "one\nDIFFERENT\nthree\n4\n") is null);
}

@("document.gitDiffSideSpecs.revspecMapping")
@safe pure nothrow
unittest
{
    // The pure half of `DVS3`: which `git show` spelling names each side.
    // `null` = read the worktree file; `":"` = the index. Testable without a
    // repository, which is the point of splitting it out.
    static void check(string revspec, bool staged, string wantOld, string wantNew)
    {
        string oldSpec, newSpec;
        DocumentPipeline.gitDiffSideSpecs(revspec, staged, oldSpec, newSpec);
        assert(oldSpec == wantOld, oldSpec);
        assert(newSpec == wantNew, newSpec is null ? "<worktree>" : newSpec);
    }

    // Bare `hue --diff`: the worktree against the index, like `git diff`.
    check("", false, ":", null);
    // `hue --diff <rev>`: the worktree against that revision.
    check("HEAD~2", false, "HEAD~2", null);
    // Ranges name both sides — an omitted end means `HEAD`, as git spells it.
    check("a..b", false, "a", "b");
    check("..b", false, "HEAD", "b");
    check("a..", false, "a", "HEAD");
    // A symmetric range keeps its raw spelling on the old side: resolving it
    // is a `git merge-base` call, which this pure mapping cannot make.
    check("a...b", false, "a...b", "b");
    check("a...", false, "a...", "HEAD");
    // `--staged` diffs the index, defaulting its base to `HEAD`.
    check("", true, "HEAD", ":");
    check("v1.2.3", true, "v1.2.3", ":");
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

@("document.classifyStructural.reflowedCodeFoldsAsNoise")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment;

    import sparkles.syntax : GrammarRegistry, LabelSet;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    const dir = buildPath(tempDir(), "hue-structural-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    // A signature and an expression reflowed across lines. The LINE STRUCTURE
    // changed, so `DVN1`'s per-line policy and `DVN2`'s per-row verdict both
    // see real changes — only the grammar can say the tokens are identical.
    const oldPath = buildPath(dir, "a.d");
    const newPath = buildPath(dir, "b.d");
    write(oldPath, "module s;\n\nint f(int alpha, int beta)\n{\n"
        ~ "    return alpha + beta;\n}\n");
    write(newPath, "module s;\n\nint f(\n    int alpha,\n    int beta)\n{\n"
        ~ "    return alpha\n        + beta;\n}\n");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    auto pipeline = DocumentPipeline(registry: &reg, cache: &cache);
    auto doc = pipeline.loadDiffPair(oldPath, newPath);

    assert(doc.diffDoc.hunks.length >= 1);
    foreach (i; 0 .. doc.diffDoc.hunks.length)
        assert(doc.diffDoc.hunks[i].formattingOnly,
            "the grammar sees no change, so every hunk is noise");

    // A real edit is never demoted, however it is formatted.
    write(newPath, "module s;\n\nint f(\n    int alpha,\n    int beta)\n{\n"
        ~ "    return alpha\n        - beta;\n}\n");
    auto edited = pipeline.loadDiffPair(oldPath, newPath);
    bool anyReal;
    foreach (i; 0 .. edited.diffDoc.hunks.length)
        if (!edited.diffDoc.hunks[i].formattingOnly)
            anyReal = true;
    assert(anyReal, "a changed operator is a change, reflow or not");
}

@("document.classifyStructural.sortedImportsAreAReorderNotFormatting")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment;

    import sparkles.syntax : GrammarRegistry, LabelSet;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    const dir = buildPath(tempDir(), "hue-commutative-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    // `DVN7`: sorting an import block is N removals and N additions, and it
    // reads like a rewrite. The tokens really did change order, so `DVN3`
    // says `differs` — correctly. Only the commutativity profile can say the
    // order carried no meaning.
    const oldPath = buildPath(dir, "a.d");
    const newPath = buildPath(dir, "b.d");
    write(oldPath, "module m;\n\nimport std.stdio;\nimport std.conv;\n"
        ~ "import std.array;\n\nvoid f() {}\n");
    write(newPath, "module m;\n\nimport std.array;\nimport std.conv;\n"
        ~ "import std.stdio;\n\nvoid f() {}\n");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    auto doc = DocumentPipeline(registry: &reg, cache: &cache)
        .loadDiffPair(oldPath, newPath);

    assert(doc.diffDoc.hunks.length == 1);
    assert(doc.diffDoc.hunks[0].reordered, "the imports only changed places");
    assert(!doc.diffDoc.hunks[0].formattingOnly,
        "a reorder is not formatting — the badge must not say so");

    // An import ADDED alongside the sort is a real change, and the whole hunk
    // stays real: this pass demotes permutations, not edits that came with one.
    write(newPath, "module m;\n\nimport std.array;\nimport std.conv;\n"
        ~ "import std.file;\nimport std.stdio;\n\nvoid f() {}\n");
    auto grown = DocumentPipeline(registry: &reg, cache: &cache)
        .loadDiffPair(oldPath, newPath);
    foreach (i; 0 .. grown.diffDoc.hunks.length)
        assert(!grown.diffDoc.hunks[i].reordered
            && !grown.diffDoc.hunks[i].formattingOnly);

    // And a project that declares nothing commutative gets no claim at all.
    auto strict = DocumentPipeline(registry: &reg, cache: &cache,
        commutative: null).loadDiffPair(oldPath, newPath);
    foreach (i; 0 .. strict.diffDoc.hunks.length)
        assert(!strict.diffDoc.hunks[i].reordered);
}

@("document.structuralView.emphasizesTokensNotCharacterRuns")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment;

    import sparkles.diff : RowKind;
    import sparkles.syntax : GrammarRegistry, LabelSet;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    const dir = buildPath(tempDir(), "hue-structural-view-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    // One operator changed, and the spacing around it changed with it — the
    // case where word runs and tokens disagree about what the reviewer
    // should be looking at.
    const oldPath = buildPath(dir, "a.d");
    const newPath = buildPath(dir, "b.d");
    write(oldPath, "module s;\n\nint f()\n{\n    return alpha+beta;\n}\n");
    write(newPath, "module s;\n\nint f()\n{\n    return alpha - beta;\n}\n");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());

    static const(char)[][] addedEmphasis(ref Document doc) @system
    {
        const(char)[][] spans;
        foreach (i; 0 .. doc.diffDoc.rows.length)
        {
            const row = doc.diffDoc.rows[i];
            if (row.kind != RowKind.added)
                continue;
            const rowText = doc.diffDoc.rowText(row);
            foreach (s; doc.diffDoc.rowEmph(row))
                spans ~= rowText[s.start .. s.end];
        }
        return spans;
    }

    // Word refinement cannot separate the operator from the padding that
    // moved with it: the whole run reads as changed.
    auto words = DocumentPipeline(registry: &reg, cache: &cache)
        .loadDiffPair(oldPath, newPath);
    assert(addedEmphasis(words) == [" - "], "word runs swallow the spacing");

    // The grammar has no token for padding, so exactly the operator lights up.
    auto tokens = DocumentPipeline(registry: &reg, cache: &cache,
        structural: StructuralPolicy.view).loadDiffPair(oldPath, newPath);
    assert(addedEmphasis(tokens) == ["-"], "the change is one token");

    // Both readings are held at once, so the runtime toggle is a swap.
    assert(tokens.diffEmphasis.available && tokens.diffEmphasis.showing);
    tokens.diffEmphasis.show(tokens.diffDoc, token: false);
    assert(addedEmphasis(tokens) == [" - "]);
    tokens.diffEmphasis.show(tokens.diffDoc, token: true);
    assert(addedEmphasis(tokens) == ["-"]);
}

@("document.classifyStructural.oneHunkReflowedOneEdited")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment;

    import sparkles.syntax : GrammarRegistry, LabelSet;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    const dir = buildPath(tempDir(), "hue-structural-hunks-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    // The commit every reviewer actually gets: one function reflowed, another
    // edited, far enough apart to be two hunks. A whole-file verdict has to
    // give up on both; the per-hunk one demotes the reflow and keeps the edit.
    enum pad = "int p1() { return 0; }\nint p2() { return 0; }\n"
        ~ "int p3() { return 0; }\nint p4() { return 0; }\n"
        ~ "int p5() { return 0; }\nint p6() { return 0; }\n";
    const oldPath = buildPath(dir, "a.d");
    const newPath = buildPath(dir, "b.d");
    // The reflow moves LINE BOUNDARIES, so no whitespace policy and no
    // row-wise verdict can reach it — only the parser can.
    write(oldPath, "module s;\n\nint f(int alpha, int beta)\n{\n"
        ~ "    return alpha + beta;\n}\n\n"
        ~ pad ~ "\nint g()\n{\n    return 1;\n}\n");
    write(newPath, "module s;\n\nint f(\n    int alpha,\n    int beta)\n{\n"
        ~ "    return alpha\n        + beta;\n}\n\n"
        ~ pad ~ "\nint g()\n{\n    return 2;\n}\n");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    auto pipeline = DocumentPipeline(registry: &reg, cache: &cache);
    auto doc = pipeline.loadDiffPair(oldPath, newPath);

    assert(doc.diffDoc.hunks.length == 2, "the two changes are far apart");
    assert(doc.diffDoc.hunks[0].formattingOnly, "the reflowed function is noise");
    assert(!doc.diffDoc.hunks[1].formattingOnly, "1 -> 2 is a real change");

    // `--diff-structural=off` puts the text-level layers back on their own:
    // the reflow changed the line structure, so nothing demotes it.
    auto textOnly = DocumentPipeline(registry: &reg, cache: &cache,
        structural: StructuralPolicy.off);
    auto plain = textOnly.loadDiffPair(oldPath, newPath);
    foreach (i; 0 .. plain.diffDoc.hunks.length)
        assert(!plain.diffDoc.hunks[i].formattingOnly,
            "without the grammar there is no evidence to demote either hunk");
}

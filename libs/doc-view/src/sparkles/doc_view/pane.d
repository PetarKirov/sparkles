/**
The document viewer as an embeddable GPU pane (`UIA14`, terminal `TDV5`–
`TDV8`): one file — source, markdown, DSV, a diff, or an image — loaded,
kept current, driven by keys and the wheel, and painted into any pixel rect
of a `sparkles:ui-raylib` window.

The pane is a component the way a terminal pane is: the embedder owns where
it sits, the focus and the closing; the pane owns the document, its scroll,
its view toggles, folding and search, and paints only inside its rect. It
reuses everything hue's window paints from — the $(LREF ViewerModel), its
display list and $(REF emitVisibleOps, sparkles,doc_view,view_ops) — so a
file looks the same in hue and in an embedding application.

Compiled where the consumer links `sparkles:ui-raylib`.
*/
module sparkles.doc_view.pane;

version (Have_sparkles_ui_raylib):

import core.time : MonoTime, msecs;
import std.datetime.systime : SysTime;

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.term_color : Color, mix, RgbColor;
import sparkles.input.events : Key, KeyEvent;
import sparkles.syntax : GrammarRegistry, LabelSet, TsConfigCache;
import sparkles.ui.canvas : DrawOp, fillRectOp, popClipOp, pushClipOp,
    RuleEdge, Scrollbar;
import sparkles.ui.geometry : Rect;
import sparkles.ui.style : ColorScheme, schemeForBackground, Slot, Visual;
import sparkles.ui.theme : Theme;
import sparkles.ui.themes : builtinDark, builtinLight;
import sparkles.ui_raylib : RaylibCanvas;

import sparkles.doc_view.document : DocumentPipeline;
import sparkles.doc_view.include : IncludeOptions;
import sparkles.doc_view.kind : ViewKind, viewKindOf;
import sparkles.doc_view.view_ops : emitVisibleOps;
import sparkles.doc_view.viewer_model : ScrollAnchor, ViewerModel;

/**
What every pane of one application shares: the grammars, the highlighting
cache and the loader. Heap-owned (the cache points at the registry), created
once by the embedder.
*/
struct DocViewEnv
{
    GrammarRegistry registry;
    TsConfigCache cache;
    LabelSet labels;
    DocumentPipeline pipeline;

    @disable this(this);

    /**
    An environment over `registry`. `read`, when given, serves every file the
    viewer opens or includes (APK assets). Markdown includes resolve
    (`VIW5`), confined to the document's tree and — reading the filesystem —
    its repository (`VIW7`); `pipeline.includeOptions` narrows that.
    */
    static DocViewEnv* create(GrammarRegistry registry,
        string delegate(string path) @system read = null) @system
    {
        auto e = new DocViewEnv;
        e.registry = registry;
        e.labels = LabelSet.standard();
        e.cache = TsConfigCache.create(&e.registry, e.labels);
        e.pipeline = DocumentPipeline(&e.registry, &e.cache);
        e.pipeline.readFile = read;
        // `TDV9`: a viewer embedded in another application never fetches
        // what a document names; `fetchUrl` stays null.
        e.pipeline.resolveIncludes = true;
        e.pipeline.includeOptions.withinRepository = read is null;
        return e;
    }
}

/**
The theme a pane wears to match its embedder's chrome (`TDV7`): the built-in
dark or light syntax colours, chosen by the background's lightness, on the
embedder's own foreground and background.
*/
immutable(Theme) chromeTheme(RgbColor fg, RgbColor bg) @safe pure nothrow
{
    const base = schemeForBackground(bg) == ColorScheme.dark ? &builtinDark : &builtinLight;
    immutable Theme t = {
        name: "chrome", defaultFg: Color.fromRgb(fg), defaultBg: Color.fromRgb(bg),
        rules: base.rules,
    };
    return t;
}

/// What a key did to the pane.
enum PaneKey : ubyte
{
    ignored, /// not the pane's: the embedder may use it
    handled, /// consumed; repaint
    close,   /// `q` / `Esc` (`KBD1`): the embedder closes the pane
}

/// See the module header.
struct DocViewPane
{
    /// The document's model (null-document while `error` is set).
    ViewerModel vm;
    /// The path the pane shows (restore re-opens it, `TDV5`).
    string path;
    /// The file name, for the pane's title.
    string title;
    /// Why the document is not showing — a located error in place of it.
    string error;
    /// The file vanished after it was opened: the last content stays, with
    /// a banner (`TDV8`).
    bool deleted;
    /// The content kind, for the embedder's icon (`TDV5`).
    ViewKind kind;

    private DocViewEnv* env;
    private SysTime mtime;
    private MonoTime lastPoll;
    private bool searching;
    private char[] query;
    private dchar pending; // `g` or `z`, awaiting its second key
    private int laidCols = -1;
    private int docRows = 1;
    private bool dirty = true;
    private SharedBuffer!(char, 4096) buf;
    private ImageTexture image;

    @disable this(this);

    // ── opening ─────────────────────────────────────────────────────────

    /**
    Loads `path` in `theme`. False (with `error` set, and the pane still
    paintable) when it cannot be read or is not a kind the viewer shows.
    */
    bool open(DocViewEnv* env_, string path_, immutable(Theme) theme) @system
    {
        import std.path : baseName;

        env = env_;
        path = path_;
        title = path_.baseName;
        error = null;
        deleted = false;
        kind = viewKindOf(path_);
        vm.names = ["chrome"];
        vm.themes = [theme];
        vm.labels = env.labels;
        vm.cache = &env.cache;
        vm.themeIdx = 0;
        static if (__traits(compiles, { import sparkles.doc_view.ansi_decode : decodeAnsi; }))
        {
            import sparkles.doc_view.ansi_decode : decodeAnsi;

            vm.decodeAnsi = (const(char)[] b) => decodeAnsi(b);
        }
        if (kind == ViewKind.image)
        {
            vm.applyTheme(0);
            mtime = modified(path_);
            dirty = true;
            return true;
        }
        if (kind == ViewKind.unsupported)
        {
            error = "not a kind of file this viewer shows";
            vm.applyTheme(0);
            return false;
        }
        return load(ScrollAnchor.init);
    }

    // Reads the document and swaps it in; `keep` names the source LINE (and
    // the rows above it) to put back at the top — see `lineAnchor`.
    private bool load(ScrollAnchor keep) @system
    {
        import sparkles.doc_view.document : Document;

        Document doc;
        try
            doc = env.pipeline.load(path);
        catch (Exception e)
        {
            error = e.msg;
            vm.applyTheme(0);
            dirty = true;
            return false;
        }
        error = null;
        vm.setDocument(doc.title, doc.dsvNote, doc.source, doc.events,
            doc.preview, doc.twoslash, doc.lang, doc.diffDoc, doc.diffSides,
            doc.diffSession, doc.diffEmphasis, doc.coverage, doc.hasCoverage);
        vm.docPath = path;
        vm.applyTheme(vm.themeIdx);
        if (keep.valid && keep.src < vm.lineStarts.length)
            vm.restoreAnchor(ScrollAnchor(vm.lineStarts[keep.src], keep.rowsAbove));
        mtime = modified(path);
        dirty = true;
        return true;
    }

    /// Re-themes the pane (`TDV7`: the embedder's light/dark switch).
    void setTheme(immutable(Theme) theme) @system
    {
        vm.themes = [theme];
        vm.applyTheme(0);
        dirty = true;
    }

    /**
    `TDV8`: reloads a file that changed on disk, keeping the first visible
    source line where it was; a deleted file keeps its content under a
    banner. Checks at most once a second; true when the pane must repaint.
    */
    bool poll() @system
    {
        const now = MonoTime.currTime;
        if (now - lastPoll < 1000.msecs || path.length == 0 || isAsset(path))
            return false;
        lastPoll = now;
        const m = modified(path);
        if (m == SysTime.init)
        {
            if (!deleted && mtime != SysTime.init)
            {
                deleted = true;
                dirty = true;
            }
            return dirty;
        }
        if (deleted || m != mtime)
        {
            deleted = false;
            if (kind == ViewKind.image)
            {
                image.release();
                mtime = m;
                dirty = true;
                return true;
            }
            cast(void) load(lineAnchor());
        }
        return dirty;
    }

    // The top row's source LINE (not byte): a reload that inserted text above
    // must keep the same line in view, not the same offset.
    private ScrollAnchor lineAnchor() const @safe
    {
        const a = vm.captureAnchor();
        if (!a.valid || vm.lineStarts.length == 0)
            return a;
        size_t line;
        foreach (i, s; vm.lineStarts)
            if (s <= a.src)
                line = i;
        return ScrollAnchor(src: line, rowsAbove: a.rowsAbove);
    }

    /// Whether the pane changed since it last painted.
    bool needsPaint() const @safe pure nothrow @nogc => dirty;

    /// Frees the GPU texture of an image pane. Call while the window lives.
    void release() @system
    {
        image.release();
    }

    // ── input (`TDV6`) ──────────────────────────────────────────────────

    /// Scrolls by `rows` (a wheel or a touch drag); true when it moved.
    bool scrollBy(long rows) @system
    {
        if (error.length || kind == ViewKind.image || rows == 0)
            return false;
        const moved = vm.scrollVertical(rows, docRows);
        dirty |= moved;
        return moved;
    }

    /// One key: the viewer's own bindings, `q`/`Esc` asking to close.
    PaneKey key(in KeyEvent k) @system
    {
        import sparkles.input.events : KeyAction;

        if (k.action == KeyAction.release)
            return PaneKey.ignored;
        dirty = true;
        if (searching)
            return searchKey(k);
        const c = k.key == Key.char_ ? k.ch : dchar.init;
        if (k.mods.ctrl || k.mods.alt || k.mods.super_)
        {
            if (k.mods.ctrl && (c == 'd' || c == 'u'))
                return scrolled(c == 'd' ? docRows / 2 : -docRows / 2);
            dirty = false;
            return PaneKey.ignored;
        }
        if (pending != dchar.init)
        {
            const p = pending;
            pending = dchar.init;
            if (p == 'g' && c == 'g')
                return top(0);
            if (p == 'z')
                return foldKey(c);
            // An unknown second key cancels the prefix and is otherwise dropped.
            return PaneKey.handled;
        }
        switch (k.key)
        {
            case Key.escape:
                return PaneKey.close;
            case Key.down:
                return scrolled(1);
            case Key.up:
                return scrolled(-1);
            case Key.pageDown:
                return scrolled(docRows);
            case Key.pageUp:
                return scrolled(-docRows);
            case Key.home:
                if (k.mods.shift)
                    return sideways(long.min);
                return top(0);
            case Key.end:
                if (k.mods.shift)
                    return sideways(long.max);
                return top(long.max);
            case Key.left:
                return k.mods.shift ? sideways(-vm.hScrollStep) : PaneKey.ignored;
            case Key.right:
                return k.mods.shift ? sideways(vm.hScrollStep) : PaneKey.ignored;
            case Key.tab:
                vm.cycleView();
                relayoutNow();
                return PaneKey.handled;
            case Key.char_:
                break;
            default:
                dirty = false;
                return PaneKey.ignored;
        }
        switch (c)
        {
            case 'q':
                return PaneKey.close;
            case 'j':
                return scrolled(1);
            case 'k':
                return scrolled(-1);
            case ' ':
                return scrolled(docRows);
            case 'G':
                return top(long.max);
            case 'g':
            case 'z':
                pending = c;
                return PaneKey.handled;
            case 'l':
                vm.lineNumbers = !vm.lineNumbers;
                relayoutNow();
                return PaneKey.handled;
            case 'c':
                vm.codeLineNumbers = !vm.codeLineNumbers;
                relayoutNow();
                return PaneKey.handled;
            case '/':
                searching = true;
                query = null;
                vm.clearSearch();
                return PaneKey.handled;
            case 'n':
                jumpToMatch(vm.curMatch + 1);
                return PaneKey.handled;
            case 'N':
                jumpToMatch(vm.curMatch + vm.matches.length - 1);
                return PaneKey.handled;
            default:
                dirty = false;
                return PaneKey.ignored;
        }
    }

    private PaneKey scrolled(long rows) @system
    {
        cast(void) vm.scrollVertical(rows, docRows);
        return PaneKey.handled;
    }

    private PaneKey top(long row) @system
    {
        vm.scrollTo(row == long.max ? vm.maxTopFor(docRows) : row);
        return PaneKey.handled;
    }

    private PaneKey sideways(long cols) @system
    {
        if (cols == long.min)
            cast(void) vm.scrollHomeHorizontal();
        else if (cols == long.max)
            cast(void) vm.scrollEndHorizontal();
        else
            cast(void) vm.scrollHorizontal(cols);
        return PaneKey.handled;
    }

    // The `z` family (`FLD5`), with the top row as the cursor — the viewer has
    // no caret — plus `zh`/`zl`.
    private PaneKey foldKey(dchar c) @system
    {
        switch (c)
        {
            case 'a':
            case 'z':
                foldAtTop(ViewerModel.FoldOp.toggle);
                break;
            case 'c':
                foldAtTop(ViewerModel.FoldOp.close);
                break;
            case 'o':
                foldAtTop(ViewerModel.FoldOp.open);
                break;
            case 'r':
                vm.setAllFolds(false);
                break;
            case 'm':
                vm.setAllFolds(true);
                break;
            case 'h':
                return sideways(-vm.hScrollStep);
            case 'l':
                return sideways(vm.hScrollStep);
            default:
                if (c >= '1' && c <= '9')
                    vm.foldToLevel(c - '0');
        }
        return PaneKey.handled;
    }

    private void foldAtTop(ViewerModel.FoldOp op) @system
    {
        if (!vm.rows.length)
            return;
        const t0 = cast(size_t)(vm.top >= 0 && vm.top < cast(long) vm.rows.length ? vm.top : 0);
        if (vm.rows[t0].srcStart != size_t.max)
            vm.foldAt(cast(long) vm.rows[t0].srcStart, op);
    }

    private PaneKey searchKey(in KeyEvent k) @system
    {
        switch (k.key)
        {
            case Key.escape:
                searching = false;
                query = null;
                vm.clearSearch();
                return PaneKey.handled;
            case Key.enter:
                searching = false;
                return PaneKey.handled;
            case Key.backspace:
                if (query.length)
                {
                    import std.utf : strideBack;

                    query = query[0 .. $ - strideBack(query, query.length)];
                }
                break;
            default:
                if (k.text.length && !k.mods.ctrl && !k.mods.alt)
                    query ~= k.text;
                else
                    return PaneKey.handled;
        }
        vm.search(query);
        if (vm.matches.length)
        {
            // The first match at or below the top, like an incremental search.
            size_t first;
            foreach (i, ref m; vm.matches)
                if (vm.visualOfMatch(m) >= vm.top)
                {
                    first = i;
                    break;
                }
            jumpToMatch(first);
        }
        return PaneKey.handled;
    }

    private void jumpToMatch(size_t i) @system
    {
        if (vm.matches.length == 0)
            return;
        vm.curMatch = i % vm.matches.length;
        vm.revealOffset(vm.matches[vm.curMatch].start);
        vm.scrollTo(vm.visualOfMatch(vm.matches[vm.curMatch]) - docRows / 2);
    }

    private void relayoutNow() @system
    {
        if (laidCols > 0)
            vm.relayout(laidCols);
    }

    // ── painting ────────────────────────────────────────────────────────

    /**
    Paints the pane at window pixels (`px`, `py`), `pw` × `ph`, through a
    canvas of the host's (its fonts, effect backend and images). `focused`
    lights the header.
    */
    void paint(ref RaylibCanvas host, int px, int py, int pw, int ph, bool focused) @system
    {
        import sparkles.ui.components.chrome : headerBar;
        import sparkles.ui.display_list : buildDisplayList;
        import sparkles.ui.geometry : SizeSpec;
        import sparkles.ui.interp.immediate : paint;
        import sparkles.ui.layout : layout;
        import sparkles.ui.style : TextStyle;
        import sparkles.ui.widget : Builder, Widget, WidgetKind;

        if (pw <= 0 || ph <= 0)
            return;
        dirty = false;
        const cw = host.cellW > 0 ? host.cellW : 1, ch = host.cellH > 0 ? host.cellH : 1;
        const cols = pw / cw, rows = ph / ch;
        auto c = RaylibCanvas(host.fonts, &buf, cw, ch, px, py);
        c.fx = host.fx;
        c.images = host.images;
        c.fillPixels(px, py, pw, ph, vm.pageBg);
        if (cols < 4 || rows < 2)
            return;

        void emit(in DrawOp op, int dx = 0, int dy = 0)
        {
            DrawOp o = op;
            o.translate(dx, dy);
            paint(c, (() @trusted => (&o)[0 .. 1])());
        }

        c.pushClip(Rect(0, 0, cols, rows));
        scope (exit) c.popClip();

        // The header: the file, the view, the position — the shared chrome.
        {
            auto b = Builder();
            const name = b.add(Widget(kind: WidgetKind.text, text: title,
                slot: focused ? Slot.chromeAccent : Slot.gutter,
                textStyle: TextStyle(bold: focused)));
            uint[] mid, tail;
            mid ~= b.add(Widget(kind: WidgetKind.text, text: modeLabel, slot: Slot.gutter));
            tail ~= b.add(Widget(kind: WidgetKind.text, text: positionLabel, slot: Slot.gutter));
            const bar = headerBar(b, [name], mid, tail, focused);
            auto wt = b.finish(b.add(Widget(kind: WidgetKind.column, children: [bar],
                width: SizeSpec.fixed(cols))));
            foreach (ref op; buildDisplayList(wt, layout(wt), vm.palette, vm.pageFg, vm.pageBg))
                emit(op);
        }

        const bannerRows = deleted ? 1 : 0;
        const inputRows = searching ? 1 : 0;
        const y0 = 1 + bannerRows;
        docRows = rows - y0 - inputRows;
        if (docRows < 1)
            docRows = 1;
        if (deleted)
            textLine(c, 1, cols, "deleted on disk — showing the last content",
                mix(vm.pageBg, RgbColor(0xd0, 0x40, 0x40), 0.35));

        if (error.length)
        {
            textLine(c, y0, cols, "cannot show " ~ path ~ ":", vm.pageBg);
            textLine(c, y0 + 1, cols, error, vm.pageBg);
            return;
        }
        if (kind == ViewKind.image)
        {
            image.draw(path, px, py + y0 * ch, pw, ph - y0 * ch);
            return;
        }

        // Lay out for the width (one column for the bar), then keep the
        // viewport inside the document.
        const width = cols - 1 > 8 ? cols - 1 : 8;
        vm.viewRows = docRows;
        if (width != laidCols || vm.widthCols != width)
        {
            const keep = vm.captureAnchor();
            laidCols = width;
            vm.relayout(width);
            vm.restoreAnchor(keep);
        }
        vm.clampView();

        // The document: two passes when scrolled sideways past a pinned
        // gutter (as in hue's window), otherwise one.
        const pinned = vm.hsb.offset > 0 ? vm.pinnedCols : 0;
        const dhx = cast(int) vm.hsb.offset;
        void pass(int dx, in Rect clip)
        {
            const dy = y0 - cast(int) vm.top;
            emit(pushClipOp(clip), dx, dy);
            emitVisibleOps(vm, docRows, (ref DrawOp op) { emit(op, dx, dy); });
            emit(popClipOp());
        }
        if (pinned > 0)
            pass(0, Rect(0, cast(int) vm.top, pinned, docRows));
        pass(-dhx, Rect(pinned + dhx, cast(int) vm.top, width - pinned, docRows));

        // Search matches, through the identity channel (raw views).
        if (!vm.showPreview)
            foreach (i, rects; vm.matchRects)
                foreach (ref const r; rects)
                {
                    const row = r.y - vm.top;
                    if (row < 0 || row >= docRows)
                        continue;
                    auto x0 = r.x - dhx;
                    if (x0 < pinned)
                        x0 = pinned;
                    const x1 = r.x - dhx + r.width > width ? width : r.x - dhx + r.width;
                    if (x1 <= x0)
                        continue;
                    emit(fillRectOp(Rect(x0, y0 + cast(int) row, x1 - x0, 1), Slot.inherit,
                        Visual(bg: i == vm.curMatch ? RgbColor(255, 145, 0) : RgbColor(255, 215, 0),
                            bgAlpha: i == vm.curMatch ? 130 : 70, hasBg: true)));
                }

        // The vertical bar.
        const extent = vm.scrollExtent(docRows);
        if (extent > docRows)
            emit(DrawOp(Scrollbar(
                rect: Rect(cols - 1, y0, 1, docRows),
                content: cast(int)(extent > int.max ? int.max : extent),
                viewport: docRows,
                offset: cast(int) vm.top,
                fg: vm.sbThumb,
                trackColor: vm.sbTrack,
                edge: RuleEdge.right,
                trackGlyph: '│',
                thumbGlyph: '█',
                slot: Slot.thumb,
            )));

        if (searching)
            textLine(c, rows - 1, cols, "/" ~ cast(string) query.idup,
                mix(vm.pageBg, vm.pageFg, 0.12));
    }

    private void textLine(ref RaylibCanvas c, int row, int cols, string text, RgbColor bg) @system
    {
        import sparkles.ui.canvas : textRunOp;
        import sparkles.ui.interp.immediate : paint;

        DrawOp[2] ops = [
            fillRectOp(Rect(0, row, cols, 1), Slot.inherit, Visual(bg: bg, hasBg: true)),
            textRunOp(Rect(1, row, cols - 1, 1), text, Slot.inherit, Visual(fg: vm.pageFg)),
        ];
        paint(c, ops[]);
    }

    /// The view the header names: preview, highlighted or plain.
    string modeLabel() const @safe pure nothrow
    {
        if (error.length)
            return "error";
        final switch (kind)
        {
            case ViewKind.image:
                return "image";
            case ViewKind.unsupported:
                return "unsupported";
            case ViewKind.code, ViewKind.markdown, ViewKind.dsv, ViewKind.diff,
                ViewKind.twoslash, ViewKind.text:
                return vm.showPreview ? (vm.summary.length ? vm.summary : "preview")
                    : vm.plainSyntax ? "plain" : "raw";
        }
    }

    private string positionLabel() const @safe
    {
        import std.conv : text;

        if (error.length || kind == ViewKind.image)
            return "";
        return text(vm.top + 1, "/", vm.rows.length);
    }
}

// ── image files ─────────────────────────────────────────────────────────────

// A decoded image file as a texture, loaded on first paint (the GL context is
// the paint's) and scaled to fit, centred, never enlarged past 1:1.
private struct ImageTexture
{
    import raylib : Texture2D;

    Texture2D tex;
    bool loaded, failed;

    void draw(string path, int x, int y, int w, int h) @system
    {
        import raylib : Color, DrawTexturePro, LoadTexture, Rectangle,
            SetTextureFilter, TextureFilter, Vector2;
        import std.string : toStringz;

        if (!loaded && !failed)
        {
            tex = LoadTexture(path.toStringz);
            loaded = tex.id != 0;
            failed = !loaded;
            if (loaded)
                SetTextureFilter(tex, TextureFilter.TEXTURE_FILTER_BILINEAR);
        }
        if (!loaded || w <= 0 || h <= 0)
            return;
        float s = cast(float) w / tex.width;
        if (cast(float) h / tex.height < s)
            s = cast(float) h / tex.height;
        if (s > 1)
            s = 1;
        const dw = tex.width * s, dh = tex.height * s;
        DrawTexturePro(tex, Rectangle(0, 0, tex.width, tex.height),
            Rectangle(x + (w - dw) / 2, y + (h - dh) / 2, dw, dh),
            Vector2(0, 0), 0, Color(255, 255, 255, 255));
    }

    void release() @system
    {
        import raylib : UnloadTexture;

        if (loaded)
            UnloadTexture(tex);
        loaded = failed = false;
    }
}

private bool isAsset(string path) @safe pure nothrow @nogc
{
    import std.algorithm.searching : startsWith;

    return path.startsWith("asset:");
}

// The file's modification time, or `SysTime.init` when it is gone.
private SysTime modified(string path) @system
{
    import std.file : timeLastModified;

    if (isAsset(path))
        return SysTime.init;
    try
        return timeLastModified(path);
    catch (Exception)
        return SysTime.init;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests (no window: the input half and the theme).
// ─────────────────────────────────────────────────────────────────────────────

@("pane.chromeTheme.followsTheBackground")
@safe unittest
{
    const dark = chromeTheme(RgbColor(0xee, 0xee, 0xee), RgbColor(0x10, 0x10, 0x10));
    const light = chromeTheme(RgbColor(0x10, 0x10, 0x10), RgbColor(0xf8, 0xf8, 0xf8));
    assert(dark.rules is builtinDark.rules && light.rules is builtinLight.rules);
    assert(dark.defaultBg == Color.fromRgb(RgbColor(0x10, 0x10, 0x10)));
}

version (unittest)
{
    private KeyEvent ch(dchar c, bool ctrl = false)
    {
        import sparkles.input.events : Mods;
        import std.utf : encode;

        KeyEvent k;
        k.key = Key.char_;
        k.ch = c;
        k.mods = Mods(ctrl: ctrl);
        char[4] b;
        k.text = b[0 .. encode(b, c)];
        return k;
    }

    private KeyEvent named(Key key)
    {
        KeyEvent k;
        k.key = key;
        return k;
    }

    private string fixture(string name, string content) @system
    {
        import std.file : tempDir, write;
        import std.path : buildPath;
        import std.process : thisProcessID;
        import std.conv : text;

        const p = buildPath(tempDir, text("doc-view-pane-", thisProcessID, "-", name));
        write(p, content);
        return p;
    }
}

@("pane.key.viewerBindingsAndClose")
@system unittest
{
    import std.array : replicate;
    import std.file : remove;

    auto env = DocViewEnv.create(GrammarRegistry.fromEnvironment());
    const p = fixture("keys.txt", "line\n".replicate(200));
    scope (exit) remove(p);
    auto pane = new DocViewPane;
    assert(pane.open(env, p, chromeTheme(RgbColor(200, 200, 200), RgbColor(20, 20, 20))));
    pane.vm.relayout(60);
    pane.docRows = 20;

    assert(pane.key(ch('j')) == PaneKey.handled && pane.vm.top == 1);
    assert(pane.key(ch('G')) == PaneKey.handled && pane.vm.top == pane.vm.maxTopFor(20));
    assert(pane.key(ch('g')) == PaneKey.handled && pane.key(ch('g')) == PaneKey.handled);
    assert(pane.vm.top == 0, "gg goes to the top");
    assert(pane.key(ch('d', ctrl: true)) == PaneKey.handled && pane.vm.top == 10);
    assert(pane.key(ch('x', ctrl: true)) == PaneKey.ignored, "the embedder's chords pass");

    // `l` toggles the line-number channel.
    const before = pane.vm.lineNumbers;
    cast(void) pane.key(ch('l'));
    assert(pane.vm.lineNumbers != before);

    // Search: typed incrementally, Esc clears it without closing the pane.
    cast(void) pane.key(ch('/'));
    foreach (c; "line")
        cast(void) pane.key(ch(c));
    assert(pane.vm.matches.length == 200);
    assert(pane.key(named(Key.escape)) == PaneKey.handled && pane.vm.matches.length == 0);

    assert(pane.key(ch('q')) == PaneKey.close);
    assert(pane.key(named(Key.escape)) == PaneKey.close);
}

@("pane.poll.reloadsKeepingTheLine")
@system unittest
{
    import core.thread : Thread;
    import std.array : replicate;
    import std.file : remove, setTimes, write;
    import std.datetime.systime : Clock;
    import core.time : seconds;

    auto env = DocViewEnv.create(GrammarRegistry.fromEnvironment());
    const p = fixture("reload.txt", "a\n".replicate(100) ~ "MARK\n" ~ "b\n".replicate(100));
    scope (exit) remove(p);
    auto pane = new DocViewPane;
    assert(pane.open(env, p, chromeTheme(RgbColor(200, 200, 200), RgbColor(20, 20, 20))));
    pane.vm.relayout(60);
    pane.docRows = 20;
    pane.vm.scrollTo(100);
    assert(pane.vm.source[pane.vm.rows[100].srcStart .. $][0 .. 4] == "MARK");

    // Ten lines inserted above: the top is still source line 101 — the
    // reader keeps their place in the file, as a pager does.
    write(p, "new\n".replicate(10) ~ "a\n".replicate(100) ~ "MARK\n" ~ "b\n".replicate(100));
    const later = Clock.currTime + 5.seconds;
    setTimes(p, later, later);
    pane.lastPoll = MonoTime.init;
    assert(pane.poll());
    const t = cast(size_t) pane.vm.top;
    assert(pane.vm.rows[t].srcStart == pane.vm.lineStarts[100]);
    assert(pane.vm.source[pane.vm.lineStarts[110] .. $][0 .. 4] == "MARK");

    // Deleted: the content stays, flagged.
    remove(p);
    pane.lastPoll = MonoTime.init;
    cast(void) pane.poll();
    assert(pane.deleted && pane.vm.source.length);
    write(p, "back\n");
}

@("pane.open.refusesWhatItCannotShow")
@system unittest
{
    import std.file : remove;

    auto env = DocViewEnv.create(GrammarRegistry.fromEnvironment());
    auto pane = new DocViewPane;
    assert(!pane.open(env, "/nonexistent/x.md", chromeTheme(RgbColor(0, 0, 0), RgbColor(255, 255, 255))));
    assert(pane.error.length, "a located error, not a crash");
}

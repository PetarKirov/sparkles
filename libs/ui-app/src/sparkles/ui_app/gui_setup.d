/**
Opening a window and loading its fonts, in the one order that works (`CLI4`–`CLI6`).

$(B The order is the contract, not the caller's problem.) Cell metrics do not
exist until the font set loads; the font set cannot load until a GL context
exists, because it uploads a texture; and the requested window size is in
$(B cells). So:

$(OL
    $(LI open the window at a provisional pixel size,)
    $(LI load the font set,)
    $(LI resolve the point size against the real panel,)
    $(LI resize to `cols × cellW`, `rows × cellH`.)
)

Any host that reorders these produces a window of the wrong size, and does so
silently. Encoding it here is the point of the module.

$(B The deterministic hooks are parameters, not environment reads.) A golden-frame
capture needs the pixel size pinned and DPI scaling suppressed; that is the
caller's business to decide and this module's to honour, so nothing here reads
the environment.
*/
module sparkles.ui_app.gui_setup;

version (UiAppGui):

import sparkles.raylib_text : displayMetrics, FontSet, pixelsForPoints;
import sparkles.ui_raylib.window : TraceLogSink, Window, WindowRequest;
import sparkles.ui_app.gui_options : FontRequest, WindowCells;

/// What the caller wants of a window and its fonts.
struct GuiRequest
{
    string title;                 /// window title
    FontRequest font;             /// the faces to resolve
    WindowCells cells;            /// requested size, in cells
    int fontSizePoints = 18;      /// resolved against the panel unless overridden

    /**
    A pixel size to use verbatim, bypassing point resolution (`0` = off).

    What a reproducible capture needs: the same pixels on any panel. It
    suppresses density scaling entirely rather than being scaled itself, which
    is the whole reason it exists — a capture whose font size quietly follows
    the display is a broken oracle, not a cosmetic difference.
    */
    int fontSizePxOverride;

    /// Extra directories to resolve faces from, ahead of fontconfig. An
    /// Android build passes its extracted asset directory and `/system/fonts`.
    string[] extraFontSources;

    /// Where the backend's own trace log goes. Installed BEFORE the window
    /// opens, because the interesting lines are emitted during creation — a
    /// sink attached afterwards misses exactly the ones worth having when
    /// creation is what failed.
    TraceLogSink traceSink;

    int targetFps = 60; ///
}

/// An open window and the fonts drawn into it. Non-copyable: two handles to one
/// window would let a stale copy close it.
struct GuiSession
{
    Window window;   ///
    FontSet fonts;   ///
    int fontSizePx;  /// the resolved pixel size

    @disable this(this);

    ~this() @system
    {
        fonts.unload();
    }

    int cellW() const @safe pure nothrow @nogc => fonts.cellW;
    /// ditto
    int cellH() const @safe pure nothrow @nogc => fonts.cellH;

    /**
    Reloads every face at `px` (clamped to $(LREF minFontSizePx)) and
    re-measures the cell metrics — the host errand behind Ctrl+`=`/`-`
    (`HST14`). Call $(B outside) the frame bracket: reloading uploads font
    textures. The surface size in cells changes on the next read; the window's
    pixel size does not (matching what every terminal emulator does — more or
    fewer cells, same window).
    */
    void setFontSize(int px) @system nothrow @nogc
    {
        fontSizePx = px < minFontSizePx ? minFontSizePx : px;
        fonts.reload(fontSizePx);
    }
}

/**
Opens a window and loads its font set, in the order above.

Returns `false` when no font could be resolved — the caller's cue to report the
family it asked for, since the window is open by then and painting into it
without a font would produce a blank one.
*/
bool openGuiSession(in GuiRequest req, out GuiSession session) @system
{
    import std.string : toStringz;

    if (req.traceSink !is null)
    {
        import sparkles.ui_raylib.window : traceLogTo;

        traceLogTo(req.traceSink);
    }

    // 1. The window. Android is the exception at both ends: `0 × 0` means the
    //    native surface resolution there (a non-zero size is NOT ignored — it
    //    is letterboxed onto the screen), the surface is not resizable, and it
    //    is not sized in cells afterwards either, because the surface IS the
    //    application.
    version (Android)
        session.window = Window.open(WindowRequest(
            title: req.title, width: 0, height: 0, resizable: false,
            targetFps: req.targetFps));
    else
        session.window = Window.open(WindowRequest(
            title: req.title, width: 800, height: 600,
            targetFps: req.targetFps));

    // 2. The point size. An explicit pixel override wins and suppresses density
    //    scaling; otherwise the panel decides, which is not an Android special
    //    case — a HiDPI desktop has the same problem and used to get the same
    //    px as a 96-dpi one.
    session.fontSizePx = req.fontSizePxOverride > 0
        ? req.fontSizePxOverride
        : pixelsForPoints(req.fontSizePoints, displayMetrics());
    if (session.fontSizePx < minFontSizePx)
        session.fontSizePx = minFontSizePx;

    // 3. The font set — after the window, because loading uploads a texture.
    string[] dirs;
    foreach (d; req.font.searchDirs)
        dirs ~= d;
    foreach (d; req.extraFontSources)
        dirs ~= d;
    auto sources = FontSet.FontSources(dirs,
        useSystemFontDb: req.font.useSystemFontDb && req.extraFontSources.length == 0);
    auto faces = FontSet.FaceOverrides(
        req.font.bold, req.font.italic, req.font.boldItalic);

    // Mutable copies: `in` makes the request's fields const, and the loader
    // takes its arguments by value.
    string family = req.font.family;
    string[] maps;
    foreach (m; req.font.codepointMaps)
        maps ~= m;

    if (!FontSet.tryLoad(family, session.fontSizePx, session.fonts,
            maps, faces, sources))
        return false;

    // 4. The size, now that a cell has a width. Skipped on Android, where the
    //    surface is the screen and there is nothing to size.
    version (Android) {}
    else if (req.cells.cols > 0 && req.cells.rows > 0)
        session.window.resize(req.cells.cols * session.fonts.cellW,
            req.cells.rows * session.fonts.cellH);

    return true;
}

/// The floor a resolved pixel size is clamped to. Below this the atlas stops
/// being legible and starts being a rounding error.
enum int minFontSizePx = 6;

@("ui_app.gui_setup.requestDefaults")
@safe pure nothrow
unittest
{
    // The request carries the shared defaults, so a caller that fills in only
    // a title gets the same window every other application gets.
    const r = GuiRequest.init;
    assert(r.fontSizePoints == 18);
    assert(r.fontSizePxOverride == 0, "off unless a capture asks for it");
    assert(r.targetFps == 60);
    assert(r.traceSink is null);
}

/**
The document pane the workspace embeds.

`sparkles.doc_view.pane` compiles only where the consumer links
`sparkles:ui-raylib`. The native arm has no such pane yet: opening a file
reports that, and the shared frame loops see an empty set.

Drift guard: this stub mirrors every member `workspace_host` names
outside a `version (Have_sparkles_ui_raylib)` block, plus `open` below.
Members only the raylib branch names (`vm`, `DocViewEnv.create`) stay
out — naming one here pulls the real pane's dependency closure into an
arm that cannot link it. If shared code grows a new viewer call, add it
here in the same commit or the Vulkan build breaks alone.
*/
module viewer_link;

version (Have_sparkles_ui_raylib)
{
    public import sparkles.doc_view.pane : chromeTheme, DocViewEnv, DocViewPane, PaneKey;
}
else
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.input.events : KeyEvent, WheelEvent;
    import sparkles.ui.components.scroll_view : OverlayBar;
    import sparkles.ui.geometry : Rect;
    import sparkles.ui.scroll_motion : ScrollMotion;
    import sparkles.ui.theme : Theme;

    /// What a viewer key did. The real pane's enum, without the pane.
    enum PaneKey : ubyte
    {
        ignored,
        handled,
        close,
    }

    /// No environment on this arm.
    struct DocViewEnv
    {
    }

    immutable(Theme) chromeTheme(RgbColor, RgbColor) @safe pure nothrow
        => Theme.init;

    /// Not constructed. The methods exist so the host's loops typecheck.
    struct DocViewPane
    {
        bool deferLoad;
        bool touch;
        bool wide;
        string title;
        OverlayBar bar;
        ScrollMotion motion;

        bool needsPaint() const @safe pure nothrow @nogc => false;
        bool poll() @safe pure nothrow @nogc => false;
        void release() @safe pure nothrow @nogc {}
        void setTheme(immutable(Theme)) @safe pure nothrow @nogc {}
        bool wheel(int, int, in WheelEvent) @safe pure nothrow @nogc => false;
        bool animate(float) @safe pure nothrow @nogc => false;
        void barTo(double) @safe pure nothrow @nogc {}
        /// Never opens on this arm; `workspace_host.createViewer` reports
        /// the missing viewer before this could be reached.
        bool open(DocViewEnv*, string, immutable(Theme)) @safe pure nothrow @nogc => false;
        bool barGeometry(out Rect, out long, out long) const @safe pure nothrow @nogc => false;
        PaneKey key(in KeyEvent) @safe pure nothrow @nogc => PaneKey.ignored;

        void paint(C)(C, int, int, int, int, bool focused, in Rect barBand = Rect.init)
            @safe pure nothrow @nogc
        {
        }
    }
}

// `hue --gui` — the raylib GPU rendering backend.
//
// A third consumer of hue's (source, events, theme) triple: instead of folding
// the highlight-event stream into ANSI escapes or HTML markup, it folds it into
// raylib draw calls — "styled runs as data", the GPU backend sparkles:syntax was
// designed for (docs/specs/syntax §2). A read-only, windowed, syntax-highlighted
// view with a live theme previewer, mirroring hue's terminal Previewer on the GPU.
//
// Compiled only by the `gui` build configuration (version(HueGui)); the default
// terminal build never references raylib. Build: dub build :hue -c gui.
module gui;

version (HueGui):

import raylib;

import sparkles.syntax : HighlightEvent, LabelSet, Theme;

/**
Opens the raylib window and paints the highlighted file, browsing `themes`
live with the arrow keys (the GPU counterpart of hue's terminal previewer).

`names`/`themes` are the sorted, parallel built-in theme arrays; `startIdx` is
the initially selected theme. Returns a process exit code.
*/
int runGui(
    string title,
    const(char)[] source,
    const(HighlightEvent)[] events,
    LabelSet labels,
    const(string)[] names,
    immutable(Theme)[] themes,
    size_t startIdx,
)
{
    // M0: window shell only. The render fold (M1) draws the styled runs.
    import std.string : toStringz;

    InitWindow(800, 600, ("hue — " ~ title).toStringz);
    scope (exit) CloseWindow();
    SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    SetTargetFPS(60);
    SetExitKey(KeyboardKey.KEY_NULL);

    while (!WindowShouldClose())
    {
        BeginDrawing();
        ClearBackground(Colors.DARKGRAY);
        EndDrawing();
    }

    return 0;
}

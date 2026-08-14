#!/usr/bin/env dub
/+ dub.sdl:
    name "cursor-shapes"
    description "Hover/click tiles to exercise raylib SetMouseCursor / GLFW standard shapes"
    targetType "executable"
    targetPath "build"
    dependency "raylib-d" version="~>6.0.1"
    libs "raylib"
+/
/// Click / hover the tiles to ask raylib (`SetMouseCursor`) for each standard
/// pointer shape. Stock GLFW 3.5.1 fails most of these on GNOME/Adwaita;
/// the sparkles glfw overlay (wp_cursor_shape_v1) is what makes them work.
/// See index.md.
module cursor_shapes;

import raylib;

struct Tile
{
    const(char)* label;
    MouseCursor cursor;
}

void main()
{
    SetTraceLogLevel(TraceLogLevel.LOG_WARNING);
    SetConfigFlags(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    InitWindow(720, 520, "raylib pointer-shape probe");
    SetTargetFPS(60);

    static immutable Tile[] tiles = [
        Tile("DEFAULT", MouseCursor.MOUSE_CURSOR_DEFAULT),
        Tile("ARROW", MouseCursor.MOUSE_CURSOR_ARROW),
        Tile("IBEAM", MouseCursor.MOUSE_CURSOR_IBEAM),
        Tile("CROSSHAIR", MouseCursor.MOUSE_CURSOR_CROSSHAIR),
        Tile("POINTING_HAND", MouseCursor.MOUSE_CURSOR_POINTING_HAND),
        Tile("RESIZE_EW", MouseCursor.MOUSE_CURSOR_RESIZE_EW),
        Tile("RESIZE_NS", MouseCursor.MOUSE_CURSOR_RESIZE_NS),
        Tile("RESIZE_NWSE", MouseCursor.MOUSE_CURSOR_RESIZE_NWSE),
        Tile("RESIZE_NESW", MouseCursor.MOUSE_CURSOR_RESIZE_NESW),
        Tile("RESIZE_ALL", MouseCursor.MOUSE_CURSOR_RESIZE_ALL),
        Tile("NOT_ALLOWED", MouseCursor.MOUSE_CURSOR_NOT_ALLOWED),
    ];

    MouseCursor current = MouseCursor.MOUSE_CURSOR_DEFAULT;
    const(char)* currentName = "DEFAULT";

    while (!WindowShouldClose())
    {
        const mouse = GetMousePosition();
        const cols = 3;
        const margin = 16;
        const gap = 10;
        const header = 88;
        const tw = (GetScreenWidth() - margin * 2 - gap * (cols - 1)) / cols;
        const th = 56;

        bool overAny;
        foreach (i, tile; tiles)
        {
            const col = cast(int)(i % cols);
            const row = cast(int)(i / cols);
            const r = Rectangle(
                margin + col * (tw + gap),
                header + row * (th + gap),
                tw, th);
            const hot = CheckCollisionPointRec(mouse, r);
            if (hot)
            {
                overAny = true;
                current = tile.cursor;
                currentName = tile.label;
                if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT))
                    currentName = tile.label;
            }
        }
        if (!overAny)
        {
            current = MouseCursor.MOUSE_CURSOR_DEFAULT;
            currentName = "DEFAULT";
        }
        SetMouseCursor(current);

        BeginDrawing();
        ClearBackground(Color(28, 30, 34, 255));
        DrawText("Hover or click a tile to SetMouseCursor(...)", 16, 16, 20, Colors.RAYWHITE);
        DrawText(TextFormat("requested: %s  (raylib %s)", currentName, RAYLIB_VERSION.ptr),
            16, 44, 18, Color(180, 200, 140, 255));
        DrawText("If the OS pointer does not change, GLFW could not realise that shape.",
            16, 66, 16, Color(160, 160, 160, 255));

        foreach (i, tile; tiles)
        {
            const col = cast(int)(i % cols);
            const row = cast(int)(i / cols);
            const r = Rectangle(
                margin + col * (tw + gap),
                header + row * (th + gap),
                tw, th);
            const hot = tile.cursor == current && overAny;
            DrawRectangleRec(r, hot ? Color(70, 110, 160, 255) : Color(50, 54, 60, 255));
            DrawRectangleLinesEx(r, 2, hot ? Colors.RAYWHITE : Color(90, 94, 100, 255));
            const twid = MeasureText(tile.label, 18);
            DrawText(tile.label,
                cast(int)(r.x + (r.width - twid) / 2),
                cast(int)(r.y + (r.height - 18) / 2),
                18, Colors.RAYWHITE);
        }
        EndDrawing();
    }
    CloseWindow();
}

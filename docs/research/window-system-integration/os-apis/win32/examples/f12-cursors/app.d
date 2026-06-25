// F12 — Cursors, Win32 implementation (../../../features/f12-cursors.md).
// Extends the scaffold (../scaffold/app.d) into a WM_SETCURSOR observatory:
//
//   * A 3×3 hover-zone grid over the client area: the 8 border cells map the
//     8 resize edges onto Win32's FOUR bidirectional resize shapes
//     (IDC_SIZENWSE / IDC_SIZENS / IDC_SIZENESW / IDC_SIZEWE — the vocabulary
//     has no per-edge cursors), and the center cell is subdivided 2×2 into
//     IDC_ARROW / IDC_IBEAM / IDC_HAND / a custom cursor. Every WM_SETCURSOR
//     is logged (the per-mouse-move storm), plus cursor_set on zone change.
//   * The pointer is driven from inside the demo: SetCursorPos steps a
//     12-stop tour across the zones (winewayland has no external warp tool;
//     SetCursorPos goes through wineserver's virtual cursor and works), and
//     each warp's WM_MOUSEMOVE → WM_SETCURSOR cascade lands in the log.
//   * One custom ARGB cursor via CreateIconIndirect (32×32 bullseye, hotspot
//     16,16: a 32bpp top-down DIB color bitmap + an all-zero monochrome mask).
//     CreateCursor is NOT used — it only takes monochrome AND/XOR planes.
//   * Class-cursor vs WM_SETCURSOR precedence probe: the class registers
//     hCursor=IDC_CROSS; phases then answer WM_SETCURSOR differently —
//     normal: SetCursor(zone)+return TRUE; set_then_def: SetCursor(IDC_HAND)
//     then DefWindowProcW; class_only: straight to DefWindowProcW — and
//     GetCursor() is sampled afterwards to capture who won.
//   * DPI: logs GetSystemMetrics(SM_CXCURSOR/SM_CYCURSOR); animated cursors:
//     attempts LoadCursorFromFileW on the prefix's C:\windows\cursors .ani
//     (logged either way; Wine prefixes ship no .ani files).
//     SetSystemCursor (system-wide cursor replacement) is deliberately NOT
//     called — it would mutate host-global state.
//
// WSI_AUTO_EXIT=1 bounds the run (~2 s); exit 0 in all modes.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

// ---------------------------------------------------------------------------
// Cursor inventory: system shapes + one custom ARGB cursor.

enum CursorId
{
    arrow,
    ibeam,
    hand,
    sizenwse, // ↖↘ — serves both the NW and SE edges
    sizenesw, // ↗↙ — serves both the NE and SW edges
    sizewe, // ↔ — serves both the W and E edges
    sizens, // ↕ — serves both the N and S edges
    cross, // the class cursor (precedence probe)
    custom, // 32×32 ARGB bullseye, hotspot (16,16)
}

immutable string[CursorId.max + 1] cursorNames = [
    "IDC_ARROW", "IDC_IBEAM", "IDC_HAND", "IDC_SIZENWSE", "IDC_SIZENESW",
    "IDC_SIZEWE", "IDC_SIZENS", "IDC_CROSS", "custom_bullseye",
];

__gshared HCURSOR[CursorId.max + 1] cursors;

const(char)* cursorName(HCURSOR h) nothrow
{
    if (h is null)
        return "null";
    foreach (i, c; cursors)
        if (c is h)
            return cursorNames[i].ptr;
    return "unknown";
}

// 32×32 ARGB bullseye with hotspot (16,16): concentric opaque rings over
// transparent ground. CreateIconIndirect with fIcon=FALSE turns the pair of
// bitmaps into a cursor; the 32bpp hbmColor carries the alpha channel, and
// the monochrome hbmMask must still be supplied (all-zero here).
HCURSOR createBullseyeCursor() nothrow
{
    enum N = 32;
    BITMAPINFO bmi;
    bmi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
    bmi.bmiHeader.biWidth = N;
    bmi.bmiHeader.biHeight = -N; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    void* bits;
    HBITMAP color = CreateDIBSection(null, &bmi, DIB_RGB_COLORS, &bits, null, 0);
    if (color is null)
        return null;
    auto px = cast(uint*) bits;
    foreach (y; 0 .. N)
        foreach (x; 0 .. N)
        {
            const dx = x - 16, dy = y - 16;
            const r2 = dx * dx + dy * dy;
            uint argb = 0; // transparent
            if (r2 <= 12 || (r2 >= 64 && r2 <= 110) || (r2 >= 196 && r2 <= 256))
                argb = 0xff000000 | (r2 <= 12 ? 0x00ff0000 : 0x00ffffff);
            px[cast(size_t) y * N + x] = argb;
        }
    static immutable ubyte[N * N / 8] maskBits; // all zero
    HBITMAP mask = CreateBitmap(N, N, 1, 1, maskBits.ptr);
    ICONINFO ii;
    ii.fIcon = FALSE; // FALSE = cursor → hotspot fields are honored
    ii.xHotspot = 16;
    ii.yHotspot = 16;
    ii.hbmMask = mask;
    ii.hbmColor = color;
    HCURSOR cur = cast(HCURSOR) CreateIconIndirect(&ii);
    DeleteObject(color); // CreateIconIndirect copies both bitmaps
    DeleteObject(mask);
    return cur;
}

void loadCursors() nothrow
{
    cursors[CursorId.arrow] = LoadCursorW(null, IDC_ARROW);
    cursors[CursorId.ibeam] = LoadCursorW(null, IDC_IBEAM);
    cursors[CursorId.hand] = LoadCursorW(null, IDC_HAND);
    cursors[CursorId.sizenwse] = LoadCursorW(null, IDC_SIZENWSE);
    cursors[CursorId.sizenesw] = LoadCursorW(null, IDC_SIZENESW);
    cursors[CursorId.sizewe] = LoadCursorW(null, IDC_SIZEWE);
    cursors[CursorId.sizens] = LoadCursorW(null, IDC_SIZENS);
    cursors[CursorId.cross] = LoadCursorW(null, IDC_CROSS);
    cursors[CursorId.custom] = createBullseyeCursor();
    foreach (i, c; cursors)
        logEvent("cursor_loaded name=%s handle=%p", cursorNames[i].ptr, c);
}

// ---------------------------------------------------------------------------
// Hover zones: 3×3 grid, the 8 border cells = the 8 resize edges, the center
// cell subdivided 2×2 (arrow / ibeam / hand / custom).

struct Zone
{
    const(char)* name;
    CursorId cursor;
}

// Border cells by (col, row), center handled separately.
immutable Zone[3][3] borderZones = [
    [{"nw", CursorId.sizenwse}, {"n", CursorId.sizens}, {"ne", CursorId.sizenesw}],
    [{"w", CursorId.sizewe}, {"center", CursorId.arrow}, {"e", CursorId.sizewe}],
    [{"sw", CursorId.sizenesw}, {"s", CursorId.sizens}, {"se", CursorId.sizenwse}],
];

immutable Zone[4] centerZones = [
    {"c_arrow", CursorId.arrow}, {"c_ibeam", CursorId.ibeam},
    {"c_hand", CursorId.hand}, {"c_custom", CursorId.custom},
];

Zone zoneForPoint(int x, int y, int w, int h) nothrow
{
    if (w <= 0 || h <= 0)
        return Zone("outside", CursorId.arrow);
    int col = x * 3 / w, row = y * 3 / h;
    if (col < 0) col = 0; if (col > 2) col = 2;
    if (row < 0) row = 0; if (row > 2) row = 2;
    if (col != 1 || row != 1)
        return borderZones[row][col];
    // center cell: quadrants
    const qx = x * 6 / w >= 3 ? 1 : 0; // right half of the center cell
    const qy = y * 6 / h >= 3 ? 1 : 0; // bottom half
    return centerZones[qy * 2 + qx];
}

// The 12-stop SetCursorPos tour: 8 border zones, then the 4 center quadrants.
// Coordinates are zone centers in 1/6ths of the client size.
struct Stop
{
    const(char)* name;
    int sx, sy; // client position numerators over /6
}

immutable Stop[12] tour = [
    {"nw", 1, 1}, {"n", 3, 1}, {"ne", 5, 1}, {"e", 5, 3},
    {"se", 5, 5}, {"s", 3, 5}, {"sw", 1, 5}, {"w", 1, 3},
    {"c_arrow", 13, 13}, {"c_ibeam", 17, 13}, // center quadrants: /30ths
    {"c_hand", 13, 17}, {"c_custom", 17, 17},
];

// ---------------------------------------------------------------------------
// Demo state.

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 16;
enum TOUR_STEP_TICKS = 6; // one SetCursorPos warp per ~96 ms

enum Phase
{
    normal, // SetCursor(zone) + return TRUE
    setThenDef, // SetCursor(IDC_HAND) then DefWindowProcW — who wins?
    classOnly, // straight to DefWindowProcW → class cursor (IDC_CROSS)
}

immutable string[Phase.max + 1] phaseNames = ["normal", "set_then_def", "class_only"];

struct Demo
{
    HDC memDc;
    HBITMAP dib, stockBmp;
    uint* pixels;
    int width, height;
    uint frame, ticks;
    uint nSetCursor, nMouseMove;
    int tourIndex = -1; // last issued stop
    Phase phase;
    const(char)* lastZone = "";
    bool autoExit;
    bool firstPaintDone;
}

__gshared Demo g;

void createBackbuffer(int w, int h) nothrow
{
    if (g.dib !is null)
    {
        SelectObject(g.memDc, g.stockBmp);
        DeleteObject(g.dib);
        g.dib = null;
        g.pixels = null;
        g.width = g.height = 0;
    }
    if (w <= 0 || h <= 0)
        return;
    BITMAPINFO bmi;
    bmi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    void* bits;
    g.dib = CreateDIBSection(null, &bmi, DIB_RGB_COLORS, &bits, null, 0);
    if (g.dib is null)
    {
        logEvent("error what=CreateDIBSection code=%lu", GetLastError());
        return;
    }
    g.pixels = cast(uint*) bits;
    g.width = w;
    g.height = h;
    g.stockBmp = cast(HBITMAP) SelectObject(g.memDc, g.dib);
    logEvent("buffer_alloc size=%dx%d bytes=%d", w, h, w * h * 4);
}

// Scaffold gradient + the 3×3 grid lines so the zones are visible on screen.
void drawFrame() nothrow
{
    if (g.pixels is null)
        return;
    const w = g.width, h = g.height;
    const blue = (g.frame * 4) & 0xff;
    foreach (y; 0 .. h)
    {
        uint* row = g.pixels + cast(size_t) y * w;
        const green = h > 1 ? (y * 255) / (h - 1) : 0;
        foreach (x; 0 .. w)
        {
            const red = w > 1 ? (x * 255) / (w - 1) : 0;
            row[x] = cast(uint)((red << 16) | (green << 8) | blue);
        }
    }
    foreach (i; 1 .. 3) // grid lines at 1/3 and 2/3
    {
        foreach (x; 0 .. w)
            g.pixels[cast(size_t)(h * i / 3) * w + x] = 0xffffff;
        foreach (y; 0 .. h)
            g.pixels[cast(size_t) y * w + (w * i / 3)] = 0xffffff;
    }
}

// Warp the OS cursor to a tour stop (client-relative → screen coordinates).
void warpTo(HWND hwnd, in Stop stop) nothrow
{
    RECT rc;
    GetClientRect(hwnd, &rc);
    const den = stop.sx >= 6 ? 30 : 6; // center quadrants use /30ths
    POINT p = POINT(rc.right * stop.sx / den, rc.bottom * stop.sy / den);
    ClientToScreen(hwnd, &p);
    logEvent("tour_warp zone=%s client=%d,%d screen=%d,%d",
        stop.name, rc.right * stop.sx / den, rc.bottom * stop.sy / den, p.x, p.y);
    if (!SetCursorPos(p.x, p.y))
        logEvent("error what=SetCursorPos code=%lu", GetLastError());
}

// ---------------------------------------------------------------------------

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_CREATE:
        g.memDc = CreateCompatibleDC(null);
        return 0;

    case WM_SETCURSOR:
        // Sent on EVERY mouse message while the cursor is over the window
        // (and on some non-mouse triggers) — the "storm". lParam: low word =
        // hit-test code, high word = the triggering mouse message.
        ++g.nSetCursor;
        const hit = cast(uint)(lParam & 0xffff);
        const trigger = cast(uint)((lParam >> 16) & 0xffff);
        logEvent("wm_setcursor n=%u hittest=%u trigger=0x%x phase=%s",
            g.nSetCursor, hit, trigger, phaseNames[g.phase].ptr);
        if (hit != HTCLIENT)
            goto default; // non-client area: let DefWindowProc pick
        if (g.phase == Phase.normal)
        {
            POINT p;
            GetCursorPos(&p);
            ScreenToClient(hwnd, &p);
            RECT rc;
            GetClientRect(hwnd, &rc);
            const zone = zoneForPoint(p.x, p.y, rc.right, rc.bottom);
            SetCursor(cursors[zone.cursor]);
            if (zone.name !is g.lastZone)
            {
                g.lastZone = zone.name;
                logEvent("cursor_set name=%s zone=%s", cursorNames[zone.cursor].ptr, zone.name);
            }
            return TRUE; // handled — DefWindowProc must not reset it
        }
        if (g.phase == Phase.setThenDef)
        {
            SetCursor(cursors[CursorId.hand]);
            logEvent("cursor_set name=IDC_HAND zone=probe then=DefWindowProcW");
        }
        goto default; // DefWindowProc applies the class cursor — or not?

    case WM_MOUSEMOVE:
        ++g.nMouseMove;
        goto default; // DefWindowProc generates the WM_SETCURSOR for us

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        if (wParam == SIZE_MINIMIZED)
            return 0;
        if (w != g.width || h != g.height)
            createBackbuffer(w, h);
        return 0;

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        ++g.frame;
        drawFrame();
        if (g.pixels !is null)
            BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
        if (!g.firstPaintDone)
        {
            g.firstPaintDone = true;
            logEvent("first_pixel_presented size=%dx%d", g.width, g.height);
        }
        EndPaint(hwnd, &ps);
        return 0;

    case WM_TIMER:
        if (wParam != TIMER_ID)
            return 0;
        ++g.ticks;
        InvalidateRect(hwnd, null, FALSE);
        if (g.autoExit)
            runSchedule(hwnd);
        return 0;

    case WM_CLOSE:
        logEvent("close_requested");
        goto default;

    case WM_DESTROY:
        KillTimer(hwnd, TIMER_ID);
        createBackbuffer(0, 0);
        if (g.memDc !is null)
        {
            DeleteDC(g.memDc);
            g.memDc = null;
        }
        if (cursors[CursorId.custom] !is null)
            DestroyCursor(cursors[CursorId.custom]);
        logEvent("summary wm_setcursor=%u wm_mousemove=%u", g.nSetCursor, g.nMouseMove);
        PostQuitMessage(0);
        return 0;

    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

// The bounded-run schedule: 12 tour warps, then the precedence probe (each
// phase: a fresh warp forces a WM_SETCURSOR, GetCursor() sampled 2 ticks
// later shows which cursor survived), then DestroyWindow.
void runSchedule(HWND hwnd) nothrow
{
    const t = g.ticks;
    if (t % TOUR_STEP_TICKS == 0 && t / TOUR_STEP_TICKS <= tour.length)
    {
        const i = cast(int)(t / TOUR_STEP_TICKS) - 1;
        if (i > g.tourIndex)
        {
            g.tourIndex = i;
            warpTo(hwnd, tour[i]);
        }
        return;
    }
    enum probeBase = (tour.length + 1) * TOUR_STEP_TICKS; // tick 78
    switch (t)
    {
    case probeBase: // phase 1: SetCursor then DefWindowProc
        g.phase = Phase.setThenDef;
        logEvent("precedence_begin phase=set_then_def class_cursor=IDC_CROSS");
        warpTo(hwnd, tour[8]); // back to the center-arrow quadrant
        break;
    case probeBase + 4:
        logEvent("precedence_result phase=set_then_def cursor_after=%s", cursorName(GetCursor()));
        g.phase = Phase.classOnly;
        logEvent("precedence_begin phase=class_only class_cursor=IDC_CROSS");
        warpTo(hwnd, tour[9]);
        break;
    case probeBase + 8:
        logEvent("precedence_result phase=class_only cursor_after=%s", cursorName(GetCursor()));
        g.phase = Phase.normal;
        warpTo(hwnd, tour[10]);
        break;
    case probeBase + 12:
        logEvent("precedence_result phase=normal cursor_after=%s", cursorName(GetCursor()));
        DestroyWindow(hwnd);
        break;
    default:
        break;
    }
}

// ---------------------------------------------------------------------------

bool envFlag(const(wchar)* name) nothrow
{
    WCHAR[16] buf;
    const n = GetEnvironmentVariableW(name, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

int main()
{
    instrumentInit("f12_cursors_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    logEvent("mode auto_exit=%d", g.autoExit ? 1 : 0);

    loadCursors();

    // DPI/system metrics: the nominal system cursor size. Win32 scales the
    // cursor per-monitor only via the system "cursor size" accessibility
    // setting / per-monitor DPI on Win10+; there is no per-window API.
    logEvent("cursor_metrics sm_cxcursor=%d sm_cycursor=%d",
        GetSystemMetrics(SM_CXCURSOR), GetSystemMetrics(SM_CYCURSOR));

    // Animated cursor probe: Windows ships .ani files under
    // C:\windows\cursors; does this (Wine) prefix?
    SetLastError(0);
    HCURSOR ani = LoadCursorFromFileW(`C:\windows\cursors\aero_busy.ani`w.ptr);
    logEvent("ani_probe path=C:/windows/cursors/aero_busy.ani handle=%p err=%lu",
        ani, ani is null ? GetLastError() : 0);
    if (ani !is null)
        DestroyCursor(ani);

    HINSTANCE hInst = GetModuleHandleW(null);
    auto clsName = "wsi-f12-class"w;
    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = clsName.ptr;
    // The probe target: a DISTINCT class cursor, so the log can tell whether
    // DefWindowProc re-applied it over our SetCursor.
    wc.hCursor = cursors[CursorId.cross];
    if (!RegisterClassExW(&wc))
    {
        logEvent("error what=RegisterClassExW code=%lu", GetLastError());
        return 1;
    }
    HWND hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f12-cursors"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, hInst, null);
    if (hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, TIMER_ID, TICK_MS, null);

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    logEvent("exit code=%d", cast(int) msg.wParam);
    return cast(int) msg.wParam;
}

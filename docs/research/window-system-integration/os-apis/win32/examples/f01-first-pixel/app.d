// F01 — first pixel & init cost, Win32 (../../f01-first-pixel.md).
//
// Implements every requirement of ../../../features/f01-first-pixel.md on top
// of the scaffold (../scaffold/app.d):
//
//   * Presents exactly ONE software-drawn frame (the corner-anchored gradient
//     into a CreateDIBSection backbuffer, BitBlt inside WM_PAINT) and exits
//     cleanly after a short hold (WSI_AUTO_EXIT=1 -> ~200 ms SetTimer ->
//     DestroyWindow -> exit 0).
//   * Logs one `step name=<api-call>` per initialization call, init_start ->
//     first_pixel_presented. LoadCursorW is called TWICE (call=1 / call=2):
//     the scaffold found the first user32 call pays the one-time session
//     connection (~13 ms under Wine); the second call isolates the per-call
//     cost from that first-connection cost.
//   * WSI_WS_VISIBLE=1 creates the window with WS_VISIBLE instead of calling
//     ShowWindow, to prove for which styles the "WM_SIZE arrives during
//     CreateWindowExW" claim holds (the scaffold showed it does NOT for a
//     non-WS_VISIBLE window — the first WM_SIZE lands in ShowWindow instead).
//   * Every creation-cascade message (incl. WM_GETMINMAXINFO and
//     WM_WINDOWPOSCHANGING, which the scaffold left uninstrumented) is logged
//     so the two orderings can be diffed line by line.
//   * first_pixel_presented = the return of the first BitBlt inside WM_PAINT
//     (spec requirement 3); a `summary` event records the concept count.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

struct Demo
{
    HDC memDc; // memory DC the DIB section is selected into
    HBITMAP dib; // top-down 32-bit DIB section (CPU-visible backbuffer)
    HBITMAP stockBmp; // the 1x1 stock bitmap displaced by SelectObject
    uint* pixels; // DIB bits: 0x00RRGGBB, row-major, row 0 = top row
    int width, height; // current client (= DIB) size, physical pixels
    int dpi = 96; // monitor DPI; scale = dpi / 96
    bool autoExit; // WSI_AUTO_EXIT=1: bounded run
    bool wsVisible; // WSI_WS_VISIBLE=1: create with WS_VISIBLE, skip ShowWindow
    bool inCreate; // between the CreateWindowExW step and window_created
    bool firstSizeSeen;
    bool firstPaintDone;
}

__gshared Demo g;

enum UINT_PTR TIMER_ID = 1;
enum HOLD_MS = 200; // post-present hold before the bounded run exits

// Distinct platform object/handle types touched before first pixel (F01
// requirement 4): HINSTANCE, HCURSOR, WNDCLASSEXW, ATOM, HWND, HDC,
// BITMAPINFO, HBITMAP, PAINTSTRUCT, MSG.
enum CONCEPT_COUNT = 10;

// ---------------------------------------------------------------------------
// Backbuffer + gradient (same shape as the scaffold; F01 draws it once).

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
    bmi.bmiHeader.biHeight = -h; // negative height = top-down rows
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits;
    logEvent("step name=CreateDIBSection");
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

void drawGradient() nothrow
{
    if (g.pixels is null)
        return;
    const w = g.width, h = g.height;
    foreach (y; 0 .. h)
    {
        uint* row = g.pixels + cast(size_t) y * w;
        const green = h > 1 ? (y * 255) / (h - 1) : 0;
        foreach (x; 0 .. w)
        {
            const red = w > 1 ? (x * 255) / (w - 1) : 0;
            row[x] = cast(uint)((red << 16) | (green << 8) | 0x40);
        }
    }
}

// ---------------------------------------------------------------------------
// WndProc: every creation/show message is logged with an in_create= marker so
// the WS_VISIBLE-vs-ShowWindow message orders can be compared line by line.

const(char)* whereTag() nothrow @nogc
{
    return g.inCreate ? "in_create=1" : "in_create=0";
}

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_GETMINMAXINFO: // documented as part of the creation set
        logEvent("msg name=WM_GETMINMAXINFO %s", whereTag());
        goto default;

    case WM_NCCREATE:
        logEvent("msg name=WM_NCCREATE %s", whereTag());
        goto default;

    case WM_NCCALCSIZE:
        logEvent("msg name=WM_NCCALCSIZE %s", whereTag());
        goto default;

    case WM_CREATE:
        logEvent("msg name=WM_CREATE %s", whereTag());
        logEvent("step name=CreateCompatibleDC");
        g.memDc = CreateCompatibleDC(null);
        // druntime's core.sys.windows has no GetDpiForWindow (Win10 1607+);
        // the system DPI from the screen DC is enough for the scale= field.
        HDC screen = GetDC(null);
        g.dpi = GetDeviceCaps(screen, LOGPIXELSX);
        ReleaseDC(null, screen);
        return 0;

    case WM_SHOWWINDOW:
        logEvent("msg name=WM_SHOWWINDOW shown=%d %s", cast(int) wParam, whereTag());
        goto default;

    case WM_WINDOWPOSCHANGING:
        logEvent("msg name=WM_WINDOWPOSCHANGING %s", whereTag());
        goto default;

    case WM_WINDOWPOSCHANGED:
        logEvent("msg name=WM_WINDOWPOSCHANGED %s", whereTag());
        goto default; // DefWindowProcW synthesizes WM_SIZE/WM_MOVE from this

    case WM_MOVE:
        logEvent("msg name=WM_MOVE %s", whereTag());
        return 0;

    case WM_ERASEBKGND:
        logEvent("msg name=WM_ERASEBKGND %s", whereTag());
        return 1; // claim erased — WM_PAINT repaints the full client anyway

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        if (!g.firstSizeSeen)
        {
            g.firstSizeSeen = true;
            // F01's spec parenthetical claims this arrives during
            // CreateWindowExW; in_create= records for which mode that holds.
            logEvent("first_configure size=%dx%d %s", w, h, whereTag());
        }
        logEvent("resize size=%dx%d scale=%d.%02d %s",
            w, h, g.dpi / 96, (g.dpi % 96) * 100 / 96, whereTag());
        if (wParam == SIZE_MINIMIZED)
            return 0;
        if (w != g.width || h != g.height)
            createBackbuffer(w, h);
        return 0;

    case WM_PAINT:
        logEvent("msg name=WM_PAINT %s", whereTag());
        PAINTSTRUCT ps;
        logEvent("step name=BeginPaint");
        HDC hdc = BeginPaint(hwnd, &ps);
        if (!g.firstPaintDone)
        {
            drawGradient(); // F01: a single software frame
            logEvent("step name=BitBlt size=%dx%d", g.width, g.height);
            if (g.pixels !is null)
                BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
            g.firstPaintDone = true;
            // F01: "presented" on Win32 = the first BitBlt returned.
            logEvent("first_pixel_presented size=%dx%d", g.width, g.height);
            logEvent("summary concepts=%d loc_file=app.d round_trips_observed=0",
                CONCEPT_COUNT);
            if (g.autoExit)
            {
                logEvent("step name=SetTimer hold_ms=%d", HOLD_MS);
                SetTimer(hwnd, TIMER_ID, HOLD_MS, null);
            }
        }
        else if (g.pixels !is null)
            BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
        EndPaint(hwnd, &ps);
        return 0;

    case WM_TIMER:
        if (wParam != TIMER_ID)
            return 0;
        logEvent("hold_elapsed ms=%d", HOLD_MS);
        DestroyWindow(hwnd);
        return 0;

    case WM_CLOSE:
        logEvent("close_requested");
        goto default; // DefWindowProcW responds with DestroyWindow

    case WM_DESTROY:
        logEvent("msg name=WM_DESTROY");
        KillTimer(hwnd, TIMER_ID);
        createBackbuffer(0, 0); // frees the DIB section
        if (g.memDc !is null)
        {
            DeleteDC(g.memDc);
            g.memDc = null;
        }
        PostQuitMessage(0);
        return 0;

    case WM_NCDESTROY:
        logEvent("msg name=WM_NCDESTROY");
        goto default;

    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

// ---------------------------------------------------------------------------

bool envFlag(const(wchar)* name) nothrow
{
    WCHAR[8] buf;
    const n = GetEnvironmentVariableW(name, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

int main()
{
    instrumentInit("f01_first_pixel_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    g.wsVisible = envFlag("WSI_WS_VISIBLE"w.ptr);
    logEvent("mode auto_exit=%d ws_visible=%d", g.autoExit ? 1 : 0, g.wsVisible ? 1 : 0);

    logEvent("step name=GetModuleHandleW");
    HINSTANCE hInst = GetModuleHandleW(null);

    // First user32 call of the process: under Wine this is where user32
    // connects to the wine server and loads the display driver. The second,
    // identical call right after isolates the steady-state per-call cost from
    // that one-time first-connection cost.
    logEvent("step name=LoadCursorW call=1");
    HCURSOR arrow = LoadCursorW(null, IDC_ARROW);
    logEvent("step name=LoadCursorW call=2");
    arrow = LoadCursorW(null, IDC_ARROW);

    auto clsName = "wsi-f01-class"w;
    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = clsName.ptr;
    wc.hCursor = arrow;
    // No hbrBackground: WM_ERASEBKGND is handled, the DIB covers every pixel.

    logEvent("step name=RegisterClassExW");
    if (!RegisterClassExW(&wc))
    {
        logEvent("error what=RegisterClassExW code=%lu", GetLastError());
        return 1;
    }

    const DWORD style = WS_OVERLAPPEDWINDOW | (g.wsVisible ? WS_VISIBLE : 0);
    logEvent("step name=CreateWindowExW ws_visible=%d", g.wsVisible ? 1 : 0);
    g.inCreate = true;
    HWND hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f01-first-pixel"w.ptr,
        style, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, hInst, null);
    g.inCreate = false;
    if (hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");

    if (g.wsVisible)
        logEvent("step name=ShowWindow skipped=1 reason=ws_visible");
    else
    {
        logEvent("step name=ShowWindow");
        ShowWindow(hwnd, SW_SHOW);
    }
    logEvent("step name=UpdateWindow");
    UpdateWindow(hwnd); // forces the first WM_PAINT synchronously, now

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    logEvent("exit code=%d", cast(int) msg.wParam);
    return cast(int) msg.wParam;
}

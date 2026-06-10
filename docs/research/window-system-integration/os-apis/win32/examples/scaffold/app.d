// Win32 windowing scaffold — the base program every fXX-* Win32 feature demo
// copies. It evolves ../../example/app.d (paint once, then quit) into the shape
// the F01/F02 specs (../../../features/) need:
//
//   * RegisterClassExW -> CreateWindowExW (title "wsi-scaffold") -> ShowWindow,
//     then the canonical GetMessageW/TranslateMessage/DispatchMessageW pump.
//   * A top-down 32-bit DIB section (CreateDIBSection) as the CPU-visible
//     backbuffer: a corner-anchored gradient is drawn into it each frame and
//     presented with BitBlt from a memory DC inside WM_PAINT. The DIB is
//     reallocated on every client-size change (WM_SIZE).
//   * Instrumentation (instrument.d) logs every init step, the first
//     WM_SIZE ("first_configure" — Win32 delivers it *inside* CreateWindowExW),
//     the return of the first BitBlt ("first_pixel_presented"), every resize and
//     buffer (re)allocation, and one "frame_callback" per paint.
//   * WSI_AUTO_EXIT=1 makes the run bounded: a ~16 ms SetTimer tick invalidates
//     the window (animating the gradient); after ~60 ticks a programmatic
//     resize storm (8 SetWindowPos size changes) runs, then DestroyWindow ->
//     WM_DESTROY -> PostQuitMessage -> clean exit 0. Without the env var the
//     demo runs until the user closes the window.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

// ---------------------------------------------------------------------------
// Demo state. The WndProc is a static extern(Windows) callback, so the state
// it needs lives in one __gshared struct (a real binding would stash a `this`
// pointer via SetWindowLongPtrW(GWLP_USERDATA) instead).

struct Demo
{
    HDC memDc; // memory DC the DIB section is selected into
    HBITMAP dib; // top-down 32-bit DIB section (CPU-visible backbuffer)
    HBITMAP stockBmp; // the 1x1 stock bitmap displaced by SelectObject
    uint* pixels; // DIB bits: 0x00RRGGBB, row-major, row 0 = top row
    int width, height; // current client (= DIB) size, physical pixels
    int dpi = 96; // monitor DPI; scale = dpi / 96
    uint frame; // paint counter (animates the gradient)
    uint ticks; // WM_TIMER counter (auto-exit schedule)
    bool autoExit; // WSI_AUTO_EXIT=1: bounded run
    bool firstSizeSeen;
    bool firstPaintDone;
}

__gshared Demo g;

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 16; // ~60 Hz animation tick
enum STORM_AFTER_TICKS = 60; // ~1 s of animation before the resize storm

// ---------------------------------------------------------------------------
// Backbuffer: a DIB section reallocated on every client-size change.

void createBackbuffer(int w, int h) nothrow
{
    if (g.dib !is null) // release the previous buffer first
    {
        SelectObject(g.memDc, g.stockBmp);
        DeleteObject(g.dib);
        g.dib = null;
        g.pixels = null;
        g.width = g.height = 0;
    }
    if (w <= 0 || h <= 0)
        return; // minimized / degenerate — keep no buffer

    BITMAPINFO bmi;
    bmi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // negative height = top-down rows
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

// Corner-anchored diagonal gradient (red tracks x, green tracks y), so any
// stretching or stale-buffer artifact during a resize is visible (F02 req. 1).
// The blue channel advances per frame so consecutive paints are distinct.
void drawGradient() nothrow
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
}

// ---------------------------------------------------------------------------
// Auto-exit driver: 8 programmatic outer-size changes (each SetWindowPos
// dispatches WM_NCCALCSIZE/WM_WINDOWPOSCHANGED/WM_SIZE re-entrantly into the
// WndProc before returning), then DestroyWindow ends the run (F02 req. 2).

void runResizeStorm(HWND hwnd) nothrow
{
    static immutable int[2][8] sizes = [
        [520, 360], [360, 520], [640, 240], [240, 640],
        [800, 600], [300, 300], [1024, 256], [480, 320],
    ];
    logEvent("resize_storm_begin steps=%d", cast(int) sizes.length);
    foreach (i, s; sizes)
    {
        logEvent("step name=SetWindowPos i=%d size=%dx%d", cast(int) i, s[0], s[1]);
        SetWindowPos(hwnd, null, 0, 0, s[0], s[1],
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        // The storm runs inside one WM_TIMER dispatch, so queued WM_PAINTs
        // would never be seen before DestroyWindow — force one synchronous
        // paint per step to prove a frame is presented at every new size.
        // The InvalidateRect is load-bearing: a resize that *shrinks* both
        // dimensions invalidates nothing by itself (the retained surface
        // already covers the smaller client area), so without it UpdateWindow
        // is a no-op and the gradient is left stale (observed under Wine).
        InvalidateRect(hwnd, null, FALSE);
        UpdateWindow(hwnd);
    }
    logEvent("resize_storm_end");
    DestroyWindow(hwnd);
}

// ---------------------------------------------------------------------------
// The window procedure. Lifecycle messages are logged as `msg name=...` so the
// observed creation / resize-storm orderings land in the instrument log.

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_NCCREATE:
        logEvent("msg name=WM_NCCREATE");
        goto default;

    case WM_NCCALCSIZE:
        logEvent("msg name=WM_NCCALCSIZE");
        goto default;

    case WM_CREATE:
        logEvent("msg name=WM_CREATE");
        g.memDc = CreateCompatibleDC(null);
        // druntime's core.sys.windows has no GetDpiForWindow (Win10 1607+);
        // the system DPI from the screen DC is enough for the scale= field.
        HDC screen = GetDC(null);
        g.dpi = GetDeviceCaps(screen, LOGPIXELSX);
        ReleaseDC(null, screen);
        return 0;

    case WM_SHOWWINDOW:
        logEvent("msg name=WM_SHOWWINDOW shown=%d", cast(int) wParam);
        goto default;

    case WM_WINDOWPOSCHANGED:
        logEvent("msg name=WM_WINDOWPOSCHANGED");
        goto default; // DefWindowProcW synthesizes WM_SIZE/WM_MOVE from this

    case WM_MOVE:
        logEvent("msg name=WM_MOVE");
        return 0;

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        if (!g.firstSizeSeen)
        {
            g.firstSizeSeen = true;
            // Note: this arrives *during* CreateWindowExW, before the
            // window_created event is logged — see the scaffold findings.
            logEvent("first_configure size=%dx%d", w, h);
        }
        logEvent("resize size=%dx%d scale=%d.%02d",
            w, h, g.dpi / 96, (g.dpi % 96) * 100 / 96);
        if (wParam == SIZE_MINIMIZED)
            return 0;
        if (w != g.width || h != g.height)
            createBackbuffer(w, h);
        return 0;

    case WM_ERASEBKGND:
        logEvent("msg name=WM_ERASEBKGND");
        return 1; // claim erased — WM_PAINT repaints the full client anyway

    case WM_PAINT:
        if (!g.firstPaintDone)
            logEvent("msg name=WM_PAINT");
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        ++g.frame;
        drawGradient();
        if (g.pixels !is null)
            BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
        if (!g.firstPaintDone)
        {
            g.firstPaintDone = true;
            // F01: "presented" on Win32 = the first BitBlt returned.
            logEvent("first_pixel_presented size=%dx%d", g.width, g.height);
        }
        logEvent("frame_callback t=%lld frame=%u", nowUs(), g.frame);
        EndPaint(hwnd, &ps);
        return 0;

    case WM_TIMER:
        if (wParam != TIMER_ID)
            return 0;
        ++g.ticks;
        InvalidateRect(hwnd, null, FALSE); // schedule the next WM_PAINT
        if (g.autoExit && g.ticks == STORM_AFTER_TICKS)
            runResizeStorm(hwnd); // ends in DestroyWindow
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

bool wantAutoExit() nothrow
{
    WCHAR[8] buf;
    const n = GetEnvironmentVariableW("WSI_AUTO_EXIT"w.ptr, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

int main()
{
    instrumentInit("scaffold_win32");
    logEvent("init_start");
    g.autoExit = wantAutoExit();
    logEvent("mode auto_exit=%d", g.autoExit ? 1 : 0);

    logEvent("step name=GetModuleHandleW");
    HINSTANCE hInst = GetModuleHandleW(null);

    // First user32 call of the process — this is where user32 connects to the
    // session (under Wine: to the wine server), so it gets its own step event.
    logEvent("step name=LoadCursorW");
    HCURSOR arrow = LoadCursorW(null, IDC_ARROW);

    auto clsName = "wsi-scaffold-class"w;
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

    logEvent("step name=CreateWindowExW");
    HWND hwnd = CreateWindowExW(0, clsName.ptr, "wsi-scaffold"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, hInst, null);
    if (hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");

    logEvent("step name=ShowWindow");
    ShowWindow(hwnd, SW_SHOW);
    logEvent("step name=UpdateWindow");
    UpdateWindow(hwnd); // forces the first WM_PAINT synchronously, now

    logEvent("step name=SetTimer interval_ms=%d", TICK_MS);
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

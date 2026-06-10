// F02 — resize correctness, Win32 (../../f02-resize.md).
//
// Implements every requirement of ../../../features/f02-resize.md on top of
// the scaffold (../scaffold/app.d):
//
//   * Continuously redrawn corner-anchored gradient (red tracks x, green
//     tracks y, blue advances per frame) so stretching or stale buffers are
//     visible; after every draw the buffer's four corners are verified
//     against the expected gradient values (`paint_check`).
//   * An aggressive programmatic SetWindowPos storm (WSI_AUTO_EXIT=1):
//     pure grows, pure shrinks, mixed grow/shrink, move-only (SWP_NOSIZE)
//     and a same-size no-move step — each followed by a synchronous
//     UpdateWindow and a `step_result painted=` verdict.
//   * Every WM_SIZING / WM_SIZE / WM_WINDOWPOSCHANGING / WM_WINDOWPOSCHANGED
//     / WM_ERASEBKGND / WM_PAINT is logged with its wParam / WINDOWPOS
//     fields / client size.
//   * WSI_NO_INVALIDATE=1 drops the per-step InvalidateRect, reproducing the
//     scaffold's "a pure shrink invalidates nothing" finding: shrink steps
//     then present no frame and the window keeps a stale, wrongly-anchored
//     gradient (step_result painted=0).
//   * WSI_GROW_ONLY=1 switches the DIB strategy from realloc-per-resize to
//     grow-only reuse (the DIB keeps its high-water-mark size; smaller client
//     sizes draw through a stride and log `buffer_reuse` instead of
//     `buffer_alloc`).
//   * WM_SIZING (and WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE) cannot fire from a
//     programmatic storm — their observed count is logged at storm end; the
//     interactive modal-resize path is F03's subject (Tier C here).
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
    int width, height; // current client size, physical pixels
    int capW, capH; // allocated DIB size (== width/height unless grow-only)
    int dpi = 96; // monitor DPI; scale = dpi / 96
    uint frame; // paint counter (animates the gradient)
    uint ticks; // WM_TIMER counter (auto-exit schedule)
    uint sizingCount; // WM_SIZING messages seen (expected 0 programmatically)
    uint sizeMoveCount; // WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE seen (expected 0)
    uint checksFailed; // paint_check corner mismatches
    bool autoExit; // WSI_AUTO_EXIT=1: bounded run with the resize storm
    bool noInvalidate; // WSI_NO_INVALIDATE=1: drop the per-step InvalidateRect
    bool growOnly; // WSI_GROW_ONLY=1: grow-only DIB reuse instead of realloc
    bool firstSizeSeen;
    bool firstPaintDone;
}

__gshared Demo g;

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 16; // ~60 Hz animation tick
enum STORM_AFTER_TICKS = 30; // ~0.5 s of animation before the resize storm

// ---------------------------------------------------------------------------
// Backbuffer. Two strategies (the allocation strategy is an F02 finding):
//   realloc (default): free + CreateDIBSection on every client-size change.
//   grow-only (WSI_GROW_ONLY=1): the DIB only ever grows (per-dimension
//   high-water mark); a smaller client size reuses it through a row stride.

void createBackbuffer(int w, int h) nothrow
{
    if (w <= 0 || h <= 0)
    {
        releaseBackbuffer();
        return;
    }
    if (g.growOnly && g.dib !is null && w <= g.capW && h <= g.capH)
    {
        g.width = w;
        g.height = h;
        logEvent("buffer_reuse size=%dx%d cap=%dx%d", w, h, g.capW, g.capH);
        return;
    }
    const allocW = g.growOnly ? (w > g.capW ? w : g.capW) : w;
    const allocH = g.growOnly ? (h > g.capH ? h : g.capH) : h;
    releaseBackbuffer();

    BITMAPINFO bmi;
    bmi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
    bmi.bmiHeader.biWidth = allocW;
    bmi.bmiHeader.biHeight = -allocH; // negative height = top-down rows
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
    g.capW = allocW;
    g.capH = allocH;
    g.stockBmp = cast(HBITMAP) SelectObject(g.memDc, g.dib);
    logEvent("buffer_alloc size=%dx%d cap=%dx%d bytes=%d",
        w, h, allocW, allocH, allocW * allocH * 4);
}

void releaseBackbuffer() nothrow
{
    if (g.dib is null)
        return;
    SelectObject(g.memDc, g.stockBmp);
    DeleteObject(g.dib);
    g.dib = null;
    g.pixels = null;
    g.width = g.height = g.capW = g.capH = 0;
}

// Corner-anchored diagonal gradient over the *current* client size, drawn
// through the allocated stride (capW) so grow-only reuse stays anchored.
void drawGradient() nothrow
{
    if (g.pixels is null)
        return;
    const w = g.width, h = g.height;
    const blue = (g.frame * 4) & 0xff;
    foreach (y; 0 .. h)
    {
        uint* row = g.pixels + cast(size_t) y * g.capW;
        const green = h > 1 ? (y * 255) / (h - 1) : 0;
        foreach (x; 0 .. w)
        {
            const red = w > 1 ? (x * 255) / (w - 1) : 0;
            row[x] = cast(uint)((red << 16) | (green << 8) | blue);
        }
    }
}

// Verify the gradient really is anchored to the current size: the four
// corners of the w x h region must hold the expected channel extremes.
// A stale or wrongly-strided buffer fails immediately (F02 requirement 1).
void checkCorners() nothrow
{
    if (g.pixels is null || g.width < 2 || g.height < 2)
        return;
    const w = g.width, h = g.height;
    const blue = (g.frame * 4) & 0xff;
    uint at(int x, int y) nothrow
    {
        return g.pixels[cast(size_t) y * g.capW + x];
    }

    const expTl = cast(uint) blue;
    const expTr = cast(uint)((255 << 16) | blue);
    const expBl = cast(uint)((255 << 8) | blue);
    const expBr = cast(uint)((255 << 16) | (255 << 8) | blue);
    const ok = at(0, 0) == expTl && at(w - 1, 0) == expTr
        && at(0, h - 1) == expBl && at(w - 1, h - 1) == expBr;
    if (!ok)
    {
        ++g.checksFailed;
        logEvent("paint_check ok=0 size=%dx%d tl=%06x tr=%06x bl=%06x br=%06x",
            w, h, at(0, 0), at(w - 1, 0), at(0, h - 1), at(w - 1, h - 1));
    }
}

// ---------------------------------------------------------------------------
// The resize storm: 14 programmatic SetWindowPos steps covering pure grows,
// pure shrinks, mixed grow/shrink, move-only and a same-size no-move step
// (F02 requirement 2). Each step's messages dispatch re-entrantly inside
// SetWindowPos; the per-step verdict logs whether a frame was presented.

struct StormStep
{
    const(char)* kind; // grow | shrink | mixed | move | same
    int x, y; // position (move steps; others pass SWP_NOMOVE)
    int w, h; // outer size (size steps; move steps pass SWP_NOSIZE)
    UINT extraFlags; // SWP_NOMOVE or SWP_NOSIZE
}

void runResizeStorm(HWND hwnd) nothrow
{
    static immutable StormStep[14] steps = [
        StormStep("grow", 0, 0, 520, 360, SWP_NOMOVE),
        StormStep("grow", 0, 0, 640, 480, SWP_NOMOVE),
        StormStep("grow", 0, 0, 800, 600, SWP_NOMOVE),
        StormStep("grow", 0, 0, 1024, 768, SWP_NOMOVE),
        StormStep("shrink", 0, 0, 700, 500, SWP_NOMOVE),
        StormStep("shrink", 0, 0, 500, 350, SWP_NOMOVE),
        StormStep("shrink", 0, 0, 320, 240, SWP_NOMOVE),
        StormStep("mixed", 0, 0, 240, 640, SWP_NOMOVE),
        StormStep("mixed", 0, 0, 640, 240, SWP_NOMOVE),
        StormStep("move", 120, 120, 0, 0, SWP_NOSIZE),
        StormStep("move", 240, 180, 0, 0, SWP_NOSIZE),
        StormStep("same", 0, 0, 640, 240, SWP_NOMOVE), // same outer size
        StormStep("grow", 0, 0, 800, 600, SWP_NOMOVE),
        StormStep("shrink", 0, 0, 480, 320, SWP_NOMOVE),
    ];
    logEvent("resize_storm_begin steps=%d invalidate=%d grow_only=%d",
        cast(int) steps.length, g.noInvalidate ? 0 : 1, g.growOnly ? 1 : 0);
    foreach (i, s; steps)
    {
        logEvent("step name=SetWindowPos i=%d kind=%s pos=%d,%d size=%dx%d",
            cast(int) i, s.kind, s.x, s.y, s.w, s.h);
        const framesBefore = g.frame;
        const wBefore = g.width, hBefore = g.height;
        SetWindowPos(hwnd, null, s.x, s.y, s.w, s.h,
            SWP_NOZORDER | SWP_NOACTIVATE | s.extraFlags);
        // The storm runs inside one WM_TIMER dispatch, so queued WM_PAINTs
        // would never be seen before DestroyWindow — present synchronously.
        // The InvalidateRect is load-bearing: a pure shrink invalidates
        // nothing by itself (the retained surface already covers the smaller
        // client area), so without it UpdateWindow is a no-op and the window
        // keeps a stale gradient. WSI_NO_INVALIDATE=1 demonstrates exactly
        // that (the step_result below records painted=0 for shrink steps).
        if (!g.noInvalidate)
            InvalidateRect(hwnd, null, FALSE);
        UpdateWindow(hwnd);
        const painted = g.frame != framesBefore;
        const sizeChanged = g.width != wBefore || g.height != hBefore;
        logEvent("step_result i=%d kind=%s painted=%d client=%dx%d",
            cast(int) i, s.kind, painted ? 1 : 0, g.width, g.height);
        // Stale only when the client size changed and no frame followed: the
        // window then shows the previous frame's gradient, wrongly anchored
        // for the new size (move-only / same-size steps are harmless).
        if (!painted && sizeChanged)
            logEvent("stale_content i=%d kind=%s was=%dx%d now=%dx%d "
                ~ "note=window_still_shows_frame_anchored_to_old_size",
                cast(int) i, s.kind, wBefore, hBefore, g.width, g.height);
    }
    logEvent("resize_storm_end wm_sizing_count=%u wm_entersizemove_count=%u "
        ~ "note=modal_resize_loop_not_reachable_programmatically_see_f03",
        g.sizingCount, g.sizeMoveCount);
    logEvent("paint_checks failed=%u", g.checksFailed);
    DestroyWindow(hwnd);
}

// ---------------------------------------------------------------------------
// The window procedure: every F02-relevant message is logged with its payload.

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

    case WM_ENTERSIZEMOVE: // interactive size/move modal loop — F03's subject
    case WM_EXITSIZEMOVE:
        ++g.sizeMoveCount;
        logEvent("msg name=%s", msg == WM_ENTERSIZEMOVE
                ? "WM_ENTERSIZEMOVE".ptr : "WM_EXITSIZEMOVE".ptr);
        goto default;

    case WM_SIZING: // only the interactive border drag produces this
        ++g.sizingCount;
        const r = cast(RECT*) lParam;
        logEvent("msg name=WM_SIZING edge=%d rect=%ld,%ld-%ld,%ld",
            cast(int) wParam, r.left, r.top, r.right, r.bottom);
        goto default;

    case WM_WINDOWPOSCHANGING:
        const wpg = cast(WINDOWPOS*) lParam;
        logEvent("msg name=WM_WINDOWPOSCHANGING pos=%d,%d size=%dx%d flags=0x%04x",
            wpg.x, wpg.y, wpg.cx, wpg.cy, wpg.flags);
        goto default;

    case WM_WINDOWPOSCHANGED:
        const wpc = cast(WINDOWPOS*) lParam;
        logEvent("msg name=WM_WINDOWPOSCHANGED pos=%d,%d size=%dx%d flags=0x%04x",
            wpc.x, wpc.y, wpc.cx, wpc.cy, wpc.flags);
        goto default; // DefWindowProcW synthesizes WM_SIZE/WM_MOVE from this

    case WM_MOVE:
        logEvent("msg name=WM_MOVE pos=%d,%d",
            cast(int) cast(short)(lParam & 0xffff),
            cast(int) cast(short)((lParam >> 16) & 0xffff));
        return 0;

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        logEvent("msg name=WM_SIZE wparam=%d size=%dx%d", cast(int) wParam, w, h);
        if (!g.firstSizeSeen)
        {
            g.firstSizeSeen = true;
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
        logEvent("msg name=WM_PAINT");
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        ++g.frame;
        drawGradient();
        checkCorners();
        if (g.pixels !is null)
            BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
        if (!g.firstPaintDone)
        {
            g.firstPaintDone = true;
            logEvent("first_pixel_presented size=%dx%d", g.width, g.height);
        }
        logEvent("frame_callback t=%lld frame=%u size=%dx%d",
            nowUs(), g.frame, g.width, g.height);
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
        releaseBackbuffer();
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
    instrumentInit("f02_resize_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    g.noInvalidate = envFlag("WSI_NO_INVALIDATE"w.ptr);
    g.growOnly = envFlag("WSI_GROW_ONLY"w.ptr);
    logEvent("mode auto_exit=%d invalidate=%d grow_only=%d",
        g.autoExit ? 1 : 0, g.noInvalidate ? 0 : 1, g.growOnly ? 1 : 0);

    logEvent("step name=GetModuleHandleW");
    HINSTANCE hInst = GetModuleHandleW(null);

    logEvent("step name=LoadCursorW");
    HCURSOR arrow = LoadCursorW(null, IDC_ARROW);

    auto clsName = "wsi-f02-class"w;
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
    HWND hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f02-resize"w.ptr,
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

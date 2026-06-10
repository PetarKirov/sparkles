// F08 — DPI / runtime rescale, Win32 implementation
// (../../../features/f08-dpi-scaling.md). Extends the scaffold
// (../scaffold/app.d) into a Per-Monitor-v2 DPI observatory:
//
//   * SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
//     before any HWND exists (druntime's core.sys.windows predates the
//     Win10-1607 DPI API surface, so the contexts and the user32 entry points
//     are declared below and resolved with GetProcAddress — which also logs
//     which of them the host provides).
//   * Logs every DPI source: GetThreadDpiAwarenessContext,
//     GetWindowDpiAwarenessContext, GetDpiForWindow, GetDpiForSystem,
//     GetSystemDpiForProcess, plus the GetDeviceCaps(LOGPIXELSX) legacy value.
//   * Immutability proofs: a second SetProcessDpiAwarenessContext call (the
//     process awareness is write-once), and a WSI_LATE_AWARENESS=1 mode that
//     creates the window FIRST and only then calls the API — capturing the
//     documented ERROR_ACCESS_DENIED ordering rule. The late mode then probes
//     SetThreadDpiAwarenessContext sub-process granularity: the existing
//     window keeps its creation-time awareness, a second window created on
//     the PMv2 thread gets the new one.
//   * WM_DPICHANGED: logs old/new DPI and the suggested rect, honors it with
//     SetWindowPos, reallocates the DIB backbuffer on the resulting WM_SIZE,
//     and logs logical (96-DPI units) vs physical client size on every
//     resize. The frame renders 1-physical-px hairlines (border + center
//     crosshair) over the scaffold gradient so scaling artifacts are visible.
//
// WSI_AUTO_EXIT=1 bounds the run (default ~1.2 s; WSI_RUN_MS overrides — the
// findings doc uses a longer run while changing the compositor output scale
// under winewayland to hunt a live WM_DPICHANGED). Exit 0 in all modes.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

// ---------------------------------------------------------------------------
// The Win10 DPI-awareness surface (winuser.h, 1607+/1803+) — absent from
// druntime's core.sys.windows. DPI_AWARENESS_CONTEXT values are pseudo
// handles; the functions are user32 exports resolved at runtime so a missing
// export is a logged finding, not a loader failure.

alias DPI_AWARENESS_CONTEXT = HANDLE;

DPI_AWARENESS_CONTEXT dpiCtx(int n) nothrow @nogc
{
    return cast(DPI_AWARENESS_CONTEXT) cast(ptrdiff_t) n;
}

enum CTX_UNAWARE = -1;
enum CTX_SYSTEM_AWARE = -2;
enum CTX_PER_MONITOR_AWARE = -3;
enum CTX_PER_MONITOR_AWARE_V2 = -4;
enum CTX_UNAWARE_GDISCALED = -5;

enum WM_DPICHANGED = 0x02E0;
enum WM_GETDPISCALEDSIZE = 0x02E4;

struct Api
{
extern (Windows) nothrow @nogc:
    BOOL function(DPI_AWARENESS_CONTEXT) SetProcessDpiAwarenessContext;
    DPI_AWARENESS_CONTEXT function() GetThreadDpiAwarenessContext;
    DPI_AWARENESS_CONTEXT function(DPI_AWARENESS_CONTEXT) SetThreadDpiAwarenessContext;
    DPI_AWARENESS_CONTEXT function(HWND) GetWindowDpiAwarenessContext;
    BOOL function(DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT) AreDpiAwarenessContextsEqual;
    UINT function(HWND) GetDpiForWindow;
    UINT function() GetDpiForSystem;
    UINT function(HANDLE) GetSystemDpiForProcess;
}

__gshared Api api;

void loadDpiApi() nothrow
{
    HMODULE u32 = GetModuleHandleW("user32"w.ptr);
    static foreach (name; __traits(allMembers, Api))
    {
        __traits(getMember, api, name) = cast(typeof(__traits(getMember, api, name)))
            GetProcAddress(u32, name.ptr);
        logEvent("api name=%s present=%d", name.ptr,
            __traits(getMember, api, name) !is null ? 1 : 0);
    }
}

// Render an awareness context as a stable name for the log (the raw value is
// an opaque handle; equality must go through AreDpiAwarenessContextsEqual).
const(char)* ctxName(DPI_AWARENESS_CONTEXT ctx) nothrow
{
    if (api.AreDpiAwarenessContextsEqual is null)
        return "unknown";
    if (api.AreDpiAwarenessContextsEqual(ctx, dpiCtx(CTX_PER_MONITOR_AWARE_V2)))
        return "per_monitor_aware_v2";
    if (api.AreDpiAwarenessContextsEqual(ctx, dpiCtx(CTX_PER_MONITOR_AWARE)))
        return "per_monitor_aware";
    if (api.AreDpiAwarenessContextsEqual(ctx, dpiCtx(CTX_SYSTEM_AWARE)))
        return "system_aware";
    if (api.AreDpiAwarenessContextsEqual(ctx, dpiCtx(CTX_UNAWARE_GDISCALED)))
        return "unaware_gdiscaled";
    if (api.AreDpiAwarenessContextsEqual(ctx, dpiCtx(CTX_UNAWARE)))
        return "unaware";
    return "unrecognized";
}

// One line with every DPI source the platform exposes, tagged by call site.
void logDpiSources(const(char)* when, HWND hwnd) nothrow
{
    const winDpi = hwnd && api.GetDpiForWindow ? api.GetDpiForWindow(hwnd) : 0;
    const sysDpi = api.GetDpiForSystem ? api.GetDpiForSystem() : 0;
    const procDpi = api.GetSystemDpiForProcess
        ? api.GetSystemDpiForProcess(GetCurrentProcess()) : 0;
    HDC screen = GetDC(null);
    const caps = GetDeviceCaps(screen, LOGPIXELSX);
    ReleaseDC(null, screen);
    logEvent("dpi_sources when=%s window=%u system=%u process=%u devcaps=%d thread_ctx=%s",
        when, winDpi, sysDpi, procDpi, caps,
        api.GetThreadDpiAwarenessContext
        ? ctxName(api.GetThreadDpiAwarenessContext()) : "unknown".ptr);
}

// ---------------------------------------------------------------------------
// Demo state: scaffold DIB backbuffer + DPI bookkeeping.

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 16;

struct Demo
{
    HWND hwndMain; // the second (granularity-probe) window must not quit us
    HDC memDc;
    HBITMAP dib, stockBmp;
    uint* pixels;
    int width, height; // physical client pixels (= DIB size)
    uint dpi = 96; // current per-window DPI; scale = dpi / 96
    uint frame, ticks;
    uint runMs = 1200; // auto-exit deadline (WSI_RUN_MS overrides)
    uint nDpiChanged;
    bool autoExit, late;
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
    bmi.bmiHeader.biHeight = -h; // top-down
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

// Scaffold gradient + 1-physical-px hairlines: a white border rectangle and a
// center crosshair. At the correct buffer size they are razor-sharp; any
// bitmap-stretch (the DPI-virtualization failure mode) blurs them visibly.
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
    foreach (x; 0 .. w) // 1-px horizontal hairlines: border + center
    {
        g.pixels[x] = 0xffffff;
        g.pixels[cast(size_t)(h - 1) * w + x] = 0xffffff;
        g.pixels[cast(size_t)(h / 2) * w + x] = 0xffffff;
    }
    foreach (y; 0 .. h) // and vertical
    {
        g.pixels[cast(size_t) y * w] = 0xffffff;
        g.pixels[cast(size_t) y * w + (w - 1)] = 0xffffff;
        g.pixels[cast(size_t) y * w + (w / 2)] = 0xffffff;
    }
}

// ---------------------------------------------------------------------------

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_CREATE:
        if (g.memDc is null) // the probe window shares nothing
            g.memDc = CreateCompatibleDC(null);
        return 0;

    case WM_DPICHANGED:
        // wParam: new X DPI (low word) / Y DPI (high word); lParam: the
        // OS-suggested window rect at the new scale. Honoring it verbatim is
        // the documented contract — it keeps the window under the cursor and
        // at an equivalent logical size on the new monitor.
        ++g.nDpiChanged;
        const newDpi = cast(uint)(wParam & 0xffff);
        const RECT* r = cast(RECT*) lParam;
        logEvent("dpi_changed old=%u new=%u suggested=%dx%d+%d+%d",
            g.dpi, newDpi, r.right - r.left, r.bottom - r.top, r.left, r.top);
        g.dpi = newDpi;
        SetWindowPos(hwnd, null, r.left, r.top,
            r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
        InvalidateRect(hwnd, null, FALSE);
        return 0;

    case WM_GETDPISCALEDSIZE: // PMv2-only negotiation hook before DPICHANGED
        logEvent("msg name=WM_GETDPISCALEDSIZE dpi=%u", cast(uint) wParam);
        goto default; // FALSE from DefWindowProc = default linear scaling

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        // Under per-monitor awareness the client rect IS physical pixels;
        // the logical (DIP) size is derived: logical = physical * 96 / dpi.
        logEvent("resize size=%dx%d scale=%u.%02u logical=%dx%d",
            w, h, g.dpi / 96, (g.dpi % 96) * 100 / 96,
            w * 96 / g.dpi, h * 96 / g.dpi);
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
            logEvent("first_pixel_presented size=%dx%d dpi=%u", g.width, g.height, g.dpi);
        }
        EndPaint(hwnd, &ps);
        return 0;

    case WM_TIMER:
        if (wParam != TIMER_ID)
            return 0;
        ++g.ticks;
        InvalidateRect(hwnd, null, FALSE);
        if (g.autoExit && g.ticks * TICK_MS >= g.runMs)
            DestroyWindow(hwnd);
        return 0;

    case WM_CLOSE:
        logEvent("close_requested");
        goto default;

    case WM_DESTROY:
        if (g.hwndMain !is null && hwnd !is g.hwndMain)
            return 0; // the probe window: no teardown, no quit
        KillTimer(hwnd, TIMER_ID);
        createBackbuffer(0, 0);
        if (g.memDc !is null)
        {
            DeleteDC(g.memDc);
            g.memDc = null;
        }
        logEvent("summary dpichanged=%u final_dpi=%u", g.nDpiChanged, g.dpi);
        PostQuitMessage(0);
        return 0;

    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

// ---------------------------------------------------------------------------

bool envFlag(const(wchar)* name) nothrow
{
    WCHAR[16] buf;
    const n = GetEnvironmentVariableW(name, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

uint envUint(const(wchar)* name, uint def) nothrow
{
    WCHAR[16] buf;
    const n = GetEnvironmentVariableW(name, buf.ptr, buf.length);
    if (n < 1 || n >= buf.length)
        return def;
    uint v;
    foreach (i; 0 .. n)
    {
        if (buf[i] < '0' || buf[i] > '9')
            return def;
        v = v * 10 + (buf[i] - '0');
    }
    return v;
}

void setAwareness(const(char)* when, int ctx) nothrow
{
    if (api.SetProcessDpiAwarenessContext is null)
    {
        logEvent("awareness_set when=%s skipped=api_missing", when);
        return;
    }
    SetLastError(0);
    const ok = api.SetProcessDpiAwarenessContext(dpiCtx(ctx));
    logEvent("awareness_set when=%s ctx=%s ok=%d err=%lu",
        when, ctxName(dpiCtx(ctx)), ok ? 1 : 0, ok ? 0 : GetLastError());
}

HWND createDemoWindow(HINSTANCE hInst, const(wchar)* cls, const(wchar)* title) nothrow
{
    return CreateWindowExW(0, cls, title, WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 480, 320, null, null, hInst, null);
}

int main()
{
    instrumentInit("f08_dpi_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    g.late = envFlag("WSI_LATE_AWARENESS"w.ptr);
    g.runMs = envUint("WSI_RUN_MS"w.ptr, 1200);
    logEvent("mode auto_exit=%d late_awareness=%d run_ms=%u",
        g.autoExit ? 1 : 0, g.late ? 1 : 0, g.runMs);

    loadDpiApi();
    logDpiSources("before_awareness", null);

    if (!g.late)
    {
        // The production ordering: declare PMv2 before ANY window exists.
        setAwareness("before_window", CTX_PER_MONITOR_AWARE_V2);
        // Write-once proof: a second call must fail (ERROR_ACCESS_DENIED).
        setAwareness("second_call", CTX_SYSTEM_AWARE);
        logDpiSources("after_awareness", null);
    }

    HINSTANCE hInst = GetModuleHandleW(null);
    auto clsName = "wsi-f08-class"w;
    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = clsName.ptr;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    if (!RegisterClassExW(&wc))
    {
        logEvent("error what=RegisterClassExW code=%lu", GetLastError());
        return 1;
    }
    HWND hwnd = createDemoWindow(hInst, clsName.ptr, "wsi-f08-dpi-scaling"w.ptr);
    if (hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");
    g.hwndMain = hwnd;
    if (api.GetDpiForWindow !is null)
        g.dpi = api.GetDpiForWindow(hwnd);
    if (api.GetWindowDpiAwarenessContext !is null)
        logEvent("window_ctx hwnd=main ctx=%s",
            ctxName(api.GetWindowDpiAwarenessContext(hwnd)));
    logDpiSources("after_window", hwnd);

    if (g.late)
    {
        // The ordering rule: setting process awareness AFTER a window exists
        // is documented to fail (the default awareness is locked in by then).
        setAwareness("after_window", CTX_PER_MONITOR_AWARE_V2);
        logDpiSources("after_late_set", hwnd);

        // Sub-process granularity: thread-scoped awareness still works…
        if (api.SetThreadDpiAwarenessContext !is null)
        {
            auto prev = api.SetThreadDpiAwarenessContext(dpiCtx(CTX_PER_MONITOR_AWARE_V2));
            logEvent("thread_awareness_set ctx=per_monitor_aware_v2 prev=%s ok=%d",
                ctxName(prev), prev !is null ? 1 : 0);
            // …the existing window keeps its creation-time awareness, while a
            // window created NOW inherits the thread's new context.
            if (api.GetWindowDpiAwarenessContext !is null)
                logEvent("window_ctx hwnd=main ctx=%s note=unchanged_after_thread_set",
                    ctxName(api.GetWindowDpiAwarenessContext(hwnd)));
            HWND hwnd2 = createDemoWindow(hInst, clsName.ptr, "wsi-f08-second"w.ptr);
            if (hwnd2 !is null && api.GetWindowDpiAwarenessContext !is null)
            {
                logEvent("window_ctx hwnd=second ctx=%s dpi=%u",
                    ctxName(api.GetWindowDpiAwarenessContext(hwnd2)),
                    api.GetDpiForWindow ? api.GetDpiForWindow(hwnd2) : 0);
                DestroyWindow(hwnd2);
            }
            api.SetThreadDpiAwarenessContext(prev);
        }
    }

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

// F04 — vsync / frame pacing, Win32 (../../f04-frame-pacing.md).
//
// Implements the Win32 half of ../../../features/f04-frame-pacing.md on top
// of the scaffold (../scaffold/app.d): drive a trivially cheap redraw (solid
// color flip) from the platform frame clock — no sleep, no busy loop — and
// measure how steady it actually is.
//
//   * Primary pacing source: DwmFlush() from dwmapi.dll, which blocks until
//     the next DWM composition pass (≈ the next vblank when composition is
//     active). DwmIsCompositionEnabled() is checked first, then a 10-call
//     probe measures whether DwmFlush actually *blocks* — a broken/stubbed
//     DwmFlush that returns immediately (or errors) would otherwise turn the
//     pacing loop into a busy spin. Whatever the probe finds is the finding.
//   * Documented fallback chain: DwmFlush -> SetTimer at 16 ms. The chosen
//     path is logged (`pacing_path path=dwm|timer reason=...`) and stamped on
//     every frame. WSI_FORCE_TIMER=1 / WSI_FORCE_DWM=1 override the choice so
//     both paths stay reachable on any host.
//   * 600 frames of `frame_callback t=...` are collected; at exit the
//     inter-frame deltas' min/p50/p99/max and a coarse jitter histogram are
//     printed to *stdout* (the instrumentation stream stays on stderr).
//   * Occlusion probe (WSI_AUTO_EXIT=1): at frame 300 the window is minimized
//     (ShowWindow(SW_MINIMIZE), `vis_change state=minimized`) and restored
//     ~3 s later — does the pacing source keep ticking while the window is
//     hidden? The frame log answers directly.
//   * A stall watchdog thread aborts (exit 2) if no frame lands for 10 s, so
//     the bounded mode can never hang CI even if a pacing source wedges.
//
// The DXGI waitable-swapchain path (the real-Windows gold path) is
// documented in ../../f04-frame-pacing.md but deliberately out of scope here:
// it needs COM + D3D11/DXGI interface bring-up that core.sys.windows does not
// carry. Only druntime's built-in bindings are used — plus two hand-declared
// dwmapi entry points (druntime ships no dwmapi module).
module app;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdio : fflush, printf, stdout;
import core.stdc.stdlib : qsort;
import core.sys.windows.windows;
import instrument;

// druntime has no core.sys.windows.dwmapi — declare the two entry points.
// pragma(lib) emits /DEFAULTLIB:dwmapi, resolved against the SDK import libs.
pragma(lib, "dwmapi");
extern (Windows) nothrow @nogc
{
    HRESULT DwmIsCompositionEnabled(BOOL* pfEnabled);
    HRESULT DwmFlush();
}

enum FRAMES_TOTAL = 600; // F04 requirement 2
enum TIMER_MS = 16; // the documented fallback cadence
enum UINT_PTR FRAME_TIMER_ID = 1;
enum MINIMIZE_AT_FRAME = 300; // occlusion probe (requirement 3)
enum MINIMIZED_HOLD_US = 3_000_000;

struct Demo
{
    HDC memDc;
    HBITMAP dib;
    HBITMAP stockBmp;
    uint* pixels;
    int width, height;
    uint frame; // frame_callback counter
    const(char)* path = "unset"; // dwm | timer
    long[FRAMES_TOTAL] frameTimes; // µs timestamps, [0 .. frame)
    bool autoExit;
    bool forceTimer, forceDwm;
    bool minimized;
    long minimizedAtUs;
    bool occlusionDone;
    bool statsDone;
}

__gshared Demo g;
__gshared HWND g_hwnd;
shared long s_lastFrameUs; // stall watchdog heartbeat
shared bool s_done;

// ---------------------------------------------------------------------------
// Backbuffer (scaffold strategy: realloc on client-size change).

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

// ---------------------------------------------------------------------------
// One paced frame: flip between two solid colors (trivially cheap), log the
// callback, drive the occlusion probe, present synchronously.

void onFrame() nothrow
{
    const t = nowUs();
    if (g.frame < FRAMES_TOTAL)
        g.frameTimes[g.frame] = t;
    ++g.frame;
    atomicStore(s_lastFrameUs, t);
    logEvent("frame_callback t=%lld frame=%u path=%s", t, g.frame, g.path);

    if (g.pixels !is null)
    {
        const color = (g.frame & 1) ? 0x2060c0 : 0xc06020; // the solid flip
        const n = cast(size_t) g.width * g.height;
        foreach (i; 0 .. n)
            g.pixels[i] = color;
    }
    InvalidateRect(g_hwnd, null, FALSE);
    UpdateWindow(g_hwnd);

    // Occlusion probe: minimize mid-run, restore after ~3 s. Both transitions
    // happen from inside the pacing callback — if the pacing source stops
    // while minimized, the restore never runs and the stall watchdog reports.
    if (g.autoExit && !g.occlusionDone)
    {
        if (!g.minimized && g.frame == MINIMIZE_AT_FRAME)
        {
            g.minimized = true;
            g.minimizedAtUs = t;
            logEvent("vis_change state=minimized t=%lld frame=%u", t, g.frame);
            ShowWindow(g_hwnd, SW_MINIMIZE);
        }
        else if (g.minimized && t - g.minimizedAtUs > MINIMIZED_HOLD_US)
        {
            g.minimized = false;
            g.occlusionDone = true;
            logEvent("vis_change state=restored t=%lld frame=%u", t, g.frame);
            ShowWindow(g_hwnd, SW_RESTORE);
        }
    }
}

// ---------------------------------------------------------------------------
// Stats: min/p50/p99/max inter-frame delta + coarse jitter histogram, printed
// to stdout at exit (F04 requirement 2).

extern (C) int cmpLong(const(void)* a, const(void)* b) nothrow @nogc
{
    const x = *cast(const(long)*) a, y = *cast(const(long)*) b;
    return (x > y) - (x < y);
}

void printStats() nothrow
{
    if (g.statsDone)
        return;
    g.statsDone = true;

    const n = (g.frame < FRAMES_TOTAL ? g.frame : FRAMES_TOTAL);
    if (n < 2)
    {
        printf("stats path=%s frames=%u deltas=0\n", g.path, g.frame);
        fflush(stdout);
        return;
    }
    static long[FRAMES_TOTAL - 1] deltas;
    const nd = n - 1;
    foreach (i; 0 .. nd)
        deltas[i] = g.frameTimes[i + 1] - g.frameTimes[i];

    // Histogram over the raw (unsorted) deltas.
    static immutable long[7] edges = [2_000, 8_000, 12_000, 17_000, 20_000,
        34_000, 100_000];
    static immutable string[8] labels = [
        "<2ms", "2-8ms", "8-12ms", "12-17ms", "17-20ms", "20-34ms",
        "34-100ms", ">=100ms",
    ];
    uint[8] buckets;
    foreach (i; 0 .. nd)
    {
        size_t b = edges.length; // last bucket unless an edge catches it
        foreach (j, e; edges)
            if (deltas[i] < e)
            {
                b = j;
                break;
            }
        ++buckets[b];
    }

    qsort(deltas.ptr, nd, long.sizeof, &cmpLong);
    const long mn = deltas[0];
    const long p50 = deltas[nd / 2];
    const long p99 = deltas[(nd * 99) / 100];
    const long mx = deltas[nd - 1];

    printf("stats path=%s frames=%u deltas=%u min_us=%lld p50_us=%lld "
            ~ "p99_us=%lld max_us=%lld\n",
        g.path, g.frame, cast(uint) nd, mn, p50, p99, mx);
    foreach (j, label; labels)
        printf("histogram bucket=%.*s count=%u\n",
            cast(int) label.length, label.ptr, buckets[j]);
    fflush(stdout);
}

// ---------------------------------------------------------------------------
// Stall watchdog: the bounded mode must never hang CI. If no frame lands for
// 10 s (a pacing source that blocks forever, e.g. a DwmFlush that never
// returns), report and abort with exit code 2.

extern (Windows) DWORD stallWatchdog(LPVOID) nothrow
{
    while (!atomicLoad(s_done))
    {
        Sleep(500);
        const last = atomicLoad(s_lastFrameUs);
        if (!atomicLoad(s_done) && nowUs() - last > 10_000_000)
        {
            logEvent("watchdog event=stall last_frame_us=%lld path=%s",
                last, g.path);
            printStats();
            ExitProcess(2);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// The window procedure.

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_CREATE:
        g.memDc = CreateCompatibleDC(null);
        return 0;

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        logEvent("resize size=%dx%d wparam=%d", w, h, cast(int) wParam);
        if (wParam == SIZE_MINIMIZED)
        {
            logEvent("vis_change state=size_minimized");
            return 0; // keep the backbuffer; pacing continues (or not — log!)
        }
        if (w != g.width || h != g.height)
            createBackbuffer(w, h);
        return 0;

    case WM_ERASEBKGND:
        return 1;

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        if (g.pixels !is null)
            BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
        EndPaint(hwnd, &ps);
        return 0;

    case WM_TIMER:
        if (wParam != FRAME_TIMER_ID)
            return 0;
        onFrame();
        if (g.autoExit && g.frame >= FRAMES_TOTAL)
        {
            KillTimer(hwnd, FRAME_TIMER_ID);
            printStats();
            DestroyWindow(hwnd);
        }
        return 0;

    case WM_CLOSE:
        logEvent("close_requested");
        goto default;

    case WM_DESTROY:
        logEvent("msg name=WM_DESTROY");
        KillTimer(hwnd, FRAME_TIMER_ID);
        createBackbuffer(0, 0);
        if (g.memDc !is null)
        {
            DeleteDC(g.memDc);
            g.memDc = null;
        }
        PostQuitMessage(0);
        return 0;

    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

// ---------------------------------------------------------------------------
// Pacing-path selection: report what DWM says, then measure what DwmFlush
// actually does. A real composition clock blocks ~per-vblank (2–50 ms); an
// immediate return (Wine stubs, composition off) or an error HRESULT means
// the documented fallback (SetTimer) must take over.

const(char)* probeDwm() nothrow
{
    BOOL enabled = FALSE;
    const hrEnabled = DwmIsCompositionEnabled(&enabled);
    logEvent("step name=DwmIsCompositionEnabled hr=0x%08x enabled=%d",
        cast(uint) hrEnabled, enabled ? 1 : 0);

    long minDt = long.max, maxDt = 0;
    HRESULT lastHr = 0;
    uint failures = 0;
    foreach (i; 0 .. 10)
    {
        const t0 = nowUs();
        const hr = DwmFlush();
        const dt = nowUs() - t0;
        if (hr != 0)
        {
            ++failures;
            lastHr = hr;
        }
        if (dt < minDt)
            minDt = dt;
        if (dt > maxDt)
            maxDt = dt;
        logEvent("pacing_probe call=%d hr=0x%08x dt_us=%lld", i,
            cast(uint) hr, dt);
    }

    if (g.forceTimer)
        return "forced_timer";
    if (failures == 10 && !g.forceDwm)
        return "dwmflush_failed";
    if (failures > 0 && !g.forceDwm)
        return "dwmflush_unreliable";
    // "Blocks at least once for >= 2 ms" is the cheapest honest signature of
    // a real composition clock; immediate returns would busy-spin the loop.
    if (maxDt < 2_000 && !g.forceDwm)
        return "dwmflush_returns_immediately";
    if (!enabled && !g.forceDwm)
        return "composition_disabled";
    return null; // use the DWM path
}

// The DwmFlush-paced loop. Returns true when the run is complete (or the
// window died); false means "fall back to the timer path mid-run".
bool runDwmLoop() nothrow
{
    uint consecutiveFailures = 0;
    while (true)
    {
        const hr = DwmFlush();
        if (hr != 0)
        {
            logEvent("pacing_error hr=0x%08x frame=%u", cast(uint) hr, g.frame);
            if (++consecutiveFailures >= 5)
            {
                logEvent("pacing_path path=timer reason=dwmflush_failed_midrun");
                return false;
            }
        }
        else
            consecutiveFailures = 0;

        onFrame();

        // Drain whatever the frame produced; the loop owns the cadence.
        MSG msg;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE))
        {
            if (msg.message == WM_QUIT)
                return true;
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (g.autoExit && g.frame >= FRAMES_TOTAL)
        {
            printStats();
            DestroyWindow(g_hwnd);
            while (GetMessageW(&msg, null, 0, 0) > 0)
            {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            return true;
        }
    }
}

bool envFlag(const(wchar)* name) nothrow
{
    WCHAR[8] buf;
    const n = GetEnvironmentVariableW(name, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

int main()
{
    instrumentInit("f04_frame_pacing_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    g.forceTimer = envFlag("WSI_FORCE_TIMER"w.ptr);
    g.forceDwm = envFlag("WSI_FORCE_DWM"w.ptr);
    logEvent("mode auto_exit=%d force_timer=%d force_dwm=%d",
        g.autoExit ? 1 : 0, g.forceTimer ? 1 : 0, g.forceDwm ? 1 : 0);

    HINSTANCE hInst = GetModuleHandleW(null);
    HCURSOR arrow = LoadCursorW(null, IDC_ARROW);

    auto clsName = "wsi-f04-class"w;
    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = clsName.ptr;
    wc.hCursor = arrow;

    logEvent("step name=RegisterClassExW");
    if (!RegisterClassExW(&wc))
    {
        logEvent("error what=RegisterClassExW code=%lu", GetLastError());
        return 1;
    }

    logEvent("step name=CreateWindowExW");
    g_hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f04-frame-pacing"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, hInst, null);
    if (g_hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");
    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);

    atomicStore(s_lastFrameUs, nowUs());
    HANDLE wd = null;
    if (g.autoExit)
        wd = CreateThread(null, 0, &stallWatchdog, null, 0, null);

    const reason = probeDwm();
    bool completed = false;
    if (reason is null)
    {
        g.path = "dwm";
        logEvent("pacing_path path=dwm reason=%s",
            g.forceDwm ? "forced_dwm".ptr : "probe_blocked".ptr);
        completed = runDwmLoop();
    }
    else
        logEvent("pacing_path path=timer reason=%s", reason);

    int code = 0;
    if (!completed)
    {
        g.path = "timer";
        logEvent("step name=SetTimer interval_ms=%d", TIMER_MS);
        SetTimer(g_hwnd, FRAME_TIMER_ID, TIMER_MS, null);
        MSG msg;
        while (GetMessageW(&msg, null, 0, 0) > 0)
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        code = cast(int) msg.wParam;
    }

    atomicStore(s_done, true);
    if (wd !is null)
    {
        WaitForSingleObject(wd, 1500);
        CloseHandle(wd);
    }
    printStats(); // no-op if already printed
    logEvent("exit code=%d", code);
    return code;
}

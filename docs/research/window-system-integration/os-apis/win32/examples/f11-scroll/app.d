// F11 — Scroll fidelity, Win32 implementation (../../../features/f11-scroll.md).
// Extends the scaffold (../scaffold/app.d) into a wheel-message observatory:
//
//   * WM_MOUSEWHEEL / WM_MOUSEHWHEEL handlers log every event's raw signed
//     wheelDelta (GET_WHEEL_DELTA_WPARAM), key state, and screen position.
//   * The ACCUMULATION CONTRACT is implemented and proved: sub-WHEEL_DELTA
//     remainders are carried in an accumulator until |acc| >= 120, then turned
//     into line scrolls (`acc=… detents=…` in every scroll line). The buggy
//     per-event truncation model runs side by side, and a per-gesture summary
//     diffs the two; WSI_TRUNCATE=1 makes the BUGGY model drive the ruler.
//   * Gestures are injected via SendInput MOUSEEVENTF_WHEEL / _HWHEEL with
//     mouseData = ±120 (one detent), ±40 (sub-detent, precision-touchpad
//     style), +360 (multi-detent), and a +40/-40/+40 jitter burst (net 40 —
//     must produce ZERO lines).
//   * Routing probe: a second window is created beside the main one; with
//     focus on MAIN and the cursor parked over OTHER, a wheel event is
//     injected and the receiving window logged (focus routing vs
//     window-under-cursor routing; SPI_GETMOUSEWHEELROUTING is probed).
//   * SPI_GETWHEELSCROLLLINES / SPI_GETWHEELSCROLLCHARS are logged; a
//     scrollable ruler (tick every line, numbered every 5) renders the
//     line-scroll output so over/under-scroll is visible.
//
// WSI_AUTO_EXIT=1 bounds the run (~1.5 s); exit 0 in all modes.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

// Missing from druntime's core.sys.windows.winuser:
enum DWORD MOUSEEVENTF_HWHEEL = 0x1000; // SendInput horizontal-wheel flag
enum UINT SPI_GETWHEELSCROLLCHARS = 0x006C;
enum UINT SPI_GETMOUSEWHEELROUTING = 0x201C;
// SPI_GETMOUSEWHEELROUTING values:
//   0 = MOUSEWHEEL_ROUTING_FOCUS, 1 = MOUSEWHEEL_ROUTING_HYBRID (Win8/8.1),
//   2 = MOUSEWHEEL_ROUTING_MOUSE_POS (Win10+ "scroll inactive windows" default)

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 16;
enum LINE_PX = 14; // ruler row height

// ---------------------------------------------------------------------------
// Per-axis scroll state: the correct carry-the-remainder accumulator next to
// the buggy per-event-truncation model.

struct Axis
{
    int acc; // carried sub-120 remainder (correct model)
    int detents; // total detents emitted by the correct model
    int truncDetents; // total detents emitted by per-event truncation (buggy)
    int gEvents, gDelta, gDetents, gTruncDetents; // per-gesture counters
}

struct Demo
{
    HDC memDc;
    HBITMAP dib, stockBmp;
    uint* pixels;
    int width, height;
    uint frame, ticks;
    HWND hwnd, other;
    bool autoExit;
    bool truncate; // WSI_TRUNCATE=1: the buggy model drives the ruler
    Axis v, h;
    int scrollLines = 3; // SPI_GETWHEELSCROLLLINES
    int rulerLine; // ruler offset in lines (driven by v-axis detents)
    const(char)* gesture = "";
}

__gshared Demo g;

// ---------------------------------------------------------------------------
// Wheel handling: one handler for both axes and both windows.

void onWheel(HWND hwnd, const(char)* axis, ref Axis ax, WPARAM wParam, LPARAM lParam) nothrow
{
    const delta = GET_WHEEL_DELTA_WPARAM(wParam); // signed; multiple/fraction of 120
    const target = hwnd is g.hwnd ? "main".ptr : "other".ptr;
    // Correct model: accumulate, emit detents, CARRY the remainder.
    // (D's / truncates toward zero, so the remainder keeps the right sign.)
    ax.acc += delta;
    const d = ax.acc / WHEEL_DELTA;
    ax.acc -= d * WHEEL_DELTA;
    // Buggy model: truncate each event in isolation — ±40 events vanish.
    const td = delta / WHEEL_DELTA;
    ax.detents += d;
    ax.truncDetents += td;
    ax.gEvents++;
    ax.gDelta += delta;
    ax.gDetents += d;
    ax.gTruncDetents += td;
    logEvent("scroll axis=%s value=%d target=%s screen=%d,%d keys=0x%x acc=%d detents=%d trunc_detents=%d",
        axis, delta, target,
        cast(int) cast(short)(lParam & 0xffff),
        cast(int) cast(short)((lParam >> 16) & 0xffff),
        cast(uint)(wParam & 0xffff), ax.acc, d, td);
    if (hwnd is g.hwnd && axis[0] == 'v')
    {
        const lines = (g.truncate ? td : d) * g.scrollLines;
        if (lines != 0)
        {
            g.rulerLine += lines;
            logEvent("ruler scroll lines=%d pos_line=%d", lines, g.rulerLine);
        }
    }
}

void gestureBegin(const(char)* name) nothrow
{
    g.gesture = name;
    g.v.gEvents = g.v.gDelta = g.v.gDetents = g.v.gTruncDetents = 0;
    g.h.gEvents = g.h.gDelta = g.h.gDetents = g.h.gTruncDetents = 0;
    logEvent("gesture_begin name=%s", name);
}

void gestureEnd() nothrow
{
    foreach (i, ax; [&g.v, &g.h])
        if (ax.gEvents != 0)
            logEvent("gesture_summary name=%s axis=%s events=%d delta_total=%d detents=%d trunc_detents=%d acc_left=%d lost_by_truncation=%d",
                g.gesture, i == 0 ? "v".ptr : "h".ptr, ax.gEvents, ax.gDelta,
                ax.gDetents, ax.gTruncDetents, ax.acc,
                ax.gDetents - ax.gTruncDetents);
}

// ---------------------------------------------------------------------------
// Injection.

void injectWheel(bool horiz, int data) nothrow
{
    INPUT inp;
    inp.type = INPUT_MOUSE;
    inp.mi.mouseData = cast(DWORD) data;
    inp.mi.dwFlags = horiz ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
    logEvent("inject axis=%s data=%d", horiz ? "h".ptr : "v".ptr, data);
    if (SendInput(1, &inp, INPUT.sizeof) != 1)
        logEvent("error what=SendInput code=%lu", GetLastError());
}

// ---------------------------------------------------------------------------
// Backbuffer + ruler rendering: a tick row every line, a bright major row
// every 5 lines, offset by the scrolled line count.

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
}

void drawFrame() nothrow
{
    if (g.pixels is null)
        return;
    const w = g.width, h = g.height;
    foreach (y; 0 .. h)
    {
        uint* row = g.pixels + cast(size_t) y * w;
        // worldLine of this row, given the current scroll offset
        const world = y + g.rulerLine * LINE_PX;
        int m = world % LINE_PX;
        if (m < 0)
            m += LINE_PX;
        const lineNo = (world - m) / LINE_PX;
        const isTick = m == 0;
        const major = isTick && lineNo % 5 == 0;
        const bg = cast(uint)(0x101820 + ((lineNo & 1) ? 0x080808 : 0));
        const tickLen = major ? w : w / 8;
        foreach (x; 0 .. w)
            row[x] = isTick && x < tickLen ? (major ? 0xffffff : 0x607080) : bg;
    }
}

// ---------------------------------------------------------------------------
// The bounded-run schedule (one entry per WM_TIMER tick).

void runSchedule(HWND hwnd) nothrow
{
    switch (g.ticks)
    {
    case 4:
        gestureBegin("one_detent_up");
        injectWheel(false, WHEEL_DELTA); // +120: away from the user
        break;
    case 8: gestureEnd(); break;
    case 10:
        gestureBegin("one_detent_down");
        injectWheel(false, -WHEEL_DELTA);
        break;
    case 14: gestureEnd(); break;
    case 16: // 3 x +40: each event is sub-detent; only the SUM is one detent
        gestureBegin("sub_detent_x3");
        injectWheel(false, 40);
        injectWheel(false, 40);
        injectWheel(false, 40);
        break;
    case 22: gestureEnd(); break;
    case 24:
        gestureBegin("sub_detent_x3_down");
        injectWheel(false, -40);
        injectWheel(false, -40);
        injectWheel(false, -40);
        break;
    case 30: gestureEnd(); break;
    case 32: // one event carrying three detents at once
        gestureBegin("multi_detent");
        injectWheel(false, 3 * WHEEL_DELTA);
        break;
    case 36: gestureEnd(); break;
    case 38: // net +40: the accumulator must NOT emit a line (and not lose it)
        gestureBegin("jitter_no_detent");
        injectWheel(false, 40);
        injectWheel(false, -40);
        injectWheel(false, 40);
        break;
    case 44: gestureEnd(); break;
    case 46:
        gestureBegin("horizontal");
        injectWheel(true, WHEEL_DELTA);
        injectWheel(true, -40);
        injectWheel(true, -40);
        injectWheel(true, -40);
        break;
    case 52: gestureEnd(); break;
    case 54: // routing: focus on MAIN, cursor over OTHER, who gets the wheel?
        gestureBegin("routing_probe");
        RECT rc;
        GetWindowRect(g.other, &rc);
        const cx = (rc.left + rc.right) / 2, cy = (rc.top + rc.bottom) / 2;
        SetCursorPos(cx, cy);
        POINT p;
        GetCursorPos(&p);
        logEvent("routing_probe focus=%s cursor_over=other requested=%d,%d actual=%d,%d",
            GetFocus() is g.hwnd ? "main".ptr : "other".ptr,
            cast(int) cx, cast(int) cy, cast(int) p.x, cast(int) p.y);
        break;
    case 56: injectWheel(false, WHEEL_DELTA); break;
    case 60:
        gestureEnd();
        RECT rc;
        GetWindowRect(hwnd, &rc);
        SetCursorPos((rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2);
        break;
    case 64:
        logEvent("summary v_detents=%d v_trunc_detents=%d v_acc=%d h_detents=%d h_trunc_detents=%d h_acc=%d ruler_pos_line=%d",
            g.v.detents, g.v.truncDetents, g.v.acc,
            g.h.detents, g.h.truncDetents, g.h.acc, g.rulerLine);
        DestroyWindow(hwnd);
        break;
    default:
        break;
    }
}

// ---------------------------------------------------------------------------

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_CREATE:
        if (g.memDc is null)
            g.memDc = CreateCompatibleDC(null);
        return 0;

    case WM_MOUSEWHEEL:
        onWheel(hwnd, "v", g.v, wParam, lParam);
        return 0;

    case WM_MOUSEHWHEEL:
        onWheel(hwnd, "h", g.h, wParam, lParam);
        return 0; // an app that handles WM_MOUSEHWHEEL must return zero

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        if (wParam == SIZE_MINIMIZED)
            return 0;
        if (hwnd is g.hwnd && (w != g.width || h != g.height))
            createBackbuffer(w, h);
        return 0;

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        if (hwnd is g.hwnd)
        {
            ++g.frame;
            drawFrame();
            if (g.pixels !is null)
                BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
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
        if (hwnd !is g.hwnd)
            goto default;
        KillTimer(hwnd, TIMER_ID);
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

bool envFlag(const(wchar)* name) nothrow
{
    WCHAR[16] buf;
    const n = GetEnvironmentVariableW(name, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

int main()
{
    instrumentInit("f11_scroll_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    g.truncate = envFlag("WSI_TRUNCATE"w.ptr);
    logEvent("mode auto_exit=%d truncate=%d", g.autoExit ? 1 : 0, g.truncate ? 1 : 0);

    // System scroll parameters.
    UINT lines = 3, chars = 3;
    const okL = SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    const okC = SystemParametersInfoW(SPI_GETWHEELSCROLLCHARS, 0, &chars, 0);
    if (okL && lines > 0 && lines != WHEEL_PAGESCROLL)
        g.scrollLines = cast(int) lines;
    logEvent("wheel_params scroll_lines=%u ok=%d scroll_chars=%u ok=%d wheel_delta=%d",
        lines, okL, chars, okC, WHEEL_DELTA);
    DWORD routing = 0xdead;
    SetLastError(0);
    const okR = SystemParametersInfoW(SPI_GETMOUSEWHEELROUTING, 0, &routing, 0);
    logEvent("wheel_routing spi=0x201C ok=%d value=%lu err=%lu",
        okR, routing, okR ? 0 : GetLastError());

    HINSTANCE hInst = GetModuleHandleW(null);
    HCURSOR arrow = LoadCursorW(null, IDC_ARROW);
    auto clsName = "wsi-f11-class"w;
    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = clsName.ptr;
    wc.hCursor = arrow;
    if (!RegisterClassExW(&wc))
    {
        logEvent("error what=RegisterClassExW code=%lu", GetLastError());
        return 1;
    }

    // Positions chosen to fit a 640x480 Xvfb screen with no overlap, so the
    // routing probe's cursor-over-other warp stays on-screen under winex11.
    g.hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f11-scroll"w.ptr,
        WS_OVERLAPPEDWINDOW, 20, 140, 480, 320, null, null, hInst, null);
    if (g.hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");

    // The routing-probe window: same class (its WM_MOUSEWHEEL logs
    // target=other), shown beside the main window without taking activation.
    g.other = CreateWindowExW(0, clsName.ptr, "wsi-f11-other"w.ptr,
        WS_OVERLAPPEDWINDOW, 510, 10, 120, 100, null, null, hInst, null);
    ShowWindow(g.other, SW_SHOWNOACTIVATE);

    ShowWindow(g.hwnd, SW_SHOW);
    UpdateWindow(g.hwnd);
    // Park the cursor over the main window so cursor-pos routing (if active)
    // also targets it during the accumulation gestures.
    RECT rc;
    GetWindowRect(g.hwnd, &rc);
    SetCursorPos((rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2);
    SetTimer(g.hwnd, TIMER_ID, TICK_MS, null);

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    logEvent("exit code=%d", cast(int) msg.wParam);
    return cast(int) msg.wParam;
}

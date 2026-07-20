// F14 — Window state & vetoable close, Win32 implementation
// (../../../features/f14-window-state.md). Extends the scaffold
// (../scaffold/app.d) into a state-transition observatory:
//
//   * ShowWindow(SW_MAXIMIZE / SW_MINIMIZE / SW_RESTORE) for the real states,
//     and the borderless-fullscreen IDIOM for fullscreen (Win32 has no
//     fullscreen window state): save GetWindowLongPtrW(GWL_STYLE) +
//     GetWindowRect, strip WS_OVERLAPPEDWINDOW, SetWindowPos to the
//     MonitorFromWindow rect with SWP_FRAMECHANGED; exit reverses it.
//   * Every message until the state settles is logged with decoded payloads:
//     WM_SIZE wParam (SIZE_RESTORED/MINIMIZED/MAXIMIZED/…),
//     WM_WINDOWPOSCHANGING/WM_WINDOWPOSCHANGED (flags + rect),
//     WM_GETMINMAXINFO (ptMaxSize/ptMaxPosition), WM_ACTIVATE (state +
//     minimized flag + peer hwnd), WM_SETFOCUS/WM_KILLFOCUS (peer hwnd — the
//     "where does focus go on minimize" probe), WM_SYSCOMMAND, WM_SHOWWINDOW.
//   * After each transition, GetWindowPlacement is logged (showCmd decode +
//     rcNormalPosition) — the normal-rect memory across max/min/fullscreen.
//   * Vetoable close: a "dirty" flag (key D toggles it interactively). On
//     WM_CLOSE with dirty set: log close_requested veto=1, clear the flag,
//     return 0 WITHOUT DefWindowProcW — Win32's first-class veto (not
//     forwarding to DefWindowProc IS the refusal; no DestroyWindow happens).
//     Second WM_CLOSE → DefWindowProcW → DestroyWindow → WM_DESTROY →
//     PostQuitMessage. The close source is visible because the demo drives it
//     through the real chain: WM_SYSCOMMAND SC_CLOSE (what the title-bar X
//     sends) → DefWindowProc → WM_CLOSE.
//   * WSI_AUTO_EXIT=1 runs the scripted tour: maximize → restore → minimize →
//     restore → fullscreen on → fullscreen off → dirty + SC_CLOSE (vetoed) →
//     SC_CLOSE (closes). Exit 0. Without it: M maximize toggle, N minimize,
//     F fullscreen toggle, R restore, D dirty toggle, close via the X button.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 16;
enum TICKS_PER_STEP = 25; // ~400 ms settle time between scripted transitions

struct Demo
{
    HDC memDc;
    HBITMAP dib, stockBmp;
    uint* pixels;
    int width, height;
    uint frame, ticks;
    bool autoExit;
    int step; // scripted-tour position
    bool dirty; // vetoable-close flag
    bool closeFromSelf; // we sent the WM_SYSCOMMAND that produced WM_CLOSE
    // Borderless-fullscreen idiom state:
    bool fullscreen;
    LONG_PTR savedStyle;
    RECT savedRect;
}

__gshared Demo g;

// ---------------------------------------------------------------------------
// Backbuffer (scaffold-identical).

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
        return;
    g.pixels = cast(uint*) bits;
    g.width = w;
    g.height = h;
    g.stockBmp = cast(HBITMAP) SelectObject(g.memDc, g.dib);
    logEvent("buffer_alloc size=%dx%d", w, h);
}

void drawGradient() nothrow
{
    if (g.pixels is null)
        return;
    const w = g.width, h = g.height;
    const blue = (g.frame * 4) & 0xff;
    // Red border band when dirty, so the veto state is visible interactively.
    foreach (y; 0 .. h)
    {
        uint* row = g.pixels + cast(size_t) y * w;
        const green = h > 1 ? (y * 255) / (h - 1) : 0;
        foreach (x; 0 .. w)
        {
            const red = w > 1 ? (x * 255) / (w - 1) : 0;
            row[x] = cast(uint)((red << 16) | (green << 8) | blue);
            if (g.dirty && (x < 8 || y < 8 || x >= w - 8 || y >= h - 8))
                row[x] = 0xcc2222;
        }
    }
}

// ---------------------------------------------------------------------------
// Decoders + placement probe.

const(char)* sizeKind(WPARAM w) nothrow @nogc
{
    switch (w)
    {
    case SIZE_RESTORED: return "SIZE_RESTORED";
    case SIZE_MINIMIZED: return "SIZE_MINIMIZED";
    case SIZE_MAXIMIZED: return "SIZE_MAXIMIZED";
    case SIZE_MAXSHOW: return "SIZE_MAXSHOW";
    case SIZE_MAXHIDE: return "SIZE_MAXHIDE";
    default: return "?";
    }
}

const(char)* showCmdName(UINT c) nothrow @nogc
{
    switch (c)
    {
    case SW_SHOWNORMAL: return "SW_SHOWNORMAL";
    case SW_SHOWMINIMIZED: return "SW_SHOWMINIMIZED";
    case SW_SHOWMAXIMIZED: return "SW_SHOWMAXIMIZED";
    default: return "other";
    }
}

const(char)* activateKind(WPARAM w) nothrow @nogc
{
    switch (LOWORD(w))
    {
    case WA_INACTIVE: return "WA_INACTIVE";
    case WA_ACTIVE: return "WA_ACTIVE";
    case WA_CLICKACTIVE: return "WA_CLICKACTIVE";
    default: return "?";
    }
}

// GetWindowPlacement: showCmd + the remembered normal rect — logged after
// every transition to prove the normal-rect memory survives max/min/fullscreen.
void logPlacement(HWND hwnd, const(char)* when) nothrow
{
    WINDOWPLACEMENT wp;
    wp.length = WINDOWPLACEMENT.sizeof;
    if (!GetWindowPlacement(hwnd, &wp))
        return;
    const r = wp.rcNormalPosition;
    logEvent("placement when=%s showCmd=%s normal_rect=%ld,%ld-%ldx%ld iconic=%d zoomed=%d",
        when, showCmdName(wp.showCmd), r.left, r.top,
        r.right - r.left, r.bottom - r.top,
        IsIconic(hwnd) ? 1 : 0, IsZoomed(hwnd) ? 1 : 0);
}

// ---------------------------------------------------------------------------
// The borderless-fullscreen idiom. Win32 has no fullscreen STATE — this is
// the documented community idiom (Raymond Chen, "How do I switch a window
// between normal and fullscreen?"): save style+rect, strip the frame, size to
// the monitor, restore both on the way out.

void enterFullscreen(HWND hwnd) nothrow
{
    if (g.fullscreen)
        return;
    g.savedStyle = GetWindowLongPtrW(hwnd, GWL_STYLE);
    GetWindowRect(hwnd, &g.savedRect);
    MONITORINFO mi;
    mi.cbSize = MONITORINFO.sizeof;
    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &mi);
    const r = mi.rcMonitor;
    logEvent("state_request kind=fullscreen_enter monitor=%ld,%ld-%ldx%ld saved_rect=%ld,%ld-%ldx%ld",
        r.left, r.top, r.right - r.left, r.bottom - r.top,
        g.savedRect.left, g.savedRect.top,
        g.savedRect.right - g.savedRect.left, g.savedRect.bottom - g.savedRect.top);
    SetWindowLongPtrW(hwnd, GWL_STYLE, g.savedStyle & ~cast(LONG_PTR) WS_OVERLAPPEDWINDOW);
    SetWindowPos(hwnd, HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top,
        SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    g.fullscreen = true;
    logPlacement(hwnd, "fullscreen_enter");
}

void exitFullscreen(HWND hwnd) nothrow
{
    if (!g.fullscreen)
        return;
    logEvent("state_request kind=fullscreen_exit");
    SetWindowLongPtrW(hwnd, GWL_STYLE, g.savedStyle);
    const r = g.savedRect;
    SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top,
        SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    g.fullscreen = false;
    logPlacement(hwnd, "fullscreen_exit");
}

// ---------------------------------------------------------------------------
// Scripted tour (WSI_AUTO_EXIT=1), one step every TICKS_PER_STEP timer ticks.

void runStep(HWND hwnd, int n) nothrow
{
    switch (n)
    {
    case 0:
        logPlacement(hwnd, "initial");
        break;
    case 1:
        logEvent("state_request kind=maximize api=ShowWindow(SW_MAXIMIZE)");
        ShowWindow(hwnd, SW_MAXIMIZE);
        logPlacement(hwnd, "after_maximize");
        break;
    case 2:
        logEvent("state_request kind=restore api=ShowWindow(SW_RESTORE)");
        ShowWindow(hwnd, SW_RESTORE);
        logPlacement(hwnd, "after_restore");
        break;
    case 3:
        logEvent("state_request kind=minimize api=ShowWindow(SW_MINIMIZE)");
        ShowWindow(hwnd, SW_MINIMIZE);
        logPlacement(hwnd, "after_minimize");
        logEvent("focus_probe foreground=%p focus=%p self=%p",
            GetForegroundWindow(), GetFocus(), hwnd);
        break;
    case 4:
        logEvent("state_request kind=restore api=ShowWindow(SW_RESTORE)");
        ShowWindow(hwnd, SW_RESTORE);
        logPlacement(hwnd, "after_restore");
        break;
    case 5:
        enterFullscreen(hwnd);
        break;
    case 6:
        exitFullscreen(hwnd);
        break;
    case 7:
        g.dirty = true;
        logEvent("dirty set=1");
        // Drive the close through the real user chain: the title-bar X sends
        // WM_SYSCOMMAND SC_CLOSE, which DefWindowProc turns into WM_CLOSE.
        g.closeFromSelf = true;
        logEvent("state_request kind=close api=WM_SYSCOMMAND(SC_CLOSE) attempt=1");
        SendMessageW(hwnd, WM_SYSCOMMAND, SC_CLOSE, 0);
        break;
    case 8:
        g.closeFromSelf = true;
        logEvent("state_request kind=close api=WM_SYSCOMMAND(SC_CLOSE) attempt=2");
        SendMessageW(hwnd, WM_SYSCOMMAND, SC_CLOSE, 0);
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
        g.memDc = CreateCompatibleDC(null);
        return 0;

    case WM_SHOWWINDOW:
        logEvent("msg name=WM_SHOWWINDOW shown=%d", cast(int) wParam);
        goto default;

    case WM_GETMINMAXINFO:
        // Sent when the size/position is about to change — notably on
        // maximize, letting the app override the maximized size/position.
        auto mmi = cast(MINMAXINFO*) lParam;
        logEvent("msg name=WM_GETMINMAXINFO maxSize=%ldx%ld maxPos=%ld,%ld",
            mmi.ptMaxSize.x, mmi.ptMaxSize.y, mmi.ptMaxPosition.x, mmi.ptMaxPosition.y);
        goto default;

    case WM_WINDOWPOSCHANGING:
        auto wpg = cast(WINDOWPOS*) lParam;
        logEvent("msg name=WM_WINDOWPOSCHANGING rect=%d,%d-%dx%d flags=0x%x",
            wpg.x, wpg.y, wpg.cx, wpg.cy, wpg.flags);
        goto default;

    case WM_WINDOWPOSCHANGED:
        auto wpd = cast(WINDOWPOS*) lParam;
        logEvent("msg name=WM_WINDOWPOSCHANGED rect=%d,%d-%dx%d flags=0x%x",
            wpd.x, wpd.y, wpd.cx, wpd.cy, wpd.flags);
        goto default; // DefWindowProc synthesizes WM_SIZE/WM_MOVE

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        logEvent("state_changed via=WM_SIZE kind=%s size=%dx%d", sizeKind(wParam), w, h);
        if (wParam == SIZE_MINIMIZED)
            return 0;
        if (w != g.width || h != g.height)
            createBackbuffer(w, h);
        return 0;

    case WM_ACTIVATE:
        logEvent("focus state=%s reason=WM_ACTIVATE minimized=%d other=%p",
            activateKind(wParam), HIWORD(wParam) ? 1 : 0, cast(void*) lParam);
        goto default;

    case WM_ACTIVATEAPP:
        logEvent("msg name=WM_ACTIVATEAPP active=%d", cast(int) wParam);
        goto default;

    case WM_SETFOCUS:
        logEvent("focus state=in reason=WM_SETFOCUS prev=%p", cast(void*) wParam);
        return 0;

    case WM_KILLFOCUS:
        // wParam = the window RECEIVING focus (may be null) — the
        // where-does-focus-go-on-minimize probe.
        logEvent("focus state=out reason=WM_KILLFOCUS next=%p", cast(void*) wParam);
        return 0;

    case WM_SYSCOMMAND:
        logEvent("msg name=WM_SYSCOMMAND cmd=0x%llx", cast(ulong)(wParam & 0xfff0));
        goto default;

    case WM_CLOSE:
        if (g.dirty)
        {
            // The first-class veto: return 0 WITHOUT calling DefWindowProcW.
            // DefWindowProc's WM_CLOSE handling is what calls DestroyWindow;
            // not forwarding IS the refusal — no further protocol required.
            logEvent("close_requested veto=1 src=%s dirty=1",
                g.closeFromSelf ? "self_syscommand".ptr : "external".ptr);
            g.dirty = false;
            g.closeFromSelf = false;
            return 0;
        }
        logEvent("close_requested veto=0 src=%s dirty=0",
            g.closeFromSelf ? "self_syscommand".ptr : "external".ptr);
        g.closeFromSelf = false;
        goto default; // DefWindowProcW → DestroyWindow

    case WM_ERASEBKGND:
        return 1;

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        ++g.frame;
        drawGradient();
        if (g.pixels !is null)
            BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
        EndPaint(hwnd, &ps);
        return 0;

    case WM_KEYDOWN:
        switch (wParam)
        {
        case 'M':
            logEvent("state_request kind=%s api=ShowWindow", IsZoomed(hwnd) ? "restore".ptr
                    : "maximize".ptr);
            ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
            logPlacement(hwnd, "after_key_m");
            break;
        case 'N':
            logEvent("state_request kind=minimize api=ShowWindow(SW_MINIMIZE)");
            ShowWindow(hwnd, SW_MINIMIZE);
            break;
        case 'R':
            logEvent("state_request kind=restore api=ShowWindow(SW_RESTORE)");
            ShowWindow(hwnd, SW_RESTORE);
            logPlacement(hwnd, "after_key_r");
            break;
        case 'F':
            if (g.fullscreen)
                exitFullscreen(hwnd);
            else
                enterFullscreen(hwnd);
            break;
        case 'D':
            g.dirty = !g.dirty;
            logEvent("dirty set=%d", g.dirty ? 1 : 0);
            InvalidateRect(hwnd, null, FALSE);
            break;
        default:
            break;
        }
        return 0;

    case WM_TIMER:
        if (wParam != TIMER_ID)
            return 0;
        ++g.ticks;
        InvalidateRect(hwnd, null, FALSE);
        if (g.autoExit && g.ticks % TICKS_PER_STEP == 0)
            runStep(hwnd, g.step++);
        return 0;

    case WM_DESTROY:
        logEvent("msg name=WM_DESTROY");
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

bool wantAutoExit() nothrow
{
    WCHAR[8] buf;
    const n = GetEnvironmentVariableW("WSI_AUTO_EXIT"w.ptr, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

int main()
{
    instrumentInit("f14_state_win32");
    logEvent("init_start");
    g.autoExit = wantAutoExit();
    logEvent("mode auto_exit=%d", g.autoExit ? 1 : 0);

    HINSTANCE hInst = GetModuleHandleW(null);
    auto clsName = "wsi-f14-class"w;
    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = clsName.ptr;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    if (!RegisterClassExW(&wc))
        return 1;

    HWND hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f14-window-state"w.ptr,
        WS_OVERLAPPEDWINDOW, 60, 40, 480, 320, null, null, hInst, null);
    if (hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created hwnd=%p", hwnd);
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

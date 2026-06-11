// F10 — Pointer: relative motion, lock & confine, Win32 implementation
// (../../../features/f10-pointer-capture.md). Extends the scaffold
// (../scaffold/app.d) into a raw-input / ClipCursor observatory:
//
//   * RegisterRawInputDevices(usage 1:2, RIDEV_INPUTSINK, hwndTarget) feeds
//     WM_INPUT; every RAWMOUSE is logged with lLastX/lLastY and the
//     MOUSE_MOVE_RELATIVE vs MOUSE_MOVE_ABSOLUTE flag, alongside the cooked
//     WM_MOUSEMOVE stream — so injected motion can be diffed raw-vs-cooked.
//     GetRegisteredRawInputDevices reads the registration back.
//   * Pointer "lock" is the classic Win32 assembly: GetCursorPos (save) →
//     ClipCursor(1×1 rect at the window center) → ShowCursor(FALSE); unlock
//     reverses it and SetCursorPos-restores the saved position. The
//     ShowCursor display COUNTER (not a flag) is probed explicitly: two
//     ShowCursor(FALSE) need two ShowCursor(TRUE).
//   * Confine: ClipCursor(center-half-of-window rect), clamping proved by
//     SetCursorPos requests outside the rect + GetCursorPos read-back, and a
//     huge injected relative move. GetClipCursor read-back after every change.
//     Headless-reachable auto-clear probes: focus loss to a second window and
//     SW_MINIMIZE, each followed by GetClipCursor.
//   * Motion is driven in-process (winewayland has no external warp tool):
//     SetCursorPos absolute warps, SendInput MOUSEEVENTF_MOVE relative
//     injection, and one legacy mouse_event call. Pointer-ballistics state is
//     logged via SystemParametersInfoW SPI_GETMOUSE / SPI_GETMOUSESPEED.
//   * Interactive mode (no WSI_AUTO_EXIT): L toggles mouselook, C toggles
//     confine; a crosshair displaced by the accumulated raw deltas (yaw/pitch)
//     visualizes mouselook.
//
// WSI_AUTO_EXIT=1 bounds the run (~2 s); exit 0 in all modes.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

// ---------------------------------------------------------------------------
// Demo state.

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 16;

struct Demo
{
    HDC memDc;
    HBITMAP dib, stockBmp;
    uint* pixels;
    int width, height;
    uint frame, ticks;
    HWND hwnd; // the main window
    HWND other; // focus-loss probe target
    bool autoExit;
    bool locked, confined;
    POINT savedPos; // cursor position at lock time (restored on unlock)
    POINT pinPos; // where the 1x1 lock rect pins the cursor
    int yaw, pitch; // accumulated raw deltas while locked (crosshair readout)
    uint nMouseMove, nInput;
}

__gshared Demo g;

// ---------------------------------------------------------------------------
// Probes.

void probeAccelState() nothrow
{
    int[3] mouse; // [xThreshold, yThreshold, accelOn]
    int speed;
    const okM = SystemParametersInfoW(SPI_GETMOUSE, 0, mouse.ptr, 0);
    const okS = SystemParametersInfoW(SPI_GETMOUSESPEED, 0, &speed, 0);
    logEvent("accel_state spi_getmouse=%d,%d,%d ok=%d speed=%d ok=%d",
        mouse[0], mouse[1], mouse[2], okM, speed, okS);
}

// ShowCursor maintains a per-input-desktop display COUNTER, not a flag: the
// cursor is shown while the counter is >= 0. Two hides need two shows.
void probeShowCursorCounter() nothrow
{
    const h1 = ShowCursor(FALSE);
    const h2 = ShowCursor(FALSE);
    const s1 = ShowCursor(TRUE);
    const s2 = ShowCursor(TRUE);
    logEvent("showcursor_probe hide1=%d hide2=%d show1=%d show2=%d visible=%d",
        h1, h2, s1, s2, s2 >= 0);
}

void registerRawMouse(HWND hwnd) nothrow
{
    RAWINPUTDEVICE rid;
    rid.usUsagePage = 1; // HID_USAGE_PAGE_GENERIC
    rid.usUsage = 2; // HID_USAGE_GENERIC_MOUSE
    rid.dwFlags = RIDEV_INPUTSINK; // probe: deltas even while unfocused
    rid.hwndTarget = hwnd; // INPUTSINK requires an explicit target
    const ok = RegisterRawInputDevices(&rid, 1, RAWINPUTDEVICE.sizeof);
    logEvent("raw_register usage=1:2 flags=RIDEV_INPUTSINK ok=%d err=%lu",
        ok, ok ? 0 : GetLastError());
    RAWINPUTDEVICE[4] back;
    UINT n = back.length;
    const got = GetRegisteredRawInputDevices(back.ptr, &n, RAWINPUTDEVICE.sizeof);
    if (got != cast(UINT)-1 && got >= 1)
        logEvent("raw_register_readback count=%u flags=0x%lx target=%p",
            got, back[0].dwFlags, back[0].hwndTarget);
    else
        logEvent("raw_register_readback count=%u err=%lu", got, GetLastError());
}

void logClipReadback(const(char)* tag) nothrow
{
    RECT rb;
    GetClipCursor(&rb);
    logEvent("%s clip_readback=%d,%d-%d,%d", tag,
        cast(int) rb.left, cast(int) rb.top, cast(int) rb.right, cast(int) rb.bottom);
}

// ---------------------------------------------------------------------------
// Lock / confine.

void lockPointer(HWND hwnd) nothrow
{
    GetCursorPos(&g.savedPos);
    RECT rc;
    GetClientRect(hwnd, &rc);
    POINT c = POINT(rc.right / 2, rc.bottom / 2);
    ClientToScreen(hwnd, &c);
    g.pinPos = c;
    RECT pin = RECT(c.x, c.y, c.x + 1, c.y + 1); // the 1x1 lock idiom
    if (!ClipCursor(&pin))
        logEvent("error what=ClipCursor code=%lu", GetLastError());
    SetCursorPos(c.x, c.y);
    const sc = ShowCursor(FALSE);
    g.locked = true;
    g.yaw = g.pitch = 0;
    logEvent("lock state=on pin=%d,%d saved=%d,%d showcursor=%d",
        cast(int) c.x, cast(int) c.y,
        cast(int) g.savedPos.x, cast(int) g.savedPos.y, sc);
    logClipReadback("lock");
}

void unlockPointer() nothrow
{
    ClipCursor(null);
    const sc = ShowCursor(TRUE);
    SetCursorPos(g.savedPos.x, g.savedPos.y);
    POINT p;
    GetCursorPos(&p);
    g.locked = false;
    logEvent("lock state=off showcursor=%d restored_to=%d,%d actual=%d,%d",
        sc, cast(int) g.savedPos.x, cast(int) g.savedPos.y,
        cast(int) p.x, cast(int) p.y);
    logClipReadback("unlock");
}

// Confine to the center half of the window (quarter-area centered rect).
void confinePointer(HWND hwnd) nothrow
{
    RECT rc;
    GetClientRect(hwnd, &rc);
    RECT r = RECT(rc.right / 4, rc.bottom / 4, rc.right * 3 / 4, rc.bottom * 3 / 4);
    MapWindowPoints(hwnd, null, cast(POINT*)&r, 2); // client -> screen
    if (!ClipCursor(&r))
        logEvent("error what=ClipCursor code=%lu", GetLastError());
    g.confined = true;
    logEvent("confine rect=%d,%d-%d,%d",
        cast(int) r.left, cast(int) r.top, cast(int) r.right, cast(int) r.bottom);
    logClipReadback("confine");
}

void unconfinePointer() nothrow
{
    ClipCursor(null);
    g.confined = false;
    logEvent("confine rect=none");
    logClipReadback("unconfine");
}

// SetCursorPos to a screen position, then read where the cursor actually
// landed — with a clip rect active the system clamps the request.
void probeWarp(const(char)* label, int x, int y) nothrow
{
    SetCursorPos(x, y);
    POINT p;
    GetCursorPos(&p);
    logEvent("confine_probe target=%s requested=%d,%d actual=%d,%d clamped=%d",
        label, x, y, cast(int) p.x, cast(int) p.y, p.x != x || p.y != y);
}

// ---------------------------------------------------------------------------
// In-process motion drivers.

void warpClient(HWND hwnd, int nx, int ny) nothrow // numerators over /4
{
    RECT rc;
    GetClientRect(hwnd, &rc);
    POINT p = POINT(rc.right * nx / 4, rc.bottom * ny / 4);
    ClientToScreen(hwnd, &p);
    logEvent("inject method=SetCursorPos kind=abs screen=%d,%d",
        cast(int) p.x, cast(int) p.y);
    SetCursorPos(p.x, p.y);
}

void injectRel(int dx, int dy) nothrow
{
    INPUT inp;
    inp.type = INPUT_MOUSE;
    inp.mi.dx = dx;
    inp.mi.dy = dy;
    inp.mi.dwFlags = MOUSEEVENTF_MOVE; // relative motion
    logEvent("inject method=SendInput kind=rel dx=%d dy=%d", dx, dy);
    if (SendInput(1, &inp, INPUT.sizeof) != 1)
        logEvent("error what=SendInput code=%lu", GetLastError());
}

// ---------------------------------------------------------------------------
// Backbuffer + crosshair rendering (scaffold gradient, dimmed; the crosshair
// is displaced by the accumulated raw deltas while locked).

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
        const green = h > 1 ? (y * 96) / (h - 1) : 0;
        foreach (x; 0 .. w)
            row[x] = cast(uint)(((x * 96 / (w > 1 ? w - 1 : 1)) << 16) | (green << 8));
    }
    if (g.confined) // show the confine rect
    {
        foreach (x; w / 4 .. w * 3 / 4)
        {
            g.pixels[cast(size_t)(h / 4) * w + x] = 0x00ffff;
            g.pixels[cast(size_t)(h * 3 / 4) * w + x] = 0x00ffff;
        }
        foreach (y; h / 4 .. h * 3 / 4)
        {
            g.pixels[cast(size_t) y * w + w / 4] = 0x00ffff;
            g.pixels[cast(size_t) y * w + w * 3 / 4] = 0x00ffff;
        }
    }
    // Crosshair at center + (yaw, pitch)/4, clamped to the client area.
    int cx = w / 2 + g.yaw / 4, cy = h / 2 + g.pitch / 4;
    if (cx < 8) cx = 8; if (cx > w - 9) cx = w - 9;
    if (cy < 8) cy = 8; if (cy > h - 9) cy = h - 9;
    const color = g.locked ? 0xffff00 : 0xffffff;
    foreach (d; -8 .. 9)
    {
        g.pixels[cast(size_t) cy * w + cx + d] = color;
        g.pixels[cast(size_t)(cy + d) * w + cx] = color;
    }
}

// ---------------------------------------------------------------------------
// The bounded-run schedule (one entry per WM_TIMER tick).

void runSchedule(HWND hwnd) nothrow
{
    switch (g.ticks)
    {
    // Phase A — absolute warps while unlocked: the WM_MOUSEMOVE / WM_INPUT
    // baseline (which flavor does a SetCursorPos warp produce?).
    case 6:
        logEvent("phase name=abs_tour");
        warpClient(hwnd, 1, 1);
        break;
    case 10: warpClient(hwnd, 3, 1); break;
    case 14: warpClient(hwnd, 3, 3); break;
    case 18: warpClient(hwnd, 2, 2); break;

    // Phase B — the same relative injection observed on both streams:
    // WM_INPUT should report the injected delta verbatim (raw bypasses
    // pointer ballistics); WM_MOUSEMOVE reports the post-ballistics position.
    case 24:
        logEvent("phase name=inject_compare");
        injectRel(16, 8);
        break;
    case 28: injectRel(16, 8); break;
    case 32: injectRel(-16, -8); break;
    case 36:
        logEvent("inject method=mouse_event kind=rel dx=-16 dy=-8");
        mouse_event(MOUSEEVENTF_MOVE, cast(DWORD)-16, cast(DWORD)-8, 0, 0);
        break;

    // Phase C — mouselook: lock (ClipCursor 1x1 + ShowCursor(FALSE)), feed
    // relative injections, prove the cursor stays pinned, unlock + restore.
    case 44:
        logEvent("phase name=mouselook");
        lockPointer(hwnd);
        break;
    case 48: injectRel(7, -3); break;
    case 52: injectRel(40, 0); break;
    case 56: injectRel(-13, 22); break;
    case 60:
        POINT p;
        GetCursorPos(&p);
        logEvent("locked_cursor x=%d y=%d pin=%d,%d yaw=%d pitch=%d",
            cast(int) p.x, cast(int) p.y,
            cast(int) g.pinPos.x, cast(int) g.pinPos.y, g.yaw, g.pitch);
        break;
    case 64: unlockPointer(); break;

    // Phase D — confine to the center half; prove clamping.
    case 70:
        logEvent("phase name=confine");
        confinePointer(hwnd);
        break;
    case 74: // inside the rect: granted verbatim
        RECT rc;
        GetClipCursor(&rc);
        probeWarp("inside", (rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2);
        break;
    case 78: // window corner, outside the rect: must clamp
        POINT c;
        ClientToScreen(hwnd, &c); // client (0,0)
        probeWarp("window_corner", c.x, c.y);
        break;
    case 82: probeWarp("screen_origin", 0, 0); break;
    case 86: injectRel(2000, 2000); break; // huge relative move: clamps too
    case 88:
        POINT p;
        GetCursorPos(&p);
        logEvent("confine_probe target=rel_2000 actual=%d,%d",
            cast(int) p.x, cast(int) p.y);
        break;

    // Phase E — what clears a ClipCursor? (headless-reachable probes)
    case 92:
        logEvent("phase name=clip_clear_probes");
        logEvent("probe name=focus_loss action=SetForegroundWindow(other)");
        SetForegroundWindow(g.other);
        break;
    case 96:
        logClipReadback("after_focus_loss");
        SetForegroundWindow(hwnd);
        break;
    case 100:
        logEvent("probe name=minimize action=ShowWindow(SW_MINIMIZE)");
        ShowWindow(hwnd, SW_MINIMIZE);
        break;
    case 104:
        logClipReadback("after_minimize");
        ShowWindow(hwnd, SW_RESTORE);
        break;
    case 108:
        unconfinePointer();
        break;
    case 112:
        logEvent("summary wm_mousemove=%u wm_input=%u", g.nMouseMove, g.nInput);
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

    case WM_INPUT:
        RAWINPUT ri;
        UINT size = RAWINPUT.sizeof;
        const got = GetRawInputData(cast(HRAWINPUT) lParam, RID_INPUT,
            &ri, &size, RAWINPUTHEADER.sizeof);
        if (got != cast(UINT)-1 && ri.header.dwType == RIM_TYPEMOUSE)
        {
            ++g.nInput;
            const fl = ri.data.mouse.usFlags;
            logEvent("pointer rel dx=%d dy=%d raw=1 flags=0x%x mode=%s buttons=0x%x",
                cast(int) ri.data.mouse.lLastX, cast(int) ri.data.mouse.lLastY,
                fl, (fl & MOUSE_MOVE_ABSOLUTE) ? "absolute".ptr : "relative".ptr,
                ri.data.mouse.usButtonFlags);
            if (g.locked && !(fl & MOUSE_MOVE_ABSOLUTE))
            {
                g.yaw += ri.data.mouse.lLastX;
                g.pitch += ri.data.mouse.lLastY;
                logEvent("mouselook yaw=%d pitch=%d", g.yaw, g.pitch);
            }
        }
        goto default; // DefWindowProc must see WM_INPUT (it frees the buffer)

    case WM_MOUSEMOVE:
        ++g.nMouseMove;
        logEvent("pointer abs x=%d y=%d raw=0",
            cast(int) cast(short)(lParam & 0xffff),
            cast(int) cast(short)((lParam >> 16) & 0xffff));
        return 0;

    case WM_KEYDOWN: // interactive mode: L = lock toggle, C = confine toggle
        if (wParam == 'L')
            g.locked ? unlockPointer() : lockPointer(hwnd);
        else if (wParam == 'C')
            g.confined ? unconfinePointer() : confinePointer(hwnd);
        return 0;

    case WM_KILLFOCUS:
        logEvent("msg name=WM_KILLFOCUS");
        return 0;

    case WM_SETFOCUS:
        logEvent("msg name=WM_SETFOCUS");
        return 0;

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
        ClipCursor(null); // hygiene: ClipCursor is GLOBAL state — always release
        if (g.locked)
            ShowCursor(TRUE);
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

// Minimal WndProc for the focus-loss probe window.
extern (Windows) LRESULT otherWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    if (msg == WM_SETFOCUS)
        logEvent("msg name=WM_SETFOCUS window=other");
    return DefWindowProcW(hwnd, msg, wParam, lParam);
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
    instrumentInit("f10_pointer_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    logEvent("mode auto_exit=%d", g.autoExit ? 1 : 0);

    probeAccelState();

    HINSTANCE hInst = GetModuleHandleW(null);
    HCURSOR arrow = LoadCursorW(null, IDC_ARROW);

    auto clsName = "wsi-f10-class"w;
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
    auto otherCls = "wsi-f10-other-class"w;
    WNDCLASSEXW wc2;
    wc2.cbSize = WNDCLASSEXW.sizeof;
    wc2.lpfnWndProc = &otherWndProc;
    wc2.hInstance = hInst;
    wc2.lpszClassName = otherCls.ptr;
    wc2.hCursor = arrow;
    RegisterClassExW(&wc2);

    HWND hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f10-pointer"w.ptr,
        WS_OVERLAPPEDWINDOW, 100, 100, 480, 320, null, null, hInst, null);
    if (hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    g.hwnd = hwnd;
    logEvent("window_created");

    // The focus-loss probe target, shown without stealing activation.
    g.other = CreateWindowExW(0, otherCls.ptr, "wsi-f10-other"w.ptr,
        WS_OVERLAPPEDWINDOW, 640, 100, 160, 120, null, null, hInst, null);
    ShowWindow(g.other, SW_SHOWNOACTIVATE);

    probeShowCursorCounter();
    logClipReadback("baseline"); // unclipped = the full screen rect
    registerRawMouse(hwnd);

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

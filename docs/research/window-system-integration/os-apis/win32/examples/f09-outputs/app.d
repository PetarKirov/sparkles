// F09 — Output enumeration & hotplug, Win32 implementation
// (../../../features/f09-outputs.md). Extends the scaffold (../scaffold/app.d)
// into a monitor observatory:
//
//   * Enumerates outputs BEFORE any window exists (EnumDisplayMonitors needs
//     only user32, proving enumeration is global), then again after window
//     creation and on every hotplug signal. Per output: GetMonitorInfoW with
//     MONITORINFOEXW (rcMonitor / rcWork / MONITORINFOF_PRIMARY / szDevice),
//     GetDpiForMonitor(MDT_EFFECTIVE_DPI) (shcore, resolved at runtime —
//     druntime predates it), and EnumDisplaySettingsW(ENUM_CURRENT_SETTINGS)
//     for the raw mode (dmPelsWidth/Height, dmBitsPerPel, dmDisplayFrequency,
//     dmPosition).
//   * Occupancy: MonitorFromWindow(MONITOR_DEFAULTTONULL) on WM_MOVE/WM_SIZE,
//     logged as surface_output enter/leave-style transitions (the derivation
//     Win32 forces on apps — no wl_surface.enter equivalent). A scripted
//     off-screen SetWindowPos probes the MONITOR_DEFAULTTONULL vs
//     MONITOR_DEFAULTTONEAREST contract when the window intersects no monitor.
//   * Hotplug: WM_DISPLAYCHANGE / WM_SETTINGCHANGE / WM_DEVICECHANGE are
//     logged (WM_DEVICECHANGE registered for GUID_DEVINTERFACE_MONITOR via
//     RegisterDeviceNotificationW), each triggering a re-enumeration that is
//     diffed by device name into output_added / output_removed. A ~0.5 s
//     poll re-enumerates and diffs too, so a topology change Wine does NOT
//     announce is still caught (via=poll vs via=msg in the log).
//
// WSI_AUTO_EXIT=1 bounds the run (~1.5 s default; WSI_RUN_MS overrides — the
// hotplug hunt uses a longer run while `swaymsg create_output` adds a second
// headless output under winewayland). Exit 0 in all modes.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import core.sys.windows.dbt;
import instrument;

// ---------------------------------------------------------------------------
// GetDpiForMonitor (shcore.dll, Win 8.1+) — absent from druntime; resolved at
// runtime so a missing export is a logged finding, not a loader failure.

enum MDT_EFFECTIVE_DPI = 0;

extern (Windows) alias GetDpiForMonitorT =
    HRESULT function(HMONITOR, int, UINT*, UINT*) nothrow @nogc;
__gshared GetDpiForMonitorT pGetDpiForMonitor;

void loadDpiApi() nothrow
{
    HMODULE shcore = LoadLibraryW("shcore"w.ptr);
    if (shcore !is null)
        pGetDpiForMonitor =
            cast(GetDpiForMonitorT) GetProcAddress(shcore, "GetDpiForMonitor");
    logEvent("api name=GetDpiForMonitor present=%d", pGetDpiForMonitor !is null ? 1 : 0);
}

// GUID_DEVINTERFACE_MONITOR {E6F07B5F-EE97-4a90-B076-33F57BF4EAA7} — the
// device-interface class RegisterDeviceNotificationW filters on.
__gshared GUID monitorInterfaceGuid = GUID(0xE6F07B5F, 0xEE97, 0x4A90,
    [0xB0, 0x76, 0x33, 0xF5, 0x7B, 0xF4, 0xEA, 0xA7]);

// ---------------------------------------------------------------------------
// Output snapshot: enumeration result kept for diffing on hotplug signals.

enum MAX_OUTPUTS = 16;

struct Output
{
    HMONITOR hmon;
    WCHAR[32] device = 0; // szDevice from MONITORINFOEXW (e.g. \\.\DISPLAY1)
    RECT rcMonitor, rcWork;
    RECT rcEnum; // the rect EnumDisplayMonitors itself hands the callback
    bool primary;
    uint dpi; // MDT_EFFECTIVE_DPI (0 = unavailable)
    uint modeW, modeH, bpp, hz; // EnumDisplaySettingsW(ENUM_CURRENT_SETTINGS)
    POINTL pos; // dmPosition (desktop coordinates of the mode)
}

struct Snapshot
{
    Output[MAX_OUTPUTS] outputs;
    int count;
}

extern (Windows) BOOL enumProc(HMONITOR hmon, HDC, LPRECT rc, LPARAM lParam) nothrow
{
    auto snap = cast(Snapshot*) lParam;
    if (snap.count >= MAX_OUTPUTS)
        return TRUE;
    Output* o = &snap.outputs[snap.count];
    o.hmon = hmon;
    if (rc !is null)
        o.rcEnum = *rc;

    MONITORINFOEXW mi;
    mi.cbSize = MONITORINFOEXW.sizeof;
    if (GetMonitorInfoW(hmon, &mi))
    {
        o.rcMonitor = mi.rcMonitor;
        o.rcWork = mi.rcWork;
        o.primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
        o.device = mi.szDevice;
    }
    if (pGetDpiForMonitor !is null)
    {
        UINT dx, dy;
        if (pGetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &dx, &dy) == S_OK)
            o.dpi = dx;
    }
    DEVMODEW dm;
    dm.dmSize = DEVMODEW.sizeof;
    if (EnumDisplaySettingsW(o.device.ptr, ENUM_CURRENT_SETTINGS, &dm))
    {
        o.modeW = dm.dmPelsWidth;
        o.modeH = dm.dmPelsHeight;
        o.bpp = dm.dmBitsPerPel;
        o.hz = dm.dmDisplayFrequency;
        o.pos = dm.dmPosition;
    }
    ++snap.count;
    return TRUE;
}

void enumerate(Snapshot* snap, const(char)* when, bool logEach) nothrow
{
    snap.count = 0;
    EnumDisplayMonitors(null, null, &enumProc, cast(LPARAM) snap);
    if (!logEach)
        return;
    logEvent("enum_pass when=%s count=%d", when, snap.count);
    foreach (i; 0 .. snap.count)
    {
        const o = &snap.outputs[i];
        logEvent("output id=%d device=%ls rect=%dx%d+%d+%d enum_rect=%dx%d+%d+%d "
            ~ "work=%dx%d+%d+%d primary=%d dpi=%u mode=%ux%u bpp=%u hz=%u pos=%d,%d",
            i, o.device.ptr,
            o.rcMonitor.right - o.rcMonitor.left, o.rcMonitor.bottom - o.rcMonitor.top,
            o.rcMonitor.left, o.rcMonitor.top,
            o.rcEnum.right - o.rcEnum.left, o.rcEnum.bottom - o.rcEnum.top,
            o.rcEnum.left, o.rcEnum.top,
            o.rcWork.right - o.rcWork.left, o.rcWork.bottom - o.rcWork.top,
            o.rcWork.left, o.rcWork.top,
            o.primary ? 1 : 0, o.dpi, o.modeW, o.modeH, o.bpp, o.hz,
            o.pos.x, o.pos.y);
    }
}

// Diff two snapshots by device name → output_added / output_removed.
// Returns true if anything changed (device set OR geometry).
bool diffSnapshots(const(Snapshot)* old, const(Snapshot)* now, const(char)* via) nothrow
{
    static bool hasDevice(const(Snapshot)* s, const(WCHAR)* dev) nothrow
    {
        foreach (i; 0 .. s.count)
            if (lstrcmpW(s.outputs[i].device.ptr, dev) == 0)
                return true;
        return false;
    }

    bool changed;
    foreach (i; 0 .. now.count)
        if (!hasDevice(old, now.outputs[i].device.ptr))
        {
            logEvent("output_added device=%ls via=%s", now.outputs[i].device.ptr, via);
            changed = true;
        }
    foreach (i; 0 .. old.count)
        if (!hasDevice(now, old.outputs[i].device.ptr))
        {
            logEvent("output_removed device=%ls via=%s", old.outputs[i].device.ptr, via);
            changed = true;
        }
    if (!changed)
        foreach (i; 0 .. now.count) // same devices — geometry/mode change?
            foreach (j; 0 .. old.count)
                if (lstrcmpW(now.outputs[i].device.ptr, old.outputs[j].device.ptr) == 0
                    && (now.outputs[i].modeW != old.outputs[j].modeW
                        || now.outputs[i].modeH != old.outputs[j].modeH
                        || now.outputs[i].rcMonitor != old.outputs[j].rcMonitor))
                {
                    logEvent("output_changed device=%ls via=%s mode=%ux%u",
                        now.outputs[i].device.ptr, via,
                        now.outputs[i].modeW, now.outputs[i].modeH);
                    changed = true;
                }
    return changed;
}

// ---------------------------------------------------------------------------
// Demo state.

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 16;
enum OFFSCREEN_AT_TICK = 30; // ~0.5 s: off-screen probe
enum RESTORE_AT_TICK = 45; // ~0.7 s: move back on-screen

struct Demo
{
    HDC memDc;
    HBITMAP dib, stockBmp;
    uint* pixels;
    int width, height;
    uint frame, ticks;
    uint runMs = 1500;
    uint nDisplayChange, nSettingChange, nDeviceChange;
    bool autoExit;
    bool firstPaintDone;
    HMONITOR currentMon; // occupancy as last derived
    Snapshot snap; // last enumeration (diff base)
    HDEVNOTIFY devNotify;
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

// Occupancy derivation (F09 req. 2): Win32 has no surface-enters-output event;
// the app re-derives via MonitorFromWindow whenever its geometry changes.
void trackOccupancy(HWND hwnd, const(char)* why) nothrow
{
    HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL);
    if (mon is g.currentMon)
        return;
    if (g.currentMon !is null)
        logEvent("surface_output leave hmon=%p", g.currentMon);
    g.currentMon = mon;
    if (mon is null)
    {
        logEvent("surface_output none why=%s", why);
        return;
    }
    MONITORINFOEXW mi;
    mi.cbSize = MONITORINFOEXW.sizeof;
    GetMonitorInfoW(mon, &mi);
    RECT wr;
    GetWindowRect(hwnd, &wr);
    logEvent("surface_output enter device=%ls why=%s window=%dx%d+%d+%d",
        mi.szDevice.ptr, why, wr.right - wr.left, wr.bottom - wr.top, wr.left, wr.top);
}

// The MONITOR_DEFAULTTONULL vs MONITOR_DEFAULTTONEAREST contract, probed with
// the window parked at +20000+20000 (intersecting no monitor).
void offscreenProbe(HWND hwnd) nothrow
{
    HMONITOR nullMon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL);
    HMONITOR nearMon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    HMONITOR priMon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFOEXW mi;
    mi.cbSize = MONITORINFOEXW.sizeof;
    if (nearMon !is null)
        GetMonitorInfoW(nearMon, &mi);
    logEvent("offscreen_probe defaulttonull=%p defaulttonearest=%ls same_as_primary=%d",
        nullMon, nearMon !is null ? mi.szDevice.ptr : "none"w.ptr,
        nearMon is priMon ? 1 : 0);
}

void reEnumerate(HWND hwnd, const(char)* via) nothrow
{
    Snapshot now;
    enumerate(&now, via, false);
    if (diffSnapshots(&g.snap, &now, via))
    {
        g.snap = now;
        enumerate(&g.snap, via, true); // log the new full state
        g.currentMon = null; // HMONITORs may be stale — re-derive occupancy
        trackOccupancy(hwnd, via);
    }
    else
        g.snap = now; // keep hmonitor handles fresh; nothing to report
}

// ---------------------------------------------------------------------------

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_CREATE:
        g.memDc = CreateCompatibleDC(null);
        return 0;

    case WM_DISPLAYCHANGE:
        // "sent to all windows when the display resolution has changed";
        // wParam = new bit depth, lParam = new primary resolution.
        ++g.nDisplayChange;
        logEvent("msg name=WM_DISPLAYCHANGE bpp=%u res=%ux%u",
            cast(uint) wParam, cast(uint)(lParam & 0xffff),
            cast(uint)((lParam >> 16) & 0xffff));
        reEnumerate(hwnd, "WM_DISPLAYCHANGE");
        return 0;

    case WM_SETTINGCHANGE:
        ++g.nSettingChange;
        logEvent("msg name=WM_SETTINGCHANGE wparam=%u area=%ls",
            cast(uint) wParam, lParam ? cast(const(wchar)*) lParam : ""w.ptr);
        return 0;

    case WM_DEVICECHANGE:
        ++g.nDeviceChange;
        logEvent("msg name=WM_DEVICECHANGE event=0x%x", cast(uint) wParam);
        if (wParam == DBT_DEVICEARRIVAL || wParam == DBT_DEVICEREMOVECOMPLETE
            || wParam == DBT_DEVNODES_CHANGED)
            reEnumerate(hwnd, "WM_DEVICECHANGE");
        return TRUE;

    case WM_MOVE:
        trackOccupancy(hwnd, "WM_MOVE");
        return 0;

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        if (wParam == SIZE_MINIMIZED)
            return 0;
        if (w != g.width || h != g.height)
            createBackbuffer(w, h);
        trackOccupancy(hwnd, "WM_SIZE");
        return 0;

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        ++g.frame;
        drawGradient();
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
        if (g.ticks % 31 == 0) // ~0.5 s topology poll (catches silent changes)
            reEnumerate(hwnd, "poll");
        if (g.autoExit)
        {
            if (g.ticks == OFFSCREEN_AT_TICK)
            {
                logEvent("step name=SetWindowPos offscreen=1 pos=20000,20000");
                SetWindowPos(hwnd, null, 20000, 20000, 0, 0,
                    SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                offscreenProbe(hwnd);
            }
            else if (g.ticks == RESTORE_AT_TICK)
            {
                logEvent("step name=SetWindowPos offscreen=0 pos=80,80");
                SetWindowPos(hwnd, null, 80, 80, 0, 0,
                    SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            }
            if (g.ticks * TICK_MS >= g.runMs)
                DestroyWindow(hwnd);
        }
        return 0;

    case WM_CLOSE:
        logEvent("close_requested");
        goto default;

    case WM_DESTROY:
        KillTimer(hwnd, TIMER_ID);
        if (g.devNotify !is null)
            UnregisterDeviceNotification(g.devNotify);
        createBackbuffer(0, 0);
        if (g.memDc !is null)
        {
            DeleteDC(g.memDc);
            g.memDc = null;
        }
        logEvent("summary displaychange=%u settingchange=%u devicechange=%u outputs=%d",
            g.nDisplayChange, g.nSettingChange, g.nDeviceChange, g.snap.count);
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

int main()
{
    instrumentInit("f09_outputs_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    g.runMs = envUint("WSI_RUN_MS"w.ptr, 1500);
    logEvent("mode auto_exit=%d run_ms=%u", g.autoExit ? 1 : 0, g.runMs);

    loadDpiApi();

    // F09 finding "does enumeration require a window?": this pass runs before
    // RegisterClassExW — only user32 (and its session connection) is needed.
    enumerate(&g.snap, "pre_window", true);

    HINSTANCE hInst = GetModuleHandleW(null);
    auto clsName = "wsi-f09-class"w;
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
    HWND hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f09-outputs"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, hInst, null);
    if (hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");

    // Hotplug signal #3: WM_DEVICECHANGE only carries device-interface events
    // if the window registers for the interface class (monitors here).
    DEV_BROADCAST_DEVICEINTERFACE_W filter;
    filter.dbcc_size = DEV_BROADCAST_DEVICEINTERFACE_W.sizeof;
    filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    filter.dbcc_classguid = monitorInterfaceGuid;
    g.devNotify = RegisterDeviceNotificationW(hwnd, &filter, DEVICE_NOTIFY_WINDOW_HANDLE);
    logEvent("step name=RegisterDeviceNotificationW handle=%p err=%lu",
        g.devNotify, g.devNotify is null ? GetLastError() : 0);

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

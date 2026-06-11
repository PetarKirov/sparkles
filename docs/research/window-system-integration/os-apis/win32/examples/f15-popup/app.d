// F15 — Popup with grab, Win32 implementation
// (../../../features/f15-popup.md). Extends the scaffold (../scaffold/app.d)
// with the capture-variant context menu the spec asks for:
//
//   * Right-click on the main window opens a WS_POPUP + WS_EX_NOACTIVATE +
//     WS_EX_TOPMOST menu window (3 items, hover highlight) at the pointer,
//     then takes SetCapture on it — Win32's "grab": all MOUSE input is routed
//     to the capture window (in its client coords, which go negative outside
//     it). Keyboard input is NOT captured — it follows focus, which
//     WS_EX_NOACTIVATE deliberately leaves on the main window, so Esc arrives
//     as the main window's WM_KEYDOWN.
//   * Outside-click dismissal = capture-routed WM_LBUTTONDOWN whose screen
//     coords hit-test outside the popup chain. Hit-testing is done in SCREEN
//     coordinates against the app-known chain rects (popup + submenu) — the
//     one-capture-owner + hit-test pattern.
//   * Placement is pure app math (no positioner object exists): anchor at the
//     click, flip-x/flip-y against the monitor work area
//     (MonitorFromPoint/GetMonitorInfoW) when the menu would overflow —
//     every term of the computation is logged (popup_place …).
//   * Submenu: hovering the last item opens a second WS_POPUP and the demo
//     deliberately moves capture to it (SetCapture(sub)) to MEASURE the
//     capture-is-single-window problem: the parent popup receives
//     WM_CAPTURECHANGED naming the thief; naive "capture lost => dismiss"
//     code would close the whole menu, so WM_CAPTURECHANGED must be filtered
//     through chain knowledge. Closing the submenu hands capture back.
//   * A theft probe (SetCapture by the main window while the menu is open)
//     shows the real fragility: any SetCapture anywhere in the session kills
//     the grab silently — the popup just gets WM_CAPTURECHANGED, logged and
//     treated as dismissal (cause=capture_lost).
//   * TrackPopupMenu probe: the system escape hatch is called once with
//     TPM_RETURNCMD; WM_ENTERMENULOOP/WM_EXITMENULOOP and its blocking
//     duration are logged. A pre-armed SetTimer fires INSIDE its modal loop
//     (the same dispatch-from-modal-loop fact as F03) and EndMenu() ends it.
//
// WSI_AUTO_EXIT=1 drives everything with real injected input (SetCursorPos
// moves + SendInput button/key events): open, hover, item click, outside
// click, Esc, edge-anchored reposition, submenu chain, capture theft,
// TrackPopupMenu — then exits 0. Without it: right-click to open, interact.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

enum UINT_PTR TIMER_ID = 1;
enum UINT_PTR MENU_TIMER_ID = 2;
enum TICK_MS = 16;
enum TICKS_PER_PHASE = 20; // ~320 ms between scripted phases

enum ITEM_W = 160;
enum ITEM_H = 24;
enum N_ITEMS = 3;
enum MENU_H = ITEM_H * N_ITEMS;

struct Menu
{
    HWND hwnd;
    RECT rect; // screen coords
}

struct Demo
{
    HDC memDc;
    HBITMAP dib, stockBmp;
    uint* pixels;
    int width, height;
    uint frame, ticks;
    bool autoExit;
    int phase;
    HWND hwndMain;
    Menu[2] menus; // [0] = popup, [1] = submenu
    int nOpen; // 0, 1 or 2
    int hoverMenu = -1, hoverItem = -1;
    bool swallowNextUp; // the opening right-click's release
    bool inMenuLoop; // inside TrackPopupMenu (pause the phase driver)
    long menuLoopT0; // TrackPopupMenu entry timestamp
}

__gshared Demo g;

// ---------------------------------------------------------------------------
// Main-window backbuffer (scaffold-identical, trimmed).

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

// ---------------------------------------------------------------------------
// Popup placement: the app IS the positioner on Win32. Anchor at the pointer,
// gravity bottom-right; flip when the work area would be overflowed.

RECT placeMenu(int ax, int ay) nothrow
{
    POINT p = POINT(ax, ay);
    MONITORINFO mi;
    mi.cbSize = MONITORINFO.sizeof;
    GetMonitorInfoW(MonitorFromPoint(p, MONITOR_DEFAULTTOPRIMARY), &mi);
    const wa = mi.rcWork;
    int x = ax, y = ay;
    const(char)* adjX = "none", adjY = "none";
    if (x + ITEM_W > wa.right)
    {
        x = ax - ITEM_W; // flip: open leftwards
        adjX = "flip-x";
        if (x < wa.left)
        {
            x = wa.right - ITEM_W; // slide as last resort
            adjX = "slide-x";
        }
    }
    if (y + MENU_H > wa.bottom)
    {
        y = ay - MENU_H;
        adjY = "flip-y";
        if (y < wa.top)
        {
            y = wa.bottom - MENU_H;
            adjY = "slide-y";
        }
    }
    logEvent("popup_place anchor=%d,%d gravity=bottom-right size=%dx%d work=%ld,%ld-%ldx%ld final=%d,%d adjust=%s,%s",
        ax, ay, ITEM_W, MENU_H, wa.left, wa.top, wa.right - wa.left,
        wa.bottom - wa.top, x, y, adjX, adjY);
    return RECT(x, y, x + ITEM_W, y + MENU_H);
}

// ---------------------------------------------------------------------------
// Chain hit-testing in screen coordinates.

// Returns menu index (0/1) or -1; item receives the row index or -1.
int hitTest(POINT s, out int item) nothrow
{
    item = -1;
    foreach_reverse (i; 0 .. g.nOpen) // submenu is on top
    {
        const r = g.menus[i].rect;
        if (s.x >= r.left && s.x < r.right && s.y >= r.top && s.y < r.bottom)
        {
            item = cast(int)((s.y - r.top) / ITEM_H);
            return cast(int) i;
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Menu windows.

immutable wchar*[N_ITEMS][2] itemLabels = [
    ["Alpha"w.ptr, "Beta"w.ptr, "Gamma  ▸"w.ptr],
    ["Sub-1"w.ptr, "Sub-2"w.ptr, "Sub-3"w.ptr],
];

void openMenu(int idx, int ax, int ay, const(char)* cause) nothrow
{
    logEvent("popup_open menu=%d anchor=%d,%d cause=%s", idx, ax, ay, cause);
    const r = placeMenu(ax, ay);
    HWND hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE,
        "wsi-f15-menu"w.ptr, null, WS_POPUP | WS_BORDER,
        r.left, r.top, ITEM_W, MENU_H, g.hwndMain, null,
        GetModuleHandleW(null), null);
    g.menus[idx].hwnd = hwnd;
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    GetWindowRect(hwnd, &g.menus[idx].rect); // authoritative placement
    const rr = g.menus[idx].rect;
    logEvent("popup_placed menu=%d rect=%ld,%ld-%ldx%ld", idx, rr.left, rr.top,
        rr.right - rr.left, rr.bottom - rr.top);
    g.nOpen = idx + 1;
    // The grab: route all mouse input to this menu window. Capture is a
    // single per-queue slot — taking it for the submenu STEALS it from the
    // parent popup (measured via the parent's WM_CAPTURECHANGED).
    HWND prev = SetCapture(hwnd);
    logEvent("grab state=acquired menu=%d owner=%p prev=%p readback=%p",
        idx, hwnd, prev, GetCapture());
}

void closeSubmenu(const(char)* cause) nothrow
{
    if (g.nOpen < 2)
        return;
    logEvent("popup_dismiss menu=1 cause=%s", cause);
    HWND h = g.menus[1].hwnd;
    g.menus[1].hwnd = null;
    g.nOpen = 1;
    SetCapture(g.menus[0].hwnd); // hand the grab back to the parent
    logEvent("grab state=returned_to_parent owner=%p", GetCapture());
    DestroyWindow(h);
}

void dismissChain(const(char)* cause) nothrow
{
    if (g.nOpen == 0)
        return;
    logEvent("popup_dismiss cause=%s open=%d", cause, g.nOpen);
    // Destroy top-down; release capture first so the destroys do not generate
    // misleading WM_CAPTURECHANGED noise (one is sent anyway on ReleaseCapture).
    g.nOpen = 0;
    g.hoverMenu = g.hoverItem = -1;
    ReleaseCapture();
    foreach_reverse (i; 0 .. 2)
        if (g.menus[i].hwnd !is null)
        {
            DestroyWindow(g.menus[i].hwnd);
            g.menus[i].hwnd = null;
        }
    logEvent("grab state=released readback=%p", GetCapture());
}

int menuIndexOf(HWND hwnd) nothrow @nogc
{
    if (hwnd is null)
        return -1;
    foreach (i; 0 .. 2)
        if (g.menus[i].hwnd is hwnd)
            return cast(int) i;
    return -1;
}

// ---------------------------------------------------------------------------
// Menu WndProc: paint + capture-routed mouse handling.

extern (Windows) LRESULT menuProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    const self = menuIndexOf(hwnd);
    switch (msg)
    {
    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        HBRUSH normal = CreateSolidBrush(RGB(232, 232, 232));
        HBRUSH hot = CreateSolidBrush(RGB(60, 120, 216));
        SetBkMode(hdc, TRANSPARENT);
        foreach (i; 0 .. N_ITEMS)
        {
            RECT r = RECT(0, i * ITEM_H, ITEM_W, (i + 1) * ITEM_H);
            const isHot = self == g.hoverMenu && i == g.hoverItem;
            FillRect(hdc, &r, isHot ? hot : normal);
            SetTextColor(hdc, isHot ? RGB(255, 255, 255) : RGB(20, 20, 20));
            r.left += 8;
            if (self >= 0)
                DrawTextW(hdc, itemLabels[self][i], -1, &r,
                    DT_SINGLELINE | DT_VCENTER | DT_LEFT);
        }
        DeleteObject(normal);
        DeleteObject(hot);
        EndPaint(hwnd, &ps);
        return 0;

    case WM_MOUSEMOVE:
        // Capture-routed: coords are THIS window's client coords, possibly
        // negative / beyond its size. Convert to screen and chain-hit-test.
        POINT s = POINT(cast(short)(lParam & 0xffff), cast(short)((lParam >> 16) & 0xffff));
        ClientToScreen(hwnd, &s);
        int item;
        const m = hitTest(s, item);
        if (m != g.hoverMenu || item != g.hoverItem)
        {
            g.hoverMenu = m;
            g.hoverItem = item;
            logEvent("hover menu=%d item=%d screen=%ld,%ld routed_to=%d", m, item, s.x, s.y, self);
            foreach (i; 0 .. g.nOpen)
                InvalidateRect(g.menus[i].hwnd, null, FALSE);
            // Submenu opens on hovering the parent's last item, closes when
            // the hover returns to a different parent item.
            if (m == 0 && item == N_ITEMS - 1 && g.nOpen == 1)
            {
                const pr = g.menus[0].rect;
                openMenu(1, pr.right, pr.top + (N_ITEMS - 1) * ITEM_H, "submenu_hover");
            }
            else if (m == 0 && item != N_ITEMS - 1 && g.nOpen == 2)
                closeSubmenu("parent_hover");
        }
        return 0;

    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
        POINT sc = POINT(cast(short)(lParam & 0xffff), cast(short)((lParam >> 16) & 0xffff));
        ClientToScreen(hwnd, &sc);
        int it;
        const mh = hitTest(sc, it);
        if (mh < 0)
        {
            logEvent("button state=down screen=%ld,%ld routed_to=%d hit=outside", sc.x, sc.y, self);
            dismissChain("outside_click");
        }
        else
        {
            logEvent("button state=down screen=%ld,%ld routed_to=%d hit=menu%d_item%d",
                sc.x, sc.y, self, mh, it);
            if (!(mh == 0 && it == N_ITEMS - 1)) // submenu anchor item only hovers
            {
                logEvent("item_activated menu=%d item=%d", mh, it);
                dismissChain("item_activated");
            }
        }
        return 0;

    case WM_RBUTTONUP:
    case WM_LBUTTONUP:
        if (g.swallowNextUp)
        {
            // The release of the click that OPENED the menu arrives capture-
            // routed; activating an item from it would be wrong.
            g.swallowNextUp = false;
            logEvent("button state=release swallowed=open_click");
        }
        return 0;

    case WM_CAPTURECHANGED:
        // lParam = the window that NOW has capture. Sent to the previous
        // owner whenever anyone calls SetCapture/ReleaseCapture — this is the
        // single-slot fragility. Filter through chain knowledge.
        HWND thief = cast(HWND) lParam;
        const thiefIdx = menuIndexOf(thief);
        logEvent("msg name=WM_CAPTURECHANGED menu=%d new_owner=%p chain_member=%d",
            self, thief, thiefIdx);
        if (thiefIdx < 0 && self == 0 && g.nOpen > 0)
        {
            // Someone outside the menu chain took (or released) capture:
            // the grab is gone and we cannot see outside clicks any more.
            dismissChain("capture_lost");
        }
        return 0;

    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE; // belt & braces with WS_EX_NOACTIVATE

    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

// ---------------------------------------------------------------------------
// Input injection (auto mode): real cursor warps + real button/key events, so
// the capture routing is exercised, not simulated.

void warpTo(int x, int y) nothrow
{
    SetCursorPos(x, y);
    logEvent("inject method=SetCursorPos screen=%d,%d", x, y);
}

void click(DWORD downFlag, DWORD upFlag, const(char)* name) nothrow
{
    INPUT[2] inp;
    inp[0].type = INPUT_MOUSE;
    inp[0].mi.dwFlags = downFlag;
    inp[1].type = INPUT_MOUSE;
    inp[1].mi.dwFlags = upFlag;
    const n = SendInput(2, inp.ptr, INPUT.sizeof);
    logEvent("inject method=SendInput kind=%s sent=%u", name, n);
}

void pressEsc() nothrow
{
    INPUT[2] inp;
    inp[0].type = INPUT_KEYBOARD;
    inp[0].ki.wVk = VK_ESCAPE;
    inp[1].type = INPUT_KEYBOARD;
    inp[1].ki.wVk = VK_ESCAPE;
    inp[1].ki.dwFlags = KEYEVENTF_KEYUP;
    const n = SendInput(2, inp.ptr, INPUT.sizeof);
    logEvent("inject method=SendInput kind=esc sent=%u", n);
}

POINT mainCenter() nothrow
{
    POINT p = POINT(g.width / 2, g.height / 2);
    ClientToScreen(g.hwndMain, &p);
    return p;
}

POINT itemCenter(int menu, int item) nothrow @nogc
{
    const r = g.menus[menu].rect;
    return POINT(r.left + ITEM_W / 2, r.top + item * ITEM_H + ITEM_H / 2);
}

// ---------------------------------------------------------------------------
// TrackPopupMenu probe — the system escape hatch, measured.

void probeTrackPopupMenu() nothrow
{
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, 101, "Sys-Alpha"w.ptr);
    AppendMenuW(menu, MF_STRING, 102, "Sys-Beta"w.ptr);
    AppendMenuW(menu, MF_STRING, 103, "Sys-Gamma"w.ptr);
    const p = mainCenter();
    // The pre-armed timer fires INSIDE TrackPopupMenu's modal loop (same
    // dispatch behavior as the F03 size/move loop) and calls EndMenu().
    SetTimer(g.hwndMain, MENU_TIMER_ID, 400, null);
    g.menuLoopT0 = nowUs();
    g.inMenuLoop = true;
    logEvent("trackpopupmenu state=calling pos=%ld,%ld", p.x, p.y);
    const r = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN,
        p.x, p.y, 0, g.hwndMain, null);
    g.inMenuLoop = false;
    logEvent("trackpopupmenu state=returned cmd=%d blocked_us=%lld err=%lu",
        cast(int) r, nowUs() - g.menuLoopT0, GetLastError());
    KillTimer(g.hwndMain, MENU_TIMER_ID);
    DestroyMenu(menu);
}

// ---------------------------------------------------------------------------
// Scripted tour.

void runPhase(int n) nothrow
{
    POINT c = mainCenter();
    switch (n)
    {
    case 0: // open at center via a real right-click
        warpTo(c.x, c.y);
        break;
    case 1:
        click(MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, "right_click");
        break;
    case 2: // hover item 0, then 1
        if (g.nOpen > 0)
        {
            const p = itemCenter(0, 0);
            warpTo(p.x, p.y);
        }
        break;
    case 3:
        if (g.nOpen > 0)
        {
            const p = itemCenter(0, 1);
            warpTo(p.x, p.y);
        }
        break;
    case 4: // activate item 1
        click(MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, "left_click");
        break;
    case 5: // reopen
        warpTo(c.x, c.y);
        click(MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, "right_click");
        break;
    case 6: // outside click (top-left of the main client, away from the menu)
        POINT o = POINT(8, 8);
        ClientToScreen(g.hwndMain, &o);
        warpTo(o.x, o.y);
        break;
    case 7:
        click(MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, "left_click");
        break;
    case 8: // reopen, dismiss via Esc (keyboard follows FOCUS, not capture)
        warpTo(c.x, c.y);
        click(MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, "right_click");
        break;
    case 9:
        logEvent("focus_probe focus=%p main=%p (keyboard goes to focus, not capture)",
            GetFocus(), g.hwndMain);
        pressEsc();
        break;
    case 10: // edge probe: anchor at the work-area bottom-right corner
        MONITORINFO mi;
        mi.cbSize = MONITORINFO.sizeof;
        GetMonitorInfoW(MonitorFromWindow(g.hwndMain, MONITOR_DEFAULTTOPRIMARY), &mi);
        g.swallowNextUp = false;
        openMenu(0, mi.rcWork.right - 4, mi.rcWork.bottom - 4, "edge_probe");
        break;
    case 11:
        // May the popup exceed the output bounds at all? Move it half off
        // the bottom-right corner and read the rect back (no WM/compositor
        // veto expected on Win32 — measured, not assumed).
        if (g.nOpen > 0)
        {
            MONITORINFO mi2;
            mi2.cbSize = MONITORINFO.sizeof;
            GetMonitorInfoW(MonitorFromWindow(g.hwndMain, MONITOR_DEFAULTTOPRIMARY), &mi2);
            const want = POINT(mi2.rcMonitor.right - ITEM_W / 2,
                mi2.rcMonitor.bottom - MENU_H / 2);
            SetWindowPos(g.menus[0].hwnd, null, want.x, want.y, 0, 0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            RECT rb;
            GetWindowRect(g.menus[0].hwnd, &rb);
            g.menus[0].rect = rb;
            logEvent("offscreen_probe requested=%ld,%ld readback=%ld,%ld-%ldx%ld monitor_br=%ld,%ld",
                want.x, want.y, rb.left, rb.top, rb.right - rb.left,
                rb.bottom - rb.top, mi2.rcMonitor.right, mi2.rcMonitor.bottom);
        }
        pressEsc();
        break;
    case 12: // reopen; walk to the submenu anchor item
        warpTo(c.x, c.y);
        click(MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, "right_click");
        break;
    case 13:
        if (g.nOpen > 0)
        {
            const p = itemCenter(0, N_ITEMS - 1); // opens the submenu
            warpTo(p.x, p.y);
        }
        break;
    case 14:
        if (g.nOpen > 1)
        {
            const p = itemCenter(1, 1); // hover Sub-2
            warpTo(p.x, p.y);
        }
        break;
    case 15:
        click(MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, "left_click");
        break;
    case 16: // capture-theft probe
        warpTo(c.x, c.y);
        click(MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, "right_click");
        break;
    case 17:
        if (g.nOpen > 0)
        {
            logEvent("capture_theft_probe api=SetCapture(main)");
            SetCapture(g.hwndMain); // any window may steal — silently
            ReleaseCapture();
        }
        break;
    case 18:
        probeTrackPopupMenu();
        break;
    case 19:
        DestroyWindow(g.hwndMain);
        break;
    default:
        break;
    }
}

// ---------------------------------------------------------------------------
// Main WndProc.

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
        if (wParam != SIZE_MINIMIZED && (w != g.width || h != g.height))
            createBackbuffer(w, h);
        return 0;

    case WM_RBUTTONDOWN:
        // Open the menu at the pointer (screen coords).
        POINT p = POINT(cast(short)(lParam & 0xffff), cast(short)((lParam >> 16) & 0xffff));
        ClientToScreen(hwnd, &p);
        if (g.nOpen == 0)
        {
            g.swallowNextUp = true; // the matching button-up is capture-routed
            openMenu(0, p.x, p.y, "right_click");
        }
        return 0;

    case WM_KEYDOWN:
        if (wParam == VK_ESCAPE && g.nOpen > 0)
        {
            logEvent("key vk=VK_ESCAPE routed_to=main_focus_window");
            dismissChain("esc");
        }
        return 0;

    case WM_ACTIVATE:
        logEvent("focus state=%s reason=WM_ACTIVATE other=%p",
            LOWORD(wParam) == WA_INACTIVE ? "out".ptr : "in".ptr, cast(void*) lParam);
        goto default;

    case WM_KILLFOCUS:
        logEvent("focus state=out reason=WM_KILLFOCUS next=%p", cast(void*) wParam);
        return 0;

    case WM_SETFOCUS:
        logEvent("focus state=in reason=WM_SETFOCUS prev=%p", cast(void*) wParam);
        return 0;

    case WM_CAPTURECHANGED:
        logEvent("msg name=WM_CAPTURECHANGED menu=main new_owner=%p", cast(void*) lParam);
        return 0;

    case WM_ENTERMENULOOP:
        logEvent("msg name=WM_ENTERMENULOOP track=%d dt_us=%lld",
            cast(int) wParam, nowUs() - g.menuLoopT0);
        return 0;

    case WM_EXITMENULOOP:
        logEvent("msg name=WM_EXITMENULOOP track=%d dt_us=%lld",
            cast(int) wParam, nowUs() - g.menuLoopT0);
        return 0;

    case WM_INITMENUPOPUP:
        logEvent("msg name=WM_INITMENUPOPUP menu=%p", cast(void*) wParam);
        goto default;

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

    case WM_TIMER:
        if (wParam == MENU_TIMER_ID)
        {
            // Fires inside TrackPopupMenu's modal loop — proof + exit lever.
            logEvent("timer id=menu inside_menu_loop dt_us=%lld", nowUs() - g.menuLoopT0);
            EndMenu();
            return 0;
        }
        if (wParam != TIMER_ID)
            return 0;
        ++g.ticks;
        InvalidateRect(hwnd, null, FALSE);
        // Regular ticks are dispatched inside TrackPopupMenu's modal loop
        // too — pause the phase driver there so only the MENU_TIMER acts.
        if (g.autoExit && !g.inMenuLoop && g.ticks % TICKS_PER_PHASE == 0)
            runPhase(g.phase++);
        return 0;

    case WM_DESTROY:
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
    instrumentInit("f15_popup_win32");
    logEvent("init_start");
    g.autoExit = wantAutoExit();
    logEvent("mode auto_exit=%d", g.autoExit ? 1 : 0);

    HINSTANCE hInst = GetModuleHandleW(null);
    HCURSOR arrow = LoadCursorW(null, IDC_ARROW);

    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = "wsi-f15-class"w.ptr;
    wc.hCursor = arrow;
    if (!RegisterClassExW(&wc))
        return 1;

    WNDCLASSEXW mc;
    mc.cbSize = WNDCLASSEXW.sizeof;
    mc.lpfnWndProc = &menuProc;
    mc.hInstance = hInst;
    mc.lpszClassName = "wsi-f15-menu"w.ptr;
    mc.hCursor = arrow;
    if (!RegisterClassExW(&mc))
        return 1;

    g.hwndMain = CreateWindowExW(0, "wsi-f15-class"w.ptr, "wsi-f15-popup"w.ptr,
        WS_OVERLAPPEDWINDOW, 60, 40, 480, 320, null, null, hInst, null);
    if (g.hwndMain is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created hwnd=%p", g.hwndMain);
    ShowWindow(g.hwndMain, SW_SHOW);
    UpdateWindow(g.hwndMain);
    SetTimer(g.hwndMain, TIMER_ID, TICK_MS, null);

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    logEvent("exit code=%d", cast(int) msg.wParam);
    return cast(int) msg.wParam;
}

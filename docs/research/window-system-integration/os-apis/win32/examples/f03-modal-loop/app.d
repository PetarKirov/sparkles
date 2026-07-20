// F03 — modal-loop survival, Win32 (../../f03-modal-loop.md).
//
// Implements the Win32 headline of ../../../features/f03-modal-loop.md on top
// of the scaffold (../scaffold/app.d):
//
//   * A ~2 Hz full-window color-cycle animation. Crucially, the animation is
//     driven from the *main loop body* (PeekMessage drain -> tick -> bounded
//     MsgWaitForMultipleObjects wait), the way a game/UI loop renders — NOT
//     from a SetTimer. That is exactly the shape the Win32 modal size/move
//     loop starves: once DefWindowProcW enters its nested pump, the app's own
//     loop body stops running and the animation freezes.
//   * WSI_AUTO_EXIT=1 enters the modal loop *programmatically*, three ways in
//     sequence, each bracketed by WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE
//     ("modal_enter"/"modal_exit"):
//       1. SendMessage(WM_SYSCOMMAND, SC_SIZE | WMSZ_BOTTOMRIGHT) — the
//          mouse-grab sizing variant custom-chrome apps use from
//          WM_NCLBUTTONDOWN (the loop expects the button to be held);
//       2. SendMessage(WM_SYSCOMMAND, SC_SIZE) — keyboard-mode sizing
//          ("Size" from the system menu; waits for arrow keys);
//       3. SendMessage(WM_SYSCOMMAND, SC_MOVE) — keyboard-mode move.
//     Because no human is present, a watchdog thread feeds each loop with
//     synthetic input via PostMessage (a WM_MOUSEMOVE, arrow-key WM_KEYDOWNs
//     that really size/move the window, then VK_RETURN to confirm) and
//     escalates to VK_ESCAPE -> WM_CANCELMODE -> WM_CLOSE if the loop refuses
//     to exit, so the freeze-measurement window is always bounded.
//   * WSI_MODAL_FIX=1 arms the survey-wide countermeasure: SetTimer on
//     WM_ENTERSIZEMOVE, render a tick from each WM_TIMER (the modal loop's
//     internal pump DOES dispatch timers), KillTimer on WM_EXITSIZEMOVE.
//     Ticks then continue *inside* the modal loop (src=timer).
//   * Every tick logs `tick t=... src=loop|timer`; inter-tick gaps are
//     tracked globally and per modal window, and each modal window emits a
//     `modal_summary ... max_gap_us=` line measuring the freeze (no-fix) or
//     its absence (fix).
//
// Without WSI_AUTO_EXIT the demo runs until closed — grab a border or the
// titlebar and watch the ticks (the Tier C interactive script on Windows).
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.atomic : atomicLoad, atomicStore;
import core.sys.windows.windows;
import instrument;

struct Demo
{
    HDC memDc; // memory DC the DIB section is selected into
    HBITMAP dib; // top-down 32-bit DIB section (CPU-visible backbuffer)
    HBITMAP stockBmp; // the 1x1 stock bitmap displaced by SelectObject
    uint* pixels; // DIB bits: 0x00RRGGBB, row-major, row 0 = top row
    int width, height; // current client size, physical pixels
    uint color; // current animation color (solid fill)
    uint tickCount; // animation ticks so far
    long lastTickUs; // timestamp of the previous tick
    long maxGapUs; // worst inter-tick gap over the whole run
    bool modalFix; // WSI_MODAL_FIX=1: SetTimer countermeasure armed
    bool autoExit; // WSI_AUTO_EXIT=1: bounded run with programmatic modal entry
    bool firstPaintDone;
    // Current modal window (the attempts run strictly one at a time).
    const(char)* curName; // attempt name for the log lines
    long curEnterUs, curExitUs;
    long curMaxGapUs; // worst tick gap from last pre-enter tick to first post-exit tick
    uint curTicks; // ticks observed while inside the modal loop
    uint curSizing, curMoving; // WM_SIZING / WM_MOVING seen inside the loop
    bool bridgePending; // modal exited; next tick closes the measurement
    bool everEntered; // WM_ENTERSIZEMOVE seen for the current attempt
}

__gshared Demo g;
__gshared HWND g_hwnd;
shared bool s_inModal; // read by the watchdog thread
shared bool s_attemptOver; // the SendMessage returned; watchdog exits early

enum UINT_PTR MODAL_TIMER_ID = 2; // the WM_ENTERSIZEMOVE countermeasure timer
enum TICK_MS = 16; // ~60 Hz animation tick (loop body and modal timer alike)
enum CYCLE_US = 500_000; // 2 Hz: one full hue cycle every 500 ms
enum WARMUP_TICKS = 30; // ~0.5 s of animation before/between modal attempts

// WMSZ_* direction nibble ORed onto SC_SIZE (winuser.h; absent from druntime).
enum WMSZ_BOTTOMRIGHT = 8;

// ---------------------------------------------------------------------------
// Backbuffer: a DIB section reallocated on every client-size change
// (same strategy as the scaffold; the arrow-key sizing resizes mid-loop).

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

// ~2 Hz full-saturation hue cycle: any >=1-frame freeze is a visible color
// jump, and the per-tick log line is the measurable counterpart.
uint colorAt(long tUs) nothrow @nogc
{
    const phase = cast(double)(tUs % CYCLE_US) / CYCLE_US;
    const h = phase * 6.0;
    const sector = cast(int) h % 6;
    const f = h - sector;
    const down = cast(uint)(255.0 * (1.0 - f));
    const up = cast(uint)(255.0 * f);
    uint rgb(uint r, uint gr, uint b) @nogc nothrow
    {
        return (r << 16) | (gr << 8) | b;
    }

    switch (sector)
    {
    case 0:
        return rgb(255, up, 0);
    case 1:
        return rgb(down, 255, 0);
    case 2:
        return rgb(0, 255, up);
    case 3:
        return rgb(0, down, 255);
    case 4:
        return rgb(up, 0, 255);
    default:
        return rgb(255, 0, down);
    }
}

void fillSolid(uint color) nothrow
{
    if (g.pixels is null)
        return;
    const n = cast(size_t) g.width * g.height;
    foreach (i; 0 .. n)
        g.pixels[i] = color;
}

// ---------------------------------------------------------------------------
// The animation tick: advance the color, log, account the inter-tick gap, and
// present synchronously. Called from the main loop body (src=loop) and — only
// while the modal loop holds the thread, in fix mode — from WM_TIMER
// (src=timer).

void tick(const(char)* src) nothrow
{
    const t = nowUs();
    if (g.tickCount > 0)
    {
        const gap = t - g.lastTickUs;
        if (gap > g.maxGapUs)
            g.maxGapUs = gap;
        if (atomicLoad(s_inModal))
        {
            if (gap > g.curMaxGapUs)
                g.curMaxGapUs = gap;
            ++g.curTicks;
        }
        else if (g.bridgePending)
        {
            // First tick after WM_EXITSIZEMOVE: the bridge gap (last tick
            // before/inside the loop -> this tick) completes the measurement.
            if (gap > g.curMaxGapUs)
                g.curMaxGapUs = gap;
            g.bridgePending = false;
            logEvent("modal_summary name=%s dur_us=%lld ticks_during=%u "
                    ~ "max_gap_us=%lld sizing=%u moving=%u",
                g.curName, g.curExitUs - g.curEnterUs, g.curTicks,
                g.curMaxGapUs, g.curSizing, g.curMoving);
        }
    }
    g.lastTickUs = t;
    ++g.tickCount;
    g.color = colorAt(t);
    logEvent("tick t=%lld src=%s frame=%u", t, src, g.tickCount);
    InvalidateRect(g_hwnd, null, FALSE);
    UpdateWindow(g_hwnd); // present now — queued WM_PAINTs may never be seen
}

// ---------------------------------------------------------------------------
// Watchdog thread: feeds the modal loop synthetic input so the freeze window
// is bounded with no human present, then escalates until the loop exits.
// Plain CreateThread — it only Sleeps, injects input, and logs (no GC).
//
// Two feed styles, matching how the two loop modes really consume input:
//   * mouse (grab variants, the realistic drag): SendInput relative
//     MOUSEEVENTF_MOVEs while the button injected by the main thread is held,
//     then MOUSEEVENTF_LEFTUP — the loop's documented exit condition.
//   * kbd (keyboard variants): posted WM_KEYDOWN arrows pick the edge and
//     size/move the window, then VK_RETURN confirms.
// Escalation ladder if the loop is still alive: VK_ESCAPE -> button-up ->
// WM_CANCELMODE -> WM_CLOSE.

enum FeedKind
{
    mouse,
    kbd,
}

enum FREEZE_HOLD_MS = 600; // evidence window before the feed starts

void postKey(DWORD vk, const(char)* name) nothrow
{
    logEvent("watchdog action=post_key vk=%s ok=%d",
        name, PostMessageW(g_hwnd, WM_KEYDOWN, vk, 0) ? 1 : 0);
}

void sendMouse(DWORD flags, int dx, int dy, const(char)* what) nothrow
{
    INPUT inp;
    inp.type = INPUT_MOUSE;
    inp.mi.dx = dx;
    inp.mi.dy = dy;
    inp.mi.dwFlags = flags;
    const sent = SendInput(1, &inp, INPUT.sizeof);
    logEvent("watchdog action=send_input what=%s sent=%u", what, sent);
}

// Sleep in 50 ms slices, bailing as soon as the SendMessage has returned.
bool sleepUnlessOver(int ms) nothrow
{
    foreach (i; 0 .. ms / 50)
    {
        if (atomicLoad(s_attemptOver))
            return false;
        Sleep(50);
    }
    return !atomicLoad(s_attemptOver);
}

extern (Windows) DWORD watchdogProc(LPVOID param) nothrow
{
    const feed = cast(FeedKind) cast(size_t) param;

    // Let the freeze accumulate a measurable evidence window first. (For the
    // keyboard variants this also covers start_size_move's pre-loop, which
    // runs *before* WM_ENTERSIZEMOVE and eats the first input.)
    if (!sleepUnlessOver(FREEZE_HOLD_MS))
        return 0;

    if (feed == FeedKind.mouse)
    {
        // Relative moves: each one reaches the modal loop as a real
        // WM_MOUSEMOVE and drives a WM_SIZING/WM_MOVING + window update.
        foreach (i; 0 .. 4)
        {
            sendMouse(MOUSEEVENTF_MOVE, 16, 12, "move+16+12");
            if (!sleepUnlessOver(50))
                return 0;
        }
        if (!sleepUnlessOver(150))
            return 0;
        sendMouse(MOUSEEVENTF_LEFTUP, 0, 0, "leftup"); // the documented exit
    }
    else
    {
        // Arrows: in the pre-loop they pick the resize edge; in the modal
        // loop proper they move the cursor 8 px per press (sizing/moving).
        foreach (i; 0 .. 3)
        {
            postKey(VK_RIGHT, "RIGHT");
            if (!sleepUnlessOver(50))
                return 0;
        }
        foreach (i; 0 .. 2)
        {
            postKey(VK_DOWN, "DOWN");
            if (!sleepUnlessOver(50))
                return 0;
        }
        if (!sleepUnlessOver(100))
            return 0;
        postKey(VK_RETURN, "RETURN"); // confirm = exit the modal loop
    }

    // Escalation ladder, ~500 ms per rung, until the SendMessage returns.
    if (!sleepUnlessOver(500))
        return 0;
    postKey(VK_ESCAPE, "ESCAPE");
    if (!sleepUnlessOver(500))
        return 0;
    sendMouse(MOUSEEVENTF_LEFTUP, 0, 0, "leftup_escalate");
    if (!sleepUnlessOver(500))
        return 0;
    logEvent("watchdog action=post_cancelmode ok=%d",
        PostMessageW(g_hwnd, WM_CANCELMODE, 0, 0) ? 1 : 0);
    if (!sleepUnlessOver(500))
        return 0;
    logEvent("watchdog event=giveup name=%s action=post_close", g.curName);
    PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
    return 0;
}

// ---------------------------------------------------------------------------
// One programmatic modal-loop attempt. SendMessage to our own window is a
// direct WndProc call; the unhandled WM_SYSCOMMAND falls through to
// DefWindowProcW, which runs the entire interactive size/move modal loop
// inside this call — it does not return until the loop exits.

void runModalAttempt(const(char)* name, WPARAM wparam, FeedKind feed, bool holdButton) nothrow
{
    g.curName = name;
    g.curEnterUs = g.curExitUs = 0;
    g.curMaxGapUs = 0;
    g.curTicks = g.curSizing = g.curMoving = 0;
    g.bridgePending = false;
    g.everEntered = false;

    RECT r;
    GetWindowRect(g_hwnd, &r);
    const cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
    // Pre-flight: the conditions the size/move loop bails on — zoomed,
    // invisible — plus the activation state, since interactive size/move
    // presumes a foreground window.
    logEvent("probe name=%s visible=%d zoomed=%d iconic=%d foreground=%d active=%d",
        name, IsWindowVisible(g_hwnd) ? 1 : 0, IsZoomed(g_hwnd) ? 1 : 0,
        IsIconic(g_hwnd) ? 1 : 0,
        GetForegroundWindow() is g_hwnd ? 1 : 0,
        GetActiveWindow() is g_hwnd ? 1 : 0);

    // The grab variants model a real drag, where the user already holds the
    // left button (a custom-chrome app sends SC_SIZE|edge from
    // WM_NCLBUTTONDOWN). The loop polls VK_LBUTTON and treats button-up as
    // "drag over", so a *real* (injected) press must precede the request.
    SetCursorPos(cx, cy);
    if (holdButton)
        sendMouse(MOUSEEVENTF_LEFTDOWN, 0, 0, "leftdown");

    logEvent("modal_request name=%s wparam=0x%04llx cursor=%d,%d",
        name, cast(ulong) wparam, cx, cy);

    atomicStore(s_attemptOver, false);
    HANDLE th = CreateThread(null, 0, &watchdogProc,
        cast(void*) cast(size_t) feed, 0, null);
    const t0 = nowUs();
    SendMessageW(g_hwnd, WM_SYSCOMMAND, wparam,
        cast(LPARAM)((cast(uint) cy << 16) | (cast(uint) cx & 0xffff)));
    atomicStore(s_attemptOver, true);
    logEvent("modal_request_returned name=%s dur_us=%lld entered=%d",
        name, nowUs() - t0, g.everEntered ? 1 : 0);
    if (th !is null)
    {
        WaitForSingleObject(th, 5000); // no stray input into the next attempt
        CloseHandle(th);
    }
    if (holdButton) // defensive: never leave the synthetic button held
        sendMouse(MOUSEEVENTF_LEFTUP, 0, 0, "leftup_cleanup");
    if (!g.everEntered)
        logEvent("modal_summary name=%s dur_us=0 ticks_during=0 max_gap_us=0 "
                ~ "sizing=0 moving=0 note=never_entered", name);
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

    case WM_SYSCOMMAND:
        logEvent("msg name=WM_SYSCOMMAND sc=0x%04llx", cast(ulong) wParam);
        goto default; // DefWindowProcW runs the modal loop right here

    case WM_ENTERSIZEMOVE:
        g.curEnterUs = nowUs();
        g.everEntered = true;
        atomicStore(s_inModal, true);
        logEvent("modal_enter t=%lld fix=%d", g.curEnterUs, g.modalFix ? 1 : 0);
        if (g.modalFix)
        {
            // The countermeasure: the modal loop's internal pump dispatches
            // WM_TIMER, so a timer armed here keeps the animation ticking
            // while GetMessageW never returns to our own loop.
            SetTimer(hwnd, MODAL_TIMER_ID, TICK_MS, null);
            logEvent("step name=SetTimer id=modal interval_ms=%d", TICK_MS);
        }
        goto default;

    case WM_EXITSIZEMOVE:
        g.curExitUs = nowUs();
        if (g.modalFix)
            KillTimer(hwnd, MODAL_TIMER_ID);
        atomicStore(s_inModal, false);
        g.bridgePending = true;
        logEvent("modal_exit t=%lld dur_us=%lld ticks_during=%u",
            g.curExitUs, g.curExitUs - g.curEnterUs, g.curTicks);
        goto default;

    case WM_TIMER:
        if (wParam == MODAL_TIMER_ID && atomicLoad(s_inModal))
            tick("timer"); // a frame from *inside* the modal loop
        return 0;

    case WM_CANCELMODE:
        logEvent("msg name=WM_CANCELMODE");
        goto default;

    case WM_GETMINMAXINFO:
        // Queried by the size/move loop just before WM_ENTERSIZEMOVE —
        // seeing it proves the modal-loop machinery actually started.
        logEvent("msg name=WM_GETMINMAXINFO");
        goto default;

    case WM_CAPTURECHANGED:
        logEvent("msg name=WM_CAPTURECHANGED");
        return 0;

    case WM_SIZING:
        ++g.curSizing;
        const sr = cast(RECT*) lParam;
        logEvent("msg name=WM_SIZING edge=%d rect=%ld,%ld-%ld,%ld",
            cast(int) wParam, sr.left, sr.top, sr.right, sr.bottom);
        goto default;

    case WM_MOVING:
        ++g.curMoving;
        const mr = cast(RECT*) lParam;
        logEvent("msg name=WM_MOVING rect=%ld,%ld-%ld,%ld",
            mr.left, mr.top, mr.right, mr.bottom);
        goto default;

    case WM_KEYDOWN:
        // Watchdog keys that arrive here were NOT consumed by a modal loop.
        logEvent("msg name=WM_KEYDOWN vk=0x%02llx in_modal=%d",
            cast(ulong) wParam, atomicLoad(s_inModal) ? 1 : 0);
        return 0;

    case WM_SIZE:
        const w = cast(int)(lParam & 0xffff);
        const h = cast(int)((lParam >> 16) & 0xffff);
        logEvent("resize size=%dx%d", w, h);
        if (wParam == SIZE_MINIMIZED)
            return 0;
        if (w != g.width || h != g.height)
            createBackbuffer(w, h);
        return 0;

    case WM_MOVE:
        logEvent("msg name=WM_MOVE pos=%d,%d",
            cast(int) cast(short)(lParam & 0xffff),
            cast(int) cast(short)((lParam >> 16) & 0xffff));
        return 0;

    case WM_ERASEBKGND:
        return 1; // the solid fill covers every pixel

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        fillSolid(g.color);
        if (g.pixels !is null)
            BitBlt(hdc, 0, 0, g.width, g.height, g.memDc, 0, 0, SRCCOPY);
        if (!g.firstPaintDone)
        {
            g.firstPaintDone = true;
            logEvent("first_pixel_presented size=%dx%d", g.width, g.height);
        }
        EndPaint(hwnd, &ps);
        return 0;

    case WM_CLOSE:
        logEvent("close_requested");
        goto default; // DefWindowProcW responds with DestroyWindow

    case WM_DESTROY:
        logEvent("msg name=WM_DESTROY");
        KillTimer(hwnd, MODAL_TIMER_ID);
        createBackbuffer(0, 0); // frees the DIB section
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
    WCHAR[8] buf;
    const n = GetEnvironmentVariableW(name, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

int main()
{
    instrumentInit("f03_modal_loop_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    g.modalFix = envFlag("WSI_MODAL_FIX"w.ptr);
    logEvent("mode auto_exit=%d modal_fix=%d", g.autoExit ? 1 : 0, g.modalFix ? 1 : 0);

    HINSTANCE hInst = GetModuleHandleW(null);
    HCURSOR arrow = LoadCursorW(null, IDC_ARROW);

    auto clsName = "wsi-f03-class"w;
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
    g_hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f03-modal-loop"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, hInst, null);
    if (g_hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");
    ShowWindow(g_hwnd, SW_SHOW);
    SetForegroundWindow(g_hwnd); // size/move presumes a foreground window
    UpdateWindow(g_hwnd);

    // The main loop: drain the queue, render one tick from the loop body,
    // sleep on the queue with a TICK_MS cap. No SetTimer drives the normal
    // animation — that is the point: this loop body is what the modal loop
    // starves, exactly like a PeekMessage game loop or a toolkit iteration.
    static struct Attempt
    {
        string name;
        WPARAM wparam;
        FeedKind feed;
        bool holdButton;
    }

    static immutable Attempt[3] attempts = [
        // The two realistic interactions (button held, mouse-fed): an
        // interactive border resize and a title-bar drag — F03 requirement 2.
        Attempt("sc_size_grab", SC_SIZE | WMSZ_BOTTOMRIGHT, FeedKind.mouse, true),
        Attempt("sc_move_caption", SC_MOVE | 2 /* HTCAPTION nibble */, FeedKind.mouse, true),
        // The keyboard variant ("Size" from the system menu), arrow-key-fed.
        Attempt("sc_size_kbd", SC_SIZE, FeedKind.kbd, false),
    ];
    uint attemptIdx = 0;
    uint nextActionTick = WARMUP_TICKS;
    bool running = true;
    int exitCode = 0;

    while (running)
    {
        MSG msg;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE))
        {
            if (msg.message == WM_QUIT)
            {
                running = false;
                exitCode = cast(int) msg.wParam;
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (!running)
            break;

        tick("loop");

        if (g.autoExit && g.tickCount >= nextActionTick)
        {
            if (attemptIdx < attempts.length)
            {
                const a = attempts[attemptIdx++];
                runModalAttempt(a.name.ptr, a.wparam, a.feed, a.holdButton);
                nextActionTick = g.tickCount + WARMUP_TICKS;
            }
            else
            {
                logEvent("summary mode=%s ticks=%u max_gap_us=%lld attempts=%d",
                    g.modalFix ? "fix".ptr : "nofix".ptr, g.tickCount,
                    g.maxGapUs, cast(int) attempts.length);
                DestroyWindow(g_hwnd);
                continue; // drain WM_DESTROY ... WM_QUIT
            }
        }

        // Wake on any message or after TICK_MS — a poll-style frame cadence
        // without a busy loop.
        MsgWaitForMultipleObjects(0, null, FALSE, TICK_MS, QS_ALLINPUT);
    }

    logEvent("exit code=%d", exitCode);
    return exitCode;
}

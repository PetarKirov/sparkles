// Win32 F17 — threading probes (../../../features/f17-threading.md), built on
// the scaffold (../scaffold/app.d). Six `--probe=N` run modes, each ending in a
// flushed verdict line:
//
//     probe n=... result=ok|error|crash|deadlock|silent detail=...
//
//   1. Window created on a WORKER thread while MAIN tries to receive its
//      messages: proves HWND message routing follows the *creating thread's*
//      queue (PostMessage'd messages are invisible to every other thread's
//      PeekMessage/GetMessage, even when filtered by that exact HWND).
//   2. Worker creates AND pumps its own window while main pumps another —
//      the legal multi-window multi-thread model, both painting concurrently.
//   3. Cross-thread SendMessage vs PostMessage: SendMessage blocks the sender
//      until the owning thread's pump dispatches (measured against a
//      deliberate 400 ms non-pumping gap); PostMessage latency for contrast.
//   4. The deadlock recipes: (a) two threads SendMessage each other
//      simultaneously — does the documented "incoming nonqueued messages are
//      processed while waiting" rule resolve it? (b) SendMessage to a thread
//      parked in WaitForSingleObject — SendMessageTimeout first (mitigation),
//      then a plain SendMessage captured by the 3 s watchdog as
//      result=deadlock.
//   5. BitBlt into a window DC acquired on a NON-owning thread, 100 frames,
//      while the owner pumps and paints — the GDI thread rules, measured.
//   6. AttachThreadInput: is GetFocus() per-queue state, and does attaching
//      the worker's input queue to main's make main's focus visible?
//
// Crash discipline (the spec's warning): a SetUnhandledExceptionFilter SEH
// hook turns any crash into a flushed `result=crash` verdict + ExitProcess(0),
// and a per-run watchdog thread turns hangs into `result=deadlock` +
// ExitProcess(0). Probe 4b *relies* on the watchdog — deadlocking is its job.
// Every child therefore exits 0; so does the driver.
//
// The no-argument run (what CI executes) spawns itself with --probe=N twice
// per probe (CreateProcessW, inherited stderr), per the spec's run-twice
// nondeterminism rule, and exits 0 regardless of child outcomes.
//
// Only druntime's core.sys.windows bindings. Worker threads are raw
// CreateThread threads that never touch the D GC (logEvent is @nogc nothrow).
module app;

import core.sys.windows.windows;
import instrument;

enum UINT WM_PING = WM_APP + 1; // SendMessage payload (handler returns 42)
enum UINT WM_POSTED = WM_APP + 2; // PostMessage latency probe
enum UINT WM_MUTUAL = WM_APP + 3; // probe 4a mutual send
enum UINT WM_DONE = WM_APP + 4; // worker -> main "stop pumping"

struct State
{
    HINSTANCE inst;
    int probe;
    HWND mainWnd, workerWnd;
    DWORD mainTid, workerTid;
    HANDLE evReady, evGo, evDone, evNever;
    long postT0; // PostMessage send timestamp (probe 3)
    long sendLatencyUs; // measured SendMessage block time (probe 3)
    int mainPaints, workerPaints; // probe 2
    int drained; // probe 1
    LONG mutualRecv; // probe 4a: WM_MUTUAL deliveries
    const(char)* stage = "init"; // what the watchdog reports
    int watchdogMs = 15000;
}

__gshared State g;

// ---------------------------------------------------------------------------
// Crash + hang capture: the verdict line must survive anything.

extern (Windows) LONG sehFilter(EXCEPTION_POINTERS* ep) nothrow
{
    const code = ep && ep.ExceptionRecord ? ep.ExceptionRecord.ExceptionCode : 0;
    logEvent("probe n=%d result=crash detail=seh code=0x%08lx stage=%s",
        g.probe, code, g.stage);
    ExitProcess(0);
    return EXCEPTION_EXECUTE_HANDLER; // not reached
}

extern (Windows) uint watchdogProc(void* arg) nothrow
{
    Sleep(cast(DWORD) cast(size_t) arg);
    // Probe 4b *expects* to land here: the deadlock is the finding.
    logEvent("probe n=%d result=deadlock detail=watchdog_fired stage=%s",
        g.probe, g.stage);
    ExitProcess(0);
    return 0;
}

void armWatchdog(int ms) nothrow
{
    CloseHandle(CreateThread(null, 0, &watchdogProc,
        cast(void*) cast(size_t) ms, 0, null));
}

// ---------------------------------------------------------------------------
// One WndProc for every probe window; per-message logging keyed by thread id.

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) nothrow
{
    switch (msg)
    {
    case WM_PING:
        logEvent("recv msg=WM_PING dispatched_on_thread=%lu", GetCurrentThreadId());
        return 42;

    case WM_POSTED:
        logEvent("post_latency_us=%lld dispatched_on_thread=%lu",
            nowUs() - g.postT0, GetCurrentThreadId());
        return 0;

    case WM_MUTUAL:
        import core.atomic : atomicOp;

        atomicOp!"+="(*cast(shared LONG*)&g.mutualRecv, 1);
        logEvent("recv msg=WM_MUTUAL dispatched_on_thread=%lu", GetCurrentThreadId());
        return 7;

    case WM_DONE:
        PostQuitMessage(0);
        return 0;

    case WM_TIMER:
        InvalidateRect(hwnd, null, FALSE); // probe 5: owner keeps repainting
        return 0;

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        const tid = GetCurrentThreadId();
        // Visible activity per thread; the count is the probe-2 evidence.
        RECT rc;
        GetClientRect(hwnd, &rc);
        FillRect(dc, &rc, cast(HBRUSH)(COLOR_WINDOW + (tid & 1)));
        EndPaint(hwnd, &ps);
        if (tid == g.mainTid)
            ++g.mainPaints;
        else
            ++g.workerPaints;
        return 0;

    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

HWND makeWindow(const(wchar)* title) nothrow
{
    HWND h = CreateWindowExW(0, "wsi-f17-class"w.ptr, title,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 320, 240,
        null, null, g.inst, null);
    if (h !is null)
        ShowWindow(h, SW_SHOW);
    return h;
}

// Pump the calling thread's queue until WM_QUIT or timeout.
int pumpUntilQuit(int timeoutMs) nothrow
{
    const deadline = nowUs() + cast(long) timeoutMs * 1000;
    MSG m;
    int dispatched;
    while (nowUs() < deadline)
    {
        while (PeekMessageW(&m, null, 0, 0, PM_REMOVE))
        {
            if (m.message == WM_QUIT)
                return dispatched;
            TranslateMessage(&m);
            DispatchMessageW(&m);
            ++dispatched;
        }
        MsgWaitForMultipleObjects(0, null, FALSE, 20, QS_ALLINPUT);
    }
    return dispatched;
}

// ---------------------------------------------------------------------------
// Probe 1 — window created on worker, messages posted to it; main must not
// see them. Worker does NOT pump until told; then it drains its own queue.

extern (Windows) uint worker1(void* arg) nothrow
{
    g.workerWnd = makeWindow("wsi-f17-worker"w.ptr);
    logEvent("thread=worker action=window_created hwnd=%p tid=%lu ok=%d",
        g.workerWnd, GetCurrentThreadId(), g.workerWnd !is null ? 1 : 0);
    foreach (i; 0 .. 10)
        PostMessageW(g.workerWnd, WM_PING, i, 0);
    logEvent("thread=worker action=posted count=10 to_own_window=1");
    SetEvent(g.evReady);
    WaitForSingleObject(g.evGo, 10000);
    // Drain with a WM_PING..WM_PING filter: an unfiltered PeekMessage(PM_REMOVE)
    // spins forever here, because WM_PAINT is only cleared from the queue by
    // validating the region (BeginPaint) — observed first-hand under Wine.
    MSG m;
    while (PeekMessageW(&m, null, WM_PING, WM_PING, PM_REMOVE))
        ++g.drained;
    logEvent("thread=worker action=drained wm_ping=%d", g.drained);
    DestroyWindow(g.workerWnd); // must happen on the creating thread
    SetEvent(g.evDone);
    return 0;
}

void probe1() nothrow
{
    g.stage = "p1_create_on_worker";
    HANDLE t = CreateThread(null, 0, &worker1, null, 0, &g.workerTid);
    WaitForSingleObject(g.evReady, 10000);

    // Main hunts for the worker-window messages for 500 ms: thread-wide peek
    // AND a peek filtered by the worker's HWND specifically.
    MSG m;
    int sawThreadWide, sawHwndFiltered;
    const deadline = nowUs() + 500_000;
    while (nowUs() < deadline)
    {
        while (PeekMessageW(&m, null, WM_PING, WM_PING, PM_REMOVE))
            ++sawThreadWide;
        if (PeekMessageW(&m, g.workerWnd, 0, 0, PM_NOREMOVE))
            ++sawHwndFiltered;
        Sleep(10);
    }
    logEvent("main_hunt thread_wide=%d hwnd_filtered=%d tid=%lu",
        sawThreadWide, sawHwndFiltered, GetCurrentThreadId());
    SetEvent(g.evGo);
    WaitForSingleObject(g.evDone, 10000);
    WaitForSingleObject(t, 5000);
    CloseHandle(t);

    const ok = sawThreadWide == 0 && sawHwndFiltered == 0 && g.drained == 10;
    logEvent("probe n=1 result=%s detail=posted=10 main_saw=%d main_saw_hwnd_filtered=%d worker_drained=%d",
        ok ? "ok".ptr : "error".ptr, sawThreadWide, sawHwndFiltered, g.drained);
}

// ---------------------------------------------------------------------------
// Probe 2 — worker creates and pumps its own window while main does the same.

extern (Windows) uint worker2(void* arg) nothrow
{
    g.workerWnd = makeWindow("wsi-f17-worker"w.ptr);
    logEvent("thread=worker action=window_created hwnd=%p tid=%lu",
        g.workerWnd, GetCurrentThreadId());
    SetEvent(g.evReady);
    foreach (i; 0 .. 30)
    {
        InvalidateRect(g.workerWnd, null, TRUE);
        MSG m;
        while (PeekMessageW(&m, null, 0, 0, PM_REMOVE))
            DispatchMessageW(&m);
        Sleep(5);
    }
    DestroyWindow(g.workerWnd);
    SetEvent(g.evDone);
    return 0;
}

void probe2() nothrow
{
    g.stage = "p2_two_pumps";
    g.mainWnd = makeWindow("wsi-f17-main"w.ptr);
    HANDLE t = CreateThread(null, 0, &worker2, null, 0, &g.workerTid);
    WaitForSingleObject(g.evReady, 10000);
    foreach (i; 0 .. 30)
    {
        InvalidateRect(g.mainWnd, null, TRUE);
        MSG m;
        while (PeekMessageW(&m, null, 0, 0, PM_REMOVE))
            DispatchMessageW(&m);
        Sleep(5);
    }
    WaitForSingleObject(g.evDone, 10000);
    WaitForSingleObject(t, 5000);
    CloseHandle(t);
    DestroyWindow(g.mainWnd);
    const ok = g.mainPaints > 0 && g.workerPaints > 0;
    logEvent("probe n=2 result=%s detail=main_paints=%d worker_paints=%d concurrent_pumps=2",
        ok ? "ok".ptr : "error".ptr, g.mainPaints, g.workerPaints);
}

// ---------------------------------------------------------------------------
// Probe 3 — SendMessage blocks until the owner pumps; PostMessage does not.

extern (Windows) uint worker3(void* arg) nothrow
{
    WaitForSingleObject(g.evReady, 10000);
    logEvent("thread=worker action=send_begin t=%lld owner_sleeping_ms=400", nowUs());
    const t0 = nowUs();
    const r = SendMessageW(g.mainWnd, WM_PING, 0, 0); // blocks: owner not pumping yet
    g.sendLatencyUs = nowUs() - t0;
    logEvent("thread=worker action=send_returned ret=%lld blocked_us=%lld",
        cast(long) r, g.sendLatencyUs);
    g.postT0 = nowUs();
    PostMessageW(g.mainWnd, WM_POSTED, 0, 0); // returns immediately
    logEvent("thread=worker action=post_returned after_us=%lld", nowUs() - g.postT0);
    PostMessageW(g.mainWnd, WM_DONE, 0, 0);
    return 0;
}

void probe3() nothrow
{
    g.stage = "p3_send_vs_post";
    g.mainWnd = makeWindow("wsi-f17-main"w.ptr);
    HANDLE t = CreateThread(null, 0, &worker3, null, 0, &g.workerTid);
    SetEvent(g.evReady);
    logEvent("main action=sleep_no_pump ms=400"); // the measured gap
    Sleep(400);
    pumpUntilQuit(5000);
    WaitForSingleObject(t, 5000);
    CloseHandle(t);
    DestroyWindow(g.mainWnd);
    const ok = g.sendLatencyUs >= 300_000; // blocked across most of the gap
    logEvent("probe n=3 result=%s detail=send_blocked_us=%lld post_dispatch=see_post_latency_line",
        ok ? "ok".ptr : "error".ptr, g.sendLatencyUs);
}

// ---------------------------------------------------------------------------
// Probe 4 — deadlock recipes.
// 4a: both threads SendMessage each other at once. The SendMessage docs say a
//     thread blocked in SendMessage still processes incoming *nonqueued*
//     (sent) messages — so this should resolve, not deadlock.
// 4b: SendMessage to a thread parked in WaitForSingleObject(INFINITE) — no
//     pump, no SendMessage wait, nothing processes the sent message.
//     SendMessageTimeout demonstrates the mitigation; the plain SendMessage
//     that follows is ended by the watchdog (result=deadlock — expected).

extern (Windows) uint worker4(void* arg) nothrow
{
    g.workerWnd = makeWindow("wsi-f17-worker"w.ptr);
    SetEvent(g.evReady);
    WaitForSingleObject(g.evGo, 10000); // barrier: fire together with main
    logEvent("thread=worker action=mutual_send_begin t=%lld", nowUs());
    const t0 = nowUs();
    const r = SendMessageW(g.mainWnd, WM_MUTUAL, 0, 0);
    logEvent("thread=worker action=mutual_send_returned ret=%lld blocked_us=%lld",
        cast(long) r, nowUs() - t0);
    SetEvent(g.evDone);
    // 4b: park hard — not pumping, not in SendMessage, just a kernel wait.
    logEvent("thread=worker action=park_in_WaitForSingleObject infinite=1");
    WaitForSingleObject(g.evNever, INFINITE);
    return 0;
}

void probe4() nothrow
{
    g.stage = "p4a_mutual_send";
    g.mainWnd = makeWindow("wsi-f17-main"w.ptr);
    HANDLE t = CreateThread(null, 0, &worker4, null, 0, &g.workerTid);
    WaitForSingleObject(g.evReady, 10000);

    SetEvent(g.evGo);
    logEvent("main action=mutual_send_begin t=%lld", nowUs());
    const t0 = nowUs();
    const r = SendMessageW(g.workerWnd, WM_MUTUAL, 0, 0);
    const mainBlocked = nowUs() - t0;
    logEvent("main action=mutual_send_returned ret=%lld blocked_us=%lld",
        cast(long) r, mainBlocked);
    WaitForSingleObject(g.evDone, 5000);
    logEvent("probe n=4 stage=mutual_send result=%s detail=both_returned wm_mutual_recv=%ld main_blocked_us=%lld",
        g.mutualRecv == 2 ? "ok".ptr : "error".ptr, g.mutualRecv, mainBlocked);

    // 4b — worker is now parked in WaitForSingleObject(INFINITE).
    Sleep(100); // let it reach the wait
    g.stage = "p4b_send_to_blocked_thread";
    DWORD res; // druntime declares the out param as PDWORD (PDWORD_PTR upstream)
    SetLastError(0);
    const ok = SendMessageTimeoutW(g.workerWnd, WM_PING, 0, 0,
        SMTO_NORMAL, 1500, &res);
    logEvent("main action=SendMessageTimeout ret=%d err=%lu timeout_ms=1500",
        cast(int) ok, GetLastError());
    logEvent("main action=plain_send_begin expect=deadlock watchdog_ms=3000");
    armWatchdog(3000); // THIS ends the probe: verdict result=deadlock
    SendMessageW(g.workerWnd, WM_PING, 0, 0); // never returns
    logEvent("probe n=4 stage=send_to_blocked result=silent detail=send_unexpectedly_returned");
}

// ---------------------------------------------------------------------------
// Probe 5 — BitBlt into the window DC from a non-owning thread, 100 frames,
// while the owning (main) thread pumps and repaints concurrently.

extern (Windows) uint worker5(void* arg) nothrow
{
    HDC wdc = GetDC(g.mainWnd); // window DC acquired on THIS thread
    logEvent("thread=worker action=GetDC hdc=%p err=%lu", wdc, GetLastError());
    HDC mem = CreateCompatibleDC(wdc);
    enum W = 200, H = 150;
    BITMAPINFO bmi;
    bmi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
    bmi.bmiHeader.biWidth = W;
    bmi.bmiHeader.biHeight = -H;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    void* bits;
    HBITMAP dib = CreateDIBSection(null, &bmi, DIB_RGB_COLORS, &bits, null, 0);
    auto old = SelectObject(mem, dib);
    int okCount, failCount;
    DWORD firstErr;
    foreach (i; 0 .. 100)
    {
        auto px = cast(uint*) bits;
        px[0 .. W * H] = 0xff0000 | (cast(uint) i * 2 << 8); // frame-varying fill
        SetLastError(0);
        if (BitBlt(wdc, 20, 20, W, H, mem, 0, 0, SRCCOPY))
            ++okCount;
        else
        {
            if (failCount == 0)
                firstErr = GetLastError();
            ++failCount;
        }
        Sleep(3);
    }
    SelectObject(mem, old);
    DeleteObject(dib);
    DeleteDC(mem);
    ReleaseDC(g.mainWnd, wdc);
    logEvent("thread=worker action=blits done ok=%d fail=%d first_err=%lu",
        okCount, failCount, failCount ? firstErr : 0);
    g.drained = okCount; // reuse the slot for the verdict
    PostMessageW(g.mainWnd, WM_DONE, 0, 0);
    return 0;
}

void probe5() nothrow
{
    g.stage = "p5_cross_thread_bitblt";
    g.mainWnd = makeWindow("wsi-f17-main"w.ptr);
    HANDLE t = CreateThread(null, 0, &worker5, null, 0, &g.workerTid);
    // Owner keeps pumping AND repainting underneath the foreign BitBlts.
    SetTimer(g.mainWnd, 1, 16, null);
    const dispatched = pumpUntilQuit(10000);
    KillTimer(g.mainWnd, 1);
    WaitForSingleObject(t, 5000);
    CloseHandle(t);
    DestroyWindow(g.mainWnd);
    logEvent("probe n=5 result=%s detail=blits_ok=%d/100 owner_dispatched=%d owner_paints=%d",
        g.drained == 100 ? "ok".ptr : "error".ptr, g.drained, dispatched, g.mainPaints);
}

// ---------------------------------------------------------------------------
// Probe 6 — AttachThreadInput: GetFocus is per-input-queue state.

extern (Windows) uint worker6(void* arg) nothrow
{
    WaitForSingleObject(g.evReady, 10000);
    HWND before = GetFocus();
    SetLastError(0);
    const att = AttachThreadInput(GetCurrentThreadId(), g.mainTid, TRUE);
    HWND after = GetFocus();
    AttachThreadInput(GetCurrentThreadId(), g.mainTid, FALSE);
    logEvent("thread=worker action=attach_probe before=%p attach_ret=%d err=%lu after=%p",
        before, att, GetLastError(), after);
    g.workerWnd = after; // smuggle the result to the verdict
    g.drained = att;
    PostMessageW(g.mainWnd, WM_DONE, 0, 0);
    return 0;
}

void probe6() nothrow
{
    g.stage = "p6_attach_thread_input";
    g.mainWnd = makeWindow("wsi-f17-main"w.ptr);
    SetForegroundWindow(g.mainWnd);
    SetFocus(g.mainWnd);
    logEvent("main action=SetFocus hwnd=%p get_focus=%p", g.mainWnd, GetFocus());
    HANDLE t = CreateThread(null, 0, &worker6, null, 0, &g.workerTid);
    SetEvent(g.evReady);
    pumpUntilQuit(5000);
    WaitForSingleObject(t, 5000);
    CloseHandle(t);
    DestroyWindow(g.mainWnd);
    const seesFocus = g.workerWnd is g.mainWnd;
    logEvent("probe n=6 result=ok detail=attach_ret=%d focus_visible_after_attach=%d focus_hwnd=%p",
        g.drained, seesFocus ? 1 : 0, g.workerWnd);
}

// ---------------------------------------------------------------------------
// Driver: child mode runs one probe; parent mode spawns every probe twice.

int runProbe(int n) nothrow
{
    g.probe = n;
    g.mainTid = GetCurrentThreadId();
    SetUnhandledExceptionFilter(cast(LPTOP_LEVEL_EXCEPTION_FILTER)&sehFilter);
    if (n != 4) // probe 4 arms its own short watchdog at the right moment
        armWatchdog(g.watchdogMs);

    g.evReady = CreateEventW(null, FALSE, FALSE, null);
    g.evGo = CreateEventW(null, FALSE, FALSE, null);
    g.evDone = CreateEventW(null, FALSE, FALSE, null);
    g.evNever = CreateEventW(null, TRUE, FALSE, null);

    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = g.inst;
    wc.lpszClassName = "wsi-f17-class"w.ptr;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    wc.hbrBackground = cast(HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassExW(&wc); // process-wide: usable from every thread

    logEvent("probe_start n=%d main_tid=%lu", n, g.mainTid);
    switch (n)
    {
    case 1:
        probe1();
        break;
    case 2:
        probe2();
        break;
    case 3:
        probe3();
        break;
    case 4:
        probe4();
        break;
    case 5:
        probe5();
        break;
    case 6:
        probe6();
        break;
    default:
        logEvent("probe n=%d result=error detail=unknown_probe", n);
        break;
    }
    ExitProcess(0); // crash probes exit 0 too — crashing is their job
    return 0;
}

int main(string[] args)
{
    instrumentInit("f17_win32");
    g.inst = GetModuleHandleW(null);

    foreach (a; args[1 .. $])
        if (a.length == 9 && a[0 .. 8] == "--probe=")
            return runProbe(a[8] - '0');

    // Parent: every probe twice (spec rule 4), each in its own process so a
    // crashed/deadlocked child cannot poison the next probe.
    logEvent("driver_start probes=6 runs_each=2");
    WCHAR[MAX_PATH] exe;
    GetModuleFileNameW(null, exe.ptr, MAX_PATH);
    foreach (n; 1 .. 7)
    {
        foreach (run; 0 .. 2)
        {
            WCHAR[MAX_PATH + 32] cmd;
            int p;
            cmd[p++] = '"';
            for (int i = 0; exe[i]; ++i)
                cmd[p++] = exe[i];
            cmd[p++] = '"';
            foreach (ch; " --probe=0"w)
                cmd[p++] = ch;
            cmd[p - 1] = cast(WCHAR)('0' + n);
            cmd[p] = 0;

            STARTUPINFOW si;
            si.cb = STARTUPINFOW.sizeof;
            PROCESS_INFORMATION pi;
            logEvent("spawn probe=%d run=%d", n, run + 1);
            if (!CreateProcessW(null, cmd.ptr, null, null, TRUE, 0, null, null, &si, &pi))
            {
                logEvent("error what=CreateProcessW code=%lu", GetLastError());
                continue;
            }
            WaitForSingleObject(pi.hProcess, 30000);
            DWORD code = 0xdead;
            GetExitCodeProcess(pi.hProcess, &code);
            logEvent("child_exit probe=%d run=%d code=%lu", n, run + 1, code);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }
    logEvent("exit code=0");
    return 0;
}

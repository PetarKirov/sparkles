// F05 — loop wakeup & external handles, Win32 implementation
// (../../../features/f05-loop-wakeup.md). Extends the scaffold
// (../scaffold/app.d) in three directions:
//
//   * Cross-thread wakeup, mechanism A: a worker thread (raw CreateThread —
//     no druntime registration needed, the thread only touches user32 and
//     QueryPerformanceCounter) posts WM_APP+1 to the window 10x/second for
//     30 s with PostMessageW; the wParam indexes a __gshared QPC-timestamp
//     slot, so the WndProc can compute "wakeup latency_us=... mech=postmessage".
//   * Cross-thread wakeup, mechanism B: the same worker also posts WM_APP+2
//     with PostThreadMessageW to the UI thread id. Thread messages have
//     msg.hwnd == null, so DispatchMessageW would drop them on the floor —
//     they MUST be handled in the pump itself (and an hwnd-filtered
//     GetMessage/PeekMessage never retrieves them: the filter probe below
//     proves it). Latency is logged as mech=threadmessage.
//   * External-handle waiting: the pump is not GetMessageW but
//     MsgWaitForMultipleObjectsEx(1, &timer, INFINITE, QS_ALLINPUT,
//     MWMO_INPUTAVAILABLE) over a CreateWaitableTimerW handle ticking at
//     7 Hz — Win32's answer to "add an arbitrary fd to the loop" is an ARRAY
//     of kernel handles, capped at MAXIMUM_WAIT_OBJECTS-1 = 63. A start-up
//     probe calls the wait with 64 handles to demonstrate the hard failure.
//
// Exit prints min/median/p99/max latency per mechanism plus the waitable
// timer's observed tick-interval distribution. WSI_AUTO_EXIT=1 destroys the
// window once the worker is done (bounded ~31 s run, exit 0).
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

enum UINT WM_WAKEUP_POST = WM_APP + 1; // mech A: PostMessageW(hwnd, ...)
enum UINT WM_WAKEUP_THREAD = WM_APP + 2; // mech B: PostThreadMessageW(tid, ...)
enum UINT WM_WORKER_DONE = WM_APP + 3;

enum POSTS_PER_SECOND = 10;
enum RUN_SECONDS = 30;
enum TOTAL_POSTS = POSTS_PER_SECOND * RUN_SECONDS; // 300 per mechanism
enum TIMER_HZ = 7; // waitable-timer tick rate
enum TIMER_PERIOD_MS = 1000 / TIMER_HZ; // 142 ms (7.04 Hz nominal)
enum FILTER_PROBE_SEQ = 150; // mid-run hwnd-filter probe (see wndProc)

// ---------------------------------------------------------------------------
// Shared state. QPC timestamps cross the thread boundary through per-sequence
// slots indexed by the message's wParam, so a latency sample never races with
// the next post (the worker writes slot i strictly before posting seq i).

struct Demo
{
    HWND hwnd;
    DWORD uiThreadId;
    HANDLE timer; // auto-reset waitable timer, 7 Hz
    HANDLE worker; // CreateThread handle
    long qpcFreq; // QueryPerformanceFrequency, counts/s
    long lastTickQpc; // previous fd_tick, for interval stats
    uint tickCount;
    bool autoExit;
    bool workerDone;
    bool probeDone;
}

__gshared Demo g;
__gshared long[TOTAL_POSTS] postStampQpc; // written by worker, read by UI thread
__gshared long[TOTAL_POSTS] threadStampQpc;

// Fixed-capacity sample sets (no allocation; the WndProc is nothrow).
struct Samples
{
    long[TOTAL_POSTS] buf;
    int n;

    void add(long v) nothrow @nogc
    {
        if (n < buf.length)
            buf[n++] = v;
    }
}

__gshared Samples postLat, threadLat, tickIntervals;

long qpcNow() nothrow @nogc
{
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return t.QuadPart;
}

long qpcToUs(long delta) nothrow @nogc
{
    return delta * 1_000_000 / g.qpcFreq;
}

// ---------------------------------------------------------------------------
// Worker thread: a raw kernel thread (CreateThread, extern(Windows) entry).
// Every ~100 ms it stamps QPC and fires both mechanisms back to back; both
// are documented as callable from any thread targeting another thread's queue.

extern (Windows) DWORD workerMain(LPVOID) nothrow
{
    foreach (i; 0 .. TOTAL_POSTS)
    {
        Sleep(1000 / POSTS_PER_SECOND);
        postStampQpc[i] = qpcNow();
        if (!PostMessageW(g.hwnd, WM_WAKEUP_POST, cast(WPARAM) i, 0))
            logEvent("error what=PostMessageW seq=%d code=%lu", cast(int) i, GetLastError());
        threadStampQpc[i] = qpcNow();
        if (!PostThreadMessageW(g.uiThreadId, WM_WAKEUP_THREAD, cast(WPARAM) i, 0))
            logEvent("error what=PostThreadMessageW seq=%d code=%lu", cast(int) i, GetLastError());
    }
    PostMessageW(g.hwnd, WM_WORKER_DONE, 0, 0);
    return 0;
}

// ---------------------------------------------------------------------------
// The 63-handle ceiling, demonstrated: MsgWaitForMultipleObjectsEx accepts at
// most MAXIMUM_WAIT_OBJECTS-1 = 63 handles (the message queue itself occupies
// the 64th slot). 64 handles fail hard with ERROR_INVALID_PARAMETER.

void probeHandleLimit() nothrow
{
    HANDLE[64] ev;
    foreach (i; 0 .. 64)
        ev[i] = CreateEventW(null, FALSE, FALSE, null);

    SetLastError(0);
    const r64 = MsgWaitForMultipleObjectsEx(64, ev.ptr, 0, QS_ALLINPUT, 0);
    logEvent("handle_limit_probe n=64 result=0x%08lx err=%lu", r64, GetLastError());

    SetLastError(0);
    const r63 = MsgWaitForMultipleObjectsEx(63, ev.ptr, 0, QS_ALLINPUT, 0);
    logEvent("handle_limit_probe n=63 result=0x%08lx err=%lu", r63, GetLastError());

    foreach (i; 0 .. 64)
        CloseHandle(ev[i]);
}

// ---------------------------------------------------------------------------
// Stats: insertion sort (300 elements, exit path only) + percentile report.

void sortSamples(ref Samples s) nothrow @nogc
{
    foreach (i; 1 .. s.n)
    {
        const v = s.buf[i];
        int j = i - 1;
        while (j >= 0 && s.buf[j] > v)
        {
            s.buf[j + 1] = s.buf[j];
            j--;
        }
        s.buf[j + 1] = v;
    }
}

void reportStats(ref Samples s, const(char)* name) nothrow
{
    if (s.n == 0)
    {
        logEvent("latency_stats mech=%s n=0", name);
        return;
    }
    sortSamples(s);
    const min = s.buf[0];
    const median = s.buf[s.n / 2];
    const p99 = s.buf[(s.n * 99) / 100];
    const max = s.buf[s.n - 1];
    logEvent("latency_stats mech=%s n=%d min_us=%lld median_us=%lld p99_us=%lld max_us=%lld",
        name, s.n, min, median, p99, max);
}

// ---------------------------------------------------------------------------
// WndProc: WM_WAKEUP_POST arrives here through DispatchMessageW like any
// window message. WM_WAKEUP_THREAD never does — see the pump.

void recordWakeup(ref Samples s, long stamp, const(char)* mech, size_t seq) nothrow
{
    const lat = qpcToUs(qpcNow() - stamp);
    s.add(lat);
    logEvent("wakeup latency_us=%lld mech=%s seq=%d", lat, mech, cast(int) seq);
}

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_WAKEUP_POST:
        recordWakeup(postLat, postStampQpc[wParam], "postmessage", wParam);
        if (wParam == FILTER_PROBE_SEQ && !g.probeDone)
        {
            // The matching WM_WAKEUP_THREAD was posted right behind this
            // message, so it is (almost certainly) sitting in the queue now:
            // an hwnd-filtered peek cannot see it, a null-filtered one can.
            // This is why thread messages are lost inside any modal loop that
            // pumps with an hwnd filter (dialogs, menus, DefWindowProc's
            // move/size loop): no hwnd matches a message that has none.
            g.probeDone = true;
            MSG probe;
            const filtered = PeekMessageW(&probe, hwnd,
                WM_WAKEUP_THREAD, WM_WAKEUP_THREAD, PM_NOREMOVE);
            const open = PeekMessageW(&probe, null,
                WM_WAKEUP_THREAD, WM_WAKEUP_THREAD, PM_NOREMOVE);
            logEvent("thread_msg_filter_probe hwnd_filtered=%d null_filtered=%d",
                cast(int) filtered, cast(int) open);
        }
        return 0;

    case WM_WORKER_DONE:
        logEvent("worker_done posts=%d", TOTAL_POSTS);
        g.workerDone = true;
        if (g.autoExit)
            DestroyWindow(hwnd);
        return 0;

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        FillRect(hdc, &ps.rcPaint, cast(HBRUSH)(COLOR_WINDOW + 1));
        EndPaint(hwnd, &ps);
        return 0;

    case WM_CLOSE:
        logEvent("close_requested");
        goto default;

    case WM_DESTROY:
        logEvent("msg name=WM_DESTROY");
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
    instrumentInit("f05_loop_wakeup_win32");
    logEvent("init_start");
    g.autoExit = wantAutoExit();
    logEvent("mode auto_exit=%d", g.autoExit ? 1 : 0);

    LARGE_INTEGER freq;
    QueryPerformanceFrequency(&freq);
    g.qpcFreq = freq.QuadPart;
    logEvent("qpc_freq hz=%lld", g.qpcFreq);
    g.uiThreadId = GetCurrentThreadId();

    HINSTANCE hInst = GetModuleHandleW(null);
    auto clsName = "wsi-f05-class"w;
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
    g.hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f05-loop-wakeup"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, hInst, null);
    if (g.hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");
    ShowWindow(g.hwnd, SW_SHOW);
    UpdateWindow(g.hwnd);

    probeHandleLimit();

    // The "arbitrary fd": an auto-reset waitable timer at ~7 Hz. Auto-reset
    // means a satisfied wait consumes the signal — no manual ResetEvent dance.
    g.timer = CreateWaitableTimerW(null, FALSE, null);
    LARGE_INTEGER due;
    due.QuadPart = -10_000L * TIMER_PERIOD_MS; // relative, 100 ns units
    if (g.timer is null || !SetWaitableTimer(g.timer, &due, TIMER_PERIOD_MS, null, null, FALSE))
    {
        logEvent("error what=SetWaitableTimer code=%lu", GetLastError());
        return 1;
    }
    logEvent("step name=SetWaitableTimer period_ms=%d", TIMER_PERIOD_MS);

    g.worker = CreateThread(null, 0, &workerMain, null, 0, null);
    if (g.worker is null)
    {
        logEvent("error what=CreateThread code=%lu", GetLastError());
        return 1;
    }
    logEvent("step name=CreateThread rate_hz=%d duration_s=%d", POSTS_PER_SECOND, RUN_SECONDS);

    // The pump: wait on {timer} + the message queue in one call. QS_ALLINPUT
    // wakes for any queued message; MWMO_INPUTAVAILABLE closes the race where
    // a message arrived between the drain below and re-entering the wait
    // (without it, already-queued-but-already-seen input would not satisfy
    // the wait and a wakeup could stall until the next timer tick).
    int exitCode = 0;
    pump: while (true)
    {
        const r = MsgWaitForMultipleObjectsEx(1, &g.timer, INFINITE,
            QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (r == WAIT_OBJECT_0) // the timer handle, not the queue
        {
            const t = qpcNow();
            ++g.tickCount;
            logEvent("fd_tick t=%lld n=%u", nowUs(), g.tickCount);
            if (g.lastTickQpc != 0)
                tickIntervals.add(qpcToUs(t - g.lastTickQpc));
            g.lastTickQpc = t;
        }
        else if (r == WAIT_FAILED)
        {
            logEvent("error what=MsgWaitForMultipleObjectsEx code=%lu", GetLastError());
            exitCode = 1;
            break;
        }
        // r == WAIT_OBJECT_0 + 1: queue input. Drain it fully either way —
        // a timer wake may coincide with pending messages.
        MSG msg;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE))
        {
            if (msg.message == WM_QUIT)
            {
                exitCode = cast(int) msg.wParam;
                break pump;
            }
            if (msg.hwnd is null)
            {
                // A thread message: DispatchMessageW would silently drop it
                // (no hwnd -> no WndProc). Handle it here, in the pump.
                if (msg.message == WM_WAKEUP_THREAD)
                    recordWakeup(threadLat, threadStampQpc[msg.wParam],
                        "threadmessage", msg.wParam);
                continue;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    WaitForSingleObject(g.worker, 5000);
    CloseHandle(g.worker);
    CancelWaitableTimer(g.timer);
    CloseHandle(g.timer);

    reportStats(postLat, "postmessage");
    reportStats(threadLat, "threadmessage");
    reportStats(tickIntervals, "handle_tick_interval");
    logEvent("tick_total n=%u nominal_period_ms=%d", g.tickCount, TIMER_PERIOD_MS);
    logEvent("exit code=%d", exitCode);
    return exitCode;
}

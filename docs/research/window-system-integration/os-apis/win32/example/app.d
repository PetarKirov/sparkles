// Minimal Win32 window — the irreducible message-pump sequence GLFW/SDL/winit wrap
// on Windows: RegisterClassExW -> CreateWindowExW -> ShowWindow -> GetMessage /
// DispatchMessage, with a WndProc handling WM_PAINT/WM_DESTROY. Uses druntime's
// built-in `core.sys.windows` bindings (the windows.h projection that ships with
// LDC/DMD) — no third-party. For full SDK coverage the windows-d package is the
// upgrade; see ../index.md (the Win32 OS-API survey).
//
// Bounded: paints once then PostQuitMessage so CI never blocks. Windows always has
// a window station (even on a headless CI runner), so no SKIP gate is needed.
module app;

import core.sys.windows.windows;
import core.stdc.stdio : printf;

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        RECT rc;
        GetClientRect(hwnd, &rc);
        FillRect(hdc, &rc, cast(HBRUSH)(COLOR_WINDOW + 1));
        EndPaint(hwnd, &ps);
        PostQuitMessage(0); // bounded: exit after the first paint
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

int main()
{
    HINSTANCE hInst = GetModuleHandleW(null);
    auto clsName = "SparklesWin32"w;

    // 1. Register the window class (WndProc + class name).
    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = clsName.ptr;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    if (!RegisterClassExW(&wc))
    {
        printf("RegisterClassExW failed (%lu)\n", GetLastError());
        return 1;
    }

    // 2. Create a standard overlapped (titled, resizable) top-level window.
    HWND hwnd = CreateWindowExW(0, clsName.ptr, "Sparkles · Win32"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, hInst, null);
    if (hwnd is null)
    {
        printf("CreateWindowExW failed (%lu)\n", GetLastError());
        return 1;
    }

    // 3. Show it and run the message pump until WM_QUIT.
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    printf("ok: created a Win32 window and pumped messages to WM_QUIT\n");
    return cast(int) msg.wParam;
}

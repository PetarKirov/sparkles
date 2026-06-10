// F06 — keyboard & keymap, Win32 implementation
// (../../../features/f06-keyboard.md). Extends the scaffold
// (../scaffold/app.d) into a keyboard observatory:
//
//   * The WndProc logs the full chain for every key: WM_KEYDOWN /
//     WM_SYSKEYDOWN (vk from wParam; scancode, extended bit, repeat count and
//     previous-state bit decoded from lParam) -> TranslateMessage ->
//     WM_CHAR / WM_DEADCHAR / WM_SYSCHAR (UTF-16 code units, surrogate pairs
//     recombined) -> WM_KEYUP. WSI_NO_TRANSLATE=1 skips TranslateMessage in
//     the pump to prove every text-level message comes from it and it alone.
//   * A SetTimer-driven script injects scancode-level input into the demo's
//     own (focused) window with SendInput(KEYEVENTF_SCANCODE): a letter, a
//     shifted digit (vk != text proof), a same-key keydown pair (previous-
//     state bit), an Alt chord (WM_SYSKEYDOWN/WM_SYSCHAR), and — after
//     LoadKeyboardLayoutW("00000407") + KLF_ACTIVATE switches the thread to
//     German — the same physical scancodes again (Y/Z swap) plus the dead-key
//     sequence acute (scan 0x0D on de) + E -> WM_DEADCHAR -> WM_CHAR 'é'.
//     A KEYEVENTF_UNICODE pair carries U+1F600 as two surrogate WM_CHARs.
//   * Repeat ownership: the system owns auto-repeat; the demo logs the
//     configured rate/delay from SystemParametersInfoW(SPI_GETKEYBOARDSPEED /
//     SPI_GETKEYBOARDDELAY) at startup.
//
// WSI_AUTO_EXIT=1 runs the script and exits 0 (~1.5 s); without it the window
// stays open for real typing after the script.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import instrument;

enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 100; // one script step per tick

// PC/AT set-1 make codes for the physical positions the script exercises.
enum SC : ushort
{
    A = 0x1e,
    B = 0x30,
    C = 0x2e,
    E = 0x12,
    Y = 0x15, // QWERTY Y position — types 'z' under de (QWERTZ)
    Z = 0x2c, // QWERTY Z position — types 'y' under de
    digit2 = 0x03,
    acute = 0x0d, // '=' position on us; the dead acute key on de
    lshift = 0x2a,
    lalt = 0x38,
    space = 0x39,
}

enum ushort UP = 0x8000; // ORed onto a SC entry: key release

struct Demo
{
    HWND hwnd;
    HKL hklStart; // layout active at startup (us under a fresh prefix)
    HKL hklDe; // 00000407 once loaded
    uint step; // script position
    wchar pendingHigh; // WM_CHAR high surrogate awaiting its low unit
    bool autoExit;
    bool noTranslate; // WSI_NO_TRANSLATE=1: pump skips TranslateMessage
    uint nKeyDown, nKeyUp, nSysKeyDown, nSysKeyUp;
    uint nChar, nDeadChar, nSysChar, nSysDeadChar, nLangChange;
}

__gshared Demo g;

// ---------------------------------------------------------------------------
// UTF-16 -> UTF-8 for log lines (nothrow @nogc; the WndProc may not throw).

void encodeUtf8(dchar c, ref char[8] buf) nothrow @nogc
{
    int n;
    if (c < 0x80)
        buf[n++] = cast(char) c;
    else if (c < 0x800)
    {
        buf[n++] = cast(char)(0xc0 | (c >> 6));
        buf[n++] = cast(char)(0x80 | (c & 0x3f));
    }
    else if (c < 0x10000)
    {
        buf[n++] = cast(char)(0xe0 | (c >> 12));
        buf[n++] = cast(char)(0x80 | ((c >> 6) & 0x3f));
        buf[n++] = cast(char)(0x80 | (c & 0x3f));
    }
    else
    {
        buf[n++] = cast(char)(0xf0 | (c >> 18));
        buf[n++] = cast(char)(0x80 | ((c >> 12) & 0x3f));
        buf[n++] = cast(char)(0x80 | ((c >> 6) & 0x3f));
        buf[n++] = cast(char)(0x80 | (c & 0x3f));
    }
    buf[n] = 0;
}

// ---------------------------------------------------------------------------
// Key-event decoding: everything but the vk lives in lParam's bitfields.

void logKey(const(char)* state, bool sys, WPARAM wParam, LPARAM lParam) nothrow
{
    const repeatCount = cast(uint)(lParam & 0xffff); // bits 0-15
    const scan = cast(uint)((lParam >> 16) & 0xff); // bits 16-23
    const ext = cast(uint)((lParam >> 24) & 1); // bit 24
    const prev = cast(uint)((lParam >> 30) & 1); // bit 30: was down before

    // Layout-dependent key name straight from the scancode bits of lParam.
    WCHAR[32] nameW = 0;
    const n = GetKeyNameTextW(cast(LONG)(lParam & 0x03ff_0000), nameW.ptr, nameW.length);
    char[64] name8 = 0;
    int o;
    foreach (i; 0 .. n) // key names are ASCII-ish; non-ASCII -> '?'
        name8[o++] = nameW[i] < 0x80 ? cast(char) nameW[i] : '?';
    name8[o] = 0;

    logEvent("key code=0x%02x ext=%u vk=0x%02x sym=%s text=- state=%s repeat=%u count=%u sys=%d",
        scan, ext, cast(uint) wParam, name8.ptr, state, prev, repeatCount, sys ? 1 : 0);
}

void logChar(const(char)* kind, WPARAM wParam, LPARAM lParam, bool sys) nothrow
{
    const unit = cast(ushort) wParam;
    const repeatBit = cast(uint)((lParam >> 30) & 1);
    dchar cp = unit;

    if (unit >= 0xd800 && unit <= 0xdbff) // high surrogate: hold for the low
    {
        g.pendingHigh = unit;
        logEvent("char_unit utf16=0x%04x note=high_surrogate_pending", unit);
        return;
    }
    if (unit >= 0xdc00 && unit <= 0xdfff)
    {
        cp = g.pendingHigh
            ? 0x10000 + ((g.pendingHigh - 0xd800) << 10) + (unit - 0xdc00) : 0xfffd;
        g.pendingHigh = 0;
    }

    char[8] u8;
    encodeUtf8(cp, u8);
    logEvent("%s utf16=0x%04x cp=U+%04X text=%s repeat=%u sys=%d",
        kind, unit, cast(uint) cp, u8.ptr, repeatBit, sys ? 1 : 0);
}

// ---------------------------------------------------------------------------
// Injection: SendInput at scancode level (wVk=0 + KEYEVENTF_SCANCODE), so the
// active layout — not the injector — decides vk and text, exactly like a
// physical key. Each step's events go in one SendInput batch (atomic order).

void injectScans(scope const(ushort)[] seq) nothrow
{
    INPUT[16] inp;
    const n = cast(UINT) seq.length;
    foreach (i, e; seq)
    {
        inp[i].type = INPUT_KEYBOARD;
        inp[i].ki.wScan = e & 0xff;
        inp[i].ki.dwFlags = KEYEVENTF_SCANCODE | ((e & UP) ? KEYEVENTF_KEYUP : 0);
    }
    const sent = SendInput(n, inp.ptr, INPUT.sizeof);
    logEvent("inject kind=scancode events=%u sent=%u err=%lu",
        n, sent, sent == n ? 0 : GetLastError());
}

void injectUnicode(scope const(wchar)[] units) nothrow
{
    INPUT[8] inp;
    UINT n;
    foreach (u; units) // per unit: down + up, vk = VK_PACKET internally
    {
        inp[n].type = INPUT_KEYBOARD;
        inp[n].ki.wScan = u;
        inp[n].ki.dwFlags = KEYEVENTF_UNICODE;
        n++;
        inp[n] = inp[n - 1];
        inp[n].ki.dwFlags |= KEYEVENTF_KEYUP;
        n++;
    }
    const sent = SendInput(n, inp.ptr, INPUT.sizeof);
    logEvent("inject kind=unicode events=%u sent=%u err=%lu",
        n, sent, sent == n ? 0 : GetLastError());
}

// ---------------------------------------------------------------------------
// Direct table lookup, the no-injection fallback: scan -> vk (MapVirtualKeyEx)
// -> text (ToUnicodeEx) against the start layout and the loaded de layout.
// rc semantics: 1 = one char, 0 = no translation, -1 = DEAD KEY (the char in
// the buffer is the accent itself).

void probeToUnicode(ushort scan) nothrow
{
    static foreach (which; 0 .. 2)
    {
        {
            HKL hkl = which == 0 ? g.hklStart : g.hklDe;
            const vk = MapVirtualKeyExW(scan, MAPVK_VSC_TO_VK, hkl);
            BYTE[256] kstate = 0;
            WCHAR[8] out16 = 0;
            const rc = ToUnicodeEx(vk, scan, kstate.ptr, out16.ptr, out16.length, 0, hkl);
            char[8] u8 = 0;
            encodeUtf8(out16[0], u8);
            logEvent("tounicodeex layout=%s hkl=0x%zx scan=0x%02x vk=0x%02x rc=%d text=%s",
                which == 0 ? "start".ptr : "de".ptr, cast(size_t) hkl,
                scan, vk, rc, rc != 0 ? u8.ptr : "-".ptr);
        }
    }
}

// ---------------------------------------------------------------------------
// The script: one step per WM_TIMER tick, so each batch's messages are pumped
// (and logged) before the next batch is injected.

void runStep(HWND hwnd) nothrow
{
    switch (g.step++)
    {
    case 0: // letter
        logEvent("script step=letter scan=0x%02x", SC.A);
        injectScans([SC.A, SC.A | UP]);
        break;

    case 1: // shifted digit: vk says '2', the text says otherwise
        logEvent("script step=shifted_digit scan=0x%02x", SC.digit2);
        injectScans([SC.lshift, SC.digit2, SC.digit2 | UP, SC.lshift | UP]);
        break;

    case 2: // two keydowns, no keyup between: bit 30 flips on the second
        logEvent("script step=repeat_bit scan=0x%02x", SC.B);
        injectScans([SC.B, SC.B, SC.B | UP]);
        break;

    case 3: // Alt chord -> the WM_SYS* flavor of the same chain
        logEvent("script step=alt_chord scan=0x%02x", SC.C);
        injectScans([SC.lalt, SC.C, SC.C | UP, SC.lalt | UP]);
        break;

    case 4: // switch the thread to German (QWERTZ + dead accents)
        logEvent("script step=load_layout klid=00000407");
        g.hklDe = LoadKeyboardLayoutW("00000407"w.ptr, KLF_ACTIVATE);
        if (g.hklDe is null)
        {
            logEvent("error what=LoadKeyboardLayoutW code=%lu note=de_steps_will_run_on_start_layout",
                GetLastError());
            break;
        }
        ActivateKeyboardLayout(g.hklDe, 0);
        WCHAR[KL_NAMELENGTH] klid;
        GetKeyboardLayoutNameW(klid.ptr);
        // The HKL value alone does not prove the *tables* switched (Wine's
        // headless null driver hands back an 0407-tagged HKL whose mapping is
        // still its built-in default table). Check behaviorally: on a real de
        // (QWERTZ) layout, the QWERTY-Y-position scancode maps to VK 'Z'.
        const vkYde = MapVirtualKeyExW(SC.Y, MAPVK_VSC_TO_VK, g.hklDe);
        logEvent("layout_active hkl=0x%zx klid=%c%c%c%c%c%c%c%c tables=%s",
            cast(size_t) GetKeyboardLayout(0),
            klid[0], klid[1], klid[2], klid[3], klid[4], klid[5], klid[6], klid[7],
            vkYde == 'Z' ? "de".ptr : "fallback_not_de".ptr);
        logEvent("layout_map scan=0x%02x vk_start=0x%02x vk_de=0x%02x", SC.Y,
            MapVirtualKeyExW(SC.Y, MAPVK_VSC_TO_VK, g.hklStart), vkYde);
        logEvent("layout_map scan=0x%02x vk_start=0x%02x vk_de=0x%02x", SC.Z,
            MapVirtualKeyExW(SC.Z, MAPVK_VSC_TO_VK, g.hklStart),
            MapVirtualKeyExW(SC.Z, MAPVK_VSC_TO_VK, g.hklDe));
        // Text-level probes straight off the layout tables, no injection:
        // ToUnicodeEx returns -1 for a dead key. Probing the dead key leaves
        // a pending accent in the thread's translation state, so a space
        // probe follows to flush it (its result is logged too — on a real de
        // layout it yields the standalone accent).
        probeToUnicode(SC.Y);
        probeToUnicode(SC.Z);
        probeToUnicode(SC.acute);
        probeToUnicode(SC.space);
        break;

    case 5: // same physical key as step 0's neighbor: QWERTY Y -> de 'z'
        logEvent("script step=de_y_position scan=0x%02x", SC.Y);
        injectScans([SC.Y, SC.Y | UP]);
        break;

    case 6: // and the mirror: QWERTY Z position -> de 'y'
        logEvent("script step=de_z_position scan=0x%02x", SC.Z);
        injectScans([SC.Z, SC.Z | UP]);
        break;

    case 7: // dead key: acute accent, alone -> WM_DEADCHAR only
        logEvent("script step=dead_acute scan=0x%02x", SC.acute);
        injectScans([SC.acute, SC.acute | UP]);
        break;

    case 8: // ... then E composes: WM_CHAR U+00E9
        logEvent("script step=dead_then_e scan=0x%02x", SC.E);
        injectScans([SC.E, SC.E | UP]);
        break;

    case 9: // supplementary-plane text -> two WM_CHARs (surrogate pair)
        logEvent("script step=unicode_surrogate cp=U+1F600");
        injectUnicode([cast(wchar) 0xd83d, cast(wchar) 0xde00]);
        break;

    default:
        KillTimer(hwnd, TIMER_ID);
        logEvent("summary keydown=%u keyup=%u syskeydown=%u syskeyup=%u char=%u deadchar=%u syschar=%u sysdeadchar=%u inputlangchange=%u",
            g.nKeyDown, g.nKeyUp, g.nSysKeyDown, g.nSysKeyUp,
            g.nChar, g.nDeadChar, g.nSysChar, g.nSysDeadChar, g.nLangChange);
        if (g.autoExit)
            DestroyWindow(hwnd);
        else
            logEvent("script_done note=window_stays_open_for_real_typing");
        break;
    }
}

// ---------------------------------------------------------------------------

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_KEYDOWN:
        ++g.nKeyDown;
        logKey("down", false, wParam, lParam);
        return 0;
    case WM_KEYUP:
        ++g.nKeyUp;
        logKey("up", false, wParam, lParam);
        return 0;
    case WM_SYSKEYDOWN:
        ++g.nSysKeyDown;
        logKey("down", true, wParam, lParam);
        goto default; // DefWindowProcW owns Alt-menu / Alt-F4 handling
    case WM_SYSKEYUP:
        ++g.nSysKeyUp;
        logKey("up", true, wParam, lParam);
        goto default;

    case WM_CHAR:
        ++g.nChar;
        logChar("char", wParam, lParam, false);
        return 0;
    case WM_DEADCHAR:
        ++g.nDeadChar;
        logChar("deadchar", wParam, lParam, false);
        return 0;
    case WM_SYSCHAR:
        ++g.nSysChar;
        logChar("char", wParam, lParam, true);
        goto default;
    case WM_SYSDEADCHAR:
        ++g.nSysDeadChar;
        logChar("deadchar", wParam, lParam, true);
        goto default;

    case WM_INPUTLANGCHANGE:
        ++g.nLangChange;
        logEvent("msg name=WM_INPUTLANGCHANGE charset=%u hkl=0x%zx",
            cast(uint) wParam, cast(size_t) lParam);
        return 1;

    case WM_TIMER:
        if (wParam == TIMER_ID)
            runStep(hwnd);
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
    instrumentInit("f06_keyboard_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    g.noTranslate = envFlag("WSI_NO_TRANSLATE"w.ptr);
    logEvent("mode auto_exit=%d no_translate=%d", g.autoExit ? 1 : 0, g.noTranslate ? 1 : 0);

    HINSTANCE hInst = GetModuleHandleW(null);
    auto clsName = "wsi-f06-class"w;
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
    g.hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f06-keyboard"w.ptr,
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

    // SendInput targets the foreground window's thread; make sure that's us
    // (under Wine's headless null driver the fresh window is, but be explicit).
    SetForegroundWindow(g.hwnd);
    SetFocus(g.hwnd);
    logEvent("focus foreground_is_self=%d focus_is_self=%d",
        GetForegroundWindow() is g.hwnd ? 1 : 0, GetFocus() is g.hwnd ? 1 : 0);

    // Who owns key repeat: the system. Its knobs (and their units) are global.
    g.hklStart = GetKeyboardLayout(0);
    WCHAR[KL_NAMELENGTH] klid;
    GetKeyboardLayoutNameW(klid.ptr);
    logEvent("layout_start hkl=0x%zx klid=%c%c%c%c%c%c%c%c", cast(size_t) g.hklStart,
        klid[0], klid[1], klid[2], klid[3], klid[4], klid[5], klid[6], klid[7]);
    DWORD speed, delay;
    SystemParametersInfoW(SPI_GETKEYBOARDSPEED, 0, &speed, 0); // 0..31 ~= 2.5..30 cps
    SystemParametersInfoW(SPI_GETKEYBOARDDELAY, 0, &delay, 0); // 0..3 ~= 250..1000 ms
    logEvent("repeat_config speed=%lu delay=%lu owner=system", speed, delay);

    SetTimer(g.hwnd, TIMER_ID, TICK_MS, null);

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        // TranslateMessage is the ONLY producer of WM_CHAR/WM_DEADCHAR: it
        // reads WM_(SYS)KEYDOWN + the thread's keyboard state + active layout
        // and posts the text-level message(s). Skip it and the text vanishes.
        if (!g.noTranslate)
            TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    logEvent("exit code=%d", cast(int) msg.wParam);
    return cast(int) msg.wParam;
}

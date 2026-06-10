// F07 — IME / text input, Win32 implementation
// (../../../features/f07-text-input.md). Extends the scaffold
// (../scaffold/app.d) into an IME observatory with two layers:
//
//   * TSF probe (the spec-mandated decision record): a minimal COM bring-up of
//     the Text Services Framework from plain D — CoInitializeEx ->
//     CoCreateInstance(CLSID_TF_ThreadMgr) -> ITfThreadMgr.Activate ->
//     CreateDocumentMgr -> CreateContext(punk=null) -> Push -> AssociateFocus.
//     druntime's core.sys.windows has no msctf.h projection, so the two vtbls
//     and three GUIDs are hand-declared below. The probe logs every HRESULT
//     and a tsf_verdict, then tears everything down: real TSF text input
//     requires the app to implement ITextStoreACP (~30 methods) + sink
//     interfaces, which is the documented reason the demo's editor speaks
//     IMM32 (see the findings doc, ../../f07-text-input.md).
//   * IMM32 editor (implemented fully): an editable line with a caret
//     (CreateCaret/SetCaretPos), the WM_IME_STARTCOMPOSITION ->
//     WM_IME_COMPOSITION (ImmGetCompositionStringW GCS_COMPSTR + GCS_COMPATTR
//     + GCS_CURSORPOS, GCS_RESULTSTR) -> WM_IME_ENDCOMPOSITION choreography,
//     inline underlined pre-edit rendering, and ImmSetCandidateWindow
//     (CANDIDATEFORM CFS_EXCLUDE anchored at the caret, re-set on every caret
//     move). WM_IME_SETCONTEXT / WM_IME_NOTIFY / ImmGetDefaultIMEWnd are
//     logged; an ImmAssociateContext(null) probe disables and restores the IME.
//
// Under Wine without a real IME the composition messages cannot fire from
// typing, so a WSI_AUTO_EXIT=1 script probes what imm32 provides: typed ASCII
// (caret + candidate-anchor movement), an ImmSetCompositionStringW(SCS_SETSTR)
// self-injection, NI_COMPOSITIONSTR commit/cancel, and the associate-null
// round-trip. The full CJK choreography is the Tier-C manual script in the
// findings doc.
//
// Only druntime's built-in core.sys.windows bindings — no third-party packages.
module app;

import core.sys.windows.windows;
import core.sys.windows.imm;
import core.sys.windows.objbase : CoInitializeEx, CoUninitialize, CoCreateInstance, COINIT;
import core.sys.windows.wtypes : CLSCTX;
import instrument;

pragma(lib, "imm32");
pragma(lib, "ole32");

// ---------------------------------------------------------------------------
// druntime's core.sys.windows.imm declares `alias DWORD HIMC` — but the real
// HIMC is a pointer-sized DECLARE_HANDLE, so on Win64 those prototypes
// truncate the handle (and none are nothrow, which a WndProc needs). The
// constants/structs (WM_IME_*, GCS_*, CFS_*, CANDIDATEFORM, …) are fine;
// the used function surface is redeclared correctly here (module-level
// declarations take precedence over imports). A finding in its own right —
// see ../../f07-text-input.md.

alias HIMC = HANDLE;

extern (Windows) nothrow @nogc
{
    HIMC ImmGetContext(HWND);
    BOOL ImmReleaseContext(HWND, HIMC);
    HIMC ImmAssociateContext(HWND, HIMC);
    HWND ImmGetDefaultIMEWnd(HWND);
    BOOL ImmGetOpenStatus(HIMC);
    BOOL ImmGetConversionStatus(HIMC, LPDWORD, LPDWORD);
    UINT ImmGetDescriptionW(HKL, LPWSTR, UINT);
    LONG ImmGetCompositionStringW(HIMC, DWORD, PVOID, DWORD);
    BOOL ImmSetCompositionStringW(HIMC, DWORD, PCVOID, DWORD, PCVOID, DWORD);
    BOOL ImmNotifyIME(HIMC, DWORD, DWORD, DWORD);
    BOOL ImmSetCandidateWindow(HIMC, PCANDIDATEFORM);
    BOOL ImmSetCompositionWindow(HIMC, PCOMPOSITIONFORM);
}

// ---------------------------------------------------------------------------
// TSF surface — hand-declared. druntime has IUnknown but nothing from msctf.h;
// these are the exact vtbl orders of the msctf.h interfaces (Windows SDK).

alias TfClientId = DWORD;
alias TfEditCookie = DWORD;
enum TF_POPF_ALL = 0x1;

interface ITfContext : IUnknown {} // opaque here — no method is called on it

interface ITfDocumentMgr : IUnknown
{
extern (Windows) nothrow:
    HRESULT CreateContext(TfClientId tidOwner, DWORD dwFlags, IUnknown punk,
        ITfContext* ppic, TfEditCookie* pecTextStore);
    HRESULT Push(ITfContext pic);
    HRESULT Pop(DWORD dwFlags);
    HRESULT GetTop(ITfContext* ppic);
    HRESULT GetBase(ITfContext* ppic);
    HRESULT EnumContexts(void** ppEnum);
}

interface ITfThreadMgr : IUnknown
{
extern (Windows) nothrow:
    HRESULT Activate(TfClientId* ptid);
    HRESULT Deactivate();
    HRESULT CreateDocumentMgr(ITfDocumentMgr* ppdim);
    HRESULT EnumDocumentMgrs(void** ppEnum);
    HRESULT GetFocus(ITfDocumentMgr* ppdimFocus);
    HRESULT SetFocus(ITfDocumentMgr pdimFocus);
    HRESULT AssociateFocus(HWND hwnd, ITfDocumentMgr pdimNew, ITfDocumentMgr* ppdimPrev);
    HRESULT IsThreadFocus(BOOL* pfThreadFocus);
    HRESULT GetFunctionProvider(REFCLSID clsid, void** ppFuncProv);
    HRESULT EnumFunctionProviders(void** ppEnum);
    HRESULT GetGlobalCompartment(void** ppCompMgr);
}

immutable GUID CLSID_TF_ThreadMgr =
    {0x529a9e6b, 0x6587, 0x4f23, [0xab, 0x9e, 0x9c, 0x7d, 0x68, 0x3e, 0x3c, 0x50]};
immutable GUID IID_ITfThreadMgr =
    {0xaa80e801, 0x2021, 0x11d2, [0x93, 0xe0, 0x00, 0x60, 0xb0, 0x67, 0xb8, 0x6e]};

// The minimal bring-up: how far plain D gets into TSF without ITextStoreACP.
// Every step logs its HRESULT; the verdict line records where it stopped.
// (Not nothrow: IUnknown.Release in druntime is a throwing prototype. The
// probe runs from main, never from the WndProc, so that is acceptable.)
void tsfProbe(HWND hwnd)
{
    auto hr = CoInitializeEx(null, COINIT.COINIT_APARTMENTTHREADED);
    logEvent("tsf step=CoInitializeEx hr=0x%08lx", hr);

    ITfThreadMgr tm;
    hr = CoCreateInstance(&CLSID_TF_ThreadMgr, null, CLSCTX.CLSCTX_INPROC_SERVER,
        &IID_ITfThreadMgr, cast(void**)&tm);
    logEvent("tsf step=CoCreateInstance clsid=TF_ThreadMgr hr=0x%08lx ptr=%d",
        hr, tm !is null ? 1 : 0);
    if (tm is null)
    {
        logEvent("tsf_verdict reached=none note=thread_mgr_unavailable");
        return;
    }

    TfClientId tid;
    hr = tm.Activate(&tid);
    logEvent("tsf step=Activate hr=0x%08lx client_id=0x%lx", hr, tid);

    ITfDocumentMgr dm;
    hr = tm.CreateDocumentMgr(&dm);
    logEvent("tsf step=CreateDocumentMgr hr=0x%08lx ptr=%d", hr, dm !is null ? 1 : 0);

    ITfContext ic;
    TfEditCookie cookie;
    if (dm !is null)
    {
        // punk=null is allowed ("the context does not have a text store") but
        // an IME can then neither read nor edit the document — the exact gap
        // a real integration fills by implementing ITextStoreACP.
        hr = dm.CreateContext(tid, 0, null, &ic, &cookie);
        logEvent("tsf step=CreateContext punk=null hr=0x%08lx cookie=0x%lx", hr, cookie);
        if (ic !is null)
        {
            hr = dm.Push(ic);
            logEvent("tsf step=Push hr=0x%08lx", hr);
        }
        ITfDocumentMgr prev;
        hr = tm.AssociateFocus(hwnd, dm, &prev);
        logEvent("tsf step=AssociateFocus hr=0x%08lx prev=%d", hr, prev !is null ? 1 : 0);
        if (prev !is null)
            prev.Release();
    }

    logEvent("tsf_verdict reached=%s note=no_ITextStoreACP_so_no_editable_store",
        ic !is null ? "context_pushed_and_focused".ptr : "thread_mgr_only".ptr);

    // Full teardown so the IMM32 half below runs on a clean thread.
    ITfDocumentMgr prev2;
    tm.AssociateFocus(hwnd, null, &prev2);
    if (prev2 !is null)
        prev2.Release();
    if (dm !is null)
        dm.Pop(TF_POPF_ALL);
    if (ic !is null)
        ic.Release();
    if (dm !is null)
        dm.Release();
    hr = tm.Deactivate();
    logEvent("tsf step=Deactivate hr=0x%08lx", hr);
    tm.Release();
}

// ---------------------------------------------------------------------------
// Editor state. Committed text + caret index, plus the live pre-edit run that
// is rendered inline (underlined) at the caret during a composition.

enum MARGIN = 12; // text origin inside the client area
enum UINT_PTR TIMER_ID = 1;
enum TICK_MS = 150; // one script step per tick

struct Demo
{
    HWND hwnd;
    HIMC himcSaved; // != null while the associate-null probe is active
    wchar[256] text; // committed text
    int len, caret; // committed length / caret index into text[]
    wchar[64] preedit; // live composition string (GCS_COMPSTR)
    int preLen, preCursor; // pre-edit length / cursor (GCS_CURSORPOS)
    int lineHeight = 16;
    bool composing, autoExit, focused;
    uint step;
    uint nStart, nComp, nEnd, nSetCtx, nNotify, nImeChar, nChar, nCommit;
}

__gshared Demo g;

void utf8z(scope const(wchar)[] s, scope char[] o) nothrow @nogc
{
    size_t n;
    foreach (i, wchar u; s) // unpaired-surrogate-naive: fine for log lines
    {
        dchar c = u;
        if (u >= 0xd800 && u <= 0xdbff && i + 1 < s.length)
            continue; // high unit: emit at the low unit
        if (u >= 0xdc00 && u <= 0xdfff && i > 0)
            c = 0x10000 + ((s[i - 1] - 0xd800) << 10) + (u - 0xdc00);
        if (n + 5 > o.length)
            break;
        if (c < 0x80)
            o[n++] = cast(char) c;
        else if (c < 0x800)
        {
            o[n++] = cast(char)(0xc0 | (c >> 6));
            o[n++] = cast(char)(0x80 | (c & 0x3f));
        }
        else if (c < 0x10000)
        {
            o[n++] = cast(char)(0xe0 | (c >> 12));
            o[n++] = cast(char)(0x80 | ((c >> 6) & 0x3f));
            o[n++] = cast(char)(0x80 | (c & 0x3f));
        }
        else
        {
            o[n++] = cast(char)(0xf0 | (c >> 18));
            o[n++] = cast(char)(0x80 | ((c >> 12) & 0x3f));
            o[n++] = cast(char)(0x80 | ((c >> 6) & 0x3f));
            o[n++] = cast(char)(0x80 | (c & 0x3f));
        }
    }
    o[n] = 0;
}

// Pixel x of the caret = extent of committed-before-caret + pre-edit-cursor.
int caretX(HDC hdc) nothrow
{
    SIZE sz;
    int x = MARGIN;
    if (g.caret > 0 && GetTextExtentPoint32W(hdc, g.text.ptr, g.caret, &sz))
        x += sz.cx;
    if (g.composing && g.preCursor > 0
        && GetTextExtentPoint32W(hdc, g.preedit.ptr, g.preCursor, &sz))
        x += sz.cx;
    return x;
}

// The candidate-window anchoring contract: tell the IME where the caret is so
// the candidate list opens beside it and never covers the composition. The
// CFS_EXCLUDE rect is the caret line; re-sent on EVERY caret move.
void anchorCandidateWindow() nothrow
{
    HIMC himc = ImmGetContext(g.hwnd);
    if (himc is null)
    {
        logEvent("candidate_anchor skipped=no_himc");
        return;
    }
    HDC hdc = GetDC(g.hwnd);
    HGDIOBJ old = SelectObject(hdc, GetStockObject(DEFAULT_GUI_FONT));
    const x = caretX(hdc);
    SelectObject(hdc, old);
    ReleaseDC(g.hwnd, hdc);

    CANDIDATEFORM cf;
    cf.dwIndex = 0;
    cf.dwStyle = CFS_EXCLUDE;
    cf.ptCurrentPos = POINT(x, MARGIN + g.lineHeight);
    cf.rcArea = RECT(x, MARGIN, x + 2, MARGIN + g.lineHeight);
    const ok = ImmSetCandidateWindow(himc, &cf);
    // Keep the composition window (the IME's inline-fallback UI) at the caret
    // too — IMEs that ignore CANDIDATEFORM still honor COMPOSITIONFORM.
    COMPOSITIONFORM comp;
    comp.dwStyle = CFS_POINT;
    comp.ptCurrentPos = POINT(x, MARGIN);
    const ok2 = ImmSetCompositionWindow(himc, &comp);
    ImmReleaseContext(g.hwnd, himc);
    logEvent("candidate_anchor x=%d y=%d style=CFS_EXCLUDE ok=%d comp_ok=%d",
        x, MARGIN + g.lineHeight, ok ? 1 : 0, ok2 ? 1 : 0);
}

void moveCaret(int delta) nothrow
{
    const next = g.caret + delta;
    if (next < 0 || next > g.len)
        return;
    g.caret = next;
    logEvent("caret index=%d", g.caret);
    InvalidateRect(g.hwnd, null, TRUE);
    anchorCandidateWindow(); // the caret moved -> re-report the rectangle
}

void insertText(scope const(wchar)[] s) nothrow
{
    foreach (u; s)
    {
        if (g.len >= g.text.length)
            break;
        foreach_reverse (i; g.caret .. g.len)
            g.text[i + 1] = g.text[i];
        g.text[g.caret++] = u;
        g.len++;
    }
    InvalidateRect(g.hwnd, null, TRUE);
    anchorCandidateWindow();
}

// ---------------------------------------------------------------------------
// WM_IME_COMPOSITION payload readers.

int readImeString(HIMC himc, DWORD what, scope wchar[] o) nothrow
{
    const n = ImmGetCompositionStringW(himc, what, o.ptr, cast(DWORD)(o.length * 2));
    return n > 0 ? n / 2 : 0; // byte count -> wchar count (negative = error)
}

void onImeComposition(HWND hwnd, LPARAM lParam) nothrow
{
    ++g.nComp;
    logEvent("msg name=WM_IME_COMPOSITION flags=0x%llx", cast(ulong) lParam);
    HIMC himc = ImmGetContext(hwnd);
    if (himc is null)
        return;
    if (lParam & GCS_RESULTSTR) // committed text replaces the pre-edit
    {
        wchar[64] r;
        const n = readImeString(himc, GCS_RESULTSTR, r);
        char[256] u8;
        utf8z(r[0 .. n], u8);
        logEvent("commit text=%s units=%d", u8.ptr, n);
        ++g.nCommit;
        g.preLen = 0;
        insertText(r[0 .. n]);
    }
    if (lParam & GCS_COMPSTR) // the live pre-edit + its attributes + cursor
    {
        g.preLen = readImeString(himc, GCS_COMPSTR, g.preedit);
        ubyte[64] attr;
        const an = ImmGetCompositionStringW(himc, GCS_COMPATTR, attr.ptr, attr.length);
        const cur = ImmGetCompositionStringW(himc, GCS_CURSORPOS, null, 0);
        g.preCursor = cur >= 0 ? cur : 0;
        char[256] u8;
        utf8z(g.preedit[0 .. g.preLen], u8);
        char[80] a8;
        size_t ai;
        foreach (i; 0 .. (an > 0 && an < 40 ? an : 0)) // ATTR_* byte per wchar
            a8[ai++] = cast(char)('0' + (attr[i] % 10));
        a8[ai] = 0;
        logEvent("preedit text=%s units=%d cursor=%d attr=%s",
            u8.ptr, g.preLen, g.preCursor, ai ? a8.ptr : "-".ptr);
    }
    if (lParam == 0) // composition canceled: clear the pre-edit
    {
        g.preLen = g.preCursor = 0;
        logEvent("preedit_cleared reason=flags_zero");
    }
    ImmReleaseContext(hwnd, himc);
    InvalidateRect(hwnd, null, TRUE);
    anchorCandidateWindow();
}

// ---------------------------------------------------------------------------
// Painting: committed text, then the pre-edit inline at the caret with a 1-px
// underline (the visual contract: pre-edit must be distinct from committed).

void paint(HWND hwnd) nothrow
{
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT rc;
    GetClientRect(hwnd, &rc);
    FillRect(hdc, &rc, cast(HBRUSH)(COLOR_WINDOW + 1));
    HGDIOBJ oldFont = SelectObject(hdc, GetStockObject(DEFAULT_GUI_FONT));
    SetBkMode(hdc, TRANSPARENT);

    TEXTMETRICW tm;
    GetTextMetricsW(hdc, &tm);
    g.lineHeight = tm.tmHeight;

    int x = MARGIN;
    SIZE sz;
    TextOutW(hdc, x, MARGIN, g.text.ptr, g.caret); // committed, before caret
    if (g.caret && GetTextExtentPoint32W(hdc, g.text.ptr, g.caret, &sz))
        x += sz.cx;
    if (g.preLen) // the pre-edit run, underlined
    {
        TextOutW(hdc, x, MARGIN, g.preedit.ptr, g.preLen);
        GetTextExtentPoint32W(hdc, g.preedit.ptr, g.preLen, &sz);
        HPEN pen = CreatePen(PS_SOLID, 1, RGB(0, 0, 0));
        HGDIOBJ oldPen = SelectObject(hdc, pen);
        MoveToEx(hdc, x, MARGIN + g.lineHeight + 1, null);
        LineTo(hdc, x + sz.cx, MARGIN + g.lineHeight + 1);
        SelectObject(hdc, oldPen);
        DeleteObject(pen);
        x += sz.cx;
    }
    TextOutW(hdc, x, MARGIN, g.text.ptr + g.caret, g.len - g.caret); // after caret

    if (g.focused)
        SetCaretPos(caretX(hdc), MARGIN);
    SelectObject(hdc, oldFont);
    EndPaint(hwnd, &ps);
}

// ---------------------------------------------------------------------------
// SendInput at scancode level (same shape as ../f06-keyboard/app.d).

void injectScans(scope const(ushort)[] seq) nothrow
{
    INPUT[8] inp;
    foreach (i, e; seq)
    {
        inp[i].type = INPUT_KEYBOARD;
        inp[i].ki.wScan = e & 0xff;
        inp[i].ki.dwFlags = KEYEVENTF_SCANCODE | ((e & 0x8000) ? KEYEVENTF_KEYUP : 0);
    }
    const sent = SendInput(cast(UINT) seq.length, inp.ptr, INPUT.sizeof);
    logEvent("inject kind=scancode events=%d sent=%u", cast(int) seq.length, sent);
}

// ---------------------------------------------------------------------------
// The script: what an IME-less host (Wine headless) lets us prove, one step
// per timer tick. Steps 2-4 are the SCS_SETSTR/NI_COMPOSITIONSTR self-
// injection probe — if imm32 echoes WM_IME_COMPOSITION back, the choreography
// handlers above capture it.

void runStep(HWND hwnd) nothrow
{
    switch (g.step++)
    {
    case 0:
        logEvent("script step=probe_imm");
        HIMC himc = ImmGetContext(hwnd);
        logEvent("imm context himc=0x%zx", cast(size_t) himc);
        logEvent("imm default_ime_wnd hwnd=0x%zx",
            cast(size_t) ImmGetDefaultIMEWnd(hwnd));
        logEvent("imm open_status open=%d", himc ? (ImmGetOpenStatus(himc) ? 1 : 0) : -1);
        DWORD conv, sent;
        const cs = himc ? ImmGetConversionStatus(himc, &conv, &sent) : FALSE;
        logEvent("imm conversion_status ok=%d conversion=0x%lx sentence=0x%lx",
            cs ? 1 : 0, conv, sent);
        WCHAR[64] desc;
        const dn = ImmGetDescriptionW(GetKeyboardLayout(0), desc.ptr, desc.length);
        logEvent("imm description len=%u note=%s", dn,
            dn ? "ime_layout".ptr : "not_an_ime_layout".ptr);
        if (himc)
            ImmReleaseContext(hwnd, himc);
        break;

    case 1: // plain typing: caret moves, candidate anchor re-sent per char
        logEvent("script step=type_ascii text=ab");
        injectScans([0x1e, 0x1e | 0x8000, 0x30, 0x30 | 0x8000]); // a, b
        break;

    case 2: // self-injection: ask the IME to set the composition string
        logEvent("script step=set_composition_string text=nihao");
        HIMC himc = ImmGetContext(hwnd);
        auto s = "nihao"w;
        const ok = ImmSetCompositionStringW(himc, SCS_SETSTR,
            cast(void*) s.ptr, cast(DWORD)(s.length * 2), null, 0);
        logEvent("imm set_composition_string scs=SCS_SETSTR ok=%d err=%lu",
            ok ? 1 : 0, ok ? 0 : GetLastError());
        ImmReleaseContext(hwnd, himc);
        break;

    case 3: // commit whatever composition exists
        logEvent("script step=notify_complete");
        HIMC himc = ImmGetContext(hwnd);
        const ok = ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_COMPLETE, 0);
        logEvent("imm notify_ime action=CPS_COMPLETE ok=%d", ok ? 1 : 0);
        ImmReleaseContext(hwnd, himc);
        break;

    case 4: // and the cancel path
        logEvent("script step=notify_cancel");
        HIMC himc = ImmGetContext(hwnd);
        auto s = "x"w;
        ImmSetCompositionStringW(himc, SCS_SETSTR, cast(void*) s.ptr, 2, null, 0);
        const ok = ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
        logEvent("imm notify_ime action=CPS_CANCEL ok=%d", ok ? 1 : 0);
        ImmReleaseContext(hwnd, himc);
        break;

    case 5: // IME disable: ImmAssociateContext(null) detaches the context
        logEvent("script step=associate_null");
        g.himcSaved = ImmAssociateContext(hwnd, null);
        logEvent("imm associate_context new=0 old=0x%zx now=0x%zx",
            cast(size_t) g.himcSaved, cast(size_t) ImmGetContext(hwnd));
        injectScans([0x2e, 0x2e | 0x8000]); // 'c' still arrives: plain WM_CHAR
        break;

    case 6: // restore
        logEvent("script step=associate_restore");
        ImmAssociateContext(hwnd, g.himcSaved);
        logEvent("imm associate_context new=0x%zx now=0x%zx",
            cast(size_t) g.himcSaved, cast(size_t) ImmGetContext(hwnd));
        break;

    default:
        KillTimer(hwnd, TIMER_ID);
        char[256] u8;
        utf8z(g.text[0 .. g.len], u8);
        logEvent("summary text=%s caret=%d start=%u comp=%u end=%u setctx=%u notify=%u imechar=%u char=%u commit=%u",
            u8.ptr, g.caret, g.nStart, g.nComp, g.nEnd, g.nSetCtx, g.nNotify,
            g.nImeChar, g.nChar, g.nCommit);
        if (g.autoExit)
            DestroyWindow(hwnd);
        else
            logEvent("script_done note=window_stays_open_for_real_ime_typing");
    }
}

// ---------------------------------------------------------------------------

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    switch (msg)
    {
    case WM_IME_SETCONTEXT:
        ++g.nSetCtx;
        logEvent("msg name=WM_IME_SETCONTEXT active=%d show=0x%llx",
            cast(int) wParam, cast(ulong) lParam);
        // We render the composition inline, so suppress the IME's own
        // composition-window UI; candidate UI stays (the IME draws the list).
        return DefWindowProcW(hwnd, msg, wParam,
            lParam & ~cast(LPARAM) ISC_SHOWUICOMPOSITIONWINDOW);

    case WM_IME_STARTCOMPOSITION:
        ++g.nStart;
        logEvent("msg name=WM_IME_STARTCOMPOSITION");
        g.composing = true;
        anchorCandidateWindow();
        return 0; // not DefWindowProc: we own the composition rendering

    case WM_IME_COMPOSITION:
        onImeComposition(hwnd, lParam);
        return 0;

    case WM_IME_ENDCOMPOSITION:
        ++g.nEnd;
        logEvent("msg name=WM_IME_ENDCOMPOSITION");
        g.composing = false;
        g.preLen = g.preCursor = 0;
        InvalidateRect(hwnd, null, TRUE);
        return 0;

    case WM_IME_NOTIFY:
        ++g.nNotify;
        logEvent("msg name=WM_IME_NOTIFY cmd=0x%llx", cast(ulong) wParam);
        goto default; // IMN_* housekeeping belongs to DefWindowProc

    case WM_IME_CHAR: // result chars arrive here only if GCS_RESULTSTR is
        ++g.nImeChar; // left unhandled — counting it proves we consumed it
        logEvent("msg name=WM_IME_CHAR utf16=0x%04llx", cast(ulong) wParam);
        return 0;

    case WM_CHAR:
        ++g.nChar;
        const wchar u = cast(wchar) wParam;
        logEvent("char utf16=0x%04x", u);
        if (u == 8 && g.caret > 0) // backspace
        {
            foreach (i; g.caret .. g.len)
                g.text[i - 1] = g.text[i];
            g.len--;
            moveCaret(-1);
        }
        else if (u >= 0x20)
        {
            wchar[1] one = u;
            insertText(one[]);
        }
        return 0;

    case WM_KEYDOWN:
        if (wParam == VK_LEFT)
            moveCaret(-1);
        else if (wParam == VK_RIGHT)
            moveCaret(1);
        return 0;

    case WM_SETFOCUS:
        g.focused = true;
        CreateCaret(hwnd, null, 1, g.lineHeight);
        ShowCaret(hwnd);
        InvalidateRect(hwnd, null, TRUE);
        return 0;
    case WM_KILLFOCUS:
        g.focused = false;
        DestroyCaret();
        return 0;

    case WM_PAINT:
        paint(hwnd);
        return 0;
    case WM_TIMER:
        if (wParam == TIMER_ID)
            runStep(hwnd);
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
    instrumentInit("f07_text_input_win32");
    logEvent("init_start");
    g.autoExit = envFlag("WSI_AUTO_EXIT"w.ptr);
    logEvent("mode auto_exit=%d", g.autoExit ? 1 : 0);

    HINSTANCE hInst = GetModuleHandleW(null);
    auto clsName = "wsi-f07-class"w;
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
    g.hwnd = CreateWindowExW(0, clsName.ptr, "wsi-f07-text-input"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 160,
        null, null, hInst, null);
    if (g.hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 1;
    }
    logEvent("window_created");

    // The decision record: TSF first (and torn down), IMM32 as the editor.
    tsfProbe(g.hwnd);

    ShowWindow(g.hwnd, SW_SHOW);
    UpdateWindow(g.hwnd);
    SetForegroundWindow(g.hwnd);
    SetFocus(g.hwnd);
    anchorCandidateWindow();

    SetTimer(g.hwnd, TIMER_ID, TICK_MS, null);
    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    CoUninitialize();
    logEvent("exit code=%d", cast(int) msg.wParam);
    return cast(int) msg.wParam;
}

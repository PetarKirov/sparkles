// Win32 F16 — clipboard + drag-and-drop (../../../features/f16-clipboard-dnd.md),
// built on the scaffold (../scaffold/app.d). One process, two roles:
//
//   * default role: a window that walks a timer-driven phase schedule —
//       1. paste_startup    enumerate + read whatever is on the clipboard at
//                           launch (the host-bridging probe: preload with
//                           wl-copy/xclip and see if Wine imported it);
//       2. copy_immediate   OpenClipboard/EmptyClipboard/SetClipboardData
//                           (CF_UNICODETEXT, GMEM_MOVEABLE HGLOBAL) with
//                           "é漢🎈", then read it back and log the formats
//                           Windows synthesizes around it;
//       3. spawn a reader   (--reader child in the same prefix) proving two
//                           Wine processes share the prefix clipboard;
//       4. copy_delayed     SetClipboardData(CF_UNICODETEXT, NULL) — delayed
//                           rendering; a reader THREAD demands the data 300 ms
//                           later and the WM_RENDERFORMAT arrival is timed;
//       5. copy_delayed2    delayed again, demanded by a spawned reader
//                           PROCESS — cross-process WM_RENDERFORMAT;
//       6. grab             a worker takes clipboard ownership ->
//                           WM_DESTROYCLIPBOARD (ownership loss) +
//                           WM_CLIPBOARDUPDATE (AddClipboardFormatListener);
//       7. dnd              OLE drag-and-drop entirely in-process: a
//                           hand-rolled (raw vtable) IDataObject + IDropSource
//                           DoDragDrop'd onto this window's own hand-rolled
//                           IDropTarget (RegisterDragDrop), CF_HDROP carrying
//                           a real temp file; the full DragEnter/DragOver/
//                           Drop negotiation and DROPEFFECT_* are logged;
//       8. destroy with an unrendered delayed format still owned ->
//                           WM_RENDERALLFORMATS (who pays when the source
//                           exits) — then clean exit 0.
//   * --reader role: opens the clipboard (retry loop), logs the offered
//     formats and the CF_UNICODETEXT byte count + content match, exits 0.
//
// COM is done with hand-declared vtables (no druntime ole2 imports): the
// binary layout is the contract under test. OleInitialize — NOT CoInitialize —
// is required for RegisterDragDrop/DoDragDrop (clipboard+DnD live in ole32).
// A watchdog thread + SEH filter guarantee the log survives and the process
// exits 0 whatever OLE does under a headless Wine driver.
module app;

import core.stdc.stdio : snprintf;
import core.stdc.string : memcmp, memcpy;
import core.sys.windows.windows;
import instrument;

pragma(lib, "ole32");
pragma(lib, "shell32");

// ---------------------------------------------------------------------------
// Win32/OLE declarations missing from druntime's core.sys.windows.

enum UINT WM_CLIPBOARDUPDATE = 0x031D;
enum DWORD DROPEFFECT_NONE = 0, DROPEFFECT_COPY = 1, DROPEFFECT_MOVE = 2,
    DROPEFFECT_LINK = 4;
enum HRESULT DRAGDROP_S_DROP = 0x00040100, DRAGDROP_S_CANCEL = 0x00040101,
    DRAGDROP_S_USEDEFAULTCURSORS = 0x00040102;
enum HRESULT E_NOINTERFACE = cast(HRESULT) 0x80004002,
    E_NOTIMPL = cast(HRESULT) 0x80004001,
    DV_E_FORMATETC = cast(HRESULT) 0x80040064,
    OLE_E_ADVISENOTSUPPORTED = cast(HRESULT) 0x80040003;
enum DWORD DVASPECT_CONTENT = 1, TYMED_HGLOBAL = 1, DATADIR_GET = 1;

struct FORMATETC
{
    ushort cfFormat; // CLIPFORMAT
    void* ptd;
    DWORD dwAspect;
    int lindex;
    DWORD tymed;
}

struct STGMEDIUM
{
    DWORD tymed;
    void* hGlobal; // the union collapsed to the one arm used here
    void* pUnkForRelease;
}

struct DROPFILES
{
    DWORD pFiles; // offset of the file list from the struct start
    POINT pt;
    BOOL fNC;
    BOOL fWide; // TRUE: the list is UTF-16
}

struct POINTL
{
    LONG x, y;
}

extern (Windows) nothrow @nogc
{
    HRESULT OleInitialize(void*);
    void OleUninitialize();
    HRESULT RegisterDragDrop(HWND, void*);
    HRESULT RevokeDragDrop(HWND);
    HRESULT DoDragDrop(void* dataObj, void* dropSource, DWORD okEffects,
        DWORD* effect);
    void ReleaseStgMedium(STGMEDIUM*);
    UINT DragQueryFileW(void* hDrop, UINT iFile, wchar* buf, UINT cch);
    BOOL AddClipboardFormatListener(HWND);
    DWORD GetClipboardSequenceNumber();
}

// IIDs (hand-declared; values from the platform SDK headers).
__gshared immutable GUID IID_IUnknown =
    GUID(0, 0, 0, [0xC0, 0, 0, 0, 0, 0, 0, 0x46]);
__gshared immutable GUID IID_IDataObject =
    GUID(0x10e, 0, 0, [0xC0, 0, 0, 0, 0, 0, 0, 0x46]);
__gshared immutable GUID IID_IDropSource =
    GUID(0x121, 0, 0, [0xC0, 0, 0, 0, 0, 0, 0, 0x46]);
__gshared immutable GUID IID_IDropTarget =
    GUID(0x122, 0, 0, [0xC0, 0, 0, 0, 0, 0, 0, 0x46]);
__gshared immutable GUID IID_IEnumFORMATETC =
    GUID(0x103, 0, 0, [0xC0, 0, 0, 0, 0, 0, 0, 0x46]);

bool sameGuid(const(GUID)* a, const(GUID)* b) nothrow @nogc
{
    return memcmp(a, b, GUID.sizeof) == 0;
}

// ---------------------------------------------------------------------------
// Hand-declared COM vtables. Every interface here is { vtbl*, refs } with a
// static vtbl of extern(Windows) function pointers — the raw ABI a framework
// binding has to reproduce. Refcounting is a formality (static lifetime).

extern (Windows) nothrow
{
    alias FnQI = HRESULT function(void*, const(GUID)*, void**);
    alias FnRef = ULONG function(void*);
    // IDropTarget
    alias FnDragEnter = HRESULT function(void*, void*, DWORD, POINTL, DWORD*);
    alias FnDragOver = HRESULT function(void*, DWORD, POINTL, DWORD*);
    alias FnDragLeave = HRESULT function(void*);
    // IDropSource
    alias FnQueryContinueDrag = HRESULT function(void*, BOOL, DWORD);
    alias FnGiveFeedback = HRESULT function(void*, DWORD);
    // IDataObject
    alias FnGetData = HRESULT function(void*, FORMATETC*, STGMEDIUM*);
    alias FnQueryGetData = HRESULT function(void*, FORMATETC*);
    alias FnGetCanonical = HRESULT function(void*, FORMATETC*, FORMATETC*);
    alias FnSetData = HRESULT function(void*, FORMATETC*, STGMEDIUM*, BOOL);
    alias FnEnumFormatEtc = HRESULT function(void*, DWORD, void**);
    alias FnDAdvise = HRESULT function(void*, FORMATETC*, DWORD, void*, DWORD*);
    alias FnDUnadvise = HRESULT function(void*, DWORD);
    alias FnEnumDAdvise = HRESULT function(void*, void**);
    // IEnumFORMATETC
    alias FnEnumNext = HRESULT function(void*, ULONG, FORMATETC*, ULONG*);
    alias FnEnumSkip = HRESULT function(void*, ULONG);
    alias FnEnumReset = HRESULT function(void*);
    alias FnEnumClone = HRESULT function(void*, void**);
}

struct DropTargetVtbl
{
    FnQI QueryInterface;
    FnRef AddRef, Release;
    FnDragEnter DragEnter;
    FnDragOver DragOver;
    FnDragLeave DragLeave;
    FnDragEnter Drop; // same signature as DragEnter
}

struct DropSourceVtbl
{
    FnQI QueryInterface;
    FnRef AddRef, Release;
    FnQueryContinueDrag QueryContinueDrag;
    FnGiveFeedback GiveFeedback;
}

struct DataObjectVtbl
{
    FnQI QueryInterface;
    FnRef AddRef, Release;
    FnGetData GetData;
    FnGetData GetDataHere;
    FnQueryGetData QueryGetData;
    FnGetCanonical GetCanonicalFormatEtc;
    FnSetData SetData;
    FnEnumFormatEtc EnumFormatEtc;
    FnDAdvise DAdvise;
    FnDUnadvise DUnadvise;
    FnEnumDAdvise EnumDAdvise;
}

struct EnumFmtVtbl
{
    FnQI QueryInterface;
    FnRef AddRef, Release;
    FnEnumNext Next;
    FnEnumSkip Skip;
    FnEnumReset Reset;
    FnEnumClone Clone;
}

struct ComObj(Vtbl)
{
    Vtbl* vtbl;
    LONG refs = 1;
    uint cursor; // EnumFORMATETC position / DropSource call counter
}

// ---------------------------------------------------------------------------
// Demo state.

struct Demo
{
    HINSTANCE inst;
    HWND hwnd;
    uint ticks;
    bool autoExit;
    int phase; // index into the schedule, for log readability
    long delayedSetAt; // when SetClipboardData(fmt, NULL) was issued
    int renderDemands; // WM_RENDERFORMAT count
    int renderAll; // WM_RENDERALLFORMATS count
    bool dndDone;
    HANDLE hDropFiles; // CF_HDROP HGLOBAL template (owned by the source)
    WCHAR[MAX_PATH] dropPath;
    ComObj!DropTargetVtbl target;
    ComObj!DropSourceVtbl source;
    ComObj!DataObjectVtbl data;
}

__gshared Demo g;
__gshared immutable wchar[] PAYLOAD = "é漢🎈\0"w; // 4 UTF-16 units + NUL
enum PAYLOAD_BYTES = PAYLOAD.length * 2; // 10

__gshared DropTargetVtbl gTargetVtbl;
__gshared DropSourceVtbl gSourceVtbl;
__gshared DataObjectVtbl gDataVtbl;
__gshared EnumFmtVtbl gEnumVtbl;

// ---------------------------------------------------------------------------
// Crash/hang capture: verdict lines must survive anything OLE does headless.

extern (Windows) LONG sehFilter(EXCEPTION_POINTERS* ep) nothrow
{
    const code = ep && ep.ExceptionRecord ? ep.ExceptionRecord.ExceptionCode : 0;
    logEvent("crash seh code=0x%08lx phase=%d", code, g.phase);
    ExitProcess(0);
    return 1;
}

extern (Windows) uint watchdogProc(void* arg) nothrow
{
    Sleep(cast(DWORD) cast(size_t) arg);
    logEvent("watchdog_fired phase=%d dnd_done=%d", g.phase, g.dndDone ? 1 : 0);
    ExitProcess(0);
    return 0;
}

// ---------------------------------------------------------------------------
// Clipboard helpers.

const(char)* cfName(UINT fmt, char* scratch, size_t n) nothrow
{
    switch (fmt)
    {
    case CF_TEXT:
        return "CF_TEXT";
    case CF_BITMAP:
        return "CF_BITMAP";
    case CF_OEMTEXT:
        return "CF_OEMTEXT";
    case CF_UNICODETEXT:
        return "CF_UNICODETEXT";
    case CF_LOCALE:
        return "CF_LOCALE";
    case CF_HDROP:
        return "CF_HDROP";
    case CF_DIB:
        return "CF_DIB";
    case CF_DIBV5:
        return "CF_DIBV5";
    default:
        WCHAR[64] wname;
        const len = GetClipboardFormatNameW(fmt, wname.ptr, 64);
        if (len > 0)
        {
            int p;
            foreach (i; 0 .. len)
                if (p < n - 1)
                    scratch[p++] = wname[i] < 0x80 ? cast(char) wname[i] : '?';
            scratch[p] = 0;
        }
        else
            snprintf(scratch, n, "0x%04x", fmt);
        return scratch;
    }
}

// Log `clip_offer formats=[...]` for the currently-open clipboard.
void logOfferedFormats(const(char)* who) nothrow
{
    char[512] line;
    char[80] scratch;
    int p;
    UINT fmt = 0;
    int count;
    while ((fmt = EnumClipboardFormats(fmt)) != 0)
    {
        const nm = cfName(fmt, scratch.ptr, scratch.length);
        p += snprintf(line.ptr + p, line.length - p, "%s%s", count ? ",".ptr : "".ptr, nm);
        ++count;
    }
    logEvent("clip_offer who=%s n=%d formats=[%s] seq=%lu",
        who, count, line.ptr, GetClipboardSequenceNumber());
}

// The GMEM_MOVEABLE contract: SetClipboardData takes an HGLOBAL allocated
// with GMEM_MOVEABLE and the *system* owns it afterwards (never free it,
// never use it again after a successful SetClipboardData).
HANDLE makeTextHGlobal(const(wchar)[] s) nothrow
{
    HANDLE h = GlobalAlloc(GMEM_MOVEABLE, s.length * 2);
    if (h is null)
        return null;
    void* p = GlobalLock(h);
    memcpy(p, s.ptr, s.length * 2);
    GlobalUnlock(h);
    return h;
}

bool openClipboardRetry(HWND owner, int tries = 20) nothrow
{
    foreach (i; 0 .. tries)
    {
        if (OpenClipboard(owner))
            return true;
        Sleep(50);
    }
    return false;
}

// Read CF_UNICODETEXT from the open clipboard; log bytes + payload match.
void readUnicodeText(const(char)* who) nothrow
{
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h is null)
    {
        logEvent("clip_read who=%s fmt=CF_UNICODETEXT result=null err=%lu",
            who, GetLastError());
        return;
    }
    auto p = cast(const(wchar)*) GlobalLock(h);
    const total = GlobalSize(h); // includes the NUL (and any slack)
    size_t len;
    while (p[len])
        ++len;
    const match = len + 1 == PAYLOAD.length &&
        memcmp(p, PAYLOAD.ptr, PAYLOAD_BYTES) == 0;
    logEvent("clip_read who=%s fmt=CF_UNICODETEXT bytes=%zu wchars=%zu payload_match=%d",
        who, total, len, match ? 1 : 0);
    GlobalUnlock(h);
}

// ---------------------------------------------------------------------------
// Phases 1-2: paste at startup, immediate copy + readback.

void phasePasteStartup() nothrow
{
    logEvent("phase name=paste_startup");
    if (!openClipboardRetry(null))
        return logEvent("error what=OpenClipboard code=%lu", GetLastError());
    logOfferedFormats("owner_startup");
    if (IsClipboardFormatAvailable(CF_UNICODETEXT))
        readUnicodeText("owner_startup");
    else
        logEvent("clip_read who=owner_startup fmt=CF_UNICODETEXT result=absent");
    CloseClipboard();
}

void phaseCopyImmediate() nothrow
{
    logEvent("phase name=copy_immediate");
    if (!OpenClipboard(g.hwnd))
        return logEvent("error what=OpenClipboard code=%lu", GetLastError());
    EmptyClipboard(); // we become the owner
    HANDLE h = makeTextHGlobal(PAYLOAD);
    const ok = SetClipboardData(CF_UNICODETEXT, h);
    logEvent("clip_send fmt=CF_UNICODETEXT bytes=%zu delayed=0 ok=%d owner=%p",
        PAYLOAD_BYTES, ok !is null ? 1 : 0, GetClipboardOwner());
    CloseClipboard();

    // Read-back: what did Windows synthesize around CF_UNICODETEXT?
    if (openClipboardRetry(null))
    {
        logOfferedFormats("owner_readback");
        readUnicodeText("owner_readback");
        CloseClipboard();
    }
}

// ---------------------------------------------------------------------------
// Phase 4: delayed rendering. SetClipboardData(fmt, NULL) promises the data;
// WM_RENDERFORMAT arrives only when somebody calls GetClipboardData.

void phaseCopyDelayed(const(char)* tag) nothrow
{
    logEvent("phase name=%s", tag);
    if (!OpenClipboard(g.hwnd))
        return logEvent("error what=OpenClipboard code=%lu", GetLastError());
    EmptyClipboard();
    const ok = SetClipboardData(CF_UNICODETEXT, null); // the promise
    g.delayedSetAt = nowUs();
    logEvent("clip_send fmt=CF_UNICODETEXT bytes=0 delayed=1 ok=%d", ok is null ? 0 : 1);
    // NOTE: SetClipboardData(fmt, NULL) returns NULL on success here — NULL is
    // also the "no data" success answer for delayed rendering (check GetLastError).
    logEvent("clip_send_delayed err=%lu", GetLastError());
    CloseClipboard();
}

// The in-process demand: a thread reads the clipboard 300 ms after the
// delayed SetClipboardData, forcing a WM_RENDERFORMAT into the main pump.
extern (Windows) uint demandThread(void* arg) nothrow
{
    Sleep(300);
    logEvent("thread=demand action=GetClipboardData t=%lld", nowUs());
    if (!openClipboardRetry(null))
        return 0;
    readUnicodeText("demand_thread");
    CloseClipboard();
    return 0;
}

// The ownership grab: another "app" (a thread opening with no owner window)
// empties the clipboard -> the owner window gets WM_DESTROYCLIPBOARD.
extern (Windows) uint grabThread(void* arg) nothrow
{
    if (!openClipboardRetry(null))
        return 0;
    logEvent("thread=grab action=EmptyClipboard t=%lld", nowUs());
    EmptyClipboard();
    HANDLE h = makeTextHGlobal("grabbed\0"w);
    SetClipboardData(CF_UNICODETEXT, h);
    CloseClipboard();
    return 0;
}

void spawnReader(int n) nothrow
{
    WCHAR[MAX_PATH] exe;
    GetModuleFileNameW(null, exe.ptr, MAX_PATH);
    WCHAR[MAX_PATH + 16] cmd;
    int p;
    cmd[p++] = '"';
    for (int i = 0; exe[i]; ++i)
        cmd[p++] = exe[i];
    cmd[p++] = '"';
    foreach (ch; " --reader"w)
        cmd[p++] = ch;
    cmd[p] = 0;
    STARTUPINFOW si;
    si.cb = STARTUPINFOW.sizeof;
    PROCESS_INFORMATION pi;
    logEvent("spawn_reader n=%d", n);
    if (!CreateProcessW(null, cmd.ptr, null, null, TRUE, 0, null, null, &si, &pi))
        return logEvent("error what=CreateProcessW code=%lu", GetLastError());
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess); // it logs on its own; the pump must keep running
}

// ---------------------------------------------------------------------------
// COM implementations — IDropTarget (the window side).

extern (Windows) HRESULT dtQueryInterface(void* self, const(GUID)* riid, void** ppv) nothrow
{
    if (sameGuid(riid, &IID_IUnknown) || sameGuid(riid, &IID_IDropTarget))
    {
        *ppv = self;
        return S_OK;
    }
    *ppv = null;
    return E_NOINTERFACE;
}

extern (Windows) ULONG comAddRef(void* self) nothrow
{
    return cast(ULONG)++(cast(ComObj!DropTargetVtbl*) self).refs;
}

extern (Windows) ULONG comRelease(void* self) nothrow
{
    return cast(ULONG)--(cast(ComObj!DropTargetVtbl*) self).refs; // static lifetime
}

// Probe the offered formats through the foreign IDataObject pointer.
void logDataObjectFormats(void* dataObj) nothrow
{
    auto obj = cast(ComObj!DataObjectVtbl*) dataObj;
    const sameObject = dataObj is &g.data;
    logEvent("dnd_dataobject ptr=%p is_our_source_object=%d", dataObj, sameObject ? 1 : 0);

    FORMATETC fe = FORMATETC(CF_HDROP, null, DVASPECT_CONTENT, -1, TYMED_HGLOBAL);
    const hrHdrop = obj.vtbl.QueryGetData(dataObj, &fe);
    fe.cfFormat = CF_UNICODETEXT;
    const hrText = obj.vtbl.QueryGetData(dataObj, &fe);
    logEvent("dnd_querygetdata CF_HDROP=0x%08lx CF_UNICODETEXT=0x%08lx", hrHdrop, hrText);

    void* enumPtr;
    if (obj.vtbl.EnumFormatEtc(dataObj, DATADIR_GET, &enumPtr) == S_OK && enumPtr)
    {
        auto en = cast(ComObj!EnumFmtVtbl*) enumPtr;
        char[256] line;
        char[80] scratch;
        int p, count;
        FORMATETC got;
        ULONG fetched;
        while (en.vtbl.Next(enumPtr, 1, &got, &fetched) == S_OK && fetched == 1)
        {
            const nm = cfName(got.cfFormat, scratch.ptr, scratch.length);
            p += snprintf(line.ptr + p, line.length - p, "%s%s(tymed=%lu)",
                count ? ",".ptr : "".ptr, nm, got.tymed);
            ++count;
        }
        en.vtbl.Release(enumPtr);
        logEvent("dnd_enter formats=[%s] n=%d", line.ptr, count);
    }
}

extern (Windows) HRESULT dtDragEnter(void* self, void* dataObj, DWORD keys,
    POINTL pt, DWORD* effect) nothrow
{
    logEvent("dnd_enter keys=0x%lx pt=%ld,%ld effects_offered=0x%lx", keys, pt.x, pt.y, *effect);
    logDataObjectFormats(dataObj);
    *effect = DROPEFFECT_COPY; // accept: we want a copy
    logEvent("dnd_enter_reply effect=DROPEFFECT_COPY");
    return S_OK;
}

extern (Windows) HRESULT dtDragOver(void* self, DWORD keys, POINTL pt, DWORD* effect) nothrow
{
    static __gshared int overCount;
    if (++overCount <= 3)
        logEvent("dnd_over n=%d pt=%ld,%ld effect_in=0x%lx", overCount, pt.x, pt.y, *effect);
    *effect = DROPEFFECT_COPY;
    return S_OK;
}

extern (Windows) HRESULT dtDragLeave(void* self) nothrow
{
    logEvent("dnd_leave");
    return S_OK;
}

extern (Windows) HRESULT dtDrop(void* self, void* dataObj, DWORD keys,
    POINTL pt, DWORD* effect) nothrow
{
    logEvent("dnd_drop pt=%ld,%ld effects_in=0x%lx", pt.x, pt.y, *effect);
    auto obj = cast(ComObj!DataObjectVtbl*) dataObj;
    FORMATETC fe = FORMATETC(CF_HDROP, null, DVASPECT_CONTENT, -1, TYMED_HGLOBAL);
    STGMEDIUM med;
    const hr = obj.vtbl.GetData(dataObj, &fe, &med);
    if (hr == S_OK && med.tymed == TYMED_HGLOBAL)
    {
        const bytes = GlobalSize(med.hGlobal);
        auto drop = cast(DROPFILES*) GlobalLock(med.hGlobal);
        const nFiles = DragQueryFileW(med.hGlobal, 0xFFFFFFFF, null, 0);
        WCHAR[MAX_PATH] path;
        const len = DragQueryFileW(med.hGlobal, 0, path.ptr, MAX_PATH);
        char[MAX_PATH] ascii;
        int p;
        foreach (i; 0 .. len)
            ascii[p++] = path[i] < 0x80 ? cast(char) path[i] : '?';
        ascii[p] = 0;
        logEvent("dnd_drop fmt=CF_HDROP bytes=%zu files=%u fwide=%d file0=%s",
            bytes, nFiles, drop.fWide, ascii.ptr);
        GlobalUnlock(med.hGlobal);
        ReleaseStgMedium(&med);
    }
    else
        logEvent("dnd_drop getdata_hr=0x%08lx tymed=%lu", hr, med.tymed);
    *effect = DROPEFFECT_COPY;
    return S_OK;
}

// ---------------------------------------------------------------------------
// IDropSource — drives the in-process drag to a programmatic drop.

extern (Windows) HRESULT dsQueryInterface(void* self, const(GUID)* riid, void** ppv) nothrow
{
    if (sameGuid(riid, &IID_IUnknown) || sameGuid(riid, &IID_IDropSource))
    {
        *ppv = self;
        return S_OK;
    }
    *ppv = null;
    return E_NOINTERFACE;
}

extern (Windows) HRESULT dsQueryContinueDrag(void* self, BOOL esc, DWORD keys) nothrow
{
    auto src = cast(ComObj!DropSourceVtbl*) self;
    const n = ++src.cursor;
    if (n <= 3 || n == 6)
        logEvent("dnd_source query_continue n=%u esc=%d keys=0x%lx", n, esc, keys);
    if (esc)
        return DRAGDROP_S_CANCEL;
    // No real mouse button is involved: after a few iterations, drop.
    return n >= 6 ? DRAGDROP_S_DROP : S_OK;
}

extern (Windows) HRESULT dsGiveFeedback(void* self, DWORD effect) nothrow
{
    static __gshared int n;
    if (++n <= 2)
        logEvent("dnd_source give_feedback n=%d effect=0x%lx", n, effect);
    return DRAGDROP_S_USEDEFAULTCURSORS;
}

// ---------------------------------------------------------------------------
// IDataObject — offers exactly one format: CF_HDROP as HGLOBAL.

extern (Windows) HRESULT doQueryInterface(void* self, const(GUID)* riid, void** ppv) nothrow
{
    if (sameGuid(riid, &IID_IUnknown) || sameGuid(riid, &IID_IDataObject))
    {
        *ppv = self;
        return S_OK;
    }
    *ppv = null;
    return E_NOINTERFACE;
}

bool isOurFormat(const(FORMATETC)* fe) nothrow
{
    return fe.cfFormat == CF_HDROP && (fe.tymed & TYMED_HGLOBAL) != 0
        && fe.dwAspect == DVASPECT_CONTENT;
}

extern (Windows) HRESULT doGetData(void* self, FORMATETC* fe, STGMEDIUM* med) nothrow
{
    logEvent("dnd_request fmt=0x%04x tymed=%lu aspect=%lu", fe.cfFormat, fe.tymed, fe.dwAspect);
    if (!isOurFormat(fe))
        return DV_E_FORMATETC;
    // Hand out a fresh copy; the callee owns and frees it (pUnkForRelease=null).
    const size = GlobalSize(g.hDropFiles);
    HANDLE dup = GlobalAlloc(GMEM_MOVEABLE, size);
    memcpy(GlobalLock(dup), GlobalLock(g.hDropFiles), size);
    GlobalUnlock(dup);
    GlobalUnlock(g.hDropFiles);
    med.tymed = TYMED_HGLOBAL;
    med.hGlobal = dup;
    med.pUnkForRelease = null;
    logEvent("dnd_send fmt=CF_HDROP bytes=%zu", size);
    return S_OK;
}

extern (Windows) HRESULT doGetDataHere(void* self, FORMATETC* fe, STGMEDIUM* med) nothrow
{
    return E_NOTIMPL;
}

extern (Windows) HRESULT doQueryGetData(void* self, FORMATETC* fe) nothrow
{
    return isOurFormat(fe) ? S_OK : DV_E_FORMATETC;
}

extern (Windows) HRESULT doGetCanonical(void* self, FORMATETC* a, FORMATETC* b) nothrow
{
    *b = *a;
    b.ptd = null;
    return E_NOTIMPL;
}

extern (Windows) HRESULT doSetData(void* self, FORMATETC* fe, STGMEDIUM* med, BOOL rel) nothrow
{
    return E_NOTIMPL;
}

extern (Windows) HRESULT doEnumFormatEtc(void* self, DWORD dir, void** ppEnum) nothrow
{
    if (dir != DATADIR_GET)
    {
        *ppEnum = null;
        return E_NOTIMPL;
    }
    __gshared ComObj!EnumFmtVtbl en; // single static enumerator (demo-grade)
    en.vtbl = &gEnumVtbl;
    en.refs = 1;
    en.cursor = 0;
    *ppEnum = &en;
    return S_OK;
}

extern (Windows) HRESULT doDAdvise(void* self, FORMATETC* fe, DWORD f, void* sink, DWORD* conn) nothrow
{
    return OLE_E_ADVISENOTSUPPORTED;
}

extern (Windows) HRESULT doDUnadvise(void* self, DWORD conn) nothrow
{
    return OLE_E_ADVISENOTSUPPORTED;
}

extern (Windows) HRESULT doEnumDAdvise(void* self, void** ppEnum) nothrow
{
    *ppEnum = null;
    return OLE_E_ADVISENOTSUPPORTED;
}

// IEnumFORMATETC over the one-format list.
extern (Windows) HRESULT efQueryInterface(void* self, const(GUID)* riid, void** ppv) nothrow
{
    if (sameGuid(riid, &IID_IUnknown) || sameGuid(riid, &IID_IEnumFORMATETC))
    {
        *ppv = self;
        return S_OK;
    }
    *ppv = null;
    return E_NOINTERFACE;
}

extern (Windows) HRESULT efNext(void* self, ULONG celt, FORMATETC* rgelt, ULONG* fetched) nothrow
{
    auto en = cast(ComObj!EnumFmtVtbl*) self;
    ULONG got = 0;
    if (celt >= 1 && en.cursor == 0)
    {
        rgelt[0] = FORMATETC(CF_HDROP, null, DVASPECT_CONTENT, -1, TYMED_HGLOBAL);
        en.cursor = 1;
        got = 1;
    }
    if (fetched)
        *fetched = got;
    return got == celt ? S_OK : S_FALSE;
}

extern (Windows) HRESULT efSkip(void* self, ULONG celt) nothrow
{
    auto en = cast(ComObj!EnumFmtVtbl*) self;
    en.cursor += celt;
    return en.cursor <= 1 ? S_OK : S_FALSE;
}

extern (Windows) HRESULT efReset(void* self) nothrow
{
    (cast(ComObj!EnumFmtVtbl*) self).cursor = 0;
    return S_OK;
}

extern (Windows) HRESULT efClone(void* self, void** ppv) nothrow
{
    *ppv = null;
    return E_NOTIMPL;
}

void initVtbls() nothrow
{
    gTargetVtbl = DropTargetVtbl(&dtQueryInterface, &comAddRef, &comRelease,
        &dtDragEnter, &dtDragOver, &dtDragLeave, &dtDrop);
    gSourceVtbl = DropSourceVtbl(&dsQueryInterface, &comAddRef, &comRelease,
        &dsQueryContinueDrag, &dsGiveFeedback);
    gDataVtbl = DataObjectVtbl(&doQueryInterface, &comAddRef, &comRelease,
        &doGetData, &doGetDataHere, &doQueryGetData, &doGetCanonical,
        &doSetData, &doEnumFormatEtc, &doDAdvise, &doDUnadvise, &doEnumDAdvise);
    gEnumVtbl = EnumFmtVtbl(&efQueryInterface, &comAddRef, &comRelease,
        &efNext, &efSkip, &efReset, &efClone);
    g.target.vtbl = &gTargetVtbl;
    g.source.vtbl = &gSourceVtbl;
    g.data.vtbl = &gDataVtbl;
}

// ---------------------------------------------------------------------------
// Phase 7: the in-process drag — DoDragDrop onto our own registered target.

// DoDragDrop's modal loop is driven by input events; headless there are none,
// so a helper thread jiggles the (wineserver-virtual) cursor to keep the loop
// calling QueryContinueDrag.
extern (Windows) uint jiggleThread(void* arg) nothrow
{
    POINT p;
    GetCursorPos(&p);
    foreach (i; 0 .. 150)
    {
        SetCursorPos(p.x + (i & 1), p.y);
        Sleep(20);
        if (g.dndDone)
            break;
    }
    return 0;
}

void buildDropFiles() nothrow
{
    // A real witness file in the prefix's temp dir.
    WCHAR[MAX_PATH] tmp;
    GetTempPathW(MAX_PATH, tmp.ptr);
    int p;
    while (tmp[p])
        ++p;
    foreach (i, ch; "wsi-f16-drop.txt\0"w)
        tmp[p + i] = ch;
    HANDLE f = CreateFileW(tmp.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, null);
    DWORD wrote;
    WriteFile(f, "wsi f16 drop payload\n".ptr, 21, &wrote, null);
    CloseHandle(f);
    g.dropPath[] = tmp[];

    int pathLen;
    while (tmp[pathLen])
        ++pathLen;
    const bytes = DROPFILES.sizeof + (pathLen + 2) * 2; // path + double NUL
    g.hDropFiles = GlobalAlloc(GMEM_MOVEABLE, bytes);
    auto drop = cast(DROPFILES*) GlobalLock(g.hDropFiles);
    *drop = DROPFILES.init;
    drop.pFiles = DROPFILES.sizeof;
    drop.fWide = TRUE;
    auto dst = cast(wchar*)(cast(ubyte*) drop + DROPFILES.sizeof);
    memcpy(dst, tmp.ptr, pathLen * 2);
    dst[pathLen] = 0;
    dst[pathLen + 1] = 0; // the list terminator
    GlobalUnlock(g.hDropFiles);
    logEvent("dnd_payload file_created bytes=%zu", bytes);
}

void phaseDnd() nothrow
{
    logEvent("phase name=dnd");
    buildDropFiles();

    // Park the virtual cursor over our client area so the OLE loop's
    // WindowFromPoint hit-test finds the registered IDropTarget.
    RECT rc;
    GetWindowRect(g.hwnd, &rc);
    SetCursorPos((rc.left + rc.right) / 2, (rc.top + rc.bottom) / 2);
    logEvent("dnd_source cursor_parked=%ld,%ld", (rc.left + rc.right) / 2,
        (rc.top + rc.bottom) / 2);

    HANDLE jig = CreateThread(null, 0, &jiggleThread, null, 0, null);
    DWORD effect = DROPEFFECT_NONE;
    logEvent("dnd_source DoDragDrop_begin ok_effects=COPY|MOVE|LINK");
    const hr = DoDragDrop(&g.data, &g.source, // hand-rolled COM objects
        DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK, &effect);
    g.dndDone = true;
    const(char)* hrName = hr == DRAGDROP_S_DROP ? "DRAGDROP_S_DROP"
        : hr == DRAGDROP_S_CANCEL ? "DRAGDROP_S_CANCEL" : "other";
    logEvent("dnd_source DoDragDrop_returned hr=0x%08lx (%s) effect=0x%lx query_continue_calls=%u",
        hr, hrName, effect, g.source.cursor);
    WaitForSingleObject(jig, 4000);
    CloseHandle(jig);
}

// ---------------------------------------------------------------------------
// WndProc: the clipboard-protocol messages are the finding.

extern (Windows) LRESULT wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) nothrow
{
    switch (msg)
    {
    case WM_RENDERFORMAT:
        // Demanded NOW: the clipboard is already open for us — just SetClipboardData.
        ++g.renderDemands;
        logEvent("clip_request msg=WM_RENDERFORMAT fmt=0x%04llx demand_n=%d us_since_delayed_set=%lld",
            cast(ulong) wp, g.renderDemands, nowUs() - g.delayedSetAt);
        if (wp == CF_UNICODETEXT)
        {
            SetClipboardData(CF_UNICODETEXT, makeTextHGlobal(PAYLOAD));
            logEvent("clip_send fmt=CF_UNICODETEXT bytes=%zu delayed_render=1", PAYLOAD_BYTES);
        }
        return 0;

    case WM_RENDERALLFORMATS:
        // Owner is dying with promises outstanding: render everything, with
        // the open/owner-check ceremony the docs require.
        ++g.renderAll;
        logEvent("clip_request msg=WM_RENDERALLFORMATS");
        if (OpenClipboard(hwnd))
        {
            if (GetClipboardOwner() is hwnd)
            {
                SetClipboardData(CF_UNICODETEXT, makeTextHGlobal(PAYLOAD));
                logEvent("clip_send fmt=CF_UNICODETEXT bytes=%zu render_all=1", PAYLOAD_BYTES);
            }
            CloseClipboard();
        }
        return 0;

    case WM_DESTROYCLIPBOARD:
        logEvent("ownership_lost msg=WM_DESTROYCLIPBOARD seq=%lu", GetClipboardSequenceNumber());
        return 0;

    case WM_CLIPBOARDUPDATE:
        logEvent("clip_update msg=WM_CLIPBOARDUPDATE seq=%lu owner=%p",
            GetClipboardSequenceNumber(), GetClipboardOwner());
        return 0;

    case WM_TIMER:
        ++g.ticks;
        if (!g.autoExit)
            return 0;
        switch (g.ticks)
        {
        case 3:
            g.phase = 1;
            phasePasteStartup();
            break;
        case 12:
            g.phase = 2;
            phaseCopyImmediate();
            break;
        case 25:
            g.phase = 3;
            spawnReader(1);
            break;
        case 60:
            g.phase = 4;
            phaseCopyDelayed("copy_delayed_thread_demand");
            CloseHandle(CreateThread(null, 0, &demandThread, null, 0, null));
            break;
        case 90:
            g.phase = 5;
            phaseCopyDelayed("copy_delayed_process_demand");
            spawnReader(2);
            break;
        case 130:
            g.phase = 6;
            logEvent("phase name=grab_ownership");
            CloseHandle(CreateThread(null, 0, &grabThread, null, 0, null));
            break;
        case 150:
            g.phase = 7;
            phaseDnd();
            break;
        case 190:
            g.phase = 8;
            phaseCopyDelayed("copy_delayed_then_destroy");
            DestroyWindow(hwnd); // -> WM_RENDERALLFORMATS before WM_DESTROY
            break;
        default:
            break;
        }
        return 0;

    case WM_CHAR: // interactive mode: c=copy v=paste d=dnd
        if (wp == 'c')
            phaseCopyImmediate();
        else if (wp == 'v')
            phasePasteStartup();
        else if (wp == 'd')
            phaseDnd();
        return 0;

    case WM_PAINT:
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        RECT rc;
        GetClientRect(hwnd, &rc);
        FillRect(dc, &rc, cast(HBRUSH)(COLOR_WINDOW + 1));
        EndPaint(hwnd, &ps);
        return 0;

    case WM_DESTROY:
        logEvent("msg name=WM_DESTROY render_demands=%d render_all=%d",
            g.renderDemands, g.renderAll);
        KillTimer(hwnd, 1);
        RevokeDragDrop(hwnd);
        PostQuitMessage(0);
        return 0;

    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

// ---------------------------------------------------------------------------
// --reader role: a separate process in the same prefix reading the clipboard.

int readerMain() nothrow
{
    instrumentInit("f16_win32_reader");
    logEvent("reader_start pid=%lu", GetCurrentProcessId());
    if (!openClipboardRetry(null))
    {
        logEvent("error what=OpenClipboard code=%lu", GetLastError());
        return 0;
    }
    logOfferedFormats("reader");
    if (IsClipboardFormatAvailable(CF_UNICODETEXT))
        readUnicodeText("reader"); // a delayed format triggers WM_RENDERFORMAT in the owner
    else
        logEvent("clip_read who=reader fmt=CF_UNICODETEXT result=absent");
    CloseClipboard();
    logEvent("reader_exit code=0");
    return 0;
}

// ---------------------------------------------------------------------------

bool wantAutoExit() nothrow
{
    WCHAR[8] buf;
    const n = GetEnvironmentVariableW("WSI_AUTO_EXIT"w.ptr, buf.ptr, buf.length);
    return n >= 1 && n < buf.length && buf[0] == '1';
}

int main(string[] args)
{
    foreach (a; args[1 .. $])
        if (a == "--reader")
            return readerMain();

    instrumentInit("f16_win32");
    logEvent("init_start");
    g.autoExit = wantAutoExit();
    g.inst = GetModuleHandleW(null);
    SetUnhandledExceptionFilter(cast(LPTOP_LEVEL_EXCEPTION_FILTER)&sehFilter);
    if (g.autoExit)
        CloseHandle(CreateThread(null, 0, &watchdogProc,
            cast(void*) cast(size_t) 30000, 0, null));

    // OLE drag-and-drop REQUIRES OleInitialize (it layers the clipboard/DnD
    // machinery on top of CoInitialize's STA); a CoInitialize-only thread gets
    // E_OUTOFMEMORY-flavored failures from RegisterDragDrop.
    const hrOle = OleInitialize(null);
    logEvent("step name=OleInitialize hr=0x%08lx", hrOle);
    initVtbls();

    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = g.inst;
    wc.lpszClassName = "wsi-f16-class"w.ptr;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    wc.hbrBackground = cast(HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassExW(&wc);

    g.hwnd = CreateWindowExW(0, "wsi-f16-class"w.ptr, "wsi-f16-clipboard-dnd"w.ptr,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 320,
        null, null, g.inst, null);
    if (g.hwnd is null)
    {
        logEvent("error what=CreateWindowExW code=%lu", GetLastError());
        return 0;
    }
    ShowWindow(g.hwnd, SW_SHOW);
    UpdateWindow(g.hwnd);
    logEvent("window_created hwnd=%p", g.hwnd);

    const lst = AddClipboardFormatListener(g.hwnd);
    logEvent("step name=AddClipboardFormatListener ret=%d err=%lu", lst, GetLastError());
    const hrReg = RegisterDragDrop(g.hwnd, &g.target);
    logEvent("step name=RegisterDragDrop hr=0x%08lx", hrReg);

    SetTimer(g.hwnd, 1, 16, null);
    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    OleUninitialize();
    logEvent("exit code=0 render_demands=%d render_all=%d", g.renderDemands, g.renderAll);
    return 0;
}

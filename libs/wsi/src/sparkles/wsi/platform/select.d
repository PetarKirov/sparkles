/** Pure backend selection, separate from environment probing. */
module sparkles.wsi.platform.select;

import sparkles.wsi.types;

@safe pure nothrow @nogc:

struct BackendAvailability
{
    bool wayland;
    bool x11;
    bool win32;
    bool appkit;
}

WsiResult!BackendKind selectBackend(BackendPreference preference,
    in BackendAvailability available)
{
    final switch (preference)
    {
        case BackendPreference.automatic:
            if (available.wayland) return wsiOk(BackendKind.wayland);
            if (available.x11) return wsiOk(BackendKind.x11);
            if (available.win32) return wsiOk(BackendKind.win32);
            if (available.appkit) return wsiOk(BackendKind.appkit);
            return unavailable(BackendKind.wayland);
        case BackendPreference.wayland:
            return available.wayland
                ? wsiOk(BackendKind.wayland) : unavailable(BackendKind.wayland);
        case BackendPreference.x11:
            return available.x11
                ? wsiOk(BackendKind.x11) : unavailable(BackendKind.x11);
        case BackendPreference.win32:
            return available.win32
                ? wsiOk(BackendKind.win32) : unavailable(BackendKind.win32);
        case BackendPreference.appkit:
            return available.appkit
                ? wsiOk(BackendKind.appkit) : unavailable(BackendKind.appkit);
    }
}

private WsiResult!BackendKind unavailable(BackendKind backend)
    => wsiErr!BackendKind(wsiError(WsiErrorKind.unavailable,
        WsiOperation.open, backend,
        diagnostic: "requested WSI backend is unavailable"));

@("wsi.platform.select.prefersNativeLinuxOrder")
unittest
{
    const both = BackendAvailability(wayland: true, x11: true);
    assert(selectBackend(BackendPreference.automatic, both).value
        == BackendKind.wayland);
    assert(selectBackend(BackendPreference.x11, both).value == BackendKind.x11);
}

@("wsi.platform.select.refusesMissingExplicitBackend")
unittest
{
    const onlyX = BackendAvailability(x11: true);
    const result = selectBackend(BackendPreference.wayland, onlyX);
    assert(result.hasError);
    assert(result.error.kind == WsiErrorKind.unavailable);
    assert(result.error.backend == BackendKind.wayland);
}

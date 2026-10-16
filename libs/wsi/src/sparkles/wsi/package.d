/**
`sparkles:wsi` — dependency-light native desktop window-system integration.

The current package exports the platform-independent contract and deterministic
recording implementation. Native Event Horizon attachment lands backend by
backend under `platform.*` without changing these values.
*/
module sparkles.wsi;

public import sparkles.wsi.clipboard;
public import sparkles.wsi.clipboard_conformance;
public import sparkles.wsi.conformance;
public import sparkles.wsi.events;
public import sparkles.wsi.handles;
public import sparkles.wsi.loop;
public import sparkles.wsi.platform.select;

version (Windows)
    public import sparkles.wsi.platform.win32;
version (OSX)
    public import sparkles.wsi.platform.appkit;
// Android is `linux` to D, but has neither Wayland nor X11.
version (Android)
    public import sparkles.wsi.platform.android;
else version (linux)
{
    public import sparkles.wsi.platform.wayland;
    public import sparkles.wsi.platform.x11;
}
public import sparkles.wsi.types;

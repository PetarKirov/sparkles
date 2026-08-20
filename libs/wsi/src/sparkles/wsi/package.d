/**
`sparkles:wsi` — dependency-light native desktop window-system integration.

The current package exports the platform-independent contract and deterministic
recording implementation. Native Event Horizon attachment lands backend by
backend under `platform.*` without changing these values.
*/
module sparkles.wsi;

public import sparkles.wsi.events;
public import sparkles.wsi.handles;
public import sparkles.wsi.loop;
public import sparkles.wsi.platform.select;

version (Windows)
    public import sparkles.wsi.platform.win32;
version (OSX)
    public import sparkles.wsi.platform.appkit;
version (linux)
    public import sparkles.wsi.platform.wayland;
version (linux)
    public import sparkles.wsi.platform.x11;
public import sparkles.wsi.types;

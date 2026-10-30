/**
Who an application is, once per process, to everything that asks: the window
system, the graphics driver, the package manager and the desktop.

One value instead of a name in each place: before it, Wayland's `app_id` was a
constant, Vulkan's application version a literal, the window title a string of
its own and the Android package id lived only in the build. Here because every
layer that reads it — `sparkles:wsi`, `sparkles:vulkan-wsi`, `sparkles:ui-app`,
`sparkles:android` — depends on `base`, and not all of them on each other.
*/
module sparkles.base.app_identity;

import sparkles.base.buffer : InlineBuffer;
import sparkles.base.text.cstring : hasInteriorNul;
import sparkles.base.text.utf8 : validateUtf8;

/**
An application's identity: to the window system (Wayland's `app_id`, X11's
`WM_CLASS`, Win32's AppUserModelID — what a desktop matches against an installed
`.desktop` file for the dock's name and icon), to the graphics driver (Vulkan's
application name and version) and, for a window that gives none, the title.

`id` is reverse-DNS, `dev.petar_kirov.sparkles.text_lab`: segments of ASCII
letters, digits and `_`, each starting with a letter — the intersection of what
Android packages, D-Bus names and desktop-entry ids accept, so one id serves
all three. On Android the installed package is authoritative; the id names it.
*/
struct AppIdentity
{
    InlineBuffer!(char, 128) id;   /// reverse-DNS; empty: `sparkles`
    InlineBuffer!(char, 128) name; /// what a person reads; empty: the id
    ushort[3] version_;            /// major, minor, patch

@safe pure nothrow @nogc:

    /// The id, or the fallback for an application that declares none.
    const(char)[] idOrDefault() const return => id.length ? id[] : "sparkles";

    /// The name, else the id.
    const(char)[] nameOrDefault() const return => name.length ? name[] : idOrDefault;

    /**
    Why `id` or `name` cannot reach the platforms, or `null`. Checked at
    `open`, so a typo fails at start-up rather than as a dock with no icon.
    */
    const(char)[] fault() const
    {
        if (validateUtf8(name[]).hasError || hasInteriorNul(name[]))
            return "application name is not NUL-free UTF-8";
        if (id.length == 0)
            return null;
        size_t segments;
        bool atStart = true;
        foreach (c; id[])
        {
            if (c == '.')
            {
                if (atStart)
                    return "application id has an empty segment";
                ++segments;
                atStart = true;
                continue;
            }
            const letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
            const other = (c >= '0' && c <= '9') || c == '_';
            if (!letter && !other)
                return "application id allows only ASCII letters, digits, `_` and `.`";
            // Android's rule, the strictest of the three.
            if (atStart && !letter)
                return "an application id segment starts with something other than a letter";
            atStart = false;
        }
        if (atStart)
            return "application id has an empty segment";
        return segments == 0 ? "application id is not reverse-DNS" : null;
    }
}

///
@("base.appIdentity.reverseDnsAndDefaults")
@safe pure nothrow @nogc
unittest
{
    AppIdentity app;
    assert(app.fault is null && app.idOrDefault == "sparkles" && app.nameOrDefault == "sparkles");
    assert(app.id.assign("dev.petar_kirov.sparkles.text_lab"));
    assert(app.fault is null && app.nameOrDefault == "dev.petar_kirov.sparkles.text_lab");
    assert(app.name.assign("Sparkles Text Lab"));
    assert(app.nameOrDefault == "Sparkles Text Lab");
    static foreach (bad; ["text_lab", "dev..lab", "dev.lab.", ".dev", "dev.text-lab", "dev.2lab",
            "dev._lab"])
    {
        assert(app.id.assign(bad));
        assert(app.fault !is null, bad);
    }
}

/**
hue's entry on the native arm (`android` configuration): the activity's
`sparkles_wsi_onCreate`, which runs app.d's `main` on the application thread
`sparkles:wsi` starts. Its own module, not app.d's: the native activity loads a
shared library, and the raylib build enters through app.d's `main`, which
raylib's glue calls.
*/
module android_entry;

version (Android):
version (HueGuiVulkan):

import sparkles.wsi.platform.android : AndroidWsiMain;

mixin AndroidWsiMain!run;

private void run()
{
    import core.sys.posix.unistd : _exit;

    import app : hueMain = main;

    // No command line on a phone: `main` reads the configuration file and
    // the extracted asset bundle (`CFG12`, `AND8`), as the raylib APK does.
    const status = hueMain(["hue"]);
    // druntime cannot start twice in a process Android keeps across activity
    // recreations, and returning leaves the activity on screen with nothing
    // drawing it: the process ends with the application. `_exit`, not `exit`:
    // the framework's own threads (hwui's) still run, and the C++ static
    // destructors `exit` runs destroy mutexes they lock (FORTIFY aborts).
    _exit(status);
}

/**
The terminal's entry on the native arm (`android` configuration): the
activity's `sparkles_wsi_onCreate`. Its own module, not app.d's: dub leaves a
library's `app.d` out, and on Android the terminal is the shared library a
NativeActivity loads. The raylib build enters through app.d's `main`.
*/
module android_entry;

version (Android):
version (TerminalVulkan):

import sparkles.wsi.platform.android : AndroidWsiMain;

mixin AndroidWsiMain!run;

private void run()
{
    import android_app : androidMain;

    cast(void) androidMain();
}

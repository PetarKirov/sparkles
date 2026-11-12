/**
The explorer's Android entry (`FXA1`): the activity's `sparkles_wsi_onCreate`.
Its own module, not app.d's: dub leaves a library's `app.d` out as a
program's main, and on Android the explorer is the shared library a
NativeActivity loads.
*/
module android_entry;

version (Android):

import std.file : mkdirRecurse;
import std.path : buildPath;

import sparkles.android.activity : internalDataPath;
import sparkles.android.assets : extractAssetBundle;
import sparkles.ui_app.gui_options : GuiOptions;
import sparkles.wsi.platform.android : AndroidWsiMain, logFailure;

import evaluate : Root;
import launch : defaultQuery, explorerGui, launch, sonameQueriesRoot;
import send : prepareIrohSend, sendStoreParent, shareText;
import sparkles.android.activity : nativeActivity;
import sparkles.android.jni : JniFrame;
import sparkles.iroh_send : IrohSend;

/*
The APK carries the sparkles repository, the fonts and the grammar queries
(nix/packages/android/fileset-explorer.nix); they are extracted into the
app's data directory on the first launch, and again when they change. The
repository there is the fileset root (`FXA2`).
*/
mixin AndroidWsiMain!androidMain;

void androidMain()
{
    const data = internalDataPath;
    if (!extractAssetBundle(data, ["fonts", "grammars", "repo"], buildPath(data, "assets-ready")))
        logFailure("fileset-explorer: the APK's assets could not be extracted");
    sonameQueriesRoot = buildPath(data, "grammars");
    // Send keeps its store in the app's data (`FXS9`); the repository is
    // named `sparkles` in a collection, as it is everywhere else.
    sendStoreParent = buildPath(data, "send");
    mkdirRecurse(sendStoreParent);
    prepareIrohSend = &installJniContext;
    // Send's Share hands the receive command to the share sheet (`FXS4`).
    shareText = (string text) {
        import sparkles.android.intents : androidShare = shareText;

        return androidShare(text, "sendme receive");
    };
    GuiOptions gui = explorerGui;
    gui.gui = true;
    gui.fontDir = [buildPath(data, "fonts")];
    cast(void) launch(Root(dir: buildPath(data, "repo"), name: "sparkles"), defaultQuery, gui);
}

/*
iroh reads the system's DNS servers through JNI on Android, and a send whose
bridge was not given the app's JVM and context aborts (`FXS9`): this hands it
the application context, as a global reference that lives as long as the
process does.
*/
string installJniContext(ref IrohSend lib)
{
    auto f = JniFrame.open();
    if (!f.ok)
        return "the app's JVM could not be reached";
    auto env = f.env;
    auto cls = (*env).GetObjectClass(env, f.activity);
    auto method = (*env).GetMethodID(env, cls, "getApplicationContext", "()Landroid/content/Context;");
    if (method is null || f.failed)
        return "the app has no application context";
    auto context = (*env).CallObjectMethodA(env, f.activity, method, null);
    if (context is null || f.failed)
        return "the app's application context could not be read";
    lib.installAndroidContext(nativeActivity().vm, (*env).NewGlobalRef(env, context));
    return null;
}

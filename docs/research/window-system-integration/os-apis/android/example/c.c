// ImportC shim over the Android NDK native-activity headers: the D compiler parses
// the real NDK headers (struct android_app, ANativeWindow, the APP_CMD_* / looper
// enums, the logging macros' underlying functions), so nothing is hand-declared.
// See docs/guidelines/importc-c-libraries.md. `c.c` -> D module `c`.
//
// NOTE: the `android_native_app_glue.c` *implementation* (which provides
// ANativeActivity_onCreate and calls android_main) lives in the NDK at
// $NDK/sources/android/native_app_glue/ and is compiled alongside this — see the
// build command in ../index.md. This shim only pulls in the declarations.
#pragma attribute(push, nogc, nothrow)
#include <android_native_app_glue.h>
#include <android/native_window.h>
#include <android/log.h>
#pragma attribute(pop)

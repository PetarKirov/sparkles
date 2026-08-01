// ImportC shim for the NDK's <jni.h> — the real header, so the JNIEnv /
// JavaVM function tables, `jvalue`, and every signature come from upstream
// and cannot drift (see docs/guidelines/importc-c-libraries.md).
//
// The stem is `jni_c`, not the canonical `c`: ImportC names the module after
// the file's base name ignoring the package path, and libhue.so already links
// sparkles.ghostty's `c.c` (module `c`). Two shims named `c.c` in one binary
// collide.
//
// It lives HERE rather than under apps/hue/src/ so dub never scans it: dub
// picks up .c files found in a source path, and on a desktop host <jni.h> is
// not the NDK's. The cross build passes this file to ldc2 explicitly, with
// -P-I pointed at the NDK sysroot (see nix/packages/android/{hue,ndk}.nix).
//
// `nogc nothrow` but NOT `pure` — JNI calls mutate VM state.
#pragma attribute(push, nogc, nothrow)
#include <jni.h>
#pragma attribute(pop)

# Android 10: the API level every Android build targets. The single source of
# truth for it: the NDK clang wrappers (ndk.nix), every native dependency's
# platform flag, the driver every D link goes through (dlang.nix's
# `ldc-android`, built for it in host.nix), and the `--min-sdk-version` aapt2
# stamps into the APK (build-apk.nix) all read it, so the declared floor cannot
# drift from the one the code was built against.
#
# The constraints that set it, the highest one winning:
#
#   23  libkqueue's monitor thread waits on `sigwaitinfo`, which bionic
#       hides below 23 (`__INTRODUCED_IN`) — see libkqueue.nix.
#   26  the Skia/Graphite/Vulkan GUI backend.
#   29  LDC's static druntime uses native ELF TLS, and every D library
#       therefore references `__tls_get_addr`, which bionic exports from
#       API 29. This was the real floor while minSdk still claimed 26:
#       the APK installed on API 26–28 and then failed to load its .so
#       ("cannot locate symbol __tls_get_addr"). Found by the terminal
#       port (docs/specs/terminal/android.md), measured with llvm-nm
#       against each API level's libc stub.
#
# Raising it is monotone-safe (a higher `__ANDROID_API__` only unhides
# declarations), but *lowering* the floor under installed users is not:
# a minSdk increase silently drops devices out of the update path and
# F-Droid offers no migration for that. So it is set to its intended
# long-term value now, before anything is published.
"29"
